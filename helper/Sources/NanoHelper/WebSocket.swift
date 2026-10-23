import Foundation
import Network

/// Server side of RFC 6455 on top of an NWConnection (after the HTTP upgrade).
/// All callbacks run on `queue`.
final class WebSocketConnection {
    let conn: NWConnection
    let queue: DispatchQueue
    let remote: String
    private var buf: [UInt8]
    private var fragments: [UInt8] = []
    private var fragmentOpcode: UInt8 = 0
    private(set) var isClosed = false
    private static let maxMessage = 2 * 1024 * 1024

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
        guard let d = try? JSONSerialization.data(withJSONObject: json) else { return }
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
        conn.send(content: frame, completion: .contentProcessed { _ in done?() })
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

    private func parse() {
        while !isClosed {
            guard buf.count >= 2 else { return }
            let b0 = buf[0], b1 = buf[1]
            let fin = b0 & 0x80 != 0
            let opcode = b0 & 0x0F
            let masked = b1 & 0x80 != 0
            var len = Int(b1 & 0x7F)
            var idx = 2
            if len == 126 {
                guard buf.count >= 4 else { return }
                len = Int(buf[2]) << 8 | Int(buf[3])
                idx = 4
            } else if len == 127 {
                guard buf.count >= 10 else { return }
                var l: UInt64 = 0
                for i in 2..<10 { l = l << 8 | UInt64(buf[i]) }
                guard l <= UInt64(WebSocketConnection.maxMessage) else { return closeLocally() }
                len = Int(l)
                idx = 10
            }
            guard len <= WebSocketConnection.maxMessage else { return closeLocally() }
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
            buf.removeFirst(idx + len)

            switch opcode {
            case 0x0:
                fragments.append(contentsOf: payload)
                if fragments.count > WebSocketConnection.maxMessage { return closeLocally() }
                if fin {
                    deliver(fragmentOpcode, fragments)
                    fragments = []
                }
            case 0x1, 0x2:
                if fin {
                    deliver(opcode, payload)
                } else {
                    fragmentOpcode = opcode
                    fragments = payload
                }
            case 0x8:
                markClosed()
                sendFrame(opcode: 0x8, payload: Data(payload.prefix(2))) { [conn] in conn.cancel() }
                return
            case 0x9:
                sendFrame(opcode: 0xA, payload: Data(payload))
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
