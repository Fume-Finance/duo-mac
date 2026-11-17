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
    var onCopy: (([String: Any]) -> Void)?
    private var watching = false
    private var timer: Timer?
    /// The clipboard's change count last sent or set (kept across launches): anything copied since,
    /// even with the app closed or the Mac not connected, is sent once the Mac is there.
    private var seen: Int {
        get { UserDefaults.standard.object(forKey: "clipSeen") as? Int ?? UIPasteboard.general.changeCount }
        set { UserDefaults.standard.set(newValue, forKey: "clipSeen") }
    }

    func setWatching(_ on: Bool) {
        watching = on
        timer?.invalidate()
        timer = nil
        guard on else { return }
        if UserDefaults.standard.object(forKey: "clipSeen") == nil { seen = UIPasteboard.general.changeCount }
        check() // copied while away
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
        guard watching, pb.changeCount != seen else { return }
        seen = pb.changeCount
        if pb.hasStrings, let s = pb.string, !s.isEmpty, s.utf8.count <= 1_000_000 {
            onCopy?(["text": s])
        } else if pb.hasImages, let img = pb.image, let png = img.pngData(), png.count <= 8_000_000 {
            onCopy?(["img": png.base64EncodedString()])
        }
    }
}
