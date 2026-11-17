// os for Linux and Windows: Logger, OSLog, os_log, OSSignposter,
// os_unfair_lock and OSAllocatedUnfairLock.
//
// Log messages go to the platform's log: the systemd journal on Linux
// (native protocol over /run/systemd/journal/socket, with SYSLOG_IDENTIFIER,
// PRIORITY and the subsystem and category as OS_SUBSYSTEM/OS_CATEGORY
// fields, so `journalctl OS_SUBSYSTEM=com.example.app` filters as
// `log stream --predicate 'subsystem == …'` does), and the debugger
// (OutputDebugString) on Windows. They are echoed to stderr when it's a
// terminal or there's no journal; RUNWAY_LOG=stderr|journal|none forces a
// sink, RUNWAY_LOG_LEVEL=debug|info|default|error sets the stderr threshold
// (default: info). `.private` values print as <private>, as Apple's do
// outside a debugger; RUNWAY_LOG_PRIVATE=1 reveals them.

@_exported import Foundation
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// MARK: Types

public struct OSLogType: Equatable, RawRepresentable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(_ rawValue: UInt8) { self.rawValue = rawValue }
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let `default` = OSLogType(0x00)
    public static let info = OSLogType(0x01)
    public static let debug = OSLogType(0x02)
    public static let error = OSLogType(0x10)
    public static let fault = OSLogType(0x11)

    var name: String {
        switch self {
        case .info: return "Info"
        case .debug: return "Debug"
        case .error: return "Error"
        case .fault: return "Fault"
        default: return "Default"
        }
    }
    /// syslog priority.
    var priority: Int {
        switch self {
        case .debug: return 7
        case .info: return 6
        case .error: return 3
        case .fault: return 2
        default: return 5
        }
    }
    /// Order for thresholds: debug < info < default < error < fault.
    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .error: return 3
        case .fault: return 4
        default: return 2
        }
    }
}

public final class OSLog: NSObject, @unchecked Sendable {
    public struct Category: Sendable, Hashable, RawRepresentable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let pointsOfInterest = Category(rawValue: "PointsOfInterest")
        public static let dynamicTracing = Category(rawValue: "DynamicTracing")
        public static let dynamicStackTracing = Category(rawValue: "DynamicStackTracing")
    }

    public let subsystem: String
    public let category: String
    let enabled: Bool

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        enabled = true
    }
    public convenience init(subsystem: String, category: Category) { self.init(subsystem: subsystem, category: category.rawValue) }

    private init(disabled: Bool) {
        subsystem = ""
        category = ""
        enabled = !disabled
    }

    public static let `default` = OSLog(disabled: false)
    public static let disabled = OSLog(disabled: true)

    public func isEnabled(type: OSLogType) -> Bool { enabled && LogSink.shared.accepts(type) }
    public var signpostsEnabled: Bool { false }

    public override var description: String { "<OSLog: \(subsystem):\(category)>" }
}

// MARK: Privacy and formatting

public struct OSLogPrivacy: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case auto, `public`, `private`, sensitive }
    public struct Mask: Equatable, Sendable {
        let hashes: Bool
        public static let hash = Mask(hashes: true)
        public static let none = Mask(hashes: false)
    }
    let kind: Kind
    let mask: Mask

    public static let auto = OSLogPrivacy(kind: .auto, mask: .none)
    public static let `public` = OSLogPrivacy(kind: .public, mask: .none)
    public static let `private` = OSLogPrivacy(kind: .private, mask: .none)
    public static let sensitive = OSLogPrivacy(kind: .sensitive, mask: .none)
    public static func auto(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: .auto, mask: mask) }
    public static func `private`(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: .private, mask: mask) }
    public static func sensitive(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: .sensitive, mask: mask) }

    func render(_ s: String) -> String {
        guard kind == .private || kind == .sensitive, !LogSink.shared.revealPrivate else { return s }
        if mask.hashes {
            var h: UInt64 = 0xcbf29ce484222325
            for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            return "<mask.hash: '\(String(h, radix: 16))'>"
        }
        return "<private>"
    }
}

public struct OSLogStringAlignment: Sendable {
    enum Side: Sendable { case none, left, right }
    let side: Side
    let columns: Int
    public static var none: OSLogStringAlignment { OSLogStringAlignment(side: .none, columns: 0) }
    public static func right(columns: @autoclosure () -> Int) -> OSLogStringAlignment { OSLogStringAlignment(side: .right, columns: columns()) }
    public static func left(columns: @autoclosure () -> Int) -> OSLogStringAlignment { OSLogStringAlignment(side: .left, columns: columns()) }

    func apply(_ s: String) -> String {
        let pad = columns - s.count
        guard pad > 0 else { return s }
        switch side {
        case .none: return s
        case .left: return s + String(repeating: " ", count: pad)
        case .right: return String(repeating: " ", count: pad) + s
        }
    }
}

public struct OSLogIntegerFormatting: Sendable {
    enum Radix: Sendable { case decimal, hex, octal }
    let radix: Radix
    let explicitPositiveSign: Bool
    let includePrefix: Bool
    let uppercase: Bool
    let minDigits: Int

    public static var decimal: OSLogIntegerFormatting { .decimal(explicitPositiveSign: false) }
    public static var hex: OSLogIntegerFormatting { .hex(explicitPositiveSign: false) }
    public static var octal: OSLogIntegerFormatting { .octal(explicitPositiveSign: false) }
    public static func decimal(explicitPositiveSign: Bool = false, minDigits: @autoclosure () -> Int = 0) -> OSLogIntegerFormatting {
        .init(radix: .decimal, explicitPositiveSign: explicitPositiveSign, includePrefix: false, uppercase: false, minDigits: minDigits())
    }
    public static func hex(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false,
                           minDigits: @autoclosure () -> Int = 0) -> OSLogIntegerFormatting {
        .init(radix: .hex, explicitPositiveSign: explicitPositiveSign, includePrefix: includePrefix, uppercase: uppercase, minDigits: minDigits())
    }
    public static func octal(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false,
                             minDigits: @autoclosure () -> Int = 0) -> OSLogIntegerFormatting {
        .init(radix: .octal, explicitPositiveSign: explicitPositiveSign, includePrefix: includePrefix, uppercase: uppercase, minDigits: minDigits())
    }

    func format<T: BinaryInteger>(_ v: T) -> String {
        let r: Int
        switch radix { case .decimal: r = 10; case .hex: r = 16; case .octal: r = 8 }
        var digits = String(v.magnitude, radix: r, uppercase: uppercase)
        if digits.count < minDigits { digits = String(repeating: "0", count: minDigits - digits.count) + digits }
        if includePrefix { digits = (radix == .hex ? "0x" : radix == .octal ? "0o" : "") + digits }
        if v < 0 { return "-" + digits }
        return (explicitPositiveSign ? "+" : "") + digits
    }
}

public struct OSLogFloatFormatting: Sendable {
    enum Style: Sendable { case fixed, hex, exponential, hybrid }
    let style: Style
    let precision: Int?
    let explicitPositiveSign: Bool
    let uppercase: Bool

    public static var fixed: OSLogFloatFormatting { .init(style: .fixed, precision: nil, explicitPositiveSign: false, uppercase: false) }
    public static var hex: OSLogFloatFormatting { .init(style: .hex, precision: nil, explicitPositiveSign: false, uppercase: false) }
    public static var exponential: OSLogFloatFormatting { .init(style: .exponential, precision: nil, explicitPositiveSign: false, uppercase: false) }
    public static var hybrid: OSLogFloatFormatting { .init(style: .hybrid, precision: nil, explicitPositiveSign: false, uppercase: false) }
    public static func fixed(precision: @autoclosure () -> Int, explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        .init(style: .fixed, precision: precision(), explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }
    public static func fixed(explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        .init(style: .fixed, precision: nil, explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }
    public static func hex(explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        .init(style: .hex, precision: nil, explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }
    public static func exponential(precision: @autoclosure () -> Int, explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        .init(style: .exponential, precision: precision(), explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }
    public static func exponential(explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        .init(style: .exponential, precision: nil, explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }
    public static func hybrid(precision: @autoclosure () -> Int, explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        .init(style: .hybrid, precision: precision(), explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }
    public static func hybrid(explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        .init(style: .hybrid, precision: nil, explicitPositiveSign: explicitPositiveSign, uppercase: uppercase)
    }

    func format(_ v: Double) -> String {
        var spec = "%" + (explicitPositiveSign ? "+" : "")
        if let precision { spec += ".\(precision)" }
        switch style {
        case .fixed: spec += uppercase ? "F" : "f"
        case .hex: spec += uppercase ? "A" : "a"
        case .exponential: spec += uppercase ? "E" : "e"
        case .hybrid: spec += uppercase ? "G" : "g"
        }
        return String(format: spec, v)
    }
}

public enum OSLogBoolFormat: Sendable {
    case truth
    case answer
}

public enum OSLogPointerFormat: Sendable {
    case none
    case ipv4Address
    case ipv6Address
    case sockaddr
    case time
    case timeval
    case timespec
    case uuid
}

public enum OSLogInt32ExtendedFormat: Sendable {
    case ipv4Address
    case secondsSince1970
    case darwinErrno
    case darwinMode
    case darwinSignal
    case bitrate
    case bytes
    case truncatedBitrate
    case truncatedBytes
}

// MARK: OSLogMessage

public struct OSLogInterpolation: StringInterpolationProtocol {
    enum Piece {
        case literal(String)
        case value(() -> String, OSLogPrivacy)
    }
    var pieces: [Piece] = []

    public init(literalCapacity: Int, interpolationCount: Int) { pieces.reserveCapacity(interpolationCount * 2 + 1) }

    public mutating func appendLiteral(_ literal: String) { pieces.append(.literal(literal)) }

    public mutating func appendInterpolation(_ argumentString: @autoclosure @escaping () -> String,
                                             align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ align.apply(argumentString()) }, privacy))
    }

    public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: @autoclosure @escaping () -> T,
                                                                         align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ align.apply(value().description) }, privacy))
    }

    public mutating func appendInterpolation<T: FixedWidthInteger>(_ number: @autoclosure @escaping () -> T,
                                                                   format: OSLogIntegerFormatting = .decimal,
                                                                   align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ align.apply(format.format(number())) }, privacy.kind == .auto ? .public : privacy))
    }

    public mutating func appendInterpolation(_ number: @autoclosure @escaping () -> Int32, format: OSLogInt32ExtendedFormat,
                                             privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ String(number()) }, privacy))
    }

    public mutating func appendInterpolation(_ number: @autoclosure @escaping () -> Double, format: OSLogFloatFormatting = .fixed,
                                             align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ align.apply(format.format(number())) }, privacy.kind == .auto ? .public : privacy))
    }

    public mutating func appendInterpolation(_ number: @autoclosure @escaping () -> Float, format: OSLogFloatFormatting = .fixed,
                                             align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ align.apply(format.format(Double(number()))) }, privacy.kind == .auto ? .public : privacy))
    }

    public mutating func appendInterpolation(_ boolean: @autoclosure @escaping () -> Bool, format: OSLogBoolFormat = .truth,
                                             privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ format == .truth ? (boolean() ? "true" : "false") : (boolean() ? "YES" : "NO") },
                             privacy.kind == .auto ? .public : privacy))
    }

    public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Any.Type, align: OSLogStringAlignment = .none,
                                             privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ align.apply(String(describing: value())) }, privacy.kind == .auto ? .public : privacy))
    }

    public mutating func appendInterpolation(_ pointer: @autoclosure @escaping () -> UnsafeRawPointer, format: OSLogPointerFormat = .none,
                                             privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ String(describing: pointer()) }, privacy))
    }

    public mutating func appendInterpolation(_ pointer: @autoclosure @escaping () -> UnsafeRawBufferPointer, format: OSLogPointerFormat = .none,
                                             privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ pointer().map { String(format: "%02x", $0) }.joined() }, privacy))
    }

    /// Anything else (errors, optionals, values without a description):
    /// as `String(describing:)`. Apple's rejects these at compile time;
    /// accepting them here never changes what compiles on a Mac.
    public mutating func appendInterpolation<T>(_ value: @autoclosure @escaping () -> T,
                                                align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        pieces.append(.value({ align.apply(String(describing: value())) }, privacy))
    }
}

public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    let interpolation: OSLogInterpolation

    public init(stringInterpolation: OSLogInterpolation) { interpolation = stringInterpolation }
    public init(stringLiteral value: String) {
        var i = OSLogInterpolation(literalCapacity: value.count, interpolationCount: 0)
        i.appendLiteral(value)
        interpolation = i
    }

    /// The message as it's logged (private values redacted).
    var rendered: String {
        var out = ""
        for p in interpolation.pieces {
            switch p {
            case .literal(let s): out += s
            case .value(let f, let privacy): out += privacy.render(f())
            }
        }
        return out
    }
}

// MARK: Logger

public struct Logger: @unchecked Sendable {
    public let logObject: OSLog

    public init(subsystem: String, category: String) { logObject = OSLog(subsystem: subsystem, category: category) }
    public init(_ logObj: OSLog) { logObject = logObj }
    public init() { logObject = .default }

    public func log(_ message: OSLogMessage) { log(level: .default, message) }
    public func log(level: OSLogType, _ message: OSLogMessage) { LogSink.shared.emit(logObject, level, message) }
    public func trace(_ message: OSLogMessage) { log(level: .debug, message) }
    public func debug(_ message: OSLogMessage) { log(level: .debug, message) }
    public func info(_ message: OSLogMessage) { log(level: .info, message) }
    public func notice(_ message: OSLogMessage) { log(level: .default, message) }
    public func warning(_ message: OSLogMessage) { LogSink.shared.emit(logObject, .error, message, priority: 4) }
    public func error(_ message: OSLogMessage) { log(level: .error, message) }
    public func critical(_ message: OSLogMessage) { log(level: .fault, message) }
    public func fault(_ message: OSLogMessage) { log(level: .fault, message) }
}

// MARK: os_log

public func os_log(_ message: OSLogMessage) {
    LogSink.shared.emit(.default, .default, message)
}

public func os_log(_ logLevel: OSLogType, log: OSLog = .default, _ message: OSLogMessage) {
    LogSink.shared.emit(log, logLevel, message)
}

public func os_log(log: OSLog, _ message: OSLogMessage) {
    LogSink.shared.emit(log, .default, message)
}

/// The printf-style form: `os_log("%{public}@ took %d ms", log: log, type: .info, name, ms)`.
public func os_log(_ message: StaticString, dso: UnsafeRawPointer? = #dsohandle, log: OSLog = .default, type: OSLogType = .default, _ args: CVarArg...) {
    LogSink.shared.emitFormat(log, type, message.description, args)
}

public func os_log(_ type: OSLogType, dso: UnsafeRawPointer = #dsohandle, log: OSLog = .default, _ message: StaticString, _ args: CVarArg...) {
    LogSink.shared.emitFormat(log, type, message.description, args)
}

// MARK: Sinks

/// One logged entry (kept for OSLogStore's current-process scope).
public struct _LogRecord: Sendable {
    public let date: Date
    public let subsystem: String
    public let category: String
    public let level: OSLogType
    public let message: String
}

final class LogSink: @unchecked Sendable {
    static let shared = LogSink()

    enum Mode { case auto, stderr, journal, none }
    let mode: Mode
    let threshold: Int
    let revealPrivate: Bool
    let toStderr: Bool
    let processName = ProcessInfo.processInfo.processName
    let pid = ProcessInfo.processInfo.processIdentifier
    private let lock = NSLock()
    private var ring: [_LogRecord] = []
    private var ringHead = 0
    static let ringCapacity = 1000
    /// Test hook: receives every rendered line.
    var observer: ((_LogRecord) -> Void)?

    #if os(Linux)
    private var journalFD: Int32 = -1
    #endif

    init() {
        let env = ProcessInfo.processInfo.environment
        switch env["RUNWAY_LOG"]?.lowercased() {
        case "stderr": mode = .stderr
        case "journal", "journald": mode = .journal
        case "none", "off": mode = .none
        default: mode = .auto
        }
        switch env["RUNWAY_LOG_LEVEL"]?.lowercased() {
        case "debug", "trace": threshold = 0
        case "default", "notice": threshold = 2
        case "error", "warning": threshold = 3
        case "fault", "critical": threshold = 4
        default: threshold = 1
        }
        revealPrivate = env["RUNWAY_LOG_PRIVATE"] == "1"
        #if os(Linux)
        var journal = false
        if mode == .auto || mode == .journal, access("/run/systemd/journal/socket", W_OK) == 0 {
            journalFD = socket(AF_UNIX, Int32(SOCK_DGRAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0)
            journal = journalFD >= 0
        }
        toStderr = mode == .stderr || (mode == .auto && (!journal || isatty(2) != 0))
        #elseif os(Windows)
        toStderr = mode == .stderr || mode == .auto
        #else
        toStderr = mode != .none
        #endif
    }

    func accepts(_ type: OSLogType) -> Bool { mode != .none }

    func emit(_ log: OSLog, _ type: OSLogType, _ message: OSLogMessage, priority: Int? = nil) {
        guard log.enabled, mode != .none else { return }
        write(log, type, message.rendered, priority: priority ?? type.priority)
    }

    func emitFormat(_ log: OSLog, _ type: OSLogType, _ format: String, _ args: [CVarArg]) {
        guard log.enabled, mode != .none else { return }
        write(log, type, LogSink.renderFormat(format, args, reveal: revealPrivate), priority: type.priority)
    }

    /// printf formatting with os_log's privacy annotations: `%{private}@`
    /// (and `{sensitive}`) redact, `%{public}@` and bare specifiers show.
    static func renderFormat(_ format: String, _ args: [CVarArg], reveal: Bool) -> String {
        var cleaned = ""
        var redact: [Bool] = []
        var i = format.startIndex
        while i < format.endIndex {
            let c = format[i]
            guard c == "%" else { cleaned.append(c); i = format.index(after: i); continue }
            var j = format.index(after: i)
            if j < format.endIndex, format[j] == "%" { cleaned += "%%"; i = format.index(after: j); continue }
            var annotation = ""
            if j < format.endIndex, format[j] == "{" {
                guard let close = format[j...].firstIndex(of: "}") else { cleaned.append(c); i = j; continue }
                annotation = String(format[format.index(after: j)..<close])
                j = format.index(after: close)
            }
            var spec = "%"
            while j < format.endIndex, !"diouxXeEfFgGaAcsSp@".contains(format[j]) { spec.append(format[j]); j = format.index(after: j) }
            if j < format.endIndex { spec.append(format[j]); j = format.index(after: j) }
            let conv = spec.last ?? "@"
            let words = annotation.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let isPublic = words.contains("public")
            let isPrivate = words.contains("private") || words.contains("sensitive")
            // Shown unless marked private, matching the interpolated form
            // (Apple also hides bare %@ in persisted logs; Runway's log is
            // the developer's own journal, so it doesn't).
            _ = isPublic; _ = conv
            redact.append(!reveal && isPrivate)
            cleaned += spec
            i = j
        }
        // Format each argument on its own, so redaction can replace it.
        var out = ""
        var argIndex = 0
        var k = cleaned.startIndex
        while k < cleaned.endIndex {
            let c = cleaned[k]
            guard c == "%" else { out.append(c); k = cleaned.index(after: k); continue }
            var j = cleaned.index(after: k)
            if j < cleaned.endIndex, cleaned[j] == "%" { out += "%"; k = cleaned.index(after: j); continue }
            var spec = "%"
            while j < cleaned.endIndex, !"diouxXeEfFgGaAcsSp@".contains(cleaned[j]) { spec.append(cleaned[j]); j = cleaned.index(after: j) }
            if j < cleaned.endIndex { spec.append(cleaned[j]); j = cleaned.index(after: j) }
            if argIndex < args.count {
                let hidden = argIndex < redact.count && redact[argIndex]
                out += hidden ? "<private>" : String(format: spec, args[argIndex])
            }
            argIndex += 1
            k = j
        }
        return out
    }

    func write(_ log: OSLog, _ type: OSLogType, _ text: String, priority: Int) {
        let record = _LogRecord(date: Date(), subsystem: log.subsystem, category: log.category, level: type, message: text)
        lock.lock()
        if ring.count < LogSink.ringCapacity { ring.append(record) } else { ring[ringHead] = record; ringHead = (ringHead + 1) % LogSink.ringCapacity }
        let obs = observer
        lock.unlock()
        obs?(record)

        #if os(Linux)
        if journalFD >= 0 { journal(record, priority: priority) }
        #elseif os(Windows)
        let line = "[\(log.subsystem):\(log.category)] \(text)\n"
        line.withCString(encodedAs: UTF16.self) { OutputDebugStringW($0) }
        #endif
        if toStderr, type.rank >= threshold {
            let scope = log.subsystem.isEmpty ? "" : " [\(log.subsystem):\(log.category)]"
            let line = "\(LogSink.timestamp(record.date)) \(processName)[\(pid)] <\(type.name)>\(scope) \(text)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    static func timestamp(_ d: Date) -> String {
        var t = time_t(d.timeIntervalSince1970)
        var tmv = tm()
        #if os(Windows)
        _ = localtime_s(&tmv, &t)
        #else
        localtime_r(&t, &tmv)
        #endif
        let ms = Int((d.timeIntervalSince1970 - Double(t)) * 1000)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", Int(tmv.tm_year) + 1900, Int(tmv.tm_mon) + 1, Int(tmv.tm_mday),
                      Int(tmv.tm_hour), Int(tmv.tm_min), Int(tmv.tm_sec), ms)
    }

    func records() -> [_LogRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(ring[ringHead...] + ring[..<ringHead])
    }

    #if os(Linux)
    /// The journal's native protocol: newline-separated FIELD=value, with
    /// MESSAGE in the length-prefixed form so it may contain newlines.
    private func journal(_ r: _LogRecord, priority: Int) {
        var d = Data()
        func field(_ k: String, _ v: String) { d.append(contentsOf: Array("\(k)=\(v.replacingOccurrences(of: "\n", with: " "))\n".utf8)) }
        d.append(contentsOf: Array("MESSAGE\n".utf8))
        let msg = Array(r.message.utf8)
        withUnsafeBytes(of: UInt64(msg.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: msg)
        d.append(0x0a)
        field("PRIORITY", String(priority))
        field("SYSLOG_IDENTIFIER", processName)
        if !r.subsystem.isEmpty { field("OS_SUBSYSTEM", r.subsystem) }
        if !r.category.isEmpty { field("OS_CATEGORY", r.category) }
        field("OS_LOG_TYPE", r.level.name)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array("/run/systemd/journal/socket".utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) }
        }
        _ = d.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(journalFD, buf.baseAddress, buf.count, Int32(MSG_NOSIGNAL), $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
    }
    #endif
}

/// Test and tooling hook: observe every message logged in this process.
public func _runwayObserveLog(_ observer: ((_LogRecord) -> Void)?) {
    LogSink.shared.observer = observer
}

/// This process's recent log entries (oldest first), for OSLogStore.
public func _runwayRecentLogRecords() -> [_LogRecord] { LogSink.shared.records() }
