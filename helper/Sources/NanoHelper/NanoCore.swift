import AppKit
import ApplicationServices
import IOKit.pwr_mgt

/// Ties everything together: web server, current phone session, screen source, input and UI state.
final class NanoCore {
    let options: Options
    let store: ConfigStore
    let mac = MacInfo.current()
    let model = AppModel()
    let server: HTTPServer
    let source: FrameSource
    let injector: InputInjector
    let webRoot: URL
    let appIcon: NSImage?
    let microphone = Microphone()

    private let configLock = NSLock()
    private var _config: NanoConfig
    var config: NanoConfig {
        configLock.lock(); defer { configLock.unlock() }
        return _config
    }

    private var keymap: KeymapInfo
    private var displays: [DisplayInfo] = []
    private var session: Session?            // net queue: the phone in control (has said hello)
    private var pending: [ObjectIdentifier: Session] = [:]  // net queue: connected, not yet said hello
    private let sinkLock = NSLock()
    private weak var sink: Session?          // receives captured frames
    private var awakeID: IOPMAssertionID = 0 // main thread
    private var awakeHeld = false
    private var reachID: IOPMAssertionID = 0 // main thread
    private var reachHeld = false
    private var timers: [Timer] = []
    private var askedForScreen = false
    private var statTicks = 0                // net queue
    private var lastCaptured = 0
    private var lastSeen: [String: Date] = [:]  // net queue: device → when its last session ended
    let nano = NanoDisplay()                 // main thread
    private var nanoTeardown: DispatchWorkItem?  // main thread

    private(set) var auth: AuthManager!      // net queue
    let tailscale = Tailscale()
    private var tsStatus = Tailscale.Status()   // main thread
    private var tsRefreshing = false
    private var tsLastRefresh = Date.distantPast
    /// The window shows a pairing request: bring it forward (set by the app delegate). main thread
    var onPairingRequest: (() -> Void)?

    /// No input for this long ends the session; unlocking again needs passkey.
    static let idleLimit: TimeInterval = 30 * 60

    /// Testing on this Mac (test pattern, or --lan): no Tailscale, plain http.
    var localMode: Bool { options.testPattern || options.lan }

    init(options: Options) {
        self.options = options
        store = ConfigStore(dir: options.configDir)
        _config = store.load()
        webRoot = WebRoot.locate(override: options.webRoot)
        appIcon = NSImage(contentsOf: webRoot.appendingPathComponent("icon-mac.png"))
        let src: FrameSource = options.testPattern ? TestPatternSource() : ScreenSource(displayIndex: options.displayIndex)
        source = src
        injector = InputInjector(dryRun: options.dryRun || options.testPattern, bounds: src.info.bounds)
        keymap = Keymap.current()
        server = HTTPServer(port: options.port ?? _config.port, localhostOnly: !options.lan, webRoot: webRoot)
        (src as? TestPatternSource)?.injector = injector
        installKeymap(keymap)
        source.onFrame = { [weak self] pb in self?.deliver(pb) }
        source.onError = { [weak self] err in self?.captureFailed(err) }
        auth = AuthManager(core: self, dir: store.dir)
    }

    // MARK: Lifecycle

    func start() {
        server.onWebSocket = { [weak self] ws, headers in self?.attach(ws, headers: headers) }
        server.onState = { [weak self] ok, err in
            DispatchQueue.main.async { self?.model.serverError = ok ? nil : err }
        }
        server.start()
        Log.info("Serving the web app from \(webRoot.path)")
        if injector.dryRun { Log.info("Dry run: input is logged, not sent to macOS") }
        if options.lan { Log.warn("--lan: answering the local network over plain http (testing only)") }
        server.queue.async { self.devicesChanged() }
        DispatchQueue.main.async {
            self.refreshModel()
            self.startTimers()
            self.updateReachable()
            self.refreshTailscale()
        }
        // Resolution changes, displays plugged in, mirroring kicking in: keep geometry current.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.server.queue.async {
                DispatchQueue.main.sync {
                    self.source.refreshInfo()
                    self.injector.bounds = self.source.info.bounds
                }
            }
        }
    }

    func shutdown() {
        injector.releaseAll()
        let done = DispatchSemaphore(value: 0)
        server.queue.async {
            // "Going away" (not "kicked"): the phone keeps retrying and reconnects when we're back.
            self.session?.ws.close(code: 1001)
            self.session = nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + 0.5)
        source.stop()
        setAwake(false)
        nano.destroy()
        // Nothing answers at the Mac's Tailscale address while the app isn't running.
        if !localMode { tailscale.stopServing(port: port, wait: true) }
    }

    private func startTimers() {
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickStats()
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            let every: TimeInterval = self.tsStatus.phase == .ready && self.tsStatus.reachable ? 30 : 4
            if Date().timeIntervalSince(self.tsLastRefresh) >= every { self.refreshTailscale() }
        })
    }

    // MARK: Pairing link and Tailscale

    var port: UInt16 { server.port }

    /// The link in the QR code; nil until Tailscale is ready (or while connections are off).
    func pairingURL() -> String? {
        let code = config.pairCode
        if options.testPattern { return "http://localhost:\(port)/?pair=\(code)" }
        if options.lan { return "http://\(mac.localHostName).local:\(port)/?pair=\(code)" }
        guard config.allowConnections, tsStatus.phase == .ready, let host = tsStatus.dnsName else { return nil }
        return "https://\(host)/?pair=\(code)"
    }

    /// main thread
    func refreshTailscale() {
        guard !localMode, !tsRefreshing else { return }
        tsRefreshing = true
        tailscale.refresh(port: port, wantServe: config.allowConnections, previous: tsStatus) { [weak self] st in
            guard let self else { return }
            self.tsRefreshing = false
            self.tsLastRefresh = Date()
            if st.phase != self.tsStatus.phase || st.serving != self.tsStatus.serving {
                Log.info("Tailscale: \(st.phase)\(st.dnsName.map { " · \($0)" } ?? "")\(st.serving ? " · serving" : "")\(st.reachable ? " · reachable" : "")")
            }
            if st != self.tsStatus {
                self.tsStatus = st
                self.refreshModel()
            }
        }
    }

    func updateConfig(_ change: (inout NanoConfig) -> Void) {
        configLock.lock()
        change(&_config)
        let c = _config
        configLock.unlock()
        store.save(c)
    }

    /// A new pairing code: the old QR code can't start a pairing any more. Paired phones keep working.
    func resetPairing() {
        updateConfig { $0.pairCode = ConfigStore.newPairCode() }
        server.queue.async { self.auth.cancelPairing() }
        DispatchQueue.main.async { self.refreshModel() }
        Log.info("New pairing code created; the old QR code no longer works")
    }

    func printBanner() {
        guard let u = pairingURL() else {
            print("\n  Duo Mac is waiting for Tailscale (sign in and turn on HTTPS), then shows a QR code.\n")
            return
        }
        print("")
        print(QR.terminal(QR.modules(u)))
        print("  Duo Mac is ready. Scan the code with your iPhone's Camera, or open:")
        print("    \(u)")
        print("  Pairing code: \(ConfigStore.formatted(config.pairCode))")
        if options.testPattern { print("  (test pattern — nothing on this Mac is shown or controlled)") }
        else if injector.dryRun { print("  (dry run — input is only logged)") }
        print("")
    }

    // MARK: Security (see Auth.swift)

    /// net queue
    func closeSessions(where match: (Session) -> Bool, code: UInt16, message: [String: Any]?) {
        var all = Array(pending.values)
        if let s = session { all.append(s) }
        for s in all where match(s) {
            if let message { s.send(message) }
            s.ws.close(code: code)
            detach(s)
        }
    }

    /// net queue
    func showPairingRequest(_ r: AuthManager.PairRequest) {
        let prompt = PairingPrompt(id: r.id, name: r.name, from: r.from, match: r.match)
        DispatchQueue.main.async {
            let isNew = self.model.pairing?.id != prompt.id
            self.model.pairing = prompt
            if isNew {
                NSSound(named: "Ping")?.play()
                self.onPairingRequest?()
            }
        }
    }

    func clearPairingRequest() {
        DispatchQueue.main.async { self.model.pairing = nil }
    }

    /// main thread: the window's Allow / Deny
    func answerPairing(_ id: UUID, allow: Bool) {
        server.queue.async { self.auth.resolvePairing(id, allow: allow) }
    }

    /// main thread
    func removeDevice(_ id: String) {
        server.queue.async { self.auth.removeDevice(id) }
    }

    /// net queue: publishes the paired devices to the window
    func devicesChanged() {
        let day = DateFormatter()
        day.dateFormat = "d MMM"
        let time = DateFormatter()
        time.dateFormat = "d MMM, HH:mm"
        let rows = auth.store.devices.map { d -> DeviceRow in
            var parts: [String] = []
            let unlock = [d.passkey != nil ? "Passkey" : nil, d.pin != nil ? "PIN" : nil].compactMap { $0 }
            parts.append(unlock.isEmpty ? "No unlock method" : unlock.joined(separator: " + "))
            if let until = d.pinLockedUntil, until > Date() { parts.append("PIN paused after wrong tries") }
            parts.append("added \(day.string(from: d.addedAt))")
            if let seen = d.lastSeenAt { parts.append("last unlocked \(time.string(from: seen))") }
            return DeviceRow(id: d.id, name: d.name, detail: parts.joined(separator: " · "))
        }
        DispatchQueue.main.async { self.model.devices = rows }
    }

    /// main thread
    func setAllowConnections(_ on: Bool) {
        updateConfig { $0.allowConnections = on }
        if !on {
            server.queue.async {
                self.auth.cancelPairing()
                self.auth.revokeAllTickets()
                self.closeSessions(where: { _ in true }, code: 4004, message: ["t": "auth-fail", "reason": "off"])
            }
            auth.log.add("iPhone connections turned off on the Mac")
        } else {
            auth.log.add("iPhone connections turned on")
        }
        updateReachable()
        refreshModel()
        tsLastRefresh = .distantPast
        refreshTailscale()
    }

    /// main thread
    func setStayReachable(_ on: Bool) {
        updateConfig { $0.stayReachable = on }
        updateReachable()
        refreshModel()
    }

    /// While on, the Mac doesn't sleep by itself (the display still may), so the iPhone can reach it. main thread
    private func updateReachable() {
        let want = config.stayReachable && config.allowConnections && !localMode
        if want && !reachHeld {
            reachHeld = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "Duo Mac: reachable from your iPhone" as CFString,
                                                    &reachID) == kIOReturnSuccess
        } else if !want && reachHeld {
            IOPMAssertionRelease(reachID)
            reachHeld = false
        }
    }

    // MARK: Sessions (net queue)

    /// A new connection waits in `pending` until it says hello; only then does it take over.
    /// (Connection attempts the phone already gave up on can still arrive late — they must not
    /// kick the live one.)
    private func attach(_ ws: WebSocketConnection, headers: [String: String]) {
        let peer = PeerInfo(headers: headers, socketRemote: ws.remote)
        let s = Session(core: self, ws: ws, userAgent: headers["user-agent"] ?? "", peer: peer)
        pending[ObjectIdentifier(s)] = s
        ws.onText = { [weak s] text in s?.handle(text: text) }
        ws.onBinary = { [weak s] data in s?.handle(binary: data) }
        ws.onClose = { [weak self, weak s] in
            guard let self, let s else { return }
            self.detach(s)
        }
        s.send(["t": "welcome", "mac": mac.computerName])
        if let b = PhoneBrowser(userAgent: headers["user-agent"] ?? "") {
            DispatchQueue.main.async { self.model.phoneBrowser = b }
        }
        Log.debug("Connection from \(peer.description)")
    }

    func isActive(_ s: Session) -> Bool { session === s }

    private func detach(_ s: Session) {
        s.end()
        auth.sessionGone(s)
        pending.removeValue(forKey: ObjectIdentifier(s))
        guard session === s else { return }
        session = nil
        setSink(nil)
        source.stop()
        injector.releaseAll()
        if let id = s.deviceID { lastSeen[id] = Date() }
        Log.info("📱 \(s.clientName) disconnected")
        DispatchQueue.main.async {
            self.setMicrophone(false)
            self.scheduleNanoTeardown()
            self.setAwake(false)
            self.model.connected = false
            self.model.fps = 0
            self.model.kbps = 0
        }
    }

    private func setSink(_ s: Session?) {
        sinkLock.lock()
        sink = s
        sinkLock.unlock()
    }

    private func deliver(_ pb: CVPixelBuffer) {
        sinkLock.lock()
        let s = sink
        sinkLock.unlock()
        s?.ingest(pb)
    }

    /// The phone said hello: it takes control, gets a description of the Mac, and capture starts.
    /// `reshape`: the phone picked a desktop size (or this is the first hello), so the Duo display
    /// may change shape. Rotation and quality changes never reshape it.
    func startStreaming(for s: Session, reshape: Bool = true) {
        guard s.isAuthed else { return }
        if session !== s {
            guard pending.removeValue(forKey: ObjectIdentifier(s)) != nil else { return }
            if let old = session {
                Log.info("\(s.clientName) took over from the previous connection")
                old.kick()
                detach(old)
            }
            session = s
            Log.info("📱 \(s.clientName) connected from \(s.peer.description)")
            if s.peer.viaTailscale {
                // Ask a moment later: the peer-to-peer path may still be setting up.
                server.queue.asyncAfter(deadline: .now() + 4) { [weak self, weak s] in
                    guard let self, let s, self.session === s else { return }
                    self.tailscale.path(to: s.peer.address, replyQueue: self.server.queue) { p in
                        if let p { Log.info("Network path to \(s.clientName): \(p)") }
                    }
                }
            }
            // Tell whoever is at the Mac — but not again for a quick reconnect (fold, network change).
            let recent = s.deviceID.flatMap { lastSeen[$0] }.map { Date().timeIntervalSince($0) < 120 } ?? false
            let who = s.clientName, from = s.peer.viaTailscale ? "through Tailscale" : "from this Mac"
            DispatchQueue.main.async {
                self.model.connected = true
                self.model.clientName = "\(s.clientName) · \(s.peer.description)"
                if !recent && !self.options.headless {
                    HUD.show(title: "\(who) is controlling this Mac", detail: "Connected \(from). End it from the Duo Mac window or menu.")
                    NSSound(named: "Glass")?.play()
                }
            }
        }
        // A sleeping screen can't be captured (it shows up as "no display"): wake it, like touching the trackpad.
        if NanoCore.wakeDisplays() { NanoCore.lastWake = Date() }
        // No Screen Recording permission yet: don't reshape the Mac's screen for nothing.
        let wantNano = s.nanoOn && permissions().screen
        var nanoPts = nanoPoints(for: s)
        // Keep the Duo display's shape for the whole session: rotating the phone just letterboxes.
        // Reshaping a mirrored display mid-session left windows off-screen. Only a new desktop-size
        // choice reshapes it.
        if !reshape, let cur = DispatchQueue.main.sync(execute: { self.nano.points }) {
            nanoPts = cur
        }
        if s.nanoOn { Log.info("Duo display request: \(s.nanoSize) → \(nanoPts.w)×\(nanoPts.h)\(reshape ? "" : " (shape kept)")") }
        var nanoFailed = false
        // Reconfiguring displays at the lock screen confuses macOS: wait until the Mac is unlocked
        // (the phone's keyboard can type the password); tickStats retries every second.
        let waitForUnlock = wantNano && !options.testPattern && !NanoCore.unlockedForSure()
        s.nanoWaitingForUnlock = waitForUnlock
        DispatchQueue.main.sync {
            self.nanoTeardown?.cancel()
            self.nanoTeardown = nil
            if waitForUnlock {
                self.source.targetDisplayID = nil
            } else if wantNano {
                if let tp = self.source as? TestPatternSource {
                    tp.nanoSize = CGSize(width: nanoPts.w, height: nanoPts.h)
                    tp.targetDisplayID = 1
                } else if var id = self.nano.ensure(width: nanoPts.w, height: nanoPts.h) {
                    // macOS refuses Retina mode below some size: step up 10% until it accepts.
                    var tries = 0
                    let stepped = !self.nano.isRetina
                    while !self.nano.isRetina, tries < 10, let next = self.nano.ensure(width: (nanoPts.w * 106 / 100) & ~1,
                                                                                        height: (nanoPts.h * 106 / 100) & ~1) {
                        nanoPts = (nanoPts.w * 106 / 100 & ~1, nanoPts.h * 106 / 100 & ~1)
                        id = next
                        tries += 1
                        Log.info("Duo display: trying \(nanoPts.w)×\(nanoPts.h) for Retina mode")
                    }
                    if stepped && self.nano.isRetina {
                        UserDefaults.standard.set(nanoPts.w, forKey: "nanoMinRetinaWidth")
                        Log.info("Smallest sharp Duo display: \(nanoPts.w) pt wide (remembered)")
                    }
                    self.nano.mirrorAllDisplays()
                    self.source.targetDisplayID = id
                } else {
                    nanoFailed = true
                    self.source.targetDisplayID = nil
                }
            } else {
                self.source.targetDisplayID = nil
                self.nano.destroy()
            }
            self.source.refreshInfo()
            self.injector.bounds = self.source.info.bounds
            self.keymap = Keymap.current()
            self.installKeymap(self.keymap)
            self.displays = self.options.testPattern ? [self.source.info] : DisplayInfo.all()
            self.model.nanoInfo = self.source.targetDisplayID == nil ? ""
                : "Duo display \(nanoPts.w) × \(nanoPts.h) — this Mac's screen mirrors it"
        }
        if nanoFailed {
            s.send(["t": "notice", "level": "info", "code": "nano-unavailable",
                    "msg": "The Duo display couldn't be created on this Mac; showing the Mac's screen instead."])
        } else if waitForUnlock {
            s.send(["t": "notice", "level": "info", "code": "nano-locked",
                    "msg": "The Mac is locked: unlock it to switch to the full-size Duo display."])
        }
        let size = streamSize(for: s)
        s.send(configMessage(for: s, size: size))
        setSink(s)
        let (screenOK, inputOK) = permissions()
        if !inputOK {
            s.send(["t": "notice", "level": "warn", "code": "input-permission",
                    "msg": "Keyboard and trackpad are off until you allow Accessibility for Duo Mac on the Mac."])
        }
        if !screenOK {
            s.send(["t": "notice", "level": "error", "code": "screen-permission",
                    "msg": "Allow Screen Recording for Duo Mac on the Mac (the window there has an Allow button), then relaunch it."])
            DispatchQueue.main.async {
                if !self.askedForScreen {
                    self.askedForScreen = true
                    CGRequestScreenCaptureAccess()
                }
            }
            return
        }
        source.start(width: size.w, height: size.h, fps: options.testPattern ? 30 : 60) { [weak self, weak s] err in
            guard let self, let err, let s else { return }
            self.server.queue.async { self.reportCaptureError(err, to: s) }
        }
        DispatchQueue.main.async { self.setAwake(self.config.keepAwake) }
    }

    /// Wakes the Mac's screens if they're asleep and waits (up to 3 s) until they're on.
    @discardableResult
    static func wakeDisplays() -> Bool {
        guard CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return false }
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Duo Mac: iPhone connected" as CFString, kIOPMUserActiveLocal, &id)
        let deadline = Date().addingTimeInterval(3)
        while CGDisplayIsAsleep(CGMainDisplayID()) != 0 && Date() < deadline { usleep(100_000) }
        Log.info(CGDisplayIsAsleep(CGMainDisplayID()) != 0 ? "The Mac's screen didn't wake up" : "Woke the Mac's screen")
        IOPMAssertionRelease(id)
        return true
    }

    static func screenIsLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false || (d["kCGSSessionOnConsoleKey"] as? Bool) == false
    }

    static var lastWake = Date.distantPast
    private static var unlockedSince: Date?

    /// Unlocked, screen on, and steadily so for 2 s: right after the screen wakes the session can briefly
    /// look unlocked while the lock screen is up, and reconfiguring displays there goes wrong.
    static func unlockedForSure() -> Bool {
        let ok = !screenIsLocked() && CGDisplayIsAsleep(CGMainDisplayID()) == 0
        if !ok { unlockedSince = nil; return false }
        let since = unlockedSince ?? Date()
        unlockedSince = since
        return Date().timeIntervalSince(since) >= 2 && Date().timeIntervalSince(lastWake) >= 3
    }

    /// Desktop size of the Duo display in points: a fixed width per size choice,
    /// height from the phone's screen area so it fills it exactly.
    private func nanoPoints(for s: Session) -> (w: Int, h: Int) {
        let aspect = s.box.height > 0 ? s.box.width / s.box.height : 1.4
        // Larger text = the smallest desktop macOS still renders sharp (found and remembered on first
        // use); Default and More space are a bit roomier.
        let smallest = max(540, Double(UserDefaults.standard.integer(forKey: "nanoMinRetinaWidth")))
        let width: Double
        switch s.nanoSize {
        case "large": width = smallest
        case "more": width = smallest * 1.3
        default: width = smallest * 1.12
        }
        // Not too wide (a very wide, short desktop breaks macOS window placement), but as tall as a
        // phone held upright, so Screen only fills even a regular iPhone edge to edge.
        let h = min(1800, max(480, width / max(0.45, min(aspect, 1.8))))
        return (Int(width) & ~1, Int(h.rounded()) & ~1)
    }

    /// After the phone leaves, keep the Duo display a minute (folding and unfolding shouldn't
    /// reshuffle the Mac's screen), then put everything back. main thread
    private func scheduleNanoTeardown() {
        nanoTeardown?.cancel()
        guard nano.isActive || source.targetDisplayID != nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Never reconfigure displays at the lock screen or while they sleep: try again later.
            if NanoCore.screenIsLocked() || DisplayInfo.activeDisplays().allSatisfy({ CGDisplayIsAsleep($0) != 0 }) {
                Log.info("Mac locked or asleep: keeping the Duo display until it's unlocked")
                self.nanoTeardown = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, self.nanoTeardown == nil, !self.model.connected else { return }
                    self.scheduleNanoTeardown()
                }
                return
            }
            self.nano.destroy()
            self.source.targetDisplayID = nil
            self.model.nanoInfo = ""
            self.server.queue.async {
                DispatchQueue.main.sync {
                    self.source.refreshInfo()
                    self.injector.bounds = self.source.info.bounds
                }
            }
        }
        nanoTeardown = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: item)
    }

    /// The phone ended the session: hang up and put the Mac's screen back immediately.
    func endSession(_ s: Session) {
        guard session === s else { return }
        Log.info("📱 \(s.clientName) ended the session")
        s.ws.close()
        detach(s)
        DispatchQueue.main.async {
            self.nanoTeardown?.perform()
            self.nanoTeardown?.cancel()
            self.nanoTeardown = nil
        }
    }

    /// Button on the Mac: end the phone's session and put the Mac's screen back right now.
    func restoreScreenNow() {
        server.queue.async {
            if let s = self.session {
                self.endSession(s)
            } else {
                DispatchQueue.main.async {
                    self.nanoTeardown?.perform()
                    self.nanoTeardown?.cancel()
                    self.nanoTeardown = nil
                }
            }
        }
    }

    /// The phone picked another display to show/control.
    func switchDisplay(_ s: Session, index: Int) {
        guard session === s, !options.testPattern else { return }
        let count = DispatchQueue.main.sync { DisplayInfo.activeDisplays().count }
        guard index >= 0, index < count else { return }
        Log.info("Switching to display \(index)")
        source.stop()
        DispatchQueue.main.sync { self.source.displayIndex = index }
        s.refresh()
        startStreaming(for: s)
    }

    /// Box size or quality changed (rotation, hinge position, settings).
    func reconfigure(_ s: Session) {
        guard session === s else { return }
        if s.nanoOn {
            startStreaming(for: s, reshape: false) // keeps the Duo display's shape, resizes the stream
            return
        }
        let size = streamSize(for: s)
        s.send(["t": "stream", "stream": [size.w, size.h], "quality": s.quality.rawValue])
        source.resize(width: size.w, height: size.h)
        s.refresh()
    }

    private func reportCaptureError(_ err: Error, to s: Session) {
        let ns = err as NSError
        Log.warn("Screen capture failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        let msg: String
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 {
            msg = "Screen Recording isn't allowed yet. On the Mac: System Settings → Privacy & Security → Screen & System Audio Recording → turn on Duo Mac, then relaunch it."
        } else {
            msg = "The Mac couldn't capture its screen: \(ns.localizedDescription)"
        }
        s.send(["t": "notice", "level": "error", "code": "capture", "msg": msg])
    }

    /// Capture stopped by itself (Stop in the menu bar recording indicator, display unplugged…).
    /// The phone shows "Try again", which says hello again and restarts capture.
    private func captureFailed(_ err: Error) {
        server.queue.async {
            guard let s = self.session else { return }
            let ns = err as NSError
            Log.warn("Screen capture stopped: \(ns.domain) \(ns.code) \(ns.localizedDescription)")
            s.send(["t": "notice", "level": "error", "code": "capture",
                    "msg": "Screen sharing stopped on the Mac (\(ns.localizedDescription)). Tap Try again to restart it."])
        }
    }

    /// Stream resolution: the phone's screen area, but never below the Mac's own point
    /// resolution in "balanced" (so pinch-zoom stays sharp), capped by a pixel budget per quality.
    private func streamSize(for s: Session) -> (w: Int, h: Int) {
        let info = source.info
        let ptW = max(info.bounds.width, 320), ptH = max(info.bounds.height, 200)
        let aspect = ptW / ptH
        let fitW = min(s.box.width, s.box.height * aspect)
        var w: Double
        switch s.quality {
        case .fast: w = min(fitW, ptW)
        case .balanced: w = min(max(fitW, ptW), Double(info.pixelSize.width))
        case .sharp: w = Double(info.pixelSize.width)
        }
        var h = w / aspect
        var budget = s.quality.maxPixels
        if source.targetDisplayID != nil && s.quality != .fast {
            budget = max(budget, min(Double(s.box.width * s.box.height), 2_800_000))
        }
        if w * h > budget {
            let k = (budget / (w * h)).squareRoot()
            w *= k
            h *= k
        }
        return (max(160, Int(w) & ~1), max(100, Int(h) & ~1))
    }

    private func configMessage(for s: Session, size: (w: Int, h: Int)) -> [String: Any] {
        let info = source.info
        var display: [String: Any] = [
            "pt": [info.bounds.width, info.bounds.height],
            "px": [info.pixelSize.width, info.pixelSize.height],
            "name": info.name,
        ]
        if let n = info.notch, info.bounds.width > 0 {
            display["notch"] = [n.width / info.bounds.width, n.height / info.bounds.height]
        }
        let (screenOK, inputOK) = permissions()
        let current = displays.firstIndex(where: { $0.displayID == info.displayID }) ?? 0
        let list: [[String: Any]] = displays.enumerated().map { i, d in
            ["i": i, "name": d.name, "pt": [d.bounds.width, d.bounds.height], "main": d.displayID == CGMainDisplayID()]
        }
        return [
            "t": "config", "v": 1,
            "displays": list,
            "displayIndex": current,
            "nano": source.targetDisplayID != nil,
            "stream": [size.w, size.h],
            "quality": s.quality.rawValue,
            "display": display,
            "mac": ["name": mac.computerName, "model": mac.model, "chip": mac.chip,
                    "memory": mac.memoryGB, "os": mac.osVersion],
            "keyboard": keymap.json,
            "test": options.testPattern,
            "dryRun": injector.dryRun,
            "perms": ["screen": screenOK, "input": inputOK],
            "mic": ["installed": Microphone.isInstalled],
        ]
    }

    private func installKeymap(_ km: KeymapInfo) {
        injector.label = { code, shift, option in km.label(code, shift: shift, option: option) }
    }

    // MARK: Permissions, stats, power

    func permissions() -> (screen: Bool, input: Bool) {
        let screen = options.testPattern || CGPreflightScreenCaptureAccess()
        let input = injector.dryRun || AXIsProcessTrusted()
        return (screen, input)
    }

    /// main thread
    func refreshModel() {
        let url = pairingURL()
        if url != model.url || (url != nil && model.qr == nil) {
            model.url = url ?? ""
            model.qr = url.flatMap { QR.image($0) }
        }
        let c = config
        model.pairCode = ConfigStore.formatted(c.pairCode)
        model.tailscale = tsStatus
        model.localMode = localMode
        model.allowConnections = c.allowConnections
        model.stayReachable = c.stayReachable
        model.keepAwake = c.keepAwake
        model.testMode = options.testPattern
        model.dryRun = injector.dryRun
        model.keyboardLayout = keymap.layoutName + (keymap.iso ? " · ISO" : "")
        model.micInstalled = Microphone.isInstalled
        refreshPermissions()
    }

    // MARK: The iPhone's microphone

    /// Where build.sh puts the driver: next to the installed helper (or in build/ when run from there).
    var microphoneDriverSource: URL? {
        let candidates = [webRoot.deletingLastPathComponent().appendingPathComponent(Microphone.driverName),
                          URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
                              .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(Microphone.driverName)]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The phone turned its microphone on or off (or went away). main thread
    func setMicrophone(_ on: Bool, for s: Session? = nil) {
        if on {
            let ok = microphone.start()
            server.queue.async { s?.send(["t": "mic", "on": ok, "installed": Microphone.isInstalled]) }
        } else {
            microphone.stop()
        }
        model.micActive = microphone.active
    }

    /// main thread
    private func refreshPermissions() {
        let (screen, input) = permissions()
        if model.screenOK != screen || model.inputOK != input {
            model.screenOK = screen
            model.inputOK = input
            server.queue.async { self.session?.send(["t": "perms", "screen": screen, "input": input]) }
        }
    }

    /// main thread
    private func tickStats() {
        server.queue.async {
            for p in self.pending.values where Date().timeIntervalSince(p.lastMessageAt) > 10 {
                p.ws.close()
                self.detach(p)
            }
            guard let s = self.session else { return }
            if let id = s.deviceID { self.auth.keepTicketsFresh(for: id) }
            if Date().timeIntervalSince(s.lastInputAt) > NanoCore.idleLimit {
                self.auth.log.add("\(s.clientName) disconnected after \(Int(NanoCore.idleLimit / 60)) minutes without use")
                if let id = s.deviceID { self.auth.revokeTickets(id) }
                s.send(["t": "notice", "level": "info", "code": "idle",
                        "msg": "Disconnected after \(Int(NanoCore.idleLimit / 60)) minutes without use."])
                s.ws.close(code: 4002)
                self.detach(s)
                return
            }
            if s.nanoWaitingForUnlock && NanoCore.unlockedForSure() {
                Log.info("Mac unlocked: switching to the Duo display")
                self.startStreaming(for: s)
            }
            // The phone pings every 2 s; silence means it was folded shut, backgrounded or left the Wi-Fi.
            if Date().timeIntervalSince(s.lastMessageAt) > 8 {
                Log.info("📱 \(s.clientName) went quiet; closing the connection")
                s.ws.close()
                self.detach(s)
                return
            }
            self.statTicks += 1
            let captured = self.source.framesCaptured
            if self.statTicks % 5 == 0 {
                Log.info("Stats: captured \((captured - self.lastCaptured) / 5)/s, waiting for \(s.outstandingCount) ack(s), rtt via phone")
                self.lastCaptured = captured
            }
            s.takeStats { frames, bytes, encode, rtt, qscale in
                if self.statTicks % 5 == 0 {
                    Log.info("Stats: sent \(frames) fps, \(bytes / 1024) KB/s, encode \(frames > 0 ? Int(encode / Double(frames) * 1000) : 0) ms, frame round trip \(Int(rtt * 1000)) ms, quality \(Int(qscale * 100))%")
                }
                let kbps = Double(bytes) / 1024
                let ms = frames > 0 ? encode / Double(frames) * 1000 : 0
                s.send(["t": "stats", "fps": frames, "kbps": Int(kbps), "encodeMs": (ms * 10).rounded() / 10,
                        "frameRtt": Int(rtt * 1000), "q": Int(qscale * 100)])
                DispatchQueue.main.async {
                    self.model.fps = Double(frames)
                    self.model.kbps = kbps
                }
            }
        }
    }

    /// main thread
    func setAwake(_ on: Bool) {
        if on && !awakeHeld {
            let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "Duo Mac: iPhone connected" as CFString, &awakeID)
            awakeHeld = r == kIOReturnSuccess
        } else if !on && awakeHeld {
            IOPMAssertionRelease(awakeID)
            awakeHeld = false
        }
    }

    /// main thread
    func setKeepAwake(_ on: Bool) {
        updateConfig { $0.keepAwake = on }
        model.keepAwake = on
        if !on { setAwake(false) } else if model.connected { setAwake(true) }
    }

}

enum WebRoot {
    /// The `web` folder next to (or above) the executable, so the helper works from the build folder
    /// and from `swift run` alike.
    static func locate(override: String?) -> URL {
        if let o = override { return URL(fileURLWithPath: o).standardizedFileURL }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = exe.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("web")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path) {
                return candidate.standardizedFileURL
            }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web")
    }
}
