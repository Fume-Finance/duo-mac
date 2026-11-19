import SafariServices
import UIKit
import WebKit

/// The Duo Mac page, full screen: no status bar, the home bar hidden, and swipes from the screen's
/// edges going to the page (the trackpad) first instead of to iOS.
final class WebViewController: UIViewController {
    private var web: WKWebView!
    private let bridge = Bridge()
    private let video = NativeVideo()
    private var errorView: UIView?
    private var errorText = ""
    private var retryTimer: Timer?
    /// The page has opened at least once (from the Mac, or from its offline copy).
    private var opened = false
    private var loginView: SFSafariViewController?
    private var askedToSignIn = false

    /// The Mac it opens (Settings › Macs switches it: Macs.swift).
    static var home: URL? { Macs.current.flatMap { URL(string: "https://\($0)/") } }

    /// That Mac's own page (https, the usual port): the only one the app's features are for.
    static func isHome(_ origin: WKSecurityOrigin) -> Bool {
        origin.protocol == "https" && origin.port == 0 && origin.host == home?.host
    }

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        // The page's address is an "app-bound domain": that's what lets it keep its offline copy
        // (service worker), so it opens even when Tailscale can't be reached.
        cfg.limitsNavigationsToAppBoundDomains = true
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.userContentController.addUserScript(
            WKUserScript(source: Bridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        cfg.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "duo")

        let w = WKWebView(frame: .zero, configuration: cfg)
        // See-through where the page leaves its canvas clear: the native video is behind it.
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.bounces = false
        w.scrollView.contentInsetAdjustmentBehavior = .never
        w.allowsBackForwardNavigationGestures = false
        w.allowsLinkPreview = false
        #if DEBUG
        w.isInspectable = true // Safari › Develop on the Mac can inspect it (debug builds only)
        #endif
        w.uiDelegate = self
        w.navigationDelegate = self
        w.hideKeyboardBar()
        bridge.web = w
        bridge.video = video
        web = w
        let root = UIView()
        root.backgroundColor = .black
        for v in [video.view, w] {
            v.frame = root.bounds
            v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            root.addSubview(v)
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        bridge.onTailnetLogin = { [weak self] in self?.showTailnetLogin() }
        bridge.presenter = self
        bridge.onOpenMac = { [weak self] host, url in self?.open(host: host, pairURL: url) }
        Tailnet.shared.onChange = { [weak self] s in self?.tailnetChanged(s) }
        Tailnet.shared.start()
        // At once, without waiting for Tailscale: the page opens from its offline copy if it has to, and
        // reconnects by itself once Tailscale is up.
        load()
    }

    // MARK: The page's stored copy

    /// A page from before the self-updating one (it has no version stamp) was stored on the phone by a
    /// service worker that only fetches from the network, and opening before Tailscale is up keeps showing it.
    /// Once Tailscale is up: drop that stored copy and load the page from the Mac, once. (Later updates go
    /// through the page's own check.)
    private var replacedOldPage = false
    private func replaceOldPage() {
        guard !replacedOldPage, opened, case .running = Tailnet.shared.state else { return }
        web.evaluateJavaScript("!!document.querySelector('meta[name=\"duo-build\"]')") { [weak self] result, _ in
            guard let self, result as? Bool == false, !self.replacedOldPage else { return }
            self.replacedOldPage = true
            print("old page: replacing its stored copy")
            self.web.evaluateJavaScript("navigator.serviceWorker.getRegistrations().then((rs) => Promise.all(rs.map((r) => r.unregister()))).then(() => caches.keys()).then((ks) => Promise.all(ks.map((k) => caches.delete(k)))).finally(() => location.reload())")
        }
    }

    // MARK: Tailscale in the app (Tailnet.swift)

    private func tailnetChanged(_ s: Tailnet.State) {
        bridge.tailnetChanged()
        if errorView != nil { showError(errorText) } // with what Tailscale needs now
        switch s {
        case .running:
            loginView?.dismiss(animated: true)
            loginView = nil
            // Couldn't open without it: now. (Open already: the page reconnects by itself, told just above.)
            if !opened || errorView != nil { load() } else { replaceOldPage() }
        case .needsLogin:
            // Ask once per launch; Settings › Connection on the page can start it later.
            if !askedToSignIn && !UserDefaults.standard.bool(forKey: "tailnetNotNow") {
                askedToSignIn = true
                let a = UIAlertController(title: "Reach your Mac from anywhere",
                                          message: "Sign in to Tailscale once, here in Duo Mac, and it reaches your Mac without the Tailscale VPN switched on.",
                                          preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in
                    UserDefaults.standard.set(true, forKey: "tailnetNotNow")
                })
                a.addAction(UIAlertAction(title: "Sign In", style: .default) { [weak self] _ in self?.showTailnetLogin() })
                present(a, animated: true)
            }
        default:
            break
        }
    }

    func showTailnetLogin() {
        if !Tailnet.enabled { Tailnet.enabled = true; Tailnet.shared.start() }
        guard case .needsLogin(let url) = Tailnet.shared.state else { return }
        let v = SFSafariViewController(url: url)
        v.dismissButtonStyle = .close
        loginView = v
        (presentedViewController ?? self).present(v, animated: true)
    }

    override var prefersStatusBarHidden: Bool { true }
    // Every way round: the iPhone Duo's inner screen is used upright and sideways, either way up.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    // iOS only holds back the edge swipes (first swipe: the trackpad; a second one: Home) while the
    // home bar is showing, so it stays, dimmed, instead of hiding.
    override var prefersHomeIndicatorAutoHidden: Bool { false }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    func becameActive() {
        if errorView != nil { retry() }
        bridge.becameActive()
    }

    /// Another Mac: open its page (with a pairing code if it came from its QR code).
    func open(host: String, pairURL: URL? = nil) {
        Macs.current = host
        hideError()
        let url = pairURL.flatMap { $0.host == host ? $0 : nil } ?? Self.home
        if let url { web.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)) }
    }

    private func load() {
        print("loading \(Self.home?.absoluteString ?? "-") (tailnet \(Tailnet.shared.state))")
        guard let url = Self.home else {
            return showError("This copy of Duo Mac doesn't know your Mac's address. Build it again with tools/ios-app.sh on the Mac.")
        }
        web.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15))
    }

    // MARK: Couldn't load (the first time, before the page has an offline copy)

    private func showError(_ text: String) {
        errorText = text
        errorView?.removeFromSuperview()
        let box = UIView(frame: view.bounds)
        box.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.backgroundColor = .black
        let cur = Macs.current
        let curName = Macs.list.first { $0.host == cur }.map { $0.name.isEmpty ? String($0.host.prefix { $0 != "." }) : $0.name }
        let title = Self.label(Macs.list.count > 1 ? "Can't reach \(curName ?? "your Mac")" : "Can't reach your Mac", .title3, bold: true)
        var views: [UIView] = [title, Self.label(text, .subheadline, alpha: 0.6)]
        // This iPhone's own Tailscale is what's missing: signing in, or the tailnet admin's approval.
        switch Tailnet.shared.state {
        case .needsLogin:
            var sc = UIButton.Configuration.filled()
            sc.title = "Sign in to Tailscale"
            sc.cornerStyle = .capsule
            views.append(UIButton(configuration: sc, primaryAction: UIAction { [weak self] _ in self?.showTailnetLogin() }))
        case .needsApproval:
            views.append(Self.label("Waiting for approval in the Tailscale admin console", .footnote, alpha: 0.8))
        default:
            break
        }
        var bc = UIButton.Configuration.filled()
        bc.title = "Try again"
        bc.baseBackgroundColor = UIColor(white: 1, alpha: 0.15)
        bc.cornerStyle = .capsule
        views.append(UIButton(configuration: bc, primaryAction: UIAction { [weak self] _ in self?.retry() }))
        // Saved another Mac: open that one instead (Settings › Macs, when this one is away).
        let others = Macs.list.filter { $0.host != cur }
        if !others.isEmpty {
            var oc = UIButton.Configuration.plain()
            oc.title = "Use another Mac…"
            oc.baseForegroundColor = UIColor(white: 1, alpha: 0.8)
            let other = UIButton(configuration: oc)
            other.menu = UIMenu(children: others.map { m in
                UIAction(title: m.name.isEmpty ? String(m.host.prefix { $0 != "." }) : m.name) { [weak self] _ in self?.open(host: m.host) }
            })
            other.showsMenuAsPrimaryAction = true
            views.append(other)
        }
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: box.widthAnchor, constant: -48),
        ])
        view.addSubview(box)
        errorView = box
    }

    /// A label in a Dynamic Type style: it follows Settings › Display › Text Size, also while showing.
    private static func label(_ text: String, _ style: UIFont.TextStyle, bold: Bool = false, alpha: CGFloat = 1) -> UILabel {
        let l = UILabel()
        l.text = text
        let f = UIFont.preferredFont(forTextStyle: style)
        l.font = bold ? f.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? f : f
        l.adjustsFontForContentSizeCategory = true
        l.textColor = UIColor(white: 1, alpha: alpha)
        l.numberOfLines = 0
        l.textAlignment = .center
        return l
    }

    /// "Try again": now, instead of the retry that's waiting.
    private func retry() {
        retryTimer?.invalidate()
        retryTimer = nil
        load()
    }

    private func hideError() {
        retryTimer?.invalidate()
        retryTimer = nil
        errorView?.removeFromSuperview()
        errorView = nil
    }
}

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" || url.host == Self.home?.host
            || action.targetFrame?.isMainFrame == false {
            return decisionHandler(.allow)
        }
        // Anything else (help pages, Tailscale's site…) opens in Safari.
        decisionHandler(.cancel)
        Self.openOutside(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.hideKeyboardBar() // its content view is new after a reload
        print("loaded \(webView.url?.absoluteString ?? "")")
        opened = true
        hideError()
        replaceOldPage()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        print("load failed: \(e.domain) \(e.code) \(e.localizedDescription)")
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        if errorView == nil {
            showError("Is Duo Mac open on the Mac, and is Tailscale connected on this iPhone? Once it has opened here, it also works without Tailscale on the same Wi-Fi or hotspot.\n\n(\(e.localizedDescription))")
        }
        // Once more in 5 s (Tailscale may just be switching on), unless a load is already under way then.
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, !self.web.isLoading else { return }
            self.load()
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        load()
    }

    static func openOutside(_ url: URL) {
        var u = url
        // The page sends some links to Safari as x-safari-https://…
        if let s = url.scheme, s.hasPrefix("x-safari-"), let plain = URL(string: String(url.absoluteString.dropFirst(9))) {
            u = plain
        }
        UIApplication.shared.open(u)
    }
}

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { Self.openOutside(url) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // The microphone only (the iPhone as the Mac's microphone), for the Mac's own page; never the camera.
        decisionHandler(type == .microphone && Self.isHome(origin) ? .grant : .deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a, animated: true)
    }
}

extension WKWebView {
    /// No ⌃ ⌄ ✓ bar above the iPhone keyboard: the page types through one hidden field, and tapping
    /// the black space around the shrunken screen puts the keyboard away. The bar is the inputAccessoryView
    /// of WebKit's content view, which has no setting for it, so that view gets a subclass returning none.
    func hideKeyboardBar() {
        guard let content = scrollView.subviews.first(where: { NSStringFromClass(type(of: $0)).hasPrefix("WKContent") }),
              let base = object_getClass(content) else { return }
        let name = NSStringFromClass(base)
        if name.hasSuffix("_NoBar") { return }
        let sel = #selector(getter: UIResponder.inputAccessoryView)
        var cls: AnyClass? = NSClassFromString(name + "_NoBar")
        if cls == nil, let c = objc_allocateClassPair(base, name + "_NoBar", 0),
           let m = class_getInstanceMethod(UIResponder.self, sel) {
            let none: @convention(block) (AnyObject) -> AnyObject? = { _ in nil }
            class_addMethod(c, sel, imp_implementationWithBlock(none), method_getTypeEncoding(m))
            objc_registerClassPair(c)
            cls = c
        }
        if let cls { object_setClass(content, cls) }
    }
}
