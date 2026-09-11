import CoreGraphics
import Foundation

enum Keystroke {
    static let command = CGEventFlags.maskCommand
    static let shift = CGEventFlags.maskShift
    static let option = CGEventFlags.maskAlternate
    static let control = CGEventFlags.maskControl

    static let commandKey: CGKeyCode = 55
    static let shiftKey: CGKeyCode = 56
    static let optionKey: CGKeyCode = 58
    static let controlKey: CGKeyCode = 59

    static func send(pid: pid_t, keyCode: CGKeyCode, flags: CGEventFlags) {
        tap(keyCode: keyCode, flags: flags, pid: pid)
    }

    /// Hardware-style chord via System Events. LaunchAgents often cannot use
    /// cghidEventTap even when Accessibility is granted; Teams WebView also
    /// ignores postToPid.
    static func tap(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t? = nil) {
        if tapViaSystemEvents(keyCode: keyCode, flags: flags) { return }
        Log.line("keystroke System Events failed; trying CGEvent")
        tapViaCGEvent(keyCode: keyCode, flags: flags, pid: pid)
    }

    private static func tapViaSystemEvents(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        var mods: [String] = []
        if flags.contains(.maskCommand) { mods.append("command down") }
        if flags.contains(.maskShift) { mods.append("shift down") }
        if flags.contains(.maskAlternate) { mods.append("option down") }
        if flags.contains(.maskControl) { mods.append("control down") }
        let using = mods.isEmpty ? "" : " using {\(mods.joined(separator: ", "))}"
        let source = "tell application \"System Events\" to key code \(keyCode)\(using)"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            Log.line("keystroke applescript \(error)")
            return false
        }
        return true
    }

    private static func tapViaCGEvent(keyCode: CGKeyCode, flags: CGEventFlags, pid: pid_t?) {
        let src = CGEventSource(stateID: .hidSystemState)
        let mods: [(CGEventFlags, CGKeyCode)] = [
            (.maskCommand, commandKey),
            (.maskShift, shiftKey),
            (.maskAlternate, optionKey),
            (.maskControl, controlKey),
        ]
        let held = mods.filter { flags.contains($0.0) }
        var downFlags: CGEventFlags = []
        for (flag, mod) in held {
            downFlags.insert(flag)
            post(src: src, key: mod, down: true, flags: downFlags, pid: pid)
        }
        post(src: src, key: keyCode, down: true, flags: flags, pid: pid)
        post(src: src, key: keyCode, down: false, flags: flags, pid: pid)
        for (flag, mod) in held.reversed() {
            downFlags.remove(flag)
            post(src: src, key: mod, down: false, flags: downFlags, pid: pid)
        }
    }

    static func canPostEvents() -> Bool {
        CGPreflightPostEventAccess()
    }

    static func requestPostEvents() -> Bool {
        if CGPreflightPostEventAccess() { return true }
        return CGRequestPostEventAccess()
    }

    private static func post(
        src: CGEventSource?, key: CGKeyCode, down: Bool, flags: CGEventFlags, pid: pid_t?
    ) {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
        ev.flags = flags
        if let pid {
            ev.postToPid(pid)
        }
        ev.post(tap: .cghidEventTap)
    }

    // ANSI key codes
    static let a: CGKeyCode = 0
    static let h: CGKeyCode = 4
    static let k: CGKeyCode = 40
    static let m: CGKeyCode = 46
    static let o: CGKeyCode = 31
    static let p: CGKeyCode = 35
    static let v: CGKeyCode = 9
    static let w: CGKeyCode = 13
    static let y: CGKeyCode = 16
    static let d: CGKeyCode = 2
    static let four: CGKeyCode = 21
    static let five: CGKeyCode = 23
    static let six: CGKeyCode = 22
    static let seven: CGKeyCode = 26
    static let eight: CGKeyCode = 28
}
