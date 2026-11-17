import AVFoundation
import UIKit
import VideoToolbox

/// The Mac's screen, decoded by the iPhone's hardware decoder and shown in a layer behind the page.
/// A web page draws at most 60 times a second; this layer follows the display, up to 120 Hz.
///
/// The page keeps the connection: it hands each H.264 frame over (web/js/screen.js), says where the
/// picture goes (its canvas, which it leaves see-through), and acknowledges a frame to the Mac once
/// it's been decoded here, as before.
final class NativeVideo {
    let view = UIView()
    private let main = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "duomac.video", qos: .userInteractive)
    private var format: CMVideoFormatDescription?   // video queue
    private var session: VTDecompressionSession?    // video queue

    init() {
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        main.videoGravity = .resize
        main.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(main)
        main.isHidden = true
    }

    // MARK: Where (main thread)

    /// The picture's frame in the page (points).
    func place(on: Bool, frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        main.isHidden = !on
        main.frame = frame
        CATransaction.commit()
        if !on { queue.async { self.reset() } }
    }

    // MARK: Decoding (any thread in, the completion on the video queue)

    /// The stream's description (sent before each key frame): [avcC], width, height.
    func configure(avcC: Data, width: Int, height: Int, completion: @escaping (Bool) -> Void) {
        queue.async {
            var fd: CMVideoFormatDescription?
            let ext = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": avcC]] as CFDictionary
            guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264, width: Int32(width),
                                                 height: Int32(height), extensions: ext, formatDescriptionOut: &fd) == noErr,
                  let fd else { return completion(false) }
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

    /// One frame (AVCC: length-prefixed NAL units). Decoded and on screen when `completion(true)` runs.
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
            let status = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                guard status == noErr, let image else { return }
                self.show(image)
                shown = true
            }
            if status == kVTInvalidSessionErr { self.reset() }
            completion(status == noErr && shown)
        }
    }

    private func show(_ image: CVImageBuffer) {
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
