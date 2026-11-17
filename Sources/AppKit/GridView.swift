// NSGridView: views in rows and columns. Each column is as wide as its
// widest cell (or its fixed width), each row as tall as its tallest; cells
// place their view by the cell's, row's, column's or grid's placement, and
// rows can align their cells on the first baseline. Merged cells span
// columns. Laid out directly, as the grid's own constraints resolve.

import Foundation
import CoreGraphics

@preconcurrency @MainActor
open class NSGridView: NSView {
    public enum CellPlacement: Int, Sendable { case inherited = 0, none, leading, top, trailing, bottom, center, fill }
    public enum RowAlignment: Int, Sendable { case inherited = 0, none, firstBaseline, lastBaseline }
    public static let sizedForContent: CGFloat = 1.17549435e-38

    open override var isFlipped: Bool { true }

    private(set) var rowList: [NSGridRow] = []
    private(set) var columnList: [NSGridColumn] = []
    /// Cells by row, then column.
    private(set) var cells: [[NSGridCell]] = []

    open var rowSpacing: CGFloat = 6 { didSet { relayout() } }
    open var columnSpacing: CGFloat = 6 { didSet { relayout() } }
    open var xPlacement: CellPlacement = .leading { didSet { relayout() } }
    open var yPlacement: CellPlacement = .top { didSet { relayout() } }
    open var rowAlignment: RowAlignment = .none { didSet { relayout() } }

    public override init(frame frameRect: NSRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }

    /// A grid of `rows` (each an array of views; nil or
    /// `NSGridCell.emptyContentView` for an empty cell).
    public convenience init(views rows: [[NSView]]) {
        self.init(frame: .zero)
        for r in rows { addRow(with: r) }
    }
    public convenience init(numberOfColumns: Int, rows: Int) {
        self.init(frame: .zero)
        for _ in 0..<numberOfColumns { addColumn(with: []) }
        for _ in 0..<rows { addRow(with: []) }
    }

    open var numberOfRows: Int { rowList.count }
    open var numberOfColumns: Int { columnList.count }
    open func row(at index: Int) -> NSGridRow { rowList[index] }
    open func column(at index: Int) -> NSGridColumn { columnList[index] }
    open func index(of row: NSGridRow) -> Int { rowList.firstIndex { $0 === row } ?? NSNotFound }
    open func index(of column: NSGridColumn) -> Int { columnList.firstIndex { $0 === column } ?? NSNotFound }
    open func cell(atColumnIndex column: Int, rowIndex row: Int) -> NSGridCell { cells[row][column] }
    open func cell(for view: NSView) -> NSGridCell? { cells.joined().first { $0.contentView === view } }

    @discardableResult open func addRow(with views: [NSView]) -> NSGridRow { insertRow(at: rowList.count, with: views) }
    @discardableResult open func insertRow(at index: Int, with views: [NSView]) -> NSGridRow {
        while columnList.count < views.count { appendColumn() }
        let row = NSGridRow(grid: self)
        rowList.insert(row, at: index)
        var rowCells: [NSGridCell] = []
        for c in 0..<columnList.count {
            let cell = NSGridCell(grid: self, row: row, column: columnList[c])
            cell.contentView = c < views.count ? views[c] : nil
            rowCells.append(cell)
        }
        cells.insert(rowCells, at: index)
        relayout()
        return row
    }
    @discardableResult open func addColumn(with views: [NSView]) -> NSGridColumn { insertColumn(at: columnList.count, with: views) }
    @discardableResult open func insertColumn(at index: Int, with views: [NSView]) -> NSGridColumn {
        while rowList.count < views.count { addRow(with: []) }
        let column = NSGridColumn(grid: self)
        columnList.insert(column, at: index)
        for r in 0..<rowList.count {
            let cell = NSGridCell(grid: self, row: rowList[r], column: column)
            cell.contentView = r < views.count ? views[r] : nil
            cells[r].insert(cell, at: index)
        }
        relayout()
        return column
    }
    private func appendColumn() {
        let column = NSGridColumn(grid: self)
        columnList.append(column)
        for r in 0..<rowList.count { cells[r].append(NSGridCell(grid: self, row: rowList[r], column: column)) }
    }
    open func removeRow(at index: Int) {
        for c in cells[index] { c.contentView = nil }
        cells.remove(at: index)
        rowList.remove(at: index)
        relayout()
    }
    open func removeColumn(at index: Int) {
        for r in 0..<cells.count {
            cells[r][index].contentView = nil
            cells[r].remove(at: index)
        }
        columnList.remove(at: index)
        relayout()
    }
    open func moveRow(at from: Int, to: Int) {
        let r = rowList.remove(at: from), c = cells.remove(at: from)
        rowList.insert(r, at: to)
        cells.insert(c, at: to)
        relayout()
    }
    open func moveColumn(at from: Int, to: Int) {
        let col = columnList.remove(at: from)
        columnList.insert(col, at: to)
        for r in 0..<cells.count { let c = cells[r].remove(at: from); cells[r].insert(c, at: to) }
        relayout()
    }
    /// Merges the cells in `hRange` × `vRange` into the top-left one.
    open func mergeCells(inHorizontalRange hRange: NSRange, verticalRange vRange: NSRange) {
        guard hRange.length > 0, vRange.length > 0 else { return }
        let head = cells[vRange.location][hRange.location]
        for r in vRange.location..<(vRange.location + vRange.length) {
            for c in hRange.location..<(hRange.location + hRange.length) where !(r == vRange.location && c == hRange.location) {
                cells[r][c].contentView = nil
                cells[r][c].headOfMergedCell = head
            }
        }
        head.span = (hRange.length, vRange.length)
        relayout()
    }

    func relayout() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        LayoutQueue.setNeedsLayout(self)
        var p = superview
        while let s = p { if let st = s as? NSStackView { LayoutQueue.setNeedsLayout(st) }; p = s.superview }
    }

    // MARK: Layout

    private func visibleRows() -> [Int] { rowList.indices.filter { !rowList[$0].isHidden } }
    private func visibleColumns() -> [Int] { columnList.indices.filter { !columnList[$0].isHidden } }

    private func size(of cell: NSGridCell) -> CGSize {
        guard let v = cell.contentView, !v.isHidden else { return .zero }
        let p = NSStackView.preferredSize(v)
        let f = v.frame.size
        return CGSize(width: p.width >= 0 ? p.width : f.width, height: p.height >= 0 ? p.height : f.height)
    }

    /// Column widths and row heights for the content.
    private func measure() -> (widths: [Int: CGFloat], heights: [Int: CGFloat]) {
        var widths: [Int: CGFloat] = [:], heights: [Int: CGFloat] = [:]
        for c in visibleColumns() {
            let col = columnList[c]
            if col.width != Self.sizedForContent { widths[c] = col.width; continue }
            var w: CGFloat = 0
            for r in visibleRows() where cells[r][c].headOfMergedCell == nil && cells[r][c].span.columns == 1 { w = max(w, size(of: cells[r][c]).width) }
            widths[c] = w + col.leadingPadding + col.trailingPadding
        }
        for r in visibleRows() {
            let row = rowList[r]
            if row.height != Self.sizedForContent { heights[r] = row.height; continue }
            var h: CGFloat = 0
            for c in visibleColumns() where cells[r][c].headOfMergedCell == nil { h = max(h, size(of: cells[r][c]).height) }
            heights[r] = h + row.topPadding + row.bottomPadding
        }
        return (widths, heights)
    }

    open override var fittingSize: NSSize {
        let (w, h) = measure()
        let cols = visibleColumns(), rows = visibleRows()
        let width = cols.reduce(0) { $0 + (w[$1] ?? 0) } + CGFloat(max(0, cols.count - 1)) * columnSpacing
        let height = rows.reduce(0) { $0 + (h[$1] ?? 0) } + CGFloat(max(0, rows.count - 1)) * rowSpacing
        return NSSize(width: width.rounded(.up), height: height.rounded(.up))
    }
    open override var intrinsicContentSize: NSSize { fittingSize }

    open override func layout() {
        super.layout()
        let (w, h) = measure()
        let cols = visibleColumns(), rows = visibleRows()
        var xs: [Int: CGFloat] = [:], ys: [Int: CGFloat] = [:]
        var x: CGFloat = 0
        for c in cols { xs[c] = x; x += (w[c] ?? 0) + columnSpacing }
        var y: CGFloat = 0
        for r in rows { ys[r] = y; y += (h[r] ?? 0) + rowSpacing }
        for r in rows {
            let row = rowList[r]
            let alignment = row.rowAlignment == .inherited ? rowAlignment : row.rowAlignment
            // The row's first baseline: the deepest among its views.
            var baseline: CGFloat = 0
            if alignment == .firstBaseline {
                for c in cols { if let v = cells[r][c].contentView { baseline = max(baseline, Self.firstBaseline(v, height: size(of: cells[r][c]).height)) } }
            }
            for c in cols {
                let cell = cells[r][c]
                guard cell.headOfMergedCell == nil, let v = cell.contentView, v.superview === self else { continue }
                let col = columnList[c]
                var cellWidth = w[c] ?? 0
                if cell.span.columns > 1 {
                    let spanned = cols.filter { $0 >= c && $0 < c + cell.span.columns }
                    cellWidth = spanned.reduce(0) { $0 + (w[$1] ?? 0) } + CGFloat(max(0, spanned.count - 1)) * columnSpacing
                }
                var cellHeight = h[r] ?? 0
                if cell.span.rows > 1 {
                    let spanned = rows.filter { $0 >= r && $0 < r + cell.span.rows }
                    cellHeight = spanned.reduce(0) { $0 + (h[$1] ?? 0) } + CGFloat(max(0, spanned.count - 1)) * rowSpacing
                }
                let area = CGRect(x: (xs[c] ?? 0) + col.leadingPadding, y: (ys[r] ?? 0) + row.topPadding,
                                  width: max(0, cellWidth - col.leadingPadding - col.trailingPadding),
                                  height: max(0, cellHeight - row.topPadding - row.bottomPadding))
                let s = size(of: cell)
                let xp = resolved(cell.xPlacement, col.xPlacement, xPlacement)
                let yp = resolved(cell.yPlacement, row.yPlacement, yPlacement)
                var f = CGRect(origin: area.origin, size: CGSize(width: min(s.width, area.width), height: min(s.height, area.height)))
                switch xp {
                case .trailing: f.origin.x = area.maxX - f.width
                case .center: f.origin.x = area.midX - f.width / 2
                case .fill: f.size.width = area.width
                default: break
                }
                if alignment == .firstBaseline, cell.span.rows == 1 {
                    f.origin.y = area.minY + baseline - Self.firstBaseline(v, height: s.height)
                } else {
                    switch yp {
                    case .bottom: f.origin.y = area.maxY - f.height
                    case .center: f.origin.y = area.midY - f.height / 2
                    case .fill: f.size.height = area.height
                    default: break
                    }
                }
                v.frame = f.integral
            }
        }
    }

    private func resolved(_ a: CellPlacement, _ b: CellPlacement, _ c: CellPlacement) -> CellPlacement {
        if a != .inherited { return a }
        if b != .inherited { return b }
        return c == .inherited ? .leading : c
    }

    /// A view's first baseline from its top: text's ascent, else its height.
    static func firstBaseline(_ v: NSView, height: CGFloat) -> CGFloat {
        let b = v.firstBaselineOffsetFromTop
        if b > 0 { return b }
        if let tf = v as? NSTextField { return (tf.font?.ascender ?? 11) + 2 }
        if let c = v as? NSControl, let f = c.font { return f.ascender + max(0, (height - f.ascender + f.descender) / 2) }
        return height
    }
}

@preconcurrency @MainActor
open class NSGridRow: NSObject {
    open private(set) weak var gridView: NSGridView?
    open var yPlacement: NSGridView.CellPlacement = .inherited { didSet { gridView?.relayout() } }
    open var rowAlignment: NSGridView.RowAlignment = .inherited { didSet { gridView?.relayout() } }
    open var height: CGFloat = NSGridView.sizedForContent { didSet { gridView?.relayout() } }
    open var topPadding: CGFloat = 0 { didSet { gridView?.relayout() } }
    open var bottomPadding: CGFloat = 0 { didSet { gridView?.relayout() } }
    open var isHidden = false {
        didSet {
            guard let g = gridView else { return }
            let i = g.index(of: self)
            if i != NSNotFound { for c in 0..<g.numberOfColumns { g.cell(atColumnIndex: c, rowIndex: i).contentView?.isHidden = isHidden } }
            g.relayout()
        }
    }
    init(grid: NSGridView) { gridView = grid; super.init() }
    open var numberOfCells: Int { gridView?.numberOfColumns ?? 0 }
    open func cell(at index: Int) -> NSGridCell {
        let g = gridView!
        return g.cell(atColumnIndex: index, rowIndex: g.index(of: self))
    }
    open func mergeCells(in range: NSRange) {
        guard let g = gridView else { return }
        g.mergeCells(inHorizontalRange: range, verticalRange: NSRange(location: g.index(of: self), length: 1))
    }
}

@preconcurrency @MainActor
open class NSGridColumn: NSObject {
    open private(set) weak var gridView: NSGridView?
    open var xPlacement: NSGridView.CellPlacement = .inherited { didSet { gridView?.relayout() } }
    open var width: CGFloat = NSGridView.sizedForContent { didSet { gridView?.relayout() } }
    open var leadingPadding: CGFloat = 0 { didSet { gridView?.relayout() } }
    open var trailingPadding: CGFloat = 0 { didSet { gridView?.relayout() } }
    open var isHidden = false {
        didSet {
            guard let g = gridView else { return }
            let i = g.index(of: self)
            if i != NSNotFound { for r in 0..<g.numberOfRows { g.cell(atColumnIndex: i, rowIndex: r).contentView?.isHidden = isHidden } }
            g.relayout()
        }
    }
    init(grid: NSGridView) { gridView = grid; super.init() }
    open var numberOfCells: Int { gridView?.numberOfRows ?? 0 }
    open func cell(at index: Int) -> NSGridCell {
        let g = gridView!
        return g.cell(atColumnIndex: g.index(of: self), rowIndex: index)
    }
    open func mergeCells(in range: NSRange) {
        guard let g = gridView else { return }
        g.mergeCells(inHorizontalRange: NSRange(location: g.index(of: self), length: 1), verticalRange: range)
    }
}

@preconcurrency @MainActor
open class NSGridCell: NSObject {
    /// A placeholder for a cell with no view (it's never shown).
    public static let emptyContentView: NSView = EmptyGridContent(frame: .zero)
    final class EmptyGridContent: NSView {}

    open private(set) weak var row: NSGridRow?
    open private(set) weak var column: NSGridColumn?
    private weak var grid: NSGridView?
    open var xPlacement: NSGridView.CellPlacement = .inherited { didSet { grid?.relayout() } }
    open var yPlacement: NSGridView.CellPlacement = .inherited { didSet { grid?.relayout() } }
    open var rowAlignment: NSGridView.RowAlignment = .inherited { didSet { grid?.relayout() } }
    open var customPlacementConstraints: [NSLayoutConstraint] = []
    open internal(set) weak var headOfMergedCell: NSGridCell?
    var span: (columns: Int, rows: Int) = (1, 1)

    init(grid: NSGridView, row: NSGridRow, column: NSGridColumn) {
        self.grid = grid
        self.row = row
        self.column = column
        super.init()
    }

    open var contentView: NSView? {
        didSet {
            guard oldValue !== contentView else { return }
            if let old = oldValue, !(old is EmptyGridContent), old.superview === grid { old.removeFromSuperview() }
            if contentView is EmptyGridContent { contentView = nil; return }
            if let v = contentView, let grid {
                v.translatesAutoresizingMaskIntoConstraints = true
                grid.addSubview(v)
            }
            grid?.relayout()
        }
    }
}
