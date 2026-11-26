// The Layout protocol (custom containers that measure and place their
// subviews), ProposedViewSize, AnyLayout and the stack layouts, ViewDimensions,
// custom alignments (AlignmentID) and alignment guides.

import Foundation
import RunwayCore

public struct ProposedViewSize: Hashable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?
    public init(width: CGFloat?, height: CGFloat?) { self.width = width; self.height = height }
    public init(_ size: CGSize) { width = size.width; height = size.height }
    public static let zero = ProposedViewSize(width: 0, height: 0)
    public static let unspecified = ProposedViewSize(width: nil, height: nil)
    public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)
    public func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10)) -> CGSize {
        CGSize(width: width ?? size.width, height: height ?? size.height)
    }
    init(_ p: ProposedSize) { width = p.width; height = p.height }
    var proposedSize: ProposedSize { ProposedSize(width: width, height: height) }
}

// MARK: Alignment

public protocol AlignmentID {
    static func defaultValue(in context: ViewDimensions) -> CGFloat
}

/// What an alignment guide is: a fraction of the size (leading, center…),
/// a text baseline, or a custom AlignmentID.
enum GuideKind: Hashable, @unchecked Sendable {
    case fraction, firstBaseline, lastBaseline
    case custom(CustomGuide)
}

struct CustomGuide: Hashable, @unchecked Sendable {
    let id: AlignmentID.Type
    static func == (a: Self, b: Self) -> Bool { ObjectIdentifier(a.id) == ObjectIdentifier(b.id) }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(id)) }
}

/// A guide on one axis.
struct GuideKey: Hashable, Sendable {
    let vertical: Bool
    let kind: GuideKind
    let fraction: CGFloat
    /// Its value for a view that sets none: a fraction of the size; the
    /// bottom edge for a baseline; a custom guide's default.
    func defaultValue(_ size: CGSize) -> CGFloat {
        switch kind {
        case .fraction: return (vertical ? size.height : size.width) * fraction
        case .firstBaseline, .lastBaseline: return size.height
        case .custom(let c): return c.id.defaultValue(in: ViewDimensions(width: size.width, height: size.height))
        }
    }
}

public struct ViewDimensions {
    public let width: CGFloat
    public let height: CGFloat
    let explicit: (GuideKey) -> CGFloat?
    public init(width: CGFloat, height: CGFloat) { self.init(width: width, height: height) { _ in nil } }
    init(width: CGFloat, height: CGFloat, explicit: @escaping (GuideKey) -> CGFloat?) {
        self.width = width; self.height = height; self.explicit = explicit
    }
    private var size: CGSize { CGSize(width: width, height: height) }
    public subscript(guide: HorizontalAlignment) -> CGFloat { explicit(guide.guide) ?? guide.guide.defaultValue(size) }
    public subscript(guide: VerticalAlignment) -> CGFloat { explicit(guide.guide) ?? guide.guide.defaultValue(size) }
    public subscript(explicit guide: HorizontalAlignment) -> CGFloat? { explicit(guide.guide) }
    public subscript(explicit guide: VerticalAlignment) -> CGFloat? { explicit(guide.guide) }
}

extension HorizontalAlignment {
    public init(_ id: AlignmentID.Type) {
        self.init(fraction: id.defaultValue(in: ViewDimensions(width: 1, height: 1)), kind: .custom(CustomGuide(id: id)))
    }
}

extension VerticalAlignment {
    public init(_ id: AlignmentID.Type) {
        self.init(fraction: id.defaultValue(in: ViewDimensions(width: 1, height: 1)), kind: .custom(CustomGuide(id: id)))
    }
}

extension View {
    /// Sets the view's value for a guide (where stacks, frames and overlays
    /// line it up with its siblings), computed from its dimensions.
    public func alignmentGuide(_ g: HorizontalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat) -> some View {
        eachNode("alignmentGuide") { n, _ in AlignmentGuideNode(n, g.guide, computeValue) }
    }
    public func alignmentGuide(_ g: VerticalAlignment, computeValue: @escaping (ViewDimensions) -> CGFloat) -> some View {
        eachNode("alignmentGuide") { n, _ in AlignmentGuideNode(n, g.guide, computeValue) }
    }
}

/// `.alignmentGuide`: an explicit value for one guide.
final class AlignmentGuideNode: LayoutNode {
    let child: LayoutNode
    let key: GuideKey
    let compute: (ViewDimensions) -> CGFloat
    init(_ child: LayoutNode, _ key: GuideKey, _ compute: @escaping (ViewDimensions) -> CGFloat) {
        self.child = child; self.key = key; self.compute = compute
        super.init()
        layoutPriority = child.layoutPriority
        tag = child.tag
        tagValue = child.tagValue
    }
    override var children: [LayoutNode] { [child] }
    override var textContent: String? { child.textContent }
    override var menuItem: MenuItemSpec? { child.menuItem }
    override var isSpacer: Bool { child.isSpacer }
    override var guideChild: LayoutNode? { child }
    override var guidesInfo: (has: Bool, stable: Bool) { (true, true) }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
    override func explicitGuide(_ g: GuideKey, _ size: CGSize) -> CGFloat? {
        guard g == key else { return child.explicitGuide(g, size) }
        let child = self.child
        return compute(ViewDimensions(width: size.width, height: size.height) { child.explicitGuide($0, size) })
    }
}

// MARK: Layout

public struct LayoutProperties: Sendable {
    public var stackOrientation: Axis?
    public init() {}
}

public struct ViewSpacing: Sendable {
    public static let zero = ViewSpacing()
    public init() {}
    public mutating func formUnion(_ other: ViewSpacing, edges: Edge.Set = .all) {}
    public func union(_ other: ViewSpacing, edges: Edge.Set = .all) -> ViewSpacing { self }
    public func distance(to next: ViewSpacing, along axis: Axis) -> CGFloat { 8 }
}

public protocol LayoutValueKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

@MainActor @preconcurrency
public protocol Layout {
    associatedtype Cache = Void
    typealias Subviews = LayoutSubviews
    static var layoutProperties: LayoutProperties { get }
    func makeCache(subviews: Subviews) -> Cache
    func updateCache(_ cache: inout Cache, subviews: Subviews)
    func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache)
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat?
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat?
}

extension Layout {
    public static var layoutProperties: LayoutProperties { LayoutProperties() }
    public func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = makeCache(subviews: subviews) }
    public func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing { ViewSpacing() }
    public func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
    public func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGFloat? { nil }
}

extension Layout where Cache == Void {
    public func makeCache(subviews: Subviews) -> Cache { () }
}

extension Layout {
    public func callAsFunction<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        _LayoutView(layout: self, content: content())
    }
}

@MainActor @preconcurrency
public struct LayoutSubview: Equatable {
    let node: LayoutNode
    let sink: () -> PlacementSink?
    let values: [ObjectIdentifier: Any]

    public static func == (a: LayoutSubview, b: LayoutSubview) -> Bool { a.node === b.node }
    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize { node.size(proposal.proposedSize) }
    public func dimensions(in proposal: ProposedViewSize) -> ViewDimensions {
        let s = sizeThatFits(proposal)
        return ViewDimensions(width: s.width, height: s.height)
    }
    public var priority: Double { node.layoutPriority }
    public var spacing: ViewSpacing { ViewSpacing() }
    public var containerValues: ContainerValues { ContainerValues() }
    public subscript<K: LayoutValueKey>(key: K.Type) -> K.Value { values[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
    public func place(at position: CGPoint, anchor: UnitPoint = .topLeading, proposal: ProposedViewSize) {
        guard let sink = sink() else { return }
        let size = node.size(proposal.proposedSize)
        let origin = CGPoint(x: position.x - size.width * anchor.x, y: position.y - size.height * anchor.y)
        node.place(CGRect(origin: origin, size: size), sink)
    }
}

public struct ContainerValues {}

public struct LayoutSubviews: RandomAccessCollection, Equatable {
    let items: [LayoutSubview]
    public var startIndex: Int { 0 }
    public var endIndex: Int { items.count }
    public subscript(i: Int) -> LayoutSubview { items[i] }
    public subscript(bounds: Range<Int>) -> LayoutSubviews { LayoutSubviews(items: Array(items[bounds])) }
    public subscript<S: Sequence>(indices: S) -> LayoutSubviews where S.Element == Int { LayoutSubviews(items: indices.map { items[$0] }) }
    public var layoutDirection: LayoutDirection { .leftToRight }
}

/// Values a subview passes to its container's layout (`.layoutValue`).
final class LayoutValueNode: LayoutNode {
    let child: LayoutNode
    let values: [ObjectIdentifier: Any]
    init(child: LayoutNode, values: [ObjectIdentifier: Any]) { self.child = child; self.values = values }
    override var children: [LayoutNode] { [child] }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

extension View {
    public func layoutValue<K: LayoutValueKey>(key: K.Type, value: K.Value) -> some View {
        eachNode("lv") { n, _ in
            var values = (n as? LayoutValueNode)?.values ?? [:]
            values[ObjectIdentifier(key)] = value
            return LayoutValueNode(child: (n as? LayoutValueNode)?.child ?? n, values: values)
        }
    }
}

final class CustomLayoutNode<L: Layout>: LayoutNode {
    let layout: L
    let items: [LayoutNode]
    private var cache: L.Cache?
    private var currentSink: PlacementSink?
    init(layout: L, children: [LayoutNode]) { self.layout = layout; self.items = children }
    override var children: [LayoutNode] { items }

    private var subviews: LayoutSubviews {
        LayoutSubviews(items: items.map { n in
            LayoutSubview(node: n, sink: { [weak self] in self?.currentSink }, values: (n as? LayoutValueNode)?.values ?? [:])
        })
    }

    private func withCache<T>(_ body: (inout L.Cache, LayoutSubviews) -> T) -> T {
        let subs = subviews
        var c = cache ?? layout.makeCache(subviews: subs)
        let r = body(&c, subs)
        cache = c
        return r
    }

    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        withCache { c, subs in layout.sizeThatFits(proposal: ProposedViewSize(p), subviews: subs, cache: &c) }
    }

    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        currentSink = sink
        withCache { c, subs in layout.placeSubviews(in: rect, proposal: ProposedViewSize(rect.size), subviews: subs, cache: &c) }
        currentSink = nil
    }
}

struct _LayoutView<L: Layout, Content: View>: View, PrimitiveView {
    typealias Body = Never
    let layout: L
    let content: Content
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let kids = ctx.with { $0._stackAxis = nil }.resolve(content, "layout")
        return [CustomLayoutNode(layout: layout, children: kids)]
    }
}

// MARK: Stack layouts and AnyLayout

/// A stack as a Layout value (so AnyLayout can switch between them).
public struct HStackLayout: Layout {
    public var alignment: VerticalAlignment
    public var spacing: CGFloat?
    public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil) { self.alignment = alignment; self.spacing = spacing }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        StackNode(axis: .horizontal, guide: alignment.guide, spacing: spacing, children: subviews.items.map(\.node)).size(proposal.proposedSize)
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let sink = subviews.items.first?.sink() else { return }
        StackNode(axis: .horizontal, guide: alignment.guide, spacing: spacing, children: subviews.items.map(\.node)).place(bounds, sink)
    }
}

public struct VStackLayout: Layout {
    public var alignment: HorizontalAlignment
    public var spacing: CGFloat?
    public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil) { self.alignment = alignment; self.spacing = spacing }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        StackNode(axis: .vertical, guide: alignment.guide, spacing: spacing, children: subviews.items.map(\.node)).size(proposal.proposedSize)
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let sink = subviews.items.first?.sink() else { return }
        StackNode(axis: .vertical, guide: alignment.guide, spacing: spacing, children: subviews.items.map(\.node)).place(bounds, sink)
    }
}

public struct ZStackLayout: Layout {
    public var alignment: Alignment
    public init(alignment: Alignment = .center) { self.alignment = alignment }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        ZStackNode(alignment: alignment, children: subviews.items.map(\.node)).size(proposal.proposedSize)
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let sink = subviews.items.first?.sink() else { return }
        ZStackNode(alignment: alignment, children: subviews.items.map(\.node)).place(bounds, sink)
    }
}

public struct AnyLayout: Layout {
    public typealias Cache = Void
    let size: @MainActor (ProposedViewSize, LayoutSubviews) -> CGSize
    let placer: @MainActor (CGRect, ProposedViewSize, LayoutSubviews) -> Void
    public init<L: Layout>(_ layout: L) {
        size = { p, s in var c = layout.makeCache(subviews: s); return layout.sizeThatFits(proposal: p, subviews: s, cache: &c) }
        placer = { b, p, s in var c = layout.makeCache(subviews: s); layout.placeSubviews(in: b, proposal: p, subviews: s, cache: &c) }
    }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size(proposal, subviews) }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) { placer(bounds, proposal, subviews) }
}

// MARK: Text and layout modifiers the corpus uses

extension View {
    public func minimumScaleFactor(_ factor: CGFloat) -> some View { self }
    public func allowsTightening(_ flag: Bool) -> some View { self }
    public func lineSpacing(_ lineSpacing: CGFloat) -> some View { environment { $0._lineSpacing = lineSpacing } }
    public func contentMargins(_ edges: Edge.Set = .all, _ insets: EdgeInsets, for placement: ContentMarginPlacement = .automatic) -> some View { self }
    public func contentMargins(_ edges: Edge.Set = .all, _ length: CGFloat?, for placement: ContentMarginPlacement = .automatic) -> some View { self }
    public func contentMargins(_ length: CGFloat, for placement: ContentMarginPlacement = .automatic) -> some View { self }
    public func gridCellUnsizedAxes(_ axes: Axis.Set) -> some View { self }
    public func gridCellAnchor(_ anchor: UnitPoint) -> some View { self }
    public func gridColumnAlignment(_ guide: HorizontalAlignment) -> some View { self }
    public func dialogSuppressionToggle(isSuppressed: Binding<Bool>) -> some View { self }
    public func dialogSuppressionToggle(_ titleKey: LocalizedStringKey, isSuppressed: Binding<Bool>) -> some View { self }
    public func focusSection() -> some View { self }
    public func geometryGroup() -> some View { self }
    public func scrollClipDisabled(_ disabled: Bool = true) -> some View { self }
    public func hueRotation(_ angle: Angle) -> some View { self }
    public func listItemTint(_ tint: Color?) -> some View { self }
    public func prefersDefaultFocus(_ prefersDefaultFocus: Bool = true, in namespace: Namespace.ID) -> some View { self }
    public func horizontalRadioGroupLayout() -> some View { self }
    public func submitLabel(_ submitLabel: SubmitLabel) -> some View { self }
    public func toolbarBackgroundVisibility(_ visibility: Visibility, for bars: ToolbarPlacement...) -> some View { self }
    public func onModifierKeysChanged(mask: EventModifiers = .all, initial: Bool = true, _ action: @escaping (EventModifiers, EventModifiers) -> Void) -> some View { self }
    public func accessibilityRepresentation<V: View>(@ViewBuilder representation: () -> V) -> some View { self }
    public func onGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T, action: @escaping (T) -> Void) -> some View { self }
    public func onGeometryChange<T: Equatable>(for type: T.Type, of transform: @escaping (GeometryProxy) -> T, action: @escaping (T, T) -> Void) -> some View { self }
}

public struct ContentMarginPlacement: Sendable {
    public static let automatic = Self(), scrollContent = Self(), scrollIndicators = Self()
}

public struct PointerStyle: Sendable {
    let cursor: CursorKind
    init(_ cursor: CursorKind = .arrow) { self.cursor = cursor }
    public static let `default` = Self(), horizontalText = Self(.iBeam), verticalText = Self(.iBeam), link = Self(.pointingHand), grabIdle = Self(.pointingHand),
                      grabActive = Self(.pointingHand), rectSelection = Self(), zoomIn = Self(), zoomOut = Self()
    public static func frameResize(position: FrameResizePosition, directions: FrameResizeDirection.Set = .all) -> Self {
        switch position {
        case .leading, .trailing: Self(.resizeLeftRight)
        case .top, .bottom: Self(.resizeUpDown)
        default: Self()
        }
    }
    public static func columnResize(directions: HorizontalDirection.Set = .all) -> Self { Self(.resizeLeftRight) }
    public static func rowResize(directions: VerticalDirection.Set = .all) -> Self { Self(.resizeUpDown) }
}

public enum FrameResizePosition: Sendable { case top, leading, bottom, trailing, topLeading, topTrailing, bottomLeading, bottomTrailing }
public enum FrameResizeDirection: Sendable {
    case inward, outward
    public struct Set: OptionSet, Sendable { public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }; public static let all = Set(rawValue: 3) }
}
public enum HorizontalDirection: Sendable {
    case leading, trailing
    public struct Set: OptionSet, Sendable { public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }; public static let all = Set(rawValue: 3) }
}
public enum VerticalDirection: Sendable {
    case up, down
    public struct Set: OptionSet, Sendable { public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }; public static let all = Set(rawValue: 3) }
}

public struct SubmitLabel: Sendable {
    public static let done = Self(), go = Self(), send = Self(), join = Self(), route = Self(), search = Self(),
                      `return` = Self(), next = Self(), `continue` = Self()
}

// MARK: Color.Resolved

extension Color {
    /// A colour's concrete sRGB components (light/dark applied).
    public struct Resolved: Hashable, Codable, Sendable, ShapeStyle {
        public var red: Float
        public var green: Float
        public var blue: Float
        public var opacity: Float
        public init(red: Float, green: Float, blue: Float, opacity: Float = 1) {
            self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
        }
        public init(colorSpace: Color.RGBColorSpace = .sRGB, red: Float, green: Float, blue: Float, opacity: Float = 1) {
            self.init(red: red, green: green, blue: blue, opacity: opacity)
        }
        static func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
        public var linearRed: Float { get { Self.linear(red) } set { red = newValue } }
        public var linearGreen: Float { get { Self.linear(green) } set { green = newValue } }
        public var linearBlue: Float { get { Self.linear(blue) } set { blue = newValue } }
        public var cgColor: CGColor { CGColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(opacity)) }
        public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { .color(RGBA(Double(red), Double(green), Double(blue), Double(opacity))) }
    }

    public init(_ resolved: Resolved) {
        self.init(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue), opacity: Double(resolved.opacity))
    }

    @preconcurrency @MainActor public func resolve(in environment: EnvironmentValues) -> Resolved {
        let c = resolve(environment)
        return Resolved(red: Float(c.r), green: Float(c.g), blue: Float(c.b), opacity: Float(c.a))
    }
}

// MARK: Text selection

public protocol TextSelectability { static var allowsSelection: Bool { get } }
public struct EnabledTextSelectability: TextSelectability { public static var allowsSelection: Bool { true } }
public struct DisabledTextSelectability: TextSelectability { public static var allowsSelection: Bool { false } }
extension TextSelectability where Self == EnabledTextSelectability { public static var enabled: EnabledTextSelectability { .init() } }
extension TextSelectability where Self == DisabledTextSelectability { public static var disabled: DisabledTextSelectability { .init() } }
