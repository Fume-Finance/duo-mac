import Foundation
import SystemConfiguration

struct MacInfo {
    let computerName: String
    let localHostName: String
    let model: String
    let chip: String
    let memoryGB: Int
    let osVersion: String

    static func current() -> MacInfo {
        let computer = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
        let local = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "localhost"
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        let mem = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return MacInfo(computerName: computer, localHostName: local,
                       model: sysctlString("hw.model") ?? "Mac",
                       chip: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
                       memoryGB: mem, osVersion: os)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// The Mac's LAN IPv4 address (Wi-Fi/Ethernet preferred).
    static func primaryIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var found: [(name: String, ip: String)] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let ifa = cur.pointee
            let flags = Int32(ifa.ifa_flags)
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found.append((String(cString: ifa.ifa_name), String(cString: host)))
                }
            }
            p = ifa.ifa_next
        }
        let usable = found.filter { !$0.ip.hasPrefix("169.254.") }
        return usable.first(where: { $0.name.hasPrefix("en") })?.ip ?? usable.first?.ip
    }
}
