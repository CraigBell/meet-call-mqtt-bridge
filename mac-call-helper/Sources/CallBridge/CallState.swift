import Foundation

struct CallState: Equatable {
    var active = false
    var app: String?
    var pid: pid_t?
    var muted: Bool?
    var cameraOn: Bool?
    var handUp: Bool?
    var blurred: Bool?

    func jsonObject() -> [String: Any] {
        var obj: [String: Any] = ["active": active]
        if let app { obj["app"] = app }
        if let pid { obj["pid"] = pid }
        if let muted { obj["muted"] = muted }
        if let cameraOn { obj["cameraOn"] = cameraOn }
        if let handUp { obj["handUp"] = handUp }
        if let blurred { obj["blurred"] = blurred }
        return obj
    }

    func jsonLine() -> String {
        let data = try! JSONSerialization.data(withJSONObject: jsonObject())
        return String(data: data, encoding: .utf8)! + "\n"
    }
}
