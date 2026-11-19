import AVFoundation
import UIKit
import VideoToolbox

/// The Mac's screen, decoded by the iPhone's hardware decoder and shown in a layer behind the page.
/// A web page draws at most 60 times a second; this layer follows the display, up to 120 Hz.
///
/// The page keeps the connection: it hands each H.264 (or HEVC) frame over (web/js/screen.js), says
/// where the picture goes (its canvas, which it leaves see-through), and acknowledges a frame to the Mac
/// once it's been decoded here, as before.
final class NativeVideo {
    let view = UIView()
    private let main = AVSampleBufferDisplayLayer()
    /// The picture's place in the page. The decoded frame can be bigger than the picture: HEVC comes out padded
    /// to whole coding blocks, on the right and at the bottom (it showed as stripes on the right edge). The
    /// video layer is then made that much bigger inside this one, which cuts the padding off.
    private let clip = CALayer()
    private var frameRect = CGRect.zero                 // main thread
    private var overscan = CGSize(width: 1, height: 1)  // main thread: decoded size ÷ picture size
    private var size = (w: 0, h: 0)                     // video queue: the picture's own size
    /// A line for the Mac's log (the page passes it on), once per stream: the decoded size. Main thread.
    var onInfo: ((String) -> Void)?
    private var reported = false                        // video queue
    private let queue = DispatchQueue(label: "duomac.video", qos: .userInteractive)
    private var format: CMVideoFormatDescription?   // video queue
    private var session: VTDecompressionSession?    // video queue
    private var link: CADisplayLink?                // main thread
    private var away = false                        // main thread: the app is in the background

    /// Frames a second to show, and to ask the Mac for: the screen's fastest (120 on ProMotion), but
    /// 60 in Low Power Mode or while the iPhone is hot.
    static var frameRate: Int {
        let p = ProcessInfo.processInfo
        if p.isLowPowerModeEnabled || p.thermalState == .serious || p.thermalState == .critical { return 60 }
        return UIScreen.main.maximumFramesPerSecond
    }

    init() {
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        main.videoGravity = .resize
        main.backgroundColor = UIColor.black.cgColor
        clip.masksToBounds = true
        clip.addSublayer(main)
        view.layer.addSublayer(clip)
        clip.isHidden = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.away = true
            self?.followFrameRate()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.away = false
            self?.followFrameRate()
        }
    }

    // MARK: Where (main thread)

    /// The picture's frame in the page (points).
    func place(on: Bool, frame: CGRect) {
        frameRect = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.isHidden = !on
        layoutVideo()
        CATransaction.commit()
        followFrameRate()
        if !on { queue.async { self.reset() } }
    }

    /// main thread
    private func layoutVideo() {
        clip.frame = frameRect
        main.frame = CGRect(x: 0, y: 0, width: frameRect.width * overscan.width, height: frameRect.height * overscan.height)
    }

    /// While the picture shows (and the app is in front), a display link asks for the video's frame
    /// rate: a ProMotion screen only runs at 120 Hz while something on it asks for that.
    func followFrameRate() {
        guard !clip.isHidden, !away else {
            link?.invalidate()
            link = nil
            return
        }
        if link == nil {
            let l = CADisplayLink(target: FrameTick(), selector: #selector(FrameTick.tick))
            l.add(to: .main, forMode: .common)
            link = l
        }
        let fps = Float(Self.frameRate)
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
    }

    // MARK: Decoding (any thread in, the completion on the video queue)

    /// The stream's description (sent before each key frame): its codec ("avc1.…" for H.264, "hvc1.…"
    /// or "hev1.…" for HEVC), its avcC (or hvcC), width, height.
    func configure(codec: String?, description: Data, width: Int, height: Int, completion: @escaping (Bool) -> Void) {
        let hevc = codec?.hasPrefix("hvc1") == true || codec?.hasPrefix("hev1") == true
        queue.async {
            var fd: CMVideoFormatDescription?
            let ext = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [hevc ? "hvcC" : "avcC": description]] as CFDictionary
            guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                 width: Int32(width), height: Int32(height), extensions: ext,
                                                 formatDescriptionOut: &fd) == noErr,
                  let fd else { return completion(false) }
            self.size = (width, height)
            self.reported = false
            if let s = self.session, VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: fd) {
                self.format = fd
                return completion(true)
            }
            self.reset()
            let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                         kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
            var s: VTDecompressionSession?
            guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                               imageBufferAttributes: attrs, outputCallback: nil,
                                               decompressionSessionOut: &s) == noErr, let s else { return completion(false) }
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            self.session = s
            self.format = fd
            completion(true)
        }
    }

    /// One frame (length-prefixed NAL units). Decoded and on screen when `completion(true)` runs.
    func decode(_ data: Data, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard let s = self.session, let fd = self.format, !data.isEmpty else { return completion(false) }
            var block: CMBlockBuffer?
            let n = data.count
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: n,
                                                     flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
                  let block else { return completion(false) }
            let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                              offsetIntoDestination: 0, dataLength: n) }
            var sample: CMSampleBuffer?
            var size = n
            guard copied == noErr,
                  CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: fd, sampleCount: 1,
                                            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
                  let sample else { return completion(false) }
            var shown = false
            let picture = self.size
            let status = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                guard status == noErr, let image else { return }
                self.show(image, picture: picture)
                shown = true
            }
            if status == kVTInvalidSessionErr { self.reset() }
            completion(status == noErr && shown)
        }
    }

    private func show(_ image: CVImageBuffer, picture: (w: Int, h: Int)) {
        // Padded (see `clip`): how much bigger than the picture, for the layout.
        let W = CVPixelBufferGetWidth(image), H = CVPixelBufferGetHeight(image)
        if !reported {
            reported = true
            let line = "video: decoded \(W)×\(H) for a \(picture.w)×\(picture.h) picture"
            DispatchQueue.main.async { self.onInfo?(line) }
        }
        if picture.w > 0, picture.h > 0 {
            let o = CGSize(width: max(1, CGFloat(W) / CGFloat(picture.w)), height: max(1, CGFloat(H) / CGFloat(picture.h)))
            DispatchQueue.main.async {
                guard o != self.overscan else { return }
                self.overscan = o
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.layoutVideo()
                CATransaction.commit()
            }
        }
        var fmt: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &fmt) == noErr,
              let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: fmt,
                                                       sampleTiming: &timing, sampleBufferOut: &sb) == noErr, let sb else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let r = main.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        r.enqueue(sb)
    }

    /// video queue
    private func reset() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
        format = nil
    }
}

/// The display link's target: it only has to exist (and ask for a frame rate), not draw anything.
private final class FrameTick: NSObject {
    @objc func tick(_ link: CADisplayLink) {}
}
