import AppKit
import SwiftUI
import Combine
import ApplicationServices

struct PairingPrompt: Equatable, Identifiable {
    let id: UUID
    let name: String
    let from: String
    let match: String
}

struct DeviceRow: Equatable, Identifiable {
    let id: String
    let name: String
    let detail: String
}

final class AppModel: ObservableObject {
    @Published var url = ""
    @Published var qr: NSImage?
    @Published var pairCode = ""
    @Published var tailscale = Tailscale.Status()
    @Published var localMode = false
    @Published var allowConnections = true
    @Published var stayReachable = false
    @Published var pairing: PairingPrompt?
    @Published var devices: [DeviceRow] = []
    @Published var screenOK = false
    @Published var inputOK = false
    @Published var connected = false
    @Published var clientName = ""
    @Published var fps = 0.0
    @Published var kbps = 0.0
    @Published var keepAwake = true
    @Published var serverError: String?
    @Published var testMode = false
    @Published var dryRun = false
    @Published var keyboardLayout = ""
    @Published var nanoInfo = ""
    /// The browser an iPhone last opened the pairing page in (the Add to Home Screen steps differ).
    @Published var phoneBrowser: PhoneBrowser?
    @Published var micInstalled = false
    @Published var micActive = false
    @Published var micNeedsUpdate = false
}

/// Things the window's buttons do.
struct StatusActions {
    let core: NanoCore

    func allowScreenRecording() {
        // First call shows the system prompt and adds us to the list; afterwards it just returns false.
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    /// Adds the Duo Mac Microphone (asks for an administrator password).
    func installMicrophone() {
        guard let src = core.microphoneDriverSource else {
            let a = NSAlert()
            a.messageText = "The microphone driver isn't built yet"
            a.informativeText = "Run ./build.sh in the duo-mac folder, then try again."
            a.runModal()
            return
        }
        Microphone.install(from: src) { ok, message in
            self.core.refreshModel()
            self.core.microphoneInstalled()
            Log.info("Microphone install: \(ok ? "done" : "failed: \(message ?? "")")")
            if !ok, let message, !message.contains("-128") { // -128: cancelled
                let a = NSAlert()
                a.messageText = "Couldn't add the Duo Mac Microphone"
                a.informativeText = message
                a.runModal()
            }
        }
    }

    func allowAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    func relaunch() {
        core.shutdown()
        if let launcher = ProcessInfo.processInfo.environment["NANO_LAUNCHER_APP"] {
            // Our launcher app owns the permissions; reopen it after we've quit.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", launcher]
            try? p.run()
        } else if let exe = Bundle.main.executableURL {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; \"$0\" &", exe.path]
            try? p.run()
        }
        exit(0)
    }

    func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(core.model.url, forType: .string)
    }

    func setKeepAwake(_ on: Bool) { core.setKeepAwake(on) }
    func setAllow(_ on: Bool) { core.setAllowConnections(on) }
    func setStayReachable(_ on: Bool) { core.setStayReachable(on) }
    func answer(_ id: UUID, allow: Bool) { core.answerPairing(id, allow: allow) }
    func checkTailscale() { core.refreshTailscale() }

    func remove(_ d: DeviceRow) {
        let a = NSAlert()
        a.messageText = "Remove “\(d.name)”?"
        a.informativeText = "It's disconnected right away and can't connect again unless you pair it again here, at this Mac."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { core.removeDevice(d.id) }
    }

    func newPairingCode() {
        let a = NSAlert()
        a.messageText = "Create a new pairing code?"
        a.informativeText = "The current QR code stops working for new iPhones. iPhones you've already paired keep working."
        a.addButton(withTitle: "Create New Code")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { core.resetPairing() }
    }

    func openLog() {
        let url = core.auth.log.url
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        NSWorkspace.shared.open(url)
    }

    func openTailscale() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app")) }
    func getTailscale() { open("https://tailscale.com/download/mac") }
    func signIn() { core.model.tailscale.authURL.map { open($0) } ?? openTailscale() }
    func enableHTTPS() { open(core.model.tailscale.enableURL ?? "https://login.tailscale.com/admin/dns") }
    func openAdmin() { open("https://login.tailscale.com/admin/machines") }

    private func open(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

/// Menu bar icon: green while an iPhone is in control. Clicking it opens the Duo Mac panel.
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let core: NanoCore
    private let popover = NSPopover()
    private var watch: AnyCancellable?

    init(core: NanoCore, open: @escaping (SettingsSection?) -> Void) {
        self.core = core
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuPanelView(
            model: core.model, actions: StatusActions(core: core), open: open,
            close: { [weak self] in self?.popover.performClose(nil) }))
        item.button?.target = self
        item.button?.action = #selector(toggle)
        watch = core.model.$connected.receive(on: RunLoop.main).sink { [weak self] on in self?.update(on) }
        update(false)
    }

    /// The Duo Mac glyph (a MacBook with a folded iPhone Duo in front of it), drawn by macOS as a template.
    private lazy var glyph: NSImage? = {
        guard let img = NSImage(contentsOf: core.webRoot.appendingPathComponent("menubar-icon.png")) else { return nil }
        img.size = NSSize(width: 29, height: 18) // the PNG is @2x
        img.isTemplate = true
        img.accessibilityDescription = "Duo Mac"
        return img
    }()

    private func update(_ connected: Bool) {
        item.button?.image = glyph ?? NSImage(systemSymbolName: "laptopcomputer.and.iphone", accessibilityDescription: "Duo Mac")
        item.button?.contentTintColor = connected ? .systemGreen : nil
        item.button?.toolTip = connected ? "Duo Mac: \(core.model.clientName)" : "Duo Mac"
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = item.button else { return }
        core.refreshModel()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func showPanel() { if !popover.isShown { toggle() } }
}

/// A small banner at the top right of the Mac's screen ("iPhone 15 Pro is controlling this Mac").
enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(title: String, detail: String) {
        let size = NSSize(width: 360, height: 76)
        let p = panel ?? {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel = p
            return p
        }()
        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.masksToBounds = true
        let host = NSHostingView(rootView:
            HStack(spacing: 12) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 26))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(width: size.width, height: size.height))
        host.frame = fx.bounds
        fx.addSubview(host)
        p.contentView = fx
        if let screen = NSScreen.screens.first {
            let f = screen.visibleFrame
            p.setFrame(NSRect(x: f.maxX - size.width - 16, y: f.maxY - size.height - 12, width: size.width, height: size.height),
                       display: true)
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let core: NanoCore
    let headless: Bool
    private var statusItem: StatusItemController?
    private var settingsWindow: NSWindow?
    private var guideWindow: NSWindow?
    private var approvalWindow: NSWindow?
    private let router = UIRouter()
    private var watchers: [AnyCancellable] = []

    init(core: NanoCore, headless: Bool) {
        self.core = core
        self.headless = headless
    }

    private var parentWatch: DispatchSourceProcess?

    func applicationDidFinishLaunching(_ notification: Notification) {
        core.start()
        // Started by Duo Mac.app: quit with it, even if it's force-quit, so port 8890 is freed.
        if ProcessInfo.processInfo.environment["NANO_LAUNCHER_APP"] != nil {
            let src = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .main)
            src.setEventHandler {
                Log.info("Launcher quit; quitting too")
                NSApp.terminate(nil)
            }
            src.resume()
            parentWatch = src
        }
        if headless {
            core.printBanner()
            return
        }
        // A menu bar app: no Dock icon unless one of its windows is open.
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        if let icon = core.appIcon { NSApp.applicationIconImage = icon }
        statusItem = StatusItemController(core: core) { [weak self] section in
            if let section { self?.showSettings(section) } else { self?.showGuide() }
        }
        core.onPairingRequest = { [weak self] in self?.showApproval() }
        watchers = [
            core.model.$pairing.map { $0 == nil }.removeDuplicates().receive(on: RunLoop.main)
                .sink { [weak self] none in if none { self?.approvalWindow?.close() } },
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.keepOnScreen() },
            NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in DispatchQueue.main.async { self?.updateActivationPolicy() } },
        ]
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showFromLauncher),
                                                            name: Notification.Name("com.riccardoconti.duomac.show"), object: nil)
        // First run, or something still missing: the setup guide. Otherwise stay in the menu bar.
        // (The model fills in a moment after launch: Tailscale and the paired devices load async.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.core.refreshModel()
            if !SetupStep.allDone(self.core.model) { self.showGuide() }
        }
    }

    /// Opening the app again (Finder, Spotlight, the launcher): the panel, or the guide if setup isn't done.
    @objc private func showFromLauncher() { reopen() }

    private func reopen() {
        if !SetupStep.allDone(core.model) { showGuide() } else { showSettings(.general) }
    }

    func showSettings(_ section: SettingsSection) {
        router.section = section
        if settingsWindow == nil {
            let view = SettingsView(model: core.model, router: router, actions: StatusActions(core: core),
                                    openGuide: { [weak self] in self?.showGuide() })
            settingsWindow = makeWindow(view, title: "Duo Mac", size: NSSize(width: 680, height: 470), resizable: true)
            settingsWindow?.toolbarStyle = .unified
        }
        present(settingsWindow)
    }

    func showGuide() {
        if guideWindow == nil {
            let view = SetupGuideView(model: core.model, actions: StatusActions(core: core),
                                      finish: { [weak self] in self?.guideWindow?.close() })
            guideWindow = makeWindow(view, title: "Set Up Duo Mac", size: NSSize(width: 540, height: 470), resizable: false)
            guideWindow?.titlebarAppearsTransparent = true
        }
        present(guideWindow)
    }

    private func showApproval() {
        guard let p = core.model.pairing else { return }
        approvalWindow?.close()
        let view = ApprovalCard(prompt: p, actions: StatusActions(core: core)).frame(width: 340)
        let w = makeWindow(view, title: "New iPhone", size: NSSize(width: 340, height: 300), resizable: false)
        w.level = .floating
        approvalWindow = w
        present(w)
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func makeWindow<V: View>(_ view: V, title: String, size: NSSize, resizable: Bool) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = resizable ? [.minSize] : [.preferredContentSize]
        let w = NSWindow(contentViewController: host)
        w.styleMask = resizable ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.titled, .closable]
        w.title = title
        w.isReleasedWhenClosed = false
        w.setContentSize(size)
        w.center()
        return w
    }

    private func present(_ w: NSWindow?) {
        guard let w else { return }
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            // The helper is a bare executable with no bundle icon, so the Dock shows a generic "exec"
            // icon unless the app icon is set again once the Dock tile exists.
            setDockIcon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.setDockIcon() }
        }
        fit(w, center: !w.isVisible)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func setDockIcon() {
        if let icon = core.appIcon { NSApp.applicationIconImage = icon }
    }

    /// Never bigger than the visible part of its screen: at "Larger text" the Duo display is small.
    private func fit(_ w: NSWindow, center: Bool) {
        guard let vis = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = w.frame
        f.size.width = min(f.width, vis.width - 16)
        f.size.height = min(f.height, vis.height - 16)
        if center {
            f.origin = NSPoint(x: vis.midX - f.width / 2, y: vis.midY - f.height / 2)
        } else {
            f.origin.x = min(max(f.minX, vis.minX + 8), vis.maxX - f.width - 8)
            f.origin.y = min(max(f.maxY - f.height, vis.minY + 8), vis.maxY - f.height - 8)
        }
        w.setFrame(f, display: true)
    }

    private func keepOnScreen() {
        for w in [settingsWindow, guideWindow, approvalWindow].compactMap({ $0 }) where w.isVisible { fit(w, center: false) }
    }

    private func updateActivationPolicy() {
        let open = [settingsWindow, guideWindow, approvalWindow].contains { $0?.isVisible == true }
        if !open { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reopen()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.shutdown()
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Duo Mac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Duo Mac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Duo Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

/// Renders the status window to a PNG (for checking the layout without a screen).
enum UISnapshot {
    static func render(core: NanoCore, to path: String) {
        core.refreshModel()
        let env = ProcessInfo.processInfo.environment
        let dark = env["NANO_SNAPSHOT_DARK"] == "1"
        if env["NANO_SNAPSHOT_DEMO"] == "1" {
            // Sample content for checking the layout of every section.
            core.model.pairing = PairingPrompt(id: UUID(), name: "iPhone Duo", from: "100.101.102.103 (you@example.com)", match: "4821")
            if env["NANO_SNAPSHOT_VIEW"] != "guide" {
                core.model.devices = [DeviceRow(id: "a", name: "iPhone Duo", detail: "Passkey + PIN · added 23 Oct · last unlocked 23 Oct, 10:31")]
            }
            core.model.qr = QR.image("https://your-mac.example.ts.net/?pair=ABCD2345")
            core.model.pairCode = "ABCD-2345"
            core.model.url = "https://your-mac.example.ts.net"
        }
        core.model.phoneBrowser = env["NANO_SNAPSHOT_BROWSER"].flatMap(PhoneBrowser.init(rawValue:))
        if env["NANO_SNAPSHOT_READY"] == "1" {
            // Everything set up, an iPhone connected (README pictures).
            core.model.pairing = nil
            core.model.tailscale = Tailscale.Status(phase: .ready, dnsName: "your-mac.tail1234.ts.net", login: "you@example.com",
                                                    phones: ["iPhone Duo"], serving: true, reachable: true)
            core.model.screenOK = true
            core.model.inputOK = true
            core.model.connected = true
            core.model.clientName = "iPhone Duo · 100.101.102.103"
            core.model.fps = 58
            core.model.kbps = 640
            core.model.stayReachable = true
        }
        let actions = StatusActions(core: core)
        let view: AnyView
        switch env["NANO_SNAPSHOT_VIEW"] ?? "menu" {
        case "guide": view = AnyView(SetupGuideView(model: core.model, actions: actions, finish: {},
                                                    page: Int(env["NANO_SNAPSHOT_PAGE"] ?? "") ?? -1))
        case "approval": view = AnyView(ApprovalCard(prompt: core.model.pairing!, actions: actions).frame(width: 340))
        case "menu": view = AnyView(MenuPanelView(model: core.model, actions: actions, open: { _ in }, close: {}))
        case "mocks": view = AnyView(HStack(spacing: 16) { ForEach(MockScene.allCases, id: \.self) { PhoneMock(scene: $0, width: 150) } }.padding(20))
        default:
            let r = UIRouter()
            r.section = SettingsSection(rawValue: env["NANO_SNAPSHOT_VIEW"] ?? "") ?? .general
            view = AnyView(SettingsView(model: core.model, router: r, actions: actions, openGuide: {}).frame(width: 680, height: 470))
        }
        if let icon = core.appIcon { NSApp.applicationIconImage = icon }
        let host = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.controlActiveState, .key)) // draw switches and selections as in a focused window
        let size = host.fittingSize
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("UI snapshot written to \(path)")
    }
}
