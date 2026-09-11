import AppKit
import CoreGraphics
import Foundation

final class MeetingMonitor {
    private(set) var state = CallState()
    var onChange: ((CallState) -> Void)?

    func scan() -> CallState {
        let previous = state
        var next = CallState()
        let apps = AXScanner.meetingApps()
        if apps.isEmpty {
            state = next
            if previous != next { onChange?(next) }
            return next
        }

        let trusted = AXScanner.isTrusted(prompt: false)
        let withWindows = apps.filter { app in
            !app.bundle.lowercased().contains("helper") || AXScanner.hasOnScreenWindow(pid: app.pid)
        }
        for app in withWindows {
            let candidate = inspect(
                kind: app.kind, pid: app.pid, axTrusted: trusted, forceWalk: false)
            if candidate.active {
                next = candidate
                break
            }
            if next.app == nil {
                next.app = candidate.app
                next.pid = candidate.pid
            }
        }
        state = next
        if previous != next { onChange?(next) }
        return next
    }

    func perform(_ action: String) {
        if action == "toggleMute" || action == "leave" {
            Log.line("key \(action) ignored here: Jabra HID handles mute/leave")
            return
        }
        guard let target = Self.resolveTarget() else {
            Log.line("key \(action) ignored: no Teams/Zoom")
            return
        }
        state.app = target.kind
        state.pid = target.pid
        let app = target.kind
        Log.line(
            "key \(action) -> \(app) pid=\(target.pid) postEvent=\(Keystroke.canPostEvents())")
        Self.focus(kind: app, pid: target.pid)
        let work = { [app] in
            switch action {
            case "toggleCamera":
                if app == "zoom" {
                    Keystroke.tap(keyCode: Keystroke.v, flags: [.maskCommand, .maskShift])
                } else {
                    Keystroke.tap(keyCode: Keystroke.o, flags: [.maskCommand, .maskShift])
                }
            case "leave":
                if app == "zoom" {
                    Keystroke.tap(keyCode: Keystroke.w, flags: [.maskCommand])
                } else {
                    Keystroke.tap(keyCode: Keystroke.h, flags: [.maskCommand, .maskShift])
                }
            case "toggleHand":
                if app == "zoom" {
                    Keystroke.tap(keyCode: Keystroke.y, flags: [.maskAlternate])
                } else {
                    Keystroke.tap(keyCode: Keystroke.k, flags: [.maskCommand, .maskShift])
                }
            case "toggleBlur":
                if app != "teams" { return }
                Keystroke.tap(keyCode: Keystroke.p, flags: [.maskCommand, .maskShift])
            case "react.like":
                Self.zoomReact(app: app, key: Keystroke.five)
            case "react.love":
                Self.zoomReact(app: app, key: Keystroke.six)
            case "react.laugh":
                Self.zoomReact(app: app, key: Keystroke.seven)
            case "react.wow":
                Self.zoomReact(app: app, key: Keystroke.eight)
            case "react.applause":
                Self.zoomReact(app: app, key: Keystroke.four)
            default:
                break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    /// Mute whoever is actually using the Jabra, not whichever OpenDeck profile is showing.
    @discardableResult
    func muteActiveCall() -> Bool {
        guard let target = Self.activeCallTarget() else {
            Log.line("key toggleMute ignored: no app using Jabra")
            return false
        }
        state.app = target.kind
        state.pid = target.pid
        Log.line("key toggleMute -> \(target.kind) pid=\(target.pid) \(target.bundle)")
        Self.focus(kind: target.kind, pid: target.pid)
        let kind = target.kind
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            switch kind {
            case "zoom":
                Keystroke.tap(keyCode: Keystroke.a, flags: [.maskCommand, .maskShift])
            case "teams":
                Keystroke.tap(keyCode: Keystroke.m, flags: [.maskCommand, .maskShift])
            default:
                Keystroke.tap(keyCode: Keystroke.d, flags: [.maskCommand])
            }
        }
        return true
    }

    static func activeCallTarget() -> (kind: String, pid: pid_t, bundle: String)? {
        if let client = JabraMonitor.inputClient() {
            return (kind(bundle: client.bundle), client.pid, client.bundle)
        }
        if let chrome = chromeMeet() {
            return ("meet", chrome.pid, chrome.bundle)
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier
        {
            let k = kind(bundle: bid)
            if k == "zoom" || k == "teams" || isBrowser(bid) {
                return (k == "zoom" || k == "teams" ? k : "meet", front.processIdentifier, bid)
            }
        }
        return nil
    }

    private static func isBrowser(_ bundle: String) -> Bool {
        let b = bundle.lowercased()
        return b.contains("chrome") || b.contains("brave") || b.contains("edgemac")
            || b.contains("safari") || b.contains("thebrowser")
    }

    private static func kind(bundle: String) -> String {
        let b = bundle.lowercased()
        if b.contains("zoom") { return "zoom" }
        if b.contains("teams") { return "teams" }
        return "meet"
    }

    private static func chromeMeet() -> (pid: pid_t, bundle: String)? {
        let browsers: Set<String> = [
            "com.google.chrome",
            "com.google.chrome.beta",
            "com.google.chrome.canary",
            "com.brave.browser",
            "com.microsoft.edgemac",
            "company.thebrowser.browser",
            "com.apple.safari",
        ]
        let apps = NSWorkspace.shared.runningApplications
        let titles = AXScanner.cgWindowTitles(ownerNames: [
            "google chrome", "brave browser", "microsoft edge", "arc", "safari",
        ])
        let inMeet = titles.contains { $0.localizedCaseInsensitiveContains("meet") }
        guard inMeet else { return nil }
        if let app = apps.first(where: { browsers.contains($0.bundleIdentifier?.lowercased() ?? "") }) {
            return (app.processIdentifier, app.bundleIdentifier ?? "chrome")
        }
        return nil
    }

    static func resolveTarget() -> (kind: String, pid: pid_t)? {
        let apps = AXScanner.meetingApps()
        guard !apps.isEmpty else { return nil }
        let profile = ProfileSwitcher.currentProfile().lowercased()
        let wantZoom = profile.contains("zoom")
        if wantZoom, let zoom = apps.first(where: { $0.kind == "zoom" }) {
            return (zoom.kind, zoom.pid)
        }
        let teams = apps.filter { $0.kind == "teams" }
        if !teams.isEmpty {
            if let web = Self.bestTeamsPid(teams) {
                return ("teams", web)
            }
            return ("teams", teams[0].pid)
        }
        if let zoom = apps.first(where: { $0.kind == "zoom" }) {
            return (zoom.kind, zoom.pid)
        }
        return nil
    }

    private static func bestTeamsPid(_ apps: [(kind: String, pid: pid_t, bundle: String)]) -> pid_t? {
        let helpers = Set(apps.filter { $0.bundle.lowercased().contains("helper") }.map(\.pid))
        if let pid = AXScanner.largestWindowPid(among: helpers) { return pid }
        let all = Set(apps.map(\.pid))
        return AXScanner.largestWindowPid(among: all) ?? apps.first { !$0.bundle.lowercased().contains("helper") }?.pid
    }

    private static func focus(kind: String, pid: pid_t) {
        let bid: String
        switch kind {
        case "zoom": bid = "us.zoom.xos"
        case "meet": bid = "com.google.Chrome"
        default: bid = "com.microsoft.teams2"
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }) {
            let ok = app.activate()
            Log.line("focus \(kind) \(bid) activate=\(ok)")
        }
        if let running = NSRunningApplication(processIdentifier: pid) {
            _ = running.activate()
        }
        AXScanner.raise(pid: pid)
    }

    private static func zoomReact(app: String, key: CGKeyCode) {
        if app == "zoom" {
            Keystroke.tap(keyCode: key, flags: [.maskCommand, .maskAlternate])
        } else {
            Log.line("key react ignored: Teams has no meeting-reaction shortcut")
        }
    }

    private func inspect(kind: String, pid: pid_t, axTrusted: Bool, forceWalk: Bool) -> CallState {
        var state = CallState()
        state.app = kind
        state.pid = pid
        var titles = AXScanner.windowTitles(pid: pid)
        if titles.isEmpty {
            let owners = kind == "zoom" ? ["zoom"] : ["microsoft teams", "teams"]
            titles = AXScanner.cgWindowTitles(ownerNames: owners)
        }
        let extraWindow = titles.contains { !isChromeTitle($0, kind: kind) }
        let twoWindows = kind == "teams" && AXScanner.axWindows(pid: pid).count >= 2
        var buttons: [AXButton] = []
        if axTrusted && (kind == "teams" || extraWindow || twoWindows || forceWalk) {
            // Walk every window, including Chat/Calendar, so End/Leave still counts
            // when the meeting is in the main Teams window.
            buttons = AXScanner.buttons(pid: pid)
        }
        let classified = classify(buttons)
        // Chat/calendar is one chrome window. A meeting is a second window,
        // a non-chrome title (the event name), or Leave/End on the meeting UI.
        state.active = extraWindow || twoWindows || classified.hasLeave
        if state.active || forceWalk {
            state.muted = classified.muted
            state.cameraOn = classified.cameraOn
            state.handUp = classified.handUp
            state.blurred = classified.blurred
        }
        return state
    }

    private func isChromeTitle(_ title: String, kind: String) -> Bool {
        let t = title.lowercased()
        if kind == "zoom" {
            return t == "zoom" || t.contains("zoom workplace") || t.contains("settings")
        }
        if t == "microsoft teams" || t == "teams" || t.hasPrefix("microsoft teams webview") {
            return true
        }
        let chrome = ["calendar |", "activity |", "chat |", "communities |", "calls |", "files |", "apps |"]
        return chrome.contains(where: { t.hasPrefix($0) })
    }

    private func classify(_ buttons: [AXButton]) -> (
        muted: Bool?, cameraOn: Bool?, handUp: Bool?, blurred: Bool?, hasLeave: Bool
    ) {
        var muted: Bool?
        var cameraOn: Bool?
        var handUp: Bool?
        var blurred: Bool?
        var hasLeave = false
        for button in buttons {
            let t = button.title.lowercased()
            if isEndOrLeave(t) {
                hasLeave = true
            }
            if t.contains("unmute") { muted = true }
            else if t.contains("mute") && !t.contains("unmute") { muted = false }
            if t.contains("start video") || t.contains("turn camera on") || t.contains("camera off") {
                cameraOn = false
            } else if t.contains("stop video") || t.contains("turn camera off") || t.contains("camera on") {
                cameraOn = true
            }
            if t.contains("lower hand") { handUp = true }
            else if t.contains("raise hand") { handUp = false }
            if t.contains("blur") {
                if t.contains("off") || t.contains("none") { blurred = true }
                else if t.contains("on") { blurred = false }
            }
        }
        return (muted, cameraOn, handUp, blurred, hasLeave)
    }

    private func isEndOrLeave(_ title: String) -> Bool {
        if title == "end" || title == "leave" || title.hasPrefix("end ") || title.hasPrefix("leave ") {
            return true
        }
        return title.contains("leave")
            || title.contains("end meeting")
            || title.contains("end call")
            || title.contains("end for everyone")
            || title.contains("hang up")
    }
}
