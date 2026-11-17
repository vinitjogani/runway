import SwiftParser
import XCTest
@testable import RunwayTranspiler

/// Overrides in extensions move into their class body (Relocate.swift).
final class RelocateTests: XCTestCase {
    static let classFile = "/pkg/Sources/App/Editor.swift"
    static let extFile = "/pkg/Sources/App/EditorBehaviours.swift"

    /// Transforms every file of a package independently (as `runway` does),
    /// checking each output parses, keeps its lines and has nothing left over.
    func package(_ files: [(String, String)], _ fileLine: StaticString = #filePath, line: UInt = #line) -> [String: String] {
        let index = PackageIndex(files: files)
        var out: [String: String] = [:]
        // Transform in reverse order too, with a fresh index: the result mustn't depend on order.
        let reversedIndex = PackageIndex(files: files)
        var reversed: [String: String] = [:]
        for (path, source) in files.reversed() {
            reversed[path] = RunwayTranspiler.transform(source: source, fileName: path, index: reversedIndex)
        }
        for (path, source) in files {
            let o = RunwayTranspiler.transform(source: source, fileName: path, index: index)
            let r = RunwayTranspiler.verify(original: source, output: o)
            XCTAssertFalse(r.parseErrors, "output doesn't parse:\n\(o)", file: fileLine, line: line)
            XCTAssertEqual(r.leftovers, [], "left over in:\n\(o)", file: fileLine, line: line)
            XCTAssertFalse(r.linesShifted, "lines moved:\n\(o)", file: fileLine, line: line)
            XCTAssertEqual(o, reversed[path], "order-dependent output for \(path)", file: fileLine, line: line)
            out[path] = o
        }
        return out
    }

    func assertContains(_ out: String?, _ needles: String..., file: StaticString = #filePath, line: UInt = #line) {
        for n in needles { XCTAssertTrue(out?.contains(n) == true, "missing \(n) in:\n\(out ?? "nil")", file: file, line: line) }
    }
    func assertLacks(_ out: String?, _ needles: String..., file: StaticString = #filePath, line: UInt = #line) {
        for n in needles { XCTAssertFalse(out?.contains(n) == true, "unexpected \(n) in:\n\(out ?? "nil")", file: file, line: line) }
    }

    /// Lines of `text` (1-based).
    func lines(_ text: String?) -> [Substring] { (text ?? "").split(separator: "\n", omittingEmptySubsequences: false) }

    // MARK: Across files

    func testOverridesMoveIntoTheClassBodyInAnotherFile() {
        let cls = """
        import AppKit

        final class Editor: NSTextView {
            var count = 0
        }
        """
        let ext = """
        import AppKit
        import UniformTypeIdentifiers

        extension Editor {
            /// Clicks.
            override func mouseDown(with event: NSEvent) {
                count += 1
                super.mouseDown(with: event)
            }
            func plain() {}
            override var isFlipped: Bool { true }
            override subscript(i: Int) -> Int { i }
        }
        """
        let out = package([(Self.classFile, cls), (Self.extFile, ext)])
        let c = out[Self.classFile], e = out[Self.extFile]
        XCTAssertEqual(c, """
        import AppKit; import UniformTypeIdentifiers

        final class Editor: NSTextView {
            var count = 0

        \(Relocate.beginMarker)
        #sourceLocation(file: "\(Self.extFile)", line: 6)
            override func mouseDown(with event: NSEvent) {
                count += 1
                super.mouseDown(with: event)
            }
        #sourceLocation(file: "\(Self.extFile)", line: 11)
            override var isFlipped: Bool { true }
        #sourceLocation(file: "\(Self.extFile)", line: 12)
            override subscript(i: Int) -> Int { i }
        \(Relocate.endMarker)
        #sourceLocation(file: "\(Self.classFile)", line: 5)
        }
        """)
        // The extension keeps its other members and every line.
        let el = lines(e)
        XCTAssertEqual(el[4], "    /// Clicks.")
        XCTAssertEqual(el[5], "    /* override func mouseDown(with:): moved into the body of Editor in Editor.swift by RunwayTranspiler */")
        XCTAssertEqual(el[6...8], ["", "", ""])
        XCTAssertEqual(el[9], "    func plain() {}")
        XCTAssertTrue(el[10].hasPrefix("    /* override var isFlipped"))
        XCTAssertEqual(el.count, lines(ext).count)
    }

    func testInitializersMoveToo() {
        let cls = "import AppKit\nclass Panel: NSView {\n}\n"
        let ext = """
        import AppKit
        extension Panel {
            convenience override init(frame: NSRect) { self.init(frame: frame) }
            required init?(coder: NSCoder) { fatalError() }
        }
        """
        let out = package([(Self.classFile, cls), (Self.extFile, ext)])
        assertContains(out[Self.classFile], "    convenience override init(frame: NSRect)", "    required init?(coder: NSCoder) { fatalError() }")
        assertContains(out[Self.extFile], "/* override init(frame:): moved", "/* required init(coder:): moved")
    }

    func testSameFileExtensionMoves() {
        let src = """
        import AppKit
        class Canvas: NSView {
            var hits = 0
        }
        extension Canvas {
            override func draw(_ dirtyRect: NSRect) { hits += 1 }
        }
        """
        let out = package([(Self.classFile, src)])[Self.classFile]
        assertContains(out, "#sourceLocation(file: \"\(Self.classFile)\", line: 6)\n    override func draw(_ dirtyRect: NSRect) { hits += 1 }\n",
                       "#sourceLocation(file: \"\(Self.classFile)\", line: 4)\n}",
                       "/* override func draw(_:): moved into the body of Canvas by RunwayTranspiler */")
    }

    // MARK: Access

    func testFilePrivateHelpersTheMovedCodeUsesBecomeInternal() {
        let cls = "import AppKit\nfinal class Editor: NSView {\n}\n"
        let ext = """
        import AppKit

        private let margin: CGFloat = 4
        private struct Hit { var p: NSPoint; fileprivate var inside: Bool { p.x > margin } }
        fileprivate enum Unused { case a }
        private func unrelated() {}

        extension Editor {
            override func mouseDown(with event: NSEvent) {
                if handle(Hit(p: event.locationInWindow)) { return }
            }
            private func handle(_ h: Hit) -> Bool { h.inside && check(Mode.on) }
            private func untouched() {}
        }

        private extension Editor {
            func check(_ m: Mode) -> Bool { true }
        }
        fileprivate enum Mode { case on }
        """
        let out = package([(Self.classFile, cls), (Self.extFile, ext)])
        let e = out[Self.extFile]
        assertContains(e, "internal let margin", "internal struct Hit", "internal var inside", "internal func handle(_ h: Hit)",
                       "internal extension Editor", "internal enum Mode")
        assertContains(e, "fileprivate enum Unused", "private func unrelated()", "private func untouched()")
    }

    func testAMovedMembersOwnPrivateGoes() {
        let cls = "import AppKit\nclass V: NSView {\n}\n"
        let ext = "import AppKit\nextension V {\n    fileprivate override func layout() {}\n}\n"
        let out = package([(Self.classFile, cls), (Self.extFile, ext)])
        assertContains(out[Self.classFile], "    internal override func layout() {}")
    }

    // MARK: #if and nesting

    func testConditionsAreCarriedIntoTheClassBody() {
        let cls = "import AppKit\nclass V: NSView {\n}\n"
        let ext = """
        import AppKit
        #if DEBUG
        extension V {
            #if os(macOS)
            override func layout() {}
            #else
            override func display() {}
            #endif
        }
        #endif
        """
        let out = package([(Self.classFile, cls), (Self.extFile, ext)])
        assertContains(out[Self.classFile],
                       "#sourceLocation(file: \"\(Self.extFile)\", line: 4)\n#if (DEBUG) && (true)\n    override func layout() {}\n#endif\n",
                       "#sourceLocation(file: \"\(Self.extFile)\", line: 6)\n#if (DEBUG) && !(true)\n    override func display() {}\n#endif\n")
    }

    func testNestedClassesAndTheirOwnOverridesStayPut() {
        let cls = """
        import AppKit
        enum Outer {
            final class Inner: NSView { var n = 0 }
        }
        """
        let ext = """
        import AppKit
        extension Outer.Inner {
            override func layout() { n += 1 }
            final class Deeper: NSView { override func layout() {} }
        }
        """
        let out = package([(Self.classFile, cls), (Self.extFile, ext)])
        let c = lines(out[Self.classFile])
        // The brace that closed Inner on line 3 moved down, after the block.
        XCTAssertEqual(c[2], "    final class Inner: NSView { var n = 0 ")
        assertContains(out[Self.classFile], "#sourceLocation(file: \"\(Self.extFile)\", line: 3)\n    override func layout() { n += 1 }\n",
                       "#sourceLocation(file: \"\(Self.classFile)\", line: 3)\n" + String(repeating: " ", count: 42) + "}\n}")
        // A class declared inside the extension has its overrides in its own body already.
        assertContains(out[Self.extFile], "final class Deeper: NSView { override func layout() {} }")
    }

    // MARK: Left alone

    func testConstrainedAndExternalExtensionsStayWithANote() {
        let cls = "import AppKit\nclass Box<T>: NSView {\n}\n"
        let ext = """
        import AppKit
        extension Box where T == Int {
            override func layout() {}
        }
        extension Box<String> {
            override func display() {}
        }
        extension NSView {
            override func keyDown(with e: NSEvent) {}
        }
        extension Box {
            override func updateLayer() {}
        }
        """
        let out = package([(Self.classFile, cls), (Self.extFile, ext)])
        let e = out[Self.extFile]
        // An override in an extension of a framework class is detached (kept as a plain member).
        assertContains(e, "    override func layout() {}", "    override func display() {}", "    func _runwayDetached_keyDown(with e: NSEvent) {}",
                       "// RunwayTranspiler: override func layout() (line 3) stays in its extension of Box: the extension is generic or constrained",
                       "// RunwayTranspiler: override func display() (line 6) stays",
                       "// RunwayTranspiler: override func keyDown(with:) (line 9) extends NSView, a class outside this package")
        // An unconstrained extension of a generic class moves.
        assertContains(out[Self.classFile], "    override func updateLayer() {}")
        assertLacks(out[Self.classFile], "override func layout", "override func display")
    }

    func testAnotherModulesClassIsLeftAlone() {
        let cls = "import AppKit\nopen class Base: NSView {\n}\n"
        let ext = "import AppKit\nimport Kit\nextension Base {\n    override func layout() {}\n}\n"
        let out = package([("/pkg/Sources/Kit/Base.swift", cls), ("/pkg/Sources/App/Ext.swift", ext)])
        assertContains(out["/pkg/Sources/App/Ext.swift"], "    override func layout() {}", "Base is declared in another module (Kit)")
        XCTAssertEqual(out["/pkg/Sources/Kit/Base.swift"], cls)
    }

    // MARK: With the rest of the transpiler

    func testMovedCodeIsRewrittenAndKeepsTheDispatchHook() {
        let cls = """
        import AppKit
        final class Doc: NSResponder {
            @objc func save(_ sender: Any?) {}
        }
        """
        let ext = """
        import AppKit
        extension Doc {
            @objc override func validateMenuItem(_ item: NSMenuItem) -> Bool { item.action == #selector(save(_:)) }
        }
        """
        let out = package([(Self.classFile, cls), (Self.extFile, ext)])
        let c = out[Self.classFile]
        assertContains(c, "func validateMenuItem(_ item: NSMenuItem) -> Bool { item.action == Selector(\"save:\") }",
                       "#sourceLocation(file: \"\(Self.classFile)\", line: 4)\nfunc _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool")
        assertLacks(c, "@objc", "#selector")
    }

    func testFilesStandingAloneAreUnchanged() {
        let src = "import AppKit\nclass V: NSView {\n    override func layout() {}\n}\n"
        XCTAssertEqual(package([(Self.classFile, src)])[Self.classFile], src)
    }
}
