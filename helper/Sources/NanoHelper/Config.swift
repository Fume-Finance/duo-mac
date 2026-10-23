import Foundation
import Security

/// Settings that survive restarts.
struct NanoConfig: Codable {
    /// In the QR code. It only lets a phone *ask* to pair: every new phone must still be allowed
    /// on the Mac, and then unlocks with a passkey (or its PIN) each time.
    var pairCode: String
    var port: UInt16 = 8890
    var keepAwake: Bool = true
    /// Master switch: off = the Mac answers no phone at all (Tailscale stops serving it too).
    var allowConnections: Bool = true
    /// Keep the Mac from sleeping while the app runs, so it can be reached from outside.
    var stayReachable: Bool = false

    init(pairCode: String) { self.pairCode = pairCode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairCode = try c.decodeIfPresent(String.self, forKey: .pairCode) ?? ConfigStore.newPairCode()
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 8890
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
        allowConnections = try c.decodeIfPresent(Bool.self, forKey: .allowConnections) ?? true
        stayReachable = try c.decodeIfPresent(Bool.self, forKey: .stayReachable) ?? false
    }
}

final class ConfigStore {
    let dir: URL
    var file: URL { dir.appendingPathComponent("config.json") }

    init(dir: String?) {
        if let dir {
            self.dir = URL(fileURLWithPath: dir)
        } else {
            self.dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Duo Mac")
        }
    }

    func load() -> NanoConfig {
        if let data = try? Data(contentsOf: file),
           let c = try? JSONDecoder().decode(NanoConfig.self, from: data),
           c.pairCode.count == 8 {
            save(c) // drops keys from older versions (the old shared link key)
            return c
        }
        let c = NanoConfig(pairCode: ConfigStore.newPairCode())
        save(c)
        return c
    }

    func save(_ c: NanoConfig) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(c) {
            try? d.write(to: file, options: .atomic)
            chmod(file.path, 0o600)
        }
    }

    /// 8 characters without look-alikes (≈40 bits), shown as ABCD-EFGH.
    static func newPairCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        return String(Crypto.randomBytes(8).map { alphabet[Int($0) % alphabet.count] })
    }

    static func formatted(_ code: String) -> String {
        code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code
    }
}

enum Crypto {
    static func randomBytes(_ n: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &bytes) != errSecSuccess {
            bytes = (0..<n).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes
    }

    static func randomToken(_ n: Int = 32) -> String { Data(randomBytes(n)).base64URL }

    /// Compares secrets in constant time.
    static func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
