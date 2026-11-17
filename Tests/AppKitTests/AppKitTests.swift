// AppKit's view system on the headless backend: Auto Layout against known
// solutions, coordinate conversion, hit testing, the responder chain and
// target/action, menu validation and key equivalents, draw(_:) display
// lists, event dispatch and tracking areas, and the bitmap rasterizer.

import XCTest
import RunwayCore
import RunwayObjC
@testable import AppKit

// MARK: Helpers

/// A responder with actions, as the transpiler would generate.
final class ActionTarget: NSResponder, SelectorDispatching {
    var performed: [String] = []
    var enabled = true
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .perform(sel, _):
            switch sel.name {
            case "doThing:", "other:": performed.append(sel.name); return true
            case "validateMenuItem:": m.result = enabled; return true
            default: return false
            }
        case let .responds(sel): return ["doThing:", "other:", "validateMenuItem:"].contains(sel.name)
        default: return false
        }
    }
}

class FlippedView: NSView { override var isFlipped: Bool { true } }

final class IntrinsicView: NSView {
    var size: NSSize
    init(_ s: NSSize) { size = s; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { size }
}

final class RecordingView: NSView {
    var events: [String] = []
    var lastLocation: NSPoint = .zero
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with e: NSEvent) { events.append("down\(e.clickCount)"); lastLocation = convert(e.locationInWindow, from: nil) }
    override func mouseDragged(with e: NSEvent) { events.append("drag") }
    override func mouseUp(with e: NSEvent) { events.append("up") }
    override func mouseEntered(with e: NSEvent) { events.append("entered") }
    override func mouseExited(with e: NSEvent) { events.append("exited") }
    override func mouseMoved(with e: NSEvent) { events.append("moved") }
    override func keyDown(with e: NSEvent) { events.append("key:\(e.charactersIgnoringModifiers ?? "")/\(e.keyCode)") }
    override func scrollWheel(with e: NSEvent) { events.append("scroll:\(e.scrollingDeltaY)") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 10, y: 10, width: 20, height: 20)).fill()
    }
}

@MainActor
final class AppKitTests: XCTestCase {
    var backend: HeadlessBackend!

    override func setUp() async throws {
        backend = HeadlessBackend()
        Runway.install(backend)
        AppKitRuntime.install()
    }

    func assertRect(_ a: NSRect, _ b: NSRect, accuracy: CGFloat = 0.01, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, "x \(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, "y \(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, "w \(a) vs \(b)", file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, "h \(a) vs \(b)", file: file, line: line)
    }

    // MARK: The solver

    func testCassowaryRequiredAndWeak() throws {
        let s = CassowarySolver()
        let x = CassowarySolver.Variable("x"), y = CassowarySolver.Variable("y")
        typealias E = CassowarySolver.Expression
        typealias T = CassowarySolver.Term
        // x + y == 100 (required), x == 70 (strong), x == 20 (weak), y >= 10.
        try s.add(.init(E([T(variable: x, coefficient: 1), T(variable: y, coefficient: 1)], -100), .equal, strength: CassowarySolver.required))
        try s.add(.init(E([T(variable: x, coefficient: 1)], -70), .equal, strength: 1000))
        try s.add(.init(E([T(variable: x, coefficient: 1)], -20), .equal, strength: 1))
        try s.add(.init(E([T(variable: y, coefficient: 1)], -10), .greaterOrEqual, strength: CassowarySolver.required))
        s.updateVariables()
        XCTAssertEqual(x.value, 70, accuracy: 1e-6)
        XCTAssertEqual(y.value, 30, accuracy: 1e-6)
        // y >= 50 (required) pushes x down.
        try s.add(.init(E([T(variable: y, coefficient: 1)], -50), .greaterOrEqual, strength: CassowarySolver.required))
        s.updateVariables()
        XCTAssertEqual(x.value, 50, accuracy: 1e-6)
    }

    func testCassowaryEditVariables() throws {
        let s = CassowarySolver()
        let w = CassowarySolver.Variable("w"), half = CassowarySolver.Variable("half")
        typealias E = CassowarySolver.Expression
        typealias T = CassowarySolver.Term
        try s.add(.init(E([T(variable: half, coefficient: 2), T(variable: w, coefficient: -1)]), .equal, strength: CassowarySolver.required))
        try s.addEditVariable(w, strength: 1_000_000)
        for v in [100.0, 340, 12] {
            try s.suggest(w, v)
            s.updateVariables()
            XCTAssertEqual(half.value, v / 2, accuracy: 1e-6)
        }
    }

    func testUnsatisfiableRequiredIsBrokenNotFatal() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(v)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 50),
            v.widthAnchor.constraint(equalToConstant: 80),
            v.heightAnchor.constraint(equalToConstant: 10),
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            v.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(v.frame.width == 50 || v.frame.width == 80)
    }

    // MARK: Auto Layout

    func testPinnedToEdgesWithInsets() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let child = NSView()
        child.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            child.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            child.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            child.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -40),
        ])
        root.layoutSubtreeIfNeeded()
        // Unflipped superview: origin at the bottom-left, so y = bottom inset.
        assertRect(child.frame, NSRect(x: 10, y: 40, width: 370, height: 230))
        // Resizing the root re-solves.
        root.setFrameSize(NSSize(width: 500, height: 200))
        root.layoutSubtreeIfNeeded()
        assertRect(child.frame, NSRect(x: 10, y: 40, width: 470, height: 130))
    }

    func testFlippedSuperviewPutsTopAtLowY() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let child = NSView()
        child.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 5),
            child.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            child.widthAnchor.constraint(equalToConstant: 100),
            child.heightAnchor.constraint(equalToConstant: 50),
        ])
        root.layoutSubtreeIfNeeded()
        assertRect(child.frame, NSRect(x: 5, y: 30, width: 100, height: 50))
    }

    func testEqualWidthsSpacingAndMultiplier() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        let a = NSView(), b = NSView(), c = NSView()
        for v in [a, b, c] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            a.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            b.leadingAnchor.constraint(equalTo: a.trailingAnchor, constant: 20),
            b.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            a.widthAnchor.constraint(equalTo: b.widthAnchor),
            a.topAnchor.constraint(equalTo: root.topAnchor), a.heightAnchor.constraint(equalToConstant: 20),
            b.topAnchor.constraint(equalTo: root.topAnchor), b.heightAnchor.constraint(equalTo: a.heightAnchor),
            // c: half the root's width, centred.
            c.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.5),
            c.heightAnchor.constraint(equalTo: root.heightAnchor, multiplier: 0.25, constant: 5),
            c.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            c.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        assertRect(a.frame, NSRect(x: 10, y: 80, width: 140, height: 20))
        assertRect(b.frame, NSRect(x: 170, y: 80, width: 140, height: 20))
        assertRect(c.frame, NSRect(x: 80, y: 35, width: 160, height: 30))
    }

    func testIntrinsicSizeHuggingAndCompression() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let label = IntrinsicView(NSSize(width: 80, height: 20))
        let field = IntrinsicView(NSSize(width: 50, height: 20))
        root.addSubview(label); root.addSubview(field)
        // Field hugs less, so it takes the extra space.
        field.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            label.topAnchor.constraint(equalTo: root.topAnchor), field.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        assertRect(label.frame, NSRect(x: 0, y: 0, width: 80, height: 20))
        assertRect(field.frame, NSRect(x: 88, y: 0, width: 212, height: 20))
        // Too narrow: the label resists compression more than the field.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.setFrameSize(NSSize(width: 100, height: 100))
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(label.frame.width, 80, accuracy: 0.01)
        XCTAssertEqual(field.frame.width, 12, accuracy: 0.01)
        // invalidateIntrinsicContentSize re-solves with the new size.
        label.size = NSSize(width: 60, height: 20)
        label.invalidateIntrinsicContentSize()
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(label.frame.width, 60, accuracy: 0.01)
    }

    func testPrioritiesAndConstantChanges() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(v)
        let wide = v.widthAnchor.constraint(equalToConstant: 200)
        wide.priority = .defaultLow
        let narrow = v.widthAnchor.constraint(lessThanOrEqualToConstant: 120)
        narrow.priority = .defaultHigh
        NSLayoutConstraint.activate([wide, narrow, v.heightAnchor.constraint(equalToConstant: 10),
                                     v.leadingAnchor.constraint(equalTo: root.leadingAnchor), v.topAnchor.constraint(equalTo: root.topAnchor)])
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(v.frame.width, 120, accuracy: 0.01)
        narrow.constant = 150
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(v.frame.width, 150, accuracy: 0.01)
        narrow.isActive = false
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(v.frame.width, 200, accuracy: 0.01)
    }

    func testNestedConstraintsAndTranslatingParent() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let panel = FlippedView(frame: NSRect(x: 50, y: 60, width: 200, height: 100))   // frame-based
        root.addSubview(panel)
        let inner = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            inner.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            inner.topAnchor.constraint(equalTo: panel.topAnchor, constant: 5),
            inner.heightAnchor.constraint(equalToConstant: 30),
        ])
        root.layoutSubtreeIfNeeded()
        assertRect(inner.frame, NSRect(x: 10, y: 5, width: 180, height: 30))
        panel.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        root.layoutSubtreeIfNeeded()
        assertRect(inner.frame, NSRect(x: 10, y: 5, width: 280, height: 30))
    }

    func testVisualFormatLanguage() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let a = NSView(), b = NSView()
        for v in [a, b] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        let views = ["a": a, "b": b]
        NSLayoutConstraint.activate(
            NSLayoutConstraint.constraints(withVisualFormat: "H:|-[a(==60)]-15-[b(>=40)]-|", options: [.alignAllTop], metrics: nil, views: views) +
            NSLayoutConstraint.constraints(withVisualFormat: "V:|-pad-[a(h)]", options: [], metrics: ["pad": 12, "h": 25], views: views) +
            NSLayoutConstraint.constraints(withVisualFormat: "V:[b(==a)]", options: [], metrics: nil, views: views))
        root.layoutSubtreeIfNeeded()
        assertRect(a.frame, NSRect(x: 20, y: 12, width: 60, height: 25))
        assertRect(b.frame, NSRect(x: 95, y: 12, width: 185, height: 25))
    }

    func testFittingSize() {
        let root = NSView()
        let a = IntrinsicView(NSSize(width: 70, height: 20))
        let b = IntrinsicView(NSSize(width: 30, height: 40))
        root.addSubview(a); root.addSubview(b)
        NSLayoutConstraint.activate([
            a.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            b.leadingAnchor.constraint(equalTo: a.trailingAnchor, constant: 5),
            root.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: 10),
            a.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            b.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            root.bottomAnchor.constraint(greaterThanOrEqualTo: a.bottomAnchor, constant: 8),
            root.bottomAnchor.constraint(greaterThanOrEqualTo: b.bottomAnchor, constant: 8),
        ])
        XCTAssertEqual(root.fittingSize, NSSize(width: 125, height: 56))
    }

    func testLayoutGuideAndLayoutOverride() {
        final class Custom: NSView {
            var laidOut = 0
            override func layout() { super.layout(); laidOut += 1 }
        }
        let root = Custom(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let guide = NSLayoutGuide()
        root.addLayoutGuide(guide)
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(v)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            guide.widthAnchor.constraint(equalToConstant: 50),
            guide.topAnchor.constraint(equalTo: root.topAnchor), guide.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: guide.trailingAnchor),
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            v.topAnchor.constraint(equalTo: root.layoutMarginsGuide.topAnchor),
            v.heightAnchor.constraint(equalToConstant: 10),
        ])
        root.layoutSubtreeIfNeeded()
        assertRect(guide.frame, NSRect(x: 20, y: 0, width: 50, height: 100))
        assertRect(v.frame, NSRect(x: 70, y: 70, width: 130, height: 10))
        XCTAssertGreaterThan(root.laidOut, 0)
        XCTAssertLessThanOrEqual(root.laidOut, 2, "one pass, not one per settle iteration")
        let n = root.laidOut
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(root.laidOut, n, "nothing changed: layout() isn't called again")
    }

    func testAutoresizingMask() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let stretch = NSView(frame: NSRect(x: 10, y: 10, width: 180, height: 80))
        stretch.autoresizingMask = [.width, .height]
        let pinnedRight = NSView(frame: NSRect(x: 150, y: 10, width: 40, height: 20))
        pinnedRight.autoresizingMask = [.minXMargin]
        root.addSubview(stretch); root.addSubview(pinnedRight)
        root.setFrameSize(NSSize(width: 300, height: 150))
        assertRect(stretch.frame, NSRect(x: 10, y: 10, width: 280, height: 130))
        assertRect(pinnedRight.frame, NSRect(x: 250, y: 10, width: 40, height: 20))
    }

    // MARK: Coordinates and hit testing

    func testCoordinateConversion() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))          // unflipped
        let flipped = FlippedView(frame: NSRect(x: 100, y: 50, width: 200, height: 100))
        let inner = NSView(frame: NSRect(x: 10, y: 20, width: 50, height: 40))          // unflipped in a flipped parent
        root.addSubview(flipped); flipped.addSubview(inner)
        // Flipped's top-left in root's (y-up) coordinates is (100, 150).
        XCTAssertEqual(flipped.convert(NSPoint(x: 0, y: 0), to: root), NSPoint(x: 100, y: 150))
        XCTAssertEqual(root.convert(NSPoint(x: 100, y: 150), to: flipped), NSPoint(x: 0, y: 0))
        // inner's origin (bottom-left) sits at flipped (10, 60) → root (110, 90).
        XCTAssertEqual(inner.convert(NSPoint.zero, to: flipped), NSPoint(x: 10, y: 60))
        XCTAssertEqual(inner.convert(NSPoint.zero, to: root), NSPoint(x: 110, y: 90))
        XCTAssertEqual(root.convert(NSPoint(x: 110, y: 90), to: inner), .zero)
        XCTAssertEqual(inner.convert(NSRect(x: 0, y: 0, width: 50, height: 40), to: root), NSRect(x: 110, y: 90, width: 50, height: 40))
        // Bounds origin scrolls: content at (0, 30) shows at the top.
        flipped.setBoundsOrigin(NSPoint(x: 0, y: 30))
        XCTAssertEqual(flipped.convert(NSPoint(x: 0, y: 30), to: root), NSPoint(x: 100, y: 150))
        // Window coordinates: nil converts to the root's base.
        XCTAssertEqual(inner.convert(NSPoint.zero, to: nil), inner.convert(NSPoint.zero, to: root))
    }

    func testHitTesting() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let a = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let b = FlippedView(frame: NSRect(x: 100, y: 100, width: 200, height: 100))  // overlaps a, on top
        let inB = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))           // at b's top-left
        root.addSubview(a); root.addSubview(b); b.addSubview(inB)
        XCTAssertTrue(root.hitTest(NSPoint(x: 50, y: 50)) === a)
        XCTAssertTrue(root.hitTest(NSPoint(x: 150, y: 150)) === b)
        XCTAssertTrue(root.hitTest(NSPoint(x: 105, y: 195)) === inB)
        XCTAssertTrue(root.hitTest(NSPoint(x: 350, y: 250)) === root)
        XCTAssertNil(root.hitTest(NSPoint(x: 500, y: 10)))
        b.isHidden = true
        XCTAssertTrue(root.hitTest(NSPoint(x: 150, y: 150)) === a)
    }

    // MARK: Responders and actions

    func testResponderChainThroughViewControllerAndWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let vc = NSViewController()
        vc.view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let leaf = RecordingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        w.contentView!.addSubview(vc.view)
        vc.view.addSubview(leaf)
        XCTAssertTrue(leaf.nextResponder === vc.view)
        XCTAssertTrue(vc.view.nextResponder === vc)
        XCTAssertTrue(vc.nextResponder === w.contentView)
        XCTAssertTrue(w.contentView!.nextResponder === w)
        XCTAssertTrue(w.makeFirstResponder(leaf))
        XCTAssertTrue(w.firstResponder === leaf)
    }

    func testSendActionWalksTheChain() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let target = ActionTarget()
        let leaf = RecordingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        w.contentView!.addSubview(leaf)
        leaf.nextResponder = target   // an explicit next responder
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(leaf)
        XCTAssertTrue(NSApp.sendAction(Selector("doThing:"), to: nil, from: self))
        XCTAssertEqual(target.performed, ["doThing:"])
        XCTAssertFalse(NSApp.sendAction(Selector("nobody:"), to: nil, from: self))
        XCTAssertTrue(NSApp.sendAction(Selector("other:"), to: target, from: self))
        XCTAssertTrue(leaf.tryToPerform(Selector("other:"), with: nil))
        XCTAssertEqual(target.performed, ["doThing:", "other:", "other:"])
        // AppKit's own registered actions answer too.
        XCTAssertTrue(NSApp.target(forAction: Selector("performClose:")) as AnyObject? === w)
        w.close()
    }

    func testDoCommandBySelectorAndKeyBindings() {
        final class Editor: NSView {
            var log: [String] = []
            override var acceptsFirstResponder: Bool { true }
            override func keyDown(with e: NSEvent) { interpretKeyEvents([e]) }
            override func insertText(_ s: Any) { log.append("insert \(s)") }
            override func moveLeft(_ sender: Any?) { log.append("moveLeft") }
            override func deleteBackward(_ sender: Any?) { log.append("deleteBackward") }
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let ed = Editor(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        w.contentView!.addSubview(ed)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(ed)
        let n = w.nativeWindow!
        func key(_ name: String, _ chars: String) {
            var e = RawEvent(kind: .keyDown); e.keyName = name; e.characters = chars; e.charactersIgnoringModifiers = chars
            backend.send(e, to: n)
        }
        key("a", "a"); key("Left", ""); key("BackSpace", "")
        XCTAssertEqual(ed.log, ["insert a", "moveLeft", "deleteBackward"])
        w.close()
    }

    // MARK: Menus

    func testMenuValidationAndKeyEquivalents() {
        let target = ActionTarget()
        let menu = NSMenu(title: "Main")
        let file = NSMenu(title: "File")
        let item = file.addItem(withTitle: "Do Thing", action: Selector("doThing:"), keyEquivalent: "d")
        item.target = target
        let shifted = file.addItem(withTitle: "Other", action: Selector("other:"), keyEquivalent: "D")   // ⇧⌘D
        shifted.target = target
        let orphan = file.addItem(withTitle: "Nobody", action: Selector("nobody:"), keyEquivalent: "")
        menu.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        file.update()
        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(orphan.isEnabled, "no target in the chain disables it")
        target.enabled = false
        file.update()
        XCTAssertFalse(item.isEnabled, "validateMenuItem: says no")
        target.enabled = true

        func keyEvent(_ c: String, _ f: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent(type: .keyDown, location: .zero, modifierFlags: f, timestamp: 0, window: nil, characters: c, charactersIgnoringModifiers: c)
        }
        XCTAssertTrue(menu.performKeyEquivalent(with: keyEvent("d", .command)))
        XCTAssertFalse(menu.performKeyEquivalent(with: keyEvent("d", [])))
        XCTAssertTrue(menu.performKeyEquivalent(with: keyEvent("D", [.command, .shift])))
        XCTAssertEqual(target.performed, ["doThing:", "other:"])
        target.enabled = false
        XCTAssertFalse(menu.performKeyEquivalent(with: keyEvent("d", .command)), "disabled items don't fire")
        XCTAssertEqual(item.accelerator, "<Control>d")
        XCTAssertEqual(shifted.accelerator, "<Control><Shift>d")
    }

    func testMainMenuBecomesMenuBarAndContextMenu() {
        let target = ActionTarget()
        let main = NSMenu(title: "")
        let app = NSMenu(title: "")
        app.addItem(withTitle: "Quit", action: Selector("terminate:"), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = app
        let edit = NSMenu(title: "Edit")
        let item = edit.addItem(withTitle: "Thing", action: Selector("doThing:"), keyEquivalent: "")
        item.target = target
        item.state = .on
        edit.addItem(.separator())
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        w.makeKeyAndOrderFront(nil)
        backend.drain()
        let bar = backend.viewSystem.menuBars[ObjectIdentifier(w.nativeWindow!)]
        XCTAssertEqual(bar?.count, 2)
        XCTAssertEqual(bar?[1].title, "Edit")
        XCTAssertEqual(bar?[1].children.first?.checked, true)
        XCTAssertEqual(bar?[1].children.last?.kind, .separator)
        // Choosing it in the bar sends the action.
        backend.viewSystem.menuCallbacks[ObjectIdentifier(w.nativeWindow!)]?.activate(item.id)
        XCTAssertEqual(target.performed, ["doThing:"])
        // A context menu.
        backend.viewSystem.popUpChoice = item.id
        XCTAssertTrue(edit.popUp(positioning: nil, at: .zero, in: w.contentView))
        XCTAssertEqual(target.performed, ["doThing:", "doThing:"])
        NSApp.mainMenu = nil
        w.close()
    }

    // MARK: Drawing

    func testDrawRecordsADisplayListInDeviceSpace() throws {
        let v = RecordingView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        let list = v.recordDrawing()
        XCTAssertEqual(list.ops.count, 1)
        guard case let .fill(path, _, color, state) = list.ops[0] else { return XCTFail("\(list.ops)") }
        XCTAssertEqual(color, [1, 0, 0, 1])
        // Unflipped: (10, 10)-(30, 30) in the view is (10, 20)-(30, 40) top-down.
        let device = path.boundingBox.applying(state.ctm)
        XCTAssertEqual(device, NSRect(x: 10, y: 20, width: 20, height: 20))
    }

    func testDrawingAPIsMapToOps() {
        final class Painter: FlippedView {
            override func draw(_ r: NSRect) {
                NSColor.blue.set()
                let p = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 40, height: 20), xRadius: 4, yRadius: 4)
                p.lineWidth = 3
                p.stroke()
                NSGradient(starting: .white, ending: .black)?.draw(in: NSRect(x: 0, y: 0, width: 10, height: 10), angle: 90)
                "Hi".draw(at: NSPoint(x: 5, y: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 20)])
                NSImage(width: 2, height: 2, rgba: [UInt8](repeating: 255, count: 16)).draw(in: NSRect(x: 0, y: 0, width: 8, height: 8))
                NSGraphicsContext.current?.cgContext.clear(NSRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
        let ops = Painter(frame: NSRect(x: 0, y: 0, width: 100, height: 100)).recordDrawing().ops
        var kinds: [String] = []
        for op in ops {
            switch op {
            case let .stroke(_, style, color, _): kinds.append("stroke"); XCTAssertEqual(style.lineWidth, 3); XCTAssertEqual(color, [0, 0, 1, 1])
            case .linearGradient: kinds.append("gradient")
            case let .text(layout, origin, flipped, _):
                kinds.append("text"); XCTAssertEqual(layout.string, "Hi"); XCTAssertEqual(origin, NSPoint(x: 5, y: 6)); XCTAssertTrue(flipped)
                XCTAssertEqual(layout.runs[0].size, 20)
            case .image: kinds.append("image")
            case .clear: kinds.append("clear")
            case .save, .restore, .clip: break
            default: kinds.append("other")
            }
        }
        XCTAssertEqual(kinds, ["stroke", "gradient", "text", "image", "clear"])
    }

    func testDisplayPassPutsDrawingInACanvasWidget() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let v = RecordingView(frame: NSRect(x: 10, y: 10, width: 100, height: 50))
        w.contentView!.addSubview(v)
        w.makeKeyAndOrderFront(nil)
        let canvas = (v.widget as! HeadlessWidget).children.first { $0.kind == .canvas }
        XCTAssertNotNil(canvas)
        if case .displayList(let l)? = canvas?.props.drawing.first { XCTAssertEqual(l.ops.count, 1) } else { XCTFail() }
        // The view's widget sits at its frame, top-down in the unflipped content view.
        XCTAssertEqual((v.widget as! HeadlessWidget).frame, NSRect(x: 10, y: 40, width: 100, height: 50))
        w.close()
    }

    func testStringMetricsAndBoundingRect() {
        let s = "Hello" as NSString
        let size = s.size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
        let wrapped = ("one two three four five six" as NSString).boundingRect(with: NSSize(width: 40, height: 1000), options: .usesLineFragmentOrigin,
                                                                                attributes: [.font: NSFont.systemFont(ofSize: 10)])
        XCTAssertGreaterThan(wrapped.height, size.height)
    }

    // MARK: Events

    func testMouseEventsGoToTheHitViewAndDragsFollowIt() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let v = RecordingView(frame: NSRect(x: 50, y: 20, width: 100, height: 50))
        w.contentView!.addSubview(v)
        w.makeKeyAndOrderFront(nil)
        let n = w.nativeWindow!
        func mouse(_ kind: RawEvent.Kind, _ x: CGFloat, _ y: CGFloat, t: TimeInterval = 0) {
            var e = RawEvent(kind: kind); e.location = CGPoint(x: x, y: y); e.timestamp = t
            backend.send(e, to: n)
        }
        // (60, 70) top-down = (60, 30) in the window = (10, 10) in v.
        mouse(.mouseDown, 60, 70); mouse(.mouseMoved, 300, 300); mouse(.mouseUp, 300, 300)
        XCTAssertEqual(v.events, ["down1", "drag", "up"])
        XCTAssertEqual(v.lastLocation, NSPoint(x: 10, y: 10))
        XCTAssertTrue(w.firstResponder === v, "clicking a view that accepts first responder focuses it")
        mouse(.mouseDown, 60, 70, t: 0.1); mouse(.mouseUp, 60, 70, t: 0.15)
        XCTAssertEqual(v.events.suffix(2), ["down2", "up"], "a quick second click counts 2")
        var s = RawEvent(kind: .scroll); s.location = CGPoint(x: 60, y: 70); s.scrollDelta = CGSize(width: 0, height: -1)
        backend.send(s, to: n)
        XCTAssertEqual(v.events.last, "scroll:-10.0")
        w.close()
    }

    func testTrackingAreasEnterExitAndMove() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let v = RecordingView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        w.contentView!.addSubview(v)
        v.addTrackingArea(NSTrackingArea(rect: NSRect(x: 0, y: 0, width: 50, height: 50), options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: v, userInfo: nil))
        w.makeKeyAndOrderFront(nil)
        let n = w.nativeWindow!
        func move(_ x: CGFloat, _ y: CGFloat) { var e = RawEvent(kind: .mouseMoved); e.location = CGPoint(x: x, y: y); backend.send(e, to: n) }
        move(150, 50)          // outside
        move(10, 90)           // window (10, 10): inside the area
        move(20, 80)           // still inside: moved
        move(10, 10)           // window (10, 90): outside
        XCTAssertEqual(v.events, ["entered", "moved", "exited"])
        w.close()
    }

    func testKeysGoToFirstResponderAfterKeyEquivalents() {
        let target = ActionTarget()
        let main = NSMenu(title: "")
        let sub = NSMenu(title: "File")
        sub.addItem(withTitle: "Thing", action: Selector("doThing:"), keyEquivalent: "t").target = target
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = sub
        NSApp.mainMenu = main
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let v = RecordingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        w.contentView!.addSubview(v)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        let n = w.nativeWindow!
        var e = RawEvent(kind: .keyDown); e.keyName = "t"; e.characters = "t"; e.charactersIgnoringModifiers = "t"
        XCTAssertTrue(backend.send(e, to: n))
        XCTAssertEqual(v.events, ["key:t/17"])
        e.modifiers = .control   // Ctrl is ⌘ here
        XCTAssertTrue(backend.send(e, to: n))
        XCTAssertEqual(target.performed, ["doThing:"])
        XCTAssertEqual(v.events.count, 1)
        var esc = RawEvent(kind: .keyDown); esc.keyName = "Escape"
        _ = backend.send(esc, to: n)
        XCTAssertEqual(v.events.last, "key:\u{1b}/53", "Escape keeps its Mac key code and character")
        NSApp.mainMenu = nil
        w.close()
    }

    func testDropsReachRegisteredViews() {
        final class Drop: NSView {
            var got: [URL] = []
            override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
            override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
                got = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
                return true
            }
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let d = Drop(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        d.registerForDraggedTypes([.fileURL])
        w.contentView!.addSubview(d)
        w.makeKeyAndOrderFront(nil)
        let handler = backend.viewSystem.dropHandlers[ObjectIdentifier(w.nativeWindow!)]!
        let url = URL(fileURLWithPath: "/tmp/a.txt")
        XCTAssertEqual(handler(RawDragEvent(kind: .entered, location: CGPoint(x: 10, y: 10), fileURLs: [url])), .copy)
        XCTAssertEqual(handler(RawDragEvent(kind: .entered, location: CGPoint(x: 150, y: 10), fileURLs: [url])), [])
        _ = handler(RawDragEvent(kind: .perform, location: CGPoint(x: 10, y: 10), fileURLs: [url]))
        XCTAssertEqual(d.got, [url])
        w.close()
    }

    // MARK: Windows and controllers

    func testWindowControllerLifecycleAndFrames() {
        final class WC: NSWindowController {
            var loaded = 0
            override func loadWindow() {
                window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            }
            override func windowDidLoad() { loaded += 1 }
        }
        final class VC: NSViewController {
            var calls: [String] = []
            override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 150)) }
            override func viewDidLoad() { calls.append("load") }
            override func viewWillAppear() { calls.append("willAppear") }
            override func viewDidAppear() { calls.append("didAppear") }
            override func viewWillDisappear() { calls.append("willDisappear") }
        }
        let wc = WC()
        XCTAssertFalse(wc.isWindowLoaded)
        let vc = VC()
        wc.contentViewController = vc
        XCTAssertEqual(wc.loaded, 1)
        XCTAssertTrue(wc.window?.windowController === wc)
        XCTAssertEqual(wc.window?.contentLayoutRect.size, NSSize(width: 300, height: 150))
        XCTAssertEqual(wc.window?.frame.height, 178, "titled frames include the title bar")
        wc.showWindow(nil)
        XCTAssertEqual(vc.calls, ["load", "willAppear", "didAppear"])
        XCTAssertTrue(NSApp.keyWindow === wc.window)
        wc.window?.frameAutosaveName.isEmpty == true ? () : XCTFail()
        let name = "RunwayTest-\(UUID().uuidString)"
        wc.window!.setFrame(NSRect(x: 40, y: 50, width: 500, height: 400), display: true)
        wc.window!.setFrameAutosaveName(name)
        let w2 = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        w2.setFrameAutosaveName(name)
        XCTAssertEqual(w2.frame, NSRect(x: 40, y: 50, width: 500, height: 400))
        NSWindow.removeFrame(usingName: name)
        wc.close()
        XCTAssertEqual(vc.calls.last, "willDisappear")
    }

    func testAppearanceInheritanceAndDynamicColors() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let child = NSView(frame: .zero)
        root.addSubview(child)
        root.appearance = NSAppearance(named: .darkAqua)
        XCTAssertTrue(child.effectiveAppearance.isDark)
        final class ColorView: NSView {
            override func draw(_ r: NSRect) { NSColor.textColor.setFill(); r.fill() }
        }
        let cv = ColorView(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        root.addSubview(cv)
        guard case let .fill(_, _, c, _)? = cv.recordDrawing().ops.first else { return XCTFail() }
        XCTAssertEqual(c, [1, 1, 1, 1], "dynamic colours resolve with the view's appearance while drawing")
    }

    func testScreensFromTheBackend() {
        let s = NSScreen.main!
        XCTAssertEqual(s.frame, NSRect(x: 0, y: 0, width: 1440, height: 900))
        XCTAssertEqual(s.visibleFrame, NSRect(x: 0, y: 0, width: 1440, height: 868), "flipped to AppKit's y-up space")
        XCTAssertEqual(s.backingScaleFactor, 2)
    }

    func testKVOOnViewFrame() {
        let v = NSView(frame: .zero)
        var seen: [NSRect] = []
        let token = v.observe(\.frame, options: [.new]) { _, change in if let n = change.newValue { seen.append(n) } }
        v.frame = NSRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(seen, [NSRect(x: 1, y: 2, width: 3, height: 4)])
        token.invalidate()
    }

    func testUndoManager() {
        let u = UndoManager()
        u.groupsByEvent = false
        var value = 0
        final class Box { var v = 0 }
        let box = Box()
        func set(_ n: Int) {
            let old = box.v
            u.registerUndo(withTarget: box) { b in b.v = old }
            box.v = n
        }
        u.beginUndoGrouping(); set(1); u.setActionName("One"); u.endUndoGrouping()
        u.beginUndoGrouping(); set(2); u.endUndoGrouping()
        XCTAssertTrue(u.canUndo)
        u.undo()
        XCTAssertEqual(box.v, 1)
        u.undo()
        XCTAssertEqual(box.v, 0)
        XCTAssertFalse(u.canUndo)
        _ = value
        value = 1
    }

    // MARK: The bitmap rasterizer

    func testBitmapContextFillsPathsAndStrokes() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 10, height: 10))   // bottom-left quadrant
        ctx.setStrokeColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.setLineWidth(2)
        ctx.strokeLineSegments(between: [CGPoint(x: 10, y: 15), CGPoint(x: 20, y: 15)])
        let img = try XCTUnwrap(ctx.makeImage())
        func px(_ x: Int, _ y: Int) -> [UInt8] { let i = (y * 20 + x) * 4; return Array(img.pixels[i..<i + 4]) }
        XCTAssertEqual(px(5, 14), [255, 0, 0, 255], "centre of the ellipse (rows are top-down)")
        XCTAssertEqual(px(1, 1)[3], 0, "outside")
        XCTAssertEqual(px(15, 4), [0, 0, 255, 255], "the stroke at y = 15 (row 4 from the top)")
        XCTAssertEqual(px(15, 8)[3], 0)
    }

    func testCGPathGeometry() {
        let p = CGMutablePath()
        p.addRoundedRect(in: CGRect(x: 0, y: 0, width: 100, height: 50), cornerWidth: 10, cornerHeight: 10)
        XCTAssertEqual(p.boundingBoxOfPath.width, 100, accuracy: 0.5)
        XCTAssertTrue(p.contains(CGPoint(x: 50, y: 25)))
        XCTAssertFalse(p.contains(CGPoint(x: 1, y: 1)), "the rounded corner is outside")
        let star = CGMutablePath()
        star.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 10)])
        let arc = CGMutablePath()
        arc.addArc(center: .zero, radius: 10, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        XCTAssertEqual(arc.currentPoint.x, 0, accuracy: 1e-6)
        XCTAssertEqual(arc.currentPoint.y, 10, accuracy: 1e-6)
    }
}
