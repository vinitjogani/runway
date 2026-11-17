// Operators over several publishers: merge, combineLatest, zip, flatMap,
// switchToLatest, concatenation, catch/retry, and the untilOutputFrom pair.
// Upstreams are subscribed with unlimited demand; values queue in a
// conduit until the downstream asks for them.

import Foundation

/// Shared state for joining operators: the upstream subscriptions, one
/// conduit downstream, a recursive lock that serializes their callbacks.
final class _WeakRef: @unchecked Sendable { weak var value: AnyObject? }

final class _Join<Downstream: Subscriber>: @unchecked Sendable {
    let lock = NSRecursiveLock()
    let conduit: _Conduit<Downstream>
    private var subs: [Cancellable] = []
    private(set) var done = false

    init(_ d: Downstream, name: String) {
        conduit = _Conduit(d, name: name)
        conduit.onCancel = { [weak self] in self?.cancelAll() }
    }

    func add(_ c: Cancellable) {
        lock.lock()
        if done { lock.unlock(); c.cancel(); return }
        subs.append(c)
        lock.unlock()
    }

    func remove(_ c: AnyObject) {
        lock.lock(); subs.removeAll { ($0 as AnyObject) === c }; lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        done = true
        let s = subs
        subs.removeAll()
        lock.unlock()
        for c in s { c.cancel() }
    }

    func send(_ v: Downstream.Input) { conduit.send(v) }

    func complete(_ c: Subscribers.Completion<Downstream.Failure>) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let s = subs
        subs.removeAll()
        lock.unlock()
        for x in s { x.cancel() }
        if case .failure = c { conduit.fail(c) } else { conduit.finish(c) }
    }

    /// Subscribes to `p`, routing its events through the join's lock.
    @discardableResult
    func subscribe<P: Publisher>(_ p: P, demand: Subscribers.Demand = .unlimited,
                                 value: @escaping (P.Output) -> Void,
                                 completion: @escaping (Subscribers.Completion<P.Failure>) -> Void) -> _ClosureSubscriber<P.Output, P.Failure> {
        let lock = self.lock
        let ref = _WeakRef()
        let s = _ClosureSubscriber<P.Output, P.Failure>(demand: demand, { v in
            lock.lock(); value(v); lock.unlock()
            return .none
        }, { [weak self] c in
            lock.lock(); completion(c); lock.unlock()
            if let o = ref.value { self?.remove(o) }
        })
        ref.value = s
        add(s)
        p.subscribe(s)
        return s
    }
}

// MARK: Merge

extension Publishers {
    public struct MergeMany<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let publishers: [Upstream]
        public init(_ upstream: Upstream...) { publishers = upstream }
        public init<S: Swift.Sequence>(_ upstream: S) where S.Element == Upstream { publishers = Array(upstream) }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _merge(publishers.map(AnyPublisher.init), subscriber, name: "MergeMany")
        }
        public func merge(with other: Upstream) -> MergeMany<Upstream> { .init(publishers + [other]) }
    }

    public struct Merge<A: Publisher, B: Publisher>: Publisher where A.Output == B.Output, A.Failure == B.Failure {
        public typealias Output = A.Output
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public init(_ a: A, _ b: B) { self.a = a; self.b = b }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _merge([AnyPublisher(a), AnyPublisher(b)], subscriber, name: "Merge")
        }
        public func merge<P: Publisher>(with other: P) -> Merge3<A, B, P> where P.Output == Output, P.Failure == Failure { .init(a, b, other) }
    }

    public struct Merge3<A: Publisher, B: Publisher, C: Publisher>: Publisher
    where A.Output == B.Output, A.Failure == B.Failure, B.Output == C.Output, B.Failure == C.Failure {
        public typealias Output = A.Output
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public let c: C
        public init(_ a: A, _ b: B, _ c: C) { self.a = a; self.b = b; self.c = c }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _merge([AnyPublisher(a), AnyPublisher(b), AnyPublisher(c)], subscriber, name: "Merge3")
        }
        public func merge<P: Publisher>(with other: P) -> Merge4<A, B, C, P> where P.Output == Output, P.Failure == Failure { .init(a, b, c, other) }
    }

    public struct Merge4<A: Publisher, B: Publisher, C: Publisher, D: Publisher>: Publisher
    where A.Output == B.Output, A.Failure == B.Failure, B.Output == C.Output, B.Failure == C.Failure, C.Output == D.Output, C.Failure == D.Failure {
        public typealias Output = A.Output
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public let c: C
        public let d: D
        public init(_ a: A, _ b: B, _ c: C, _ d: D) { self.a = a; self.b = b; self.c = c; self.d = d }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _merge([AnyPublisher(a), AnyPublisher(b), AnyPublisher(c), AnyPublisher(d)], subscriber, name: "Merge4")
        }
    }
}

func _merge<S: Subscriber>(_ ps: [AnyPublisher<S.Input, S.Failure>], _ subscriber: S, name: String) {
    let join = _Join(subscriber, name: name)
    join.conduit.start()
    var remaining = ps.count
    if remaining == 0 { join.complete(.finished); return }
    for p in ps {
        join.subscribe(p, value: { join.send($0) }, completion: { c in
            switch c {
            case .failure: join.complete(c)
            case .finished:
                remaining -= 1
                if remaining == 0 { join.complete(.finished) }
            }
        })
    }
}

extension Publisher {
    public func merge<P: Publisher>(with other: P) -> Publishers.Merge<Self, P> where P.Output == Output, P.Failure == Failure { .init(self, other) }
    public func merge<B: Publisher, C: Publisher>(with b: B, _ c: C) -> Publishers.Merge3<Self, B, C>
    where B.Output == Output, B.Failure == Failure, C.Output == Output, C.Failure == Failure { .init(self, b, c) }
    public func merge<B: Publisher, C: Publisher, D: Publisher>(with b: B, _ c: C, _ d: D) -> Publishers.Merge4<Self, B, C, D>
    where B.Output == Output, B.Failure == Failure, C.Output == Output, C.Failure == Failure, D.Output == Output, D.Failure == Failure { .init(self, b, c, d) }
}

// MARK: CombineLatest, Zip

/// Joins n type-erased upstreams: `combine` builds the output from one
/// value per upstream. `zip` pairs values in order; otherwise each new value
/// combines with the latest of the others.
func _joinLatest<S: Subscriber>(_ ps: [AnyPublisher<Any, S.Failure>], _ subscriber: S, zip: Bool, name: String,
                                combine: @escaping ([Any]) -> S.Input) {
    let n = ps.count
    let join = _Join(subscriber, name: name)
    join.conduit.start()
    var latest = [Any?](repeating: nil, count: n)
    var queues = [[Any]](repeating: [], count: n)
    var finished = [Bool](repeating: false, count: n)
    for (i, p) in ps.enumerated() {
        join.subscribe(p, value: { v in
            if zip {
                queues[i].append(v)
                if queues.allSatisfy({ !$0.isEmpty }) {
                    let row = queues.indices.map { queues[$0].removeFirst() }
                    join.send(combine(row))
                    // Zip finishes once a finished upstream has nothing left.
                    if finished.indices.contains(where: { finished[$0] && queues[$0].isEmpty }) { join.complete(.finished) }
                }
            } else {
                latest[i] = v
                if latest.allSatisfy({ $0 != nil }) { join.send(combine(latest.map { $0! })) }
            }
        }, completion: { c in
            switch c {
            case .failure: join.complete(c)
            case .finished:
                finished[i] = true
                if zip ? queues[i].isEmpty : finished.allSatisfy({ $0 }) { join.complete(.finished) }
            }
        })
    }
}

extension Publisher {
    func _anyOutput() -> AnyPublisher<Any, Failure> { map { $0 as Any }.eraseToAnyPublisher() }
}

extension Publishers {
    public struct CombineLatest<A: Publisher, B: Publisher>: Publisher where A.Failure == B.Failure {
        public typealias Output = (A.Output, B.Output)
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public init(_ a: A, _ b: B) { self.a = a; self.b = b }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _joinLatest([a._anyOutput(), b._anyOutput()], subscriber, zip: false, name: "CombineLatest") { ($0[0] as! A.Output, $0[1] as! B.Output) }
        }
    }

    public struct CombineLatest3<A: Publisher, B: Publisher, C: Publisher>: Publisher where A.Failure == B.Failure, B.Failure == C.Failure {
        public typealias Output = (A.Output, B.Output, C.Output)
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public let c: C
        public init(_ a: A, _ b: B, _ c: C) { self.a = a; self.b = b; self.c = c }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _joinLatest([a._anyOutput(), b._anyOutput(), c._anyOutput()], subscriber, zip: false, name: "CombineLatest3") {
                ($0[0] as! A.Output, $0[1] as! B.Output, $0[2] as! C.Output)
            }
        }
    }

    public struct CombineLatest4<A: Publisher, B: Publisher, C: Publisher, D: Publisher>: Publisher
    where A.Failure == B.Failure, B.Failure == C.Failure, C.Failure == D.Failure {
        public typealias Output = (A.Output, B.Output, C.Output, D.Output)
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public let c: C
        public let d: D
        public init(_ a: A, _ b: B, _ c: C, _ d: D) { self.a = a; self.b = b; self.c = c; self.d = d }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _joinLatest([a._anyOutput(), b._anyOutput(), c._anyOutput(), d._anyOutput()], subscriber, zip: false, name: "CombineLatest4") {
                ($0[0] as! A.Output, $0[1] as! B.Output, $0[2] as! C.Output, $0[3] as! D.Output)
            }
        }
    }

    public struct Zip<A: Publisher, B: Publisher>: Publisher where A.Failure == B.Failure {
        public typealias Output = (A.Output, B.Output)
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public init(_ a: A, _ b: B) { self.a = a; self.b = b }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _joinLatest([a._anyOutput(), b._anyOutput()], subscriber, zip: true, name: "Zip") { ($0[0] as! A.Output, $0[1] as! B.Output) }
        }
    }

    public struct Zip3<A: Publisher, B: Publisher, C: Publisher>: Publisher where A.Failure == B.Failure, B.Failure == C.Failure {
        public typealias Output = (A.Output, B.Output, C.Output)
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public let c: C
        public init(_ a: A, _ b: B, _ c: C) { self.a = a; self.b = b; self.c = c }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _joinLatest([a._anyOutput(), b._anyOutput(), c._anyOutput()], subscriber, zip: true, name: "Zip3") {
                ($0[0] as! A.Output, $0[1] as! B.Output, $0[2] as! C.Output)
            }
        }
    }

    public struct Zip4<A: Publisher, B: Publisher, C: Publisher, D: Publisher>: Publisher
    where A.Failure == B.Failure, B.Failure == C.Failure, C.Failure == D.Failure {
        public typealias Output = (A.Output, B.Output, C.Output, D.Output)
        public typealias Failure = A.Failure
        public let a: A
        public let b: B
        public let c: C
        public let d: D
        public init(_ a: A, _ b: B, _ c: C, _ d: D) { self.a = a; self.b = b; self.c = c; self.d = d }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            _joinLatest([a._anyOutput(), b._anyOutput(), c._anyOutput(), d._anyOutput()], subscriber, zip: true, name: "Zip4") {
                ($0[0] as! A.Output, $0[1] as! B.Output, $0[2] as! C.Output, $0[3] as! D.Output)
            }
        }
    }
}

extension Publisher {
    public func combineLatest<P: Publisher>(_ other: P) -> Publishers.CombineLatest<Self, P> where P.Failure == Failure { .init(self, other) }
    public func combineLatest<P: Publisher, T>(_ other: P, _ transform: @escaping (Output, P.Output) -> T) -> Publishers.Map<Publishers.CombineLatest<Self, P>, T>
    where P.Failure == Failure { combineLatest(other).map(transform) }
    public func combineLatest<P: Publisher, Q: Publisher>(_ p: P, _ q: Q) -> Publishers.CombineLatest3<Self, P, Q>
    where P.Failure == Failure, Q.Failure == Failure { .init(self, p, q) }
    public func combineLatest<P: Publisher, Q: Publisher, T>(_ p: P, _ q: Q, _ transform: @escaping (Output, P.Output, Q.Output) -> T)
    -> Publishers.Map<Publishers.CombineLatest3<Self, P, Q>, T> where P.Failure == Failure, Q.Failure == Failure {
        combineLatest(p, q).map(transform)
    }
    public func combineLatest<P: Publisher, Q: Publisher, R: Publisher>(_ p: P, _ q: Q, _ r: R) -> Publishers.CombineLatest4<Self, P, Q, R>
    where P.Failure == Failure, Q.Failure == Failure, R.Failure == Failure { .init(self, p, q, r) }
    public func combineLatest<P: Publisher, Q: Publisher, R: Publisher, T>(_ p: P, _ q: Q, _ r: R, _ transform: @escaping (Output, P.Output, Q.Output, R.Output) -> T)
    -> Publishers.Map<Publishers.CombineLatest4<Self, P, Q, R>, T> where P.Failure == Failure, Q.Failure == Failure, R.Failure == Failure {
        combineLatest(p, q, r).map(transform)
    }

    public func zip<P: Publisher>(_ other: P) -> Publishers.Zip<Self, P> where P.Failure == Failure { .init(self, other) }
    public func zip<P: Publisher, T>(_ other: P, _ transform: @escaping (Output, P.Output) -> T) -> Publishers.Map<Publishers.Zip<Self, P>, T>
    where P.Failure == Failure { zip(other).map(transform) }
    public func zip<P: Publisher, Q: Publisher>(_ p: P, _ q: Q) -> Publishers.Zip3<Self, P, Q> where P.Failure == Failure, Q.Failure == Failure { .init(self, p, q) }
    public func zip<P: Publisher, Q: Publisher, T>(_ p: P, _ q: Q, _ transform: @escaping (Output, P.Output, Q.Output) -> T)
    -> Publishers.Map<Publishers.Zip3<Self, P, Q>, T> where P.Failure == Failure, Q.Failure == Failure { zip(p, q).map(transform) }
    public func zip<P: Publisher, Q: Publisher, R: Publisher>(_ p: P, _ q: Q, _ r: R) -> Publishers.Zip4<Self, P, Q, R>
    where P.Failure == Failure, Q.Failure == Failure, R.Failure == Failure { .init(self, p, q, r) }
    public func zip<P: Publisher, Q: Publisher, R: Publisher, T>(_ p: P, _ q: Q, _ r: R, _ transform: @escaping (Output, P.Output, Q.Output, R.Output) -> T)
    -> Publishers.Map<Publishers.Zip4<Self, P, Q, R>, T> where P.Failure == Failure, Q.Failure == Failure, R.Failure == Failure {
        zip(p, q, r).map(transform)
    }
}

// MARK: FlatMap, SwitchToLatest

extension Publishers {
    public struct FlatMap<NewPublisher: Publisher, Upstream: Publisher>: Publisher where NewPublisher.Failure == Upstream.Failure {
        public typealias Output = NewPublisher.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let maxPublishers: Subscribers.Demand
        public let transform: (Upstream.Output) -> NewPublisher
        public init(upstream: Upstream, maxPublishers: Subscribers.Demand, transform: @escaping (Upstream.Output) -> NewPublisher) {
            self.upstream = upstream; self.maxPublishers = maxPublishers; self.transform = transform
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let join = _Join(subscriber, name: "FlatMap")
            join.conduit.start()
            let t = transform
            var active = 0
            var upstreamDone = false
            var outer: _ClosureSubscriber<Upstream.Output, Failure>?
            outer = join.subscribe(upstream, demand: maxPublishers, value: { v in
                active += 1
                var inner: _ClosureSubscriber<NewPublisher.Output, NewPublisher.Failure>?
                inner = join.subscribe(t(v), value: { join.send($0) }, completion: { c in
                    if let inner { join.remove(inner) }
                    switch c {
                    case .failure: join.complete(c)
                    case .finished:
                        active -= 1
                        if upstreamDone && active == 0 { join.complete(.finished) } else { outer?.request(.max(1)) }
                    }
                })
            }, completion: { c in
                switch c {
                case .failure: join.complete(c)
                case .finished:
                    upstreamDone = true
                    if active == 0 { join.complete(.finished) }
                }
            })
        }
    }

    public struct SwitchToLatest<P: Publisher, Upstream: Publisher>: Publisher where Upstream.Output == P, P.Failure == Upstream.Failure {
        public typealias Output = P.Output
        public typealias Failure = P.Failure
        public let upstream: Upstream
        public init(upstream: Upstream) { self.upstream = upstream }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let join = _Join(subscriber, name: "SwitchToLatest")
            join.conduit.start()
            var current: _ClosureSubscriber<P.Output, P.Failure>?
            var generation = 0
            var upstreamDone = false
            join.subscribe(upstream, value: { p in
                if let c = current { join.remove(c); c.cancel() }
                generation += 1
                let mine = generation
                current = nil
                var finishedNow = false
                let inner = join.subscribe(p, value: { if mine == generation { join.send($0) } }, completion: { c in
                    guard mine == generation else { return }
                    finishedNow = true
                    current = nil
                    switch c {
                    case .failure: join.complete(c)
                    case .finished: if upstreamDone { join.complete(.finished) }
                    }
                })
                if mine == generation, !finishedNow { current = inner }
            }, completion: { c in
                switch c {
                case .failure: join.complete(c)
                case .finished:
                    upstreamDone = true
                    if current == nil { join.complete(.finished) }
                }
            })
        }
    }
}

extension Publisher {
    public func flatMap<T, P: Publisher>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Output) -> P)
    -> Publishers.FlatMap<P, Self> where T == P.Output, P.Failure == Failure {
        .init(upstream: self, maxPublishers: maxPublishers, transform: transform)
    }
}

extension Publisher where Failure == Never {
    public func flatMap<P: Publisher>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Output) -> P)
    -> Publishers.FlatMap<P, Publishers.SetFailureType<Self, P.Failure>> {
        setFailureType(to: P.Failure.self).flatMap(maxPublishers: maxPublishers, transform)
    }
    public func flatMap<P: Publisher>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Output) -> P)
    -> Publishers.FlatMap<P, Self> where P.Failure == Never {
        .init(upstream: self, maxPublishers: maxPublishers, transform: transform)
    }
}

extension Publisher {
    public func flatMap<P: Publisher>(maxPublishers: Subscribers.Demand = .unlimited, _ transform: @escaping (Output) -> P)
    -> Publishers.FlatMap<Publishers.SetFailureType<P, Failure>, Self> where P.Failure == Never {
        .init(upstream: self, maxPublishers: maxPublishers, transform: { transform($0).setFailureType(to: Failure.self) })
    }
}

extension Publisher where Output: Publisher, Output.Failure == Failure {
    public func switchToLatest() -> Publishers.SwitchToLatest<Output, Self> { .init(upstream: self) }
}

extension Publisher where Output: Publisher, Failure == Never {
    public func switchToLatest() -> Publishers.SwitchToLatest<Output, Publishers.SetFailureType<Self, Output.Failure>> {
        .init(upstream: setFailureType(to: Output.Failure.self))
    }
}

extension Publisher where Failure == Never, Output: Publisher, Output.Failure == Never {
    public func switchToLatest() -> Publishers.SwitchToLatest<Output, Self> { .init(upstream: self) }
}

// MARK: Concatenate, prepend, append

extension Publishers {
    public struct Concatenate<Prefix: Publisher, Suffix: Publisher>: Publisher where Prefix.Output == Suffix.Output, Prefix.Failure == Suffix.Failure {
        public typealias Output = Suffix.Output
        public typealias Failure = Suffix.Failure
        public let prefix: Prefix
        public let suffix: Suffix
        public init(prefix: Prefix, suffix: Suffix) { self.prefix = prefix; self.suffix = suffix }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let join = _Join(subscriber, name: "Concatenate")
            join.conduit.start()
            let suffix = self.suffix
            join.subscribe(prefix, value: { join.send($0) }, completion: { c in
                switch c {
                case .failure: join.complete(c)
                case .finished:
                    join.subscribe(suffix, value: { join.send($0) }, completion: { join.complete($0) })
                }
            })
        }
    }
}

extension Publishers.Concatenate: Equatable where Prefix: Equatable, Suffix: Equatable {}

extension Publisher {
    public func prepend(_ elements: Output...) -> Publishers.Concatenate<Publishers.Sequence<[Output], Failure>, Self> {
        .init(prefix: .init(sequence: elements), suffix: self)
    }
    public func prepend<S: Sequence>(_ elements: S) -> Publishers.Concatenate<Publishers.Sequence<S, Failure>, Self> where S.Element == Output {
        .init(prefix: .init(sequence: elements), suffix: self)
    }
    public func prepend<P: Publisher>(_ publisher: P) -> Publishers.Concatenate<P, Self> where P.Output == Output, P.Failure == Failure {
        .init(prefix: publisher, suffix: self)
    }
    public func append(_ elements: Output...) -> Publishers.Concatenate<Self, Publishers.Sequence<[Output], Failure>> {
        .init(prefix: self, suffix: .init(sequence: elements))
    }
    public func append<S: Sequence>(_ elements: S) -> Publishers.Concatenate<Self, Publishers.Sequence<S, Failure>> where S.Element == Output {
        .init(prefix: self, suffix: .init(sequence: elements))
    }
    public func append<P: Publisher>(_ publisher: P) -> Publishers.Concatenate<Self, P> where P.Output == Output, P.Failure == Failure {
        .init(prefix: self, suffix: publisher)
    }
}

// MARK: Catch, TryCatch, Retry

extension Publishers {
    public struct Catch<Upstream: Publisher, NewPublisher: Publisher>: Publisher where Upstream.Output == NewPublisher.Output {
        public typealias Output = Upstream.Output
        public typealias Failure = NewPublisher.Failure
        public let upstream: Upstream
        public let handler: (Upstream.Failure) -> NewPublisher
        public init(upstream: Upstream, handler: @escaping (Upstream.Failure) -> NewPublisher) { self.upstream = upstream; self.handler = handler }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let join = _Join(subscriber, name: "Catch")
            join.conduit.start()
            let h = handler
            join.subscribe(upstream, value: { join.send($0) }, completion: { c in
                switch c {
                case .finished: join.complete(.finished)
                case .failure(let e): join.subscribe(h(e), value: { join.send($0) }, completion: { join.complete($0) })
                }
            })
        }
    }

    public struct TryCatch<Upstream: Publisher, NewPublisher: Publisher>: Publisher where Upstream.Output == NewPublisher.Output {
        public typealias Output = Upstream.Output
        public typealias Failure = Error
        public let upstream: Upstream
        public let handler: (Upstream.Failure) throws -> NewPublisher
        public init(upstream: Upstream, handler: @escaping (Upstream.Failure) throws -> NewPublisher) { self.upstream = upstream; self.handler = handler }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            let join = _Join(subscriber, name: "TryCatch")
            join.conduit.start()
            let h = handler
            join.subscribe(upstream, value: { join.send($0) }, completion: { c in
                switch c {
                case .finished: join.complete(.finished)
                case .failure(let e):
                    do {
                        join.subscribe(try h(e), value: { join.send($0) }, completion: { join.complete($0.eraseError) })
                    } catch { join.complete(.failure(error)) }
                }
            })
        }
    }

    public struct Retry<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let retries: Int?
        public init(upstream: Upstream, retries: Int?) { self.upstream = upstream; self.retries = retries }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let join = _Join(subscriber, name: "Retry")
            join.conduit.start()
            var remaining = retries
            let upstream = self.upstream
            func attempt() {
                join.subscribe(upstream, value: { join.send($0) }, completion: { c in
                    if case .failure = c, remaining.map({ $0 > 0 }) ?? true, !join.done {
                        remaining = remaining.map { $0 - 1 }
                        attempt()
                    } else {
                        join.complete(c)
                    }
                })
            }
            attempt()
        }
    }
}

extension Publisher {
    public func `catch`<P: Publisher>(_ handler: @escaping (Failure) -> P) -> Publishers.Catch<Self, P> where P.Output == Output {
        .init(upstream: self, handler: handler)
    }
    public func tryCatch<P: Publisher>(_ handler: @escaping (Failure) throws -> P) -> Publishers.TryCatch<Self, P> where P.Output == Output {
        .init(upstream: self, handler: handler)
    }
    public func retry(_ retries: Int) -> Publishers.Retry<Self> { .init(upstream: self, retries: retries) }
}

// MARK: untilOutputFrom

extension Publishers {
    public struct DropUntilOutput<Upstream: Publisher, Other: Publisher>: Publisher where Upstream.Failure == Other.Failure {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let other: Other
        public init(upstream: Upstream, other: Other) { self.upstream = upstream; self.other = other }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let join = _Join(subscriber, name: "DropUntilOutput")
            join.conduit.start()
            var open = false
            var trigger: _ClosureSubscriber<Other.Output, Other.Failure>?
            trigger = join.subscribe(other, value: { _ in
                open = true
                if let t = trigger { join.remove(t); t.cancel() }
            }, completion: { c in
                if case .failure = c { join.complete(c) }
            })
            join.subscribe(upstream, value: { if open { join.send($0) } }, completion: { join.complete($0) })
        }
    }

    public struct PrefixUntilOutput<Upstream: Publisher, Other: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let other: Other
        public init(upstream: Upstream, other: Other) { self.upstream = upstream; self.other = other }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let join = _Join(subscriber, name: "PrefixUntilOutput")
            join.conduit.start()
            join.subscribe(other, value: { _ in join.complete(.finished) }, completion: { _ in })
            join.subscribe(upstream, value: { join.send($0) }, completion: { join.complete($0) })
        }
    }
}

extension Publisher {
    public func drop<P: Publisher>(untilOutputFrom publisher: P) -> Publishers.DropUntilOutput<Self, P> where Failure == P.Failure {
        .init(upstream: self, other: publisher)
    }
    public func prefix<P: Publisher>(untilOutputFrom publisher: P) -> Publishers.PrefixUntilOutput<Self, P> {
        .init(upstream: self, other: publisher)
    }
}

// MARK: Encode, Decode

public protocol TopLevelEncoder {
    associatedtype Output
    func encode<T: Encodable>(_ value: T) throws -> Output
}

public protocol TopLevelDecoder {
    associatedtype Input
    func decode<T: Decodable>(_ type: T.Type, from: Input) throws -> T
}

extension JSONEncoder: TopLevelEncoder {}
extension JSONDecoder: TopLevelDecoder {}
extension PropertyListEncoder: TopLevelEncoder {}
extension PropertyListDecoder: TopLevelDecoder {}

extension Publishers {
    public struct Encode<Upstream: Publisher, Coder: TopLevelEncoder>: Publisher where Upstream.Output: Encodable {
        public typealias Output = Coder.Output
        public typealias Failure = Error
        public let upstream: Upstream
        private let encoder: Coder
        public init(upstream: Upstream, encoder: Coder) { self.upstream = upstream; self.encoder = encoder }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            let e = encoder
            upstream.tryMap { try e.encode($0) }.receive(subscriber: subscriber)
        }
    }

    public struct Decode<Upstream: Publisher, Output: Decodable, Coder: TopLevelDecoder>: Publisher where Upstream.Output == Coder.Input {
        public typealias Failure = Error
        public let upstream: Upstream
        private let decoder: Coder
        public init(upstream: Upstream, decoder: Coder) { self.upstream = upstream; self.decoder = decoder }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            let d = decoder
            upstream.tryMap { try d.decode(Output.self, from: $0) }.receive(subscriber: subscriber)
        }
    }
}

extension Publisher where Output: Encodable {
    public func encode<Coder: TopLevelEncoder>(encoder: Coder) -> Publishers.Encode<Self, Coder> { .init(upstream: self, encoder: encoder) }
}

extension Publisher {
    public func decode<Item: Decodable, Coder: TopLevelDecoder>(type: Item.Type, decoder: Coder) -> Publishers.Decode<Self, Item, Coder>
    where Output == Coder.Input { .init(upstream: self, decoder: decoder) }
}

// MARK: Buffer

extension Publishers {
    public enum PrefetchStrategy: Equatable, Hashable, Sendable {
        case keepFull
        case byRequest
    }

    public enum BufferingStrategy<Failure: Error> {
        case dropNewest
        case dropOldest
        case customError(() -> Failure)
    }

    public struct Buffer<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let size: Int
        public let prefetch: PrefetchStrategy
        public let whenFull: BufferingStrategy<Failure>
        public init(upstream: Upstream, size: Int, prefetch: PrefetchStrategy, whenFull: BufferingStrategy<Failure>) {
            self.upstream = upstream; self.size = size; self.prefetch = prefetch; self.whenFull = whenFull
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream.subscribe(_BufferInner(subscriber, size: size, whenFull: whenFull))
        }
    }
}

final class _BufferInner<Input, Downstream: Subscriber>: Subscriber, Subscription, @unchecked Sendable where Downstream.Input == Input {
    typealias Failure = Downstream.Failure
    private let lock = NSLock()
    private let downstream: Downstream
    private var upstream: Subscription?
    private var buffer: [Input] = []
    private var demand = Subscribers.Demand.none
    private var completion: Subscribers.Completion<Failure>?
    private var delivering = false
    private var done = false
    let size: Int
    let whenFull: Publishers.BufferingStrategy<Failure>

    init(_ d: Downstream, size: Int, whenFull: Publishers.BufferingStrategy<Failure>) { downstream = d; self.size = Swift.max(1, size); self.whenFull = whenFull }

    func receive(subscription: Subscription) {
        lock.lock(); upstream = subscription; lock.unlock()
        downstream.receive(subscription: self)
        subscription.request(.unlimited)
    }
    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        guard !done else { lock.unlock(); return .none }
        if buffer.count >= size {
            switch whenFull {
            case .dropNewest: lock.unlock(); return .none
            case .dropOldest: buffer.removeFirst(); buffer.append(input)
            case .customError(let make):
                lock.unlock()
                cancelUpstream()
                fail(make())
                return .none
            }
        } else {
            buffer.append(input)
        }
        lock.unlock()
        drain()
        return .none
    }
    func receive(completion c: Subscribers.Completion<Failure>) {
        lock.lock(); completion = c; upstream = nil; lock.unlock()
        if case .failure = c { lock.lock(); buffer.removeAll(); lock.unlock() }
        drain()
    }
    private func fail(_ e: Failure) { lock.lock(); buffer.removeAll(); completion = .failure(e); lock.unlock(); drain() }
    private func cancelUpstream() { lock.lock(); let u = upstream; upstream = nil; lock.unlock(); u?.cancel() }
    func request(_ d: Subscribers.Demand) { lock.lock(); demand += d; lock.unlock(); drain() }
    func cancel() { lock.lock(); done = true; buffer.removeAll(); lock.unlock(); cancelUpstream() }
    private func drain() {
        lock.lock()
        if delivering { lock.unlock(); return }
        delivering = true
        while !done {
            if !buffer.isEmpty, demand > 0 {
                let v = buffer.removeFirst()
                demand -= 1
                lock.unlock()
                let more = downstream.receive(v)
                lock.lock()
                demand += more
                continue
            }
            if buffer.isEmpty, let c = completion {
                done = true
                lock.unlock()
                downstream.receive(completion: c)
                lock.lock()
            }
            break
        }
        delivering = false
        lock.unlock()
    }
}

extension Publisher {
    public func buffer(size: Int, prefetch: Publishers.PrefetchStrategy, whenFull: Publishers.BufferingStrategy<Failure>) -> Publishers.Buffer<Self> {
        .init(upstream: self, size: size, prefetch: prefetch, whenFull: whenFull)
    }
}
