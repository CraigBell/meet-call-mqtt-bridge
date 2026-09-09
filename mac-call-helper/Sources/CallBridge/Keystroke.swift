import CoreGraphics
import Foundation

enum Keystroke {
    static let command = CGEventFlags.maskCommand
    static let shift = CGEventFlags.maskShift
    static let option = CGEventFlags.maskAlternate
    static let control = CGEventFlags.maskControl

    static func send(pid: pid_t, keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.postToPid(pid)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.postToPid(pid)
        }
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
    static let four: CGKeyCode = 21
    static let five: CGKeyCode = 23
    static let six: CGKeyCode = 22
    static let seven: CGKeyCode = 26
    static let eight: CGKeyCode = 28
}
