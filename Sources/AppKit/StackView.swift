// NSStackView: arranged subviews in a row or column with spacing, custom
// spacing, distributions, alignment, edge insets and detached hidden views.
// It lays out as Auto Layout resolves a stack's constraints: views keep
// their intrinsic size on the stacking axis unless they have none (or the
// distribution fills), and align across it.

import Foundation
import CoreGraphics
import RunwayCore

public typealias NSUserInterfaceLayoutOrientation = NSLayoutConstraint.Orientation

@preconcurrency @MainActor public protocol NSStackViewDelegate: AnyObject {
    func stackView(_ stackView: NSStackView, willDetach views: [NSView])
    func stackView(_ stackView: NSStackView, didReattach views: [NSView])
}
extension NSStackViewDelegate {
    public func stackView(_ stackView: NSStackView, willDetach views: [NSView]) {}
    public func stackView(_ stackView: NSStackView, didReattach views: [NSView]) {}
}

@preconcurrency @MainActor
open class NSStackView: NSView {
    open override var isFlipped: Bool { true }
    public enum Distribution: Int, Sendable { case gravityAreas = -1, fill = 0, fillEqually, fillProportionally, equalSpacing, equalCentering }
    public enum Gravity: Int, Sendable { case leading = 1, center, trailing; public static var top: Gravity { .leading }; public static var bottom: Gravity { .trailing } }
    public struct VisibilityPriority: RawRepresentable, Hashable, Sendable {
        public let rawValue: Float
        public init(rawValue: Float) { self.rawValue = rawValue }
        public static let mustHold = VisibilityPriority(rawValue: 1000)
        public static let detachOnlyIfNecessary = VisibilityPriority(rawValue: 900)
        public static let notVisible = VisibilityPriority(rawValue: 0)
    }
    public static let useDefaultSpacing: CGFloat = .greatestFiniteMagnitude

    public weak var delegate: NSStackViewDelegate?
    public var orientation: NSUserInterfaceLayoutOrientation = .horizontal {
        didSet {
            if !alignmentSet { alignment = orientation == .horizontal ? .centerY : .centerX; alignmentSet = false }
            setNeedsArrange()
        }
    }
    public var alignment: NSLayoutConstraint.Attribute = .centerY { didSet { alignmentSet = true; setNeedsArrange() } }
    private var alignmentSet = false
    public var spacing: CGFloat = 8 { didSet { setNeedsArrange() } }
    public var distribution: Distribution = .gravityAreas { didSet { setNeedsArrange() } }
    public var edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) { didSet { setNeedsArrange() } }
    public var detachesHiddenViews = true { didSet { setNeedsArrange() } }
    public var hasEqualSpacing: Bool {
        get { distribution == .equalSpacing }
        set { distribution = newValue ? .equalSpacing : .gravityAreas }
    }
    public private(set) var arrangedSubviews: [NSView] = []
    private var gravities: [ObjectIdentifier: Gravity] = [:]
    private var customSpacing: [ObjectIdentifier: CGFloat] = [:]
    private var visibility: [ObjectIdentifier: VisibilityPriority] = [:]
    private var stackHugging: [Int: NSLayoutConstraint.Priority] = [:]
    private var stackClipping: [Int: NSLayoutConstraint.Priority] = [:]
    private var lastHidden: Set<ObjectIdentifier> = []
    private var arranging = false

    public override init(frame frameRect: CGRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }
    public convenience init(views: [NSView]) {
        self.init(frame: .zero)
        for v in views { addArrangedSubview(v) }
    }

    // MARK: Arranged views

    open func addArrangedSubview(_ v: NSView) { insertArrangedSubview(v, at: arrangedSubviews.count) }
    open func insertArrangedSubview(_ v: NSView, at i: Int) {
        arrangedSubviews.removeAll { $0 === v }
        arrangedSubviews.insert(v, at: min(i, arrangedSubviews.count))
        if v.superview !== self { addSubview(v) }
        setNeedsArrange()
    }
    open func removeArrangedSubview(_ v: NSView) {
        arrangedSubviews.removeAll { $0 === v }
        setNeedsArrange()
    }
    open override func addSubview(_ v: NSView) {
        super.addSubview(v)
        setNeedsArrange()
    }

    /// Views by gravity area (the gravity-areas distribution).
    public func addView(_ v: NSView, in gravity: Gravity) {
        gravities[ObjectIdentifier(v)] = gravity
        let last = arrangedSubviews.lastIndex { (gravities[ObjectIdentifier($0)] ?? .leading).rawValue <= gravity.rawValue } ?? -1
        insertArrangedSubview(v, at: last + 1)
    }
    public func insertView(_ v: NSView, at i: Int, in gravity: Gravity) {
        gravities[ObjectIdentifier(v)] = gravity
        let inGravity = views(in: gravity)
        let anchor = i < inGravity.count ? arrangedSubviews.firstIndex { $0 === inGravity[i] } ?? arrangedSubviews.count : (arrangedSubviews.lastIndex { gravities[ObjectIdentifier($0)] ?? .leading == gravity }.map { $0 + 1 } ?? arrangedSubviews.count)
        insertArrangedSubview(v, at: anchor)
    }
    public func setViews(_ vs: [NSView], in gravity: Gravity) {
        for v in views(in: gravity) { removeArrangedSubview(v); v.removeFromSuperview() }
        for v in vs { addView(v, in: gravity) }
    }
    public func views(in gravity: Gravity) -> [NSView] { arrangedSubviews.filter { (gravities[ObjectIdentifier($0)] ?? .leading) == gravity } }
    public var views: [NSView] { arrangedSubviews }
    public var detachedViews: [NSView] { arrangedSubviews.filter { $0.isHidden } }

    public func setCustomSpacing(_ s: CGFloat, after v: NSView) { customSpacing[ObjectIdentifier(v)] = s; setNeedsArrange() }
    public func customSpacing(after v: NSView) -> CGFloat { customSpacing[ObjectIdentifier(v)] ?? Self.useDefaultSpacing }
    public func setVisibilityPriority(_ p: VisibilityPriority, for v: NSView) { visibility[ObjectIdentifier(v)] = p; setNeedsArrange() }
    public func visibilityPriority(for v: NSView) -> VisibilityPriority { visibility[ObjectIdentifier(v)] ?? .mustHold }
    public func setHuggingPriority(_ p: NSLayoutConstraint.Priority, for o: NSUserInterfaceLayoutOrientation) { stackHugging[o.rawValue] = p }
    public func huggingPriority(for o: NSUserInterfaceLayoutOrientation) -> NSLayoutConstraint.Priority { stackHugging[o.rawValue] ?? .defaultLow }
    public func setClippingResistancePriority(_ p: NSLayoutConstraint.Priority, for o: NSUserInterfaceLayoutOrientation) { stackClipping[o.rawValue] = p }
    public func clippingResistancePriority(for o: NSUserInterfaceLayoutOrientation) -> NSLayoutConstraint.Priority { stackClipping[o.rawValue] ?? .required }

    // MARK: Layout

    func setNeedsArrange() {
        invalidateIntrinsicSizeUp()
        LayoutQueue.setNeedsLayout(self)
    }

    /// A change inside resizes enclosing stacks too.
    private func invalidateIntrinsicSizeUp() {
        var p = superview
        while let s = p { if let st = s as? NSStackView { LayoutQueue.setNeedsLayout(st) }; p = s.superview }
    }

    private var horizontal: Bool { orientation == .horizontal }
    private var shown: [NSView] { arrangedSubviews.filter { !(detachesHiddenViews && $0.isHidden) && visibilityPriority(for: $0) != .notVisible } }

    /// A view's preferred size: intrinsic, else its frame, else nothing
    /// (-1: it takes what the stack gives).
    static func preferredSize(_ v: NSView) -> CGSize {
        if let s = v as? NSStackView { return s.fittingSize }
        if let b = v as? NSBox, b.boxType != .separator, let c = b.contentView {
            let f = c.fittingSize
            return CGSize(width: f.width > 0 ? f.width + b.contentViewMargins.width * 2 : -1, height: f.height > 0 ? f.height + b.contentViewMargins.height * 2 + 18 : -1)
        }
        var i = v.intrinsicContentSize
        // Width and height constraints on the view itself win, as Auto Layout resolves them.
        for c in v.constraints where c.isActive && c.firstItem === v && c.secondItem == nil && c.relation != .lessThanOrEqual {
            if c.firstAttribute == .width { i.width = c.relation == .equal ? c.constant : max(i.width, c.constant) }
            if c.firstAttribute == .height { i.height = c.relation == .equal ? c.constant : max(i.height, c.constant) }
        }
        // A view sized by its subviews' constraints (a plain container, or a
        // subclass such as a glass capsule pinned around a stack) fits them,
        // as Auto Layout sizes it on the Mac.
        let constrained = type(of: v) == NSView.self || v.subviews.contains { !$0.translatesAutoresizingMaskIntoConstraints }
        let fit = constrained && (i.width < 0 || i.height < 0) ? v.fittingSize : CGSize(width: -1, height: -1)
        return CGSize(width: i.width >= 0 ? i.width : (fit.width > 0 ? fit.width : -1),
                      height: i.height >= 0 ? i.height : (fit.height > 0 ? fit.height : -1))
    }

    /// Wrapping labels get their height at the width they're given.
    private static func height(_ v: NSView, width: CGFloat) -> CGFloat {
        if let tf = v as? NSTextField, tf.maximumNumberOfLines != 1 { return tf.height(forWidth: width) }
        if let s = v as? NSStackView { return s.fittingSize(forWidth: width).height }
        return preferredSize(v).height
    }

    private func spacing(after v: NSView) -> CGFloat {
        let c = customSpacing(after: v)
        return c == Self.useDefaultSpacing ? spacing : c
    }

    open override var fittingSize: CGSize { fittingSize(forWidth: nil) }
    open override var intrinsicContentSize: CGSize { fittingSize }

    func fittingSize(forWidth width: CGFloat?) -> CGSize {
        let views = shown
        var main: CGFloat = 0, cross: CGFloat = 0
        let innerWidth = width.map { $0 - edgeInsets.left - edgeInsets.right }
        for (i, v) in views.enumerated() {
            let p = Self.preferredSize(v)
            if horizontal {
                main += max(0, p.width)
                cross = max(cross, max(0, p.height))
            } else {
                let h = innerWidth.map { Self.height(v, width: p.width > 0 && alignment != .width ? min(p.width, $0) : $0) } ?? p.height
                main += max(0, h)
                cross = max(cross, max(0, p.width))
            }
            if i < views.count - 1 { main += spacing(after: v) }
        }
        let w = horizontal ? main : cross, h = horizontal ? cross : main
        return CGSize(width: (w + edgeInsets.left + edgeInsets.right).rounded(.up), height: (h + edgeInsets.top + edgeInsets.bottom).rounded(.up))
    }

    open override func layout() {
        super.layout()
        arrange()
    }

    /// Places the arranged views in the bounds.
    func arrange() {
        guard !arranging else { return }
        arranging = true
        defer { arranging = false }
        lastHidden = Set(arrangedSubviews.filter(\.isHidden).map { ObjectIdentifier($0) })
        let views = shown
        let inner = CGRect(x: edgeInsets.left, y: edgeInsets.top, width: max(0, bounds.width - edgeInsets.left - edgeInsets.right),
                           height: max(0, bounds.height - edgeInsets.top - edgeInsets.bottom))
        let mainLength = horizontal ? inner.width : inner.height
        let crossLength = horizontal ? inner.height : inner.width
        guard !views.isEmpty else { return }

        // Sizes across the stack first (they decide wrapped heights).
        var crossSizes: [CGFloat] = []
        var mainSizes: [CGFloat?] = []
        for v in views {
            let p = Self.preferredSize(v)
            let fillsCross = horizontal ? alignment == .height : alignment == .width
            var c = horizontal ? p.height : p.width
            if c < 0 || fillsCross { c = crossLength } else { c = min(c, crossLength) }
            crossSizes.append(c)
            if horizontal { mainSizes.append(p.width >= 0 ? p.width : nil) }
            else {
                let h = Self.height(v, width: c)
                mainSizes.append(h >= 0 ? h : nil)
            }
        }
        let gaps = views.dropLast().map { spacing(after: $0) }
        let gapTotal = gaps.reduce(0, +)
        var sizes = mainSizes.map { $0 ?? 0 }
        let fixedTotal = sizes.reduce(0, +)
        var extra = mainLength - fixedTotal - gapTotal
        let flexible = mainSizes.indices.filter { mainSizes[$0] == nil }

        switch distribution {
        case .fillEqually:
            let each = max(0, (mainLength - gapTotal) / CGFloat(views.count))
            sizes = Array(repeating: each, count: views.count)
            extra = 0
        case .fillProportionally:
            if fixedTotal > 0 { sizes = sizes.map { max(0, $0 + extra * $0 / fixedTotal) } } else { sizes = Array(repeating: max(0, (mainLength - gapTotal) / CGFloat(views.count)), count: views.count) }
            extra = 0
        case .fill:
            if !flexible.isEmpty {
                for i in flexible { sizes[i] = max(0, extra / CGFloat(flexible.count)) }
            } else if extra > 0, let i = loosest(views, below: nil) {
                // The view that hugs least takes the slack, as Auto Layout breaks the weakest hugging.
                sizes[i] += extra
            } else if let last = sizes.indices.last {
                sizes[last] = max(0, sizes[last] + extra)
            }
            extra = 0
        default:
            // Views without a size share what's left; the rest keep theirs.
            if !flexible.isEmpty, extra > 0 {
                for i in flexible { sizes[i] = extra / CGFloat(flexible.count) }
                extra = 0
            }
            // The gap between gravity areas holds at the stack's hugging
            // priority: a view that hugs more loosely stretches instead.
            if extra > 0, let i = loosest(views, below: huggingPriority(for: orientation)) {
                sizes[i] += extra
                extra = 0
            }
            if extra < 0 {
                // Compress the largest views first (clipping resistance).
                var over = -extra
                for i in sizes.indices.sorted(by: { sizes[$0] > sizes[$1] }) where over > 0 {
                    let cut = min(over, sizes[i] * 0.5)
                    sizes[i] -= cut
                    over -= cut
                }
                extra = 0
            }
        }

        // Where along the stack each view starts.
        var positions: [CGFloat] = []
        var gapsUsed = gaps
        var start: CGFloat = 0
        switch distribution {
        case .equalSpacing where views.count > 1:
            let g = (mainLength - sizes.reduce(0, +)) / CGFloat(views.count - 1)
            gapsUsed = Array(repeating: max(g, spacing), count: views.count - 1)
        case .equalCentering where views.count > 1:
            let firstHalf = sizes.first! / 2, lastHalf = sizes.last! / 2
            let step = (mainLength - firstHalf - lastHalf) / CGFloat(views.count - 1)
            var c = firstHalf
            for s in sizes { positions.append(c - s / 2); c += step }
        case .gravityAreas:
            // Leading views from the start, trailing from the end, centre in the middle.
            let lead = views.indices.filter { (gravities[ObjectIdentifier(views[$0])] ?? .leading) == .leading }
            let center = views.indices.filter { gravities[ObjectIdentifier(views[$0])] == .center }
            let trail = views.indices.filter { gravities[ObjectIdentifier(views[$0])] == .trailing }
            if !center.isEmpty || !trail.isEmpty {
                var pos = Array(repeating: CGFloat(0), count: views.count)
                var x: CGFloat = 0
                for i in lead { pos[i] = x; x += sizes[i] + (i < gaps.count ? gaps[i] : 0) }
                let trailLen = trail.map { sizes[$0] }.reduce(0, +) + CGFloat(max(0, trail.count - 1)) * spacing
                var tx = mainLength - trailLen
                for i in trail { pos[i] = tx; tx += sizes[i] + spacing }
                let centerLen = center.map { sizes[$0] }.reduce(0, +) + CGFloat(max(0, center.count - 1)) * spacing
                var cx = (mainLength - centerLen) / 2
                for i in center { pos[i] = cx; cx += sizes[i] + spacing }
                positions = pos
            }
        default:
            start = 0
        }
        if positions.isEmpty {
            var x = start
            for (i, s) in sizes.enumerated() {
                positions.append(x)
                x += s + (i < gapsUsed.count ? gapsUsed[i] : 0)
            }
        }

        for (i, v) in views.enumerated() {
            let c = crossSizes[i]
            var crossPos: CGFloat
            switch alignment {
            case .top, .leading, .left, .firstBaseline: crossPos = 0
            case .bottom, .trailing, .right, .lastBaseline: crossPos = crossLength - c
            default: crossPos = (crossLength - c) / 2
            }
            if alignment == .firstBaseline || alignment == .lastBaseline, horizontal { crossPos = (crossLength - c) / 2 }
            let f = horizontal
                ? CGRect(x: inner.minX + positions[i], y: inner.minY + crossPos, width: sizes[i], height: c)
                : CGRect(x: inner.minX + crossPos, y: inner.minY + positions[i], width: c, height: sizes[i])
            let r = CGRect(x: f.minX.rounded(), y: f.minY.rounded(), width: f.width.rounded(), height: f.height.rounded())
            if v.frame != r { v.frame = r } else { v.layout() }
        }
        layoutSubviews()
    }

    /// The arranged view with the lowest hugging priority on the stacking
    /// axis (the last of equals), if it is below `limit`.
    private func loosest(_ views: [NSView], below limit: NSLayoutConstraint.Priority?) -> Int? {
        var best: Int?
        var bestP = Float.infinity
        for (i, v) in views.enumerated() {
            let p = v.contentHuggingPriority(for: orientation).rawValue
            if p <= bestP { best = i; bestP = p }
        }
        if let limit, bestP >= limit.rawValue { return nil }
        return best
    }

    /// A subview shown or hidden re-arranges the stack.
    override func place() {
        placementDirty = false
        // Views removed from the stack stop being arranged, as in AppKit.
        if arrangedSubviews.contains(where: { $0.superview !== self }) {
            arrangedSubviews.removeAll { $0.superview !== self }
            setNeedsArrange()
        }
        let hidden = Set(arrangedSubviews.filter(\.isHidden).map { ObjectIdentifier($0) })
        if hidden != lastHidden, !arranging {
            let detached = arrangedSubviews.filter { hidden.contains(ObjectIdentifier($0)) && !lastHidden.contains(ObjectIdentifier($0)) }
            if !detached.isEmpty { delegate?.stackView(self, willDetach: detached) }
            lastHidden = hidden
            setNeedsArrange()
        }
        super.place()
    }

    open override func frameSizeChanged(from old: CGSize) {
        super.frameSizeChanged(from: old)
        arrange()
    }

    /// Sizes the stack to fit its views.
    public func sizeToFit() { setFrameSize(fittingSize) }
}
