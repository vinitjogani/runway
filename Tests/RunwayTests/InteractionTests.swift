// Focus, key presses, hover, context menus, tables, scrolling to views,
// attributed text and custom label styles, on the headless backend.

import XCTest
import RunwayCore
@testable import SwiftUI

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
}
