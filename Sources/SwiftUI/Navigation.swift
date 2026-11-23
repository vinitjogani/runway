// In-window navigation for SwiftUI stack previews.

import Foundation
import RunwayCore

public struct NavigationPath {
    var values: [AnyHashable] = []
    public init() {}
    public init<S: Sequence>(_ elements: S) where S.Element: Hashable { values = elements.map(AnyHashable.init) }
    public var count: Int { values.count }
    public var isEmpty: Bool { values.isEmpty }
    public mutating func append<V: Hashable>(_ value: V) { values.append(AnyHashable(value)) }
    public mutating func removeLast(_ count: Int = 1) { values.removeLast(count) }
}

private enum NavigationRoute {
    case value(AnyHashable)
    case view(AnyView)
}

private struct NavigationPush: @unchecked Sendable {
    var action: (@MainActor (NavigationRoute) -> Void)?
}

private struct NavigationPushKey: EnvironmentKey { static var defaultValue: NavigationPush { NavigationPush() } }

public struct NavigationStack<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    private let content: Content
    private let path: Binding<[AnyHashable]>?

    public init(@ViewBuilder root: () -> Content) { content = root(); path = nil }

    public init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Content) {
        content = root()
        self.path = path.values
    }

    public init<P: RandomAccessCollection & RangeReplaceableCollection>(path: Binding<P>, @ViewBuilder root: () -> Content) where P.Element: Hashable {
        content = root()
        self.path = Binding(get: { path.wrappedValue.map(AnyHashable.init) }, set: { values in
            let elements = values.compactMap { $0.base as? P.Element }
            if elements.count == values.count { path.wrappedValue = P(elements) }
        })
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        if ctx.dryRun { return ctx.resolve(content, "root") }
        let local = ctx.host.stateBox(ctx.path + "$routes") { [NavigationRoute]() }
        let path = self.path
        let push = NavigationPush { route in
            if case .value(let value) = route, let path, local.value.isEmpty {
                path.wrappedValue.append(value)
                local.set([])
            } else {
                local.set(local.value + [route])
            }
        }
        let stack = ctx.with {
            $0[NavigationPushKey.self] = push
            $0._collectsNavigationBar = $0._mobilePreview
        }
        var current = stack.resolve(content, "root")
        var pop: (@MainActor () -> Void)?
        var registrations: [NavigationRegistrationNode] = []
        let pathValues = path?.wrappedValue ?? []
        let routes = pathValues.map(NavigationRoute.value) + local.value

        for (index, route) in routes.enumerated() {
            registrations += current.flatMap(navigationRegistrations)
            let destination: AnyView?
            switch route {
            case .value(let value): destination = registrations.reversed().lazy.compactMap { $0.match?(value) }.first
            case .view(let view): destination = view
            }
            guard let destination else { break }
            let back: @MainActor () -> Void = {
                if index < pathValues.count, let path {
                    path.wrappedValue = Array(pathValues.prefix(index))
                    local.set([])
                } else {
                    local.set(Array(local.value.prefix(index - pathValues.count)))
                }
            }
            let key: String
            if case .value(let value) = route { key = "page\(index):\(value.hashValue)" } else { key = "page\(index)" }
            current = stack.with { $0.dismiss = DismissAction(back) }.resolve(destination, key)
            pop = back
        }

        // Boolean and item destinations stay registered on their source screen.
        // Keep that screen's storage alive while displaying its destination.
        var presented = Set<String>()
        while let page = current.flatMap(navigationRegistrations).lazy.compactMap(\.page).first,
              presented.insert(page.id).inserted {
            current = stack.with { $0.dismiss = DismissAction(page.dismiss) }.resolve(page.content, "presented:" + page.id)
            pop = page.dismiss
        }

        let hidesBackButton = current.flatMap(navigationRegistrations).contains(where: \.hidesBackButton)
        if ctx.env._mobilePreview {
            let screen = mobileNavigationNodes(current, back: hidesBackButton ? nil : pop,
                                               reservesTopSafeArea: !ctx.env._collectsNavigationBar, in: stack)
            return [NavigationBoundaryNode(screen, fillsViewport: true)]
        }
        let content = NavigationBoundaryNode(current)
        guard let pop, !hidesBackButton else { return [content] }
        let back = stack.resolve(
            Button(action: pop) { Label("Back", systemImage: "chevron.left") }
                .buttonStyle(.plain).padding(.horizontal, 12).frame(minHeight: 36)
                .frame(maxWidth: .infinity, alignment: .leading), "back")
        return [NavigationBoundaryNode(back + [content])]
    }
}

public typealias NavigationView = NavigationStack

public struct NavigationLink<Label: View, Destination: View>: View, PrimitiveView {
    public typealias Body = Never
    private let label: Label
    private let route: NavigationRoute?

    public init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {
        self.label = label()
        route = .view(AnyView(destination()))
    }

    public init<V: Hashable>(value: V?, @ViewBuilder label: () -> Label) where Destination == EmptyView {
        self.label = label()
        route = value.map { .value(AnyHashable($0)) }
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        guard let route, let push = ctx.env[NavigationPushKey.self].action else { return ctx.resolve(label, "label") }
        return ctx.resolve(Button(action: { push(route) }) { label }.buttonStyle(.plain), "link")
    }
}

extension NavigationLink where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder destination: () -> Destination) {
        self.init(destination: destination, label: { Text(titleKey) })
    }
    public init<V: Hashable>(_ titleKey: LocalizedStringKey, value: V?) where Destination == EmptyView {
        self.init(value: value, label: { Text(titleKey) })
    }
}

public struct NavigationBarItem {
    public enum TitleDisplayMode: Sendable { case automatic, inline, large }
}

extension View {
    public func navigationBarTitleDisplayMode(_ mode: NavigationBarItem.TitleDisplayMode) -> some View {
        navigationPreference("navigationBarTitleDisplayMode") { _ in .displayMode(mode) }
    }

    public func navigationDestination<D: Hashable, C: View>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        eachNode("navigationDestination") { node, _ in
            NavigationRegistrationNode(node, match: { value in (value.base as? D).map { AnyView(destination($0)) } })
        }
    }

    public func navigationDestination<C: View>(isPresented: Binding<Bool>, @ViewBuilder destination: @escaping () -> C) -> some View {
        eachNode("navigationPresentation") { node, ctx in
            ctx.scope?.volatile = true
            let page = isPresented.wrappedValue ? NavigationPage(id: ctx.path, content: AnyView(destination()), dismiss: { isPresented.wrappedValue = false }) : nil
            return NavigationRegistrationNode(node, page: page)
        }
    }

    public func navigationDestination<D: Hashable, C: View>(item: Binding<D?>, @ViewBuilder destination: @escaping (D) -> C) -> some View {
        eachNode("navigationItem") { node, ctx in
            ctx.scope?.volatile = true
            let page = item.wrappedValue.map { value in
                NavigationPage(id: ctx.path + ":\(value.hashValue)", content: AnyView(destination(value)), dismiss: { item.wrappedValue = nil })
            }
            return NavigationRegistrationNode(node, page: page)
        }
    }

    public func navigationBarBackButtonHidden(_ hidesBackButton: Bool = true) -> some View {
        eachNode("navigationBackButton") { node, _ in NavigationRegistrationNode(node, hidesBackButton: hidesBackButton) }
    }
}

private struct NavigationPage {
    let id: String
    let content: AnyView
    let dismiss: @MainActor () -> Void
}

private final class NavigationRegistrationNode: LayoutNode {
    let child: LayoutNode
    let match: ((AnyHashable) -> AnyView?)?
    let page: NavigationPage?
    let hidesBackButton: Bool

    init(_ child: LayoutNode, match: ((AnyHashable) -> AnyView?)? = nil, page: NavigationPage? = nil, hidesBackButton: Bool = false) {
        self.child = child
        self.match = match
        self.page = page
        self.hidesBackButton = hidesBackButton
        super.init()
        layoutPriority = child.layoutPriority
        tag = child.tag
        tagValue = child.tagValue
    }

    override var children: [LayoutNode] { [child] }
    override var isEmptyLayout: Bool { child.isEmptyLayout }
    override var isSpacer: Bool { child.isSpacer }
    override var menuItem: MenuItemSpec? { child.menuItem }
    override func sizeThatFits(_ proposal: ProposedSize) -> CGSize { child.size(proposal) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

final class NavigationBoundaryNode: LayoutNode {
    let child: LayoutNode
    init(_ nodes: [LayoutNode], fillsViewport: Bool = false) {
        let content = nodes.count == 1 ? nodes[0] : StackNode(axis: .vertical, alignment: 0, spacing: 0, children: nodes)
        if fillsViewport {
            let frame = FrameNode(child: content, alignment: .topLeading)
            frame.maxWidth = .infinity
            frame.maxHeight = .infinity
            child = frame
        } else {
            child = content
        }
    }
    override var children: [LayoutNode] { [child] }
    override func sizeThatFits(_ proposal: ProposedSize) -> CGSize { child.size(proposal) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

@MainActor private func navigationRegistrations(_ node: LayoutNode) -> [NavigationRegistrationNode] {
    guard !(node is NavigationBoundaryNode) else { return [] }
    let descendants = node.children.flatMap(navigationRegistrations)
    if let registration = node as? NavigationRegistrationNode { return descendants + [registration] }
    return descendants
}
