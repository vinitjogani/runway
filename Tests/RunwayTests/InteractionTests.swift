// Focus, key presses, hover, context menus, tables, scrolling to views,
// attributed text and custom label styles, on the headless backend.

import XCTest
import RunwayCore
@testable import SwiftUI

@MainActor @Observable private final class SheetModel { var open = false }
@MainActor @Observable private final class ChatModel { var entries: [String] = ["Hello"] }

@MainActor @Observable private final class LiveText { var text = "Hi" }

private struct ChatReply: View, Equatable {
    let text: String
    var live: LiveText? = nil
    var body: some View { Text(live?.text ?? text).frame(maxWidth: .infinity, alignment: .leading) }
    static func == (a: Self, b: Self) -> Bool { a.text == b.text && a.live === b.live }
}

private struct Chat: View {
    let model: ChatModel
    var body: some View {
        GeometryReader { _ in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { _, text in
                        ChatReply(text: text).equatable()
                    }
                    Text("FOOTER")
                }
            }
        }
    }
}

private struct OverlayHost: View {
    let model: SheetModel
    var body: some View {
        // Read inside a GeometryReader, as Merge's workspace does.
        GeometryReader { _ in
        VStack { Text("Inbox") }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                if model.open {
                    ZStack(alignment: .top) {
                        Rectangle().fill(.black.opacity(0.085)).ignoresSafeArea().onTapGesture { model.open = false }
                        VStack(spacing: 6) {
                            HStack { Text("Search requests"); Counted() }.frame(height: 48)
                        }
                        .frame(maxWidth: 600)
                        .padding(.top, 63)
                    }
                    .onExitCommand { model.open = false }
                }
            }
        }
    }
}

private struct Counted: NSViewRepresentable {
    nonisolated(unsafe) static var made = 0
    nonisolated(unsafe) static var dismantled = 0
    func makeNSView(context: Context) -> NSView { Self.made += 1; return NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) { dismantled += 1 }
}

private struct DragProbe: View {
    let log: (String) -> Void
    @GestureState private var dragging: CGFloat = 0
    var body: some View {
        Color.red.frame(width: 200, height: 40)
            .overlay { Text(verbatim: "state \(Int(dragging))") }
            .gesture(DragGesture(minimumDistance: 5)
                .updating($dragging) { value, state, _ in state = value.translation.width }
                .onChanged { log("changed \(Int($0.translation.width))") }
                .onEnded { log("ended \(Int($0.translation.width))") })
    }
}

private struct FocusProbe: View {
    enum Field: Hashable { case name, card }
    @FocusState var focus: Field?
    @State var keys: [String] = []
    var body: some View {
        VStack {
            TextField("Name", text: .constant("")).focused($focus, equals: .name)
                .onKeyPress(.return) { keys.append("return"); return .handled }
            Text("card").padding().focusable().focused($focus, equals: .card)
                .onKeyPress(phases: .down) { keys.append($0.characters); return .handled }
            Text(verbatim: "focus \(focus.map { "\($0)" } ?? "none") keys \(keys.joined(separator: ","))")
            Button("Focus card") { focus = .card }
        }
    }
}

private struct Row: Identifiable, Hashable { let id: Int; let title: String; let size: Int }

private struct TableProbe: View {
    @State var order = [KeyPathComparator(\Row.title)]
    @State var selection: Set<Int> = []
    let opened: (Set<Int>) -> Void
    var rows: [Row] { [Row(id: 1, title: "b", size: 3), Row(id: 2, title: "a", size: 1), Row(id: 3, title: "c", size: 2)].sorted(using: order) }
    var body: some View {
        VStack {
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn("Title", value: \.title)
                TableColumn("Size", value: \.size) { Text("\($0.size)") }.width(min: 40, ideal: 60, max: 80)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Open \(ids.sorted().map(String.init).joined())") { opened(ids) }
            } primaryAction: { opened($0) }
            Text(verbatim: "selected \(selection.sorted().map(String.init).joined(separator: ","))")
        }
    }
}

private final class ProbeView: NSView {
    var movedToWindow = 0
    override func viewDidMoveToWindow() { movedToWindow += 1 }
}

private struct Probe: NSViewRepresentable {
    let view: ProbeView
    let dismantled: () -> Void
    func makeNSView(context: Context) -> ProbeView { view }
    func updateNSView(_ nsView: ProbeView, context: Context) {}
    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) { }
}

private struct WrappingLabelStyle: LabelStyle {
    let inner: _Style
    func makeBody(configuration: Configuration) -> some View { Label(configuration).labelStyle(inner) }
}

@MainActor
final class InteractionTests: XCTestCase {
    var backend: HeadlessBackend!
    var hosts: [ViewHost] = []

    override func setUp() async throws {
        backend = HeadlessBackend()
        Runway.install(backend)
    }

    func render<V: View>(_ view: V, size: CGSize = CGSize(width: 400, height: 300)) -> (ViewHost, HeadlessWidget) {
        let host = ViewHost(view, backend: backend)
        host.setSize(size)
        host.render()
        hosts.append(host)
        return (host, host.container as! HeadlessWidget)
    }

    func texts(_ root: HeadlessWidget) -> [String] { root.all.filter { $0.kind == .text }.compactMap { $0.props.text?.plain } }

    func testCustomLabelStyleWrappingABuiltInOne() {
        let (_, root) = render(Label("Commits", systemImage: "clock").labelStyle(WrappingLabelStyle(inner: .iconOnly)))
        XCTAssertFalse(texts(root).contains("Commits"))
        let (_, root2) = render(Label("Commits", systemImage: "clock").labelStyle(WrappingLabelStyle(inner: .titleAndIcon)))
        XCTAssertTrue(texts(root2).contains("Commits"))
    }

    func testInnerForegroundStyleOverridesOuter() {
        let (_, root) = render(HStack {
            Image(systemName: "plus").foregroundStyle(Color.red.opacity(0.55))
            Text("x").foregroundStyle(Color(red: 0, green: 1, blue: 0))
        }.foregroundStyle(.primary))
        let image = root.all.first { $0.kind == .image }
        XCTAssertEqual(image?.props.imageTint?.r ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(image?.props.imageTint?.a ?? 0, 0.55, accuracy: 0.01)
        let text = root.all.first { $0.kind == .text }
        XCTAssertEqual(text?.props.text?.runs.first?.color?.g ?? 0, 1, accuracy: 0.01)
    }

    func testImageTintAlone() {
        let (_, root) = render(Image(systemName: "plus").foregroundStyle(Color.red))
        XCTAssertEqual(root.all.first { $0.kind == .image }?.props.imageTint?.r ?? 0, 1, accuracy: 0.01)
        let (_, root2) = render(Image(systemName: "plus").foregroundStyle(Color.red).foregroundStyle(.primary))
        XCTAssertEqual(root2.all.first { $0.kind == .image }?.props.imageTint?.r ?? 0, 1, accuracy: 0.01)
    }

    func testEqualAnyShapeStyles() {
        let a: AnyShapeStyle? = AnyShapeStyle(HierarchicalShapeStyle.primary)
        let b: AnyShapeStyle? = AnyShapeStyle(Color.red)
        XCTAssertFalse(FieldLayout.equalAny(a as Any, b as Any))
    }

    func testHoverAndContextMenuWrappersKeepFlexibility() {
        let row = HStack(spacing: 8) {
            HStack(spacing: 3) {
                Button {} label: { Text("Sources/File.swift") }
                    .layoutPriority(1)
                    .contextMenu { Button("Copy") {} }
                Button {} label: { Image(systemName: "doc.on.doc").frame(width: 22, height: 22) }
                    .opacity(0)
                Color.clear.onTapGesture {}
            }
            .buttonStyle(.plain)
            .onHover { _ in }
            Text("+12 -4").fixedSize()
        }
        .padding(.horizontal, 9)
        .background(Color.gray)
        .frame(maxWidth: .infinity)
        let (host, _) = render(row, size: CGSize(width: 900, height: 40))
        let size = host.lastRoot!.size(ProposedSize(width: 900, height: 40))
        XCTAssertEqual(size.width, 900)
        // The background spans the row.
        let bg = (host.container as! HeadlessWidget).all.filter { $0.kind == .canvas }.map(\.frame.width).max() ?? 0
        XCTAssertEqual(bg, 900, accuracy: 1)
    }

    func testFirstTextBaselineLinesUpTextOfDifferentSizes() {
        let (_, root) = render(HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("•").font(.system(size: 20))
            Text("A long item that wraps onto a second line here").font(.system(size: 12)).frame(width: 120)
        })
        let t = root.all.filter { $0.kind == .text }
        XCTAssertEqual(t.count, 2)
        let bullet = backend.textBaselines(t[0], width: t[0].frame.width)!.first + t[0].windowFrame.minY
        let item = backend.textBaselines(t[1], width: t[1].frame.width)!.first + t[1].windowFrame.minY
        XCTAssertEqual(bullet, item, accuracy: 0.5)
        // The bullet sits with the first line, not the middle of the item.
        XCTAssertLessThan(t[0].windowFrame.midY, t[1].windowFrame.midY)
    }

    func testAlignmentGuideOverridesAndCustomGuidesCrossStacks() {
        struct Mid: AlignmentID { static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] } }
        let mid = VerticalAlignment(Mid.self)
        let (_, root) = render(HStack(alignment: mid, spacing: 0) {
            Color.red.frame(width: 10, height: 10)
            VStack(spacing: 0) {
                Color.green.frame(width: 10, height: 30)
                Color.blue.frame(width: 10, height: 10).alignmentGuide(mid) { d in d[VerticalAlignment.center] }
            }
        }, size: CGSize(width: 100, height: 200))
        let shapes = root.all.filter { $0.kind == .canvas }.map(\.windowFrame)
        let small = shapes.filter { $0.height == 10 }.sorted { $0.minX < $1.minX }
        guard small.count == 2 else { return XCTFail(root.dump()) }
        let red = small[0], blue = small[1]
        XCTAssertEqual(red.midY, blue.midY, accuracy: 0.5)

        let (_, r2) = render(HStack(alignment: .top, spacing: 0) {
            Color.red.frame(width: 10, height: 10).alignmentGuide(.top) { _ in -20 }
            Color.blue.frame(width: 10, height: 10)
        }, size: CGSize(width: 100, height: 200))
        let s2 = r2.all.filter { $0.kind == .canvas }.map(\.windowFrame).sorted { $0.minX < $1.minX }
        XCTAssertEqual(s2[0].minY - s2[1].minY, 20, accuracy: 0.5)
    }

    func testRowsBelowAGrowingEntryMoveDown() {
        let model = ChatModel()
        let (host, root) = render(Chat(model: model), size: CGSize(width: 200, height: 400))
        func footerY() -> CGFloat { root.all.first { $0.kind == .text && $0.props.text?.plain == "FOOTER" }?.windowFrame.minY ?? -1 }
        let before = footerY()
        model.entries[0] = String(repeating: "word ", count: 60)
        backend.drain()
        host.renderIfNeeded()
        XCTAssertGreaterThan(footerY(), before + 30)
        model.entries.append("Second")
        backend.drain()
        let entry = root.all.first { $0.kind == .text && $0.props.text?.plain == "Second" }!.windowFrame
        XCTAssertGreaterThanOrEqual(footerY(), entry.maxY)
    }

    func testRowsBelowAnEntryThatGrowsOnItsOwnMoveDown() {
        struct Live: View {
            let live: LiveText
            var body: some View {
                GeometryReader { _ in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ChatReply(text: "", live: live).equatable()
                            Text("FOOTER")
                        }
                    }
                }
            }
        }
        let live = LiveText()
        let (_, root) = render(Live(live: live), size: CGSize(width: 200, height: 400))
        func y(_ s: String) -> CGRect? { root.all.first { $0.kind == .text && $0.props.text?.plain == s }?.windowFrame }
        let before = y("FOOTER")!.minY
        live.text = String(repeating: "word ", count: 60)
        backend.drain()
        let reply = y(live.text)!
        XCTAssertGreaterThan(y("FOOTER")!.minY, before + 30)
        XCTAssertGreaterThanOrEqual(y("FOOTER")!.minY, reply.maxY)
    }

    func testStacksPlaceChildrenAsTheyMeasuredThem() {
        // A horizontal scroll view (greedy in height) in a column inside a
        // vertical scroll view: measured under an unspecified height, it is
        // as tall as its content, and stays so when placed.
        let (_, root) = render(ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(repeating: "word ", count: 40))
                    ScrollView(.horizontal) { Text("let x = 1").fixedSize().padding(8) }
                    Text("after the code")
                }
                Text("FOOTER")
            }
        }, size: CGSize(width: 200, height: 600))
        func f(_ s: String) -> CGRect { root.all.first { $0.kind == .text && $0.props.text?.plain == s }!.windowFrame }
        XCTAssertGreaterThanOrEqual(f("FOOTER").minY, f("after the code").maxY)
    }

    func testStreamedReplyKeepsTheRowsBelowItClear() {
        struct Blocks: View {
            let text: String
            var body: some View {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                        if block.hasPrefix("```") {
                            ScrollView(.horizontal) { Text(block).fixedSize(horizontal: true, vertical: false).padding(8) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if block.hasPrefix("- ") {
                            ForEach(Array(block.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(line.dropFirst(2)) }
                            }
                        } else {
                            Text(block)
                        }
                    }
                }
            }
        }
        struct Reply: View, Equatable {
            let text: String
            var body: some View { Blocks(text: text).frame(maxWidth: .infinity, alignment: .leading) }
        }
        struct Chat: View {
            let model: ChatModel
            var body: some View {
                GeometryReader { _ in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 13) {
                            ForEach(Array(model.entries.enumerated()), id: \.offset) { _, t in Reply(text: t).equatable() }
                            Text("FOOTER")
                        }
                    }
                }
            }
        }
        let full = "This PR makes Merge run on Linux through Runway, with a longer opening line.\n\n- real popovers anchored to their views\n- local event monitors that can consume a press\n- bindings that re-render the views that read them\n\n```swift\n.popover(isPresented: $open) { Picker() }\n```\n\nWant me to leave a comment on the file?"
        let model = ChatModel()
        model.entries = ["Hi", ""]
        let (_, root) = render(Chat(model: model), size: CGSize(width: 300, height: 700))
        var i = full.startIndex
        while i < full.endIndex {
            i = full.index(i, offsetBy: 24, limitedBy: full.endIndex) ?? full.endIndex
            model.entries[1] = String(full[..<i])
            backend.drain()
        }
        model.entries.append("after")
        backend.drain()
        func f(_ s: String) -> CGRect? { root.all.first { $0.kind == .text && $0.props.text?.plain == s }?.windowFrame }
        let last = f("Want me to leave a comment on the file?")!
        XCTAssertGreaterThanOrEqual(f("after")!.minY, last.maxY, root.dump())
    }

    func testScaledToFitImageInAPlainButtonKeepsItsAspect() {
        let ctx = CGContext(data: nil, width: 1280, height: 828, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let (_, root) = render(VStack(alignment: .leading) {
            Text("Above")
            Button {} label: {
                Image(image, scale: 1, label: Text("Shot")).resizable().scaledToFit()
                    .frame(maxWidth: 1280).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Text("Below")
        }.frame(width: 248), size: CGSize(width: 248, height: 600))
        let img = root.all.first { $0.kind == .image }!.windowFrame
        XCTAssertEqual(img.width, 248, accuracy: 1, root.dump())
        XCTAssertEqual(img.height, 248 * 828 / 1280, accuracy: 1.5, root.dump())
    }

    func testPositionCentresTheViewAtThePoint() {
        let (_, root) = render(ZStack(alignment: .topLeading) {
            Color.clear
            Text("handle").frame(width: 16, height: 16).position(x: 40, y: 13)
        }.frame(width: 200, height: 26), size: CGSize(width: 200, height: 26))
        let handle = root.all.first { $0.kind == .text }
        XCTAssertEqual(handle?.frame.midX ?? 0, 40, accuracy: 0.5)
        XCTAssertEqual(handle?.frame.midY ?? 0, 13, accuracy: 0.5)
    }

    func testCodeReviewSymbolsHaveArtwork() {
        for name in ["arrow.triangle.branch", "arrow.triangle.merge", "arrowshape.turn.up.left", "brain", "bubble.left",
                     "checklist", "cloud.fill", "paperclip", "return", "scope", "at", "checkmark.circle.fill", "xmark.circle.fill"] {
            XCTAssertNotNil(SymbolArt.svg(name), name)
        }
    }

    func testModifierContainersKeepLayoutPriority() {
        let (_, root) = render(HStack(spacing: 0) {
            Text("Sources/Workspace/ReviewRouter.swift").lineLimit(1).layoutPriority(1).contextMenu { Button("Copy") {} }
            Color.clear
        }.frame(width: 300))
        let label = root.all.first { $0.kind == .text }
        XCTAssertGreaterThan(label?.frame.width ?? 0, 200)
    }

    func testRepresentableJoinsTheHostingViewHierarchy() {
        let probe = ProbeView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            Color.red.frame(height: 50)
            Probe(view: probe, dismantled: {}).frame(width: 100, height: 40)
            Spacer()
        })
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        hosting.layoutSubtreeIfNeeded()
        hosting.host.render()
        XCTAssertTrue(probe.superview === hosting)
        XCTAssertTrue(probe.window === window)
        XCTAssertEqual(probe.movedToWindow, 1)
        // Framed where SwiftUI put it, in the hosting view's top-left coordinates.
        XCTAssertEqual(probe.frame, NSRect(x: 100, y: 50, width: 100, height: 40))
        // hitTest takes the superview's (here the window's) coordinates.
        XCTAssertTrue(hosting.hitTest(hosting.convert(NSPoint(x: 150, y: 70), to: nil)) === probe)
        XCTAssertFalse(hosting.hitTest(hosting.convert(NSPoint(x: 150, y: 10), to: nil)) === probe)
    }

    func testOverlayAppearsWhenModelChanges() {
        let model = SheetModel()
        let (host, root) = render(OverlayHost(model: model), size: CGSize(width: 800, height: 600))
        XCTAssertFalse(texts(root).contains("Search requests"))
        model.open = true
        // The change itself schedules the render.
        backend.drain()
        XCTAssertTrue(texts(root).contains("Search requests"))
        // Closed, what it held goes with it, though it's resolved inside a
        // GeometryReader at layout time.
        XCTAssertEqual(Counted.made, 1)
        model.open = false
        backend.drain()
        XCTAssertFalse(texts(root).contains("Search requests"))
        XCTAssertEqual(Counted.dismantled, 1)
        model.open = true
        backend.drain()
        XCTAssertEqual(Counted.made, 2, "a new view, as SwiftUI makes one for new identity")
    }

    func testSystemNSColorsBridgeToSwiftUI() {
        var env = EnvironmentValues()
        env.colorScheme = .light
        let c = Color(nsColor: .windowBackgroundColor).resolve(env)
        XCTAssertGreaterThan(c.a, 0.99)
        XCTAssertGreaterThan(c.r, 0.8)
    }

    func testChildWithABindingSeesItsValueChange() {
        struct Input: View {
            @Binding var text: String
            var body: some View {
                ZStack {
                    if text.isEmpty { Text("Placeholder") }
                    TextEditor(text: $text)
                }
            }
        }
        struct Sheet: View {
            @State var body_ = ""
            var body: some View {
                Input(text: $body_).onAppear { body_ = "A description" }
            }
        }
        let (_, root) = render(Sheet())
        backend.drain()
        XCTAssertEqual(root.all.first { $0.kind == .textEditor }?.props.string, "A description")
        XCTAssertFalse(texts(root).contains("Placeholder"))
    }

    func testTextSetOnAppearReachesATextEditorBehindAPlaceholder() {
        struct Sheet: View {
            @State var title = ""
            @State var body_ = ""
            var body: some View {
                VStack {
                    TextField("Title", text: $title)
                    ZStack(alignment: .topLeading) {
                        if body_.isEmpty { Text("Describe the change").allowsHitTesting(false) }
                        TextEditor(text: $body_).scrollContentBackground(.hidden)
                    }
                }
                .onAppear { title = "A title"; body_ = "A description" }
            }
        }
        let (_, root) = render(Sheet())
        backend.drain()
        XCTAssertEqual(root.all.first { if case .textField = $0.kind { true } else { false } }?.props.string, "A title")
        XCTAssertEqual(root.all.first { $0.kind == .textEditor }?.props.string, "A description")
        XCTAssertFalse(texts(root).contains("Describe the change"))
    }

    func testTextEditorFillsAStack() {
        let (_, root) = render(VStack(alignment: .leading, spacing: 9) {
            Text("Default review instructions")
            ZStack(alignment: .topLeading) {
                Text("Placeholder")
                TextEditor(text: .constant("")).scrollContentBackground(.hidden).padding(5)
            }
            .font(.system(size: 12))
            .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.gray) }
            .onChange(of: 1) { _, _ in }
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity), size: CGSize(width: 560, height: 378))
        let editor = root.all.first { $0.kind == .textEditor }
        XCTAssertGreaterThan(editor?.frame.height ?? 0, 250)
    }

    func testLinkSymbolImage() {
        XCTAssertNotNil(SymbolArt.svg("link"))
        let img = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        XCTAssertNotNil(img)
        XCTAssertNotNil(NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil))
    }

    func pointerWidgets(_ root: HeadlessWidget) -> [HeadlessWidget] {
        root.all.filter { HeadlessBackend.record($0).pointer != nil }
    }

    func testDragGestureTracksThePointer() {
        var log: [String] = []
        let (_, root) = render(DragProbe { log.append($0) })
        guard let area = pointerWidgets(root).first, let pointer = HeadlessBackend.record(area).pointer else { return XCTFail("no drag area") }
        _ = pointer(PointerEvent(kind: .down, location: CGPoint(x: 10, y: 10)))
        _ = pointer(PointerEvent(kind: .dragged, location: CGPoint(x: 12, y: 10)))
        XCTAssertTrue(log.isEmpty, "under the minimum distance")
        _ = pointer(PointerEvent(kind: .dragged, location: CGPoint(x: 40, y: 10)))
        backend.drain()
        XCTAssertEqual(log, ["changed 30"])
        XCTAssertTrue(texts(root).contains("state 30"), "GestureState follows the drag")
        _ = pointer(PointerEvent(kind: .up, location: CGPoint(x: 50, y: 10)))
        backend.drain()
        XCTAssertEqual(log, ["changed 30", "ended 40"])
        XCTAssertTrue(texts(root).contains("state 0"), "and resets when it ends")
    }

    func testFocusStateAndKeyPresses() {
        let (_, root) = render(FocusProbe())
        let field = root.all.first { $0.kind == .textField(secure: false) }!
        // Focusing the field natively sets the state; keys reach its handlers first.
        backend.focus(field)
        backend.drain()
        XCTAssertTrue(texts(root).contains { $0.hasPrefix("focus name") })
        XCTAssertEqual(HeadlessBackend.record(field).textKey?(KeyPress(key: "return")), true)
        XCTAssertEqual(HeadlessBackend.record(field).textKey?(KeyPress(key: "a")), false, "other keys stay the field's")
        backend.drain()
        XCTAssertTrue(texts(root).contains { $0.hasSuffix("keys return") })
        // Setting the state in code moves focus to the focusable card.
        let button = root.all.first { $0.kind == .button }!
        button.events.onTap?()
        backend.drain()
        XCTAssertTrue(texts(root).contains { $0.hasPrefix("focus card") })
        let card = root.all.first { HeadlessBackend.record($0).focusable }!
        XCTAssertTrue(HeadlessBackend.focused === card)
        XCTAssertEqual(HeadlessBackend.record(card).key?(KeyPress(key: "x")), true)
        backend.drain()
        XCTAssertTrue(texts(root).contains { $0.hasSuffix("keys return,x") })
    }

    func testHoverAndContextMenu() {
        final class Box { var hovered = false; var picked = "" }
        let box = Box()
        let (_, root) = render(Text("row")
            .onHover { box.hovered = $0 }
            .contextMenu { Button("Copy") { box.picked = "copy" }; Divider(); Button("Open") { box.picked = "open" } })
        let areas = pointerWidgets(root)
        XCTAssertEqual(areas.count, 2)
        for a in areas { _ = HeadlessBackend.record(a).pointer?(PointerEvent(kind: .moved, location: CGPoint(x: 2, y: 2))) }
        XCTAssertTrue(box.hovered)
        for a in areas { _ = HeadlessBackend.record(a).pointer?(PointerEvent(kind: .exited, location: .zero)) }
        XCTAssertFalse(box.hovered)
        for a in areas { _ = HeadlessBackend.record(a).pointer?(PointerEvent(kind: .down, location: CGPoint(x: 2, y: 2), button: 1)) }
        let menu = HeadlessBackend.poppedUpMenus.last
        XCTAssertEqual(menu?.map(\.title), ["Copy", "", "Open"])
        menu?[2].action?()
        XCTAssertEqual(box.picked, "open")
    }

    func testMenuItemsCarrySymbolsShortcutsAndRoles() {
        let (_, root) = render(Text("row").contextMenu {
            Button("Copy Line", systemImage: "doc.on.doc") {}.keyboardShortcut("c", modifiers: [.command, .shift])
            Label("Comment", systemImage: "plus.bubble")
            Button("Delete", role: .destructive) {}
            Toggle("Wrap", isOn: .constant(true))
        })
        for a in pointerWidgets(root) { _ = HeadlessBackend.record(a).pointer?(PointerEvent(kind: .down, location: CGPoint(x: 2, y: 2), button: 1)) }
        let menu = HeadlessBackend.poppedUpMenus.last ?? []
        let copy = menu.first { $0.title == "Copy Line" }
        XCTAssertEqual(copy?.symbol, "doc.on.doc")
        XCTAssertEqual(copy?.shortcut, KeyPress(key: "c", command: true, shift: true))
        XCTAssertEqual(copy?.shortcut?.displayText, "Ctrl+Shift+C")
        XCTAssertEqual(copy?.shortcut?.gtkAccelerator, "<Control><Shift>c")
        XCTAssertEqual(menu.first { $0.title == "Delete" }?.destructive, true)
        XCTAssertEqual(menu.first { $0.title == "Wrap" }?.checked, true)
    }

    func testTableSortsSelectsAndOpens() {
        var opened: [Set<Int>] = []
        let (_, root) = render(TableProbe { opened.append($0) }, size: CGSize(width: 400, height: 300))
        func cells() -> [String] { texts(root).filter { ["a", "b", "c"].contains($0) } }
        XCTAssertEqual(cells(), ["a", "b", "c"])
        // Clicking the sorted column's header reverses it; another column sorts by it.
        let headers = root.all.filter { $0.kind == .tapArea || $0.kind == .button }
        let title = headers.first { $0.all.contains { $0.props.text?.plain == "Title" } }
        title?.events.onTap?()
        backend.drain()
        XCTAssertEqual(cells(), ["c", "b", "a"])
        let size = headers.first { $0.all.contains { $0.props.text?.plain == "Size" } }
        size?.events.onTap?()
        backend.drain()
        XCTAssertEqual(cells(), ["a", "c", "b"])
        // Rows: click selects, ⌘-click adds, double-click opens, secondary click shows the menu.
        let rows = pointerWidgets(root).filter { $0.frame.height == 24 }
        XCTAssertEqual(rows.count, 3)
        _ = HeadlessBackend.record(rows[0]).pointer?(PointerEvent(kind: .down, location: CGPoint(x: 5, y: 5)))
        _ = HeadlessBackend.record(rows[2]).pointer?(PointerEvent(kind: .down, location: CGPoint(x: 5, y: 5), modifiers: .command))
        backend.drain()
        XCTAssertTrue(texts(root).contains("selected 1,2"))
        _ = HeadlessBackend.record(rows[1]).pointer?(PointerEvent(kind: .down, location: CGPoint(x: 5, y: 5), clickCount: 2))
        XCTAssertEqual(opened, [[3]])
        _ = HeadlessBackend.record(rows[1]).pointer?(PointerEvent(kind: .down, location: CGPoint(x: 5, y: 5), button: 1))
        XCTAssertEqual(HeadlessBackend.poppedUpMenus.last?.map(\.title), ["Open 3"])
    }
}

private struct LateInner: View {
    var body: some View { Text("Nested in a reader") }
}

private struct LateRow: View {
    var body: some View { VStack { LateInner() } }
}

extension InteractionTests {
    /// Views nested two deep in GeometryReader content keep their widgets
    /// when a later render reuses the outer one (a window resize).
    func testViewsNestedInGeometryReaderContentSurviveResizes() {
        let (host, root) = render(GeometryReader { _ in LateRow() }, size: CGSize(width: 400, height: 300))
        let text = root.all.first { $0.props.text?.plain == "Nested in a reader" }
        XCTAssertNotNil(text)
        for width in [360.0, 420, 380] {
            host.setSize(CGSize(width: width, height: 300))
            host.render()
        }
        XCTAssertEqual(text?.destroyed, false)
        XCTAssertTrue(root.all.contains { $0 === text })
    }
}
