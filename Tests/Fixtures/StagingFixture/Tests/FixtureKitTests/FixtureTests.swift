import FixtureKit
import Foundation
import XCTest

final class FixtureTests: XCTestCase {
    func testFilePathNamesTheOriginal() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixture.txt")
        XCTAssertEqual(try String(contentsOf: fixture, encoding: .utf8), "fixture\n")
        XCTAssertTrue(fixtureWhere().hasSuffix("Sources/FixtureKit/Kit.swift"))
        XCTAssertFalse(fixtureWhere().contains(".runway"))
    }
}
