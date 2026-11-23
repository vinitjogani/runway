import XCTest
import RunwayCore
@testable import SwiftUI

@MainActor
final class TabViewTests: XCTestCase {
    func testMobileTabBarUsesLabelsAndUpdatesSelection() {
        let backend = HeadlessBackend()
        Runway.install(backend)
        var selection = 1
        let host = ViewHost(
            TabView(selection: Binding(get: { selection }, set: { selection = $0 })) {
                VStack {
                    Text("First page")
                    Image(systemName: "person.crop.circle")
                    Spacer()
                    Button("Bottom action") {}
                }.tag(1)
                    .tabItem { Label("One", systemImage: "heart") }
                Text("Second page")
                    .tabItem { Label("Second tab", systemImage: "person.crop.circle") }.tag(2)
            }
            .tint(.green), backend: backend
        )
        host.baseEnvironment = MobilePreviewProfile.iphonePro.environment
        host.setSize(MobilePreviewProfile.iphonePro.size)
        host.render()

        let root = host.container as! HeadlessWidget
        let action = root.all.first { $0.kind == .button && $0.all.contains { $0.props.text?.plain == "Bottom action" } }
        XCTAssertEqual(action?.windowFrame.maxY, 782)
        let bar = root.all.first { $0.kind == .canvas && $0.windowFrame.height == 64 }
        XCTAssertEqual(bar?.windowFrame, CGRect(x: 20, y: 790, width: 362, height: 64))
        XCTAssertEqual(bar?.props.backdropBlur?.radius, 14)
        if case let .fill(_, .linearGradient(stops, _, _))? = bar?.props.drawing.first {
            XCTAssertTrue(stops.allSatisfy { $0.color.a > 0 && $0.color.a < 1 })
        } else {
            XCTFail("Expected a translucent glass fill")
        }
        XCTAssertEqual(root.all.filter { $0.kind == .canvas }.count, 2)
        assertSingleGlassEdge(bar?.props.drawing ?? [])
        let buttons = root.all.filter { $0.kind == .button && $0 !== action }
        XCTAssertEqual(buttons.map(\.props.title), ["One", "Second tab"])
        XCTAssertEqual(buttons.map(\.windowFrame), [
            CGRect(x: 25, y: 795, width: 176, height: 54),
            CGRect(x: 201, y: 795, width: 176, height: 54),
        ])
        let selectedFrame = { root.all.first { $0.kind == .canvas && $0.windowFrame.height == 54 }?.windowFrame }
        XCTAssertEqual(selectedFrame(), buttons.first?.windowFrame)
        XCTAssertNil(root.all.first { $0.kind == .canvas && $0.windowFrame.height == 54 }?.props.backdropBlur)
        let icons = buttons.flatMap { $0.all.filter { $0.kind == .image } }
        XCTAssertEqual(icons.map(\.props.image), [.symbol("heart"), .symbol("person.crop.circle")])
        XCTAssertEqual(icons.map(\.props.imageSymbolVariant), [nil, "person.crop.circle.fill"])
        let ordinaryProfile = root.all.first { $0.kind == .image && $0.props.image == .symbol("person.crop.circle") }
        XCTAssertNotNil(ordinaryProfile)
        XCTAssertNil(ordinaryProfile?.props.imageSymbolVariant)
        XCTAssertEqual(icons.map(\.props.imagePointSize), [24, 24])
        XCTAssertEqual(icons.map(\.props.imageTint), [Color.green.resolve(host.baseEnvironment), Color.primary.resolve(host.baseEnvironment)])
        XCTAssertTrue(root.all.contains { $0.props.text?.plain == "First page" })
        guard let second = buttons.last else { return XCTFail("Missing second tab button") }
        second.events.onTap?()
        backend.drain()
        XCTAssertEqual(selection, 2)
        XCTAssertTrue(root.all.contains { $0.props.text?.plain == "Second page" })
        XCTAssertEqual(icons.map(\.props.imageTint), [Color.primary.resolve(host.baseEnvironment), Color.green.resolve(host.baseEnvironment)])
        XCTAssertEqual(selectedFrame(), second.windowFrame)
    }

    func testMobileTabBarOverlaysScrollViewportWithBottomClearance() throws {
        let backend = HeadlessBackend()
        Runway.install(backend)
        let host = ViewHost(TabView {
            ScrollView {
                Text("Content").frame(height: 900)
            }
            .tabItem { Label("Activity", systemImage: "waveform") }
        }, backend: backend)
        host.baseEnvironment = MobilePreviewProfile.iphonePro.environment
        host.setSize(MobilePreviewProfile.iphonePro.size)
        host.render()

        let root = host.container as! HeadlessWidget
        let scroll = try XCTUnwrap(root.all.first { $0.kind == .scroll(horizontal: false, vertical: true) })
        XCTAssertEqual(scroll.windowFrame, CGRect(x: 0, y: 0, width: 402, height: 874))
        let content = try XCTUnwrap(scroll.children.first)
        XCTAssertEqual(content.contentSize.height, 992)
    }

    func testToolbarGlassUsesOneDirectionalEdgeAndKeepsItsBackdrop() throws {
        let backend = HeadlessBackend()
        Runway.install(backend)
        let host = ViewHost(Color.clear.frame(width: 44, height: 44)
            .background { MobileGlassSurface(.toolbar) }
            .opacity(0.4), backend: backend)
        host.setSize(CGSize(width: 100, height: 100))
        host.render()

        let root = host.container as! HeadlessWidget
        let surface = try XCTUnwrap(root.all.first { $0.props.backdropBlur != nil })
        XCTAssertEqual(surface.props.backdropBlur?.radius, 10)
        XCTAssertEqual(surface.props.opacity, 0.4)
        XCTAssertEqual(surface.windowFrame, CGRect(x: 28, y: 28, width: 44, height: 44))
        XCTAssertEqual(root.all.filter { $0.kind == .canvas }.count, 2)
        assertSingleGlassEdge(surface.props.drawing)
    }

    func testDesktopTabViewUsesSegmentedControl() {
        let backend = HeadlessBackend()
        Runway.install(backend)
        let host = ViewHost(TabView {
            Text("First page").tabItem { Label("One", systemImage: "heart") }
            Text("Second page").tabItem { Text("Two") }
        }, backend: backend)
        host.setSize(CGSize(width: 400, height: 300))
        host.render()

        let root = host.container as! HeadlessWidget
        let control = root.all.first { $0.kind == .segmented }
        XCTAssertEqual(control?.props.options, ["One", "Two"])
        XCTAssertEqual(control?.props.selected, 0)
        control?.events.onSelect?(1)
        backend.drain()
        XCTAssertEqual(control?.props.selected, 1)
        XCTAssertTrue(root.all.contains { $0.props.text?.plain == "Second page" })
    }

    private func assertSingleGlassEdge(_ commands: [DrawCommand], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(commands.count, 2, file: file, line: line)
        guard case let .stroke(edge, .linearGradient(stops, start, end), style)? = commands.last else {
            return XCTFail("Expected one directional edge", file: file, line: line)
        }
        XCTAssertEqual(edge.bounds.minY - style.lineWidth / 2, 0, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(start, CGPoint(x: 0.5, y: 0), file: file, line: line)
        XCTAssertEqual(end, CGPoint(x: 0.5, y: 1), file: file, line: line)
        XCTAssertGreaterThan(stops.first?.color.a ?? 0, stops.last?.color.a ?? 0, file: file, line: line)
    }
}
