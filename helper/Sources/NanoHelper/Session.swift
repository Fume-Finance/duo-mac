import Foundation
import CoreVideo
import CoreGraphics

enum Quality: String {
    case fast, balanced, sharp

    var jpegQuality: Double {
        switch self {
        case .fast: return 0.5
        case .balanced: return 0.7
        case .sharp: return 0.85
        }
    }

    /// Quality used to re-send regions once they stop changing, so still text looks crisp.
    var refineQuality: Double {
        switch self {
        case .fast: return 0.72
        case .balanced: return 0.9
        case .sharp: return 0.95
        }
    }

    var maxPixels: Double {
        switch self {
        case .fast: return 800_000
        case .balanced: return 2_000_000
        case .sharp: return 3_800_000
        }
    }
}

/// One connected phone: protocol handling, flow control and the frame pipeline.
///
/// Pipeline: capture thread copies each new frame into `pending`; the encode queue swaps it out,
/// diffs it against `reference` (what the phone already shows), JPEG-encodes only the changed
/// tiles and sends them. At most `maxInFlight` frames are unacknowledged, so on a slow network
/// we skip stale frames instead of building up lag.
final class Session {
    private static var counter = 0
    let id: Int
    let ws: WebSocketConnection
    unowned let core: NanoCore
    let peer: PeerInfo

    /// How far this connection got: paired device or not, unlocked or not (see Auth.swift).
    enum Stage {
        case anonymous
        case known(String)               // device key checked, waiting for passkey / PIN
        case waiting                     // asked to pair, waiting for Allow on the Mac
        case approved(PendingDevice)     // allowed, setting up passkey / PIN
        case authed(String)              // unlocked: may control the Mac
    }

    // net queue
    var clientName: String
    var stage: Stage = .anonymous
    var challenge: (bytes: [UInt8], at: Date)?
    private(set) var lastInputAt = Date()
    private var logsBeforeAuth = 0
    private(set) var quality: Quality = .balanced
    private(set) var box = CGSize(width: 1280, height: 800)
    /// The phone wants the Duo display (a virtual display shaped like its screen) and how roomy.
    private(set) var nanoOn = false
    private(set) var nanoSize = "default"   // large (bigger text) | default | more (more space)
    var nanoWaitingForUnlock = false
    private(set) var lastMessageAt = Date()

    // shared with the capture thread
    private let pendingLock = NSLock()
    private var pending: FrameBuffer?
    private var hasPending = false

    // encode queue
    private let encodeQueue = DispatchQueue(label: "nano.encode", qos: .userInteractive)
    private var working: FrameBuffer?
    private var reference: FrameBuffer?
    private var forceFull = true
    private var outstanding: [UInt32: (at: Date, bytes: Int)] = [:]   // sent, not yet acknowledged
    // Adapting to the network (mobile data, Tailscale relays): round trip measured from frame acks.
    private var srtt = 0.0                    // smoothed round trip, seconds
    private var minRtt = Double.infinity      // the link's own latency, without queueing
    private var qualityScale = 1.0            // JPEG quality is lowered while the link is congested
    private var lastAdapt = Date()
    /// Queues are building up (acks take much longer than the link's base latency).
    private var congested: Bool { srtt > minRtt * 2 + 0.08 }
    /// More frames in flight on a slow-but-clear link (fps ≈ frames in flight / round trip).
    private var maxInFlight: Int { srtt > 0.06 && !congested ? 4 : 2 }
    private var resynced = false              // already resynced during the current silence
    private var lastSendAt = Date.distantPast
    private var frameNo: UInt32 = 0
    private var ended = false
    private var statFrames = 0
    private var statBytes = 0
    private var statEncode = 0.0
    // Regions sent at normal quality that haven't been re-sent sharp yet.
    private var blurry: [IRect] = []
    private var refineGeneration = 0

    init(core: NanoCore, ws: WebSocketConnection, userAgent: String, peer: PeerInfo) {
        Session.counter += 1
        id = Session.counter
        self.core = core
        self.ws = ws
        self.peer = peer
        clientName = Session.deviceName(from: userAgent)
    }

    var isAuthed: Bool {
        if case .authed = stage { return true }
        return false
    }

    var deviceID: String? {
        switch stage {
        case .authed(let id), .known(let id): return id
        default: return nil
        }
    }

    static func deviceName(from ua: String) -> String {
        if ua.contains("iPhone") { return "iPhone" }
        if ua.contains("iPad") { return "iPad" }
        if ua.contains("Android") { return "Android phone" }
        if ua.contains("Macintosh") { return "Mac browser" }
        return "Browser"
    }

    func send(_ json: [String: Any]) { ws.send(json: json) }

    /// Another device took over: close with code 4001 so the phone doesn't fight back.
    func kick() {
        send(["t": "kicked"])
        ws.close(code: 4001)
    }

    func end() {
        encodeQueue.async {
            self.ended = true
            self.reference = nil
            self.working = nil
        }
        pendingLock.lock()
        pending = nil
        hasPending = false
        pendingLock.unlock()
    }

    // MARK: Messages from the phone (net queue)

    private static let authTypes: Set<String> = ["auth", "auth-passkey", "auth-pin", "pair", "passkey-begin",
                                                 "passkey-register", "pin-set", "pair-finish", "lock", "forget"]
    private static let inputTypes: Set<String> = ["m", "a", "b", "c", "s", "k", "txt", "aux", "act"]

    func handle(text: String) {
        lastMessageAt = Date()
        guard let data = text.data(using: .utf8),
              let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = m["t"] as? String else { return }
        switch t {
        case "ping":
            return send(["t": "pong", "ts": m["ts"] ?? 0])
        case "log":
            // A few lines before unlocking (pairing problems), unlimited after.
            if !isAuthed {
                logsBeforeAuth += 1
                guard logsBeforeAuth <= 20 else { return }
            }
            let msg = (m["msg"] as? String ?? "").prefix(800)
            return Log.info("📱 \(m["level"] as? String ?? "log"): \(msg)")
        case _ where Session.authTypes.contains(t):
            return core.auth.handle(t, m, from: self)
        case "prefs":
            if isAuthed { core.auth.savePrefs(m["v"], for: clientName) }
            return
        default:
            break
        }
        // Everything else needs an unlocked phone, and only the phone in control may send input
        // (another unlocked connection may be about to say hello and take over).
        guard isAuthed, core.isActive(self) || t == "hello" else { return }
        if Session.inputTypes.contains(t) { lastInputAt = Date() }
        let inj = core.injector
        switch t {
        case "m": inj.moveBy(dx: num(m["x"]), dy: num(m["y"]))
        case "a": inj.moveTo(nx: num(m["x"]), ny: num(m["y"]))
        case "b": inj.button(int(m["b"]), down: int(m["d"]) == 1, clicks: int(m["n"], 1), flags: Session.flags(int(m["mod"])))
        case "c": inj.click(int(m["b"]), clicks: int(m["n"], 1), flags: Session.flags(int(m["mod"])))
        case "s": inj.scroll(dx: num(m["x"]), dy: num(m["y"]))
        case "k": inj.key(UInt16(clamping: int(m["c"])), down: int(m["d"]) == 1, flags: Session.flags(int(m["mod"])), isRepeat: int(m["r"]) == 1)
        case "txt": if let s = m["s"] as? String, !s.isEmpty { inj.type(s) }
        case "aux": inj.aux(Int32(clamping: int(m["k"])), down: int(m["d"]) == 1)
        case "act": if let a = m["a"] as? String { inj.action(a) }
        case "rel": inj.releaseAll()
        case "hit":
            // Where the phone's finger just went down: is it a text field? (Screen only: the phone
            // shows its own keyboard.) Off the network queue: Accessibility can be slow.
            let id = m["id"] ?? 0, x = num(m["x"]), y = num(m["y"])
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let text = inj.isTextField(nx: x, ny: y)
                self?.send(["t": "hit", "id": id, "text": text])
            }
        case "ack": ack(UInt32(truncatingIfNeeded: int(m["f"])))
        case "hello":
            readBox(m["box"])
            if let q = (m["q"] as? String).flatMap(Quality.init(rawValue:)) { quality = q }
            readNano(m["nano"])
            core.startStreaming(for: self)
        case "nano":
            readNano(m)
            readBox(m["box"])
            core.startStreaming(for: self)
        case "resize":
            readBox(m["box"])
            core.reconfigure(self)
        case "quality":
            if let q = (m["q"] as? String).flatMap(Quality.init(rawValue:)) {
                quality = q
                core.reconfigure(self)
            }
        case "refresh": refresh()
        case "bye": core.endSession(self)
        case "display": core.switchDisplay(self, index: int(m["i"], -1))
        default:
            Log.debug("Unknown message \(t)")
        }
    }

    private func readNano(_ v: Any?) {
        guard let n = v as? [String: Any] else { return }
        nanoOn = (n["on"] as? Bool) ?? false
        if let size = n["size"] as? String, ["large", "default", "more"].contains(size) { nanoSize = size }
    }

    private func readBox(_ v: Any?) {
        guard let a = v as? [Any], a.count == 2 else { return }
        box = CGSize(width: max(240, num(a[0])), height: max(160, num(a[1])))
    }

    private func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    private func int(_ v: Any?, _ d: Int = 0) -> Int { (v as? NSNumber)?.intValue ?? d }

    static func flags(_ mask: Int) -> CGEventFlags {
        var f: CGEventFlags = []
        if mask & 1 != 0 { f.insert(.maskShift) }
        if mask & 2 != 0 { f.insert(.maskControl) }
        if mask & 4 != 0 { f.insert(.maskAlternate) }
        if mask & 8 != 0 { f.insert(.maskCommand) }
        return f
    }

    // MARK: Frames

    /// Capture thread.
    func ingest(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        pendingLock.lock()
        if pending == nil || pending!.width != w || pending!.height != h {
            pending = FrameBuffer(width: w, height: h)
        }
        pending!.copy(from: pb)
        hasPending = true
        pendingLock.unlock()
        encodeQueue.async { self.pump() }
    }

    private func ack(_ id: UInt32) {
        encodeQueue.async {
            if let o = self.outstanding.removeValue(forKey: id) {
                self.resynced = false
                self.measure(rtt: Date().timeIntervalSince(o.at))
            }
            self.pump()
        }
    }

    /// encode queue
    private func measure(rtt: Double) {
        srtt = srtt == 0 ? rtt : srtt * 0.8 + rtt * 0.2
        // Slowly forget the minimum, so a network change (Wi-Fi → 5G) is picked up.
        minRtt = min(minRtt == .infinity ? rtt : minRtt * 1.002, rtt)
        let now = Date()
        guard now.timeIntervalSince(lastAdapt) > 0.4 else { return }
        lastAdapt = now
        if congested {
            qualityScale = max(0.45, qualityScale * 0.85)
        } else if srtt < minRtt * 1.5 + 0.04 {
            qualityScale = min(1, qualityScale + 0.05)
        }
    }

    func refresh() {
        encodeQueue.async {
            self.forceFull = true
            self.pump()
        }
    }

    /// encode queue
    private func pump() {
        guard !ended else { return }
        if outstanding.count >= maxInFlight {
            // No acks for a while (lost message, busy phone): resync once, then wait for an ack
            // before trying again so a sleeping phone doesn't get buried in frames.
            // (On a slow link a frame can legitimately take a while: don't resend a big full frame too soon.)
            guard !resynced, Date().timeIntervalSince(lastSendAt) > max(2.5, srtt * 4) else { return }
            Log.debug("No frame acks for a while; resyncing")
            outstanding.removeAll()
            resynced = true
            forceFull = true
        }
        pendingLock.lock()
        let fresh = hasPending
        if fresh {
            swap(&pending, &working)
            hasPending = false
        }
        pendingLock.unlock()

        if fresh, let frame = working {
            encodeAndSend(frame)
            swap(&working, &reference)
        } else if forceFull, let ref = reference {
            encodeAndSend(ref)
        }
    }

    /// encode queue
    private func encodeAndSend(_ frame: FrameBuffer) {
        let w = frame.width, h = frame.height
        let full = forceFull || reference == nil || reference!.width != w || reference!.height != h || reference === frame
        var rects: [IRect]
        if full {
            rects = [IRect(x: 0, y: 0, w: w, h: h)]
        } else {
            rects = TileDiff.diff(frame, reference!)
            if rects.isEmpty { return }
            if rects.reduce(0, { $0 + $1.area }) > w * h * 55 / 100 {
                rects = [IRect(x: 0, y: 0, w: w, h: h)]
            }
        }
        forceFull = false
        if full { blurry = [IRect(x: 0, y: 0, w: w, h: h)] } else { addBlurry(rects) }
        send(frame: frame, rects: TileDiff.split(rects), quality: max(0.3, quality.jpegQuality * qualityScale), full: full)
        scheduleRefine()
    }

    private func addBlurry(_ rects: [IRect]) {
        blurry.append(contentsOf: rects)
        if blurry.count > 40 { blurry = TileDiff.merge(blurry) }
    }

    /// Once the screen has been still for a moment, re-send the recently changed areas at high quality.
    private func scheduleRefine(after delay: Double = 0.3) {
        refineGeneration += 1
        let gen = refineGeneration
        encodeQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.refineGeneration, !self.ended else { return }
            self.refine()
        }
    }

    /// encode queue
    private func refine() {
        guard !blurry.isEmpty, let ref = reference else { return }
        pendingLock.lock()
        let busy = hasPending
        pendingLock.unlock()
        if busy || !outstanding.isEmpty || congested {
            scheduleRefine(after: 0.2)
            return
        }
        let rects = TileDiff.merge(blurry)
        blurry = []
        let area = rects.reduce(0) { $0 + $1.area }
        let full = area > ref.width * ref.height * 6 / 10
        let todo = full ? [IRect(x: 0, y: 0, w: ref.width, h: ref.height)] : rects
        send(frame: ref, rects: TileDiff.split(todo), quality: quality.refineQuality, full: false)
    }

    /// encode queue: JPEG-encode `rects` of `frame` and send them as one message.
    private func send(frame: FrameBuffer, rects: [IRect], quality q: Double, full: Bool) {
        let w = frame.width, h = frame.height
        let t0 = Date()
        var payloads = [Data?](repeating: nil, count: rects.count)
        payloads.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: rects.count) { i in
                buf[i] = JPEGEncoder.encode(frame, rects[i], quality: q)
            }
        }
        statEncode += Date().timeIntervalSince(t0)

        var parts: [(IRect, Data)] = []
        for (r, p) in zip(rects, payloads) { if let p { parts.append((r, p)) } }
        guard parts.count == rects.count else {
            Log.warn("JPEG encoding failed; sending a full frame next")
            forceFull = true
            return
        }

        // Pointer position in stream pixels, so the phone can keep it in view when zoomed in.
        let bounds = core.injector.bounds
        let loc = core.injector.pointerLocation()
        var cx = UInt16.max, cy = UInt16.max
        if bounds.width > 0, bounds.contains(loc) {
            cx = UInt16(clamping: Int((loc.x - bounds.minX) / bounds.width * Double(w)))
            cy = UInt16(clamping: Int((loc.y - bounds.minY) / bounds.height * Double(h)))
        }

        frameNo &+= 1
        let total = parts.reduce(0) { $0 + $1.1.count }
        var msg = Data(capacity: 16 + parts.count * 12 + total)
        msg.append(1)                          // type: frame
        msg.append(full ? 1 : 0)               // flags: bit0 = full frame
        msg.appendLE(UInt16(parts.count))
        msg.appendLE(frameNo)
        msg.appendLE(UInt16(w))
        msg.appendLE(UInt16(h))
        msg.appendLE(cx)
        msg.appendLE(cy)
        for (r, p) in parts {
            msg.appendLE(UInt16(r.x)); msg.appendLE(UInt16(r.y))
            msg.appendLE(UInt16(r.w)); msg.appendLE(UInt16(r.h))
            msg.appendLE(UInt32(p.count))
        }
        for (_, p) in parts { msg.append(p) }
        ws.send(binary: msg)

        outstanding[frameNo] = (Date(), msg.count)
        lastSendAt = Date()
        statFrames += 1
        statBytes += msg.count
    }

    var outstandingCount: Int { encodeQueue.sync { outstanding.count } }

    /// Returns and resets counters (frames, bytes, seconds spent encoding), plus round trip and quality scale.
    func takeStats(_ done: @escaping (Int, Int, Double, Double, Double) -> Void) {
        encodeQueue.async {
            let s = (self.statFrames, self.statBytes, self.statEncode)
            self.statFrames = 0
            self.statBytes = 0
            self.statEncode = 0
            done(s.0, s.1, s.2, self.srtt, self.qualityScale)
        }
    }
}
