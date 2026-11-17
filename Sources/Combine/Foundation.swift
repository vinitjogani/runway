// Combine's Foundation integration: Timer.publish, NotificationCenter
// publishers, URLSession.dataTaskPublisher, and async sequences of values.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: Timer.publish

extension Timer {
    public static func publish(every interval: TimeInterval, tolerance: TimeInterval? = nil, on runLoop: RunLoop,
                               in mode: RunLoop.Mode, options: RunLoop.SchedulerOptions? = nil) -> Timer.TimerPublisher {
        TimerPublisher(interval: interval, tolerance: tolerance, runLoop: runLoop, mode: mode, options: options)
    }

    public final class TimerPublisher: ConnectablePublisher, @unchecked Sendable {
        public typealias Output = Date
        public typealias Failure = Never
        public final let interval: TimeInterval
        public final let tolerance: TimeInterval?
        public final let runLoop: RunLoop
        public final let mode: RunLoop.Mode
        public final let options: RunLoop.SchedulerOptions?
        private let subject = PassthroughSubject<Date, Never>()

        public init(interval: TimeInterval, tolerance: TimeInterval? = nil, runLoop: RunLoop, mode: RunLoop.Mode, options: RunLoop.SchedulerOptions? = nil) {
            self.interval = interval; self.tolerance = tolerance; self.runLoop = runLoop; self.mode = mode; self.options = options
        }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Date, S.Failure == Never {
            subject.receive(subscriber: subscriber)
        }

        public func connect() -> Cancellable {
            let subject = self.subject
            let iv = Swift.max(interval, 0.0001)
            if runLoop === RunLoop.main {
                // The main run loop's work is the main queue's (see Schedulers.swift).
                let t = DispatchSource.makeTimerSource(queue: .main)
                t.setEventHandler { subject.send(Date()) }
                t.schedule(deadline: .now() + iv, repeating: iv, leeway: .nanoseconds(Int((tolerance ?? 0) * 1e9)))
                t.resume()
                return AnyCancellable { t.cancel() }
            }
            let timer = Timer(timeInterval: iv, repeats: true) { _ in subject.send(Date()) }
            if let tolerance { timer.tolerance = tolerance }
            runLoop.add(timer, forMode: mode)
            return AnyCancellable { timer.invalidate() }
        }
    }
}

// MARK: NotificationCenter

extension NotificationCenter {
    public func publisher(for name: Notification.Name, object: AnyObject? = nil) -> NotificationCenter.Publisher {
        Publisher(center: self, name: name, object: object)
    }

    public struct Publisher: Combine.Publisher {
        public typealias Output = Notification
        public typealias Failure = Never
        public let center: NotificationCenter
        public let name: Notification.Name
        public let object: AnyObject?

        public init(center: NotificationCenter, name: Notification.Name, object: AnyObject? = nil) {
            self.center = center; self.name = name; self.object = object
        }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Notification, S.Failure == Never {
            let conduit = _Conduit(subscriber, name: "NotificationCenter.Publisher")
            let token = center.addObserver(forName: name, object: object, queue: nil) { n in
                // Apple's drops notifications posted while there's no demand.
                if conduit.pendingDemand > 0 { conduit.send(n) }
            }
            let center = self.center
            conduit.onCancel = { center.removeObserver(token) }
            conduit.start()
        }
    }
}

extension NotificationCenter.Publisher: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.center === rhs.center && lhs.name == rhs.name && lhs.object === rhs.object
    }
}

// MARK: URLSession

extension URLSession {
    public func dataTaskPublisher(for url: URL) -> DataTaskPublisher { DataTaskPublisher(request: URLRequest(url: url), session: self) }
    public func dataTaskPublisher(for request: URLRequest) -> DataTaskPublisher { DataTaskPublisher(request: request, session: self) }

    public struct DataTaskPublisher: Publisher, @unchecked Sendable {
        public typealias Output = (data: Data, response: URLResponse)
        public typealias Failure = URLError
        public let request: URLRequest
        public let session: URLSession

        public init(request: URLRequest, session: URLSession) { self.request = request; self.session = session }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == URLError {
            let conduit = _Conduit(subscriber, name: "DataTaskPublisher")
            let lock = NSLock()
            var task: URLSessionDataTask?
            var started = false
            let (session, request) = (self.session, self.request)
            conduit.onRequest = { _ in
                lock.lock()
                guard !started else { lock.unlock(); return }
                started = true
                let t = session.dataTask(with: request) { data, response, error in
                    if let error {
                        conduit.fail(.failure((error as? URLError) ?? URLError(.unknown, userInfo: [NSUnderlyingErrorKey: error])))
                    } else if let response {
                        conduit.send((data ?? Data(), response))
                        conduit.finish(.finished)
                    } else {
                        conduit.fail(.failure(URLError(.badServerResponse)))
                    }
                }
                task = t
                lock.unlock()
                t.resume()
            }
            conduit.onCancel = { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
            conduit.start()
        }
    }
}

// MARK: async values

public struct AsyncPublisher<P: Publisher>: AsyncSequence where P.Failure == Never {
    public typealias Element = P.Output
    let publisher: P
    public init(_ publisher: P) { self.publisher = publisher }

    public struct Iterator: AsyncIteratorProtocol {
        let inner: _AsyncInner<P.Output, Never>
        public mutating func next() async -> P.Output? { try! await inner.next() }
    }

    public func makeAsyncIterator() -> Iterator {
        let inner = _AsyncInner<P.Output, Never>()
        publisher.subscribe(inner)
        return Iterator(inner: inner)
    }
}

public struct AsyncThrowingPublisher<P: Publisher>: AsyncSequence {
    public typealias Element = P.Output
    let publisher: P
    public init(_ publisher: P) { self.publisher = publisher }

    public struct Iterator: AsyncIteratorProtocol {
        let inner: _AsyncInner<P.Output, P.Failure>
        public mutating func next() async throws -> P.Output? { try await inner.next() }
    }

    public func makeAsyncIterator() -> Iterator {
        let inner = _AsyncInner<P.Output, P.Failure>()
        publisher.subscribe(inner)
        return Iterator(inner: inner)
    }
}

/// Requests one value per `next()`, as Apple's async publishers do.
final class _AsyncInner<Input, Failure: Error>: Subscriber, Cancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var subscription: Subscription?
    private var buffered: [Input] = []
    private var completion: Subscribers.Completion<Failure>?
    private var waiting: CheckedContinuation<Input?, Error>?
    private var pendingRequest = false

    func receive(subscription s: Subscription) {
        lock.lock()
        subscription = s
        let ask = pendingRequest
        pendingRequest = false
        lock.unlock()
        if ask { s.request(.max(1)) }
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        if let w = waiting { waiting = nil; lock.unlock(); w.resume(returning: input) } else { buffered.append(input); lock.unlock() }
        return .none
    }

    func receive(completion c: Subscribers.Completion<Failure>) {
        lock.lock()
        completion = c
        subscription = nil
        let w = waiting
        waiting = nil
        lock.unlock()
        guard let w else { return }
        switch c {
        case .finished: w.resume(returning: nil)
        case .failure(let e): w.resume(throwing: e)
        }
    }

    func next() async throws -> Input? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Input?, Error>) in
                lock.lock()
                if !buffered.isEmpty { let v = buffered.removeFirst(); lock.unlock(); k.resume(returning: v); return }
                if let c = completion {
                    lock.unlock()
                    switch c {
                    case .finished: k.resume(returning: nil)
                    case .failure(let e): k.resume(throwing: e)
                    }
                    return
                }
                waiting = k
                let s = subscription
                if s == nil { pendingRequest = true }
                lock.unlock()
                s?.request(.max(1))
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock()
        let s = subscription
        subscription = nil
        if completion == nil { completion = .finished }
        let w = waiting
        waiting = nil
        lock.unlock()
        s?.cancel()
        w?.resume(returning: nil)
    }
}

extension Publisher where Failure == Never {
    public var values: AsyncPublisher<Self> { AsyncPublisher(self) }
}

extension Publisher {
    public var values: AsyncThrowingPublisher<Self> { AsyncThrowingPublisher(self) }
}
