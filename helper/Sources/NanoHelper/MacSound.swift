import CoreAudio
import CoreMedia
import Foundation

/// The Mac's sound, for the phone's speaker. ScreenCaptureKit hands over 48 kHz float audio; the
/// phone gets 24 kHz 16-bit stereo (96 KB/s), as binary messages:
///   [2] [channels] [rate / 100, UInt16 LE] then interleaved Int16 samples.
/// (Screen frames start with 1.) Silence isn't sent at all.
enum MacSound {
    static let rate = 24_000
    /// Diagnostics (capture queue): buffers captured, and those with sound in them; plus the
    /// format of the last one.
    nonisolated(unsafe) static var captured = 0, loud = 0
    nonisolated(unsafe) static var format = ""

    static func encode(_ sb: CMSampleBuffer) -> Data? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { format = "no format"; return nil }
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mSampleRate > 0 else {
            format = "unsupported: id \(asbd.mFormatID) flags \(asbd.mFormatFlags) bits \(asbd.mBitsPerChannel) rate \(asbd.mSampleRate)"
            return nil
        }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { format = "empty"; return nil }
        // Ask how big the buffer list must be, then fetch it.
        var size = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard status == noErr, size > 0 else { format = "buffer list size: \(status)"; return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { format = "buffer list: \(status)"; return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let channels = Int(asbd.mChannelsPerFrame)
        format = "\(Int(asbd.mSampleRate)) Hz × \(channels)\(interleaved ? " interleaved" : ""), \(buffers.count) buffers"
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
