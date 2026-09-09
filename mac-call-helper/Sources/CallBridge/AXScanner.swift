import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

struct AXButton {
    let title: String
    let element: AXUIElement
}

enum AXScanner {
    static func isTrusted(prompt: Bool) -> Bool {
        if prompt {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    static func apps() -> [(name: String, bundle: String, pid: pid_t)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bid = app.bundleIdentifier, app.processIdentifier > 0 else { return nil }
            let name = app.localizedName ?? bid
            return (name, bid, app.processIdentifier)
        }
    }

    static func meetingApps() -> [(kind: String, pid: pid_t, bundle: String)] {
        apps().compactMap { item in
            let bid = item.bundle.lowercased()
            if bid == "com.microsoft.teams2" || bid == "com.microsoft.teams"
                || bid == "com.microsoft.teams2.helper"
            {
                return ("teams", item.pid, item.bundle)
            }
            if bid == "us.zoom.xos" {
                return ("zoom", item.pid, item.bundle)
            }
            return nil
        }
    }

    static func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = copyAttr(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        return windows.compactMap { copyString($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
    }

    static func hasOnScreenWindow(pid: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.contains { info in
            let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            return owner == pid
        }
    }

    static func cgWindowTitles(ownerNames: [String]) -> [String] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let owners = Set(ownerNames.map { $0.lowercased() })
        return list.compactMap { info in
            let owner = (info[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            guard owners.contains(where: { owner.contains($0) }) else { return nil }
            return info[kCGWindowName as String] as? String
        }.filter { !$0.isEmpty }
    }

    static func buttons(pid: pid_t, limit: Int = 400, includeWindow: ((String) -> Bool)? = nil) -> [AXButton] {
        let app = AXUIElementCreateApplication(pid)
        guard let windows = copyAttr(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var found: [AXButton] = []
        for window in windows {
            if found.count >= limit { break }
            let title = copyString(window, kAXTitleAttribute) ?? ""
            if let includeWindow, !includeWindow(title) { continue }
            walk(window, depth: 0, found: &found, remaining: limit)
        }
        return found
    }

    static func dump(pid: pid_t) -> String {
        let titles = windowTitles(pid: pid)
        let btns = buttons(pid: pid, limit: 600)
        var lines: [String] = ["windows:"]
        lines.append(contentsOf: titles.map { "  - \($0)" })
        lines.append("buttons:")
        lines.append(contentsOf: btns.prefix(80).map { "  - \($0.title)" })
        return lines.joined(separator: "\n")
    }

    static func press(matching needles: [String], pid: pid_t) -> Bool {
        let lower = needles.map { $0.lowercased() }
        for button in buttons(pid: pid) {
            let t = button.title.lowercased()
            if lower.contains(where: { t == $0 || t.contains($0) }) {
                AXUIElementPerformAction(button.element, kAXPressAction as CFString)
                return true
            }
        }
        return false
    }

    private static func walk(_ el: AXUIElement, depth: Int, found: inout [AXButton], remaining: Int) {
        if found.count >= remaining || depth > 18 { return }
        let role = copyString(el, kAXRoleAttribute) ?? ""
        if role == "AXButton" || role == "AXCheckBox" || role == "AXToggle" || role == "AXMenuButton" {
            let title = [
                copyString(el, kAXTitleAttribute),
                copyString(el, kAXDescriptionAttribute),
                copyString(el, kAXHelpAttribute),
                copyString(el, "AXIdentifier"),
            ].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            if !title.isEmpty {
                found.append(AXButton(title: title, element: el))
            }
        }
        if let children = copyAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                walk(child, depth: depth + 1, found: &found, remaining: remaining)
                if found.count >= remaining { return }
            }
        }
    }

    private static func copyAttr(_ el: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private static func copyString(_ el: AXUIElement, _ attr: String) -> String? {
        copyAttr(el, attr) as? String
    }
}
