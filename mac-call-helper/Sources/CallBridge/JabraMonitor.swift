import AppKit
import CoreAudio
import Foundation

/// Event-driven in-call detector for Jabra headsets.
///
/// Uses Core Audio `DeviceIsRunningSomewhere` on devices named "Jabra".
/// That is the cheap signal that the Engage 75 is actually in a call
/// (the base shows "Softphone"). We do **not** open HID or the Jabra SDK:
/// those take the exclusive call lock and were the old CPU hog.
final class JabraMonitor {
    var onChange: ((Bool) -> Void)?
    var onMuteChange: (() -> Void)?
    private var watched = Set<AudioObjectID>()
    private var muteWatched = Set<AudioObjectID>()
    private let queue = DispatchQueue(label: "at.craig.call-bridge.jabra")
    private let lock = NSLock()
    private var debounce: DispatchWorkItem?
    private var hardwareListenerInstalled = false
    private var storedInCall = false

    var inCall: Bool {
        lock.lock(); defer { lock.unlock() }
        return storedInCall
    }

    func start() {
        queue.async { [weak self] in
            self?.installHardwareListener()
            self?.resyncDevices()
            self?.publish(self?.isAnyJabraRunning() ?? false, immediate: true)
        }
    }

    func snapshot() -> [(name: String, id: AudioObjectID, running: Bool)] {
        Self.jabraDevices().map { dev in
            (Self.deviceName(dev), dev, Self.isRunning(dev))
        }
    }

    private func installHardwareListener() {
        guard !hardwareListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue
        ) { [weak self] _, _ in
            self?.resyncDevices()
            self?.publish(self?.isAnyJabraRunning() ?? false, immediate: false)
        }
        if status == noErr { hardwareListenerInstalled = true }
    }

    private func resyncDevices() {
        let current = Set(Self.jabraDevices())
        for id in current.subtracting(watched) {
            addRunningListener(id)
        }
        watched = current
        for id in current.subtracting(muteWatched) where Self.hasScope(id, scope: kAudioDevicePropertyScopeInput) {
            addMuteListener(id)
            muteWatched.insert(id)
        }
    }

    private func addRunningListener(_ id: AudioObjectID) {
        var addr = Self.runningAddress
        _ = AudioObjectAddPropertyListenerBlock(id, &addr, queue) { [weak self] _, _ in
            self?.publish(self?.isAnyJabraRunning() ?? false, immediate: false)
        }
    }

    private func addMuteListener(_ id: AudioObjectID) {
        for element in Self.elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: element)
            let status = AudioObjectAddPropertyListenerBlock(id, &addr, queue) { [weak self] _, _ in
                DispatchQueue.main.async { self?.onMuteChange?() }
            }
            if status == noErr { return }
        }
    }

    private func isAnyJabraRunning() -> Bool {
        watched.contains { Self.isRunning($0) }
    }

    private func publish(_ next: Bool, immediate: Bool) {
        debounce?.cancel()
        let apply = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let changed = self.storedInCall != next
            self.storedInCall = next
            self.lock.unlock()
            guard changed else { return }
            Log.line("jabra inCall=\(next)")
            DispatchQueue.main.async { self.onChange?(next) }
        }
        if immediate {
            apply()
            return
        }
        let work = DispatchWorkItem(block: apply)
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static var runningAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func jabraDevices() -> [AudioObjectID] {
        allDevices().filter { deviceName($0).localizedCaseInsensitiveContains("jabra") }
    }

    private static func allDevices() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    private static func deviceName(_ id: AudioObjectID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let cf else {
            return ""
        }
        return cf.takeUnretainedValue() as String
    }

    static func isRunning(_ id: AudioObjectID) -> Bool {
        var addr = runningAddress
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    /// Process currently capturing from the Jabra (the live call app).
    static func inputClient() -> (pid: pid_t, bundle: String, name: String)? {
        let jabraIDs = Set(jabraDevices())
        guard !jabraIDs.isEmpty else { return nil }
        for proc in processObjects() {
            guard processRunningInput(proc) else { continue }
            let devices = processDevices(proc)
            guard devices.contains(where: { jabraIDs.contains($0) }) else { continue }
            let pid = processPid(proc)
            guard pid > 0 else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            return (pid, app?.bundleIdentifier ?? "", app?.localizedName ?? "pid \(pid)")
        }
        return nil
    }

    static func isMuted() -> Bool? {
        let inputs = inputDevices()
        guard !inputs.isEmpty else { return nil }
        return inputs.contains { uintValue($0, kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput) == 1 }
    }

    @discardableResult
    static func toggleMute() -> Bool? {
        guard let current = isMuted() else { return nil }
        let next = !current
        var ok = false
        for id in inputDevices() {
            if setUint(id, kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput, next ? 1 : 0) {
                ok = true
            }
        }
        guard ok else {
            Log.line("jabra mute property missing")
            return nil
        }
        Log.line("jabra muted=\(next)")
        return next
    }

    static func volume() -> Float32? {
        guard let id = preferredOutput() else { return nil }
        return floatValue(id, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
    }

    @discardableResult
    static func adjustVolume(_ delta: Float32) -> Float32? {
        guard let id = preferredOutput(),
              let current = floatValue(id, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        else {
            Log.line("jabra volume: no output")
            return nil
        }
        let next = min(1, max(0, current + delta))
        guard setFloat(id, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, next) else {
            Log.line("jabra volume set failed")
            return nil
        }
        Log.line(String(format: "jabra volume=%.2f", next))
        return next
    }

    private static func inputDevices() -> [AudioObjectID] {
        jabraDevices().filter { hasScope($0, scope: kAudioDevicePropertyScopeInput) }
    }

    private static func outputDevices() -> [AudioObjectID] {
        jabraDevices().filter { hasScope($0, scope: kAudioDevicePropertyScopeOutput) }
    }

    private static func preferredOutput() -> AudioObjectID? {
        let outs = outputDevices()
        return outs.first { isRunning($0) } ?? outs.first
    }

    private static func hasScope(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size >= MemoryLayout<AudioStreamID>.size
    }

    private static let elements: [AudioObjectPropertyElement] = [
        kAudioObjectPropertyElementMain,
        1,
        2,
    ]

    private static func uintValue(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> UInt32? {
        for element in elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: element)
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    private static func setUint(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ value: UInt32
    ) -> Bool {
        for element in elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: element)
            var value = value
            let size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value) == noErr {
                return true
            }
        }
        return false
    }

    private static func floatValue(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> Float32? {
        for element in elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }

    private static func setFloat(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope, _ value: Float32
    ) -> Bool {
        for element in elements {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: element)
            var value = value
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value) == noErr {
                return true
            }
        }
        return false
    }

    // MARK: - Which process has the Jabra input (macOS 12+ Audio Process objects)

    private static let processListSel: AudioObjectPropertySelector = 0x7072636C // 'prcl'
    private static let processPidSel: AudioObjectPropertySelector = 0x70706964 // 'ppid'
    private static let processDevicesSel: AudioObjectPropertySelector = 0x7064766E // 'pdvn'
    private static let processRunningInputSel: AudioObjectPropertySelector = 0x70697269 // 'piri'

    private static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: processListSel,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func processPid(_ proc: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: processPidSel,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &pid) == noErr else {
            return 0
        }
        return pid
    }

    private static func processDevices(_ proc: AudioObjectID) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: processDevicesSel,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(proc, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func processRunningInput(_ proc: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: processRunningInputSel,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
