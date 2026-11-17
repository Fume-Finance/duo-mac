import AVFoundation
import Speech

/// Dictation into whatever app is in front on the Mac: the iPhone's own speech recognition (on the
/// phone when it can, so nothing leaves it), and the page types the result on the Mac.
final class Dictation {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var text = ""
    /// What's been heard so far (main thread), and whether it's final.
    var onText: ((String, Bool) -> Void)?

    var running: Bool { task != nil }

    func start(locale: String?, completion: @escaping (String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { return completion("Allow Speech Recognition for Duo Mac in Settings.") }
                AVAudioApplication.requestRecordPermission { ok in
                    DispatchQueue.main.async {
                        guard ok else { return completion("Allow the microphone for Duo Mac in Settings.") }
                        completion(self.begin(locale: locale))
                    }
                }
            }
        }
    }

    private func begin(locale: String?) -> String? {
        stop(deliver: false)
        let recognizer = locale.flatMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) } ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { return "Dictation isn't available for this language right now." }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
            try s.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buf, _ in req?.append(buf) }
            engine.prepare()
            try engine.start()
        } catch {
            return "Couldn't start the microphone (\(error.localizedDescription))."
        }
        text = ""
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.text = result.bestTranscription.formattedString
                    if !result.isFinal { self.onText?(self.text, false) }
                }
                if error != nil || result?.isFinal == true { self.deliver() }
            }
        }
        return nil
    }

    /// Stop listening; `deliver`: hand over what was heard (the final text arrives through onText).
    func stop(deliver: Bool = true) {
        guard task != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        if !deliver { task?.cancel(); finish(); return }
        // The recognizer sends its final result shortly; if it doesn't, what was heard so far.
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
        // The session stays active: the Mac's sound may be playing through it.
    }
}
