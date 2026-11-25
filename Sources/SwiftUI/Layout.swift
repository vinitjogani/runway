// Layout with SwiftUI's rules, independent of the toolkit: a parent
// proposes a size, the child chooses its own, the parent places it.
// Stacks divide space among children from least to most flexible, by
// layout priority; frames clamp; fixedSize proposes nil (the ideal size).
// The result is absolute frames that backends apply to native widgets.

import Foundation
import CoreGraphics
import RunwayCore

// MARK: Geometry types

public enum Axis: Hashable, Sendable, CaseIterable {
    case horizontal, vertical
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1)
        public static let vertical = Set(rawValue: 2)
    }
}

public enum Edge: Int8, Hashable, Sendable, CaseIterable {
    case top, leading, bottom, trailing
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public init(_ e: Edge) { rawValue = 1 << e.rawValue }
        public static let top = Set(.top)
        public static let leading = Set(.leading)
        public static let bottom = Set(.bottom)
        public static let trailing = Set(.trailing)
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
        public static let all: Set = [.top, .leading, .bottom, .trailing]
    }
}

public struct EdgeInsets: Hashable, Sendable {
    public var top, leading, bottom, trailing: CGFloat
    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    public init() { self.init(top: 0) }
    var horizontal: CGFloat { leading + trailing }
    var vertical: CGFloat { top + bottom }
}

public struct HorizontalAlignment: Hashable, Sendable {
    let fraction: CGFloat
    public static let leading = HorizontalAlignment(fraction: 0)
    public static let center = HorizontalAlignment(fraction: 0.5)
    public static let trailing = HorizontalAlignment(fraction: 1)
    public static let listRowSeparatorLeading = HorizontalAlignment(fraction: 0)
    public static let listRowSeparatorTrailing = HorizontalAlignment(fraction: 1)
}

public struct VerticalAlignment: Hashable, Sendable {
    let fraction: CGFloat
    public static let top = VerticalAlignment(fraction: 0)
    public static let center = VerticalAlignment(fraction: 0.5)
    public static let bottom = VerticalAlignment(fraction: 1)
    public static let firstTextBaseline = VerticalAlignment(fraction: 0.5)
    public static let lastTextBaseline = VerticalAlignment(fraction: 0.5)
}

public struct Alignment: Hashable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) { self.horizontal = horizontal; self.vertical = vertical }
    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)
    public static let leadingFirstTextBaseline = Alignment.leading
    public static let centerFirstTextBaseline = Alignment.center

    func origin(of size: CGSize, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + (rect.width - size.width) * horizontal.fraction,
                y: rect.minY + (rect.height - size.height) * vertical.fraction)
    }
}

public struct UnitPoint: Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public init(x: CGFloat, y: CGFloat) { self.x = x; self.y = y }
    public init() { self.init(x: 0, y: 0) }
    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
    var point: CGPoint { CGPoint(x: x, y: y) }
}

public enum ContentMode: Hashable, Sendable { case fit, fill }

/// The default spacing between views (macOS's).
let defaultSpacing: CGFloat = 8

// MARK: Nodes

/// A node in the layout tree, rebuilt every render (widgets persist).
@preconcurrency @MainActor public class LayoutNode {
    var layoutPriority: Double = 0
    /// For Picker options: the value from `.tag(_:)`.
    var tag: AnyHashable?
    var tagValue: Any?
    /// For menus and pickers: what this node shows as text.
    var textContent: String? { children.lazy.compactMap(\.textContent).first }
    var children: [LayoutNode] { [] }
    /// Menu building: an action and title found in the content.
    var menuItem: MenuItemSpec? { nil }
    var isSpacer: Bool { false }
    /// SwiftUI drops spacing next to nodes that are hidden structure.
    var isEmptyLayout: Bool { false }

    // Sizes already computed for proposals. A node sees one to a handful of
    // distinct proposals per layout (a stack asks for the minimum, the
    // maximum and a share), so the first lives inline and the rest in a short
    // list searched linearly: no hashing and, usually, no allocation.
    private var hasFirst = false
    private var firstProposal = ProposedSize.unspecified
    private var firstSize = CGSize.zero
    private var moreSizes: [(ProposedSize, CGSize)] = []

    /// The scope whose body is being resolved while nodes are made.
    static var buildingScope: Scope?
    /// The scope that made this node. Nodes outlive a render when their
    /// scope is reused; when something inside changes size without the
    /// scope running again, the scope's epoch moves on and its nodes
    /// measure afresh.
    private weak var owner: Scope? = LayoutNode.buildingScope
    private lazy var cacheEpoch = owner?.layoutEpoch ?? 0

    func clearSizeCache() {
        hasFirst = false
        moreSizes.removeAll()
    }

    /// Layout work done (RUNWAY_METRICS): size requests, misses, backend measures.
    static var sizeCalls = 0, sizeMisses = 0, measures = 0

    public func size(_ p: ProposedSize) -> CGSize {
        if RunwayMetrics.enabled { LayoutNode.sizeCalls += 1 }
        if let o = owner, o.layoutEpoch != cacheEpoch {
            cacheEpoch = o.layoutEpoch
            clearSizeCache()
        }
        if hasFirst {
            if firstProposal == p { return firstSize }
            for (q, s) in moreSizes where q == p { return s }
        }
        if RunwayMetrics.enabled { LayoutNode.sizeMisses += 1 }
        let s = sizeThatFits(p)
        if !hasFirst {
            hasFirst = true
            firstProposal = p
            firstSize = s
        } else {
            if moreSizes.count >= 8 { moreSizes.removeFirst() }
            moreSizes.append((p, s))
        }
        return s
    }

    func sizeThatFits(_ p: ProposedSize) -> CGSize { .zero }
    func place(_ rect: CGRect, _ sink: PlacementSink) {}

    /// For tests and `runway run --headless`.
    public var debugName: String { String(describing: type(of: self)) }
}

/// A native widget.
final class WidgetNode: LayoutNode {
    let widget: NativeWidget?
    let backend: Backend
    var flexibleWidth = false
    var flexibleHeight = false
    var idealWidth: CGFloat?
    var minWidth: CGFloat = 0
    let text: String?
    let item: MenuItemSpec?

    /// Kinds sized by the proposed width alone (the backend contract:
    /// natural size, wrapped to the width where it can wrap), so proposals
    /// differing only in height share one measurement.
    private let widthOnly: Bool
    private var measured: [(CGFloat?, CGSize)] = []

    init(_ widget: NativeWidget?, backend: Backend, text: String? = nil, item: MenuItemSpec? = nil) {
        self.widget = widget
        self.backend = backend
        self.text = text
        self.item = item
        widthOnly = widget.flatMap { WidgetKinds.kind(of: $0) }.map(WidgetKinds.measuresByWidthOnly) ?? false
    }
    override var textContent: String? { text }
    override var menuItem: MenuItemSpec? { item }

    private func natural(_ pw: CGFloat?, _ ph: CGFloat?, _ widget: NativeWidget) -> CGSize {
        guard widthOnly else {
            if RunwayMetrics.enabled { LayoutNode.measures += 1 }
            return backend.measure(widget, proposal: ProposedSize(width: pw, height: ph))
        }
        for (w, s) in measured where w == pw { return s }
        if RunwayMetrics.enabled { LayoutNode.measures += 1 }
        let s = backend.measure(widget, proposal: ProposedSize(width: pw, height: nil))
        measured.append((pw, s))
        return s
    }

    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        guard let widget else { return .zero }
        let pw = p.width.flatMap { $0.isFinite ? $0 : nil }
        let ph = p.height.flatMap { $0.isFinite ? $0 : nil }
        var natural = natural(pw, ph, widget)
        if let i = idealWidth, !flexibleWidth || pw == nil { natural.width = max(natural.width, i) }
        var w = natural.width, h = natural.height
        if flexibleWidth, let pw { w = max(pw, minWidth) }
        if flexibleHeight, let ph { h = ph }
        return CGSize(width: w, height: h)
    }

    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        if let widget { sink.add(widget, rect) }
    }
}

/// The kind of each native widget a host made (for layout decisions that
/// depend on it).
@MainActor enum WidgetKinds {
    private static var kinds: [ObjectIdentifier: WidgetKind] = [:]
    static func set(_ w: NativeWidget, _ k: WidgetKind?) { kinds[ObjectIdentifier(w)] = k }
    static func kind(of w: NativeWidget) -> WidgetKind? { kinds[ObjectIdentifier(w)] }
    static func measuresByWidthOnly(_ k: WidgetKind) -> Bool {
        switch k {
        case .container, .scroll, .tapArea, .canvas, .textEditor: return false
        default: return true
        }
    }
}

final class SpacerNode: LayoutNode {
    let minLength: CGFloat?
    let axis: Axis?
    init(minLength: CGFloat?, axis: Axis?) { self.minLength = minLength; self.axis = axis }
    override var isSpacer: Bool { true }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        let m = minLength ?? defaultSpacing
        switch axis {
        case .horizontal: return CGSize(width: max(m, p.width ?? m), height: 0)
        case .vertical: return CGSize(width: 0, height: max(m, p.height ?? m))
        case nil: return CGSize(width: max(m, p.width ?? m), height: max(m, p.height ?? m))
        }
    }
}

/// HStack and VStack.
final class StackNode: LayoutNode {
    let axis: Axis
    let alignmentFraction: CGFloat
    let spacing: CGFloat?
    let items: [LayoutNode]
    init(axis: Axis, alignment: CGFloat, spacing: CGFloat?, children: [LayoutNode]) {
        self.axis = axis
        self.alignmentFraction = alignment
        self.spacing = spacing
        self.items = children
    }
    convenience init(axis: Axis, alignment: HorizontalAlignment, spacing: CGFloat?, children: [LayoutNode]) {
        self.init(axis: axis, alignment: alignment.fraction, spacing: spacing, children: children)
    }
    override var children: [LayoutNode] { items }

    private func main(_ s: CGSize) -> CGFloat { axis == .horizontal ? s.width : s.height }
    private func cross(_ s: CGSize) -> CGFloat { axis == .horizontal ? s.height : s.width }
    private func proposal(main m: CGFloat?, cross c: CGFloat?) -> ProposedSize {
        axis == .horizontal ? ProposedSize(width: m, height: c) : ProposedSize(width: c, height: m)
    }

    /// The spacing between children, summed as the children are laid out.
    private var gapTotal: CGFloat {
        guard items.count > 1 else { return 0 }
        let g = spacing ?? defaultSpacing
        var total: CGFloat = 0
        for _ in 1..<items.count { total += g }
        return total
    }

    /// Each child's main-axis size for a main-axis proposal.
    private func distribute(_ p: ProposedSize) -> [CGSize] {
        let crossP = axis == .horizontal ? p.height : p.width
        guard let total = axis == .horizontal ? p.width : p.height else {
            return items.map { $0.size(proposal(main: nil, cross: crossP)) }
        }
        let count = items.count
        var remaining = total - gapTotal
        var sizes = [CGSize](repeating: .zero, count: count)
        // Each child's size at the smallest and largest main-axis proposals.
        let low = items.map { $0.size(proposal(main: 0, cross: crossP)) }
        let high = items.map { $0.size(proposal(main: .infinity, cross: crossP)) }
        let mins = low.map(main), maxs = high.map(main)
        let idealWidths = axis == .horizontal && total.isFinite
            ? items.map { main($0.size(proposal(main: nil, cross: crossP))) }
            : []
        // Highest priority first; within a priority, least flexible first.
        let groups: [[Int]]
        let firstPriority = items.first?.layoutPriority ?? 0
        if items.allSatisfy({ $0.layoutPriority == firstPriority }) {
            groups = [Array(items.indices)]
        } else {
            groups = Dictionary(grouping: items.indices, by: { items[$0].layoutPriority }).sorted { $0.key > $1.key }.map(\.value)
        }
        var reservedBelow = mins.reduce(0, +)
        for group in groups {
            var groupMin: CGFloat = 0
            for i in group { groupMin += mins[i] }
            reservedBelow -= groupMin
            var avail = remaining - reservedBelow
            let order = group.sorted { (maxs[$0] - mins[$0]) < (maxs[$1] - mins[$1]) }
            var remainingIdeal = idealWidths.isEmpty ? 0 : group.reduce(CGFloat.zero) { $0 + idealWidths[$1] }
            let canFitIdeal = !idealWidths.isEmpty && remainingIdeal <= avail
            for (n, i) in order.enumerated() {
                if canFitIdeal { remainingIdeal -= idealWidths[i] }
                let s: CGSize
                if low[i] == high[i] {
                    // A child the same size whatever it's offered (text, a
                    // fixed frame, a row of them) is that size for any share
                    // in between: no need to ask again.
                    s = high[i]
                } else {
                    var share = max(0, avail / CGFloat(order.count - n))
                    if canFitIdeal {
                        // Keep a fitting single-line label at its ideal width, even
                        // with a wide spacer or a sibling with a smaller ideal.
                        share = max(idealWidths[i], min(share, avail - remainingIdeal))
                    }
                    s = items[i].size(proposal(main: share, cross: crossP))
                }
                sizes[i] = s
                avail -= main(s)
            }
            var used: CGFloat = 0
            for i in order { used += main(sizes[i]) }
            remaining -= used
        }
        return sizes
    }

    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        let sizes = distribute(p)
        let m = sizes.map(main).reduce(0, +) + gapTotal
        let c = sizes.map(cross).max() ?? 0
        return axis == .horizontal ? CGSize(width: m, height: c) : CGSize(width: c, height: m)
    }

    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        let p = ProposedSize(width: rect.width, height: rect.height)
        let sizes = distribute(p)
        var pos = axis == .horizontal ? rect.minX : rect.minY
        let gap = spacing ?? defaultSpacing
        for (i, child) in items.enumerated() {
            let s = sizes[i]
            let frame: CGRect
            if axis == .horizontal {
                frame = CGRect(x: pos, y: rect.minY + (rect.height - s.height) * alignmentFraction, width: s.width, height: s.height)
                pos += s.width
            } else {
                frame = CGRect(x: rect.minX + (rect.width - s.width) * alignmentFraction, y: pos, width: s.width, height: s.height)
                pos += s.height
            }
            child.place(frame, sink)
            if i < items.count - 1 { pos += gap }
        }
    }
}

final class ZStackNode: LayoutNode {
    let alignment: Alignment
    let items: [LayoutNode]
    init(alignment: Alignment, children: [LayoutNode]) { self.alignment = alignment; self.items = children }
    override var children: [LayoutNode] { items }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        let sizes = items.map { $0.size(p) }
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).max() ?? 0)
    }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        for c in items {
            let s = c.size(ProposedSize(width: rect.width, height: rect.height))
            c.place(CGRect(origin: alignment.origin(of: s, in: rect), size: s), sink)
        }
    }
}

final class PaddingNode: LayoutNode {
    let insets: EdgeInsets
    let child: LayoutNode
    init(_ insets: EdgeInsets, _ child: LayoutNode) { self.insets = insets; self.child = child }
    override var children: [LayoutNode] { [child] }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        let inner = ProposedSize(width: p.width.map { max(0, $0 - insets.horizontal) }, height: p.height.map { max(0, $0 - insets.vertical) })
        let s = child.size(inner)
        return CGSize(width: s.width + insets.horizontal, height: s.height + insets.vertical)
    }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        child.place(CGRect(x: rect.minX + insets.leading, y: rect.minY + insets.top,
                           width: max(0, rect.width - insets.horizontal), height: max(0, rect.height - insets.vertical)), sink)
    }
}

/// `.frame(width:height:)` and `.frame(minWidth:…maxHeight:)`.
final class FrameNode: LayoutNode {
    var width: CGFloat?, height: CGFloat?
    var minWidth: CGFloat?, idealWidth: CGFloat?, maxWidth: CGFloat?
    var minHeight: CGFloat?, idealHeight: CGFloat?, maxHeight: CGFloat?
    let alignment: Alignment
    let child: LayoutNode
    init(child: LayoutNode, alignment: Alignment) { self.child = child; self.alignment = alignment }
    override var children: [LayoutNode] { [child] }
    override var textContent: String? { child.textContent }

    private func axis(_ proposed: CGFloat?, fixed: CGFloat?, min: CGFloat?, ideal: CGFloat?, max: CGFloat?, child c: (CGFloat?) -> CGFloat) -> (proposal: CGFloat?, result: CGFloat) {
        if let fixed { return (fixed, fixed) }
        guard min != nil || max != nil || ideal != nil else {
            return (proposed, c(proposed))
        }
        var p = proposed ?? ideal
        if let p0 = p {
            var v = p0
            if let mn = min { v = Swift.max(v, mn) }
            if let mx = max { v = Swift.min(v, mx) }
            p = v
        }
        let cs = c(p)
        var r = cs
        let prop = proposed ?? ideal ?? cs
        if let mn = min { r = Swift.max(mn, Swift.min(r, prop)) }
        if let mx = max { r = Swift.min(mx, Swift.max(r, prop)) }
        if min == nil, max == nil, ideal != nil, proposed == nil { r = ideal! }
        return (p, r)
    }

    private func layout(_ pr: ProposedSize) -> (child: ProposedSize, size: CGSize) {
        var childP = ProposedSize(width: nil, height: nil)
        let wAxis = axis(pr.width, fixed: width, min: minWidth, ideal: idealWidth, max: maxWidth) { pw in
            self.child.size(ProposedSize(width: pw, height: self.height ?? pr.height)).width
        }
        childP.width = wAxis.proposal
        let hAxis = axis(pr.height, fixed: height, min: minHeight, ideal: idealHeight, max: maxHeight) { ph in
            self.child.size(ProposedSize(width: childP.width, height: ph)).height
        }
        childP.height = hAxis.proposal
        return (childP, CGSize(width: wAxis.result, height: hAxis.result))
    }

    override func sizeThatFits(_ p: ProposedSize) -> CGSize { layout(p).size }

    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        let (cp, _) = layout(ProposedSize(width: rect.width, height: rect.height))
        let s = child.size(cp)
        child.place(CGRect(origin: alignment.origin(of: s, in: rect), size: s), sink)
    }
}

final class FixedSizeNode: LayoutNode {
    let horizontal: Bool, vertical: Bool
    let child: LayoutNode
    init(_ child: LayoutNode, horizontal: Bool, vertical: Bool) { self.child = child; self.horizontal = horizontal; self.vertical = vertical }
    override var children: [LayoutNode] { [child] }
    override var textContent: String? { child.textContent }
    private func adjust(_ p: ProposedSize) -> ProposedSize {
        ProposedSize(width: horizontal ? nil : p.width, height: vertical ? nil : p.height)
    }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(adjust(p)) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        let s = child.size(adjust(ProposedSize(width: rect.width, height: rect.height)))
        child.place(CGRect(origin: Alignment.center.origin(of: s, in: rect), size: s), sink)
    }
}

final class AspectRatioNode: LayoutNode {
    let ratio: CGFloat?
    let mode: ContentMode
    let child: LayoutNode
    init(_ child: LayoutNode, ratio: CGFloat?, mode: ContentMode) { self.child = child; self.ratio = ratio; self.mode = mode }
    override var children: [LayoutNode] { [child] }
    private var effectiveRatio: CGFloat {
        if let ratio { return ratio }
        let ideal = child.size(.unspecified)
        return ideal.height > 0 ? ideal.width / ideal.height : 1
    }
    private func fitted(_ p: ProposedSize) -> CGSize {
        let r = effectiveRatio
        switch (p.width.flatMap { $0.isFinite ? $0 : nil }, p.height.flatMap { $0.isFinite ? $0 : nil }) {
        case let (w?, h?):
            let byW = CGSize(width: w, height: w / r), byH = CGSize(width: h * r, height: h)
            if mode == .fit { return byW.height <= h ? byW : byH }
            return byW.height >= h ? byW : byH
        case let (w?, nil): return CGSize(width: w, height: w / r)
        case let (nil, h?): return CGSize(width: h * r, height: h)
        case (nil, nil):
            let ideal = child.size(.unspecified)
            return ratio == nil ? ideal : CGSize(width: ideal.width, height: ideal.width / r)
        }
    }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(ProposedSize(fitted(p))) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        let s = child.size(ProposedSize(fitted(ProposedSize(width: rect.width, height: rect.height))))
        child.place(CGRect(origin: Alignment.center.origin(of: s, in: rect), size: s), sink)
    }
}

/// `.overlay` and `.background`: sized by the primary child.
final class LayerNode: LayoutNode {
    let primary: LayoutNode
    let secondary: [LayoutNode]
    let alignment: Alignment
    let behind: Bool
    init(primary: LayoutNode, secondary: [LayoutNode], alignment: Alignment, behind: Bool) {
        self.primary = primary; self.secondary = secondary; self.alignment = alignment; self.behind = behind
    }
    override var children: [LayoutNode] { [primary] + secondary }
    override var textContent: String? { primary.textContent }
    override var menuItem: MenuItemSpec? { primary.menuItem }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { primary.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        func placeSecondary() {
            for s in secondary {
                let size = s.size(ProposedSize(width: rect.width, height: rect.height))
                s.place(CGRect(origin: alignment.origin(of: size, in: rect), size: size), sink)
            }
        }
        if behind { placeSecondary() }
        primary.place(rect, sink)
        if !behind { placeSecondary() }
    }
}

final class OffsetNode: LayoutNode {
    let offset: CGSize
    let child: LayoutNode
    init(_ child: LayoutNode, _ offset: CGSize) { self.child = child; self.offset = offset }
    override var children: [LayoutNode] { [child] }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect.offsetBy(dx: offset.width, dy: offset.height), sink) }
}

/// Rotates drawing in the subtree while leaving its layout proposal unchanged.
final class DrawingRotationNode: LayoutNode {
    let child: LayoutNode
    let rotation: ShapeRotation

    init(child: LayoutNode, rotation: ShapeRotation) {
        self.child = child
        self.rotation = rotation
        super.init()
        layoutPriority = child.layoutPriority
        tag = child.tag
        tagValue = child.tagValue
    }

    override var children: [LayoutNode] { [child] }
    override var menuItem: MenuItemSpec? { child.menuItem }
    override var isSpacer: Bool { child.isSpacer }
    override var isEmptyLayout: Bool { child.isEmptyLayout }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }

    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        let previous = sink.drawingTransform
        sink.drawingTransform = rotation.transform(in: rect).concatenating(previous)
        defer { sink.drawingTransform = previous }
        child.place(rect, sink)
    }
}

/// A layout-priority wrapper (`.layoutPriority(_:)`).
final class PriorityNode: LayoutNode {
    let child: LayoutNode
    init(_ child: LayoutNode, _ priority: Double) { self.child = child; super.init(); layoutPriority = priority; tag = child.tag; tagValue = child.tagValue }
    override var children: [LayoutNode] { [child] }
    override var textContent: String? { child.textContent }
    override var isSpacer: Bool { child.isSpacer }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

/// A node that only carries a tag or menu item for its child.
final class TaggedNode: LayoutNode {
    let child: LayoutNode
    init(_ child: LayoutNode) { self.child = child }
    override var children: [LayoutNode] { [child] }
    override var textContent: String? { child.textContent }
    override var menuItem: MenuItemSpec? { child.menuItem }
    override var isSpacer: Bool { child.isSpacer }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { child.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) { child.place(rect, sink) }
}

/// A native container holding its own children: scroll views, buttons
/// with custom labels, tap areas, clipping.
final class ContainerNode: LayoutNode {
    enum Sizing { case hug, scroll(horizontal: Bool, vertical: Bool, enabled: Bool) }
    let widget: NativeWidget?
    let backend: Backend
    let content: LayoutNode
    let sizing: Sizing
    let insets: EdgeInsetsValue
    var minSize: CGSize = .zero
    var item: MenuItemSpec?
    init(widget: NativeWidget?, backend: Backend, content: LayoutNode, sizing: Sizing, insets: EdgeInsetsValue = .zero) {
        self.widget = widget; self.backend = backend; self.content = content; self.sizing = sizing; self.insets = insets
    }
    override var children: [LayoutNode] { [content] }
    override var textContent: String? { content.textContent }
    override var menuItem: MenuItemSpec? { item }

    private func contentProposal(_ p: ProposedSize) -> ProposedSize {
        switch sizing {
        case .hug:
            return ProposedSize(width: p.width.map { max(0, $0 - insets.leading - insets.trailing) },
                                height: p.height.map { max(0, $0 - insets.top - insets.bottom) })
        case let .scroll(h, v, _):
            return ProposedSize(width: h ? nil : p.width, height: v ? nil : p.height)
        }
    }

    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        let c = content.size(contentProposal(p))
        switch sizing {
        case .hug:
            return CGSize(width: max(minSize.width, c.width + insets.leading + insets.trailing),
                          height: max(minSize.height, c.height + insets.top + insets.bottom))
        case let .scroll(h, v, enabled):
            // Scroll views take the space offered on their scrolling axes.
            // Greedy like SwiftUI's, except on a scroll axis with scrolling
            // disabled, where it hugs its content.
            func axis(_ proposed: CGFloat?, _ contentSize: CGFloat, _ scrolls: Bool) -> CGFloat {
                guard let proposed, proposed.isFinite else { return contentSize }
                if scrolls && !enabled { return contentSize }
                return scrolls ? proposed : max(proposed, contentSize)
            }
            return CGSize(width: axis(p.width, c.width, h), height: axis(p.height, c.height, v))
        }
    }

    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        guard let widget else { return }
        sink.add(widget, rect)
        let inner = backend.childContainer(widget)
        let s = sink.nested(inner, origin: .zero)
        let chromeOrigin = inner !== widget ? CGPoint(x: insets.leading, y: insets.top) : .zero
        s.hostOrigin = CGPoint(x: sink.hostOrigin.x + rect.minX - sink.offset.x + chromeOrigin.x,
                               y: sink.hostOrigin.y + rect.minY - sink.offset.y + chromeOrigin.y)
        if case .scroll(_, _, true) = sizing {
            s.scrollDocument = widget
            s.documentOrigin = .zero
            if let scrolled = (backend as? AppKitBackend)?.scrollOffset(widget) {
                s.hostOrigin.x -= scrolled.x
                s.hostOrigin.y -= scrolled.y
            }
        } else {
            let chrome = inner !== widget ? CGPoint(x: insets.leading, y: insets.top) : .zero
            s.documentOrigin = CGPoint(x: sink.documentOrigin.x + rect.minX - sink.offset.x + chrome.x,
                                       y: sink.documentOrigin.y + rect.minY - sink.offset.y + chrome.y)
        }
        let local: CGRect
        switch sizing {
        case .hug:
            // The inner container is already inset by the native chrome
            // (a button's padding), so content is placed from its origin.
            let separate = inner !== widget
            local = CGRect(x: separate ? 0 : insets.leading, y: separate ? 0 : insets.top,
                           width: max(0, rect.width - insets.leading - insets.trailing),
                           height: max(0, rect.height - insets.top - insets.bottom))
            let cs = content.size(ProposedSize(width: local.width, height: local.height))
            content.place(CGRect(origin: Alignment.center.origin(of: cs, in: local), size: cs), s)
            s.commit(contentSize: separate ? local.size : rect.size)
        case let .scroll(h, v, _):
            let cs = content.size(contentProposal(ProposedSize(width: rect.width, height: rect.height)))
            let size = CGSize(width: h ? max(cs.width, rect.width) : rect.width, height: v ? max(cs.height, rect.height) : rect.height)
            let csPlaced = content.size(ProposedSize(width: h ? cs.width : rect.width, height: v ? cs.height : rect.height))
            content.place(CGRect(origin: Alignment.top.origin(of: csPlaced, in: CGRect(origin: .zero, size: size)), size: csPlaced), s)
            s.commit(contentSize: size)
            sink.host?.scrollPlaced(widget, document: size, viewport: rect.size)
        }
    }
}

/// A shape: drawing made for its final size.
final class ShapeNode: LayoutNode {
    let widget: NativeWidget?
    let backend: Backend
    let props: WidgetProps
    let events: WidgetEvents
    let draw: (CGRect) -> [DrawCommand]
    init(widget: NativeWidget?, backend: Backend, props: WidgetProps, events: WidgetEvents, draw: @escaping (CGRect) -> [DrawCommand]) {
        self.widget = widget; self.backend = backend; self.props = props; self.events = events; self.draw = draw
    }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        CGSize(width: p.width ?? 10, height: p.height ?? 10)   // fills any proposal, infinity included, as SwiftUI shapes do
    }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        guard let widget else { return }
        var pr = props
        let commands = draw(CGRect(origin: .zero, size: rect.size))
        let transform = sink.drawingTransform
        let frame: CGRect
        if transform.isIdentity {
            pr.drawing = commands
            frame = rect
        } else {
            // Enlarge the drawing surface to contain the rotated rectangle.
            // The parent still lays out the shape at its original size.
            frame = rect.applying(transform).integral
            let local = CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .concatenating(transform)
                .concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
            pr.drawing = commands.map { $0.applying(local) }
        }
        backend.update(widget, props: pr, events: events)
        sink.add(widget, frame)
    }
}

/// GeometryReader: greedy, and builds its content for the size it gets.
final class GeometryNode: LayoutNode {
    let build: (CGSize) -> [LayoutNode]
    init(_ build: @escaping (CGSize) -> [LayoutNode]) { self.build = build }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        CGSize(width: p.width ?? 10, height: p.height ?? 10)   // greedy, infinity included, as SwiftUI's is
    }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        for n in build(rect.size) {
            let s = n.size(ProposedSize(width: rect.width, height: rect.height))
            n.place(CGRect(origin: rect.origin, size: s), sink)
        }
    }
}

/// LazyVGrid / LazyHGrid (laid out eagerly).
final class GridNode: LayoutNode {
    let columns: [GridItem]
    let spacing: CGFloat
    let rowSpacing: CGFloat
    let alignment: HorizontalAlignment
    let items: [LayoutNode]
    init(columns: [GridItem], spacing: CGFloat?, rowSpacing: CGFloat?, alignment: HorizontalAlignment, children: [LayoutNode]) {
        self.columns = columns; self.spacing = spacing ?? defaultSpacing; self.rowSpacing = rowSpacing ?? defaultSpacing
        self.alignment = alignment; self.items = children
    }
    override var children: [LayoutNode] { items }

    private func columnWidths(_ width: CGFloat?) -> [CGFloat] {
        let w = width ?? CGFloat(columns.count) * 80
        var cols: [CGFloat] = []
        var flexible: [Int] = []
        var used: CGFloat = 0
        for item in columns {
            switch item.size {
            case let .fixed(f): cols.append(f); used += f
            case .flexible: flexible.append(cols.count); cols.append(0)
            case let .adaptive(minimum, maximum):
                let gap = item.spacing ?? spacing
                let n = max(1, Int((w - used + gap) / (minimum + gap)))
                let each = min(maximum, (w - used - CGFloat(n - 1) * gap) / CGFloat(n))
                cols += Array(repeating: each, count: n)
                used += CGFloat(n) * each
            }
        }
        let gaps = CGFloat(max(0, cols.count - 1)) * spacing
        if !flexible.isEmpty {
            let each = max(0, (w - used - gaps) / CGFloat(flexible.count))
            for i in flexible {
                if case let .flexible(mn, mx) = columns[min(i, columns.count - 1)].size { cols[i] = min(mx, max(mn, each)) } else { cols[i] = each }
            }
        }
        return cols
    }

    private func rows(_ widths: [CGFloat]) -> [[(LayoutNode, CGSize)]] {
        guard !widths.isEmpty else { return [] }
        var out: [[(LayoutNode, CGSize)]] = []
        var row: [(LayoutNode, CGSize)] = []
        for item in items {
            let w = widths[row.count]
            row.append((item, item.size(ProposedSize(width: w, height: nil))))
            if row.count == widths.count { out.append(row); row = [] }
        }
        if !row.isEmpty { out.append(row) }
        return out
    }

    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        let widths = columnWidths(p.width)
        let rs = rows(widths)
        let h = rs.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + CGFloat(max(0, rs.count - 1)) * rowSpacing
        let w = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * spacing
        return CGSize(width: p.width ?? w, height: h)
    }

    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        let widths = columnWidths(rect.width)
        var y = rect.minY
        for row in rows(widths) {
            let h = row.map(\.1.height).max() ?? 0
            var x = rect.minX
            for (i, (node, size)) in row.enumerated() {
                let cell = CGRect(x: x, y: y, width: widths[i], height: h)
                node.place(CGRect(origin: Alignment(horizontal: alignment, vertical: .center).origin(of: size, in: cell), size: size), sink)
                x += widths[i] + spacing
            }
            y += h + rowSpacing
        }
    }
}

/// ViewThatFits: the first child whose ideal size fits.
final class FitsNode: LayoutNode {
    let options: [LayoutNode]
    let axes: Axis.Set
    init(_ options: [LayoutNode], axes: Axis.Set) { self.options = options; self.axes = axes }
    override var children: [LayoutNode] { options }
    private func choice(_ p: ProposedSize) -> LayoutNode? {
        for o in options {
            let s = o.size(.unspecified)
            let fitsW = !axes.contains(.horizontal) || p.width == nil || s.width <= p.width! + 0.5
            let fitsH = !axes.contains(.vertical) || p.height == nil || s.height <= p.height! + 0.5
            if fitsW && fitsH { return o }
        }
        return options.last
    }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { choice(p)?.size(p) ?? .zero }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        choice(ProposedSize(width: rect.width, height: rect.height))?.place(rect, sink)
    }
}
