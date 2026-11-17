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
        let rows = ctx.with { $0._stackAxis = .vertical }.resolve(content, "list")
        var out: [LayoutNode] = []
        for (i, row) in rows.enumerated() {
            var node: LayoutNode = PaddingNode(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10), fillWidth(row))
            if let tag = row.tag, let selection {
                // Selectable rows: tap to select, the selection highlighted.
                if selection.contains(tag) {
                    let bg = ctx.child("sel\(i)").resolve(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.2)), "bg")
                    node = LayerNode(primary: node, secondary: bg, alignment: .center, behind: true)
                }
                let w = ctx.widget(.tapArea, "row\(i)")
                var events = WidgetEvents()
                let value = row.tagValue
                events.onTap = { selection.select(value) }
                if let w { ctx.host.backend.update(w, props: ctx.baseProps(), events: events) }
                node = ContainerNode(widget: w, backend: ctx.host.backend, content: node, sizing: .hug)
            }
            out.append(fillWidth(node))
        }
        let stack = PaddingNode(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0), StackNode(axis: .vertical, alignment: 0, spacing: 0, children: out))
        let w = ctx.widget(.scroll(horizontal: false, vertical: true))
        if let w { ctx.host.backend.update(w, props: WidgetProps(), events: WidgetEvents()) }
        return [ContainerNode(widget: w, backend: ctx.host.backend, content: stack, sizing: .scroll(horizontal: false, vertical: true, enabled: true))]
    }
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

public struct NavigationStack<Content: View>: View {
    let content: Content
    public init(@ViewBuilder root: () -> Content) { content = root() }
    public init<P>(path: Binding<P>, @ViewBuilder root: () -> Content) { content = root() }
    public var body: some View { content }
}

public typealias NavigationView = NavigationStack

public struct NavigationLink<Label: View, Destination: View>: View {
    let label: Label
    public init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) { self.label = label() }
    public init<V: Hashable>(value: V?, @ViewBuilder label: () -> Label) where Destination == EmptyView { self.label = label() }
    public var body: some View { label }
}

extension NavigationLink where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder destination: () -> Destination) { label = Text(titleKey) }
}

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

public struct TabView<SelectionValue: Hashable, Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let content: Content
    let selection: Binding<SelectionValue>?

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        // Tabs are the content's children; their labels come from .tabItem.
        var dry = ctx
        dry.dryRun = true
        let probes = dry.resolve(content, "tabs")
        let titles = probes.enumerated().map { i, n in (n as? TabItemNode)?.title ?? "Tab \(i + 1)" }
        let key = ctx.path + "$tab"
        let local = ctx.host.stateBox(key) { 0 }
        var index = local.value
        if let selection, let i = probes.firstIndex(where: { $0.tag == AnyHashable(selection.wrappedValue) }) { index = i }
        index = min(max(0, index), max(0, probes.count - 1))

        let kids = ctx.resolve(content, "tabs")
        var events = WidgetEvents()
        events.onSelect = { i in
            local.set(i)
            if let selection, probes.indices.contains(i), let v = probes[i].tagValue as? SelectionValue { selection.wrappedValue = v }
        }
        var p = ctx.baseProps()
        p.options = titles
        p.selected = index
        let w = ctx.widget(.segmented, "tabs")
        if let w { ctx.host.backend.update(w, props: p, events: events) }
        let bar = WidgetNode(w, backend: ctx.host.backend)
        let page: [LayoutNode] = kids.indices.contains(index) ? [kids[index]] : []
        let pageFrame = FrameNode(child: page.first ?? StackNode(axis: .vertical, alignment: 0, spacing: 0, children: []), alignment: .top)
        pageFrame.maxWidth = .infinity
        pageFrame.maxHeight = .infinity
        return [StackNode(axis: .vertical, alignment: 0.5, spacing: 12, children: [PaddingNode(EdgeInsets(top: 12), bar), pageFrame])]
    }
}

extension TabView {
    @_disfavoredOverload public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) { self.content = content(); self.selection = selection }
}
extension TabView where SelectionValue == Int {
    public init(@ViewBuilder content: () -> Content) { self.content = content(); selection = nil }
}

final class TabItemNode: LayoutNode {
    let title: String
    let child: LayoutNode
    init(title: String, child: LayoutNode) { self.title = title; self.child = child; super.init(); tag = child.tag; tagValue = child.tagValue }
    override var children: [LayoutNode] { [child] }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

public struct Tab<Value: Hashable, Content: View>: View {
    let title: String
    let value: Value?
    let content: Content
    public init(_ title: String, systemImage: String, value: Value, @ViewBuilder content: () -> Content) { self.title = title; self.value = value; self.content = content() }
    public init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) where Value == Never { self.title = title; value = nil; self.content = content() }
    public var body: some View {
        let t = title
        return content.eachNode("tab") { n, _ in
            let node = TabItemNode(title: t, child: n)
            return node
        }
    }
}

extension View {
    public func tabItem<V: View>(@ViewBuilder _ label: () -> V) -> some View {
        let l = label()
        return nodes("tabItem") { ns, ctx in
            let title = ctx.labelText(l)
            return ns.map { TabItemNode(title: title, child: $0) }
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
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == Void { self.content = content() }
    public init(id: String, placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) where ID == String { self.content = content() }
    public var body: some View { content }
}

public struct ToolbarItemGroup<Content: View>: View {
    let content: Content
    public init(placement: ToolbarItemPlacement = .automatic, @ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { content }
}

public struct ToolbarSpacer: View {
    public init(_ sizing: Any? = nil, placement: ToolbarItemPlacement = .automatic) {}
    public var body: some View { Spacer() }
}

public struct ToolbarItemPlacement: Sendable {
    public static let automatic = ToolbarItemPlacement(), principal = ToolbarItemPlacement(), navigation = ToolbarItemPlacement()
    public static let primaryAction = ToolbarItemPlacement(), secondaryAction = ToolbarItemPlacement(), status = ToolbarItemPlacement()
    public static let confirmationAction = ToolbarItemPlacement(), cancellationAction = ToolbarItemPlacement(), destructiveAction = ToolbarItemPlacement()
}

public typealias ToolbarContentBuilder = ViewBuilder

extension View {
    /// The toolbar is a bar above the content (GTK and Win32 have no
    /// unified title bar to merge it into).
    public func toolbar<C: View>(@ViewBuilder content: () -> C) -> some View {
        let bar = content()
        return VStack(spacing: 0) {
            HStack(spacing: 8) { bar }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Divider()
            self.frame(maxHeight: .infinity)
        }
    }
    public func toolbar(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    public func toolbarBackground(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    public func toolbarTitleDisplayMode(_ mode: Any) -> some View { self }
    public func navigationTitle(_ title: String) -> some View {
        nodes("title") { ns, ctx in
            if !ctx.dryRun { ctx.host.title = title }
            return ns
        }
    }
    public func navigationTitle(_ title: Text) -> some View { navigationTitle(title.plainText) }
    public func navigationTitle(_ key: LocalizedStringKey) -> some View { navigationTitle(key.string) }
    public func navigationSubtitle(_ s: String) -> some View { self }
    public func navigationSplitViewColumnWidth(_ w: CGFloat) -> some View { self }
    public func navigationSplitViewColumnWidth(min: CGFloat? = nil, ideal: CGFloat, max: CGFloat? = nil) -> some View { self }
    public func navigationDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View { self }
}

public struct ToolbarPlacement: Sendable {
    public static let automatic = ToolbarPlacement(), windowToolbar = ToolbarPlacement()
}
