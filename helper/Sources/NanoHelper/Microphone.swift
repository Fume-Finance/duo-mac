import AudioToolbox
import CoreAudio
import Foundation

/// The iPhone's microphone, as a Mac microphone. The phone streams 16-bit, 24 kHz mono audio; this
/// plays it into the hidden "Duo Mac Microphone Feed", which comes back out of "Duo Mac Microphone"
/// (driver/DuoMacMicrophone.c, a loopback) for every app to record from. While it's on, that
/// microphone is the Mac's default input; the previous one comes back when it stops.
///
/// The phone only records while some app is listening to the microphone (`onListening` says when),
/// so its microphone isn't on the whole time.
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
    private var feedID: AudioDeviceID?
    private var ioProc: AudioDeviceIOProcID?
    private(set) var active = false
    // What's flowing, logged every 5 s while on (lock): chunks and loudest sample from the phone,
    // samples handed to the feed, and silence played because the buffer was empty.
    private var received = 0, peak: Float = 0, played = 0, starved = 0
    private var report: Timer?
    private var listener: AudioObjectPropertyListenerBlock?
    private var micID: AudioDeviceID?
    /// An app started or stopped listening to the Duo Mac Microphone (main thread).
    var onListening: ((Bool) -> Void)?
    private(set) var listening = false
    private static var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

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
        // Play into the feed, not the speakers. (Never into the microphone itself: opening a device
        // with an input would count as recording, and macOS would stop here to ask for permission.)
        // Straight to the device, whose format is the driver's: 48 kHz mono float.
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, feed, nil) { [weak self] _, _, _, out, _ in
            for b in UnsafeMutableAudioBufferListPointer(out) {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                if let self { self.pull(p, n) } else { p.update(repeating: 0, count: n) }
            }
        }
        if status == noErr, let proc { status = AudioDeviceStart(feed, proc) }
        guard status == noErr, let proc else {
            Log.warn("Microphone: can't play into the feed (\(status))")
            if let proc { AudioDeviceDestroyIOProcID(feed, proc) }
            return false
        }
        feedID = feed
        ioProc = proc
        active = true
        lock.lock(); received = 0; peak = 0; played = 0; starved = 0; lock.unlock()
        report = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.logFlow() }
        if let cur = Microphone.defaultInput(), cur != dev {
            if let uid = Microphone.uid(of: cur) { UserDefaults.standard.set(uid, forKey: Microphone.previousKey) }
            Microphone.setDefaultInput(dev)
        }
        // Who's listening: the phone records only then.
        micID = dev
        listening = Microphone.isRunningSomewhere(dev)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.active, let id = self.micID else { return }
            let now = Microphone.isRunningSomewhere(id)
            guard now != self.listening else { return }
            self.listening = now
            Log.info("Microphone: \(now ? "an app started listening" : "no app is listening any more")")
            self.onListening?(now)
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(dev, &Microphone.runningAddress, .main, block)
        Log.info("Microphone: the iPhone is the Mac's microphone\(listening ? " (an app is listening)" : "")")
        return true
    }

    func stop() {
        guard active else { return }
        report?.invalidate()
        report = nil
        if let micID, let listener { AudioObjectRemovePropertyListenerBlock(micID, &Microphone.runningAddress, .main, listener) }
        listener = nil
        micID = nil
        listening = false
        logFlow()
        if let feedID, let ioProc {
            AudioDeviceStop(feedID, ioProc)
            AudioDeviceDestroyIOProcID(feedID, ioProc)
        }
        feedID = nil
        ioProc = nil
        active = false
        giveBackDefaultInput()
        lock.lock()
        readPos = 0; writePos = 0; count = 0; primed = false
        lock.unlock()
        Log.info("Microphone: back to the Mac's own")
    }

    // MARK: The Mac's own microphone

    /// The input the Mac had before Duo Mac took over (by UID, so it survives restarts).
    private static let previousKey = "MicrophonePreviousInputUID"

    /// Only while the iPhone is in use may the Duo Mac Microphone be the Mac's input: with no phone
    /// it's silent, and the Mac would seem to have lost its microphone. macOS can pick it again on
    /// its own (when another input, like AirPods, goes away), so this watches for that too and puts
    /// back the previous input, or the built-in microphone. main thread
    func guardDefaultInput() {
        giveBackDefaultInput()
        var a = Microphone.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { [weak self] _, _ in
            self?.giveBackDefaultInput()
        }
    }

    private func giveBackDefaultInput() {
        guard !active, let mic = Microphone.deviceID(), Microphone.defaultInput() == mic else { return }
        let saved = UserDefaults.standard.string(forKey: Microphone.previousKey).flatMap { Microphone.deviceID($0) }
        guard let back = (saved != mic ? saved : nil) ?? Microphone.builtInInput() else { return }
        Microphone.setDefaultInput(back)
        Log.info("Microphone: the Mac's input is \(Microphone.name(of: back) ?? "its own microphone") again")
    }

    static func uid(of id: AudioDeviceID) -> String? { stringProperty(id, kAudioDevicePropertyDeviceUID) }
    static func name(of id: AudioDeviceID) -> String? { stringProperty(id, kAudioObjectPropertyName) }

    private static func stringProperty(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr, let v else { return nil }
        return v.takeRetainedValue() as String
    }

    /// The Mac's built-in microphone (any built-in device with an input).
    static func builtInInput() -> AudioDeviceID? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            var t = UInt32(0), ts = UInt32(4)
            var ta = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var ss = UInt32(0)
            return AudioObjectGetPropertyData(id, &ta, 0, nil, &ts, &t) == noErr && t == kAudioDeviceTransportTypeBuiltIn
                && AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == noErr && ss > 0
        }
    }

    /// main thread
    private func logFlow() {
        lock.lock()
        let r = received, p = peak, pl = played, st = starved
        received = 0; peak = 0; played = 0; starved = 0
        lock.unlock()
        let db = p > 0 ? Int((20 * log10(p)).rounded()) : -99
        let mic = Microphone.deviceID()
        let listened = mic.map { Microphone.isRunningSomewhere($0) } ?? false
        let def = Microphone.defaultInput() == mic
        Log.info("Microphone: \(r) chunks from the iPhone (loudest \(db) dB), \(pl / 48) ms played into the feed, \(st / 48) ms of gaps; "
                 + "the Duo Mac Microphone is \(def ? "" : "NOT ")the default input, \(listened ? "and an app is listening" : "no app is listening")")
    }

    static func isRunningSomewhere(_ id: AudioDeviceID) -> Bool {
        var v = UInt32(0), size = UInt32(4)
        return AudioObjectGetPropertyData(id, &runningAddress, 0, nil, &size, &v) == noErr && v != 0
    }

    // MARK: Audio

    /// 16-bit little-endian samples at 24 kHz from the phone (any thread).
    func feed(_ data: Data) {
        guard active else { return }
        lock.lock(); defer { lock.unlock() }
        received += 1
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<(raw.count / 2) {
                let f = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
                peak = max(peak, abs(f))
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
            starved += n
            out.update(repeating: 0, count: n)
            return
        }
        let take = min(n, count)
        played += take
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
