// The incremental graph: only invalidated scopes run their bodies, equal
// inputs are reused, splices keep the rest of the tree, resizes only lay
// out, and nothing is lost or leaked along the way.

import XCTest
import RunwayCore
@testable import SwiftUI

/// Counts body evaluations per view, by name.
@MainActor final class BodyLog {
    static var counts: [String: Int] = [:]
    static func hit(_ name: String) { counts[name, default: 0] += 1 }
    static func reset() { counts = [:] }
}

@MainActor
final class IncrementalTests: XCTestCase {
    var backend: HeadlessBackend!
    var hosts: [ViewHost] = []

    override func setUp() async throws {
        backend = HeadlessBackend()
        Runway.install(backend)
        BodyLog.reset()
    }

    func render<V: View>(_ view: V, size: CGSize = CGSize(width: 400, height: 600)) -> (ViewHost, HeadlessWidget) {
        let host = ViewHost(view, backend: backend)
        host.setSize(size)
        host.render()
        hosts.append(host)
        return (host, host.container as! HeadlessWidget)
    }

    func texts(_ root: HeadlessWidget) -> [String] { root.all.filter { $0.kind == .text }.compactMap { $0.props.text?.plain } }
    func button(_ root: HeadlessWidget, _ title: String) -> HeadlessWidget { root.all.first { $0.kind == .button && $0.props.title == title }! }

    // MARK: Fixtures

    struct Leaf: View {
        let label: String
        var body: some View {
            BodyLog.hit("leaf " + label)
            return Text(label)
        }
    }

    struct LocalCounter: View {
        let name: String
        @State var count = 0
        var body: some View {
            BodyLog.hit("counter " + name)
            return HStack {
                Text("\(name) \(count)")
                Button("+\(name)") { count += 1 }
            }
        }
    }

    struct Parent: View {
        @State var title = "T"
        var body: some View {
            BodyLog.hit("parent")
            return VStack {
                Text(title)
                Button("Retitle") { title += "!" }
                LocalCounter(name: "a")
                LocalCounter(name: "b")
                Leaf(label: "x")
            }
        }
    }

    // MARK: Tests

    func testLocalStateRunsOnlyItsOwnBody() {
        let (host, root) = render(Parent())
        XCTAssertEqual(BodyLog.counts["parent"], 1)
        XCTAssertEqual(BodyLog.counts["counter a"], 1)
        BodyLog.reset()

        button(root, "+a").events.onTap?()
        backend.drain()
        XCTAssertTrue(texts(root).contains("a 1"))
        XCTAssertTrue(texts(root).contains("b 0"))
        // Only the counter whose state changed ran, spliced in place.
        XCTAssertEqual(BodyLog.counts, ["counter a": 1])
        XCTAssertEqual(host.splices, 1)
    }

    func testParentChangeReusesChildrenWithEqualInput() {
        let (_, root) = render(Parent())
        button(root, "+b").events.onTap?()
        backend.drain()
        BodyLog.reset()

        button(root, "Retitle").events.onTap?()
        backend.drain()
        XCTAssertTrue(texts(root).contains("T!"))
        // The parent ran; children with unchanged input were reused, and
        // their state survived.
        XCTAssertEqual(BodyLog.counts, ["parent": 1])
        XCTAssertTrue(texts(root).contains("b 1"))
    }

    struct Labelled: View {
        @State var suffix = ""
        var body: some View {
            BodyLog.hit("labelled")
            return VStack {
                Leaf(label: "item" + suffix)
                Leaf(label: "fixed")
                Button("Change") { suffix = "!" }
            }
        }
    }

    func testChildWithChangedInputRunsAgain() {
        let (_, root) = render(Labelled())
        BodyLog.reset()
        button(root, "Change").events.onTap?()
        backend.drain()
        XCTAssertEqual(BodyLog.counts["leaf item!"], 1)
        XCTAssertNil(BodyLog.counts["leaf fixed"])
        XCTAssertTrue(texts(root).contains("item!"))
    }

    @Observable final class Model {
        var a = 1
        var b = 1
    }

    struct ReadsA: View {
        let model: Model
        var body: some View {
            BodyLog.hit("reads a")
            return Text("a=\(model.a)")
        }
    }

    struct ReadsB: View {
        let model: Model
        var body: some View {
            BodyLog.hit("reads b")
            return Text("b=\(model.b)")
        }
    }

    struct Both: View {
        let model: Model
        var body: some View {
            BodyLog.hit("both")
            return VStack { ReadsA(model: model); ReadsB(model: model) }
        }
    }

    func testObservationRunsReadersNotSiblings() {
        let model = Model()
        let (_, root) = render(Both(model: model))
        BodyLog.reset()
        model.a = 2
        backend.drain()
        XCTAssertTrue(texts(root).contains("a=2"))
        XCTAssertEqual(BodyLog.counts["reads a"], 1)
        XCTAssertNil(BodyLog.counts["reads b"], "a sibling that didn't read the change is reused")
    }

    func testResizeOnlyLaysOut() {
        let (host, root) = render(Parent())
        BodyLog.reset()
        let before = host.fullResolves
        host.setSize(CGSize(width: 200, height: 300))
        backend.drain()
        XCTAssertEqual(BodyLog.counts, [:])
        XCTAssertEqual(host.fullResolves, before)
        XCTAssertEqual(host.splices, 0)
        // Laid out again in the new size: the stack is re-centred.
        let x = { root.all.first { $0.kind == .text && $0.props.text?.plain == "x" }!.windowFrame.midX }
        XCTAssertEqual(x(), 100, accuracy: 1)
    }

    struct Growing: View {
        @State var lines = 1
        var body: some View {
            VStack(spacing: 0) {
                ForEach(0..<lines, id: \.self) { i in Color.red.frame(width: 20, height: 10) }
                Button("Grow") { lines += 1 }
            }
        }
    }

    struct Holder: View {
        var body: some View {
            VStack(spacing: 0) {
                Growing()
                Color.blue.frame(width: 30, height: 10)
            }
        }
    }

    func testSplicedScopeRelaysOutItsAncestors() {
        let (host, root) = render(Holder())
        let blueY = { root.all.filter { $0.kind == .canvas }.last!.windowFrame.minY }
        let y0 = blueY()
        button(root, "Grow").events.onTap?()
        backend.drain()
        XCTAssertEqual(host.splices, 1)
        // The parent didn't run, but its layout saw the child grow.
        XCTAssertEqual(blueY() - y0, 5, accuracy: 0.5)   // re-centred: 10 taller, half above
        XCTAssertEqual(root.all.filter { $0.kind == .canvas }.count, 3)
    }

    struct Toggler: View {
        @State var on = true
        var body: some View {
            VStack {
                if on { LocalCounter(name: "c") }
                Button("Flip") { on.toggle() }
            }
        }
    }

    func testShapeChangeFallsBackAndReleasesState() {
        let (_, root) = render(Toggler())
        button(root, "+c").events.onTap?()
        backend.drain()
        XCTAssertTrue(texts(root).contains("c 1"))
        button(root, "Flip").events.onTap?(); backend.drain()
        XCTAssertFalse(texts(root).contains { $0.hasPrefix("c ") })
        button(root, "Flip").events.onTap?(); backend.drain()
        XCTAssertTrue(texts(root).contains("c 0"), "state was released when the view left")
    }

    struct WithShortcut: View {
        @State var n = 0
        var body: some View {
            Button("Go \(n)") { n += 1 }.keyboardShortcut(.defaultAction)
        }
    }

    func testWindowActionsSurviveRerenders() {
        let (host, root) = render(VStack { WithShortcut(); LocalCounter(name: "d") })
        XCTAssertTrue(host.handleKey(KeyPress(key: "return")))
        backend.drain()
        XCTAssertNotNil(root.all.first { $0.props.title == "Go 1" })
        // A splice elsewhere keeps the default action.
        button(root, "+d").events.onTap?(); backend.drain()
        XCTAssertTrue(host.handleKey(KeyPress(key: "return")))
        backend.drain()
        XCTAssertNotNil(root.all.first { $0.props.title == "Go 2" })
    }

    struct Stored: View {
        @AppStorage("runway.test.flag") var flag = false
        let name: String
        var body: some View {
            Toggle(name, isOn: $flag)
        }
    }

    func testAppStorageUpdatesEveryReader() {
        UserDefaults.standard.removeObject(forKey: "runway.test.flag")
        let (_, root) = render(VStack { Stored(name: "one"); Stored(name: "two") })
        let toggles = { root.all.filter { if case .toggle = $0.kind { return true }; return false } }
        toggles()[0].events.onToggle?(true)
        backend.drain()
        XCTAssertEqual(toggles().map(\.props.isOn), [true, true])
        UserDefaults.standard.removeObject(forKey: "runway.test.flag")
    }

    func testUnchangedContainersAreNotRecommitted() {
        let counting = backend!
        let (_, root) = render(VStack {
            ScrollView { VStack { ForEach(0..<20, id: \.self) { Leaf(label: "row \($0)") } } }
            LocalCounter(name: "e")
        })
        let calls = counting.setChildrenCalls
        button(root, "+e").events.onTap?()
        counting.drain()
        // Only the root container (the counter's text changed width) is
        // re-sent; the scroll view's rows are untouched.
        XCTAssertLessThanOrEqual(counting.setChildrenCalls - calls, 1)
        XCTAssertTrue(texts(root).contains("e 1"))
    }

    func testModelChangeAfterHostIsGoneIsHarmless() {
        let model = Model()
        do {
            let host = ViewHost(Both(model: model), backend: backend)
            host.setSize(CGSize(width: 200, height: 200))
            host.render()
            host.tearDown()
        }
        // Its Observation callbacks are still registered with the model.
        model.a = 5
        model.b = 6
        backend.drain()
        let (_, root) = render(Both(model: model))
        XCTAssertTrue(texts(root).contains("a=5"))
    }

    func testFieldLayoutComparison() {
        struct A: Equatable { var x: Int }
        struct V { var a: A; var s: String; var c: () -> Void; @State var st = 0 }
        let f: () -> Void = {}
        let v1 = V(a: A(x: 1), s: "hello, a fairly long string", c: f)
        var v2 = V(a: A(x: 1), s: "hello, a fairly long string", c: f, st: 5)   // state isn't input
        XCTAssertTrue(FieldLayout.equal(v1, v2))
        v2.s = "hello, a fairly long string".uppercased().lowercased()   // equal, different buffer
        XCTAssertTrue(FieldLayout.equal(v1, v2))
        v2.a.x = 2
        XCTAssertFalse(FieldLayout.equal(v1, v2))
        var v3 = v1
        v3.c = {}
        XCTAssertFalse(FieldLayout.equal(v1, v3), "a new closure is a new input")
    }
}
