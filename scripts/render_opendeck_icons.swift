#!/usr/bin/env swift
import AppKit
import CoreImage
import Foundation

let plugin = URL(fileURLWithPath: NSString(
    string: "~/Library/Application Support/opendeck/plugins/com.craigbell.callbridge.sdPlugin"
).expandingTildeInPath)
let images = URL(fileURLWithPath: NSString(
    string: "~/Library/Application Support/opendeck/images/99-355499441494-293S"
).expandingTildeInPath)

func ensureDir(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func writePNG(_ image: NSImage, to url: URL) throws {
    try ensureDir(url.deletingLastPathComponent())
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:])
    else { throw NSError(domain: "render", code: 1) }
    try data.write(to: url)
}

func recolorToZoomBlue(src: URL, dst: URL) throws {
    guard let ci = CIImage(contentsOf: src) else { throw NSError(domain: "render", code: 2) }
    let hue = CIFilter(name: "CIHueAdjust")
    hue?.setValue(ci, forKey: kCIInputImageKey)
    // Teams purple (~270°) → Zoom blue (~210°)
    hue?.setValue(-1.05, forKey: kCIInputAngleKey)
    let sat = CIFilter(name: "CIColorControls")
    sat?.setValue(hue?.outputImage, forKey: kCIInputImageKey)
    sat?.setValue(1.15, forKey: kCIInputSaturationKey)
    sat?.setValue(1.08, forKey: kCIInputContrastKey)
    guard let output = sat?.outputImage else { throw NSError(domain: "render", code: 3) }
    let rep = NSBitmapImageRep(ciImage: output)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "render", code: 4)
    }
    try ensureDir(dst.deletingLastPathComponent())
    try data.write(to: dst)
}

func drawVolume(plus: Bool, size: CGFloat = 288) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    NSColor.black.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
    NSColor.white.setFill()
    NSColor.white.setStroke()

    let s = size
    let speaker = NSBezierPath()
    speaker.move(to: NSPoint(x: s * 0.18, y: s * 0.40))
    speaker.line(to: NSPoint(x: s * 0.32, y: s * 0.40))
    speaker.line(to: NSPoint(x: s * 0.46, y: s * 0.26))
    speaker.line(to: NSPoint(x: s * 0.46, y: s * 0.74))
    speaker.line(to: NSPoint(x: s * 0.32, y: s * 0.60))
    speaker.line(to: NSPoint(x: s * 0.18, y: s * 0.60))
    speaker.close()
    speaker.fill()

    let wave = NSBezierPath()
    wave.lineWidth = s * 0.045
    wave.lineCapStyle = .round
    wave.appendArc(
        withCenter: NSPoint(x: s * 0.48, y: s * 0.50),
        radius: s * 0.16,
        startAngle: -40,
        endAngle: 40
    )
    wave.stroke()

    let cx = s * 0.78
    let cy = s * 0.50
    let arm = s * 0.11
    let bar = NSBezierPath()
    bar.lineWidth = s * 0.055
    bar.lineCapStyle = .round
    bar.move(to: NSPoint(x: cx - arm, y: cy))
    bar.line(to: NSPoint(x: cx + arm, y: cy))
    bar.stroke()
    if plus {
        bar.removeAllPoints()
        bar.move(to: NSPoint(x: cx, y: cy - arm))
        bar.line(to: NSPoint(x: cx, y: cy + arm))
        bar.stroke()
    }
    img.unlockFocus()
    return img
}

func drawZoomLogo(size: CGFloat = 288) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    NSColor.black.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
    let blue = NSColor(red: 0.18, green: 0.55, blue: 0.98, alpha: 1)
    blue.setFill()
    let body = NSRect(x: size * 0.16, y: size * 0.30, width: size * 0.46, height: size * 0.40)
    NSBezierPath(roundedRect: body, xRadius: size * 0.08, yRadius: size * 0.08).fill()
    NSColor.black.setFill()
    let hole = NSRect(x: size * 0.24, y: size * 0.38, width: size * 0.30, height: size * 0.24)
    NSBezierPath(roundedRect: hole, xRadius: size * 0.05, yRadius: size * 0.05).fill()
    blue.setFill()
    let lens = NSBezierPath()
    lens.move(to: NSPoint(x: size * 0.60, y: size * 0.42))
    lens.line(to: NSPoint(x: size * 0.84, y: size * 0.30))
    lens.line(to: NSPoint(x: size * 0.84, y: size * 0.70))
    lens.line(to: NSPoint(x: size * 0.60, y: size * 0.58))
    lens.close()
    lens.fill()
    img.unlockFocus()
    return img
}

let pairs: [(String, String)] = [
    ("icons/toggleMute/states/Mute@2x.png", "icons/zoom/toggleMute/states/Mute@2x.png"),
    ("icons/toggleMute/states/Unmute@2x.png", "icons/zoom/toggleMute/states/Unmute@2x.png"),
    ("icons/toggleMute/actions/ToggleMute@2x.png", "icons/zoom/toggleMute/actions/ToggleMute@2x.png"),
    ("icons/toggleVideo/states/CameraOff@2x.png", "icons/zoom/toggleVideo/states/CameraOff@2x.png"),
    ("icons/toggleVideo/states/CameraOn@2x.png", "icons/zoom/toggleVideo/states/CameraOn@2x.png"),
    ("icons/toggleVideo/actions/ToggleCamera@2x.png", "icons/zoom/toggleVideo/actions/ToggleCamera@2x.png"),
    ("icons/leave/states/LeaveCall@2x.png", "icons/zoom/leave/states/LeaveCall@2x.png"),
    ("icons/leave/actions/LeaveCall@2x.png", "icons/zoom/leave/actions/LeaveCall@2x.png"),
    ("icons/toggleHand/states/HandDown@2x.png", "icons/zoom/toggleHand/states/HandDown@2x.png"),
    ("icons/toggleHand/states/HandUp@2x.png", "icons/zoom/toggleHand/states/HandUp@2x.png"),
    ("icons/toggleHand/actions/ToggleHand@2x.png", "icons/zoom/toggleHand/actions/ToggleHand@2x.png"),
]

for (srcRel, dstRel) in pairs {
    let src = plugin.appendingPathComponent(srcRel)
    let dst = plugin.appendingPathComponent(dstRel)
    guard FileManager.default.fileExists(atPath: src.path) else {
        fputs("skip missing \(srcRel)\n", stderr)
        continue
    }
    try recolorToZoomBlue(src: src, dst: dst)
    print("zoom \(dstRel)")
}

try writePNG(drawVolume(plus: false), to: plugin.appendingPathComponent("icons/volume/down@2x.png"))
try writePNG(drawVolume(plus: true), to: plugin.appendingPathComponent("icons/volume/up@2x.png"))
try writePNG(drawZoomLogo(), to: plugin.appendingPathComponent("icons/zoom/logo@2x.png"))
print("volume + zoom logo")

let defaultZoom = images.appendingPathComponent("Default/Keypad.3.0/0.png")
try writePNG(drawZoomLogo(), to: defaultZoom)
for (folder, name) in [("Teams", "13"), ("Teams", "14"), ("Zoom", "13"), ("Zoom", "14")] {
    let plus = name == "14"
    let dest = images.appendingPathComponent("\(folder)/Keypad.\(name).0/0.png")
    try writePNG(drawVolume(plus: plus), to: dest)
}
print("profile images")
