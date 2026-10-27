import Foundation
import Network
import CryptoKit

/// Minimal HTTP/1.1 server: serves the web app as static files and upgrades `/ws` to a WebSocket.
/// One port for everything, so the phone only needs a single URL. It listens on this Mac only:
/// phones reach it through Tailscale Serve (HTTPS), which forwards to 127.0.0.1.
///
/// With `tls`, it's local mode's entrance instead (LocalMode): HTTPS on the local network, only
/// the WebSocket, only from private addresses, only for Duo Mac's own page (`allowedOrigin`).
final class HTTPServer {
    let queue = DispatchQueue(label: "nano.net", qos: .userInteractive)
    let port: UInt16
    let localhostOnly: Bool
    let webRoot: URL
    let tls: sec_identity_t?
    let allowedOrigin: (() -> String?)?
    var isLocalEntrance: Bool { tls != nil }
    private var listener: NWListener?

    var onWebSocket: ((WebSocketConnection, [String: String]) -> Void)?
    var onState: ((Bool, String?) -> Void)?
    /// Generated files (path → body and type), served before the web app's own (main thread safe).
    var dynamicFile: ((String) -> (Data, String)?)?

    init(port: UInt16, localhostOnly: Bool, webRoot: URL, tls: sec_identity_t? = nil, allowedOrigin: (() -> String?)? = nil) {
        self.port = port
        self.localhostOnly = localhostOnly
        self.webRoot = webRoot.standardizedFileURL
        self.tls = tls
        self.allowedOrigin = allowedOrigin
    }

    func start() {
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
            tcp.keepaliveInterval = 5
            tcp.keepaliveCount = 3
            var tlsOptions: NWProtocolTLS.Options?
            if let tls {
                let o = NWProtocolTLS.Options()
                sec_protocol_options_set_local_identity(o.securityProtocolOptions, tls)
                sec_protocol_options_set_min_tls_protocol_version(o.securityProtocolOptions, .TLSv12)
                tlsOptions = o
            }
            let params = NWParameters(tls: tlsOptions, tcp: tcp)
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let l: NWListener
            if localhostOnly {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
                l = try NWListener(using: params)
            } else {
                l = try NWListener(using: params, on: nwPort)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if !self.isLocalEntrance { Log.info("Listening on port \(self.port)\(self.localhostOnly ? " (this Mac only)" : "")") }
                    self.onState?(true, nil)
                case .failed(let e):
                    Log.warn("Cannot listen on port \(self.port): \(e)")
                    self.onState?(false, "Port \(self.port) is unavailable (\(e.localizedDescription)). Is another copy running?")
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                // The local entrance answers the local network only (Wi-Fi, hotspot), never the internet.
                if self.isLocalEntrance, case .hostPort(let host, _) = c.endpoint,
                   !LocalMode.isOnLocalNetwork("\(host)") {
                    c.cancel()
                    return
                }
                HTTPConnection(conn: c, server: self).start()
            }
            l.start(queue: queue)
            listener = l
        } catch {
            Log.warn("Cannot listen on port \(port): \(error)")
            onState?(false, "Port \(port) is unavailable: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Handles exactly one request, then either closes or hands the socket to a WebSocketConnection.
private final class HTTPConnection {
    let conn: NWConnection
    unowned let server: HTTPServer
    private var buffer = Data()
    private static let headerEnd = Data([13, 10, 13, 10])

    init(conn: NWConnection, server: HTTPServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.conn.cancel() }
        }
        conn.start(queue: server.queue)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data { self.buffer.append(data) }
            if let r = self.buffer.range(of: HTTPConnection.headerEnd) {
                let head = String(decoding: self.buffer[self.buffer.startIndex..<r.lowerBound], as: UTF8.self)
                let rest = Data(self.buffer[r.upperBound...])
                self.handle(head: head, rest: rest)
                return
            }
            if complete || error != nil || self.buffer.count > 32_768 {
                self.conn.cancel()
                return
            }
            self.receive()
        }
    }

    private func handle(head: String, rest: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return respond(400, "Bad Request") }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        let path = URLComponents(string: target)?.path ?? "/"

        switch path {
        case "/ws":
            upgrade(headers: headers, rest: rest)
        case "/healthz":
            respond(200, "ok")
        default:
            guard method == "GET" || method == "HEAD" else { return respond(405, "Method Not Allowed") }
            if server.isLocalEntrance { return respond(404, "Not Found") } // the page itself comes through Tailscale (or the phone's copy)
            if let (body, type) = server.dynamicFile?(path) {
                let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                    + "Cache-Control: no-store\r\n\(HTTPConnection.securityHeaders)Connection: close\r\n\r\n"
                return finish(Data(header.utf8) + (method == "HEAD" ? Data() : body))
            }
            serveFile(path: path, headOnly: method == "HEAD")
        }
    }

    private func serveFile(path: String, headOnly: Bool) {
        var rel = path.removingPercentEncoding ?? path
        if rel.hasSuffix("/") { rel += "index.html" }
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.split(separator: "/").contains(where: { $0 == ".." || $0.hasPrefix(".") }) {
            return respond(403, "Forbidden")
        }
        let url = server.webRoot.appendingPathComponent(rel).standardizedFileURL
        var isDir: ObjCBool = false
        guard url.path.hasPrefix(server.webRoot.path),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let body = try? Data(contentsOf: url) else {
            return respond(404, "Not Found")
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(HTTPConnection.mime(url.pathExtension))\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\n\(HTTPConnection.securityHeaders)Connection: close\r\n\r\n"
        var out = Data(header.utf8)
        if !headOnly { out.append(body) }
        finish(out)
    }

    /// Only this app's own code and connections; never shown inside another page; nothing leaks in referrers.
    private static let securityHeaders =
        "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
        + "img-src 'self' data: blob:; media-src 'self' data: blob:; connect-src 'self' wss: ws:; "
        + "object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n"
        + "X-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"

    private func upgrade(headers: [String: String], rest: Data) {
        guard headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] else {
            return respond(400, "Expected a WebSocket upgrade")
        }
        var headers = headers
        headers["x-duo-local"] = nil // only this server says that
        if server.isLocalEntrance {
            // Only Duo Mac's own page, at its Tailscale address (or the phone's saved copy of it).
            guard let origin = headers["origin"], let allowed = server.allowedOrigin?(), origin.lowercased() == allowed.lowercased(),
                  let host = URLComponents(string: allowed)?.host else {
                Log.warn("Local mode: refused a connection from a page at \(headers["origin"] ?? "nowhere")")
                return respond(403, "Forbidden")
            }
            // The page's address is what passkeys are bound to; the caller is on the local network.
            headers["x-forwarded-for"] = nil
            headers["tailscale-user-login"] = nil
            headers["x-forwarded-host"] = host
            headers["x-duo-local"] = "1"
        } else if let origin = headers["origin"], let o = URLComponents(string: origin), let oh = o.host?.lowercased() {
            // Only our own page may open the socket (not some other site the phone's browser has open).
            let originHost = oh + (o.port.map { ":\($0)" } ?? "")
            let hosts = [headers["host"], headers["x-forwarded-host"]].compactMap { $0?.lowercased() }
            guard hosts.contains(originHost) else {
                Log.warn("Refused a connection from a page at \(origin)")
                return respond(403, "Forbidden")
            }
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
        let ws = WebSocketConnection(conn: conn, queue: server.queue, initial: rest)
        server.onWebSocket?(ws, headers)
        ws.start()
    }

    private func respond(_ code: Int, _ text: String, type: String = "text/plain; charset=utf-8") {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][code] ?? "Error"
        let body = Data(text.utf8)
        let header = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n\(HTTPConnection.securityHeaders)Connection: close\r\n\r\n"
        finish(Data(header.utf8) + body)
    }

    private func finish(_ data: Data) {
        conn.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            self.conn.cancel()
        })
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "webmanifest": return "application/manifest+json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        default: return "application/octet-stream"
        }
    }
}
