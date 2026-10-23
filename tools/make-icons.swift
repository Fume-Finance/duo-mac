// Draws the Duo Mac icons from design/icon.png (1024 px, full-bleed square; render it from icon.svg with
// `rsvg-convert -w 1024 design/icon.svg -o design/icon.png`).
// Usage: swift tools/make-icons.swift <project folder> [--laptop]
//   --laptop  the original drawn-laptop icon instead (copies of it are in design/old-icon-laptop/)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let master: CGImage? = CommandLine.arguments.contains("--laptop") ? nil : {
    let url = root.appendingPathComponent("design/icon.png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("Can't read \(url.path)")
    }
    return img
}()

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}

func gradient(_ colors: [UInt32], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors.map { color($0) } as CFArray, locations: locs)!
}

/// Draws the icon artwork into `rect` (CG coordinates, origin bottom-left).
func drawArt(_ ctx: CGContext, in r: CGRect) {
    if let master {
        ctx.interpolationQuality = .high
        ctx.draw(master, in: r)
        return
    }
    let S = r.width
    // Background
    ctx.saveGState()
    ctx.clip(to: r)
    ctx.drawLinearGradient(gradient([0x30333c, 0x15161a], [0, 1]), start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
    // soft glow behind the laptop
    ctx.drawRadialGradient(CGGradient(colorsSpace: space, colors: [color(0x7d6bff, 0.35), color(0x7d6bff, 0)] as CFArray, locations: [0, 1])!,
                           startCenter: CGPoint(x: r.midX, y: r.minY + S * 0.55), startRadius: 0,
                           endCenter: CGPoint(x: r.midX, y: r.minY + S * 0.55), endRadius: S * 0.5, options: [])
    ctx.restoreGState()

    // Lid
    let lidW = S * 0.64, lidH = S * 0.42
    let lid = CGRect(x: r.midX - lidW / 2, y: r.minY + S * 0.33, width: lidW, height: lidH)
    ctx.addPath(CGPath(roundedRect: lid, cornerWidth: S * 0.035, cornerHeight: S * 0.035, transform: nil))
    ctx.setFillColor(color(0x08080a))
    ctx.fillPath()
    // Display
    let b = S * 0.022
    let disp = lid.insetBy(dx: b, dy: b)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: disp, cornerWidth: S * 0.018, cornerHeight: S * 0.018, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(gradient([0x2a1b78, 0x6c2bd9, 0xe0457b, 0xffb057], [0, 0.4, 0.75, 1]),
                           start: CGPoint(x: disp.minX, y: disp.maxY), end: CGPoint(x: disp.maxX, y: disp.minY), options: [])
    // a gentle wave
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: disp.minX, y: disp.minY + disp.height * 0.35))
    wave.addCurve(to: CGPoint(x: disp.maxX, y: disp.minY + disp.height * 0.55),
                  control1: CGPoint(x: disp.minX + disp.width * 0.35, y: disp.minY + disp.height * 0.75),
                  control2: CGPoint(x: disp.minX + disp.width * 0.6, y: disp.minY + disp.height * 0.1))
    wave.addLine(to: CGPoint(x: disp.maxX, y: disp.minY))
    wave.addLine(to: CGPoint(x: disp.minX, y: disp.minY))
    wave.closeSubpath()
    ctx.addPath(wave)
    ctx.setFillColor(color(0x000000, 0.18))
    ctx.fillPath()
    // menu bar
    ctx.setFillColor(color(0x000000, 0.25))
    ctx.fill(CGRect(x: disp.minX, y: disp.maxY - S * 0.022, width: disp.width, height: S * 0.022))
    ctx.restoreGState()
    // Notch
    let nW = S * 0.075, nH = S * 0.026
    ctx.addPath(CGPath(roundedRect: CGRect(x: lid.midX - nW / 2, y: disp.maxY - nH, width: nW, height: nH + b * 0.5),
                       cornerWidth: S * 0.008, cornerHeight: S * 0.008, transform: nil))
    ctx.setFillColor(color(0x08080a))
    ctx.fillPath()

    // Base
    let baseW = S * 0.80, baseH = S * 0.045
    let base = CGRect(x: r.midX - baseW / 2, y: lid.minY - baseH + S * 0.004, width: baseW, height: baseH)
    let basePath = CGMutablePath()
    basePath.addRoundedRect(in: base, cornerWidth: S * 0.02, cornerHeight: S * 0.02)
    ctx.saveGState()
    ctx.addPath(basePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([0xf2f3f6, 0xb9bcc5, 0x80848f], [0, 0.55, 1]),
                           start: CGPoint(x: base.midX, y: base.maxY), end: CGPoint(x: base.midX, y: base.minY), options: [])
    // thumb notch
    ctx.setFillColor(color(0x5d616b, 0.9))
    ctx.addPath(CGPath(roundedRect: CGRect(x: base.midX - S * 0.06, y: base.maxY - S * 0.012, width: S * 0.12, height: S * 0.02),
                       cornerWidth: S * 0.008, cornerHeight: S * 0.008, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    // contact shadow
    ctx.setFillColor(color(0x000000, 0.35))
    ctx.fillEllipse(in: CGRect(x: base.minX + S * 0.04, y: base.minY - S * 0.03, width: baseW - S * 0.08, height: S * 0.035))
}

func png(_ size: Int, squircle: Bool) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let S = CGFloat(size)
    if squircle {
        // macOS icon grid: 824/1024 artwork with a soft shadow.
        let inset = S * 100 / 1024
        let rect = CGRect(x: inset, y: inset * 1.15, width: S - inset * 2, height: S - inset * 2)
        let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03, color: color(0x000000, 0.45))
        ctx.addPath(path)
        ctx.setFillColor(color(0x15161a))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        drawArt(ctx, in: rect)
        ctx.restoreGState()
    } else {
        drawArt(ctx, in: CGRect(x: 0, y: 0, width: S, height: S))
    }
    let img = ctx.makeImage()!
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

func write(_ data: Data, _ path: String) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

// iPhone Home Screen (iOS masks the corners itself)
write(png(180, squircle: false), "web/icon-180.png")
write(png(512, squircle: false), "web/icon-512.png")
// macOS (Dock icon at runtime + .icns for the launcher app)
write(png(512, squircle: true), "web/icon-mac.png")
let iconset = "build/AppIcon.iconset"
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    write(png(px, squircle: true), "\(iconset)/icon_\(name).png")
}
print("Icons written.")
