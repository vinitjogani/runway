// Single-upstream operators. Each passes the downstream's demand upstream
// (asking for one more when it drops a value), as Apple's do.

import Foundation

@inline(__always)
func _same<F: Error>(_ c: Subscribers.Completion<F>) -> Subscribers.Completion<F> { c }

extension Publisher {
    @inline(__always)
    func _pipe<S: Subscriber>(_ s: S, _ name: String,
                              _ step: @escaping (Output) -> _Step<S.Input, S.Failure>,
                              _ complete: @escaping (Subscribers.Completion<Failure>) -> Subscribers.Completion<S.Failure>) {
        subscribe(_StepInner<Output, Failure, S>(s, name: name, step: step, complete: complete))
    }
    @inline(__always)
    func _reduce<S: Subscriber>(_ s: S, _ name: String,
                                _ onValue: @escaping (Output) -> _ReduceInner<Output, Failure, S>.Next,
                                _ onFinish: @escaping () -> S.Input?,
                                _ mapFailure: @escaping (Failure) -> S.Failure) {
        subscribe(_ReduceInner<Output, Failure, S>(s, name: name, onValue: onValue, onFinish: onFinish, mapFailure: mapFailure))
    }
}

private func _try<T, E>(_ f: () throws -> T, _ then: (T) -> _Step<E, Error>) -> _Step<E, Error> {
    do { return then(try f()) } catch { return .fail(error) }
}

// MARK: Map family

extension Publishers {
    public struct Map<Upstream: Publisher, Output>: Publisher {
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let transform: (Upstream.Output) -> Output
        public init(upstream: Upstream, transform: @escaping (Upstream.Output) -> Output) { self.upstream = upstream; self.transform = transform }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let t = transform
            upstream._pipe(subscriber, "Map", { .emit(t($0)) }, _same)
        }
    }

    public struct TryMap<Upstream: Publisher, Output>: Publisher {
        public typealias Failure = Error
        public let upstream: Upstream
        public let transform: (Upstream.Output) throws -> Output
        public init(upstream: Upstream, transform: @escaping (Upstream.Output) throws -> Output) { self.upstream = upstream; self.transform = transform }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            let t = transform
            upstream._pipe(subscriber, "TryMap", { v in _try({ try t(v) }) { .emit($0) } }, { $0.eraseError })
        }
    }

    public struct MapError<Upstream: Publisher, Failure: Error>: Publisher {
        public typealias Output = Upstream.Output
        public let upstream: Upstream
        public let transform: (Upstream.Failure) -> Failure
        public init(upstream: Upstream, _ map: @escaping (Upstream.Failure) -> Failure) { self.upstream = upstream; transform = map }
        public init(upstream: Upstream, transform: @escaping (Upstream.Failure) -> Failure) { self.upstream = upstream; self.transform = transform }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let t = transform
            upstream._pipe(subscriber, "MapError", { .emit($0) }, { $0.mapError(t) })
        }
    }

    public struct CompactMap<Upstream: Publisher, Output>: Publisher {
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let transform: (Upstream.Output) -> Output?
        public init(upstream: Upstream, transform: @escaping (Upstream.Output) -> Output?) { self.upstream = upstream; self.transform = transform }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let t = transform
            upstream._pipe(subscriber, "CompactMap", { t($0).map { .emit($0) } ?? .skip }, _same)
        }
    }

    public struct TryCompactMap<Upstream: Publisher, Output>: Publisher {
        public typealias Failure = Error
        public let upstream: Upstream
        public let transform: (Upstream.Output) throws -> Output?
        public init(upstream: Upstream, transform: @escaping (Upstream.Output) throws -> Output?) { self.upstream = upstream; self.transform = transform }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            let t = transform
            upstream._pipe(subscriber, "TryCompactMap", { v in _try({ try t(v) }) { $0.map { .emit($0) } ?? .skip } }, { $0.eraseError })
        }
    }

    public struct Filter<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let isIncluded: (Upstream.Output) -> Bool
        public init(upstream: Upstream, isIncluded: @escaping (Upstream.Output) -> Bool) { self.upstream = upstream; self.isIncluded = isIncluded }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let f = isIncluded
            upstream._pipe(subscriber, "Filter", { f($0) ? .emit($0) : .skip }, _same)
        }
    }

    public struct TryFilter<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error
        public let upstream: Upstream
        public let isIncluded: (Upstream.Output) throws -> Bool
        public init(upstream: Upstream, isIncluded: @escaping (Upstream.Output) throws -> Bool) { self.upstream = upstream; self.isIncluded = isIncluded }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            let f = isIncluded
            upstream._pipe(subscriber, "TryFilter", { v in _try({ try f(v) }) { $0 ? .emit(v) : .skip } }, { $0.eraseError })
        }
    }

    public struct RemoveDuplicates<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let predicate: (Output, Output) -> Bool
        public init(upstream: Upstream, predicate: @escaping (Output, Output) -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let p = predicate
            var last: Output?
            upstream._pipe(subscriber, "RemoveDuplicates", { v in
                defer { last = v }
                if let l = last, p(l, v) { return .skip }
                return .emit(v)
            }, _same)
        }
    }

    public struct TryRemoveDuplicates<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error
        public let upstream: Upstream
        public let predicate: (Output, Output) throws -> Bool
        public init(upstream: Upstream, predicate: @escaping (Output, Output) throws -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            let p = predicate
            var last: Output?
            upstream._pipe(subscriber, "TryRemoveDuplicates", { v in
                defer { last = v }
                guard let l = last else { return .emit(v) }
                return _try({ try p(l, v) }) { $0 ? .skip : .emit(v) }
            }, { $0.eraseError })
        }
    }

    public struct ReplaceError<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Never
        public let upstream: Upstream
        public let output: Output
        public init(upstream: Upstream, output: Output) { self.upstream = upstream; self.output = output }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
            Publishers.Catch(upstream: upstream) { [output] _ in Just(output) }.receive(subscriber: subscriber)
        }
    }

    public struct ReplaceEmpty<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let output: Output
        public init(upstream: Upstream, output: Output) { self.upstream = upstream; self.output = output }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let o = output
            upstream.append_ifEmpty(o).receive(subscriber: subscriber)
        }
    }

    public struct Scan<Upstream: Publisher, Output>: Publisher {
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let initialResult: Output
        public let nextPartialResult: (Output, Upstream.Output) -> Output
        public init(upstream: Upstream, initialResult: Output, nextPartialResult: @escaping (Output, Upstream.Output) -> Output) {
            self.upstream = upstream; self.initialResult = initialResult; self.nextPartialResult = nextPartialResult
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var acc = initialResult
            let f = nextPartialResult
            upstream._pipe(subscriber, "Scan", { acc = f(acc, $0); return .emit(acc) }, _same)
        }
    }

    public struct TryScan<Upstream: Publisher, Output>: Publisher {
        public typealias Failure = Error
        public let upstream: Upstream
        public let initialResult: Output
        public let nextPartialResult: (Output, Upstream.Output) throws -> Output
        public init(upstream: Upstream, initialResult: Output, nextPartialResult: @escaping (Output, Upstream.Output) throws -> Output) {
            self.upstream = upstream; self.initialResult = initialResult; self.nextPartialResult = nextPartialResult
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            var acc = initialResult
            let f = nextPartialResult
            upstream._pipe(subscriber, "TryScan", { v in _try({ try f(acc, v) }) { acc = $0; return .emit($0) } }, { $0.eraseError })
        }
    }

    public struct SetFailureType<Upstream: Publisher, Failure: Error>: Publisher where Upstream.Failure == Never {
        public typealias Output = Upstream.Output
        public let upstream: Upstream
        public init(upstream: Upstream) { self.upstream = upstream }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream._pipe(subscriber, "SetFailureType", { .emit($0) }, { _ in .finished })
        }
        public func setFailureType<E: Error>(to failure: E.Type) -> Publishers.SetFailureType<Upstream, E> { .init(upstream: upstream) }
    }

    public struct IgnoreOutput<Upstream: Publisher>: Publisher {
        public typealias Output = Never
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public init(upstream: Upstream) { self.upstream = upstream }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Never, S.Failure == Failure {
            upstream._reduce(subscriber, "IgnoreOutput", { _ in .continue }, { nil }, { $0 })
        }
    }

    public struct HandleEvents<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public var receiveSubscription: ((Subscription) -> Void)?
        public var receiveOutput: ((Upstream.Output) -> Void)?
        public var receiveCompletion: ((Subscribers.Completion<Upstream.Failure>) -> Void)?
        public var receiveCancel: (() -> Void)?
        public var receiveRequest: ((Subscribers.Demand) -> Void)?
        public init(upstream: Upstream, receiveSubscription: ((Subscription) -> Void)? = nil, receiveOutput: ((Output) -> Void)? = nil,
                    receiveCompletion: ((Subscribers.Completion<Failure>) -> Void)? = nil, receiveCancel: (() -> Void)? = nil,
                    receiveRequest: ((Subscribers.Demand) -> Void)?) {
            self.upstream = upstream
            self.receiveSubscription = receiveSubscription
            self.receiveOutput = receiveOutput
            self.receiveCompletion = receiveCompletion
            self.receiveCancel = receiveCancel
            self.receiveRequest = receiveRequest
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream.subscribe(_HandleEventsInner(subscriber, self))
        }
    }
}

final class _HandleEventsInner<Upstream: Publisher, Downstream: Subscriber>: Subscriber, Subscription, CustomStringConvertible, @unchecked Sendable
where Downstream.Input == Upstream.Output, Downstream.Failure == Upstream.Failure {
    typealias Input = Upstream.Output
    typealias Failure = Upstream.Failure
    let downstream: Downstream
    let ops: Publishers.HandleEvents<Upstream>
    private let lock = NSLock()
    private var upstream: Subscription?
    var description: String { "HandleEvents" }
    init(_ d: Downstream, _ ops: Publishers.HandleEvents<Upstream>) { downstream = d; self.ops = ops }
    func receive(subscription: Subscription) {
        lock.lock(); upstream = subscription; lock.unlock()
        ops.receiveSubscription?(subscription)
        downstream.receive(subscription: self)
    }
    func receive(_ input: Input) -> Subscribers.Demand {
        ops.receiveOutput?(input)
        let d = downstream.receive(input)
        if d > 0 { ops.receiveRequest?(d) }
        return d
    }
    func receive(completion: Subscribers.Completion<Failure>) {
        lock.lock(); upstream = nil; lock.unlock()
        ops.receiveCompletion?(completion)
        downstream.receive(completion: completion)
    }
    func request(_ demand: Subscribers.Demand) {
        ops.receiveRequest?(demand)
        lock.lock(); let u = upstream; lock.unlock()
        u?.request(demand)
    }
    func cancel() {
        lock.lock(); let u = upstream; upstream = nil; lock.unlock()
        guard let u else { return }
        ops.receiveCancel?()
        u.cancel()
    }
}

// MARK: Element selection

extension Publishers {
    public struct Drop<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let count: Int
        public init(upstream: Upstream, count: Int) { self.upstream = upstream; self.count = count }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var remaining = count
            upstream._pipe(subscriber, "Drop", { v in
                if remaining > 0 { remaining -= 1; return .skip }
                return .emit(v)
            }, _same)
        }
    }

    public struct DropWhile<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let predicate: (Output) -> Bool
        public init(upstream: Upstream, predicate: @escaping (Output) -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var dropping = true
            let p = predicate
            upstream._pipe(subscriber, "DropWhile", { v in
                if dropping, p(v) { return .skip }
                dropping = false
                return .emit(v)
            }, _same)
        }
    }

    public struct TryDropWhile<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error
        public let upstream: Upstream
        public let predicate: (Output) throws -> Bool
        public init(upstream: Upstream, predicate: @escaping (Output) throws -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            var dropping = true
            let p = predicate
            upstream._pipe(subscriber, "TryDropWhile", { v in
                guard dropping else { return .emit(v) }
                return _try({ try p(v) }) { drop in
                    if drop { return .skip }
                    dropping = false
                    return .emit(v)
                }
            }, { $0.eraseError })
        }
    }

    public struct Output<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let range: CountableRange<Int>
        public init(upstream: Upstream, range: CountableRange<Int>) { self.upstream = upstream; self.range = range }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Upstream.Output, S.Failure == Failure {
            var index = 0
            let r = range
            if r.isEmpty {
                upstream._pipe(subscriber, "Output", { _ in .finish }, _same)
                return
            }
            upstream._pipe(subscriber, "Output", { v in
                defer { index += 1 }
                if index < r.lowerBound { return .skip }
                if index == r.upperBound - 1 { return .emitAndFinish(v) }
                return .emit(v)
            }, _same)
        }
    }

    public struct PrefixWhile<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let predicate: (Upstream.Output) -> Bool
        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let p = predicate
            upstream._pipe(subscriber, "PrefixWhile", { p($0) ? .emit($0) : .finish }, _same)
        }
    }

    public struct TryPrefixWhile<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error
        public let upstream: Upstream
        public let predicate: (Upstream.Output) throws -> Bool
        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) throws -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            let p = predicate
            upstream._pipe(subscriber, "TryPrefixWhile", { v in _try({ try p(v) }) { $0 ? .emit(v) : .finish } }, { $0.eraseError })
        }
    }

    public struct First<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public init(upstream: Upstream) { self.upstream = upstream }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            upstream._reduce(subscriber, "First", { .finish($0) }, { nil }, { $0 })
        }
    }

    public struct FirstWhere<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let predicate: (Output) -> Bool
        public init(upstream: Upstream, predicate: @escaping (Output) -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let p = predicate
            upstream._reduce(subscriber, "FirstWhere", { p($0) ? .finish($0) : .continue }, { nil }, { $0 })
        }
    }

    public struct TryFirstWhere<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error
        public let upstream: Upstream
        public let predicate: (Output) throws -> Bool
        public init(upstream: Upstream, predicate: @escaping (Output) throws -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            let p = predicate
            upstream._reduce(subscriber, "TryFirstWhere", { v in
                do { return try p(v) ? .finish(v) : .continue } catch { return .fail(error) }
            }, { nil }, { $0 })
        }
    }

    public struct Last<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public init(upstream: Upstream) { self.upstream = upstream }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var last: Output?
            upstream._reduce(subscriber, "Last", { last = $0; return .continue }, { last }, { $0 })
        }
    }

    public struct LastWhere<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let predicate: (Output) -> Bool
        public init(upstream: Upstream, predicate: @escaping (Output) -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var last: Output?
            let p = predicate
            upstream._reduce(subscriber, "LastWhere", { if p($0) { last = $0 }; return .continue }, { last }, { $0 })
        }
    }

    public struct TryLastWhere<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error
        public let upstream: Upstream
        public let predicate: (Output) throws -> Bool
        public init(upstream: Upstream, predicate: @escaping (Output) throws -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            var last: Output?
            let p = predicate
            upstream._reduce(subscriber, "TryLastWhere", { v in
                do { if try p(v) { last = v }; return .continue } catch { return .fail(error) }
            }, { last }, { $0 })
        }
    }
}

// MARK: Reducing

extension Publishers {
    public struct Collect<Upstream: Publisher>: Publisher {
        public typealias Output = [Upstream.Output]
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public init(upstream: Upstream) { self.upstream = upstream }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var all: [Upstream.Output] = []
            upstream._reduce(subscriber, "Collect", { all.append($0); return .continue }, { all }, { $0 })
        }
    }

    public struct CollectByCount<Upstream: Publisher>: Publisher {
        public typealias Output = [Upstream.Output]
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let count: Int
        public init(upstream: Upstream, count: Int) { self.upstream = upstream; self.count = count }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let n = Swift.max(1, count)
            let conduit = _Conduit(subscriber, name: "CollectByCount")
            var batch: [Upstream.Output] = []
            let up = _ClosureSubscriber<Upstream.Output, Failure>({ v in
                batch.append(v)
                if batch.count == n { conduit.send(batch); batch.removeAll() }
                return .none
            }, { c in
                if case .finished = c, !batch.isEmpty { conduit.send(batch) }
                if case .failure = c { conduit.fail(c) } else { conduit.finish(c) }
            })
            conduit.onCancel = { up.cancel() }
            conduit.start()
            upstream.subscribe(up)
        }
    }

    public struct Count<Upstream: Publisher>: Publisher {
        public typealias Output = Int
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public init(upstream: Upstream) { self.upstream = upstream }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Int, S.Failure == Failure {
            var n = 0
            upstream._reduce(subscriber, "Count", { _ in n += 1; return .continue }, { n }, { $0 })
        }
    }

    public struct Reduce<Upstream: Publisher, Output>: Publisher {
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let initial: Output
        public let nextPartialResult: (Output, Upstream.Output) -> Output
        public init(upstream: Upstream, initial: Output, nextPartialResult: @escaping (Output, Upstream.Output) -> Output) {
            self.upstream = upstream; self.initial = initial; self.nextPartialResult = nextPartialResult
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var acc = initial
            let f = nextPartialResult
            upstream._reduce(subscriber, "Reduce", { acc = f(acc, $0); return .continue }, { acc }, { $0 })
        }
    }

    public struct TryReduce<Upstream: Publisher, Output>: Publisher {
        public typealias Failure = Error
        public let upstream: Upstream
        public let initial: Output
        public let nextPartialResult: (Output, Upstream.Output) throws -> Output
        public init(upstream: Upstream, initial: Output, nextPartialResult: @escaping (Output, Upstream.Output) throws -> Output) {
            self.upstream = upstream; self.initial = initial; self.nextPartialResult = nextPartialResult
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            var acc = initial
            let f = nextPartialResult
            upstream._reduce(subscriber, "TryReduce", { v in
                do { acc = try f(acc, v); return .continue } catch { return .fail(error) }
            }, { acc }, { $0 })
        }
    }

    public struct Comparison<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let areInIncreasingOrder: (Upstream.Output, Upstream.Output) -> Bool
        public init(upstream: Upstream, areInIncreasingOrder: @escaping (Upstream.Output, Upstream.Output) -> Bool) {
            self.upstream = upstream; self.areInIncreasingOrder = areInIncreasingOrder
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var best: Output?
            let ordered = areInIncreasingOrder
            // `max` passes a reversed predicate; keep the later of equals.
            upstream._reduce(subscriber, "Comparison", { v in
                if let b = best { if ordered(b, v) { best = v } } else { best = v }
                return .continue
            }, { best }, { $0 })
        }
    }

    public struct TryComparison<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error
        public let upstream: Upstream
        public let areInIncreasingOrder: (Upstream.Output, Upstream.Output) throws -> Bool
        public init(upstream: Upstream, areInIncreasingOrder: @escaping (Upstream.Output, Upstream.Output) throws -> Bool) {
            self.upstream = upstream; self.areInIncreasingOrder = areInIncreasingOrder
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Error {
            var best: Output?
            let ordered = areInIncreasingOrder
            upstream._reduce(subscriber, "TryComparison", { v in
                do {
                    if let b = best { if try ordered(b, v) { best = v } } else { best = v }
                    return .continue
                } catch { return .fail(error) }
            }, { best }, { $0 })
        }
    }

    public struct ContainsWhere<Upstream: Publisher>: Publisher {
        public typealias Output = Bool
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let predicate: (Upstream.Output) -> Bool
        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Bool, S.Failure == Failure {
            let p = predicate
            upstream._reduce(subscriber, "ContainsWhere", { p($0) ? .finish(true) : .continue }, { false }, { $0 })
        }
    }

    public struct TryContainsWhere<Upstream: Publisher>: Publisher {
        public typealias Output = Bool
        public typealias Failure = Error
        public let upstream: Upstream
        public let predicate: (Upstream.Output) throws -> Bool
        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) throws -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Bool, S.Failure == Error {
            let p = predicate
            upstream._reduce(subscriber, "TryContainsWhere", { v in
                do { return try p(v) ? .finish(true) : .continue } catch { return .fail(error) }
            }, { false }, { $0 })
        }
    }

    public struct Contains<Upstream: Publisher>: Publisher where Upstream.Output: Equatable {
        public typealias Output = Bool
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let output: Upstream.Output
        public init(upstream: Upstream, output: Upstream.Output) { self.upstream = upstream; self.output = output }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Bool, S.Failure == Failure {
            let o = output
            upstream._reduce(subscriber, "Contains", { $0 == o ? .finish(true) : .continue }, { false }, { $0 })
        }
    }

    public struct AllSatisfy<Upstream: Publisher>: Publisher {
        public typealias Output = Bool
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let predicate: (Upstream.Output) -> Bool
        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Bool, S.Failure == Failure {
            let p = predicate
            upstream._reduce(subscriber, "AllSatisfy", { p($0) ? .continue : .finish(false) }, { true }, { $0 })
        }
    }

    public struct TryAllSatisfy<Upstream: Publisher>: Publisher {
        public typealias Output = Bool
        public typealias Failure = Error
        public let upstream: Upstream
        public let predicate: (Upstream.Output) throws -> Bool
        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) throws -> Bool) { self.upstream = upstream; self.predicate = predicate }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Bool, S.Failure == Error {
            let p = predicate
            upstream._reduce(subscriber, "TryAllSatisfy", { v in
                do { return try p(v) ? .continue : .finish(false) } catch { return .fail(error) }
            }, { true }, { $0 })
        }
    }

    public struct AssertNoFailure<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Never
        public let upstream: Upstream
        public let prefix: String
        public let file: StaticString
        public let line: UInt
        public init(upstream: Upstream, prefix: String, file: StaticString, line: UInt) {
            self.upstream = upstream; self.prefix = prefix; self.file = file; self.line = line
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
            let (p, f, l) = (prefix, file, line)
            upstream._pipe(subscriber, "AssertNoFailure", { .emit($0) }, { c in
                if case .failure(let e) = c { fatalError("\(p)\(p.isEmpty ? "" : " ")\(e)", file: f, line: l) }
                return .finished
            })
        }
    }

    public struct Print<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let prefix: String
        public let upstream: Upstream
        public let stream: TextOutputStream?
        public init(upstream: Upstream, prefix: String, to stream: TextOutputStream? = nil) {
            self.upstream = upstream; self.prefix = prefix; self.stream = stream
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let p = prefix.isEmpty ? "" : prefix + ": "
            let out = _StreamBox(stream)
            func log(_ s: String) { if out.stream != nil { out.stream!.write(p + s + "\n") } else { Swift.print(p + s) } }
            Publishers.HandleEvents(upstream: upstream,
                                    receiveSubscription: { _ in log("receive subscription: (\(upstream))") },
                                    receiveOutput: { log("receive value: (\($0))") },
                                    receiveCompletion: { c in
                                        switch c {
                                        case .finished: log("receive finished")
                                        case .failure(let e): log("receive error: (\(e))")
                                        }
                                    },
                                    receiveCancel: { log("receive cancel") },
                                    receiveRequest: { log("request \($0)") })
                .receive(subscriber: subscriber)
        }
    }

    public struct Breakpoint<Upstream: Publisher>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let receiveSubscription: ((Subscription) -> Bool)?
        public let receiveOutput: ((Upstream.Output) -> Bool)?
        public let receiveCompletion: ((Subscribers.Completion<Failure>) -> Bool)?
        public init(upstream: Upstream, receiveSubscription: ((Subscription) -> Bool)? = nil,
                    receiveOutput: ((Upstream.Output) -> Bool)? = nil, receiveCompletion: ((Subscribers.Completion<Failure>) -> Bool)? = nil) {
            self.upstream = upstream; self.receiveSubscription = receiveSubscription
            self.receiveOutput = receiveOutput; self.receiveCompletion = receiveCompletion
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            // Raising SIGTRAP without a debugger would kill the process;
            // Runway evaluates the predicates and keeps going.
            let (rs, ro, rc) = (receiveSubscription, receiveOutput, receiveCompletion)
            Publishers.HandleEvents(upstream: upstream, receiveSubscription: { _ = rs?($0) }, receiveOutput: { _ = ro?($0) },
                                    receiveCompletion: { _ = rc?($0) }, receiveCancel: nil, receiveRequest: nil)
                .receive(subscriber: subscriber)
        }
    }
}

// MARK: Operator methods

extension Publisher {
    public func map<T>(_ transform: @escaping (Output) -> T) -> Publishers.Map<Self, T> { .init(upstream: self, transform: transform) }
    public func tryMap<T>(_ transform: @escaping (Output) throws -> T) -> Publishers.TryMap<Self, T> { .init(upstream: self, transform: transform) }
    public func mapError<E: Error>(_ transform: @escaping (Failure) -> E) -> Publishers.MapError<Self, E> { .init(upstream: self, transform: transform) }
    public func map<T>(_ keyPath: KeyPath<Output, T>) -> Publishers.Map<Self, T> { map { $0[keyPath: keyPath] } }
    public func map<T0, T1>(_ k0: KeyPath<Output, T0>, _ k1: KeyPath<Output, T1>) -> Publishers.Map<Self, (T0, T1)> {
        map { ($0[keyPath: k0], $0[keyPath: k1]) }
    }
    public func map<T0, T1, T2>(_ k0: KeyPath<Output, T0>, _ k1: KeyPath<Output, T1>, _ k2: KeyPath<Output, T2>) -> Publishers.Map<Self, (T0, T1, T2)> {
        map { ($0[keyPath: k0], $0[keyPath: k1], $0[keyPath: k2]) }
    }
    public func compactMap<T>(_ transform: @escaping (Output) -> T?) -> Publishers.CompactMap<Self, T> { .init(upstream: self, transform: transform) }
    public func tryCompactMap<T>(_ transform: @escaping (Output) throws -> T?) -> Publishers.TryCompactMap<Self, T> { .init(upstream: self, transform: transform) }
    public func filter(_ isIncluded: @escaping (Output) -> Bool) -> Publishers.Filter<Self> { .init(upstream: self, isIncluded: isIncluded) }
    public func tryFilter(_ isIncluded: @escaping (Output) throws -> Bool) -> Publishers.TryFilter<Self> { .init(upstream: self, isIncluded: isIncluded) }
    public func removeDuplicates(by predicate: @escaping (Output, Output) -> Bool) -> Publishers.RemoveDuplicates<Self> { .init(upstream: self, predicate: predicate) }
    public func tryRemoveDuplicates(by predicate: @escaping (Output, Output) throws -> Bool) -> Publishers.TryRemoveDuplicates<Self> { .init(upstream: self, predicate: predicate) }
    public func replaceError(with output: Output) -> Publishers.ReplaceError<Self> { .init(upstream: self, output: output) }
    public func replaceEmpty(with output: Output) -> Publishers.ReplaceEmpty<Self> { .init(upstream: self, output: output) }
    public func scan<T>(_ initialResult: T, _ nextPartialResult: @escaping (T, Output) -> T) -> Publishers.Scan<Self, T> {
        .init(upstream: self, initialResult: initialResult, nextPartialResult: nextPartialResult)
    }
    public func tryScan<T>(_ initialResult: T, _ nextPartialResult: @escaping (T, Output) throws -> T) -> Publishers.TryScan<Self, T> {
        .init(upstream: self, initialResult: initialResult, nextPartialResult: nextPartialResult)
    }
    public func reduce<T>(_ initialResult: T, _ nextPartialResult: @escaping (T, Output) -> T) -> Publishers.Reduce<Self, T> {
        .init(upstream: self, initial: initialResult, nextPartialResult: nextPartialResult)
    }
    public func tryReduce<T>(_ initialResult: T, _ nextPartialResult: @escaping (T, Output) throws -> T) -> Publishers.TryReduce<Self, T> {
        .init(upstream: self, initial: initialResult, nextPartialResult: nextPartialResult)
    }
    public func ignoreOutput() -> Publishers.IgnoreOutput<Self> { .init(upstream: self) }
    public func collect() -> Publishers.Collect<Self> { .init(upstream: self) }
    public func collect(_ count: Int) -> Publishers.CollectByCount<Self> { .init(upstream: self, count: count) }
    public func count() -> Publishers.Count<Self> { .init(upstream: self) }
    public func first() -> Publishers.First<Self> { .init(upstream: self) }
    public func first(where predicate: @escaping (Output) -> Bool) -> Publishers.FirstWhere<Self> { .init(upstream: self, predicate: predicate) }
    public func tryFirst(where predicate: @escaping (Output) throws -> Bool) -> Publishers.TryFirstWhere<Self> { .init(upstream: self, predicate: predicate) }
    public func last() -> Publishers.Last<Self> { .init(upstream: self) }
    public func last(where predicate: @escaping (Output) -> Bool) -> Publishers.LastWhere<Self> { .init(upstream: self, predicate: predicate) }
    public func tryLast(where predicate: @escaping (Output) throws -> Bool) -> Publishers.TryLastWhere<Self> { .init(upstream: self, predicate: predicate) }
    public func dropFirst(_ count: Int = 1) -> Publishers.Drop<Self> { .init(upstream: self, count: count) }
    public func drop(while predicate: @escaping (Output) -> Bool) -> Publishers.DropWhile<Self> { .init(upstream: self, predicate: predicate) }
    public func tryDrop(while predicate: @escaping (Output) throws -> Bool) -> Publishers.TryDropWhile<Self> { .init(upstream: self, predicate: predicate) }
    public func prefix(_ maxLength: Int) -> Publishers.Output<Self> { .init(upstream: self, range: 0..<maxLength) }
    public func prefix(while predicate: @escaping (Output) -> Bool) -> Publishers.PrefixWhile<Self> { .init(upstream: self, predicate: predicate) }
    public func tryPrefix(while predicate: @escaping (Output) throws -> Bool) -> Publishers.TryPrefixWhile<Self> { .init(upstream: self, predicate: predicate) }
    public func output(at index: Int) -> Publishers.Output<Self> { .init(upstream: self, range: index..<(index + 1)) }
    public func output<R: RangeExpression>(in range: R) -> Publishers.Output<Self> where R.Bound == Int {
        .init(upstream: self, range: range.relative(to: 0..<Int.max))
    }
    public func contains(where predicate: @escaping (Output) -> Bool) -> Publishers.ContainsWhere<Self> { .init(upstream: self, predicate: predicate) }
    public func tryContains(where predicate: @escaping (Output) throws -> Bool) -> Publishers.TryContainsWhere<Self> { .init(upstream: self, predicate: predicate) }
    public func allSatisfy(_ predicate: @escaping (Output) -> Bool) -> Publishers.AllSatisfy<Self> { .init(upstream: self, predicate: predicate) }
    public func tryAllSatisfy(_ predicate: @escaping (Output) throws -> Bool) -> Publishers.TryAllSatisfy<Self> { .init(upstream: self, predicate: predicate) }
    public func min(by areInIncreasingOrder: @escaping (Output, Output) -> Bool) -> Publishers.Comparison<Self> {
        .init(upstream: self, areInIncreasingOrder: { a, b in areInIncreasingOrder(b, a) })
    }
    public func max(by areInIncreasingOrder: @escaping (Output, Output) -> Bool) -> Publishers.Comparison<Self> {
        .init(upstream: self, areInIncreasingOrder: { a, b in !areInIncreasingOrder(b, a) })
    }
    public func tryMin(by areInIncreasingOrder: @escaping (Output, Output) throws -> Bool) -> Publishers.TryComparison<Self> {
        .init(upstream: self, areInIncreasingOrder: { a, b in try areInIncreasingOrder(b, a) })
    }
    public func tryMax(by areInIncreasingOrder: @escaping (Output, Output) throws -> Bool) -> Publishers.TryComparison<Self> {
        .init(upstream: self, areInIncreasingOrder: { a, b in try !areInIncreasingOrder(b, a) })
    }
    public func handleEvents(receiveSubscription: ((Subscription) -> Void)? = nil, receiveOutput: ((Output) -> Void)? = nil,
                             receiveCompletion: ((Subscribers.Completion<Failure>) -> Void)? = nil, receiveCancel: (() -> Void)? = nil,
                             receiveRequest: ((Subscribers.Demand) -> Void)? = nil) -> Publishers.HandleEvents<Self> {
        .init(upstream: self, receiveSubscription: receiveSubscription, receiveOutput: receiveOutput,
              receiveCompletion: receiveCompletion, receiveCancel: receiveCancel, receiveRequest: receiveRequest)
    }
    public func print(_ prefix: String = "", to stream: TextOutputStream? = nil) -> Publishers.Print<Self> {
        .init(upstream: self, prefix: prefix, to: stream)
    }
    public func breakpoint(receiveSubscription: ((Subscription) -> Bool)? = nil, receiveOutput: ((Output) -> Bool)? = nil,
                           receiveCompletion: ((Subscribers.Completion<Failure>) -> Bool)? = nil) -> Publishers.Breakpoint<Self> {
        .init(upstream: self, receiveSubscription: receiveSubscription, receiveOutput: receiveOutput, receiveCompletion: receiveCompletion)
    }
    public func breakpointOnError() -> Publishers.Breakpoint<Self> {
        .init(upstream: self, receiveCompletion: { if case .failure = $0 { return true }; return false })
    }
    public func assertNoFailure(_ prefix: String = "", file: StaticString = #file, line: UInt = #line) -> Publishers.AssertNoFailure<Self> {
        .init(upstream: self, prefix: prefix, file: file, line: line)
    }
}

extension Publisher where Failure == Never {
    public func setFailureType<E: Error>(to failureType: E.Type) -> Publishers.SetFailureType<Self, E> { .init(upstream: self) }
}

extension Publisher where Output: Equatable {
    public func removeDuplicates() -> Publishers.RemoveDuplicates<Self> { removeDuplicates(by: ==) }
    public func contains(_ output: Output) -> Publishers.Contains<Self> { .init(upstream: self, output: output) }
}

extension Publisher where Output: Comparable {
    public func min() -> Publishers.Comparison<Self> { min(by: <) }
    public func max() -> Publishers.Comparison<Self> { max(by: <) }
}

extension Publisher {
    public func replaceNil<T>(with output: T) -> Publishers.Map<Self, T> where Output == T? { map { $0 ?? output } }
}

extension Publisher {
    /// Upstream, or `value` if it finishes without emitting.
    func append_ifEmpty(_ value: Output) -> AnyPublisher<Output, Failure> {
        let upstream = self
        return AnyPublisher(_AnonymousPublisher<Output, Failure> { subscriber in
            var sawValue = false
            let conduit = _Conduit(subscriber, name: "ReplaceEmpty")
            let up = _ClosureSubscriber<Output, Failure>({ v in sawValue = true; conduit.send(v); return .none }, { c in
                if case .finished = c, !sawValue { conduit.send(value) }
                conduit.finish(c)
            })
            conduit.onCancel = { up.cancel() }
            conduit.start()
            upstream.subscribe(up)
        })
    }
}

/// A publisher from a subscribe closure.
struct _AnonymousPublisher<Output, Failure: Error>: Publisher {
    let body: (AnySubscriber<Output, Failure>) -> Void
    init(_ body: @escaping (AnySubscriber<Output, Failure>) -> Void) { self.body = body }
    func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure { body(AnySubscriber(subscriber)) }
}

final class _StreamBox: @unchecked Sendable {
    var stream: TextOutputStream?
    init(_ s: TextOutputStream?) { stream = s }
}
