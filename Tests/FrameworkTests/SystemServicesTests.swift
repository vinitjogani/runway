import XCTest
import Foundation
import IOKit
import SystemConfiguration
import Network
import RunwayDistributedNotifications

final class SystemServicesTests: XCTestCase {
    func testPlatformUUIDAndEmptyMatches() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        XCTAssertNotEqual(service, 0)
        defer { _ = IOObjectRelease(service) }
        if FileManager.default.fileExists(atPath: "/etc/machine-id") {
            let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            XCTAssertEqual(uuid?.count, 36)
        }
        var it: io_iterator_t = 0
        XCTAssertEqual(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"), &it), KERN_SUCCESS)
        XCTAssertEqual(IOIteratorNext(it), 0)
        _ = IOObjectRelease(it)
        XCTAssertEqual(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent), kIOHIDAccessTypeDenied)
    }

    func testPowerSources() {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as! [AnyObject]
        for ps in list {
            let d = IOPSGetPowerSourceDescription(blob, ps).takeUnretainedValue() as! [String: Any]
            XCTAssertNotNil(d[kIOPSCurrentCapacityKey])
        }
        let type = IOPSGetProvidingPowerSourceType(blob).takeRetainedValue() as String
        XCTAssertTrue([kIOPSACPowerValue, kIOPSBatteryPowerValue].contains(type))
        var id: IOPMAssertionID = 0
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "test" as CFString, &id)
        // Granted where logind / a screen saver service is reachable, unsupported otherwise.
        XCTAssertTrue(r == kIOReturnSuccess || r == kIOReturnUnsupported)
        if r == kIOReturnSuccess { XCTAssertEqual(IOPMAssertionRelease(id), kIOReturnSuccess) }
    }

    func testReachabilityAndInterfaces() {
        let r = SCNetworkReachabilityCreateWithName(nil, "localhost")!
        var flags = SCNetworkReachabilityFlags()
        XCTAssertTrue(SCNetworkReachabilityGetFlags(r, &flags))
        XCTAssertTrue(flags.contains(.reachable))
        let interfaces = SCNetworkInterfaceCopyAll() as! [SCNetworkInterface]
        for i in interfaces { XCTAssertNotNil(SCNetworkInterfaceGetBSDName(i)) }
        XCTAssertNotNil(SCDynamicStoreCopyComputerName(nil, nil))
    }

    func testPathMonitorDeliversCurrentPath() {
        let monitor = NWPathMonitor()
        let got = expectation(description: "path")
        monitor.pathUpdateHandler = { path in
            XCTAssertEqual(path.status == .satisfied, !path.availableInterfaces.isEmpty)
            got.fulfill()
        }
        monitor.start(queue: DispatchQueue(label: "path"))
        wait(for: [got], timeout: 2)
        monitor.cancel()
    }

    func testUnixSocketEcho() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("runway-\(UUID().uuidString.prefix(8)).sock").path
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: params)
        let q = DispatchQueue(label: "net")
        listener.newConnectionHandler = { conn in
            conn.start(queue: q)
            conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { data, _, _, _ in
                conn.send(content: Data((data ?? Data()).reversed()), completion: .contentProcessed { _ in })
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if $0 == .ready { ready.fulfill() } }
        listener.start(queue: q)
        wait(for: [ready], timeout: 2)

        let client = NWConnection(to: .unix(path: path), using: .tcp)
        let connected = expectation(description: "connected")
        client.stateUpdateHandler = { if $0 == .ready { connected.fulfill() } }
        client.start(queue: q)
        wait(for: [connected], timeout: 2)
        let echoed = expectation(description: "echo")
        client.send(content: Data("hello".utf8), completion: .contentProcessed { XCTAssertNil($0) })
        client.receive(minimumIncompleteLength: 5, maximumLength: 5) { data, _, _, error in
            XCTAssertNil(error)
            XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "olleh")
            echoed.fulfill()
        }
        wait(for: [echoed], timeout: 2)
        client.cancel()
        listener.cancel()

        let refused = expectation(description: "refused")
        let bad = NWConnection(to: .unix(path: path + ".missing"), using: .tcp)
        bad.stateUpdateHandler = { if case .failed(let e) = $0 { XCTAssertEqual(e, .posix(.ENOENT)); refused.fulfill() } }
        bad.start(queue: q)
        wait(for: [refused], timeout: 2)
    }

    func testDistributedNotificationCenterPostsLocally() {
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name("com.example.runway.ping")
        let got = expectation(description: "posted")
        let token = center.addObserver(forName: name, object: nil, queue: nil) { n in
            XCTAssertEqual(n.object as? String, "sender")
            got.fulfill()
        }
        center.postNotificationName(name, object: "sender", userInfo: ["k": 1], deliverImmediately: true)
        wait(for: [got], timeout: 2)
        center.removeObserver(token)
    }
}
