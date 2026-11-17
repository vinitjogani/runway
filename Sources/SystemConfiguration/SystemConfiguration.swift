// SystemConfiguration for Linux and Windows: reachability, network
// interfaces and services, and the parts of the dynamic store apps read
// (primary interface, link state, computer name, console user), from the
// kernel's view of the network (RunwayNet). Reachability callbacks fire on
// the kernel's change notifications, on the queue or run loop the app set.

@_exported import RunwayCF
import Foundation
import RunwayNet
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif


nonisolated(unsafe) private var lastError: Int32 = 0
public func SCError() -> Int32 { lastError }
public func SCErrorString(_ status: Int32) -> UnsafePointer<CChar> { UnsafePointer(strdup("Error \(status)")!) }
public var kSCStatusOK: Int { 0 }
public var kSCStatusFailed: Int { 1001 }
public var kSCStatusNoKey: Int { 1004 }

// MARK: Reachability

public struct SCNetworkReachabilityFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let transientConnection = SCNetworkReachabilityFlags(rawValue: 1 << 0)
    public static let reachable = SCNetworkReachabilityFlags(rawValue: 1 << 1)
    public static let connectionRequired = SCNetworkReachabilityFlags(rawValue: 1 << 2)
    public static let connectionOnTraffic = SCNetworkReachabilityFlags(rawValue: 1 << 3)
    public static let interventionRequired = SCNetworkReachabilityFlags(rawValue: 1 << 4)
    public static let connectionOnDemand = SCNetworkReachabilityFlags(rawValue: 1 << 5)
    public static let isLocalAddress = SCNetworkReachabilityFlags(rawValue: 1 << 16)
    public static let isDirect = SCNetworkReachabilityFlags(rawValue: 1 << 17)
    public static let isWWAN = SCNetworkReachabilityFlags(rawValue: 1 << 18)
    public static let connectionAutomatic = connectionOnTraffic
}
public var kSCNetworkFlagsTransientConnection: Int { 1 << 0 }
public var kSCNetworkFlagsReachable: Int { 1 << 1 }
public var kSCNetworkFlagsConnectionRequired: Int { 1 << 2 }
public var kSCNetworkFlagsConnectionAutomatic: Int { 1 << 3 }
public var kSCNetworkFlagsInterventionRequired: Int { 1 << 4 }
public var kSCNetworkFlagsIsLocalAddress: Int { 1 << 16 }
public var kSCNetworkFlagsIsDirect: Int { 1 << 17 }

public struct SCNetworkReachabilityContext {
    public var version: CFIndex
    public var info: UnsafeMutableRawPointer?
    public var retain: CFAllocatorRetainCallBack?
    public var release: CFAllocatorReleaseCallBack?
    public var copyDescription: CFAllocatorCopyDescriptionCallBack?
    public init() { version = 0 }
    public init(version: CFIndex, info: UnsafeMutableRawPointer?, retain: CFAllocatorRetainCallBack?, release: CFAllocatorReleaseCallBack?,
                copyDescription: CFAllocatorCopyDescriptionCallBack?) {
        self.version = version; self.info = info; self.retain = retain; self.release = release; self.copyDescription = copyDescription
    }
}

/// (A Swift closure type: SCNetworkReachability is a Swift class here.)
public typealias SCNetworkReachabilityCallBack = (SCNetworkReachability, SCNetworkReachabilityFlags, UnsafeMutableRawPointer?) -> Void

public final class SCNetworkReachability: @unchecked Sendable {
    enum Target { case any, local, host(String) }
    let target: Target
    let lock = NSLock()
    var callback: SCNetworkReachabilityCallBack?
    var info: UnsafeMutableRawPointer?
    var queue: DispatchQueue?
    var runLoop: CFRunLoop?
    var token: UUID?
    var lastFlags: SCNetworkReachabilityFlags?
    init(_ t: Target) { target = t }

    var flags: SCNetworkReachabilityFlags {
        let s = NetStatus.current()
        switch target {
        case .local: return [.reachable, .isLocalAddress, .isDirect]
        case .any, .host:
            if case .host(let h) = target, h == "localhost" || h.hasPrefix("127.") || h == "::1" { return [.reachable, .isLocalAddress, .isDirect] }
            guard s.connected else { return [] }
            var f: SCNetworkReachabilityFlags = [.reachable]
            if let primary = s.routeInterfaces.first, s.interfaces.first(where: { $0.name == primary })?.kind == .cellular { f.insert(.isWWAN) }
            return f
        }
    }

    func update() {
        let f = flags
        lock.lock()
        let changed = f != lastFlags
        lastFlags = f
        let cb = callback, i = info, q = queue, rl = runLoop
        lock.unlock()
        guard changed, let cb else { return }
        nonisolated(unsafe) let info = i
        if let q { q.async { cb(self, f, info) } } else { rl?.perform { cb(self, f, info) } }
    }

    func reschedule() {
        lock.lock()
        let wants = callback != nil && (queue != nil || runLoop != nil)
        let t = token
        if wants, t == nil { lastFlags = nil }
        lock.unlock()
        if wants, t == nil {
            let id = NetMonitor.shared.observe { [weak self] in self?.update() }
            lock.lock(); token = id; lock.unlock()
        } else if !wants, let t {
            NetMonitor.shared.remove(t)
            lock.lock(); token = nil; lock.unlock()
        }
    }

    deinit { if let token { NetMonitor.shared.remove(token) } }
}

public func SCNetworkReachabilityGetTypeID() -> CFTypeID { 0x5343 }

public func SCNetworkReachabilityCreateWithName(_ allocator: CFAllocator?, _ nodename: UnsafePointer<CChar>) -> SCNetworkReachability? {
    SCNetworkReachability(.host(String(cString: nodename)))
}

public func SCNetworkReachabilityCreateWithAddress(_ allocator: CFAllocator?, _ address: UnsafePointer<sockaddr>) -> SCNetworkReachability? {
    var local = false
    if Int32(address.pointee.sa_family) == Int32(AF_INET) {
        let a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        #if os(Windows)
        let b = UInt32(a.S_un.S_addr).bigEndian
        #else
        let b = UInt32(a.s_addr).bigEndian
        #endif
        local = b >> 24 == 127 || (b >> 16) == 0xA9FE
    }
    return SCNetworkReachability(local ? .local : .any)
}

public func SCNetworkReachabilityCreateWithAddressPair(_ allocator: CFAllocator?, _ localAddress: UnsafePointer<sockaddr>?,
                                                       _ remoteAddress: UnsafePointer<sockaddr>?) -> SCNetworkReachability? {
    remoteAddress.flatMap { SCNetworkReachabilityCreateWithAddress(allocator, $0) } ?? SCNetworkReachability(.any)
}

public func SCNetworkReachabilityGetFlags(_ target: SCNetworkReachability, _ flags: UnsafeMutablePointer<SCNetworkReachabilityFlags>) -> Bool {
    flags.pointee = target.flags
    return true
}

public func SCNetworkReachabilitySetCallback(_ target: SCNetworkReachability, _ callout: SCNetworkReachabilityCallBack?,
                                             _ context: UnsafeMutablePointer<SCNetworkReachabilityContext>?) -> Bool {
    target.lock.lock()
    target.callback = callout
    var info = context?.pointee.info
    if let r = context?.pointee.retain, let i = info { info = UnsafeMutableRawPointer(mutating: r(i)) }
    target.info = info
    target.lock.unlock()
    target.reschedule()
    return true
}

public func SCNetworkReachabilitySetDispatchQueue(_ target: SCNetworkReachability, _ queue: DispatchQueue?) -> Bool {
    target.lock.lock(); target.queue = queue; target.lock.unlock()
    target.reschedule()
    return true
}

public func SCNetworkReachabilityScheduleWithRunLoop(_ target: SCNetworkReachability, _ runLoop: CFRunLoop, _ runLoopMode: CFString) -> Bool {
    target.lock.lock(); target.runLoop = runLoop; target.lock.unlock()
    target.reschedule()
    return true
}

public func SCNetworkReachabilityUnscheduleFromRunLoop(_ target: SCNetworkReachability, _ runLoop: CFRunLoop, _ runLoopMode: CFString) -> Bool {
    target.lock.lock(); target.runLoop = nil; target.lock.unlock()
    target.reschedule()
    return true
}

// MARK: Interfaces and services

public let kSCNetworkInterfaceTypeEthernet: CFString = "Ethernet"
public let kSCNetworkInterfaceTypeIEEE80211: CFString = "IEEE80211"
public let kSCNetworkInterfaceTypeWWAN: CFString = "WWAN"
public let kSCNetworkInterfaceTypeBluetooth: CFString = "Bluetooth"
public let kSCNetworkInterfaceTypeBond: CFString = "Bond"
public let kSCNetworkInterfaceTypeBridge: CFString = "Bridge"
public let kSCNetworkInterfaceTypeVLAN: CFString = "VLAN"
public let kSCNetworkInterfaceTypePPP: CFString = "PPP"
public let kSCNetworkInterfaceTypeIPSec: CFString = "IPSec"
public let kSCNetworkInterfaceTypeIPv4: CFString = "IPv4"
public let kSCNetworkInterfaceTypeLoopback: CFString = "Loopback"

public final class SCNetworkInterface: @unchecked Sendable {
    let iface: NetInterface
    init(_ i: NetInterface) { iface = i }
    var type: String {
        switch iface.kind {
        case .wifi: return kSCNetworkInterfaceTypeIEEE80211 as String
        case .ethernet: return kSCNetworkInterfaceTypeEthernet as String
        case .cellular: return kSCNetworkInterfaceTypeWWAN as String
        case .loopback: return kSCNetworkInterfaceTypeLoopback as String
        case .other: return iface.name.hasPrefix("br") ? kSCNetworkInterfaceTypeBridge as String : (iface.name.hasPrefix("bond") ? kSCNetworkInterfaceTypeBond as String : kSCNetworkInterfaceTypeIPv4 as String)
        }
    }
    var displayName: String {
        switch iface.kind {
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .loopback: return "Loopback"
        case .other: return iface.name
        }
    }
}

public func SCNetworkInterfaceCopyAll() -> CFArray {
    NetStatus.current().interfaces.filter { $0.kind != .loopback }.map { SCNetworkInterface($0) } as NSArray
}
public func SCNetworkInterfaceGetBSDName(_ interface: SCNetworkInterface) -> CFString? { interface.iface.name as NSString }
public func SCNetworkInterfaceGetInterfaceType(_ interface: SCNetworkInterface) -> CFString? { interface.type as NSString }
public func SCNetworkInterfaceGetLocalizedDisplayName(_ interface: SCNetworkInterface) -> CFString? { interface.displayName as NSString }
public func SCNetworkInterfaceGetHardwareAddressString(_ interface: SCNetworkInterface) -> CFString? { interface.iface.hardwareAddress as NSString? }
public func SCNetworkInterfaceGetInterface(_ interface: SCNetworkInterface) -> SCNetworkInterface? { nil }
public func SCNetworkInterfaceCopyMediaOptions(_ interface: SCNetworkInterface, _ current: UnsafeMutablePointer<Unmanaged<CFDictionary>?>?,
                                               _ active: UnsafeMutablePointer<Unmanaged<CFDictionary>?>?,
                                               _ available: UnsafeMutablePointer<Unmanaged<CFArray>?>?, _ filter: Bool) -> Bool {
    #if os(Linux)
    let speed = (try? String(contentsOfFile: "/sys/class/net/\(interface.iface.name)/speed", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sub: String = speed.flatMap(Int.init).map { $0 >= 1000 ? "\($0 / 1000)GbaseT" : "\($0)baseTX" } ?? "autoselect"
    let d = [kSCPropNetEthernetMediaSubType as String: sub, kSCPropNetEthernetMediaOptions as String: ["full-duplex"]] as NSDictionary
    current?.pointee = .passRetained(d)
    active?.pointee = .passRetained(d)
    available?.pointee = .passRetained([sub] as NSArray)
    return true
    #else
    return false
    #endif
}

public final class SCPreferences: @unchecked Sendable {}
public final class SCNetworkService: @unchecked Sendable {
    let interface: SCNetworkInterface
    init(_ i: SCNetworkInterface) { interface = i }
}

public func SCPreferencesCreate(_ allocator: CFAllocator?, _ name: CFString, _ prefsID: CFString?) -> SCPreferences? { SCPreferences() }
public func SCNetworkServiceCopyAll(_ prefs: SCPreferences) -> CFArray? {
    (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface])?.map { SCNetworkService($0) } as NSArray?
}
public func SCNetworkServiceGetServiceID(_ service: SCNetworkService) -> CFString? { service.interface.iface.name as NSString }
public func SCNetworkServiceGetName(_ service: SCNetworkService) -> CFString? { service.interface.displayName as NSString }
public func SCNetworkServiceGetInterface(_ service: SCNetworkService) -> SCNetworkInterface? { service.interface }
public func SCNetworkServiceGetEnabled(_ service: SCNetworkService) -> Bool { service.interface.iface.isUp }

// MARK: Dynamic store

public let kSCDynamicStoreDomainState: CFString = "State:"
public let kSCDynamicStoreDomainSetup: CFString = "Setup:"
public let kSCCompAnyRegex: CFString = "[^/]+"
public let kSCEntNetLink: CFString = "Link"
public let kSCEntNetIPv4: CFString = "IPv4"
public let kSCEntNetIPv6: CFString = "IPv6"
public let kSCEntNetDNS: CFString = "DNS"
public let kSCEntNetAirPort: CFString = "AirPort"
public let kSCPropNetLinkActive: CFString = "Active"
public let kSCPropNetIPv4Addresses: CFString = "Addresses"
public let kSCPropNetIPv4Router: CFString = "Router"
public let kSCDynamicStorePropNetPrimaryInterface: CFString = "PrimaryInterface"
public let kSCDynamicStorePropNetPrimaryService: CFString = "PrimaryService"
public let kSCPropNetEthernetMediaSubType: CFString = "MediaSubType"
public let kSCPropNetEthernetMediaOptions: CFString = "MediaOptions"

public typealias SCDynamicStoreCallBack = (SCDynamicStore, CFArray, UnsafeMutableRawPointer?) -> Void

public struct SCDynamicStoreContext {
    public var version: CFIndex
    public var info: UnsafeMutableRawPointer?
    public var retain: CFAllocatorRetainCallBack?
    public var release: CFAllocatorReleaseCallBack?
    public var copyDescription: CFAllocatorCopyDescriptionCallBack?
    public init() { version = 0 }
    public init(version: CFIndex, info: UnsafeMutableRawPointer?, retain: CFAllocatorRetainCallBack?, release: CFAllocatorReleaseCallBack?,
                copyDescription: CFAllocatorCopyDescriptionCallBack?) {
        self.version = version; self.info = info; self.retain = retain; self.release = release; self.copyDescription = copyDescription
    }
}

public final class SCDynamicStore: @unchecked Sendable {
    let lock = NSLock()
    let callout: SCDynamicStoreCallBack?
    let info: UnsafeMutableRawPointer?
    var keys: [String] = []
    var token: UUID?
    var queue: DispatchQueue?
    init(_ c: SCDynamicStoreCallBack?, _ i: UnsafeMutableRawPointer?) { callout = c; info = i }
    deinit { if let token { NetMonitor.shared.remove(token) } }

    static func value(_ key: String) -> NSDictionary? {
        let s = NetStatus.current()
        let parts = key.split(separator: "/").map(String.init)
        if key == "State:/Network/Global/IPv4" || key == "State:/Network/Global/IPv6" {
            guard let primary = s.routeInterfaces.first else { return nil }
            return [kSCDynamicStorePropNetPrimaryInterface as String: primary, kSCDynamicStorePropNetPrimaryService as String: primary]
        }
        if parts.count == 5, parts[0] == "State:", parts[1] == "Network", parts[2] == "Interface", let i = s.interfaces.first(where: { $0.name == parts[3] }) {
            switch parts[4] {
            case "Link": return [kSCPropNetLinkActive as String: NSNumber(value: i.isUp)]
            case "IPv4": return i.hasIPv4 ? [kSCPropNetIPv4Addresses as String: [] as NSArray] : nil
            default: return nil
            }
        }
        return nil
    }
}

public func SCDynamicStoreCreate(_ allocator: CFAllocator?, _ name: CFString, _ callout: SCDynamicStoreCallBack?,
                                 _ context: UnsafeMutablePointer<SCDynamicStoreContext>?) -> SCDynamicStore? {
    SCDynamicStore(callout, context?.pointee.info)
}

public func SCDynamicStoreCopyValue(_ store: SCDynamicStore?, _ key: CFString) -> CFPropertyList? { SCDynamicStore.value(key as String) }

public func SCDynamicStoreCopyMultiple(_ store: SCDynamicStore?, _ keys: CFArray?, _ patterns: CFArray?) -> CFDictionary? {
    let d = NSMutableDictionary()
    for k in (keys as? [String]) ?? [] { if let v = SCDynamicStore.value(k) { d[k] = v } }
    return d
}

public func SCDynamicStoreCopyKeyList(_ store: SCDynamicStore?, _ pattern: CFString) -> CFArray? {
    let s = NetStatus.current()
    let all = ["State:/Network/Global/IPv4"] + s.interfaces.flatMap { ["State:/Network/Interface/\($0.name)/Link", "State:/Network/Interface/\($0.name)/IPv4"] }
    let re = try? NSRegularExpression(pattern: "^" + (pattern as String) + "$")
    return all.filter { k in re.map { $0.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil } ?? false } as NSArray
}

public func SCDynamicStoreSetNotificationKeys(_ store: SCDynamicStore, _ keys: CFArray?, _ patterns: CFArray?) -> Bool {
    store.lock.lock()
    store.keys = ((keys as? [String]) ?? []) + ((patterns as? [String]) ?? [])
    store.lock.unlock()
    return true
}

public func SCDynamicStoreSetDispatchQueue(_ store: SCDynamicStore, _ queue: DispatchQueue?) -> Bool {
    store.lock.lock()
    store.queue = queue
    let had = store.token
    store.lock.unlock()
    if let had, queue == nil { NetMonitor.shared.remove(had); store.lock.lock(); store.token = nil; store.lock.unlock() }
    if had == nil, queue != nil {
        let id = NetMonitor.shared.observe { [weak store] in
            guard let store else { return }
            store.lock.lock(); let keys = store.keys as NSArray; let q = store.queue; store.lock.unlock()
            nonisolated(unsafe) let info = store.info
            q?.async { store.callout?(store, keys, info) }
        }
        store.lock.lock(); store.token = id; store.lock.unlock()
    }
    return true
}

public func SCDynamicStoreCreateRunLoopSource(_ allocator: CFAllocator?, _ store: SCDynamicStore, _ order: CFIndex) -> CFRunLoopSource? {
    let source = CFRunLoopSource()
    let id = NetMonitor.shared.observe { [weak store, weak source] in
        guard let store, let source else { return }
        store.lock.lock(); let keys = store.keys as NSArray; store.lock.unlock()
        nonisolated(unsafe) let info = store.info
        source.signal { store.callout?(store, keys, info) }
    }
    source.onInvalidate = { NetMonitor.shared.remove(id) }
    return source
}

public func SCDynamicStoreKeyCreateNetworkInterfaceEntity(_ allocator: CFAllocator?, _ domain: CFString, _ ifname: CFString, _ entity: CFString?) -> CFString {
    "\(domain as String)/Network/Interface/\(ifname as String)\(entity.map { "/" + ($0 as String) } ?? "")" as NSString
}
public func SCDynamicStoreKeyCreateNetworkGlobalEntity(_ allocator: CFAllocator?, _ domain: CFString, _ entity: CFString) -> CFString {
    "\(domain as String)/Network/Global/\(entity as String)" as NSString
}
public func SCDynamicStoreKeyCreateNetworkServiceEntity(_ allocator: CFAllocator?, _ domain: CFString, _ serviceID: CFString, _ entity: CFString?) -> CFString {
    "\(domain as String)/Network/Service/\(serviceID as String)\(entity.map { "/" + ($0 as String) } ?? "")" as NSString
}

public func SCDynamicStoreCopyComputerName(_ store: SCDynamicStore?, _ nameEncoding: UnsafeMutablePointer<CFStringEncoding>?) -> CFString? {
    nameEncoding?.pointee = 0x08000100   // UTF-8
    #if os(Linux)
    if let pretty = (try? String(contentsOfFile: "/etc/machine-info", encoding: .utf8))?.split(separator: "\n")
        .first(where: { $0.hasPrefix("PRETTY_HOSTNAME=") }) {
        return String(pretty.dropFirst(16)).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) as NSString
    }
    #endif
    return ProcessInfo.processInfo.hostName.split(separator: ".").first.map { String($0) as NSString }
}

public func SCDynamicStoreCopyLocalHostName(_ store: SCDynamicStore?) -> CFString? {
    ProcessInfo.processInfo.hostName.split(separator: ".").first.map { String($0) as NSString }
}

public func SCDynamicStoreCopyConsoleUser(_ store: SCDynamicStore?, _ uid: UnsafeMutablePointer<uid_t>?, _ gid: UnsafeMutablePointer<gid_t>?) -> CFString? {
    #if os(Linux)
    uid?.pointee = getuid()
    gid?.pointee = getgid()
    #endif
    return NSUserName() as NSString
}

#if os(Windows)
public typealias uid_t = UInt32
public typealias gid_t = UInt32
#endif
