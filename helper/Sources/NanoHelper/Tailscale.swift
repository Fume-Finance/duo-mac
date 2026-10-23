import Foundation

/// Talks to the Tailscale app through its command-line tool: is it signed in, what is this Mac called
/// on the tailnet, and `tailscale serve`, which puts the helper (listening on this Mac only) behind
/// https://<mac>.<tailnet>.ts.net with a real certificate. Only devices on the user's tailnet can
/// reach that address, and the traffic is end-to-end encrypted.
final class Tailscale {
    enum Phase: Equatable {
        case notInstalled, notRunning, needsLogin, needsApproval, stopped, starting, needsHTTPS, ready
    }

    struct Status: Equatable {
        var phase: Phase = .starting
        var dnsName: String?        // macbook-pro.tail1234.ts.net
        var login: String?          // the account this Mac is signed in with
        var authURL: String?        // sign-in link while signed out
        var enableURL: String?      // one-click "enable HTTPS" link, from tailscale serve
        var phones: [String] = []   // iPhones / iPads on the tailnet
        var serving = false         // tailscale serve forwards the address to the helper
        var reachable = false       // a request through it came back
        var detail: String?

        var url: String? { dnsName.map { "https://\($0)" } }
    }

    static let cli: String? = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    private let queue = DispatchQueue(label: "nano.tailscale")
    private var lastEnableTry = Date.distantPast

    // MARK: Running the CLI

    struct Output {
        let code: Int32
        let text: String
        let timedOut: Bool
    }

    static func run(_ args: [String], timeout: TimeInterval = 8) -> Output? {
        guard let cli else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        // The App Store Tailscale binary acts as the CLI only when it looks like it was run from a
        // shell (SHLVL set); otherwise it tries to start its GUI and fails ("CLIError error 3"). An app
        // opened from Finder or relaunched has no SHLVL, so set it.
        var env = ProcessInfo.processInfo.environment
        env["SHLVL"] = env["SHLVL"] ?? "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        var outData = Data(), errData = Data()
        let reads = DispatchGroup()
        reads.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); reads.leave() }
        reads.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); reads.leave() }
        do { try p.run() } catch { return nil }
        var timedOut = false
        if reads.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()
            _ = reads.wait(timeout: .now() + 2)
        }
        p.waitUntilExit()
        let text = String(decoding: outData, as: UTF8.self) + String(decoding: errData, as: UTF8.self)
        return Output(code: p.terminationStatus, text: text, timedOut: timedOut)
    }

    // MARK: Status

    /// Blocking: call on `queue` (see `refresh`).
    private func check(port: UInt16, wantServe: Bool, previous: Status) -> Status {
        var st = Status()
        guard Tailscale.cli != nil else { st.phase = .notInstalled; return st }
        guard let r = Tailscale.run(["status", "--json"], timeout: 6), !r.timedOut,
              let json = try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any] else {
            st.phase = .notRunning
            return st
        }
        let state = json["BackendState"] as? String ?? ""
        switch state {
        case "NeedsLogin", "NoState":
            st.phase = .needsLogin
            st.authURL = (json["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return st
        case "NeedsMachineAuth": st.phase = .needsApproval; return st
        case "Stopped": st.phase = .stopped; return st
        case "Running": break
        default: st.phase = .starting; return st
        }

        let me = json["Self"] as? [String: Any] ?? [:]
        let dns = (me["DNSName"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        st.dnsName = dns.isEmpty ? nil : dns
        if let uid = me["UserID"] as? NSNumber, let users = json["User"] as? [String: Any],
           let u = users[uid.stringValue] as? [String: Any] {
            st.login = u["LoginName"] as? String
        }
        let peers = (json["Peer"] as? [String: Any] ?? [:]).values.compactMap { $0 as? [String: Any] }
        st.phones = peers.filter { ($0["OS"] as? String) == "iOS" }
            .map { Tailscale.prettyName(dnsName: $0["DNSName"] as? String, hostName: $0["HostName"] as? String) }
            .sorted()
        let tailnet = json["CurrentTailnet"] as? [String: Any]
        let magicDNS = tailnet?["MagicDNSEnabled"] as? Bool ?? false
        let certs = (json["CertDomains"] as? [String] ?? []).map { $0.lowercased() }
        st.enableURL = previous.enableURL

        guard let dnsName = st.dnsName, magicDNS, certs.contains(dnsName) else {
            st.phase = .needsHTTPS
            st.detail = magicDNS ? nil : "MagicDNS is off"
            // `tailscale serve` hands out a one-click link that turns HTTPS on for this Mac.
            if wantServe, st.enableURL == nil, Date().timeIntervalSince(lastEnableTry) > 60 {
                lastEnableTry = Date()
                st.enableURL = enableLink(port: port)
            }
            return st
        }
        st.enableURL = nil

        let target = "http://127.0.0.1:\(port)"
        let current = Tailscale.run(["serve", "status", "--json"], timeout: 5)?.text ?? ""
        if wantServe {
            if !current.contains(target) {
                let r = Tailscale.run(["serve", "--bg", "--yes", "--https=443", target], timeout: 15)
                if let r, !r.timedOut, r.code == 0 {
                    Log.info("Tailscale: serving https://\(dnsName) → \(target)")
                } else {
                    st.detail = r.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "tailscale serve failed"
                    if let link = Tailscale.firstURL(in: st.detail ?? "") { st.enableURL = link; st.phase = .needsHTTPS; return st }
                    Log.warn("Tailscale serve failed: \(st.detail ?? "")")
                }
            }
            st.serving = (Tailscale.run(["serve", "status", "--json"], timeout: 5)?.text ?? "").contains(target)
            st.reachable = st.serving && Tailscale.probe("https://\(dnsName)/healthz")
        } else if current.contains(target) {
            stopServing(port: port)
        }
        st.phase = .ready
        return st
    }

    private func enableLink(port: UInt16) -> String? {
        // Pointed at a dead port on purpose: if HTTPS happens to be on already, nothing is exposed yet.
        guard let r = Tailscale.run(["serve", "--bg", "--yes", "--https=443", "http://127.0.0.1:9"], timeout: 6) else { return nil }
        if !r.timedOut && r.code == 0 { _ = Tailscale.run(["serve", "--https=443", "off"], timeout: 5) }
        return Tailscale.firstURL(in: r.text)
    }

    static func firstURL(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace }).first { $0.hasPrefix("https://login.tailscale.com/") }.map(String.init)
    }

    /// One request through Tailscale Serve to our own /healthz (the first one also gets the certificate issued).
    static func probe(_ url: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: cfg)
        let done = DispatchSemaphore(value: 0)
        var ok = false
        session.dataTask(with: u) { data, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200 && data.map { String(decoding: $0, as: UTF8.self) } == "ok"
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 25)
        session.invalidateAndCancel()
        return ok
    }

    /// Checks (and fixes up serving) off the main thread; `done` runs on the main thread.
    func refresh(port: UInt16, wantServe: Bool, previous: Status, done: @escaping (Status) -> Void) {
        queue.async {
            let st = self.check(port: port, wantServe: wantServe, previous: previous)
            DispatchQueue.main.async { done(st) }
        }
    }

    func stopServing(port: UInt16, wait: Bool = false) {
        let work = {
            let target = "http://127.0.0.1:\(port)"
            guard (Tailscale.run(["serve", "status", "--json"], timeout: 4)?.text ?? "").contains(target) else { return }
            _ = Tailscale.run(["serve", "--https=443", "off"], timeout: 5)
            Log.info("Tailscale: stopped serving this Mac")
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// The tailnet's name for the device at `ip` ("iPhone 15 Pro"), delivered on `replyQueue`.
    func whois(_ ip: String, replyQueue: DispatchQueue, done: @escaping (String?) -> Void) {
        queue.async {
            var name: String?
            if let r = Tailscale.run(["whois", "--json", ip], timeout: 5), !r.timedOut,
               let json = try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any],
               let node = json["Node"] as? [String: Any] {
                name = Tailscale.prettyName(dnsName: node["Name"] as? String,
                                            hostName: (node["Hostinfo"] as? [String: Any])?["Hostname"] as? String)
            }
            replyQueue.async { done(name) }
        }
    }

    /// How traffic to `ip` flows: "direct" (peer to peer) or "relayed via fra" (slower, Tailscale's DERP relay).
    func path(to ip: String, replyQueue: DispatchQueue, done: @escaping (String?) -> Void) {
        queue.async {
            var desc: String?
            if let r = Tailscale.run(["status", "--json"], timeout: 5), !r.timedOut,
               let json = try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any],
               let peers = json["Peer"] as? [String: Any] {
                for case let p as [String: Any] in peers.values where (p["TailscaleIPs"] as? [String] ?? []).contains(ip) {
                    let cur = p["CurAddr"] as? String ?? "", relay = p["Relay"] as? String ?? ""
                    desc = cur.isEmpty ? "relayed via \(relay.isEmpty ? "Tailscale" : relay) (slower)" : "direct"
                }
            }
            replyQueue.async { done(desc) }
        }
    }

    /// "iphone-15-pro.tail1234.ts.net." → "iPhone 15 Pro" (iOS reports its host name as "localhost").
    static func prettyName(dnsName: String?, hostName: String?) -> String {
        if let h = hostName, !h.isEmpty, h != "localhost" { return h }
        let label = (dnsName ?? "").split(separator: ".").first.map(String.init) ?? ""
        guard !label.isEmpty else { return "iPhone" }
        return label.split(separator: "-").map { w -> String in
            switch w.lowercased() {
            case "iphone": return "iPhone"
            case "ipad": return "iPad"
            default: return w.prefix(1).uppercased() + w.dropFirst()
            }
        }.joined(separator: " ")
    }
}
