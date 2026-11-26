// SF Symbols names resolve to drawn art: base glyphs, and variants composed
// from them (.fill, .circle, .circle.fill, .square, .slash).

import XCTest
@testable import RunwayCore
import CoreGraphics

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

    func testMobileChartAndActivitySymbolsResolve() throws {
        let names = ["chart.line.uptrend.xyaxis", "chart.bar.fill", "chart.bar.xaxis", "hourglass",
                     "arrowtriangle.down.fill", "lightbulb", "figure.run", "figure.mixed.cardio", "book.closed",
                     "dumbbell.fill", "leaf.fill", "rosette", "point.3.connected.trianglepath.dotted", "wave.3.right"]
        for name in names { XCTAssertNotNil(SymbolArt.svg(name), name) }
        let down = try XCTUnwrap(SymbolArt.svg("arrowtriangle.down.fill"))
        XCTAssertNotEqual(down, SymbolArt.svg("arrowtriangle.up.fill"))
        XCTAssertNotEqual(SymbolArt.svg("waveform.path.ecg"), SymbolArt.svg("waveform"))
        let trend = try XCTUnwrap(SymbolArt.svg("chart.line.uptrend.xyaxis"))
        XCTAssertTrue(trend.contains("M14.5 9H19v4.5"))
    }

    func testLocalOverrideLooksUpTheExactSymbolName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" fill="black"/></svg>"#
        try svg.write(to: directory.appendingPathComponent("chevron.down.svg"), atomically: true, encoding: .utf8)
        try "not SVG artwork".write(to: directory.appendingPathComponent("chevron.up.svg"), atomically: true, encoding: .utf8)

        XCTAssertEqual(SymbolArt.overrideSVG("chevron.down", in: directory), svg)
        XCTAssertNil(SymbolArt.overrideSVG("chevron.down.circle", in: directory))
        XCTAssertNil(SymbolArt.overrideSVG("chevron.up", in: directory))
        XCTAssertNil(SymbolArt.overrideSVG("../chevron.down", in: directory))
        XCTAssertNotNil(SymbolArt.svg("chevron.down.circle"))
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

final class SymbolPathsTests: XCTestCase {
    func testPlainGlyphParsesToStrokes() throws {
        let shapes = try XCTUnwrap(SymbolPaths.shapes("plus"))
        XCTAssertFalse(shapes.isEmpty)
        XCTAssertTrue(shapes.allSatisfy { $0.stroke && !$0.fill && !$0.knockout })
        XCTAssertEqual(shapes[0].strokeWidth, 1.75, accuracy: 0.01)
    }

    func testFilledEnclosureKnocksTheGlyphOut() throws {
        let shapes = try XCTUnwrap(SymbolPaths.shapes("checkmark.circle.fill"))
        XCTAssertTrue(shapes.contains { $0.fill && !$0.knockout })
        XCTAssertTrue(shapes.contains { $0.knockout })
        // The glyph sits inside the circle, at about half size.
        for s in shapes where s.knockout {
            for case let .line(p) in s.elements { XCTAssertTrue((4...20).contains(p.x) && (4...20).contains(p.y), "\(p)") }
        }
    }

    func testArcsBecomeCurvesEndingAtTheTarget() {
        let e = SymbolPaths.pathData("M2 12a10 10 0 0120 0")
        guard case let .curve(end, _, _)? = e.last else { return XCTFail("\(e)") }
        XCTAssertEqual(end.x, 22, accuracy: 0.001)
        XCTAssertEqual(end.y, 12, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(e.count, 3)
    }

    func testRelativeCommandsAndShorthands() {
        let e = SymbolPaths.pathData("m1 1h4v4H1z")
        XCTAssertEqual(e.count, 5)
        if case let .line(p) = e[2] { XCTAssertEqual(p, CGPoint(x: 5, y: 5)) } else { XCTFail() }
    }

    func testEveryMappedSymbolParses() {
        for name in ["gearshape", "magnifyingglass", "person.crop.circle.fill", "xmark.circle.fill", "bubble.left", "arrow.triangle.branch", "doc.on.doc"] {
            XCTAssertFalse((SymbolPaths.shapes(name) ?? []).isEmpty, name)
        }
    }
}
