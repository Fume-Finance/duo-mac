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
    /// Refresh rate to ask for: 120 when the phone shows 120 frames a second (the iPhone app), else 60.
    var hz = 60
    private var appliedHz = 0
    private(set) var mirrored: [CGDirectDisplayID] = []
    private var serial: UInt32 = 1

    var displayID: CGDirectDisplayID? { display?.displayID }
    var isActive: Bool { display != nil }

    /// Whether the display got its sharp 2× mode (otherwise everything looks half size).
    private(set) var isRetina = false

    /// macOS took too long over the last setup: a sign the window server is in trouble.
    private(set) var stalled = false
    private var setupStarted = Date()

    /// The heights this display offers for its width: every shape the phone has asked for (upright, sideways,
    /// folded…), so turning or folding it is a mode switch (0.4 s, capture carries on) instead of a new display
    /// (about 2 s, and capture starting over).
    private var shapes: [Int] = []
    private var appliedRate = 60

    /// Shapes seen before, per width and refresh rate, newest first (kept across launches).
    private static let shapesKey = "nanoShapes"
    private static func remember(width w: Int, height h: Int, hz: Int) -> [Int] {
        var all = UserDefaults.standard.dictionary(forKey: shapesKey) ?? [:]
        var list = (all["\(w)@\(hz)"] as? [Int]) ?? []
        list.removeAll { $0 == h }
        list.insert(h, at: 0)
        list = Array(list.prefix(6))
        all["\(w)@\(hz)"] = list
        UserDefaults.standard.set(all, forKey: shapesKey)
        return list
    }

    /// Creates the display if needed and sets its size in points (rendered at 2×, Retina).
    /// Returns the display ID, or nil if macOS refused.
    func ensure(width w: Int, height h: Int) -> CGDirectDisplayID? {
        setupStarted = Date()
        stalled = false
        let heights = NanoDisplay.remember(width: w, height: h, hz: hz)
        // Replacing an existing display's modes often leaves it stuck in 1× mode (macOS refuses the Retina mode,
        // error 1001), but switching between modes it was made with works. So a shape it already offers is a mode
        // switch; another width, refresh rate or a new shape needs a fresh display, made with all known shapes.
        if display != nil, let p = points, p.w != w || appliedHz != hz || !shapes.contains(h) {
            stopMirroring()
            display = nil
            points = nil
            serial = serial % 4 + 1 // the old one may linger a moment: don't collide with it
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
            // A Duo display left by an earlier run (macOS doesn't always remove it while the Mac is
            // locked with the lid closed) blocks a new one with the same serial: try the others.
            var made: CGVirtualDisplay?
            for k in 0..<4 {
                let n = UInt32((Int(serial) - 1 + k) % 4 + 1)
                d.serialNum = n
                if let v = CGVirtualDisplay(descriptor: d), v.displayID != 0 {
                    if k > 0 { Log.info("Duo display: serial \(serial) was taken, using \(n)") }
                    serial = n
                    made = v
                    break
                }
            }
            guard let v = made else {
                Log.warn("Couldn't create the Duo display")
                return nil
            }
            display = v
            points = nil
            Log.info("Duo display created (id \(v.displayID))")
            // Its modes, once: every known shape, Retina (2×) and 1×.
            func settings(_ rate: Int) -> CGVirtualDisplaySettings {
                let s = CGVirtualDisplaySettings()
                s.hiDPI = 1
                s.modes = heights.flatMap { hh in [
                    CGVirtualDisplayMode(width: UInt(w * 2), height: UInt(hh * 2), refreshRate: Double(rate)),
                    CGVirtualDisplayMode(width: UInt(w), height: UInt(hh), refreshRate: Double(rate)),
                ] }
                return s
            }
            var rate = hz
            if !v.apply(settings(rate)) {
                guard rate != 60, v.apply(settings(60)) else {
                    Log.warn("The Duo display rejected \(w)×\(h)")
                    display = nil
                    return nil
                }
                Log.warn("The Duo display rejected \(rate) Hz: 60 Hz instead")
                rate = 60
            }
            appliedHz = hz // what was asked (so a refusal isn't retried each time)
            appliedRate = rate
            shapes = heights
        }
        guard let v = display else { return nil }
        if points?.w != w || points?.h != h {
            // Changing the mode of a display that's being mirrored fails (error 1001):
            // stop mirroring first; the caller mirrors again afterwards.
            stopMirroring()
            let switching = points != nil
            points = (w, h)
            isRetina = selectRetinaMode(v.displayID, w, h)
            Log.info("Duo display \(switching ? "switched" : "set") to \(w)×\(h) pt at \(appliedRate) Hz")
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
                    // Each refused switch can hang for 10 s: stop once setting up has taken over 5 s.
                    if checkStalled() { return false }
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
        // Not a screen that's switched off (the built-in one with the lid closed): mirroring it hangs
        // for 10 s and fails, and there's nothing to see on it anyway.
        let lidClosed = NanoCore.lidClosed()
        let targets = ids.prefix(Int(count)).filter {
            $0 != v.displayID && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay
                && CGDisplayIsAsleep($0) == 0 && !(lidClosed && CGDisplayIsBuiltin($0) != 0)
        }
        guard !targets.isEmpty else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        for t in targets { CGConfigureDisplayMirrorOfDisplay(cfg, t, v.displayID) }
        let r = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
        checkStalled()
        if r == .success {
            mirrored = Array(targets)
            Log.info("Display\(targets.count > 1 ? "s" : "") \(targets.map(String.init).joined(separator: ", ")) now mirror the Duo display")
        } else {
            Log.warn("Couldn't mirror the Mac's screens to the Duo display (\(r.rawValue))")
        }
    }

    /// With the lid closed the built-in screen can't mirror anything, and the lock screen and menu bar
    /// stay on it, out of sight: put the Duo display where the main screen goes (origin 0,0) instead.
    func makeMain() {
        guard let v = display, CGMainDisplayID() != v.displayID else { return }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success else { return }
        CGConfigureDisplayOrigin(cfg, v.displayID, 0, 0)
        let r = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
        checkStalled()
        if r == .success, CGMainDisplayID() == v.displayID {
            Log.info("The Duo display is now the main screen")
        } else {
            Log.warn("Couldn't make the Duo display the main screen (\(r.rawValue), main is \(CGMainDisplayID()))")
        }
    }

    /// Setting up has taken over 5 s since `ensure` began.
    @discardableResult
    private func checkStalled() -> Bool {
        if Date().timeIntervalSince(setupStarted) > 5 { stalled = true }
        return stalled
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
