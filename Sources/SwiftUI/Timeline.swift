// TimelineView (content redrawn on a schedule) and onReceive (an action for
// each value a Combine publisher sends while the view is shown).

import Foundation
import Combine

// MARK: Schedules

/// When a timeline view updates.
public protocol TimelineSchedule {
    /// The first update time after `date`; nil: no more updates.
    func nextDate(after date: Date) -> Date?
}

public struct PeriodicTimelineSchedule: TimelineSchedule, Sendable {
    let start: Date
    let interval: TimeInterval
    public init(from startDate: Date, by interval: TimeInterval) { start = startDate; self.interval = max(interval, 1.0 / 120) }
    public func nextDate(after date: Date) -> Date? {
        guard date >= start else { return start }
        let n = ((date.timeIntervalSince(start)) / interval).rounded(.down) + 1
        return start.addingTimeInterval(n * interval)
    }
}
public struct EveryMinuteTimelineSchedule: TimelineSchedule, Sendable {
    public init() {}
    public func nextDate(after date: Date) -> Date? {
        let t = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 60).rounded(.down) * 60 + 60)
    }
}
public struct AnimationTimelineSchedule: TimelineSchedule, Sendable {
    let minimumInterval: TimeInterval
    let paused: Bool
    public init(minimumInterval: Double? = nil, paused: Bool = false) { self.minimumInterval = minimumInterval ?? 1.0 / 60; self.paused = paused }
    public func nextDate(after date: Date) -> Date? { paused ? nil : date.addingTimeInterval(minimumInterval) }
}
public struct ExplicitTimelineSchedule<Entries: Sequence>: TimelineSchedule where Entries.Element == Date {
    let dates: Entries
    public init(_ dates: Entries) { self.dates = dates }
    public func nextDate(after date: Date) -> Date? { dates.filter { $0 > date }.min() }
}

extension TimelineSchedule where Self == PeriodicTimelineSchedule {
    public static func periodic(from startDate: Date, by interval: TimeInterval) -> PeriodicTimelineSchedule {
        PeriodicTimelineSchedule(from: startDate, by: interval)
    }
}
extension TimelineSchedule where Self == EveryMinuteTimelineSchedule {
    public static var everyMinute: EveryMinuteTimelineSchedule { EveryMinuteTimelineSchedule() }
}
extension TimelineSchedule where Self == AnimationTimelineSchedule {
    public static var animation: AnimationTimelineSchedule { AnimationTimelineSchedule() }
    public static func animation(minimumInterval: Double? = nil, paused: Bool = false) -> AnimationTimelineSchedule {
        AnimationTimelineSchedule(minimumInterval: minimumInterval, paused: paused)
    }
}
extension TimelineSchedule {
    public static func explicit<S: Sequence>(_ dates: S) -> ExplicitTimelineSchedule<S> where Self == ExplicitTimelineSchedule<S> {
        ExplicitTimelineSchedule(dates)
    }
}

// MARK: TimelineView

/// Content rebuilt at each of the schedule's dates.
public struct TimelineView<Schedule: TimelineSchedule, Content: View>: View {
    public typealias Context = TimelineViewContext
    let schedule: Schedule
    let content: (Context) -> Content
    @State private var date = Date()

    public init(_ schedule: Schedule, @ViewBuilder content: @escaping (Context) -> Content) {
        self.schedule = schedule
        self.content = content
    }

    public var body: some View {
        let schedule = UncheckedSchedule(schedule: schedule)
        let date = $date
        return content(Context(date: self.date, cadence: .live))
            .task {
                while !Task.isCancelled {
                    let now = Date()
                    guard let next = schedule.schedule.nextDate(after: now) else { return }
                    let wait = max(0.001, next.timeIntervalSince(now))
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    if Task.isCancelled { return }
                    date.wrappedValue = Date()
                }
            }
    }
}
private struct UncheckedSchedule<S: TimelineSchedule>: @unchecked Sendable { let schedule: S }

/// A common context lets Swift infer a timeline's content independently of the
/// closure parameter, including when the closure starts with local bindings.
public struct TimelineViewContext {
    public enum Cadence: Comparable, Sendable { case live, seconds, minutes }
    public let date: Date
    public let cadence: Cadence
    public func invalidateTimelineContent() {}
}

public typealias TimelineViewDefaultContext = TimelineViewContext

// MARK: onReceive

private final class ReceiveBox<P: Publisher>: @unchecked Sendable where P.Failure == Never {
    let publisher: P
    let action: (P.Output) -> Void
    init(_ p: P, _ a: @escaping (P.Output) -> Void) { publisher = p; action = a }
}

extension View {
    /// Runs `action` with each value `publisher` sends while the view is
    /// shown (on the main actor).
    public func onReceive<P: Publisher>(_ publisher: P, perform action: @escaping (P.Output) -> Void) -> some View where P.Failure == Never {
        let box = ReceiveBox(publisher, action)
        return nodes("receive") { ns, ctx in
            if !ctx.dryRun {
                ctx.host.task(ctx.path + "/receive", id: nil, priority: .userInitiated) { @MainActor in
                    var subscription: AnyCancellable?
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                            subscription = box.publisher.sink { value in
                                if Thread.isMainThread {
                                    MainActor.assumeIsolated { box.action(value) }
                                } else {
                                    let v = UncheckedValue(value)
                                    DispatchQueue.main.async { MainActor.assumeIsolated { box.action(v.value) } }
                                }
                            }
                            ReceiveTasks.hold(k, for: box)
                        }
                    } onCancel: {
                        ReceiveTasks.release(box)
                    }
                    subscription?.cancel()
                }
            }
            return ns
        }
    }
}
private struct UncheckedValue<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}

/// Continuations of live onReceive tasks, resumed when the task is cancelled.
private enum ReceiveTasks {
    nonisolated(unsafe) static var held: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    nonisolated(unsafe) static var released: Set<ObjectIdentifier> = []
    static let lock = NSLock()
    static func hold(_ k: CheckedContinuation<Void, Never>, for box: AnyObject) {
        let id = ObjectIdentifier(box)
        let already = lock.withLock { () -> Bool in
            if released.remove(id) != nil { return true }
            held[id] = k
            return false
        }
        if already { k.resume() }
    }
    static func release(_ box: AnyObject) {
        let id = ObjectIdentifier(box)
        let k = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let k = held.removeValue(forKey: id) { return k }
            released.insert(id)
            return nil
        }
        k?.resume()
    }
}
