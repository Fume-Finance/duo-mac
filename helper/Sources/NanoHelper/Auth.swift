import Foundation
import CryptoKit
import CommonCrypto

// Who may control this Mac.
//
// Pairing: the QR code's pairing code lets a phone *ask*; the request shows up in the Mac window and
// someone at the Mac must click Allow. The phone then gets its own random device key (the Mac keeps
// only a hash of it) and registers a passkey (passkey) and/or a 6-digit PIN.
// Connecting: device key + passkey (or the PIN). A short-lived ticket lets the phone reconnect after
// a network blip or a fold without asking for passkey again.

struct PairedDevice: Codable, Identifiable, Equatable {
    struct Passkey: Codable, Equatable {
        var credentialID: String   // base64url, as the phone reports it
        var publicKey: String      // P-256, x9.63, base64
        var rpId: String           // the Mac's address the passkey was made for
        var signCount: UInt32
    }

    struct PIN: Codable, Equatable {
        var salt: String           // base64
        var hash: String           // base64, PBKDF2-HMAC-SHA256
        var rounds: Int
    }

    var id: String
    var name: String
    var tokenHash: String          // SHA-256 (hex) of the device key; the key itself lives only on the phone
    var addedAt: Date
    var lastSeenAt: Date?
    var lastFrom: String?
    var passkey: Passkey?
    var pin: PIN?
    var pinFailures = 0
    var pinLockedUntil: Date?
}

/// devices.json next to config.json (0600). Net queue only.
final class DeviceStore {
    let file: URL
    private(set) var devices: [PairedDevice] = []

    init(dir: URL) {
        file = dir.appendingPathComponent("devices.json")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: file), let list = try? dec.decode([PairedDevice].self, from: d) {
            devices = list
        }
    }

    func device(_ id: String) -> PairedDevice? { devices.first { $0.id == id } }

    func upsert(_ d: PairedDevice) {
        if let i = devices.firstIndex(where: { $0.id == d.id }) { devices[i] = d } else { devices.append(d) }
        save()
    }

    func remove(_ id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(devices) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }
}

/// Where a connection came from, as seen through Tailscale Serve (or directly, when testing on this Mac).
struct PeerInfo {
    let address: String   // the phone's Tailscale IP
    let user: String?     // Tailscale account, when it came through Tailscale
    let host: String      // the host name the page was opened at (no port)
    let viaTailscale: Bool
    let local: Bool       // through local mode's entrance (same Wi-Fi or hotspot)

    init(headers: [String: String], socketRemote: String) {
        let fwd = headers["x-forwarded-for"]?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        viaTailscale = fwd != nil
        local = headers["x-duo-local"] == "1"
        address = fwd ?? socketRemote
        user = headers["tailscale-user-login"].flatMap { $0.isEmpty ? nil : $0 }
        host = PeerInfo.stripPort(headers["x-forwarded-host"] ?? headers["host"] ?? "localhost")
    }

    /// WebAuthn needs a domain name (not an IP address) to bind passkeys to.
    var rpId: String? {
        if host == "localhost" { return host }
        let isIPv4 = host.split(separator: ".").count == 4 && host.allSatisfy { $0.isNumber || $0 == "." }
        return host.contains(".") && !isIPv4 && !host.contains(":") ? host : nil
    }

    var description: String { local ? "\(address) (same network)" : user.map { "\(address) (\($0))" } ?? address }

    static func stripPort(_ h: String) -> String {
        if h.hasPrefix("[") { return String(h.dropFirst().prefix { $0 != "]" }) }
        return String(h.split(separator: ":").first ?? "").lowercased()
    }
}

/// A device allowed on the Mac but still setting up passkey / its PIN: saved only once that's done.
struct PendingDevice {
    let id: String
    let name: String
    let token: String
    var passkey: PairedDevice.Passkey?
    var pin: PairedDevice.PIN?
}

enum WebAuthn {
    private struct ClientData: Decodable {
        let type: String
        let challenge: String
        let origin: String
    }

    static func clientDataOK(_ raw: Data, type: String, challenge: [UInt8], origin: (String) -> Bool) -> Bool {
        guard let c = try? JSONDecoder().decode(ClientData.self, from: raw), c.type == type else { return false }
        return Crypto.equal(Array(c.challenge.utf8), Array(Data(challenge).base64URL.utf8)) && origin(c.origin)
    }

    /// Checks the RP ID hash and that passkey / the passcode was used; returns the signature counter.
    static func authDataOK(_ ad: Data, rpId: String) -> UInt32? {
        let b = [UInt8](ad)
        guard b.count >= 37 else { return nil }
        guard Crypto.equal(Array(b[0..<32]), Array(SHA256.hash(data: Data(rpId.utf8)))) else { return nil }
        guard b[32] & 0x01 != 0, b[32] & 0x04 != 0 else { return nil } // user present, user verified
        return UInt32(b[33]) << 24 | UInt32(b[34]) << 16 | UInt32(b[35]) << 8 | UInt32(b[36])
    }

    /// The phone sends the key as SubjectPublicKeyInfo ("spki") or, from older browsers, raw x‖y ("raw").
    static func publicKey(_ data: Data, format: String) -> P256.Signing.PublicKey? {
        format == "raw" ? try? P256.Signing.PublicKey(rawRepresentation: data)
                        : try? P256.Signing.PublicKey(derRepresentation: data)
    }

    static func verify(_ key: P256.Signing.PublicKey, authData: Data, clientData: Data, signature: Data) -> Bool {
        guard let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        var msg = authData
        msg.append(contentsOf: SHA256.hash(data: clientData))
        return key.isValidSignature(sig, for: msg) // ES256: ECDSA over SHA-256(authData ‖ SHA-256(clientData))
    }
}

enum PINHash {
    static let rounds = 120_000

    static func isValid(_ pin: String) -> Bool { pin.count == 6 && pin.allSatisfy { $0.isASCII && $0.isNumber } }

    static func derive(_ pin: String, salt: [UInt8], rounds: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pin, pin.utf8.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, out.count)
        return out
    }

    static func make(_ pin: String) -> PairedDevice.PIN {
        let salt = Crypto.randomBytes(16)
        return .init(salt: Data(salt).base64EncodedString(),
                     hash: Data(derive(pin, salt: salt, rounds: rounds)).base64EncodedString(), rounds: rounds)
    }

    static func check(_ pin: String, _ p: PairedDevice.PIN) -> Bool {
        guard isValid(pin), let salt = Data(base64Encoded: p.salt), let want = Data(base64Encoded: p.hash) else { return false }
        return Crypto.equal(derive(pin, salt: [UInt8](salt), rounds: p.rounds), [UInt8](want))
    }
}

/// Plain-text record of who paired, connected and failed: ~/Library/Logs/Duo Mac/connections.log
/// (next to the settings instead when testing with --config-dir).
final class ConnectionLog {
    let url: URL
    private let queue = DispatchQueue(label: "nano.connlog")
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    init(dir: URL? = nil) {
        let dir = dir ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Duo Mac")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("connections.log")
    }

    func add(_ text: String) {
        Log.info("🔐 \(text)")
        let line = "\(stamp.string(from: Date()))  \(text)\n"
        queue.async { [url] in
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Net queue (like sessions). Tells the window about pairing requests and device changes on main.
final class AuthManager {
    unowned let core: NanoCore
    let store: DeviceStore
    let log: ConnectionLog

    static let ticketLife: TimeInterval = 15 * 60
    static let challengeLife: TimeInterval = 180
    static let pinTries = 5

    private struct Ticket {
        let deviceID: String
        var expires: Date
    }

    final class PairRequest {
        let id = UUID()
        weak var session: Session?
        var name: String
        let from: String
        let match: String
        let created = Date()

        init(session: Session, name: String, from: String, match: String) {
            self.session = session
            self.name = name
            self.from = from
            self.match = match
        }
    }

    private var tickets: [String: Ticket] = [:]   // SHA-256 (hex) of the ticket → ticket
    private var pendingPair: PairRequest?
    private var pinChecking = Set<String>()       // device IDs with a PIN check running

    init(core: NanoCore, dir: URL) {
        self.core = core
        store = DeviceStore(dir: dir)
        log = ConnectionLog(dir: core.options.configDir != nil ? dir : nil)
        prefsFile = dir.appendingPathComponent("prefs.json")
    }

    // MARK: Phone settings backup

    /// The phone's own settings, kept per device name. A Home Screen app added again starts with
    /// empty storage (and pairs again), so it restores them from here. Net queue only.
    private let prefsFile: URL

    private func allPrefs() -> [String: Any] {
        guard let d = try? Data(contentsOf: prefsFile),
              let v = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return v
    }

    func savePrefs(_ prefs: Any?, for name: String) {
        guard let prefs = prefs as? [String: Any], prefs.count < 64 else { return }
        var all = allPrefs()
        all[name] = prefs
        if let d = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: prefsFile, options: .atomic)
        }
    }

    static func hash(_ s: String) -> String { Data(SHA256.hash(data: Data(s.utf8))).hex }

    // MARK: Messages

    func handle(_ t: String, _ m: [String: Any], from s: Session) {
        switch t {
        case "auth": signIn(m, s)
        case "auth-passkey": passkeyLogin(m, s)
        case "auth-pin": pinLogin(m, s)
        case "pair": pair(m, s)
        case "passkey-begin": passkeyBegin(s)
        case "passkey-register": passkeyRegister(m, s)
        case "pin-set": pinSet(m, s)
        case "pair-finish": pairFinish(s)
        case "lock": lock(s)
        case "forget": forget(s)
        default: break
        }
    }

    /// First message of every connection from a paired phone: its device key, plus a ticket if it
    /// unlocked recently.
    private func signIn(_ m: [String: Any], _ s: Session) {
        guard core.config.allowConnections else { return refuse(s) }
        guard let id = m["dev"] as? String, let tok = m["tok"] as? String, let d = store.device(id),
              Crypto.equal(Array(AuthManager.hash(tok).utf8), Array(d.tokenHash.utf8)) else {
            log.add("Refused an unknown device from \(s.peer.description)")
            s.send(["t": "auth-fail", "reason": "unknown-device"])
            return
        }
        if let t = m["ticket"] as? String, ticketValid(t, for: d.id) {
            return grant(s, d, via: nil)
        }
        challenge(s, d)
    }

    private func challenge(_ s: Session, _ d: PairedDevice) {
        s.stage = .known(d.id)
        let ch = Crypto.randomBytes(32)
        s.challenge = (ch, Date())
        var msg: [String: Any] = ["t": "auth-need", "challenge": Data(ch).base64URL, "name": d.name,
                                  "pin": d.pin != nil, "pinWait": Int(pinLockRemaining(d).rounded(.up)),
                                  "passkey": false]
        if let pk = d.passkey {
            msg["cred"] = pk.credentialID
            msg["rpId"] = pk.rpId
            msg["passkey"] = pk.rpId == s.peer.rpId // only works at the address it was made for
        }
        s.send(msg)
    }

    /// The challenge, once: it expires after a few minutes and can't be replayed.
    private func takeChallenge(_ s: Session) -> [UInt8]? {
        defer { s.challenge = nil }
        guard let c = s.challenge, Date().timeIntervalSince(c.at) < AuthManager.challengeLife else { return nil }
        return c.bytes
    }

    private func originOK(_ origin: String, rpId: String) -> Bool {
        if rpId == "localhost" { return origin == "http://localhost" || origin.hasPrefix("http://localhost:") }
        return origin == "https://\(rpId)"
    }

    private func passkeyLogin(_ m: [String: Any], _ s: Session) {
        guard case .known(let id) = s.stage, var d = store.device(id), let pk = d.passkey else { return }
        let ch = takeChallenge(s)
        guard let ch, (m["id"] as? String) == pk.credentialID,
              let ad = (m["authData"] as? String).flatMap({ Data(base64URL: $0) }),
              let cd = (m["clientData"] as? String).flatMap({ Data(base64URL: $0) }),
              let sig = (m["sig"] as? String).flatMap({ Data(base64URL: $0) }),
              let keyData = Data(base64Encoded: pk.publicKey),
              let key = try? P256.Signing.PublicKey(x963Representation: keyData),
              WebAuthn.clientDataOK(cd, type: "webauthn.get", challenge: ch, origin: { self.originOK($0, rpId: pk.rpId) }),
              let count = WebAuthn.authDataOK(ad, rpId: pk.rpId),
              WebAuthn.verify(key, authData: ad, clientData: cd, signature: sig) else {
            log.add("Passkey check failed for \(d.name) from \(s.peer.description)")
            s.send(["t": "auth-fail", "reason": "passkey"])
            return challenge(s, d)
        }
        // A counter going backwards would mean a copied key (iCloud Keychain passkeys always say 0).
        if count != 0 || pk.signCount != 0 {
            guard count > pk.signCount else {
                log.add("Refused \(d.name): its passkey counter went backwards")
                s.send(["t": "auth-fail", "reason": "passkey"])
                return challenge(s, d)
            }
            d.passkey?.signCount = count
        }
        grant(s, d, via: "passkey")
    }

    private func pinLockRemaining(_ d: PairedDevice) -> TimeInterval {
        max(0, d.pinLockedUntil?.timeIntervalSinceNow ?? 0)
    }

    private func pinLogin(_ m: [String: Any], _ s: Session) {
        guard case .known(let id) = s.stage, let d = store.device(id), let stored = d.pin else { return }
        let wait = pinLockRemaining(d)
        guard wait <= 0 else {
            s.send(["t": "auth-fail", "reason": "pin-locked", "wait": Int(wait.rounded(.up))])
            return
        }
        guard !pinChecking.contains(id) else { return } // one guess at a time
        pinChecking.insert(id)
        let pin = m["pin"] as? String ?? ""
        let queue = core.server.queue
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = PINHash.check(pin, stored)
            queue.async {
                self.pinChecking.remove(id)
                guard var d = self.store.device(id) else { return }
                if ok {
                    d.pinFailures = 0
                    d.pinLockedUntil = nil
                    guard case .known(id) = s.stage, !s.ws.isClosed else { return self.store.upsert(d) }
                    self.grant(s, d, via: "PIN")
                    return
                }
                d.pinFailures += 1
                if d.pinFailures >= AuthManager.pinTries {
                    // Five wrong in a row: an hour's pause, doubling with every further miss.
                    let hours = pow(2, Double(min(10, d.pinFailures - AuthManager.pinTries)))
                    d.pinLockedUntil = Date().addingTimeInterval(3600 * hours)
                }
                self.store.upsert(d)
                self.log.add("Wrong PIN for \(d.name) from \(s.peer.description) (\(d.pinFailures) in a row)")
                s.send(["t": "auth-fail", "reason": "pin", "left": max(0, AuthManager.pinTries - d.pinFailures),
                        "wait": Int(self.pinLockRemaining(d).rounded(.up))])
                self.core.devicesChanged()
            }
        }
    }

    // MARK: Pairing

    private func pair(_ m: [String: Any], _ s: Session) {
        guard core.config.allowConnections else { return refuse(s) }
        let code = (m["code"] as? String ?? "").uppercased().filter { $0.isLetter || $0.isNumber }
        guard Crypto.equal(Array(code.utf8), Array(core.config.pairCode.utf8)) else {
            log.add("Refused a pairing request with an old or wrong code from \(s.peer.description)")
            s.send(["t": "pair-fail", "reason": "bad-code"])
            return
        }
        if let p = pendingPair, let other = p.session, other !== s, !other.ws.isClosed,
           Date().timeIntervalSince(p.created) < 120 {
            s.send(["t": "pair-fail", "reason": "busy"])
            return
        }
        let raw = (m["name"] as? String ?? "").filter { !$0.isNewline && $0 != "\u{0}" }
        let name = raw.isEmpty ? s.clientName : String(raw.prefix(40))
        let b = Crypto.randomBytes(2)
        let match = String(format: "%04d", (Int(b[0]) << 8 | Int(b[1])) % 10000)
        let req = PairRequest(session: s, name: name, from: s.peer.description, match: match)
        pendingPair = req
        s.stage = .waiting
        s.send(["t": "pair-wait", "match": match])
        log.add("\(name) from \(s.peer.description) asks to pair")
        core.showPairingRequest(req)
        // A better name from Tailscale ("iPhone 15 Pro") if it knows this device.
        if s.peer.viaTailscale {
            core.tailscale.whois(s.peer.address, replyQueue: core.server.queue) { [weak self, weak req] found in
                guard let self, let req, let found, self.pendingPair === req else { return }
                req.name = (raw.isEmpty || raw == "iPhone" || raw == "iPad") ? found : name
                self.core.showPairingRequest(req)
            }
        }
        core.server.queue.asyncAfter(deadline: .now() + 120) { [weak self, weak req] in
            guard let self, let req, self.pendingPair === req else { return }
            self.resolvePairing(req.id, allow: false, timedOut: true)
        }
        if core.options.autoApprove { // test pattern only (see Options)
            core.server.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.resolvePairing(req.id, allow: true) }
        }
    }

    /// The Mac window's Allow / Deny.
    func resolvePairing(_ id: UUID, allow: Bool, timedOut: Bool = false) {
        guard let p = pendingPair, p.id == id else { return }
        pendingPair = nil
        core.clearPairingRequest()
        guard let s = p.session, !s.ws.isClosed, case .waiting = s.stage else { return }
        guard allow else {
            s.stage = .anonymous
            s.send(["t": "pair-fail", "reason": timedOut ? "timeout" : "denied"])
            log.add("\(timedOut ? "Nobody answered" : "Denied") the pairing request from \(p.name) (\(p.from))")
            return
        }
        s.stage = .approved(PendingDevice(id: Crypto.randomToken(12), name: p.name, token: Crypto.randomToken(32)))
        s.send(["t": "pair-approved", "name": p.name])
        log.add("Allowed \(p.name) (\(p.from)); it's setting up passkey / a PIN")
    }

    func cancelPairing() {
        guard let p = pendingPair else { return }
        resolvePairing(p.id, allow: false)
    }

    /// The phone that asked to pair went away: take the request off the Mac's screen.
    func sessionGone(_ s: Session) {
        guard let p = pendingPair, p.session === s || p.session == nil else { return }
        pendingPair = nil
        core.clearPairingRequest()
        log.add("\(p.name) stopped asking to pair")
    }

    private func passkeyBegin(_ s: Session) {
        guard case .approved(let pd) = s.stage else { return }
        guard let rpId = s.peer.rpId else {
            s.send(["t": "passkey-options", "unavailable": true])
            return
        }
        let ch = Crypto.randomBytes(32)
        s.challenge = (ch, Date())
        s.send(["t": "passkey-options", "challenge": Data(ch).base64URL, "rpId": rpId,
                "userId": Data(pd.id.utf8).base64URL, "userName": core.mac.computerName])
    }

    private func passkeyRegister(_ m: [String: Any], _ s: Session) {
        guard case .approved(var pd) = s.stage, let rpId = s.peer.rpId else { return }
        let ch = takeChallenge(s)
        guard let ch, let credID = m["id"] as? String, !credID.isEmpty, credID.count < 1400,
              let cd = (m["clientData"] as? String).flatMap({ Data(base64URL: $0) }),
              let ad = (m["authData"] as? String).flatMap({ Data(base64URL: $0) }),
              let pub = (m["pub"] as? String).flatMap({ Data(base64URL: $0) }),
              let key = WebAuthn.publicKey(pub, format: m["fmt"] as? String ?? "spki"),
              WebAuthn.clientDataOK(cd, type: "webauthn.create", challenge: ch, origin: { self.originOK($0, rpId: rpId) }),
              WebAuthn.authDataOK(ad, rpId: rpId) != nil else {
            log.add("Couldn't register the passkey for \(pd.name)")
            s.send(["t": "passkey-fail"])
            return
        }
        pd.passkey = .init(credentialID: credID, publicKey: key.x963Representation.base64EncodedString(), rpId: rpId, signCount: 0)
        s.stage = .approved(pd)
        s.send(["t": "passkey-ok"])
    }

    /// While pairing (backup PIN) or once unlocked (change the PIN).
    private func pinSet(_ m: [String: Any], _ s: Session) {
        let pin = m["pin"] as? String ?? ""
        guard PINHash.isValid(pin) else { return s.send(["t": "pin-fail", "reason": "format"]) }
        switch s.stage {
        case .approved, .authed: break
        default: return
        }
        let queue = core.server.queue
        DispatchQueue.global(qos: .userInitiated).async {
            let stored = PINHash.make(pin)
            queue.async {
                switch s.stage {
                case .approved(var pd):
                    pd.pin = stored
                    s.stage = .approved(pd)
                case .authed(let id):
                    guard var d = self.store.device(id) else { return }
                    d.pin = stored
                    d.pinFailures = 0
                    d.pinLockedUntil = nil
                    self.store.upsert(d)
                    self.log.add("\(d.name) set a new PIN")
                    self.core.devicesChanged()
                default:
                    return
                }
                s.send(["t": "pin-ok"])
            }
        }
    }

    private func pairFinish(_ s: Session) {
        guard case .approved(let pd) = s.stage else { return }
        guard pd.passkey != nil || pd.pin != nil else { return s.send(["t": "pair-fail", "reason": "no-unlock"]) }
        let d = PairedDevice(id: pd.id, name: pd.name, tokenHash: AuthManager.hash(pd.token), addedAt: Date(),
                             passkey: pd.passkey, pin: pd.pin)
        store.upsert(d)
        let how = [d.passkey != nil ? "Passkey" : nil, d.pin != nil ? "PIN" : nil].compactMap { $0 }.joined(separator: " + ")
        log.add("Paired \(d.name) (\(how))")
        s.send(["t": "paired", "dev": d.id, "tok": pd.token])
        grant(s, d, via: nil)
    }

    private func grant(_ s: Session, _ d: PairedDevice, via: String?) {
        var d = d
        s.stage = .authed(d.id)
        s.challenge = nil
        s.clientName = d.name
        d.lastSeenAt = Date()
        d.lastFrom = s.peer.description
        store.upsert(d)
        if let via { log.add("\(d.name) unlocked with \(via) from \(s.peer.description)") }
        var reply: [String: Any] = ["t": "authed", "ticket": issueTicket(for: d.id),
                                    "device": ["name": d.name, "passkey": d.passkey != nil, "pin": d.pin != nil]]
        if let prefs = allPrefs()[d.name] { reply["prefs"] = prefs }
        s.send(reply)
        core.devicesChanged()
    }

    /// "Lock" in the phone's settings: forget the unlock, so the next connection needs passkey again.
    private func lock(_ s: Session) {
        guard case .authed(let id) = s.stage else { return }
        revokeTickets(id)
        log.add("\(s.clientName) locked Duo Mac")
        s.ws.close()
    }

    /// "Forget this Mac" on the phone.
    private func forget(_ s: Session) {
        guard case .authed(let id) = s.stage else { return }
        log.add("\(s.clientName) unpaired itself")
        removeDevice(id)
    }

    private func refuse(_ s: Session) {
        s.send(["t": "auth-fail", "reason": "off"])
        s.ws.close(code: 4004)
    }

    // MARK: Devices and tickets

    func removeDevice(_ id: String) {
        guard let d = store.device(id) else { return }
        store.remove(id)
        revokeTickets(id)
        log.add("Removed \(d.name)")
        core.closeSessions(where: { $0.deviceID == id }, code: 4003, message: ["t": "revoked"])
        core.devicesChanged()
    }

    private func issueTicket(for id: String) -> String {
        let now = Date()
        tickets = tickets.filter { $0.value.expires > now }
        let t = Crypto.randomToken(32)
        tickets[AuthManager.hash(t)] = Ticket(deviceID: id, expires: now.addingTimeInterval(AuthManager.ticketLife))
        return t
    }

    private func ticketValid(_ t: String, for id: String) -> Bool {
        guard let k = tickets[AuthManager.hash(t)] else { return false }
        return k.deviceID == id && k.expires > Date()
    }

    /// While a phone is connected its tickets stay fresh; they run out 15 minutes after it leaves.
    func keepTicketsFresh(for id: String) {
        let exp = Date().addingTimeInterval(AuthManager.ticketLife)
        for k in tickets.keys where tickets[k]?.deviceID == id { tickets[k]?.expires = exp }
    }

    func revokeTickets(_ id: String) { tickets = tickets.filter { $0.value.deviceID != id } }
    func revokeAllTickets() { tickets.removeAll() }
}

/// `--selftest-auth`: checks the WebAuthn and PIN code against keys made here (no phone needed).
enum AuthSelfTest {
    static func run() -> Bool {
        var ok = true
        func expect(_ cond: Bool, _ what: String) {
            print("\(cond ? "ok  " : "FAIL") \(what)")
            ok = ok && cond
        }
        let rpId = "macbook.example.ts.net", origin = "https://\(rpId)"
        let key = P256.Signing.PrivateKey()
        let challenge = Crypto.randomBytes(32)
        func authData(flags: UInt8, count: UInt32 = 0, rp: String = rpId) -> Data {
            var d = Data(SHA256.hash(data: Data(rp.utf8)))
            d.append(flags)
            d.append(contentsOf: [UInt8(count >> 24 & 0xFF), UInt8(count >> 16 & 0xFF), UInt8(count >> 8 & 0xFF), UInt8(count & 0xFF)])
            return d
        }
        func clientData(_ type: String, _ ch: [UInt8], _ o: String) -> Data {
            Data("{\"type\":\"\(type)\",\"challenge\":\"\(Data(ch).base64URL)\",\"origin\":\"\(o)\",\"crossOrigin\":false}".utf8)
        }
        func sign(_ ad: Data, _ cd: Data) -> Data {
            var msg = ad
            msg.append(contentsOf: SHA256.hash(data: cd))
            return (try? key.signature(for: msg).derRepresentation) ?? Data()
        }
        let ad = authData(flags: 0x05), cd = clientData("webauthn.get", challenge, origin)
        let sig = sign(ad, cd)
        let originOK = { (o: String) in o == origin }
        expect(WebAuthn.verify(key.publicKey, authData: ad, clientData: cd, signature: sig), "valid assertion verifies")
        expect(WebAuthn.clientDataOK(cd, type: "webauthn.get", challenge: challenge, origin: originOK), "client data accepted")
        expect(WebAuthn.authDataOK(ad, rpId: rpId) == 0, "auth data accepted")
        expect(!WebAuthn.clientDataOK(cd, type: "webauthn.get", challenge: Crypto.randomBytes(32), origin: originOK), "other challenge refused")
        expect(!WebAuthn.clientDataOK(clientData("webauthn.get", challenge, "https://evil.example"), type: "webauthn.get",
                                      challenge: challenge, origin: originOK), "other origin refused")
        expect(!WebAuthn.clientDataOK(cd, type: "webauthn.create", challenge: challenge, origin: originOK), "wrong type refused")
        expect(WebAuthn.authDataOK(authData(flags: 0x01), rpId: rpId) == nil, "no passkey (UV) refused")
        expect(WebAuthn.authDataOK(authData(flags: 0x05, rp: "evil.example"), rpId: rpId) == nil, "other RP refused")
        var bad = ad
        bad[33] ^= 1
        expect(!WebAuthn.verify(key.publicKey, authData: bad, clientData: cd, signature: sig), "tampered auth data refused")
        expect(!WebAuthn.verify(P256.Signing.PrivateKey().publicKey, authData: ad, clientData: cd, signature: sig), "other key refused")
        let spki = key.publicKey.derRepresentation, raw = key.publicKey.rawRepresentation
        expect(WebAuthn.publicKey(spki, format: "spki")?.rawRepresentation == raw, "SPKI key parses")
        expect(WebAuthn.publicKey(raw, format: "raw")?.rawRepresentation == raw, "raw key parses")
        let stored = PINHash.make("482913")
        expect(PINHash.check("482913", stored), "right PIN accepted")
        expect(!PINHash.check("482914", stored), "wrong PIN refused")
        expect(!PINHash.isValid("12345") && !PINHash.isValid("12345a") && PINHash.isValid("012345"), "PIN format")
        expect(Data(base64URL: Data([0xfb, 0xff, 0x01]).base64URL) == Data([0xfb, 0xff, 0x01]), "base64url round trip")
        let peer = PeerInfo(headers: ["x-forwarded-for": "100.101.102.103", "host": "your-mac.tail1234.ts.net",
                                      "tailscale-user-login": "me@example.com"], socketRemote: "127.0.0.1")
        expect(peer.viaTailscale && peer.rpId == "your-mac.tail1234.ts.net" && peer.address == "100.101.102.103", "peer via Tailscale")
        expect(PeerInfo(headers: ["host": "127.0.0.1:8890"], socketRemote: "127.0.0.1").rpId == nil, "no passkeys on an IP address")
        expect(PeerInfo(headers: ["host": "localhost:8891"], socketRemote: "127.0.0.1").rpId == "localhost", "localhost for tests")
        print(ok ? "All auth checks passed." : "Some auth checks FAILED.")
        return ok
    }
}
