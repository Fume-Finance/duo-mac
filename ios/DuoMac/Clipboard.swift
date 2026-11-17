import UIKit

/// The iPhone's half of clipboard sync (helper/…/Clipboard.swift): sets what the Mac copied, and
/// hands the page what was copied here (when the app comes back to the front, or while it's open).
/// Reading another app's copy shows iOS's paste prompt unless Settings › Duo Mac › Paste from Other
/// Apps is set to Allow.
final class ClipboardWatch {
    var onCopy: (([String: Any]) -> Void)?
    private var watching = false
    private var seen = UIPasteboard.general.changeCount
    private var timer: Timer?

    func setWatching(_ on: Bool) {
        watching = on
        timer?.invalidate()
        timer = nil
        guard on else { return }
        seen = UIPasteboard.general.changeCount // what's there already isn't news
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.check() }
    }

    /// The Mac copied something: put it on this clipboard (not sent back).
    func set(text: String?, image: Data?) {
        let pb = UIPasteboard.general
        if let text { pb.string = text } else if let image, let img = UIImage(data: image) { pb.image = img } else { return }
        seen = pb.changeCount
    }

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
