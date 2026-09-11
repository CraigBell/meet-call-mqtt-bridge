import Darwin
import Foundation
import Security

/// OpenDeck’s tungstenite server requires a classic HTTP upgrade
/// (`Connection: Upgrade`). URLSession/NW WebSocket omit it, so pad
/// presses never reach the plugin.
final class OpenDeckSocket {
    private let port: Int
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "at.craig.call-bridge.opendeck-ws")
    private let lock = NSLock()
    private var buffer = Data()
    private var upgraded = false
    private var reconnecting = false
    var onMessage: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onFail: ((String) -> Void)?

    init(port: Int) {
        self.port = port
    }

    func connect() {
        queue.async { [weak self] in
            self?.open()
        }
    }

    func send(_ obj: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard JSONSerialization.isValidJSONObject(obj),
              let payload = try? JSONSerialization.data(withJSONObject: obj)
        else {
            completion?(nil)
            return
        }
        let frame = Self.textFrame(payload)
        lock.lock()
        let sock = fd
        lock.unlock()
        guard sock >= 0 else {
            completion?(POSIXError(.ENOTCONN))
            return
        }
        let ok = frame.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return Darwin.send(sock, base, frame.count, 0) == frame.count
        }
        completion?(ok ? nil : POSIXError(.EIO))
    }

    func cancel() {
        queue.async { [weak self] in
            self?.closeFd()
        }
    }

    private func open() {
        closeFd()
        buffer.removeAll()
        upgraded = false
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else {
            fail("socket \(errno)")
            return
        }
        fd = sock
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            fail("connect errno=\(errno)")
            return
        }
        Log.line("plugin: tcp \(port) connected")
        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = nonce.base64EncodedString()
        let req = "GET / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let reqData = Data(req.utf8)
        let sent = reqData.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return Darwin.send(sock, base, reqData.count, 0)
        }
        if sent != reqData.count {
            fail("upgrade send \(sent)")
            return
        }
        readLoop()
    }

    private func readLoop() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while fd >= 0 {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 {
                fail("recv \(n) errno=\(errno)")
                return
            }
            buffer.append(contentsOf: chunk[0..<n])
            consume()
        }
    }

    private func consume() {
        if !upgraded {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let header = String(data: buffer.subdata(in: buffer.startIndex..<range.upperBound), encoding: .utf8) ?? ""
            buffer.removeSubrange(..<range.upperBound)
            guard header.contains("101") else {
                fail("upgrade rejected \(header.prefix(80))")
                return
            }
            upgraded = true
            Log.line("plugin: websocket upgraded")
            DispatchQueue.main.async { self.onReady?() }
        }
        while let message = popFrame() {
            DispatchQueue.main.async { self.onMessage?(message) }
        }
    }

    private func popFrame() -> String? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.startIndex + 1]
        let opcode = b0 & 0x0f
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7f)
        var offset = 2
        if len == 126 {
            guard buffer.count >= 4 else { return nil }
            len = (Int(buffer[buffer.startIndex + 2]) << 8) | Int(buffer[buffer.startIndex + 3])
            offset = 4
        } else if len == 127 {
            return nil
        }
        var mask = [UInt8](repeating: 0, count: 4)
        if masked {
            guard buffer.count >= offset + 4 else { return nil }
            for i in 0..<4 {
                mask[i] = buffer[buffer.startIndex + offset + i]
            }
            offset += 4
        }
        guard buffer.count >= offset + len else { return nil }
        var payload = [UInt8](buffer[buffer.startIndex + offset ..< buffer.startIndex + offset + len])
        if masked {
            for i in payload.indices {
                payload[i] ^= mask[i % 4]
            }
        }
        buffer.removeSubrange(..<(buffer.startIndex + offset + len))
        if opcode == 0x8 {
            fail("close")
            return nil
        }
        if opcode == 0x9 {
            let pong = Self.frame(opcode: 0x8a, payload: Data(payload))
            _ = pong.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return Darwin.send(self.fd, base, pong.count, 0)
            }
            return nil
        }
        if opcode == 0x1 || opcode == 0x0 {
            return String(bytes: payload, encoding: .utf8)
        }
        return nil
    }

    private func fail(_ message: String) {
        Log.line("opendeck ws error \(message)")
        closeFd()
        guard !reconnecting else { return }
        reconnecting = true
        DispatchQueue.main.async { self.onFail?(message) }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.reconnecting = false
        }
    }

    private func closeFd() {
        lock.lock()
        let sock = fd
        fd = -1
        lock.unlock()
        if sock >= 0 {
            Darwin.close(sock)
        }
    }

    private static func textFrame(_ payload: Data) -> Data {
        frame(opcode: 0x81, payload: payload)
    }

    private static func frame(opcode: UInt8, payload: Data) -> Data {
        var out = Data([opcode])
        let count = payload.count
        if count < 126 {
            out.append(0x80 | UInt8(count))
        } else {
            out.append(0x80 | 126)
            out.append(UInt8((count >> 8) & 0xff))
            out.append(UInt8(count & 0xff))
        }
        var mask = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &mask)
        out.append(contentsOf: mask)
        out.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return out
    }
}
