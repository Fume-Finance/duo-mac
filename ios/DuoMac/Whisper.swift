import AVFoundation
import Network
import UIKit
import WhisperKit

/// Whisper on the iPhone (WhisperKit, open source, all on the phone): recognizes the language by
/// itself (English, Italian… even mixed), and is the most accurate. Its model (large-v3 turbo, ~630 MB)
/// downloads only when asked to (Settings › Dictation: on Wi-Fi, or on mobile data if allowed), and loads
/// on the first Whisper dictation; until it's ready, dictation uses Apple's engine (Dictation.swift).
@MainActor
final class WhisperEngine {
    static let shared = WhisperEngine()
    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    /// The model's download size (the page says it before downloading).
    static let bytes = 632_000_000
    /// Where the model is once it's all downloaded: relative to `base`, as the app's own folder moves
    /// when it's reinstalled. Older copies of the app saved its full path (it went into Documents).
    private static let folderKey = "whisperModelFolder"

    enum State: Equatable { case idle, downloading(Int), loading, ready, waitingForWiFi, failed(String) }
    private(set) var state = State.idle
    /// The loaded model (about a gigabyte of memory). Let go of when iOS is short of memory or the app
    /// has been in the background for 5 minutes; it loads again on the next Whisper dictation.
    private(set) var kit: WhisperKit?
    private var wanted = false      // a download asked for, waiting for a network it may use
    private var cellular = false    // …mobile data allowed for it
    private var network: NWPath?    // as last seen
    private var monitor: NWPathMonitor?
    private var awaySince: Date?
    private var awayTimer: Timer?

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.unload() }
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.away(true) }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.away(false) }
        }
    }

    /// New downloads go here, left out of iCloud backups (it can always download again).
    private static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("whisper", isDirectory: true)
    }

    /// The model's folder, if it's on the phone.
    private var folder: URL? {
        guard let p = UserDefaults.standard.string(forKey: Self.folderKey) else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = !p.hasPrefix("/") ? Self.base.appendingPathComponent(p, isDirectory: true)
            // A full path from an older copy: the same place in this copy's Documents.
            : p.range(of: "/Documents/").map { docs.appendingPathComponent(String(p[$0.upperBound...]), isDirectory: true) }
                ?? URL(fileURLWithPath: p)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var isDownloaded: Bool { folder != nil }

    // MARK: Downloading (only when asked)

    /// Downloads the model: now on Wi-Fi (or on mobile data if `cellular`), otherwise once on Wi-Fi.
    func download(cellular: Bool) {
        guard folder == nil else { return }
        if case .downloading = state { return }
        wanted = true
        self.cellular = cellular
        if let network { return networkChanged(network) }
        state = .downloading(0) // for the moment until the network is known (Wi-Fi, most likely)
        guard monitor == nil else { return } // its first answer is on its way
        let m = NWPathMonitor()
        m.pathUpdateHandler = { path in Task { @MainActor in WhisperEngine.shared.networkChanged(path) } }
        m.start(queue: DispatchQueue(label: "duomac.whisper.network"))
        monitor = m
    }

    private func networkChanged(_ path: NWPath) {
        network = path
        guard wanted else { return }
        // Not on mobile data (or a hotspot) unless allowed, and not offline: it starts when that changes.
        guard path.status == .satisfied, cellular || !(path.isExpensive || path.usesInterfaceType(.cellular)) else {
            state = .waitingForWiFi
            return
        }
        wanted = false
        fetch()
    }

    private func fetch() {
        state = .downloading(0)
        print("whisper: downloading \(Self.variant)")
        Task {
            do {
                var base = Self.base
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                var noBackup = URLResourceValues()
                noBackup.isExcludedFromBackup = true
                try base.setResourceValues(noBackup)
                let f = try await WhisperKit.download(variant: Self.variant, downloadBase: base) { p in
                    let pct = Int(p.fractionCompleted * 100)
                    Task { @MainActor in
                        let w = WhisperEngine.shared
                        guard case .downloading(let old) = w.state, old != pct else { return }
                        if old / 10 != pct / 10 { print("whisper: \(pct)%") }
                        w.state = .downloading(pct)
                    }
                }
                let inBase = f.path.hasPrefix(base.path + "/")
                UserDefaults.standard.set(inBase ? String(f.path.dropFirst(base.path.count + 1)) : f.path, forKey: Self.folderKey)
                state = .idle
                print("whisper: downloaded")
            } catch {
                state = .failed(error.localizedDescription)
                print("whisper: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Memory

    /// Loads the downloaded model, in the background (for the next dictation).
    func load() {
        guard kit == nil, state != .loading, let folder else { return }
        state = .loading
        print("whisper: loading")
        Task {
            do {
                let cfg = WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .error,
                                           prewarm: true, load: true, download: false)
                kit = try await WhisperKit(cfg)
                state = .ready
                print("whisper: ready")
            } catch {
                state = .failed(error.localizedDescription)
                print("whisper: \(error.localizedDescription)")
            }
        }
    }

    /// The model, loading it first if needed (a dictation that started before it was ready waits for it
    /// here, at the end: it only needs it to transcribe). nil if it isn't downloaded or can't load.
    func ready() async -> WhisperKit? {
        if let kit { return kit }
        load()
        while state == .loading { try? await Task.sleep(nanoseconds: 100_000_000) }
        return kit
    }

    private func unload() {
        guard kit != nil else { return }
        kit = nil
        state = .idle
        print("whisper: unloaded")
    }

    /// The app went to the background (or came back): after 5 minutes there, the model goes. Suspended,
    /// the app can't run the timer, so the same check happens when it's back.
    private func away(_ gone: Bool) {
        awayTimer?.invalidate()
        awayTimer = nil
        if gone {
            awaySince = Date()
            awayTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.unload() }
            }
        } else {
            if let t = awaySince, Date().timeIntervalSince(t) >= 300 { unload() }
            awaySince = nil
        }
    }
}

/// Records while you speak, then Whisper transcribes all of it when you stop.
@MainActor
final class WhisperDictation {
    var onText: ((String, Bool) -> Void)?
    /// Kept until it has transcribed, even if the engine lets go of it meanwhile. nil while the model is
    /// still loading: it records anyway, and waits for the model when you stop.
    private var kit: WhisperKit?
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()
    private var ticker: Timer?
    private var started = Date()

    init(kit: WhisperKit?) {
        self.kit = kit
    }

    func start() throws {
        try Dictation.startSession()
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw DictationError(message: "Dictation couldn't read the microphone.")
        }
        let node = engine.inputNode
        let inFormat = node.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw DictationError(message: "Dictation couldn't read the microphone.")
        }
        samples = []
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            let cap = AVAudioFrameCount(Double(buf.frameLength) * 16_000 / inFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            guard err == nil, let ch = out.floatChannelData else { return }
            let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            guard let self else { return }
            self.lock.lock(); self.samples.append(contentsOf: chunk); self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        started = Date()
        onText?("Listening…", false)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let s = Int(Date().timeIntervalSince(self.started))
            Task { @MainActor in self.onText?("Listening… \(s / 60):\(String(format: "%02d", s % 60))", false) }
        }
    }

    /// Stops and returns the transcription.
    func stop() async -> String {
        ticker?.invalidate()
        ticker = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        Dictation.endSession()
        let audio = lock.withLock { () -> [Float] in
            let a = samples
            samples = []
            return a
        }
        guard audio.count > 8_000 else { return "" } // under half a second
        if kit == nil {
            onText?("Loading Whisper…", false)
            kit = await WhisperEngine.shared.ready()
        }
        onText?("Transcribing…", false)
        do { return try await transcribe(audio) } catch {
            print("whisper: \(error.localizedDescription)")
            return ""
        }
    }

    /// 16 kHz mono samples → text, in whatever language(s) it hears.
    private func transcribe(_ samples: [Float]) async throws -> String {
        let options = DecodingOptions(task: .transcribe, language: nil, temperatureFallbackCount: 3,
                                      usePrefillPrompt: false, detectLanguage: true, skipSpecialTokens: true,
                                      withoutTimestamps: true, chunkingStrategy: .vad)
        guard let kit else { throw DictationError(message: "Whisper's model couldn't be loaded.") }
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
