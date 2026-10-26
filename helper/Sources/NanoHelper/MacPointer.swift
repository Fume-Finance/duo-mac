import AppKit

// The pointer isn't in the video: the phone draws it itself (web/js/cursor.js), so it moves the
// moment your finger does instead of a network round trip later. The Mac tells it what the
// pointer looks like (MacPointer) and where it really is (PointerEcho), and the phone reconciles
// its prediction with that.

/// ~30 times a second, the pointer's real position (0…1 of the display) and the last phone move
/// applied to it (`q`), when either changed. Moves the phone made after `q` are still on their way;
/// the phone replays them on top. It also follows the pointer when it's moved at the Mac itself.
final class PointerEcho {
    private let injector: InputInjector
    private let send: ([String: Any]) -> Void
    private let lock = NSLock()
    private var seq: Int = 0
    private var last: (Double, Double, Int)?
    private var timer: DispatchSourceTimer?

    init(injector: InputInjector, send: @escaping ([String: Any]) -> Void) {
        self.injector = injector
        self.send = send
    }

    /// The phone's move `q` has been applied (any thread).
    func applied(_ q: Any?) {
        guard let q = (q as? NSNumber)?.intValue else { return }
        lock.lock(); seq = max(seq, q); lock.unlock()
    }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "nano.pointer"))
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let b = injector.bounds
        guard b.width > 0 else { return }
        let p = injector.pointerLocation()
        let x = Double(((p.x - b.minX) / b.width * 10000).rounded() / 10000)
        let y = Double(((p.y - b.minY) / b.height * 10000).rounded() / 10000)
        lock.lock(); let q = seq; lock.unlock()
        if let l = last, l.0 == x, l.1 == y, l.2 == q { return }
        last = (x, y, q)
        send(["t": "p", "x": x, "y": y, "q": q, "w": b.width, "h": b.height])
    }
}

/// What the pointer looks like (arrow, I-beam, hand, resize…), sent when it changes: a PNG at the
/// Mac's resolution, its size and hot spot in points. Checked ~15 times a second. main thread
final class MacPointer {
    private var timer: Timer?
    private var lastPNG: Data?
    private var send: (([String: Any]) -> Void)?

    func start(_ send: @escaping ([String: Any]) -> Void) {
        self.send = send
        lastPNG = nil
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in self?.check() }
        check()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        send = nil
    }

    private func check() {
        guard let cursor = NSCursor.currentSystem else { return }
        let image = cursor.image
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]), png != lastPNG else { return }
        lastPNG = png
        send?(["t": "cursor", "img": png.base64EncodedString(), "w": image.size.width, "h": image.size.height,
               "hx": cursor.hotSpot.x, "hy": cursor.hotSpot.y])
    }
}
