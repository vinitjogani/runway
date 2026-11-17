// AppKit's standard controls on the headless backend: target/action and
// values, text field delegate traffic, table and outline data source /
// delegate call sequences, selection by real mouse events, stack and split
// view layout, scrolling, text storage and editing, popovers, toolbars and
// status items.

import XCTest
import RunwayCore
import RunwayObjC
@testable import AppKit

// MARK: Helpers

/// A target with actions, as the transpiler generates them.
final class Target: NSObject, SelectorDispatching {
    var fired: [String] = []
    var senders: [AnyObject] = []
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .perform(sel, args):
            guard ["clicked:", "changed:", "doubleClicked:"].contains(sel.name) else { return false }
            fired.append(sel.name)
            if let s = args.first.flatMap({ $0 }) as AnyObject? { senders.append(s) }
            return true
        case let .responds(sel): return ["clicked:", "changed:", "doubleClicked:"].contains(sel.name)
        default: return false
        }
    }
}

@MainActor
class ControlsTestCase: XCTestCase {
    var backend: HeadlessBackend!

    override func setUp() async throws {
        backend = HeadlessBackend()
        Runway.install(backend)
        AppKitRuntime.install()
        HeadlessBackend.popovers.removeAll()
        HeadlessBackend.statusItems.removeAll()
    }

    /// A window showing `view` as its content.
    func window(_ view: NSView, size: CGSize = CGSize(width: 600, height: 400)) -> NSWindow {
        let w = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        w.makeKeyAndOrderFront(nil)
        settle(view)
        return w
    }

    func settle(_ v: NSView) {
        for _ in 0..<3 {
            RunwayLayoutTree(v)
            ViewSystem.flush()
            backend.drain()
        }
    }

    /// A click at a point in `view`, through the window's event dispatch.
    func click(_ view: NSView, at p: CGPoint, count: Int = 1, flags: NSEvent.ModifierFlags = []) {
        guard let w = view.window else { return XCTFail("view not in a window") }
        let loc = view.convert(p, to: nil)
        for n in 1...count {
            w.sendEvent(NSEvent(type: .leftMouseDown, location: loc, modifierFlags: flags, timestamp: 0, window: w, clickCount: n, buttonNumber: 0, eventNumber: 0))
            w.sendEvent(NSEvent(type: .leftMouseUp, location: loc, modifierFlags: flags, timestamp: 0, window: w, clickCount: n, buttonNumber: 0, eventNumber: 0))
        }
    }

    func key(_ chars: String, to w: NSWindow, flags: NSEvent.ModifierFlags = []) {
        w.sendEvent(NSEvent(type: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, window: w,
                            characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0))
    }

    func headless(_ w: NativeWidget) -> HeadlessWidget { w as! HeadlessWidget }
}

// MARK: Controls

final class ControlTests: ControlsTestCase {
    func testButtonTargetActionThroughTheRuntime() {
        let t = Target()
        let b = NSButton(title: "Save", target: t, action: Selector("clicked:"))
        b.performClick(nil)
        XCTAssertEqual(t.fired, ["clicked:"])
        XCTAssertTrue(t.senders.first === b)
        // The native button's tap is the same click.
        headless(b.native).events.onTap?()
        XCTAssertEqual(t.fired.count, 2)
        b.isEnabled = false
        headless(b.native).events.onTap?()
        XCTAssertEqual(t.fired.count, 2, "disabled buttons don't act")
        XCTAssertFalse(headless(b.native).props.enabled)
    }

    func testButtonTitleReachesTheWidgetAndSizes() {
        let b = NSButton(title: "Cancel", target: nil, action: nil)
        XCTAssertEqual(headless(b.native).props.title, "Cancel")
        XCTAssertGreaterThan(b.frame.width, 50)
        XCTAssertEqual(b.frame.height, 22)
    }

    func testDefaultButtonKeyEquivalent() {
        let b = NSButton(title: "OK", target: nil, action: nil)
        b.keyEquivalent = "\r"
        XCTAssertTrue(headless(b.native).props.isDefault)
        XCTAssertTrue(headless(b.native).props.prominent)
        XCTAssertEqual(HeadlessBackend.record(b.native).keyEquivalent?.key, "return")
        b.keyEquivalent = "\u{1b}"
        XCTAssertTrue(headless(b.native).props.isCancel)
        XCTAssertEqual(HeadlessBackend.record(b.native).keyEquivalent?.key, "escape")
    }

    func testCheckboxTogglesAndMixedState() {
        let c = NSButton(checkboxWithTitle: "Sync", target: nil, action: nil)
        var count = 0
        c.handler = { _ in count += 1 }
        XCTAssertEqual(c.state, .off)
        headless(c.native).events.onToggle?(true)
        XCTAssertEqual(c.state, .on)
        XCTAssertEqual(c.integerValue, 1)
        c.allowsMixedState = true
        c.performClick(nil)
        XCTAssertEqual(c.state, .mixed)
        c.performClick(nil)
        XCTAssertEqual(c.state, .off)
        XCTAssertEqual(count, 3)
        XCTAssertEqual(headless(c.native).kind, .toggle(.checkbox))
    }

    func testRadioButtonsSharingAnActionAreAGroup() {
        let a = NSButton(radioButtonWithTitle: "A", target: nil, action: Selector("pick:"))
        let b = NSButton(radioButtonWithTitle: "B", target: nil, action: Selector("pick:"))
        let other = NSButton(radioButtonWithTitle: "C", target: nil, action: Selector("else:"))
        let stack = NSStackView(views: [a, b, other])
        _ = stack
        a.performClick(nil)
        other.performClick(nil)
        XCTAssertEqual([a.state, b.state, other.state], [.on, .off, .on])
        b.performClick(nil)
        XCTAssertEqual([a.state, b.state, other.state], [.off, .on, .on])
        XCTAssertTrue(HeadlessBackend.record(a.native).radio)
    }

    func testControlValuesConvert() {
        let s = NSSlider(value: 0.25, minValue: 0, maxValue: 1, target: nil, action: nil)
        XCTAssertEqual(s.doubleValue, 0.25)
        s.doubleValue = 4
        XCTAssertEqual(s.doubleValue, 1, "clamped to maxValue")
        XCTAssertEqual(headless(s.native).props.number, 1)
        let t = NSTextField(string: "42")
        XCTAssertEqual(t.integerValue, 42)
        XCTAssertEqual(t.doubleValue, 42)
        t.intValue = 7
        XCTAssertEqual(t.stringValue, "7")
    }

    func testSliderAndStepperSendActions() {
        let t = Target()
        let s = NSSlider(value: 0, minValue: 0, maxValue: 10, target: t, action: Selector("changed:"))
        headless(s.native).events.onNumber?(3)
        XCTAssertEqual(s.doubleValue, 3)
        XCTAssertEqual(t.fired, ["changed:"])
        s.numberOfTickMarks = 3
        s.allowsTickMarkValuesOnly = true
        headless(s.native).events.onNumber?(6.1)
        XCTAssertEqual(s.doubleValue, 5)

        let st = NSStepper(frame: .zero)
        st.maxValue = 3
        st.integerValue = 3
        st.step(up: true)
        XCTAssertEqual(st.integerValue, 0, "wraps")
        st.valueWraps = false
        st.step(up: false)
        XCTAssertEqual(st.integerValue, 0)
    }

    func testPopUpButtonItemsSelectionAndAction() {
        let t = Target()
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: ["One", "Two", "Three"])
        p.target = t
        p.action = Selector("changed:")
        XCTAssertEqual(p.indexOfSelectedItem, 0)
        XCTAssertEqual(headless(p.popupWidget).props.options, ["One", "Two", "Three"])
        headless(p.popupWidget).events.onSelect?(2)
        XCTAssertEqual(p.titleOfSelectedItem, "Three")
        XCTAssertEqual(p.selectedItem?.state, .on)
        XCTAssertEqual(t.fired, ["changed:"])
        p.selectItem(withTitle: "Two")
        XCTAssertEqual(headless(p.popupWidget).props.selected, 1)
        p.removeItem(at: 1)
        XCTAssertEqual(p.itemTitles, ["One", "Three"])

        let pull = NSPopUpButton(frame: .zero, pullsDown: true)
        pull.addItems(withTitles: ["Actions", "Rename", "Delete"])
        var ran: [String] = []
        pull.item(at: 2)?.handler = { ran.append($0.title) }
        XCTAssertEqual(headless(pull.popupWidget).kind, .menuButton)
        XCTAssertEqual(headless(pull.popupWidget).props.title, "Actions")
        headless(pull.popupWidget).events.menu[1].action?()
        XCTAssertEqual(ran, ["Delete"])
    }

    func testSegmentedControlModes() {
        let s = NSSegmentedControl(labels: ["A", "B", "C"], trackingMode: .selectOne, target: nil, action: nil)
        s.selectedSegment = 1
        XCTAssertEqual(s.selectedSegment, 1)
        s.setSelected(true, forSegment: 2)
        XCTAssertFalse(s.isSelected(forSegment: 1))
        let any = NSSegmentedControl(labels: ["Bold", "Italic"], trackingMode: .selectAny, target: nil, action: nil)
        any.setSelected(true, forSegment: 0)
        any.setSelected(true, forSegment: 1)
        XCTAssertTrue(any.isSelected(forSegment: 0) && any.isSelected(forSegment: 1))
    }

    func testProgressAnimatesOnlyWhileRunning() {
        let p = NSProgressIndicator(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        p.startAnimation(nil)
        XCTAssertEqual(HeadlessBackend.timers.count, 1)
        HeadlessBackend.fireTimers()
        XCTAssertEqual(HeadlessBackend.timers.count, 1)
        p.stopAnimation(nil)
        HeadlessBackend.fireTimers()
        XCTAssertEqual(HeadlessBackend.timers.count, 0, "no timer when stopped")
    }
}

// MARK: Text fields

final class TextFieldDelegateLog: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
    var log: [String] = []
    var handleCommands: Set<String> = []
    func controlTextDidBeginEditing(_ obj: Notification) { log.append("begin") }
    func controlTextDidChange(_ obj: Notification) { log.append("change:\((obj.object as? NSTextField)?.stringValue ?? "")") }
    func controlTextDidEndEditing(_ obj: Notification) { log.append("end") }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        log.append("command:\(sel.name)")
        return handleCommands.contains(sel.name)
    }
}

final class TextFieldTests: ControlsTestCase {
    func testLabelsAreLabels() {
        let l = NSTextField(labelWithString: "Name:")
        XCTAssertEqual(headless(l.native).kind, .text)
        XCTAssertEqual(headless(l.native).props.text?.plain, "Name:")
        XCTAssertGreaterThan(l.frame.width, 20)
        let f = NSTextField(string: "x")
        XCTAssertEqual(headless(f.native).kind, .textField(secure: false))
        XCTAssertEqual(f.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(headless(NSSecureTextField(string: "pw").native).kind, .textField(secure: true))
    }

    func testDelegateEditingSequenceAndCommands() {
        let f = NSTextField(string: "")
        let d = TextFieldDelegateLog()
        f.delegate = d
        let t = Target()
        f.target = t
        f.action = Selector("clicked:")
        headless(f.native).events.onText?("H")
        headless(f.native).events.onText?("Hi")
        XCTAssertEqual(f.stringValue, "Hi")
        // Return: the delegate's command first; unhandled, the field's action.
        XCTAssertFalse(HeadlessBackend.press(KeyPress(key: "return"), on: f.native))
        headless(f.native).events.onSubmit?()
        XCTAssertEqual(t.fired, ["clicked:"])
        // Escape handled by the delegate.
        d.handleCommands = ["cancelOperation:"]
        XCTAssertTrue(HeadlessBackend.press(KeyPress(key: "escape"), on: f.native))
        XCTAssertEqual(d.log, ["begin", "change:H", "change:Hi", "command:insertNewline:", "end", "command:cancelOperation:"])
        // Editing again, then focus leaves.
        headless(f.native).events.onText?("Hi!")
        HeadlessBackend.setTextFocus(f.native, false)
        XCTAssertEqual(d.log.suffix(3), ["begin", "change:Hi!", "end"])
    }

    func testSearchFieldSendsWhileTypingAndClearsOnEscape() {
        let s = NSSearchField(frame: .zero)
        let t = Target()
        s.target = t
        s.action = Selector("changed:")
        XCTAssertTrue(HeadlessBackend.record(s.native).search)
        XCTAssertEqual(s.placeholderString, "Search")
        headless(s.native).events.onText?("ru")
        XCTAssertEqual(t.fired, ["changed:"])
        XCTAssertTrue(HeadlessBackend.press(KeyPress(key: "escape"), on: s.native))
        XCTAssertEqual(s.stringValue, "")
        XCTAssertEqual(t.fired.count, 2)
    }

    func testTokenFieldValueIsTokens() {
        let t = NSTokenField(frame: .zero)
        t.objectValue = ["a", "b"]
        XCTAssertEqual(t.stringValue, "a, b")
        headless(t.native).events.onText?("x, y ,z")
        XCTAssertEqual(t.objectValue as? [String], ["x", "y", "z"])
    }

    func testComboBoxSelection() {
        let c = NSComboBox(frame: .zero)
        let d = TextFieldDelegateLog()
        c.delegate = d
        c.addItems(withObjectValues: ["Red", "Green"])
        c.selectItem(at: 1)
        XCTAssertEqual(c.stringValue, "Green")
        XCTAssertEqual(c.indexOfSelectedItem, 1)
        headless(c.native).events.onText?("Red")
        XCTAssertEqual(c.indexOfSelectedItem, 0)
    }
}

// MARK: Tables

final class TableLog: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var rows: [String]
    var log: [String] = []
    var made = 0
    var selectionChanges = 0
    var refuse: Set<Int> = []
    init(_ rows: [String]) { self.rows = rows }
    func numberOfRows(in tableView: NSTableView) -> Int { log.append("count"); return rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        log.append("view:\(row)")
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView { cell = reused } else {
            made += 1
            cell = NSTableCellView(frame: .zero)
            cell.identifier = id
            let tf = NSTextField(labelWithString: "")
            cell.addSubview(tf)
            cell.textField = tf
        }
        cell.textField?.stringValue = rows[row]
        return cell
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !refuse.contains(row) }
    func tableViewSelectionDidChange(_ notification: Notification) { selectionChanges += 1 }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
        log.append("sort:\(tableView.sortDescriptors.first?.ascending == true ? "asc" : "desc")")
    }
}

final class TableTests: ControlsTestCase {
    func makeTable(_ n: Int, height: CGFloat = 240) -> (NSScrollView, NSTableView, TableLog) {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: height))
        let table = NSTableView(frame: .zero)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        col.title = "Name"
        col.width = 200
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 24
        let data = TableLog((0..<n).map { "Row \($0)" })
        table.dataSource = data
        table.delegate = data
        scroll.documentView = table
        return (scroll, table, data)
    }

    func testOnlyRowsInViewAreMadeAndCellsAreReused() {
        let (scroll, table, data) = makeTable(1000)
        _ = window(scroll, size: CGSize(width: 300, height: 240))
        XCTAssertEqual(table.numberOfRows, 1000)
        XCTAssertEqual(table.frame.height, 24_000)
        let shown = table.subviews.compactMap { $0 as? NSTableRowView }.count
        XCTAssertGreaterThan(shown, 9)
        XCTAssertLessThan(shown, 40, "rows outside the view aren't made")
        XCTAssertEqual(data.made, shown)
        // Scrolling far reuses the cells rather than making new ones.
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 12_000))
        XCTAssertEqual(scroll.documentVisibleRect.minY, 12_000)
        XCTAssertNotNil(table.view(atColumn: 0, row: 505, makeIfNecessary: false))
        XCTAssertNil(table.view(atColumn: 0, row: 3, makeIfNecessary: false))
        // At most a view's worth either side is ever made.
        XCTAssertLessThanOrEqual(data.made, 2 + (240 + 2 * 240) / 24)
        // Reloading asks the data source again.
        data.log.removeAll()
        table.reloadData()
        XCTAssertEqual(data.log.first, "count")
        XCTAssertTrue(data.log.contains("view:505"))
    }

    func testSelectionByMouseAndKeys() {
        let (scroll, table, data) = makeTable(20)
        table.allowsMultipleSelection = true
        let w = window(scroll, size: CGSize(width: 300, height: 240))
        click(table, at: CGPoint(x: 50, y: 24 * 2 + 5))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 2))
        XCTAssertTrue(w.firstResponder === table)
        click(table, at: CGPoint(x: 50, y: 24 * 5 + 5), flags: .shift)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(2...5))
        click(table, at: CGPoint(x: 50, y: 24 * 3 + 5), flags: .command)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([2, 4, 5]))
        // The delegate can refuse a row.
        data.refuse = [7]
        click(table, at: CGPoint(x: 50, y: 24 * 7 + 5))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([2, 4, 5]))
        // Arrow keys move the selection.
        click(table, at: CGPoint(x: 50, y: 24 * 8 + 5))
        key(String(Character(UnicodeScalar(0xF701)!)), to: w)   // down arrow
        XCTAssertEqual(table.selectedRow, 9)
        XCTAssertEqual(data.selectionChanges, 5)
        // Selected rows draw emphasized and their labels turn white.
        let cell = table.view(atColumn: 0, row: 9, makeIfNecessary: false) as? NSTableCellView
        XCTAssertEqual(cell?.backgroundStyle, .emphasized)
        XCTAssertEqual(cell?.textField?.backgroundStyle, .emphasized)
    }

    func testActionAndDoubleAction() {
        let (scroll, table, _) = makeTable(5)
        let t = Target()
        table.target = t
        table.action = Selector("clicked:")
        table.doubleAction = Selector("doubleClicked:")
        _ = window(scroll)
        click(table, at: CGPoint(x: 20, y: 30), count: 2)
        XCTAssertEqual(t.fired, ["clicked:", "doubleClicked:"])
        XCTAssertEqual(table.clickedRow, 1)
    }

    func testHeaderSortsAndResizes() {
        let (scroll, table, data) = makeTable(5)
        table.headerView = NSTableHeaderView(frame: CGRect(x: 0, y: 0, width: 300, height: 28))
        table.headerView?.tableView = table
        table.tableColumns[0].sortDescriptorPrototype = NSSortDescriptor(keyPath: \NSTableColumn.title, ascending: true)
        _ = window(scroll)
        XCTAssertEqual(scroll.contentView.frame.minY, 28, "rows sit below the header")
        table.headerClicked(0)
        table.headerClicked(0)
        XCTAssertEqual(data.log.filter { $0.hasPrefix("sort") }, ["sort:asc", "sort:desc"])
        XCTAssertEqual(table.sortDescriptors.first?.ascending, false)
    }

    func testColumnsFitTheClipView() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let table = NSTableView(frame: .zero)
        for (id, w) in [("a", 200.0), ("b", 50.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.width = CGFloat(w)
            table.addTableColumn(c)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        scroll.documentView = table
        _ = window(scroll, size: CGSize(width: 400, height: 200))
        XCTAssertEqual(table.tableColumns[0].width, 200)
        XCTAssertEqual(table.tableColumns.map(\.width).reduce(0, +) + table.rowInset * 2, 400, accuracy: 1)
    }
}

// MARK: Outline views

final class Node {
    let name: String
    var children: [Node]
    init(_ name: String, _ children: [Node] = []) { self.name = name; self.children = children }
}

final class OutlineLog: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let roots: [Node]
    var log: [String] = []
    var vetoExpand: Set<String> = []
    init(_ roots: [Node]) { self.roots = roots }
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? roots[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as! Node).children.isEmpty) }
    func outlineView(_ o: NSOutlineView, objectValueFor c: NSTableColumn?, byItem item: Any?) -> Any? { (item as? Node)?.name }
    func outlineView(_ o: NSOutlineView, shouldExpandItem item: Any) -> Bool { !vetoExpand.contains((item as! Node).name) }
    func outlineViewItemWillExpand(_ n: Notification) { log.append("willExpand:\((n.userInfo?["NSObject"] as! Node).name)") }
    func outlineViewItemDidExpand(_ n: Notification) { log.append("didExpand:\((n.userInfo?["NSObject"] as! Node).name)") }
    func outlineViewItemDidCollapse(_ n: Notification) { log.append("didCollapse:\((n.userInfo?["NSObject"] as! Node).name)") }
    func outlineViewSelectionDidChange(_ n: Notification) { log.append("selection") }
}

final class OutlineTests: ControlsTestCase {
    func testExpandCollapseRowsAndLevels() {
        let a1 = Node("a1"), a = Node("a", [a1, Node("a2", [Node("a2x")])]), b = Node("b")
        let data = OutlineLog([a, b])
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let o = NSOutlineView(frame: .zero)
        o.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        o.headerView = nil
        o.dataSource = data
        o.delegate = data
        scroll.documentView = o
        _ = window(scroll)
        XCTAssertEqual(o.numberOfRows, 2)
        o.expandItem(a)
        XCTAssertEqual(o.numberOfRows, 4)
        XCTAssertTrue(o.item(atRow: 1) as? Node === a1)
        XCTAssertEqual(o.level(forRow: 1), 1)
        XCTAssertEqual(o.row(forItem: b), 3)
        XCTAssertTrue(o.parent(forItem: a1) as? Node === a)
        XCTAssertEqual(data.log, ["willExpand:a", "didExpand:a"])
        // Children indent past the disclosure triangle.
        XCTAssertGreaterThan(o.frameOfCell(atColumn: 0, row: 1).minX, o.frameOfCell(atColumn: 0, row: 0).minX)
        // A selection inside a collapsed item moves to the item.
        o.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        o.collapseItem(a)
        XCTAssertEqual(o.numberOfRows, 2)
        XCTAssertEqual(o.selectedRow, 0)
        // The delegate can refuse to expand; expandChildren opens the subtree.
        data.vetoExpand = ["a"]
        o.expandItem(a)
        XCTAssertFalse(o.isItemExpanded(a))
        data.vetoExpand = []
        o.expandItem(a, expandChildren: true)
        XCTAssertEqual(o.numberOfRows, 5)
    }

    func testDisclosureClickAndArrowKeys() {
        let a = Node("a", [Node("a1")]), b = Node("b")
        let data = OutlineLog([a, b])
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let o = NSOutlineView(frame: .zero)
        o.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        o.headerView = nil
        o.dataSource = data
        o.delegate = data
        scroll.documentView = o
        let w = window(scroll)
        let tri = o.frameOfOutlineCell(atRow: 0)
        click(o, at: CGPoint(x: tri.midX, y: tri.midY))
        XCTAssertTrue(o.isItemExpanded(a), "the triangle expands")
        XCTAssertEqual(o.selectedRow, -1, "and doesn't select")
        click(o, at: CGPoint(x: 150, y: 5))
        key(String(Character(UnicodeScalar(0xF702)!)), to: w)   // left arrow
        XCTAssertFalse(o.isItemExpanded(a))
        key(String(Character(UnicodeScalar(0xF703)!)), to: w)   // right arrow
        XCTAssertTrue(o.isItemExpanded(a))
    }
}

// MARK: Layout containers

final class LayoutTests: ControlsTestCase {
    func box(_ w: CGFloat, _ h: CGFloat) -> NSView {
        let v = NSView(frame: .zero)
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    func testHorizontalStack() {
        let a = box(40, 20), b = box(60, 30), c = box(10, 10)
        let s = NSStackView(views: [a, b, c])
        s.spacing = 5
        s.edgeInsets = NSEdgeInsets(top: 2, left: 3, bottom: 2, right: 3)
        XCTAssertEqual(s.fittingSize, CGSize(width: 3 + 40 + 5 + 60 + 5 + 10 + 3, height: 34))
        s.frame = CGRect(origin: .zero, size: s.fittingSize)
        RunwayLayoutTree(s)
        XCTAssertEqual(a.frame, CGRect(x: 3, y: 7, width: 40, height: 20))
        XCTAssertEqual(b.frame, CGRect(x: 48, y: 2, width: 60, height: 30))
        XCTAssertEqual(c.frame.minX, 113)
        // Custom spacing, then a hidden view detaches.
        s.setCustomSpacing(20, after: a)
        b.isHidden = true
        RunwayLayoutTree(s)
        XCTAssertEqual(c.frame.minX, 3 + 40 + 20)
    }

    func testVerticalStackAlignmentAndFill() {
        let label = NSTextField(labelWithString: "Title")
        let field = NSTextField(string: "")
        let s = NSStackView(views: [label, field])
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 6
        s.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        RunwayLayoutTree(s)
        XCTAssertEqual(label.frame.minX, 0)
        XCTAssertEqual(label.frame.minY, 0, "flipped: the first view at the top")
        XCTAssertEqual(field.frame.width, 200, "no intrinsic width: it takes the width")
        XCTAssertEqual(field.frame.minY, label.frame.maxY + 6)
        s.distribution = .fillEqually
        s.orientation = .horizontal
        RunwayLayoutTree(s)
        XCTAssertEqual(label.frame.width, field.frame.width, accuracy: 1)
    }

    func testSplitViewPositionsHoldingPriorityAndCollapse() {
        let split = NSSplitView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        split.isVertical = true
        split.dividerStyle = .thin
        let a = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 300)), b = NSView(frame: CGRect(x: 0, y: 0, width: 399, height: 300))
        split.addSubview(a)
        split.addSubview(b)
        RunwayLayoutTree(split)
        XCTAssertEqual(a.frame.width, 200)
        XCTAssertEqual(b.frame.minX, 201)
        split.setPosition(250, ofDividerAt: 0)
        XCTAssertEqual(a.frame.width, 250)
        XCTAssertEqual(b.frame.width, 349)
        // The sidebar holds; the other pane takes a window resize.
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setFrameSize(CGSize(width: 800, height: 300))
        XCTAssertEqual(a.frame.width, 250)
        XCTAssertEqual(b.frame.width, 549)
        // Dragging the divider through AppKit's events.
        _ = window(split, size: CGSize(width: 800, height: 300))
        let handle = split.subviews.first { $0 is DividerHandle }!
        let w = split.window!
        let down = handle.convert(CGPoint(x: 1, y: 100), to: nil)
        w.sendEvent(NSEvent(type: .leftMouseDown, location: down, modifierFlags: [], timestamp: 0, window: w, clickCount: 1, buttonNumber: 0, eventNumber: 0))
        w.sendEvent(NSEvent(type: .leftMouseDragged, location: CGPoint(x: down.x + 50, y: down.y), modifierFlags: [], timestamp: 0, window: w, buttonNumber: 0, eventNumber: 0))
        w.sendEvent(NSEvent(type: .leftMouseUp, location: CGPoint(x: down.x + 50, y: down.y), modifierFlags: [], timestamp: 0, window: w, clickCount: 1, buttonNumber: 0, eventNumber: 0))
        XCTAssertEqual(a.frame.width, 300, accuracy: 1)
        split.setCollapsed(a, true)
        XCTAssertTrue(split.isSubviewCollapsed(a))
        XCTAssertEqual(b.frame.width, 800)
    }

    func testSplitViewControllerSidebarToggle() {
        let svc = NSSplitViewController()
        let side = NSViewController(), main = NSViewController()
        side.view = NSView(frame: CGRect(x: 0, y: 0, width: 220, height: 400))
        main.view = NSView(frame: .zero)
        svc.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: side))
        svc.addSplitViewItem(NSSplitViewItem(viewController: main))
        svc.view.frame = CGRect(x: 0, y: 0, width: 900, height: 400)
        RunwayLayoutTree(svc.view)
        XCTAssertEqual(main.view.frame.width, 900 - 220 - 1)
        // The action reaches the controller through the runtime.
        _ = NSApp.sendAction(Selector("toggleSidebar:"), to: svc, from: nil)
        XCTAssertTrue(svc.splitViewItems[0].isCollapsed)
        XCTAssertEqual(main.view.frame.width, 900)
    }

    func testScrollViewDocumentAndPosition() {
        let s = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let doc = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 1000))
        s.documentView = doc
        XCTAssertTrue(doc.superview === s.contentView)
        XCTAssertTrue(doc.enclosingScrollView === s)
        var notified = 0
        let o = NotificationCenter.default.addObserver(forName: Notification.Name("NSViewBoundsDidChangeNotification"), object: s.contentView, queue: nil) { _ in notified += 1 }
        defer { NotificationCenter.default.removeObserver(o) }
        doc.scroll(CGPoint(x: 0, y: 300))
        XCTAssertEqual(s.documentVisibleRect.origin.y, 300)
        XCTAssertEqual(s.contentView.bounds.origin.y, 300)
        XCTAssertEqual(notified, 1)
        // The user scrolling (the native scroller) is reflected too.
        HeadlessBackend.scroll(s.native, to: CGPoint(x: 0, y: 500))
        XCTAssertEqual(s.documentVisibleRect.minY, 500)
        XCTAssertEqual(notified, 2)
        // Out of range positions clamp.
        s.contentView.scroll(to: CGPoint(x: 0, y: 5000))
        XCTAssertEqual(s.documentVisibleRect.minY, 900)
    }

    func testTabViewSelection() {
        let tabs = NSTabView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let one = NSTabViewItem(identifier: "one"), two = NSTabViewItem(identifier: "two")
        one.label = "One"; two.label = "Two"
        one.view = NSView(frame: .zero); two.view = NSView(frame: .zero)
        tabs.addTabViewItem(one)
        tabs.addTabViewItem(two)
        XCTAssertTrue(tabs.selectedTabViewItem === one)
        XCTAssertTrue(one.view?.superview === tabs)
        tabs.selectTabViewItem(withIdentifier: "two")
        XCTAssertTrue(two.view?.superview === tabs)
        XCTAssertNil(one.view?.superview)
        XCTAssertGreaterThan(two.view!.frame.minY, 10, "below the tabs")
    }
}

// MARK: Text views

final class TextViewLog: NSObject, NSTextViewDelegate {
    var log: [String] = []
    var refuse = false
    func textView(_ textView: NSTextView, shouldChangeTextIn r: NSRange, replacementString s: String?) -> Bool {
        log.append("should:\(r.location),\(r.length):\(s ?? "")")
        return !refuse
    }
    func textDidBeginEditing(_ n: Notification) { log.append("begin") }
    func textDidChange(_ n: Notification) { log.append("change") }
    func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool { log.append("command:\(sel.name)"); return sel.name == "insertTab:" }
}

final class TextViewTests: ControlsTestCase {
    func testStorageWithManyFontsReachesTheView() {
        let tv = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let ts = tv.textStorage!
        ts.append(NSAttributedString(string: "Bold ", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)]))
        ts.append(NSAttributedString(string: "plain ", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        ts.append(NSAttributedString(string: "blue", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemBlue,
                                                                   .underlineStyle: NSUnderlineStyle.single.rawValue, .paragraphStyle: p]))
        let runs = HeadlessBackend.record(tv.native).runs
        XCTAssertEqual(runs.map(\.string), ["Bold ", "plain ", "blue"])
        XCTAssertEqual(runs[0].font.weight, .bold)
        XCTAssertEqual(runs[0].font.size, 15)
        XCTAssertTrue(runs[2].underline)
        XCTAssertEqual(runs[2].paragraph?.alignment, .center)
        XCTAssertEqual(tv.string, "Bold plain blue")
        var effective = NSRange()
        XCTAssertEqual((ts.attribute(.font, at: 7, effectiveRange: &effective) as? NSFont)?.pointSize, 13)
        XCTAssertEqual(effective, NSRange(location: 5, length: 6))
        ts.setAttributes([.font: NSFont.systemFont(ofSize: 20)], range: NSRange(location: 0, length: 4))
        XCTAssertEqual(HeadlessBackend.record(tv.native).runs.first?.font.size, 20)
        XCTAssertEqual(ts.attributedSubstring(from: NSRange(location: 2, length: 5)).string, "ld pl")
    }

    func testTypingGoesThroughTheDelegateIntoTheStorage() {
        let tv = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        tv.string = "Hello"
        let d = TextViewLog()
        tv.delegate = d
        HeadlessBackend.record(tv.native).selection = 5..<5
        XCTAssertTrue(HeadlessBackend.type(" world", in: tv.native))
        XCTAssertEqual(tv.string, "Hello world")
        XCTAssertEqual(tv.textStorage?.string, "Hello world")
        XCTAssertEqual(d.log, ["should:5,0: world", "begin", "change"])
        d.refuse = true
        XCTAssertFalse(HeadlessBackend.type("!", in: tv.native))
        XCTAssertEqual(tv.string, "Hello world")
        // Commands go to the delegate first, then the view performs them (Return inserts a newline).
        d.refuse = false
        XCTAssertTrue(HeadlessBackend.press(KeyPress(key: "tab"), on: tv.native))
        XCTAssertTrue(HeadlessBackend.press(KeyPress(key: "return"), on: tv.native))
        XCTAssertEqual(d.log.suffix(4), ["command:insertTab:", "command:insertNewline:", "should:11,0:\n", "change"])
        XCTAssertEqual(tv.string, "Hello world\n")
        // Non-ASCII offsets: UTF-16 ranges map to scalars.
        tv.string = "😀ab"
        tv.setSelectedRange(NSRange(location: 2, length: 1))
        XCTAssertEqual(HeadlessBackend.record(tv.native).selection, 1..<2)
        XCTAssertEqual(tv.selectedRange, NSRange(location: 2, length: 1))
    }

    func testTextViewGrowsInItsScrollView() {
        let s = NSTextView.scrollableTextView()
        let tv = s.documentView as! NSTextView
        tv.string = (0..<50).map { "Line \($0)" }.joined(separator: "\n")
        tv.sizeToFitText()
        XCTAssertGreaterThan(tv.frame.height, 50 * 15)
        XCTAssertEqual(tv.frame.width, s.contentSize.width)
    }

    func testCopyPasteThroughSelectors() {
        let tv = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        tv.string = "copy me"
        tv.setSelectedRange(NSRange(location: 0, length: 4))
        _ = NSApp.sendAction(Selector("copy:"), to: tv, from: nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "copy")
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        _ = NSApp.sendAction(Selector("paste:"), to: tv, from: nil)
        XCTAssertEqual(tv.string, "copy mecopy")
    }
}

// MARK: TextKit: glyphs, the layout delegate, editing hooks, undo

/// Hides `*` (null glyphs), lays `@` out as 20 points of space, and gives
/// lines starting with `#` 30 points of spacing before, as editors that
/// show Markdown formatted do.
@MainActor final class MarkupLayout: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        let s = lm.textStorage!.mutableString
        var out = Array(UnsafeBufferPointer(start: props, count: glyphRange.length))
        var changed = false
        for k in 0..<glyphRange.length {
            switch s.character(at: charIndexes[k]) {
            case 42: out[k] = .null; changed = true
            case 64: out[k] = .controlCharacter; changed = true
            default: break
            }
        }
        guard changed else { return 0 }
        out.withUnsafeBufferPointer { lm.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange) }
        return glyphRange.length
    }
    func layoutManager(_ lm: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        lm.textStorage!.mutableString.character(at: charIndex) == 64 ? .whitespace : action
    }
    func layoutManager(_ lm: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: 20, height: 0)
    }
    func layoutManager(_ lm: NSLayoutManager, paragraphSpacingBeforeGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        lm.textStorage!.mutableString.character(at: glyphIndex) == 35 ? 30 : 0
    }
}

/// Logs the NSTextView methods editors override.
final class HookedTextView: NSTextView {
    var log: [String] = []
    override func insertText(_ s: Any, replacementRange: NSRange) { log.append("insert:\(s)"); super.insertText(s, replacementRange: replacementRange) }
    override func insertNewline(_ sender: Any?) { log.append("newline"); super.insertNewline(sender) }
    override func insertTab(_ sender: Any?) { log.append("tab") }
    override func deleteBackward(_ sender: Any?) { log.append("deleteBackward"); super.deleteBackward(sender) }
    override func doCommand(by selector: Selector) { log.append("command:\(selector.name)"); super.doCommand(by: selector) }
    override func shouldChangeText(in r: NSRange, replacementString s: String?) -> Bool {
        log.append("should:\(r.location),\(r.length)")
        return super.shouldChangeText(in: r, replacementString: s)
    }
    override func didChangeText() { log.append("did"); super.didChangeText() }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let r = ranges.first!.rangeValue
        log.append("select:\(r.location),\(r.length)")
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }
    override func mouseDown(with event: NSEvent) { log.append("mouseDown"); super.mouseDown(with: event) }
}

final class TextKitTests: ControlsTestCase {
    func testLayoutDelegateGlyphsAndSpacingReachTheView() {
        let storage = NSTextStorage()
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: 300, height: 1e7))
        lm.addTextContainer(tc)
        let d = MarkupLayout()
        lm.delegate = d
        let tv = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), textContainer: tc)
        tv.string = "a **b** @c\n# Head"
        var runs = HeadlessBackend.record(tv.native).runs
        XCTAssertEqual(runs.map(\.string).joined(), tv.string, "the text is unchanged")
        XCTAssertEqual(runs.filter(\.hidden).map(\.string).joined(), "****")
        XCTAssertEqual(runs.first { $0.string == "@" }?.spacerWidth, 20)
        XCTAssertEqual(lm.propertyForGlyph(at: 2), .null)
        XCTAssertEqual(lm.propertyForGlyph(at: 8), .controlCharacter)
        XCTAssertEqual(runs.first { $0.string.contains("Head") }?.paragraph?.paragraphSpacingBefore, 30)
        XCTAssertEqual(runs.first?.paragraph?.paragraphSpacingBefore, 0)
        // An edit is laid out again: a typed `*` is hidden, the rest kept.
        tv.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 1), with: "*")
        runs = HeadlessBackend.record(tv.native).runs
        XCTAssertEqual(runs.map(\.string).joined(), "* **b** @c\n# Head")
        XCTAssertTrue(runs.first!.hidden)
        XCTAssertEqual(runs.filter(\.hidden).map(\.string).joined(), "*****")
    }

    func testAttributesAndTemporaryAttributesBecomeRuns() {
        let tv = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.25
        p.headIndent = 24
        tv.textStorage!.setAttributedString(NSAttributedString(string: "one two", attributes: [.font: NSFont.systemFont(ofSize: 15.5), .paragraphStyle: p]))
        tv.textStorage!.addAttributes([.strikethroughStyle: 1, .strikethroughColor: NSColor.red], range: NSRange(location: 4, length: 3))
        var runs = HeadlessBackend.record(tv.native).runs
        XCTAssertEqual(runs.first?.paragraph?.lineHeightMultiple, 1.25)
        XCTAssertEqual(runs.first?.paragraph?.headIndent, 24)
        XCTAssertEqual(runs.first?.font.size, 15.5)
        XCTAssertEqual(runs.last?.strikethroughColor, NSColor.red.rgbaValue)
        // Temporary attributes show over the storage's, without changing it.
        tv.layoutManager!.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: NSRange(location: 0, length: 3))
        backend.drain()
        runs = HeadlessBackend.record(tv.native).runs
        XCTAssertEqual(runs.first { $0.string == "one" }?.underline, true)
        XCTAssertNil(tv.textStorage!.attribute(.underlineStyle, at: 0, effectiveRange: nil))
        tv.layoutManager!.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: 7))
        backend.drain()
        XCTAssertFalse(HeadlessBackend.record(tv.native).runs.contains { $0.underline })
    }

    func testLongestEffectiveRangeJoinsRunsWithTheSameValue() {
        let ts = NSTextStorage(string: "abcdef", attributes: [.foregroundColor: NSColor.red])
        ts.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13), range: NSRange(location: 2, length: 2))
        var r = NSRange()
        XCTAssertNotNil(ts.attribute(.foregroundColor, at: 3, longestEffectiveRange: &r, in: NSRange(location: 0, length: 6)))
        XCTAssertEqual(r, NSRange(location: 0, length: 6))
        _ = ts.attribute(.foregroundColor, at: 3, effectiveRange: &r)
        XCTAssertEqual(r, NSRange(location: 2, length: 2), "the effective range is the run")
        var ranges: [NSRange] = []
        ts.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 6), options: []) { _, r, _ in ranges.append(r) }
        XCTAssertEqual(ranges, [NSRange(location: 0, length: 6)])
    }

    func testKeysAndTypingGoThroughTheViewsOverridableMethods() {
        let tv = HookedTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let w = window(tv)
        XCTAssertTrue(w.makeFirstResponder(tv))
        tv.log = []
        // Typed text (the input method's commit): insertText, through shouldChangeText.
        XCTAssertTrue(HeadlessBackend.type("a", in: tv.native))
        XCTAssertEqual(tv.string, "a")
        XCTAssertEqual(Array(tv.log.prefix(2)), ["select:0,0", "insert:a"])
        XCTAssertTrue(tv.log.contains("should:0,0"))
        XCTAssertEqual(tv.log.last, "did")
        // Keys with commands come through the responder chain: keyDown → doCommand(by:) → the action.
        func key(_ name: String, _ chars: String) -> Bool {
            var raw = RawEvent(kind: .keyDown)
            raw.keyName = name
            raw.characters = chars
            raw.charactersIgnoringModifiers = chars
            return w.handleRaw(raw)
        }
        tv.log = []
        XCTAssertTrue(key("Return", "\r"))
        XCTAssertEqual(Array(tv.log.prefix(3)), ["command:insertNewline:", "newline", "insert:\n"])
        XCTAssertEqual(tv.string, "a\n")
        tv.log = []
        XCTAssertTrue(key("Tab", "\t"))
        XCTAssertEqual(tv.log, ["command:insertTab:", "tab"], "an override that doesn't call super inserts nothing")
        XCTAssertTrue(key("BackSpace", "\u{7f}"))
        XCTAssertTrue(tv.log.contains("deleteBackward"))
        XCTAssertEqual(tv.string, "a")
        // Plain characters are left to the input method.
        XCTAssertFalse(key("b", "b"))
    }

    func testTypingIsOneUndoStepAndUndoRestoresTheText() {
        let tv = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        for c in "abc" { XCTAssertTrue(HeadlessBackend.type(String(c), in: tv.native)) }
        XCTAssertEqual(tv.string, "abc")
        let um = tv.undoManager!
        XCTAssertTrue(um.canUndo)
        um.undo()
        XCTAssertEqual(tv.string, "", "typing coalesces into one change")
        um.redo()
        XCTAssertEqual(tv.string, "abc")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.breakUndoCoalescing()
        XCTAssertTrue(HeadlessBackend.type("d", in: tv.native))
        tv.deleteBackward(nil)
        tv.deleteBackward(nil)
        XCTAssertEqual(tv.string, "ab")
        um.undo()
        XCTAssertEqual(tv.string, "abc", "Backspaces after typing undo with it")
        // Edits made through shouldChangeText / didChangeText undo too.
        let r = NSRange(location: 0, length: 1)
        XCTAssertTrue(tv.shouldChangeText(in: r, replacementString: "X"))
        tv.textStorage!.replaceCharacters(in: r, with: "X")
        tv.didChangeText()
        XCTAssertEqual(tv.string, "Xbc")
        um.undo()
        XCTAssertEqual(tv.string, "abc")
    }

    func testSelectionChangesGoThroughSetSelectedRanges() {
        let tv = HookedTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        tv.string = "hello world"
        tv.log = []
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.moveRight(nil)
        tv.moveToEndOfLineAndModifySelection(nil)
        XCTAssertEqual(tv.log.filter { $0.hasPrefix("select") }, ["select:6,0", "select:7,0", "select:7,4"])
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 7, length: 4))
        XCTAssertEqual(HeadlessBackend.record(tv.native).selection, 7..<11)
    }

    func testCopyUsesTheWritableTypesAndPasteTheReadableOnes() {
        final class Pasting: NSTextView {
            var read: [NSPasteboard.PasteboardType] = []
            override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.html, .string] }
            override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
                read.append(type)
                return super.readSelection(from: pboard, type: type)
            }
        }
        let tv = Pasting(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        tv.string = "copy me"
        tv.setSelectedRange(NSRange(location: 5, length: 2))
        tv.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "me")
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.paste(nil)
        XCTAssertEqual(tv.read, [.string])
        XCTAssertEqual(tv.string, "mecopy me")
    }

    func testBorderlessTextFieldShowsNoBezel() {
        let f = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertTrue((f.native as! HeadlessWidget).props.bordered, "a new field is bezeled")
        f.isBordered = false
        f.drawsBackground = false
        f.font = .systemFont(ofSize: 28, weight: .semibold)
        XCTAssertFalse((f.native as! HeadlessWidget).props.bordered, "AppKit has one border setting: none")
        XCTAssertEqual((f.native as! HeadlessWidget).props.text?.runs.first?.font.size, 28)
        f.isBezeled = true
        XCTAssertTrue((f.native as! HeadlessWidget).props.bordered)
    }
}

// MARK: Popovers, toolbars, status items

final class PopoverLog: NSObject, NSPopoverDelegate {
    var log: [String] = []
    func popoverWillShow(_ n: Notification) { log.append("willShow") }
    func popoverDidShow(_ n: Notification) { log.append("didShow") }
    func popoverDidClose(_ n: Notification) { log.append("didClose") }
}

final class ToolbarLog: NSObject, NSToolbarDelegate {
    var asked: [String] = []
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [.toggleSidebar, .flexibleSpace, "add"] }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        asked.append(id.rawValue)
        guard id == "add" else { return nil }
        let i = NSToolbarItem(itemIdentifier: id)
        i.label = "Add"
        i.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        return i
    }
}

final class ChromeTests: ControlsTestCase {
    func testPopoverShowsAndCloses() {
        let anchor = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        _ = window(anchor)
        let p = NSPopover()
        let d = PopoverLog()
        p.delegate = d
        let vc = NSViewController()
        vc.view = NSView(frame: CGRect(x: 0, y: 0, width: 180, height: 90))
        p.contentViewController = vc
        p.behavior = .transient
        p.show(relativeTo: CGRect(x: 10, y: 10, width: 20, height: 20), of: anchor, preferredEdge: .minY)
        XCTAssertTrue(p.isShown)
        let shown = HeadlessBackend.popovers.last!
        XCTAssertEqual(shown.size, CGSize(width: 180, height: 90))
        XCTAssertEqual(shown.edge, .bottom)
        shown.dismiss()   // a click outside
        XCTAssertFalse(p.isShown)
        XCTAssertEqual(d.log, ["willShow", "didShow", "didClose"])
        // Presenting a controller as a popover goes through NSPopover too.
        let host = NSViewController()
        host.view = anchor
        host.present(vc, asPopoverRelativeTo: .zero, of: anchor, preferredEdge: .maxY, behavior: NSPopover.Behavior.transient.rawValue)
        XCTAssertEqual(HeadlessBackend.popovers.last?.edge, .top)
    }

    func testToolbarItemsAndTitlebarStrip() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let d = ToolbarLog()
        let t = NSToolbar(identifier: "t")
        t.delegate = d
        w.toolbar = t
        XCTAssertEqual(t.items.map(\.itemIdentifier), [.toggleSidebar, .flexibleSpace, "add"])
        w.makeKeyAndOrderFront(nil)
        XCTAssertNotNil(w.shownToolbarStrip)
        XCTAssertTrue(w.toolbar === t)
        var added = 0
        t.items[2].handler = { _ in added += 1 }
        t.items[2].perform(sender: nil)
        XCTAssertEqual(added, 1)
    }

    func testStatusItemRegistersWithItsMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
        item.button?.toolTip = "Power"
        let menu = NSMenu(title: "")
        var ran: [String] = []
        let open = menu.addItem(withTitle: "Open", action: nil, keyEquivalent: "")
        open.handler = { ran.append($0.title) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: nil, keyEquivalent: "q")
        item.menu = menu
        backend.drain()
        let tray = HeadlessBackend.statusItems.last!
        XCTAssertEqual(tray.spec.symbol, "bolt")
        XCTAssertTrue(item.isShownInTray)
        let specs = tray.menu()
        XCTAssertEqual(specs.map(\.title), ["Open", "", "Quit"])
        XCTAssertTrue(specs[1].isSeparator)
        specs[0].action?()
        XCTAssertEqual(ran, ["Open"])
        // Without a menu, clicking the tray icon sends the button's action.
        item.menu = nil
        var clicked = 0
        item.button?.handler = { _ in clicked += 1 }
        tray.activate()
        XCTAssertEqual(clicked, 1)
        NSStatusBar.system.removeStatusItem(item)
        XCTAssertTrue(tray.removed)
    }
}
