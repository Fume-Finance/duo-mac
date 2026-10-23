import Foundation

enum Log {
    static var verbose = false
    private static let start = Date()
    private static let queue = DispatchQueue(label: "nano.log")

    static func info(_ s: String) { emit("·", s) }
    static func warn(_ s: String) { emit("!", s) }
    static func debug(_ s: String) { if verbose { emit(" ", s) } }

    /// When started from Duo Mac.app there is no terminal, so also keep a log file
    /// (~/Library/Logs/Duo Mac/helper.log) — handy for debugging, phone errors included.
    private static let file: FileHandle? = {
        guard ProcessInfo.processInfo.environment["NANO_LAUNCHER_APP"] != nil || CommandLine.arguments.contains("--log-file") else { return nil }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Duo Mac")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("helper.log")
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 4_000_000 {
            let old = dir.appendingPathComponent("helper.old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func emit(_ mark: String, _ s: String) {
        let now = Date()
        let t = String(format: "%8.2f", now.timeIntervalSince(start))
        queue.async {
            print("[\(t)] \(mark) \(s)")
            if let file {
                file.write(Data("\(stamp.string(from: now)) \(mark) \(s)\n".utf8))
            }
        }
    }
}

enum NanoError: Error, LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to capture."
        }
    }
}
