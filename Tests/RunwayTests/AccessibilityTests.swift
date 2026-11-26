// SwiftUI's accessibility modifiers and the accessibility tree backends
// that draw their own controls expose.

import XCTest
import RunwayCore
@testable import SwiftUI

@MainActor
final class AccessibilityTests: XCTestCase {
    var backend: HeadlessBackend!
    var hosts: [ViewHost] = []

    override func setUp() async throws {
        backend = HeadlessBackend()
        Runway.install(backend)
    }

    func tree<V: View>(_ view: V) -> AccessibleElement {
        let host = ViewHost(view, backend: backend)
        host.setSize(CGSize(width: 400, height: 300))
        host.render()
        hosts.append(host)
        return AccessibilityTree.build(host.container as! HeadlessWidget, title: "Window", frame: .zero)
    }

    func testControlsAreElementsAndLayoutIsTransparent() {
        var tapped = 0
        let t = tree(VStack {
            Text("Title")
            HStack { Button("Save") { tapped += 1 }; Toggle("Wrap", isOn: .constant(true)) }
        })
        XCTAssertEqual(t.children.map(\.role), [.staticText, .button, .checkBox])
        XCTAssertEqual(t.children.map(\.name), ["Title", "Save", "Wrap"])
        XCTAssertTrue(t.children[2].states.contains(.checked))
        XCTAssertTrue(t.children[1].perform())
        XCTAssertEqual(tapped, 1)
    }

    func testChainedModifiersMergeIntoOneElement() {
        let t = tree(Button("+") {}.accessibilityLabel("Add comment").accessibilityHint("Opens the composer").accessibilityIdentifier("add"))
        XCTAssertEqual(t.children.count, 1)
        let e = t.children[0]
        XCTAssertEqual(e.role, .button)
        XCTAssertEqual(e.name, "Add comment")
        XCTAssertEqual(e.hint, "Opens the composer")
        XCTAssertEqual(e.identifier, "add")
        // One wrapper widget, not one per modifier.
        let root = hosts[0].container as! HeadlessWidget
        XCTAssertEqual(root.all.filter { $0.props.accessibility != nil }.count, 1)
    }

    func testHiddenAndCombinedAndHeader() {
        let t = tree(VStack {
            Image(systemName: "star").accessibilityHidden(true)
            HStack { Text("Unit tests"); Text("Passed") }.accessibilityElement(children: .combine)
            Text("Checks").accessibilityAddTraits(.isHeader)
            HStack { Text("a"); Text("b") }.accessibilityElement(children: .ignore).accessibilityLabel("Summary").accessibilityValue("2 of 5")
        })
        XCTAssertEqual(t.children.map(\.role), [.staticText, .heading, .staticText])
        XCTAssertEqual(t.children[0].name, "Unit tests, Passed")
        XCTAssertEqual(t.children[1].name, "Checks")
        XCTAssertEqual(t.children[2].name, "Summary")
        XCTAssertEqual(t.children[2].value, "2 of 5")
        XCTAssertTrue(t.children[2].children.isEmpty)
    }

    func testTappableViewsAndCustomActions() {
        var log: [String] = []
        let t = tree(VStack {
            Image(systemName: "plus").onTapGesture { log.append("tap") }.accessibilityLabel("Add").accessibilityAddTraits(.isButton)
            Text("Rating").accessibilityAdjustableAction { log.append($0 == .increment ? "up" : "down") }
        })
        XCTAssertEqual(t.children.map(\.role), [.button, .staticText])
        XCTAssertEqual(t.children[0].name, "Add")
        t.children[0].perform()
        t.children[1].perform("increment")
        t.children[1].perform("decrement")
        XCTAssertEqual(log, ["tap", "up", "down"])
    }

    func testTextFieldValueCanBeSet() {
        final class Box { var text = "hi" }
        let box = Box()
        let t = tree(TextField("Search", text: Binding(get: { box.text }, set: { box.text = $0 })))
        let e = t.children[0]
        XCTAssertEqual(e.role, .textField)
        XCTAssertEqual(e.name, "Search")
        XCTAssertEqual(e.value, "hi")
        e.setValue?("hello")
        XCTAssertEqual(box.text, "hello")
    }
}

@MainActor
final class DragDropTests: XCTestCase {
    func testDropDestinationReceivesDroppedFiles() {
        let backend = HeadlessBackend()
        Runway.install(backend)
        var got: [URL] = []
        var targeted: [Bool] = []
        let host = ViewHost(Text("Drop here").dropDestination(for: URL.self) { urls, _ in got = urls; return true } isTargeted: { targeted.append($0) },
                            backend: backend)
        host.setSize(CGSize(width: 200, height: 100))
        host.render()
        let zone = (host.container as! HeadlessWidget).all.first { $0.events.onDrop != nil }
        XCTAssertNotNil(zone)
        let file = URL(fileURLWithPath: "/tmp/notes.txt")
        XCTAssertEqual(zone?.events.onDrop?(RawDragEvent(kind: .entered, location: .zero, fileURLs: [file])), .copy)
        XCTAssertEqual(zone?.events.onDrop?(RawDragEvent(kind: .perform, location: .zero, fileURLs: [file])), .copy)
        XCTAssertEqual(got, [file])
        XCTAssertEqual(targeted, [true, false])
    }
}
