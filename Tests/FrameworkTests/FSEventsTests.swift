import XCTest
import Foundation
import CoreServices

/// Collects deliveries from the C callback.
final class EventLog: @unchecked Sendable {
    let lock = NSLock()
    var events: [(String, Int)] = []
    private var onEvent: (() -> Void)?
    func add(_ path: String, _ flags: Int) {
        lock.lock(); events.append((path, flags)); let f = onEvent; lock.unlock()
        f?()
    }
    /// Installs the check run after each event. Set only from the test
    /// thread: clearing it from a callback could wipe out the next one.
    func whenEvent(_ f: @escaping () -> Void) { lock.lock(); onEvent = f; lock.unlock() }
    func has(_ suffix: String, _ flag: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return events.contains { $0.0.hasSuffix(suffix) && $0.1 & flag != 0 }
    }
}

private let cfCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    let log = Unmanaged<EventLog>.fromOpaque(info!).takeUnretainedValue()
    let array = Unmanaged<NSArray>.fromOpaque(paths).takeUnretainedValue()
    for i in 0..<count { log.add(array[i] as! String, Int(flags[i])) }
}

private let cCallback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
    let log = Unmanaged<EventLog>.fromOpaque(info!).takeUnretainedValue()
    let cpaths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    for i in 0..<count { log.add(String(cString: cpaths[i]), Int(flags[i])) }
}

final class FSEventsTests: XCTestCase {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("fsevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func watch(_ dir: URL, flags: Int, callback: FSEventStreamCallback, log: EventLog, queue: DispatchQueue) -> FSEventStreamRef {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(log).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [dir.path] as CFArray,
                                         FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, FSEventStreamCreateFlags(flags))!
        FSEventStreamSetDispatchQueue(stream, queue)
        XCTAssertTrue(FSEventStreamStart(stream))
        return stream
    }

    func testFileEventsRecursive() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog()
        let q = DispatchQueue(label: "fsevents.test")
        let stream = watch(dir, flags: kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer,
                           callback: cfCallback, log: log, queue: q)
        defer { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }

        let created = expectation(description: "created + nested")
        created.assertForOverFulfill = false
        log.whenEvent { if log.has("/sub/deep.md", kFSEventStreamEventFlagItemCreated) && log.has("/a.md", kFSEventStreamEventFlagItemModified) { created.fulfill() } }
        try "hi".write(to: dir.appendingPathComponent("a.md"), atomically: false, encoding: .utf8)
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: 0.05)
        try "deep".write(to: sub.appendingPathComponent("deep.md"), atomically: false, encoding: .utf8)
        wait(for: [created], timeout: 10)
        XCTAssertTrue(log.has("/a.md", kFSEventStreamEventFlagItemIsFile))
        XCTAssertTrue(log.has("/sub", kFSEventStreamEventFlagItemIsDir))

        let renamed = expectation(description: "renamed + removed")
        renamed.assertForOverFulfill = false
        log.whenEvent { if log.has("/b.md", kFSEventStreamEventFlagItemRenamed) && log.has("/deep.md", kFSEventStreamEventFlagItemRemoved) { renamed.fulfill() } }
        try FileManager.default.moveItem(at: dir.appendingPathComponent("a.md"), to: dir.appendingPathComponent("b.md"))
        try FileManager.default.removeItem(at: sub.appendingPathComponent("deep.md"))
        wait(for: [renamed], timeout: 10)
        XCTAssertTrue(log.has("/a.md", kFSEventStreamEventFlagItemRenamed))
        XCTAssertGreaterThan(FSEventsGetCurrentEventId(), 0)
    }

    func testDirectoryLevelEventsAndCPaths() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog()
        let stream = watch(dir, flags: kFSEventStreamCreateFlagNone, callback: cCallback, log: log, queue: DispatchQueue(label: "fsevents.dir"))
        defer { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        let changed = expectation(description: "dir changed")
        changed.assertForOverFulfill = false
        log.whenEvent { changed.fulfill() }
        try "x".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 10)
        log.lock.lock()
        let first = log.events.first
        log.lock.unlock()
        // Directory-level streams name the directory, with a trailing slash.
        XCTAssertEqual(first?.0, dir.standardizedFileURL.path + "/")
        XCTAssertEqual(first?.1, kFSEventStreamEventFlagNone)
    }

    func testMainQueueDelivery() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = EventLog()
        let stream = watch(dir, flags: kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes,
                           callback: cfCallback, log: log, queue: .main)
        defer { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        let onMain = expectation(description: "on main")
        onMain.assertForOverFulfill = false
        log.whenEvent { XCTAssertTrue(Thread.isMainThread); onMain.fulfill() }
        try "x".write(to: dir.appendingPathComponent("m.md"), atomically: false, encoding: .utf8)
        wait(for: [onMain], timeout: 10)
        XCTAssertEqual(FSEventStreamCopyPathsBeingWatched(stream) as? [String], [dir.standardizedFileURL.path])
    }

    func testLegacyUTTypeFunctions() {
        let uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, "png" as CFString, nil)?.takeRetainedValue()
        XCTAssertEqual(uti as String?, "public.png")
        XCTAssertTrue(UTTypeConformsTo("public.png" as CFString, kUTTypeImage))
        XCTAssertEqual(UTTypeCopyPreferredTagWithClass(kUTTypeJPEG, kUTTagClassMIMEType)?.takeRetainedValue() as String?, "image/jpeg")
    }
}
