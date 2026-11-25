// NSView: frame and bounds (flipped or not), the view hierarchy,
// coordinate conversion, display and hit testing.
//
// Each view owns a native container widget its subviews' widgets sit in.
// A view that draws gets a `.canvas` widget behind its subviews showing the
// CGDisplayList its `draw(_:)` recorded; drawing happens again only when the
// view is marked as needing display, never per frame. Placement, layout
// and display are deferred and coalesced (`ViewSystem.flush`), run after
// each event and once per main-loop turn otherwise.

import Foundation
@_exported import QuartzCore
import RunwayCore
import RunwayPlatform

@preconcurrency @MainActor
open class NSView: NSResponder, NSAppearanceCustomization, NSUserInterfaceItemIdentification {
    /// The native container this view's subviews (and drawing) sit in.
    nonisolated(unsafe) public let widget: NativeWidget
    /// The canvas showing `draw(_:)`'s output (created on first drawing).
    var drawingWidget: NativeWidget?
    var lastDrawing: CGDisplayList?

    open private(set) var subviews: [NSView] = []
    open private(set) weak var superview: NSView?
    /// The window: the content view's, inherited down the tree.
    open internal(set) weak var window: NSWindow?
    weak var _viewController: NSViewController?

    open var autoresizingMask: AutoresizingMask = []
    open var autoresizesSubviews = true
    open var translatesAutoresizingMaskIntoConstraints = true {
        didSet { if oldValue != translatesAutoresizingMaskIntoConstraints { layoutStructureChanged() } }
    }
    open var identifier: NSUserInterfaceItemIdentifier?
    open var tag: Int { -1 }
    open var wantsLayer = false
    /// Runway: views backed by a native widget that takes keyboard focus
    /// itself (text fields) set this; key events then go to the widget.
    open var usesNativeKeyboardFocus: Bool { false }
    /// Views that manage their container's children themselves (hosting
    /// views) set this so NSView's placement leaves them alone.
    open var managesOwnContent: Bool { false }

    open var toolTip: String? { didSet { updateWidgetProps() } }
    open var alphaValue: CGFloat = 1 { didSet { updateWidgetProps(); KVO.didChange(self, "alphaValue", old: oldValue, new: alphaValue) } }
    open var isHidden = false {
        didSet {
            guard oldValue != isHidden else { return }
            KVO.didChange(self, "hidden", old: oldValue, new: isHidden)
            KVO.didChange(self, "isHidden", old: oldValue, new: isHidden)
            superview?.setNeedsPlacement()
            if isHidden, let w = window, let fr = w.firstResponder as? NSView, fr.isDescendant(of: self) { _ = w.makeFirstResponder(nil) }
            viewDidHide(); if !isHidden { viewDidUnhide() }
        }
    }
    open var isHiddenOrHasHiddenAncestor: Bool { isHidden || (superview?.isHiddenOrHasHiddenAncestor ?? false) }
    /// Clips subviews to the bounds (macOS 14's default: no).
    open var clipsToBounds = false { didSet { updateWidgetProps() } }
    open var isOpaque: Bool { false }
    open var wantsDefaultClipping: Bool { true }
    open var canDrawConcurrently = false
    open var preservesContentDuringLiveResize: Bool { false }
    open var inLiveResize: Bool { false }
    open var layerContentsRedrawPolicy: LayerContentsRedrawPolicy = .duringViewResize
    public enum LayerContentsRedrawPolicy: Int, Sendable { case never, onSetNeedsDisplay, duringViewResize, beforeViewResize, crossfade }
    open var focusRingType: NSFocusRingType = .default
    open var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection = .leftToRight
    open var postsFrameChangedNotifications = true
    open var postsBoundsChangedNotifications = true
    open var allowedTouchTypes: Int = 0
    open var pressureConfiguration: AnyObject?
    open var mouseDownCanMoveWindow: Bool { !isOpaque }
    open var acceptsTouchEvents = false
    open var wantsRestingTouches = false

    public static let frameDidChangeNotification = Notification.Name("NSViewFrameDidChangeNotification")
    public static let boundsDidChangeNotification = Notification.Name("NSViewBoundsDidChangeNotification")
    public static let noIntrinsicMetric: CGFloat = -1

    public struct AutoresizingMask: OptionSet, Sendable, Hashable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let none = AutoresizingMask([])
        public static let minXMargin = AutoresizingMask(rawValue: 1)
        public static let width = AutoresizingMask(rawValue: 2)
        public static let maxXMargin = AutoresizingMask(rawValue: 4)
        public static let minYMargin = AutoresizingMask(rawValue: 8)
        public static let height = AutoresizingMask(rawValue: 16)
        public static let maxYMargin = AutoresizingMask(rawValue: 32)
    }

    // MARK: Creating

    public init(frame frameRect: NSRect) {
        RunwayPlatform.installDefaultBackend()
        AppKitRuntime.install()
        widget = Runway.backend.makeWidget(.container)
        _frame = frameRect
        _bounds = CGRect(origin: .zero, size: frameRect.size)
        super.init()
        needsDisplay = true
    }
    public override convenience init() { self.init(frame: .zero) }
    /// Interface Builder documents decode views through this (InterfaceBuilder/).
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        RunwayPlatform.installDefaultBackend()
        AppKitRuntime.install()
        widget = Runway.backend.makeWidget(.container)
        let frameRect = IBDecoding.frame(coder)
        _frame = frameRect
        _bounds = CGRect(origin: .zero, size: frameRect.size)
        super.init(coder: coder)
        needsDisplay = true
        IBDecoding.leave(self, coder)
    }

    // MARK: Geometry

    private var _frame: CGRect
    private var _bounds: CGRect
    private var boundsSet = false

    /// The view's rectangle in its superview's coordinates.
    open var frame: NSRect {
        get { _frame }
        set {
            let old = _frame
            guard newValue != old else { return }
            _frame = newValue
            defer { KVO.didChange(self, "frame", old: old, new: newValue) }
            if !boundsSet { _bounds.size = newValue.size } else if old.size != newValue.size {
                // Bounds keep their scale: grow with the frame.
                let sx = old.width != 0 ? _bounds.width / old.width : 1, sy = old.height != 0 ? _bounds.height / old.height : 1
                _bounds.size = CGSize(width: newValue.width * sx, height: newValue.height * sy)
            }
            superview?.setNeedsPlacement()
            if old.size != newValue.size {
                frameSizeChanged(from: old.size)
                setNeedsPlacement()
                needsDisplay = true
                needsLayout = true
            }
            if !translatesAutoresizingMaskIntoConstraints { } else { layoutConstantsChanged() }
            ViewSystem.geometryChanged(self)
            if postsFrameChangedNotifications { NotificationCenter.default.post(name: Self.frameDidChangeNotification, object: self) }
        }
    }

    /// The view's own coordinate system: its origin (scrolling) and size
    /// (scaling) relative to the frame.
    open var bounds: NSRect {
        get { _bounds }
        set {
            guard newValue != _bounds else { return }
            let oldBounds = _bounds
            _bounds = newValue
            defer { KVO.didChange(self, "bounds", old: oldBounds, new: newValue) }
            boundsSet = newValue.size != _frame.size || newValue.origin != .zero
            setNeedsPlacement()
            needsDisplay = true
            ViewSystem.geometryChanged(self)
            if postsBoundsChangedNotifications { NotificationCenter.default.post(name: Self.boundsDidChangeNotification, object: self) }
        }
    }

    open func setFrameSize(_ s: NSSize) { frame = CGRect(origin: _frame.origin, size: s) }
    open func setFrameOrigin(_ p: NSPoint) { frame = CGRect(origin: p, size: _frame.size) }
    open func setBoundsOrigin(_ p: NSPoint) { bounds = CGRect(origin: p, size: _bounds.size) }
    open func setBoundsSize(_ s: NSSize) { bounds = CGRect(origin: _bounds.origin, size: s) }
    open func translateOrigin(to p: NSPoint) { setBoundsOrigin(CGPoint(x: _bounds.minX - p.x, y: _bounds.minY - p.y)) }
    open func scaleUnitSquare(to s: NSSize) { setBoundsSize(CGSize(width: _bounds.width / s.width, height: _bounds.height / s.height)) }
    open var frameRotation: CGFloat = 0
    open var boundsRotation: CGFloat = 0
    open var frameCenterRotation: CGFloat = 0

    /// Whether y grows downward. AppKit's default is no (y-up, origin at
    /// the bottom-left).
    open var isFlipped: Bool { false }

    /// Called when the frame's size changes: resizes autoresizing subviews.
    open func frameSizeChanged(from old: CGSize) {
        resizeSubviews(withOldSize: old)
    }
    open func resizeSubviews(withOldSize oldSize: NSSize) {
        guard autoresizesSubviews else { return }
        for v in subviews where v.translatesAutoresizingMaskIntoConstraints && !v.autoresizingMask.isEmpty {
            v.resize(withOldSuperviewSize: oldSize)
        }
    }
    /// Applies the autoresizing mask: each axis's change is shared among
    /// its flexible parts in proportion to their sizes.
    open func resize(withOldSuperviewSize oldSize: NSSize) {
        guard let s = superview else { return }
        let m = autoresizingMask
        var f = frame
        func distribute(_ delta: CGFloat, _ minM: Bool, _ size: Bool, _ maxM: Bool, _ lo: CGFloat, _ len: CGFloat, _ hi: CGFloat) -> (CGFloat, CGFloat) {
            let parts = [(minM, lo), (size, len), (maxM, hi)].filter(\.0)
            guard !parts.isEmpty else { return (0, 0) }
            let total = parts.map { max(0, $0.1) }.reduce(0, +)
            func share(_ on: Bool, _ v: CGFloat) -> CGFloat {
                guard on else { return 0 }
                return total > 0 ? delta * max(0, v) / total : delta / CGFloat(parts.count)
            }
            return (share(minM, lo), share(size, len))
        }
        let nw = s.bounds.width, nh = s.bounds.height
        let (dx, dw) = distribute(nw - oldSize.width, m.contains(.minXMargin), m.contains(.width), m.contains(.maxXMargin),
                                  f.minX, f.width, oldSize.width - f.maxX)
        let (dy, dh) = distribute(nh - oldSize.height, m.contains(.minYMargin), m.contains(.height), m.contains(.maxYMargin),
                                  f.minY, f.height, oldSize.height - f.maxY)
        f.origin.x += dx; f.size.width = max(0, f.width + dw)
        f.origin.y += dy; f.size.height = max(0, f.height + dh)
        frame = f
    }

    open var visibleRect: NSRect {
        var r = bounds
        var v: NSView = self
        while let s = v.superview {
            let inS = v.convert(r, to: s).intersection(s.bounds)
            if inS.isNull { return .zero }
            r = s.convert(inS, to: self)
            v = s
        }
        return r.intersection(bounds)
    }

    // MARK: Coordinate conversion

    /// A point in this view's bounds to its superview's coordinates (or
    /// window coordinates for a window's content view: y-up, origin at the
    /// bottom-left of the content area).
    func toParent(_ p: CGPoint) -> CGPoint {
        let sx = _bounds.width != 0 ? _frame.width / _bounds.width : 1
        let sy = _bounds.height != 0 ? _frame.height / _bounds.height : 1
        let lx = (p.x - _bounds.minX) * sx, ly = (p.y - _bounds.minY) * sy
        let parentFlipped = superview?.isFlipped ?? false
        if isFlipped == parentFlipped { return CGPoint(x: _frame.minX + lx, y: _frame.minY + ly) }
        return CGPoint(x: _frame.minX + lx, y: _frame.maxY - ly)
    }
    func fromParent(_ q: CGPoint) -> CGPoint {
        let sx = _frame.width != 0 ? _bounds.width / _frame.width : 1
        let sy = _frame.height != 0 ? _bounds.height / _frame.height : 1
        let parentFlipped = superview?.isFlipped ?? false
        let lx = q.x - _frame.minX
        let ly = isFlipped == parentFlipped ? q.y - _frame.minY : _frame.maxY - q.y
        return CGPoint(x: lx * sx + _bounds.minX, y: ly * sy + _bounds.minY)
    }
    /// To the root of the hierarchy's base space (the window's coordinates
    /// when it's a window's content view).
    func toBase(_ p: CGPoint) -> CGPoint {
        var q = p
        var v: NSView? = self
        while let cur = v { q = cur.toParent(q); v = cur.superview }
        return q
    }
    func fromBase(_ p: CGPoint) -> CGPoint {
        var chain: [NSView] = []
        var v: NSView? = self
        while let cur = v { chain.append(cur); v = cur.superview }
        var q = p
        for cur in chain.reversed() { q = cur.fromParent(q) }
        return q
    }

    open func convert(_ point: NSPoint, from view: NSView?) -> NSPoint {
        guard let view else { return fromBase(point) }
        if view === self { return point }
        if view === superview { return fromParent(point) }
        if view.superview === self { return view.toParent(point) }
        return fromBase(view.toBase(point))
    }
    open func convert(_ point: NSPoint, to view: NSView?) -> NSPoint {
        guard let view else { return toBase(point) }
        return view.convert(point, from: self)
    }
    open func convert(_ size: NSSize, from view: NSView?) -> NSSize {
        let o = convert(CGPoint.zero, from: view), p = convert(CGPoint(x: size.width, y: size.height), from: view)
        return CGSize(width: abs(p.x - o.x), height: abs(p.y - o.y))
    }
    open func convert(_ size: NSSize, to view: NSView?) -> NSSize {
        let o = convert(CGPoint.zero, to: view), p = convert(CGPoint(x: size.width, y: size.height), to: view)
        return CGSize(width: abs(p.x - o.x), height: abs(p.y - o.y))
    }
    open func convert(_ rect: NSRect, from view: NSView?) -> NSRect {
        let a = convert(CGPoint(x: rect.minX, y: rect.minY), from: view), b = convert(CGPoint(x: rect.maxX, y: rect.maxY), from: view)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
    open func convert(_ rect: NSRect, to view: NSView?) -> NSRect {
        let a = convert(CGPoint(x: rect.minX, y: rect.minY), to: view), b = convert(CGPoint(x: rect.maxX, y: rect.maxY), to: view)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
    open func convertToBacking(_ p: NSPoint) -> NSPoint { p }
    open func convertFromBacking(_ p: NSPoint) -> NSPoint { p }
    open func convertToBacking(_ r: NSRect) -> NSRect { r }
    open func convertFromBacking(_ r: NSRect) -> NSRect { r }
    open func convertToBacking(_ s: NSSize) -> NSSize { s }
    open func convertFromBacking(_ s: NSSize) -> NSSize { s }
    open func backingAlignedRect(_ r: NSRect, options: AlignmentOptions) -> NSRect { r.integral }
    public struct AlignmentOptions: OptionSet, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let alignAllEdgesNearest = AlignmentOptions(rawValue: 0x0F0000)
        public static let alignAllEdgesInward = AlignmentOptions(rawValue: 0x0F)
        public static let alignAllEdgesOutward = AlignmentOptions(rawValue: 0x0F00)
    }
    open func centerScanRect(_ r: NSRect) -> NSRect { r.integral }

    // MARK: The hierarchy

    open func addSubview(_ view: NSView) { insertSubview(view, at: subviews.count) }

    open func addSubview(_ view: NSView, positioned place: NSWindow.OrderingMode, relativeTo other: NSView?) {
        let idx: Int
        if let other, let i = subviews.firstIndex(where: { $0 === other }) {
            idx = place == .below ? i : i + 1
        } else {
            idx = place == .below ? 0 : subviews.count
        }
        insertSubview(view, at: idx)
    }

    func insertSubview(_ view: NSView, at index: Int) {
        precondition(view !== self, "a view can't be its own subview")
        if view.superview === self, let i = subviews.firstIndex(where: { $0 === view }) {
            subviews.remove(at: i)
            subviews.insert(view, at: min(index > i ? index - 1 : index, subviews.count))
            setNeedsPlacement()
            return
        }
        let oldWindow = view.window
        let newWindow = window
        if oldWindow !== newWindow { view.viewWillMove(toWindow: newWindow) }
        view.viewWillMove(toSuperview: self)
        view.detachFromSuperview()
        subviews.insert(view, at: min(index, subviews.count))
        view.superview = self
        view.setWindowRecursively(newWindow)
        setNeedsPlacement()
        view.layoutStructureChanged()
        view.viewDidMoveToSuperview()
        if oldWindow !== newWindow { view.viewDidMoveToWindowRecursively() }
        didAddSubview(view)
        if newWindow != nil { view.appearanceMayHaveChanged() }
    }

    private func detachFromSuperview() {
        guard let s = superview else { return }
        s.willRemoveSubview(self)
        s.subviews.removeAll { $0 === self }
        s.setNeedsPlacement()
        s.layoutStructureChanged()
        superview = nil
    }

    open func removeFromSuperview() {
        guard superview != nil else { return }
        let oldWindow = window
        if oldWindow != nil { viewWillMove(toWindow: nil) }
        viewWillMove(toSuperview: nil)
        if let w = oldWindow, let fr = w.firstResponder as? NSView, fr === self || fr.isDescendant(of: self) { _ = w.makeFirstResponder(nil) }
        for c in constraintsInvolvingOutside() { c.isActive = false }
        detachFromSuperview()
        setWindowRecursively(nil)
        layoutStructureChanged()
        viewDidMoveToSuperview()
        if oldWindow != nil { viewDidMoveToWindowRecursively() }
    }
    open func removeFromSuperviewWithoutNeedingDisplay() { removeFromSuperview() }
    open func replaceSubview(_ old: NSView, with new: NSView) {
        guard let i = subviews.firstIndex(where: { $0 === old }) else { return }
        old.removeFromSuperview()
        insertSubview(new, at: i)
    }
    open func setSubviews(_ views: [NSView]) {
        for v in subviews where !views.contains(where: { $0 === v }) { v.removeFromSuperview() }
        for (i, v) in views.enumerated() { insertSubview(v, at: i) }
    }
    open func sortSubviews(_ areInIncreasingOrder: (NSView, NSView) -> Bool) {
        subviews.sort(by: areInIncreasingOrder)
        setNeedsPlacement()
    }

    open func isDescendant(of view: NSView) -> Bool {
        var v: NSView? = self
        while let cur = v { if cur === view { return true }; v = cur.superview }
        return false
    }
    open func ancestorShared(with view: NSView) -> NSView? {
        var mine = Set<ObjectIdentifier>()
        var v: NSView? = self
        while let cur = v { mine.insert(ObjectIdentifier(cur)); v = cur.superview }
        v = view
        while let cur = v { if mine.contains(ObjectIdentifier(cur)) { return cur }; v = cur.superview }
        return nil
    }
    open func viewWithTag(_ tag: Int) -> NSView? {
        if self.tag == tag { return self }
        for s in subviews { if let v = s.viewWithTag(tag) { return v } }
        return nil
    }
    open var opaqueAncestor: NSView? { isOpaque ? self : superview?.opaqueAncestor }

    open func viewWillMove(toSuperview newSuperview: NSView?) {}
    open func viewDidMoveToSuperview() {}
    open func viewWillMove(toWindow newWindow: NSWindow?) {}
    open func viewDidMoveToWindow() {}
    open func didAddSubview(_ subview: NSView) {}
    open func willRemoveSubview(_ subview: NSView) {}
    open func viewDidHide() {}
    open func viewDidUnhide() {}
    open func viewDidChangeBackingProperties() {}
    open func viewWillStartLiveResize() {}
    open func viewDidEndLiveResize() {}

    func setWindowRecursively(_ w: NSWindow?) {
        window = w
        for s in subviews { s.setWindowRecursively(w) }
    }
    func viewDidMoveToWindowRecursively() {
        viewDidMoveToWindow()
        if window != nil { needsDisplay = true; ViewSystem.geometryChanged(self) }
        for s in subviews { s.viewDidMoveToWindowRecursively() }
        if let vc = _viewController { vc.viewMovedToWindow(window) }
    }

    // MARK: The responder chain

    open override var nextResponder: NSResponder? {
        get {
            if let n = explicitNextResponder { return n }
            if let vc = _viewController, vc.view === self { return vc }
            return superview ?? window
        }
        set { super.nextResponder = newValue }
    }
    /// Where the next responder after this view's controller goes.
    var nextResponderSkippingController: NSResponder? { superview ?? window }

    open var needsPanelToBecomeKey: Bool { false }
    open var acceptsFirstMouse: Bool { false }
    open func acceptsFirstMouse(for event: NSEvent?) -> Bool { acceptsFirstMouse }
    open var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }
    open weak var nextKeyView: NSView?
    open var previousKeyView: NSView? {
        guard let root = window?.contentView else { return nil }
        var found: NSView?
        func walk(_ v: NSView) { if v.nextKeyView === self { found = v }; v.subviews.forEach(walk) }
        walk(root)
        return found
    }
    open var nextValidKeyView: NSView? {
        var v = nextKeyView
        var n = 0
        while let cur = v, n < 256 { if cur.canBecomeKeyView { return cur }; v = cur.nextKeyView; n += 1 }
        return nil
    }
    open var previousValidKeyView: NSView? { previousKeyView }

    // MARK: Hit testing

    /// The deepest visible view containing `point` (in the superview's
    /// coordinates), front-most first.
    open func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let local = fromParent(point)
        guard bounds.contains(local) else { return nil }
        for s in subviews.reversed() {
            if let hit = s.hitTest(local) { return hit }
        }
        return self
    }
    open func isMousePoint(_ point: NSPoint, in rect: NSRect) -> Bool { mouse(point, in: rect) }
    open func mouse(_ point: NSPoint, in rect: NSRect) -> Bool {
        isFlipped ? (point.x >= rect.minX && point.x < rect.maxX && point.y >= rect.minY && point.y < rect.maxY)
            : (point.x >= rect.minX && point.x < rect.maxX && point.y > rect.minY && point.y <= rect.maxY)
    }

    // MARK: Events with view defaults

    /// The context menu for an event: the view's `menu` by default.
    open func menu(for event: NSEvent) -> NSMenu? { menu ?? Self.defaultMenu }
    open class var defaultMenu: NSMenu? { nil }
    open func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {}
    open func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {}

    open override func rightMouseDown(with event: NSEvent) {
        if let m = menu(for: event) {
            willOpenMenu(m, with: event)
            NSMenu.popUpContextMenu(m, with: event, for: self)
            didCloseMenu(m, with: event)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        for s in subviews where !s.isHidden { if s.performKeyEquivalent(with: event) { return true } }
        return false
    }

    // MARK: Display

    open var needsDisplay: Bool {
        get { _needsDisplay }
        set {
            if newValue, !_needsDisplay { ViewSystem.needsDisplay(self) }
            _needsDisplay = newValue
        }
    }
    var _needsDisplay = false
    open func setNeedsDisplay(_ invalidRect: NSRect) { needsDisplay = true }
    open func display() { needsDisplay = false; render(); ViewSystem.flushPlacement() }
    open func displayIfNeeded() {
        if _needsDisplay { needsDisplay = false; render() }
        for s in subviews { s.displayIfNeeded() }
    }
    open func displayIfNeededIgnoringOpacity() { displayIfNeeded() }
    open func display(_ rect: NSRect) { display() }
    open func displayIfNeeded(in rect: NSRect) { displayIfNeeded() }
    open func viewWillDraw() {}
    open var wantsUpdateLayer: Bool { false }
    open func updateLayer() {}
    open func lockFocus() {}
    open func unlockFocus() {}
    open func lockFocusIfCanDraw() -> Bool { true }
    open func getRectsBeingDrawn(_ rects: UnsafeMutablePointer<UnsafePointer<NSRect>>?, count: UnsafeMutablePointer<Int>?) { count?.pointee = 0 }
    open func needsToDraw(_ rect: NSRect) -> Bool { true }
    open func setKeyboardFocusRingNeedsDisplay(_ rect: NSRect) { needsDisplay = true }
    open func drawFocusRingMask() {}
    open var focusRingMaskBounds: NSRect { bounds }
    open func noteFocusRingMaskChanged() {}

    /// Draws the view's content in its own coordinates. The default draws
    /// nothing; NSGraphicsContext.current is set up for it.
    open func draw(_ dirtyRect: NSRect) {}

    /// The transform from this view's coordinates to its canvas widget's
    /// (top-left, y-down, in points).
    var deviceTransform: CGAffineTransform {
        let sx = _bounds.width != 0 ? _frame.width / _bounds.width : 1
        let sy = _bounds.height != 0 ? _frame.height / _bounds.height : 1
        if isFlipped {
            return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: -_bounds.minX * sx, ty: -_bounds.minY * sy)
        }
        return CGAffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: -_bounds.minX * sx, ty: _frame.height + _bounds.minY * sy)
    }

    /// Records what `draw(_:)` (and the layer's simple properties) draw.
    /// Whether the view is drawing (recordDrawing) now.
    var isRecordingDrawing = false
    open func recordDrawing() -> CGDisplayList {
        let ctx = CGContext(recordingSize: _frame.size, baseTransform: deviceTransform)
        let gc = NSGraphicsContext(cgContext: ctx, flipped: isFlipped)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = gc
        let appearance = NSAppearance.current
        NSAppearance.current = effectiveAppearance
        let wasRecording = isRecordingDrawing
        isRecordingDrawing = true
        defer {
            NSGraphicsContext.current = previous
            NSAppearance.current = appearance
            isRecordingDrawing = wasRecording
        }
        if wantsLayer, let layer { layer.drawBackground(in: ctx, bounds: bounds, flipped: isFlipped) }
        viewWillDraw()
        if wantsUpdateLayer, wantsLayer { updateLayer(); layer?.drawBackground(in: ctx, bounds: bounds, flipped: isFlipped) } else { draw(bounds) }
        // Layers added to the backing layer (an AVPlayerLayer, shape and
        // gradient layers) draw over the view's own drawing, under its
        // subviews. Their space is the view's (AppKit flips a flipped view's
        // layer geometry), so the backing layer takes the view's bounds,
        // which also autoresizes them.
        if wantsLayer, let layer, layer.sublayers?.isEmpty == false {
            if layer.bounds != bounds { layer.bounds = bounds }
            layer.renderSublayers(in: ctx, flipped: isFlipped)
        }
        if wantsLayer, let layer { layer.drawBorder(in: ctx, bounds: bounds, flipped: isFlipped) }
        return ctx.displayList
    }

    /// Redraws into the canvas widget if the drawing changed.
    func render() {
        let list = recordDrawing()
        guard list != lastDrawing else { return }
        lastDrawing = list
        let backend = Runway.backend
        if drawingWidget == nil {
            guard !list.isEmpty else { return }
            drawingWidget = backend.makeWidget(.canvas)
            setNeedsPlacement()
        }
        var p = WidgetProps()
        p.drawing = list.isEmpty ? [] : [.displayList(list)]
        backend.update(drawingWidget!, props: p, events: WidgetEvents())
    }

    /// Core Animation's layer, kept to what views use for simple styling
    /// (background, border, corner radius, opacity).
    open var layer: CALayer? {
        get {
            if _layer == nil, wantsLayer { _layer = makeBackingLayer(); host(_layer) }
            return _layer
        }
        set { _layer = newValue; host(newValue); needsDisplay = true }
    }
    private var _layer: CALayer?
    /// Follows the backing layer: opacity and masking onto the view, any change a redraw.
    private func host(_ l: CALayer?) {
        l?.hostObserver = { [weak self] key in
            MainActor.assumeIsolated {
                guard let self, let l = self._layer else { return }
                switch key {
                case "opacity": self.alphaValue = CGFloat(l.opacity)
                case "masksToBounds": self.clipsToBounds = l.masksToBounds
                // Layer changes made while the view draws (updateLayer())
                // are in that drawing already.
                default: if !self.isRecordingDrawing { self.needsDisplay = true }
                }
            }
        }
    }
    open func makeBackingLayer() -> CALayer { CALayer() }

    // MARK: Placement (native widgets)

    var placementDirty = false
    func setNeedsPlacement() {
        guard !placementDirty else { return }
        placementDirty = true
        ViewSystem.needsPlacement(self)
    }

    /// A subview's rect in this view's container widget (top-left, points).
    func widgetRect(of v: NSView) -> CGRect {
        let f = v._frame
        let sx = _bounds.width != 0 ? _frame.width / _bounds.width : 1
        let sy = _bounds.height != 0 ? _frame.height / _bounds.height : 1
        let x = (f.minX - _bounds.minX) * sx
        let y = isFlipped ? (f.minY - _bounds.minY) * sy : _frame.height - (f.maxY - _bounds.minY) * sy
        return CGRect(x: x.rounded(), y: y.rounded(), width: (f.width * sx).rounded(), height: (f.height * sy).rounded())
    }

    /// Puts the drawing canvas and visible subviews' widgets in place.
    func place() {
        placementDirty = false
        guard !managesOwnContent else { return }
        var children: [(NativeWidget, CGRect)] = []
        children.reserveCapacity(subviews.count + 1)
        if let d = drawingWidget { children.append((d, CGRect(origin: .zero, size: _frame.size))) }
        for s in subviews where !s.isHidden { children.append((s.widget, widgetRect(of: s))) }
        Runway.backend.setChildren(widget, children, contentSize: _frame.size)
    }

    /// Runway: places this view's subviews now (layout first).
    func layoutSubviews() { place() }

    func updateWidgetProps() {
        var p = WidgetProps()
        p.tooltip = activeToolTip ?? toolTip
        p.opacity = Double(alphaValue)
        p.clips = clipsToBounds
        Runway.backend.update(widget, props: p, events: WidgetEvents())
    }

    // MARK: Appearance

    open var appearance: NSAppearance? { didSet { appearanceMayHaveChanged() } }
    open var effectiveAppearance: NSAppearance {
        appearance ?? superview?.effectiveAppearance ?? window?.effectiveAppearance ?? NSApplication.shared.effectiveAppearance
    }
    private var lastAppearanceName: NSAppearance.Name?
    open func viewDidChangeEffectiveAppearance() {}
    func appearanceMayHaveChanged() {
        let name = effectiveAppearance.name
        if name != lastAppearanceName {
            let first = lastAppearanceName == nil
            lastAppearanceName = name
            needsDisplay = true
            if !first { viewDidChangeEffectiveAppearance() }
        }
        for s in subviews { s.appearanceMayHaveChanged() }
    }

    // MARK: Tracking areas and cursor rects

    open private(set) var trackingAreas: [NSTrackingArea] = []
    open func addTrackingArea(_ area: NSTrackingArea) {
        trackingAreas.append(area)
        area.view = self
        ViewSystem.trackingChanged(self)
    }
    open func removeTrackingArea(_ area: NSTrackingArea) {
        trackingAreas.removeAll { $0 === area }
        ViewSystem.trackingChanged(self)
    }
    /// Called when the view's geometry changes: rebuild tracking areas here.
    open func updateTrackingAreas() {}

    var cursorRects: [(NSRect, NSCursor)] = []
    open func resetCursorRects() {}
    open func addCursorRect(_ rect: NSRect, cursor: NSCursor) { cursorRects.append((rect, cursor)) }
    open func removeCursorRect(_ rect: NSRect, cursor: NSCursor) { cursorRects.removeAll { $0.0 == rect && $0.1 === cursor } }
    open func discardCursorRects() { cursorRects.removeAll() }
    // MARK: Accessibility (NSAccessibility)

    var accessibility = AccessibilityAttributes()
    open func isAccessibilityElement() -> Bool { accessibility.element ?? false }
    open func setAccessibilityElement(_ flag: Bool) { accessibility.element = flag }
    open func accessibilityLabel() -> String? { accessibility.label }
    open func setAccessibilityLabel(_ label: String?) { accessibility.label = label }
    open func accessibilityTitle() -> String? { accessibility.title }
    open func setAccessibilityTitle(_ title: String?) { accessibility.title = title }
    open func accessibilityHelp() -> String? { accessibility.help ?? toolTip }
    open func setAccessibilityHelp(_ help: String?) { accessibility.help = help }
    open func accessibilityPlaceholderValue() -> String? { accessibility.placeholderValue }
    open func setAccessibilityPlaceholderValue(_ value: String?) { accessibility.placeholderValue = value }
    open func accessibilityIdentifier() -> String { accessibility.identifier ?? identifier?.rawValue ?? "" }
    open func setAccessibilityIdentifier(_ identifier: String?) { accessibility.identifier = identifier }
    open func accessibilityRole() -> NSAccessibility.Role? { accessibility.role ?? .group }
    open func setAccessibilityRole(_ role: NSAccessibility.Role?) { accessibility.role = role }
    open func accessibilitySubrole() -> NSAccessibility.Subrole? { accessibility.subrole }
    open func setAccessibilitySubrole(_ subrole: NSAccessibility.Subrole?) { accessibility.subrole = subrole }
    open func accessibilityRoleDescription() -> String? { accessibility.roleDescription }
    open func setAccessibilityRoleDescription(_ description: String?) { accessibility.roleDescription = description }
    open func accessibilityValue() -> Any? { accessibility.value }
    open func setAccessibilityValue(_ value: Any?) { accessibility.value = value }
    open func isAccessibilityHidden() -> Bool { accessibility.hidden }
    open func setAccessibilityHidden(_ hidden: Bool) { accessibility.hidden = hidden }
    open func isAccessibilityEnabled() -> Bool { accessibility.enabled }
    open func setAccessibilityEnabled(_ enabled: Bool) { accessibility.enabled = enabled }
    open func isAccessibilitySelected() -> Bool { accessibility.selected }
    open func setAccessibilitySelected(_ selected: Bool) { accessibility.selected = selected }
    open func isAccessibilityFocused() -> Bool { accessibility.focused }
    open func setAccessibilityFocused(_ focused: Bool) { accessibility.focused = focused }
    open func accessibilityChildren() -> [Any]? { accessibility.children ?? subviews }
    open func setAccessibilityChildren(_ children: [Any]?) { accessibility.children = children }
    open func accessibilityParent() -> Any? { accessibility.parent ?? superview ?? window }
    open func setAccessibilityParent(_ parent: Any?) { accessibility.parent = parent as AnyObject? }
    open func accessibilityFrame() -> NSRect { window.map { $0.convertToScreen(convert(bounds, to: nil)) } ?? frame }
    // Actions assistive technology performs; a view that handles one returns true.
    open func accessibilityPerformPress() -> Bool { false }
    open func accessibilityPerformCancel() -> Bool { false }
    open func accessibilityPerformConfirm() -> Bool { false }
    open func accessibilityPerformDecrement() -> Bool { false }
    open func accessibilityPerformIncrement() -> Bool { false }
    open func accessibilityPerformPick() -> Bool { false }
    open func accessibilityPerformRaise() -> Bool { false }
    open func accessibilityPerformShowMenu() -> Bool { false }
    open func accessibilityPerformDelete() -> Bool { false }

    // MARK: Tool tips

    public typealias ToolTipTag = Int
    struct ToolTipRect {
        let tag: ToolTipTag
        let rect: NSRect
        let owner: AnyObject?
        let string: String?
        let userData: UnsafeMutableRawPointer?
    }
    var toolTipRects: [ToolTipRect] = []
    nonisolated(unsafe) private static var nextToolTipTag = 0
    /// The tool tip shown while the pointer is over one of the view's tool
    /// tip rectangles (it takes the place of `toolTip`).
    var activeToolTip: String? {
        didSet { if activeToolTip != oldValue { updateWidgetProps() } }
    }

    /// A rectangle whose tool tip comes from `owner`: a string, or an object
    /// answering `view(_:stringForToolTip:point:userData:)` (NSViewToolTipOwner),
    /// asked each time the pointer moves in the rectangle.
    @discardableResult open func addToolTip(_ rect: NSRect, owner: Any, userData data: UnsafeMutableRawPointer?) -> ToolTipTag {
        Self.nextToolTipTag += 1
        let tag = Self.nextToolTipTag
        let string = owner as? String ?? (owner as? NSString).map { $0 as String }
        toolTipRects.append(ToolTipRect(tag: tag, rect: rect, owner: string == nil ? owner as AnyObject : nil, string: string, userData: data))
        return tag
    }
    open func removeToolTip(_ tag: ToolTipTag) {
        toolTipRects.removeAll { $0.tag == tag }
        if toolTipRects.isEmpty { activeToolTip = nil }
    }
    open func removeAllToolTips() {
        toolTipRects.removeAll()
        activeToolTip = nil
    }

    /// The tool tip for `point` (the view's coordinates) from its tool tip
    /// rectangles: nil when no rectangle contains it.
    func toolTip(at point: NSPoint) -> String?? {
        guard let r = toolTipRects.last(where: { $0.rect.contains(point) }) else { return nil }
        if let s = r.string { return .some(s) }
        if let owner = r.owner as? NSViewToolTipOwner {
            return .some(owner.view(self, stringForToolTip: r.tag, point: point, userData: r.userData))
        }
        return .some(nil)
    }

    // MARK: Drag and drop (destination)

    open private(set) var registeredDraggedTypes: [NSPasteboard.PasteboardType] = []
    open func registerForDraggedTypes(_ types: [NSPasteboard.PasteboardType]) {
        for t in types where !registeredDraggedTypes.contains(t) { registeredDraggedTypes.append(t) }
        window?.dropTargetsChanged()
    }
    open func unregisterDraggedTypes() { registeredDraggedTypes = [] }

    open func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    open func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    open func draggingExited(_ sender: NSDraggingInfo?) {}
    open func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    open func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    open func concludeDragOperation(_ sender: NSDraggingInfo?) {}
    open func draggingEnded(_ sender: NSDraggingInfo) {}
    open func wantsPeriodicDraggingUpdates() -> Bool { true }
    open func updateDraggingItemsForDrag(_ sender: NSDraggingInfo?) {}

    /// Starting a drag from this view: not supported off the Mac yet; the
    /// session is returned so code compiles and the drag simply doesn't start.
    open func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: NSDraggingSource) -> NSDraggingSession {
        NSDraggingSession()
    }

    // MARK: Auto Layout (overridable parts; the rest is in Layout.swift)

    /// The natural size of the content (`noIntrinsicMetric` per axis for none).
    open var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    open var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    open var firstBaselineOffsetFromTop: CGFloat { 0 }
    open var lastBaselineOffsetFromBottom: CGFloat { 0 }
    open var baselineOffsetFromBottom: CGFloat { lastBaselineOffsetFromBottom }
    open class var requiresConstraintBasedLayout: Bool { false }
    /// The smallest size satisfying the constraints in this view's subtree.
    open var fittingSize: NSSize { computeFittingSize() }

    open var needsLayout: Bool {
        get { _needsLayout }
        set {
            _needsLayout = newValue
            if newValue { ViewSystem.needsLayout(root: layoutRoot) }
        }
    }
    open var needsUpdateConstraints: Bool {
        get { _needsUpdateConstraints }
        set {
            _needsUpdateConstraints = newValue
            if newValue { needsLayout = true }
        }
    }
    /// Override to add or change constraints; call super at the end.
    open func updateConstraints() { _needsUpdateConstraints = false }
    /// Positions subviews. The default applies Auto Layout's solution to
    /// subviews that don't translate their autoresizing masks.
    open func layout() { applyEngineFrames() }

    // MARK: Layout state (see Layout.swift)

    var _constraints: [NSLayoutConstraint] = []
    var _layoutGuides: [NSLayoutGuide] = []
    var _needsLayout = false
    var _needsUpdateConstraints = true
    var engine: LayoutEngine?
    var hugging: (h: NSLayoutConstraint.Priority, v: NSLayoutConstraint.Priority) = (.defaultLow, .defaultLow)
    var compression: (h: NSLayoutConstraint.Priority, v: NSLayoutConstraint.Priority) = (.defaultHigh, .defaultHigh)
    lazy var layoutItem = LayoutItem(view: self)
    var _additionalSafeAreaInsets = NSEdgeInsets()
    /// The safe area's insets changed (scroll views inset their content).
    func safeAreaInsetsDidChange() {}
}

public enum NSFocusRingType: UInt, Sendable { case `default`, none, exterior }

// MARK: Layers
// Layers are QuartzCore's CALayer (re-exported): a view hosting one keeps
// its opacity and masking in sync and redraws when the layer tree changes.

// MARK: The deferred passes

/// Coalesces placement, layout and display, and runs them once per turn of
/// the main loop (or right after an event).
@MainActor enum ViewSystem {
    private static var placement: [NSView] = []
    private static var display: [NSView] = []
    private static var layoutRoots: [NSView] = []
    private static var geometry: [NSView] = []
    private static var scheduled = false
    static var flushing = false

    static func schedule() {
        guard !scheduled else { return }
        scheduled = true
        Runway.backend.schedule { flush() }
    }
    static func needsPlacement(_ v: NSView) { placement.append(v); schedule() }
    static func needsDisplay(_ v: NSView) { display.append(v); schedule() }
    static func needsLayout(root v: NSView) {
        if !layoutRoots.contains(where: { $0 === v }) { layoutRoots.append(v) }
        schedule()
    }
    static func geometryChanged(_ v: NSView) {
        guard v.window != nil else { return }
        geometry.append(v)
        schedule()
    }
    static func trackingChanged(_ v: NSView) { v.window?.trackingDirty = true }

    /// Layout, then display, then placement; repeated while passes dirty
    /// more (bounded).
    static func flush() {
        scheduled = false
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        for _ in 0..<8 {
            if layoutRoots.isEmpty, display.isEmpty, placement.isEmpty, geometry.isEmpty { break }
            let roots = layoutRoots
            layoutRoots.removeAll()
            for r in roots { r.layoutSubtreeIfNeeded() }
            let views = display
            display.removeAll()
            for v in views where v._needsDisplay {
                v._needsDisplay = false
                v.render()
            }
            flushPlacement()
            let changed = geometry
            geometry.removeAll()
            var seen = Set<ObjectIdentifier>()
            for v in changed where seen.insert(ObjectIdentifier(v)).inserted {
                v.updateTrackingAreas()
                v.window?.trackingDirty = true
                v.window?.invalidateCursorRects(for: v)
            }
        }
        scheduled = false
    }

    static func flushPlacement() {
        guard !placement.isEmpty else { return }
        let views = placement
        placement.removeAll()
        for v in views where v.placementDirty { v.place() }
    }
}

/// An object that supplies the strings for a view's tool tip rectangles
/// (`NSView.addToolTip(_:owner:userData:)`).
@preconcurrency @MainActor public protocol NSViewToolTipOwner: AnyObject {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String
}
