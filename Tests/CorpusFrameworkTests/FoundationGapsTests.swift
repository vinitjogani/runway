import XCTest
import Foundation
@testable import RunwayFoundation

final class FoundationGapsTests: XCTestCase {
    func testStringLocalized() {
        let n = 3
        XCTAssertEqual(String(localized: "Hello"), "Hello")
        XCTAssertEqual(String(localized: "Items: \(n) of \("x")"), "Items: 3 of x")
        XCTAssertEqual(String(localized: "k", defaultValue: "Default \(n)", comment: "c"), "Default 3")
        let r: LocalizedStringResource = "Res \(n)"
        XCTAssertEqual(String(localized: r), "Res 3")
        XCTAssertEqual(LocalizedStringResource.substitute("%2$@ and %1$@ %%", ["a", "b"]), "b and a %")
        XCTAssertEqual(LocalizedStringResource.substitute("%@ has %lld", ["x", "4"]), "x has 4")
    }

    func testCoreFoundationNames() {
        let a = [1, 2, 3] as NSArray
        XCTAssertEqual(CFArrayGetCount(a), 3)
        XCTAssertNotNil(CFArrayGetValueAtIndex(a, 2))
        XCTAssertTrue(CFBooleanGetValue(kCFBooleanTrue))
        XCTAssertEqual(kCFBundleNameKey as String, "CFBundleName")
        let d = NSData(bytes: [1, 2, 3] as [UInt8], length: 3)
        XCTAssertEqual(CFDataGetLength(d), 3)
        XCTAssertEqual(CFDataGetBytePtr(d)[1], 2)
    }

    func testAssociatedObjects() {
        final class Box {}
        var key = 0
        let o = Box()
        objc_setAssociatedObject(o, &key, "v", .OBJC_ASSOCIATION_RETAIN)
        XCTAssertEqual(objc_getAssociatedObject(o, &key) as? String, "v")
        XCTAssertNil(objc_getAssociatedObject(Box(), &key))
    }

    func testSysctl() {
        var size = 0
        XCTAssertEqual(sysctlbyname("hw.memsize", nil, &size, nil, 0), 0)
        XCTAssertEqual(size, 8)
        var mem: Int64 = 0
        XCTAssertEqual(sysctlbyname("hw.memsize", &mem, &size, nil, 0), 0)
        XCTAssertGreaterThan(mem, 0)
        XCTAssertEqual(sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0), 0)
        var buf = [CChar](repeating: 0, count: size)
        XCTAssertEqual(sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0), 0)
        XCTAssertFalse(String(cString: buf).isEmpty)
        XCTAssertEqual(sysctlbyname("no.such.name", nil, &size, nil, 0), -1)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        XCTAssertEqual(tb.numer, 1)
        XCTAssertGreaterThan(mach_absolute_time(), 0)
    }

    func testFileWrapperRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let w = FileWrapper(directoryWithFileWrappers: [:])
        w.addRegularFile(withContents: Data("hi".utf8), preferredFilename: "a.txt")
        try w.write(to: dir, options: [], originalContentsURL: nil)
        let back = try FileWrapper(url: dir)
        XCTAssertTrue(back.isDirectory)
        XCTAssertEqual(back.fileWrappers?["a.txt"]?.regularFileContents, Data("hi".utf8))
        try? FileManager.default.removeItem(at: dir)
    }

    func testXPCConnectionFailsThroughHandlers() {
        let c = NSXPCConnection(machServiceName: "com.example.helper")
        let invalidated = expectation(description: "invalidated")
        let errored = expectation(description: "error handler")
        c.invalidationHandler = { invalidated.fulfill() }
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in errored.fulfill() }
        XCTAssertTrue(proxy is NSXPCUnavailableProxy)
        c.resume()
        wait(for: [invalidated, errored], timeout: 5)
    }

    func testUbiquitousStoreKeepsValues() {
        let s = NSUbiquitousKeyValueStore.default
        s.set("v", forKey: "runway-test")
        XCTAssertEqual(s.string(forKey: "runway-test"), "v")
        s.removeObject(forKey: "runway-test")
        XCTAssertNil(s.object(forKey: "runway-test"))
    }
}
