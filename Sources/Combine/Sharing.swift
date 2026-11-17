import Foundation

public protocol ConnectablePublisher<Output, Failure>: Publisher {
    func connect() -> Cancellable
}

extension ConnectablePublisher {
    public func autoconnect() -> Publishers.Autoconnect<Self> { .init(upstream: self) }
}

extension Publishers {
    /// Connects on the first subscriber; disconnects when the last leaves.
    public final class Autoconnect<Upstream: ConnectablePublisher>: Publisher, @unchecked Sendable {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public final let upstream: Upstream
        private let lock = NSLock()
        private var connection: Cancellable?
        private var subscribers = 0

        public init(upstream: Upstream) { self.upstream = upstream }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            var counted = true
            // Strong: a live subscription keeps the connection (and so this
            // publisher) alive, as Apple's does.
            let leave: () -> Void = { [self] in
                guard counted else { return }
                counted = false
                self.lock.lock()
                self.subscribers -= 1
                let c = self.subscribers == 0 ? self.connection : nil
                if c != nil { self.connection = nil }
                self.lock.unlock()
                c?.cancel()
            }
            Publishers.HandleEvents(upstream: upstream, receiveCompletion: { _ in leave() }, receiveCancel: leave, receiveRequest: nil)
                .receive(subscriber: subscriber)
            lock.lock()
            subscribers += 1
            let shouldConnect = connection == nil
            lock.unlock()
            if shouldConnect {
                let c = upstream.connect()
                lock.lock()
                if connection == nil { connection = c; lock.unlock() } else { lock.unlock(); c.cancel() }
            }
        }
    }

    public final class Multicast<Upstream: Publisher, SubjectType: Subject>: ConnectablePublisher, @unchecked Sendable
    where Upstream.Failure == SubjectType.Failure, Upstream.Output == SubjectType.Output {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public final let upstream: Upstream
        public final let createSubject: () -> SubjectType
        private lazy var subject: SubjectType = createSubject()
        private let lock = NSLock()

        public init(upstream: Upstream, createSubject: @escaping () -> SubjectType) {
            self.upstream = upstream
            self.createSubject = createSubject
        }

        private var currentSubject: SubjectType { lock.lock(); defer { lock.unlock() }; return subject }

        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure {
            currentSubject.receive(subscriber: subscriber)
        }

        public func connect() -> Cancellable { upstream.subscribe(currentSubject) }
    }

    public struct MakeConnectable<Upstream: Publisher>: ConnectablePublisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        private let inner: Multicast<Upstream, PassthroughSubject<Output, Failure>>
        public init(upstream: Upstream) { inner = Multicast(upstream: upstream) { PassthroughSubject() } }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure { inner.receive(subscriber: subscriber) }
        public func connect() -> Cancellable { inner.connect() }
    }

    public final class Share<Upstream: Publisher>: Publisher, Equatable, @unchecked Sendable {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure
        public final let upstream: Upstream
        private let inner: Autoconnect<Multicast<Upstream, PassthroughSubject<Output, Failure>>>
        public init(upstream: Upstream) {
            self.upstream = upstream
            inner = Multicast(upstream: upstream) { PassthroughSubject() }.autoconnect()
        }
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Failure { inner.receive(subscriber: subscriber) }
        public static func == (lhs: Share, rhs: Share) -> Bool { lhs === rhs }
    }
}

extension Publisher {
    public func share() -> Publishers.Share<Self> { .init(upstream: self) }
    public func makeConnectable() -> Publishers.MakeConnectable<Self> where Failure == Never { .init(upstream: self) }
    public func multicast<S: Subject>(_ createSubject: @escaping () -> S) -> Publishers.Multicast<Self, S> where Failure == S.Failure, Output == S.Output {
        .init(upstream: self, createSubject: createSubject)
    }
    public func multicast<S: Subject>(subject: S) -> Publishers.Multicast<Self, S> where Failure == S.Failure, Output == S.Output {
        .init(upstream: self, createSubject: { subject })
    }
}
