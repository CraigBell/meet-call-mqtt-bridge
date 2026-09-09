import Darwin
import Foundation

final class ControlServer {
    private var listenFD: Int32 = -1
    private var clients: [Int32] = []
    private let lock = NSLock()
    var onCommand: ((String) -> Void)?
    var stateProvider: (() -> CallState)?

    func start(path: String) {
        unlink(path)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            Log.line("socket create failed")
            return
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            guard let base = buf.baseAddress else { return }
            path.withCString { cstr in
                let n = min(strlen(cstr), buf.count - 1)
                memcpy(base, cstr, n)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindOk = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFD, sockPtr, len)
            }
        }
        guard bindOk == 0, listen(listenFD, 8) == 0 else {
            Log.line("socket bind/listen failed")
            return
        }
        chmod(path, 0o600)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
        Log.line("control socket \(path)")
    }

    func broadcast(_ state: CallState) {
        let data = Data(state.jsonLine().utf8)
        lock.lock()
        let fds = clients
        lock.unlock()
        for fd in fds {
            data.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                    _ = Darwin.send(fd, base, data.count, 0)
                }
            }
        }
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            lock.lock()
            clients.append(fd)
            lock.unlock()
            if let state = stateProvider?() {
                let data = Data(state.jsonLine().utf8)
                data.withUnsafeBytes { raw in
                    if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                        _ = Darwin.send(fd, base, data.count, 0)
                    }
                }
            }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.readLoop(fd)
            }
        }
    }

    private func readLoop(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let range = buffer.firstIndex(of: 10) { // newline
                let line = buffer.subdata(in: buffer.startIndex..<range)
                buffer.removeSubrange(...range)
                handle(line: String(data: line, encoding: .utf8) ?? "")
            }
        }
        Darwin.close(fd)
        lock.lock()
        clients.removeAll { $0 == fd }
        lock.unlock()
    }

    private func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let action = obj["action"] as? String {
            DispatchQueue.main.async { self.onCommand?(action) }
        }
    }
}
