// Darwin system API Mac code reaches through Foundation (which re-exports
// the C library there) and that has no counterpart in Glibc or the Windows
// CRT: quality-of-service classes, and Foundation formatters
// swift-corelibs-foundation marks unavailable.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: Quality of service

/// `qos_class_t` (sys/qos.h).
public struct qos_class_t: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
public let QOS_CLASS_USER_INTERACTIVE = qos_class_t(0x21)
public let QOS_CLASS_USER_INITIATED = qos_class_t(0x19)
public let QOS_CLASS_DEFAULT = qos_class_t(0x15)
public let QOS_CLASS_UTILITY = qos_class_t(0x11)
public let QOS_CLASS_BACKGROUND = qos_class_t(0x09)
public let QOS_CLASS_UNSPECIFIED = qos_class_t(0x00)

private final class ThreadQoS: @unchecked Sendable {
    static let key = "RunwayQoSClass"
}

/// Sets the calling thread's class. Linux and Windows have no QoS classes:
/// the class is remembered for `qos_class_self()` and scheduling is left alone.
@discardableResult
public func pthread_set_qos_class_self_np(_ qos: qos_class_t, _ relativePriority: Int32) -> Int32 {
    Thread.current.threadDictionary[ThreadQoS.key] = qos.rawValue
    return 0
}

public func qos_class_self() -> qos_class_t {
    if let raw = Thread.current.threadDictionary[ThreadQoS.key] as? UInt32 { return qos_class_t(rawValue: raw) }
    return Thread.isMainThread ? QOS_CLASS_USER_INTERACTIVE : QOS_CLASS_DEFAULT
}

public func qos_class_main() -> qos_class_t { QOS_CLASS_USER_INTERACTIVE }

extension DispatchQoS.QoSClass {
    public init?(rawValue: qos_class_t) {
        switch rawValue {
        case QOS_CLASS_USER_INTERACTIVE: self = .userInteractive
        case QOS_CLASS_USER_INITIATED: self = .userInitiated
        case QOS_CLASS_DEFAULT: self = .default
        case QOS_CLASS_UTILITY: self = .utility
        case QOS_CLASS_BACKGROUND: self = .background
        case QOS_CLASS_UNSPECIFIED: self = .unspecified
        default: return nil
        }
    }
    public var rawValue: qos_class_t {
        switch self {
        case .userInteractive: return QOS_CLASS_USER_INTERACTIVE
        case .userInitiated: return QOS_CLASS_USER_INITIATED
        case .default: return QOS_CLASS_DEFAULT
        case .utility: return QOS_CLASS_UTILITY
        case .background: return QOS_CLASS_BACKGROUND
        default: return QOS_CLASS_UNSPECIFIED
        }
    }
}

// MARK: MeasurementFormatter

/// Foundation's MeasurementFormatter (unavailable in corelibs): numbers
/// through a NumberFormatter, units by their symbols; `.naturalScale`
/// picks the unit of the same dimension that keeps the value readable.
open class MeasurementFormatter: Formatter, @unchecked Sendable {
    public struct UnitOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let providedUnit = UnitOptions(rawValue: 1 << 0)
        public static let naturalScale = UnitOptions(rawValue: 1 << 1)
        public static let temperatureWithoutUnit = UnitOptions(rawValue: 1 << 2)
    }
    open var unitOptions: UnitOptions = []
    open var unitStyle: Formatter.UnitStyle = .medium
    open var locale: Locale! = .current { didSet { numberFormatter.locale = locale } }
    open var numberFormatter: NumberFormatter! = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 3
        return f
    }()

    public override init() { super.init() }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    private func scaled(_ value: Double, _ unit: Unit) -> (Double, Unit) {
        guard unitOptions.contains(.naturalScale), !unitOptions.contains(.providedUnit), let d = unit as? Dimension else { return (value, unit) }
        let base = d.converter.baseUnitValue(fromValue: value)
        let family: [Dimension]
        switch d {
        case is UnitInformationStorage: family = [UnitInformationStorage.bytes, UnitInformationStorage.kilobytes, UnitInformationStorage.megabytes, UnitInformationStorage.gigabytes, UnitInformationStorage.terabytes]
        case is UnitLength: family = [UnitLength.millimeters, UnitLength.centimeters, UnitLength.meters, UnitLength.kilometers]
        case is UnitMass: family = [UnitMass.milligrams, UnitMass.grams, UnitMass.kilograms, UnitMass.metricTons]
        case is UnitDuration: family = [UnitDuration.seconds, UnitDuration.minutes, UnitDuration.hours]
        case is UnitFrequency: family = [UnitFrequency.hertz, UnitFrequency.kilohertz, UnitFrequency.megahertz, UnitFrequency.gigahertz]
        case is UnitPower: family = [UnitPower.milliwatts, UnitPower.watts, UnitPower.kilowatts, UnitPower.megawatts]
        case is UnitEnergy: family = [UnitEnergy.joules, UnitEnergy.kilojoules]
        default: return (value, unit)
        }
        var best: (Double, Unit) = (value, unit)
        for u in family {
            let v = u.converter.value(fromBaseUnitValue: base)
            if abs(v) >= 1 || u == family.first { best = (v, u) }
        }
        return best
    }

    open func string(from measurement: Measurement<Unit>) -> String { string(value: measurement.value, unit: measurement.unit) }

    open func string<U: Unit>(from measurement: Measurement<U>) -> String { string(value: measurement.value, unit: measurement.unit) }

    private func string(value: Double, unit: Unit) -> String {
        let (v, u) = scaled(value, unit)
        let number = numberFormatter.string(from: NSNumber(value: v)) ?? "\(v)"
        if u is UnitTemperature {
            if unitOptions.contains(.temperatureWithoutUnit) { return number + "°" }
            return number + u.symbol
        }
        return unitStyle == .short ? number + u.symbol : number + " " + u.symbol
    }

    open func string(from unit: Unit) -> String { unit.symbol }

    open override func string(for obj: Any?) -> String? {
        if let m = obj as? Measurement<Unit> { return string(from: m) }
        if let m = obj as? NSMeasurement { return string(value: m.doubleValue, unit: m.unit) }
        return nil
    }
}

// MARK: ValueTransformer

public struct NSValueTransformerName: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public static let negateBooleanTransformerName = NSValueTransformerName("NSNegateBoolean")
    public static let isNilTransformerName = NSValueTransformerName("NSIsNil")
    public static let isNotNilTransformerName = NSValueTransformerName("NSIsNotNil")
    public static let unarchiveFromDataTransformerName = NSValueTransformerName("NSUnarchiveFromData")
    public static let keyedUnarchiveFromDataTransformerName = NSValueTransformerName("NSKeyedUnarchiveFromData")
    public static let secureUnarchiveFromDataTransformerName = NSValueTransformerName("NSSecureUnarchiveFromData")
}

/// Foundation's ValueTransformer (missing from corelibs): the registry of
/// named transformers and the base class to subclass.
open class ValueTransformer: NSObject {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registry: [NSValueTransformerName: ValueTransformer] = [
        .negateBooleanTransformerName: _NegateBoolean(), .isNilTransformerName: _IsNil(negated: false), .isNotNilTransformerName: _IsNil(negated: true),
    ]

    public override init() { super.init() }

    open class func setValueTransformer(_ transformer: ValueTransformer?, forName name: NSValueTransformerName) {
        lock.lock(); defer { lock.unlock() }
        registry[name] = transformer
    }
    public convenience init?(forName name: NSValueTransformerName) {
        guard ValueTransformer.transformer(named: name) != nil else { return nil }
        self.init()
        forwarded = ValueTransformer.transformer(named: name)
    }
    private var forwarded: ValueTransformer?
    private static func transformer(named name: NSValueTransformerName) -> ValueTransformer? {
        lock.lock(); defer { lock.unlock() }
        return registry[name]
    }
    open class func valueTransformerNames() -> [NSValueTransformerName] {
        lock.lock(); defer { lock.unlock() }
        return Array(registry.keys)
    }
    open class func transformedValueClass() -> AnyClass { NSObject.self }
    open class func allowsReverseTransformation() -> Bool { true }
    open func transformedValue(_ value: Any?) -> Any? { forwarded.map { $0.transformedValue(value) } ?? value }
    open func reverseTransformedValue(_ value: Any?) -> Any? { forwarded.map { $0.reverseTransformedValue(value) } ?? transformedValue(value) }
}

private final class _NegateBoolean: ValueTransformer {
    override func transformedValue(_ value: Any?) -> Any? { !((value as? Bool) ?? (value as? NSNumber)?.boolValue ?? false) }
}
private final class _IsNil: ValueTransformer {
    let negated: Bool
    init(negated: Bool) { self.negated = negated; super.init() }
    override class func allowsReverseTransformation() -> Bool { false }
    override func transformedValue(_ value: Any?) -> Any? { (value == nil || value is NSNull) != negated }
}


// MARK: Threads to subclass

/// A thread class that can be subclassed, with `Thread`'s API (corelibs'
/// own `Thread` can't be: its overridable members don't load outside
/// Foundation). The build tool makes `class Worker: Thread` inherit this.
open class SubclassableThread: NSObject, @unchecked Sendable {
    private let state = NSLock()
    private var thread: Thread?
    private var block: (@Sendable () -> Void)?
    private var _cancelled = false, _executing = false, _finished = false
    open var name: String? { didSet { thread?.name = name } }
    open var qualityOfService: QualityOfService = .default
    open var stackSize: Int = 0
    open var threadPriority: Double = 0.5
    public let threadDictionary = NSMutableDictionary()

    public override init() { super.init() }
    public convenience init(block: @escaping @Sendable () -> Void) {
        self.init()
        self.block = block
    }

    open var isCancelled: Bool { state.lock(); defer { state.unlock() }; return _cancelled }
    open var isExecuting: Bool { state.lock(); defer { state.unlock() }; return _executing }
    open var isFinished: Bool { state.lock(); defer { state.unlock() }; return _finished }
    open var isMainThread: Bool { false }

    open func start() {
        state.lock()
        guard thread == nil else { state.unlock(); return }
        let t = Thread { [self] in
            state.lock(); _executing = true; state.unlock()
            if !isCancelled { main() }
            state.lock(); _executing = false; _finished = true; state.unlock()
        }
        t.name = name
        t.qualityOfService = qualityOfService
        if stackSize > 0 { t.stackSize = stackSize }
        thread = t
        state.unlock()
        t.start()
    }

    /// The thread's work; the default runs the block it was made with.
    open func main() { block?() }

    open func cancel() {
        state.lock(); _cancelled = true; state.unlock()
        thread?.cancel()
    }
}

// MARK: CFRunLoop of a RunLoop

extension RunLoop {
    /// The Core Foundation run loop behind this one.
    public func getCFRunLoop() -> CFRunLoop { self === RunLoop.main ? CFRunLoopGetMain() : CFRunLoopGetCurrent() }
}


// MARK: libproc

/// `proc_bsdinfo` (sys/proc_info.h), filled from /proc on Linux.
public struct proc_bsdinfo {
    public var pbi_flags: UInt32 = 0
    public var pbi_status: UInt32 = 0
    public var pbi_xstatus: UInt32 = 0
    public var pbi_pid: UInt32 = 0
    public var pbi_ppid: UInt32 = 0
    public var pbi_uid: uid_t = 0
    public var pbi_gid: gid_t = 0
    public var pbi_ruid: uid_t = 0
    public var pbi_rgid: gid_t = 0
    public var pbi_svuid: uid_t = 0
    public var pbi_svgid: gid_t = 0
    public var rfu_1: UInt32 = 0
    public var pbi_comm: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    public var pbi_name: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    public var pbi_nfiles: UInt32 = 0
    public var pbi_pgid: UInt32 = 0
    public var pbi_pjobc: UInt32 = 0
    public var e_tdev: UInt32 = 0
    public var e_tpgid: UInt32 = 0
    public var pbi_nice: Int32 = 0
    public var pbi_start_tvsec: UInt64 = 0
    public var pbi_start_tvusec: UInt64 = 0
    public init() {}
}

public let PROC_PIDTBSDINFO: Int32 = 3
public let PROC_PIDTASKINFO: Int32 = 4
public let PROC_PIDTASKALLINFO: Int32 = 2
public let PROC_PIDVNODEPATHINFO: Int32 = 9
public let PROC_PIDPATHINFO_MAXSIZE: Int32 = 4096
public let PROC_ALL_PIDS: UInt32 = 1
public let MAXCOMLEN: Int32 = 16
public let PROC_PIDPATHINFO_SIZE: Int32 = 1024

private func procFile(_ pid: Int32, _ name: String) -> String? {
    try? String(contentsOfFile: "/proc/\(pid)/\(name)", encoding: .utf8)
}

/// Seconds since the epoch at boot (/proc/stat's btime).
private let bootTime: Double = {
    guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else { return 0 }
    for line in stat.split(separator: "\n") where line.hasPrefix("btime ") { return Double(line.dropFirst(6)) ?? 0 }
    return 0
}()

/// `proc_pidinfo`: PROC_PIDTBSDINFO is answered from /proc/<pid>/stat and
/// status; other flavors return 0 (no information), as for a process the
/// caller may not inspect.
public func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32 {
    guard flavor == PROC_PIDTBSDINFO, let buffer, Int(buffersize) >= MemoryLayout<proc_bsdinfo>.size,
          let stat = procFile(pid, "stat"), let close = stat.lastIndex(of: ")") else { return 0 }
    var info = proc_bsdinfo()
    info.pbi_pid = UInt32(pid)
    let name = stat[stat.index(after: stat.firstIndex(of: "(") ?? stat.startIndex)..<close]
    let fields = stat[stat.index(after: close)...].split(separator: " ")
    if fields.count > 20 {
        info.pbi_ppid = UInt32(fields[1]) ?? 0
        info.pbi_pgid = UInt32(fields[2]) ?? 0
        info.pbi_nice = Int32(fields[16]) ?? 0
        let ticks = Double(fields[19]) ?? 0
        let start = bootTime + ticks / 100
        info.pbi_start_tvsec = UInt64(max(start, 0))
        info.pbi_start_tvusec = UInt64(max((start - start.rounded(.down)) * 1_000_000, 0))
    }
    if let status = procFile(pid, "status") {
        for line in status.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            if line.hasPrefix("Uid:"), parts.count > 2 { info.pbi_ruid = uid_t(parts[1]) ?? 0; info.pbi_uid = uid_t(parts[2]) ?? 0 }
            if line.hasPrefix("Gid:"), parts.count > 2 { info.pbi_rgid = gid_t(parts[1]) ?? 0; info.pbi_gid = gid_t(parts[2]) ?? 0 }
        }
    }
    withUnsafeMutableBytes(of: &info.pbi_comm) { raw in
        for (i, b) in name.utf8.prefix(15).enumerated() { raw[i] = b }
    }
    withUnsafeMutableBytes(of: &info.pbi_name) { raw in
        for (i, b) in name.utf8.prefix(31).enumerated() { raw[i] = b }
    }
    buffer.assumingMemoryBound(to: proc_bsdinfo.self).pointee = info
    return Int32(MemoryLayout<proc_bsdinfo>.size)
}

/// The executable's path (/proc/<pid>/exe).
public func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32 {
    guard let buffer, let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe") else { return 0 }
    let bytes = Array(path.utf8.prefix(Int(buffersize) - 1))
    buffer.copyMemory(from: bytes, byteCount: bytes.count)
    buffer.storeBytes(of: 0, toByteOffset: bytes.count, as: UInt8.self)
    return Int32(bytes.count)
}

/// The process's short name (/proc/<pid>/comm).
public func proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32 {
    guard let buffer, let name = procFile(pid, "comm")?.trimmingCharacters(in: .whitespacesAndNewlines) else { return 0 }
    let bytes = Array(name.utf8.prefix(Int(buffersize) - 1))
    buffer.copyMemory(from: bytes, byteCount: bytes.count)
    buffer.storeBytes(of: 0, toByteOffset: bytes.count, as: UInt8.self)
    return Int32(bytes.count)
}

/// Every process id; with a nil buffer, how many there are.
public func proc_listallpids(_ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32 {
    let pids = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { Int32($0) }
    guard let buffer else { return Int32(pids.count) }
    let n = min(pids.count, Int(buffersize) / MemoryLayout<Int32>.size)
    buffer.copyMemory(from: pids, byteCount: n * MemoryLayout<Int32>.size)
    return Int32(n)
}

/// `proc_listpids`: the same, counted in bytes.
public func proc_listpids(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32 {
    proc_listallpids(buffer, buffersize) * Int32(MemoryLayout<Int32>.size)
}

// MARK: Numbers

extension CGFloat {
    public init(truncating number: NSNumber) { self.init(number.doubleValue) }
    public init?(exactly number: NSNumber) { self.init(number.doubleValue) }
}


// MARK: stdio with Darwin's nullability

// Darwin imports `FILE *` as implicitly unwrapped (`fopen` returns
// `UnsafeMutablePointer<FILE>!` and the rest take one); Glibc's headers make
// the result optional and the parameters non-optional, so Mac code passing
// `fopen`'s result along doesn't compile. These overloads take the optional.
#if canImport(Glibc) || canImport(Musl)
@discardableResult public func fclose(_ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { fclose($0) } ?? EOF }
@discardableResult public func fflush(_ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { fflush($0) } ?? EOF }
public func fread(_ ptr: UnsafeMutableRawPointer!, _ size: Int, _ nitems: Int, _ stream: UnsafeMutablePointer<FILE>?) -> Int { stream.map { fread(ptr, size, nitems, $0) } ?? 0 }
@discardableResult public func fwrite(_ ptr: UnsafeRawPointer!, _ size: Int, _ nitems: Int, _ stream: UnsafeMutablePointer<FILE>?) -> Int { stream.map { fwrite(ptr, size, nitems, $0) } ?? 0 }
@discardableResult public func fseek(_ stream: UnsafeMutablePointer<FILE>?, _ offset: Int, _ whence: Int32) -> Int32 { stream.map { fseek($0, offset, whence) } ?? -1 }
@discardableResult public func fseeko(_ stream: UnsafeMutablePointer<FILE>?, _ offset: off_t, _ whence: Int32) -> Int32 { stream.map { fseeko($0, offset, whence) } ?? -1 }
public func ftell(_ stream: UnsafeMutablePointer<FILE>?) -> Int { stream.map { ftell($0) } ?? -1 }
public func ftello(_ stream: UnsafeMutablePointer<FILE>?) -> off_t { stream.map { ftello($0) } ?? -1 }
public func rewind(_ stream: UnsafeMutablePointer<FILE>?) { if let stream { rewind(stream) } }
public func feof(_ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { feof($0) } ?? 1 }
public func ferror(_ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { ferror($0) } ?? 1 }
public func fileno(_ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { fileno($0) } ?? -1 }
public func fgetc(_ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { fgetc($0) } ?? EOF }
public func getc(_ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { getc($0) } ?? EOF }
@discardableResult public func fputc(_ c: Int32, _ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { fputc(c, $0) } ?? EOF }
@discardableResult public func fputs(_ s: UnsafePointer<CChar>!, _ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { fputs(s, $0) } ?? EOF }
public func fgets(_ s: UnsafeMutablePointer<CChar>!, _ n: Int32, _ stream: UnsafeMutablePointer<FILE>?) -> UnsafeMutablePointer<CChar>? { stream.flatMap { fgets(s, n, $0) } }
@discardableResult public func pclose(_ stream: UnsafeMutablePointer<FILE>?) -> Int32 { stream.map { pclose($0) } ?? -1 }
public func clearerr(_ stream: UnsafeMutablePointer<FILE>?) { if let stream { clearerr(stream) } }
#endif

// MARK: Core Foundation time

/// Seconds between the Unix epoch and Core Foundation's reference date (1 January 2001).
public let kCFAbsoluteTimeIntervalSince1970: CFTimeInterval = 978_307_200
public let kCFAbsoluteTimeIntervalSince1904: CFTimeInterval = 3_061_152_000
