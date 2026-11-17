// Shared plumbing for AppKit's controls and containers: native widgets
// placed beneath a view's subviews, deferred layout, colour and font
// conversion, and drawing helpers for the controls Runway draws itself.

import Foundation
import CoreGraphics
import RunwayCore

/// Makes a control's native widget (from its initializer).
@MainActor func makeNative(_ kind: WidgetKind) -> NativeWidget {
    AppKitControls.install()
    return Runway.backend.makeWidget(kind)
}

/// One-time hooks the view system calls into the controls through.
@MainActor enum AppKitControls {
    private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        CALayer._subclassFactory = { cls in ClassRegistry.factory(for: cls).flatMap { make in MainActor.assumeIsolated { make() } } }
        NSViewController._runwayPopoverPresenter = { vc, rect, view, edge, behavior in
            let p = NSPopover()
            p.contentViewController = vc
            p.behavior = NSPopover.Behavior(rawValue: behavior) ?? .transient
            p.show(relativeTo: rect, of: view, preferredEdge: edge)
        }
        registerActions()
    }

    /// The standard actions the controls answer (menu items and the
    /// responder chain send them by selector).
    private static func registerActions() {
        func reg<T: AnyObject>(_ name: String, _ type: T.Type, _ f: @escaping @MainActor (T, Any?) -> Any?) {
            registerSelector(Selector(name), for: type) { obj, args in
                MainActor.assumeIsolated { f(obj as! T, args.first ?? nil) }
            }
        }
        reg("copy:", NSTextView.self) { $0.copy($1); return nil }
        reg("cut:", NSTextView.self) { $0.cut($1); return nil }
        reg("paste:", NSTextView.self) { $0.paste($1); return nil }
        reg("selectAll:", NSTextView.self) { $0.selectAll($1); return nil }
        reg("delete:", NSTextView.self) { $0.delete($1); return nil }
        reg("selectAll:", NSTextField.self) { $0.selectText($1); return nil }
        reg("selectAll:", NSTableView.self) { $0.selectAll($1); return nil }
        reg("deselectAll:", NSTableView.self) { $0.deselectAll($1); return nil }
        reg("toggleSidebar:", NSSplitViewController.self) { $0.toggleSidebar($1); return nil }
        reg("toggleInspector:", NSSplitViewController.self) { $0.toggleInspector($1); return nil }
        reg("selectNextTabViewItem:", NSTabView.self) { $0.selectNextTabViewItem($1); return nil }
        reg("selectPreviousTabViewItem:", NSTabView.self) { $0.selectPreviousTabViewItem($1); return nil }
        reg("performClose:", NSPopover.self) { $0.performClose($1); return nil }
        reg("performClick:", NSControl.self) { $0.performClick($1); return nil }
    }
}

/// Runs set-up work from an initializer once every stored property is set.
@MainActor func onMain(_ work: @MainActor () -> Void) { work() }

/// Views whose layout is computed in `layout()`: a change asks for a pass
/// on the next turn of the loop, coalesced across views.
@MainActor enum LayoutQueue {
    private static var pending: [NSView] = []
    private static var scheduled = false

    static func setNeedsLayout(_ v: NSView) {
        if !pending.contains(where: { $0 === v }) { pending.append(v) }
        guard !scheduled else { return }
        scheduled = true
        Runway.backend.schedule { flush() }
    }

    /// Lays out everything pending, outermost first.
    static func flush() {
        scheduled = false
        var guardCount = 0
        while !pending.isEmpty, guardCount < 64 {
            let batch = pending.sorted { depth($0) < depth($1) }
            pending.removeAll()
            for v in batch { v.layout() }
            guardCount += 1
        }
    }

    static func depth(_ v: NSView) -> Int {
        var n = 0
        var p = v.superview
        while let q = p { n += 1; p = q.superview }
        return n
    }
}

/// Lays out a view tree now, top-down (tests; `layoutSubtreeIfNeeded`).
@preconcurrency @MainActor public func RunwayLayoutTree(_ v: NSView) {
    LayoutQueue.flush()
    v.layout()
    for s in v.subviews { RunwayLayoutTree(s) }
}

extension NSView {
    /// The window this view is in.
    var hostWindow: NSWindow? { window ?? superview?.hostWindow }

    /// Places native widgets (below and above the subviews) and the
    /// subviews in this view's container.
    func placeChildren(below: [(NativeWidget, CGRect)], above: [(NativeWidget, CGRect)] = []) {
        let subs = subviews.filter { !$0.isHidden }.map { ($0.widget, widgetRect(of: $0)) }
        Runway.backend.setChildren(widget, below + subs + above, contentSize: frame.size)
    }

    /// Whether `v` is this view or inside it.
    func contains(_ v: NSView) -> Bool {
        var p: NSView? = v
        while let q = p { if q === self { return true }; p = q.superview }
        return false
    }

    /// A point in this view converted to an ancestor's coordinates.
    func offset(in ancestor: NSView?) -> CGPoint {
        var p = CGPoint.zero
        var v: NSView? = self
        while let q = v, q !== ancestor {
            p.x += q.frame.minX; p.y += q.frame.minY
            v = q.superview
        }
        return p
    }
}

extension NSColor {
    /// The colour in the current appearance.
    var rgbaValue: RGBA { current }
}

extension NSFont {
    static var defaultControlFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }
}

extension NSControl.ControlSize {
    var value: ControlSizeValue {
        switch self {
        case .mini: .mini
        case .small: .small
        case .regular: .regular
        case .large: .large
        case .extraLarge: .extraLarge
        }
    }
    /// macOS's control heights.
    var height: CGFloat {
        switch self {
        case .mini: 16
        case .small: 19
        case .regular: 22
        case .large: 28
        case .extraLarge: 34
        }
    }
}

extension NSTextAlignment {
    var value: TextAlignmentValue {
        switch self {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
    }
}

/// Drawing for controls Runway draws itself (level indicators, table
/// selections, box borders): a canvas widget with a list of commands.
@MainActor final class DrawnLayer {
    let widget: NativeWidget
    init() { widget = Runway.backend.makeWidget(.canvas) }
    func draw(_ commands: [DrawCommand]) {
        var p = WidgetProps()
        p.drawing = commands
        Runway.backend.update(widget, props: p, events: WidgetEvents())
    }
}

/// A plain label widget (headers, titles, a box's caption).
@MainActor final class LabelWidget {
    let widget: NativeWidget
    private var last: StyledText?
    init() { widget = Runway.backend.makeWidget(.text) }
    func set(_ string: String, font: NSFont = .defaultControlFont, color: NSColor? = .labelColor, alignment: TextAlignmentValue = .leading, lines: Int? = 1) {
        let t = StyledText(runs: [TextRun(string: string, font: font.spec, color: color?.rgbaValue)], alignment: alignment, lineLimit: lines, truncation: .tail)
        guard t != last else { return }
        last = t
        var p = WidgetProps()
        p.text = t
        Runway.backend.update(widget, props: p, events: WidgetEvents())
    }
    func size(width: CGFloat? = nil) -> CGSize { Runway.backend.measure(widget, proposal: ProposedSize(width: width, height: nil)) }
}

/// The widget AppKit puts under views that take pointer and key events,
/// or a plain container where the backend has no events.
@MainActor func makeEventWidget(focusable: Bool, pointer: @escaping @MainActor (PointerEvent) -> Bool, key: @escaping @MainActor (KeyPress) -> Bool = { _ in false }) -> NativeWidget {
    // With AppKit's own event dispatch (the backend reports raw window
    // input), views get mouseDown(with:) and friends instead.
    if !(Runway.backend is ViewSystemBackend), let ak = Runway.appKit { return ak.makeEventContainer(focusable: focusable, pointer: pointer, key: key) }
    return Runway.backend.makeWidget(.container)
}

/// NSMenu as backend menu items (pop-up buttons, context menus, status items).
extension NSMenu {
    @MainActor func specs(sender: AnyObject? = nil) -> [MenuItemSpec] {
        items.filter { !$0.isHidden }.map { item in
            if item.isSeparatorItem { return .separator }
            return MenuItemSpec(title: item.title, enabled: item.isEnabled, checked: item.state == .on,
                                children: item.submenu?.specs(sender: sender) ?? []) { [weak item] in
                item?.perform()
            }
        }
    }
}


/// Runs `body` on the main thread and returns its result: at once when
/// called there, else synchronously through the main queue (for AppKit API
/// that's callable from any thread).
func onMainThread<T>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated(body) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}
