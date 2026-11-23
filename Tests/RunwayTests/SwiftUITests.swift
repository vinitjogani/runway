// The SwiftUI layer on the headless backend: layout follows SwiftUI's
// rules, state and Observation re-render, controls report back, effects run.

import XCTest
import RunwayCore
@testable import SwiftUI

@MainActor
final class SwiftUITests: XCTestCase {
    var backend: HeadlessBackend!
    /// Hosts live as long as the test (windows own them in an app).
    var hosts: [ViewHost] = []

    override func setUp() async throws {
        backend = HeadlessBackend()
        Runway.install(backend)
    }

    /// Renders `view` in a container of `size` and returns its widgets.
    func render<V: View>(_ view: V, size: CGSize = CGSize(width: 400, height: 300)) -> (ViewHost, HeadlessWidget) {
        let host = ViewHost(view, backend: backend)
        host.setSize(size)
        host.render()
        hosts.append(host)
        return (host, host.container as! HeadlessWidget)
    }

    func widgets(_ root: HeadlessWidget, _ kind: WidgetKind) -> [HeadlessWidget] { root.all.filter { $0.kind == kind } }
    func text(_ root: HeadlessWidget, _ s: String) -> HeadlessWidget? { root.all.first { $0.kind == .text && $0.props.text?.plain == s } }

    // MARK: Layout

    func testVStackCentersAndSpaces() {
        let (_, root) = render(VStack(spacing: 10) {
            Color.red.frame(width: 100, height: 20)
            Color.blue.frame(width: 50, height: 30)
        })
        let shapes = widgets(root, .canvas)
        XCTAssertEqual(shapes.count, 2)
        // 60 high in a 300 container: centred at y = 120.
        XCTAssertEqual(shapes[0].frame, CGRect(x: 150, y: 120, width: 100, height: 20))
        XCTAssertEqual(shapes[1].frame, CGRect(x: 175, y: 150, width: 50, height: 30))
    }

    func testHStackSpacerPushesApart() {
        let (_, root) = render(HStack {
            Color.red.frame(width: 40, height: 10)
            Spacer()
            Color.blue.frame(width: 40, height: 10)
        }.frame(width: 300))
        let s = widgets(root, .canvas)
        XCTAssertEqual(s[0].frame.minX, 50)
        XCTAssertEqual(s[1].frame.maxX, 350)
    }

    func testFlexibleChildrenShareSpaceLeastFlexibleFirst() {
        // A fixed 100 and two greedy colours in 400: the greedy split the rest.
        let (_, root) = render(HStack(spacing: 0) {
            Color.red.frame(width: 100)
            Color.green
            Color.blue
        })
        let s = widgets(root, .canvas)
        XCTAssertEqual(s.map(\.frame.width), [100, 150, 150])
    }

    func testLayoutPriorityWins() {
        let (_, root) = render(HStack(spacing: 0) {
            Color.red
            Color.blue.layoutPriority(1)
        }.frame(width: 200, height: 10))
        let s = widgets(root, .canvas)
        XCTAssertEqual(s[1].frame.width, 200)
        XCTAssertEqual(s[0].frame.width, 0)
    }

    func testPaddingAndMaxWidthFrame() {
        let (_, root) = render(Color.red.frame(height: 10).frame(maxWidth: .infinity).padding(20))
        XCTAssertEqual(widgets(root, .canvas)[0].frame, CGRect(x: 20, y: 145, width: 360, height: 10))
    }

    func testFrameAlignment() {
        let (_, root) = render(Color.red.frame(width: 10, height: 10).frame(width: 100, height: 100, alignment: .bottomTrailing))
        XCTAssertEqual(widgets(root, .canvas)[0].frame, CGRect(x: 240, y: 190, width: 10, height: 10))
    }

    func testTextWrapsToProposedWidth() {
        let (_, root) = render(Text(String(repeating: "word ", count: 40)).frame(width: 120))
        let t = widgets(root, .text)[0]
        XCTAssertEqual(t.frame.width, 120)
        XCTAssertGreaterThan(t.frame.height, HeadlessBackend.lineHeight(13) * 3)
    }

    func testFixedSizeUsesIdealSize() {
        let (_, root) = render(Text("A long line of text here").fixedSize().frame(width: 40))
        XCTAssertGreaterThan(widgets(root, .text)[0].frame.width, 40)
    }

    func testOverlayAndBackgroundTakePrimarySize() {
        let (_, root) = render(Color.red.frame(width: 50, height: 20).background(Color.blue).overlay(Color.green))
        let s = widgets(root, .canvas)
        XCTAssertEqual(s.count, 3)
        XCTAssertTrue(s.allSatisfy { $0.frame.size == CGSize(width: 50, height: 20) })
        // Drawing order: background, content, overlay.
        if case let .fill(_, .color(c))? = s[0].props.drawing.first { XCTAssertEqual(c, Color.blue.resolve(EnvironmentValues())) } else { XCTFail() }
    }

    func testZStackAlignment() {
        let (_, root) = render(ZStack(alignment: .topLeading) {
            Color.red.frame(width: 100, height: 100)
            Color.blue.frame(width: 10, height: 10)
        })
        let s = widgets(root, .canvas)
        XCTAssertEqual(s[1].frame.origin, s[0].frame.origin)
    }

    func testDividerSpansStackCrossAxis() {
        // As in SwiftUI, a divider takes the width the stack is offered.
        let (_, root) = render(VStack { Color.red.frame(width: 80, height: 10); Divider() })
        XCTAssertEqual(widgets(root, .divider)[0].frame.size, CGSize(width: 400, height: 1))
        let (_, fixed) = render(VStack { Color.red.frame(width: 80, height: 10); Divider() }.fixedSize())
        XCTAssertEqual(widgets(fixed, .divider)[0].frame.width, 80)
    }

    func testScrollViewIsGreedyAndHoldsContent() {
        let (_, root) = render(ScrollView { VStack { ForEach(0..<50) { Text("Row \($0)") } } })
        let scroll = root.all.first { if case .scroll = $0.kind { return true }; return false }!
        XCTAssertEqual(scroll.frame.size, CGSize(width: 400, height: 300))
        XCTAssertGreaterThan(scroll.children[0].contentSize.height, 300)
    }

    func testGridAdaptiveColumns() {
        let (_, root) = render(LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 10) {
            ForEach(0..<8) { _ in Color.red.frame(height: 20) }
        }.frame(width: 400))
        let s = widgets(root, .canvas)
        XCTAssertEqual(Set(s.map(\.frame.minY)).count, 2)   // 4 per row
    }

    // MARK: State and controls

    struct CounterView: View {
        @State var count = 0
        var body: some View {
            VStack {
                Text("Count \(count)")
                Button("Add") { count += 1 }
            }
        }
    }

    func testStatePersistsAndRerenders() {
        let (host, root) = render(CounterView())
        let button = widgets(root, .button)[0]
        XCTAssertEqual(button.props.title, "Add")
        button.events.onTap?()
        button.events.onTap?()
        backend.drain()
        XCTAssertNotNil(text(root, "Count 2"))
        XCTAssertGreaterThanOrEqual(host.renderCount, 2)
        // The same native widget is reused.
        XCTAssertTrue(widgets(root, .button)[0] === button)
    }

    @Observable final class Model {
        var name = "One"
        var on = false
        var choice = 2
    }

    struct ModelView: View {
        @Bindable var model: Model
        var body: some View {
            Form {
                Section("S") {
                    TextField("Name", text: $model.name)
                    Toggle("On", isOn: $model.on)
                    Picker("Choice", selection: $model.choice) {
                        Text("One").tag(1)
                        Text("Two").tag(2)
                        Text("Three").tag(3)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    func testObservationAndBindings() {
        let model = Model()
        let (_, root) = render(ModelView(model: model))
        let field = widgets(root, .textField(secure: false))[0]
        XCTAssertEqual(field.props.string, "One")
        field.events.onText?("Two")
        XCTAssertEqual(model.name, "Two")

        let toggle = widgets(root, .toggle(.switch))[0]
        toggle.events.onToggle?(true)
        XCTAssertTrue(model.on)

        let seg = widgets(root, .segmented)[0]
        XCTAssertEqual(seg.props.options, ["One", "Two", "Three"])
        XCTAssertEqual(seg.props.selected, 1)
        seg.events.onSelect?(2)
        XCTAssertEqual(model.choice, 3)

        // Changing the model elsewhere re-renders (Observation tracking).
        model.name = "Changed"
        backend.drain()
        XCTAssertEqual(widgets(root, .textField(secure: false))[0].props.string, "Changed")
        XCTAssertEqual(widgets(root, .segmented)[0].props.selected, 2)
    }

    func testFormRowsPutLabelsLeadingAndControlsTrailing() {
        let (_, root) = render(ModelView(model: Model()), size: CGSize(width: 400, height: 400))
        let label = text(root, "On")!.windowFrame
        let toggle = widgets(root, .toggle(.switch))[0].windowFrame
        XCTAssertLessThan(label.maxX, toggle.minX)
        XCTAssertEqual(toggle.maxX, 400 - 20 - 10, accuracy: 1)   // form and row insets
    }

    struct OptionalPicker: View {
        @State var mic: String? = nil
        var body: some View {
            Picker("Mic", selection: $mic) {
                Text("None").tag(String?.none)
                ForEach(["a", "b"], id: \.self) { Text($0.uppercased()).tag(Optional($0)) }
            }
        }
    }

    func testPickerWithOptionalTags() {
        let (_, root) = render(OptionalPicker())
        let dd = widgets(root, .dropdown)[0]
        XCTAssertEqual(dd.props.options, ["None", "A", "B"])
        XCTAssertEqual(dd.props.selected, 0)
        dd.events.onSelect?(2)
        backend.drain()
        XCTAssertEqual(widgets(root, .dropdown)[0].props.selected, 2)
    }

    struct Effects: View {
        @State var value = 0
        let log: (String) -> Void
        var body: some View {
            Button("Bump") { value += 1 }
                .onAppear { log("appear") }
                .onChange(of: value) { old, new in log("change \(old)->\(new)") }
        }
    }

    func testLifecycleEffects() {
        var events: [String] = []
        let (_, root) = render(Effects { events.append($0) })
        XCTAssertEqual(events, ["appear"])
        widgets(root, .button)[0].events.onTap?()
        backend.drain()
        XCTAssertEqual(events, ["appear", "change 0->1"])
    }

    struct Conditional: View {
        @State var show = true
        var body: some View {
            VStack {
                if show { CounterView() }
                Button("Toggle") { show.toggle() }
            }
        }
    }

    func testStateResetsWhenViewLeaves() {
        let (_, root) = render(Conditional())
        widgets(root, .button).first { $0.props.title == "Add" }!.events.onTap?()
        backend.drain()
        XCTAssertNotNil(text(root, "Count 1"))
        let toggle = { self.widgets(root, .button).first { $0.props.title == "Toggle" }! }
        toggle().events.onTap?(); backend.drain()
        XCTAssertNil(text(root, "Count 1"))
        toggle().events.onTap?(); backend.drain()
        XCTAssertNotNil(text(root, "Count 0"))
    }

    func testKeyboardShortcuts() {
        var done = 0, cancelled = 0, saved = 0
        let (host, _) = render(HStack {
            Button("Cancel") { cancelled += 1 }.keyboardShortcut(.cancelAction)
            Button("OK") { done += 1 }.keyboardShortcut(.defaultAction)
            Button("Save") { saved += 1 }.keyboardShortcut("s")
        })
        XCTAssertTrue(host.handleKey(KeyPress(key: "return")))
        XCTAssertTrue(host.handleKey(KeyPress(key: "escape")))
        XCTAssertTrue(host.handleKey(KeyPress(key: "s", command: true)))
        XCTAssertFalse(host.handleKey(KeyPress(key: "x", command: true)))
        XCTAssertEqual([done, cancelled, saved], [1, 1, 1])
    }

    func testDisabledAndHelpPropagate() {
        let (_, root) = render(VStack { Button("A") {}; Toggle("B", isOn: .constant(true)) }.disabled(true).help("Tip"))
        for w in root.all where w.kind == .button || w.kind == .toggle(.checkbox) {
            XCTAssertFalse(w.props.enabled)
            XCTAssertEqual(w.props.tooltip, "Tip")
        }
    }

    func testMenuCollectsItems() {
        var picked = ""
        let (_, root) = render(Menu("More") {
            Button("First") { picked = "first" }
            Divider()
            Button("Second") { picked = "second" }
        })
        let m = widgets(root, .menuButton)[0]
        XCTAssertEqual(m.events.menu.map(\.title), ["First", "", "Second"])
        XCTAssertTrue(m.events.menu[1].isSeparator)
        m.events.menu[2].action?()
        XCTAssertEqual(picked, "second")
    }

    func testColorsFollowColorScheme() {
        var env = EnvironmentValues()
        env.colorScheme = .dark
        XCTAssertEqual(Color.primary.resolve(env).r, 1)
        env.colorScheme = .light
        XCTAssertEqual(Color.primary.resolve(env).r, 0)
    }

    func testWindowHostSizesToContent() {
        let w = WindowHost(title: "T", view: AnyView(Color.red.frame(width: 120, height: 80)), size: nil, sizedToContent: true)
        XCTAssertEqual(w.window.contentSize, CGSize(width: 120, height: 80))
        XCTAssertEqual(w.window.title, "T")
    }

    func testMobileSceneProfilesSizeWindowsAndSetSizeClasses() {
        let profiles: [(MobilePreviewProfile, CGSize, String)] = [
            (.iphone, CGSize(width: 393, height: 852), "compact × regular"),
            (.ipad, CGSize(width: 820, height: 1180), "regular × regular"),
        ]
        for (profile, size, sizeClasses) in profiles {
            let registry = SceneRegistry(mobileProfile: profile)
            registry.collect(WindowGroup { SizeClassLabel() })
            registry.openInitial()
            guard let window = backend.windows.first else {
                XCTFail("Missing preview window")
                return
            }
            XCTAssertEqual(window.contentSize, size)
            XCTAssertNotNil(text(window.root, sizeClasses))
            window.close()
        }
    }

    func testSheetInheritsEnvironment() {
        _ = render(
            Text("Parent")
                .sheet(isPresented: .constant(true)) { SizeClassLabel() }
                .environment(\.horizontalSizeClass, .compact)
        )
        guard let sheet = backend.windows.first else {
            XCTFail("Missing sheet window")
            return
        }
        XCTAssertNotNil(text(sheet.root, "compact × regular"))
    }

    func testMobilePickerMenusUseDirectActionsAndKeepTheirLabel() {
        let (host, root) = render(MobilePickerControls().environment(\._mobilePreview, true),
                                  size: CGSize(width: 340, height: 220))
        guard let menu = widgets(root, .menuButton).first, let segments = widgets(root, .segmented).first else {
            XCTFail("Missing mobile picker controls")
            return
        }
        XCTAssertNotNil(text(menu, "Selected 1"))
        XCTAssertEqual(menu.events.menu.map(\.title), ["Daily", "Weekly"])
        XCTAssertEqual(menu.events.menu.map(\.checked), [true, false])
        XCTAssertNil(text(root, "Trend interval"))
        XCTAssertEqual(segments.frame.width, 340)
        XCTAssertEqual(segments.frame.height, 32)
        menu.events.menu.last?.action?()
        backend.drain()
        XCTAssertNotNil(text(menu, "Selected 2"))
        XCTAssertEqual(menu.events.menu.map(\.checked), [false, true])
        XCTAssertEqual(segments.props.selected, 1)
        withExtendedLifetime(host) {}
    }

    private struct MobilePickerControls: View {
        @State var selection = 1

        var body: some View {
            VStack {
                Menu {
                    Picker("Show", selection: $selection) { options }
                } label: {
                    HStack {
                        Text("Selected \(selection)")
                        Image(systemName: "chevron.down")
                    }
                }
                Picker("Trend interval", selection: $selection) { options }
                    .pickerStyle(.segmented)
            }
        }

        @ViewBuilder private var options: some View {
            Text("Daily").tag(1)
            Text("Weekly").tag(2)
        }
    }

    private struct SizeClassLabel: View {
        @Environment(\.horizontalSizeClass) private var horizontal
        @Environment(\.verticalSizeClass) private var vertical

        var body: some View {
            Text("\(horizontal == .compact ? "compact" : "regular") × \(vertical == .compact ? "compact" : "regular")")
        }
    }
}

@MainActor
final class AlertTests: XCTestCase {
    struct Host: View {
        @State var shown = true
        var tapped: () -> Void
        var body: some View {
            Text(shown ? "shown" : "hidden")
                .alert("Title", isPresented: $shown) { Button("OK") { tapped() } }
        }
    }

    func testAlertButtonRunsActionThenDismisses() {
        let backend = HeadlessBackend()
        Runway.install(backend)
        var taps = 0
        let host = ViewHost(Host { taps += 1 }, backend: backend)
        host.setSize(CGSize(width: 300, height: 200))
        host.render()
        backend.drain()
        // The alert is a modal window; press its OK button.
        let alert = backend.windows.last!
        let ok = alert.root.all.first { $0.kind == .button && $0.props.title == "OK" }!
        ok.events.onTap?()
        backend.drain()
        XCTAssertEqual(taps, 1)
        XCTAssertTrue((host.container as! HeadlessWidget).all.contains { $0.props.text?.plain == "hidden" })
        withExtendedLifetime(host) {}
    }
}
