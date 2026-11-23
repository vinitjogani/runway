import Foundation
import RunwayCore

private struct CollectNavigationBarKey: EnvironmentKey { static let defaultValue = false }
private struct RenderToolbarKey: EnvironmentKey { static let defaultValue = false }
private struct MobileToolbarItemKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var _collectsNavigationBar: Bool {
        get { self[CollectNavigationBarKey.self] }
        set { self[CollectNavigationBarKey.self] = newValue }
    }
    var _mobileToolbarItem: Bool { self[MobileToolbarItemKey.self] }
}

enum NavigationPreference {
    case title(String)
    case displayMode(NavigationBarItem.TitleDisplayMode)
    case visibility(Visibility)
    case background(Visibility)
    case toolbar(AnyView, EnvironmentValues)
    case backdrop(AnyView, EnvironmentValues)
}

extension View {
    func navigationPreference(_ name: String, _ preference: @escaping @MainActor (ResolveContext) -> NavigationPreference?) -> some View {
        nodes(name) { children, ctx in
            guard ctx.env._collectsNavigationBar, let value = preference(ctx) else { return children }
            return navigationNodes(children, with: value, in: ctx)
        }
    }
}

func navigationNodes(_ children: [LayoutNode], with preference: NavigationPreference, in ctx: ResolveContext) -> [LayoutNode] {
    // A title or a toolbar label can read state owned by the visible screen.
    // Rebuild its navigation bar whenever that screen's preference changes.
    ctx.scope?.volatile = true
    let content = children.count == 1 ? children[0] : StackNode(axis: .vertical, alignment: 0, spacing: 0, children: children)
    return [NavigationPreferenceNode(content, preference: preference)]
}

func navigationBackdrop<V: View>(_ layer: LayerNode, background: V, in ctx: ResolveContext) -> LayoutNode {
    guard ctx.env._collectsNavigationBar, layer.behind, layer.alignment == .center else { return layer }
    return NavigationPreferenceNode(layer, preference: .backdrop(AnyView(background), ctx.env))
}

private final class NavigationPreferenceNode: LayoutNode {
    let child: LayoutNode
    let preference: NavigationPreference

    init(_ child: LayoutNode, preference: NavigationPreference) {
        self.child = child
        self.preference = preference
        super.init()
        layoutPriority = child.layoutPriority
        tag = child.tag
        tagValue = child.tagValue
    }

    override var children: [LayoutNode] { [child] }
    override var isEmptyLayout: Bool { child.isEmptyLayout }
    override var isSpacer: Bool { child.isSpacer }
    override var textContent: String? { child.textContent }
    override var menuItem: MenuItemSpec? { child.menuItem }
    override func sizeThatFits(_ proposal: ProposedSize) -> CGSize { child.size(proposal) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

struct NavigationToolbar<Content: View, Bar: View>: View, PrimitiveView {
    typealias Body = Never
    let content: Content
    let bar: Bar

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        if ctx.env._collectsNavigationBar {
            return navigationNodes(ctx.resolve(content, "content"), with: .toolbar(AnyView(bar), ctx.env), in: ctx)
        }
        return ctx.resolve(VStack(spacing: 0) {
            HStack(spacing: 8) { bar }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Divider()
            content.frame(maxHeight: .infinity)
        }, "toolbar")
    }
}

struct MobileToolbarItem<Content: View>: View, PrimitiveView {
    typealias Body = Never
    let placement: ToolbarItemPlacement
    let content: Content

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        guard ctx.env[RenderToolbarKey.self] else { return ctx.resolve(content, "content") }
        let label = HStack(spacing: 0) { content }
        let group: AnyView
        if placement.region == .center {
            group = AnyView(label)
        } else {
            let padding: CGFloat = ctx.labelText(content).isEmpty ? 0 : 12
            group = AnyView(label.padding(.horizontal, padding)
                .frame(minWidth: 44, minHeight: 44)
                .background { MobileGlassSurface(.toolbar) })
        }
        let nodes = ctx.resolve(group, "group")
        return nodes.map { PositionedToolbarNode($0, region: placement.region) }
    }
}

private final class PositionedToolbarNode: LayoutNode {
    let child: LayoutNode
    let region: ToolbarItemPlacement.Region

    init(_ child: LayoutNode, region: ToolbarItemPlacement.Region) {
        self.child = child
        self.region = region
    }

    override var children: [LayoutNode] { [child] }
    override func sizeThatFits(_ proposal: ProposedSize) -> CGSize { child.size(proposal) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

private func navigationPreferences(in node: LayoutNode) -> [NavigationPreference] {
    guard !(node is NavigationBoundaryNode) else { return [] }
    let nested = node.children.flatMap(navigationPreferences)
    if let wrapper = node as? NavigationPreferenceNode { return nested + [wrapper.preference] }
    return nested
}

/// Read the backdrop attached to the viewport itself. Backgrounds on scroll
/// rows and other leaf views stay inside the content area.
private func viewportBackdrop(in node: LayoutNode) -> (AnyView, EnvironmentValues)? {
    if let preference = node as? NavigationPreferenceNode,
       case let .backdrop(view, environment) = preference.preference,
       containsViewport(preference.child) { return (view, environment) }
    if let layer = node as? LayerNode { return viewportBackdrop(in: layer.primary) }
    guard !(node is ContainerNode || node is NavigationBoundaryNode), node.children.count == 1 else { return nil }
    return viewportBackdrop(in: node.children[0])
}

private func containsViewport(_ node: LayoutNode) -> Bool {
    if let container = node as? ContainerNode, case .scroll = container.sizing { return true }
    if let layer = node as? LayerNode { return containsViewport(layer.primary) }
    return node.children.count == 1 && containsViewport(node.children[0])
}

private func positionedToolbarItems(in node: LayoutNode) -> [PositionedToolbarNode] {
    if let item = node as? PositionedToolbarNode { return [item] }
    return node.children.flatMap(positionedToolbarItems)
}

func mobileNavigationNodes(_ content: [LayoutNode], back: (@MainActor () -> Void)?, reservesTopSafeArea: Bool, in ctx: ResolveContext) -> [LayoutNode] {
    var title = ""
    var mode = NavigationBarItem.TitleDisplayMode.automatic
    var visibility = Visibility.automatic
    var background = Visibility.automatic
    var toolbars: [(AnyView, EnvironmentValues)] = []
    for preference in content.flatMap(navigationPreferences) {
        switch preference {
        case .title(let value): title = value
        case .displayMode(let value): mode = value
        case .visibility(let value): visibility = value
        case .background(let value): background = value
        case .toolbar(let view, let environment): toolbars.append((view, environment))
        case .backdrop: break
        }
    }
    ctx.host.title = title

    let profile = ctx.env._mobilePreviewProfile ?? .iphonePro
    var top: [LayoutNode] = []
    if reservesTopSafeArea {
        top += ctx.resolve(Color.clear.frame(height: profile.topSafeArea), "statusArea")
    }

    func toolbarContext(_ environment: EnvironmentValues) -> ResolveContext {
        ctx.with {
            $0 = environment
            $0._collectsNavigationBar = false
            $0[RenderToolbarKey.self] = true
            $0[MobileToolbarItemKey.self] = true
            if $0._buttonStyle == .automatic { $0._buttonStyle = .plain }
        }
    }

    var regions: [ToolbarItemPlacement.Region: [LayoutNode]] = [:]
    for (offset, toolbar) in toolbars.enumerated() where visibility != .hidden {
        let nodes = toolbarContext(toolbar.1).resolve(toolbar.0, "toolbar\(offset)")
        for node in nodes where !node.isEmptyLayout {
            let items = positionedToolbarItems(in: node)
            if items.isEmpty { regions[.trailing, default: []].append(node) }
            for item in items { regions[item.region, default: []].append(item) }
        }
    }
    if let back, visibility != .hidden {
        let backButton = MobileToolbarItem(placement: .topBarLeading, content: Button(action: back) {
            Image(systemName: "chevron.left").font(.body.weight(.semibold)).accessibilityLabel("Back")
        })
        regions[.leading, default: []].insert(contentsOf: toolbarContext(ctx.env).resolve(backButton, "navigationBack"), at: 0)
    }

    let hasItems = [.leading, .center, .trailing].contains { regions[$0] != nil }
    if visibility != .hidden && (!title.isEmpty || visibility == .visible || hasItems) {
        var center = regions[.center] ?? []
        if center.isEmpty, !title.isEmpty, mode != .large {
            center = ctx.resolve(Text(title).font(.headline.weight(.semibold)).lineLimit(1), "navigationTitle")
        }
        let row = MobileNavigationBarNode(leading: regions[.leading] ?? [], center: center, trailing: regions[.trailing] ?? [], profile: profile)
        let surface = ctx.env.colorScheme == .dark ? Color.black : Color.white
        top.append(background == .visible ? LayerNode(primary: row, secondary: ctx.resolve(surface, "navigationBackground"), alignment: .center, behind: true) : row)
        if mode == .large, !title.isEmpty {
            top += ctx.resolve(Text(title).font(.largeTitle.bold()).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 8), "largeNavigationTitle")
        }
    }
    if !top.isEmpty, content.count == 1, let (backdrop, environment) = viewportBackdrop(in: content[0]) {
        let context = ctx.with { $0 = environment; $0._collectsNavigationBar = false }
        let layer = context.resolve(backdrop, "chromeBackdrop")
        top = [LayerNode(primary: StackNode(axis: .vertical, alignment: 0, spacing: 0, children: top), secondary: layer,
                         alignment: .center, behind: true)]
    }
    let bottom = regions[.bottom].map { [MobileNavigationBarNode(leading: [], center: $0, trailing: [], profile: profile)] } ?? []
    return [MobileNavigationViewport(header: top, content: content, footer: bottom)]
}

/// Reserve space for the bars while drawing their material above the content.
private final class MobileNavigationViewport: LayoutNode {
    let header: LayoutNode
    let content: LayoutNode
    let footer: LayoutNode

    init(header: [LayoutNode], content: [LayoutNode], footer: [LayoutNode]) {
        func column(_ children: [LayoutNode]) -> LayoutNode {
            children.count == 1 ? children[0] : StackNode(axis: .vertical, alignment: 0, spacing: 0, children: children)
        }
        self.header = column(header)
        self.content = column(content)
        self.footer = column(footer)
    }

    override var children: [LayoutNode] { [content, header, footer] }

    private func barSizes(width: CGFloat?) -> (header: CGSize, footer: CGSize) {
        let proposal = ProposedSize(width: width, height: nil)
        return (header.size(proposal), footer.size(proposal))
    }

    override func sizeThatFits(_ proposal: ProposedSize) -> CGSize {
        let (head, foot) = barSizes(width: proposal.width)
        let reserved = head.height + foot.height
        let body = content.size(ProposedSize(width: proposal.width, height: proposal.height.map { max(0, $0 - reserved) }))
        return CGSize(width: max(head.width, body.width, foot.width), height: reserved + body.height)
    }

    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        let (head, foot) = barSizes(width: rect.width)
        let bodyHeight = max(0, rect.height - head.height - foot.height)
        content.place(CGRect(x: rect.minX, y: rect.minY + head.height, width: rect.width, height: bodyHeight), sink)
        header.place(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: head.height), sink)
        footer.place(CGRect(x: rect.minX, y: rect.minY + head.height + bodyHeight, width: rect.width, height: foot.height), sink)
    }
}

/// Keeps the title centered independently of the leading and trailing tools.
private final class MobileNavigationBarNode: LayoutNode {
    let leading: LayoutNode
    let center: LayoutNode
    let trailing: LayoutNode
    let profile: MobilePreviewProfile

    init(leading: [LayoutNode], center: [LayoutNode], trailing: [LayoutNode], profile: MobilePreviewProfile) {
        func group(_ items: [LayoutNode]) -> LayoutNode {
            StackNode(axis: .horizontal, alignment: 0.5, spacing: 8, children: items)
        }
        self.leading = group(leading)
        self.center = group(center)
        self.trailing = group(trailing)
        self.profile = profile
    }

    override var children: [LayoutNode] { [leading, center, trailing] }

    private func measurements(width: CGFloat?) -> (CGSize, CGSize, CGSize) {
        let inset = profile.toolbarHorizontalInset
        let sideProposal = ProposedSize(width: width.map { max(0, $0 / 2 - inset) }, height: nil)
        let lhs = leading.size(sideProposal)
        let rhs = trailing.size(sideProposal)
        let titleWidth = width.map { max(0, $0 - 2 * (max(lhs.width, rhs.width) + inset)) }
        return (lhs, center.size(ProposedSize(width: titleWidth, height: nil)), rhs)
    }

    override func sizeThatFits(_ proposal: ProposedSize) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let (lhs, title, rhs) = measurements(width: width)
        return CGSize(width: width ?? 2 * (max(lhs.width, rhs.width) + profile.toolbarHorizontalInset) + title.width,
                      height: max(profile.toolbarHeight, lhs.height, title.height, rhs.height))
    }

    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        let (lhs, title, rhs) = measurements(width: rect.width)
        let padding = profile.toolbarHorizontalInset
        leading.place(CGRect(x: rect.minX + padding, y: rect.midY - lhs.height / 2, width: lhs.width, height: lhs.height), sink)
        center.place(CGRect(x: rect.midX - title.width / 2, y: rect.midY - title.height / 2, width: title.width, height: title.height), sink)
        trailing.place(CGRect(x: rect.maxX - padding - rhs.width, y: rect.midY - rhs.height / 2, width: rhs.width, height: rhs.height), sink)
    }
}
