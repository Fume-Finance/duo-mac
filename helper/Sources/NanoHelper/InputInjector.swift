import AppKit
import CoreGraphics

/// Turns the phone's touches and key presses into real macOS mouse/keyboard events.
/// In dry-run mode nothing is posted; events are only recorded (and drawn by the test pattern).
final class InputInjector {
    let dryRun: Bool
    /// Bounds of the streamed display in global points. Input is clamped to it.
    var bounds: CGRect {
        get { lock.lock(); defer { lock.unlock() }; return _bounds }
        set { lock.lock(); _bounds = newValue; lock.unlock() }
    }
    /// Keymap lookup used to preview typing in dry-run mode: (keycode, shift, option) -> character.
    var label: ((UInt16, Bool, Bool) -> String)?

    private let source = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    private var _bounds: CGRect
    private var cursor: CGPoint
    private var lastPosted: CGPoint?
    private var lastPostAt = Date.distantPast
    private var buttons: Set<Int> = []
    private var keys: Set<UInt16> = []
    private var scrollRemainder = CGPoint.zero
    private var typed = ""
    private var events: [String] = []
    private var lastClick: (CGPoint, Date)?
    private var lastScrollLog = Date.distantPast

    static let arrowKeys: Set<UInt16> = [0x7B, 0x7C, 0x7D, 0x7E]
    // F1–F12, home/end/page up/page down/forward delete/help: real keyboards send these with the fn flag.
    static let functionKeys: Set<UInt16> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F,
                                            0x73, 0x77, 0x74, 0x79, 0x75, 0x72]

    init(dryRun: Bool, bounds: CGRect) {
        self.dryRun = dryRun
        _bounds = bounds
        cursor = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    struct Snapshot {
        var cursor: CGPoint
        var typed: String
        var events: [String]
        var lastClick: (CGPoint, Date)?
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(cursor: cursor, typed: typed, events: events, lastClick: lastClick)
    }

    /// Current pointer position in global points.
    func pointerLocation() -> CGPoint {
        lock.lock(); defer { lock.unlock() }
        return locationLocked()
    }

    private func locationLocked() -> CGPoint {
        if dryRun { return cursor }
        // Right after we post a move, the system still reports the old position for a moment,
        // so trust our own last position while we're actively driving the pointer. When idle,
        // read the real one (someone may have used the Mac's own trackpad).
        if let lp = lastPosted, Date().timeIntervalSince(lastPostAt) < 0.5 { return lp }
        return CGEvent(source: nil)?.location ?? cursor
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, _bounds.minX), _bounds.maxX - 1),
                y: min(max(p.y, _bounds.minY), _bounds.maxY - 1))
    }

    // MARK: Text fields

    /// Is there somewhere to type at this point of the screen (0…1 coordinates)? An Accessibility
    /// hit test, so the phone can bring up its own keyboard when you tap a text field.
    func isTextField(nx: Double, ny: Double) -> Bool {
        if dryRun { return false }
        let b = bounds
        return isTextField(at: CGPoint(x: b.minX + min(max(nx, 0), 1) * b.width, y: b.minY + min(max(ny, 0), 1) * b.height))
    }

    /// The same, under the Mac's pointer (a tap on the trackpad clicks there).
    func isTextFieldUnderPointer() -> Bool {
        if dryRun { return false }
        return isTextField(at: pointerLocation())
    }

    private func isTextField(at p: CGPoint) -> Bool {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.3)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &hit) == .success, var el = hit else { return false }
        for _ in 0..<3 {
            if InputInjector.isTextLike(el) { return true }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success,
                  let pa = parent, CFGetTypeID(pa) == AXUIElementGetTypeID() else { break }
            el = pa as! AXUIElement
        }
        return false
    }

    private static func isTextLike(_ el: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if let r = role as? String, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(r) { return true }
        // Web pages' editable areas: a settable text selection.
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, "AXSelectedTextRange" as CFString, &settable) == .success && settable.boolValue
    }

    // MARK: Pointer

    func moveBy(dx: Double, dy: Double) {
        lock.lock(); defer { lock.unlock() }
        let cur = locationLocked()
        let p = clamp(CGPoint(x: cur.x + dx, y: cur.y + dy))
        postMoveLocked(to: p, dx: dx, dy: dy)
    }

    func moveTo(nx: Double, ny: Double) {
        lock.lock(); defer { lock.unlock() }
        let p = clamp(CGPoint(x: _bounds.minX + min(max(nx, 0), 1) * _bounds.width,
                              y: _bounds.minY + min(max(ny, 0), 1) * _bounds.height))
        let cur = locationLocked()
        postMoveLocked(to: p, dx: p.x - cur.x, dy: p.y - cur.y)
    }

    private func postMoveLocked(to p: CGPoint, dx: Double, dy: Double) {
        cursor = p
        lastPosted = p
        lastPostAt = Date()
        if dryRun { return }
        let type: CGEventType
        let button: CGMouseButton
        if buttons.contains(0) {
            type = .leftMouseDragged; button = .left
        } else if buttons.contains(1) {
            type = .rightMouseDragged; button = .right
        } else if buttons.contains(2) {
            type = .otherMouseDragged; button = .center
        } else {
            type = .mouseMoved; button = .left
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.post(tap: .cghidEventTap)
    }

    func button(_ b: Int, down: Bool, clicks: Int, flags: CGEventFlags) {
        lock.lock(); defer { lock.unlock() }
        buttonLocked(b, down: down, clicks: clicks, flags: flags)
        record("\(["left", "right", "middle"][min(max(b, 0), 2)]) \(down ? "down" : "up")\(clicks > 1 ? " ×\(clicks)" : "")")
    }

    func click(_ b: Int, clicks: Int, flags: CGEventFlags) {
        lock.lock(); defer { lock.unlock() }
        buttonLocked(b, down: true, clicks: clicks, flags: flags)
        buttonLocked(b, down: false, clicks: clicks, flags: flags)
        let name = b == 1 ? "right-click" : clicks == 2 ? "double-click" : clicks >= 3 ? "triple-click" : "click"
        record("\(Self.describe(flags))\(name)")
    }

    private func buttonLocked(_ b: Int, down: Bool, clicks: Int, flags: CGEventFlags) {
        let p = locationLocked()
        if down {
            buttons.insert(b)
            lastClick = (p, Date())
        } else {
            buttons.remove(b)
        }
        if dryRun { return }
        let type: CGEventType
        let mb: CGMouseButton
        switch b {
        case 1: type = down ? .rightMouseDown : .rightMouseUp; mb = .right
        case 2: type = down ? .otherMouseDown : .otherMouseUp; mb = .center
        default: type = down ? .leftMouseDown : .leftMouseUp; mb = .left
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: mb) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clicks)))
        if b == 2 { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        e.flags = flags
        e.post(tap: .cghidEventTap)
        lastPosted = p
        lastPostAt = Date()
    }

    /// Pixel-precise ("continuous") scrolling, like a trackpad. Positive y scrolls up / reveals content above.
    func scroll(dx: Double, dy: Double) {
        lock.lock(); defer { lock.unlock() }
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let ix = Int32(scrollRemainder.x.rounded(.towardZero))
        let iy = Int32(scrollRemainder.y.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return }
        scrollRemainder.x -= Double(ix)
        scrollRemainder.y -= Double(iy)
        if Date().timeIntervalSince(lastScrollLog) > 0.25 {
            lastScrollLog = Date()
            record("scroll \(ix), \(iy)")
        }
        if dryRun { return }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        e.location = locationLocked()
        e.post(tap: .cghidEventTap)
    }

    // MARK: Pinch

    /// A trackpad pinch, as the Mac sees one: the app under the pointer zooms (a web page, a map, a
    /// photo), not the whole screen. There is no public API for trackpad gestures, so these are the
    /// gesture events a real trackpad sends, built from CGEvent's undocumented gesture fields (the
    /// recipe Hammerspoon and others use). phase: "b" began, "c" changed (by `amount`, e.g. 0.03 =
    /// 3% bigger), "e" ended.
    func magnify(phase: String, amount: Double) {
        lock.lock(); defer { lock.unlock() }
        if phase == "b" { record("pinch") }
        if dryRun { return }
        let at = locationLocked()
        func post(hid: Int64, phase p: Int64 = 0, zoom: Double = 0) {
            guard let e = CGEvent(source: source) else { return }
            e.type = Self.gestureType
            e.location = at
            e.setIntegerValueField(Self.gestureHIDType, value: hid)
            if hid == Self.hidZoom {
                e.setIntegerValueField(Self.gesturePhase, value: p)
                e.setDoubleValueField(Self.gestureZoom, value: zoom)
            }
            e.post(tap: .cghidEventTap)
        }
        switch phase {
        case "b":
            post(hid: Self.hidBeginGesture)
            post(hid: Self.hidZoom, phase: 1)
        case "c":
            post(hid: Self.hidZoom, phase: 2, zoom: max(-0.5, min(0.5, amount)))
        default:
            post(hid: Self.hidZoom, phase: 4)
            post(hid: Self.hidEndGesture)
        }
    }

    private static let gestureType = CGEventType(rawValue: 29)!               // NSEventTypeGesture
    private static let gestureHIDType = CGEventField(rawValue: 110)!          // kCGSEventGestureHIDType
    private static let gestureZoom = CGEventField(rawValue: 113)!             // kCGSEventGestureZoomValue
    private static let gesturePhase = CGEventField(rawValue: 132)!            // kCGSEventGesturePhase
    private static let hidZoom: Int64 = 8, hidBeginGesture: Int64 = 61, hidEndGesture: Int64 = 62

    // MARK: Keyboard

    func key(_ code: UInt16, down: Bool, flags: CGEventFlags, isRepeat: Bool) {
        lock.lock(); defer { lock.unlock() }
        keyLocked(code, down: down, flags: flags, isRepeat: isRepeat)
    }

    private func keyLocked(_ code: UInt16, down: Bool, flags: CGEventFlags, isRepeat: Bool) {
        if down { keys.insert(code) } else { keys.remove(code) }
        var f = flags
        if Self.arrowKeys.contains(code) {
            f.insert(.maskNumericPad)
            f.insert(.maskSecondaryFn)
        } else if Self.functionKeys.contains(code) {
            f.insert(.maskSecondaryFn)
        }
        if dryRun {
            if down { previewTyping(code, flags: flags) }
            return
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = f
        if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        e.post(tap: .cghidEventTap)
    }

    /// Types arbitrary text (from the iPhone's own keyboard: accents, emoji, dictation…).
    func type(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        if dryRun {
            typed += text
            trimTyped()
            record("text “\(text.prefix(24))”")
            return
        }
        for ch in text {
            if ch == "\n" || ch == "\r" {
                keyLocked(0x24, down: true, flags: [], isRepeat: false)
                keyLocked(0x24, down: false, flags: [], isRepeat: false)
                continue
            }
            if ch == "\t" {
                keyLocked(0x30, down: true, flags: [], isRepeat: false)
                keyLocked(0x30, down: false, flags: [], isRepeat: false)
                continue
            }
            var units = Array(String(ch).utf16)
            guard let d = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let u = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { continue }
            d.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            u.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            d.flags = []
            u.flags = []
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
        }
    }

    /// Media / brightness keys (NX_KEYTYPE_* codes), the same events the real top row sends.
    func aux(_ key: Int32, down: Bool) {
        lock.lock()
        record("media key \(key) \(down ? "down" : "up")")
        lock.unlock()
        if dryRun { return }
        DispatchQueue.main.async {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    func action(_ name: String) {
        lock.lock()
        record("action \(name)")
        lock.unlock()
        switch name {
        case "missionControl":
            if dryRun { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            }
        case "appExpose": combo(0x7D, .maskControl)
        case "spaceLeft": combo(0x7B, .maskControl)
        case "spaceRight": combo(0x7C, .maskControl)
        case "spotlight": combo(0x31, .maskCommand)
        default: break
        }
    }

    private func combo(_ code: UInt16, _ flags: CGEventFlags) {
        lock.lock(); defer { lock.unlock() }
        keyLocked(code, down: true, flags: flags, isRepeat: false)
        keyLocked(code, down: false, flags: flags, isRepeat: false)
    }

    /// Lets go of everything (on disconnect), so nothing stays stuck down on the Mac.
    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        for b in buttons { buttonLocked(b, down: false, clicks: 1, flags: []) }
        for k in keys { keyLocked(k, down: false, flags: [], isRepeat: false) }
        buttons.removeAll()
        keys.removeAll()
    }

    // MARK: Dry-run bookkeeping

    private func record(_ s: String) {
        events.append(s)
        if events.count > 7 { events.removeFirst(events.count - 7) }
        Log.debug("input: \(s)")
    }

    private func previewTyping(_ code: UInt16, flags: CGEventFlags) {
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            let ch = label?(code, false, false) ?? "?"
            record("shortcut \(Self.describe(flags))\(ch.uppercased())")
            return
        }
        switch code {
        case 0x33: if !typed.isEmpty { typed.removeLast() }
        case 0x24: typed += "⏎"
        case 0x31: typed += " "
        case 0x30: typed += "⇥"
        case 0x35: record("esc")
        case 0x7B, 0x7C, 0x7D, 0x7E: record("arrow \(["←", "→", "↓", "↑"][Int(code - 0x7B)])")
        default:
            if let s = label?(code, flags.contains(.maskShift), flags.contains(.maskAlternate)), !s.isEmpty {
                typed += s
            } else {
                record("key 0x\(String(code, radix: 16))")
            }
        }
        trimTyped()
    }

    private func trimTyped() {
        if typed.count > 48 { typed = String(typed.suffix(48)) }
    }

    static func describe(_ f: CGEventFlags) -> String {
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s
    }
}
