import UIKit
import UniformTypeIdentifiers

/// The iPhone's half of clipboard sync (helper/…/Clipboard.swift): sets what the Mac copied, and
/// hands the page what was copied here. Copying on the iPhone happens in other apps, so it's checked
/// when Duo Mac comes back to the front, not while it's open: a change then is Universal Clipboard
/// bringing over the Mac's (reading it would make iOS fetch it from the Mac and send it back). What's
/// set here from the Mac is local to the iPhone, so Universal Clipboard doesn't echo it to the Mac.
/// Reading another app's copy shows iOS's paste prompt unless Settings › Duo Mac › Paste from Other
/// Apps is set to Allow.
final class ClipboardWatch {
    /// Hands a copy to the page, which answers whether it really went to the Mac (main thread).
    var onCopy: (([String: Any], @escaping (Bool) -> Void) -> Void)?
    private var watching = false
    /// A copy on its way to the page (one at a time).
    private var sending = false
    /// The clipboard's change count last sent or set (kept across launches): anything copied since,
    /// even with the app closed or the Mac not connected, is sent once the Mac is there.
    private var seen: Int {
        get { UserDefaults.standard.object(forKey: "clipSeen") as? Int ?? UIPasteboard.general.changeCount }
        set { UserDefaults.standard.set(newValue, forKey: "clipSeen") }
    }

    func setWatching(_ on: Bool) {
        watching = on
        guard on else { return }
        if UserDefaults.standard.object(forKey: "clipSeen") == nil { seen = UIPasteboard.general.changeCount }
        check() // copied while away, or not sent before (the page turns this on again once it reconnects)
    }

    /// The Mac copied something: put it on this clipboard (not sent back).
    func set(text: String?, image: Data?) {
        let pb = UIPasteboard.general
        let local: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if let text {
            pb.setItems([[UTType.utf8PlainText.identifier: text]], options: local)
        } else if let image, UIImage(data: image) != nil {
            pb.setItems([[UTType.png.identifier: image]], options: local)
        } else { return }
        seen = pb.changeCount
    }

    /// The app is open again: anything new was copied in another app meanwhile.
    func appCameBack() { check() }

    /// main thread: something new on this clipboard? (changeCount reads without a prompt.)
    func check() {
        let pb = UIPasteboard.general
        let count = pb.changeCount, before = seen
        guard watching, !sending, count != before else { return }
        // Seen once it's dealt with, but not over a copy from the Mac set meanwhile (that isn't sent back).
        let handled = { if self.seen == before { self.seen = count } }
        if pb.hasStrings, let s = pb.string, !s.isEmpty, s.utf8.count <= 1_000_000 {
            send(["text": s], then: handled)
        } else if pb.hasImages, let img = pb.image {
            sending = true
            // Its PNG off the main thread: a big screenshot takes a moment.
            DispatchQueue.global(qos: .userInitiated).async {
                let png = img.pngData().flatMap { $0.count <= 8_000_000 ? $0.base64EncodedString() : nil }
                DispatchQueue.main.async {
                    self.sending = false
                    if let png { self.send(["img": png], then: handled) } else { handled() } // too big to send
                }
            }
        } else {
            handled() // nothing it can send (or pasting wasn't allowed): not asked again
        }
    }

    /// `then` runs once the page says it really went to the Mac. Otherwise it stays unseen, and the
    /// next check offers it again (when the app comes back, or the page watches again after reconnecting).
    private func send(_ m: [String: Any], then sent: @escaping () -> Void) {
        guard let onCopy else { return }
        sending = true
        onCopy(m) { [weak self] ok in
            self?.sending = false
            if ok { sent() }
        }
    }
}
