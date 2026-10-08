// Lune's app icon: the moon from MoonView (awake), a white circle with tall oval eyes, on black.
// Writes the three 1024 px PNGs into the asset catalog:
//
//   swift design/app-icon/generate.swift
//
// Run from the repo root. The drawing uses the same 100 × 100 grid as MoonView.draw.

import AppKit

struct Theme {
    let file: String
    let moon: NSColor
    let eye: NSColor
}

func hex(_ value: Int) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

// Black like iOS's own black icons. Dark mode dims the moon slightly; tinted stays neutral gray for iOS to tint.
let themes = [
    Theme(file: "AppIcon.png", moon: hex(0xF2F2F7), eye: hex(0x1C1C1E)),
    Theme(file: "AppIcon-Dark.png", moon: hex(0xE5E5EA), eye: hex(0x1C1C1E)),
    Theme(file: "AppIcon-Tinted.png", moon: hex(0xF0F0F0), eye: hex(0x1C1C1C)),
]

let size = 1024
/// The moon's diameter as a share of the icon.
let moonShare: CGFloat = 0.58
let folder = URL(fileURLWithPath: "Lune/Assets.xcassets/AppIcon.appiconset")

for theme in themes {
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { fatalError("no context") }

    // Core Graphics puts the origin at the bottom left; flip so the grid reads like MoonView's.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)

    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let diameter = CGFloat(size) * moonShare
    let origin = (CGFloat(size) - diameter) / 2
    let unit = diameter / 100
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: origin + x * unit, y: origin + y * unit, width: width * unit, height: height * unit)
    }

    context.setFillColor(theme.moon.cgColor)
    context.fillEllipse(in: rect(0, 0, 100, 100))
    context.setFillColor(theme.eye.cgColor)
    context.fillEllipse(in: rect(32.5, 36.5, 9, 15))
    context.fillEllipse(in: rect(58.5, 36.5, 9, 15))

    let image = context.makeImage()!
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try! data.write(to: folder.appendingPathComponent(theme.file))
    print("wrote \(theme.file)")
}
