// OSLog: os's logging plus OSLogStore. The current-process store returns
// this process's recent entries (the last 1000, held in memory by `os`);
// the system store and log archives aren't readable (as for a sandboxed
// Mac app), so those initializers throw.

@_exported import os
import Foundation

public let OSLogErrorDomain = "OSLogErrorDomain"

open class OSLogPosition: NSObject, @unchecked Sendable {
    let date: Date
    init(date: Date) { self.date = date }
}

open class OSLogEntry: NSObject, @unchecked Sendable {
    public enum StoreCategory: Int, Sendable {
        case undefined, metadata, shortTerm, longTermAuto, longTerm1, longTerm3, longTerm7, longTerm14, longTerm30
    }
    open var composedMessage: String { _message }
    open var date: Date { _date }
    open var storeCategory: StoreCategory { .shortTerm }
    let _message: String
    let _date: Date
    init(message: String, date: Date) { _message = message; _date = date }
}

public protocol OSLogEntryFromProcess {
    var activityIdentifier: os_activity_id_t { get }
    var process: String { get }
    var processIdentifier: pid_t { get }
    var sender: String { get }
    var threadIdentifier: UInt64 { get }
}

public protocol OSLogEntryWithPayload {
    var components: [OSLogMessageComponent] { get }
    var formatString: String { get }
    var subsystem: String { get }
    var category: String { get }
}

public typealias os_activity_id_t = UInt64

open class OSLogMessageComponent: NSObject, @unchecked Sendable {
    public enum ArgumentCategory: Int, Sendable { case undefined, data, double, signed, string, unsigned }
    open var formatSubstring: String { "" }
    open var placeholder: String { "" }
    open var argumentCategory: ArgumentCategory { .undefined }
}

public final class OSLogEntryLog: OSLogEntry, OSLogEntryFromProcess, OSLogEntryWithPayload, @unchecked Sendable {
    public enum Level: Int, Sendable { case undefined, debug, info, notice, error, fault }
    public let level: Level
    public let subsystem: String
    public let category: String
    public var process: String { ProcessInfo.processInfo.processName }
    public var processIdentifier: pid_t { pid_t(ProcessInfo.processInfo.processIdentifier) }
    public var sender: String { process }
    public var threadIdentifier: UInt64 { 0 }
    public var activityIdentifier: os_activity_id_t { 0 }
    public var formatString: String { composedMessage }
    public var components: [OSLogMessageComponent] { [] }

    init(_ r: _LogRecord) {
        switch r.level {
        case .debug: level = .debug
        case .info: level = .info
        case .error: level = .error
        case .fault: level = .fault
        default: level = .notice
        }
        subsystem = r.subsystem
        category = r.category
        super.init(message: r.message, date: r.date)
    }
}

public final class OSLogStore: NSObject, @unchecked Sendable {
    public enum Scope: Int, Sendable {
        case system = 0
        case currentProcessIdentifier = 1
    }

    public struct EnumeratorOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let reverse = EnumeratorOptions(rawValue: 1)
    }

    private override init() {}

    public convenience init(scope: Scope) throws {
        guard scope == .currentProcessIdentifier else { throw OSLogStore.unavailable() }
        self.init()
    }

    public static func local() throws -> OSLogStore { throw unavailable() }
    public convenience init(url: URL) throws { throw OSLogStore.unavailable() }

    static func unavailable() -> NSError {
        NSError(domain: OSLogErrorDomain, code: 10, userInfo: [NSLocalizedDescriptionKey: "The system log store isn't available on this platform."])
    }

    public func position(date: Date) -> OSLogPosition { OSLogPosition(date: date) }
    public func position(timeIntervalSinceEnd: TimeInterval) -> OSLogPosition { OSLogPosition(date: Date().addingTimeInterval(timeIntervalSinceEnd)) }
    public func position(timeIntervalSinceLatestBoot: TimeInterval) -> OSLogPosition {
        OSLogPosition(date: Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime + timeIntervalSinceLatestBoot))
    }

    /// Predicates are evaluated per entry (block and value predicates: this
    /// Foundation has no `NSPredicate(format:)`).
    public func getEntries(with options: EnumeratorOptions = [], at position: OSLogPosition? = nil,
                           matching predicate: NSPredicate? = nil) throws -> AnySequence<OSLogEntry> {
        var entries: [OSLogEntry] = _runwayRecentLogRecords()
            .filter { position == nil || $0.date >= position!.date }
            .map(OSLogEntryLog.init)
        if let predicate { entries = entries.filter { predicate.evaluate(with: $0) } }
        if options.contains(.reverse) { entries.reverse() }
        return AnySequence(entries)
    }
}
