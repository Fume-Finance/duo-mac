import AppKit
import ScreenCaptureKit

/// The phone's Screenshot button: a part of the screen it's showing (or all of it), captured at full
/// resolution and put on the Mac's clipboard (and from there on the iPhone's, with the shared clipboard).
enum Screenshot {
    /// rect: normalized (0…1) within the display. done: ok, on any thread.
    static func capture(display: DisplayInfo, rect: CGRect, done: @escaping (Bool) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let d = content.displays.first(where: { $0.displayID == display.displayID }) else { return done(false) }
                let pts = CGRect(x: rect.minX * CGFloat(d.width), y: rect.minY * CGFloat(d.height),
                                 width: max(1, rect.width * CGFloat(d.width)), height: max(1, rect.height * CGFloat(d.height)))
                let scale = display.bounds.width > 0 ? display.pixelSize.width / display.bounds.width : 2
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = pts
                cfg.width = Int(pts.width * scale)
                cfg.height = Int(pts.height * scale)
                cfg.showsCursor = false
                cfg.captureResolution = .best
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingWindows: []),
                                                                       configuration: cfg)
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([NSImage(cgImage: image, size: NSSize(width: pts.width, height: pts.height))])
                }
                Log.info("Screenshot from the iPhone: \(Int(pts.width))×\(Int(pts.height)) pt, on the clipboard")
                done(true)
            } catch {
                Log.warn("Screenshot failed: \(error.localizedDescription)")
                done(false)
            }
        }
    }
}
