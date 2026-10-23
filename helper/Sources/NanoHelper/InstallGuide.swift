import SwiftUI

/// The iPhone browser the pairing page was opened in. They hide Add to Home Screen in different
/// places, so the guide shows the taps for each (the web page does the same, see web/js/install.js).
enum PhoneBrowser: String, CaseIterable, Identifiable {
    case safari = "Safari", chrome = "Chrome"
    var id: String { rawValue }

    /// Chrome on iOS says "CriOS/…"; Safari says "Version/… Safari/…" (a Home Screen app says neither).
    init?(userAgent ua: String) {
        guard ua.contains("iPhone") || ua.contains("iPad") else { return nil }
        if ua.contains("CriOS/") { self = .chrome }
        else if ua.contains("Version/"), ua.contains("Safari/"), !ua.contains("FxiOS/"), !ua.contains("EdgiOS/"), !ua.contains("GSA/") { self = .safari }
        else { return nil }
    }

    var steps: [(scene: MockScene, text: Text)] {
        switch self {
        case .safari: [
            (.safariBar, Text("Tap \(Image(systemName: "line.3.horizontal")) in the address bar")),
            (.safariMenu, Text("Tap **Share**")),
            (.shareSheet, Text("Tap **View More**")),
            (.shareList, Text("Tap **Add to Home Screen**")),
            (.addDialog, Text("Tap **Add**")),
            (.home, Text("Open **Duo Mac** from the Home Screen")),
        ]
        case .chrome: [
            (.chromeBar, Text("Tap \(Image(systemName: "square.and.arrow.up")) in the address bar")),
            (.shareSheet, Text("Tap **View More**")),
            (.shareList, Text("Tap **Add to Home Screen**")),
            (.addDialog, Text("Tap **Add**")),
            (.home, Text("Open **Duo Mac** from the Home Screen")),
        ]
        }
    }
}

/// Add to Home Screen, tap by tap: a miniature iPhone plays each screen while the list follows along.
/// Picks the browser the iPhone actually used once it has opened the page.
struct InstallGuide: View {
    var detected: PhoneBrowser?
    var phoneWidth: CGFloat = 120
    var listWidth: CGFloat = 260
    @State private var browser: PhoneBrowser = .safari
    @State private var step = 0
    @State private var pausedUntil = Date.distantPast
    private let tick = Timer.publish(every: 2.6, on: .main, in: .common).autoconnect()

    var body: some View {
        let steps = browser.steps
        HStack(alignment: .center, spacing: phoneWidth < 110 ? 14 : 20) {
            ZStack {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    PhoneMock(scene: s.scene, width: phoneWidth).opacity(i == step ? 1 : 0)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: step)
            VStack(alignment: .leading, spacing: 3) {
                Picker("Browser", selection: $browser) {
                    ForEach(PhoneBrowser.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: min(170, listWidth))
                Group {
                    if let detected, detected == browser {
                        Label("Your iPhone opened it in \(detected.rawValue)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("If the QR code opened in \(browser.rawValue):").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.vertical, 4)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                    Button {
                        step = i
                        pausedUntil = Date().addingTimeInterval(6)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(i + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(i == step ? .white : .secondary)
                                .frame(width: 19, height: 19)
                                .background(Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.15)))
                            s.text
                                .font(.callout)
                                .foregroundStyle(i == step ? .primary : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: listWidth, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(i == step ? Color.accentColor.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.easeOut(duration: 0.2), value: step)
        }
        .onReceive(tick) { _ in
            if Date() > pausedUntil { step = (step + 1) % browser.steps.count }
        }
        .onChange(of: browser) { step = 0 }
        .onChange(of: detected) { if let detected { browser = detected } }
        .onAppear { if let detected { browser = detected } }
    }
}

enum MockScene: CaseIterable { case chromeBar, safariBar, safariMenu, shareSheet, shareList, addDialog, home }

/// A miniature iPhone screen, drawn in units of 1/15 of its width (`u`), like the web version's em.
struct PhoneMock: View {
    let scene: MockScene
    var width: CGFloat = 120

    private var u: CGFloat { width / 15 }
    private var height: CGFloat { width * 31 / 15 }
    private let chrome = Color(white: 0.17)
    private let fill = Color(white: 0.28)
    private let row = Color(white: 0.23)

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
            Text("9:41").font(.system(size: 0.8 * u, weight: .semibold)).foregroundStyle(.white)
                .padding(.leading, 1.7 * u).padding(.top, 0.7 * u)
        }
        .frame(width: width, height: height)
        .background(chrome)
        .clipShape(RoundedRectangle(cornerRadius: 2.3 * u, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 2.3 * u, style: .continuous).strokeBorder(Color(white: 0.32), lineWidth: 0.4 * u))
        .shadow(color: .black.opacity(0.35), radius: u, y: 0.5 * u)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch scene {
        case .chromeBar:
            VStack(spacing: 0) {
                HStack(spacing: 0.4 * u) {
                    icon("arrow.left").foregroundStyle(.secondary)
                    HStack {
                        Text("…ts.net")
                        Spacer(minLength: 0)
                        icon("square.and.arrow.up").tapTarget(u)
                    }
                    .font(.system(size: 0.75 * u))
                    .padding(.leading, 0.8 * u).padding(.trailing, 0.5 * u)
                    .frame(height: 2.6 * u)
                    .background(Capsule().fill(fill))
                    icon("ellipsis").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 0.6 * u).padding(.top, 2.4 * u).padding(.bottom, 0.5 * u)
                page(dim: false)
                HStack { ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 0.3 * u).fill(Color(white: 0.4)).frame(width: 1.2 * u, height: 1.2 * u).frame(maxWidth: .infinity) } }
                    .frame(height: 2.8 * u)
            }
        case .safariBar:
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) { Color.clear.frame(height: 2.2 * u); page(dim: false) }
                HStack(spacing: 0.4 * u) {
                    circle("arrow.left")
                    HStack {
                        icon("line.3.horizontal").tapTarget(u)
                        Spacer(minLength: 0)
                        Text("ts.net").font(.system(size: 0.75 * u))
                        Spacer(minLength: 0)
                        icon("arrow.clockwise").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 0.5 * u)
                    .frame(height: 2.6 * u)
                    .background(Capsule().fill(fill))
                    circle("square.on.square")
                }
                .padding(.horizontal, 0.6 * u).padding(.bottom, 0.9 * u)
            }
        case .safariMenu:
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) { Color.clear.frame(height: 2.2 * u); page(dim: true) }
                VStack(alignment: .leading, spacing: 0) {
                    menuRow("Ask Siri")
                    menuRow("Translate…")
                    Rectangle().fill(.white.opacity(0.15)).frame(height: 0.06 * u).padding(.horizontal, 0.6 * u).padding(.vertical, 0.3 * u)
                    menuRow("Share", symbol: "square.and.arrow.up", on: true)
                    menuRow("Add to Bookmarks")
                    menuRow("Find on Page")
                }
                .padding(0.4 * u)
                .background(RoundedRectangle(cornerRadius: 1.4 * u, style: .continuous).fill(Color(white: 0.25)))
                .padding(.horizontal, 2 * u).padding(.bottom, 2.6 * u)
            }
        case .shareSheet:
            sheet(top: 0.34) {
                HStack(spacing: 0.6 * u) {
                    appIcon(2.6 * u)
                    VStack(alignment: .leading, spacing: 0.1 * u) {
                        Text("Duo Mac").font(.system(size: 0.85 * u, weight: .bold))
                        Text("…ts.net").font(.system(size: 0.65 * u)).foregroundStyle(.secondary)
                    }
                }
                dotsRow(round: true, colors: Array(repeating: fill, count: 4))
                dotsRow(round: false, colors: [.blue, .green, Color(red: 0.23, green: 0.55, blue: 1), .yellow])
                actions(last: "View More", on: true)
            }
        case .shareList:
            sheet(top: 0.07) {
                actions(last: "View Less", on: false)
                group(["Add to Bookmarks", "Find on Page", "Print"])
                listRow("Add to Home Screen", symbol: "plus.square", on: true)
                    .background(RoundedRectangle(cornerRadius: u, style: .continuous).fill(row))
            }
        case .addDialog:
            sheet(top: 0.07) {
                HStack {
                    circle("xmark", size: 2.2)
                    Spacer(minLength: 0)
                    Text("Add to Home Screen").font(.system(size: 0.7 * u, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Text("Add").font(.system(size: 0.8 * u, weight: .semibold))
                        .padding(.horizontal, 0.95 * u).padding(.vertical, 0.45 * u)
                        .background(Capsule().fill(Color.blue))
                        .fixedSize()
                        .tapTarget(u)
                }
                HStack(spacing: 0.6 * u) {
                    appIcon(3 * u)
                    VStack(alignment: .leading, spacing: 0.1 * u) {
                        Text("Duo Mac").font(.system(size: 0.78 * u))
                        Text("https://…ts.net").font(.system(size: 0.62 * u)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(0.6 * u)
                .background(RoundedRectangle(cornerRadius: 0.8 * u, style: .continuous).fill(row))
                HStack {
                    Text("Open as Web App").font(.system(size: 0.78 * u))
                    Spacer(minLength: 0)
                    Capsule().fill(Color.green).frame(width: 2.6 * u, height: 1.5 * u)
                        .overlay(alignment: .trailing) { Circle().fill(.white).frame(width: 1.2 * u).padding(0.15 * u) }
                }
                .padding(0.6 * u)
                .background(RoundedRectangle(cornerRadius: 0.8 * u, style: .continuous).fill(row))
                Spacer(minLength: 0)
                keys(rows: 4, cols: 10, color: Color(white: 0.36)).frame(height: 9 * u)
            }
        case .home:
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.21, green: 0.28, blue: 0.48), Color(red: 0.07, green: 0.08, blue: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1.1 * u), count: 4), spacing: 1.2 * u) {
                        ForEach(0..<16) { i in
                            if i == 9 {
                                VStack(spacing: 0.25 * u) {
                                    appIcon(2.5 * u).tapTarget(u, radius: 1.1 * u)
                                    Text("Duo Mac").font(.system(size: 0.55 * u)).lineLimit(1).fixedSize()
                                }
                            } else {
                                RoundedRectangle(cornerRadius: 0.75 * u, style: .continuous).fill(.white.opacity(0.2)).frame(width: 2.5 * u, height: 2.5 * u)
                                    .padding(.bottom, 0.8 * u)
                            }
                        }
                    }
                    .padding(.horizontal, 1.3 * u).padding(.top, 3.2 * u)
                    Spacer()
                }
                HStack { ForEach(0..<4) { _ in RoundedRectangle(cornerRadius: 0.7 * u, style: .continuous).fill(.white.opacity(0.28)).frame(width: 2.7 * u, height: 2.7 * u).frame(maxWidth: .infinity) } }
                    .padding(.horizontal, 0.4 * u)
                    .frame(height: 4.2 * u)
                    .background(RoundedRectangle(cornerRadius: 1.6 * u, style: .continuous).fill(.white.opacity(0.16)))
                    .padding(0.6 * u)
            }
        }
    }

    // MARK: Pieces

    /// The Duo Mac page behind the browser bars: the screen half, the keyboard and the trackpad.
    private func page(dim: Bool) -> some View {
        VStack(spacing: 0.6 * u) {
            Color.black
            keys(rows: 5, cols: 12, color: Color(white: 0.2)).frame(height: 7 * u).padding(.horizontal, 0.5 * u)
            RoundedRectangle(cornerRadius: 0.5 * u).fill(Color(white: 0.12))
                .overlay(RoundedRectangle(cornerRadius: 0.5 * u).strokeBorder(Color(white: 0.24), lineWidth: 0.08 * u))
                .frame(height: 3.4 * u).padding(.horizontal, 2.6 * u).padding(.bottom, 0.9 * u)
        }
        .background(Color.black)
        .brightness(dim ? -0.6 : 0)
    }

    private func keys(rows: Int, cols: Int, color: Color) -> some View {
        Canvas { ctx, size in
            let gap = size.width * 0.012
            let kw = (size.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
            let kh = (size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            for r in 0..<rows {
                for c in 0..<cols {
                    let rect = CGRect(x: gap + CGFloat(c) * (kw + gap), y: gap + CGFloat(r) * (kh + gap), width: kw, height: kh)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: kw * 0.18), with: .color(color))
                }
            }
        }
    }

    /// A bottom sheet over the dimmed page, starting `top` of the way down.
    private func sheet<C: View>(top: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) { Color.clear.frame(height: 2.2 * u); page(dim: true) }
            VStack(alignment: .leading, spacing: 0.8 * u, content: content)
                .padding(u)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .frame(height: height * (1 - top) - 0.3 * u)
                .background(UnevenRoundedRectangle(topLeadingRadius: 2 * u, bottomLeadingRadius: 1.9 * u, bottomTrailingRadius: 1.9 * u, topTrailingRadius: 2 * u, style: .continuous).fill(chrome))
                .padding(0.3 * u)
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 0.95 * u, weight: .medium)).frame(width: 1.6 * u, height: 1.6 * u)
    }

    private func circle(_ symbol: String, size: CGFloat = 2.6) -> some View {
        Image(systemName: symbol).font(.system(size: 0.85 * u, weight: .medium))
            .frame(width: size * u, height: size * u)
            .background(Circle().fill(fill))
    }

    private func appIcon(_ side: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: side * 0.24, style: .continuous).fill(Color(white: 0.08))
            .overlay(Image(systemName: "laptopcomputer").font(.system(size: side * 0.45)).foregroundStyle(.white))
            .frame(width: side, height: side)
    }

    private func menuRow(_ title: String, symbol: String? = nil, on: Bool = false) -> some View {
        HStack(spacing: 0.5 * u) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.system(size: 0.8 * u, weight: on ? .semibold : .regular))
        .padding(.horizontal, 0.75 * u).padding(.vertical, 0.5 * u)
        .background(RoundedRectangle(cornerRadius: 0.7 * u, style: .continuous).fill(on ? Color.blue.opacity(0.3) : .clear))
        .modifier(OptionalTap(on: on, u: u, radius: 0.8 * u))
    }

    private func listRow(_ title: String, symbol: String? = nil, on: Bool = false) -> some View {
        HStack(spacing: 0.5 * u) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.system(size: 0.78 * u, weight: on ? .semibold : .regular))
        .padding(.horizontal, 0.8 * u).padding(.vertical, 0.55 * u)
        .background(RoundedRectangle(cornerRadius: u, style: .continuous).fill(on ? Color.blue.opacity(0.3) : .clear))
        .modifier(OptionalTap(on: on, u: u, radius: u))
    }

    private func group(_ titles: [String]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { i, t in
                if i > 0 { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.06 * u) }
                listRow(t)
            }
        }
        .background(RoundedRectangle(cornerRadius: u, style: .continuous).fill(row))
    }

    private func dotsRow(round: Bool, colors: [Color]) -> some View {
        HStack {
            ForEach(Array(colors.enumerated()), id: \.offset) { i, c in
                if i > 0 { Spacer(minLength: 0) }
                RoundedRectangle(cornerRadius: round ? 1.25 * u : 0.7 * u, style: .continuous).fill(c).frame(width: 2.5 * u, height: 2.5 * u)
            }
        }
        .padding(.horizontal, 0.2 * u)
    }

    /// Copy · Bookmark · Reading List · View More / View Less.
    private func actions(last: String, on: Bool) -> some View {
        HStack(alignment: .top) {
            action("doc.on.doc", "Copy")
            Spacer(minLength: 0)
            action(nil, "Bookmark")
            Spacer(minLength: 0)
            action(nil, "Reading List")
            Spacer(minLength: 0)
            action(on ? "chevron.down" : "chevron.up", last, on: on)
        }
    }

    private func action(_ symbol: String?, _ title: String, on: Bool = false) -> some View {
        VStack(spacing: 0.25 * u) {
            Circle().fill(fill).frame(width: 2.6 * u, height: 2.6 * u)
                .overlay { if let symbol { Image(systemName: symbol).font(.system(size: 0.9 * u, weight: .semibold)) } }
                .modifier(OptionalTap(on: on, u: u, radius: nil))
            Text(title).font(.system(size: 0.5 * u)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).frame(width: 3.2 * u)
        }
    }
}

private struct OptionalTap: ViewModifier {
    let on: Bool
    let u: CGFloat
    let radius: CGFloat?
    func body(content: Content) -> some View {
        if on { content.tapTarget(u, radius: radius) } else { content }
    }
}

extension View {
    /// What to tap: a ring pulsing out and a fingertip pressing, over and over.
    func tapTarget(_ u: CGFloat, radius: CGFloat? = nil) -> some View {
        overlay {
            TimelineView(.animation) { t in
                let p = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
                let shape = RoundedRectangle(cornerRadius: radius ?? 99, style: .continuous)
                ZStack {
                    shape.stroke(Color.blue, lineWidth: 0.2 * u)
                        .padding(-0.45 * u)
                        .scaleEffect(0.75 + 0.4 * p)
                        .opacity(p < 0.25 ? p / 0.25 : 1 - (p - 0.25) / 0.75)
                    Circle().fill(.white.opacity(0.5))
                        .frame(width: 2 * u, height: 2 * u)
                        .scaleEffect(p < 0.2 ? 1.5 - 2.5 * p : (p < 0.45 ? 1 - 0.72 * (p - 0.2) : 0.82))
                        .opacity(p < 0.2 ? p / 0.2 * 0.9 : (p < 0.45 ? 0.9 : max(0, 0.9 - (p - 0.45) / 0.25 * 0.9)))
                }
            }
            .allowsHitTesting(false)
        }
    }
}
