import CoreMedia
import Foundation

/// The Mac's sound, for the phone's speaker. ScreenCaptureKit hands over 48 kHz float audio; the
/// phone gets 24 kHz 16-bit stereo (96 KB/s), as binary messages:
///   [2] [channels] [rate / 100, UInt16 LE] then interleaved Int16 samples.
/// (Screen frames start with 1.) Silence isn't sent at all.
enum MacSound {
    static let rate = 24_000

    static func encode(_ sb: CMSampleBuffer) -> Data? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mSampleRate > 0 else { return nil }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return nil }
        var block: CMBlockBuffer?
        let size = MemoryLayout<AudioBufferList>.size + 8 * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return nil }
        // sample(c, i): channel c of frame i
        func sample(_ c: Int, _ i: Int) -> Float {
            if interleaved {
                guard let p = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return 0 }
                return p[i * channels + min(c, channels - 1)]
            }
            let b = buffers[min(c, buffers.count - 1)]
            guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            return p[i]
        }
        let step = max(1, Int((asbd.mSampleRate / Double(rate)).rounded())) // 48 kHz → 2
        let out = frames / step
        guard out > 0 else { return nil }
        var data = Data(count: 4 + out * 4)
        var loud: Float = 0
        data.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            dst[0] = 2
            dst[1] = 2
            let r = UInt16(rate / 100)
            dst[2] = UInt8(r & 0xFF)
            dst[3] = UInt8(r >> 8)
            let s = dst.baseAddress!.advanced(by: 4).assumingMemoryBound(to: Int16.self)
            for j in 0..<out {
                for c in 0..<2 {
                    var v: Float = 0
                    for k in 0..<step { v += sample(c, j * step + k) }
                    v /= Float(step)
                    loud = max(loud, abs(v))
                    s[j * 2 + c] = Int16(max(-32768, min(32767, (v * 32767).rounded()))).littleEndian
                }
            }
        }
        return loud < 0.0002 ? nil : data
    }
}
