import Darwin
import Foundation

final class OpenDeckPlugin {
    private let port: Int
    private let uuid: String
    private let registerEvent: String
    private var task: URLSessionWebSocketTask?
    private var contexts: [String: Set<String>] = [:]
    private let session = URLSession(configuration: .default)
    private var socket: Int32 = -1
    private var mqtt: MQTTPublisher?
    private var lastActive: Bool?

    init(port: Int, uuid: String, registerEvent: String) {
        self.port = port
        self.uuid = uuid
        self.registerEvent = registerEvent
    }

    func run() {
        connectDaemon()
        let cfg = BridgeConfig.load()
        if let hp = cfg.mqttHostPort {
            let client = MQTTPublisher(
                host: hp.0, port: hp.1, user: cfg.mqttUser, pass: cfg.mqttPass, topic: cfg.mqttTopic,
                clientId: "call-bridge-plugin-\(getpid())")
            mqtt = client
            client.start()
        }
        connectOpenDeck()
        RunLoop.main.run()
    }

    private func connectOpenDeck() {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        send(["event": registerEvent, "uuid": uuid])
        receiveLoop()
    }

    private func connectDaemon() {
        socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Paths.socket
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            guard let base = buf.baseAddress else { return }
            path.withCString { cstr in
                let n = min(strlen(cstr), buf.count - 1)
                memcpy(base, cstr, n)
            }
        }
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(self.socket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok != 0 {
            Darwin.close(socket)
            socket = -1
            Log.line("plugin: daemon socket missing at \(path); retrying")
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.connectDaemon()
            }
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.daemonReadLoop()
        }
    }

    private func daemonReadLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while socket >= 0 {
            let n = Darwin.recv(socket, &chunk, chunk.count, 0)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let range = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: buffer.startIndex..<range)
                buffer.removeSubrange(...range)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    DispatchQueue.main.async { self.applyState(obj) }
                }
            }
        }
        Darwin.close(socket)
        socket = -1
        Log.line("plugin: daemon socket closed; retrying")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.connectDaemon()
        }
    }

    private func sendCommand(_ action: String) {
        let line = "{\"action\":\"\(action)\"}\n"
        let data = Data(line.utf8)
        data.withUnsafeBytes { raw in
            if let base = raw.bindMemory(to: UInt8.self).baseAddress {
                _ = Darwin.send(socket, base, data.count, 0)
            }
        }
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            switch result {
            case .failure(let err):
                Log.line("opendeck ws error \(err)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.connectOpenDeck()
                }
            case .success(let message):
                if case .string(let text) = message {
                    self?.handleDeck(text)
                }
                self?.receiveLoop()
            }
        }
    }

    private func handleDeck(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        let type = event["event"] as? String ?? ""
        let action = event["action"] as? String ?? ""
        let context = event["context"] as? String ?? ""
        if type == "willAppear", !action.isEmpty, !context.isEmpty {
            var set = contexts[action] ?? []
            set.insert(context)
            contexts[action] = set
        } else if type == "willDisappear" {
            contexts[action]?.remove(context)
        } else if type == "keyUp" {
            if let cmd = Self.actionToCommand[action] {
                sendCommand(cmd)
            }
        }
    }

    private func applyState(_ obj: [String: Any]) {
        let active = obj["active"] as? Bool ?? false
        if active != lastActive {
            if active {
                mqtt?.publish("true")
            } else if lastActive == true {
                mqtt?.publish("false")
            }
            lastActive = active
        }
        let muted = obj["muted"] as? Bool
        let cameraOn = obj["cameraOn"] as? Bool
        let handUp = obj["handUp"] as? Bool
        let blurred = obj["blurred"] as? Bool
        setStates(action: "com.craigbell.callbridge.togglemute", state: toggleState(active: active, on: muted.map { !$0 }, idle: 2))
        setStates(action: "com.craigbell.callbridge.togglecamera", state: toggleState(active: active, on: cameraOn, idle: 2))
        setStates(action: "com.craigbell.callbridge.togglehand", state: toggleState(active: active, on: handUp, idle: 1))
        setStates(action: "com.craigbell.callbridge.toggleblur", state: toggleState(active: active, on: blurred, idle: 1))
        setStates(action: "com.craigbell.callbridge.leave", state: 1)
        for react in ["like", "love", "laugh", "wow", "applause"] {
            setStates(action: "com.craigbell.callbridge.react.\(react)", state: 1)
        }
    }

    private func toggleState(active: Bool, on: Bool?, idle: Int) -> Int {
        if !active { return idle }
        if let on { return on ? 2 : 1 }
        return 1
    }

    private func setStates(action: String, state: Int) {
        for context in contexts[action] ?? [] {
            send([
                "event": "setState",
                "context": context,
                "payload": ["state": state],
            ])
        }
    }

    private func send(_ obj: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { _ in }
    }

    private static let actionToCommand: [String: String] = [
        "com.craigbell.callbridge.togglemute": "toggleMute",
        "com.craigbell.callbridge.togglecamera": "toggleCamera",
        "com.craigbell.callbridge.leave": "leave",
        "com.craigbell.callbridge.togglehand": "toggleHand",
        "com.craigbell.callbridge.toggleblur": "toggleBlur",
        "com.craigbell.callbridge.react.like": "react.like",
        "com.craigbell.callbridge.react.love": "react.love",
        "com.craigbell.callbridge.react.laugh": "react.laugh",
        "com.craigbell.callbridge.react.wow": "react.wow",
        "com.craigbell.callbridge.react.applause": "react.applause",
    ]
}
