import Foundation

struct BridgeConfig {
    var mqttURL: String = ""
    var mqttUser: String = ""
    var mqttPass: String = ""
    var mqttTopic: String = "jabra/call_active"
    var switchProfiles: Bool = true
    var defaultProfile: String = "Default"
    var teamsProfile: String = "Teams"
    var zoomProfile: String = "Zoom"

    static func load() -> BridgeConfig {
        var cfg = BridgeConfig()
        let urls: [URL] = [
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/opendeck/plugins/com.chrisregado.googlemeet.sdPlugin/meet-mqtt.json"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".config/meet-call-mqtt-bridge.json"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/call-bridge/config.json"),
        ]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let v = obj["MQTT_URL"] as? String, !v.isEmpty { cfg.mqttURL = v }
            if let v = obj["MQTT_USER"] as? String { cfg.mqttUser = v }
            if let v = obj["MQTT_PASS"] as? String { cfg.mqttPass = v }
            if let v = obj["MEET_MQTT_TOPIC"] as? String, !v.isEmpty { cfg.mqttTopic = v }
            if let v = obj["MQTT_TOPIC"] as? String, !v.isEmpty { cfg.mqttTopic = v }
            if let v = obj["SWITCH_PROFILES"] as? Bool { cfg.switchProfiles = v }
            break
        }
        if let env = ProcessInfo.processInfo.environment["MQTT_URL"], !env.isEmpty {
            cfg.mqttURL = env
        }
        if let env = ProcessInfo.processInfo.environment["MQTT_USER"] {
            cfg.mqttUser = env
        }
        if let env = ProcessInfo.processInfo.environment["MQTT_PASS"] {
            cfg.mqttPass = env
        }
        if let env = ProcessInfo.processInfo.environment["MEET_MQTT_TOPIC"], !env.isEmpty {
            cfg.mqttTopic = env
        }
        return cfg
    }

    var mqttHostPort: (String, UInt16)? {
        guard !mqttURL.isEmpty else { return nil }
        var raw = mqttURL
        if let range = raw.range(of: "://") {
            raw = String(raw[range.upperBound...])
        }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let host = parts.first ?? ""
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 1883 : 1883
        guard !host.isEmpty else { return nil }
        return (host, port)
    }
}

enum Paths {
    static var support: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/call-bridge")
    }

    static var socket: String {
        support.appendingPathComponent("call-bridge.sock").path
    }

    static var log: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/call-bridge.log")
    }
}
