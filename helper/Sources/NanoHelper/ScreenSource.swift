import AppKit
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Something that produces screen frames: the real display (ScreenCaptureKit) or the test pattern.
protocol FrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer) -> Void)? { get set }
    /// The Mac's sound, captured with the screen (48 kHz float). Capture queue.
    var onAudio: ((CMSampleBuffer) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var info: DisplayInfo { get }
    var displayIndex: Int? { get set }
    /// When set (the Duo display), capture this display instead of `displayIndex`. Main thread.
    var targetDisplayID: CGDirectDisplayID? { get set }
    /// Frames delivered by the system so far (diagnostics).
    var framesCaptured: Int { get }
    /// Re-reads display geometry. Main thread only.
    func refreshInfo()
    func start(width: Int, height: Int, fps: Int, completion: @escaping (Error?) -> Void)
    func resize(width: Int, height: Int)
    func stop()
}

struct DisplayInfo {
    var displayID: CGDirectDisplayID
    var bounds: CGRect          // global coordinates, points (what mouse events use)
    var pixelSize: CGSize       // native pixels
    var notch: CGSize?          // camera housing size in points, if the display has one
    var name: String

    static func activeDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// All displays, for the phone's display picker. Main thread only.
    static func all() -> [DisplayInfo] {
        activeDisplays().indices.map { resolve(index: $0) }
    }

    /// Main thread only (uses NSScreen).
    static func resolve(index: Int?) -> DisplayInfo {
        let list = activeDisplays()
        var id = CGMainDisplayID()
        if let index, index >= 0, index < list.count { id = list[index] }
        return resolve(id: id)
    }

    /// Main thread only (uses NSScreen).
    static func resolve(id: CGDirectDisplayID) -> DisplayInfo {
        let bounds = CGDisplayBounds(id)
        var px = CGSize(width: bounds.width, height: bounds.height)
        if let mode = CGDisplayCopyDisplayMode(id) {
            px = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        }
        var notch: CGSize? = nil
        var name = "Display"
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }) {
            name = screen.localizedName
            if screen.safeAreaInsets.top > 0,
               let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                notch = CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
            }
        }
        return DisplayInfo(displayID: id, bounds: bounds, pixelSize: px, notch: notch, name: name)
    }
}

final class ScreenSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var info: DisplayInfo
    /// Which display to capture (index into the active display list; nil = main). Main thread.
    var displayIndex: Int?
    var targetDisplayID: CGDirectDisplayID?
    var framesCaptured = 0
    private let sampleQueue = DispatchQueue(label: "nano.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "nano.capture.audio", qos: .userInteractive)
    private let control = DispatchQueue(label: "nano.capture.control")

    // control-queue state
    private var stream: SCStream?
    private var streamDisplay: CGDirectDisplayID = 0
    private var wanted: (w: Int, h: Int, fps: Int, display: CGDirectDisplayID)?
    private var active: (w: Int, h: Int)?
    private var starting = false
    private var completions: [(Error?) -> Void] = []

    init(displayIndex: Int?) {
        self.displayIndex = displayIndex
        info = DisplayInfo.resolve(index: displayIndex)
        super.init()
    }

    func refreshInfo() {
        if let t = targetDisplayID {
            info = DisplayInfo.resolve(id: t)
            if info.name == "Display" { info.name = "Duo Mac" }
        } else {
            info = DisplayInfo.resolve(index: displayIndex)
        }
    }

    func start(width: Int, height: Int, fps: Int, completion: @escaping (Error?) -> Void) {
        let display = info.displayID // the caller has just refreshed `info`
        control.async {
            self.wanted = (width, height, fps, display)
            if let s = self.stream, self.streamDisplay != display {
                // Another display was picked: drop the old stream and start over.
                self.stream = nil
                self.active = nil
                Task { try? await s.stopCapture() }
            }
            if self.stream != nil {
                self.applyResize()
                completion(nil)
                return
            }
            self.completions.append(completion)
            self.launch()
        }
    }

    /// control queue: start a stream for `wanted`, unless one is already starting
    /// (that one re-checks `wanted` when it finishes).
    private func launch() {
        guard !starting, let want = wanted else { return }
        starting = true
        Task {
            var failure: Error? = nil
            var started: SCStream? = nil
            do {
                // A just-created display (the Duo display) can take a moment to become capturable.
                var found: SCDisplay?
                for _ in 0..<16 {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    found = content.displays.first(where: { $0.displayID == want.display })
                    if found != nil { break }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                guard let display = found else { throw NanoError.noDisplay }
                let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                 configuration: ScreenSource.config(want.w, want.h, want.fps), delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.sampleQueue)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                try await s.startCapture()
                started = s
            } catch {
                failure = error
            }
            self.control.async {
                self.starting = false
                let done = self.completions
                self.completions = []
                if let s = started {
                    if let now = self.wanted, now.display == want.display {
                        self.stream = s
                        self.streamDisplay = want.display
                        self.active = (want.w, want.h)
                        Log.info("Capturing display \(want.display) at \(want.w)×\(want.h)")
                        self.applyResize()
                    } else {
                        // Stopped, or switched to another display, while starting.
                        Task { try? await s.stopCapture() }
                        if self.wanted != nil {
                            self.completions = done
                            self.launch()
                            return
                        }
                    }
                }
                for c in done { c(failure) }
            }
        }
    }

    func resize(width: Int, height: Int) {
        control.async {
            guard var w = self.wanted else { return }
            w.w = width
            w.h = height
            self.wanted = w
            self.applyResize()
        }
    }

    func stop() {
        control.async {
            self.wanted = nil
            if let s = self.stream {
                self.stream = nil
                self.active = nil
                Task { try? await s.stopCapture() }
                Log.info("Capture stopped")
            }
        }
    }

    /// control queue
    private func applyResize() {
        guard let stream, let w = wanted, let a = active, a.w != w.w || a.h != w.h else { return }
        active = (w.w, w.h)
        let cfg = ScreenSource.config(w.w, w.h, w.fps)
        Task {
            do {
                try await stream.updateConfiguration(cfg)
                Log.info("Capture resized to \(w.w)×\(w.h)")
            } catch {
                Log.warn("Capture resize failed: \(error.localizedDescription)")
            }
        }
    }

    static func config(_ w: Int, _ h: Int, _ fps: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = w & ~1  // even sizes: H.264 needs them
        c.height = h & ~1
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.showsCursor = false // the phone draws the pointer itself (MacPointer), with no lag
        c.queueDepth = 5
        c.scalesToFit = true
        c.captureResolution = .best
        // The Mac's sound too (all apps, not Duo Mac's own), for the phone's speaker.
        c.capturesAudio = true
        c.excludesCurrentProcessAudio = true
        c.sampleRate = 48_000
        c.channelCount = 2
        return c
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sb.isValid { onAudio?(sb) }
            return
        }
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw), status == .complete,
              let pb = sb.imageBuffer else { return }
        framesCaptured &+= 1
        onFrame?(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        control.async {
            // An old stream (e.g. of a Duo display we just replaced) reporting its end: not a problem.
            guard self.stream === stream else {
                Log.debug("Old capture stream ended: \(error.localizedDescription)")
                return
            }
            Log.warn("Screen capture stopped: \(error.localizedDescription)")
            self.stream = nil
            self.active = nil
            self.onError?(error)
        }
    }
}
