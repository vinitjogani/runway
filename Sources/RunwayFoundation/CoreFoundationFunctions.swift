// Core Foundation functions and constants apps call from plain Foundation
// code (the Mac's Foundation re-exports Core Foundation): bundle keys,
// booleans, arrays, dictionaries, data, strings, UUIDs, preferences; and
// what Foundation re-exports from Darwin and the Objective-C runtime:
// associated objects, sysctlbyname over /proc and sysinfo, Mach time.
// CF types are their toll-free-bridged Foundation classes here.

import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: Bundle keys and booleans

public let kCFBundleNameKey: CFString = "CFBundleName"
public let kCFBundleVersionKey: CFString = "CFBundleVersion"
public let kCFBundleIdentifierKey: CFString = "CFBundleIdentifier"
public let kCFBundleExecutableKey: CFString = "CFBundleExecutable"
public let kCFBundleInfoDictionaryVersionKey: CFString = "CFBundleInfoDictionaryVersion"
public let kCFBundleDevelopmentRegionKey: CFString = "CFBundleDevelopmentRegion"
public let kCFBundleLocalizationsKey: CFString = "CFBundleLocalizations"

public let kCFBooleanTrue: CFBoolean! = NSNumber(value: true)
public let kCFBooleanFalse: CFBoolean! = NSNumber(value: false)
public let kCFNull: NSNull! = NSNull()
public let kCFNotFound: CFIndex = -1

public let kCFStringEncodingUTF8: CFStringEncoding = 0x0800_0100
public let kCFStringEncodingASCII: CFStringEncoding = 0x0600
public let kCFStringEncodingMacRoman: CFStringEncoding = 0
public let kCFStringEncodingUTF16: CFStringEncoding = 0x0100
public let kCFStringEncodingISOLatin1: CFStringEncoding = 0x0201

// MARK: Memory (ARC manages the bridged objects)

public func CFRetain(_ cf: CFTypeRef?) -> CFTypeRef? { cf }
public func CFRelease(_ cf: CFTypeRef?) {}
public func CFEqual(_ a: CFTypeRef?, _ b: CFTypeRef?) -> Bool {
    if let a = a as? NSObject, let b = b as? NSObject { return a.isEqual(b) }
    return a === b
}
public func CFHash(_ cf: CFTypeRef?) -> CFHashCode { UInt(bitPattern: (cf as? NSObject)?.hash ?? 0) }
public func CFCopyDescription(_ cf: CFTypeRef?) -> CFString! { String(describing: cf.map { $0 } as Any) as NSString }

// MARK: Arrays

public func CFArrayGetCount(_ a: CFArray!) -> CFIndex { a?.count ?? 0 }
public func CFArrayGetValueAtIndex(_ a: CFArray!, _ i: CFIndex) -> UnsafeRawPointer? {
    guard let a, i >= 0, i < a.count else { return nil }
    return UnsafeRawPointer(Unmanaged.passUnretained(a[i] as AnyObject).toOpaque())
}
public func CFArrayCreate(_ allocator: CFAllocator?, _ values: UnsafeMutablePointer<UnsafeRawPointer?>!, _ count: CFIndex,
                          _ callBacks: UnsafeRawPointer?) -> CFArray! {
    var out: [AnyObject] = []
    for i in 0..<count { if let p = values[i] { out.append(Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()) } }
    return out as NSArray
}
public func CFArrayCreateMutable(_ allocator: CFAllocator?, _ capacity: CFIndex, _ callBacks: UnsafeRawPointer?) -> CFMutableArray! { NSMutableArray() }
public func CFArrayAppendValue(_ a: CFMutableArray!, _ value: UnsafeRawPointer?) {
    guard let value else { return }
    a?.add(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue())
}

// MARK: Dictionaries

public func CFDictionaryGetCount(_ d: CFDictionary!) -> CFIndex { d?.count ?? 0 }
public func CFDictionaryGetValue(_ d: CFDictionary!, _ key: UnsafeRawPointer?) -> UnsafeRawPointer? {
    guard let d, let key else { return nil }
    let k = Unmanaged<AnyObject>.fromOpaque(key).takeUnretainedValue()
    guard let v = d.object(forKey: k) else { return nil }
    return UnsafeRawPointer(Unmanaged.passUnretained(v as AnyObject).toOpaque())
}
public func CFDictionaryContainsKey(_ d: CFDictionary!, _ key: UnsafeRawPointer?) -> Bool { CFDictionaryGetValue(d, key) != nil }
public func CFDictionaryCreateMutable(_ allocator: CFAllocator?, _ capacity: CFIndex, _ keyCallBacks: UnsafeRawPointer?,
                                      _ valueCallBacks: UnsafeRawPointer?) -> CFMutableDictionary! { NSMutableDictionary() }
public func CFDictionaryCreateMutableCopy(_ allocator: CFAllocator?, _ capacity: CFIndex, _ d: CFDictionary!) -> CFMutableDictionary! {
    (d?.mutableCopy() as? NSMutableDictionary) ?? NSMutableDictionary()
}
public func CFDictionarySetValue(_ d: CFMutableDictionary!, _ key: UnsafeRawPointer?, _ value: UnsafeRawPointer?) {
    guard let d, let key else { return }
    let k = Unmanaged<AnyObject>.fromOpaque(key).takeUnretainedValue()
    if let value { d.setObject(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue(), forKey: k as! AnyHashable) } else { d.removeObject(forKey: k) }
}
public func CFDictionaryRemoveValue(_ d: CFMutableDictionary!, _ key: UnsafeRawPointer?) { CFDictionarySetValue(d, key, nil) }
public let kCFTypeDictionaryKeyCallBacks: UnsafeRawPointer? = nil
public let kCFTypeDictionaryValueCallBacks: UnsafeRawPointer? = nil
public let kCFTypeArrayCallBacks: UnsafeRawPointer? = nil

// MARK: Data

public func CFDataGetLength(_ d: CFData!) -> CFIndex { d?.length ?? 0 }
public func CFDataGetBytePtr(_ d: CFData!) -> UnsafePointer<UInt8>! { d?.bytes.assumingMemoryBound(to: UInt8.self) }
public func CFDataGetMutableBytePtr(_ d: CFMutableData!) -> UnsafeMutablePointer<UInt8>! { d?.mutableBytes.assumingMemoryBound(to: UInt8.self) }
public func CFDataGetBytes(_ d: CFData!, _ range: CFRange, _ buffer: UnsafeMutablePointer<UInt8>!) {
    guard let d else { return }
    d.getBytes(buffer, range: NSRange(location: range.location, length: range.length))
}
public func CFDataCreate(_ allocator: CFAllocator?, _ bytes: UnsafePointer<UInt8>!, _ length: CFIndex) -> CFData! {
    NSData(bytes: bytes, length: length)
}
public func CFDataCreateMutable(_ allocator: CFAllocator?, _ capacity: CFIndex) -> CFMutableData! { NSMutableData(capacity: capacity) }
public func CFDataAppendBytes(_ d: CFMutableData!, _ bytes: UnsafePointer<UInt8>!, _ length: CFIndex) { d?.append(bytes, length: length) }
public func CFDataSetLength(_ d: CFMutableData!, _ length: CFIndex) { d?.length = length }
public func CFDataIncreaseLength(_ d: CFMutableData!, _ extra: CFIndex) { d?.increaseLength(by: extra) }

// MARK: Strings

public func CFStringGetLength(_ s: CFString!) -> CFIndex { s?.length ?? 0 }
public func CFStringCreateWithCharacters(_ allocator: CFAllocator?, _ chars: UnsafePointer<UniChar>!, _ count: CFIndex) -> CFString! {
    NSString(characters: chars, length: count)
}
public func CFStringCreateWithCString(_ allocator: CFAllocator?, _ cStr: UnsafePointer<CChar>!, _ encoding: CFStringEncoding) -> CFString! {
    cStr.map { NSString(utf8String: $0) } ?? nil
}
public func CFStringGetCString(_ s: CFString!, _ buffer: UnsafeMutablePointer<CChar>!, _ size: CFIndex, _ encoding: CFStringEncoding) -> Bool {
    guard let s, let buffer else { return false }
    let utf8 = Array(String(s).utf8CString)
    guard utf8.count <= size else { return false }
    for (i, c) in utf8.enumerated() { buffer[i] = c }
    return true
}
public func CFStringCompare(_ a: CFString!, _ b: CFString!, _ options: CFOptionFlags) -> ComparisonResult {
    (a as String? ?? "").compare(b as String? ?? "")
}

// MARK: UUIDs

public func CFUUIDCreate(_ allocator: CFAllocator?) -> CFUUID! { NSUUID() }
public func CFUUIDCreateString(_ allocator: CFAllocator?, _ uuid: CFUUID!) -> CFString! { uuid?.uuidString as NSString? }
public func CFUUIDGetTypeID() -> CFTypeID { 30 }
public struct CFUUIDBytes: Sendable {
    public var byte0, byte1, byte2, byte3, byte4, byte5, byte6, byte7: UInt8
    public var byte8, byte9, byte10, byte11, byte12, byte13, byte14, byte15: UInt8
    public init(byte0: UInt8 = 0, byte1: UInt8 = 0, byte2: UInt8 = 0, byte3: UInt8 = 0, byte4: UInt8 = 0, byte5: UInt8 = 0,
                byte6: UInt8 = 0, byte7: UInt8 = 0, byte8: UInt8 = 0, byte9: UInt8 = 0, byte10: UInt8 = 0, byte11: UInt8 = 0,
                byte12: UInt8 = 0, byte13: UInt8 = 0, byte14: UInt8 = 0, byte15: UInt8 = 0) {
        (self.byte0, self.byte1, self.byte2, self.byte3, self.byte4, self.byte5, self.byte6, self.byte7) = (byte0, byte1, byte2, byte3, byte4, byte5, byte6, byte7)
        (self.byte8, self.byte9, self.byte10, self.byte11, self.byte12, self.byte13, self.byte14, self.byte15) = (byte8, byte9, byte10, byte11, byte12, byte13, byte14, byte15)
    }
}
public func CFUUIDGetConstantUUIDWithBytes(_ allocator: CFAllocator?, _ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8, _ b4: UInt8,
                                           _ b5: UInt8, _ b6: UInt8, _ b7: UInt8, _ b8: UInt8, _ b9: UInt8, _ b10: UInt8, _ b11: UInt8,
                                           _ b12: UInt8, _ b13: UInt8, _ b14: UInt8, _ b15: UInt8) -> CFUUID! {
    NSUUID(uuidString: UUID(uuid: (b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15)).uuidString)
}
public func CFUUIDGetUUIDBytes(_ uuid: CFUUID!) -> CFUUIDBytes {
    guard let u = uuid?.uuidString, let id = UUID(uuidString: u) else { return CFUUIDBytes() }
    let t = id.uuid
    return CFUUIDBytes(byte0: t.0, byte1: t.1, byte2: t.2, byte3: t.3, byte4: t.4, byte5: t.5, byte6: t.6, byte7: t.7,
                       byte8: t.8, byte9: t.9, byte10: t.10, byte11: t.11, byte12: t.12, byte13: t.13, byte14: t.14, byte15: t.15)
}

// MARK: Preferences and bundles

public let kCFPreferencesCurrentApplication: CFString = "kCFPreferencesCurrentApplication"
public let kCFPreferencesAnyApplication: CFString = "kCFPreferencesAnyApplication"
public let kCFPreferencesCurrentUser: CFString = "kCFPreferencesCurrentUser"
public let kCFPreferencesAnyUser: CFString = "kCFPreferencesAnyUser"
public let kCFPreferencesCurrentHost: CFString = "kCFPreferencesCurrentHost"
public let kCFPreferencesAnyHost: CFString = "kCFPreferencesAnyHost"

private func preferenceDefaults(_ app: CFString) -> UserDefaults? {
    let id = app as String
    if id == "kCFPreferencesCurrentApplication" { return .standard }
    if id == "kCFPreferencesAnyApplication" { return UserDefaults(suiteName: ".GlobalPreferences") }
    return UserDefaults(suiteName: id)
}
public func CFPreferencesCopyAppValue(_ key: CFString, _ app: CFString) -> CFPropertyList? {
    preferenceDefaults(app)?.object(forKey: key as String) as AnyObject?
}
public func CFPreferencesSetAppValue(_ key: CFString, _ value: CFPropertyList?, _ app: CFString) {
    preferenceDefaults(app)?.set(value, forKey: key as String)
}
public func CFPreferencesAppSynchronize(_ app: CFString) -> Bool { preferenceDefaults(app)?.synchronize() ?? false }
public func CFPreferencesGetAppBooleanValue(_ key: CFString, _ app: CFString, _ valid: UnsafeMutablePointer<DarwinBoolean>?) -> Bool {
    let v = preferenceDefaults(app)?.object(forKey: key as String)
    valid?.pointee = DarwinBoolean(v != nil)
    return (v as? Bool) ?? false
}
public func CFPreferencesGetAppIntegerValue(_ key: CFString, _ app: CFString, _ valid: UnsafeMutablePointer<DarwinBoolean>?) -> CFIndex {
    let v = preferenceDefaults(app)?.object(forKey: key as String)
    valid?.pointee = DarwinBoolean(v != nil)
    return (v as? Int) ?? 0
}

public func CFBundleCopyInfoDictionaryForURL(_ url: CFURL!) -> CFDictionary! {
    guard let u = url as URL? else { return nil }
    for candidate in [u.appendingPathComponent("Contents/Info.plist"), u.appendingPathComponent("Info.plist"), u] {
        if let data = try? Data(contentsOf: candidate),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return plist as NSDictionary
        }
    }
    return nil
}

public struct DarwinBoolean: ExpressibleByBooleanLiteral, Sendable, Hashable {
    public var boolValue: Bool
    public init(_ value: Bool) { boolValue = value }
    public init(booleanLiteral value: Bool) { boolValue = value }
}

// MARK: Objective-C associated objects

public enum objc_AssociationPolicy: UInt, Sendable {
    case OBJC_ASSOCIATION_ASSIGN = 0
    case OBJC_ASSOCIATION_RETAIN_NONATOMIC = 1
    case OBJC_ASSOCIATION_COPY_NONATOMIC = 3
    case OBJC_ASSOCIATION_RETAIN = 769
    case OBJC_ASSOCIATION_COPY = 771
}

private final class AssociationTable: @unchecked Sendable {
    struct Entry {
        weak var owner: AnyObject?
        var values: [UnsafeRawPointer: Any] = [:]
    }
    let lock = NSLock()
    var entries: [ObjectIdentifier: Entry] = [:]
    var writes = 0
    static let shared = AssociationTable()
}

/// Values attached to an object by key, dropped once the object is gone
/// (checked on access, so a reused address never sees a stale value).
public func objc_setAssociatedObject(_ object: Any, _ key: UnsafeRawPointer, _ value: Any?, _ policy: objc_AssociationPolicy) {
    let owner = object as AnyObject
    let t = AssociationTable.shared
    t.lock.withLock {
        let id = ObjectIdentifier(owner)
        var e = t.entries[id].flatMap { $0.owner === owner ? $0 : nil } ?? AssociationTable.Entry(owner: owner)
        e.values[key] = value
        t.entries[id] = e
        t.writes += 1
        if t.writes % 256 == 0 { t.entries = t.entries.filter { $0.value.owner != nil } }
    }
}

public func objc_getAssociatedObject(_ object: Any, _ key: UnsafeRawPointer) -> Any? {
    let owner = object as AnyObject
    let t = AssociationTable.shared
    return t.lock.withLock {
        guard let e = t.entries[ObjectIdentifier(owner)], e.owner === owner else { return nil }
        return e.values[key]
    }
}

public func objc_removeAssociatedObjects(_ object: Any) {
    let owner = object as AnyObject
    let t = AssociationTable.shared
    t.lock.withLock { _ = t.entries.removeValue(forKey: ObjectIdentifier(owner)) }
}

/// Classes by name: Swift classes aren't registered with a runtime here.
public func objc_getClass(_ name: UnsafePointer<CChar>) -> Any? { NSClassFromString(String(cString: name)) }
public func objc_lookUpClass(_ name: UnsafePointer<CChar>) -> AnyClass? { NSClassFromString(String(cString: name)) }

// MARK: Mach time

public struct mach_timebase_info_data_t: Sendable {
    public var numer: UInt32
    public var denom: UInt32
    public init() { numer = 1; denom = 1 }
    public init(numer: UInt32, denom: UInt32) { self.numer = numer; self.denom = denom }
}
public typealias mach_timebase_info_t = UnsafeMutablePointer<mach_timebase_info_data_t>
public typealias kern_return_t = Int32
public typealias mach_port_t = UInt32
public typealias natural_t = UInt32
public typealias integer_t = Int32
public let KERN_SUCCESS: kern_return_t = 0
public let KERN_INVALID_ARGUMENT: kern_return_t = 4
public let KERN_FAILURE: kern_return_t = 5
public let KERN_NOT_FOUND: kern_return_t = 56
/// The task's port (no Mach ports here; calls taking one fail or answer from /proc).
public var mach_task_self_: mach_port_t { 0 }
public func mach_task_self() -> mach_port_t { 0 }
public func mach_host_self() -> mach_port_t { 0 }

/// Nanoseconds of monotonic time (the timebase is 1/1).
public func mach_absolute_time() -> UInt64 {
    #if canImport(Glibc)
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
    #else
    return DispatchTime.now().uptimeNanoseconds
    #endif
}
public func mach_continuous_time() -> UInt64 { mach_absolute_time() }
@discardableResult
public func mach_timebase_info(_ info: mach_timebase_info_t!) -> kern_return_t {
    info?.pointee = mach_timebase_info_data_t(numer: 1, denom: 1)
    return KERN_SUCCESS
}

// MARK: sysctlbyname

/// The Mac's sysctl names that describe the machine, answered from
/// sysinfo, /proc and uname. Unknown names fail with ENOENT, as on a Mac.
public func sysctlbyname(_ name: UnsafePointer<CChar>!, _ oldp: UnsafeMutableRawPointer!, _ oldlenp: UnsafeMutablePointer<Int>!,
                         _ newp: UnsafeMutableRawPointer!, _ newlen: Int) -> Int32 {
    guard let name else { return -1 }
    guard let value = SysctlValues.value(String(cString: name)) else {
        #if canImport(Glibc)
        errno = ENOENT
        #endif
        return -1
    }
    let bytes: [UInt8]
    switch value {
    case .int32(let v): bytes = withUnsafeBytes(of: v) { Array($0) }
    case .int64(let v): bytes = withUnsafeBytes(of: v) { Array($0) }
    case .string(let s): bytes = Array(s.utf8) + [0]
    case .raw(let b): bytes = b
    }
    guard let oldlenp else { return 0 }
    if oldp == nil {
        oldlenp.pointee = bytes.count
        return 0
    }
    let n = min(bytes.count, oldlenp.pointee)
    bytes.withUnsafeBytes { src in oldp.copyMemory(from: src.baseAddress!, byteCount: n) }
    oldlenp.pointee = n
    return n < bytes.count && !(SysctlValues.isString(value)) ? -1 : 0
}

enum SysctlValues {
    enum Value { case int32(Int32), int64(Int64), string(String), raw([UInt8]) }
    static func isString(_ v: Value) -> Bool { if case .string = v { return true }; return false }

    static func procField(_ file: String, _ key: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix(key) {
            if let colon = line.firstIndex(of: ":") { return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    static func kernel(_ file: String) -> String {
        ((try? String(contentsOfFile: "/proc/sys/kernel/" + file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var machine: String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }

    static func value(_ name: String) -> Value? {
        let cpus = ProcessInfo.processInfo.processorCount
        let active = ProcessInfo.processInfo.activeProcessorCount
        switch name {
        case "hw.memsize", "hw.memsize_usable": return .int64(Int64(ProcessInfo.processInfo.physicalMemory))
        case "hw.physmem": return .int32(Int32(truncatingIfNeeded: ProcessInfo.processInfo.physicalMemory))
        case "hw.ncpu", "hw.logicalcpu", "hw.logicalcpu_max", "hw.physicalcpu", "hw.physicalcpu_max":
            return .int32(Int32(cpus))
        case "hw.activecpu": return .int32(Int32(active))
        case "hw.pagesize", "vm.pagesize", "hw.pagesize32": return .int64(4096)
        case "hw.cachelinesize": return .int64(64)
        case "hw.byteorder": return .int32(1234)
        case "hw.cpufrequency", "hw.cpufrequency_max":
            if let mhz = procField("/proc/cpuinfo", "cpu MHz").flatMap(Double.init) { return .int64(Int64(mhz * 1_000_000)) }
            return nil
        case "machdep.cpu.brand_string":
            return .string(procField("/proc/cpuinfo", "model name") ?? procField("/proc/cpuinfo", "Hardware") ?? "Unknown CPU")
        case "machdep.cpu.vendor": return .string(procField("/proc/cpuinfo", "vendor_id") ?? "Unknown")
        case "machdep.cpu.core_count", "machdep.cpu.thread_count": return .int32(Int32(cpus))
        case "hw.model", "hw.product":
            let model = (try? String(contentsOfFile: "/sys/class/dmi/id/product_name", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .string(model.flatMap { $0.isEmpty ? nil : $0 } ?? "Linux")
        case "hw.machine": return .string(machine)
        case "kern.ostype": return .string(kernel("ostype"))
        case "kern.osrelease": return .string(kernel("osrelease"))
        case "kern.version": return .string(kernel("version"))
        case "kern.hostname": return .string(ProcessInfo.processInfo.hostName)
        case "kern.osversion", "kern.osproductversion":
            return .string(ProcessInfo.processInfo.operatingSystemVersionString)
        case "kern.boottime":
            let boot = Int64(Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime)
            return .raw(withUnsafeBytes(of: (boot, Int64(0))) { Array($0) })
        case "sysctl.proc_translated", "hw.optional.arm64", "hw.optional.arm.FEAT_AES": return .int32(0)
        case "hw.optional.x86_64": return .int32(machine == "x86_64" ? 1 : 0)
        case "hw.nperflevels": return .int32(1)
        case "hw.perflevel0.physicalcpu", "hw.perflevel0.logicalcpu": return .int32(Int32(cpus))
        case "hw.perflevel1.physicalcpu", "hw.perflevel1.logicalcpu": return .int32(0)
        default: return nil
        }
    }
}
