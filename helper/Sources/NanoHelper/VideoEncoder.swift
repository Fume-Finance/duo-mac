import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// The screen as H.264 video, for phones that can decode it (WebCodecs). Much less data than JPEG
/// tiles when a lot of the screen changes (scrolling, moving windows, video), so it stays smooth on
/// slow links. The Mac's hardware encoder in low-latency mode: no B-frames, every frame is output
/// as soon as it's encoded, and the bitrate follows `bitrate` (set from the network's state).
///
/// Output is AVCC (length-prefixed NAL units), what WebCodecs' VideoDecoder takes with an avcC
/// `description`. Each key frame comes with that description and the codec string.
final class H264Encoder {
    struct Output {
        let data: Data
        let key: Bool
        let config: (codec: String, avcC: Data)?
    }

    enum Result {
        case frame(Output)
        case skipped   // the rate control dropped it (it may after a forced sharp frame): nothing to send
        case failed
    }

    /// How much detail a frame may have, as limits on its QP (lower = finer). Measured on screens of
    /// text, for slow links (a Tailscale relay):
    enum Detail {
        /// The rate control decides.
        case normal
        /// QP 26 or more: as sharp as text needs. Without it the rate control keeps refining a
        /// picture that's already sharp whenever something small moves (the wallpaper): 440 KB in
        /// the second after a switch instead of 110 KB.
        case enough
        /// QP 38 or more: a big change becomes about a third of the data (37 KB instead of 111 KB
        /// for a switch to another app), so it arrives sooner, a bit soft.
        case coarse
        /// QP 26–27: one frame that brings a coarse picture back to full detail. Left to the rate
        /// control, it would spend nothing on a still picture for a while after big frames, so
        /// it would stay soft.
        case sharp
    }

    let width: Int, height: Int
    private var session: VTCompressionSession?
    private var frames: Int64 = 0
    private var detail = Detail.normal
    private(set) var bitrate: Int

    init?(width: Int, height: Int, bitrate: Int) {
        self.width = width
        self.height = height
        self.bitrate = bitrate
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else {
            Log.warn("H.264: can't create an encoder (\(status))")
            return nil
        }
        session = s
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(s, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        // Key frames only when asked (a new phone, a decoder error): the link never loses data.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 100_000 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 3600 as CFNumber)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit { invalidate() }

    func invalidate() {
        guard let s = session else { return }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
        session = nil
    }

    func setBitrate(_ bps: Int) {
        guard let s = session, abs(bps - bitrate) > bitrate / 10 else { return }
        bitrate = bps
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
    }

    /// Encodes one frame; `done` runs on the encoder's thread with the result.
    func encode(_ pb: CVPixelBuffer, key: Bool, detail: Detail, done: @escaping (Result) -> Void) {
        guard let s = session else { return done(.failed) }
        if detail != self.detail {
            self.detail = detail
            // QP limits; 0 and 51 = none (not -1, the unset default: setting that back upsets the
            // rate control). The one being lifted goes first, so they never conflict.
            let minQP = switch detail {
            case .normal: 0
            case .enough, .sharp: 26
            case .coarse: 38
            }
            let limits = [(kVTCompressionPropertyKey_MinAllowedFrameQP, minQP),
                          (kVTCompressionPropertyKey_MaxAllowedFrameQP, detail == .sharp ? 27 : 51)]
            for (k, v) in detail == .coarse ? limits.reversed() : limits { VTSessionSetProperty(s, key: k, value: v as CFNumber) }
        }
        frames += 1
        let pts = CMTime(value: frames, timescale: 60)
        let props = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                                     frameProperties: props, infoFlagsOut: nil) { status, flags, sb in
            if status == noErr && (sb == nil || flags.contains(.frameDropped)) { return done(.skipped) }
            guard status == noErr, let sb, let out = H264Encoder.output(sb) else { return done(.failed) }
            done(.frame(out))
        }
        if status != noErr {
            Log.warn("H.264: encode failed (\(status))")
            done(.failed)
        }
    }

    private static func output(_ sb: CMSampleBuffer) -> Output? {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let ok = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) } == noErr
        guard ok else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var config: (String, Data)?
        if key, let fd = CMSampleBufferGetFormatDescription(sb),
           let atoms = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let avcC = atoms["avcC"] as? Data, avcC.count >= 4 {
            // avc1.PPCCLL: profile, constraint flags and level, straight from the avcC record.
            let codec = String(format: "avc1.%02x%02x%02x", avcC[1], avcC[2], avcC[3])
            config = (codec, avcC)
        }
        return Output(data: data, key: key, config: config)
    }
}
