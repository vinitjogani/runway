// Combine for Linux and Windows: Apple's API (Publisher, Subscriber,
// Subscription, Subjects, operators, schedulers, @Published and
// ObservableObject), implemented in Swift. Single-upstream operators pass
// demand through as Apple's do; operators that join several upstreams or
// hop schedulers request `.unlimited` upstream and buffer for the
// downstream's demand, so no value is ever lost or delivered unrequested.

@_exported import Foundation

// MARK: Core protocols

public protocol Publisher<Output, Failure> {
    associatedtype Output
    associatedtype Failure: Error
    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure
}

extension Publisher {
    public func subscribe<S: Subscriber>(_ subscriber: S) where S.Input == Output, S.Failure == Failure {
        receive(subscriber: subscriber)
    }
}

public protocol Subscriber<Input, Failure>: CustomCombineIdentifierConvertible {
    associatedtype Input
    associatedtype Failure: Error
    func receive(subscription: Subscription)
    func receive(_ input: Input) -> Subscribers.Demand
    func receive(completion: Subscribers.Completion<Failure>)
}

extension Subscriber where Input == Void {
    public func receive() -> Subscribers.Demand { receive(()) }
}

public protocol Cancellable {
    func cancel()
}

public protocol Subscription: Cancellable, CustomCombineIdentifierConvertible {
    func request(_ demand: Subscribers.Demand)
}

public struct CombineIdentifier: Hashable, CustomStringConvertible, Sendable {
    private static let counter = _Counter()
    private let value: UInt64
    public init() { value = CombineIdentifier.counter.next() }
    public init(_ obj: AnyObject) { value = UInt64(UInt(bitPattern: ObjectIdentifier(obj).hashValue)) }
    public var description: String { "0x" + String(value, radix: 16) }
}

final class _Counter: @unchecked Sendable {
    private var v: UInt64 = 0
    private let lock = NSLock()
    func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; v &+= 1; return v | (1 << 63) }
}

public protocol CustomCombineIdentifierConvertible {
    var combineIdentifier: CombineIdentifier { get }
}

extension CustomCombineIdentifierConvertible where Self: AnyObject {
    public var combineIdentifier: CombineIdentifier { CombineIdentifier(self) }
}

// MARK: Subscribers namespace

public enum Subscribers {}

extension Subscribers {
    public enum Completion<Failure: Error> {
        case finished
        case failure(Failure)
    }

    /// How many values a subscriber wants: a count, or unlimited.
    public struct Demand: Equatable, Comparable, Hashable, Codable, CustomStringConvertible, Sendable {
        // Saturating storage: `rawValue == UInt.max` means unlimited.
        let rawValue: UInt
        private init(raw: UInt) { rawValue = raw }

        public static let unlimited = Demand(raw: .max)
        public static let none = Demand(raw: 0)
        public static func max(_ value: Int) -> Demand {
            precondition(value >= 0, "demand must not be negative")
            return Demand(raw: UInt(value))
        }

        public var max: Int? { rawValue == .max ? nil : Int(rawValue) }
        public var description: String { rawValue == .max ? "unlimited" : "max(\(rawValue))" }

        public static func + (lhs: Demand, rhs: Demand) -> Demand {
            if lhs == .unlimited || rhs == .unlimited { return .unlimited }
            let (r, o) = lhs.rawValue.addingReportingOverflow(rhs.rawValue)
            return o || r == .max ? .unlimited : Demand(raw: r)
        }
        public static func += (lhs: inout Demand, rhs: Demand) { lhs = lhs + rhs }
        public static func + (lhs: Demand, rhs: Int) -> Demand {
            rhs < 0 ? lhs - Demand.max(-rhs) : lhs + Demand.max(rhs)
        }
        public static func += (lhs: inout Demand, rhs: Int) { lhs = lhs + rhs }
        public static func * (lhs: Demand, rhs: Int) -> Demand {
            if lhs == .unlimited { return .unlimited }
            precondition(rhs >= 0)
            let (r, o) = lhs.rawValue.multipliedReportingOverflow(by: UInt(rhs))
            return o || r == .max ? .unlimited : Demand(raw: r)
        }
        public static func *= (lhs: inout Demand, rhs: Int) { lhs = lhs * rhs }
        public static func - (lhs: Demand, rhs: Demand) -> Demand {
            if lhs == .unlimited { return .unlimited }
            if rhs == .unlimited { return .none }
            return Demand(raw: lhs.rawValue > rhs.rawValue ? lhs.rawValue - rhs.rawValue : 0)
        }
        public static func -= (lhs: inout Demand, rhs: Demand) { lhs = lhs - rhs }
        public static func - (lhs: Demand, rhs: Int) -> Demand {
            rhs < 0 ? lhs + Demand.max(-rhs) : lhs - Demand.max(rhs)
        }
        public static func -= (lhs: inout Demand, rhs: Int) { lhs = lhs - rhs }

        public static func < (lhs: Demand, rhs: Demand) -> Bool { lhs.rawValue < rhs.rawValue }
        /// -1, 0, 1 as a demand compares to a count (unlimited exceeds every count).
        private static func cmp(_ d: Demand, _ i: Int) -> Int {
            if d.rawValue == .max || i < 0 { return 1 }
            let u = UInt(i)
            return d.rawValue < u ? -1 : (d.rawValue == u ? 0 : 1)
        }
        public static func > (lhs: Demand, rhs: Int) -> Bool { cmp(lhs, rhs) > 0 }
        public static func >= (lhs: Demand, rhs: Int) -> Bool { cmp(lhs, rhs) >= 0 }
        public static func < (lhs: Demand, rhs: Int) -> Bool { cmp(lhs, rhs) < 0 }
        public static func <= (lhs: Demand, rhs: Int) -> Bool { cmp(lhs, rhs) <= 0 }
        public static func > (lhs: Int, rhs: Demand) -> Bool { cmp(rhs, lhs) < 0 }
        public static func >= (lhs: Int, rhs: Demand) -> Bool { cmp(rhs, lhs) <= 0 }
        public static func < (lhs: Int, rhs: Demand) -> Bool { cmp(rhs, lhs) > 0 }
        public static func <= (lhs: Int, rhs: Demand) -> Bool { cmp(rhs, lhs) >= 0 }
        public static func == (lhs: Demand, rhs: Int) -> Bool { cmp(lhs, rhs) == 0 && rhs >= 0 && lhs.rawValue != .max }
        public static func != (lhs: Demand, rhs: Int) -> Bool { !(lhs == rhs) }
        public static func == (lhs: Int, rhs: Demand) -> Bool { rhs == lhs }
        public static func != (lhs: Int, rhs: Demand) -> Bool { !(rhs == lhs) }
        public static func == (lhs: Demand, rhs: Int?) -> Bool { rhs.map { lhs == $0 } ?? (lhs == .unlimited) }
        public static func != (lhs: Demand, rhs: Int?) -> Bool { !(lhs == rhs) }
        public static func == (lhs: Int?, rhs: Demand) -> Bool { rhs == lhs }
        public static func != (lhs: Int?, rhs: Demand) -> Bool { !(rhs == lhs) }

        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UInt.self) }
        public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
    }
}

extension Subscribers.Completion: Equatable where Failure: Equatable {}
extension Subscribers.Completion: Hashable where Failure: Hashable {}
extension Subscribers.Completion: Sendable where Failure: Sendable {}
private enum _CompletionKeys: String, CodingKey { case success, error }

extension Subscribers.Completion: Encodable where Failure: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: _CompletionKeys.self)
        switch self {
        case .finished: try c.encode(true, forKey: .success)
        case .failure(let e): try c.encode(false, forKey: .success); try c.encode(e, forKey: .error)
        }
    }
}
extension Subscribers.Completion: Decodable where Failure: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: _CompletionKeys.self)
        self = try c.decode(Bool.self, forKey: .success) ? .finished : .failure(try c.decode(Failure.self, forKey: .error))
    }
}

extension Subscribers.Completion {
    func mapError<E: Error>(_ f: (Failure) -> E) -> Subscribers.Completion<E> {
        switch self { case .finished: return .finished; case .failure(let e): return .failure(f(e)) }
    }
    var eraseError: Subscribers.Completion<Error> { mapError { $0 } }
}

// MARK: Subscriptions

public enum Subscriptions {
    /// A subscription that does nothing: for publishers that complete at once.
    public static var empty: Subscription { _EmptySubscription.shared }
}

final class _EmptySubscription: Subscription, CustomStringConvertible, @unchecked Sendable {
    static let shared = _EmptySubscription()
    func request(_ demand: Subscribers.Demand) {}
    func cancel() {}
    var description: String { "Empty" }
}

// MARK: AnyCancellable

public final class AnyCancellable: Cancellable, Hashable, @unchecked Sendable {
    private var _cancel: (() -> Void)?
    private let lock = NSLock()

    public init(_ cancel: @escaping () -> Void) { _cancel = cancel }
    public init<C: Cancellable>(_ canceller: C) { _cancel = canceller.cancel }

    deinit { _cancel?() }

    public func cancel() {
        lock.lock()
        let c = _cancel
        _cancel = nil
        lock.unlock()
        c?()
    }

    public static func == (lhs: AnyCancellable, rhs: AnyCancellable) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    public func store<C: RangeReplaceableCollection>(in collection: inout C) where C.Element == AnyCancellable {
        collection.append(self)
    }
    public func store(in set: inout Set<AnyCancellable>) { set.insert(self) }
}

extension Cancellable {
    public func store<C: RangeReplaceableCollection>(in collection: inout C) where C.Element == AnyCancellable {
        AnyCancellable(self).store(in: &collection)
    }
    public func store(in set: inout Set<AnyCancellable>) { AnyCancellable(self).store(in: &set) }
}

// MARK: Type erasure

public struct AnySubscriber<Input, Failure: Error>: Subscriber, CustomStringConvertible, CustomReflectable, CustomPlaygroundDisplayConvertible {
    public let combineIdentifier: CombineIdentifier
    let receiveSubscriptionThunk: (Subscription) -> Void
    let receiveValueThunk: (Input) -> Subscribers.Demand
    let receiveCompletionThunk: (Subscribers.Completion<Failure>) -> Void
    let descriptionThunk: () -> String

    public init<S: Subscriber>(_ s: S) where Input == S.Input, Failure == S.Failure {
        if let erased = s as? AnySubscriber<Input, Failure> { self = erased; return }
        combineIdentifier = s.combineIdentifier
        receiveSubscriptionThunk = s.receive(subscription:)
        receiveValueThunk = s.receive(_:)
        receiveCompletionThunk = s.receive(completion:)
        descriptionThunk = { (s as? CustomStringConvertible)?.description ?? "\(type(of: s))" }
    }

    public init<S: Subject>(_ s: S) where Output == S.Output, Failure == S.Failure {
        combineIdentifier = CombineIdentifier()
        receiveSubscriptionThunk = { s.send(subscription: $0); $0.request(.unlimited) }
        receiveValueThunk = { s.send($0); return .none }
        receiveCompletionThunk = { s.send(completion: $0) }
        descriptionThunk = { "Subject" }
    }

    public init(receiveSubscription: ((Subscription) -> Void)? = nil,
                receiveValue: ((Input) -> Subscribers.Demand)? = nil,
                receiveCompletion: ((Subscribers.Completion<Failure>) -> Void)? = nil) {
        combineIdentifier = CombineIdentifier()
        receiveSubscriptionThunk = receiveSubscription ?? { _ in }
        receiveValueThunk = receiveValue ?? { _ in .none }
        receiveCompletionThunk = receiveCompletion ?? { _ in }
        descriptionThunk = { "Anonymous AnySubscriber" }
    }

    public typealias Output = Input
    public var description: String { descriptionThunk() }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
    public var playgroundDescription: Any { description }
    public func receive(subscription: Subscription) { receiveSubscriptionThunk(subscription) }
    public func receive(_ value: Input) -> Subscribers.Demand { receiveValueThunk(value) }
    public func receive(completion: Subscribers.Completion<Failure>) { receiveCompletionThunk(completion) }
}

@frozen
public struct AnyPublisher<Output, Failure: Error>: Publisher, CustomStringConvertible, CustomPlaygroundDisplayConvertible {
    let subscribeThunk: (AnySubscriber<Output, Failure>) -> Void

    public init<P: Publisher>(_ publisher: P) where Output == P.Output, Failure == P.Failure {
        if let erased = publisher as? AnyPublisher<Output, Failure> { self = erased; return }
        subscribeThunk = { publisher.receive(subscriber: $0) }
    }

    public var description: String { "AnyPublisher" }
    public var playgroundDescription: Any { description }

    public func receive<S: Subscriber>(subscriber: S) where Output == S.Input, Failure == S.Failure {
        subscribeThunk(AnySubscriber(subscriber))
    }
}

extension Publisher {
    public func eraseToAnyPublisher() -> AnyPublisher<Output, Failure> { AnyPublisher(self) }
}

extension Subscriber {
    func eraseToAnySubscriber() -> AnySubscriber<Input, Failure> { AnySubscriber(self) }
}

// MARK: Plumbing

/// A lock that's cheap and never held while calling out.
typealias _Lock = NSLock

/// The subscription a buffering operator hands its downstream: queues
/// values and the completion, and delivers them serially as demand allows.
final class _Conduit<Downstream: Subscriber>: Subscription, CustomStringConvertible, @unchecked Sendable {
    private let lock = _Lock()
    private var subscriber: Downstream?
    private var queue: [Downstream.Input] = []
    private var head = 0
    private var demand = Subscribers.Demand.none
    private var completion: Subscribers.Completion<Downstream.Failure>?
    private var terminated = false
    private var delivering = false
    var onCancel: (() -> Void)?
    var onRequest: ((Subscribers.Demand) -> Void)?
    let name: String

    init(_ subscriber: Downstream, name: String = "Conduit") {
        self.subscriber = subscriber
        self.name = name
    }

    var description: String { name }

    /// Hands this conduit to the downstream as its subscription.
    func start() { subscriber?.receive(subscription: self) }

    var isTerminated: Bool { lock.lock(); defer { lock.unlock() }; return terminated || completion != nil }
    var pendingDemand: Subscribers.Demand { lock.lock(); defer { lock.unlock() }; return demand }

    func send(_ value: Downstream.Input) {
        lock.lock()
        guard !terminated, completion == nil else { lock.unlock(); return }
        queue.append(value)
        lock.unlock()
        drain()
    }

    func finish(_ c: Subscribers.Completion<Downstream.Failure>) {
        lock.lock()
        guard !terminated, completion == nil else { lock.unlock(); return }
        completion = c
        lock.unlock()
        drain()
    }

    /// Fails at once, dropping anything queued (errors don't wait for demand).
    func fail(_ c: Subscribers.Completion<Downstream.Failure>) {
        lock.lock()
        guard !terminated, completion == nil else { lock.unlock(); return }
        queue.removeAll(); head = 0
        completion = c
        lock.unlock()
        drain()
    }

    /// Where deliveries prompted by `request` run (receive(on:) delivers
    /// on its scheduler, never on the requesting thread).
    var deliverVia: ((@escaping () -> Void) -> Void)?

    func request(_ d: Subscribers.Demand) {
        lock.lock()
        guard !terminated else { lock.unlock(); return }
        demand += d
        let via = deliverVia
        lock.unlock()
        onRequest?(d)
        if let via { via { self.drain() } } else { drain() }
    }

    func cancel() {
        lock.lock()
        guard !terminated else { lock.unlock(); return }
        terminated = true
        queue.removeAll(); head = 0
        subscriber = nil
        let c = onCancel
        onCancel = nil
        onRequest = nil
        lock.unlock()
        c?()
    }

    private func drain() {
        lock.lock()
        if delivering { lock.unlock(); return }
        delivering = true
        while !terminated {
            if head < queue.count, demand > 0, let s = subscriber {
                let v = queue[head]
                head += 1
                if head > 64, head * 2 > queue.count { queue.removeFirst(head); head = 0 }
                demand -= 1
                lock.unlock()
                let more = s.receive(v)
                lock.lock()
                demand += more
                continue
            }
            if head >= queue.count, let c = completion, let s = subscriber {
                terminated = true
                subscriber = nil
                let cancelHook = onCancel
                onCancel = nil
                onRequest = nil
                _ = cancelHook
                lock.unlock()
                s.receive(completion: c)
                lock.lock()
            }
            break
        }
        delivering = false
        lock.unlock()
    }
}

/// An upstream subscriber that forwards into closures (used by joining
/// operators to subscribe to each upstream with unlimited demand).
final class _ClosureSubscriber<Input, Failure: Error>: Subscriber, Cancellable, @unchecked Sendable {
    private let lock = _Lock()
    private var subscription: Subscription?
    private var cancelled = false
    let initialDemand: Subscribers.Demand
    let onValue: (Input) -> Subscribers.Demand
    let onCompletion: (Subscribers.Completion<Failure>) -> Void

    init(demand: Subscribers.Demand = .unlimited,
         _ onValue: @escaping (Input) -> Subscribers.Demand,
         _ onCompletion: @escaping (Subscribers.Completion<Failure>) -> Void) {
        initialDemand = demand
        self.onValue = onValue
        self.onCompletion = onCompletion
    }

    func receive(subscription s: Subscription) {
        lock.lock()
        if subscription != nil || cancelled { lock.unlock(); s.cancel(); return }
        subscription = s
        lock.unlock()
        if initialDemand > 0 { s.request(initialDemand) }
    }
    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        let live = !cancelled
        lock.unlock()
        return live ? onValue(input) : .none
    }
    func receive(completion: Subscribers.Completion<Failure>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        subscription = nil
        lock.unlock()
        onCompletion(completion)
    }
    func request(_ d: Subscribers.Demand) {
        lock.lock(); let s = subscription; lock.unlock()
        s?.request(d)
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let s = subscription
        subscription = nil
        lock.unlock()
        s?.cancel()
    }
}

/// What a pass-through operator does with one upstream value.
enum _Step<Output, Failure: Error> {
    case emit(Output)
    case skip
    case finish
    case emitAndFinish(Output)
    case fail(Failure)
}

/// The inner subscriber/subscription of a demand-passing operator.
final class _StepInner<Input, UpstreamFailure: Error, Downstream: Subscriber>: Subscriber, Subscription, CustomStringConvertible, @unchecked Sendable {
    typealias Failure = UpstreamFailure
    private let lock = _Lock()
    private let downstream: Downstream
    private var upstream: Subscription?
    private var done = false
    private let step: (Input) -> _Step<Downstream.Input, Downstream.Failure>
    private let complete: (Subscribers.Completion<UpstreamFailure>) -> Subscribers.Completion<Downstream.Failure>
    let description: String

    init(_ downstream: Downstream, name: String,
         step: @escaping (Input) -> _Step<Downstream.Input, Downstream.Failure>,
         complete: @escaping (Subscribers.Completion<UpstreamFailure>) -> Subscribers.Completion<Downstream.Failure>) {
        self.downstream = downstream
        self.step = step
        self.complete = complete
        description = name
    }

    func receive(subscription: Subscription) {
        lock.lock()
        if upstream != nil || done { lock.unlock(); subscription.cancel(); return }
        upstream = subscription
        lock.unlock()
        downstream.receive(subscription: self)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        guard !done else { lock.unlock(); return .none }
        lock.unlock()
        switch step(input) {
        case .emit(let v): return downstream.receive(v)
        case .skip: return .max(1)
        case .finish: terminate(.finished)
        case .emitAndFinish(let v):
            _ = downstream.receive(v)
            terminate(.finished)
        case .fail(let e): terminate(.failure(e))
        }
        return .none
    }

    private func terminate(_ c: Subscribers.Completion<Downstream.Failure>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let u = upstream
        upstream = nil
        lock.unlock()
        u?.cancel()
        downstream.receive(completion: c)
    }

    func receive(completion: Subscribers.Completion<UpstreamFailure>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        upstream = nil
        lock.unlock()
        downstream.receive(completion: complete(completion))
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock(); let u = upstream; lock.unlock()
        u?.request(demand)
    }

    func cancel() {
        lock.lock()
        done = true
        let u = upstream
        upstream = nil
        lock.unlock()
        u?.cancel()
    }
}

/// The inner of an operator that consumes its whole upstream (with
/// unlimited demand) and emits at most one value, at the end or early.
final class _ReduceInner<Input, UpstreamFailure: Error, Downstream: Subscriber>: Subscriber, Subscription, CustomStringConvertible, @unchecked Sendable {
    typealias Failure = UpstreamFailure
    enum Next { case `continue`, finish(Downstream.Input?), fail(Downstream.Failure) }

    private let lock = _Lock()
    private let downstream: Downstream
    private var upstream: Subscription?
    private var done = false
    private var requested = false
    private var pending: Downstream.Input??   // .some(v): result ready to send
    private var pendingCompletion: Subscribers.Completion<Downstream.Failure>?
    private let onValue: (Input) -> Next
    private let onFinish: () -> Downstream.Input?
    private let mapFailure: (UpstreamFailure) -> Downstream.Failure
    let description: String

    init(_ downstream: Downstream, name: String,
         onValue: @escaping (Input) -> Next,
         onFinish: @escaping () -> Downstream.Input?,
         mapFailure: @escaping (UpstreamFailure) -> Downstream.Failure) {
        self.downstream = downstream
        self.onValue = onValue
        self.onFinish = onFinish
        self.mapFailure = mapFailure
        description = name
    }

    func receive(subscription: Subscription) {
        lock.lock()
        if upstream != nil || done { lock.unlock(); subscription.cancel(); return }
        upstream = subscription
        lock.unlock()
        downstream.receive(subscription: self)
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        guard !done else { lock.unlock(); return .none }
        lock.unlock()
        switch onValue(input) {
        case .continue: return .none
        case .finish(let v):
            lock.lock(); let u = upstream; upstream = nil; lock.unlock()
            u?.cancel()
            deliver(v, .finished)
        case .fail(let e):
            lock.lock(); let u = upstream; upstream = nil; lock.unlock()
            u?.cancel()
            deliver(nil, .failure(e))
        }
        return .none
    }

    func receive(completion: Subscribers.Completion<UpstreamFailure>) {
        lock.lock()
        guard !done, pendingCompletion == nil else { lock.unlock(); return }
        upstream = nil
        lock.unlock()
        switch completion {
        case .finished: deliver(onFinish(), .finished)
        case .failure(let e): deliver(nil, .failure(mapFailure(e)))
        }
    }

    private func deliver(_ value: Downstream.Input?, _ c: Subscribers.Completion<Downstream.Failure>) {
        lock.lock()
        guard !done, pendingCompletion == nil else { lock.unlock(); return }
        if value != nil, !requested, case .finished = c {
            pending = .some(value)
            pendingCompletion = c
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        if let value { _ = downstream.receive(value) }
        downstream.receive(completion: c)
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        guard !done, demand > 0 else { lock.unlock(); return }
        let first = !requested
        requested = true
        if let p = pending, let c = pendingCompletion {
            done = true
            pending = nil
            lock.unlock()
            if let v = p { _ = downstream.receive(v) }
            downstream.receive(completion: c)
            return
        }
        let u = upstream
        lock.unlock()
        if first { u?.request(.unlimited) }
    }

    func cancel() {
        lock.lock()
        done = true
        let u = upstream
        upstream = nil
        lock.unlock()
        u?.cancel()
    }
}
