import Foundation
import Network
import WebKit

/// Tailscale inside the app (libtailscale): the app is its own device on your tailnet ("duo-mac-iphone"),
/// so reaching the Mac from anywhere doesn't need the Tailscale app's VPN switched on on the iPhone.
/// The web view's requests for the tailnet's names (*.ts.net) go through this device's local SOCKS5
/// proxy; everything else (the Mac on the same Wi-Fi or hotspot) goes direct.
///
/// Signing in happens once, in Tailscale's own login page; the device's keys stay in the app.
final class Tailnet {
    enum State: Equatable {
        case off
        case starting
        case needsLogin(URL)
        case running(suffix: String)
        case failed(String)
    }

    static let shared = Tailnet()
    private let queue = DispatchQueue(label: "duomac.tailnet")
    private var sd: Int32 = -1
    private var proxy: (port: UInt16, cred: String)?
    private var timer: DispatchSourceTimer?
    /// main thread
    private(set) var state = State.off { didSet { if state != oldValue { print("tailnet: \(state)"); onChange?(state) } } }
    /// main thread
    var onChange: ((State) -> Void)?

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "tailnet") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tailnet") }
    }

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    func start() {
        #if targetEnvironment(simulator)
        state = .failed("Not in the simulator")
        #else
        guard Self.enabled, sd < 0 else { return }
        state = .starting
        queue.async {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tailscale", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let sd = tailscale_new()
            tailscale_set_dir(sd, dir.path)
            tailscale_set_hostname(sd, "duo-mac-iphone")
            tailscale_set_logfd(sd, -1)
            guard tailscale_start(sd) == 0 else {
                let e = Self.error(sd)
                DispatchQueue.main.async { self.state = .failed(e) }
                return
            }
            self.sd = sd
            self.watch()
        }
        #endif
    }

    /// Turned off in Settings: the device stays on the tailnet (signed in) but the app stops using it.
    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            if self.sd >= 0 { tailscale_close(self.sd) }
            self.sd = -1
            self.proxy = nil
            DispatchQueue.main.async {
                self.state = .off
                WKWebsiteDataStore.default().proxyConfigurations = []
            }
        }
    }

    /// queue: follow the device's state (signing in, then running) every second.
    private func watch() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        guard sd >= 0, let st = status() else { return }
        let backend = st["BackendState"] as? String ?? ""
        switch backend {
        case "Running":
            let suffix = ((st["CurrentTailnet"] as? [String: Any])?["MagicDNSSuffix"] as? String) ?? "ts.net"
            if proxy == nil { proxy = loopback() }
            guard let p = proxy else { return }
            DispatchQueue.main.async {
                if case .running = self.state { return }
                Self.useProxy(port: p.port, cred: p.cred, suffix: suffix)
                self.state = .running(suffix: suffix)
            }
        case "NeedsLogin", "NeedsMachineAuth":
            if let s = st["AuthURL"] as? String, let url = URL(string: s) {
                DispatchQueue.main.async { self.state = .needsLogin(url) }
            }
        default:
            break
        }
    }

    /// iOS can take back the proxy's listening socket while the app is in the background, and the
    /// library keeps handing out that dead one: if it's gone, start this device over (a second or two;
    /// it keeps its keys, so no new sign-in). main thread
    func resumed() {
        queue.async {
            guard self.sd >= 0, let p = self.proxy, !Self.listening(port: p.port) else { return }
            self.timer?.cancel()
            self.timer = nil
            tailscale_close(self.sd)
            self.sd = -1
            self.proxy = nil
            DispatchQueue.main.async {
                self.state = .off
                self.start()
            }
        }
    }

    /// Something accepts connections at 127.0.0.1:port (the proxy is alive).
    private static func listening(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

    // MARK: libtailscale (queue)

    private func status() -> [String: Any]? {
        var out: UnsafeMutablePointer<CChar>?
        guard tailscale_status_json(sd, &out) == 0, let out else { return nil }
        defer { free(out) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: out).utf8))) as? [String: Any]
    }

    private func loopback() -> (port: UInt16, cred: String)? {
        var addr = [CChar](repeating: 0, count: 256)
        var cred = [CChar](repeating: 0, count: 33)
        var api = [CChar](repeating: 0, count: 33)
        guard tailscale_loopback(sd, &addr, addr.count, &cred, &api) == 0 else { return nil }
        let a = String(cString: addr)
        guard let port = a.split(separator: ":").last.flatMap({ UInt16($0) }) else { return nil }
        return (port, String(cString: cred))
    }

    private static func error(_ sd: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 512)
        tailscale_errmsg(sd, &buf, buf.count)
        return String(cString: buf)
    }

    /// main thread: the web view's tailnet names go through this device.
    private static func useProxy(port: UInt16, cred: String, suffix: String) {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        var config = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: p))
        config.applyCredential(username: "tsnet", password: cred)
        config.matchDomains = [suffix.trimmingCharacters(in: CharacterSet(charactersIn: "."))]
        WKWebsiteDataStore.default().proxyConfigurations = [config]
    }
}
