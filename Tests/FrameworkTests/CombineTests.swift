import XCTest
import Foundation
import Combine

final class CombineTests: XCTestCase {
    var bag = Set<AnyCancellable>()

    override func tearDown() { bag.removeAll() }

    func collect<P: Publisher>(_ p: P) -> ([P.Output], Subscribers.Completion<P.Failure>?) {
        var values: [P.Output] = []
        var completion: Subscribers.Completion<P.Failure>?
        p.sink(receiveCompletion: { completion = $0 }, receiveValue: { values.append($0) }).store(in: &bag)
        return (values, completion)
    }

    func testDemand() {
        XCTAssertEqual(Subscribers.Demand.max(2) + .max(3), .max(5))
        XCTAssertEqual(Subscribers.Demand.unlimited + .max(3), .unlimited)
        XCTAssertEqual(Subscribers.Demand.max(2) - .max(3), .none)
        XCTAssertTrue(Subscribers.Demand.unlimited > 1_000_000)
        XCTAssertTrue(Subscribers.Demand.max(1) > 0)
        XCTAssertFalse(Subscribers.Demand.none > 0)
        XCTAssertEqual(Subscribers.Demand.max(3).max, 3)
        XCTAssertNil(Subscribers.Demand.unlimited.max)
    }

    func testMapFilterCompactMapScan() {
        let (v, c) = collect([1, 2, 3, 4, 5, 6].publisher.map { $0 * 10 }.filter { $0 % 20 == 0 }.compactMap { $0 == 40 ? nil : $0 }.scan(0, +))
        XCTAssertEqual(v, [20, 80])
        XCTAssertEqual(c, .finished)
    }

    func testRemoveDuplicatesAndDropPrefix() {
        XCTAssertEqual(collect([1, 1, 2, 2, 2, 3, 1].publisher.removeDuplicates()).0, [1, 2, 3, 1])
        XCTAssertEqual(collect((1...10).publisher.dropFirst(2).prefix(3)).0, [3, 4, 5])
        XCTAssertEqual(collect((1...10).publisher.drop(while: { $0 < 8 })).0, [8, 9, 10])
        XCTAssertEqual(collect((1...10).publisher.prefix(while: { $0 < 3 })).0, [1, 2])
        XCTAssertEqual(collect((1...10).publisher.output(at: 4)).0, [5])
        XCTAssertEqual(collect((1...10).publisher.output(in: 2...3)).0, [3, 4])
    }

    func testReducers() {
        XCTAssertEqual(collect((1...4).publisher.collect()).0, [[1, 2, 3, 4]])
        XCTAssertEqual(collect((1...5).publisher.collect(2)).0, [[1, 2], [3, 4], [5]])
        XCTAssertEqual(collect((1...4).publisher.reduce(0, +)).0, [10])
        XCTAssertEqual(collect((1...4).publisher.count()).0, [4])
        XCTAssertEqual(collect((1...4).publisher.first()).0, [1])
        XCTAssertEqual(collect((1...4).publisher.last()).0, [4])
        XCTAssertEqual(collect((1...4).publisher.first(where: { $0 > 2 })).0, [3])
        XCTAssertEqual(collect([3, 1, 2].publisher.min()).0, [1])
        XCTAssertEqual(collect([3, 1, 2].publisher.max()).0, [3])
        XCTAssertEqual(collect((1...4).publisher.contains(3)).0, [true])
        XCTAssertEqual(collect((1...4).publisher.allSatisfy { $0 < 3 }).0, [false])
        XCTAssertEqual(collect(Empty<Int, Never>().replaceEmpty(with: 7)).0, [7])
        XCTAssertEqual(collect([Int?.none, 2].publisher.replaceNil(with: 0)).0, [0, 2])
    }

    struct Boom: Error, Equatable {}

    func testTryMapFailsAndCatch() {
        let (v, c) = collect((1...4).publisher.tryMap { v -> Int in if v == 3 { throw Boom() }; return v })
        XCTAssertEqual(v, [1, 2])
        if case .failure(let e)? = c { XCTAssertTrue(e is Boom) } else { XCTFail("expected failure") }

        let caught = collect(Fail<Int, Boom>(error: Boom()).catch { _ in Just(9) })
        XCTAssertEqual(caught.0, [9])
        XCTAssertEqual(collect(Fail<Int, Boom>(error: Boom()).replaceError(with: 1)).0, [1])
        var attempts = 0
        let retried = collect(Deferred { () -> AnyPublisher<Int, Boom> in
            attempts += 1
            return attempts < 3 ? Fail(error: Boom()).eraseToAnyPublisher() : Just(attempts).setFailureType(to: Boom.self).eraseToAnyPublisher()
        }.retry(5))
        XCTAssertEqual(retried.0, [3])
        XCTAssertEqual(collect(Fail<Int, Boom>(error: Boom()).mapError { _ in URLError(.badURL) }).1, .failure(URLError(.badURL)))
    }

    func testSubjects() {
        let s = PassthroughSubject<Int, Never>()
        var got: [Int] = []
        s.send(0)
        s.sink { got.append($0) }.store(in: &bag)
        s.send(1); s.send(2)
        s.send(completion: .finished)
        s.send(3)
        XCTAssertEqual(got, [1, 2])

        let cv = CurrentValueSubject<String, Never>("a")
        var seen: [String] = []
        let c = cv.sink { seen.append($0) }
        cv.value = "b"
        cv.send("c")
        c.cancel()
        cv.send("d")
        XCTAssertEqual(seen, ["a", "b", "c"])
        XCTAssertEqual(cv.value, "d")
    }

    /// A subscriber that asks for values one at a time.
    final class Stepper<Input>: Subscriber {
        typealias Failure = Never
        var subscription: Subscription?
        var values: [Input] = []
        var finished = false
        func receive(subscription: Subscription) { self.subscription = subscription }
        func receive(_ input: Input) -> Subscribers.Demand { values.append(input); return .none }
        func receive(completion: Subscribers.Completion<Never>) { finished = true }
    }

    func testBackpressure() {
        let s = Stepper<Int>()
        (1...5).publisher.map { $0 * 2 }.subscribe(s)
        XCTAssertEqual(s.values, [])
        s.subscription?.request(.max(2))
        XCTAssertEqual(s.values, [2, 4])
        s.subscription?.request(.max(10))
        XCTAssertEqual(s.values, [2, 4, 6, 8, 10])
        XCTAssertTrue(s.finished)

        // CurrentValueSubject holds the latest value for a subscriber without demand.
        let cv = CurrentValueSubject<Int, Never>(1)
        let t = Stepper<Int>()
        cv.subscribe(t)
        cv.send(2); cv.send(3)
        t.subscription?.request(.max(1))
        XCTAssertEqual(t.values, [3])
        // PassthroughSubject drops values sent without demand.
        let p = PassthroughSubject<Int, Never>()
        let u = Stepper<Int>()
        p.subscribe(u)
        p.send(1)
        u.subscription?.request(.max(1))
        p.send(2); p.send(3)
        XCTAssertEqual(u.values, [2])
    }

    func testCombiningOperators() {
        let a = PassthroughSubject<Int, Never>(), b = PassthroughSubject<String, Never>()
        var latest: [String] = []
        a.combineLatest(b) { "\($0)\($1)" }.sink { latest.append($0) }.store(in: &bag)
        a.send(1); b.send("x"); a.send(2); b.send("y")
        XCTAssertEqual(latest, ["1x", "2x", "2y"])

        let c = PassthroughSubject<Int, Never>(), d = PassthroughSubject<Int, Never>()
        var zipped: [String] = []
        var zipDone = false
        c.zip(d).sink(receiveCompletion: { _ in zipDone = true }, receiveValue: { zipped.append("\($0)-\($1)") }).store(in: &bag)
        c.send(1); c.send(2); d.send(10); c.send(completion: .finished); d.send(20)
        XCTAssertEqual(zipped, ["1-10", "2-20"])
        XCTAssertTrue(zipDone)

        XCTAssertEqual(collect([1, 2].publisher.merge(with: [3].publisher)).0.sorted(), [1, 2, 3])
        XCTAssertEqual(collect([1, 2].publisher.flatMap { [$0, $0 * 10].publisher }).0, [1, 10, 2, 20])
        XCTAssertEqual(collect([2, 3].publisher.prepend(1).append(4)).0, [1, 2, 3, 4])

        let outer = PassthroughSubject<PassthroughSubject<Int, Never>, Never>()
        let i1 = PassthroughSubject<Int, Never>(), i2 = PassthroughSubject<Int, Never>()
        var switched: [Int] = []
        outer.switchToLatest().sink { switched.append($0) }.store(in: &bag)
        outer.send(i1); i1.send(1); outer.send(i2); i1.send(2); i2.send(3)
        XCTAssertEqual(switched, [1, 3])
    }

    func testFutureAndJust() async throws {
        let f = Future<Int, Never> { promise in DispatchQueue.global().async { promise(.success(42)) } }
        let v = await f.value
        XCTAssertEqual(v, 42)
        XCTAssertEqual(collect(Just(5)).0, [5])
        var all: [Int] = []
        for await x in [1, 2, 3].publisher.values { all.append(x) }
        XCTAssertEqual(all, [1, 2, 3])
    }

    func testDebounceAndReceiveOn() {
        let s = PassthroughSubject<Int, Never>()
        let q = DispatchQueue(label: "test.debounce")
        let done = expectation(description: "debounced")
        var got: [Int] = []
        s.debounce(for: .milliseconds(80), scheduler: q).sink { v in got.append(v); if v == 3 { done.fulfill() } }.store(in: &bag)
        s.send(1); s.send(2); s.send(3)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(got, [3])

        let hop = expectation(description: "received on queue")
        let key = DispatchSpecificKey<Int>()
        q.setSpecific(key: key, value: 7)
        Just(1).receive(on: q).sink { _ in
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), 7)
            hop.fulfill()
        }.store(in: &bag)
        wait(for: [hop], timeout: 2)
    }

    func testThrottleAndDelayAndTimer() {
        let s = PassthroughSubject<Int, Never>()
        let q = DispatchQueue(label: "test.throttle")
        var got: [Int] = []
        let done = expectation(description: "throttled")
        s.throttle(for: .milliseconds(100), scheduler: q, latest: true).sink { v in got.append(v); if v == 4 { done.fulfill() } }.store(in: &bag)
        s.send(1); s.send(2); s.send(3); s.send(4)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(got, [1, 4])

        let start = Date()
        let delayed = expectation(description: "delayed")
        Just(1).delay(for: .milliseconds(50), scheduler: q).sink { _ in
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.045)
            delayed.fulfill()
        }.store(in: &bag)
        wait(for: [delayed], timeout: 2)

        let ticks = expectation(description: "timer")
        ticks.expectedFulfillmentCount = 3
        Timer.publish(every: 0.02, on: .main, in: .common).autoconnect().prefix(3).sink { _ in ticks.fulfill() }.store(in: &bag)
        wait(for: [ticks], timeout: 2)
    }

    func testNotificationCenterPublisher() {
        let name = Notification.Name("RunwayCombineTest")
        var got: [String] = []
        NotificationCenter.default.publisher(for: name).compactMap { $0.object as? String }.sink { got.append($0) }.store(in: &bag)
        NotificationCenter.default.post(name: name, object: "hello")
        XCTAssertEqual(got, ["hello"])
    }

    final class Model: ObservableObject {
        @Published var count = 0
        @Published var name = "a"
    }

    final class ManualModel: ObservableObject {
        let objectWillChange = ObservableObjectPublisher()
        @Published var value = 0
    }

    func testPublishedAndObservableObject() {
        let m = Model()
        var willChange = 0
        m.objectWillChange.sink { willChange += 1 }.store(in: &bag)
        var counts: [Int] = []
        var seenAtEmit: [Int] = []
        m.$count.sink { v in counts.append(v); seenAtEmit.append(m.count) }.store(in: &bag)
        m.count = 1
        m.name = "b"
        m.count = 2
        XCTAssertEqual(willChange, 3)
        XCTAssertEqual(counts, [0, 1, 2])
        // willSet semantics: the property still holds the old value.
        XCTAssertEqual(seenAtEmit, [0, 0, 1])

        let manual = ManualModel()
        var manualChanges = 0
        manual.objectWillChange.sink { manualChanges += 1 }.store(in: &bag)
        manual.value = 3
        XCTAssertEqual(manualChanges, 1)

        let target = Model()
        Just(9).assign(to: &target.$count)
        XCTAssertEqual(target.count, 9)
        final class Box { var v = 0 }
        let box = Box()
        [1, 2].publisher.assign(to: \.v, on: box).store(in: &bag)
        XCTAssertEqual(box.v, 2)
    }

    func testShareAndCancellation() {
        var subscriptions = 0
        let source = PassthroughSubject<Int, Never>()
        let shared = source.handleEvents(receiveSubscription: { _ in subscriptions += 1 }).share()
        var a: [Int] = [], b: [Int] = []
        let ca = shared.sink { a.append($0) }
        let cb = shared.sink { b.append($0) }
        source.send(1)
        ca.cancel()
        source.send(2)
        XCTAssertEqual(subscriptions, 1)
        XCTAssertEqual(a, [1])
        XCTAssertEqual(b, [1, 2])
        cb.cancel()

        var cancelled = false
        let c = source.handleEvents(receiveCancel: { cancelled = true }).sink { _ in }
        _ = c
        var c2: AnyCancellable? = c
        c2 = nil
        _ = c2
        XCTAssertFalse(cancelled)
        c.cancel()
        XCTAssertTrue(cancelled)
    }

    func testAnyPublisherAndEncodeDecode() throws {
        struct P: Codable, Equatable { var x: Int }
        let (v, _) = collect(Just(P(x: 3)).encode(encoder: JSONEncoder()).decode(type: P.self, decoder: JSONDecoder()).eraseToAnyPublisher())
        XCTAssertEqual(v, [P(x: 3)])
    }
}

/// A sink whose own closures hold the last reference to its AnyCancellable:
/// finishing releases the closures, which cancels the sink re-entrantly.
/// (Crashed with "Fatal access conflict" before the handlers were swapped
/// out under the lock.)
final class CombineReentrancyTests: XCTestCase {
    final class Holder { var cancellable: AnyCancellable? }

    func testSinkReleasingItsOwnCancellableOnCompletion() {
        for _ in 0..<200 {
            let subject = PassthroughSubject<Int, Never>()
            var seen = 0
            do {
                let holder = Holder()
                holder.cancellable = subject.sink { _ in seen += 1; _ = holder }
            }
            subject.send(1)
            subject.send(completion: .finished)
            XCTAssertEqual(seen, 1)
        }
    }

    func testSinkReleasingItsOwnCancellableOnCancel() {
        let subject = PassthroughSubject<Int, Never>()
        let holder = Holder()
        holder.cancellable = subject.sink { _ in _ = holder }
        holder.cancellable?.cancel()
        holder.cancellable = nil
        subject.send(1)
    }
}
