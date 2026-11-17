import UIKit
import WebKit

/// What the page can ask the app for, as `window.duoNative` (see web/js/native.js). Every call is a
/// promise: `duoNative.call({ t: … })`.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var web: WKWebView?
    var video: NativeVideo?
    var onTailnetLogin: (() -> Void)?
    weak var presenter: UIViewController?

    /// Tells the page (Settings › Connection) how the app's own Tailscale is doing.
    func tailnetChanged() {
        web?.evaluateJavaScript("window.duoTailnet && window.duoTailnet(\(Self.tailnetJSON()))")
    }

    private static func tailnetInfo() -> [String: Any] {
        var s = "off"
        switch Tailnet.shared.state {
        case .off: s = "off"
        case .starting: s = "starting"
        case .needsLogin: s = "needs-login"
        case .running: s = "running"
        case .failed: s = "failed"
        }
        return ["state": s, "enabled": Tailnet.enabled]
    }

    private static func tailnetJSON() -> String {
        (try? JSONSerialization.data(withJSONObject: tailnetInfo())).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
    private lazy var clipboard: ClipboardWatch = {
        let c = ClipboardWatch()
        c.onCopy = { [weak self] m in
            guard let data = try? JSONSerialization.data(withJSONObject: m),
                  let json = String(data: data, encoding: .utf8) else { return }
            self?.web?.evaluateJavaScript("window.duoClipboard && window.duoClipboard(\(json))")
        }
        return c
    }()
    private var awake = false
    private lazy var taps: [String: UIImpactFeedbackGenerator] = [
        "light": UIImpactFeedbackGenerator(style: .light),
        "medium": UIImpactFeedbackGenerator(style: .medium),
        "rigid": UIImpactFeedbackGenerator(style: .rigid),
        "soft": UIImpactFeedbackGenerator(style: .soft),
    ]
    private lazy var select = UISelectionFeedbackGenerator()
    private lazy var dictation: Dictation = {
        let d = Dictation()
        d.onText = { [weak self] text, final in
            guard let data = try? JSONSerialization.data(withJSONObject: [text]),
                  let json = String(data: data, encoding: .utf8) else { return }
            self?.web?.evaluateJavaScript("window.duoDictation && window.duoDictation(\(json)[0], \(final))")
        }
        return d
    }()

    /// Runs before the page's own scripts.
    static var script: String {
        // The fastest this screen refreshes (120 on ProMotion): the Mac sends that many frames.
        let fps = UIScreen.main.maximumFramesPerSecond
        return base.replacingOccurrences(of: "__FPS__", with: String(fps))
    }
    private static let base = """
    (() => {
      const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.duo;
      if (!h) return;
      const call = (m) => h.postMessage(m);
      window.duoNative = {
        version: 1,
        call,
        haptic(k) { h.postMessage({ t: 'haptic', k: k || 'light' }).catch(() => {}); },
        video: true,      // decodes and shows H.264 itself (NativeVideo.swift)
        maxFPS: __FPS__,
      };
      // The page's console and errors, also in the app's own log (seen over the cable: devicectl --console).
      for (const k of ['log', 'warn', 'error']) {
        const orig = console[k].bind(console);
        console[k] = (...a) => { orig(...a); try { h.postMessage({ t: 'log', k, m: a.map((x) => (x && x.stack) || String(x)).join(' ').slice(0, 800) }).catch(() => {}); } catch (e) {} };
      }
      window.addEventListener('error', (e) => { try { h.postMessage({ t: 'log', k: 'error', m: `${e.message} @${e.filename}:${e.lineno}` }).catch(() => {}); } catch (x) {} });
      window.addEventListener('unhandledrejection', (e) => { try { h.postMessage({ t: 'log', k: 'error', m: `unhandled: ${(e.reason && e.reason.stack) || e.reason}` }).catch(() => {}); } catch (x) {} });
      // The page treats this like its Home Screen app (no "Add to Home Screen" step).
      try { Object.defineProperty(Navigator.prototype, 'standalone', { get: () => true, configurable: true }); } catch (e) {}
    })();
    """

    func becameActive() {
        UIApplication.shared.isIdleTimerDisabled = awake
        clipboard.check() // copied something in another app meanwhile
        for g in taps.values { g.prepare() }
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let m = message.body as? [String: Any], let t = m["t"] as? String else {
            return replyHandler(nil, "bad message")
        }
        // Only Duo Mac's own page may use the app's features (Face ID above all).
        guard let host = WebViewController.home?.host, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == host else {
            return replyHandler(nil, "not allowed")
        }
        switch t {
        case "log":
            print("page \(m["k"] as? String ?? ""): \(m["m"] as? String ?? "")")
            replyHandler(nil, nil)

        case "haptic":
            let k = m["k"] as? String ?? "light"
            if k == "select" { select.selectionChanged() } else { (taps[k] ?? taps["light"]!).impactOccurred() }
            replyHandler(nil, nil)

        case "awake":
            awake = m["on"] as? Bool ?? false
            UIApplication.shared.isIdleTimerDisabled = awake
            replyHandler(nil, nil)

        case "info":
            var info: [String: Any] = ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""]
            if let exp = Provisioning.expiry { info["expires"] = exp.timeIntervalSince1970 * 1000 }
            replyHandler(info, nil)

        case "passkey-create", "passkey-get":
            guard let rpId = m["rpId"] as? String, rpId == host, let challenge = m["challenge"] as? String else {
                return replyHandler(nil, "NotSupportedError")
            }
            let done: (Result<[String: Any], Error>) -> Void = { r in
                DispatchQueue.main.async {
                    switch r {
                    case .success(let v): replyHandler(v, nil)
                    case .failure(let e): replyHandler(nil, (e as? Authenticator.Failure)?.name ?? "UnknownError")
                    }
                }
            }
            if t == "passkey-create" {
                Authenticator.create(rpId: rpId, challenge: challenge, completion: done)
            } else {
                guard let cred = m["cred"] as? String else { return replyHandler(nil, "NotAllowedError") }
                Authenticator.get(rpId: rpId, challenge: challenge, credentialID: cred, completion: done)
            }

        case "dictate":
            if m["on"] as? Bool == true {
                dictation.start(locale: m["lang"] as? String, engine: m["engine"] as? String) { err in replyHandler(err == nil, err) }
            } else {
                dictation.stop(deliver: m["cancel"] as? Bool != true)
                replyHandler(true, nil)
            }

        case "scan-qr":
            guard let h = presenter else { return replyHandler(nil, "NotAllowedError") }
            QRScanner.scan(from: h.presentedViewController ?? h) { s in replyHandler(s, nil) }

        case "tailnet":
            replyHandler(Self.tailnetInfo(), nil)

        case "tailnet-login":
            onTailnetLogin?()
            replyHandler(nil, nil)

        case "tailnet-enable":
            let on = m["on"] as? Bool == true
            Tailnet.enabled = on
            if on { UserDefaults.standard.set(false, forKey: "tailnetNotNow"); Tailnet.shared.start() } else { Tailnet.shared.stop() }
            replyHandler(nil, nil)

        case "clip-watch":
            clipboard.setWatching(m["on"] as? Bool == true)
            replyHandler(nil, nil)

        case "clip-set":
            clipboard.set(text: m["text"] as? String, image: (m["img"] as? String).flatMap { Data(base64Encoded: $0) })
            replyHandler(nil, nil)

        case "vconf":
            guard let v = video, let d = (m["avcc"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                return replyHandler(false, nil)
            }
            v.configure(avcC: d, width: m["w"] as? Int ?? 0, height: m["h"] as? Int ?? 0) { ok in
                DispatchQueue.main.async { replyHandler(ok, nil) }
            }

        case "vframe":
            guard let v = video, let d = (m["d"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                return replyHandler(false, nil)
            }
            v.decode(d) { ok in DispatchQueue.main.async { replyHandler(ok, nil) } }

        case "vrect":
            let n = { (k: String) in CGFloat((m[k] as? NSNumber)?.doubleValue ?? 0) }
            video?.place(on: m["on"] as? Bool == true, frame: CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h")))
            replyHandler(nil, nil)

        case "whisper":
            // Settings › Dictation: get the model ready (on Wi-Fi), and say how it's going.
            if let e = m["engine"] as? String { UserDefaults.standard.set(e, forKey: "dictationEngine") }
            if m["prepare"] as? Bool == true { WhisperEngine.shared.prepare() }
            var st = "idle", pct = 0
            switch WhisperEngine.shared.state {
            case .idle: st = "idle"
            case .downloading(let p): st = "downloading"; pct = p
            case .loading: st = "loading"
            case .ready: st = "ready"
            case .waitingForWiFi: st = "wifi"
            case .failed: st = "failed"
            }
            replyHandler(["state": st, "pct": pct], nil)

        case "find-mac":
            let port = UInt16(clamping: m["port"] as? Int ?? 8892)
            MacFinder.find(port: port) { hosts in DispatchQueue.main.async { replyHandler(hosts, nil) } }

        default:
            replyHandler(nil, "unknown call \(t)")
        }
    }
}

/// When this copy of the app stops opening: free Apple ID signing lasts 7 days.
enum Provisioning {
    static let expiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)
                as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }()
}
