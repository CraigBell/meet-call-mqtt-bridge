import Darwin
import Foundation
import IOKit.hid

/// Engage 75 telephony HID without seizing the device.
/// Jabra Direct keeps the call lock; we write the same output LEDs a softphone uses
/// (mute / microphone / off-hook) and watch Phone Mute so the pad icon can follow.
final class JabraHID {
    var onMutePress: (() -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var muteLED: IOHIDElement?
    private var micLED: IOHIDElement?
    private var offHookLED: IOHIDElement?
    private var reportOutputs: [IOHIDElement] = []
    private var lastMuteAt: TimeInterval = 0
    private var ignoreButtonUntil: TimeInterval = 0

    var ready: Bool { muteLED != nil && device != nil }

    func start() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match = [kIOHIDVendorIDKey as String: 0x0B0E] as CFDictionary
        IOHIDManagerSetDeviceMatching(mgr, match)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<JabraHID>.fromOpaque(ctx).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<JabraHID>.fromOpaque(ctx).takeUnretainedValue().detach(device)
        }, ctx)
        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
            guard let ctx else { return }
            Unmanaged<JabraHID>.fromOpaque(ctx).takeUnretainedValue().handleInput(value)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if status != kIOReturnSuccess {
            Log.line(String(format: "jabra HID open skipped (%08x)", status))
            return
        }
        manager = mgr
        Log.line("jabra HID open (no seize)")
    }

    func ignoreNextButton() {
        ignoreButtonUntil = Date().timeIntervalSince1970 + 0.45
    }

    /// Toggle headset mute. While a call is up, keep off-hook set so the report cannot drop the call.
    func toggleMute(currentlyMuted: Bool?, inCall: Bool) -> Bool? {
        guard ready else {
            Log.line("jabra HID mute ignored: no telephony LED")
            return nil
        }
        let current = currentlyMuted ?? read(muteLED) ?? false
        let next = !current
        let offHook = inCall || (read(offHookLED) ?? false)
        guard commit(mute: next, offHook: offHook) else { return nil }
        ignoreNextButton()
        Log.line("jabra HID muted=\(next)")
        return next
    }

    func hangUp(inCall: Bool) -> Bool {
        guard inCall else {
            Log.line("jabra HID hang up ignored: not in call")
            return false
        }
        guard ready else {
            Log.line("jabra HID hang up ignored: no telephony LED")
            return false
        }
        let mute = read(muteLED) ?? false
        guard commit(mute: mute, offHook: false) else { return false }
        Log.line("jabra HID hang up")
        return true
    }

    func printDump() {
        guard let device else {
            print("jabra HID: no device yet")
            return
        }
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
        print("jabra HID device=\(name) ready=\(ready) outputs=\(reportOutputs.count)")
        for el in reportOutputs {
            let page = IOHIDElementGetUsagePage(el)
            let usage = IOHIDElementGetUsage(el)
            let report = IOHIDElementGetReportID(el)
            let val = read(el).map { $0 ? "1" : "0" } ?? "?"
            print(String(format: "  out page=0x%04x usage=0x%04x report=%d val=%@", page, usage, report, val))
        }
    }

    static func runOnce(_ work: (JabraHID) -> Void) {
        let hid = JabraHID()
        hid.start()
        for _ in 0..<40 {
            if hid.ready { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        work(hid)
    }

    private func attach(_ device: IOHIDDevice) {
        let page = intProp(device, kIOHIDPrimaryUsagePageKey)
        let usage = intProp(device, kIOHIDPrimaryUsageKey)
        guard page == 0x0B, usage == 0x05 else { return }
        var mute: IOHIDElement?
        var mic: IOHIDElement?
        var hook: IOHIDElement?
        var outputs: [IOHIDElement] = []
        for el in Self.elements(on: device) {
            guard IOHIDElementGetType(el) == kIOHIDElementTypeOutput else { continue }
            guard IOHIDElementGetReportID(el) == 2 else { continue }
            let usagePage = Int(IOHIDElementGetUsagePage(el))
            let u = Int(IOHIDElementGetUsage(el))
            outputs.append(el)
            if usagePage == 0x08, u == 0x09 { mute = el }
            if usagePage == 0x08, u == 0x21 { mic = el }
            if usagePage == 0x08, u == 0x17 { hook = el }
        }
        guard let mute else { return }
        self.device = device
        muteLED = mute
        micLED = mic
        offHookLED = hook
        reportOutputs = outputs
        Log.line("jabra HID telephony LEDs mute=true mic=\(mic != nil) offhook=\(hook != nil)")
    }

    private func detach(_ device: IOHIDDevice) {
        guard self.device === device else { return }
        self.device = nil
        muteLED = nil
        micLED = nil
        offHookLED = nil
        reportOutputs = []
        Log.line("jabra HID device removed")
    }

    private func handleInput(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let pressed = IOHIDValueGetIntegerValue(value) != 0
        guard pressed, Self.isMuteInput(page: page, usage: usage) else { return }
        let now = Date().timeIntervalSince1970
        guard now >= ignoreButtonUntil, now - lastMuteAt > 0.25 else { return }
        lastMuteAt = now
        DispatchQueue.main.async { self.onMutePress?() }
    }

    private func commit(mute: Bool, offHook: Bool) -> Bool {
        guard let device, let muteLED else { return false }
        let targets: [IOHIDElement] = reportOutputs.isEmpty ? [muteLED] : reportOutputs
        var keyCbs = kCFTypeDictionaryKeyCallBacks
        var valCbs = kCFTypeDictionaryValueCallBacks
        guard let multiple = CFDictionaryCreateMutable(kCFAllocatorDefault, targets.count, &keyCbs, &valCbs) else {
            return false
        }
        for el in targets {
            let usagePage = Int(IOHIDElementGetUsagePage(el))
            let usage = Int(IOHIDElementGetUsage(el))
            let bit: Int
            if usagePage == 0x08, usage == 0x09 { bit = mute ? 1 : 0 }
            else if usagePage == 0x08, usage == 0x21 { bit = mute ? 1 : 0 }
            else if usagePage == 0x08, usage == 0x17 { bit = offHook ? 1 : 0 }
            else { bit = (read(el) ?? false) ? 1 : 0 }
            let hidValue = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, el, mach_absolute_time(), bit)
            CFDictionarySetValue(
                multiple,
                Unmanaged.passUnretained(el).toOpaque(),
                Unmanaged.passUnretained(hidValue).toOpaque())
        }
        let status = IOHIDDeviceSetValueMultiple(device, multiple)
        if status != kIOReturnSuccess {
            Log.line(String(format: "jabra HID set failed (%08x)", status))
            return false
        }
        return true
    }

    private func read(_ element: IOHIDElement?) -> Bool? {
        guard let device, let element else { return nil }
        let ptr = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard IOHIDDeviceGetValue(device, element, ptr) == kIOReturnSuccess else { return nil }
        return IOHIDValueGetIntegerValue(ptr.pointee.takeUnretainedValue()) != 0
    }

    private func intProp(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let raw = IOHIDDeviceGetProperty(device, key as CFString) else { return nil }
        return (raw as? NSNumber)?.intValue
    }

    private static func isMuteInput(page: Int, usage: Int) -> Bool {
        (page == 0x0B && usage == 0x2F) || (page == 0x08 && usage == 0x09)
    }

    private static func elements(on device: IOHIDDevice) -> [IOHIDElement] {
        guard let raw = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) else {
            return []
        }
        let n = CFArrayGetCount(raw)
        var out: [IOHIDElement] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let ptr = CFArrayGetValueAtIndex(raw, i) else { continue }
            out.append(Unmanaged<IOHIDElement>.fromOpaque(ptr).takeUnretainedValue())
        }
        return out
    }
}
