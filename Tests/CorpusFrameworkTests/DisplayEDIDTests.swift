import XCTest
@testable import CoreGraphics

final class DisplayEDIDTests: XCTestCase {
    func testParsesVendorModelSerialAndName() {
        var e = [UInt8](repeating: 0, count: 128)
        e[0...7] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        e[8] = 0x06; e[9] = 0x10              // "APP" (Apple), as the Mac's vendor number 0x610
        e[10] = 0x34; e[11] = 0x12            // product 0x1234
        e[12] = 0x78; e[13] = 0x56; e[14] = 0x34; e[15] = 0x12
        e[21] = 60; e[22] = 34
        let d = 54 + 18                        // second descriptor: monitor name
        e[d + 3] = 0xFC
        let name = Array("Studio\n".utf8)
        for (i, b) in name.enumerated() { e[d + 5 + i] = b }
        let id = DisplayEDID.parse(e)
        XCTAssertEqual(id.vendor, 0x610)
        XCTAssertEqual(id.model, 0x1234)
        XCTAssertEqual(id.serial, 0x12345678)
        XCTAssertEqual(id.name, "Studio")
        XCTAssertEqual(id.widthMM, 600)
        XCTAssertEqual(CGDisplayIsInMirrorSet(CGMainDisplayID()), 0)
    }
}
