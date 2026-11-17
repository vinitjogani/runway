// Window chrome: the titlebar band a toolbar takes, the safe area it leaves
// content views, full-size content, frame sizes, and Auto Layout around
// stack views as AppKit resolves it (no broken constraints).

import XCTest
import RunwayCore
@testable import AppKit

final class WindowChromeTests: ControlsTestCase {
    /// A borderless symbol button sized by its own constraints, as apps
    /// make toolbar-like buttons.
    private func fixedButton() -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!, target: nil, action: nil)
        b.isBordered = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    func testStackArrangedButtonsWithSizeConstraintsDontConflict() {
        LayoutEngine.conflicts.removeAll()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let a = fixedButton(), b = fixedButton()
        let stack = NSStackView(views: [a, b])
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
        ])
        _ = window(root)
        XCTAssertEqual(LayoutEngine.conflicts, [])
        XCTAssertEqual(a.frame.size, CGSize(width: 28, height: 26))
        XCTAssertEqual(stack.frame.size, CGSize(width: 58, height: 26))
        XCTAssertEqual(stack.frame.maxX, 590)
    }

    /// A sidebar whose tools sit in the titlebar band over full-size
    /// content, centred in the band above its safe area (as Flight Notes'
    /// sidebar does), and a pane below whose bar reaches the safe area.
    func testFullSizeContentGetsTheToolbarBandAsSafeArea() {
        LayoutEngine.conflicts.removeAll()
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let sidebar = NSViewController()
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 500))
        let tools = NSStackView(views: [fixedButton(), fixedButton()])
        tools.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tools)
        let band = NSLayoutGuide()
        root.addLayoutGuide(band)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: root.topAnchor),
            band.bottomAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            tools.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            tools.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
        ])
        sidebar.view = root
        let pane = NSViewController()
        pane.view = NSView(frame: CGRect(x: 0, y: 0, width: 580, height: 500))
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebar))
        split.addSplitViewItem(NSSplitViewItem(viewController: pane))
        w.contentViewController = split
        w.toolbarStyle = .unifiedCompact
        w.toolbar = NSToolbar(identifier: "empty")
        w.makeKeyAndOrderFront(nil)
        settle(w.contentView!)

        XCTAssertEqual(w.contentView!.safeAreaInsets.top, 38)
        XCTAssertEqual(w.contentLayoutRect, CGRect(x: 0, y: 0, width: 800, height: 462))
        XCTAssertEqual(root.safeAreaInsets.top, 38)
        XCTAssertEqual(pane.view.safeAreaInsets.top, 38)
        XCTAssertEqual(pane.view.safeAreaRect.height, 462)
        // The tools centre in the band.
        let inWindow = tools.convert(tools.bounds, to: nil)
        XCTAssertEqual(inWindow.midY, 500 - 19, accuracy: 0.5)
        XCTAssertEqual(inWindow.maxX, root.convert(root.bounds, to: nil).maxX - 10, accuracy: 0.5)
        XCTAssertEqual(LayoutEngine.conflicts, [])
        // Without the toolbar, nothing covers the content.
        w.toolbar?.isVisible = false
        settle(w.contentView!)
        XCTAssertEqual(root.safeAreaInsets.top, 0)
        XCTAssertEqual(w.contentLayoutRect.height, 500)
    }

    /// Caps' editor: the title and content items over the content, the
    /// inspector's items over the inspector (after the inspector tracking
    /// separator), the standard Toggle Inspector item at the end.
    func testToolbarItemsFollowTheInspectorTrackingSeparator() {
        final class D: NSObject, NSToolbarDelegate {
            func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
                [.flexibleSpace, "export", .inspectorTrackingSeparator, .flexibleSpace, "tabs", .flexibleSpace, .toggleInspector]
            }
            func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
                switch id {
                case "export":
                    let i = NSToolbarItem(itemIdentifier: id)
                    i.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
                    return i
                case "tabs":
                    return NSToolbarItemGroup(itemIdentifier: id, titles: ["Edit", "Captions"], selectionMode: .selectOne, labels: nil, target: nil, action: nil)
                default: return nil
                }
            }
        }
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Recording"
        w.titlebarAppearsTransparent = true
        let content = NSViewController(); content.view = NSView(frame: CGRect(x: 0, y: 0, width: 700, height: 600))
        let inspector = NSViewController(); inspector.view = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let split = NSSplitViewController()
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        let item = NSSplitViewItem(inspectorWithViewController: inspector)
        item.minimumThickness = 300
        split.addSplitViewItem(item)
        w.contentViewController = split
        let d = D()
        let t = NSToolbar(identifier: "editor")
        t.delegate = d
        w.toolbar = t
        w.setContentSize(CGSize(width: 1000, height: 600))
        w.makeKeyAndOrderFront(nil)
        settle(w.contentView!)
        XCTAssertEqual(t.items.map(\.itemIdentifier).last, .toggleInspector)
        let strip = w.shownToolbarStrip!
        XCTAssertTrue(strip.floatsOverContent)
        XCTAssertEqual(strip.frame, CGRect(x: 0, y: 554, width: 1000, height: 46))
        // The inspector runs under the band; the content's safe area starts below it.
        XCTAssertEqual(inspector.view.safeAreaInsets.top, 46)
        let edge = split.splitView.position(ofDividerAt: 0) + split.splitView.dividerThickness
        let views = strip.subviews.filter { !$0.isHidden && !($0 is NSTextField) }
        let tabs = views.first { $0 is NSSegmentedControl }!
        let others = views.filter { !($0 is NSSegmentedControl) }.sorted { $0.frame.minX < $1.frame.minX }
        let export = others[0], toggle = others[1]
        XCTAssertLessThan(export.frame.maxX, edge)
        XCTAssertGreaterThan(export.frame.minX, edge - 60)
        XCTAssertEqual(tabs.frame.midX, edge + (1000 - edge) / 2, accuracy: 30)
        XCTAssertGreaterThan(toggle.frame.minX, tabs.frame.maxX)
        XCTAssertEqual(toggle.frame.maxX, 990, accuracy: 1)
        // The title leads the content's part.
        let title = strip.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Recording" }!
        XCTAssertEqual(title.frame.minX, 14)
        // Clicking the band's empty part over full-size content drags rather
        // than reaching the content.
        XCTAssertNil(w.toolbarHit(CGPoint(x: 300, y: 580)))
        XCTAssertTrue(w.toolbarHit(CGPoint(x: toggle.frame.midX, y: 577)) === toggle)
        // Collapsing the inspector puts its items at the end of the band.
        item.isCollapsed = true
        settle(w.contentView!)
        XCTAssertEqual(toggle.frame.maxX, 990, accuracy: 1)
    }

    /// Content that isn't full-size sits below the band; the frame holds both.
    func testToolbarBandSitsAboveRegularContent() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let d = ToolbarLog()
        let t = NSToolbar(identifier: "t")
        t.delegate = d
        w.toolbar = t
        w.setContentSize(CGSize(width: 600, height: 400))
        w.makeKeyAndOrderFront(nil)
        settle(w.contentView!)
        XCTAssertEqual(w.contentView!.frame.size, CGSize(width: 600, height: 400))
        XCTAssertEqual(w.contentView!.safeAreaInsets.top, 0)
        XCTAssertEqual(w.frame.height, 400 + 28 + 46)
        let strip = w.shownToolbarStrip!
        XCTAssertEqual(strip.frame, CGRect(x: 0, y: 400, width: 600, height: 46))
        XCTAssertFalse(strip.floatsOverContent)
        // The title shows in the band, not the titlebar row.
        w.title = "Doc"
        XCTAssertEqual(HeadlessBackend.titlebarShowsTitle[ObjectIdentifier(w.nativeWindow!)], false)
        w.toolbar?.isVisible = false
        XCTAssertEqual(HeadlessBackend.titlebarShowsTitle[ObjectIdentifier(w.nativeWindow!)], true)
        XCTAssertEqual(w.contentView!.frame.height, 446)
    }
}
