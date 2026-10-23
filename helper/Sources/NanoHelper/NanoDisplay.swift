import AppKit
import CoreGraphics
import CGVirtualDisplayPrivate

/// The "Duo display": a virtual display shaped exactly like the phone's screen half.
/// The Mac's screens all mirror it, so the phone shows the whole desktop edge to edge
/// (and the Mac's own screens show the same desktop, letterboxed).
///
/// Display changes use `.forAppOnly`, and the virtual display belongs to this process,
/// so everything reverts by itself if the helper quits or crashes. Main thread only.
final class NanoDisplay {
    private var display: CGVirtualDisplay?
    private(set) var points: (w: Int, h: Int)?
    private(set) var mirrored: [CGDirectDisplayID] = []
    private var serial: UInt32 = 1

    var displayID: CGDirectDisplayID? { display?.displayID }
    var isActive: Bool { display != nil }

    /// Whether the display got its sharp 2× mode (otherwise everything looks half size).
    private(set) var isRetina = false

    /// Creates the display if needed and sets its size in points (rendered at 2×, Retina).
    /// Returns the display ID, or nil if macOS refused.
    func ensure(width w: Int, height h: Int) -> CGDirectDisplayID? {
        // Switching an existing display to a new size often leaves it stuck in 1× mode (macOS refuses
        // the Retina mode, error 1001). A fresh display gets its Retina mode reliably, so replace it.
        if display != nil, let p = points, p.w != w || p.h != h {
            stopMirroring()
            display = nil
            points = nil
            serial = serial == 1 ? 2 : 1 // the old one may linger a moment: don't collide with it
        }
        if display == nil {
            let d = CGVirtualDisplayDescriptor()
            d.setDispatchQueue(DispatchQueue.main)
            d.name = "Duo Mac"
            d.maxPixelsWide = 4096
            d.maxPixelsHigh = 4096
            d.sizeInMillimeters = CGSize(width: 300, height: 200)
            d.vendorID = 0x4E41  // stable IDs: macOS remembers the arrangement for this display
            d.productID = 0x4E4F
            d.serialNum = serial
            guard let v = CGVirtualDisplay(descriptor: d), v.displayID != 0 else {
                Log.warn("Couldn't create the Duo display")
                return nil
            }
            display = v
            points = nil
            Log.info("Duo display created (id \(v.displayID))")
        }
        guard let v = display else { return nil }
        if points?.w != w || points?.h != h {
            // Changing the mode of a display that's being mirrored fails (error 1001):
            // stop mirroring first; the caller mirrors again afterwards.
            stopMirroring()
            let s = CGVirtualDisplaySettings()
            s.hiDPI = 1
            s.modes = [
                CGVirtualDisplayMode(width: UInt(w * 2), height: UInt(h * 2), refreshRate: 60),
                CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60),
            ]
            guard v.apply(s) else {
                Log.warn("The Duo display rejected \(w)×\(h)")
                return nil
            }
            points = (w, h)
            isRetina = selectRetinaMode(v.displayID, w, h)
            Log.info("Duo display set to \(w)×\(h) pt")
        }
        return v.displayID
    }

    /// Prefers the HiDPI ("looks like w×h", 2× pixels) mode over the 1× one.
    @discardableResult
    private func selectRetinaMode(_ id: CGDirectDisplayID, _ w: Int, _ h: Int) -> Bool {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        for _ in 0..<20 {
            let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
            // macOS only offers a Retina variant above a minimum size; below it there's nothing to pick.
            if !modes.isEmpty, !modes.contains(where: { $0.width == w * 2 || $0.width == w }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                continue
            }
            if let m = modes.first(where: { $0.width == w && $0.height == h && $0.pixelWidth == w * 2 }) {
                if let cur = CGDisplayCopyDisplayMode(id), cur.width == m.width, cur.pixelWidth == m.pixelWidth { return true }
                // Right after new modes are applied the switch is sometimes refused: retry a few times.
                for attempt in 1...4 {
                    var cfg: CGDisplayConfigRef?
                    guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
                    CGConfigureDisplayWithDisplayMode(cfg, id, m, nil)
                    let r = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
                    if r == .success { return true }
                    Log.warn("Couldn't switch the Duo display mode (\(r.rawValue)), attempt \(attempt)")
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                }
                return false
            }
            if modes.contains(where: { $0.width == w * 2 }) {
                Log.info("macOS offers no Retina mode at \(w)×\(h)")
                return false
            }
            // The new modes can take a moment to show up.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        Log.warn("No \(w)×\(h) mode on the Duo display")
        return false
    }

    /// Makes every other screen of the Mac (built-in and external) mirror the Duo display, so there is
    /// one desktop: no windows or pointer can end up on a screen the phone doesn't show.
    func mirrorAllDisplays() {
        guard let v = display, mirrored.isEmpty else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let targets = ids.prefix(Int(count)).filter { $0 != v.displayID && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        guard !targets.isEmpty else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for t in targets { CGConfigureDisplayMirrorOfDisplay(cfg, t, v.displayID) }
        let r = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
        if r == .success {
            mirrored = Array(targets)
            Log.info("Display\(targets.count > 1 ? "s" : "") \(targets.map(String.init).joined(separator: ", ")) now mirror the Duo display")
        } else {
            Log.warn("Couldn't mirror the Mac's screens to the Duo display (\(r.rawValue))")
        }
    }

    private func stopMirroring() {
        guard !mirrored.isEmpty else { return }
        let list = mirrored
        mirrored = []
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for m in list { CGConfigureDisplayMirrorOfDisplay(cfg, m, kCGNullDirectDisplay) }
        CGCompleteDisplayConfiguration(cfg, .forAppOnly)
    }

    /// Back to normal: stop mirroring and remove the virtual display.
    func destroy() {
        guard display != nil else { return }
        stopMirroring()
        display = nil // releasing it removes the display
        points = nil
        Log.info("Duo display removed")
    }
}
