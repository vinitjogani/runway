// NSOutlineView: a table of a tree's expanded items, with disclosure
// triangles, indentation, ← and → to collapse and expand, group items and
// the sidebar (source-list) style.

import Foundation
import CoreGraphics
import RunwayCore

@preconcurrency @MainActor public protocol NSOutlineViewDataSource: NSTableViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any?
    func outlineView(_ outlineView: NSOutlineView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, byItem item: Any?)
    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor])
    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any?
    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any?
}
extension NSOutlineViewDataSource {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { 0 }
    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { fatalError("outlineView(_:child:ofItem:) isn't implemented") }
    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
    public func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? { nil }
    public func outlineView(_ outlineView: NSOutlineView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, byItem item: Any?) {}
    public func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {}
    public func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? { nil }
    public func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? { nil }
}

@preconcurrency @MainActor public protocol NSOutlineViewDelegate: NSTableViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView?
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView?
    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int)
    func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int)
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool
    func selectionShouldChange(in outlineView: NSOutlineView) -> Bool
    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool
    func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn)
    func outlineViewSelectionDidChange(_ notification: Notification)
    func outlineViewSelectionIsChanging(_ notification: Notification)
    func outlineViewItemWillExpand(_ notification: Notification)
    func outlineViewItemDidExpand(_ notification: Notification)
    func outlineViewItemWillCollapse(_ notification: Notification)
    func outlineViewItemDidCollapse(_ notification: Notification)
    func outlineViewColumnDidResize(_ notification: Notification)
}
extension NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? { nil }
    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { nil }
    public func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {}
    public func outlineView(_ outlineView: NSOutlineView, didRemove rowView: NSTableRowView, forRow row: Int) {}
    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { outlineView.rowHeight }
    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }
    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }
    public func selectionShouldChange(in outlineView: NSOutlineView) -> Bool { true }
    public func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet { proposedSelectionIndexes }
    public func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool { true }
    public func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { true }
    public func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }
    public func outlineView(_ outlineView: NSOutlineView, didClick tableColumn: NSTableColumn) {}
    public func outlineViewSelectionDidChange(_ notification: Notification) {}
    public func outlineViewSelectionIsChanging(_ notification: Notification) {}
    public func outlineViewItemWillExpand(_ notification: Notification) {}
    public func outlineViewItemDidExpand(_ notification: Notification) {}
    public func outlineViewItemWillCollapse(_ notification: Notification) {}
    public func outlineViewItemDidCollapse(_ notification: Notification) {}
    public func outlineViewColumnDidResize(_ notification: Notification) {}
}

@preconcurrency @MainActor
open class NSOutlineView: NSTableView {
    public static let itemWillExpandNotification = Notification.Name("NSOutlineViewItemWillExpandNotification")
    public static let itemDidExpandNotification = Notification.Name("NSOutlineViewItemDidExpandNotification")
    public static let itemWillCollapseNotification = Notification.Name("NSOutlineViewItemWillCollapseNotification")
    public static let itemDidCollapseNotification = Notification.Name("NSOutlineViewItemDidCollapseNotification")
    public static let disclosureButtonIdentifier = NSUserInterfaceItemIdentifier("NSOutlineViewDisclosureButtonKey")
    public static let showHideButtonIdentifier = NSUserInterfaceItemIdentifier("NSOutlineViewShowHideButtonKey")
    public static let dropOnItemIndex = -1

    open var outlineTableColumn: NSTableColumn? { didSet { reloadData() } }
    open var indentationPerLevel: CGFloat = 16 { didSet { reloadData() } }
    open var indentationMarkerFollowsCell = true
    open var autoresizesOutlineColumn = false
    open var autosaveExpandedItems = false
    open var stronglyReferencesItems = true

    private struct Row { let item: Any; let key: AnyHashable; let level: Int; let parent: AnyHashable?; let expandable: Bool; let group: Bool }
    private var rows: [Row] = []
    private var expanded: Set<AnyHashable> = []
    private var parents: [AnyHashable: Any] = [:]
    private var outlineDataSource: NSOutlineViewDataSource? { dataSource as? NSOutlineViewDataSource }
    private var outlineDelegate: NSOutlineViewDelegate? { delegate as? NSOutlineViewDelegate }

    public override init(frame frameRect: CGRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }

    /// How items are told apart: objects by identity, hashable values by value.
    static func key(_ item: Any?) -> AnyHashable {
        guard let item else { return AnyHashable("<root>") }
        if type(of: item) is AnyClass, !(item is NSObject) { return AnyHashable(ObjectIdentifier(item as AnyObject)) }
        if let h = item as? AnyHashable { return h }
        return AnyHashable(String(describing: item))
    }

    // MARK: The tree

    private func rebuild() {
        rows.removeAll(keepingCapacity: true)
        parents.removeAll(keepingCapacity: true)
        guard let ds = outlineDataSource else { return }
        func walk(_ parent: Any?, _ level: Int) {
            let pk = parent.map { Self.key($0) }
            let n = ds.outlineView(self, numberOfChildrenOfItem: parent)
            for i in 0..<n {
                let item = ds.outlineView(self, child: i, ofItem: parent)
                let k = Self.key(item)
                let expandable = ds.outlineView(self, isItemExpandable: item)
                let group = outlineDelegate?.outlineView(self, isGroupItem: item) ?? false
                rows.append(Row(item: item, key: k, level: level, parent: pk, expandable: expandable, group: group))
                if let parent { parents[k] = parent }
                if expandable, expanded.contains(k) { walk(item, level + 1) }
            }
        }
        walk(nil, 0)
    }

    override func dataRowCount() -> Int { rebuild(); return rows.count }
    override func dataIsGroupRow(_ row: Int) -> Bool { rows.indices.contains(row) && rows[row].group }
    override func dataHeight(ofRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return rowHeight }
        let h = outlineDelegate?.outlineView(self, heightOfRowByItem: rows[row].item) ?? rowHeight
        return h > 0 ? h : rowHeight
    }
    override func dataView(for column: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row].item
        if let v = outlineDelegate?.outlineView(self, viewFor: column, item: item) { return v }
        guard let value = outlineDataSource?.outlineView(self, objectValueFor: column, byItem: item) else { return nil }
        let id = NSUserInterfaceItemIdentifier("RunwayTextCell")
        let cell = (makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let c = NSTableCellView(frame: .zero)
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            c.addSubview(tf)
            c.textField = tf
            return c
        }()
        cell.objectValue = value
        cell.textField?.stringValue = (value as? String) ?? "\(value)"
        return cell
    }
    override func dataRowView(_ row: Int) -> NSTableRowView? {
        guard rows.indices.contains(row) else { return nil }
        return outlineDelegate?.outlineView(self, rowViewForItem: rows[row].item)
    }
    override func dataShouldSelect(_ row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        return outlineDelegate?.outlineView(self, shouldSelectItem: rows[row].item) ?? true
    }
    override func dataSelectionShouldChange() -> Bool { outlineDelegate?.selectionShouldChange(in: self) ?? true }
    override func dataProposedSelection(_ s: IndexSet) -> IndexSet {
        outlineDelegate?.outlineView(self, selectionIndexesForProposedSelection: s) ?? s
    }
    override func dataSelectionDidChange(_ n: Notification) {
        let on = Notification(name: Notification.Name("NSOutlineViewSelectionDidChangeNotification"), object: self)
        outlineDelegate?.outlineViewSelectionDidChange(on)
        NotificationCenter.default.post(on)
        super.dataSelectionDidChange(n)
    }
    override func dataDidAdd(_ rv: NSTableRowView, _ row: Int) { outlineDelegate?.outlineView(self, didAdd: rv, forRow: row); super.dataDidAdd(rv, row) }
    override func dataDidRemove(_ rv: NSTableRowView, _ row: Int) { outlineDelegate?.outlineView(self, didRemove: rv, forRow: row); super.dataDidRemove(rv, row) }

    var outlineColumnIndex: Int {
        if let c = outlineTableColumn, let i = tableColumns.firstIndex(where: { $0 === c }) { return i }
        return visibleColumnIndexes.first ?? 0
    }

    /// Indentation in the sidebar style doesn't count a group item's level.
    private func indentLevel(_ row: Int) -> Int {
        let r = rows[row]
        guard effectiveStyle == .sourceList else { return r.level }
        var level = r.level
        var p = r.parent
        while let pk = p {
            if let item = parents[r.key] ?? (rows.first { $0.key == pk }?.item), outlineDelegate?.outlineView(self, isGroupItem: item) ?? false { level -= 1; break }
            p = rows.first { $0.key == pk }?.parent
        }
        return max(0, level)
    }

    private var reservesDisclosureSpace: Bool { effectiveStyle != .sourceList }

    override func cellIndent(row: Int, column: Int) -> CGFloat {
        guard rows.indices.contains(row), column == outlineColumnIndex, !rows[row].group else { return 0 }
        return CGFloat(indentLevel(row)) * indentationPerLevel + (reservesDisclosureSpace ? 16 : 0)
    }

    /// The disclosure triangle's rect in a row.
    private func disclosureRect(_ row: Int) -> CGRect {
        let cell = frameOfCell(atColumn: outlineColumnIndex, row: row)
        let s: CGFloat = 14
        return CGRect(x: cell.minX - s - (reservesDisclosureSpace ? 2 : 1), y: ((rect(ofRow: row).height - s) / 2).rounded(), width: s, height: s)
    }

    override func decorate(_ rowView: NSTableRowView, row: Int) {
        guard rows.indices.contains(row), rows[row].expandable, !rows[row].group,
              outlineDelegate?.outlineView(self, shouldShowOutlineCellForItem: rows[row].item) ?? true else { return }
        let d = DisclosureTriangle(frame: disclosureRect(row))
        d.isExpanded = expanded.contains(rows[row].key)
        d.emphasized = rowView.interiorBackgroundStyle == .emphasized
        rowView.addSubview(d)
    }

    override func handlePointerDown(at p: CGPoint, row: Int) -> Bool {
        guard rows.indices.contains(row), rows[row].expandable, !rows[row].group else { return false }
        var r = disclosureRect(row)
        r.origin.y += rect(ofRow: row).minY
        guard r.insetBy(dx: -3, dy: -3).contains(p) else { return false }
        let item = rows[row].item
        if isItemExpanded(item) { animator().collapseItem(item) } else { animator().expandItem(item) }
        return true
    }

    override func handleExtraKey(_ k: KeyPress) -> Bool {
        let r = selectedRow
        guard rows.indices.contains(r) else { return false }
        let item = rows[r].item
        switch k.key {
        case "right":
            if rows[r].expandable, !isItemExpanded(item) { expandItem(item, expandChildren: k.option) }
            return true
        case "left":
            if rows[r].expandable, isItemExpanded(item) { collapseItem(item, collapseChildren: k.option) }
            else if let p = parent(forItem: item) {
                let pr = self.row(forItem: p)
                if pr >= 0 { selectRowIndexes(IndexSet(integer: pr), byExtendingSelection: false); scrollRowToVisible(pr) }
            }
            return true
        default:
            return false
        }
    }

    // MARK: Items

    open func item(atRow row: Int) -> Any? { rows.indices.contains(row) ? rows[row].item : nil }
    open func row(forItem item: Any?) -> Int {
        let k = Self.key(item)
        return rows.firstIndex { $0.key == k } ?? -1
    }
    open func parent(forItem item: Any?) -> Any? { parents[Self.key(item)] }
    open func level(forItem item: Any?) -> Int {
        let r = row(forItem: item)
        return r >= 0 ? rows[r].level : -1
    }
    open func level(forRow row: Int) -> Int { rows.indices.contains(row) ? rows[row].level : -1 }
    open func isExpandable(_ item: Any?) -> Bool {
        guard let item else { return true }
        return outlineDataSource?.outlineView(self, isItemExpandable: item) ?? false
    }
    open func isItemExpanded(_ item: Any?) -> Bool { item == nil || expanded.contains(Self.key(item)) }
    open func numberOfChildren(ofItem item: Any?) -> Int { outlineDataSource?.outlineView(self, numberOfChildrenOfItem: item) ?? 0 }
    open func child(_ index: Int, ofItem item: Any?) -> Any? { outlineDataSource?.outlineView(self, child: index, ofItem: item) }
    open func childIndex(forItem item: Any) -> Int {
        let p = parent(forItem: item)
        let k = Self.key(item)
        for i in 0..<numberOfChildren(ofItem: p) where Self.key(child(i, ofItem: p)) == k { return i }
        return -1
    }
    open func frameOfOutlineCell(atRow row: Int) -> CGRect { disclosureRect(row).offsetBy(dx: 0, dy: rect(ofRow: row).minY) }

    private func post(_ name: Notification.Name, _ item: Any, _ call: (NSOutlineViewDelegate?, Notification) -> Void) {
        let n = Notification(name: name, object: self, userInfo: ["NSObject": item])
        call(outlineDelegate, n)
        NotificationCenter.default.post(n)
    }

    open func expandItem(_ item: Any?, expandChildren: Bool) {
        guard let item else {
            for r in rows where r.level == 0 { expandItem(r.item, expandChildren: expandChildren) }
            return
        }
        let k = Self.key(item)
        guard isExpandable(item) else { return }
        if !expanded.contains(k) {
            guard outlineDelegate?.outlineView(self, shouldExpandItem: item) ?? true else { return }
            post(Self.itemWillExpandNotification, item) { $0?.outlineViewItemWillExpand($1) }
            let selected = selectedItems
            expanded.insert(k)
            refreshRows(keeping: selected)
            post(Self.itemDidExpandNotification, item) { $0?.outlineViewItemDidExpand($1) }
        }
        if expandChildren {
            for i in 0..<numberOfChildren(ofItem: item) { if let c = child(i, ofItem: item) { expandItem(c, expandChildren: true) } }
        }
    }
    open func expandItem(_ item: Any?) { expandItem(item, expandChildren: false) }

    open func collapseItem(_ item: Any?, collapseChildren: Bool) {
        guard let item else {
            for r in rows where r.level == 0 { collapseItem(r.item, collapseChildren: collapseChildren) }
            return
        }
        let k = Self.key(item)
        guard expanded.contains(k) else { return }
        guard outlineDelegate?.outlineView(self, shouldCollapseItem: item) ?? true else { return }
        post(Self.itemWillCollapseNotification, item) { $0?.outlineViewItemWillCollapse($1) }
        // A selection inside the collapsed item moves to the item, as in AppKit.
        let r0 = row(forItem: item)
        var selected = selectedItems
        let hiddenSelection = selectedRowIndexes.contains { $0 > r0 && isDescendant(rows[$0].key, of: k) }
        expanded.remove(k)
        if collapseChildren { collapseDescendants(of: item) }
        if hiddenSelection { selected = selected.filter { row(forItem: $0) >= 0 && !isDescendantKey(Self.key($0), of: k) } + [item] }
        refreshRows(keeping: selected)
        post(Self.itemDidCollapseNotification, item) { $0?.outlineViewItemDidCollapse($1) }
    }
    open func collapseItem(_ item: Any?) { collapseItem(item, collapseChildren: false) }

    private func collapseDescendants(of item: Any) {
        for i in 0..<numberOfChildren(ofItem: item) {
            guard let c = child(i, ofItem: item) else { continue }
            expanded.remove(Self.key(c))
            collapseDescendants(of: c)
        }
    }
    private func isDescendant(_ k: AnyHashable, of ancestor: AnyHashable) -> Bool { isDescendantKey(k, of: ancestor) }
    private func isDescendantKey(_ k: AnyHashable, of ancestor: AnyHashable) -> Bool {
        var p = parents[k].map { Self.key($0) }
        while let pk = p {
            if pk == ancestor { return true }
            p = parents[pk].map { Self.key($0) }
        }
        return false
    }

    private var selectedItems: [Any] { selectedRowIndexes.compactMap { item(atRow: $0) } }

    private func refreshRows(keeping selection: [Any]) {
        noteNumberOfRowsChanged()
        let rowsNow = IndexSet(selection.map { row(forItem: $0) }.filter { $0 >= 0 })
        if rowsNow != selectedRowIndexes { selectRowIndexes(rowsNow, byExtendingSelection: false) }
        reloadData(forRowIndexes: IndexSet(0..<numberOfRows), columnIndexes: IndexSet())
    }

    open override func reloadData() {
        let selected = selectedItems
        super.reloadData()
        let rowsNow = IndexSet(selected.map { row(forItem: $0) }.filter { $0 >= 0 })
        if rowsNow != selectedRowIndexes { selectRowIndexes(rowsNow, byExtendingSelection: false) }
    }

    open func reloadItem(_ item: Any?, reloadChildren: Bool) {
        if item == nil || reloadChildren { refreshRows(keeping: selectedItems); return }
        let r = row(forItem: item)
        if r >= 0 { reloadData(forRowIndexes: IndexSet(integer: r), columnIndexes: IndexSet()) }
    }
    open func reloadItem(_ item: Any?) { reloadItem(item, reloadChildren: false) }

    open func insertItems(at indexes: IndexSet, inParent parent: Any?, withAnimation options: NSTableView.AnimationOptions = []) {
        refreshRows(keeping: selectedItems)
    }
    open func removeItems(at indexes: IndexSet, inParent parent: Any?, withAnimation options: NSTableView.AnimationOptions = []) {
        let before = selectedRowIndexes.count
        refreshRows(keeping: selectedItems.filter { _ in true })
        if selectedRowIndexes.count != before { postSelectionChange() }
    }
    open func moveItem(at from: Int, inParent oldParent: Any?, to to: Int, inParent newParent: Any?) { refreshRows(keeping: selectedItems) }

    open func setDropItem(_ item: Any?, dropChildIndex index: Int) {}
}

/// The disclosure triangle beside expandable items.
@MainActor final class DisclosureTriangle: NSView {
    override var isFlipped: Bool { true }
    var isExpanded = false { didSet { update() } }
    var emphasized = false { didSet { update() } }
    private let image: NativeWidget

    override init(frame frameRect: CGRect) {
        image = makeNative(.image)
        super.init(frame: frameRect)
        onMain { update() }
    }
    required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }

    private func update() {
        var p = WidgetProps()
        p.image = .symbol(isExpanded ? "chevron.down" : "chevron.right")
        p.imagePointSize = 9
        p.imageTint = emphasized ? RGBA(1, 1, 1, 0.9) : NSColor.secondaryLabelColor.rgbaValue
        Runway.backend.update(image, props: p, events: WidgetEvents())
        layoutSubviews()
    }
    override func place() {
        placementDirty = false
        let s: CGFloat = 10
        placeChildren(below: [(image, CGRect(x: ((bounds.width - s) / 2).rounded(), y: ((bounds.height - s) / 2).rounded(), width: s, height: s))])
    }
    override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }
}
