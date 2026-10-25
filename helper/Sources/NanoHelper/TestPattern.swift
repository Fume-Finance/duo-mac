import CoreMedia
import Foundation
import CoreVideo
import CoreGraphics
import CoreText

/// A fake 1512×982 "screen" for testing without Screen Recording permission.
/// It draws the pointer, clicks, typed text and recent input events coming from the phone,
/// so the whole loop (stream → touch → event → stream) can be checked end to end.
final class TestPatternSource: FrameSource {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?
    static let laptop = DisplayInfo(displayID: 0, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    pixelSize: CGSize(width: 3024, height: 1964), notch: CGSize(width: 186, height: 32),
                                    name: "Test pattern")
    private(set) var info = TestPatternSource.laptop
    weak var injector: InputInjector?
    var displayIndex: Int?
    /// Test mode imitates the Duo display: any non-nil value switches to `nanoSize`.
    var targetDisplayID: CGDirectDisplayID?
    var nanoSize: CGSize?
    var framesCaptured = 0

    private let queue = DispatchQueue(label: "nano.testpattern", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var width = 0, height = 0
    private var pool: CVPixelBufferPool?
    private var background: CGImage?
    private let start = Date()
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func refreshInfo() {
        let next: DisplayInfo
        if targetDisplayID != nil, let n = nanoSize {
            next = DisplayInfo(displayID: 1, bounds: CGRect(origin: .zero, size: n),
                               pixelSize: CGSize(width: n.width * 2, height: n.height * 2), notch: nil, name: "Duo display (test)")
        } else {
            next = TestPatternSource.laptop
        }
        queue.sync {
            self.info = next
            self.background = nil
        }
    }

    func start(width: Int, height: Int, fps: Int, completion: @escaping (Error?) -> Void) {
        queue.async {
            self.configure(width, height)
            if self.timer == nil {
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(1000 / max(1, fps)))
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                self.timer = t
                Log.info("Test pattern running at \(width)×\(height)")
            }
            completion(nil)
        }
    }

    func resize(width: Int, height: Int) { queue.async { self.configure(width, height) } }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    private func configure(_ w: Int, _ h: Int) {
        guard w != width || h != height else { return }
        width = w
        height = h
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        pool = nil
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        background = nil
    }

    private func tick() {
        guard let pool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let pb = out else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space,
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            draw(ctx)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        onFrame?(pb)
    }

    // MARK: Drawing (in 1512×982 "points", origin top-left)

    private func draw(_ ctx: CGContext) {
        if background == nil { background = makeBackground() }
        if let bg = background {
            ctx.draw(bg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / info.bounds.width, y: -CGFloat(height) / info.bounds.height)

        let snap = injector?.snapshot()
        let t = Date().timeIntervalSince(start)

        // Menu bar clock (changes once a second → small update)
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM  HH:mm:ss"
        let W = info.bounds.width, H = info.bounds.height
        text(ctx, f.string(from: Date()), x: W - 222, y: 22, size: 14, weight: .medium, color: .white)

        // Typed text
        let typed = (snap?.typed ?? "")
        text(ctx, typed.isEmpty ? "Type on the Nano keyboard…" : typed + "▏", x: 386, y: 572, size: 30,
             weight: .regular, color: typed.isEmpty ? CGColor(gray: 1, alpha: 0.35) : .white, mono: true)

        // Recent events
        for (i, e) in (snap?.events ?? []).reversed().enumerated() {
            text(ctx, e, x: 386, y: 668 + CGFloat(i) * 26, size: 18, weight: .regular,
                 color: CGColor(gray: 1, alpha: max(0.25, 1 - Double(i) * 0.13)), mono: true)
        }

        // Bouncing ball (a small region changing every frame)
        let span = W - 2 * 60
        let phase = (t * 260).truncatingRemainder(dividingBy: span * 2)
        let bx = 60 + (phase < span ? phase : span * 2 - phase)
        let by = H - 64 + sin(t * 3) * 22
        ctx.setFillColor(CGColor(red: 1, green: 0.62, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: bx - 16, y: by - 16, width: 32, height: 32))

        // Click ripple
        if let (p, at) = snap?.lastClick {
            let age = Date().timeIntervalSince(at)
            if age < 0.6 {
                let r = 10 + age * 70
                ctx.setStrokeColor(CGColor(red: 0.35, green: 0.8, blue: 1, alpha: 1 - age / 0.6))
                ctx.setLineWidth(4)
                ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
        }

        // Pointer
        if let c = snap?.cursor { drawArrow(ctx, at: c) }
        ctx.restoreGState()
    }

    private func makeBackground() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / info.bounds.width, y: -CGFloat(height) / info.bounds.height)
        let W = info.bounds.width, H = info.bounds.height

        let colors = [CGColor(red: 0.13, green: 0.10, blue: 0.36, alpha: 1),
                      CGColor(red: 0.36, green: 0.12, blue: 0.46, alpha: 1),
                      CGColor(red: 0.85, green: 0.36, blue: 0.32, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.6, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W * 0.35, y: H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.06))
        ctx.setLineWidth(1)
        var x = 0.0
        while x < W { ctx.move(to: CGPoint(x: x, y: 32)); ctx.addLine(to: CGPoint(x: x, y: H)); x += 108 }
        var y = 32.0
        while y < H { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)); y += 108 }
        ctx.strokePath()

        // Menu bar
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: 32))
        text(ctx, "Nano      File      Edit      View      Window      Help", x: 22, y: 22, size: 14, weight: .medium, color: .white)

        // Corner markers (to check nothing is cropped)
        ctx.setFillColor(CGColor(red: 0.3, green: 1, blue: 0.5, alpha: 1))
        for (cx, cy) in [(0.0, 32.0), (W - 14, 32.0), (0.0, H - 14), (W - 14, H - 14)] {
            ctx.fill(CGRect(x: cx, y: cy, width: 14, height: 14))
        }

        // Card
        let card = CGRect(x: 356, y: 150, width: 800, height: 700)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(CGPath(roundedRect: card, cornerWidth: 26, cornerHeight: 26, transform: nil))
        ctx.fillPath()
        text(ctx, "Duo Mac", x: 386, y: 232, size: 64, weight: .bold, color: .white)
        text(ctx, "Test pattern — if you can read this, streaming works.", x: 388, y: 284, size: 22, weight: .regular,
             color: CGColor(gray: 1, alpha: 0.75))
        text(ctx, "Move the pointer, tap to click, two fingers to scroll, type below.", x: 388, y: 318, size: 18,
             weight: .regular, color: CGColor(gray: 1, alpha: 0.55))
        // Fine detail to judge sharpness
        for i in 0..<40 {
            let xx = 388 + Double(i) * 6
            ctx.setFillColor(CGColor(gray: 1, alpha: i % 2 == 0 ? 0.9 : 0.15))
            ctx.fill(CGRect(x: xx, y: 350, width: 3, height: 40))
        }
        let swatches: [CGColor] = [CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1), CGColor(red: 1, green: 0.8, blue: 0, alpha: 1),
                                   CGColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 1), CGColor(red: 0, green: 0.48, blue: 1, alpha: 1),
                                   CGColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)]
        for (i, c) in swatches.enumerated() {
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: 650 + Double(i) * 56, y: 350, width: 44, height: 40))
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 376, y: 530, width: 760, height: 60), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        text(ctx, "Typed", x: 388, y: 518, size: 14, weight: .semibold, color: CGColor(gray: 1, alpha: 0.5))
        text(ctx, "Input events", x: 388, y: 636, size: 14, weight: .semibold, color: CGColor(gray: 1, alpha: 0.5))
        return ctx.makeImage()
    }

    private func drawArrow(_ ctx: CGContext, at p: CGPoint) {
        let pts: [(Double, Double)] = [(0, 0), (0, 17), (4.2, 13.2), (7, 19.6), (9.6, 18.5), (6.9, 12.3), (12.4, 12.3)]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p.x + pts[0].0 * 1.4, y: p.y + pts[0].1 * 1.4))
        for (x, y) in pts.dropFirst() { path.addLine(to: CGPoint(x: p.x + x * 1.4, y: p.y + y * 1.4)) }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(.black)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(1.6)
        ctx.strokePath()
    }

    private enum Weight { case regular, medium, semibold, bold }

    private func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: Weight,
                      color: CGColor, mono: Bool = false) {
        let type: CTFontUIFontType = mono ? .userFixedPitch : (weight == .bold || weight == .semibold ? .emphasizedSystem : .system)
        guard let font = CTFontCreateUIFontForLanguage(type, size, nil) else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
