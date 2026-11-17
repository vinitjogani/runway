// NSScrollView on the platform's scrolled window (GtkScrolledWindow with
// overlay scrollbars, as macOS shows them): the document view sits in the
// scrolled window's document; the clip view's bounds origin is the scroll
// position, both ways. A table's header view stays pinned above.

import Foundation
import CoreGraphics
import RunwayCore

public enum NSBorderType: UInt, Sendable { case noBorder = 0, lineBorder, bezelBorder, grooveBorder }

@preconcurrency @MainActor
open class NSScroller: NSControl {
    public enum Style: Int, Sendable { case legacy = 0, overlay = 1 }
    public enum KnobStyle: Int, Sendable { case `default` = 0, dark, light }
    open var knobProportion: CGFloat = 1
    open var scrollerStyle: Style = .overlay
    open var knobStyle: KnobStyle = .default
    public static var preferredScrollerStyle: Style { .overlay }
    public static func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: Style) -> CGFloat { scrollerStyle == .overlay ? 0 : 15 }
}

/// The scroll view's visible area; its bounds origin is the scroll position.
@preconcurrency @MainActor
open class NSClipView: NSView {
    open var documentView: NSView? {
        didSet {
            guard documentView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let d = documentView { addSubview(d) }
            (superview as? NSScrollView)?.documentChanged()
        }
    }
    open var drawsBackground = true
    open var backgroundColor: NSColor = .controlBackgroundColor
    open var copiesOnScroll = true
    open var automaticallyAdjustsContentInsets = true
    open var contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    /// The scroll position: the clip view's bounds origin.
    var origin: CGPoint {
        get { bounds.origin }
        set { super.setBoundsOrigin(newValue) }
    }

    public override init(frame frameRect: CGRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }

    open override var isFlipped: Bool { true }

    /// The visible part of the document.
    open var documentRect: CGRect { documentView?.frame ?? .zero }
    open var documentVisibleRect: CGRect { CGRect(origin: origin, size: frame.size) }
    /// The clip view's bounds: its size, at the scroll position.
    open var clipBounds: CGRect { CGRect(origin: origin, size: frame.size) }

    open func scroll(to p: CGPoint) {
        let c = constrainBoundsRect(CGRect(origin: p, size: frame.size)).origin
        guard let sv = superview as? NSScrollView else { origin = c; return }
        sv.setScrollPosition(c, fromUser: false)
    }
    open func constrainBoundsRect(_ r: CGRect) -> CGRect {
        let doc = documentRect.size
        var o = r.origin
        o.x = max(0, min(o.x, doc.width - r.width))
        o.y = max(0, min(o.y, doc.height - r.height))
        return CGRect(origin: o, size: r.size)
    }
    open override func setBoundsOrigin(_ p: NSPoint) { scroll(to: p) }
    open func viewFrameChanged(_ n: Notification) {}

    open override func frameSizeChanged(from old: CGSize) {
        super.frameSizeChanged(from: old)
        (documentView as? NSTextView)?.sizeToFitText()
        (documentView as? VisibleRectObserving)?.visibleRectDidChange()
    }

    /// The document goes in the scroll view's native document, not here.
    override func place() {
        placementDirty = false
        guard let sv = superview as? NSScrollView, let d = documentView else { return }
        Runway.backend.setChildren(sv.documentContainer, [(d.widget, CGRect(origin: .zero, size: d.frame.size))], contentSize: d.frame.size)
        sv.documentFrameChanged()
    }
}

/// Views told when their visible part changes (tables, outline views,
/// collection views), to show only the rows in view.
@MainActor protocol VisibleRectObserving: AnyObject {
    func visibleRectDidChange()
}

@preconcurrency @MainActor
open class NSScrollView: NSView {
    open override var isFlipped: Bool { true }
    public static let willStartLiveScrollNotification = Notification.Name("NSScrollViewWillStartLiveScrollNotification")
    public static let didLiveScrollNotification = Notification.Name("NSScrollViewDidLiveScrollNotification")
    public static let didEndLiveScrollNotification = Notification.Name("NSScrollViewDidEndLiveScrollNotification")
    public static let willStartLiveMagnifyNotification = Notification.Name("NSScrollViewWillStartLiveMagnifyNotification")
    public static let didEndLiveMagnifyNotification = Notification.Name("NSScrollViewDidEndLiveMagnifyNotification")

    public enum Elasticity: Int, Sendable { case automatic = 0, none, allowed }
    public enum FindBarPosition: Int, Sendable { case aboveHorizontalRuler = 0, aboveContent, belowContent }

    let native: NativeWidget
    let documentContainer: NativeWidget
    open var contentView: NSClipView {
        didSet {
            oldValue.removeFromSuperview()
            addSubview(contentView)
            tile()
        }
    }
    open var hasVerticalScroller = false { didSet { updateScrollers() } }
    open var hasHorizontalScroller = false { didSet { updateScrollers() } }
    open var autohidesScrollers = false { didSet { updateScrollers() } }
    open var borderType: NSBorderType = .noBorder { didSet { updateScrollers() } }
    open var scrollerStyle: NSScroller.Style = .overlay
    open var scrollerKnobStyle: NSScroller.KnobStyle = .default
    open var drawsBackground = true { didSet { contentView.drawsBackground = drawsBackground } }
    open var backgroundColor: NSColor {
        get { contentView.backgroundColor }
        set { contentView.backgroundColor = newValue }
    }
    open var automaticallyAdjustsContentInsets = true { didSet { tile() } }
    open var contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) { didSet { tile() } }
    /// The insets in effect: the safe area's (what a toolbar band covers of
    /// full-size content) when automatic, as on the Mac.
    var effectiveContentInsets: NSEdgeInsets {
        guard automaticallyAdjustsContentInsets else { return contentInsets }
        SafeArea.track(self)
        return safeAreaInsets
    }
    override func safeAreaInsetsDidChange() { if automaticallyAdjustsContentInsets { tile() } }
    open var scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    open var verticalScrollElasticity: Elasticity = .automatic
    open var horizontalScrollElasticity: Elasticity = .automatic
    open var usesPredominantAxisScrolling = true
    open var allowsMagnification = false
    open var magnification: CGFloat = 1
    open var minMagnification: CGFloat = 0.25
    open var maxMagnification: CGFloat = 4
    open var verticalLineScroll: CGFloat = 10
    open var horizontalLineScroll: CGFloat = 10
    open var lineScroll: CGFloat = 10
    open var verticalPageScroll: CGFloat = 10
    open var horizontalPageScroll: CGFloat = 10
    open var pageScroll: CGFloat = 10
    open var scrollsDynamically = true
    open var findBarPosition: FindBarPosition = .aboveContent
    open var rulersVisible = false
    open var hasVerticalRuler = false
    open var hasHorizontalRuler = false
    open var verticalScroller: NSScroller? = NSScroller(frame: .zero)
    open var horizontalScroller: NSScroller? = NSScroller(frame: .zero)
    private var liveScrolling = false

    public override init(frame frameRect: CGRect) {
        let made: (NativeWidget, NativeWidget) = MainActor.assumeIsolated {
            let s = Runway.backend.makeWidget(.scroll(horizontal: true, vertical: true))
            return (s, Runway.backend.childContainer(s))
        }
        native = made.0
        documentContainer = made.1
        contentView = NSClipView(frame: CGRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        onMain {
            addSubview(contentView)
            updateScrollers()
            Runway.appKit?.observeScroll(native) { [weak self] p in self?.setScrollPosition(p, fromUser: true) }
            tile()
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        let frameRect = IBDecoding.frame(coder)
        let made: (NativeWidget, NativeWidget) = MainActor.assumeIsolated {
            let s = Runway.backend.makeWidget(.scroll(horizontal: true, vertical: true))
            return (s, Runway.backend.childContainer(s))
        }
        native = made.0
        documentContainer = made.1
        contentView = NSClipView(frame: CGRect(origin: .zero, size: frameRect.size))
        super.init(coder: coder)
        onMain {
            addSubview(contentView)
            updateScrollers()
            Runway.appKit?.observeScroll(native) { [weak self] p in self?.setScrollPosition(p, fromUser: true) }
            tile()
        }
        IBDecoding.leave(self, coder)
    }

    open var documentView: NSView? {
        get { contentView.documentView }
        set { contentView.documentView = newValue }
    }

    /// The area the clip view fills: below a table's header, inside the insets.
    open var contentSize: CGSize { contentView.frame.size }
    open var documentVisibleRect: CGRect { contentView.documentVisibleRect }
    public static func contentSize(forFrameSize f: CGSize, horizontalScrollerClass: AnyClass?, verticalScrollerClass: AnyClass?, borderType: NSBorderType, controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGSize {
        let b: CGFloat = borderType == .noBorder ? 0 : 2
        return CGSize(width: f.width - b, height: f.height - b)
    }
    public static func frameSize(forContentSize c: CGSize, horizontalScrollerClass: AnyClass?, verticalScrollerClass: AnyClass?, borderType: NSBorderType, controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGSize {
        let b: CGFloat = borderType == .noBorder ? 0 : 2
        return CGSize(width: c.width + b, height: c.height + b)
    }

    /// The header view a table document brings (pinned above the rows).
    var headerView: NSView? { (documentView as? NSTableView)?.headerView }
    var headerHeight: CGFloat {
        guard let h = headerView, !h.isHidden else { return 0 }
        return h.frame.height > 0 ? h.frame.height : 28
    }

    private func updateScrollers() {
        Runway.appKit?.setScrollers(native, horizontal: hasHorizontalScroller, vertical: hasVerticalScroller,
                                    autohides: autohidesScrollers, bordered: borderType != .noBorder)
    }

    // MARK: Layout

    open func tile() {
        let ins = effectiveContentInsets
        let top = ins.top + headerHeight
        let r = CGRect(x: ins.left, y: top, width: max(0, bounds.width - ins.left - ins.right), height: max(0, bounds.height - top - ins.bottom))
        if contentView.frame != r { contentView.frame = r }
        if let h = headerView {
            if h.superview !== self { addSubview(h) }
            let hf = CGRect(x: ins.left, y: ins.top, width: r.width, height: headerHeight)
            if h.frame != hf { h.frame = hf }
        }
        layoutSubviews()
    }

    func documentChanged() {
        if let h = headerView, h.superview !== self { addSubview(h) }
        tile()
        contentView.layoutSubviews()
        (documentView as? VisibleRectObserving)?.visibleRectDidChange()
    }

    func documentFrameChanged() {
        // Keep the position in range as the document shrinks.
        let c = contentView.constrainBoundsRect(contentView.clipBounds).origin
        if c != contentView.origin { setScrollPosition(c, fromUser: false) }
    }

    override func place() {
        placementDirty = false
        let ins = effectiveContentInsets
        let scrollRect = CGRect(x: ins.left, y: ins.top + headerHeight, width: contentView.frame.width, height: contentView.frame.height)
        var above: [(NativeWidget, CGRect)] = []
        for v in subviews where v !== contentView && !v.isHidden && !(v is NSScroller) { above.append((v.widget, v.frame)) }
        Runway.backend.setChildren(widget, [(native, scrollRect)] + above, contentSize: frame.size)
    }

    open override func frameSizeChanged(from old: CGSize) {
        super.frameSizeChanged(from: old)
        tile()
    }

    // MARK: Scrolling

    /// The scroll position changed (the user, or `scroll(to:)`).
    func setScrollPosition(_ p: CGPoint, fromUser: Bool) {
        guard p != contentView.origin else {
            if !fromUser { Runway.appKit?.setScrollOffset(native, p) }
            return
        }
        contentView.origin = p
        if !fromUser { Runway.appKit?.setScrollOffset(native, p) }
        if let h = headerView as? NSTableHeaderView { h.scrollOffsetX = p.x }
        // The clip view posts NSViewBoundsDidChangeNotification as its bounds move.
        if fromUser {
            if !liveScrolling {
                liveScrolling = true
                NotificationCenter.default.post(name: Self.willStartLiveScrollNotification, object: self)
                Runway.backend.schedule { [weak self] in
                    guard let self else { return }
                    self.liveScrolling = false
                    NotificationCenter.default.post(name: Self.didEndLiveScrollNotification, object: self)
                }
            }
            NotificationCenter.default.post(name: Self.didLiveScrollNotification, object: self)
        }
        (documentView as? VisibleRectObserving)?.visibleRectDidChange()
    }

    open func reflectScrolledClipView(_ clip: NSClipView) { Runway.appKit?.setScrollOffset(native, clip.origin) }
    open func flashScrollers() {}
    open func magnify(toFit rect: CGRect) {}
    open func setMagnification(_ m: CGFloat, centeredAt p: CGPoint) { magnification = m }
    open override func scrollToBeginningOfDocument(_ sender: Any?) { contentView.scroll(to: .zero) }
    open override func scrollToEndOfDocument(_ sender: Any?) {
        contentView.scroll(to: CGPoint(x: 0, y: max(0, (documentView?.frame.height ?? 0) - contentView.frame.height)))
    }
    open func addFloatingSubview(_ v: NSView, for axis: Int) { addSubview(v) }
}

extension NSView {
    /// Scrolls the enclosing scroll view so `rect` (in this view) shows.
    @discardableResult
    public func scrollToVisible(_ rect: CGRect) -> Bool {
        guard let sv = enclosingScrollView, let doc = sv.documentView else { return false }
        let o = offset(in: doc)
        let r = rect.offsetBy(dx: o.x, dy: o.y)
        var p = sv.documentVisibleRect.origin
        let size = sv.documentVisibleRect.size
        if r.minY < p.y { p.y = r.minY } else if r.maxY > p.y + size.height { p.y = r.maxY - size.height }
        if r.minX < p.x { p.x = r.minX } else if r.maxX > p.x + size.width { p.x = r.maxX - size.width }
        guard p != sv.documentVisibleRect.origin else { return false }
        sv.contentView.scroll(to: p)
        return true
    }

    /// Scrolls the enclosing clip view to put `point` (in this view) at its origin.
    public func scroll(_ point: CGPoint) {
        guard let sv = enclosingScrollView, let doc = sv.documentView else { return }
        let o = offset(in: doc)
        sv.contentView.scroll(to: CGPoint(x: point.x + o.x, y: point.y + o.y))
    }
}
