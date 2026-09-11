import AppKit
import Foundation

final class Daemon {
    private let config = BridgeConfig.load()
    private let monitor = MeetingMonitor()
    private let jabra = JabraMonitor()
    private let hid = JabraHID()
    private let server = ControlServer()
    private var mqtt: MQTTPublisher?
    private var callMuted: Bool?

    func run() {
        _ = AXScanner.isTrusted(prompt: true)
        if !Keystroke.requestPostEvents() {
            Log.line("post-event/input monitoring not granted; Teams/Zoom keys may do nothing")
        }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        if let hp = config.mqttHostPort {
            let client = MQTTPublisher(
                host: hp.0, port: hp.1, user: config.mqttUser, pass: config.mqttPass,
                topic: config.mqttTopic, clientId: "call-bridge-daemon")
            mqtt = client
            client.start()
            client.publish("false")
            Log.line("mqtt topic \(config.mqttTopic)")
        } else {
            Log.line("mqtt disabled (no MQTT_URL)")
        }
        server.stateProvider = { [weak self] in self?.deckState() ?? CallState() }
        server.onCommand = { [weak self] action in
            self?.handleCommand(action)
        }
        server.start(path: Paths.socket)
        jabra.onChange = { [weak self] inCall in
            self?.handleJabra(inCall)
        }
        hid.onMutePress = { [weak self] in
            self?.flipCallMute(reason: "jabra-button")
        }
        jabra.start()
        hid.start()
        Log.line("daemon running (jabra HID mute/hangup, no AX poll)")
        RunLoop.main.run()
    }

    private func handleCommand(_ action: String) {
        switch action {
        case "toggleMute":
            if let next = hid.toggleMute(currentlyMuted: callMuted, inCall: jabra.inCall) {
                setCallMuted(next, reason: "opendeck")
            }
        case "leave":
            _ = hid.hangUp(inCall: jabra.inCall)
        case "volumeUp":
            JabraMonitor.adjustVolume(0.10)
        case "volumeDown":
            JabraMonitor.adjustVolume(-0.10)
        default:
            monitor.perform(action)
        }
    }

    private func flipCallMute(reason: String) {
        setCallMuted(!(callMuted ?? false), reason: reason)
    }

    private func setCallMuted(_ muted: Bool, reason: String) {
        callMuted = muted
        Log.line("call muted=\(muted) source=\(reason)")
        server.broadcast(deckState())
    }

    private func handleJabra(_ inCall: Bool) {
        if !inCall {
            callMuted = nil
        } else if callMuted == nil {
            callMuted = false
        }
        mqtt?.publish(inCall ? "true" : "false")
        server.broadcast(deckState())
        Log.line("state active=\(inCall) source=jabra")
    }

    private func deckState() -> CallState {
        var state = CallState()
        state.active = jabra.inCall
        state.muted = callMuted
        if let target = MeetingMonitor.activeCallTarget() {
            state.app = target.kind
            state.pid = target.pid
        }
        return state
    }
}
