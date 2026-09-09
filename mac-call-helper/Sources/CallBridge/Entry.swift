import Darwin
import Foundation

@main
enum CallBridgeMain {
    private static let daemon = Daemon()

    static func main() {
        let args = Array(ProcessInfo.processInfo.arguments.dropFirst())
        if args.contains("-port") || args.contains("--port") || args.first == "plugin" {
            runPlugin(args)
            return
        }
        let cmd = args.first ?? "daemon"
        switch cmd {
        case "daemon":
            daemon.run()
        case "doctor":
            doctor()
        case "dump":
            dump()
        default:
            FileHandle.standardError.write(
                Data("usage: call-bridge daemon|plugin|doctor|dump\n".utf8))
            exit(1)
        }
    }

    static func runPlugin(_ args: [String]) {
        var port: Int?
        var uuid: String?
        var event: String?
        var i = 0
        let list = args.first == "plugin" ? Array(args.dropFirst()) : args
        while i < list.count {
            let a = list[i]
            if a == "-port" || a == "--port", i + 1 < list.count {
                port = Int(list[i + 1]); i += 2; continue
            }
            if a == "-pluginUUID" || a == "--pluginUUID", i + 1 < list.count {
                uuid = list[i + 1]; i += 2; continue
            }
            if a == "-registerEvent" || a == "--registerEvent", i + 1 < list.count {
                event = list[i + 1]; i += 2; continue
            }
            i += 1
        }
        guard let port, let uuid, let event else {
            Log.line("plugin args missing port/uuid/registerEvent")
            exit(1)
        }
        OpenDeckPlugin(port: port, uuid: uuid, registerEvent: event).run()
    }

    static func doctor() {
        let cfg = BridgeConfig.load()
        print("ax trusted: \(AXScanner.isTrusted(prompt: true))")
        fflush(stdout)
        print("mqtt url set: \(!cfg.mqttURL.isEmpty) topic: \(cfg.mqttTopic)")
        print("socket: \(Paths.socket) exists=\(FileManager.default.fileExists(atPath: Paths.socket))")
        let apps = AXScanner.meetingApps()
        if apps.isEmpty {
            print("teams/zoom: not running")
        } else {
            for app in apps {
                print("\(app.kind) pid=\(app.pid) bundle=\(app.bundle)")
                print(AXScanner.dump(pid: app.pid))
            }
        }
        let state = MeetingMonitor().scan()
        print("scan active=\(state.active) app=\(state.app ?? "-") muted=\(String(describing: state.muted))")
    }

    static func dump() {
        doctor()
    }
}
