import AppKit
import Foundation

final class Daemon {
    private let config = BridgeConfig.load()
    private let monitor = MeetingMonitor()
    private let server = ControlServer()
    private var mqtt: MQTTPublisher?
    private var publishedByUs = false
    private var lastProfile: String?

    func run() {
        _ = AXScanner.isTrusted(prompt: true)
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let hp = config.mqttHostPort {
            let client = MQTTPublisher(
                host: hp.0, port: hp.1, user: config.mqttUser, pass: config.mqttPass,
                topic: config.mqttTopic, clientId: "call-bridge-daemon")
            mqtt = client
            client.start()
            Log.line("mqtt topic \(config.mqttTopic)")
        } else {
            Log.line("mqtt disabled (no MQTT_URL)")
        }
        server.stateProvider = { [weak self] in self?.monitor.state ?? CallState() }
        server.onCommand = { [weak self] action in
            self?.monitor.perform(action)
        }
        server.start(path: Paths.socket)
        monitor.onChange = { [weak self] state in
            self?.handle(state)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.tick() }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tick()
        Log.line("daemon running")
        RunLoop.main.run()
    }

    private func tick() {
        if AXScanner.meetingApps().isEmpty && !monitor.state.active {
            // Stay cheap when neither app is open.
            return
        }
        _ = monitor.scan()
    }

    private func handle(_ state: CallState) {
        server.broadcast(state)
        if state.active {
            mqtt?.publish("true")
            publishedByUs = true
            if config.switchProfiles {
                let wanted = state.app == "zoom" ? config.zoomProfile : config.teamsProfile
                if lastProfile != wanted {
                    ProfileSwitcher.switchTo(wanted)
                    lastProfile = wanted
                }
            }
        } else if publishedByUs {
            mqtt?.publish("false")
            publishedByUs = false
            if config.switchProfiles, lastProfile != nil {
                ProfileSwitcher.switchTo(config.defaultProfile)
                lastProfile = nil
            }
        }
        Log.line(
            "state active=\(state.active) app=\(state.app ?? "-") pid=\(state.pid ?? 0) muted=\(String(describing: state.muted)) camera=\(String(describing: state.cameraOn))"
        )
    }
}
