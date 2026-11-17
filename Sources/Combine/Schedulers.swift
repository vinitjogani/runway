// Scheduler and its conformances: ImmediateScheduler, DispatchQueue,
// RunLoop, OperationQueue. On Linux and Windows the main run loop's work goes
// through the main dispatch queue, which corelibs' RunLoop.main drains and
// Runway's UI backends service from their native loops.

import Foundation
import Dispatch

public protocol SchedulerTimeIntervalConvertible {
    static func seconds(_ s: Int) -> Self
    static func seconds(_ s: Double) -> Self
    static func milliseconds(_ ms: Int) -> Self
    static func microseconds(_ us: Int) -> Self
    static func nanoseconds(_ ns: Int) -> Self
}

public protocol Scheduler<SchedulerTimeType> {
    associatedtype SchedulerTimeType: Strideable where SchedulerTimeType.Stride: SchedulerTimeIntervalConvertible
    associatedtype SchedulerOptions
    var now: SchedulerTimeType { get }
    var minimumTolerance: SchedulerTimeType.Stride { get }
    func schedule(options: SchedulerOptions?, _ action: @escaping () -> Void)
    func schedule(after date: SchedulerTimeType, tolerance: SchedulerTimeType.Stride, options: SchedulerOptions?, _ action: @escaping () -> Void)
    func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, tolerance: SchedulerTimeType.Stride,
                  options: SchedulerOptions?, _ action: @escaping () -> Void) -> Cancellable
}

extension Scheduler {
    public func schedule(after date: SchedulerTimeType, _ action: @escaping () -> Void) {
        schedule(after: date, tolerance: minimumTolerance, options: nil, action)
    }
    public func schedule(_ action: @escaping () -> Void) { schedule(options: nil, action) }
    public func schedule(after date: SchedulerTimeType, tolerance: SchedulerTimeType.Stride, _ action: @escaping () -> Void) {
        schedule(after: date, tolerance: tolerance, options: nil, action)
    }
    public func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, tolerance: SchedulerTimeType.Stride,
                         _ action: @escaping () -> Void) -> Cancellable {
        schedule(after: date, interval: interval, tolerance: tolerance, options: nil, action)
    }
    public func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, _ action: @escaping () -> Void) -> Cancellable {
        schedule(after: date, interval: interval, tolerance: minimumTolerance, action)
    }
}

// MARK: ImmediateScheduler

public struct ImmediateScheduler: Scheduler, Sendable {
    public struct SchedulerTimeType: Strideable, Sendable {
        public struct Stride: ExpressibleByFloatLiteral, Comparable, SignedNumeric, Codable, SchedulerTimeIntervalConvertible, Sendable {
            public typealias FloatLiteralType = Double
            public typealias IntegerLiteralType = Int
            public typealias Magnitude = Int
            public var magnitude: Int
            public init(_ value: Int) { magnitude = value }
            public init(integerLiteral value: Int) { magnitude = value }
            public init(floatLiteral value: Double) { magnitude = Int(value) }
            public init?<T: BinaryInteger>(exactly source: T) { guard let v = Int(exactly: source) else { return nil }; magnitude = v }
            public static func < (lhs: Stride, rhs: Stride) -> Bool { lhs.magnitude < rhs.magnitude }
            public static func * (lhs: Stride, rhs: Stride) -> Stride { .init(lhs.magnitude * rhs.magnitude) }
            public static func + (lhs: Stride, rhs: Stride) -> Stride { .init(lhs.magnitude + rhs.magnitude) }
            public static func - (lhs: Stride, rhs: Stride) -> Stride { .init(lhs.magnitude - rhs.magnitude) }
            public static func *= (lhs: inout Stride, rhs: Stride) { lhs = lhs * rhs }
            public static func += (lhs: inout Stride, rhs: Stride) { lhs = lhs + rhs }
            public static func -= (lhs: inout Stride, rhs: Stride) { lhs = lhs - rhs }
            public static func seconds(_ s: Int) -> Stride { .init(0) }
            public static func seconds(_ s: Double) -> Stride { .init(0) }
            public static func milliseconds(_ ms: Int) -> Stride { .init(0) }
            public static func microseconds(_ us: Int) -> Stride { .init(0) }
            public static func nanoseconds(_ ns: Int) -> Stride { .init(0) }
        }
        public func distance(to other: SchedulerTimeType) -> Stride { .init(0) }
        public func advanced(by n: Stride) -> SchedulerTimeType { self }
    }
    public typealias SchedulerOptions = Never
    public static let shared = ImmediateScheduler()
    public var now: SchedulerTimeType { SchedulerTimeType() }
    public var minimumTolerance: SchedulerTimeType.Stride { .init(0) }
    public func schedule(options: Never?, _ action: @escaping () -> Void) { action() }
    public func schedule(after date: SchedulerTimeType, tolerance: SchedulerTimeType.Stride, options: Never?, _ action: @escaping () -> Void) { action() }
    public func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, tolerance: SchedulerTimeType.Stride,
                         options: Never?, _ action: @escaping () -> Void) -> Cancellable {
        action()
        return AnyCancellable {}
    }
}

// MARK: DispatchQueue

extension DispatchQueue: Scheduler {
    public struct SchedulerTimeType: Strideable, Codable, Hashable, @unchecked Sendable {
        public var dispatchTime: DispatchTime
        public init(_ time: DispatchTime) { dispatchTime = time }

        public func distance(to other: SchedulerTimeType) -> Stride {
            let a = dispatchTime.uptimeNanoseconds, b = other.dispatchTime.uptimeNanoseconds
            return Stride(.nanoseconds(b >= a ? Int(clamping: b - a) : -Int(clamping: a - b)))
        }
        public func advanced(by n: Stride) -> SchedulerTimeType {
            let base = Int64(clamping: dispatchTime.uptimeNanoseconds)
            let t = Swift.max(0, base &+ Int64(n.magnitude))
            return SchedulerTimeType(DispatchTime(uptimeNanoseconds: UInt64(t)))
        }
        public init(from decoder: Decoder) throws {
            dispatchTime = DispatchTime(uptimeNanoseconds: try decoder.singleValueContainer().decode(UInt64.self))
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(dispatchTime.uptimeNanoseconds)
        }
        public func hash(into hasher: inout Hasher) { hasher.combine(dispatchTime.uptimeNanoseconds) }
        public static func == (lhs: SchedulerTimeType, rhs: SchedulerTimeType) -> Bool {
            lhs.dispatchTime.uptimeNanoseconds == rhs.dispatchTime.uptimeNanoseconds
        }

        public struct Stride: SchedulerTimeIntervalConvertible, Comparable, SignedNumeric, ExpressibleByFloatLiteral, Hashable, Codable, Sendable {
            public typealias FloatLiteralType = Double
            public typealias IntegerLiteralType = Int
            public typealias Magnitude = Int
            /// Nanoseconds.
            public var magnitude: Int

            public var timeInterval: DispatchTimeInterval { .nanoseconds(magnitude) }

            public init(_ timeInterval: DispatchTimeInterval) {
                switch timeInterval {
                case .seconds(let s): magnitude = s.multipliedReportingOverflow(by: 1_000_000_000).overflow ? .max : s * 1_000_000_000
                case .milliseconds(let ms): magnitude = ms * 1_000_000
                case .microseconds(let us): magnitude = us * 1_000
                case .nanoseconds(let ns): magnitude = ns
                case .never: magnitude = .max
                @unknown default: magnitude = .max
                }
            }
            public init(_ timeInterval: Double) { magnitude = Int((timeInterval * 1_000_000_000).rounded()) }
            public init(floatLiteral value: Double) { self.init(value) }
            /// Seconds, as Apple's.
            public init(integerLiteral value: Int) { self.init(.seconds(value)) }
            public init?<T: BinaryInteger>(exactly source: T) {
                guard let s = Int(exactly: source) else { return nil }
                self.init(.seconds(s))
            }
            private init(ns: Int) { magnitude = ns }

            public static func < (lhs: Stride, rhs: Stride) -> Bool { lhs.magnitude < rhs.magnitude }
            public static func * (lhs: Stride, rhs: Stride) -> Stride { Stride(Double(lhs.magnitude) * Double(rhs.magnitude) / 1e18) }
            public static func + (lhs: Stride, rhs: Stride) -> Stride { Stride(ns: lhs.magnitude &+ rhs.magnitude) }
            public static func - (lhs: Stride, rhs: Stride) -> Stride { Stride(ns: lhs.magnitude &- rhs.magnitude) }
            public static func -= (lhs: inout Stride, rhs: Stride) { lhs = lhs - rhs }
            public static func *= (lhs: inout Stride, rhs: Stride) { lhs = lhs * rhs }
            public static func += (lhs: inout Stride, rhs: Stride) { lhs = lhs + rhs }

            public static func seconds(_ s: Double) -> Stride { Stride(s) }
            public static func seconds(_ s: Int) -> Stride { Stride(.seconds(s)) }
            public static func milliseconds(_ ms: Int) -> Stride { Stride(.milliseconds(ms)) }
            public static func microseconds(_ us: Int) -> Stride { Stride(.microseconds(us)) }
            public static func nanoseconds(_ ns: Int) -> Stride { Stride(.nanoseconds(ns)) }
        }
    }

    public struct SchedulerOptions: @unchecked Sendable {
        public var qos: DispatchQoS
        public var flags: DispatchWorkItemFlags
        public var group: DispatchGroup?
        public init(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], group: DispatchGroup? = nil) {
            self.qos = qos; self.flags = flags; self.group = group
        }
    }

    public var now: SchedulerTimeType { SchedulerTimeType(.now()) }
    public var minimumTolerance: SchedulerTimeType.Stride { SchedulerTimeType.Stride(.nanoseconds(0)) }

    public func schedule(options: SchedulerOptions?, _ action: @escaping () -> Void) {
        let o = options ?? SchedulerOptions()
        async(group: o.group, qos: o.qos, flags: o.flags, execute: action)
    }

    public func schedule(after date: SchedulerTimeType, tolerance: SchedulerTimeType.Stride, options: SchedulerOptions?, _ action: @escaping () -> Void) {
        let o = options ?? SchedulerOptions()
        asyncAfter(deadline: date.dispatchTime, qos: o.qos, flags: o.flags, execute: action)
    }

    public func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, tolerance: SchedulerTimeType.Stride,
                         options: SchedulerOptions?, _ action: @escaping () -> Void) -> Cancellable {
        let timer = DispatchSource.makeTimerSource(queue: self)
        timer.setEventHandler(handler: action)
        timer.schedule(deadline: date.dispatchTime, repeating: interval.timeInterval, leeway: tolerance.timeInterval)
        timer.resume()
        return AnyCancellable { timer.cancel() }
    }
}

// MARK: RunLoop, OperationQueue

extension RunLoop: Scheduler {
    public struct SchedulerTimeType: Strideable, Codable, Hashable, Sendable {
        public var date: Date
        public init(_ date: Date) { self.date = date }
        public func distance(to other: SchedulerTimeType) -> Stride { Stride(other.date.timeIntervalSince(date)) }
        public func advanced(by n: Stride) -> SchedulerTimeType { SchedulerTimeType(date.addingTimeInterval(n.magnitude)) }

        public struct Stride: ExpressibleByFloatLiteral, Comparable, SignedNumeric, Codable, Hashable, SchedulerTimeIntervalConvertible, Sendable {
            public typealias FloatLiteralType = TimeInterval
            public typealias IntegerLiteralType = TimeInterval
            public typealias Magnitude = TimeInterval
            public var magnitude: TimeInterval
            public var timeInterval: TimeInterval { magnitude }
            public init(integerLiteral value: TimeInterval) { magnitude = value }
            public init(floatLiteral value: TimeInterval) { magnitude = value }
            public init(_ timeInterval: TimeInterval) { magnitude = timeInterval }
            public init?<T: BinaryInteger>(exactly source: T) { guard let v = Double(exactly: source) else { return nil }; magnitude = v }
            public static func < (lhs: Stride, rhs: Stride) -> Bool { lhs.magnitude < rhs.magnitude }
            public static func * (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude * rhs.magnitude) }
            public static func + (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude + rhs.magnitude) }
            public static func - (lhs: Stride, rhs: Stride) -> Stride { Stride(lhs.magnitude - rhs.magnitude) }
            public static func -= (lhs: inout Stride, rhs: Stride) { lhs = lhs - rhs }
            public static func *= (lhs: inout Stride, rhs: Stride) { lhs = lhs * rhs }
            public static func += (lhs: inout Stride, rhs: Stride) { lhs = lhs + rhs }
            public static func seconds(_ s: Int) -> Stride { Stride(Double(s)) }
            public static func seconds(_ s: Double) -> Stride { Stride(s) }
            public static func milliseconds(_ ms: Int) -> Stride { Stride(Double(ms) / 1e3) }
            public static func microseconds(_ us: Int) -> Stride { Stride(Double(us) / 1e6) }
            public static func nanoseconds(_ ns: Int) -> Stride { Stride(Double(ns) / 1e9) }
        }
    }

    public struct SchedulerOptions: Sendable {}

    public var now: SchedulerTimeType { SchedulerTimeType(Date()) }
    public var minimumTolerance: SchedulerTimeType.Stride { 0.0 }

    public func schedule(options: SchedulerOptions?, _ action: @escaping () -> Void) {
        if self === RunLoop.main { DispatchQueue.main.async(execute: action); return }
        let t = Timer(fire: Date(), interval: 0, repeats: false) { _ in action() }
        add(t, forMode: .default)
    }

    public func schedule(after date: SchedulerTimeType, tolerance: SchedulerTimeType.Stride, options: SchedulerOptions?, _ action: @escaping () -> Void) {
        if self === RunLoop.main {
            DispatchQueue.main.asyncAfter(deadline: .now() + Swift.max(0, date.date.timeIntervalSinceNow), execute: action)
            return
        }
        let t = Timer(fire: date.date, interval: 0, repeats: false) { _ in action() }
        t.tolerance = tolerance.magnitude
        add(t, forMode: .default)
    }

    public func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, tolerance: SchedulerTimeType.Stride,
                         options: SchedulerOptions?, _ action: @escaping () -> Void) -> Cancellable {
        if self === RunLoop.main {
            return DispatchQueue.main.schedule(after: .init(.now() + Swift.max(0, date.date.timeIntervalSinceNow)),
                                               interval: .init(interval.magnitude), tolerance: .init(tolerance.magnitude), action)
        }
        let t = Timer(fire: date.date, interval: interval.magnitude, repeats: true) { _ in action() }
        t.tolerance = tolerance.magnitude
        add(t, forMode: .default)
        return AnyCancellable { t.invalidate() }
    }
}

extension OperationQueue: Scheduler {
    public typealias SchedulerTimeType = RunLoop.SchedulerTimeType
    public struct SchedulerOptions: Sendable {}

    public var now: SchedulerTimeType { SchedulerTimeType(Date()) }
    public var minimumTolerance: SchedulerTimeType.Stride { 0.0 }

    public func schedule(options: SchedulerOptions?, _ action: @escaping () -> Void) { addOperation(action) }

    public func schedule(after date: SchedulerTimeType, tolerance: SchedulerTimeType.Stride, options: SchedulerOptions?, _ action: @escaping () -> Void) {
        let q = self
        DispatchQueue.global().asyncAfter(deadline: .now() + Swift.max(0, date.date.timeIntervalSinceNow)) { q.addOperation(action) }
    }

    public func schedule(after date: SchedulerTimeType, interval: SchedulerTimeType.Stride, tolerance: SchedulerTimeType.Stride,
                         options: SchedulerOptions?, _ action: @escaping () -> Void) -> Cancellable {
        let q = self
        return DispatchQueue.global().schedule(after: .init(.now() + Swift.max(0, date.date.timeIntervalSinceNow)),
                                               interval: .init(interval.magnitude), tolerance: .init(tolerance.magnitude)) { q.addOperation(action) }
    }
}
