import CoreGraphics
import Foundation

final class MeetingMonitor {
    private(set) var state = CallState()
    var onChange: ((CallState) -> Void)?
    private var missCount = 0
    private let dropAfterMisses = 5

    func scan() -> CallState {
        let previous = state
        var next = CallState()
        let apps = AXScanner.meetingApps()
        if apps.isEmpty {
            missCount = 0
            state = next
            if previous != next { onChange?(next) }
            return next
        }

        let trusted = AXScanner.isTrusted(prompt: false)
        let withWindows = apps.filter { app in
            !app.bundle.lowercased().contains("helper") || AXScanner.hasOnScreenWindow(pid: app.pid)
        }
        let preferHelpers = previous.active
        let ordered = preferHelpers
            ? withWindows.sorted { lhs, rhs in
                let lHelper = lhs.bundle.lowercased().contains("helper")
                let rHelper = rhs.bundle.lowercased().contains("helper")
                if lHelper != rHelper { return lHelper }
                return lhs.pid < rhs.pid
            }
            : withWindows
        for app in ordered {
            let candidate = inspect(
                kind: app.kind, pid: app.pid, axTrusted: trusted,
                forceWalk: previous.active && app.bundle.lowercased().contains("helper"))
            if candidate.active {
                next = candidate
                break
            }
            if next.app == nil {
                next.app = candidate.app
                next.pid = candidate.pid
            }
        }
        if next.active {
            missCount = 0
        } else if previous.active {
            missCount += 1
            if missCount < dropAfterMisses {
                next = previous
                next.active = true
            } else {
                missCount = 0
            }
        } else {
            missCount = 0
        }
        state = next
        if previous != next { onChange?(next) }
        return next
    }

    func perform(_ action: String) {
        _ = scan()
        guard let pid = state.pid, state.active else { return }
        let app = state.app ?? "teams"
        switch action {
        case "toggleMute":
            if !AXScanner.press(matching: ["unmute", "mute", "microphone"], pid: pid) {
                if app == "zoom" {
                    Keystroke.send(pid: pid, keyCode: Keystroke.a, flags: [.maskCommand, .maskShift])
                } else {
                    Keystroke.send(pid: pid, keyCode: Keystroke.m, flags: [.maskCommand, .maskShift])
                }
            }
        case "toggleCamera":
            if !AXScanner.press(matching: ["camera", "video", "start video", "stop video"], pid: pid) {
                if app == "zoom" {
                    Keystroke.send(pid: pid, keyCode: Keystroke.v, flags: [.maskCommand, .maskShift])
                } else {
                    Keystroke.send(pid: pid, keyCode: Keystroke.o, flags: [.maskCommand, .maskShift])
                }
            }
        case "leave":
            if !AXScanner.press(matching: ["leave", "end meeting", "end call"], pid: pid) {
                if app == "zoom" {
                    Keystroke.send(pid: pid, keyCode: Keystroke.w, flags: [.maskCommand])
                } else {
                    Keystroke.send(pid: pid, keyCode: Keystroke.h, flags: [.maskCommand, .maskShift])
                }
            }
        case "toggleHand":
            if !AXScanner.press(matching: ["raise hand", "lower hand", "hand"], pid: pid) {
                if app == "zoom" {
                    Keystroke.send(pid: pid, keyCode: Keystroke.y, flags: [.maskAlternate])
                } else {
                    Keystroke.send(pid: pid, keyCode: Keystroke.k, flags: [.maskCommand, .maskShift])
                }
            }
        case "toggleBlur":
            if app != "teams" { return }
            if !AXScanner.press(matching: ["blur", "background"], pid: pid) {
                Keystroke.send(pid: pid, keyCode: Keystroke.p, flags: [.maskCommand, .maskShift])
            }
        case "react.like":
            zoomReact(pid: pid, key: Keystroke.five) {
                self.react(["like", "thumbs up"], pid: pid)
            }
        case "react.love":
            zoomReact(pid: pid, key: Keystroke.six) {
                self.react(["love", "heart"], pid: pid)
            }
        case "react.laugh":
            zoomReact(pid: pid, key: Keystroke.seven) {
                self.react(["laugh", "haha", "joy"], pid: pid)
            }
        case "react.wow":
            zoomReact(pid: pid, key: Keystroke.eight) {
                self.react(["wow", "surprised", "amazed", "open mouth"], pid: pid)
            }
        case "react.applause":
            zoomReact(pid: pid, key: Keystroke.four) {
                self.react(["applause", "clap", "clapping"], pid: pid)
            }
        default:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            _ = self?.scan()
        }
    }

    private func zoomReact(pid: pid_t, key: CGKeyCode, otherwise: () -> Void) {
        if state.app == "zoom" {
            Keystroke.send(pid: pid, keyCode: key, flags: [.maskCommand, .maskAlternate])
            return
        }
        otherwise()
    }

    private func react(_ needles: [String], pid: pid_t) {
        if AXScanner.press(matching: needles, pid: pid) { return }
        _ = AXScanner.press(matching: ["react", "reactions", "emoji"], pid: pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            _ = AXScanner.press(matching: needles, pid: pid)
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
        let titleHit = titles.contains { isMeetingTitle($0, kind: kind) }
        let extraWindow = titles.contains { !isChromeTitle($0, kind: kind) }
        var buttons: [AXButton] = []
        if axTrusted && (titleHit || extraWindow || forceWalk) {
            buttons = AXScanner.buttons(pid: pid) { title in
                !self.isChromeTitle(title, kind: kind)
            }
        }
        let classified = classify(buttons)
        let controlHit = classified.muted != nil || classified.cameraOn != nil
        state.active = titleHit || controlHit
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
        let chrome = ["calendar |", "activity |", "chat |", "communities |", "calls |", "files |", "apps |"]
        return chrome.contains(where: { t.hasPrefix($0) })
    }

    private func isMeetingTitle(_ title: String, kind: String) -> Bool {
        if isChromeTitle(title, kind: kind) { return false }
        let t = title.lowercased()
        if kind == "zoom" {
            return t.contains("zoom meeting") || t.contains("zoom webinar")
        }
        if t.contains("meeting") || t.contains("webinar") || t.contains("call with") || t.contains("meet now") {
            return true
        }
        return false
    }

    private func classify(_ buttons: [AXButton]) -> (
        muted: Bool?, cameraOn: Bool?, handUp: Bool?, blurred: Bool?
    ) {
        var muted: Bool?
        var cameraOn: Bool?
        var handUp: Bool?
        var blurred: Bool?
        for button in buttons {
            let t = button.title.lowercased()
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
        return (muted, cameraOn, handUp, blurred)
    }
}
