import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

/// The Mac's sound, for the phone's speaker. ScreenCaptureKit hands over 48 kHz float audio; the
/// phone gets 24 kHz 16-bit stereo (96 KB/s), as binary messages:
///   [2] [channels] [rate / 100, UInt16 LE] then interleaved Int16 samples.
/// (Screen frames start with 1.) Silence isn't sent at all.
enum MacSound {
    static let rate = 24_000

    /// The buffer as interleaved stereo floats, with its sample rate (ScreenCaptureKit: 48 kHz, planar).
    static func stereo(_ sb: CMSampleBuffer) -> (samples: [Float], rate: Double)? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mSampleRate > 0 else { return nil }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return nil }
        var size = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return nil }
        var out = [Float](repeating: 0, count: frames * 2)
        for c in 0..<2 {
            if interleaved {
                guard let p = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return nil }
                for i in 0..<frames { out[i * 2 + c] = p[i * channels + min(c, channels - 1)] }
            } else {
                guard let p = buffers[min(c, buffers.count - 1)].mData?.assumingMemoryBound(to: Float.self) else { return nil }
                for i in 0..<frames { out[i * 2 + c] = p[i] }
            }
        }
        return (out, asbd.mSampleRate)
    }

    static func encode(_ sb: CMSampleBuffer) -> Data? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mSampleRate > 0 else { return nil }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return nil }
        // Ask how big the buffer list must be, then fetch it.
        var size = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { return nil }
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

/// The Mac's sound as Opus (macOS's own encoder): 48 kHz stereo in 20 ms packets at about 96 kbit/s, an eighth
/// of the plain samples above, for phones that decode Opus (WebCodecs). One packet per message:
///   [6] [channels] [rate / 100, UInt16 LE] then the Opus packet.
/// Every packet is encoded (the encoder keeps its state), but silent ones aren't sent. Audio capture queue only.
final class OpusEncoder {
    private var converter: AudioConverterRef?
    private var fifo: [Float] = []             // interleaved stereo, waiting for a whole packet
    private static let frame = 960             // 20 ms at 48 kHz
    // The packet being encoded, where the converter's callback reads it (a fixed buffer: it must not move).
    private let chunk = UnsafeMutablePointer<Float>.allocate(capacity: OpusEncoder.frame * 2)
    private var chunkRead = 0

    init?() {
        var input = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var output = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                 mBytesPerPacket: 0, mFramesPerPacket: UInt32(OpusEncoder.frame),
                                                 mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var c: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &c) == noErr, let c else {
            Log.warn("Opus: this Mac can't encode it; sending plain sound")
            return nil
        }
        var bitrate: UInt32 = 96_000
        AudioConverterSetProperty(c, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        converter = c
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        chunk.deallocate()
    }

    /// The messages ready to send for this buffer (none until a whole packet is in).
    func encode(_ sb: CMSampleBuffer) -> [Data] {
        guard let converter, let (samples, rate) = MacSound.stereo(sb), rate == 48_000 else { return [] }
        fifo.append(contentsOf: samples)
        var out: [Data] = []
        let n = OpusEncoder.frame * 2
        while fifo.count >= n {
            var loud: Float = 0
            for i in 0..<n {
                chunk[i] = fifo[i]
                loud = max(loud, abs(fifo[i]))
            }
            fifo.removeFirst(n)
            chunkRead = 0
            var packet = [UInt8](repeating: 0, count: 1500)
            var count: UInt32 = 1
            var desc = AudioStreamPacketDescription()
            let size: Int = packet.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                let me = Unmanaged.passUnretained(self).toOpaque()
                let status = AudioConverterFillComplexBuffer(converter, OpusEncoder.supply, me, &count, &abl, &desc)
                return (status == noErr || status == OpusEncoder.drained) && count > 0 ? Int(abl.mBuffers.mDataByteSize) : 0
            }
            guard size > 0, loud >= 0.0002 else { continue }
            var m = Data(capacity: 4 + size)
            m.append(6)
            m.append(2)
            m.appendLE(UInt16(480))
            m.append(contentsOf: packet[0..<size])
            out.append(m)
        }
        return out
    }

    /// "No more input for now": the converter keeps what it has and goes on next time.
    private static let drained: OSStatus = 0x6E6F6474 // 'nodt'

    private static let supply: AudioConverterComplexInputDataProc = { _, packets, data, _, user in
        let me = Unmanaged<OpusEncoder>.fromOpaque(user!).takeUnretainedValue()
        let left = OpusEncoder.frame - me.chunkRead
        guard left > 0 else { packets.pointee = 0; return drained }
        let n = min(Int(packets.pointee), left)
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = 2
        data.pointee.mBuffers.mDataByteSize = UInt32(n * 8)
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(me.chunk + me.chunkRead * 2)
        packets.pointee = UInt32(n)
        me.chunkRead += n
        return noErr
    }
}

/// While the iPhone plays the Mac's sound, the Mac's own speakers are muted (the Mac may be at home,
/// playing to an empty room); they come back when the phone stops or leaves. Capture doesn't mind:
/// ScreenCaptureKit records each app's audio before the output device. A speaker that was already
/// muted is left alone. If Duo Mac stops while it holds them muted, the next launch unmutes them.
final class MacSpeakers {
    private static let key = "MacSpeakersMutedUID"
    private var muted: AudioDeviceID? // main thread
    private var listening = false

    init() {
        if let uid = UserDefaults.standard.string(forKey: Self.key) {
            if let dev = Microphone.deviceID(uid) { Self.setMute(dev, false) }
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }

    /// main thread
    func mute(_ on: Bool) {
        if on {
            guard muted == nil, let dev = Self.defaultOutput(), Self.isMuted(dev) == false, Self.setMute(dev, true) else { return }
            muted = dev
            if let uid = Microphone.uid(of: dev) { UserDefaults.standard.set(uid, forKey: Self.key) }
            Log.info("Mac speakers muted while the iPhone plays the sound (\(Microphone.name(of: dev) ?? "output"))")
            watchOutput()
        } else if let dev = muted {
            Self.setMute(dev, false)
            muted = nil
            UserDefaults.standard.removeObject(forKey: Self.key)
            Log.info("Mac speakers back on")
        }
    }

    /// Headphones plugged in, or another output picked: mute that one instead.
    private func watchOutput() {
        guard !listening else { return }
        listening = true
        var a = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            guard let self, self.muted != nil, let now = Self.defaultOutput(), now != self.muted else { return }
            self.mute(false)
            self.mute(true)
        }
    }

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    /// The device's mute switch: the main element, or else each of the first two channels.
    private static func muteAddresses(_ dev: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        for elements in [[kAudioObjectPropertyElementMain], [UInt32(1), UInt32(2)]] {
            let list = elements.map { AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: $0) }
            if list.allSatisfy({ a in var a = a; var settable = DarwinBoolean(false)
                return AudioObjectHasProperty(dev, &a) && AudioObjectIsPropertySettable(dev, &a, &settable) == noErr && settable.boolValue }) {
                return list
            }
        }
        return []
    }

    static func isMuted(_ dev: AudioDeviceID) -> Bool? {
        guard var a = muteAddresses(dev).first else { return nil }
        var v = UInt32(0), size = UInt32(4)
        return AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v != 0 : nil
    }

    @discardableResult
    static func setMute(_ dev: AudioDeviceID, _ on: Bool) -> Bool {
        let list = muteAddresses(dev)
        var ok = !list.isEmpty
        for var a in list {
            var v = UInt32(on ? 1 : 0)
            ok = AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &v) == noErr && ok
        }
        return ok
    }
}
