// Draws the review account's sample photos and avatars (flat illustrations, no real photos):
//
//   swift scripts/review-account/make-assets.swift
//
// Run from the repo root. Writes JPEGs into scripts/review-account/assets/.

import AppKit

func hex(_ value: Int) -> CGColor {
    CGColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

func draw(_ name: String, width: Int, height: Int, _ paint: (CGContext) -> Void) {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    // Top-left origin, like the screen.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    paint(context)
    let data = NSBitmapImageRep(cgImage: context.makeImage()!)
        .representation(using: .jpeg, properties: [.compressionFactor: 0.85])!
    try! data.write(to: URL(fileURLWithPath: "scripts/review-account/assets/\(name).jpg"))
    print("wrote \(name).jpg")
}

func gradient(_ context: CGContext, _ colors: [Int], height: Int) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(hex) as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
}

try? FileManager.default.createDirectory(atPath: "scripts/review-account/assets", withIntermediateDirectories: true)

// Mia: dusk over the sea, the moon already up.
draw("photo-mia", width: 1200, height: 900) { c in
    gradient(c, [0x1E2A4A, 0x6B4E71, 0xE8875A], height: 620)
    c.setFillColor(hex(0xF2F2F7))
    c.fillEllipse(in: CGRect(x: 820, y: 150, width: 120, height: 120))
    c.setFillColor(hex(0x16213A))
    c.fill(CGRect(x: 0, y: 620, width: 1200, height: 280))
    c.setFillColor(hex(0xE8875A))
    for (i, width) in [520, 380, 240, 120].enumerated() {
        c.fill(CGRect(x: 600 - width / 2, y: 650 + i * 50, width: width, height: 8))
    }
}

// Leo: a cup of tea on a wooden table.
draw("photo-leo", width: 1200, height: 900) { c in
    c.setFillColor(hex(0x2B2420))
    c.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
    c.setFillColor(hex(0x6E4B33))
    c.fill(CGRect(x: 0, y: 560, width: 1200, height: 340))
    c.setFillColor(hex(0xEDE6DA))
    c.fillEllipse(in: CGRect(x: 380, y: 420, width: 440, height: 300))
    c.setFillColor(hex(0xA0662E))
    c.fillEllipse(in: CGRect(x: 420, y: 450, width: 360, height: 220))
    c.setStrokeColor(hex(0xEDE6DA))
    c.setLineWidth(36)
    c.strokeEllipse(in: CGRect(x: 790, y: 500, width: 110, height: 120))
}

// Ava: the city from a late train.
draw("photo-ava", width: 1200, height: 900) { c in
    gradient(c, [0x0B1026, 0x1D2547], height: 900)
    let buildings: [(x: Int, w: Int, h: Int)] = [(40, 180, 420), (240, 140, 560), (400, 220, 360), (640, 160, 620), (820, 200, 460), (1040, 140, 520)]
    for b in buildings {
        c.setFillColor(hex(0x05081A))
        c.fill(CGRect(x: b.x, y: 900 - b.h, width: b.w, height: b.h))
        c.setFillColor(hex(0xF5C76B))
        var y = 900 - b.h + 30
        var lit = b.x
        while y < 860 {
            var x = b.x + 20
            while x < b.x + b.w - 30 {
                lit = (lit * 37 + 11) % 100
                if lit < 45 { c.fill(CGRect(x: x, y: y, width: 22, height: 30)) }
                x += 44
            }
            y += 60
        }
    }
}

// Avatars: a flat colour and one shape each.
for (name, background, shape) in [("avatar-mia", 0xE8875A, 0xF2F2F7), ("avatar-leo", 0x6E8B5B, 0xEDE6DA), ("avatar-ava", 0x4B5FA6, 0xF5C76B)] {
    draw(name, width: 512, height: 512) { c in
        c.setFillColor(hex(background))
        c.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        c.setFillColor(hex(shape))
        c.fillEllipse(in: CGRect(x: 156, y: 156, width: 200, height: 200))
    }
}
