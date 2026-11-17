// os_unfair_lock and OSAllocatedUnfairLock (futex / WaitOnAddress), and
// signposts, which Runway accepts and drops (there's no Instruments to read
// them; the intervals' work still runs).

import Foundation
import CRunwaySystem

// MARK: os_unfair_lock

public struct os_unfair_lock_s {
    public var _os_unfair_lock_opaque: UInt32
    public init() { _os_unfair_lock_opaque = 0 }
    public init(_os_unfair_lock_opaque: UInt32) { self._os_unfair_lock_opaque = _os_unfair_lock_opaque }
}

public typealias os_unfair_lock = os_unfair_lock_s
public typealias os_unfair_lock_t = UnsafeMutablePointer<os_unfair_lock_s>

@inline(__always)
private func word(_ lock: os_unfair_lock_t) -> UnsafeMutablePointer<UInt32> {
    UnsafeMutableRawPointer(lock).assumingMemoryBound(to: UInt32.self)
}

public func os_unfair_lock_lock(_ lock: os_unfair_lock_t) { runway_unfair_lock_lock(word(lock)) }
public func os_unfair_lock_trylock(_ lock: os_unfair_lock_t) -> Bool { runway_unfair_lock_trylock(word(lock)) != 0 }
public func os_unfair_lock_unlock(_ lock: os_unfair_lock_t) { runway_unfair_lock_unlock(word(lock)) }
/// Ownership isn't tracked; these assert only that the lock is (or isn't) held.
public func os_unfair_lock_assert_owner(_ lock: os_unfair_lock_t) {
    precondition(runway_unfair_lock_is_locked(word(lock)) != 0, "os_unfair_lock not owned")
}
public func os_unfair_lock_assert_not_owner(_ lock: os_unfair_lock_t) {}

// MARK: OSAllocatedUnfairLock

public struct OSAllocatedUnfairLock<State>: @unchecked Sendable {
    final class Storage {
        let word: UnsafeMutablePointer<UInt32> = {
            let p = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
            p.initialize(to: 0)
            return p
        }()
        var state: State
        init(_ s: State) { state = s }
        deinit { word.deallocate() }
    }
    let storage: Storage

    public init(uncheckedState initialState: State) { storage = Storage(initialState) }
    public init(initialState: State) { storage = Storage(initialState) }

    @inline(__always) func acquire() { runway_unfair_lock_lock(storage.word) }
    @inline(__always) func tryAcquire() -> Bool { runway_unfair_lock_trylock(storage.word) != 0 }
    @inline(__always) func release() { runway_unfair_lock_unlock(storage.word) }

    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        acquire(); defer { release() }
        return try body(&storage.state)
    }
    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        acquire(); defer { release() }
        return try body(&storage.state)
    }
    public func withLockIfAvailableUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R? {
        guard tryAcquire() else { return nil }
        defer { release() }
        return try body(&storage.state)
    }
    public func withLockIfAvailable<R>(_ body: (inout State) throws -> R) rethrows -> R? {
        guard tryAcquire() else { return nil }
        defer { release() }
        return try body(&storage.state)
    }

    public enum Ownership: Hashable, Sendable {
        case owner
        case notOwner
    }

    public func precondition(_ condition: Ownership) {
        if condition == .owner {
            Swift.precondition(runway_unfair_lock_is_locked(storage.word) != 0, "lock not owned")
        }
    }
}

extension OSAllocatedUnfairLock where State == () {
    public init() { storage = Storage(()) }
    public func lock() { acquire() }
    public func unlock() { release() }
    public func lockIfAvailable() -> Bool { tryAcquire() }
    public func withLockUnchecked<R>(_ body: () throws -> R) rethrows -> R {
        acquire(); defer { release() }
        return try body()
    }
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        acquire(); defer { release() }
        return try body()
    }
}

// MARK: Signposts

public struct OSSignpostID: Comparable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(_ value: UInt64) { rawValue = value }
    public init(log: OSLog) { rawValue = OSSignpostID.next() }
    public init(log: OSLog, object: AnyObject) { rawValue = UInt64(UInt(bitPattern: ObjectIdentifier(object).hashValue)) }
    public static let exclusive = OSSignpostID(0xEEEEB0B5B2B2EEEE)
    public static let invalid = OSSignpostID(~0)
    public static let null = OSSignpostID(0)
    public static func < (a: OSSignpostID, b: OSSignpostID) -> Bool { a.rawValue < b.rawValue }

    private static let counter = OSAllocatedUnfairLock(initialState: UInt64(1))
    static func next() -> UInt64 { counter.withLock { v in v += 1; return v } }
}

public struct OSSignpostType: Equatable, RawRepresentable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let event = OSSignpostType(rawValue: 0)
    public static let begin = OSSignpostType(rawValue: 1)
    public static let end = OSSignpostType(rawValue: 2)
}

public func os_signpost(_ type: OSSignpostType, dso: UnsafeRawPointer = #dsohandle, log: OSLog, name: StaticString,
                        signpostID: OSSignpostID = .exclusive) {}
public func os_signpost(_ type: OSSignpostType, dso: UnsafeRawPointer = #dsohandle, log: OSLog, name: StaticString,
                        signpostID: OSSignpostID = .exclusive, _ format: StaticString, _ arguments: CVarArg...) {}
public func os_signpost(_ type: OSSignpostType, dso: UnsafeRawPointer = #dsohandle, log: OSLog, name: StaticString,
                        signpostID: OSSignpostID = .exclusive, _ message: OSLogMessage) {}

public struct OSSignpostIntervalState: Codable, Sendable {
    public let signpostID: OSSignpostID
    init(_ id: OSSignpostID) { signpostID = id }
    public static func beginState(id: OSSignpostID) -> OSSignpostIntervalState { .init(id) }
    public init(from decoder: Decoder) throws { signpostID = OSSignpostID(try decoder.singleValueContainer().decode(UInt64.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(signpostID.rawValue) }
}

public struct OSSignpostError: Error, Hashable, Codable, Sendable {
    public enum Code: Int, Codable, Sendable { case doubleEnd }
    public let code: Code
}

public struct OSSignposter: @unchecked Sendable {
    public let logHandle: OSLog
    public init(subsystem: String, category: String) { logHandle = OSLog(subsystem: subsystem, category: category) }
    public init(subsystem: String, category: OSLog.Category) { logHandle = OSLog(subsystem: subsystem, category: category) }
    public init(logger: Logger) { logHandle = logger.logObject }
    public init(logHandle: OSLog) { self.logHandle = logHandle }
    public init() { logHandle = .default }
    public static let disabled = OSSignposter(logHandle: .disabled)

    public var isEnabled: Bool { false }
    public func makeSignpostID() -> OSSignpostID { OSSignpostID(OSSignpostID.next()) }
    public func makeSignpostID(from object: AnyObject) -> OSSignpostID { OSSignpostID(log: logHandle, object: object) }

    public func emitEvent(_ name: StaticString, id: OSSignpostID = .exclusive) {}
    public func emitEvent(_ name: StaticString, id: OSSignpostID = .exclusive, _ message: OSLogMessage) {}
    public func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive) -> OSSignpostIntervalState { .init(id) }
    public func beginInterval(_ name: StaticString, id: OSSignpostID = .exclusive, _ message: OSLogMessage) -> OSSignpostIntervalState { .init(id) }
    public func beginAnimationInterval(_ name: StaticString, id: OSSignpostID = .exclusive) -> OSSignpostIntervalState { .init(id) }
    public func beginAnimationInterval(_ name: StaticString, id: OSSignpostID = .exclusive, _ message: OSLogMessage) -> OSSignpostIntervalState { .init(id) }
    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {}
    public func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState, _ message: OSLogMessage) {}
    public func withIntervalSignpost<T>(_ name: StaticString, id: OSSignpostID = .exclusive, around task: () throws -> T) rethrows -> T { try task() }
    public func withIntervalSignpost<T>(_ name: StaticString, id: OSSignpostID = .exclusive, _ message: OSLogMessage,
                                        around task: () throws -> T) rethrows -> T { try task() }
}
