import XCTest
import RunwayCore
@testable import SwiftUI

@MainActor
final class NavigationTests: XCTestCase {
    func testBindingDestinationPushesAndDismissesWithoutLosingRootState() {
        let backend = HeadlessBackend()
        let host = ViewHost(NavigationStack { Screen() }, backend: backend)
        host.setSize(CGSize(width: 393, height: 852))
        host.render()
        let root = host.container as! HeadlessWidget

        root.all.first { $0.props.title == "Show details" }?.events.onTap?()
        host.renderIfNeeded()
        XCTAssertTrue(root.all.contains { $0.props.text?.plain == "Details" })
        XCTAssertFalse(root.all.contains { $0.props.title == "Show details" })

        root.all.first { $0.props.title == "Close details" }?.events.onTap?()
        host.renderIfNeeded()
        XCTAssertFalse(root.all.contains { $0.props.text?.plain == "Details" })
        XCTAssertTrue(root.all.contains { $0.props.text?.plain == "Visits: 1" })
    }

    func testValueLinkUpdatesTypedPath() {
        var path: [Int] = []
        let binding = Binding(get: { path }, set: { path = $0 })
        let backend = HeadlessBackend()
        let host = ViewHost(NavigationStack(path: binding) {
            NavigationLink("Seven", value: 7)
                .navigationDestination(for: Int.self) { Text("Number: \($0)") }
        }, backend: backend)
        host.setSize(CGSize(width: 393, height: 852))
        host.render()
        let root = host.container as! HeadlessWidget

        root.all.first { $0.children.contains { $0.props.text?.plain == "Seven" } && $0.events.onTap != nil }?.events.onTap?()
        host.render()
        XCTAssertEqual(path, [7])
        XCTAssertTrue(root.all.contains { $0.props.text?.plain == "Number: 7" })
    }

    func testMobileToolbarCentersTitleAndKeepsActionsAtTheirDeclaredEdges() throws {
        let backend = HeadlessBackend()
        let host = ViewHost(NavigationStack { ToolbarScreen() }, backend: backend,
                            environment: MobilePreviewProfile.iphonePro.environment)
        host.setSize(CGSize(width: 402, height: 874))
        host.render()
        let root = host.container as! HeadlessWidget
        let title = try XCTUnwrap(root.all.first { $0.props.text?.plain == "Metric components" })
        let left = try XCTUnwrap(root.all.first { $0.props.text?.plain == "Month" })
        let right = try XCTUnwrap(root.all.first { $0.props.text?.plain == "Daily" })
        let content = try XCTUnwrap(root.all.first { $0.props.text?.plain == "Chart content" })
        XCTAssertEqual(title.windowFrame.midX, 201, accuracy: 1)
        XCTAssertLessThan(left.windowFrame.midX, title.windowFrame.minX)
        XCTAssertGreaterThan(right.windowFrame.midX, title.windowFrame.maxX)
        XCTAssertGreaterThan(content.windowFrame.minY, title.windowFrame.maxY)

        let button = try XCTUnwrap(root.all.first { $0.children.contains { $0.props.text?.plain == "Month" } && $0.events.onTap != nil })
        XCTAssertEqual(button.windowFrame.minY, 62, accuracy: 0.01)
        XCTAssertEqual(button.windowFrame.height, 44, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(button.windowFrame.width, 44)
        button.events.onTap?()
        host.renderIfNeeded()
        XCTAssertTrue(root.all.contains { $0.props.text?.plain == "Week" })
    }

    func testMobileHiddenNavigationBarDoesNotMountTitleOrToolbar() {
        let backend = HeadlessBackend()
        let host = ViewHost(NavigationStack {
            Text("Sign in").navigationTitle("Account").toolbar { Button("Settings") {} }
                .toolbar(.hidden, for: .navigationBar)
        }, backend: backend, environment: MobilePreviewProfile.iphone.environment)
        host.setSize(CGSize(width: 393, height: 852))
        host.render()
        let root = host.container as! HeadlessWidget
        XCTAssertTrue(root.all.contains { $0.props.text?.plain == "Sign in" })
        XCTAssertFalse(root.all.contains { $0.props.text?.plain == "Account" || $0.props.text?.plain == "Settings" })
    }

    private struct Screen: View {
        @State var presented = false
        @State var visits = 0
        var body: some View {
            VStack {
                Text("Visits: \(visits)")
                Button("Show details") { visits += 1; presented = true }
            }
            .navigationDestination(isPresented: $presented) { Detail() }
        }
    }

    private struct Detail: View {
        @Environment(\.dismiss) var dismiss
        var body: some View {
            VStack {
                Text("Details")
                Button("Close details") { dismiss() }
            }
        }
    }

    private struct ToolbarScreen: View {
        @State var expanded = false

        var body: some View {
            Text("Chart content")
                .navigationTitle("Metric components")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(expanded ? "Week" : "Month") { expanded.toggle() } }
                    ToolbarItem(placement: .topBarTrailing) { Button("Daily") {} }
                }
        }
    }
}
