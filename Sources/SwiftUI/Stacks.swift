// Stacks, spacers, dividers, scroll views, grids, GeometryReader.

import Foundation
import RunwayCore

public struct VStack<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let kids = ctx.with { $0._stackAxis = .vertical }.resolve(content, "v")
        return [StackNode(axis: .vertical, alignment: alignment, spacing: spacing, children: kids)]
    }
}

public struct HStack<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let alignment: VerticalAlignment
    let spacing: CGFloat?
    let content: Content
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let kids = ctx.with { $0._stackAxis = .horizontal }.resolve(content, "h")
        return [StackNode(axis: .horizontal, alignment: alignment.fraction, spacing: spacing, children: kids)]
    }
}

public struct ZStack<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let alignment: Alignment
    let content: Content
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) { self.alignment = alignment; self.content = content() }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        [ZStackNode(alignment: alignment, children: ctx.with { $0._stackAxis = nil }.resolve(content, "z"))]
    }
}

/// Lazy stacks lay out eagerly here; fine for the sizes desktop apps show.
public struct LazyVStack<Content: View>: View {
    let stack: VStack<Content>
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        stack = VStack(alignment: alignment, spacing: spacing, content: content)
    }
    public var body: some View { stack }
}

public struct LazyHStack<Content: View>: View {
    let stack: HStack<Content>
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        stack = HStack(alignment: alignment, spacing: spacing, content: content)
    }
    public var body: some View { stack }
}

public struct Spacer: View, PrimitiveView {
    public typealias Body = Never
    let minLength: CGFloat?
    public init(minLength: CGFloat? = nil) { self.minLength = minLength }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] { [SpacerNode(minLength: minLength, axis: ctx.env._stackAxis)] }
}

public struct Divider: View, PrimitiveView {
    public typealias Body = Never
    public init() {}
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        if ctx.env._inMenu { return [DividerMarker()] }
        let w = ctx.widget(.divider)
        if let w { ctx.host.backend.update(w, props: WidgetProps(), events: WidgetEvents()) }
        let n = WidgetNode(w, backend: ctx.host.backend)
        // A line across the stack's other axis.
        if ctx.env._stackAxis == .horizontal { n.flexibleHeight = true } else { n.flexibleWidth = true }
        return [n]
    }
}

public struct ScrollView<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let axes: Axis.Set
    let showsIndicators: Bool
    let content: Content
    public init(_ axes: Axis.Set = .vertical, showsIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.axes = axes; self.showsIndicators = showsIndicators; self.content = content()
    }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let h = axes.contains(.horizontal), v = axes.contains(.vertical)
        let enabled = ctx.env.isScrollEnabled
        let clearance = v && enabled ? ctx.env._mobileTabBarInset : 0
        let kids = ctx.with { env in
            env._stackAxis = h && !v ? .horizontal : .vertical
            if clearance > 0 { env._mobileTabBarInset = 0 }
        }.resolve(content, "s")
        let inner: LayoutNode = kids.count == 1 ? kids[0] : StackNode(axis: h && !v ? .horizontal : .vertical, alignment: .center, spacing: nil, children: kids)
        let scrollContent = clearance > 0 ? PaddingNode(EdgeInsets(bottom: clearance), inner) : inner
        let widget = ctx.widget(enabled ? .scroll(horizontal: h, vertical: v) : .container)
        if let widget { ctx.host.backend.update(widget, props: WidgetProps(), events: WidgetEvents()) }
        return [ContainerNode(widget: widget, backend: ctx.host.backend, content: scrollContent, sizing: .scroll(horizontal: h, vertical: v, enabled: enabled))]
    }
}

public struct ScrollViewProxy {
    public func scrollTo<ID: Hashable>(_ id: ID, anchor: UnitPoint? = nil) {}
}

public struct ScrollViewReader<Content: View>: View {
    let content: (ScrollViewProxy) -> Content
    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) { self.content = content }
    public var body: some View { content(ScrollViewProxy()) }
}

public struct GridItem: Hashable, Sendable {
    public enum Size: Hashable, Sendable {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }
    public var size: Size
    public var spacing: CGFloat?
    public var alignment: Alignment?
    public init(_ size: Size = .flexible(), spacing: CGFloat? = nil, alignment: Alignment? = nil) {
        self.size = size; self.spacing = spacing; self.alignment = alignment
    }
}

public struct LazyVGrid<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let columns: [GridItem]
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let content: Content
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, pinnedViews: PinnedScrollableViews = [], @ViewBuilder content: () -> Content) {
        self.columns = columns; self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let kids = ctx.resolve(content, "grid")
        return [GridNode(columns: columns, spacing: columns.first?.spacing, rowSpacing: spacing, alignment: alignment, children: kids)]
    }
}

public typealias LazyHGrid = LazyVGrid

public struct PinnedScrollableViews: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let sectionHeaders = PinnedScrollableViews(rawValue: 1)
    public static let sectionFooters = PinnedScrollableViews(rawValue: 2)
}

/// Grid { GridRow { … } }: rows of cells with shared column widths.
public struct Grid<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let alignment: Alignment
    let hSpacing: CGFloat?, vSpacing: CGFloat?
    let content: Content
    public init(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; hSpacing = horizontalSpacing; vSpacing = verticalSpacing; self.content = content()
    }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        [StackNode(axis: .vertical, alignment: alignment.horizontal, spacing: vSpacing, children: ctx.resolve(content, "grid"))]
    }
}

public struct GridRow<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let alignment: VerticalAlignment
    let content: Content
    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) { self.alignment = alignment ?? .center; self.content = content() }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        [StackNode(axis: .horizontal, alignment: alignment.fraction, spacing: nil, children: ctx.with { $0._stackAxis = .horizontal }.resolve(content, "row"))]
    }
}

public struct GeometryProxy {
    public let size: CGSize
    public var safeAreaInsets: EdgeInsets { EdgeInsets() }
    public func frame(in space: CoordinateSpace) -> CGRect { CGRect(origin: .zero, size: size) }
    public func frame(in space: some CoordinateSpaceProtocol) -> CGRect { CGRect(origin: .zero, size: size) }
}

public enum CoordinateSpace: Hashable, @unchecked Sendable { case global, local, named(AnyHashable) }
public protocol CoordinateSpaceProtocol {}
public struct LocalCoordinateSpace: CoordinateSpaceProtocol {}
public struct GlobalCoordinateSpace: CoordinateSpaceProtocol {}
extension CoordinateSpaceProtocol where Self == LocalCoordinateSpace { public static var local: LocalCoordinateSpace { LocalCoordinateSpace() } }
extension CoordinateSpaceProtocol where Self == GlobalCoordinateSpace { public static var global: GlobalCoordinateSpace { GlobalCoordinateSpace() } }

public struct GeometryReader<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let content: (GeometryProxy) -> Content
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) { self.content = content }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let content = self.content
        let c = ctx.with { $0._stackAxis = nil }
        // Its content depends on the size: resizes run bodies again.
        if !ctx.dryRun { ctx.host.readsGeometry = true }
        return [GeometryNode { size in c.host.resolveLate { c.resolve(content(GeometryProxy(size: size)), "geo") } }]
    }
}

public struct ViewThatFits<Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let axes: Axis.Set
    let content: Content
    public init(in axes: Axis.Set = [.horizontal, .vertical], @ViewBuilder content: () -> Content) { self.axes = axes; self.content = content() }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] { [FitsNode(ctx.resolve(content, "fits"), axes: axes)] }
}

/// Liquid Glass containers group glass effects; layout is their content's.
public struct GlassEffectContainer<Content: View>: View {
    let content: Content
    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View { content }
}
