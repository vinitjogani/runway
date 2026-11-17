// SF Symbols names resolve to drawn art: base glyphs, and variants composed
// from them (.fill, .circle, .circle.fill, .square, .slash).

import XCTest
@testable import RunwayCore

final class SymbolArtTests: XCTestCase {
    func testVariantsResolveToTheirBase() {
        XCTAssertEqual(SymbolArt.resolve("xmark.circle.fill"), .init(base: "xmark", fill: true, enclosure: .circle))
        XCTAssertEqual(SymbolArt.resolve("person.crop.circle"), .init(base: "person.crop", enclosure: .circle))
        XCTAssertEqual(SymbolArt.resolve("folder.fill.badge.plus"), .init(base: "folder.badge.plus", fill: true))
        XCTAssertEqual(SymbolArt.resolve("icloud.slash"), .init(base: "icloud", slash: true))
        XCTAssertEqual(SymbolArt.resolve("circle.fill"), .init(base: "circle", fill: true))
        XCTAssertNil(SymbolArt.resolve("no.such.symbol"))
    }

    func testSVGIsCompleteAndTintable() throws {
        let svg = try XCTUnwrap(SymbolArt.svg("checkmark.circle.fill"))
        XCTAssertTrue(svg.hasPrefix("<svg") && svg.hasSuffix("</svg>"))
        XCTAssertTrue(svg.contains("currentColor"))
        XCTAssertTrue(svg.contains("<mask"), "a filled enclosure knocks the glyph out")
        XCTAssertNotNil(SymbolArt.svg("gearshape"))
    }

    /// Every symbol name an app in this repo uses has art, when the file
    /// listing them is given (RUNWAY_SYMBOL_NAMES=path, one name per line).
    func testAppSymbolsHaveArt() throws {
        guard let path = ProcessInfo.processInfo.environment["RUNWAY_SYMBOL_NAMES"] else { throw XCTSkip("no list") }
        let names = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        let missing = names.filter { SymbolArt.svg($0) == nil }
        XCTAssertEqual(missing, [], "symbols without art")
    }
}
