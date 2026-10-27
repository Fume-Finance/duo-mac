import CryptoKit
import Foundation
import Network
import Security
import SystemConfiguration

// Local mode: when the iPhone and the Mac are on the same Wi-Fi (or the Mac is on the iPhone's
// hotspot), the phone connects straight to the Mac instead of through Tailscale, which may route
// it through a relay far away (or not work at all: no internet, or where Tailscale is blocked).
//
// The phone's page needs a secure connection (H.264 decoding, Face ID and the microphone require
// one), so the Mac has its own small certificate authority, created once, and the iPhone trusts it
// through a profile. The authority can only vouch for local names (*.local) and private addresses
// (name constraints): even if its key leaked, it couldn't impersonate a real website. From it, the
// Mac gives itself a certificate for its local name and current addresses, renewed when they
// change.
//
// The local entrance is the same WebSocket as through Tailscale, with TLS, on port + 2, answering
// only devices on private networks and only Duo Mac's own page (its Tailscale address). There,
// paired iPhones can unlock (device key, then passkey or PIN, as usual); pairing a new one isn't
// possible (Session refuses it), since anyone on a shared Wi-Fi can reach that port.

final class LocalMode {
    let port: UInt16
    private let dir: URL
    private let queue = DispatchQueue(label: "nano.local")
    private var server: HTTPServer?
    private var monitor: NWPathMonitor?
    private var addresses: [String] = []
    private let lock = NSLock()
    private var _origin: String?
    private var _hosts: [String] = []
    var onWebSocket: ((WebSocketConnection, [String: String]) -> Void)?

    init(port: UInt16, configDir: URL) {
        self.port = port
        dir = configDir.appendingPathComponent("local", isDirectory: true)
    }

    /// The page allowed to connect: Duo Mac's own, at its Tailscale address (any thread).
    var origin: String? {
        get { lock.lock(); defer { lock.unlock() }; return _origin }
        set { lock.lock(); _origin = newValue; lock.unlock() }
    }

    /// What the phone needs to try the local route: where (name and addresses) and the port.
    var info: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return _hosts.isEmpty ? nil : ["port": Int(port), "hosts": _hosts]
    }

    static var hostName: String {
        (SCDynamicStoreCopyLocalHostName(nil) as String? ?? "Mac") + ".local"
    }

    func start() {
        queue.async {
            do { try self.ensureAuthority() } catch {
                Log.warn("Local mode: can't create the certificate authority (\(error.localizedDescription))")
                return
            }
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] _ in self?.queue.async { self?.refresh() } }
            m.start(queue: self.queue)
            self.monitor = m
            self.refresh()
        }
    }

    /// queue: (re)start the entrance with a certificate for the current addresses, if they changed.
    private func refresh(force: Bool = false) {
        let now = LocalMode.privateAddresses()
        guard force || now != addresses || server == nil else { return }
        addresses = now
        server?.stop()
        server = nil
        guard let identity = issue(name: LocalMode.hostName, ips: now) else { return }
        let s = HTTPServer(port: port, localhostOnly: false, webRoot: URL(fileURLWithPath: "/nonexistent"),
                           tls: identity, allowedOrigin: { [weak self] in self?.origin })
        s.onWebSocket = { [weak self] ws, headers in self?.onWebSocket?(ws, headers) }
        s.start()
        server = s
        lock.lock(); _hosts = [LocalMode.hostName] + now; lock.unlock()
        Log.info("Local mode: \(LocalMode.hostName) (\(now.joined(separator: ", "))) on port \(port)")
    }

    // MARK: The certificate authority

    private var caKey: URL { dir.appendingPathComponent("ca.key") }
    private var caCert: URL { dir.appendingPathComponent("ca.crt") }

    private func ensureAuthority() throws {
        if FileManager.default.fileExists(atPath: caKey.path), FileManager.default.fileExists(atPath: caCert.path) { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cnf = dir.appendingPathComponent("ca.cnf")
        try """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = Duo Mac (\(LocalMode.hostName))
        O = Duo Mac
        [ca]
        basicConstraints = critical, CA:TRUE, pathlen:0
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        nameConstraints = critical, permitted;DNS:local, permitted;IP:10.0.0.0/255.0.0.0, permitted;IP:172.16.0.0/255.240.0.0, permitted;IP:192.168.0.0/255.255.0.0, permitted;IP:169.254.0.0/255.255.0.0
        """.write(to: cnf, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: cnf) }
        try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", caKey.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
        try openssl(["req", "-x509", "-new", "-key", caKey.path, "-sha256", "-days", "3650", "-config", cnf.path,
                     "-extensions", "ca", "-out", caCert.path])
        Log.info("Local mode: created this Mac's certificate authority")
    }

    /// A fresh certificate for this Mac's local name and addresses (397 days, the most iOS accepts),
    /// loaded straight into memory (nothing goes into the keychain).
    private func issue(name: String, ips: [String]) -> sec_identity_t? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("duomac-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let cnf = tmp.appendingPathComponent("leaf.cnf"), key = tmp.appendingPathComponent("leaf.key")
            let csr = tmp.appendingPathComponent("leaf.csr"), crt = tmp.appendingPathComponent("leaf.crt")
            let p12 = tmp.appendingPathComponent("leaf.p12")
            let san = (["DNS:\(name)"] + ips.map { "IP:\($0)" }).joined(separator: ", ")
            try """
            [req]
            distinguished_name = dn
            prompt = no
            [dn]
            CN = \(name)
            [leaf]
            basicConstraints = critical, CA:FALSE
            keyUsage = critical, digitalSignature
            extendedKeyUsage = serverAuth
            subjectAltName = \(san)
            authorityKeyIdentifier = keyid
            """.write(to: cnf, atomically: true, encoding: .utf8)
            let pass = UUID().uuidString
            try openssl(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key.path])
            try openssl(["req", "-new", "-key", key.path, "-config", cnf.path, "-out", csr.path])
            try openssl(["x509", "-req", "-in", csr.path, "-CA", caCert.path, "-CAkey", caKey.path,
                         "-set_serial", String(UInt32.random(in: 1...UInt32.max)), "-sha256", "-days", "397",
                         "-extfile", cnf.path, "-extensions", "leaf", "-out", crt.path])
            try openssl(["pkcs12", "-export", "-inkey", key.path, "-in", crt.path, "-out", p12.path, "-passout", "pass:\(pass)",
                         "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"]) // what SecPKCS12Import reads; it never leaves memory
            var items: CFArray?
            // In memory only (macOS 15+): otherwise it would land in the login keychain each time.
            guard #available(macOS 15, *) else {
                Log.warn("Local mode needs macOS 15 or later")
                return nil
            }
            let opts = [kSecImportExportPassphrase: pass, kSecImportToMemoryOnly: true] as CFDictionary
            let status = SecPKCS12Import(try Data(contentsOf: p12) as CFData, opts, &items)
            guard status == errSecSuccess, let first = (items as? [[CFString: Any]])?.first,
                  let id = first[kSecImportItemIdentity] else {
                Log.warn("Local mode: can't load the certificate (\(status))")
                return nil
            }
            return sec_identity_create(id as! SecIdentity)
        } catch {
            Log.warn("Local mode: can't issue a certificate (\(error.localizedDescription))")
            return nil
        }
    }

    private func openssl(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "openssl", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "openssl \(args[0]): \(msg)"])
        }
    }

    // MARK: The iPhone's profile

    /// A configuration profile that makes the iPhone trust this Mac's authority (for local names only).
    func profile() -> Data? {
        guard let pem = try? String(contentsOf: caCert, encoding: .utf8) else { return nil }
        let b64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: b64) else { return nil }
        // Stable identifiers: installing it again replaces it instead of adding a copy.
        let h = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
        func uuid(_ salt: String) -> String {
            let x = Array(SHA256.hash(data: Data((h + salt).utf8)).map { String(format: "%02X", $0) }.joined().prefix(32))
            return "\(String(x[0..<8]))-\(String(x[8..<12]))-\(String(x[12..<16]))-\(String(x[16..<20]))-\(String(x[20..<32]))"
        }
        let name = LocalMode.hostName
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>PayloadCertificateFileName</key><string>duo-mac-local.cer</string>
                    <key>PayloadContent</key><data>\(der.base64EncodedString())</data>
                    <key>PayloadDescription</key><string>Duo Mac on \(name): valid for local network names and addresses only.</string>
                    <key>PayloadDisplayName</key><string>Duo Mac (\(name))</string>
                    <key>PayloadIdentifier</key><string>com.riccardoconti.duomac.local.\(h.prefix(12)).cert</string>
                    <key>PayloadType</key><string>com.apple.security.root</string>
                    <key>PayloadUUID</key><string>\(uuid("cert"))</string>
                    <key>PayloadVersion</key><integer>1</integer>
                </dict>
            </array>
            <key>PayloadDescription</key><string>Lets Duo Mac connect straight to \(name) when your iPhone and the Mac are on the same Wi-Fi or hotspot. It only covers local network names, never websites.</string>
            <key>PayloadDisplayName</key><string>Duo Mac: same Wi-Fi</string>
            <key>PayloadIdentifier</key><string>com.riccardoconti.duomac.local.\(h.prefix(12))</string>
            <key>PayloadType</key><string>Configuration</string>
            <key>PayloadUUID</key><string>\(uuid("profile"))</string>
            <key>PayloadVersion</key><integer>1</integer>
        </dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    // MARK: Addresses

    /// This Mac's private IPv4 addresses (Wi-Fi, Ethernet, the iPhone's hotspot), not Tailscale's.
    static func privateAddresses() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let i = p?.pointee {
            defer { p = i.ifa_next }
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), i.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if isPrivate(ip), !out.contains(ip) { out.append(ip) }
        }
        return out.sorted()
    }

    /// Is this caller on one of this Mac's own networks (the same Wi-Fi, Ethernet or hotspot),
    /// IPv4 or IPv6, or this Mac itself? Tailscale's interfaces don't count: that's not local.
    static func isOnLocalNetwork(_ ip: String) -> Bool {
        let host = ip.components(separatedBy: "%").first ?? ip
        guard let remote = bytes(host) else { return false }
        if host == "::1" || host.hasPrefix("127.") { return true }
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return false }
        defer { freeifaddrs(ifap) }
        var p = ifap
        while let i = p?.pointee {
            defer { p = i.ifa_next }
            let name = String(cString: i.ifa_name)
            guard !name.hasPrefix("utun"), i.ifa_flags & UInt32(IFF_UP) != 0, let a = i.ifa_addr, let m = i.ifa_netmask,
                  a.pointee.sa_family == UInt8(AF_INET) || a.pointee.sa_family == UInt8(AF_INET6) else { continue }
            guard let mine = bytes(numeric(a)), let mask = bytes(numeric(m)), mine.count == remote.count, mask.count == remote.count else { continue }
            if zip(zip(mine, remote), mask).allSatisfy({ ($0.0 & $1) == ($0.1 & $1) }) { return true }
        }
        return false
    }

    private static func numeric(_ sa: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = sa.pointee.sa_len > 0 ? socklen_t(sa.pointee.sa_len)
            : socklen_t(sa.pointee.sa_family == UInt8(AF_INET6) ? MemoryLayout<sockaddr_in6>.size : MemoryLayout<sockaddr_in>.size)
        guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
        return String(cString: host).components(separatedBy: "%").first ?? ""
    }

    private static func bytes(_ ip: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        if inet_pton(AF_INET6, ip, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    /// 10/8, 172.16/12, 192.168/16, 169.254/16 (IPv4); link-local and unique-local IPv6.
    static func isPrivate(_ ip: String) -> Bool {
        let h = ip.lowercased()
        if h.contains(":") { return h.hasPrefix("fe80") || h.hasPrefix("fc") || h.hasPrefix("fd") }
        let o = h.split(separator: ".").compactMap { Int($0) }
        guard o.count == 4 else { return false }
        return o[0] == 10 || (o[0] == 172 && (16...31).contains(o[1])) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
    }
}
