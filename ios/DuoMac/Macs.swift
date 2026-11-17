import Foundation

/// The Macs this app connects to (each runs Duo Mac), and the one it opens. Each is a host on the
/// tailnet ("duo-mac.tail1234.ts.net"); every Mac's page keeps its own pairing and settings. The first
/// one is the Mac the app was built on (tools/ios-app.sh).
enum Macs {
    struct Mac: Codable, Equatable { var host: String; var name: String }

    private static let listKey = "macs", currentKey = "currentMac"

    static var builtIn: String? {
        (Bundle.main.object(forInfoDictionaryKey: "DuoMacURL") as? String).flatMap { URL(string: $0)?.host }
    }

    static var list: [Mac] {
        get {
            var l = (UserDefaults.standard.data(forKey: listKey)).flatMap { try? JSONDecoder().decode([Mac].self, from: $0) } ?? []
            if let b = builtIn, !l.contains(where: { $0.host == b }) { l.insert(Mac(host: b, name: ""), at: 0) }
            return l
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: listKey) }
    }

    static var current: String? {
        get {
            let c = UserDefaults.standard.string(forKey: currentKey)
            return c.flatMap { h in list.contains { $0.host == h } ? h : nil } ?? list.first?.host
        }
        set { UserDefaults.standard.set(newValue, forKey: currentKey) }
    }

    /// The tailnet's names (".tail1234.ts.net"): another Mac is added by its name there.
    static var suffix: String? {
        guard let b = builtIn, let dot = b.firstIndex(of: ".") else { return nil }
        return String(b[dot...])
    }

    /// "fabios-imac", "fabios-imac.tail1234.ts.net" or a pairing link → its host, if it's one we can reach.
    static func host(from input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let u = URL(string: s), let h = u.host { s = h }
        guard !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return nil }
        if !s.contains("."), let suffix { s += suffix }
        // Only names on this tailnet: the web view may only open those (its app-bound domain).
        if let suffix, !s.hasSuffix(suffix) { return nil }
        return s
    }

    @discardableResult
    static func add(_ host: String) -> Mac {
        var l = list
        if let m = l.first(where: { $0.host == host }) { return m }
        let m = Mac(host: host, name: "")
        l.append(m)
        list = l
        return m
    }

    static func remove(_ host: String) {
        list = list.filter { $0.host != host || $0.host == builtIn }
        if current == host { current = list.first?.host }
    }

    static func setName(_ name: String, for host: String) {
        list = list.map { $0.host == host ? Mac(host: $0.host, name: name) : $0 }
    }
}
