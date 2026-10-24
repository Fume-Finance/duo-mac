// The Mac side's interface: a menu bar panel for everyday use, a Settings window (System Settings
// style, opened from the panel) and a step-by-step setup guide for the first run.
import AppKit
import SwiftUI

// MARK: - Shared bits

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, addPhone, devices, setup
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .addPhone: "Add iPhone"
        case .devices: "Paired iPhones"
        case .setup: "Setup"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .addPhone: "qrcode"
        case .devices: "iphone.gen3"
        case .setup: "checklist"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .addPhone: .blue
        case .devices: .green
        case .setup: .orange
        }
    }
}

/// Which settings page is showing, shared by the window and whoever opens it.
final class UIRouter: ObservableObject {
    @Published var section: SettingsSection = .general
}

/// The setup steps, in order, and whether each is done.
enum SetupStep: Int, CaseIterable, Identifiable {
    case tailscale, https, phoneTailscale, screen, accessibility, pair
    var id: Int { rawValue }

    func done(_ m: AppModel) -> Bool {
        let p = m.tailscale.phase
        switch self {
        case .tailscale: return m.localMode || p == .needsHTTPS || p == .ready
        case .https: return m.localMode || p == .ready
        case .phoneTailscale: return m.localMode || !m.tailscale.phones.isEmpty || !m.devices.isEmpty
        case .screen: return m.screenOK
        case .accessibility: return m.inputOK
        case .pair: return !m.devices.isEmpty
        }
    }

    var title: String {
        switch self {
        case .tailscale: "Connect this Mac"
        case .https: "Turn on HTTPS"
        case .phoneTailscale: "Connect your iPhone"
        case .screen: "Allow Screen Recording"
        case .accessibility: "Allow Accessibility"
        case .pair: "Pair your iPhone"
        }
    }

    var short: String {
        switch self {
        case .tailscale: "Tailscale on Mac"
        case .https: "HTTPS"
        case .phoneTailscale: "Tailscale on iPhone"
        case .screen: "Screen Recording"
        case .accessibility: "Accessibility"
        case .pair: "Pair iPhone"
        }
    }

    var symbol: String {
        switch self {
        case .tailscale: "network"
        case .https: "lock.shield.fill"
        case .phoneTailscale: "iphone.gen3.radiowaves.left.and.right"
        case .screen: "rectangle.dashed.badge.record"
        case .accessibility: "keyboard.fill"
        case .pair: "qrcode.viewfinder"
        }
    }

    static func allDone(_ m: AppModel) -> Bool { allCases.allSatisfy { $0.done(m) } }
    static func firstOpen(_ m: AppModel) -> SetupStep? { allCases.first { !$0.done(m) } }
}

/// A System Settings–style icon: a symbol on a small coloured rounded square.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.gradient))
    }
}

struct StatusTick: View {
    let done: Bool
    var body: some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 16))
            .foregroundStyle(done ? Color.green : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
    }
}

extension AppModel {
    var statusLine: String {
        if connected { return clientName.components(separatedBy: " · ").first ?? clientName }
        return allowConnections ? "No iPhone connected" : "iPhone connections are off"
    }

    var rateLine: String {
        String(format: "%.0f fps · %@", fps, kbps >= 1024 ? String(format: "%.1f MB/s", kbps / 1024) : String(format: "%.0f KB/s", kbps))
    }
}

// MARK: - Pairing request

struct ApprovalCard: View {
    let prompt: PairingPrompt
    let actions: StatusActions
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            Image(systemName: "iphone.gen3.badge.exclamationmark")
                .font(.system(size: compact ? 24 : 40))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
            Text("Allow “\(prompt.name)”?")
                .font(compact ? .headline : .title3.weight(.semibold))
            Text("Only if it's your iPhone and it shows:")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(prompt.match)
                .font(.system(size: compact ? 26 : 38, weight: .bold, design: .rounded).monospacedDigit())
                .tracking(compact ? 6 : 10)
            HStack {
                Button("Deny") { actions.answer(prompt.id, allow: false) }
                    .frame(maxWidth: .infinity)
                Button("Allow") { actions.answer(prompt.id, allow: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(compact ? .regular : .large)
            if !compact {
                Text(prompt.from).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(compact ? 12 : 24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(compact ? 0.12 : 0)))
    }
}

// MARK: - Menu bar panel

struct MenuPanelView: View {
    @ObservedObject var model: AppModel
    let actions: StatusActions
    let open: (SettingsSection?) -> Void   // nil: the setup guide
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let p = model.pairing { ApprovalCard(prompt: p, actions: actions, compact: true) }
            connection
            if !SetupStep.allDone(model) {
                Button { close(); open(nil) } label: {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Finish setting up").fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
            }
            VStack(spacing: 8) {
                toggle("Allow iPhone connections", model.allowConnections, actions.setAllow)
                toggle("Stay reachable while away", model.stayReachable, actions.setStayReachable)
                toggle("Keep screen on while connected", model.keepAwake, actions.setKeepAwake)
            }
            .padding(.horizontal, 2)
            Divider()
            VStack(spacing: 2) {
                MenuRow(title: "Add iPhone…", symbol: "plus") { close(); open(.addPhone) }
                MenuRow(title: "Settings…", symbol: "gearshape") { close(); open(.general) }
                MenuRow(title: "Quit Duo Mac", symbol: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 34, height: 34)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Duo Mac").font(.headline)
                Text(model.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }

    private var connection: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(model.connected ? Color.green.opacity(0.18) : Color.secondary.opacity(0.12))
                Image(systemName: model.connected ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3.slash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(model.connected ? Color.green : Color.secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: model.connected)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.connected ? model.statusLine : (model.allowConnections ? "Waiting for your iPhone" : "Connections are off"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if model.connected {
                    Text(model.rateLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !model.nanoInfo.isEmpty {
                    Text(model.nanoInfo.replacingOccurrences(of: " — this Mac's screen mirrors it", with: ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if model.connected || !model.nanoInfo.isEmpty {
                Button(model.connected ? "End" : "Restore") { actions.core.restoreScreenNow() }
                    .controlSize(.small)
                    .help("Disconnects the iPhone and gives this Mac its normal screen back now")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private func toggle(_ title: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            Toggle(title, isOn: Binding(get: { on }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A menu-like row: highlights on hover, like the items of a real menu.
struct MenuRow: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .foregroundStyle(hover ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var router: UIRouter
    let actions: StatusActions
    let openGuide: () -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SettingsSection?>(get: { router.section }, set: { if let s = $0 { router.section = s } })) {
                ForEach(SettingsSection.allCases) { s in
                    Label { Text(s.title) } icon: { IconTile(symbol: s.symbol, tint: s.tint, size: 20) }
                        .badge(s == .setup && !SetupStep.allDone(model) ? Text("!") : nil)
                        .tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            Group {
                switch router.section {
                case .general: GeneralPage(model: model, actions: actions)
                case .addPhone: AddPhonePage(model: model, actions: actions, openGuide: openGuide)
                case .devices: DevicesPage(model: model, actions: actions)
                case .setup: SetupPage(model: model, actions: actions, openGuide: openGuide)
                }
            }
            .navigationTitle(router.section.title)
        }
        .frame(minWidth: 580, minHeight: 360)
    }
}

struct GeneralPage: View {
    @ObservedObject var model: AppModel
    let actions: StatusActions

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: model.connected ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3",
                             tint: model.connected ? .green : .gray, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.connected ? model.statusLine : (model.allowConnections ? "Waiting for your iPhone" : "Connections are off"))
                            .font(.headline)
                        Text(model.connected ? model.rateLine : "Open Duo Mac on your iPhone to connect.")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if !model.nanoInfo.isEmpty {
                            Text(model.nanoInfo).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.connected || !model.nanoInfo.isEmpty {
                        Button(model.connected ? "End Session" : "Restore Screen") { actions.core.restoreScreenNow() }
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Toggle("Allow iPhone connections", isOn: Binding(get: { model.allowConnections }, set: actions.setAllow))
                Toggle(isOn: Binding(get: { model.stayReachable }, set: actions.setStayReachable)) {
                    Text("Stay reachable while I'm away")
                    Text("This Mac won't sleep. Keep it plugged in; a closed MacBook still sleeps without an external display.")
                }
                Toggle("Keep the screen on while connected", isOn: Binding(get: { model.keepAwake }, set: actions.setKeepAwake))
            }
            Section {
                HStack(spacing: 12) {
                    IconTile(symbol: "mic.fill", tint: model.micActive ? .orange : .pink, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPhone microphone")
                        Text(model.micInstalled
                             ? (model.micActive ? "In use: Mac apps hear your iPhone." : "Turn it on in the Duo Mac settings on your iPhone.")
                             : "Let Mac apps (dictation, calls, voice mode) hear your iPhone's microphone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !model.micInstalled { Button("Install…", action: actions.installMicrophone) }
                    else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            Section {
                LabeledContent("Keyboard layout", value: model.keyboardLayout)
                LabeledContent("Address") {
                    Text(model.tailscale.dnsName ?? "—").textSelection(.enabled).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AddPhonePage: View {
    @ObservedObject var model: AppModel
    let actions: StatusActions
    let openGuide: () -> Void

    var body: some View {
        Form {
            if let qr = model.qr, model.allowConnections {
                Section {
                    HStack(spacing: 18) {
                        ScanQR(qr: qr, side: 104)
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Scan it with the iPhone's Camera", systemImage: "camera.fill").font(.headline)
                            Text("It opens Duo Mac in the iPhone's browser.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    InstallGuide(detected: model.phoneBrowser, phoneWidth: 100, listWidth: 230)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } header: {
                    Text("Then add it to the Home Screen")
                } footer: {
                    Text("Open Duo Mac from the Home Screen, then click Allow on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Pairing code") {
                        Text(model.pairCode).font(.system(.body, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                    }
                    LabeledContent("Link") {
                        HStack {
                            Text(model.url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button(action: actions.copyLink) { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("Copy link")
                        }
                    }
                    HStack {
                        Spacer()
                        Button("New Pairing Code…", action: actions.newPairingCode)
                    }
                }
            } else {
                Section {
                    ContentUnavailableView {
                        Label(model.allowConnections ? "Finish setup first" : "Connections are off",
                              systemImage: model.allowConnections ? "checklist" : "nosign")
                    } description: {
                        Text(model.allowConnections ? "The QR code appears once this Mac can be reached." : "Turn on iPhone connections in General.")
                    } actions: {
                        if model.allowConnections { Button("Open Setup Guide", action: openGuide) }
                        else { Button("Turn On") { actions.setAllow(true) } }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DevicesPage: View {
    @ObservedObject var model: AppModel
    let actions: StatusActions

    var body: some View {
        Form {
            Section {
                if model.devices.isEmpty {
                    Text("No iPhone paired yet.").foregroundStyle(.secondary)
                }
                ForEach(model.devices) { d in
                    HStack(spacing: 12) {
                        IconTile(symbol: "iphone.gen3", tint: .green, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name).fontWeight(.medium)
                            Text(d.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove…") { actions.remove(d) }
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text("A new iPhone can only pair after you click Allow here, at this Mac. Each one then unlocks with its passkey or PIN.")
            }
            Section("Security") {
                LabeledContent("Connection") {
                    Label(model.localMode ? "Local network" : "Private to your Tailscale network",
                          systemImage: "lock.fill").foregroundStyle(.secondary)
                }
                LabeledContent("Log") { Button("Connection Log…", action: actions.openLog) }
            }
        }
        .formStyle(.grouped)
    }
}

struct SetupPage: View {
    @ObservedObject var model: AppModel
    let actions: StatusActions
    let openGuide: () -> Void

    var body: some View {
        Form {
            Section {
                ForEach(SetupStep.allCases) { s in
                    HStack(spacing: 12) {
                        IconTile(symbol: s.symbol, tint: s.done(model) ? .green : .orange, size: 26)
                        Text(s.short)
                        Spacer()
                        StatusTick(done: s.done(model))
                    }
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Open Setup Guide…", action: openGuide)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Setup guide

struct SetupGuideView: View {
    @ObservedObject var model: AppModel
    let actions: StatusActions
    let finish: () -> Void
    /// nil: the welcome page; past the last step: all done.
    @State private var page: Int

    init(model: AppModel, actions: StatusActions, finish: @escaping () -> Void, page: Int? = nil) {
        self.model = model
        self.actions = actions
        self.finish = finish
        // Start at the welcome page the first time; after a relaunch, at the first unfinished step.
        let open = SetupStep.firstOpen(model)
        _page = State(initialValue: page ?? (SetupStep.allCases.filter { $0.done(model) }.isEmpty ? -1 : (open?.rawValue ?? SetupStep.allCases.count)))
    }

    private var step: SetupStep? { SetupStep(rawValue: page) }

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 18)
            Spacer(minLength: 8)
            Group {
                if page < 0 { welcome }
                else if let step { stepPage(step) }
                else { allSet }
            }
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            Spacer(minLength: 8)
            footer
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
        .frame(width: 560, height: 520)
        .animation(.spring(duration: 0.45), value: page)
        .onChange(of: step.map { $0.done(model) } ?? false) { _, done in
            // Move on by itself once the current step is done.
            guard done else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { if step?.done(model) == true { advance() } }
        }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in actions.core.refreshModel() }
    }

    private func advance() {
        let next = SetupStep.allCases.first { $0.rawValue > page && !$0.done(model) }
        page = next?.rawValue ?? SetupStep.allCases.count
    }

    @ViewBuilder private var footer: some View {
        if let step {
            HStack {
                Button("Back") { page = step.rawValue - 1 < 0 ? -1 : step.rawValue - 1 }
                Spacer()
                Button(step.done(model) ? "Continue" : "Skip for Now") { advanceFrom(step) }
            }
            .buttonStyle(.borderless)
        } else {
            Color.clear.frame(height: 16)
        }
    }

    /// The next step after this one (done or not), so Skip always moves forward.
    private func advanceFrom(_ s: SetupStep) {
        page = SetupStep(rawValue: s.rawValue + 1)?.rawValue ?? SetupStep.allCases.count
    }

    // A chip per step (its symbol, or a tick once done), joined by a line, with a short label.
    private var progress: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(SetupStep.allCases) { s in
                let done = s.done(model), current = s.rawValue == page
                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(done ? Color.green : (current ? Color.accentColor : Color.secondary.opacity(0.18)))
                            .frame(width: 30, height: 30)
                        Image(systemName: done ? "checkmark" : s.symbol)
                            .font(.system(size: done ? 13 : 12, weight: .bold))
                            .foregroundStyle(done || current ? Color.white : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .overlay(Circle().stroke(Color.accentColor.opacity(current && !done ? 0.35 : 0), lineWidth: 4).padding(-4))
                    Text(s.short)
                        .font(.system(size: 9.5, weight: current ? .semibold : .regular))
                        .foregroundStyle(current ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 74)
                }
                .contentShape(Rectangle())
                .onTapGesture { page = s.rawValue }
                .overlay(alignment: .topTrailing) {
                    if s.rawValue < SetupStep.allCases.count - 1 {
                        Rectangle()
                            .fill(done ? Color.green.opacity(0.6) : Color.secondary.opacity(0.2))
                            .frame(width: 40, height: 2)
                            .offset(x: 20, y: 14)
                    }
                }
            }
        }
        .opacity(page < 0 ? 0 : 1)
        .animation(.spring(duration: 0.3), value: model.screenOK)
        .animation(.spring(duration: 0.3), value: page)
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            HStack(spacing: 18) {
                Image(systemName: "laptopcomputer").font(.system(size: 58, weight: .light))
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolEffect(.pulse, options: .repeating)
                Image(systemName: "iphone.gen3").font(.system(size: 50, weight: .light))
            }
            .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
            Text("Your Mac, on your Duo").font(.largeTitle.weight(.bold))
            Text("A few quick steps. Each one ticks itself off when it's done.")
                .foregroundStyle(.secondary)
            Button("Get Started") { advance() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
    }

    private var allSet: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 76))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: page)
            Text("You're all set").font(.largeTitle.weight(.bold))
            Text("Duo Mac lives in the menu bar. Open it on your iPhone any time.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 20)).foregroundStyle(.secondary)
            Button("Done", action: finish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func stepPage(_ s: SetupStep) -> some View {
        if s == .pair && !s.done(model) { pairPage } else { plainStepPage(s) }
    }

    /// Scan, then Add to Home Screen tap by tap for the iPhone's browser, then Allow.
    private var pairPage: some View {
        VStack(spacing: 14) {
            Text(SetupStep.pair.title).font(.title.weight(.bold))
            HStack(alignment: .center, spacing: 22) {
                VStack(spacing: 10) {
                    if let qr = model.qr { ScanQR(qr: qr, side: 118) } else { ProgressView().frame(width: 134, height: 134) }
                    Label("Scan with the Camera", systemImage: "camera.fill").font(.callout).foregroundStyle(.secondary)
                }
                Rectangle().fill(.separator).frame(width: 1, height: 170)
                InstallGuide(detected: model.phoneBrowser, phoneWidth: 88, listWidth: 205)
            }
            Label("Then open it from the Home Screen and click Allow here", systemImage: "hand.thumbsup.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func plainStepPage(_ s: SetupStep) -> some View {
        let done = s.done(model)
        VStack(spacing: 14) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 70))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                        .symbolEffect(.bounce, value: done)
                } else {
                    illustration(s).transition(.opacity)
                }
            }
            .frame(height: 150)
            .animation(.spring(duration: 0.4), value: done)
            Text(s.title).font(.title.weight(.bold))
            if done {
                Text("Done.").foregroundStyle(.secondary)
            } else {
                HowStrip(items: how(s))
                Text(hint(s))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            if !done { actionButtons(s).padding(.top, 4) }
            if !done && (s == .screen || s == .accessibility) {
                // After an update macOS can show the switch on for the old copy of the app.
                Text("Already switched on? Select Duo Mac in that list, click –, then Open System Settings again.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
    }

    /// What to do, as three little pictures.
    private func how(_ s: SetupStep) -> [(String, String)] {
        switch s {
        case .tailscale: [("arrow.down.app", "Install Tailscale"), ("person.crop.circle", "Sign in"), ("checkmark.circle", "Connected")]
        case .https: [("safari", "Admin console"), ("lock.fill", "Enable HTTPS"), ("arrow.uturn.backward", "Come back")]
        case .phoneTailscale: [("arrow.down.app", "App Store"), ("person.crop.circle", "Same account"), ("power", "Turn it on")]
        case .screen: [("gearshape", "Open Settings"), ("switch.2", "Switch on Duo Mac"), ("arrow.clockwise", "Relaunch")]
        case .accessibility: [("gearshape", "Open Settings"), ("switch.2", "Switch on Duo Mac"), ("checkmark.circle", "Done")]
        case .pair: [("camera.fill", "Scan with Camera"), ("plus.app", "Add to Home Screen"), ("hand.thumbsup.fill", "Allow here")]
        }
    }

    private func hint(_ s: SetupStep) -> String {
        let ts = model.tailscale
        switch s {
        case .tailscale:
            switch ts.phase {
            case .notInstalled: return "Duo Mac uses Tailscale (free) to reach this Mac privately, from anywhere."
            case .needsLogin: return "Sign in to Tailscale."
            case .needsApproval: return "Approve this Mac in the Tailscale admin console."
            case .stopped, .notRunning: return "Turn Tailscale on."
            default: return "Starting Tailscale…"
            }
        case .https: return ts.detail == "MagicDNS is off" ? "Turn on MagicDNS and HTTPS in the admin console." : "One click in the Tailscale admin console."
        case .phoneTailscale: return "Use the same account as this Mac."
        case .screen: return "So your iPhone can show this Mac's screen."
        case .accessibility: return "So your iPhone can type and click."
        case .pair: return "Then open it from the Home Screen."
        }
    }

    @ViewBuilder private func actionButtons(_ s: SetupStep) -> some View {
        let ts = model.tailscale
        HStack {
            switch s {
            case .tailscale:
                switch ts.phase {
                case .notInstalled: primary("Get Tailscale", actions.getTailscale)
                case .needsLogin: primary("Sign In", actions.signIn)
                case .needsApproval: primary("Open Admin Console", actions.openAdmin)
                case .notRunning, .stopped: primary("Open Tailscale", actions.openTailscale)
                default: ProgressView().controlSize(.small)
                }
            case .https: primary("Turn On HTTPS", actions.enableHTTPS)
            case .phoneTailscale:
                primary("Get Tailscale for iPhone") { NSWorkspace.shared.open(URL(string: "https://apps.apple.com/app/tailscale/id1470499037")!) }
            case .screen:
                primary("Open System Settings", actions.allowScreenRecording)
                Button("Relaunch", action: actions.relaunch).controlSize(.large)
            case .accessibility: primary("Open System Settings", actions.allowAccessibility)
            case .pair:
                EmptyView()
            }
        }
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder private func illustration(_ s: SetupStep) -> some View {
        switch s {
        case .screen: SettingsToggleHint(pane: "Screen & System Audio Recording", symbol: "rectangle.dashed.badge.record")
        case .accessibility: SettingsToggleHint(pane: "Accessibility", symbol: "accessibility")
        case .pair:
            if let qr = model.qr { ScanHint(qr: qr) } else { ProgressView() }
        case .tailscale: LinkHint(left: "laptopcomputer", leftDone: false, right: "network")
        case .phoneTailscale: LinkHint(left: "laptopcomputer", leftDone: true, right: "iphone.gen3")
        case .https: AddressBarHint(host: model.tailscale.dnsName ?? "your-mac.ts.net")
        }
    }
}

/// An animated miniature of the System Settings row to switch on: a pointer moves to the switch and
/// flips it, over and over.
struct SettingsToggleHint: View {
    let pane: String
    let symbol: String
    @State private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.blue)
                Text("Privacy & Security › \(pane)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                }
                Text("Duo Mac").fontWeight(.medium)
                Spacer()
                Capsule()
                    .fill(on ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: on ? .trailing : .leading) {
                        Circle().fill(.white).padding(2).shadow(radius: 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 18))
                            .foregroundStyle(.primary)
                            .offset(x: on ? 6 : 26, y: on ? 12 : 34)
                            .opacity(on ? 1 : 0.0001)
                    }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator))
        }
        .padding(14)
        .frame(width: 330)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.6)))
        .onReceive(Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()) { _ in
            withAnimation(.spring(duration: 0.35)) { on.toggle() }
        }
    }
}

/// Three small steps with arrows between them: what to do, at a glance.
struct HowStrip: View {
    let items: [(String, String)]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                VStack(spacing: 5) {
                    Image(systemName: item.0)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.blue.opacity(0.12)))
                    Text(item.1).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 96)
                }
                if i < items.count - 1 {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary).padding(.top, 14)
                }
            }
        }
    }
}

/// Two devices joined through a lock, with a light travelling between them.
struct LinkHint: View {
    let left: String
    let leftDone: Bool
    let right: String

    var body: some View {
        HStack(spacing: 10) {
            device(left, done: leftDone)
            TimelineView(.animation) { t in
                let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                HStack(spacing: 6) {
                    dots(phase)
                    Image(systemName: "lock.shield.fill").font(.system(size: 30)).foregroundStyle(.green)
                    dots(phase)
                }
            }
            device(right, done: false)
        }
    }

    private func device(_ symbol: String, done: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 52, weight: .light))
            .foregroundStyle(.primary.opacity(0.85))
            .overlay(alignment: .bottomTrailing) {
                if done { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 18)).offset(x: 6, y: 4) }
            }
    }

    private func dots(_ phase: Double) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<4) { i in
                let lit = Int(phase * 4) == i
                Circle().fill(lit ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: lit ? 7 : 5, height: lit ? 7 : 5)
            }
        }
        .frame(width: 44)
    }
}

/// A browser address bar for this Mac's private https address, with the padlock pulsing.
struct AddressBarHint: View {
    let host: String

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.green).symbolEffect(.pulse, options: .repeating)
                Text("https://").foregroundStyle(.green) + Text(host).foregroundStyle(.primary)
                Spacer()
            }
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(width: 380)
            .background(Capsule().fill(.quaternary.opacity(0.7)))
            HStack(spacing: 16) {
                Image(systemName: "laptopcomputer").font(.system(size: 40, weight: .light))
                Image(systemName: "checkmark.shield.fill").font(.system(size: 30)).foregroundStyle(.green)
                Image(systemName: "iphone.gen3").font(.system(size: 36, weight: .light))
            }
            .foregroundStyle(.secondary)
        }
    }
}

/// The QR code with a scan line sweeping over it, and an iPhone pointing at it.
struct ScanHint: View {
    let qr: NSImage

    var body: some View {
        HStack(spacing: 22) {
            ScanQR(qr: qr, side: 124)
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.blue)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        }
    }
}

/// The QR code on white, with a scan line sweeping over it.
struct ScanQR: View {
    let qr: NSImage
    let side: CGFloat

    var body: some View {
        Image(nsImage: qr).interpolation(.none).resizable().frame(width: side, height: side)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
            .overlay {
                TimelineView(.animation) { t in
                    let p = (sin(t.date.timeIntervalSinceReferenceDate * 2.2) + 1) / 2
                    GeometryReader { g in
                        Rectangle()
                            .fill(LinearGradient(colors: [.clear, .blue.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(height: 3)
                            .offset(y: 8 + p * (g.size.height - 19))
                    }
                }
            }
    }
}
