// Loads the Nano web app in WebKit (the engine iOS Safari uses), runs it for a while,
// prints console output and saves a snapshot. For testing without an iPhone.
// Usage: swift tools/webcheck.swift <url> <width> <height> <seconds> <out.png> [js-to-eval-at-end]
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 6 else {
    print("usage: webcheck <url> <width> <height> <seconds> <out.png> [js]")
    exit(2)
}
let url = URL(string: args[1])!
let width = Double(args[2])!, height = Double(args[3])!
let seconds = Double(args[4])!
let out = args[5]
let finalJS = args.count > 6 ? args[6] : "JSON.stringify(window.__autotest || null)"

final class Logger: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        print("[web] \(m.body)")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("[nav] failed: \(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("[nav] failed: \(error.localizedDescription)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let logger = Logger()
let ucc = WKUserContentController()
ucc.add(logger, name: "log")
ucc.addUserScript(WKUserScript(source: """
(function () {
  const post = (s) => { try { window.webkit.messageHandlers.log.postMessage(s); } catch (e) {} };
  for (const k of ['log', 'info', 'warn', 'error']) {
    const f = console[k].bind(console);
    console[k] = (...a) => { post(k + ': ' + a.map(x => { try { return typeof x === 'string' ? x : JSON.stringify(x); } catch (e) { return String(x); } }).join(' ')); f(...a); };
  }
  window.addEventListener('error', e => post('uncaught: ' + e.message + ' @' + e.filename + ':' + e.lineno));
  window.addEventListener('unhandledrejection', e => post('unhandled rejection: ' + (e.reason && (e.reason.stack || e.reason))));
})();
""", injectionTime: .atDocumentStart, forMainFrameOnly: true))
let cfg = WKWebViewConfiguration()
cfg.userContentController = ucc
let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: cfg)
wv.navigationDelegate = logger
wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
// Keep rendering/timers running even if the window is covered or the display sleeps.
let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
if wv.responds(to: sel) {
    typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(wv.method(for: sel), to: Fn.self)(wv, sel, false)
}
let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = wv
win.orderFrontRegardless()
wv.load(URLRequest(url: url))

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    wv.evaluateJavaScript(finalJS) { result, error in
        print("[eval] \(result.map { "\($0)" } ?? "nil") \(error.map { "error: \($0)" } ?? "")")
        let sc = WKSnapshotConfiguration()
        wv.takeSnapshot(with: sc) { image, err in
            if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
                print("[snap] \(out)")
            } else {
                print("[snap] failed \(err.map { "\($0)" } ?? "")")
            }
            exit(0)
        }
    }
}
app.run()
