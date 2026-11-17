import Foundation

public protocol Subject<Output, Failure>: AnyObject, Publisher {
    func send(_ value: Output)
    func send(completion: Subscribers.Completion<Failure>)
    func send(subscription: Subscription)
}

extension Subject where Output == Void {
    public func send() { send(()) }
}

extension Publisher {
    /// Subscribes a subject to this publisher.
    public func subscribe<S: Subject>(_ subject: S) -> AnyCancellable where Failure == S.Failure, Output == S.Output {
        let sub = _ClosureSubscriber<Output, Failure>({ subject.send($0); return .none }, { subject.send(completion: $0) })
        subscribe(sub)
        return AnyCancellable(sub)
    }
}

/// Per-subscriber state for subjects. `replayLatest` keeps the most recent
/// value for a subscriber without demand (CurrentValueSubject); otherwise
/// values sent without demand are dropped (PassthroughSubject), as Apple's do.
final class _SubjectConduit<Output, Failure: Error>: Subscription, CustomStringConvertible, @unchecked Sendable {
    private let lock = _Lock()
    /// Serializes calls into the downstream (re-entrant: a subscriber may send).
    private let deliverLock = NSRecursiveLock()
    private var downstream: AnySubscriber<Output, Failure>?
    private var demand = Subscribers.Demand.none
    private var latest: Output?
    private let replayLatest: Bool
    weak var parent: _SubjectCore<Output, Failure>?
    let description: String

    init(_ downstream: AnySubscriber<Output, Failure>, parent: _SubjectCore<Output, Failure>, replayLatest: Bool, name: String) {
        self.downstream = downstream
        self.parent = parent
        self.replayLatest = replayLatest
        description = name
    }

    /// The value a CurrentValueSubject subscriber receives on its first request.
    func seed(_ v: Output) { latest = v }

    func offer(_ value: Output) {
        lock.lock()
        guard let d = downstream else { lock.unlock(); return }
        guard demand > 0 else {
            if replayLatest { latest = value }
            lock.unlock()
            return
        }
        demand -= 1
        lock.unlock()
        deliver(d, value)
    }

    private func deliver(_ d: AnySubscriber<Output, Failure>, _ value: Output) {
        deliverLock.lock()
        let more = d.receive(value)
        deliverLock.unlock()
        if more > 0 {
            lock.lock(); demand += more; lock.unlock()
        }
    }

    func finish(_ c: Subscribers.Completion<Failure>) {
        lock.lock()
        guard let d = downstream else { lock.unlock(); return }
        downstream = nil
        latest = nil
        lock.unlock()
        deliverLock.lock()
        d.receive(completion: c)
        deliverLock.unlock()
    }

    func request(_ d: Subscribers.Demand) {
        precondition(d > 0, "demand must be positive")
        lock.lock()
        guard let down = downstream else { lock.unlock(); return }
        demand += d
        guard let v = latest else { lock.unlock(); return }
        latest = nil
        demand -= 1
        lock.unlock()
        deliver(down, v)
    }

    func cancel() {
        lock.lock()
        downstream = nil
        latest = nil
        lock.unlock()
        parent?.remove(self)
    }
}

/// Subscriber bookkeeping shared by both subjects.
class _SubjectCore<Output, Failure: Error>: @unchecked Sendable {
    let lock = NSRecursiveLock()
    var conduits: [_SubjectConduit<Output, Failure>] = []
    var completion: Subscribers.Completion<Failure>?
    var upstreams: [Subscription] = []

    func remove(_ c: _SubjectConduit<Output, Failure>) {
        lock.lock(); defer { lock.unlock() }
        conduits.removeAll { $0 === c }
    }

    func attach<S: Subscriber>(_ subscriber: S, replayLatest: Bool, name: String, current: Output?) where S.Input == Output, S.Failure == Failure {
        lock.lock()
        if let c = completion {
            lock.unlock()
            subscriber.receive(subscription: Subscriptions.empty)
            subscriber.receive(completion: c)
            return
        }
        let conduit = _SubjectConduit(AnySubscriber(subscriber), parent: self, replayLatest: replayLatest, name: name)
        if let current { conduit.seed(current) }
        conduits.append(conduit)
        lock.unlock()
        subscriber.receive(subscription: conduit)
    }

    func broadcast(_ value: Output) {
        lock.lock()
        guard completion == nil else { lock.unlock(); return }
        let targets = conduits
        lock.unlock()
        for c in targets { c.offer(value) }
    }

    func complete(_ c: Subscribers.Completion<Failure>) {
        lock.lock()
        guard completion == nil else { lock.unlock(); return }
        completion = c
        let targets = conduits
        conduits.removeAll()
        upstreams.removeAll()
        lock.unlock()
        for t in targets { t.finish(c) }
    }

    func addUpstream(_ s: Subscription) {
        lock.lock()
        let live = completion == nil
        if live { upstreams.append(s) }
        lock.unlock()
        if live { s.request(.unlimited) } else { s.cancel() }
    }
}

public final class PassthroughSubject<Output, Failure: Error>: Subject, @unchecked Sendable {
    let core = _SubjectCore<Output, Failure>()
    public init() {}
    public func send(subscription: Subscription) { core.addUpstream(subscription) }
    public func send(_ input: Output) { core.broadcast(input) }
    public func send(completion: Subscribers.Completion<Failure>) { core.complete(completion) }
    public func receive<S: Subscriber>(subscriber: S) where Output == S.Input, Failure == S.Failure {
        core.attach(subscriber, replayLatest: false, name: "PassthroughSubject", current: nil)
    }
}

public final class CurrentValueSubject<Output, Failure: Error>: Subject, @unchecked Sendable {
    let core = _SubjectCore<Output, Failure>()
    private var _value: Output

    public init(_ value: Output) { _value = value }

    public var value: Output {
        get { core.lock.lock(); defer { core.lock.unlock() }; return _value }
        set { send(newValue) }
    }

    public func send(subscription: Subscription) { core.addUpstream(subscription) }
    public func send(_ input: Output) {
        core.lock.lock()
        guard core.completion == nil else { core.lock.unlock(); return }
        _value = input
        core.lock.unlock()
        core.broadcast(input)
    }
    public func send(completion: Subscribers.Completion<Failure>) { core.complete(completion) }
    public func receive<S: Subscriber>(subscriber: S) where Output == S.Input, Failure == S.Failure {
        core.lock.lock()
        let v = _value
        core.lock.unlock()
        core.attach(subscriber, replayLatest: true, name: "CurrentValueSubject", current: v)
    }
}
