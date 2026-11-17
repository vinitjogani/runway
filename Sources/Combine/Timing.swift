// Scheduler-driven operators: receive(on:), subscribe(on:), debounce,
// throttle, delay, timeout, measureInterval, collect(.byTime).

import Foundation

extension Publishers {
    public struct ReceiveOn<Upstream: Publisher, Context: Scheduler>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let scheduler: Context
        public let options: Context.SchedulerOptions?
        public init(upstream: Upstream, scheduler: Context, options: Context.SchedulerOptions?) {
            self.upstream = upstream; self.scheduler = scheduler; self.options = options
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let (sch, opt) = (scheduler, options)
            let join = _Join(subscriber, name: "ReceiveOn")
            join.conduit.deliverVia = { work in sch.schedule(options: opt, work) }
            join.conduit.start()
            join.subscribe(upstream, value: { v in sch.schedule(options: opt) { join.send(v) } },
                           completion: { c in sch.schedule(options: opt) { join.complete(c) } })
        }
    }

    public struct SubscribeOn<Upstream: Publisher, Context: Scheduler>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let scheduler: Context
        public let options: Context.SchedulerOptions?
        public init(upstream: Upstream, scheduler: Context, options: Context.SchedulerOptions?) {
            self.upstream = upstream; self.scheduler = scheduler; self.options = options
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let up = upstream
            scheduler.schedule(options: options) { up.subscribe(subscriber) }
        }
    }

    public struct Debounce<Upstream: Publisher, Context: Scheduler>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let dueTime: Context.SchedulerTimeType.Stride
        public let scheduler: Context
        public let options: Context.SchedulerOptions?
        public init(upstream: Upstream, dueTime: Context.SchedulerTimeType.Stride, scheduler: Context, options: Context.SchedulerOptions?) {
            self.upstream = upstream; self.dueTime = dueTime; self.scheduler = scheduler; self.options = options
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let (sch, opt, due) = (scheduler, options, dueTime)
            let join = _Join(subscriber, name: "Debounce")
            join.conduit.start()
            var generation = 0
            join.subscribe(upstream, value: { v in
                generation += 1
                let mine = generation
                sch.schedule(after: sch.now.advanced(by: due), tolerance: sch.minimumTolerance, options: opt) {
                    join.lock.lock()
                    let current = mine == generation
                    join.lock.unlock()
                    if current { join.send(v) }
                }
            }, completion: { c in
                // As Apple's: completion cancels a pending value.
                generation += 1
                sch.schedule(options: opt) { join.complete(c) }
            })
        }
    }

    public struct Throttle<Upstream: Publisher, Context: Scheduler>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let interval: Context.SchedulerTimeType.Stride
        public let scheduler: Context
        public let latest: Bool
        public init(upstream: Upstream, interval: Context.SchedulerTimeType.Stride, scheduler: Context, latest: Bool) {
            self.upstream = upstream; self.interval = interval; self.scheduler = scheduler; self.latest = latest
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let (sch, interval, latest) = (scheduler, self.interval, self.latest)
            let join = _Join(subscriber, name: "Throttle")
            join.conduit.start()
            var lastEmit: Context.SchedulerTimeType?
            var pending: Output?
            var windowOpen = false
            func closeWindow() {
                join.lock.lock()
                if let p = pending {
                    pending = nil
                    lastEmit = sch.now
                    join.send(p)
                    sch.schedule(after: sch.now.advanced(by: interval), tolerance: sch.minimumTolerance, options: nil) { closeWindow() }
                } else {
                    windowOpen = false
                }
                join.lock.unlock()
            }
            join.subscribe(upstream, value: { v in
                let now = sch.now
                if !windowOpen, lastEmit.map({ $0.distance(to: now) >= interval }) ?? true {
                    lastEmit = now
                    windowOpen = true
                    sch.schedule(options: nil) { join.send(v) }
                    sch.schedule(after: now.advanced(by: interval), tolerance: sch.minimumTolerance, options: nil) { closeWindow() }
                } else {
                    if latest || pending == nil { pending = v }
                    if !windowOpen {
                        windowOpen = true
                        sch.schedule(after: (lastEmit ?? now).advanced(by: interval), tolerance: sch.minimumTolerance, options: nil) { closeWindow() }
                    }
                }
            }, completion: { c in
                sch.schedule(options: nil) {
                    join.lock.lock()
                    if case .finished = c, let p = pending { join.send(p) }
                    pending = nil
                    join.lock.unlock()
                    join.complete(c)
                }
            })
        }
    }

    public struct Delay<Upstream: Publisher, Context: Scheduler>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let interval: Context.SchedulerTimeType.Stride
        public let tolerance: Context.SchedulerTimeType.Stride
        public let scheduler: Context
        public let options: Context.SchedulerOptions?
        public init(upstream: Upstream, interval: Context.SchedulerTimeType.Stride, tolerance: Context.SchedulerTimeType.Stride,
                    scheduler: Context, options: Context.SchedulerOptions? = nil) {
            self.upstream = upstream; self.interval = interval; self.tolerance = tolerance; self.scheduler = scheduler; self.options = options
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let (sch, opt, iv, tol) = (scheduler, options, interval, tolerance)
            let join = _Join(subscriber, name: "Delay")
            join.conduit.start()
            join.subscribe(upstream, value: { v in
                sch.schedule(after: sch.now.advanced(by: iv), tolerance: tol, options: opt) { join.send(v) }
            }, completion: { c in
                sch.schedule(after: sch.now.advanced(by: iv), tolerance: tol, options: opt) { join.complete(c) }
            })
        }
    }

    public struct Timeout<Upstream: Publisher, Context: Scheduler>: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let interval: Context.SchedulerTimeType.Stride
        public let scheduler: Context
        public let options: Context.SchedulerOptions?
        public let customError: (() -> Upstream.Failure)?
        public init(upstream: Upstream, interval: Context.SchedulerTimeType.Stride, scheduler: Context,
                    options: Context.SchedulerOptions?, customError: (() -> Upstream.Failure)?) {
            self.upstream = upstream; self.interval = interval; self.scheduler = scheduler; self.options = options; self.customError = customError
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let (sch, opt, iv, err) = (scheduler, options, interval, customError)
            let join = _Join(subscriber, name: "Timeout")
            join.conduit.start()
            var generation = 0
            func arm() {
                generation += 1
                let mine = generation
                sch.schedule(after: sch.now.advanced(by: iv), tolerance: sch.minimumTolerance, options: opt) {
                    join.lock.lock()
                    let fire = mine == generation
                    join.lock.unlock()
                    if fire { join.complete(err.map { .failure($0()) } ?? .finished) }
                }
            }
            join.lock.lock(); arm(); join.lock.unlock()
            join.subscribe(upstream, value: { v in
                arm()
                sch.schedule(options: opt) { join.send(v) }
            }, completion: { c in
                generation += 1
                sch.schedule(options: opt) { join.complete(c) }
            })
        }
    }

    public struct MeasureInterval<Upstream: Publisher, Context: Scheduler>: Publisher {
        public typealias Output = Context.SchedulerTimeType.Stride
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let scheduler: Context
        public init(upstream: Upstream, scheduler: Context) { self.upstream = upstream; self.scheduler = scheduler }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let sch = scheduler
            var last = sch.now
            upstream._pipe(subscriber, "MeasureInterval", { _ in
                let now = sch.now
                defer { last = now }
                return .emit(last.distance(to: now))
            }, _same)
        }
    }

    public enum TimeGroupingStrategy<Context: Scheduler> {
        case byTime(Context, Context.SchedulerTimeType.Stride)
        case byTimeOrCount(Context, Context.SchedulerTimeType.Stride, Int)
    }

    public struct CollectByTime<Upstream: Publisher, Context: Scheduler>: Publisher {
        public typealias Output = [Upstream.Output]
        public typealias Failure = Upstream.Failure
        public let upstream: Upstream
        public let strategy: TimeGroupingStrategy<Context>
        public let options: Context.SchedulerOptions?
        public init(upstream: Upstream, strategy: TimeGroupingStrategy<Context>, options: Context.SchedulerOptions?) {
            self.upstream = upstream; self.strategy = strategy; self.options = options
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            let (sch, stride, maxCount): (Context, Context.SchedulerTimeType.Stride, Int)
            switch strategy {
            case .byTime(let c, let s): (sch, stride, maxCount) = (c, s, .max)
            case .byTimeOrCount(let c, let s, let n): (sch, stride, maxCount) = (c, s, Swift.max(1, n))
            }
            let opt = options
            let join = _Join(subscriber, name: "CollectByTime")
            var batch: [Upstream.Output] = []
            func flush() { if !batch.isEmpty { let b = batch; batch.removeAll(); join.send(b) } }
            let timer = sch.schedule(after: sch.now.advanced(by: stride), interval: stride, tolerance: sch.minimumTolerance, options: opt) {
                join.lock.lock(); flush(); join.lock.unlock()
            }
            join.add(AnyCancellable { timer.cancel() })
            join.conduit.start()
            join.subscribe(upstream, value: { v in
                batch.append(v)
                if batch.count >= maxCount { flush() }
            }, completion: { c in
                if case .finished = c { flush() }
                join.complete(c)
            })
        }
    }
}

extension Publisher {
    public func receive<S: Scheduler>(on scheduler: S, options: S.SchedulerOptions? = nil) -> Publishers.ReceiveOn<Self, S> {
        .init(upstream: self, scheduler: scheduler, options: options)
    }
    public func subscribe<S: Scheduler>(on scheduler: S, options: S.SchedulerOptions? = nil) -> Publishers.SubscribeOn<Self, S> {
        .init(upstream: self, scheduler: scheduler, options: options)
    }
    public func debounce<S: Scheduler>(for dueTime: S.SchedulerTimeType.Stride, scheduler: S, options: S.SchedulerOptions? = nil) -> Publishers.Debounce<Self, S> {
        .init(upstream: self, dueTime: dueTime, scheduler: scheduler, options: options)
    }
    public func throttle<S: Scheduler>(for interval: S.SchedulerTimeType.Stride, scheduler: S, latest: Bool) -> Publishers.Throttle<Self, S> {
        .init(upstream: self, interval: interval, scheduler: scheduler, latest: latest)
    }
    public func delay<S: Scheduler>(for interval: S.SchedulerTimeType.Stride, tolerance: S.SchedulerTimeType.Stride? = nil,
                                    scheduler: S, options: S.SchedulerOptions? = nil) -> Publishers.Delay<Self, S> {
        .init(upstream: self, interval: interval, tolerance: tolerance ?? scheduler.minimumTolerance, scheduler: scheduler, options: options)
    }
    public func timeout<S: Scheduler>(_ interval: S.SchedulerTimeType.Stride, scheduler: S, options: S.SchedulerOptions? = nil,
                                      customError: (() -> Failure)? = nil) -> Publishers.Timeout<Self, S> {
        .init(upstream: self, interval: interval, scheduler: scheduler, options: options, customError: customError)
    }
    public func measureInterval<S: Scheduler>(using scheduler: S, options: S.SchedulerOptions? = nil) -> Publishers.MeasureInterval<Self, S> {
        .init(upstream: self, scheduler: scheduler)
    }
    public func collect<S: Scheduler>(_ strategy: Publishers.TimeGroupingStrategy<S>, options: S.SchedulerOptions? = nil) -> Publishers.CollectByTime<Self, S> {
        .init(upstream: self, strategy: strategy, options: options)
    }
}
