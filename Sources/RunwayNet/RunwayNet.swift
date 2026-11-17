// Network status shared by Network (NWPathMonitor) and
// SystemConfiguration (SCNetworkReachability): the interfaces and whether
// there's a default route, and change notifications from the kernel
// (rtnetlink on Linux: link, address and route groups, one thread blocked
// in recv; NotifyAddrChange on Windows).

import Foundation
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public struct NetInterface: Hashable, Sendable {
    public enum Kind: Sendable { case wifi, ethernet, cellular, loopback, other }
    public let name: String
    public let index: Int
    public let kind: Kind
    public let isUp: Bool
    public let hasIPv4: Bool
    public let hasIPv6: Bool
    public let hardwareAddress: String?
}

public struct NetStatus: Equatable, Sendable {
    public let interfaces: [NetInterface]
    public let hasIPv4Route: Bool
    public let hasIPv6Route: Bool
    /// Interfaces carrying the default route, best first.
    public let routeInterfaces: [String]
    public var connected: Bool { (hasIPv4Route || hasIPv6Route) && interfaces.contains { $0.isUp && $0.kind != .loopback && ($0.hasIPv4 || $0.hasIPv6) } }
    public var dnsConfigured: Bool {
        #if os(Linux)
        guard let r = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return false }
        return r.split(separator: "\n").contains { $0.hasPrefix("nameserver") }
        #else
        return connected
        #endif
    }

    public static func current() -> NetStatus {
        #if os(Linux)
        var ifs: [String: (up: Bool, v4: Bool, v6: Bool)] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ptr) == 0, let first = ptr {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let a = p {
                let name = String(cString: a.pointee.ifa_name)
                var e = ifs[name] ?? (false, false, false)
                let flags = Int32(bitPattern: a.pointee.ifa_flags)
                e.up = e.up || (flags & Int32(IFF_UP) != 0 && flags & Int32(IFF_RUNNING) != 0)
                if let addr = a.pointee.ifa_addr {
                    if addr.pointee.sa_family == sa_family_t(AF_INET) { e.v4 = true }
                    if addr.pointee.sa_family == sa_family_t(AF_INET6) {
                        // Link-local (fe80::/10) alone doesn't reach the internet.
                        let b = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr.__in6_u.__u6_addr8 }
                        if !(b.0 == 0xfe && b.1 & 0xc0 == 0x80) { e.v6 = true }
                    }
                }
                ifs[name] = e
                p = a.pointee.ifa_next
            }
            freeifaddrs(first)
        }
        func read(_ path: String) -> String? { (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let interfaces = ifs.keys.sorted().map { name -> NetInterface in
            let e = ifs[name]!
            let sys = "/sys/class/net/\(name)"
            let kind: NetInterface.Kind
            if name == "lo" || read(sys + "/type") == "772" { kind = .loopback }
            else if FileManager.default.fileExists(atPath: sys + "/wireless") || FileManager.default.fileExists(atPath: sys + "/phy80211") { kind = .wifi }
            else if name.hasPrefix("wwan") || name.hasPrefix("rmnet") || name.hasPrefix("ppp") { kind = .cellular }
            else if read(sys + "/type") == "1", FileManager.default.fileExists(atPath: sys + "/device") { kind = .ethernet }
            else { kind = .other }
            return NetInterface(name: name, index: Int(if_nametoindex(name)), kind: kind, isUp: e.up, hasIPv4: e.v4, hasIPv6: e.v6,
                                hardwareAddress: read(sys + "/address"))
        }
        var v4 = false, v6 = false
        var routeIfs: [(String, Int)] = []
        if let routes = read("/proc/net/route") {
            for line in routes.split(separator: "\n").dropFirst() {
                let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if f.count > 7, f[1] == "00000000", f[7] == "00000000" { v4 = true; routeIfs.append((String(f[0]), Int(f[6]) ?? 0)) }
            }
        }
        if let routes = read("/proc/net/ipv6_route") {
            for line in routes.split(separator: "\n") {
                let f = line.split(separator: " ")
                if f.count > 9, f[0] == "00000000000000000000000000000000", f[1] == "00", f[9] != "lo" { v6 = true; routeIfs.append((String(f[9]), 1 << 20)) }
            }
        }
        let ordered = routeIfs.sorted { $0.1 < $1.1 }.map(\.0).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return NetStatus(interfaces: interfaces, hasIPv4Route: v4, hasIPv6Route: v6, routeInterfaces: ordered)
        #elseif os(Windows)
        var size: ULONG = 16 * 1024
        var buf = [UInt8](repeating: 0, count: Int(size))
        var result: [NetInterface] = []
        var anyGateway = false
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            let p = raw.baseAddress!.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES_LH.self)
            return GetAdaptersAddresses(ULONG(AF_UNSPEC), ULONG(GAA_FLAG_INCLUDE_GATEWAYS), nil, p, &size) == ERROR_SUCCESS
        }
        if ok {
            buf.withUnsafeMutableBytes { raw in
                var a: UnsafeMutablePointer<IP_ADAPTER_ADDRESSES_LH>? = raw.baseAddress!.assumingMemoryBound(to: IP_ADAPTER_ADDRESSES_LH.self)
                while let ad = a {
                    let up = ad.pointee.OperStatus == IfOperStatusUp
                    let kind: NetInterface.Kind
                    switch ad.pointee.IfType {
                    case DWORD(IF_TYPE_IEEE80211): kind = .wifi
                    case DWORD(IF_TYPE_ETHERNET_CSMACD): kind = .ethernet
                    case DWORD(IF_TYPE_SOFTWARE_LOOPBACK): kind = .loopback
                    case DWORD(IF_TYPE_WWANPP), DWORD(IF_TYPE_WWANPP2): kind = .cellular
                    default: kind = .other
                    }
                    if up, ad.pointee.FirstGatewayAddress != nil { anyGateway = true }
                    let name = String(cString: ad.pointee.AdapterName)
                    result.append(NetInterface(name: name, index: Int(ad.pointee.IfIndex), kind: kind, isUp: up,
                                               hasIPv4: ad.pointee.FirstUnicastAddress != nil, hasIPv6: false, hardwareAddress: nil))
                    a = ad.pointee.Next
                }
            }
        }
        return NetStatus(interfaces: result, hasIPv4Route: anyGateway, hasIPv6Route: false,
                         routeInterfaces: result.filter { $0.isUp && $0.kind != .loopback }.map(\.name))
        #else
        return NetStatus(interfaces: [], hasIPv4Route: false, hasIPv6Route: false, routeInterfaces: [])
        #endif
    }
}

#if os(Linux)
/// struct sockaddr_nl (linux/netlink.h), which Glibc's module doesn't export.
struct SockaddrNL {
    var nl_family: sa_family_t = 0
    var nl_pad: UInt16 = 0
    var nl_pid: UInt32 = 0
    var nl_groups: UInt32 = 0
}
#endif

/// Calls observers (on its own thread) when the network configuration
/// changes. Started on first observer.
public final class NetMonitor: @unchecked Sendable {
    public static let shared = NetMonitor()
    private let lock = NSLock()
    private var observers: [UUID: () -> Void] = [:]
    private var started = false

    public func observe(_ f: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = f
        let start = !started
        started = true
        lock.unlock()
        if start { startThread() }
        return id
    }

    public func remove(_ id: UUID) { lock.lock(); observers[id] = nil; lock.unlock() }

    private func notify() {
        lock.lock(); let obs = Array(observers.values); lock.unlock()
        obs.forEach { $0() }
    }

    private func startThread() {
        let t = Thread { [self] in
            #if os(Linux)
            let fd = socket(AF_NETLINK, Int32(SOCK_RAW.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0 /* NETLINK_ROUTE */)
            guard fd >= 0 else { return }
            var addr = SockaddrNL()
            addr.nl_family = sa_family_t(AF_NETLINK)
            // RTMGRP_LINK | IPV4_IFADDR | IPV4_ROUTE | IPV6_IFADDR | IPV6_ROUTE
            addr.nl_groups = 0x1 | 0x10 | 0x40 | 0x100 | 0x400
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<SockaddrNL>.size)) } }
            guard bound == 0 else { close(fd); return }
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n < 0 { if errno == EINTR { continue }; break }
                // Bursts of messages: let them settle, then report once.
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                while poll(&pfd, 1, 50) > 0 { _ = recv(fd, &buf, buf.count, Int32(MSG_DONTWAIT)) }
                notify()
            }
            close(fd)
            #elseif os(Windows)
            while NotifyAddrChange(nil, nil) == NO_ERROR { notify() }
            #endif
        }
        t.name = "runway.netmonitor"
        t.start()
    }
}
