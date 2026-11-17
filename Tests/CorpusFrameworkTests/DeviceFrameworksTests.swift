import XCTest
import CoreBluetooth
import CoreWLAN
import ScriptingBridge
import simd

final class DeviceFrameworksTests: XCTestCase {
    final class Central: NSObject, CBCentralManagerDelegate {
        var states: [CBManagerState] = []
        let done: XCTestExpectation
        init(_ done: XCTestExpectation) { self.done = done }
        func centralManagerDidUpdateState(_ central: CBCentralManager) { states.append(central.state); done.fulfill() }
    }

    func testBluetoothIsPoweredOff() {
        let delegate = Central(expectation(description: "state"))
        let manager = CBCentralManager(delegate: delegate, queue: .global())
        wait(for: [delegate.done], timeout: 5)
        XCTAssertEqual(delegate.states, [.poweredOff])
        XCTAssertTrue(manager.retrievePeripherals(withIdentifiers: [UUID()]).isEmpty)
        XCTAssertEqual(CBUUID(string: "180d").uuidString, "180D")
    }

    func testWiFiInterfacesComeFromSysfs() {
        let names = CWWiFiClient.interfaceNames() ?? []
        XCTAssertEqual(CWWiFiClient.shared.interfaces()?.count ?? 0, names.count)
    }

    func testScriptingBridgeFindsNoApplications() {
        XCTAssertNil(SBApplication(bundleIdentifier: "com.apple.finder"))
    }

    func testSIMDMatrices() {
        let m = simd_double3x3(rows: [SIMD3(2, 0, 0), SIMD3(0, 3, 0), SIMD3(1, 0, 4)])
        XCTAssertEqual(m * SIMD3(1, 1, 1), SIMD3(2, 3, 5))
        let i = m * m.inverse
        for c in 0..<3 { for r in 0..<3 { XCTAssertEqual(i[c, r], c == r ? 1 : 0, accuracy: 1e-12) } }
        XCTAssertEqual(m.determinant, 24, accuracy: 1e-12)
        XCTAssertEqual(simd_mix(SIMD3<Double>(0, 0, 0), SIMD3(2, 4, 6), SIMD3(repeating: 0.5)), SIMD3(1, 2, 3))
        XCTAssertEqual(simd_smoothstep(0.0, 1.0, 0.5), 0.5)
        XCTAssertEqual(simd_precise_cbrt(27), 3, accuracy: 1e-12)
    }
}
