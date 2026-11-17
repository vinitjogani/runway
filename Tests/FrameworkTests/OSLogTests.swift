import XCTest
import Foundation
import OSLog

final class OSLogTests: XCTestCase {
    var lines: [_LogRecord] = []
    let lock = NSLock()

    override func setUp() {
        _runwayObserveLog { [weak self] r in
            guard let self else { return }
            self.lock.lock(); self.lines.append(r); self.lock.unlock()
        }
    }
    override func tearDown() { _runwayObserveLog(nil) }

    var messages: [String] { lock.lock(); defer { lock.unlock() }; return lines.map(\.message) }

    func testLoggerLevelsAndInterpolation() {
        let log = Logger(subsystem: "com.example.runway", category: "tests")
        let name = "Ada"
        let secret = "hunter2"
        let error = URLError(.timedOut)
        log.info("hello \(name, privacy: .public)")
        log.debug("count \(42) hex \(255, format: .hex) pi \(3.14159, format: .fixed(precision: 2))")
        log.error("password \(secret, privacy: .private) masked \(secret, privacy: .private(mask: .hash))")
        log.warning("failed: \(error)")
        log.notice("flag \(true) \(Int.self) [\(name, align: .left(columns: 5))]")
        log.fault("optional \(Optional(3) as Int?)")
        let m = messages
        XCTAssertEqual(m[0], "hello Ada")
        XCTAssertEqual(m[1], "count 42 hex ff pi 3.14")
        XCTAssertTrue(m[2].hasPrefix("password <private> masked <mask.hash: '"), m[2])
        XCTAssertTrue(m[3].hasPrefix("failed: "), m[3])
        XCTAssertEqual(m[4], "flag true Int [Ada  ]")
        XCTAssertEqual(m[5], "optional Optional(3)")
        XCTAssertEqual(lines[0].subsystem, "com.example.runway")
        XCTAssertEqual(lines[2].level, .error)
        XCTAssertEqual(lines[5].level, .fault)
    }

    func testOSLogFunctions() {
        let log = OSLog(subsystem: "com.example.runway", category: "legacy")
        os_log("plain")
        os_log("%{public}@ took %d ms", log: log, type: .info, "load", 12)
        os_log("%{private}@ hidden %.1f%%", log: log, type: .error, "token", 99.5)
        os_log(.debug, log: log, "modern \(7)")
        XCTAssertEqual(messages, ["plain", "load took 12 ms", "<private> hidden 99.5%", "modern 7"])
        XCTAssertTrue(log.isEnabled(type: .info))
        XCTAssertFalse(OSLog.disabled.isEnabled(type: .info))
        os_log("dropped", log: .disabled, type: .info)
        XCTAssertEqual(messages.count, 4)
    }

    func testLogStoreCurrentProcess() throws {
        Logger(subsystem: "com.example.store", category: "c").notice("stored entry")
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(timeIntervalSinceEnd: -60))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "com.example.store" }
        XCTAssertEqual(entries.last?.composedMessage, "stored entry")
        XCTAssertEqual(entries.last?.level, .notice)
        XCTAssertThrowsError(try OSLogStore.local())
    }

    func testUnfairLocks() {
        var raw = os_unfair_lock()
        os_unfair_lock_lock(&raw)
        XCTAssertFalse(os_unfair_lock_trylock(&raw))
        os_unfair_lock_unlock(&raw)
        XCTAssertTrue(os_unfair_lock_trylock(&raw))
        os_unfair_lock_unlock(&raw)

        let counter = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<10_000 { counter.withLock { $0 += 1 } }
        }
        XCTAssertEqual(counter.withLock { $0 }, 80_000)
        let plain = OSAllocatedUnfairLock()
        plain.lock()
        XCTAssertFalse(plain.lockIfAvailable())
        plain.unlock()
        XCTAssertEqual(plain.withLock { 5 }, 5)
    }

    func testSignpostsRunTheirWork() {
        let s = OSSignposter(subsystem: "com.example.runway", category: .pointsOfInterest)
        let id = s.makeSignpostID()
        let state = s.beginInterval("load", id: id, "begin \(1)")
        s.endInterval("load", state)
        XCTAssertEqual(s.withIntervalSignpost("work") { 3 }, 3)
        os_signpost(.event, log: OSLog(subsystem: "x", category: "y"), name: "tick")
    }
}
