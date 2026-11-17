import XCTest
import SwiftUI
import AppKit

final class AppKitCorpusTests: XCTestCase {
    func testNSColorArchivesWithSecureCoding() throws {
        let c = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let data = try NSKeyedArchiver.archivedData(withRootObject: c, requiringSecureCoding: true)
        let back = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
        XCTAssertEqual(back, c)
    }

    @MainActor func testColorResolvedRoundTrips() throws {
        let r = Color(red: 1, green: 0.5, blue: 0).resolve(in: EnvironmentValues())
        XCTAssertEqual(r.green, 0.5, accuracy: 0.001)
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(Color.Resolved.self, from: data), r)
    }

    @MainActor func testRunningApplicationsIncludeThisProcess() {
        XCTAssertTrue(NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier })
        XCTAssertNotNil(NSRunningApplication.current.executableURL)
    }
}
