import Foundation

enum ProfileSwitcher {
    static func currentProfile() -> String {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/opendeck/profiles")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        else { return "Default" }
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["selected_profile"] as? String
            else { continue }
            return name
        }
        return "Default"
    }

    static func switchTo(_ name: String) {
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "System Events"
          if not (exists process "OpenDeck") then return
          tell process "OpenDeck"
            try
              click menu item "\(escaped)" of menu "Profiles" of menu bar 1
            end try
          end tell
        end tell
        """
        var error: NSDictionary?
        if let apple = NSAppleScript(source: script) {
            apple.executeAndReturnError(&error)
            if let error {
                Log.line("profile switch error \(error)")
            } else {
                Log.line("opendeck profile \(name)")
            }
        }
    }
}
