import XCTest
import RunwayCore
import SwiftUI

private final class ButtonLabelModel: ObservableObject {
    let title = "Environment label"
}

private struct EnvironmentButtonLabel: View {
    @EnvironmentObject private var model: ButtonLabelModel
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(model.title + (isEnabled ? "" : " disabled"))
    }
}

@MainActor
final class EnvironmentProbeTests: XCTestCase {
    func testButtonLabelProbeReadsEnvironment() {
        let backend = HeadlessBackend()
        let host = ViewHost(
            Button(action: {}) { EnvironmentButtonLabel() }
                .disabled(true)
                .environmentObject(ButtonLabelModel()),
            backend: backend
        )
        host.setSize(CGSize(width: 400, height: 300))
        host.render()

        let button = (host.container as? HeadlessWidget)?.all.first { $0.kind == .button }
        XCTAssertEqual(button?.props.title, "Environment label disabled")
    }
}
