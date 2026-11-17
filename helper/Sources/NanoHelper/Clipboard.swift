import AppKit
import CryptoKit

// Copy on one, paste on the other: while the iPhone app is connected (and asked for it), what's
// copied on the Mac goes to the iPhone's clipboard, and what's copied on the iPhone comes here.
// Text and pictures. Universal Clipboard does the same when the two are near each other; this also
// works with the Mac far away. Something already sent either way isn't sent back (no ping-pong, also
// with Universal Clipboard copying the same thing across).
final class ClipboardSync {
    static let maxText = 1_000_000
    static let maxImage = 8_000_000

    /// main thread
    var enabled = false {
        didSet { if enabled && !oldValue { lastCount = NSPasteboard.general.changeCount } }
    }
    /// Sends a message to the phone (any thread).
    var send: (([String: Any]) -> Void)?
    private var lastCount = NSPasteboard.general.changeCount
    private var lastHash = ""

    /// main thread, a few times a second: the Mac's clipboard changed? Send it.
    func tick() {
        guard enabled else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        var m: [String: Any] = ["t": "clip"]
        let hash: String
        if let s = pb.string(forType: .string), !s.isEmpty {
            guard s.utf8.count <= Self.maxText else { return }
            m["text"] = s
            hash = Self.hash(Data(s.utf8))
        } else if let png = Self.png(from: pb) {
            guard png.count <= Self.maxImage else { return }
            m["img"] = png.base64EncodedString()
            hash = Self.hash(png)
        } else {
            return
        }
        guard hash != lastHash else { return }
        lastHash = hash
        Log.info("Clipboard → iPhone (\(m["text"] != nil ? "text" : "picture"))")
        send?(m)
    }

    /// main thread: the phone copied something.
    func apply(_ m: [String: Any]) {
        guard enabled else { return }
        let pb = NSPasteboard.general
        if let s = m["text"] as? String, !s.isEmpty, s.utf8.count <= Self.maxText {
            let h = Self.hash(Data(s.utf8))
            guard h != lastHash else { return }
            lastHash = h
            pb.clearContents()
            pb.setString(s, forType: .string)
            Log.info("Clipboard ← iPhone (text)")
        } else if let b = m["img"] as? String, let d = Data(base64Encoded: b), d.count <= Self.maxImage, let img = NSImage(data: d) {
            let h = Self.hash(d)
            guard h != lastHash else { return }
            lastHash = h
            pb.clearContents()
            pb.writeObjects([img])
            Log.info("Clipboard ← iPhone (picture)")
        } else {
            return
        }
        lastCount = pb.changeCount
    }

    private static func png(from pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}
