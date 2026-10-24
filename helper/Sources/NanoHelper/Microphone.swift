import AVFoundation
import CoreAudio
import Foundation

/// The iPhone's microphone, as a Mac microphone. The phone streams 16-bit, 24 kHz mono audio; this
/// plays it into the hidden "Duo Mac Microphone Feed", which comes back out of "Duo Mac Microphone"
/// (driver/DuoMacMicrophone.c, a loopback) for every app to record from. While it's on, that
/// microphone is the Mac's default input; the previous one comes back when it stops.
final class Microphone {
    static let deviceUID = "DuoMacMicrophone_UID"
    static let feedUID = "DuoMacMicrophoneFeed_UID"
    static let driverName = "DuoMacMicrophone.driver"
    static let installedPath = "/Library/Audio/Plug-Ins/HAL/" + driverName

    private let lock = NSLock()
    private var ring = [Float](repeating: 0, count: 48_000) // 1 s at 48 kHz
    private var readPos = 0, writePos = 0, count = 0
    private var primed = false
    private var last: Float = 0
    private var engine: AVAudioEngine?
    private var previousInput: AudioDeviceID?
    private(set) var active = false
    private var received = 0 // chunks from the phone since start (logged now and then)

    // MARK: The device

    static func deviceID(_ uid: String = deviceUID) -> AudioDeviceID? {
        var uid = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = withUnsafeMutablePointer(to: &uid) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Both devices are there. The first driver had a single device (no feed): it needs updating.
    static var isInstalled: Bool { deviceID() != nil && deviceID(feedUID) != nil }
    static var needsUpdate: Bool { deviceID() != nil && deviceID(feedUID) == nil }

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    static func defaultInput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, 0, nil, &size, &id) == noErr ? id : nil
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var v = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultInputAddress, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &v) == noErr
    }

    /// Copies the driver into /Library/Audio/Plug-Ins/HAL and restarts Core Audio (sound stops for a
    /// second). macOS asks for an administrator password. `done` runs on the main thread.
    static func install(from source: URL, done: @escaping (Bool, String?) -> Void) {
        let src = source.path, dest = installedPath
        let shell = "/bin/mkdir -p /Library/Audio/Plug-Ins/HAL && /bin/rm -rf '\(dest)' && /bin/cp -R '\(src)' '\(dest)'"
            + " && /usr/sbin/chown -R root:wheel '\(dest)' && /usr/bin/killall coreaudiod"
        let script = "do shell script \"\(shell)\" with prompt \"Duo Mac wants to add the Duo Mac Microphone.\" with administrator privileges"
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            var ok = false, message: String?
            do {
                try p.run()
                p.waitUntilExit()
                ok = p.terminationStatus == 0
                message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { message = error.localizedDescription }
            // Core Audio takes a moment to come back with the new device.
            DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 2 : 0)) { done(ok, ok ? nil : message) }
        }
    }

    // MARK: Streaming (main thread)

    func start() -> Bool {
        if active { return true }
        guard let dev = Microphone.deviceID(), let feed = Microphone.deviceID(Microphone.feedUID) else {
            Log.warn("Microphone: the Duo Mac Microphone is \(Microphone.needsUpdate ? "out of date" : "not installed")")
            return false
        }
        let engine = AVAudioEngine()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else { return false }
        let source = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if let self { self.pull(out, Int(frames)) } else { out.update(repeating: 0, count: Int(frames)) }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: fmt)
        // Play into the feed, not the speakers. (Never into the microphone itself: opening a device
        // with an input would count as recording, and macOS would stop here to ask for permission.)
        guard let au = engine.outputNode.audioUnit else { return false }
        var id = feed
        let set = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard set == noErr else { Log.warn("Microphone: can't select the device (\(set))"); return false }
        do { try engine.start() } catch {
            Log.warn("Microphone: \(error.localizedDescription)")
            return false
        }
        self.engine = engine
        active = true
        received = 0
        if let cur = Microphone.defaultInput(), cur != dev {
            previousInput = cur
            Microphone.setDefaultInput(dev)
        }
        Log.info("Microphone: the iPhone is the Mac's microphone")
        return true
    }

    func stop() {
        guard active else { return }
        engine?.stop()
        engine = nil
        active = false
        if let dev = Microphone.deviceID(), Microphone.defaultInput() == dev, let prev = previousInput {
            Microphone.setDefaultInput(prev)
        }
        previousInput = nil
        lock.lock()
        readPos = 0; writePos = 0; count = 0; primed = false
        lock.unlock()
        Log.info("Microphone: back to the Mac's own")
    }

    // MARK: Audio

    /// 16-bit little-endian samples at 24 kHz from the phone (any thread).
    func feed(_ data: Data) {
        guard active else { return }
        received += 1
        if received == 1 || received % 3000 == 0 { Log.info("Microphone: \(received) chunks from the iPhone") } // every minute
        lock.lock(); defer { lock.unlock() }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<(raw.count / 2) {
                let f = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                write((last + f) / 2) // 24 → 48 kHz: the midpoint, then the sample
                write(f)
                last = f
            }
        }
        // Never fall more than ~0.25 s behind: drop the oldest audio.
        let maxBacklog = 12_000
        if count > maxBacklog {
            let drop = count - 4_800
            readPos = (readPos + drop) % ring.count
            count -= drop
        }
    }

    private func write(_ f: Float) {
        ring[writePos] = f
        writePos = (writePos + 1) % ring.count
        if count < ring.count { count += 1 } else { readPos = (readPos + 1) % ring.count }
    }

    /// The device asks for audio (real-time thread): wait for ~40 ms of buffer before playing, so
    /// network jitter doesn't chop the words.
    private func pull(_ out: UnsafeMutablePointer<Float>, _ n: Int) {
        lock.lock(); defer { lock.unlock() }
        if !primed && count >= 1_920 { primed = true }
        guard primed, count > 0 else {
            primed = false
            out.update(repeating: 0, count: n)
            return
        }
        let take = min(n, count)
        for i in 0..<take {
            out[i] = ring[readPos]
            readPos = (readPos + 1) % ring.count
        }
        count -= take
        if take < n {
            (out + take).update(repeating: 0, count: n - take)
            primed = false
        }
    }
}
