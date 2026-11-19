import Compression
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
    let queue: DispatchQueue
    let port: UInt16
    let localhostOnly: Bool
    let webRoot: URL
    let tls: sec_identity_t?
    let allowedOrigin: (() -> [String])?
    var isLocalEntrance: Bool { tls != nil }
    private var listener: NWListener?

    var onWebSocket: ((WebSocketConnection, [String: String]) -> Void)?
    var onState: ((Bool, String?) -> Void)?
    /// Generated files (path and query → body and type), served before the web app's own (any thread).
    var dynamicFile: ((String, [String: String]) -> (Data, String)?)?

    // MARK: The web app's version

    /// The web app's files (relative paths) and a short hash of their names, sizes and dates: it changes whenever
    /// build.sh installs a new web app, even while this app keeps running. Cached for a second (every connection
    /// asks). Any thread.
    private let buildLock = NSLock()
    private var cachedBuild: (at: Date, build: String, files: [String])?

    private func scanWebRoot() -> (build: String, files: [String]) {
        buildLock.lock(); defer { buildLock.unlock() }
        if let c = cachedBuild, Date().timeIntervalSince(c.at) < 1 { return (c.build, c.files) }
        var files: [String] = []
        var sig = ""
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if let e = FileManager.default.enumerator(at: webRoot, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in e {
                let rel = String(url.standardizedFileURL.path.dropFirst(webRoot.path.count + 1))
                if rel.hasPrefix("downloads") { e.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                files.append(rel)
                sig += "\(rel):\(v.fileSize ?? 0):\(v.contentModificationDate?.timeIntervalSince1970 ?? 0);"
            }
        }
        files.sort()
        let build = String(Data(SHA256.hash(data: Data(sig.utf8))).hex.prefix(12))
        cachedBuild = (Date(), build, files)
        return (build, files)
    }

    /// The web app's version, as in its page (index.html says it too).
    var build: String { scanWebRoot().build }

    /// /build.json: the version and the files, for the phone's stored copy (web/sw.js) to update itself.
    func buildManifest() -> Data {
        let (build, files) = scanWebRoot()
        return (try? JSONSerialization.data(withJSONObject: ["build": build, "files": files])) ?? Data("{}".utf8)
    }

    /// `queue`: where connections are handled; local mode's entrance shares the main server's, since
    /// sessions from both share the sign-in state (AuthManager, NanoCore), which isn't thread-safe.
    init(port: UInt16, localhostOnly: Bool, webRoot: URL, tls: sec_identity_t? = nil, allowedOrigin: (() -> [String])? = nil,
         queue: DispatchQueue? = nil) {
        self.queue = queue ?? DispatchQueue(label: "nano.net", qos: .userInteractive)
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

    /// The names the main server answers to: this Mac itself, or its Tailscale name (Tailscale Serve
    /// forwards the phone's requests). Anything else is DNS rebinding: a website pointing a name of
    /// its own at 127.0.0.1 to talk to this server as if it were its own site.
    static func isOwnName(_ host: String?) -> Bool {
        guard let host else { return false }
        let name = PeerInfo.stripPort(host)
        return name == "localhost" || name == "127.0.0.1" || name == "::1" || name.hasSuffix(".ts.net")
    }
}

/// Handles exactly one request, then either closes or hands the socket to a WebSocketConnection.
private final class HTTPConnection {
    let conn: NWConnection
    unowned let server: HTTPServer
    private var buffer = Data()
    private var arrived = false               // the request's headers are all here
    private static let headerEnd = Data([13, 10, 13, 10])
    /// Refused requests can come in floods: a few lines a minute in the log, not one each.
    private static let refusals = LogBudget(perMinute: 10)

    init(conn: NWConnection, server: HTTPServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            if case .failed = st { self?.conn.cancel() }
        }
        conn.start(queue: server.queue)
        // A request that never finishes arriving (a stuck or deliberately slow client) mustn't hold
        // the connection open forever.
        server.queue.asyncAfter(deadline: .now() + 10) { [self] in
            if !arrived { conn.cancel() }
        }
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
        arrived = true
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return respond(400, "Bad Request") }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            // A bare line feed or other control character inside a header: not from a browser, and it could
            // forge lines in the logs (names and addresses are logged).
            guard !line.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" || $0.value == 0x7F }) else {
                return respond(400, "Bad Request")
            }
            guard let i = line.firstIndex(of: ":") else { continue }
            let k = line[..<i].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        let comps = URLComponents(string: target)
        let path = comps?.path ?? "/"
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        if server.localhostOnly && !HTTPServer.isOwnName(headers["host"]) {
            HTTPConnection.refusals.log { Log.warn("Refused a request addressed to \(headers["host"] ?? "no host")") }
            return respond(403, "Forbidden")
        }

        switch path {
        case "/ws":
            upgrade(headers: headers, rest: rest)
        case "/healthz":
            respond(200, "ok")
        default:
            guard method == "GET" || method == "HEAD" else { return respond(405, "Method Not Allowed") }
            if server.isLocalEntrance { return respond(404, "Not Found") } // the page itself comes through Tailscale (or the phone's copy)
            if let (body, type) = server.dynamicFile?(path, query) {
                let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                    + "Cache-Control: no-store\r\n\(HTTPConnection.securityHeaders)Connection: close\r\n\r\n"
                return finish(Data(header.utf8) + (method == "HEAD" ? Data() : body))
            }
            serveFile(path: path, headOnly: method == "HEAD", gzip: headers["accept-encoding"]?.contains("gzip") == true)
        }
    }

    private func serveFile(path: String, headOnly: Bool, gzip: Bool) {
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
              var body = try? Data(contentsOf: url) else {
            return respond(404, "Not Found")
        }
        // The page says which version it is (web/js/main.js compares it with the Mac's, see sw.js).
        if rel == "index.html" {
            body = Data(String(decoding: body, as: UTF8.self).replacingOccurrences(of: "__DUO_BUILD__", with: server.build).utf8)
        }
        let type = HTTPConnection.mime(url.pathExtension)
        // Text goes compressed (about a third of the size), which counts through a Tailscale relay.
        var encoding = ""
        if gzip, type.hasPrefix("text/") || type.contains("json") || type.contains("svg"), body.count > 1024,
           let z = Gzip.compress(body) {
            body = z
            encoding = "Content-Encoding: gzip\r\nVary: Accept-Encoding\r\n"
        }
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\n\(encoding)"
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
            // (Only browsers can't fake this header: a program on the network can. The credentials are
            // what keeps it out.)
            guard let origin = headers["origin"]?.lowercased(),
                  let allowed = server.allowedOrigin?().first(where: { $0.lowercased() == origin }),
                  let host = URLComponents(string: allowed)?.host else {
                HTTPConnection.refusals.log { Log.warn("Local mode: refused a connection from a page at \(headers["origin"] ?? "nowhere")") }
                return respond(403, "Forbidden")
            }
            // The page's address is what passkeys are bound to; the caller is on the local network.
            headers["x-forwarded-for"] = nil
            headers["tailscale-user-login"] = nil
            headers["x-forwarded-host"] = host
            headers["x-duo-local"] = "1"
        } else {
            // Only our own page may open the socket: not some other site the browser has open, nor a
            // page that hides where it's from (a sandboxed frame says "null").
            guard let origin = headers["origin"], let o = URLComponents(string: origin), let oh = o.host?.lowercased() else {
                HTTPConnection.refusals.log { Log.warn("Refused a connection from a page that doesn't say where it's from") }
                return respond(403, "Forbidden")
            }
            let originHost = oh + (o.port.map { ":\($0)" } ?? "")
            let hosts = [headers["host"], headers["x-forwarded-host"]].compactMap { $0?.lowercased() }
            guard hosts.contains(originHost) else {
                HTTPConnection.refusals.log { Log.warn("Refused a connection from a page at \(origin)") }
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

/// gzip (RFC 1952) around the system's DEFLATE (Compression), for text files.
enum Gzip {
    static func compress(_ data: Data) -> Data? {
        let capacity = data.count + 1024
        var raw = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&raw, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        guard n > 0 else { return nil }
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(contentsOf: raw[0..<n])
        let crc = crc32(data)
        for v in [crc, UInt32(truncatingIfNeeded: data.count)] {
            out.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)])
        }
        return out
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffffffff
    }
}
