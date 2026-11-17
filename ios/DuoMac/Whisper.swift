import AVFoundation
import WhisperKit

/// Whisper on the iPhone (WhisperKit, open source, all on the phone): recognizes the language by
/// itself (English, Italian… even mixed), and is the most accurate. Its model (large-v3 turbo, ~630 MB)
/// downloads once (Wi-Fi or mobile data); until it's ready, dictation uses Apple's engine (Dictation.swift).
@MainActor
final class WhisperEngine {
    static let shared = WhisperEngine()
    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private static let folderKey = "whisperModelFolder"

    enum State: Equatable { case idle, downloading(Int), loading, ready, waitingForWiFi, failed(String) }
    private(set) var state = State.idle
    private var kit: WhisperKit?
    private var preparing = false

    var isReady: Bool { kit != nil }

    private var savedFolder: URL? {
        guard let p = UserDefaults.standard.string(forKey: Self.folderKey),
              FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    /// Downloaded already: load it (at launch, so it's ready when you dictate).
    func loadIfDownloaded() {
        if savedFolder != nil { prepare() }
    }

    /// Download and load, in the background.
    func prepare() {
        print("whisper: prepare (preparing \(preparing), ready \(kit != nil))")
        guard !preparing, kit == nil else { return }
        preparing = true
        Task {
            defer { preparing = false }
            do {
                var folder = savedFolder
                if folder == nil {
                    print("whisper: downloading \(Self.variant)")
                    state = .downloading(0)
                    let f = try await WhisperKit.download(variant: Self.variant) { p in
                        let pct = Int(p.fractionCompleted * 100)
                        Task { @MainActor in
                            if case .downloading(let old) = WhisperEngine.shared.state, old / 10 != pct / 10 { print("whisper: \(pct)%") }
                            WhisperEngine.shared.state = .downloading(pct)
                        }
                    }
                    UserDefaults.standard.set(f.path, forKey: Self.folderKey)
                    folder = f
                }
                state = .loading
                print("whisper: loading")
                let cfg = WhisperKitConfig(modelFolder: folder!.path, verbose: false, logLevel: .error,
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

    /// 16 kHz mono samples → text, in whatever language(s) it hears.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let kit else { throw DictationError(message: "Whisper isn't ready yet.") }
        let options = DecodingOptions(task: .transcribe, language: nil, temperatureFallbackCount: 3,
                                      usePrefillPrompt: false, detectLanguage: true, skipSpecialTokens: true,
                                      withoutTimestamps: true, chunkingStrategy: .vad)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Records while you speak, then Whisper transcribes all of it when you stop.
@MainActor
final class WhisperDictation {
    var onText: ((String, Bool) -> Void)?
    private let engine = AVAudioEngine()
    private var samples: [Float] = []
    private let lock = NSLock()
    private var ticker: Timer?
    private var started = Date()

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
        lock.lock(); let audio = samples; samples = []; lock.unlock()
        guard audio.count > 8_000 else { return "" } // under half a second
        onText?("Transcribing…", false)
        do { return try await WhisperEngine.shared.transcribe(audio) } catch {
            print("whisper: \(error.localizedDescription)")
            return ""
        }
    }
}
