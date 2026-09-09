import Foundation

enum ProfileSwitcher {
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
