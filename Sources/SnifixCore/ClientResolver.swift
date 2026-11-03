import Foundation
import Darwin
import NIOCore
import SystemConfiguration

public enum ClientResolver {
    static func resolve(channel: Channel) -> ClientInfo {
        let address = channel.remoteAddress?.ipAddress ?? "?"
        let port = channel.remoteAddress?.port ?? 0
        let isLocal = address == "127.0.0.1" || address == "::1" || NetworkInfo.localAddresses().contains(address)
        var info = ClientInfo(address: address, port: port, isLocal: isLocal)
        if isLocal, let pid = pid(forLocalPort: port, remotePort: channel.localAddress?.port ?? 0) {
            let path = executablePath(pid)
            if path.map({ ($0 as NSString).lastPathComponent == "adb" }) ?? false {
                info.isLocal = false
                info.address = "USB"
                info.deviceName = "Android"
                return info
            }
            // The .app bundle when there is one, else the executable (its icon is still shown)
            info.bundlePath = path.flatMap(outermostBundle) ?? path
            info.appName = path.flatMap(outermostBundle).map { ($0 as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
                ?? path.map { ($0 as NSString).lastPathComponent }
            info.deviceName = "Mac"
        }
        return info
    }

    /// Finds the process owning the client side of a local TCP connection to the proxy.
    static func pid(forLocalPort port: Int, remotePort: Int) -> pid_t? {
        guard port > 0 else { return nil }
        let count = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 16)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let n = Int(bytes) / MemoryLayout<pid_t>.size
        let me = getpid()
        for pid in pids.prefix(n) where pid > 0 && pid != me {
            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdBytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdBytes) / MemoryLayout<proc_fdinfo>.size)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, fdBytes)
            let fdCount = Int(got) / MemoryLayout<proc_fdinfo>.size
            for fd in fds.prefix(fdCount) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var si = socket_fdinfo()
                let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, Int32(MemoryLayout<socket_fdinfo>.size))
                guard r == MemoryLayout<socket_fdinfo>.size, si.psi.soi_kind == SOCKINFO_TCP else { continue }
                let ini = si.psi.soi_proto.pri_tcp.tcpsi_ini
                let lport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
                let fport = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport)))
                if lport == port && (remotePort == 0 || fport == remotePort) { return pid }
            }
        }
        return nil
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    static func outermostBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// "Octo%20Mobile/1.2 CFNetwork/..." → "Octo Mobile"; "okhttp/4.9" → "okhttp".
    public static func appName(fromUserAgent ua: String?) -> String? {
        guard let ua, !ua.isEmpty else { return nil }
        let first = String(ua.split(separator: " ").first ?? "")
        let product = String(first.split(separator: "/").first ?? "")
        if product == "Mozilla" {
            if ua.contains("Edg/") { return "Edge" }
            if ua.contains("Chrome/") { return "Chrome" }
            if ua.contains("Firefox/") { return "Firefox" }
            if ua.contains("Safari/") { return "Safari" }
            return "Браузер"
        }
        let name = product.removingPercentEncoding ?? product
        return name.isEmpty ? nil : name
    }

    public static func deviceName(fromUserAgent ua: String?, isLocal: Bool) -> String? {
        if isLocal { return "Mac" }
        guard let ua = ua?.lowercased() else { return nil }
        if ua.contains("iphone") || ua.contains("ios") || ua.contains("cfnetwork") || ua.contains("darwin") { return "iPhone" }
        if ua.contains("ipad") { return "iPad" }
        if ua.contains("android") || ua.contains("okhttp") || ua.contains("dalvik") { return "Android" }
        return nil
    }
}

public enum NetworkInfo {
    /// IPv4 addresses of this Mac's interfaces (excluding loopback).
    public static func localAddresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: host)
                if s != "127.0.0.1" { result.append(s) }
            }
        }
        return result
    }

    /// The address phones on the same network should use (en0/en1 first).
    public static func primaryAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(String, String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((String(cString: ifa.ifa_name), String(cString: host)))
            }
        }
        let preferred = candidates.first { $0.0 == "en0" } ?? candidates.first { $0.0.hasPrefix("en") } ?? candidates.first
        return preferred?.1
    }

    /// Bonjour name such as "MacBook-Pro.local", which phones resolve even when the IP changes.
    public static func bonjourName() -> String {
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? { return local + ".local" }
        let name = ProcessInfo.processInfo.hostName
        if name.hasSuffix(".local") { return name }
        let short = name.split(separator: ".").first.map(String.init) ?? name
        return short + ".local"
    }
}
