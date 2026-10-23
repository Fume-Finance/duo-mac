import Carbon
import Foundation

/// The Mac's active keyboard layout, so the phone can label its keys exactly like the real keyboard
/// (e.g. QWERTZ and è/é/à on Swiss French) and draw the ISO or ANSI shape.
struct KeymapInfo {
    let layoutName: String
    let iso: Bool
    /// keycode -> [plain, shift, option, shift+option]
    let labels: [UInt16: [String]]

    var json: [String: Any] {
        var l: [String: [String]] = [:]
        for (k, v) in labels { l[String(k)] = v }
        return ["layout": layoutName, "iso": iso, "labels": l]
    }

    func label(_ code: UInt16, shift: Bool, option: Bool) -> String {
        guard let row = labels[code] else { return "" }
        let i = (shift ? 1 : 0) + (option ? 2 : 0)
        return i < row.count ? row[i] : ""
    }
}

enum Keymap {
    /// Every key that produces a character (letters, digits, punctuation, ISO extra key).
    static let printable: [UInt16] = (0x00...0x2F).filter { $0 != 0x24 }.map { UInt16($0) } + [0x32]

    /// Main thread only (Text Input Sources API).
    static func current() -> KeymapInfo {
        let kbdType = LMGetKbdType()
        let iso = KBGetLayoutType(Int16(kbdType)) == PhysicalKeyboardLayoutType(kKeyboardISO)
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return KeymapInfo(layoutName: "Keyboard", iso: iso, labels: [:])
        }
        var name = "Keyboard"
        if let p = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) {
            name = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
        guard let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else {
            return KeymapInfo(layoutName: name, iso: iso, labels: [:])
        }
        let data = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else {
            return KeymapInfo(layoutName: name, iso: iso, labels: [:])
        }
        var labels: [UInt16: [String]] = [:]
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            for code in printable {
                var row: [String] = []
                // modifier state for UCKeyTranslate is (EventModifiers >> 8): shift = 2, option = 8
                for mods: UInt32 in [0, 2, 8, 10] {
                    var dead: UInt32 = 0
                    var len = 0
                    var chars = [UniChar](repeating: 0, count: 8)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), mods, UInt32(kbdType),
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &len, &chars)
                    var s = status == noErr ? String(utf16CodeUnits: chars, count: len) : ""
                    if let u = s.unicodeScalars.first, u.value < 0x20 || u.value == 0x7F { s = "" }
                    row.append(s)
                }
                labels[code] = row
            }
        }
        return KeymapInfo(layoutName: name, iso: iso, labels: labels)
    }
}
