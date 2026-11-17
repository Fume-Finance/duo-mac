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
    private var retryTimer: Timer?
    private var loadedOnce = false
    /// Opened before the app's Tailscale was up: the page may be the stored copy (not the latest).
    private var loadedBeforeTailnet = false
    private var loginView: SFSafariViewController?
    private var askedToSignIn = false

    static let home: URL? = {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "DuoMacURL") as? String, !s.isEmpty else { return nil }
        return URL(string: s)
    }()

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
        w.isInspectable = true // Safari › Develop on the Mac can inspect it
        w.uiDelegate = self
        w.navigationDelegate = self
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
        Tailnet.shared.onChange = { [weak self] s in self?.tailnetChanged(s) }
        Tailnet.shared.start()
        // Give the app's own Tailscale a moment to come up, so the first load goes through it.
        if Tailnet.enabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.loadedOnce == false { self?.load() }
            }
        } else {
            load()
        }
    }

    // MARK: Tailscale in the app (Tailnet.swift)

    private func tailnetChanged(_ s: Tailnet.State) {
        bridge.tailnetChanged()
        switch s {
        case .running:
            loginView?.dismiss(animated: true)
            loginView = nil
            // Not opened yet, couldn't open, or opened from the stored copy: (re)load the latest.
            if !loadedOnce || errorView != nil || loadedBeforeTailnet { load() }
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
        if errorView != nil { load() }
        bridge.becameActive()
    }

    private func load() {
        loadedOnce = true
        loadedBeforeTailnet = Tailnet.enabled && !Tailnet.shared.isRunning
        print("loading \(Self.home?.absoluteString ?? "-") (tailnet \(Tailnet.shared.state))")
        guard let url = Self.home else {
            return showError("This copy of Duo Mac doesn't know your Mac's address. Build it again with tools/ios-app.sh on the Mac.")
        }
        web.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15))
    }

    // MARK: Couldn't load (the first time, before the page has an offline copy)

    private func showError(_ text: String) {
        retryTimer?.invalidate()
        errorView?.removeFromSuperview()
        let box = UIView(frame: view.bounds)
        box.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.backgroundColor = .black
        let title = UILabel()
        title.text = "Can't reach your Mac"
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .white
        let body = UILabel()
        body.text = text
        body.numberOfLines = 0
        body.textAlignment = .center
        body.font = .systemFont(ofSize: 15)
        body.textColor = UIColor(white: 1, alpha: 0.6)
        var bc = UIButton.Configuration.filled()
        bc.title = "Try again"
        bc.baseBackgroundColor = UIColor(white: 1, alpha: 0.15)
        bc.cornerStyle = .capsule
        let button = UIButton(configuration: bc, primaryAction: UIAction { [weak self] _ in self?.retry() })
        let stack = UIStackView(arrangedSubviews: [title, body, button])
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
        // Keep trying quietly: Tailscale may just be switching on.
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.load() }
    }

    private func retry() {
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
        print("loaded \(webView.url?.absoluteString ?? "")")
        hideError()
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
        if errorView != nil { return } // already showing it, retrying
        showError("Is Duo Mac open on the Mac, and Tailscale on on this iPhone? Once it has opened here, it also works without Tailscale on the same Wi-Fi or hotspot.\n\n(\(e.localizedDescription))")
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
        decisionHandler(origin.host == Self.home?.host ? .grant : .deny)
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
