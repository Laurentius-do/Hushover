// Renders the Hushover app icon into Resources/AppIcon.icns.
// Usage: ./Tools/make-icon.sh
import AppKit

/// Music bars that dip in the middle, making room for a speech bubble.
func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // Squircle body on Apple's 1024 grid (824 pt body, 100 pt margin).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.47, green: 0.36, blue: 0.98, alpha: 1).cgColor,
        NSColor(red: 0.16, green: 0.10, blue: 0.42, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 250, y: 924), end: CGPoint(x: 780, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // Soft glow behind the bubble.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.22).cgColor,
        NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 640), endRadius: 330, options: [])

    // Music bars.
    let profile: [CGFloat] = [0.45, 0.78, 0.6, 0.95, 0.7, 0.9, 0.75, 1.0, 0.62, 0.85, 0.5]
    let count = profile.count
    let barWidth: CGFloat = 38
    let spacing: CGFloat = 58
    let startX = 512 - spacing * CGFloat(count - 1) / 2
    let centerY: CGFloat = 395
    let maxHalf: CGFloat = 165
    let middle = CGFloat(count - 1) / 2
    let barGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.55, green: 1.0, blue: 0.86, alpha: 1).cgColor,
        NSColor(red: 0.36, green: 0.78, blue: 1.0, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!

    for (i, value) in profile.enumerated() {
        let distance = (CGFloat(i) - middle) / 1.7
        let duck = 1 - 0.82 * exp(-distance * distance)
        let half = max(maxHalf * value * duck, barWidth / 2)
        let rect = CGRect(x: startX + CGFloat(i) * spacing - barWidth / 2, y: centerY - half, width: barWidth, height: half * 2)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.clip()
        ctx.drawLinearGradient(barGradient, start: CGPoint(x: 0, y: centerY + maxHalf), end: CGPoint(x: 0, y: centerY - maxHalf), options: [])
        ctx.restoreGState()
    }

    // Speech bubble with its tail pointing down into the dip.
    let bubble = CGRect(x: 342, y: 580, width: 340, height: 196)
    let bubblePath = CGMutablePath()
    bubblePath.addPath(CGPath(roundedRect: bubble, cornerWidth: 98, cornerHeight: 98, transform: nil))
    bubblePath.move(to: CGPoint(x: 462, y: 600))
    bubblePath.addQuadCurve(to: CGPoint(x: 490, y: 500), control: CGPoint(x: 486, y: 550))
    bubblePath.addQuadCurve(to: CGPoint(x: 560, y: 592), control: CGPoint(x: 512, y: 545))
    bubblePath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(bubblePath)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // "Shh" – three dots in the background color.
    ctx.setFillColor(NSColor(red: 0.30, green: 0.22, blue: 0.72, alpha: 1).cgColor)
    for dx in [-78.0, 0, 78] {
        ctx.fillEllipse(in: CGRect(x: 512 + dx - 22, y: 678 - 22, width: 44, height: 44))
    }

    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawIcon(in: context.cgContext, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Writes an .icns file with PNG payloads (supported since macOS 10.7) – no iconutil needed.
func icns(entries: [(type: String, size: Int)]) -> Data {
    var body = Data()
    for entry in entries {
        let data = png(size: entry.size)
        body.append(entry.type.data(using: .ascii)!)
        body.append(bigEndian: UInt32(data.count + 8))
        body.append(data)
    }
    var file = "icns".data(using: .ascii)!
    file.append(bigEndian: UInt32(body.count + 8))
    file.append(body)
    return file
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let preview = URL(fileURLWithPath: CommandLine.arguments[2])
try icns(entries: [
    ("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
]).write(to: output)
try png(size: 1024).write(to: preview)
