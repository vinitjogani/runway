import Foundation

public enum Publishers {}

// MARK: Just, Empty, Fail

public struct Just<Output>: Publisher {
    public typealias Failure = Never
    public let output: Output
    public init(_ output: Output) { self.output = output }
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        _OnceSubscription.start(subscriber, value: output, completion: .finished)
    }
}

extension Just: Equatable where Output: Equatable {}
extension Just: Sendable where Output: Sendable {}

extension Just {
    public func setFailureType<E: Error>(to failureType: E.Type) -> Result<Output, E>.Publisher { .init(output) }
}

/// Delivers at most one value and a completion, on the first request.
final class _OnceSubscription<Downstream: Subscriber>: Subscription, CustomStringConvertible, @unchecked Sendable {
    private let lock = _Lock()
    private var downstream: Downstream?
    private let value: Downstream.Input?
    private let completion: Subscribers.Completion<Downstream.Failure>
    var description: String { "Once" }

    private init(_ d: Downstream, _ v: Downstream.Input?, _ c: Subscribers.Completion<Downstream.Failure>) {
        downstream = d; value = v; completion = c
    }

    static func start(_ d: Downstream, value: Downstream.Input?, completion: Subscribers.Completion<Downstream.Failure>) {
        if value == nil {
            d.receive(subscription: Subscriptions.empty)
            d.receive(completion: completion)
            return
        }
        d.receive(subscription: _OnceSubscription(d, value, completion))
    }

    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        guard demand > 0, let d = downstream else { lock.unlock(); return }
        downstream = nil
        lock.unlock()
        if let v = value { _ = d.receive(v) }
        d.receive(completion: completion)
    }

    func cancel() { lock.lock(); downstream = nil; lock.unlock() }
}

public struct Empty<Output, Failure: Error>: Publisher, Equatable {
    public let completeImmediately: Bool
    public init(completeImmediately: Bool = true) { self.completeImmediately = completeImmediately }
    public init(completeImmediately: Bool = true, outputType: Output.Type, failureType: Failure.Type) {
        self.completeImmediately = completeImmediately
    }
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        subscriber.receive(subscription: Subscriptions.empty)
        if completeImmediately { subscriber.receive(completion: .finished) }
    }
    public static func == (lhs: Empty, rhs: Empty) -> Bool { lhs.completeImmediately == rhs.completeImmediately }
}

extension Empty: Sendable {}

public struct Fail<Output, Failure: Error>: Publisher {
    public let error: Failure
    public init(error: Failure) { self.error = error }
    public init(outputType: Output.Type, failure: Failure) { error = failure }
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        subscriber.receive(subscription: Subscriptions.empty)
        subscriber.receive(completion: .failure(error))
    }
}

extension Fail: Equatable where Failure: Equatable {}
extension Fail: Sendable where Failure: Sendable {}

// MARK: Future, Deferred

public final class Future<Output, Failure: Error>: Publisher, @unchecked Sendable {
    public typealias Promise = (Result<Output, Failure>) -> Void
    private let lock = NSLock()
    private var result: Result<Output, Failure>?
    private var waiting: [_FutureConduit<Output, Failure>] = []

    public init(_ attemptToFulfill: @escaping (@escaping Promise) -> Void) {
        attemptToFulfill { [self] r in self.fulfill(r) }
    }

    private func fulfill(_ r: Result<Output, Failure>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let w = waiting
        waiting.removeAll()
        lock.unlock()
        for c in w { c.fulfill(r) }
    }

    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        let c = _FutureConduit<Output, Failure>(AnySubscriber(subscriber))
        lock.lock()
        let r = result
        if r == nil { waiting.append(c) }
        lock.unlock()
        subscriber.receive(subscription: c)
        if let r { c.fulfill(r) }
    }
}

extension Future {
    /// The future's result, awaited (macOS 12+).
    public var value: Output {
        get async throws {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Output, Error>) in
                var c: AnyCancellable?
                c = self.sink(receiveCompletion: { if case .failure(let e) = $0 { k.resume(throwing: e) }; _ = c },
                              receiveValue: { k.resume(returning: $0) })
            }
        }
    }
}

extension Future where Failure == Never {
    public var value: Output {
        get async {
            await withCheckedContinuation { (k: CheckedContinuation<Output, Never>) in
                var c: AnyCancellable?
                c = self.sink(receiveCompletion: { _ in _ = c }, receiveValue: { k.resume(returning: $0) })
            }
        }
    }
}

final class _FutureConduit<Output, Failure: Error>: Subscription, @unchecked Sendable {
    private let lock = NSLock()
    private var downstream: AnySubscriber<Output, Failure>?
    private var requested = false
    private var result: Result<Output, Failure>?
    init(_ d: AnySubscriber<Output, Failure>) { downstream = d }

    func fulfill(_ r: Result<Output, Failure>) {
        lock.lock()
        result = r
        let ready = requested || { if case .failure = r { return true }; return false }()
        lock.unlock()
        if ready { deliver() }
    }
    func request(_ demand: Subscribers.Demand) {
        lock.lock()
        requested = true
        let ready = result != nil
        lock.unlock()
        if ready { deliver() }
    }
    private func deliver() {
        lock.lock()
        guard let d = downstream, let r = result else { lock.unlock(); return }
        downstream = nil
        lock.unlock()
        switch r {
        case .success(let v): _ = d.receive(v); d.receive(completion: .finished)
        case .failure(let e): d.receive(completion: .failure(e))
        }
    }
    func cancel() { lock.lock(); downstream = nil; lock.unlock() }
}

public struct Deferred<DeferredPublisher: Publisher>: Publisher {
    public typealias Output = DeferredPublisher.Output
    public typealias Failure = DeferredPublisher.Failure
    public let createPublisher: () -> DeferredPublisher
    public init(createPublisher: @escaping () -> DeferredPublisher) { self.createPublisher = createPublisher }
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        createPublisher().receive(subscriber: subscriber)
    }
}

// MARK: Sequence, Optional, Result, Record

extension Publishers {
    public struct Sequence<Elements: Swift.Sequence, Failure: Error>: Publisher {
        public typealias Output = Elements.Element
        public let sequence: Elements
        public init(sequence: Elements) { self.sequence = sequence }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var it = sequence.makeIterator()
            guard let first = it.next() else {
                subscriber.receive(subscription: Subscriptions.empty)
                subscriber.receive(completion: .finished)
                return
            }
            subscriber.receive(subscription: _SequenceSubscription(subscriber, first: first, rest: it))
        }
    }
}

extension Publishers.Sequence: Equatable where Elements: Equatable {}

extension Publishers.Sequence where Failure == Never {
    public func setFailureType<E: Error>(to: E.Type) -> Publishers.Sequence<Elements, E> { .init(sequence: sequence) }
}

final class _SequenceSubscription<Downstream: Subscriber, It: IteratorProtocol>: Subscription, CustomStringConvertible, @unchecked Sendable where It.Element == Downstream.Input {
    private let lock = NSRecursiveLock()
    private var downstream: Downstream?
    private var next: It.Element?
    private var iterator: It
    private var demand = Subscribers.Demand.none
    private var emitting = false
    var description: String { "Sequence" }

    init(_ d: Downstream, first: It.Element, rest: It) { downstream = d; next = first; iterator = rest }

    func request(_ d: Subscribers.Demand) {
        lock.lock()
        demand += d
        if emitting { lock.unlock(); return }
        emitting = true
        while demand > 0, let ds = downstream, let v = next {
            demand -= 1
            next = iterator.next()
            lock.unlock()
            let more = ds.receive(v)
            lock.lock()
            demand += more
        }
        if next == nil, let ds = downstream {
            downstream = nil
            lock.unlock()
            ds.receive(completion: .finished)
            lock.lock()
        }
        emitting = false
        lock.unlock()
    }

    func cancel() { lock.lock(); downstream = nil; next = nil; lock.unlock() }
}

extension Sequence {
    public var publisher: Publishers.Sequence<Self, Never> { .init(sequence: self) }
}

extension Optional {
    public var publisher: Optional<Wrapped>.Publisher { .init(self) }

    public struct Publisher: Combine.Publisher {
        public typealias Output = Wrapped
        public typealias Failure = Never
        public let output: Wrapped?
        public init(_ output: Wrapped?) { self.output = output }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Wrapped, S.Failure == Never {
            _OnceSubscription.start(subscriber, value: output, completion: .finished)
        }
    }
}

extension Result {
    public var publisher: Result<Success, Failure>.Publisher { .init(self) }

    public struct Publisher: Combine.Publisher {
        public typealias Output = Success
        public let result: Result<Success, Failure>
        public init(_ result: Result<Success, Failure>) { self.result = result }
        public init(_ output: Success) { result = .success(output) }
        public init(_ failure: Failure) { result = .failure(failure) }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Success, S.Failure == Failure {
            switch result {
            case .success(let v): _OnceSubscription.start(subscriber, value: v, completion: .finished)
            case .failure(let e): _OnceSubscription.start(subscriber, value: nil, completion: .failure(e))
            }
        }
    }
}

public struct Record<Output, Failure: Error>: Publisher {
    public struct Recording {
        public private(set) var output: [Output] = []
        public private(set) var completion: Subscribers.Completion<Failure> = .finished
        private var finished = false
        public init() {}
        public init(output: [Output], completion: Subscribers.Completion<Failure> = .finished) {
            self.output = output; self.completion = completion; finished = true
        }
        public mutating func receive(_ input: Output) { precondition(!finished); output.append(input) }
        public mutating func receive(completion: Subscribers.Completion<Failure>) { precondition(!finished); self.completion = completion; finished = true }
    }
    public let recording: Recording
    public init(record: (inout Recording) -> Void) {
        var r = Recording()
        record(&r)
        recording = r
    }
    public init(recording: Recording) { self.recording = recording }
    public init(output: [Output], completion: Subscribers.Completion<Failure>) { recording = Recording(output: output, completion: completion) }
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
        let c = recording.completion
        Publishers.Sequence<[Output], Failure>(sequence: recording.output)
            .receive(subscriber: _StepInner<Output, Failure, S>(subscriber, name: "Record", step: { .emit($0) }, complete: { _ in c }))
    }
}

// MARK: Sink, Assign

extension Subscribers {
    public final class Sink<Input, Failure: Error>: Subscriber, Cancellable, CustomStringConvertible, CustomReflectable, CustomPlaygroundDisplayConvertible, @unchecked Sendable {
        public var receiveValue: (Input) -> Void
        public var receiveCompletion: (Subscribers.Completion<Failure>) -> Void
        private let lock = NSLock()
        private var subscription: Subscription?
        private var done = false

        public init(receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void, receiveValue: @escaping (Input) -> Void) {
            self.receiveCompletion = receiveCompletion
            self.receiveValue = receiveValue
        }

        public var description: String { "Sink" }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
        public var playgroundDescription: Any { description }

        public func receive(subscription: Subscription) {
            lock.lock()
            if self.subscription != nil || done { lock.unlock(); subscription.cancel(); return }
            self.subscription = subscription
            lock.unlock()
            subscription.request(.unlimited)
        }
        public func receive(_ value: Input) -> Subscribers.Demand {
            lock.lock()
            let live = !done
            let handler = receiveValue
            lock.unlock()
            if live { handler(value) }
            return .none
        }
        public func receive(completion: Subscribers.Completion<Failure>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let s = subscription
            subscription = nil
            let handler = receiveCompletion
            lock.unlock()
            handler(completion)
            releaseHandlers()
            withExtendedLifetime(s) {}
        }
        public func cancel() {
            lock.lock()
            done = true
            let s = subscription
            subscription = nil
            lock.unlock()
            s?.cancel()
            releaseHandlers()
        }
        /// Breaks the closures' retain cycles once finished, as Apple's does.
        /// The old closures are swapped out under the lock and released only
        /// after it: releasing one can drop the last AnyCancellable, whose
        /// deinit cancels this sink again (re-entrantly).
        private func releaseHandlers() {
            lock.lock()
            let old = (receiveValue, receiveCompletion)
            receiveValue = { _ in }
            receiveCompletion = { _ in }
            lock.unlock()
            withExtendedLifetime(old) {}
        }
    }

    public final class Assign<Root, Input>: Subscriber, Cancellable, CustomStringConvertible, CustomReflectable, CustomPlaygroundDisplayConvertible, @unchecked Sendable {
        public typealias Failure = Never
        public private(set) var object: Root?
        public let keyPath: ReferenceWritableKeyPath<Root, Input>
        private let lock = NSLock()
        private var subscription: Subscription?

        public init(object: Root, keyPath: ReferenceWritableKeyPath<Root, Input>) {
            self.object = object
            self.keyPath = keyPath
        }
        public var description: String { object.map { "Assign \(type(of: $0))" } ?? "Assign" }
        public var customMirror: Mirror { Mirror(self, children: ["object": object as Any, "keyPath": keyPath]) }
        public var playgroundDescription: Any { description }

        public func receive(subscription: Subscription) {
            lock.lock()
            if self.subscription != nil || object == nil { lock.unlock(); subscription.cancel(); return }
            self.subscription = subscription
            lock.unlock()
            subscription.request(.unlimited)
        }
        public func receive(_ value: Input) -> Subscribers.Demand {
            lock.lock(); let o = object; lock.unlock()
            o?[keyPath: keyPath] = value
            return .none
        }
        public func receive(completion: Subscribers.Completion<Never>) {
            lock.lock(); object = nil; subscription = nil; lock.unlock()
        }
        public func cancel() {
            lock.lock()
            let s = subscription
            subscription = nil
            object = nil
            lock.unlock()
            s?.cancel()
        }
    }
}

extension Publisher {
    public func sink(receiveCompletion: @escaping (Subscribers.Completion<Failure>) -> Void,
                     receiveValue: @escaping (Output) -> Void) -> AnyCancellable {
        let s = Subscribers.Sink<Output, Failure>(receiveCompletion: receiveCompletion, receiveValue: receiveValue)
        subscribe(s)
        return AnyCancellable(s)
    }
}

extension Publisher where Failure == Never {
    public func sink(receiveValue: @escaping (Output) -> Void) -> AnyCancellable {
        sink(receiveCompletion: { _ in }, receiveValue: receiveValue)
    }

    public func assign<Root>(to keyPath: ReferenceWritableKeyPath<Root, Output>, on object: Root) -> AnyCancellable {
        let s = Subscribers.Assign(object: object, keyPath: keyPath)
        subscribe(s)
        return AnyCancellable(s)
    }
}
