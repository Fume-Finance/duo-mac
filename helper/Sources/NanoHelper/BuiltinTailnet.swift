import Foundation

/// Tailscale built into Duo Mac (helper/tailnet: a small Go program on Tailscale's own library), for a
/// Mac without the Tailscale app. It's its own device on your tailnet ("duo-mac") and serves Duo Mac
/// at https://duo-mac.<tailnet>.ts.net the way `tailscale serve` did. Tailscale.swift asks it, instead
/// of the Tailscale app, for the status, the sign-in link and who a tailnet address is.
///
/// It runs as a child of the helper and quits with it (its stdin is the helper's end of a pipe).
final class BuiltinTailnet {
    static var binary: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Duo Mac/.bin/duo-mac-tailnet")
    }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    private let lock = NSLock()
    private var process: Process?
    private var input: Pipe?
    private var control: String?           // 127.0.0.1:port, once it said so
    private let token = Crypto.randomBytes(24).map { String(format: "%02x", $0) }.joined()
    private let dir: URL
    private let target: String

    init(configDir: URL, port: UInt16) {
        dir = configDir.appendingPathComponent("tailnet", isDirectory: true)
        target = "http://127.0.0.1:\(port)"
    }

    var running: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard process?.isRunning != true, BuiltinTailnet.isInstalled else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = BuiltinTailnet.binary
        p.arguments = ["-dir", dir.path, "-hostname", "duo-mac", "-target", target]
        var env = ProcessInfo.processInfo.environment
        env["DUO_TAILNET_TOKEN"] = token
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            Log.warn("Built-in Tailscale stopped (\(proc.terminationStatus))")
            self?.lock.lock(); self?.control = nil; self?.lock.unlock()
        }
        do { try p.run() } catch {
            Log.warn("Built-in Tailscale didn't start (\(error.localizedDescription))")
            return
        }
        process = p
        self.input = input
        control = nil
        // Its first line says where to ask it things.
        DispatchQueue.global().async { [weak self] in
            let h = output.fileHandleForReading
            var line = Data()
            while let b = try? h.read(upToCount: 1), let c = b.first, c != 10 { line.append(c) }
            let text = String(decoding: line, as: UTF8.self)
            guard text.hasPrefix("control ") else { return }
            self?.lock.lock()
            self?.control = String(text.dropFirst(8))
            self?.lock.unlock()
            Log.info("Built-in Tailscale started")
            // Keep reading (and dropping) the rest, so it never blocks on a full pipe.
            while let d = try? h.read(upToCount: 4096), !d.isEmpty {}
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        try? input?.fileHandleForWriting.close() // it quits when its stdin closes
        if let p = process, p.isRunning {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        }
        process = nil
        input = nil
        control = nil
    }

    /// Blocking (the Tailscale queue): its answer to one question, as JSON.
    func get(_ path: String, timeout: TimeInterval = 6) -> [String: Any]? {
        lock.lock()
        let c = control
        lock.unlock()
        guard let c, let url = URL(string: "http://\(c)\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let done = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200, let data {
                out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return out
    }
}
