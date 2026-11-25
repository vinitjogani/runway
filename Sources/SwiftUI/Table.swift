// Table: a header of sortable columns over rows, as on the Mac.
//
// Built from Runway's own views, so it lays out the same on every
// backend. Columns take their ideal widths, then share the extra width
// (or give back what doesn't fit) within their minimums and maximums;
// dragging a header divider resizes a column. Clicking a sortable header
// sorts by it (again: the other way). Rows select on click (⌘ adds or
// removes one, ⇧ extends a range), open on double-click through
// `contextMenu(forSelectionType:primaryAction:)`, and show its menu on a
// secondary click. Up and down arrows move the selection while the table
// has focus.

import Foundation
import RunwayCore

// MARK: Columns

/// A column of a `Table`.
public struct TableColumn<RowValue: Identifiable, Sort, Content: View, Label: View> {
    let title: String
    let cell: (RowValue) -> Content
    let comparator: Sort?
    var minWidth: CGFloat?
    var idealWidth: CGFloat?
    var maxWidth: CGFloat?

    public func width(min: CGFloat? = nil, ideal: CGFloat? = nil, max: CGFloat? = nil) -> Self {
        var c = self
        c.minWidth = min; c.idealWidth = ideal; c.maxWidth = max
        return c
    }
    public func width(_ fixed: CGFloat?) -> Self {
        var c = self
        if let fixed { c.minWidth = fixed; c.idealWidth = fixed; c.maxWidth = fixed }
        return c
    }
    public func alignment(_ alignment: TableColumnAlignment) -> Self { self }
    public func customizationID(_ id: String) -> Self { self }
    public func defaultVisibility(_ visibility: Visibility) -> Self { self }
    public func disabledCustomizationBehavior(_ behavior: TableColumnCustomizationBehavior) -> Self { self }
}

public struct TableColumnAlignment: Hashable, Sendable {
    public static let automatic = Self(), leading = Self(), center = Self(), trailing = Self(), numeric = Self()
}
public struct TableColumnCustomizationBehavior: Hashable, Sendable {
    public static let automatic = Self(), all = Self(), resize = Self(), reorder = Self(), visibility = Self()
}

extension TableColumn where Sort == KeyPathComparator<RowValue>, Label == Text {
    public init<V: Comparable>(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, V>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(title: Text(titleKey).plainText, cell: content, comparator: KeyPathComparator(value))
    }
    @_disfavoredOverload
    public init<S: StringProtocol, V: Comparable>(_ title: S, value: KeyPath<RowValue, V>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(title: String(title), cell: content, comparator: KeyPathComparator(value))
    }
    public init<V: Comparable>(_ text: Text, value: KeyPath<RowValue, V>, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(title: text.plainText, cell: content, comparator: KeyPathComparator(value))
    }
}

extension TableColumn where Sort == KeyPathComparator<RowValue>, Label == Text, Content == Text {
    public init(_ titleKey: LocalizedStringKey, value: KeyPath<RowValue, String>) {
        self.init(title: Text(titleKey).plainText, cell: { Text($0[keyPath: value]) }, comparator: KeyPathComparator(value))
    }
    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, value: KeyPath<RowValue, String>) {
        self.init(title: String(title), cell: { Text($0[keyPath: value]) }, comparator: KeyPathComparator(value))
    }
}

extension TableColumn where Label == Text {
    /// A column that doesn't sort.
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(title: Text(titleKey).plainText, cell: content, comparator: nil)
    }
    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(title: String(title), cell: content, comparator: nil)
    }
}

/// A column with its types erased: what the table lays out.
@MainActor public struct _TableColumnSpec<RowValue, Sort> {
    let title: String
    let cell: (RowValue) -> AnyView
    let comparator: Sort?
    let minWidth: CGFloat
    let idealWidth: CGFloat
    let maxWidth: CGFloat
}

@resultBuilder
public enum TableColumnBuilder<RowValue: Identifiable, Sort> {
    public static func buildExpression<C: View, L: View>(_ column: TableColumn<RowValue, Sort, C, L>) -> [_TableColumnSpec<RowValue, Sort>] {
        let cell = column.cell
        let minW = column.minWidth ?? 10
        let ideal = column.idealWidth ?? max(minW, 100)
        return [_TableColumnSpec(title: column.title, cell: { AnyView(cell($0)) }, comparator: column.comparator,
                                 minWidth: minW, idealWidth: max(ideal, minW), maxWidth: max(column.maxWidth ?? .infinity, minW))]
    }
    public static func buildBlock(_ parts: [_TableColumnSpec<RowValue, Sort>]...) -> [_TableColumnSpec<RowValue, Sort>] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [_TableColumnSpec<RowValue, Sort>]?) -> [_TableColumnSpec<RowValue, Sort>] { part ?? [] }
    public static func buildEither(first: [_TableColumnSpec<RowValue, Sort>]) -> [_TableColumnSpec<RowValue, Sort>] { first }
    public static func buildEither(second: [_TableColumnSpec<RowValue, Sort>]) -> [_TableColumnSpec<RowValue, Sort>] { second }
    public static func buildArray(_ parts: [[_TableColumnSpec<RowValue, Sort>]]) -> [_TableColumnSpec<RowValue, Sort>] { parts.flatMap { $0 } }
    public static func buildLimitedAvailability(_ part: [_TableColumnSpec<RowValue, Sort>]) -> [_TableColumnSpec<RowValue, Sort>] { part }
}

// MARK: Selection menus

/// `contextMenu(forSelectionType:menu:primaryAction:)` for the table inside.
@MainActor struct SelectionMenu {
    let menu: (Set<AnyHashable>) -> AnyView
    let primaryAction: ((Set<AnyHashable>) -> Void)?
}

struct SelectionMenuKey: EnvironmentKey { static var defaultValue: SelectionMenu? { nil } }
struct AlternatingRowsKey: EnvironmentKey { static var defaultValue: Bool { true } }

extension EnvironmentValues {
    var _selectionMenu: SelectionMenu? { get { self[SelectionMenuKey.self] } set { self[SelectionMenuKey.self] = newValue } }
    var _alternatingRows: Bool { get { self[AlternatingRowsKey.self] } set { self[AlternatingRowsKey.self] = newValue } }
}

public struct AlternatingRowBackgroundBehavior: Hashable, Sendable {
    let on: Bool
    public static let automatic = Self(on: true), enabled = Self(on: true), disabled = Self(on: false)
}

extension View {
    public func contextMenu<I: Hashable, M: View>(forSelectionType itemType: I.Type = I.self, @ViewBuilder menu: @escaping (Set<I>) -> M,
                                                  primaryAction: ((Set<I>) -> Void)? = nil) -> some View {
        let typed = { (s: Set<AnyHashable>) in Set(s.compactMap { $0.base as? I }) }
        let spec = SelectionMenu(menu: { AnyView(menu(typed($0))) }, primaryAction: primaryAction.map { action in { action(typed($0)) } })
        return environment { $0._selectionMenu = spec }
    }

    public func alternatingRowBackgrounds(_ behavior: AlternatingRowBackgroundBehavior = .automatic) -> some View {
        environment { $0._alternatingRows = behavior.on }
    }
}

// MARK: Table

public struct Table<Value: Identifiable, Sort>: View {
    let rows: [Value]
    let columns: [_TableColumnSpec<Value, Sort>]
    let selection: Binding<Set<Value.ID>>?
    let single: Binding<Value.ID?>?
    let sortOrder: Binding<[Sort]>?

    public init<Data: RandomAccessCollection>(_ data: Data, selection: Binding<Set<Value.ID>>, sortOrder: Binding<[Sort]>,
                                              @TableColumnBuilder<Value, Sort> columns: () -> [_TableColumnSpec<Value, Sort>])
    where Data.Element == Value, Sort: SortComparator, Sort.Compared == Value {
        rows = Array(data); self.columns = columns(); self.selection = selection; single = nil; self.sortOrder = sortOrder
    }
    public init<Data: RandomAccessCollection>(_ data: Data, selection: Binding<Value.ID?>, sortOrder: Binding<[Sort]>,
                                              @TableColumnBuilder<Value, Sort> columns: () -> [_TableColumnSpec<Value, Sort>])
    where Data.Element == Value, Sort: SortComparator, Sort.Compared == Value {
        rows = Array(data); self.columns = columns(); self.selection = nil; single = selection; self.sortOrder = sortOrder
    }
    public init<Data: RandomAccessCollection>(_ data: Data, sortOrder: Binding<[Sort]>,
                                              @TableColumnBuilder<Value, Sort> columns: () -> [_TableColumnSpec<Value, Sort>])
    where Data.Element == Value, Sort: SortComparator, Sort.Compared == Value {
        rows = Array(data); self.columns = columns(); selection = nil; single = nil; self.sortOrder = sortOrder
    }

    @Environment(\._selectionMenu) private var selectionMenu
    @Environment(\._alternatingRows) private var alternating
    @Environment(\.colorScheme) private var colorScheme
    @State private var widths: [CGFloat] = []
    @State private var anchor: Value.ID?
    @State private var resizing: (index: Int, start: CGFloat)?
    @FocusState private var focused: Bool

    static var rowHeight: CGFloat { 24 }
    static var headerHeight: CGFloat { 28 }

    public var body: some View {
        GeometryReader { geometry in
            let layout = columnWidths(for: geometry.size.width)
            VStack(spacing: 0) {
                header(layout)
                Divider()
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(row, index: index, layout: layout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.upArrow, .downArrow, .return]) { press in
            switch press.key {
            case .upArrow: move(-1, extend: press.modifiers.contains(.shift)); return .handled
            case .downArrow: move(1, extend: press.modifiers.contains(.shift)); return .handled
            default:
                guard let open = selectionMenu?.primaryAction, !selectedIDs.isEmpty else { return .ignored }
                open(Set(selectedIDs.map { AnyHashable($0) }))
                return .handled
            }
        }
    }

    // MARK: Widths

    /// Ideal widths, then the difference from the available width shared
    /// among the columns that can grow (or shrink).
    func columnWidths(for available: CGFloat) -> [CGFloat] {
        var w = columns.indices.map { i in widths.indices.contains(i) && widths.count == columns.count ? widths[i] : columns[i].idealWidth }
        let padding: CGFloat = 8
        var extra = available - padding * 2 - w.reduce(0, +)
        for _ in 0..<4 where abs(extra) > 0.5 {
            let open = columns.indices.filter { extra > 0 ? w[$0] < columns[$0].maxWidth : w[$0] > columns[$0].minWidth }
            guard !open.isEmpty else { break }
            let share = extra / CGFloat(open.count)
            for i in open {
                let nw = min(max(w[i] + share, columns[i].minWidth), columns[i].maxWidth)
                extra -= nw - w[i]
                w[i] = nw
            }
        }
        return w.map { $0.rounded(.down) }
    }

    // MARK: Header

    private func header(_ layout: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { i in
                headerCell(i, width: layout.indices.contains(i) ? layout[i] : 0, layout: layout)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.headerHeight)
    }

    private func headerCell(_ i: Int, width: CGFloat, layout: [CGFloat]) -> some View {
        let column = columns[i]
        let active = sortIndicator(i)
        return HStack(spacing: 0) {
            Button {
                sort(by: i)
            } label: {
                HStack(spacing: 3) {
                    Text(verbatim: column.title)
                        .font(.system(size: 11, weight: active != nil ? .semibold : .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let active {
                        Image(systemName: active ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(column.comparator == nil)
            if i < columns.count - 1 {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        resize(i, by: value.translation.width, layout: layout)
                    }.onEnded { _ in resizing = nil })
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private func resize(_ i: Int, by delta: CGFloat, layout: [CGFloat]) {
        if resizing?.index != i { resizing = (i, layout[i]) }
        var w = layout
        let start = resizing?.start ?? layout[i]
        w[i] = min(max(start + delta, columns[i].minWidth), columns[i].maxWidth)
        widths = w
    }

    /// true ascending, false descending, nil when not the primary sort.
    private func sortIndicator(_ i: Int) -> Bool? {
        guard let sortOrder, let first = sortOrder.wrappedValue.first, let mine = columns[i].comparator else { return nil }
        return Self.sameColumn(first, mine) ? Self.order(of: first) == .forward : nil
    }

    private func sort(by i: Int) {
        guard let sortOrder, let mine = columns[i].comparator else { return }
        var order = sortOrder.wrappedValue
        if let first = order.first, Self.sameColumn(first, mine) {
            order[0] = Self.toggled(first)
        } else {
            order.removeAll { Self.sameColumn($0, mine) }
            order.insert(mine, at: 0)
        }
        sortOrder.wrappedValue = order
    }

    static func order(of s: Sort) -> SortOrder {
        (s as? any SortComparator).map { Self.openOrder($0) } ?? .forward
    }
    private static func openOrder<C: SortComparator>(_ c: C) -> SortOrder { c.order }
    static func toggled(_ s: Sort) -> Sort {
        guard let c = s as? any SortComparator else { return s }
        return (flip(c) as? Sort) ?? s
    }
    private static func flip<C: SortComparator>(_ c: C) -> C {
        var c = c
        c.order = c.order == .forward ? .reverse : .forward
        return c
    }
    /// The same column whatever the order: equal once both sort forward.
    static func sameColumn(_ a: Sort, _ b: Sort) -> Bool {
        guard let ca = a as? any SortComparator, let cb = b as? any SortComparator else { return false }
        return forward(ca) == forward(cb)
    }
    private static func forward<C: SortComparator>(_ c: C) -> AnyHashable {
        var c = c
        c.order = .forward
        return AnyHashable(c)
    }

    // MARK: Rows

    private var selectedIDs: Set<Value.ID> {
        if let selection { return selection.wrappedValue }
        if let single, let id = single.wrappedValue { return [id] }
        return []
    }

    private func setSelection(_ ids: Set<Value.ID>) {
        if let selection { selection.wrappedValue = ids }
        if let single { single.wrappedValue = ids.first }
    }

    private func rowView(_ row: Value, index: Int, layout: [CGFloat]) -> some View {
        let selected = selectedIDs.contains(row.id)
        return HStack(spacing: 0) {
            ForEach(columns.indices, id: \.self) { i in
                columns[i].cell(row)
                    .padding(.horizontal, 6)
                    .frame(width: layout.indices.contains(i) ? layout[i] : 0, height: Self.rowHeight, alignment: .leading)
                    .clipped()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background(rowBackground(index: index, selected: selected))
        .environment(\._tableRowSelected, selected && focused)
        .contentShape(Rectangle())
        .onRowEvents(
            click: { modifiers in click(row.id, modifiers: modifiers) },
            doubleClick: {
                setSelection([row.id])
                selectionMenu?.primaryAction?([AnyHashable(row.id)])
            },
            menu: {
                if !selectedIDs.contains(row.id) { setSelection([row.id]) }
                return selectionMenu.map { m in { m.menu(Set(selectedIDs.map { AnyHashable($0) })) } }
            })
        .id(row.id)
    }

    @ViewBuilder private func rowBackground(index: Int, selected: Bool) -> some View {
        if selected {
            RoundedRectangle(cornerRadius: 5)
                .fill(focused ? Color.accentColor : Color.secondary.opacity(0.22))
                .padding(.horizontal, 4)
        } else if alternating, index % 2 == 1 {
            Rectangle().fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
        } else {
            Color.clear
        }
    }

    private func click(_ id: Value.ID, modifiers: EventModifiers) {
        focused = true
        var ids = selectedIDs
        if modifiers.contains(.command), selection != nil {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        } else if modifiers.contains(.shift), selection != nil, let a = anchor,
                  let from = rows.firstIndex(where: { $0.id == a }), let to = rows.firstIndex(where: { $0.id == id }) {
            ids = Set(rows[min(from, to)...max(from, to)].map(\.id))
        } else {
            ids = [id]
            anchor = id
        }
        setSelection(ids)
    }

    private func move(_ step: Int, extend: Bool) {
        guard !rows.isEmpty else { return }
        let current = anchor.flatMap { a in rows.firstIndex { $0.id == a } }
            ?? rows.lastIndex { selectedIDs.contains($0.id) }
        let next = current.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        let id = rows[next].id
        if extend, selection != nil, let a = anchor, let from = rows.firstIndex(where: { $0.id == a }) {
            setSelection(Set(rows[min(from, next)...max(from, next)].map(\.id)))
        } else {
            setSelection([id])
            anchor = id
        }
    }
}

struct TableRowSelectedKey: EnvironmentKey { static var defaultValue: Bool { false } }
extension EnvironmentValues {
    /// Inside a selected row of a focused table (its text shows white).
    var _tableRowSelected: Bool { get { self[TableRowSelectedKey.self] } set { self[TableRowSelectedKey.self] = newValue } }
}

// MARK: Row events

extension View {
    /// Clicks, double-clicks and secondary clicks on a row, seen without
    /// taking them from controls in it.
    func onRowEvents(click: @escaping (EventModifiers) -> Void, doubleClick: @escaping () -> Void,
                     menu: @escaping () -> (() -> AnyView)?) -> some View {
        nodes("row") { ns, ctx in
            guard !ctx.dryRun, let (w, h) = ctx.host.eventWidget(ctx.path, focusable: false) else { return ns }
            h.widget = w
            let snapshot = ctx
            h.pointer = { [weak h, weak host = ctx.host] e in
                guard e.kind == .down, let host, let h else { return false }
                var mods: EventModifiers = []
                if e.modifiers.contains(.command) { mods.insert(.command) }
                if e.modifiers.contains(.shift) { mods.insert(.shift) }
                if e.button == 1 {
                    guard let content = menu(), let appKit = host.backend as? AppKitBackend, let w = h.widget else { return false }
                    let items = MenuItems.collect(content(), snapshot.child("menu"))
                    if !items.isEmpty { appKit.popUpMenu(items, in: w, at: e.location) }
                    return true
                }
                guard e.button == 0 else { return false }
                if e.clickCount >= 2 { doubleClick() } else { click(mods) }
                return false
            }
            ctx.host.backend.update(w, props: ctx.baseProps(), events: WidgetEvents())
            let inner: LayoutNode = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            return [ContainerNode.modifier(w, ctx.host.backend, inner)]
        }
    }
}
