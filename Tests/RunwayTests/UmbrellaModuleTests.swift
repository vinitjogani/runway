// `import Cocoa` and `import Darwin` resolve as on the Mac.
import XCTest
import Cocoa
import Darwin

final class UmbrellaModuleTests: XCTestCase {
    func testCocoaBringsAppKitAndFoundation() {
        XCTAssertEqual(NSColor.white.rgba(dark: false), .white)
        XCTAssertEqual(URL(fileURLWithPath: "/tmp").lastPathComponent, "tmp")
    }
    func testDarwinIsTheCLibrary() {
        XCTAssertEqual(strlen("runway"), 6)
        XCTAssertGreaterThan(getpid(), 0)
    }
}
