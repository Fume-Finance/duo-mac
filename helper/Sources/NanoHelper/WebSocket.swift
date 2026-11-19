import Foundation
import Network

/// Server side of RFC 6455 on top of an NWConnection (after the HTTP upgrade).
/// All callbacks run on `queue`.
final class WebSocketConnection {
    let conn: NWConnection
    let queue: DispatchQueue
    let remote: String
    private var buf: [UInt8]
    private var pos = 0                       // where the next frame starts in `buf`
    private var fragments: [UInt8] = []
    private var fragmentOpcode: UInt8 = 0
    private var fragmenting = false
    private(set) var isClosed = false

    /// The largest message (a frame, or the fragments of one put together). Small for a connection
    /// that hasn't unlocked, so a stranger can't make the Mac hold megabytes; `AuthManager.grant`
    /// raises it to `maxAuthedMessage`. Queue only.
    var maxMessage = 64 * 1024 {
        didSet {
            sendLock.lock()
            unlocked = maxMessage >= WebSocketConnection.maxAuthedMessage
            sendLock.unlock()
        }
    }
    static let maxAuthedMessage = 2 * 1024 * 1024

    /// Pongs handed to the network and not sent yet: a peer that pings faster than it reads gets no
    /// more until those are out. Queue only.
    private var pongsWaiting = 0
    private static let maxPongsWaiting = 4

    /// Bytes handed to the network and not sent yet. A connection that hasn't unlocked only ever gets
    /// small messages: when they pile up, it isn't reading (pongs to a flood of pings), so it's closed.
    private let sendLock = NSLock()
    private var waiting = 0                   // sendLock
    private var unlocked = false              // sendLock
    private static let maxWaitingBeforeUnlock = 256 * 1024
    private static let floods = LogBudget(perMinute: 5)

    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    init(conn: NWConnection, queue: DispatchQueue, initial: Data) {
        self.conn = conn
        self.queue = queue
        self.buf = [UInt8](initial)
        switch conn.endpoint {
        case .hostPort(let host, _): remote = "\(host)"
        default: remote = "\(conn.endpoint)"
        }
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.closeLocally()
            default: break
            }
        }
        queue.async {
            self.parse()
            self.receive()
        }
    }

    // MARK: Sending (safe from any thread)

    func send(text: String) { sendFrame(opcode: 0x1, payload: Data(text.utf8)) }

    func send(json: [String: Any]) {
        // Some numbers can't be written as JSON (infinity: "1e999" from the phone reads as one), and
        // JSONSerialization then raises an Objective-C exception, which `try?` doesn't catch: it would
        // take the whole app down. Check first.
        guard JSONSerialization.isValidJSONObject(json), let d = try? JSONSerialization.data(withJSONObject: json) else { return }
        sendFrame(opcode: 0x1, payload: d)
    }

    func send(binary: Data) { sendFrame(opcode: 0x2, payload: binary) }

    /// Graceful close: the close frame goes out before the socket is torn down.
    /// 1000 = normal, 1001 = going away (Mac app quitting), 4001 = replaced by another device.
    func close(code: UInt16 = 1000) {
        queue.async {
            guard !self.isClosed else { return }
            self.markClosed()
            self.sendFrame(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xFF)])) { [conn = self.conn] in
                conn.cancel()
            }
            // In case the send never completes (dead peer).
            self.queue.asyncAfter(deadline: .now() + 1.5) { [conn = self.conn] in conn.cancel() }
        }
    }

    private func sendFrame(opcode: UInt8, payload: Data, then done: (() -> Void)? = nil) {
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(n >> 8))
            frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF)) }
        }
        frame.append(payload)
        let size = frame.count
        sendLock.lock()
        let flooded = !unlocked && waiting + size > WebSocketConnection.maxWaitingBeforeUnlock
        if !flooded { waiting += size }
        sendLock.unlock()
        if flooded {
            queue.async {
                guard !self.isClosed else { return }
                WebSocketConnection.floods.log { Log.warn("Closed a connection from \(self.remote) that doesn't read what it's sent") }
                self.closeLocally()
            }
            return
        }
        conn.send(content: frame, completion: .contentProcessed { [weak self] _ in
            if let self {
                self.sendLock.lock()
                self.waiting -= size
                self.sendLock.unlock()
            }
            done?()
        })
    }

    // MARK: Receiving

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
            if let data, !data.isEmpty {
                self.buf.append(contentsOf: data)
                self.parse()
            }
            if complete || error != nil {
                self.closeLocally()
                return
            }
            if !self.isClosed { self.receive() }
        }
    }

    /// Takes every complete frame from `buf`, reading on from `pos`, then drops what was read in one go
    /// (removing each frame from the front as it's read made a flood of tiny frames quadratic).
    private func parse() {
        defer {
            if pos > 0 {
                buf.removeFirst(pos)
                pos = 0
            }
        }
        while !isClosed {
            let avail = buf.count - pos
            guard avail >= 2 else { return }
            let b0 = buf[pos], b1 = buf[pos + 1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0F
            let masked = b1 & 0x80 != 0
            var len = Int(b1 & 0x7F)
            // Close, ping and pong are short and come in one piece (RFC 6455, 5.5).
            if opcode & 0x08 != 0 && (!fin || len > 125) { return closeLocally() }
            var idx = pos + 2
            if len == 126 {
                guard avail >= 4 else { return }
                len = Int(buf[pos + 2]) << 8 | Int(buf[pos + 3])
                idx = pos + 4
            } else if len == 127 {
                guard avail >= 10 else { return }
                var l: UInt64 = 0
                for i in 2..<10 { l = l << 8 | UInt64(buf[pos + i]) }
                guard l <= UInt64(maxMessage) else { return closeLocally() }
                len = Int(l)
                idx = pos + 10
            }
            guard len <= maxMessage else { return closeLocally() }
            var mask: [UInt8] = [0, 0, 0, 0]
            if masked {
                guard buf.count >= idx + 4 else { return }
                mask = Array(buf[idx..<idx + 4])
                idx += 4
            }
            guard buf.count >= idx + len else { return }
            var payload = Array(buf[idx..<idx + len])
            if masked {
                for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
            }
            pos = idx + len

            switch opcode {
            case 0x0:
                // A continuation needs a message to continue.
                guard fragmenting else { return closeLocally() }
                fragments.append(contentsOf: payload)
                if fragments.count > maxMessage { return closeLocally() }
                if fin {
                    let message = fragments
                    fragments = []
                    fragmenting = false
                    deliver(fragmentOpcode, message)
                }
            case 0x1, 0x2:
                // A new message can't start in the middle of another.
                guard !fragmenting else { return closeLocally() }
                if fin {
                    deliver(opcode, payload)
                } else {
                    fragmentOpcode = opcode
                    fragments = payload
                    fragmenting = true
                }
            case 0x8:
                markClosed()
                sendFrame(opcode: 0x8, payload: Data(payload.prefix(2))) { [conn] in conn.cancel() }
                return
            case 0x9:
                // Answered while the earlier pongs are on their way; a flood of pings gets no more
                // (only the latest ping needs an answer anyway).
                guard pongsWaiting < WebSocketConnection.maxPongsWaiting else { break }
                pongsWaiting += 1
                sendFrame(opcode: 0xA, payload: Data(payload)) { [weak self] in self?.pongsWaiting -= 1 }
            case 0xA:
                break
            default:
                closeLocally()
            }
        }
    }

    private func deliver(_ opcode: UInt8, _ payload: [UInt8]) {
        if opcode == 0x1 {
            onText?(String(decoding: payload, as: UTF8.self))
        } else {
            onBinary?(Data(payload))
        }
    }

    /// Stops delivering messages and tells the owner; the socket itself is cancelled separately.
    private func markClosed() {
        guard !isClosed else { return }
        isClosed = true
        let cb = onClose
        onClose = nil
        onText = nil
        onBinary = nil
        cb?()
    }

    private func closeLocally() {
        markClosed()
        conn.cancel()
    }
}
