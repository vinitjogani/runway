import XCTest
import RunwayCore
@testable import SwiftUI

@MainActor
final class HorizontalTextLayoutTests: XCTestCase {
    func testFittingOneLineLabelDoesNotShareItsWidthWithSpacer() throws {
        try verifyIdealTextWidth("Fill in your journal", in: HStack(spacing: 0) {
            Text("Fill in your journal").font(.system(size: 17)).lineLimit(1)
            Spacer(minLength: 8)
            Text("›")
        }.frame(width: 250))
    }

    func testFittingLabelKeepsIdealWidthWhenItsMinimumIsLarger() throws {
        try verifyIdealTextWidth("—", in: HStack(spacing: 8) {
            Text("—").font(.system(size: 104)).lineLimit(1).frame(minWidth: 45)
            Text("bpm").font(.system(size: 17))
        })
    }

    private func verifyIdealTextWidth<V: View>(_ text: String, in view: V) throws {
        let host = ViewHost(view, backend: HeadlessBackend())
        host.setSize(CGSize(width: 393, height: 852))
        host.render()
        let container = host.container as! HeadlessWidget
        let widget = try XCTUnwrap(container.all.first { $0.props.text?.plain == text })
        let styled = try XCTUnwrap(widget.props.text)
        XCTAssertEqual(widget.frame.width, HeadlessBackend.measureText(styled, width: nil).width)
    }
}
