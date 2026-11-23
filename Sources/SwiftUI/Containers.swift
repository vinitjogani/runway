// Form, Section, LabeledContent, GroupBox, List, DisclosureGroup,
// NavigationStack/SplitView, TabView, ContentUnavailableView — built from
// the primitives, laid out the way macOS lays them out (a grouped form is
// cards of rows: label leading, control trailing, hairlines between).

import Foundation
import RunwayCore

public struct Form<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let inner = ctx.with { env in
            env._inForm = true
            env._stackAxis = .vertical
        }
        let sections = inner.resolve(content, "form")
        let stack = PaddingNode(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20),
                                StackNode(axis: .vertical, alignment: 0, spacing: 18, children: sections.map(fillWidth)))
        let enabled = ctx.env.isScrollEnabled
        let w = ctx.widget(enabled ? .scroll(horizontal: false, vertical: true) : .container)
        if let w { ctx.host.backend.update(w, props: WidgetProps(), events: WidgetEvents()) }
        return [ContainerNode(widget: w, backend: ctx.host.backend, content: stack, sizing: .scroll(horizontal: false, vertical: true, enabled: enabled))]
    }
}

/// Stretches a node to the width offered (form sections and rows do).
@MainActor func fillWidth(_ n: LayoutNode) -> LayoutNode {
    let f = FrameNode(child: n, alignment: .leading)
    f.maxWidth = .infinity
    return f
}

public struct Section<Parent: View, Content: View, Footer: View>: View, PrimitiveView {
    public typealias Body = Never
    let header: Parent
    let content: Content
    let footer: Footer

    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let env = ctx.env
        let headerNodes = ctx.with { env in
            if env.font == nil { env.font = .system(size: 13, weight: .semibold) }
        }.resolve(header, "header")
        let footerNodes = ctx.with { env in
            if env.font == nil { env.font = .system(size: 11) }
            if env._foreground == nil { env._foreground = AnyShapeStyle(HierarchicalShapeStyle.secondary) }
        }.resolve(footer, "footer")

        if let group = env._insetGroupedList, !env._inForm {
            let rows = ctx.resolve(content, "rows")
            var children = headerNodes.map(fillWidth)
            if !rows.isEmpty { children.append(group.card(rows, in: ctx.child("card"))) }
            children += footerNodes.map(fillWidth)
            guard !children.isEmpty else { return [] }
            let section = StackNode(axis: .vertical, alignment: 0, spacing: 6, children: children)
            return [GroupedListSectionNode(section)]
        }

        guard env._inForm else {
            // Outside a form (List, VStack): header, rows, footer.
            let rows = ctx.resolve(content, "rows")
            return [StackNode(axis: .vertical, alignment: 0, spacing: 6, children: headerNodes + rows + footerNodes)]
        }

        // A grouped form's card.
        let rowCtx = ctx.with { env in
            env._inFormRow = true
            env._stackAxis = .vertical
        }
        let rows = rowCtx.resolve(content, "rows")
        var cardRows: [LayoutNode] = []
        for (i, row) in rows.enumerated() {
            if i > 0 {
                let line = _ShapeView(shape: Rectangle(), style: AnyShapeStyle(SeparatorShapeStyle()), stroke: nil)
                let lineNode = ctx.child("sep\(i)").resolve(line, "l").first!
                let f = FrameNode(child: lineNode, alignment: .center)
                f.height = 1
                f.maxWidth = .infinity
                cardRows.append(PaddingNode(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10), f))
            }
            let padded = PaddingNode(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10), fillWidth(row))
            let minH = FrameNode(child: padded, alignment: .leading)
            minH.minHeight = 36
            minH.maxWidth = .infinity
            cardRows.append(minH)
        }
        var out: [LayoutNode] = []
        if !headerNodes.isEmpty {
            out.append(PaddingNode(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10),
                                   StackNode(axis: .horizontal, alignment: 0.5, spacing: nil, children: headerNodes + [SpacerNode(minLength: 0, axis: .horizontal)])))
        }
        if !cardRows.isEmpty {
            // macOS draws grouped sections as lighter cards with a hairline
            // edge on the window background.
            let card = StackNode(axis: .vertical, alignment: 0, spacing: 0, children: cardRows)
            let bg = ctx.child("card").resolve(
                _ShapeView(shape: RoundedRectangle(cornerRadius: 10), style: AnyShapeStyle(Color(light: RGBA(1, 1, 1, 0.72), dark: RGBA(1, 1, 1, 0.045))), stroke: nil)
                    .strokeBorder(Color(light: RGBA(0, 0, 0, 0.065), dark: RGBA(1, 1, 1, 0.08)), lineWidth: 1),
                "bg")
            out.append(LayerNode(primary: card, secondary: bg, alignment: .center, behind: true))
        }
        if !footerNodes.isEmpty {
            out.append(PaddingNode(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10),
                                   StackNode(axis: .vertical, alignment: 0, spacing: 4, children: footerNodes)))
        }
        return [StackNode(axis: .vertical, alignment: 0, spacing: 6, children: out.map(fillWidth))]
    }
}

extension Section where Parent == EmptyView, Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content) { self.init(content: content, header: { EmptyView() }, footer: { EmptyView() }) }
}
extension Section where Footer == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) { self.init(content: content, header: header, footer: { EmptyView() }) }
    public init(header: Parent, @ViewBuilder content: () -> Content) { self.init(content: content, header: { header }, footer: { EmptyView() }) }
}
extension Section where Parent == EmptyView {
    public init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) { self.init(content: content, header: { EmptyView() }, footer: footer) }
    public init(footer: Footer, @ViewBuilder content: () -> Content) { self.init(content: content, header: { EmptyView() }, footer: { footer }) }
}
extension Section {
    public init(header: Parent, footer: Footer, @ViewBuilder content: () -> Content) { self.init(content: content, header: { header }, footer: { footer }) }
}
extension Section where Parent == Text, Footer == EmptyView {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.init(content: content, header: { Text(titleKey) }, footer: { EmptyView() }) }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) { self.init(content: content, header: { Text(title) }, footer: { EmptyView() }) }
    public init(_ titleKey: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) { self.init(titleKey, content: content) }
}

public struct LabeledContent<Label: View, Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let label: Label
    let content: Content
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) { self.content = content(); self.label = label() }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let lbl = ctx.resolve(label, "label")
        let value = ctx.with { env in
            if env._foreground == nil, Content.self == Text.self { env._foreground = AnyShapeStyle(HierarchicalShapeStyle.secondary) }
        }.resolve(content, "content")
        if ctx.env._labelsHidden { return value }
        let spacer: [LayoutNode] = ctx.env._inFormRow ? [SpacerNode(minLength: 12, axis: .horizontal)] : []
        return [StackNode(axis: .horizontal, alignment: 0.5, spacing: 8, children: lbl + spacer + value)]
    }
}

extension LabeledContent where Label == Text, Content == Text {
    public init(_ titleKey: LocalizedStringKey, value: String) { self.init(content: { Text(value) }, label: { Text(titleKey) }) }
    @_disfavoredOverload public init<S: StringProtocol, V: StringProtocol>(_ title: S, value: V) { self.init(content: { Text(value) }, label: { Text(title) }) }
    public init<F: FormatStyle>(_ titleKey: LocalizedStringKey, value: F.FormatInput, format: F) where F.FormatOutput == String {
        self.init(content: { Text(format.format(value)) }, label: { Text(titleKey) })
    }
}

extension LabeledContent where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.init(content: content, label: { Text(titleKey) }) }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) { self.init(content: content, label: { Text(title) }) }
}

public struct GroupBox<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) { self.content = content(); self.label = label() }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            label.font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(light: RGBA(0, 0, 0, 0.035), dark: RGBA(1, 1, 1, 0.05))))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(light: RGBA(0, 0, 0, 0.06), dark: RGBA(1, 1, 1, 0.07)), lineWidth: 1))
        }
    }
}

extension GroupBox where Label == EmptyView {
    public init(@ViewBuilder content: () -> Content) { self.init(content: content, label: { EmptyView() }) }
}
extension GroupBox where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.init(content: content, label: { Text(titleKey) }) }
}

public struct DisclosureGroup<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    let external: Binding<Bool>?
    @State private var expanded = false
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) { self.content = content(); self.label = label(); external = nil }
    public init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content(); self.label = label(); external = isExpanded
    }
    public var body: some View {
        let open = external?.wrappedValue ?? expanded
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let e = external { e.wrappedValue.toggle() } else { expanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10))
                    label
                }
            }
            .buttonStyle(.plain)
            if open { content.padding(.leading, 14) }
        }
    }
}

extension DisclosureGroup where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.init(content: content, label: { Text(titleKey) }) }
    public init(_ titleKey: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.init(isExpanded: isExpanded, content: content, label: { Text(titleKey) })
    }
}

// MARK: List

public struct List<SelectionValue: Hashable, Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let content: Content
    /// Single (`Binding<V?>`) or multiple (`Binding<Set<V>>`) selection, type-erased:
    /// whether a row's tag is selected, and what a click on it does.
    let selection: ListSelection?

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let group = ctx.env._mobilePreview && ctx.env._insetGroupedListStyle ? InsetGroupedList(selection: selection) : nil
        let bottom = 6 + ctx.env._mobileTabBarInset
        let rows = ctx.with { env in
            env._stackAxis = .vertical
            env._insetGroupedList = group
            env._mobileTabBarInset = 0
        }.resolve(content, "list")
        if let group {
            let sections = group.sections(rows, in: ctx.child("groups"))
            let spacing: CGFloat = switch ctx.env._listSectionSpacing {
            case .default: 20
            default: ctx.env._listSectionSpacing.spacing
            }
            let inset: CGFloat = ctx.env.horizontalSizeClass == .regular ? 20 : 16
            let top: CGFloat = ctx.env._mobilePreviewProfile == .iphonePro ? 36 : 6
            let stack = StackNode(axis: .vertical, alignment: 0, spacing: spacing, children: sections)
            return [scrollList(PaddingNode(EdgeInsets(top: top, leading: inset, bottom: bottom, trailing: inset), stack), in: ctx)]
        }

        var out: [LayoutNode] = []
        for (i, row) in rows.enumerated() {
            let padded = PaddingNode(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10), fillWidth(row))
            let node = selectableListRow(row, content: padded, selection: selection, in: ctx.child("row\(i)"))
            out.append(fillWidth(node))
        }
        let spacing = ctx.env._listSectionSpacing.spacing
        let stack = PaddingNode(EdgeInsets(top: 6, leading: 0, bottom: bottom, trailing: 0), StackNode(axis: .vertical, alignment: 0, spacing: spacing, children: out))
        return [scrollList(stack, in: ctx)]
    }

    private func scrollList(_ stack: LayoutNode, in ctx: ResolveContext) -> LayoutNode {
        let w = ctx.widget(.scroll(horizontal: false, vertical: true))
        if let w { ctx.host.backend.update(w, props: WidgetProps(), events: WidgetEvents()) }
        return ContainerNode(widget: w, backend: ctx.host.backend, content: stack, sizing: .scroll(horizontal: false, vertical: true, enabled: true))
    }
}

private struct InsetGroupedListStyleKey: EnvironmentKey { static let defaultValue = false }
private struct InsetGroupedListKey: EnvironmentKey { static var defaultValue: InsetGroupedList? { nil } }

extension EnvironmentValues {
    var _insetGroupedListStyle: Bool {
        get { self[InsetGroupedListStyleKey.self] }
        set { self[InsetGroupedListStyleKey.self] = newValue }
    }

    fileprivate var _insetGroupedList: InsetGroupedList? {
        get { self[InsetGroupedListKey.self] }
        set { self[InsetGroupedListKey.self] = newValue }
    }
}

private final class GroupedListSectionNode: LayoutNode {
    let child: LayoutNode
    init(_ child: LayoutNode) { self.child = child }
    override var children: [LayoutNode] { [child] }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }

    static func contains(_ node: LayoutNode) -> Bool {
        if node is GroupedListSectionNode { return true }
        if let scope = node as? ScopeNode { return contains(scope.target) }
        if let row = node as? ListRowDecorationNode { return contains(row.child) }
        return false
    }
}

enum ListRowDecoration {
    case insets(EdgeInsets?)
    case background(AnyView?)
    case separator(Visibility, VerticalEdge.Set)
}

extension View {
    func listRowDecoration(_ name: String, _ decoration: ListRowDecoration) -> some View {
        nodes(name) { children, ctx in
            guard ctx.env._insetGroupedList != nil else { return children }
            return children.map { ListRowDecorationNode($0, decoration: decoration) }
        }
    }
}

private final class ListRowDecorationNode: LayoutNode {
    let child: LayoutNode
    let decoration: ListRowDecoration

    init(_ child: LayoutNode, decoration: ListRowDecoration) {
        self.child = child
        self.decoration = decoration
        super.init()
        tag = child.tag
        tagValue = child.tagValue
    }

    override var children: [LayoutNode] { [child] }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

private struct ListRowAppearance {
    private static let defaultInsets = EdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16)
    var insets = defaultInsets
    var background: AnyView?
    var topSeparator = Visibility.automatic
    var bottomSeparator = Visibility.automatic

    @MainActor init(_ node: LayoutNode) {
        if let row = node as? ListRowDecorationNode {
            self = Self(row.child)
            switch row.decoration {
            case .insets(let insets): self.insets = insets ?? Self.defaultInsets
            case .background(let background): self.background = background
            case .separator(let visibility, let edges):
                if edges.contains(.top) { topSeparator = visibility }
                if edges.contains(.bottom) { bottomSeparator = visibility }
            }
        } else if let scope = node as? ScopeNode { self = Self(scope.target) }
        else if let tag = node as? TaggedNode { self = Self(tag.child) }
    }

}

@MainActor private struct InsetGroupedList {
    let selection: ListSelection?

    func sections(_ nodes: [LayoutNode], in ctx: ResolveContext) -> [LayoutNode] {
        var sections: [LayoutNode] = []
        var rows: [LayoutNode] = []
        func flush() {
            guard !rows.isEmpty else { return }
            sections.append(card(rows, in: ctx.child("implicit\(sections.count)")))
            rows.removeAll()
        }
        for node in nodes where !node.isEmptyLayout {
            if GroupedListSectionNode.contains(node) {
                flush()
                sections.append(node)
            } else {
                rows.append(node)
            }
        }
        flush()
        return sections
    }

    func card(_ rows: [LayoutNode], in ctx: ResolveContext) -> LayoutNode {
        let appearance = rows.map(ListRowAppearance.init)
        let children = rows.enumerated().map { index, row -> LayoutNode in
            let rowCtx = ctx.child("row\(index)")
            let style = appearance[index]
            let frame = FrameNode(child: PaddingNode(style.insets, fillWidth(row)), alignment: .leading)
            frame.minHeight = 44
            frame.maxWidth = .infinity
            var content = selectableListRow(row, content: frame, selection: selection, in: rowCtx)
            let background: [LayoutNode]
            if let view = style.background, !(view.view is Color) {
                background = rowCtx.resolve(view, "background")
            } else {
                let shape = ListRowCorners(top: index == 0, bottom: index == rows.count - 1)
                let color = (style.background?.view as? Color) ?? .controlBackground
                background = rowCtx.resolve(shape.fill(color), "background")
            }
            content = LayerNode(primary: content, secondary: background, alignment: .center, behind: true)
            if index + 1 < rows.count, style.bottomSeparator != .hidden, appearance[index + 1].topSeparator != .hidden {
                let leading = style.insets.leading + (leadingTextOffset(in: row) ?? 0)
                let line = Rectangle().fill(.separator).frame(height: 1)
                    .padding(EdgeInsets(leading: leading, trailing: style.insets.trailing))
                content = LayerNode(primary: content, secondary: rowCtx.resolve(line, "separator"), alignment: .bottom, behind: false)
            }
            return content
        }
        return StackNode(axis: .vertical, alignment: 0, spacing: 0, children: children)
    }
}

/// In a label that starts with a fixed-size icon, line up the separator with
/// the title. Plain text rows use the row's normal leading inset.
@MainActor private func leadingTextOffset(in node: LayoutNode) -> CGFloat? {
    if let widget = node as? WidgetNode { return widget.text == nil ? nil : 0 }
    if let layer = node as? LayerNode { return leadingTextOffset(in: layer.primary) }
    if let padding = node as? PaddingNode { return leadingTextOffset(in: padding.child).map { $0 + padding.insets.leading } }
    if let stack = node as? StackNode, stack.axis == .horizontal {
        var leading: CGFloat = 0
        for child in stack.items {
            if let offset = leadingTextOffset(in: child) { return leading + offset }
            let width = child.size(.unspecified).width
            guard width.isFinite else { return nil }
            leading += width + (stack.spacing ?? defaultSpacing)
        }
        return nil
    }
    return node.children.lazy.compactMap { leadingTextOffset(in: $0) }.first
}

private struct ListRowCorners: Shape {
    let top: Bool
    let bottom: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(26, rect.width / 2, rect.height / 2)
        let topRadius = top ? radius : 0
        let bottomRadius = bottom ? radius : 0
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + topRadius), control: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + topRadius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

@MainActor private func selectableListRow(_ row: LayoutNode, content: LayoutNode, selection: ListSelection?, in ctx: ResolveContext) -> LayoutNode {
    guard let tag = row.tag, let selection else { return content }
    var node = content
    if selection.contains(tag) {
        let background = ctx.resolve(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2)), "selected")
        node = LayerNode(primary: node, secondary: background, alignment: .center, behind: true)
    }
    let widget = ctx.widget(.tapArea)
    var events = WidgetEvents()
    let value = row.tagValue
    events.onTap = { selection.select(value) }
    if let widget { ctx.host.backend.update(widget, props: ctx.baseProps(), events: events) }
    return ContainerNode(widget: widget, backend: ctx.host.backend, content: node, sizing: .hug)
}

struct ListSelection {
    let contains: (AnyHashable) -> Bool
    let select: (Any?) -> Void
    init<V: Hashable>(_ b: Binding<V?>) {
        contains = { AnyHashable(b.wrappedValue) == $0 }
        select = { b.wrappedValue = $0 as? V }
    }
    init<V: Hashable>(_ b: Binding<Set<V>>) {
        contains = { tag in b.wrappedValue.contains { AnyHashable($0) == tag } }
        // A click selects just that row, as on the Mac without modifier keys.
        select = { if let v = $0 as? V { b.wrappedValue = [v] } }
    }
}

extension List {
    public init(selection: Binding<SelectionValue?>, @ViewBuilder content: () -> Content) { self.content = content(); self.selection = ListSelection(selection) }
    public init(selection: Binding<Set<SelectionValue>>, @ViewBuilder content: () -> Content) { self.content = content(); self.selection = ListSelection(selection) }
    /// A selection that is never empty (macOS 13).
    @_disfavoredOverload public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.selection = ListSelection(Binding<SelectionValue?>(get: { selection.wrappedValue }, set: { if let v = $0 { selection.wrappedValue = v } }))
    }
}
extension List where SelectionValue == Never {
    public init(@ViewBuilder content: () -> Content) { self.content = content(); selection = nil }
    public init<Data: RandomAccessCollection, RowContent: View>(_ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
    where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        content = ForEach(data, content: rowContent); selection = nil
    }
    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
    where Content == ForEach<Data, ID, RowContent> {
        content = ForEach(data, id: id, content: rowContent); selection = nil
    }
}
extension List {
    public init<Data: RandomAccessCollection, RowContent: View>(_ data: Data, selection: Binding<SelectionValue?>, @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent)
    where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable, SelectionValue == Data.Element.ID {
        content = ForEach(data) { rowContent($0).tag($0.id) as! RowContent }
        self.selection = ListSelection(selection)
    }
}

// MARK: Navigation

public enum NavigationSplitViewVisibility: Hashable, Sendable { case automatic, all, doubleColumn, detailOnly }

public struct NavigationSplitView<Sidebar: View, Content: View, Detail: View>: View {
    let sidebar: Sidebar
    let content: Content?
    let detail: Detail
    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) where Content == EmptyView {
        self.sidebar = sidebar(); content = nil; self.detail = detail()
    }
    public init(columnVisibility: Binding<NavigationSplitViewVisibility>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) where Content == EmptyView {
        self.sidebar = sidebar(); content = nil; self.detail = detail()
    }
    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar(); self.content = content(); self.detail = detail()
    }
    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color(light: RGBA(0, 0, 0, 0.04), dark: RGBA(1, 1, 1, 0.04)))
            Divider()
            if let content {
                content.frame(width: 260).frame(maxHeight: .infinity, alignment: .top)
                Divider()
            }
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: TabView

private struct MobileTabBarInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct MobileTabSymbolKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var _mobileTabBarInset: CGFloat {
        get { self[MobileTabBarInsetKey.self] }
        set { self[MobileTabBarInsetKey.self] = newValue }
    }

    var _mobileTabSymbol: Bool {
        get { self[MobileTabSymbolKey.self] }
        set { self[MobileTabSymbolKey.self] = newValue }
    }
}

public struct TabView<SelectionValue: Hashable, Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let content: Content
    let selection: Binding<SelectionValue>?

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        // Tabs are the content's children; their labels come from .tabItem.
        // Resolve with the real environment: a tab's body can require an
        // environment object even before a tab is selected.
        let profile = ctx.env._mobilePreview
            ? ctx.env._mobilePreviewProfile ?? (ctx.env.horizontalSizeClass == .regular ? .ipad : .iphone)
            : nil
        let clearance = profile.map { $0.tabBarHeight + $0.tabBarBottomInset + 8 } ?? 0
        let kids = ctx.with { $0._mobileTabBarInset = clearance }.resolve(content, "tabs")
        let items = kids.enumerated().map { index, node in
            TabItemNode.item(in: node) ?? TabBarItem(title: "Tab \(index + 1)")
        }
        let key = ctx.path + "$tab"
        let local = ctx.host.stateBox(key) { 0 }
        var index = local.value
        if let selection, let i = kids.firstIndex(where: { $0.tag == AnyHashable(selection.wrappedValue) }) { index = i }
        index = min(max(0, index), max(0, kids.count - 1))

        let select: @MainActor (Int) -> Void = { index in
            guard kids.indices.contains(index) else { return }
            local.set(index)
            if let selection, let value = kids[index].tagValue as? SelectionValue {
                selection.wrappedValue = value
            }
        }
        let page = kids.indices.contains(index) ? kids[index] : StackNode(axis: .vertical, alignment: 0, spacing: 0, children: [])
        let pageFrame = FrameNode(child: page, alignment: .top)
        pageFrame.maxWidth = .infinity
        pageFrame.maxHeight = .infinity

        if let profile {
            pageFrame.minWidth = 0
            pageFrame.minHeight = 0
            guard !items.isEmpty else { return [pageFrame] }
            let primary: LayoutNode = containsVerticalScroll(page)
                ? pageFrame : PaddingNode(EdgeInsets(bottom: clearance), pageFrame)
            let bar = MobileTabBar(items: items, selected: index, profile: profile, select: select)
            return [LayerNode(primary: primary, secondary: ctx.resolve(bar, "tabBar"), alignment: .bottom, behind: false)]
        }

        var events = WidgetEvents()
        events.onSelect = select
        var p = ctx.baseProps()
        p.options = items.map(\.title)
        p.selected = index
        let w = ctx.widget(.segmented, "tabs")
        if let w { ctx.host.backend.update(w, props: p, events: events) }
        let bar = WidgetNode(w, backend: ctx.host.backend)
        let content: [LayoutNode] = ctx.env.horizontalSizeClass == .compact
            ? [pageFrame, PaddingNode(EdgeInsets(bottom: 12), bar)]
            : [PaddingNode(EdgeInsets(top: 12), bar), pageFrame]
        return [StackNode(axis: .vertical, alignment: 0.5, spacing: 12, children: content)]
    }

    private func containsVerticalScroll(_ node: LayoutNode) -> Bool {
        if let container = node as? ContainerNode, case .scroll(_, true, true) = container.sizing { return true }
        return node.children.contains(where: containsVerticalScroll)
    }
}

extension TabView {
    @_disfavoredOverload public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) { self.content = content(); self.selection = selection }
}
extension TabView where SelectionValue == Int {
    public init(@ViewBuilder content: () -> Content) { self.content = content(); selection = nil }
}

@MainActor private struct TabBarItem {
    let title: String
    let label: AnyView

    init(title: String, label: AnyView? = nil) {
        self.title = title
        self.label = label ?? AnyView(Text(title))
    }
}

private final class TabItemNode: LayoutNode {
    let item: TabBarItem
    let child: LayoutNode

    init(item: TabBarItem, child: LayoutNode) {
        self.item = item
        self.child = child
        super.init()
        tag = child.tag
        tagValue = child.tagValue
    }

    static func item(in node: LayoutNode) -> TabBarItem? {
        if let tab = node as? TabItemNode { return tab.item }
        if let scope = node as? ScopeNode { return item(in: scope.target) }
        if let tagged = node as? TaggedNode { return item(in: tagged.child) }
        return nil
    }

    override var children: [LayoutNode] { [child] }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

private struct MobileTabBar: View {
    let items: [TabBarItem]
    let selected: Int
    let profile: MobilePreviewProfile
    let select: @MainActor (Int) -> Void

    private let itemInset: CGFloat = 5

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                MobileTabButton(item: items[index], isSelected: index == selected,
                                height: profile.tabBarHeight - itemInset * 2) { select(index) }
            }
        }
        .padding(itemInset)
        .frame(maxWidth: profile == .ipad ? 460 : .infinity)
        .background { MobileGlassSurface(.tabBar) }
        .padding(.horizontal, profile.tabBarHorizontalInset)
        .padding(.bottom, profile.tabBarBottomInset)
    }
}

private struct MobileTabButton: View, PrimitiveView {
    typealias Body = Never
    let item: TabBarItem
    let isSelected: Bool
    let height: CGFloat
    let select: @MainActor () -> Void

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let backend = ctx.host.backend
        let widget = ctx.widget(.button)
        var props = ctx.baseProps()
        props.title = item.title
        props.hasContent = true
        props.bordered = false
        var events = WidgetEvents()
        let enabled = ctx.env.isEnabled
        events.onTap = { if enabled { select() } }
        if let widget { backend.update(widget, props: props, events: events) }
        let insets = widget.map { backend.contentInsets($0) } ?? .zero

        let labels = ctx.with { env in
            let usesProAppearance = env._mobilePreviewProfile == .iphonePro
            env.font = .system(size: usesProAppearance ? 11 : 10, weight: .medium)
            let unselected = usesProAppearance ? Color.primary : Color.secondary
            env._foreground = AnyShapeStyle(isSelected ? Color.accentColor : unselected)
            env._labelStyle = .titleAndIcon
            env._mobileTabSymbol = usesProAppearance
        }.resolve(item.label, "label")
        let label = StackNode(axis: .vertical, alignment: 0.5, spacing: 2, children: labels)
        let labelFrame = FrameNode(child: label, alignment: .center)
        labelFrame.height = max(0, height - insets.top - insets.bottom)
        labelFrame.minWidth = 0
        labelFrame.maxWidth = .infinity
        let button = ContainerNode(widget: widget, backend: backend, content: labelFrame, sizing: .hug, insets: insets)
        let frame = FrameNode(child: button, alignment: .center)
        frame.minWidth = 0
        frame.maxWidth = .infinity
        guard isSelected else { return [frame] }
        let pill = ctx.resolve(MobileGlassSurface(.selection), "selected")
        return [LayerNode(primary: frame, secondary: pill, alignment: .center, behind: true)]
    }
}

@MainActor private protocol MobileTabItemLabel {
    var mobileTabLabel: AnyView { get }
}

extension Label: MobileTabItemLabel {
    fileprivate var mobileTabLabel: AnyView {
        AnyView(VStack(spacing: 2) {
            icon.font(.system(size: 24))
            title.lineLimit(1)
        })
    }
}

public struct Tab<Value: Hashable, Content: View>: View {
    let title: String
    let systemImage: String
    let value: Value?
    let content: Content
    public init(_ title: String, systemImage: String, value: Value, @ViewBuilder content: () -> Content) {
        self.title = title; self.systemImage = systemImage; self.value = value; self.content = content()
    }
    public init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) where Value == Never {
        self.title = title; self.systemImage = systemImage; value = nil; self.content = content()
    }
    public var body: some View {
        let label = Label(title, systemImage: systemImage).mobileTabLabel
        let item = TabBarItem(title: title, label: label)
        return content.eachNode("tab") { n, _ in
            let node = TabItemNode(item: item, child: n)
            if let value {
                node.tag = AnyHashable(value)
                node.tagValue = value
            }
            return node
        }
    }
}

extension View {
    public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> some View {
        let l = label()
        return nodes("tabItem") { ns, ctx in
            let mobileLabel = (l as? any MobileTabItemLabel)?.mobileTabLabel ?? AnyView(l)
            let item = TabBarItem(title: ctx.labelText(l), label: mobileLabel)
            return ns.map { TabItemNode(item: item, child: $0) }
        }
    }
}

// MARK: ContentUnavailableView

public struct ContentUnavailableView<Label: View, Description: View, Actions: View>: View {
    let label: Label
    let description: Description
    let actions: Actions
    public init(@ViewBuilder label: () -> Label, @ViewBuilder description: () -> Description = { EmptyView() }, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.label = label(); self.description = description(); self.actions = actions()
    }
    public var body: some View {
        VStack(spacing: 8) {
            label.font(.system(size: 22, weight: .semibold)).labelStyle(_VerticalLabels())
            description.font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            actions
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Icon above title, as ContentUnavailableView shows its label.
struct _VerticalLabels: LabelStyle {
    var _kind: _StyleToken { _StyleToken(name: "automatic") }
    func makeBody(configuration: LabelStyleConfiguration) -> Never { fatalError("built-in style") }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    public init(_ title: LocalizedStringKey, systemImage name: String, description: Text? = nil) {
        self.init(label: { SwiftUI.Label(title, systemImage: name) }, description: { description })
    }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage name: String, description: Text? = nil) {
        self.init(label: { SwiftUI.Label(title, systemImage: name) }, description: { description })
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text, Actions == EmptyView {
    public static var search: ContentUnavailableView<SwiftUI.Label<Text, Image>, Text, EmptyView> {
        ContentUnavailableView(label: { SwiftUI.Label("No Results", systemImage: "magnifyingglass") }, description: { Text("Check the spelling or try a new search.") }, actions: { EmptyView() })
    }
}

// MARK: Toolbar and titles

public struct ToolbarItem<ID, Content: View>: View {
    let content: Content
    let placement: ToolbarItemPlacement
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == Void {
        self.placement = placement
        self.content = content()
    }
    public init(id: String, placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == String {
        self.placement = placement
        self.content = content()
    }
    public var body: some View { MobileToolbarItem(placement: placement, content: content) }
}

public struct ToolbarItemGroup<Content: View>: View {
    let content: Content
    let placement: ToolbarItemPlacement
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) {
        self.placement = placement
        self.content = content()
    }
    public var body: some View { MobileToolbarItem(placement: placement, content: content) }
}

public struct ToolbarSpacer: View {
    public init(_ sizing: Any? = nil, placement: ToolbarItemPlacement = .automatic) {}
    public var body: some View { Spacer() }
}

public struct ToolbarItemPlacement: Sendable {
    enum Region: Sendable { case leading, center, trailing, bottom }
    let region: Region
    public static let automatic = Self(region: .trailing), principal = Self(region: .center), navigation = Self(region: .leading)
    public static let primaryAction = Self(region: .trailing), secondaryAction = Self(region: .trailing), status = Self(region: .center)
    public static let confirmationAction = Self(region: .trailing), cancellationAction = Self(region: .leading), destructiveAction = Self(region: .trailing)
    public static let topBarLeading = Self(region: .leading), topBarTrailing = Self(region: .trailing), bottomBar = Self(region: .bottom)
    public static let navigationBarLeading = topBarLeading, navigationBarTrailing = topBarTrailing
}

public typealias ToolbarContentBuilder = ViewBuilder

extension View {
    /// The toolbar is a bar above the content (GTK and Win32 have no
    /// unified title bar to merge it into).
    public func toolbar<C: View>(@ViewBuilder content: () -> C) -> some View {
        let bar = content()
        return NavigationToolbar(content: self, bar: bar)
    }
    public func toolbar(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View {
        navigationPreference("toolbarVisibility") { _ in
            bars.isEmpty || bars.contains(.automatic) || bars.contains(.navigationBar) ? .visibility(visibility) : nil
        }
    }
    public func toolbarBackground(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View {
        navigationPreference("toolbarBackgroundVisibility") { _ in
            bars.isEmpty || bars.contains(.automatic) || bars.contains(.navigationBar) ? .background(visibility) : nil
        }
    }
    public func toolbarTitleDisplayMode(_ mode: Any) -> some View { self }
    public func navigationTitle(_ title: String) -> some View {
        nodes("title") { ns, ctx in
            if ctx.env._collectsNavigationBar { return navigationNodes(ns, with: .title(title), in: ctx) }
            if !ctx.dryRun { ctx.host.title = title }
            return ns
        }
    }
    public func navigationTitle(_ title: Text) -> some View { navigationTitle(title.plainText) }
    public func navigationTitle(_ key: LocalizedStringKey) -> some View { navigationTitle(key.string) }
    public func navigationSubtitle(_ s: String) -> some View { self }
    public func navigationSplitViewColumnWidth(_ w: CGFloat) -> some View { self }
    public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View { self }
}

public enum ToolbarPlacement: Hashable, Sendable { case automatic, windowToolbar, navigationBar, tabBar, bottomBar }
