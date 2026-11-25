// Focus, key presses, hover, context menus, tables, scrolling to views,
// attributed text and custom label styles, on the headless backend.

import XCTest
import RunwayCore
@testable import SwiftUI

@MainActor @Observable private final class SheetModel { var open = false }

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
}
