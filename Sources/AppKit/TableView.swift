// View-based NSTableView: rows of NSTableRowView holding cell views the
// delegate makes (reused through `makeView(withIdentifier:owner:)`), only
// for the rows in view; columns with a header (sorting, resizing),
// selection with the Mac's click, ⌘-click, ⇧-click and arrow keys,
// actions and double actions, the inset, full-width, plain and source-list
// styles. Rows, selections and the header are drawn the way AppKit draws
// them; the cells are whatever views the delegate returns.

import Foundation
import CoreGraphics
import RunwayCore

/// Whether two sort descriptors sort by the same thing (key paths off
/// Apple platforms, where Foundation has no key-value coding).
func sameSortKey(_ a: NSSortDescriptor, _ b: NSSortDescriptor) -> Bool {
    if a === b { return true }
    return a.keyPath == b.keyPath
}

// MARK: Protocols

@preconcurrency @MainActor public protocol NSTableViewDataSource: AnyObject {
    func numberOfRows(in tableView: NSTableView) -> Int
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any?
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int)
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor])
    // Dragging rows.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting?
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet)
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation)
    func tableView(_ tableView: NSTableView, updateDraggingItemsForDrag draggingInfo: NSDraggingInfo)
}
extension NSTableView {
    /// Where a drop lands relative to a row.
    public enum DropOperation: UInt, Sendable { case on = 0, above }
}
extension NSTableViewDataSource {
    public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { nil }
    public func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation { [] }
    public func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool { false }
    public func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {}
    public func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {}
    public func tableView(_ tableView: NSTableView, updateDraggingItemsForDrag draggingInfo: NSDraggingInfo) {}
    public func numberOfRows(in tableView: NSTableView) -> Int { 0 }
    public func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { nil }
    public func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {}
    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {}
}

@preconcurrency @MainActor public protocol NSTableViewDelegate: NSControlTextEditingDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView?
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int)
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int)
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool
    func selectionShouldChange(in tableView: NSTableView) -> Bool
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet
    func tableView(_ tableView: NSTableView, shouldSelect tableColumn: NSTableColumn?) -> Bool
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn)
    func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn)
    func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool
    func tableViewSelectionDidChange(_ notification: Notification)
    func tableViewSelectionIsChanging(_ notification: Notification)
    func tableViewColumnDidResize(_ notification: Notification)
    func tableViewColumnDidMove(_ notification: Notification)
}
extension NSTableViewDelegate {
    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }
    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { nil }
    public func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {}
    public func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {}
    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { tableView.rowHeight }
    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }
    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    public func selectionShouldChange(in tableView: NSTableView) -> Bool { true }
    public func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet { proposedSelectionIndexes }
    public func tableView(_ tableView: NSTableView, shouldSelect tableColumn: NSTableColumn?) -> Bool { false }
    public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {}
    public func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {}
    public func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat { tableView.tableColumns[column].width }
    public func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool { true }
    public func tableViewSelectionDidChange(_ notification: Notification) {}
    public func tableViewSelectionIsChanging(_ notification: Notification) {}
    public func tableViewColumnDidResize(_ notification: Notification) {}
    public func tableViewColumnDidMove(_ notification: Notification) {}
}

extension NSView {
    public enum BackgroundStyle: Int, Sendable { case normal = 0, emphasized, raised, lowered }
}

extension NSTableView {
    public typealias Style = NSTableViewStyle
    public typealias SelectionHighlightStyle = NSTableViewSelectionHighlightStyle
}
public enum NSTableViewStyle: Int, Sendable { case automatic = 0, fullWidth, inset, sourceList, plain }
public enum NSTableViewSelectionHighlightStyle: Int, Sendable { case none = -1, regular = 0, sourceList = 1 }

// MARK: Columns

@preconcurrency @MainActor
open class NSTableColumn: NSObject {
    public struct ResizingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let autoresizingMask = ResizingOptions(rawValue: 1)
        public static let userResizingMask = ResizingOptions(rawValue: 2)
    }
    open var identifier: NSUserInterfaceItemIdentifier
    open weak var tableView: NSTableView?
    open var title: String {
        get { headerCell.stringValue }
        set { headerCell.stringValue = newValue; tableView?.headerView?.refresh() }
    }
    open var headerCell = NSTableHeaderCell(textCell: "")
    open var headerToolTip: String?
    open var width: CGFloat = 100 { didSet { width = max(minWidth, min(maxWidth, width)); if width != oldValue { tableView?.columnsChanged() } } }
    open var minWidth: CGFloat = 10
    open var maxWidth: CGFloat = 100_000
    open var resizingMask: ResizingOptions = [.autoresizingMask, .userResizingMask]
    open var isHidden = false { didSet { tableView?.columnsChanged() } }
    open var isEditable = true
    open var sortDescriptorPrototype: NSSortDescriptor?
    open var dataCell: Any?

    public init(identifier: NSUserInterfaceItemIdentifier) { self.identifier = identifier; super.init() }
    public convenience init(identifier: String) { self.init(identifier: NSUserInterfaceItemIdentifier(identifier)) }
    open func sizeToFit() {
        let t = LabelWidget()
        t.set(title, font: .systemFont(ofSize: 11))
        width = t.size().width + 24
    }
}

@preconcurrency @MainActor open class NSTableHeaderCell: NSTextFieldCell {}

// MARK: Header

/// Column titles above the rows, with sort indicators and resizing.
@preconcurrency @MainActor
open class NSTableHeaderView: NSView {
    open override var isFlipped: Bool { true }
    // AppKit's event dispatch (when the backend reports raw input).
    open override func mouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.mouseDown(with: e) } }
    open override func mouseDragged(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .dragged)) }
    open override func mouseUp(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .up)) }
    open override func mouseMoved(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .moved)) }
    open override func rightMouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.rightMouseDown(with: e) } }

    open weak var tableView: NSTableView?
    open private(set) var resizedColumn = -1
    open private(set) var draggedColumn = -1
    open var draggedDistance: CGFloat = 0
    var scrollOffsetX: CGFloat = 0 { didSet { if scrollOffsetX != oldValue { refresh() } } }
    private var events: NativeWidget!
    private let backdrop = DrawnLayer()
    private var labels: [LabelWidget] = []
    private var indicators: [NativeWidget] = []
    private var resizing: (column: Int, startX: CGFloat, startWidth: CGFloat)?
    private var pressedColumn = -1

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain {
            events = makeEventWidget(focusable: false, pointer: { [weak self] e in self?.pointer(e) ?? false })
            if frame.height == 0 { frame.size.height = 28 }
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        onMain {
            events = makeEventWidget(focusable: false, pointer: { [weak self] e in self?.pointer(e) ?? false })
            if frame.height == 0 { frame.size.height = 28 }
        }
        IBDecoding.leave(self, coder)
    }

    open func headerRect(ofColumn column: Int) -> CGRect {
        guard let t = tableView else { return .zero }
        let r = t.rect(ofColumn: column)
        return CGRect(x: r.minX - scrollOffsetX, y: 0, width: r.width, height: bounds.height)
    }
    open func column(at point: CGPoint) -> Int {
        guard let t = tableView else { return -1 }
        return t.column(at: CGPoint(x: point.x + scrollOffsetX, y: 0))
    }

    func refresh() {
        guard let t = tableView else { return }
        let cols = t.visibleColumnIndexes
        while labels.count < cols.count { labels.append(LabelWidget()) }
        var cmds: [DrawCommand] = [.fill(.rect(bounds), .color(NSColor.controlBackgroundColor.rgbaValue)),
                                   .fill(.rect(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)), .color(NSColor.separatorColor.rgbaValue))]
        var placed: [(NativeWidget, CGRect)] = []
        var ind: [NativeWidget] = []
        for (n, i) in cols.enumerated() {
            let col = t.tableColumns[i]
            let r = headerRect(ofColumn: i)
            if pressedColumn == i { cmds.append(.fill(.rect(r), .color(NSColor.quaternaryLabelColor.rgbaValue))) }
            if n < cols.count - 1 || t.effectiveStyle == .fullWidth {
                cmds.append(.fill(.rect(CGRect(x: r.maxX - 1, y: 5, width: 1, height: bounds.height - 10)), .color(NSColor.separatorColor.rgbaValue)))
            }
            let sorted = t.sortDescriptors.first.flatMap { d in col.sortDescriptorPrototype.map { sameSortKey($0, d) } == true ? d : nil }
            let pad: CGFloat = n == 0 && t.effectiveStyle == .inset ? 4 : 6
            let label = labels[n]
            label.set(col.title, font: .systemFont(ofSize: 11, weight: sorted != nil ? .bold : .regular), color: .headerTextColor,
                      alignment: (col.headerCell.alignment == .right ? .trailing : col.headerCell.alignment == .center ? .center : .leading))
            let lh = label.size().height
            let indW: CGFloat = sorted != nil ? 14 : 0
            placed.append((label.widget, CGRect(x: r.minX + pad, y: ((bounds.height - lh) / 2).rounded(), width: max(0, r.width - pad * 2 - indW), height: lh)))
            if let s = sorted {
                let w = indicators.count > ind.count ? indicators[ind.count] : Runway.backend.makeWidget(.image)
                var p = WidgetProps()
                p.image = .symbol(s.ascending ? "chevron.up" : "chevron.down")
                p.imagePointSize = 9
                p.imageTint = NSColor.secondaryLabelColor.rgbaValue
                Runway.backend.update(w, props: p, events: WidgetEvents())
                ind.append(w)
                placed.append((w, CGRect(x: r.maxX - pad - 11, y: ((bounds.height - 11) / 2).rounded(), width: 11, height: 11)))
            }
        }
        indicators = ind
        backdrop.draw(cmds)
        Runway.backend.setChildren(events, [(backdrop.widget, bounds)] + placed, contentSize: bounds.size)
        placeChildren(below: [(events, bounds)])
    }

    override func place() {
        placementDirty = false; placeChildren(below: [(events, bounds)]) }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); refresh() }

    /// The column boundary near x, for resizing.
    private func boundary(near x: CGFloat) -> Int? {
        guard let t = tableView, t.allowsColumnResizing else { return nil }
        for i in t.visibleColumnIndexes where t.tableColumns[i].resizingMask.contains(.userResizingMask) {
            if abs(headerRect(ofColumn: i).maxX - x) <= 4 { return i }
        }
        return nil
    }

    private func pointer(_ e: PointerEvent) -> Bool {
        guard let t = tableView else { return false }
        switch e.kind {
        case .moved:
            Runway.appKit?.setCursor(events, boundary(near: e.location.x) != nil ? .resizeLeftRight : .arrow)
        case .down:
            if let c = boundary(near: e.location.x) {
                resizing = (c, e.location.x, t.tableColumns[c].width)
                resizedColumn = c
            } else {
                pressedColumn = column(at: e.location)
                if pressedColumn >= 0 { t.delegate?.tableView(t, mouseDownInHeaderOf: t.tableColumns[pressedColumn]) }
                refresh()
            }
        case .dragged:
            if let r = resizing {
                t.tableColumns[r.column].width = r.startWidth + e.location.x - r.startX
                t.postColumnResize(t.tableColumns[r.column])
            }
        case .up:
            if resizing != nil {
                resizing = nil
                resizedColumn = -1
            } else if pressedColumn >= 0 {
                let c = pressedColumn
                pressedColumn = -1
                if column(at: e.location) == c { t.headerClicked(c) }
                refresh()
            }
        default: return false
        }
        return true
    }
}

// MARK: Row and cell views

/// A row: its selection and background, drawn as AppKit draws them, under
/// its cell views.
@preconcurrency @MainActor
open class NSTableRowView: NSView {
    open override var isFlipped: Bool { true }
    open var isSelected = false { didSet { if isSelected != oldValue { selectionChanged() } } }
    open var isEmphasized = true { didSet { if isEmphasized != oldValue { selectionChanged() } } }
    open var isGroupRowStyle = false { didSet { needsDisplay = true } }
    open var isFloating = false
    open var isTargetForDropOperation = false { didSet { needsDisplay = true } }
    open var selectionHighlightStyle: NSTableView.SelectionHighlightStyle = .regular { didSet { needsDisplay = true } }
    open var backgroundColor: NSColor = .clear { didSet { needsDisplay = true } }
    open var isNextRowSelected = false { didSet { if isNextRowSelected != oldValue { needsDisplay = true } } }
    open var isPreviousRowSelected = false { didSet { if isPreviousRowSelected != oldValue { needsDisplay = true } } }
    open var indentationForDropOperation: CGFloat = 0
    open var draggingDestinationFeedbackStyle: NSTableView.DraggingDestinationFeedbackStyle = .regular
    open var numberOfColumns: Int { subviews.count }
    open var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && selectionHighlightStyle != .none && isEmphasized ? .emphasized : .normal
    }
    /// The table's style decides the selection's shape.
    var style: NSTableView.Style = .inset { didSet { if style != oldValue { needsDisplay = true } } }
    var alternateColor: NSColor? { didSet { needsDisplay = true } }

    public override init(frame frameRect: CGRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }

    open func view(atColumn column: Int) -> Any? { column < subviews.count ? subviews[column] : nil }

    /// Called before the table reuses the row for another.
    open func prepareForReuse() {}

    private func selectionChanged() {
        needsDisplay = true
        let style = interiorBackgroundStyle
        for v in subviews {
            (v as? NSTableCellView)?.backgroundStyle = style
            (v as? DisclosureTriangle)?.emphasized = style == .emphasized
        }
    }

    /// The table redraws rows whose state it changed.
    func redraw() { needsDisplay = true }

    // MARK: Drawing (subclasses override these, as in AppKit)

    open override func draw(_ dirtyRect: NSRect) {
        drawBackground(in: dirtyRect)
        if isSelected, selectionHighlightStyle != .none { drawSelection(in: dirtyRect) }
        drawSeparator(in: dirtyRect)
        if isTargetForDropOperation { drawDraggingDestinationFeedback(in: dirtyRect) }
    }

    open func drawBackground(in dirtyRect: NSRect) {
        if let a = alternateColor { a.setFill(); bounds.fill() }
        if backgroundColor.alphaComponent > 0 { backgroundColor.setFill(); bounds.fill() }
    }

    /// The selection: a rounded, inset rectangle (inset and source-list
    /// styles, joined to selected neighbours), or a full-width band.
    open func drawSelection(in dirtyRect: NSRect) {
        let color: NSColor = isEmphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor
        color.setFill()
        switch style {
        case .inset, .sourceList:
            let inset: CGFloat = 10
            var r = CGRect(x: inset, y: 0, width: max(0, bounds.width - inset * 2), height: bounds.height)
            let radius: CGFloat = style == .sourceList ? 5 : 6
            if isPreviousRowSelected || isNextRowSelected {
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
                if isPreviousRowSelected { CGRect(x: r.minX, y: r.minY, width: r.width, height: radius).fill() }
                if isNextRowSelected { CGRect(x: r.minX, y: r.maxY - radius, width: r.width, height: radius).fill() }
            } else {
                r = r.insetBy(dx: 0, dy: style == .sourceList ? 1 : 0)
                NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            }
        default:
            bounds.fill()
        }
    }

    open func drawSeparator(in dirtyRect: NSRect) {}

    open func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setStroke()
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 11, dy: 1), xRadius: 5, yRadius: 5)
        p.lineWidth = 2
        p.stroke()
    }

    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); needsDisplay = true }
    open override func addSubview(_ v: NSView) {
        super.addSubview(v)
        (v as? NSTableCellView)?.backgroundStyle = interiorBackgroundStyle
    }
}

/// The usual cell: an optional image and text field, with an object value.
@preconcurrency @MainActor
open class NSTableCellView: NSView {
    open var textField: NSTextField? { didSet { needsCellLayout() } }
    open var imageView: NSImageView? { didSet { needsCellLayout() } }
    open var objectValue: Any? {
        didSet { if let s = objectValue as? String, let tf = textField, tf.stringValue != s { tf.stringValue = s } }
    }
    open var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet {
            textField?.backgroundStyle = backgroundStyle
            imageView?.backgroundStyle = backgroundStyle
            for case let tf as NSTextField in subviews where tf !== textField { tf.backgroundStyle = backgroundStyle }
        }
    }
    open var rowSizeStyle: NSTableView.RowSizeStyle = .default

    /// Called before the table hands the cell out again from
    /// `makeView(withIdentifier:owner:)`.
    open func prepareForReuse() {}
    open var draggingImageComponents: [Any] { [] }

    public override init(frame frameRect: CGRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }

    private func needsCellLayout() { LayoutQueue.setNeedsLayout(self) }
    open override func addSubview(_ v: NSView) { super.addSubview(v); needsCellLayout() }

    /// The standard cell layout for an image and a text field that have
    /// no frames of their own: the image at the leading edge, the text
    /// beside it, both centred vertically.
    open override func layout() {
        super.layout()
        var x: CGFloat = 2
        if let iv = imageView, iv.superview === self, needsStandardFrame(iv) {
            let s: CGFloat = min(bounds.height - 4, rowSizeStyle == .large ? 24 : rowSizeStyle == .small ? 14 : 16)
            iv.frame = CGRect(x: x, y: ((bounds.height - s) / 2).rounded(), width: s, height: s)
            x = iv.frame.maxX + 6
        } else if let iv = imageView, iv.superview === self {
            x = iv.frame.maxX + 6
        }
        if let tf = textField, tf.superview === self, needsStandardFrame(tf) {
            let h = tf.intrinsicContentSize.height
            tf.frame = CGRect(x: x, y: ((bounds.height - h) / 2).rounded(), width: max(0, bounds.width - x - 2), height: h)
        }
    }
    /// Image and text views the cell lays out: those no constraint places
    /// and no autoresizing mask keeps where the app put them.
    private func needsStandardFrame(_ v: NSView) -> Bool {
        let constrained = constraints.contains { $0.firstItem === v || $0.secondItem === v } || !v.constraints.isEmpty
        if constrained { return false }
        if v.translatesAutoresizingMaskIntoConstraints, !v.autoresizingMask.isEmpty, v.frame.width > 1 { return false }
        return true
    }
    open override func frameSizeChanged(from old: CGSize) {
        super.frameSizeChanged(from: old)
        layout()
    }
}

// MARK: The table

@preconcurrency @MainActor
open class NSTableView: NSControl, VisibleRectObserving {
    open override var isFlipped: Bool { true }
    // AppKit's event dispatch (when the backend reports raw input).
    open override func mouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.mouseDown(with: e) } }
    open override func mouseDragged(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .dragged)) }
    open override func mouseUp(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .up)) }
    open override func mouseMoved(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .moved)) }
    open override func rightMouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.rightMouseDown(with: e) } }
    open override var acceptsFirstResponder: Bool { true }
    open override func keyDown(with e: NSEvent) { if let k = KeyPress(e), key(k) { return }; super.keyDown(with: e) }
    open override func becomeFirstResponder() -> Bool { focusChanged(true); return true }
    open override func resignFirstResponder() -> Bool { focusChanged(false); return true }

    public enum ColumnAutoresizingStyle: UInt, Sendable {
        case noColumnAutoresizing = 0, uniformColumnAutoresizingStyle, sequentialColumnAutoresizingStyle, reverseSequentialColumnAutoresizingStyle,
             lastColumnOnlyAutoresizingStyle, firstColumnOnlyAutoresizingStyle
    }
    public struct GridLineStyle: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let solidVerticalGridLineMask = GridLineStyle(rawValue: 1)
        public static let solidHorizontalGridLineMask = GridLineStyle(rawValue: 2)
        public static let dashedHorizontalGridLineMask = GridLineStyle(rawValue: 8)
    }
    public enum RowSizeStyle: Int, Sendable { case `default` = -1, custom = 0, small, medium, large }
    public struct AnimationOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let effectFade = AnimationOptions(rawValue: 1), effectGap = AnimationOptions(rawValue: 2)
        public static let slideUp = AnimationOptions(rawValue: 0x10), slideDown = AnimationOptions(rawValue: 0x20)
        public static let slideLeft = AnimationOptions(rawValue: 0x30), slideRight = AnimationOptions(rawValue: 0x40)
    }
    public enum DraggingDestinationFeedbackStyle: Int, Sendable { case none = -1, regular = 0, sourceList, gap }
    public enum RowActionEdge: Int, Sendable { case leading, trailing }

    public static let selectionDidChangeNotification = Notification.Name("NSTableViewSelectionDidChangeNotification")
    public static let selectionIsChangingNotification = Notification.Name("NSTableViewSelectionIsChangingNotification")
    public static let columnDidResizeNotification = Notification.Name("NSTableViewColumnDidResizeNotification")
    public static let columnDidMoveNotification = Notification.Name("NSTableViewColumnDidMoveNotification")
    public static let rowViewKey = "NSTableRowViewKey"

    open weak var dataSource: NSTableViewDataSource? { didSet { reloadData() } }
    open weak var delegate: NSTableViewDelegate? { didSet { reloadData() } }
    open private(set) var tableColumns: [NSTableColumn] = []
    open var headerView: NSTableHeaderView? {
        didSet {
            oldValue?.removeFromSuperview()
            headerView?.tableView = self
            enclosingScrollView?.documentChanged()
        }
    }
    open var cornerView: NSView?
    open var rowHeight: CGFloat = 24 { didSet { if rowHeight != oldValue { noteHeightsChanged() } } }
    open var usesAutomaticRowHeights = false { didSet { noteHeightsChanged() } }
    open var rowSizeStyle: RowSizeStyle = .default { didSet { noteHeightsChanged() } }
    open var effectiveRowSizeStyle: RowSizeStyle { rowSizeStyle == .default ? .medium : rowSizeStyle }
    open var intercellSpacing = CGSize(width: 17, height: 0) { didSet { tile() } }
    open var style: Style = .automatic { didSet { reloadStyle() } }
    open var effectiveStyle: Style {
        if style != .automatic { return style }
        return selectionHighlightStyle == .sourceList ? .sourceList : .inset
    }
    open var selectionHighlightStyle: SelectionHighlightStyle = .regular { didSet { reloadStyle() } }
    open var usesAlternatingRowBackgroundColors = false { didSet { reloadStyle() } }
    open var backgroundColor: NSColor = .controlBackgroundColor { didSet { drawBackground() } }
    open var gridStyleMask: GridLineStyle = [] { didSet { drawBackground() } }
    open var gridColor: NSColor = .gridColor
    open var columnAutoresizingStyle: ColumnAutoresizingStyle = .uniformColumnAutoresizingStyle { didSet { tile() } }
    open var allowsMultipleSelection = false
    open var allowsEmptySelection = true
    open var allowsColumnSelection = false
    open var allowsColumnReordering = true
    open var allowsColumnResizing = true
    open var allowsTypeSelect = true
    open var floatsGroupRows = true
    open var verticalMotionCanBeginDrag = true
    open var draggingDestinationFeedbackStyle: DraggingDestinationFeedbackStyle = .regular
    open var autosaveName: String?
    open var autosaveTableColumns = false
    open var doubleAction: Selector?
    /// Runway: run on double-click, as `doubleAction` (see `handler`).
    open var doubleClickHandler: ((NSTableView) -> Void)?
    open var sortDescriptors: [NSSortDescriptor] = [] {
        didSet {
            headerView?.refresh()
            if !sortDescriptorsEqual(oldValue, sortDescriptors) { dataSource?.tableView(self, sortDescriptorsDidChange: oldValue) }
        }
    }
    open var highlightedTableColumn: NSTableColumn?
    open private(set) var clickedRow = -1
    open private(set) var clickedColumn = -1
    open private(set) var selectedRowIndexes = IndexSet()
    open private(set) var selectedColumnIndexes = IndexSet()
    open private(set) var editedRow = -1
    open private(set) var editedColumn = -1

    /// The rows' container: takes the clicks and keys.
    private var events: NativeWidget!
    private let background = DrawnLayer()
    private var rowCount = 0
    private var rowOffsets: [CGFloat] = [0]
    private var visibleRows: [Int: NSTableRowView] = [:]
    private var reusableCells: [NSUserInterfaceItemIdentifier: [NSView]] = [:]
    private var reusableRows: [NSTableRowView] = []
    private var selectionAnchor: Int?
    private var updateDepth = 0
    private var focused = false
    private var tiling = false
    var groupRows: Set<Int> = []

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain {
            events = makeEventWidget(focusable: true, pointer: { [weak self] e in self?.pointer(e) ?? false },
                                     key: { [weak self] k in self?.key(k) ?? false })
            Runway.appKit?.observeFocus(events) { [weak self] f in self?.focusChanged(f) }
            let h = NSTableHeaderView(frame: CGRect(x: 0, y: 0, width: frameRect.width, height: 28))
            headerView = h
            h.tableView = self
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        let frameRect = IBDecoding.frame(coder)
        super.init(coder: coder)
        onMain {
            events = makeEventWidget(focusable: true, pointer: { [weak self] e in self?.pointer(e) ?? false },
                                     key: { [weak self] k in self?.key(k) ?? false })
            Runway.appKit?.observeFocus(events) { [weak self] f in self?.focusChanged(f) }
            let h = NSTableHeaderView(frame: CGRect(x: 0, y: 0, width: frameRect.width, height: 28))
            headerView = h
            h.tableView = self
        }
        IBDecoding.leave(self, coder)
    }

    // MARK: Columns

    open var numberOfColumns: Int { tableColumns.count }
    open func addTableColumn(_ c: NSTableColumn) { c.tableView = self; tableColumns.append(c); columnsChanged() }
    open func removeTableColumn(_ c: NSTableColumn) { tableColumns.removeAll { $0 === c }; c.tableView = nil; columnsChanged() }
    open func moveColumn(_ from: Int, toColumn to: Int) {
        let c = tableColumns.remove(at: from)
        tableColumns.insert(c, at: to)
        columnsChanged()
        let n = Notification(name: Self.columnDidMoveNotification, object: self, userInfo: ["NSOldColumn": from, "NSNewColumn": to])
        delegate?.tableViewColumnDidMove(n)
        NotificationCenter.default.post(n)
    }
    open func tableColumn(withIdentifier id: NSUserInterfaceItemIdentifier) -> NSTableColumn? { tableColumns.first { $0.identifier == id } }
    open func column(withIdentifier id: NSUserInterfaceItemIdentifier) -> Int { tableColumns.firstIndex { $0.identifier == id } ?? -1 }
    var visibleColumnIndexes: [Int] { tableColumns.indices.filter { !tableColumns[$0].isHidden } }

    func columnsChanged() {
        guard !tiling else { return }
        tile()
        headerView?.refresh()
    }

    func postColumnResize(_ c: NSTableColumn) {
        let n = Notification(name: Self.columnDidResizeNotification, object: self, userInfo: ["NSTableColumn": c])
        delegate?.tableViewColumnDidResize(n)
        NotificationCenter.default.post(n)
    }

    /// The horizontal inset rows have in the inset and source-list styles.
    var rowInset: CGFloat { effectiveStyle == .inset || effectiveStyle == .sourceList ? 10 : 0 }

    open func rect(ofColumn column: Int) -> CGRect {
        guard tableColumns.indices.contains(column), !tableColumns[column].isHidden else { return .zero }
        var x = rowInset
        for i in visibleColumnIndexes {
            if i == column { return CGRect(x: x, y: 0, width: tableColumns[i].width, height: bounds.height) }
            x += tableColumns[i].width
        }
        return .zero
    }

    open func column(at point: CGPoint) -> Int {
        for i in visibleColumnIndexes where rect(ofColumn: i).minX <= point.x && point.x < rect(ofColumn: i).maxX { return i }
        return -1
    }

    open func sizeLastColumnToFit() {
        guard let last = visibleColumnIndexes.last else { return }
        let others = visibleColumnIndexes.dropLast().map { tableColumns[$0].width }.reduce(0, +)
        tableColumns[last].width = max(tableColumns[last].minWidth, availableWidth - others)
    }
    open override func sizeToFit() { sizeLastColumnToFit() }

    /// The width rows can use: the clip view's, less the insets.
    private var availableWidth: CGFloat {
        // Only a clip view gives columns a width to fit (a bare table keeps them).
        guard let w = (superview as? NSClipView)?.frame.width else { return 0 }
        return max(0, w - rowInset * 2)
    }

    /// Fits columns to the width (by the autoresizing style), then sizes
    /// the table to its rows.
    open func tile() {
        guard !tiling else { return }
        tiling = true
        defer { tiling = false }
        let cols = visibleColumnIndexes
        let total = cols.map { tableColumns[$0].width }.reduce(0, +)
        // Columns follow changes in the table's width; the first time it has
        // one they only grow to fill it (wider columns scroll).
        let avail = availableWidth
        var extra: CGFloat = 0
        if avail > 1 {
            if let last = lastAvailableWidth { extra = avail - last } else { extra = max(0, avail - total) }
            lastAvailableWidth = avail
        }
        if abs(extra) >= 0.5, !cols.isEmpty {
            switch columnAutoresizingStyle {
            case .noColumnAutoresizing: break
            case .lastColumnOnlyAutoresizingStyle:
                distribute(extra, over: [cols.last!])
            case .firstColumnOnlyAutoresizingStyle:
                distribute(extra, over: [cols.first!])
            case .sequentialColumnAutoresizingStyle:
                distribute(extra, over: cols.reversed())
            case .reverseSequentialColumnAutoresizingStyle:
                distribute(extra, over: cols)
            case .uniformColumnAutoresizingStyle:
                let resizable = cols.filter { tableColumns[$0].resizingMask.contains(.autoresizingMask) }
                if !resizable.isEmpty {
                    var left = extra
                    for (n, i) in resizable.enumerated() {
                        let share = n == resizable.count - 1 ? left : (extra / CGFloat(resizable.count)).rounded()
                        let c = tableColumns[i]
                        let before = c.width
                        c.width = before + share
                        left -= c.width - before
                    }
                    if abs(left) >= 0.5 { distribute(left, over: resizable.reversed()) }
                }
            }
        }
        let width = max(availableWidth, cols.map { tableColumns[$0].width }.reduce(0, +)) + rowInset * 2
        let height = max(rowOffsets.last ?? 0, (superview as? NSClipView)?.frame.height ?? 0)
        let size = CGSize(width: width.rounded(), height: height.rounded(.up))
        if frame.size != size { setFrameSize(size) }
        headerView?.refresh()
        updateVisibleRows(force: true)
    }

    private var lastAvailableWidth: CGFloat?

    private func distribute(_ amount: CGFloat, over cols: [Int]) {
        var left = amount
        for i in cols where abs(left) >= 0.5 {
            let c = tableColumns[i]
            let before = c.width
            c.width = before + left
            left -= c.width - before
        }
    }

    // MARK: Rows

    open var numberOfRows: Int { rowCount }

    /// The rows the table shows; NSOutlineView flattens its items.
    func dataRowCount() -> Int { dataSource?.numberOfRows(in: self) ?? 0 }
    func dataIsGroupRow(_ row: Int) -> Bool { delegate?.tableView(self, isGroupRow: row) ?? false }
    func dataHeight(ofRow row: Int) -> CGFloat {
        if usesAutomaticRowHeights { return automaticHeight(row) }
        let h = delegate?.tableView(self, heightOfRow: row) ?? rowHeight
        return h > 0 ? h : rowHeight
    }
    func dataView(for column: NSTableColumn?, row: Int) -> NSView? {
        if let v = delegate?.tableView(self, viewFor: column, row: row) { return v }
        // No view-based delegate: a text cell showing the data source's value.
        guard let value = dataSource?.tableView(self, objectValueFor: column, row: row) else { return nil }
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
    func dataRowView(_ row: Int) -> NSTableRowView? { delegate?.tableView(self, rowViewForRow: row) }
    func dataShouldSelect(_ row: Int) -> Bool { delegate?.tableView(self, shouldSelectRow: row) ?? true }
    func dataSelectionShouldChange() -> Bool { delegate?.selectionShouldChange(in: self) ?? true }
    func dataProposedSelection(_ s: IndexSet) -> IndexSet { delegate?.tableView(self, selectionIndexesForProposedSelection: s) ?? s }
    func dataSelectionDidChange(_ n: Notification) { delegate?.tableViewSelectionDidChange(n) }
    func dataDidAdd(_ rv: NSTableRowView, _ row: Int) { delegate?.tableView(self, didAdd: rv, forRow: row) }
    func dataDidRemove(_ rv: NSTableRowView, _ row: Int) { delegate?.tableView(self, didRemove: rv, forRow: row) }
    /// The leading indent of the outline column's cell (NSOutlineView).
    func cellIndent(row: Int, column: Int) -> CGFloat { 0 }
    /// Extra views an outline view adds to a row (disclosure buttons).
    func decorate(_ rowView: NSTableRowView, row: Int) {}

    private func automaticHeight(_ row: Int) -> CGFloat {
        var h: CGFloat = 0
        for i in visibleColumnIndexes {
            guard let v = dataView(for: tableColumns[i], row: row) else { continue }
            let w = max(1, tableColumns[i].width - intercellSpacing.width)
            if let tc = v as? NSTableCellView, let tf = tc.textField { h = max(h, tf.height(forWidth: w - 4) + 8) }
            else { h = max(h, v.fittingSize.height) }
            enqueue(v)
        }
        return max(h, rowHeight)
    }

    open func reloadData() {
        guard events != nil else { return }
        recycleAllRows()
        rowCount = dataRowCount()
        groupRows = Set((0..<rowCount).filter { dataIsGroupRow($0) })
        recomputeOffsets()
        let valid = IndexSet(selectedRowIndexes.filter { $0 < rowCount })
        if valid != selectedRowIndexes { selectedRowIndexes = valid }
        tile()
    }

    open func reloadData(forRowIndexes rows: IndexSet, columnIndexes: IndexSet) {
        for r in rows {
            guard let rv = visibleRows[r] else { continue }
            recycle(rowView: rv, row: r)
            visibleRows[r] = nil
        }
        updateVisibleRows(force: true)
    }

    open func noteNumberOfRowsChanged() {
        rowCount = dataRowCount()
        groupRows = Set((0..<rowCount).filter { dataIsGroupRow($0) })
        recomputeOffsets()
        tile()
    }
    open func noteHeightOfRows(withIndexesChanged rows: IndexSet) { noteHeightsChanged() }
    private func noteHeightsChanged() {
        guard events != nil else { return }
        recomputeOffsets()
        recycleAllRows()
        tile()
    }

    private func recomputeOffsets() {
        var offs: [CGFloat] = [0]
        offs.reserveCapacity(rowCount + 1)
        var y: CGFloat = 0
        for r in 0..<rowCount {
            y += dataHeight(ofRow: r) + intercellSpacing.height
            offs.append(y)
        }
        rowOffsets = offs
    }

    open func beginUpdates() { updateDepth += 1 }
    open func endUpdates() {
        updateDepth = max(0, updateDepth - 1)
        if updateDepth == 0 { noteNumberOfRowsChanged(); recycleAllRows(); updateVisibleRows(force: true) }
    }
    open func insertRows(at indexes: IndexSet, withAnimation options: AnimationOptions = []) {
        selectedRowIndexes = shift(selectedRowIndexes, inserting: indexes)
        if updateDepth == 0 { recycleAllRows(); noteNumberOfRowsChanged() }
    }
    open func removeRows(at indexes: IndexSet, withAnimation options: AnimationOptions = []) {
        let hadSelection = !selectedRowIndexes.isEmpty
        selectedRowIndexes = shift(selectedRowIndexes, removing: indexes)
        if updateDepth == 0 { recycleAllRows(); noteNumberOfRowsChanged() }
        if hadSelection, selectedRowIndexes.isEmpty { postSelectionChange() }
    }
    open func moveRow(at old: Int, to new: Int) {
        if updateDepth == 0 { recycleAllRows(); noteNumberOfRowsChanged() }
    }
    open func hideRows(at indexes: IndexSet, withAnimation options: AnimationOptions = []) {}
    open func unhideRows(at indexes: IndexSet, withAnimation options: AnimationOptions = []) {}
    open var hiddenRowIndexes: IndexSet { IndexSet() }

    private func shift(_ s: IndexSet, inserting ins: IndexSet) -> IndexSet {
        var out = IndexSet()
        for i in s { out.insert(i + ins.count(in: 0...i)) }
        return out
    }
    private func shift(_ s: IndexSet, removing rem: IndexSet) -> IndexSet {
        var out = IndexSet()
        for i in s where !rem.contains(i) { out.insert(i - rem.count(in: 0..<i)) }
        return out
    }

    open func rect(ofRow row: Int) -> CGRect {
        guard row >= 0, row < rowCount else { return .zero }
        return CGRect(x: 0, y: rowOffsets[row], width: bounds.width, height: rowOffsets[row + 1] - rowOffsets[row] - intercellSpacing.height)
    }
    open func row(at point: CGPoint) -> Int {
        guard rowCount > 0, point.y >= 0, point.y < rowOffsets[rowCount] else { return -1 }
        var lo = 0, hi = rowCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowOffsets[mid] <= point.y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
    open func rows(in rect: CGRect) -> NSRange {
        let a = row(at: CGPoint(x: 0, y: max(0, rect.minY)))
        guard a >= 0 else { return NSRange(location: 0, length: 0) }
        var b = row(at: CGPoint(x: 0, y: rect.maxY - 0.5))
        if b < 0 { b = rowCount - 1 }
        return NSRange(location: a, length: b - a + 1)
    }
    open func frameOfCell(atColumn column: Int, row: Int) -> CGRect {
        let c = rect(ofColumn: column), r = rect(ofRow: row)
        let indent = cellIndent(row: row, column: column)
        let half = (intercellSpacing.width / 2).rounded(.down)
        let x = c.minX + half + indent
        return CGRect(x: x, y: r.minY, width: max(0, c.width - intercellSpacing.width - indent), height: r.height)
    }
    open func columnIndexes(in rect: CGRect) -> IndexSet { IndexSet(visibleColumnIndexes.filter { self.rect(ofColumn: $0).intersects(rect) }) }

    // MARK: Views for rows

    /// A cell view to reuse with this identifier, if one is free.
    open func makeView(withIdentifier id: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        guard var pool = reusableCells[id], let v = pool.popLast() else { return IBTableCellNibs.make(self, id, owner: owner) }
        reusableCells[id] = pool
        (v as? NSTableCellView)?.prepareForReuse()
        return v
    }
    open func register(_ nib: NSNib?, forIdentifier id: NSUserInterfaceItemIdentifier) { IBTableCellNibs.register(nib, self, id) }
    open var registeredNibsByIdentifier: [NSUserInterfaceItemIdentifier: NSNib]? { IBTableCellNibs.registered(self) }

    private func enqueue(_ v: NSView) {
        v.removeFromSuperview()
        guard let id = v.identifier else { return }
        var pool = reusableCells[id] ?? []
        if pool.count < 64 { pool.append(v) }
        reusableCells[id] = pool
    }

    open func view(atColumn column: Int, row: Int, makeIfNecessary: Bool) -> NSView? {
        if let rv = rowView(atRow: row, makeIfNecessary: makeIfNecessary) {
            return rv.subviews.first { cellColumn[ObjectIdentifier($0)] == column }
        }
        return nil
    }
    private var cellColumn: [ObjectIdentifier: Int] = [:]

    open func rowView(atRow row: Int, makeIfNecessary: Bool) -> NSTableRowView? {
        if let rv = visibleRows[row] { return rv }
        guard makeIfNecessary, row >= 0, row < rowCount else { return nil }
        let rv = makeRowView(row)
        visibleRows[row] = rv
        addSubview(rv)
        dataDidAdd(rv, row)
        return rv
    }

    open func row(for view: NSView) -> Int {
        for (r, rv) in visibleRows where rv.contains(view) { return r }
        return -1
    }
    open func column(for view: NSView) -> Int {
        for rv in visibleRows.values where rv.contains(view) {
            for c in rv.subviews where c.contains(view) { return cellColumn[ObjectIdentifier(c)] ?? -1 }
        }
        return -1
    }

    open func enumerateAvailableRowViews(_ block: (NSTableRowView, Int) -> Void) {
        for r in visibleRows.keys.sorted() { block(visibleRows[r]!, r) }
    }

    private func makeRowView(_ row: Int) -> NSTableRowView {
        let rv = dataRowView(row) ?? reusableRows.popLast().map { $0.prepareForReuse(); return $0 } ?? NSTableRowView(frame: .zero)
        let rect = rect(ofRow: row)
        rv.frame = rect
        configure(rv, row: row)
        let group = groupRows.contains(row)
        if group {
            if let v = dataView(for: nil, row: row) {
                v.frame = CGRect(x: rowInset + (intercellSpacing.width / 2).rounded(.down), y: 0,
                                 width: max(0, rect.width - rowInset * 2 - intercellSpacing.width), height: rect.height)
                cellColumn[ObjectIdentifier(v)] = -1
                rv.addSubview(v)
            }
        } else {
            for i in visibleColumnIndexes {
                guard let v = dataView(for: tableColumns[i], row: row) else { continue }
                var f = frameOfCell(atColumn: i, row: row)
                f.origin.y = 0
                v.frame = f
                cellColumn[ObjectIdentifier(v)] = i
                rv.addSubview(v)
            }
        }
        decorate(rv, row: row)
        return rv
    }

    private func configure(_ rv: NSTableRowView, row: Int) {
        rv.style = effectiveStyle
        rv.selectionHighlightStyle = selectionHighlightStyle
        rv.isGroupRowStyle = groupRows.contains(row)
        rv.isEmphasized = effectiveStyle == .sourceList ? focused : (focused || true)
        if usesAlternatingRowBackgroundColors {
            let alt = NSColor.alternatingContentBackgroundColors
            rv.alternateColor = alt[row % alt.count]
        } else {
            rv.alternateColor = nil
        }
        rv.isSelected = selectedRowIndexes.contains(row)
        rv.isPreviousRowSelected = row > 0 && selectedRowIndexes.contains(row - 1)
        rv.isNextRowSelected = selectedRowIndexes.contains(row + 1)
        rv.redraw()
    }

    private func recycle(rowView rv: NSTableRowView, row: Int) {
        for v in rv.subviews {
            cellColumn[ObjectIdentifier(v)] = nil
            if v.identifier != nil { enqueue(v) } else { v.removeFromSuperview() }
        }
        rv.removeFromSuperview()
        dataDidRemove(rv, row)
        if type(of: rv) == NSTableRowView.self, reusableRows.count < 32 { reusableRows.append(rv) }
    }

    private func recycleAllRows() {
        for (r, rv) in visibleRows { recycle(rowView: rv, row: r) }
        visibleRows.removeAll()
    }

    /// The rows in view (with a screen's worth either side), made or reused.
    private func updateVisibleRows(force: Bool = false) {
        guard events != nil else { return }
        // Until it's in a scroll view or a window, a table makes no rows.
        guard superview is NSClipView || window != nil else { return }
        let vis = visibleRect
        let margin = max(vis.height, 200)
        let want = rows(in: CGRect(x: 0, y: vis.minY - margin, width: bounds.width, height: vis.height + margin * 2))
        let range = want.length > 0 ? want.location..<(want.location + want.length) : 0..<0
        for (r, rv) in visibleRows where !range.contains(r) {
            recycle(rowView: rv, row: r)
            visibleRows[r] = nil
        }
        for r in range {
            if let rv = visibleRows[r] {
                if force {
                    let rr = rect(ofRow: r)
                    if rv.frame != rr {
                        rv.frame = rr
                        for v in rv.subviews {
                            if let c = cellColumn[ObjectIdentifier(v)], c >= 0 {
                                var f = frameOfCell(atColumn: c, row: r)
                                f.origin.y = 0
                                if v.frame != f { v.frame = f }
                            }
                        }
                    }
                    configure(rv, row: r)
                }
                continue
            }
            _ = rowView(atRow: r, makeIfNecessary: true)
        }
        drawBackground()
        layoutSubviews()
    }

    func visibleRectDidChange() {
        if let clip = superview as? NSClipView, abs(clip.frame.width - frame.width) > 0.5 || frame.height < clip.frame.height { tile() }
        else { updateVisibleRows() }
    }

    private func reloadStyle() {
        guard events != nil else { return }
        if effectiveStyle == .sourceList, selectionHighlightStyle == .regular, style == .sourceList { selectionHighlightStyle = .sourceList; return }
        if effectiveStyle == .sourceList {
            backgroundColor = .clear
            if rowSizeStyle == .default { rowHeight = 28 }
        }
        recycleAllRows()
        tile()
    }

    /// The table's background (and grid) behind the rows in view.
    private func drawBackground() {
        let vis = visibleRect
        var cmds: [DrawCommand] = []
        if backgroundColor.rgbaValue.a > 0 { cmds.append(.fill(.rect(CGRect(origin: .zero, size: vis.size)), .color(backgroundColor.rgbaValue))) }
        if usesAlternatingRowBackgroundColors, rowCount > 0 {
            // Stripes continue below the last row, as on the Mac.
            let alt = NSColor.alternatingContentBackgroundColors
            var y = rowOffsets[rowCount] - vis.minY
            var r = rowCount
            while y < vis.height {
                cmds.append(.fill(.rect(CGRect(x: 0, y: y, width: vis.width, height: rowHeight)), .color(alt[r % alt.count].rgbaValue)))
                y += rowHeight; r += 1
            }
        }
        if gridStyleMask.contains(.solidVerticalGridLineMask) {
            for i in visibleColumnIndexes.dropLast() {
                let x = rect(ofColumn: i).maxX - vis.minX
                cmds.append(.fill(.rect(CGRect(x: x - 0.5, y: 0, width: 1, height: vis.height)), .color(gridColor.rgbaValue)))
            }
        }
        if gridStyleMask.contains(.solidHorizontalGridLineMask) || gridStyleMask.contains(.dashedHorizontalGridLineMask) {
            let range = rows(in: vis)
            for r in range.location..<(range.location + range.length) {
                let y = rowOffsets[r + 1] - vis.minY
                cmds.append(.fill(.rect(CGRect(x: 0, y: y - 1, width: vis.width, height: 1)), .color(gridColor.rgbaValue)))
            }
        }
        background.draw(cmds)
        backgroundRect = vis
    }
    private var backgroundRect: CGRect = .zero

    override func place() {
        placementDirty = false
        guard let events else { return }
        let rows = subviews.filter { !$0.isHidden }.map { ($0.widget, $0.frame) }
        Runway.backend.setChildren(events, [(background.widget, backgroundRect)] + rows, contentSize: frame.size)
        Runway.backend.setChildren(widget, [(events, bounds)], contentSize: frame.size)
    }

    open override func frameSizeChanged(from old: CGSize) {
        super.frameSizeChanged(from: old)
        layoutSubviews()
    }

    // MARK: Selection

    open var selectedRow: Int { selectedRowIndexes.last ?? -1 }
    open var selectedColumn: Int { selectedColumnIndexes.last ?? -1 }
    open var numberOfSelectedRows: Int { selectedRowIndexes.count }
    open var numberOfSelectedColumns: Int { selectedColumnIndexes.count }
    open func isRowSelected(_ row: Int) -> Bool { selectedRowIndexes.contains(row) }
    open func isColumnSelected(_ c: Int) -> Bool { selectedColumnIndexes.contains(c) }

    open func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        var s = extend ? selectedRowIndexes.union(indexes) : indexes
        s = IndexSet(s.filter { $0 >= 0 && $0 < rowCount })
        if !allowsMultipleSelection, s.count > 1 { s = IndexSet(integer: indexes.last ?? s.last!) }
        setSelection(s, notify: true)
    }
    open func selectColumnIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
        selectedColumnIndexes = extend ? selectedColumnIndexes.union(indexes) : indexes
    }
    open func deselectRow(_ row: Int) {
        var s = selectedRowIndexes
        s.remove(row)
        setSelection(s, notify: true)
    }
    open func deselectColumn(_ c: Int) { selectedColumnIndexes.remove(c) }
    open func deselectAll(_ sender: Any?) { setSelection(IndexSet(), notify: true) }
    open override func selectAll(_ sender: Any?) { if allowsMultipleSelection { setSelection(IndexSet(0..<rowCount), notify: true) } }

    private func setSelection(_ s: IndexSet, notify: Bool) {
        guard s != selectedRowIndexes else { return }
        let old = selectedRowIndexes
        selectedRowIndexes = s
        for r in old.symmetricDifference(s).union(IndexSet(old.map { $0 - 1 } + old.map { $0 + 1 } + s.map { $0 - 1 } + s.map { $0 + 1 })) {
            if let rv = visibleRows[r] { configure(rv, row: r) }
        }
        if notify { postSelectionChange() }
    }

    func postSelectionChange() {
        let n = Notification(name: Self.selectionDidChangeNotification, object: self)
        dataSelectionDidChange(n)
        NotificationCenter.default.post(n)
    }

    /// A click's proposal through the delegate (shouldSelectRow, then
    /// selectionIndexesForProposedSelection).
    private func propose(_ s: IndexSet) -> IndexSet? {
        guard dataSelectionShouldChange() else { return nil }
        let allowed = IndexSet(s.filter { dataShouldSelect($0) })
        if allowed.isEmpty, !s.isEmpty { return nil }
        let out = dataProposedSelection(allowed)
        if out.isEmpty, !allowsEmptySelection, !selectedRowIndexes.isEmpty { return nil }
        return out
    }

    // MARK: Events

    private func focusChanged(_ f: Bool) {
        focused = f
        for (r, rv) in visibleRows { configure(rv, row: r) }
    }

    private var mouseDownRow = -1

    private func pointer(_ e: PointerEvent) -> Bool {
        switch e.kind {
        case .down:
            guard e.button == 0 || e.button == 1 else { return false }
            if let w = window { _ = w.makeFirstResponder(self) } else { Runway.appKit?.focus(events) }
            let r = row(at: e.location)
            mouseDownRow = r
            clickedRow = r
            clickedColumn = column(at: e.location)
            if e.button == 1 {
                if r >= 0, !selectedRowIndexes.contains(r), let s = propose(IndexSet(integer: r)) { setSelection(s, notify: true) }
                return true
            }
            if handlePointerDown(at: e.location, row: r) { mouseDownRow = -2; return true }
            if e.clickCount == 2 {
                if r >= 0 || doubleAction != nil { sendDoubleAction() }
                return true
            }
            click(row: r, modifiers: e.modifiers)
            return true
        case .up:
            guard e.button == 0, e.clickCount == 1, mouseDownRow != -2 else { return e.button == 0 }
            if action != nil || handler != nil, isEnabled { sendAction(action, to: target) }
            return true
        default:
            return false
        }
    }

    /// Selection by click: plain, ⌘ (toggle) and ⇧ (extend from the anchor).
    func click(row r: Int, modifiers: KeyModifiers) {
        if r < 0 || groupRows.contains(r) && !dataShouldSelect(r) {
            if r < 0, allowsEmptySelection, modifiers.isEmpty, let s = propose(IndexSet()) { setSelection(s, notify: true) }
            return
        }
        var proposed: IndexSet
        if modifiers.contains(.command), allowsMultipleSelection || selectedRowIndexes.contains(r) {
            proposed = selectedRowIndexes
            if proposed.contains(r) { proposed.remove(r) } else { proposed.insert(r) }
            if proposed.isEmpty, !allowsEmptySelection { return }
            selectionAnchor = r
        } else if modifiers.contains(.shift), allowsMultipleSelection, let a = selectionAnchor ?? selectedRowIndexes.first {
            proposed = IndexSet(integersIn: min(a, r)...max(a, r))
        } else {
            proposed = IndexSet(integer: r)
            selectionAnchor = r
        }
        if let s = propose(proposed) { setSelection(s, notify: true) }
    }

    private func sendDoubleAction() {
        doubleClickHandler?(self)
        if let d = doubleAction, isEnabled {
            _ = NSApp.sendAction(d, to: target, from: self)
        }
    }

    /// A press the subclass handles itself (an outline's disclosure triangles).
    func handlePointerDown(at p: CGPoint, row: Int) -> Bool { false }
    /// Keys the subclass handles (an outline's left and right arrows).
    func handleExtraKey(_ k: KeyPress) -> Bool { false }

    private func key(_ k: KeyPress) -> Bool {
        if handleExtraKey(k) { return true }
        if k.command, k.key == "a" { selectAll(nil); return true }
        let current = selectedRow
        var target: Int?
        switch k.key {
        case "down": target = nextSelectable(from: current, step: 1)
        case "up": target = nextSelectable(from: current < 0 ? rowCount : current, step: -1)
        case "home": target = nextSelectable(from: -1, step: 1)
        case "end": target = nextSelectable(from: rowCount, step: -1)
        case "return", "kp_enter":
            if doubleAction != nil || doubleClickHandler != nil { sendDoubleAction(); return true }
            return false
        default: return false
        }
        guard let t = target else { return true }
        if k.shift, allowsMultipleSelection, let a = selectionAnchor ?? selectedRowIndexes.first {
            if let s = propose(IndexSet(integersIn: min(a, t)...max(a, t))) { setSelection(s, notify: true) }
        } else {
            selectionAnchor = t
            if let s = propose(IndexSet(integer: t)) { setSelection(s, notify: true) }
        }
        scrollRowToVisible(t)
        return true
    }

    private func nextSelectable(from r: Int, step: Int) -> Int? {
        var i = r + step
        while i >= 0, i < rowCount {
            if !groupRows.contains(i) || dataShouldSelect(i) { return i }
            i += step
        }
        return nil
    }

    func headerClicked(_ column: Int) {
        let col = tableColumns[column]
        if let proto = col.sortDescriptorPrototype {
            var ds = sortDescriptors
            if let first = ds.first, sameSortKey(first, proto) {
                ds[0] = first.reversedSortDescriptor as! NSSortDescriptor
            } else {
                ds.removeAll { sameSortKey($0, proto) }
                ds.insert(proto, at: 0)
            }
            sortDescriptors = ds
        }
        delegate?.tableView(self, didClick: col)
    }

    open func scrollRowToVisible(_ row: Int) { _ = scrollToVisible(rect(ofRow: row)) }
    open func scrollColumnToVisible(_ column: Int) { _ = scrollToVisible(rect(ofColumn: column)) }

    /// Puts the cell's text field into editing.
    open func editColumn(_ column: Int, row: Int, with event: Any?, select: Bool) {
        guard let v = view(atColumn: column, row: row, makeIfNecessary: true) else { return }
        editedRow = row
        editedColumn = column
        let tf = (v as? NSTableCellView)?.textField ?? (v as? NSTextField)
        tf?.isEditable = true
        tf?._runwayFocus()
    }

    open func indicatorImage(in column: NSTableColumn) -> NSImage? { nil }
    open func setIndicatorImage(_ image: NSImage?, in column: NSTableColumn) {}
    /// The drag operations rows dragged out of the table allow, within the
    /// app (local) and to other apps.
    open func setDraggingSourceOperationMask(_ mask: NSDragOperation, forLocal: Bool) {
        if forLocal { localDragOperations = mask } else { externalDragOperations = mask }
    }
    open internal(set) var localDragOperations: NSDragOperation = .every
    open internal(set) var externalDragOperations: NSDragOperation = .copy
    open func setDropRow(_ row: Int, dropOperation: Int) {}

    private func sortDescriptorsEqual(_ a: [NSSortDescriptor], _ b: [NSSortDescriptor]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { sameSortKey($0, $1) && $0.ascending == $1.ascending }
    }
}
