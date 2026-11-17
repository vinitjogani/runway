// More of Apple's Foundation (and what it re-exports from Darwin and
// CoreServices) that corelibs lacks: NSException, NSDataDetector (links,
// e-mail addresses, phone numbers and dates found with regular
// expressions and DateFormatter-free parsing), NSMetadataQuery (Spotlight:
// a query that gathers nothing), Apple Event send constants, sysctl() by
// MIB for process info (kinfo_proc, P_TRACED from /proc/self/status).

import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: NSException

public struct NSExceptionName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let genericException = NSExceptionName("NSGenericException")
    public static let rangeException = NSExceptionName("NSRangeException")
    public static let invalidArgumentException = NSExceptionName("NSInvalidArgumentException")
    public static let internalInconsistencyException = NSExceptionName("NSInternalInconsistencyException")
    public static let mallocException = NSExceptionName("NSMallocException")
    public static let objectInaccessibleException = NSExceptionName("NSObjectInaccessibleException")
    public static let destinationInvalidException = NSExceptionName("NSDestinationInvalidException")
    public static let portTimeoutException = NSExceptionName("NSPortTimeoutException")
    public static let parseErrorException = NSExceptionName("NSParseErrorException")
    public static let characterConversionException = NSExceptionName("NSCharacterConversionException")
    public static let fileHandleOperationException = NSExceptionName("NSFileHandleOperationException")
    public static let undefinedKeyException = NSExceptionName("NSUnknownKeyException")
}

/// Objective-C exceptions: Swift can't catch them, so raising one ends the
/// program with its name and reason, as an uncaught exception does on a Mac.
open class NSException: NSObject, Error, @unchecked Sendable {
    public let name: NSExceptionName
    public let reason: String?
    public let userInfo: [AnyHashable: Any]?
    open var callStackSymbols: [String] { Thread.callStackSymbols }
    open var callStackReturnAddresses: [NSNumber] { Thread.callStackReturnAddresses }
    public init(name: NSExceptionName, reason: String?, userInfo: [AnyHashable: Any]? = nil) {
        self.name = name
        self.reason = reason
        self.userInfo = userInfo
    }
    open func raise() -> Never { fatalError("*** Terminating app due to uncaught exception '\(name.rawValue)', reason: '\(reason ?? "")'") }
    open class func raise(_ name: NSExceptionName, format: String, arguments: CVaListPointer) -> Never {
        NSException(name: name, reason: format).raise()
    }
}

public typealias NSUncaughtExceptionHandler = (NSException) -> Void
public func NSGetUncaughtExceptionHandler() -> NSUncaughtExceptionHandler? { nil }
public func NSSetUncaughtExceptionHandler(_ handler: NSUncaughtExceptionHandler?) {}

// MARK: NSDataDetector

public typealias NSTextCheckingTypes = UInt64

/// A detected link, date or phone number (corelibs can't construct its own
/// result kinds for these).
final class DetectedResult: NSTextCheckingResult, @unchecked Sendable {
    let kind: NSTextCheckingResult.CheckingType
    let found: NSRange
    let link: URL?
    let when: Date?
    let phone: String?
    init(kind: NSTextCheckingResult.CheckingType, range: NSRange, url: URL? = nil, date: Date? = nil, phone: String? = nil) {
        self.kind = kind; found = range; link = url; when = date; self.phone = phone
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override var resultType: NSTextCheckingResult.CheckingType { kind }
    override var range: NSRange { found }
    override var numberOfRanges: Int { 1 }
    override func range(at idx: Int) -> NSRange { found }
}

extension NSTextCheckingResult {
    /// What a data detector found (links, dates, phone numbers).
    public var url: URL? { (self as? DetectedResult)?.link }
    public var date: Date? { (self as? DetectedResult)?.when }
    public var phoneNumber: String? { (self as? DetectedResult)?.phone }
    public var duration: TimeInterval { 0 }
    public var timeZone: TimeZone? { nil }
    public var addressComponents: [NSTextCheckingKey: String]? { nil }
}

public struct NSTextCheckingKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Finds links, e-mail addresses, phone numbers and ISO dates with regular
/// expressions (Apple's detector is a trained parser; this covers the
/// common shapes).
open class NSDataDetector: NSObject, @unchecked Sendable {
    public let checkingTypes: NSTextCheckingTypes
    let expression: NSRegularExpression
    static let linkPattern = #"(?:(?:https?|ftp|file)://|www\.|mailto:)[^\s<>"'()\[\]]+[^\s<>"'()\[\].,;:!?]|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
    static let phonePattern = #"\+?\(?\d{1,4}\)?[\s.-]?\(?\d{2,4}\)?[\s.-]?\d{3,4}[\s.-]?\d{3,4}"#
    static let datePattern = #"\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?(?:Z|[+-]\d{2}:?\d{2})?)?\b"#

    public init(types checkingTypes: NSTextCheckingTypes) throws {
        self.checkingTypes = checkingTypes
        var parts: [String] = []
        let t = NSTextCheckingResult.CheckingType(rawValue: checkingTypes)
        if t.contains(.link) { parts.append("(?:" + Self.linkPattern + ")") }
        if t.contains(.date) { parts.append("(?:" + Self.datePattern + ")") }
        if t.contains(.phoneNumber) { parts.append("(?:" + Self.phonePattern + ")") }
        expression = try NSRegularExpression(pattern: parts.isEmpty ? "(?!)" : parts.joined(separator: "|"), options: [.caseInsensitive])
        super.init()
    }

    open var pattern: String { expression.pattern }

    open func matches(in string: String, options: NSRegularExpression.MatchingOptions = [], range: NSRange) -> [NSTextCheckingResult] {
        let types = NSTextCheckingResult.CheckingType(rawValue: checkingTypes)
        return expression.matches(in: string, options: options, range: range).compactMap { m -> NSTextCheckingResult? in
            let text = (string as NSString).substring(with: m.range)
            if types.contains(.date), text.range(of: "^" + Self.datePattern + "$", options: .regularExpression) != nil {
                let f = ISO8601DateFormatter()
                f.formatOptions = text.count == 10 ? [.withFullDate] : [.withInternetDateTime]
                if let d = f.date(from: text) { return DetectedResult(kind: .date, range: m.range, date: d) }
            }
            if types.contains(.link), text.range(of: "^(?:" + Self.linkPattern + ")$", options: .regularExpression) != nil {
                let s = text.contains("@") && !text.contains("://") && !text.lowercased().hasPrefix("mailto:") ? "mailto:" + text
                    : text.lowercased().hasPrefix("www.") ? "http://" + text : text
                if let u = URL(string: s) { return DetectedResult(kind: .link, range: m.range, url: u) }
            }
            if types.contains(.phoneNumber) { return DetectedResult(kind: .phoneNumber, range: m.range, phone: text) }
            return nil
        }
    }

    open func firstMatch(in string: String, options: NSRegularExpression.MatchingOptions = [], range: NSRange) -> NSTextCheckingResult? {
        matches(in: string, options: options, range: range).first
    }

    open func numberOfMatches(in string: String, options: NSRegularExpression.MatchingOptions = [], range: NSRange) -> Int {
        matches(in: string, options: options, range: range).count
    }

    open func rangeOfFirstMatch(in string: String, options: NSRegularExpression.MatchingOptions = [], range: NSRange) -> NSRange {
        firstMatch(in: string, options: options, range: range)?.range ?? NSRange(location: NSNotFound, length: 0)
    }

    open func enumerateMatches(in string: String, options: NSRegularExpression.MatchingOptions = [], range: NSRange,
                               using block: (NSTextCheckingResult?, NSRegularExpression.MatchingFlags, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop: ObjCBool = false
        for m in matches(in: string, options: options, range: range) {
            block(m, [], &stop)
            if stop.boolValue { break }
        }
    }
}

// MARK: NSMetadataQuery (Spotlight)

open class NSMetadataItem: NSObject, @unchecked Sendable {
    let values: [String: Any]
    public init?(url: URL) { values = [NSMetadataItemPathKey: url.path, NSMetadataItemURLKey: url, NSMetadataItemFSNameKey: url.lastPathComponent] }
    open func value(forAttribute key: String) -> Any? { values[key] }
    open func values(forAttributes keys: [String]) -> [String: Any]? { values.filter { keys.contains($0.key) } }
    open var attributes: [String] { Array(values.keys) }
}

public let NSMetadataItemPathKey = "kMDItemPath"
public let NSMetadataItemURLKey = "kMDItemURL"
public let NSMetadataItemFSNameKey = "kMDItemFSName"
public let NSMetadataItemDisplayNameKey = "kMDItemDisplayName"
public let NSMetadataItemContentTypeKey = "kMDItemContentType"
public let NSMetadataItemCFBundleIdentifierKey = "kMDItemCFBundleIdentifier"
public let NSMetadataItemFSContentChangeDateKey = "kMDItemFSContentChangeDate"
public let NSMetadataItemFSCreationDateKey = "kMDItemFSCreationDate"
public let NSMetadataItemFSSizeKey = "kMDItemFSSize"
public let NSMetadataItemKindKey = "kMDItemKind"
public let NSMetadataItemLastUsedDateKey = "kMDItemLastUsedDate"
public let NSMetadataQueryUserHomeScope = "NSMetadataQueryUserHomeScope"
public let NSMetadataQueryLocalComputerScope = "NSMetadataQueryLocalComputerScope"
public let NSMetadataQueryNetworkScope = "NSMetadataQueryNetworkScope"
public let NSMetadataQueryUbiquitousDocumentsScope = "NSMetadataQueryUbiquitousDocumentsScope"
public let NSMetadataQueryUbiquitousDataScope = "NSMetadataQueryUbiquitousDataScope"
public let NSMetadataQueryIndexedLocalComputerScope = "NSMetadataQueryIndexedLocalComputerScope"
public let NSMetadataUbiquitousItemDownloadingStatusKey = "NSMetadataUbiquitousItemDownloadingStatusKey"

public protocol NSMetadataQueryDelegate: AnyObject {
    func metadataQuery(_ query: NSMetadataQuery, replacementObjectForResultObject result: NSMetadataItem) -> Any
    func metadataQuery(_ query: NSMetadataQuery, replacementValueForAttribute attrName: String, value attrValue: Any) -> Any
}
extension NSMetadataQueryDelegate {
    public func metadataQuery(_ query: NSMetadataQuery, replacementObjectForResultObject result: NSMetadataItem) -> Any { result }
    public func metadataQuery(_ query: NSMetadataQuery, replacementValueForAttribute attrName: String, value attrValue: Any) -> Any { attrValue }
}

/// Spotlight has no index here: a started query finishes gathering at
/// once with no results (posting the notifications a Mac posts).
open class NSMetadataQuery: NSObject, @unchecked Sendable {
    public static let didStartGatheringNotification = Notification.Name("NSMetadataQueryDidStartGatheringNotification")
    public static let gatheringProgressNotification = Notification.Name("NSMetadataQueryGatheringProgressNotification")
    public static let didFinishGatheringNotification = Notification.Name("NSMetadataQueryDidFinishGatheringNotification")
    public static let didUpdateNotification = Notification.Name("NSMetadataQueryDidUpdateNotification")
    open weak var delegate: NSMetadataQueryDelegate?
    open var predicate: NSPredicate?
    open var sortDescriptors: [NSSortDescriptor] = []
    open var valueListAttributes: [String] = []
    open var groupingAttributes: [String]?
    open var notificationBatchingInterval: TimeInterval = 1
    open var searchScopes: [Any] = []
    open var searchItems: [Any]?
    open var operationQueue: OperationQueue?
    open private(set) var isStarted = false
    open private(set) var isGathering = false
    open var isStopped: Bool { !isStarted }
    open var resultCount: Int { 0 }
    open var results: [Any] { [] }
    public override init() {}

    @discardableResult
    open func start() -> Bool {
        isStarted = true
        let post = { [self] in
            NotificationCenter.default.post(name: Self.didStartGatheringNotification, object: self)
            NotificationCenter.default.post(name: Self.didFinishGatheringNotification, object: self)
        }
        if let q = operationQueue { q.addOperation(post) } else { DispatchQueue.main.async(execute: post) }
        return true
    }
    open func stop() { isStarted = false }
    open func disableUpdates() {}
    open func enableUpdates() {}
    open func result(at idx: Int) -> Any { fatalError("NSMetadataQuery has no results") }
    open func index(ofResult result: Any) -> Int { NSNotFound }
    open func value(ofAttribute attrName: String, forResultAt idx: Int) -> Any? { nil }
}

// MARK: Apple Event sending (CoreServices' AE headers)

public let kAutoGenerateReturnID: AEReturnID = -1
public let kAnyTransactionID: AETransactionID = 0
public let kAEDefaultTimeout: Int = -1
public let kNoTimeOut: Int = -2

// MARK: sysctl by MIB

public let CTL_KERN: Int32 = 1
public let CTL_HW: Int32 = 6
public let KERN_PROC: Int32 = 14
public let KERN_PROC_PID: Int32 = 1
public let KERN_PROC_ALL: Int32 = 0
public let KERN_OSRELEASE: Int32 = 2
public let KERN_BOOTTIME: Int32 = 21
public let HW_MEMSIZE: Int32 = 24
public let HW_NCPU: Int32 = 3
public let P_TRACED: Int32 = 0x0000_0800

public struct extern_proc: Sendable {
    public var p_flag: Int32 = 0
    public var p_pid: Int32 = 0
    public var p_stat: Int8 = 0
    public var p_comm: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    public init() {}
}

public struct eproc: Sendable {
    public var e_ppid: Int32 = 0
    public var e_pgid: Int32 = 0
    public init() {}
}

public struct kinfo_proc: Sendable {
    public var kp_proc = extern_proc()
    public var kp_eproc = eproc()
    public init() {}
}

/// sysctl by MIB: process info (kern.proc.pid: flags with P_TRACED when a
/// debugger is attached, parent pid) and the names sysctlbyname answers.
public func sysctl(_ name: UnsafeMutablePointer<Int32>!, _ namelen: UInt32, _ oldp: UnsafeMutableRawPointer!,
                   _ oldlenp: UnsafeMutablePointer<Int>!, _ newp: UnsafeMutableRawPointer!, _ newlen: Int) -> Int32 {
    guard let name, namelen >= 2 else { return -1 }
    let mib = (0..<Int(namelen)).map { name[$0] }
    if mib[0] == CTL_KERN, mib[1] == KERN_PROC, namelen >= 4, mib[2] == KERN_PROC_PID {
        var info = kinfo_proc()
        let pid = mib[3]
        info.kp_proc.p_pid = pid
        if let status = try? String(contentsOfFile: "/proc/\(pid)/status", encoding: .utf8) {
            for line in status.split(separator: "\n") {
                if line.hasPrefix("TracerPid:"), let t = Int32(line.dropFirst(10).trimmingCharacters(in: .whitespaces)), t != 0 {
                    info.kp_proc.p_flag |= P_TRACED
                }
                if line.hasPrefix("PPid:"), let p = Int32(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) { info.kp_eproc.e_ppid = p }
            }
        } else {
            return -1
        }
        let size = MemoryLayout<kinfo_proc>.size
        if let oldp, let oldlenp, oldlenp.pointee >= size { oldp.storeBytes(of: info, as: kinfo_proc.self) }
        oldlenp?.pointee = size
        return 0
    }
    let names: [[Int32]: String] = [[CTL_KERN, KERN_OSRELEASE]: "kern.osrelease", [CTL_KERN, KERN_BOOTTIME]: "kern.boottime",
                                    [CTL_HW, HW_MEMSIZE]: "hw.memsize", [CTL_HW, HW_NCPU]: "hw.ncpu"]
    guard let n = names[Array(mib.prefix(2))] else { return -1 }
    return sysctlbyname(n, oldp, oldlenp, newp, newlen)
}

// MARK: audit_token_t (bsm)

/// A process's audit token: 8 words, the pid at index 5 as on the Mac.
public struct audit_token_t: Sendable, Equatable {
    public var val: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)
    public init() { val = (0, 0, 0, 0, 0, 0, 0, 0) }
    public init(val: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)) { self.val = val }
    public static func == (a: Self, b: Self) -> Bool { withUnsafeBytes(of: a.val) { x in withUnsafeBytes(of: b.val) { y in x.elementsEqual(y) } } }
}
public func audit_token_to_pid(_ token: audit_token_t) -> Int32 { Int32(bitPattern: token.val.5) }

// MARK: Run loop modes and observers

extension RunLoop.Mode {
    /// The Mac's mode while a control tracks the mouse (menus, sliders).
    public static let eventTracking = RunLoop.Mode("NSEventTrackingRunLoopMode")
    public static let modalPanel = RunLoop.Mode("NSModalPanelRunLoopMode")
}

public struct CFRunLoopActivity: OptionSet, Sendable {
    public let rawValue: CFOptionFlags
    public init(rawValue: CFOptionFlags) { self.rawValue = rawValue }
    public static let entry = Self(rawValue: 1), beforeTimers = Self(rawValue: 2), beforeSources = Self(rawValue: 4)
    public static let beforeWaiting = Self(rawValue: 32), afterWaiting = Self(rawValue: 64), exit = Self(rawValue: 128)
    public static let allActivities = Self(rawValue: 0x0FFF_FFFF)
}

/// A run loop observer. The main run loop here is the main dispatch queue
/// (see CFRunLoop), which has no observable phases, so observers are
/// accepted and never called.
public final class CFRunLoopObserver: @unchecked Sendable {
    let activities: CFRunLoopActivity
    let block: (CFRunLoopObserver?, CFRunLoopActivity) -> Void
    var valid = true
    init(_ activities: CFRunLoopActivity, _ block: @escaping (CFRunLoopObserver?, CFRunLoopActivity) -> Void) {
        self.activities = activities
        self.block = block
    }
}

public func CFRunLoopObserverCreateWithHandler(_ allocator: CFAllocator?, _ activities: CFOptionFlags, _ repeats: Bool, _ order: CFIndex,
                                               _ block: ((CFRunLoopObserver?, CFRunLoopActivity) -> Void)!) -> CFRunLoopObserver! {
    CFRunLoopObserver(CFRunLoopActivity(rawValue: activities), block)
}
public func CFRunLoopAddObserver(_ rl: CFRunLoop!, _ observer: CFRunLoopObserver!, _ mode: CFRunLoopMode!) {}
public func CFRunLoopRemoveObserver(_ rl: CFRunLoop!, _ observer: CFRunLoopObserver!, _ mode: CFRunLoopMode!) {}
public func CFRunLoopObserverInvalidate(_ observer: CFRunLoopObserver!) { observer?.valid = false }
public func CFRunLoopObserverIsValid(_ observer: CFRunLoopObserver!) -> Bool { observer?.valid ?? false }

// MARK: dyld images (the dynamic loader's list of loaded objects)

public struct mach_header: Sendable {
    public var magic: UInt32 = 0, cputype: Int32 = 0, cpusubtype: Int32 = 0, filetype: UInt32 = 0
    public var ncmds: UInt32 = 0, sizeofcmds: UInt32 = 0, flags: UInt32 = 0
    public init() {}
}

enum LoadedImages {
    /// (path, base address) of every loaded object, from /proc/self/maps.
    static func list() -> [(String, UInt)] {
        guard let maps = try? String(contentsOfFile: "/proc/self/maps", encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var out: [(String, UInt)] = []
        for line in maps.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 6, let path = parts.last.map(String.init), path.hasPrefix("/"), !seen.contains(path) else { continue }
            seen.insert(path)
            let base = UInt(parts[0].split(separator: "-")[0], radix: 16) ?? 0
            out.append((path, base))
        }
        return out
    }
    nonisolated(unsafe) static var cachedNames: [UnsafeMutablePointer<CChar>] = []
}

public func _dyld_image_count() -> UInt32 { UInt32(LoadedImages.list().count) }
public func _dyld_get_image_name(_ image_index: UInt32) -> UnsafePointer<CChar>! {
    let l = LoadedImages.list()
    guard Int(image_index) < l.count else { return nil }
    let p = strdup(l[Int(image_index)].0)!
    LoadedImages.cachedNames.append(p)
    return UnsafePointer(p)
}
public func _dyld_get_image_header(_ image_index: UInt32) -> UnsafePointer<mach_header>! {
    let l = LoadedImages.list()
    guard Int(image_index) < l.count else { return nil }
    return UnsafePointer(bitPattern: l[Int(image_index)].1)
}
public func _dyld_get_image_vmaddr_slide(_ image_index: UInt32) -> Int { 0 }

// MARK: MacTypes integer names

public typealias uint8 = UInt8
public typealias uint16 = UInt16
public typealias uint32 = UInt32
public typealias uint64 = UInt64
public typealias sint8 = Int8
public typealias sint16 = Int16
public typealias sint32 = Int32
public typealias sint64 = Int64

extension NSValue {
    /// Copies the value's bytes (NSValue's `getValue(_:size:)`).
    public func getValue(_ value: UnsafeMutableRawPointer, size: Int) { getValue(value) }
}
