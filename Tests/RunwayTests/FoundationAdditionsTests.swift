// Foundation API corelibs lacks, from RunwayFoundation: NSItemProvider,
// file system dispatch sources (inotify), AutoreleasingUnsafeMutablePointer,
// UndoManager, NSAppleEventDescriptor and path abbreviation.

import XCTest
import Foundation
import Dispatch
import RunwayFoundation

final class FoundationAdditionsTests: XCTestCase {
    func testItemProviderDataAndValues() {
        let p = NSItemProvider()
        p.registerDataRepresentation(forTypeIdentifier: "com.example.id", visibility: .ownProcess) { done in
            done(Data("42".utf8), nil)
            return nil
        }
        p.suggestedName = "Item"
        XCTAssertEqual(p.registeredTypeIdentifiers, ["com.example.id"])
        XCTAssertTrue(p.hasItemConformingToTypeIdentifier("com.example.id"))
        XCTAssertFalse(p.hasItemConformingToTypeIdentifier("public.png"))
        let got = expectation(description: "data")
        p.loadDataRepresentation(forTypeIdentifier: "com.example.id") { data, error in
            XCTAssertEqual(data, Data("42".utf8))
            XCTAssertNil(error)
            got.fulfill()
        }
        let missing = expectation(description: "missing")
        p.loadDataRepresentation(forTypeIdentifier: "public.png") { data, error in
            XCTAssertNil(data)
            XCTAssertEqual((error as NSError?)?.domain, NSItemProvider.errorDomain)
            missing.fulfill()
        }
        wait(for: [got, missing], timeout: 1)
    }

    func testItemProviderStringsURLsAndFiles() throws {
        let s = NSItemProvider(object: "hello")
        XCTAssertTrue(s.canLoadObject(ofClass: String.self))
        let gotString = expectation(description: "string")
        s.loadObject(ofClass: String.self) { v, _ in XCTAssertEqual(v, "hello"); gotString.fulfill() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try Data("contents".utf8).write(to: file)
        let f = try XCTUnwrap(NSItemProvider(contentsOf: file))
        XCTAssertEqual(f.suggestedName, "note.txt")
        XCTAssertTrue(f.hasItemConformingToTypeIdentifier("public.plain-text"), "txt conforms to plain text")
        XCTAssertTrue(f.canLoadObject(ofClass: URL.self))
        let gotURL = expectation(description: "url")
        f.loadObject(ofClass: URL.self) { url, _ in XCTAssertEqual(url?.path, file.path); gotURL.fulfill() }
        let gotFile = expectation(description: "file")
        f.loadFileRepresentation(forTypeIdentifier: "public.utf8-plain-text") { url, _ in
            XCTAssertNotEqual(url, file, "a temporary copy")
            XCTAssertEqual(url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }, "contents")
            gotFile.fulfill()
        }
        let gotItem = expectation(description: "item")
        f.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            XCTAssertEqual((item as? URL)?.path, file.path)
            gotItem.fulfill()
        }
        wait(for: [gotString, gotURL, gotFile, gotItem], timeout: 2)
    }

    #if os(Linux)
    func testFileSystemObjectSourceReportsDirectoryWritesAndDeletes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fd = open(dir.path, O_EVTONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let queue = DispatchQueue(label: "fs-test")
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete], queue: queue)
        let wrote = expectation(description: "write")
        wrote.assertForOverFulfill = false
        let cancelled = expectation(description: "cancel")
        src.setEventHandler {
            if src.data.contains(.write) { wrote.fulfill() }
        }
        src.setCancelHandler {
            close(fd)
            cancelled.fulfill()
        }
        src.resume()
        XCTAssertEqual(src.handle, fd)
        XCTAssertEqual(src.mask, [.write, .delete])
        queue.sync {}
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.txt"))
        wait(for: [wrote], timeout: 3)
        src.cancel()
        wait(for: [cancelled], timeout: 3)
        XCTAssertTrue(src.isCancelled)
    }

    func testFileSystemObjectSourceSeesAFileUnlinked() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fs-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        let fd = open(file.path, O_EVTONLY)
        defer { close(fd) }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.delete, .extend], queue: .global())
        let deleted = expectation(description: "delete")
        deleted.assertForOverFulfill = false
        let grew = expectation(description: "extend")
        grew.assertForOverFulfill = false
        src.setEventHandler {
            let d = src.data
            if d.contains(.extend) { grew.fulfill() }
            if d.contains(.delete) { deleted.fulfill() }
        }
        src.activate()
        let h = try FileHandle(forWritingTo: file)
        h.seekToEndOfFile()
        h.write(Data("more".utf8))
        try h.close()
        wait(for: [grew], timeout: 3)
        try FileManager.default.removeItem(at: file)
        wait(for: [deleted], timeout: 3)
        src.cancel()
    }
    #endif

    func testAutoreleasingPointerStoresThrough() {
        var value: NSString? = nil
        withUnsafeMutablePointer(to: &value) { p in
            let a = AutoreleasingUnsafeMutablePointer(p)
            a.pointee = "error" as NSString
        }
        XCTAssertEqual(value, "error")
    }

    func testUndoManagerGroupsAndRedoes() {
        final class Box { var value = 0 }
        let u = UndoManager()
        u.groupsByEvent = false
        let b = Box()
        func set(_ v: Int) {
            let old = b.value
            b.value = v
            u.registerUndo(withTarget: b) { _ in set(old) }
        }
        u.beginUndoGrouping(); set(1); u.setActionName("One"); u.endUndoGrouping()
        u.beginUndoGrouping(); set(2); u.endUndoGrouping()
        XCTAssertEqual(u.undoMenuItemTitle, "Undo")
        u.undo()
        XCTAssertEqual(b.value, 1)
        XCTAssertEqual(u.undoActionName, "One")
        u.redo()
        XCTAssertEqual(b.value, 2)
    }

    func testAppleEventDescriptorParams() {
        let e = NSAppleEventDescriptor.appleEvent(withEventClass: runwayFourCharCode("aevt"), eventID: runwayFourCharCode("oapp"),
                                                  targetDescriptor: nil, returnID: -1, transactionID: 0)
        e.setParam(NSAppleEventDescriptor(string: "x"), forKeyword: runwayFourCharCode("----"))
        XCTAssertEqual(e.paramDescriptor(forKeyword: runwayFourCharCode("----"))?.stringValue, "x")
        XCTAssertNil(e.paramDescriptor(forKeyword: runwayFourCharCode("prdt")))
    }

    func testAbbreviatingWithTilde() {
        let home = NSHomeDirectory()
        XCTAssertEqual((home + "/Notes" as NSString).abbreviatingWithTildeInPath, "~/Notes")
        XCTAssertEqual(("/elsewhere/x" as NSString).abbreviatingWithTildeInPath, "/elsewhere/x")
    }

    /// An app's own NSObject subclasses as attribute values: inserting a run
    /// beside one with a different object compares them (CFEqual), which
    /// halted in corelibs for objects without a CF type. It now asks the
    /// objects' `isEqual(_:)`.
    func testAttributedStringRunsWithAppObjects() {
        final class Style: NSObject {
            let size: Double
            init(_ size: Double) { self.size = size }
            override func isEqual(_ object: Any?) -> Bool { (object as? Style)?.size == size }
            override var hash: Int { size.hashValue }
        }
        let key = NSAttributedString.Key("AppStyle")
        let m = NSMutableAttributedString(string: "")
        m.append(NSAttributedString(string: "small ", attributes: [key: Style(13)]))
        m.append(NSAttributedString(string: "large ", attributes: [key: Style(14)]))
        m.append(NSAttributedString(string: "large", attributes: [key: Style(14)]))
        var runs: [(NSRange, Double)] = []
        m.enumerateAttribute(key, in: NSRange(location: 0, length: m.length), options: []) { v, r, _ in runs.append((r, (v as? Style)?.size ?? 0)) }
        XCTAssertEqual(runs.map(\.0), [NSRange(location: 0, length: 6), NSRange(location: 6, length: 11)])
        XCTAssertEqual(runs.map(\.1), [13, 14])
        // Plain NSObjects (identity) too.
        let n = NSMutableAttributedString(string: "ab")
        n.addAttribute(key, value: NSObject(), range: NSRange(location: 0, length: 1))
        n.addAttribute(key, value: NSObject(), range: NSRange(location: 1, length: 1))
        var count = 0
        n.enumerateAttribute(key, in: NSRange(location: 0, length: 2), options: []) { _, _, _ in count += 1 }
        XCTAssertEqual(count, 2)
    }
}
