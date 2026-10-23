import Foundation

struct Options {
    var headless = false
    var port: UInt16? = nil
    var lan = false
    var webRoot: String? = nil
    var testPattern = false
    var dryRun = false
    var displayIndex: Int? = nil
    var verbose = false
    var snapshotUI: String? = nil
    var configDir: String? = nil
    var autoApprove = false

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--headless": o.headless = true
            case "--port": if let v = next(), let p = UInt16(v) { o.port = p }
            case "--localhost": break // the default now; kept so old commands still work
            case "--lan": o.lan = true
            case "--web": o.webRoot = next()
            case "--test-pattern": o.testPattern = true
            case "--dry-run": o.dryRun = true
            case "--display": if let v = next(), let d = Int(v) { o.displayIndex = d }
            case "--verbose", "-v": o.verbose = true
            case "--snapshot-ui": o.snapshotUI = next()
            case "--config-dir": o.configDir = next()
            case "--auto-approve": o.autoApprove = true
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                break // ignore anything else (e.g. -psn_… from Finder)
            }
            i += 1
        }
        // Approving pairings without asking is for automated tests of the test pattern only.
        if !o.testPattern { o.autoApprove = false }
        return o
    }

    static let usage = """
    Duo Mac helper

      --headless        no window; print the pairing QR code in the terminal
      --port N          listen on port N (default 8890)
      --web DIR         serve the web app from DIR
      --test-pattern    stream a synthetic test screen instead of the real one (http://localhost)
      --auto-approve    with --test-pattern: allow pairing requests without asking (tests)
      --dry-run         log input events instead of sending them to macOS
      --display N       capture display N (0 = main display)
      --config-dir DIR  keep settings and paired devices in DIR instead of Application Support
      --lan             also answer the local network over plain http (testing; no passkey there)
      --verbose         more logging

    Normally the helper listens on this Mac only, and Tailscale Serve makes it reachable from
    your iPhone at https://<this Mac>.<your tailnet>.ts.net.
    """
}
