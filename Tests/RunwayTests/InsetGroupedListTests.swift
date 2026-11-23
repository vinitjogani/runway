import XCTest
import RunwayCore
@testable import SwiftUI

@MainActor
final class InsetGroupedListTests: XCTestCase {
    func testMobileListAppliesSectionCardsAndRowAppearance() {
        let backend = HeadlessBackend()
        Runway.install(backend)
        let host = ViewHost(List {
            Section {
                Text("Hero")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
            Section {
                Text("First").listRowSeparator(.hidden, edges: .bottom)
                Text("Second")
                Text("Third")
            } header: {
                Text("Group")
            }
        }.listStyle(.insetGrouped), backend: backend)
        host.baseEnvironment._mobilePreview = true
        host.setSize(CGSize(width: 400, height: 300))
        host.render()

        let root = host.container as! HeadlessWidget
        let backgrounds = root.all.filter { $0.kind == .canvas && $0.frame.height > 1 }
        let colors = backgrounds.compactMap { widget -> RGBA? in
            guard case let .fill(_, .color(color))? = widget.props.drawing.first else { return nil }
            return color
        }
        XCTAssertEqual(backgrounds.map(\.frame.width), [368, 368, 368, 368])
        XCTAssertEqual(colors, [.clear, .white, .white, .white])
        XCTAssertEqual(root.all.filter { $0.kind == .canvas && $0.frame.height == 1 }.count, 1)
        XCTAssertEqual(root.all.first { $0.props.text?.plain == "Hero" }?.windowFrame.minX, 16)
        XCTAssertEqual(root.all.first { $0.props.text?.plain == "Group" }?.windowFrame.minX, 16)
        XCTAssertEqual(root.all.first { $0.props.text?.plain == "First" }?.windowFrame.minX, 32)
    }

    func testPhoneRowsAlignSeparatorWithTitleAfterIcon() {
        let backend = HeadlessBackend()
        Runway.install(backend)
        func row(_ title: String) -> some View {
            Button {} label: {
                HStack(spacing: 12) {
                    Rectangle().fill(Color.gray).frame(width: 36, height: 36)
                    Text(title)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        let host = ViewHost(List {
            Section {
                row("First")
                row("Second")
            }
        }.listStyle(.insetGrouped), backend: backend)
        host.baseEnvironment = MobilePreviewProfile.iphonePro.environment
        host.baseEnvironment._mobileTabBarInset = 92
        host.setSize(CGSize(width: 402, height: 250))
        host.render()

        let root = host.container as! HeadlessWidget
        let cards = root.all.filter { $0.kind == .canvas && $0.frame.height == 82 }
        XCTAssertEqual(cards.map(\.windowFrame), [
            CGRect(x: 16, y: 36, width: 370, height: 82),
            CGRect(x: 16, y: 118, width: 370, height: 82),
        ])
        guard case let .fill(.path(path), _)? = cards.first?.props.drawing.first else { return XCTFail("Missing card outline") }
        XCTAssertEqual(path.first, .move(CGPoint(x: 26, y: 0)))
        XCTAssertEqual(root.all.first { $0.kind == .canvas && $0.frame.height == 36 }?.windowFrame.minX, 32)
        XCTAssertEqual(root.all.first { $0.props.text?.plain == "First" }?.windowFrame.minX, 80)
        XCTAssertEqual(root.all.first { $0.kind == .canvas && $0.frame.height == 1 }?.windowFrame,
                       CGRect(x: 80, y: 117, width: 290, height: 1))
        let scroll = root.all.first { $0.kind == .scroll(horizontal: false, vertical: true) }
        XCTAssertEqual(scroll?.children.first?.contentSize.height, 298)
    }
}
