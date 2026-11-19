import AVFoundation
import Speech

/// Dictation into whatever app is in front on the Mac: the iPhone listens, the page types the result
/// on the Mac. On iOS 26 and later it's Apple's newer on-device model (SpeechAnalyzer + SpeechTranscriber,
/// made for long dictation and much more accurate; its model downloads once). Before that, the older
/// SFSpeechRecognizer, which after a pause starts its text over: the earlier parts are kept here.
final class Dictation {
    /// What's been heard so far (main thread), and whether it's final.
    var onText: ((String, Bool) -> Void)?
    private var modern: AnyObject?          // ModernDictation, on iOS 26+
    @MainActor private var whisper: WhisperDictation?
    private let legacy = LegacyDictation()

    init() {
        legacy.onText = { [weak self] t, f in self?.onText?(t, f) }
    }

    /// engine: "whisper" (WhisperKit, once its model is loaded; until then Apple's) or "apple".
    func start(locale: String?, engine: String?, completion: @escaping (String?) -> Void) {
        MainActor.assumeIsolated { startOnMain(locale: locale, engine: engine, completion: completion) }
    }

    @MainActor private func startOnMain(locale: String?, engine: String?, completion: @escaping (String?) -> Void) {
        let loc = locale.map { Locale(identifier: $0) } ?? Locale.current
        // Whisper's model loads on its first dictation (Apple's engine takes that one), and is kept for a
        // dictation it starts even if the engine lets go of it meanwhile.
        let w = WhisperEngine.shared
        let kit = engine == "whisper" ? w.kit : nil
        if engine == "whisper", kit == nil { w.load() }
        // Whisper needs only the microphone; Speech Recognition is for Apple's engine.
        Dictation.permissions(speech: kit == nil) { error in MainActor.assumeIsolated {
            if let error { return completion(error) }
            if let kit {
                let d = WhisperDictation(kit: kit)
                d.onText = { [weak self] t, f in self?.onText?(t, f) }
                do { try d.start(); self.whisper = d; return completion(nil) } catch {
                    Dictation.endSession()
                    return completion((error as? DictationError)?.message ?? error.localizedDescription)
                }
            }
            if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
                Task { @MainActor in
                    let m = ModernDictation()
                    m.onText = { [weak self] t, f in self?.onText?(t, f) }
                    self.modern = m
                    do {
                        try await m.start(locale: loc)
                        completion(nil)
                    } catch {
                        self.modern = nil
                        Dictation.endSession()
                        completion((error as? DictationError)?.message ?? "Dictation didn't start (\(error.localizedDescription)).")
                    }
                }
            } else {
                completion(self.legacy.start(locale: loc))
            }
        } }
    }

    /// Stop listening; `deliver`: hand over what was heard (the final text arrives through onText).
    func stop(deliver: Bool = true) {
        MainActor.assumeIsolated { stopOnMain(deliver: deliver) }
    }

    @MainActor private func stopOnMain(deliver: Bool) {
        if let w = whisper {
            whisper = nil
            Task { @MainActor in
                let text = await w.stop()
                if deliver { self.onText?(text, true) } else { self.onText?("", true) }
            }
            return
        }
        if #available(iOS 26.0, *), let m = modern as? ModernDictation {
            modern = nil
            Task { @MainActor in
                let text = await m.stop()
                if deliver { self.onText?(text, true) }
            }
        } else {
            legacy.stop(deliver: deliver)
        }
    }

    /// The microphone, and Speech Recognition when Apple's engine is the one listening.
    private static func permissions(speech: Bool, _ done: @escaping (String?) -> Void) {
        let mic = {
            AVAudioApplication.requestRecordPermission { ok in
                DispatchQueue.main.async { done(ok ? nil : "Allow the microphone for Duo Mac in Settings.") }
            }
        }
        guard speech else { return mic() }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { return done("Allow Speech Recognition for Duo Mac in Settings.") }
                mic()
            }
        }
    }

    /// main thread: the audio session as it was before dictation changed it, to put back afterwards
    /// (the page's sound: AirPods back to full quality instead of call quality, for one).
    private static var before: (category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                                options: AVAudioSession.CategoryOptions)?

    static func startSession() throws {
        let s = AVAudioSession.sharedInstance()
        if before == nil { before = (s.category, s.mode, s.categoryOptions) }
        try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try s.setActive(true)
    }

    /// Dictation stopped (or didn't start): the audio session back the way it was.
    static func endSession() {
        guard let b = before else { return }
        before = nil
        try? AVAudioSession.sharedInstance().setCategory(b.category, mode: b.mode, options: b.options)
    }

    /// Joins finished stretches of text with one space between them.
    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }
}

struct DictationError: Error { let message: String }

// MARK: - iOS 26+: SpeechAnalyzer

@available(iOS 26.0, *)
@MainActor
final class ModernDictation {
    var onText: ((String, Bool) -> Void)?
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var finished = ""   // finalized stretches, in order
    private var volatile = ""   // the stretch still being worked out
    private var text: String { Dictation.join(finished, volatile) }

    func start(locale: Locale) async throws {
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationError(message: "Dictation doesn't support \(locale.identifier) yet.")
        }
        let transcriber = SpeechTranscriber(locale: loc, preset: .progressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onText?("Getting the dictation model ready (once)…", false)
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationError(message: "Dictation has no audio format for this iPhone.")
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        input = cont
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        results = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    let t = String(r.text.characters)
                    guard let self else { return }
                    if r.isFinal { self.finished = Dictation.join(self.finished, t); self.volatile = "" } else { self.volatile = t }
                    self.onText?(self.text, false)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)

        try Dictation.startSession()
        let node = engine.inputNode
        let inFormat = node.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: format) else {
            throw DictationError(message: "Dictation couldn't read the microphone.")
        }
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buf, _ in
            let ratio = format.sampleRate / inFormat.sampleRate
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            if err == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops listening and returns everything heard.
    func stop() async -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        Dictation.endSession()
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await results?.value
        analyzer = nil
        return text
    }
}

// MARK: - Before iOS 26: SFSpeechRecognizer

final class LegacyDictation {
    var onText: ((String, Bool) -> Void)?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var committed = ""  // what it said before it started over
    private var current = ""
    private var text: String { Dictation.join(committed, current) }

    func start(locale: Locale) -> String? {
        stop(deliver: false)
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            return "Dictation isn't available for this language right now."
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        do {
            try Dictation.startSession()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buf, _ in req?.append(buf) }
            engine.prepare()
            try engine.start()
        } catch {
            Dictation.endSession()
            return "Couldn't start the microphone (\(error.localizedDescription))."
        }
        committed = ""
        current = ""
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    let t = result.bestTranscription.formattedString
                    // After a pause the recognizer starts over with only the new words: keep the old ones.
                    if !self.current.isEmpty, t.count < self.current.count / 2, !self.current.hasPrefix(t) {
                        self.committed = Dictation.join(self.committed, self.current)
                    }
                    self.current = t
                    if !result.isFinal { self.onText?(self.text, false) }
                }
                if error != nil || result?.isFinal == true { self.deliver() }
            }
        }
        return nil
    }

    func stop(deliver: Bool = true) {
        guard task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        Dictation.endSession()
        request?.endAudio()
        if !deliver { task?.cancel(); finish(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.deliver() }
    }

    private func deliver() {
        guard task != nil else { return }
        let t = text
        finish()
        onText?(t, true)
    }

    private func finish() {
        guard task != nil else { return }
        task = nil
        request = nil
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        Dictation.endSession() // also when the recognizer stopped by itself
    }
}
