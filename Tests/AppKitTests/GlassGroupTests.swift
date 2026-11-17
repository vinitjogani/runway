// Toolbar-style capsules: an NSGlassEffectView around a stack of fixed-size
// symbol buttons takes its size from them, and sits in a bar beside a
// flexible label without stretching.

import XCTest
import RunwayCore
@testable import AppKit

final class GlassGroupTests: XCTestCase {
    private func button() -> NSButton {
        let b = NSButton(image: NSImage(), target: nil, action: nil)
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }
    private func group(_ n: Int) -> NSView {
        let stack = NSStackView(views: (0..<n).map { _ in button() })
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        let glass = NSGlassEffectView()
        glass.contentView = stack
        glass.heightAnchor.constraint(equalToConstant: 30).isActive = true
        glass.setContentHuggingPriority(.required, for: .horizontal)
        glass.setContentHuggingPriority(.required, for: .vertical)
        return glass
    }

    @MainActor func testCapsuleHugsItsButtons() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 40))
        let a = group(3), b = group(1)
        let tools = NSStackView(views: [a, b])
        tools.spacing = 8
        tools.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tools)
        NSLayoutConstraint.activate([
            tools.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            tools.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
        ])
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(a.frame.width, 88, accuracy: 0.5, "\(a.frame)")
        XCTAssertEqual(b.frame.width, 32, accuracy: 0.5, "\(b.frame)")
        XCTAssertEqual(b.frame.minX - a.frame.maxX, 8, accuracy: 0.5)
        XCTAssertEqual(tools.frame.maxX, 250, accuracy: 0.5)
    }

    @MainActor func testCapsuleBesideAFlexibleTitle() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 32))
        let title = NSTextField(labelWithString: "Welcome")
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let actions = group(2)
        let stack = NSStackView(views: [title, actions])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        root.layoutSubtreeIfNeeded()
        XCTAssertEqual(actions.frame.width, 60, accuracy: 0.5, "\(actions.frame)")
        XCTAssertEqual(actions.convert(actions.bounds, to: root).maxX, 790, accuracy: 0.5)
    }
}
