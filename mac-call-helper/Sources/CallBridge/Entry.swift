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
        case "hid-dump":
            JabraHID.runOnce { $0.printDump() }
        case "hid-mute":
            JabraHID.runOnce { hid in
                let next = hid.toggleMute(currentlyMuted: nil, inCall: JabraMonitor().snapshot().contains { $0.running })
                print("hid-mute \(next.map { $0 ? "muted" : "unmuted" } ?? "failed")")
            }
        case "hid-hangup":
            JabraHID.runOnce { hid in
                let ok = hid.hangUp(inCall: JabraMonitor().snapshot().contains { $0.running })
                print("hid-hangup \(ok ? "ok" : "failed")")
            }
        case "mute-toggle":
            _ = JabraMonitor.toggleMute()
        case "volume-up":
            _ = JabraMonitor.adjustVolume(0.10)
        case "volume-down":
            _ = JabraMonitor.adjustVolume(-0.10)
        default:
            FileHandle.standardError.write(
                Data("usage: call-bridge daemon|plugin|doctor|dump|hid-dump|hid-mute|hid-hangup|mute-toggle|volume-up|volume-down\n".utf8))
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
        print("ax trusted: \(AXScanner.isTrusted(prompt: false))")
        print("post-event: \(Keystroke.canPostEvents())")
        fflush(stdout)
        print("mqtt url set: \(!cfg.mqttURL.isEmpty) topic: \(cfg.mqttTopic)")
        print("socket: \(Paths.socket) exists=\(FileManager.default.fileExists(atPath: Paths.socket))")
        let jabra = JabraMonitor().snapshot()
        if jabra.isEmpty {
            print("jabra: no Core Audio device named Jabra")
        } else {
            for dev in jabra {
                print("jabra id=\(dev.id) name=\(dev.name) running=\(dev.running)")
            }
        }
        print("jabra inCall=\(jabra.contains { $0.running })")
        if let client = JabraMonitor.inputClient() {
            print("jabra inputClient=\(client.name) pid=\(client.pid) \(client.bundle)")
        } else {
            print("jabra inputClient=none")
        }
        if let target = MeetingMonitor.activeCallTarget() {
            print("mute target=\(target.kind) pid=\(target.pid)")
        } else {
            print("mute target=none")
        }
        if let target = MeetingMonitor.resolveTarget() {
            print("opendeck profile=\(ProfileSwitcher.currentProfile()) keys -> \(target.kind) pid=\(target.pid)")
        } else {
            print("opendeck profile=\(ProfileSwitcher.currentProfile()) keys -> no Teams/Zoom")
        }
    }

    static func dump() {
        doctor()
    }
}
