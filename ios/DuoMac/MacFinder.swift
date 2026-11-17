import Foundation
import Network

/// Finds the Mac on this iPhone's own hotspot. There the Mac's address changes from one connection to
/// the next and its .local name doesn't resolve, so the page may only know an old address. A hotspot
/// network is tiny (172.20.10.0/28: 14 addresses), so knock on Duo Mac's local port at each one.
enum MacFinder {
    static func find(port: UInt16, timeout: TimeInterval = 1.5, completion: @escaping ([String]) -> Void) {
        let candidates = hotspotPeers()
        guard !candidates.isEmpty, let p = NWEndpoint.Port(rawValue: port) else { return completion([]) }
        let queue = DispatchQueue(label: "duomac.finder")
        var found: [String] = []
        var pending = candidates.count
        var finished = false
        var conns: [NWConnection] = []
        let finish = {
            guard !finished else { return }
            finished = true
            for c in conns { c.cancel() }
            completion(found)
        }
        for host in candidates {
            let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
            conns.append(c)
            var settled = false
            c.stateUpdateHandler = { state in
                guard !settled else { return }
                switch state {
                case .ready:
                    settled = true
                    found.append(host)
                case .failed, .cancelled, .waiting:
                    settled = true
                default:
                    return
                }
                c.cancel()
                pending -= 1
                if pending == 0 { finish() }
            }
            c.start(queue: queue)
        }
        queue.asyncAfter(deadline: .now() + timeout) { finish() }
    }

    /// The other addresses on a small network this iPhone is the gateway of (its hotspot).
    static func hotspotPeers() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let maskPtr = ifa.ifa_netmask,
                  String(cString: ifa.ifa_name).hasPrefix("bridge") else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let size = ~mask
            guard size > 1, size <= 63 else { continue } // only small networks (a hotspot is /28)
            let net = ip & mask
            for host in (net + 1)..<(net + size) where host != ip {
                out.append("\(host >> 24).\((host >> 16) & 255).\((host >> 8) & 255).\(host & 255)")
            }
        }
        return out
    }
}
