// NSSplitView (panes with draggable dividers, delegate constraints,
// collapsing, holding priorities) and NSSplitViewController with
// NSSplitViewItem (sidebars, content lists, inspectors, toggleSidebar).

import Foundation
import CoreGraphics
import RunwayCore

@preconcurrency @MainActor public protocol NSSplitViewDelegate: AnyObject {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool
    func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView, forDoubleClickOnDividerAt dividerIndex: Int) -> Bool
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool
    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: CGRect, forDrawnRect drawnRect: CGRect, ofDividerAt dividerIndex: Int) -> CGRect
    func splitViewWillResizeSubviews(_ notification: Notification)
    func splitViewDidResizeSubviews(_ notification: Notification)
}
extension NSSplitViewDelegate {
    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
    public func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView, forDoubleClickOnDividerAt dividerIndex: Int) -> Bool { false }
    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { p }
    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { p }
    public func splitView(_ splitView: NSSplitView, constrainSplitPosition p: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { p }
    public func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { true }
    public func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { false }
    public func splitView(_ splitView: NSSplitView, effectiveRect r: CGRect, forDrawnRect drawnRect: CGRect, ofDividerAt dividerIndex: Int) -> CGRect { r }
    public func splitViewWillResizeSubviews(_ notification: Notification) {}
    public func splitViewDidResizeSubviews(_ notification: Notification) {}
}

@preconcurrency @MainActor
open class NSSplitView: NSView {
    open override var isFlipped: Bool { true }
    public enum DividerStyle: Int, Sendable { case thick = 1, thin = 2, paneSplitter = 3 }
    public static let willResizeSubviewsNotification = Notification.Name("NSSplitViewWillResizeSubviewsNotification")
    public static let didResizeSubviewsNotification = Notification.Name("NSSplitViewDidResizeSubviewsNotification")

    public weak var delegate: NSSplitViewDelegate?
    public var isVertical = false { didSet { adjustSubviews() } }
    public var dividerStyle: DividerStyle = .thick { didSet { adjustSubviews() } }
    public var arrangesAllSubviews = true
    public var autosaveName: String?
    public var dividerColor: NSColor { .separatorColor }
    public var dividerThickness: CGFloat { dividerStyle == .thin ? 1 : dividerStyle == .paneSplitter ? 9 : 9 }
    public var arrangedSubviews: [NSView] { arrangesAllSubviews ? subviews.filter { !($0 is DividerHandle) } : explicitArranged }
    private var explicitArranged: [NSView] = []
    private var holding: [ObjectIdentifier: NSLayoutConstraint.Priority] = [:]
    private var collapsed: Set<ObjectIdentifier> = []
    /// Each pane's length along the split, as last laid out.
    private var lengths: [ObjectIdentifier: CGFloat] = [:]
    private var handles: [DividerHandle] = []
    private let backdrop = DrawnLayer()
    private var lastSize: CGSize = .zero
    private var adjusting = false
    /// Hidden dividers (the controller hides those of collapsed sidebars).
    var hiddenDividers: Set<Int> = []
    /// Minimum and maximum pane lengths (split view items set these).
    var minimumLengths: [ObjectIdentifier: CGFloat] = [:]
    var maximumLengths: [ObjectIdentifier: CGFloat] = [:]

    public override init(frame frameRect: CGRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }

    open func addArrangedSubview(_ v: NSView) { explicitArranged.append(v); addSubview(v) }
    open func insertArrangedSubview(_ v: NSView, at i: Int) { explicitArranged.insert(v, at: min(i, explicitArranged.count)); addSubview(v) }
    open func removeArrangedSubview(_ v: NSView) { explicitArranged.removeAll { $0 === v }; adjustSubviews() }
    open override func addSubview(_ v: NSView) {
        // A pane starts at its own length (its frame along the split).
        if !(v is DividerHandle), lengths[ObjectIdentifier(v)] == nil, length(of: v.frame) > 0 { lengths[ObjectIdentifier(v)] = length(of: v.frame) }
        super.addSubview(v)
        if !(v is DividerHandle) { LayoutQueue.setNeedsLayout(self) }
    }

    public func holdingPriorityForSubview(at i: Int) -> NSLayoutConstraint.Priority {
        let a = arrangedSubviews
        return i < a.count ? holding[ObjectIdentifier(a[i])] ?? .defaultLow : .defaultLow
    }
    public func setHoldingPriority(_ p: NSLayoutConstraint.Priority, forSubviewAt i: Int) {
        let a = arrangedSubviews
        if i < a.count { holding[ObjectIdentifier(a[i])] = p }
    }
    public func isSubviewCollapsed(_ v: NSView) -> Bool { collapsed.contains(ObjectIdentifier(v)) }
    func setCollapsed(_ v: NSView, _ c: Bool) {
        let id = ObjectIdentifier(v)
        if c { collapsed.insert(id) } else { collapsed.remove(id) }
        adjustSubviews()
    }

    private func length(of r: CGRect) -> CGFloat { isVertical ? r.width : r.height }
    private var total: CGFloat { isVertical ? bounds.width : bounds.height }

    /// The position (leading edge) of divider `i`.
    public func position(ofDividerAt i: Int) -> CGFloat {
        let a = arrangedSubviews
        guard i < a.count - 1 else { return 0 }
        return isVertical ? a[i].frame.maxX : a[i].frame.maxY
    }

    open func setPosition(_ position: CGFloat, ofDividerAt i: Int) {
        let a = visiblePanes
        guard i >= 0, i + 1 < a.count else { return }
        let all = arrangedSubviews
        var pos = position
        // The panes either side share the space between their outer edges.
        let before = a[i], after = a[i + 1]
        let start = isVertical ? before.frame.minX : before.frame.minY
        let end = isVertical ? after.frame.maxX : after.frame.maxY
        var minP = start + (minimumLengths[ObjectIdentifier(before)] ?? 0)
        var maxP = end - dividerThickness - (minimumLengths[ObjectIdentifier(after)] ?? 0)
        if let m = maximumLengths[ObjectIdentifier(before)] { maxP = min(maxP, start + m) }
        if let m = maximumLengths[ObjectIdentifier(after)] { minP = max(minP, end - dividerThickness - m) }
        let di = all.firstIndex { $0 === before } ?? i
        if let d = delegate {
            minP = d.splitView(self, constrainMinCoordinate: minP, ofSubviewAt: di)
            maxP = d.splitView(self, constrainMaxCoordinate: maxP, ofSubviewAt: di)
            pos = d.splitView(self, constrainSplitPosition: pos, ofSubviewAt: di)
        }
        pos = max(minP, min(maxP, pos)).rounded()
        lengths[ObjectIdentifier(before)] = pos - start
        lengths[ObjectIdentifier(after)] = end - pos - dividerThickness
        placePanes()
    }

    private var visiblePanes: [NSView] { arrangedSubviews.filter { !$0.isHidden && !collapsed.contains(ObjectIdentifier($0)) } }

    /// Fits the panes to the view: new panes share space equally; on a
    /// resize the panes with the lowest holding priority absorb the change.
    open func adjustSubviews() {
        guard !adjusting else { return }
        adjusting = true
        defer { adjusting = false }
        let panes = visiblePanes
        guard panes.count > 1 else { placePanes(); return }
        let available = max(0, total - dividerThickness * CGFloat(panes.count - 1))
        for p in panes where lengths[ObjectIdentifier(p)] == nil {
            let l = length(of: p.frame)
            lengths[ObjectIdentifier(p)] = l > 0 ? l : available / CGFloat(panes.count)
        }
        var current = panes.map { lengths[ObjectIdentifier($0)]! }
        var delta = available - current.reduce(0, +)
        // Lowest holding priority first; ties go to the last pane.
        let order = panes.indices.sorted {
            let a = holding[ObjectIdentifier(panes[$0])] ?? .defaultLow, b = holding[ObjectIdentifier(panes[$1])] ?? .defaultLow
            return a == b ? $0 > $1 : a < b
        }
        for i in order where abs(delta) >= 0.5 {
            guard delegate?.splitView(self, shouldAdjustSizeOfSubview: panes[i]) ?? true else { continue }
            let id = ObjectIdentifier(panes[i])
            let minL = minimumLengths[id] ?? 0, maxL = maximumLengths[id] ?? .greatestFiniteMagnitude
            let new = max(minL, min(maxL, current[i] + delta))
            delta -= new - current[i]
            current[i] = new
        }
        if abs(delta) >= 0.5, let last = current.indices.last { current[last] = max(0, current[last] + delta) }
        for (p, l) in zip(panes, current) { lengths[ObjectIdentifier(p)] = l }
        placePanes()
    }

    /// Sets the panes' frames from their lengths, and draws the dividers.
    private func placePanes() {
        let n = Notification(name: Self.willResizeSubviewsNotification, object: self)
        delegate?.splitViewWillResizeSubviews(n)
        var x: CGFloat = 0
        let panes = visiblePanes
        var dividers: [CGRect] = []
        for (i, p) in panes.enumerated() {
            var l = (lengths[ObjectIdentifier(p)] ?? 0).rounded()
            if i == panes.count - 1 { l = max(0, total - x) }
            let f = isVertical ? CGRect(x: x, y: 0, width: l, height: bounds.height) : CGRect(x: 0, y: x, width: bounds.width, height: l)
            if p.frame != f { p.frame = f } else { p.layout() }
            x += l
            if i < panes.count - 1 {
                dividers.append(isVertical ? CGRect(x: x, y: 0, width: dividerThickness, height: bounds.height) : CGRect(x: 0, y: x, width: bounds.width, height: dividerThickness))
                x += dividerThickness
            }
        }
        for p in arrangedSubviews where collapsed.contains(ObjectIdentifier(p)) {
            p.frame = isVertical ? CGRect(x: 0, y: 0, width: 0, height: bounds.height) : CGRect(x: 0, y: 0, width: bounds.width, height: 0)
        }
        drawDividers(dividers)
        let d = Notification(name: Self.didResizeSubviewsNotification, object: self)
        delegate?.splitViewDidResizeSubviews(d)
        NotificationCenter.default.post(d)
        layoutSubviews()
    }

    private func drawDividers(_ rects: [CGRect]) {
        while handles.count < rects.count {
            let h = DividerHandle(frame: .zero)
            h.split = self
            h.index = handles.count
            handles.append(h)
            super.addSubview(h)
        }
        while handles.count > rects.count { handles.removeLast().removeFromSuperview() }
        var cmds: [DrawCommand] = []
        for (i, r) in rects.enumerated() {
            let hidden = hiddenDividers.contains(i) || (delegate?.splitView(self, shouldHideDividerAt: i) ?? false)
            if !hidden {
                switch dividerStyle {
                case .thin:
                    cmds.append(.fill(.rect(r), .color(dividerColor.rgbaValue)))
                case .thick, .paneSplitter:
                    // AppKit's thick divider: a band with hairlines and a centre dimple.
                    cmds.append(.fill(.rect(r), .color(NSColor.windowBackgroundColor.rgbaValue)))
                    let a = isVertical ? CGRect(x: r.minX, y: 0, width: 1, height: r.height) : CGRect(x: 0, y: r.minY, width: r.width, height: 1)
                    let b = isVertical ? CGRect(x: r.maxX - 1, y: 0, width: 1, height: r.height) : CGRect(x: 0, y: r.maxY - 1, width: r.width, height: 1)
                    cmds.append(.fill(.rect(a), .color(dividerColor.rgbaValue)))
                    cmds.append(.fill(.rect(b), .color(dividerColor.rgbaValue)))
                    let c = CGPoint(x: r.midX, y: r.midY)
                    cmds.append(.fill(.ellipse(CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), .color(NSColor.tertiaryLabelColor.rgbaValue)))
                }
            }
            // The grab area is wider than a thin divider.
            let grab: CGFloat = dividerStyle == .thin ? 3 : 0
            let hr = isVertical ? r.insetBy(dx: -grab, dy: 0) : r.insetBy(dx: 0, dy: -grab)
            if handles[i].frame != hr { handles[i].frame = hr }
            handles[i].isHidden = hidden && dividerStyle == .thin && hiddenDividers.contains(i)
        }
        backdrop.draw(cmds)
    }

    override func place() {
        placementDirty = false
        // Panes, then the dividers' drawing, then the grab handles on top.
        let panes = subviews.filter { !$0.isHidden && !($0 is DividerHandle) }.map { ($0.widget, $0.frame) }
        let grabs = handles.filter { !$0.isHidden }.map { ($0.widget, $0.frame) }
        Runway.backend.setChildren(widget, panes + [(backdrop.widget, bounds)] + grabs, contentSize: frame.size)
    }

    open override func layout() {
        super.layout()
        adjustSubviews()
    }

    open override func frameSizeChanged(from old: CGSize) {
        // Panes keep their lengths; the lowest-priority one takes the change.
        super.frameSizeChanged(from: old)
        adjustSubviews()
    }

    func dividerDragged(_ i: Int, to p: CGFloat) { setPosition(p, ofDividerAt: i) }
    func dividerDoubleClicked(_ i: Int) {
        let a = visiblePanes
        guard i + 1 < a.count else { return }
        for v in [a[i], a[i + 1]] where delegate?.splitView(self, shouldCollapseSubview: v, forDoubleClickOnDividerAt: i) ?? false {
            setCollapsed(v, true)
            return
        }
    }

    public func drawDivider(in rect: CGRect) {}
    public var dividerIndexForPoint: Int { -1 }
}

/// The area that drags a divider.
@MainActor final class DividerHandle: NSView {
    override var isFlipped: Bool { true }
    // AppKit's event dispatch (when the backend reports raw input).
    override func mouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.mouseDown(with: e) } }
    override func mouseDragged(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .dragged)) }
    override func mouseUp(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .up)) }
    override func mouseMoved(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .moved)) }
    override func rightMouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.rightMouseDown(with: e) } }

    weak var split: NSSplitView?
    var index = 0
    private var events: NativeWidget!
    private var grabOffset: CGFloat = 0

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain {
            events = makeEventWidget(focusable: false, pointer: { [weak self] e in self?.pointer(e) ?? false })
            Runway.appKit?.setCursor(events, .resizeLeftRight)
        }
    }
    required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }

    private func pointer(_ e: PointerEvent) -> Bool {
        guard let s = split else { return false }
        let along = s.isVertical ? e.location.x + frame.minX : e.location.y + frame.minY
        switch e.kind {
        case .down:
            if e.clickCount == 2 { s.dividerDoubleClicked(index); return true }
            grabOffset = along - s.position(ofDividerAt: index)
        case .dragged:
            s.dividerDragged(index, to: along - grabOffset)
        case .up: break
        default: return false
        }
        return true
    }

    override func place() {
        placementDirty = false
        Runway.appKit?.setCursor(events, split?.isVertical ?? true ? .resizeLeftRight : .resizeUpDown)
        placeChildren(below: [(events, bounds)])
    }
    override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }
}

// MARK: Split view controller

@preconcurrency @MainActor
open class NSSplitViewItem: NSObject {
    public enum Behavior: Int, Sendable { case `default` = 0, sidebar, contentList, inspector }
    public enum CollapseBehavior: Int, Sendable { case `default` = 0, preferResizingSplitViewWithFixedSiblings, preferResizingSiblingsWithFixedSplitView, useConstraints }
    public static let unspecifiedDimension: CGFloat = -1

    public let viewController: NSViewController
    public private(set) var behavior: Behavior = .default
    public var isCollapsed = false { didSet { if isCollapsed != oldValue { controller?.itemCollapseChanged(self) } } }
    public var canCollapse = false
    public var canCollapseFromWindowResize = true
    public var collapseBehavior: CollapseBehavior = .default
    public var holdingPriority: NSLayoutConstraint.Priority = .defaultLow { didSet { controller?.applyItemSettings() } }
    public var minimumThickness: CGFloat = NSSplitViewItem.unspecifiedDimension { didSet { controller?.applyItemSettings() } }
    public var maximumThickness: CGFloat = NSSplitViewItem.unspecifiedDimension { didSet { controller?.applyItemSettings() } }
    public var preferredThicknessFraction: CGFloat = NSSplitViewItem.unspecifiedDimension
    public var automaticMaximumThickness: CGFloat = NSSplitViewItem.unspecifiedDimension
    public var isSpringLoaded = false
    public var allowsFullHeightLayout = true
    public var titlebarSeparatorStyle = 0
    public var automaticallyAdjustsSafeAreaInsets = false
    weak var controller: NSSplitViewController?
    /// The view the split view arranges (the controller's view, with a
    /// sidebar's material behind it).
    var paneView: NSView?

    public init(viewController: NSViewController) { self.viewController = viewController; super.init() }
    public convenience init(sidebarWithViewController vc: NSViewController) {
        self.init(viewController: vc)
        behavior = .sidebar
        canCollapse = true
        holdingPriority = NSLayoutConstraint.Priority(260)
        minimumThickness = 140
        maximumThickness = 400
    }
    public convenience init(contentListWithViewController vc: NSViewController) {
        self.init(viewController: vc)
        behavior = .contentList
        holdingPriority = NSLayoutConstraint.Priority(260)
        minimumThickness = 180
    }
    public convenience init(inspectorWithViewController vc: NSViewController) {
        self.init(viewController: vc)
        behavior = .inspector
        canCollapse = true
        holdingPriority = NSLayoutConstraint.Priority(260)
        minimumThickness = 200
    }
    public func animator() -> NSSplitViewItem { self }
}

@preconcurrency @MainActor
open class NSSplitViewController: NSViewController, NSSplitViewDelegate {
    public static let automaticDimension: CGFloat = -1
    /// The panes, in order; setting it replaces them.
    public var splitViewItems: [NSSplitViewItem] {
        get { items }
        set {
            for i in items where !newValue.contains(where: { $0 === i }) { removeSplitViewItem(i) }
            for (n, i) in newValue.enumerated() where !items.contains(where: { $0 === i }) { insertSplitViewItem(i, at: n) }
        }
    }
    private var items: [NSSplitViewItem] = []
    public var splitView: NSSplitView = NSSplitView(frame: .zero) {
        didSet { if isViewLoaded { view = splitView }; splitView.delegate = self }
    }
    public var minimumThicknessForInlineSidebars: CGFloat = NSSplitViewController.automaticDimension

    open override func loadView() {
        AppKitControls.install()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.frame = CGRect(origin: .zero, size: preferredContentSize == .zero ? CGSize(width: 800, height: 500) : preferredContentSize)
        view = splitView
    }

    open func addSplitViewItem(_ item: NSSplitViewItem) { insertSplitViewItem(item, at: splitViewItems.count) }
    open func insertSplitViewItem(_ item: NSSplitViewItem, at i: Int) {
        _ = view   // items go in the loaded split view
        item.controller = self
        items.insert(item, at: min(i, items.count))
        let v = item.viewController.view
        let pane: NSView
        if item.behavior == .sidebar {
            // Sidebars sit on the sidebar material, as on the Mac.
            let fx = NSVisualEffectView(frame: v.frame)
            fx.material = .sidebar
            fx.blendingMode = .behindWindow
            v.frame = fx.bounds
            v.autoresizingMask = [.width, .height]
            fx.addSubview(v)
            pane = fx
        } else {
            pane = v
        }
        item.paneView = pane
        if item.preferredThicknessFraction > 0 { pane.frame.size.width = max(pane.frame.width, item.preferredThicknessFraction * splitView.bounds.width) }
        if item.behavior == .sidebar, pane.frame.width <= 0 { pane.frame.size.width = 220 }
        // Panes go in item order.
        let ordered = splitViewItems.compactMap(\.paneView)
        for p in ordered where p.superview === splitView { p.removeFromSuperview() }
        for p in ordered { splitView.addSubview(p) }
        applyItemSettings()
        if item.isCollapsed { splitView.setCollapsed(pane, true) }
    }
    open func removeSplitViewItem(_ item: NSSplitViewItem) {
        item.paneView?.removeFromSuperview()
        items.removeAll { $0 === item }
        splitView.adjustSubviews()
    }
    public func splitViewItem(for vc: NSViewController) -> NSSplitViewItem? { splitViewItems.first { $0.viewController === vc } }

    func applyItemSettings() {
        for (i, item) in splitViewItems.enumerated() {
            guard let p = item.paneView else { continue }
            splitView.setHoldingPriority(item.holdingPriority, forSubviewAt: i)
            let id = ObjectIdentifier(p)
            splitView.minimumLengths[id] = item.minimumThickness > 0 ? item.minimumThickness : nil
            splitView.maximumLengths[id] = item.maximumThickness > 0 ? item.maximumThickness : nil
        }
        splitView.adjustSubviews()
    }

    func itemCollapseChanged(_ item: NSSplitViewItem) {
        guard let p = item.paneView else { return }
        splitView.setCollapsed(p, item.isCollapsed)
        NotificationCenter.default.post(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }

    /// Shows or hides the first sidebar.
    open func toggleSidebar(_ sender: Any?) {
        guard let s = splitViewItems.first(where: { $0.behavior == .sidebar }) else { return }
        s.isCollapsed.toggle()
    }
    open func toggleInspector(_ sender: Any?) {
        guard let s = splitViewItems.first(where: { $0.behavior == .inspector }) else { return }
        s.isCollapsed.toggle()
    }

    // NSSplitViewDelegate (the controller is its split view's delegate;
    // subclasses override these and call super).
    open func splitViewWillResizeSubviews(_ notification: Notification) {}
    open func splitViewDidResizeSubviews(_ notification: Notification) {}

    // NSSplitViewDelegate
    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        splitViewItems.first { $0.paneView === subview }?.canCollapse ?? false
    }
    public func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { false }
}

extension NSResponder {
    /// Runway: the toggleSidebar(_:) action, sent up the window's controllers.
    @preconcurrency @MainActor public func runwayToggleSidebar(in window: NSWindow?) {
        (window?.contentViewController as? NSSplitViewController)?.toggleSidebar(nil)
    }
}

// MARK: Visual effect and glass views

/// macOS 26's glass: a rounded, tinted panel holding a content view.
@preconcurrency @MainActor
open class NSGlassEffectView: NSView {
    open override var isFlipped: Bool { true }
    public enum Style: Int, Sendable { case regular = 0, clear }
    public var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let c = contentView { NSView._embedFilling(c, in: self) }
        }
    }
    public var cornerRadius: CGFloat = 12 { didSet { redraw() } }
    public var tintColor: NSColor? { didSet { redraw() } }
    public var style: Style = .regular { didSet { redraw() } }
    private let backdrop = DrawnLayer()

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain { redraw() }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        onMain { redraw() }
        IBDecoding.leave(self, coder)
    }

    private func redraw() {
        let dark = NSAppearance.current.isDark
        var fill = dark ? RGBA(1, 1, 1, style == .clear ? 0.06 : 0.12) : RGBA(1, 1, 1, style == .clear ? 0.35 : 0.72)
        if let t = tintColor?.rgbaValue { fill = RGBA(t.r, t.g, t.b, max(0.2, t.a * 0.5)) }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        backdrop.draw([.fill(.roundedRect(r, radius: cornerRadius), .color(fill)),
                    .stroke(.roundedRect(r, radius: cornerRadius), .color(RGBA(0, 0, 0, dark ? 0.3 : 0.08)), lineWidth: 1, dash: [])])
        layoutSubviews()
    }
    override func place() {
        placementDirty = false; placeChildren(below: [(backdrop.widget, bounds)]) }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); redraw() }
}

extension NSView {
    /// How AppKit embeds a glass view's content: pinned edge to edge with
    /// constraints, so the glass takes its size from the content (a capsule
    /// of buttons hugs them) as well as handing its size down.
    static func _embedFilling(_ c: NSView, in host: NSView) {
        c.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(c)
        NSLayoutConstraint.activate([
            c.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            c.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            c.topAnchor.constraint(equalTo: host.topAnchor),
            c.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }
}

@preconcurrency @MainActor open class NSGlassEffectContainerView: NSView {
    public var contentView: NSView? {
        didSet { oldValue?.removeFromSuperview(); if let c = contentView { NSView._embedFilling(c, in: self) } }
    }
    public var spacing: CGFloat = 0
}
