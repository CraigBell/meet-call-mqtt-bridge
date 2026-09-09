import Darwin
import Foundation

/// Minimal MQTT 3.1.1 publisher (QoS 0, retain) over a BSD TCP socket.
final class MQTTPublisher {
    private let host: String
    private let port: UInt16
    private let user: String
    private let pass: String
    private let topic: String
    private let clientId: String
    private var fd: Int32 = -1
    private var lastPayload: String?
    private let queue = DispatchQueue(label: "at.craig.call-bridge.mqtt")
    private var pingTimer: DispatchSourceTimer?

    init(host: String, port: UInt16, user: String, pass: String, topic: String, clientId: String) {
        self.host = host
        self.port = port
        self.user = user
        self.pass = pass
        self.topic = topic
        self.clientId = clientId
    }

    func start() {
        queue.async { [weak self] in self?.connect() }
    }

    func publish(_ payload: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastPayload = payload
            self.writePacket(self.publishPacket(payload))
        }
    }

    private func connect() {
        closeFD()
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
            ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let err = host.withCString { h in
            portStr.withCString { p in
                getaddrinfo(h, p, &hints, &result)
            }
        }
        defer { if let result { freeaddrinfo(result) } }
        guard err == 0, let info = result else {
            Log.line("mqtt resolve failed \(err)")
            scheduleReconnect()
            return
        }
        let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard sock >= 0 else {
            Log.line("mqtt socket failed")
            scheduleReconnect()
            return
        }
        var on: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let cErr = Darwin.connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if cErr != 0 {
            Log.line("mqtt connect failed errno=\(errno)")
            Darwin.close(sock)
            scheduleReconnect()
            return
        }
        fd = sock
        Log.line("mqtt connected \(host):\(port)")
        writePacket(connectPacket())
        if let last = lastPayload {
            writePacket(publishPacket(last))
        }
        startPing()
        queue.async { [weak self] in self?.readLoop() }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 256)
        while fd >= 0 {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n <= 0 {
                Log.line("mqtt disconnected")
                scheduleReconnect()
                return
            }
        }
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.writePacket(Data([0xC0, 0x00]))
        }
        timer.resume()
        pingTimer = timer
    }

    private func scheduleReconnect() {
        pingTimer?.cancel()
        pingTimer = nil
        closeFD()
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.connect()
        }
    }

    private func closeFD() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func writePacket(_ data: Data) {
        guard fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = Darwin.send(fd, base, data.count, 0)
        }
    }

    private func connectPacket() -> Data {
        var payload = Data()
        payload.append(mqttString("MQTT"))
        payload.append(4)
        var flags: UInt8 = 0x02
        if !user.isEmpty { flags |= 0x80 }
        if !pass.isEmpty { flags |= 0x40 }
        payload.append(flags)
        payload.append(contentsOf: [0x00, 0x3C])
        payload.append(mqttString(clientId))
        if !user.isEmpty { payload.append(mqttString(user)) }
        if !pass.isEmpty { payload.append(mqttString(pass)) }
        var packet = Data([0x10])
        packet.append(remainingLength(payload.count))
        packet.append(payload)
        return packet
    }

    private func publishPacket(_ payload: String) -> Data {
        var body = mqttString(topic)
        body.append(contentsOf: Array(payload.utf8))
        var packet = Data([0x31])
        packet.append(remainingLength(body.count))
        packet.append(body)
        return packet
    }

    private func mqttString(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        var data = Data([UInt8(bytes.count / 256), UInt8(bytes.count % 256)])
        data.append(contentsOf: bytes)
        return data
    }

    private func remainingLength(_ length: Int) -> Data {
        var x = length
        var out = Data()
        repeat {
            var encoded = UInt8(x % 128)
            x /= 128
            if x > 0 { encoded |= 0x80 }
            out.append(encoded)
        } while x > 0
        return out
    }
}
