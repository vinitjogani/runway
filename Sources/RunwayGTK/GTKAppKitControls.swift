// GTK 4 for AppKit's controls: event containers (GtkGestureClick, GtkGestureDrag,
// motion, key and focus controllers on a RunwayCanvas), scrolled-window
// positions, entries' focus, keys and search icons, radio groups, window-wide
// key equivalents, rich text in a GtkTextView with tags, GtkPopover,
// pass-through canvases (a toolbar over full-size content), pop-up menus, and tray items over D-Bus.

#if os(Linux)
import Foundation
import CGtk
import CRunwayGtk
import CoreGraphics
import RunwayCore

/// Per-widget state for the AppKit extras, owned by the GTK widget
/// (released with it through g_object_set_data_full).
@MainActor final class AKState {
    var pointer: ((PointerEvent) -> Bool)?
    var key: ((KeyPress) -> Bool)?
    var focus: ((Bool) -> Void)?
    var textFocus: ((Bool) -> Void)?
    var textKey: ((KeyPress) -> Bool)?
    var scroll: ((CGPoint) -> Void)?
    var pendingOffset: CGPoint?
    var clickCount = 1
    var button = 0
    var dragStart = CGPoint.zero
    var pressed = false
    var keyEquivalent: KeyPress?
    weak var keyRoot: AnyObject?
    var keyRootWidget: GW?
    var keyController: OpaquePointer?
    var search = false
    // Text views.
    var textEvents = TextViewEvents()
    var textConfig = TextViewConfig()
    var runs: [RichTextRun] = []
    var tags: [RichTextRun: UnsafeMutablePointer<GtkTextTag>] = [:]
    var textLayers: (CGDisplayList?, CGDisplayList?) = (nil, nil)
    weak var box: GtkBox?
}

private let stateKey = "rw-appkit"
private let releaseState: @convention(c) (UnsafeMutableRawPointer?) -> Void = { p in
    guard let p else { return }
    Unmanaged<AKState>.fromOpaque(p).release()
}

@MainActor func akState(_ w: GW) -> AKState {
    if let p = g_object_get_data(UnsafeMutablePointer<GObject>(OpaquePointer(w)), stateKey) {
        return Unmanaged<AKState>.fromOpaque(p).takeUnretainedValue()
    }
    let s = AKState()
    g_object_set_data_full(UnsafeMutablePointer<GObject>(OpaquePointer(w)), stateKey, Unmanaged.passRetained(s).toOpaque(), releaseState)
    return s
}

@inline(__always) private func stateOf(_ data: UnsafeMutableRawPointer?) -> AKState? {
    guard let data else { return nil }
    return Unmanaged<AKState>.fromOpaque(data).takeUnretainedValue()
}

/// Signals carry the widget as their user data; its state is looked up on it.
private func connectState(_ instance: UnsafeMutableRawPointer, _ signal: String, _ cb: GCallback, _ w: GW, after: Bool = false) {
    _ = g_signal_connect_data(instance, signal, cb, UnsafeMutableRawPointer(w), nil, after ? G_CONNECT_AFTER : GConnectFlags(rawValue: 0))
}
@inline(__always) private func widgetState(_ data: UnsafeMutableRawPointer?) -> AKState? {
    guard let data else { return nil }
    let w = data.assumingMemoryBound(to: GtkWidget.self)
    return MainActor.assumeIsolated { akState(w) }
}

private func modifiers(_ state: UInt32) -> KeyModifiers {
    var m: KeyModifiers = []
    if state & GDK_CONTROL_MASK.rawValue != 0 { m.insert(.command) }
    if state & GDK_SHIFT_MASK.rawValue != 0 { m.insert(.shift) }
    if state & GDK_ALT_MASK.rawValue != 0 { m.insert(.option) }
    return m
}

private func currentModifiers(_ controller: UnsafeMutableRawPointer?) -> KeyModifiers {
    guard let controller else { return [] }
    return modifiers(gtk_event_controller_get_current_event_state(OpaquePointer(controller)).rawValue)
}

/// GDK key names as Runway's KeyPress names them.
func runwayKeyPress(_ keyval: guint, _ state: GdkModifierType) -> KeyPress? {
    guard let cname = gdk_keyval_name(gdk_keyval_to_lower(keyval)) else { return nil }
    var name = String(cString: cname).lowercased()
    switch name {
    case "return", "kp_enter", "iso_enter": name = "return"
    case "iso_left_tab": name = "tab"
    case "comma": name = ","
    case "period": name = "."
    case "slash": name = "/"
    case "kp_up": name = "up"
    case "kp_down": name = "down"
    case "kp_left": name = "left"
    case "kp_right": name = "right"
    case "page_up", "prior": name = "pageup"
    case "page_down", "next": name = "pagedown"
    default: break
    }
    let m = modifiers(state.rawValue)
    return KeyPress(key: name, command: m.contains(.command), shift: m.contains(.shift) || String(cString: cname) == "ISO_Left_Tab",
                    option: m.contains(.option), control: false)
}

// MARK: C callbacks

private let pressedCB: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { g, n, x, y, data in
    MainActor.assumeIsolated {
        guard let s = widgetState(data) else { return }
        s.clickCount = Int(n)
        // GTK numbers buttons 1 left, 2 middle, 3 right; events use 0
        // primary, 1 secondary, 2 middle.
        switch gtk_gesture_single_get_current_button(OpaquePointer(g)) {
        case 3: s.button = 1
        case 2: s.button = 2
        case let b where b > 3: s.button = Int(b) - 1
        default: s.button = 0
        }
        s.pressed = true
        s.dragStart = CGPoint(x: x, y: y)
        if let w = data?.assumingMemoryBound(to: GtkWidget.self), gtk_widget_get_focusable(w) != 0 { gtk_widget_grab_focus(w) }
        let e = PointerEvent(kind: .down, location: CGPoint(x: x, y: y), button: s.button, clickCount: s.clickCount, modifiers: currentModifiers(g))
        if s.pointer?(e) == true { gtk_gesture_set_state(OpaquePointer(g), GTK_EVENT_SEQUENCE_CLAIMED) }
    }
}
private let releasedCB: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { g, n, x, y, data in
    MainActor.assumeIsolated {
        guard let s = widgetState(data), s.pressed else { return }
        s.pressed = false
        _ = s.pointer?(PointerEvent(kind: .up, location: CGPoint(x: x, y: y), button: s.button, clickCount: Int(n), modifiers: currentModifiers(g)))
    }
}
private let dragUpdateCB: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { g, dx, dy, data in
    MainActor.assumeIsolated {
        guard let s = widgetState(data), s.pressed else { return }
        _ = s.pointer?(PointerEvent(kind: .dragged, location: CGPoint(x: s.dragStart.x + dx, y: s.dragStart.y + dy), button: s.button, modifiers: currentModifiers(g)))
    }
}
private let dragEndCB: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { g, dx, dy, data in
    MainActor.assumeIsolated {
        // A drag that moved past the click threshold ends here (the click
        // gesture is cancelled then and won't report the release).
        guard let s = widgetState(data), s.pressed else { return }
        s.pressed = false
        _ = s.pointer?(PointerEvent(kind: .up, location: CGPoint(x: s.dragStart.x + dx, y: s.dragStart.y + dy), button: s.button, clickCount: s.clickCount, modifiers: currentModifiers(g)))
    }
}
private let motionCB: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void = { g, x, y, data in
    MainActor.assumeIsolated {
        guard let s = widgetState(data), !s.pressed else { return }
        _ = s.pointer?(PointerEvent(kind: .moved, location: CGPoint(x: x, y: y), modifiers: currentModifiers(g)))
    }
}
private let leaveCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    MainActor.assumeIsolated { _ = widgetState(data)?.pointer?(PointerEvent(kind: .exited, location: .zero)) }
}
private let keyCB: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, data in
    MainActor.assumeIsolated {
        guard let s = widgetState(data), let k = runwayKeyPress(keyval, state) else { return 0 }
        if let tk = s.textKey { return tk(k) ? 1 : 0 }
        if let tv = s.textEvents.key { return tv(k) ? 1 : 0 }
        return s.key?(k) == true ? 1 : 0
    }
}
private let focusInCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        guard let s = widgetState(data) else { return }
        s.focus?(true); s.textFocus?(true); s.textEvents.focusChanged?(true)
    }
}
private let focusOutCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        guard let s = widgetState(data) else { return }
        s.focus?(false); s.textFocus?(false); s.textEvents.focusChanged?(false)
    }
}
private let adjustmentCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        guard let data else { return }
        let w = data.assumingMemoryBound(to: GtkWidget.self)
        let s = akState(w)
        if let p = s.pendingOffset { GTKBackend.applyOffset(w, p, s) ; return }
        guard !GTKBackend.settingOffset else { return }
        s.scroll?(GTKBackend.offset(of: w))
    }
}
private let adjustmentChangedCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        guard let data else { return }
        let w = data.assumingMemoryBound(to: GtkWidget.self)
        let s = akState(w)
        if let p = s.pendingOffset { GTKBackend.applyOffset(w, p, s) }
    }
}
private let entryChangedCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { e, data in
    MainActor.assumeIsolated {
        guard let e, let s = widgetState(data), s.search else { return }
        let empty = gtk_editable_get_text(OpaquePointer(e)).pointee == 0
        gtk_entry_set_icon_from_icon_name(e.assumingMemoryBound(to: GtkEntry.self), GTK_ENTRY_ICON_SECONDARY, empty ? nil : "edit-clear-symbolic")
    }
}
private let iconPressCB: @convention(c) (UnsafeMutableRawPointer?, GtkEntryIconPosition, UnsafeMutableRawPointer?) -> Void = { e, pos, _ in
    MainActor.assumeIsolated {
        guard let e, pos == GTK_ENTRY_ICON_SECONDARY else { return }
        gtk_editable_set_text(OpaquePointer(e), "")
    }
}
private let rootKeyCB: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, data in
    MainActor.assumeIsolated {
        guard let data, let k = runwayKeyPress(keyval, state) else { return 0 }
        let w = data.assumingMemoryBound(to: GtkWidget.self)
        let s = akState(w)
        guard let want = s.keyEquivalent, want.key == k.key, want.command == k.command, want.option == k.option,
              want.shift == k.shift || want.key == "return" || want.key == "escape" else { return 0 }
        guard gtk_widget_is_sensitive(w) != 0, gtk_widget_get_mapped(w) != 0 else { return 0 }
        _ = gtk_widget_activate(w)
        return 1
    }
}
private let rootChangedCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, _, data in
    MainActor.assumeIsolated {
        guard let data else { return }
        GTKBackend.attachKeyEquivalent(data.assumingMemoryBound(to: GtkWidget.self))
    }
}

// NSTextView's text view (runway_textview.c): its data is the GtkTextView.
private func textState(_ data: UnsafeMutableRawPointer?) -> AKState? {
    guard let data else { return nil }
    return MainActor.assumeIsolated { akState(data.assumingMemoryBound(to: GtkWidget.self)) }
}
private let textDrawCB: @convention(c) (Int32, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = { layer, cr, data in
    MainActor.assumeIsolated {
        guard let cr, let s = textState(data), let list = layer == 0 ? s.textLayers.0 : s.textLayers.1 else { return }
        AppKitCairo.replay(list, cr)
    }
}
private let textPointerCB: @convention(c) (Int32, Double, Double, Int32, UInt32, Double, UnsafeMutableRawPointer?) -> gboolean = { kind, x, y, button, mods, _, data in
    MainActor.assumeIsolated {
        guard let s = textState(data), let f = s.textEvents.pointer else { return 0 }
        var m: KeyModifiers = []
        if mods & 1 != 0 { m.insert(.shift) }
        if mods & 2 != 0 { m.insert(.command) }
        if mods & 4 != 0 { m.insert(.option) }
        if mods & 8 != 0 { m.insert(.control) }
        return f(PointerEvent(kind: kind == 0 ? .down : .up, location: CGPoint(x: x, y: y), button: Int(button), modifiers: m)) ? 1 : 0
    }
}
private let textInsertCB: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> gboolean = { text, data in
    MainActor.assumeIsolated {
        guard let text, let s = textState(data) else { return 0 }
        return s.textEvents.insertText?(String(cString: text)) == true ? 1 : 0
    }
}
private let textDeleteCB: @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> Void = { a, b, data in
    MainActor.assumeIsolated {
        guard let s = textState(data) else { return }
        s.textEvents.userSelection?(Int(a)..<Int(b), false)
        _ = s.textEvents.insertText?("")
    }
}
private let textSelectionCB: @convention(c) (Int32, Int32, gboolean, UnsafeMutableRawPointer?) -> Void = { a, b, dragging, data in
    MainActor.assumeIsolated {
        guard let s = textState(data) else { return }
        s.textEvents.userSelection?(Int(a)..<Int(b), dragging != 0)
        s.textEvents.selectionChanged?(Int(a)..<Int(b))
    }
}
private let textHeightCB: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { h, data in
    MainActor.assumeIsolated { textState(data)?.textEvents.heightChanged?(CGFloat(h)) }
}

private let popoverClosedCB: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { _, data in
    guard let data else { return }
    let p = Unmanaged<GTKPopover>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { p.closed() }
}
private let menuIndexCB: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { i, data in
    guard let data else { return }
    let m = Unmanaged<GTKMenuActions>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { m.run(Int(i)) }
}
private let statusCB: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { i, data in
    guard let data else { return }
    let s = Unmanaged<GTKStatusItem>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { s.fire(Int(i)) }
}
private let timeoutCB: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
    guard let data else { return }
    let b = Unmanaged<WorkBox>.fromOpaque(data).takeRetainedValue()
    MainActor.assumeIsolated { b.work() }
}

// MARK: Objects behind handles

@MainActor final class GTKPopover {
    let popover: GW
    let content: GtkBox
    let onClose: () -> Void
    var isOpen = true
    /// Points at the whole anchor, measured when it pops up.
    var pointsAtAnchor = false
    var keys: KeyHandlerBox?
    init(popover: GW, content: GtkBox, onClose: @escaping () -> Void) { self.popover = popover; self.content = content; self.onClose = onClose }
    func closed() {
        guard isOpen else { return }
        isOpen = false
        onClose()
        // Unparent once GTK has finished with the popover.
        let p = popover
        GTKBackend.current?.schedule {
            gtk_popover_set_child(typed(p), nil)
            gtk_widget_unparent(p)
        }
        GTKBackend.openPopovers.removeAll { $0 === self }
    }
}

@MainActor final class GTKMenuActions {
    var items: [MenuItemSpec]
    init(_ items: [MenuItemSpec]) { self.items = items }
    func run(_ i: Int) { if items.indices.contains(i) { items[i].action?() } }
}

@MainActor final class GTKStatusItem {
    var native: OpaquePointer?
    let menu: () -> [MenuItemSpec]
    let activate: () -> Void
    var flat: [MenuItemSpec] = []
    init(menu: @escaping () -> [MenuItemSpec], activate: @escaping () -> Void) { self.menu = menu; self.activate = activate }
    func fire(_ i: Int) {
        switch i {
        case -1: activate()
        case -2: refreshMenu()
        default: if flat.indices.contains(i) { flat[i].action?() }
        }
    }
    func refreshMenu() {
        var titles: [String] = [], kinds: [Int32] = [], enabled: [gboolean] = [], checked: [gboolean] = []
        flat = []
        func walk(_ list: [MenuItemSpec]) {
            for m in list {
                titles.append(m.title); enabled.append(m.enabled ? 1 : 0); checked.append(m.checked ? 1 : 0); flat.append(m)
                if m.isSeparator { kinds.append(1) }
                else if !m.children.isEmpty {
                    kinds.append(2)
                    walk(m.children)
                    titles.append(""); kinds.append(3); enabled.append(0); checked.append(0); flat.append(.separator)
                } else { kinds.append(0) }
            }
        }
        walk(menu())
        withCStringArray(titles) { t in
            runway_status_item_set_menu(native, t, kinds, enabled, checked, Int32(titles.count))
        }
    }
    deinit {}
}

func withCStringArray<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
    let dup = strings.map { strdup($0) }
    defer { dup.forEach { free($0) } }
    var ptrs: [UnsafePointer<CChar>?] = dup.map { UnsafePointer($0) }
    ptrs.append(nil)
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}

// MARK: The conformance

extension GTKBackend: AppKitBackend {
    public func beginWindowMove(_ window: NativeWindow, button: Int, at point: CGPoint, timestamp: TimeInterval) {
        guard let w = window as? GtkNativeWindow else { return }
        runway_appkit_begin_move(w.window, Int32(button + 1), Double(point.x), Double(point.y), UInt32(truncatingIfNeeded: Int64(timestamp * 1000)))
    }

    static var openPopovers: [GTKPopover] = []
    static var settingOffset = false
    private static var cssInstalled = false

    /// Bezel styles and AppKit-only looks, layered on the Mac stylesheet.
    static func installAppKitCSS() {
        guard !cssInstalled else { return }
        cssInstalled = true
        let p = gtk_css_provider_new()
        gtk_css_provider_load_from_string(p, """
        button.rw-bezel-textured, button.rw-bezel-recessed { background: none; box-shadow: none; border: none; min-height: 22px; padding: 2px 7px; border-radius: 6px; }
        button.rw-bezel-textured:hover, button.rw-bezel-recessed:hover { background-color: alpha(currentColor, 0.07); }
        button.rw-bezel-textured:active, button.rw-bezel-textured:checked, button.rw-bezel-recessed:active, button.rw-bezel-recessed:checked { background-color: alpha(currentColor, 0.13); }
        button.rw-bezel-inline { border-radius: 999px; padding: 0 7px; min-height: 16px; font-size: 11px; font-weight: bold; }
        button.rw-bezel-accessory { border-radius: 5px; padding: 1px 8px; min-height: 18px; }
        button.rw-bezel-circular, button.rw-bezel-help { border-radius: 999px; min-width: 21px; min-height: 21px; padding: 0; }
        button.rw-bezel-square { border-radius: 0; }
        button.rw-hover-border:not(:hover) { background: none; box-shadow: none; }
        textview.rw-textview, textview.rw-textview > text { background-color: transparent; }
        popover.rw-popover > contents { padding: 0; }
        """)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(p), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2))
    }

    private func box(_ w: NativeWidget) -> GtkBox { w as! GtkBox }

    // MARK: Events

    public func makeEventContainer(focusable: Bool, pointer: @escaping @MainActor (PointerEvent) -> Bool, key: @escaping @MainActor (KeyPress) -> Bool) -> NativeWidget {
        Self.installAppKitCSS()
        let b = makeWidget(.container) as! GtkBox
        let w = b.outer
        let s = akState(w)
        s.pointer = pointer
        s.key = key
        let click = gtk_gesture_click_new()!
        gtk_gesture_single_set_button(click, 0)
        connectState(UnsafeMutableRawPointer(click), "pressed", unsafeBitCast(pressedCB, to: GCallback.self), w)
        connectState(UnsafeMutableRawPointer(click), "released", unsafeBitCast(releasedCB, to: GCallback.self), w)
        gtk_widget_add_controller(w, click)
        let drag = gtk_gesture_drag_new()!
        connectState(UnsafeMutableRawPointer(drag), "drag-update", unsafeBitCast(dragUpdateCB, to: GCallback.self), w)
        connectState(UnsafeMutableRawPointer(drag), "drag-end", unsafeBitCast(dragEndCB, to: GCallback.self), w)
        gtk_widget_add_controller(w, drag)
        // One group: claiming the press for the click gesture would
        // otherwise deny the drag gesture, so a drag never updated.
        gtk_gesture_group(click, drag)
        let motion = gtk_event_controller_motion_new()!
        connectState(UnsafeMutableRawPointer(motion), "motion", unsafeBitCast(motionCB, to: GCallback.self), w)
        connectState(UnsafeMutableRawPointer(motion), "leave", unsafeBitCast(leaveCB, to: GCallback.self), w)
        gtk_widget_add_controller(w, motion)
        if focusable {
            gtk_widget_set_focusable(w, 1)
            let k = gtk_event_controller_key_new()!
            connectState(UnsafeMutableRawPointer(k), "key-pressed", unsafeBitCast(keyCB, to: GCallback.self), w)
            gtk_widget_add_controller(w, k)
        }
        return b
    }

    public func focus(_ widget: NativeWidget) {
        let b = box(widget)
        _ = gtk_widget_grab_focus(b.inner ?? b.outer)
    }

    public func resignFocus(_ widget: NativeWidget) {
        let b = box(widget)
        let w = b.inner ?? b.outer
        guard let root = gtk_widget_get_root(w), let focused = gtk_root_get_focus(root) else { return }
        // Only when focus is in this widget: another may have taken it already.
        let f = UnsafeMutableRawPointer(focused).assumingMemoryBound(to: GtkWidget.self)
        if f == w || gtk_widget_is_ancestor(f, w) != 0 || f == b.outer || gtk_widget_is_ancestor(f, b.outer) != 0 {
            gtk_root_set_focus(root, nil)
        }
    }

    public func setOwnsPoint(_ container: NativeWidget, _ owns: (@MainActor (CGPoint) -> Bool)?) {
        guard let c = (container as? GtkBox)?.canvas, runway_widget_is_canvas(c) != 0 else { return }
        guard let owns else { runway_canvas_set_contains(c, nil, nil, nil); return }
        let box = OwnsPointBox(owns)
        runway_canvas_set_contains(c, { x, y, data in
            guard let data else { return 1 }
            let f = Unmanaged<OwnsPointBox>.fromOpaque(data).takeUnretainedValue().f
            return MainActor.assumeIsolated { f(CGPoint(x: x, y: y)) } ? 1 : 0
        }, Unmanaged.passRetained(box).toOpaque(), { data in
            if let data { Unmanaged<OwnsPointBox>.fromOpaque(data).release() }
        })
    }

    public func setHitTestable(_ widget: NativeWidget, _ testable: Bool) {
        gtk_widget_set_can_target(box(widget).outer, testable ? 1 : 0)
    }

    public func observeFocus(_ widget: NativeWidget, _ changed: @escaping @MainActor (Bool) -> Void) {
        let w = box(widget).outer
        let s = akState(w)
        let first = s.focus == nil
        s.focus = changed
        if first { addFocusController(w) }
    }

    private func addFocusController(_ w: GW) {
        let f = gtk_event_controller_focus_new()!
        connectState(UnsafeMutableRawPointer(f), "enter", unsafeBitCast(focusInCB, to: GCallback.self), w)
        connectState(UnsafeMutableRawPointer(f), "leave", unsafeBitCast(focusOutCB, to: GCallback.self), w)
        gtk_widget_add_controller(w, f)
    }

    public func setCursor(_ widget: NativeWidget, _ cursor: CursorKind) {
        let name: String? = switch cursor {
        case .arrow: nil
        case .pointingHand: "pointer"
        case .iBeam: "text"
        case .resizeLeftRight: "col-resize"
        case .resizeUpDown: "row-resize"
        }
        gtk_widget_set_cursor_from_name(box(widget).outer, name)
    }

    // MARK: Scroll views

    static func offset(of scroll: GW) -> CGPoint {
        let h = gtk_scrolled_window_get_hadjustment(OpaquePointer(scroll)), v = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroll))
        return CGPoint(x: h.map { gtk_adjustment_get_value($0) } ?? 0, y: v.map { gtk_adjustment_get_value($0) } ?? 0)
    }

    static func applyOffset(_ scroll: GW, _ p: CGPoint, _ s: AKState) {
        guard let h = gtk_scrolled_window_get_hadjustment(OpaquePointer(scroll)), let v = gtk_scrolled_window_get_vadjustment(OpaquePointer(scroll)) else { return }
        settingOffset = true
        defer { settingOffset = false }
        let maxX = gtk_adjustment_get_upper(h) - gtk_adjustment_get_page_size(h)
        let maxY = gtk_adjustment_get_upper(v) - gtk_adjustment_get_page_size(v)
        // Until the document is allocated its extent is unknown: keep the request.
        if p.x > maxX + 0.5 || p.y > maxY + 0.5 { s.pendingOffset = p } else { s.pendingOffset = nil }
        gtk_adjustment_set_value(h, min(p.x, max(0, maxX)))
        gtk_adjustment_set_value(v, min(p.y, max(0, maxY)))
    }

    private func watchAdjustments(_ w: GW) {
        let s = akState(w)
        guard s.scroll == nil else { return }
        for adj in [gtk_scrolled_window_get_hadjustment(OpaquePointer(w)), gtk_scrolled_window_get_vadjustment(OpaquePointer(w))] {
            guard let adj else { continue }
            connectState(UnsafeMutableRawPointer(adj), "value-changed", unsafeBitCast(adjustmentCB, to: GCallback.self), w)
            connectState(UnsafeMutableRawPointer(adj), "changed", unsafeBitCast(adjustmentChangedCB, to: GCallback.self), w)
        }
    }

    public func scrollOffset(_ scroll: NativeWidget) -> CGPoint { Self.offset(of: box(scroll).outer) }
    public func setScrollOffset(_ scroll: NativeWidget, _ offset: CGPoint) {
        let w = box(scroll).outer
        watchAdjustments(w)
        if akState(w).scroll == nil { akState(w).scroll = { _ in } }
        Self.applyOffset(w, offset, akState(w))
    }
    public func scrollViewportSize(_ scroll: NativeWidget) -> CGSize {
        let w = box(scroll).outer
        let h = gtk_scrolled_window_get_hadjustment(OpaquePointer(w)), v = gtk_scrolled_window_get_vadjustment(OpaquePointer(w))
        return CGSize(width: h.map { gtk_adjustment_get_page_size($0) } ?? 0, height: v.map { gtk_adjustment_get_page_size($0) } ?? 0)
    }
    public func observeScroll(_ scroll: NativeWidget, _ changed: @escaping @MainActor (CGPoint) -> Void) {
        let w = box(scroll).outer
        watchAdjustments(w)
        akState(w).scroll = changed
    }
    public func setScrollers(_ scroll: NativeWidget, horizontal: Bool, vertical: Bool, autohides: Bool, bordered: Bool) {
        let w = box(scroll).outer
        // A scroller AppKit hides still scrolls (by wheel and keys); GTK's
        // EXTERNAL policy is that.
        gtk_scrolled_window_set_policy(OpaquePointer(w), horizontal ? GTK_POLICY_AUTOMATIC : GTK_POLICY_EXTERNAL, vertical ? GTK_POLICY_AUTOMATIC : GTK_POLICY_EXTERNAL)
        gtk_scrolled_window_set_has_frame(OpaquePointer(w), bordered ? 1 : 0)
        gtk_scrolled_window_set_overlay_scrolling(OpaquePointer(w), 1)
    }

    // MARK: Text fields and buttons

    public func observeTextField(_ field: NativeWidget, focus: @escaping @MainActor (Bool) -> Void, key: @escaping @MainActor (KeyPress) -> Bool) {
        let w = box(field).outer
        let s = akState(w)
        let first = s.textFocus == nil
        s.textFocus = focus
        s.textKey = key
        guard first else { return }
        addFocusController(w)
        let k = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(k, GTK_PHASE_CAPTURE)
        connectState(UnsafeMutableRawPointer(k), "key-pressed", unsafeBitCast(keyCB, to: GCallback.self), w)
        gtk_widget_add_controller(w, k)
    }

    public func setSearchField(_ field: NativeWidget, _ search: Bool) {
        let w = box(field).outer
        let s = akState(w)
        guard search != s.search else { return }
        s.search = search
        gtk_entry_set_icon_from_icon_name(typed(w), GTK_ENTRY_ICON_PRIMARY, search ? "system-search-symbolic" : nil)
        if search {
            connectState(UnsafeMutableRawPointer(w), "changed", unsafeBitCast(entryChangedCB, to: GCallback.self), w)
            connectState(UnsafeMutableRawPointer(w), "icon-press", unsafeBitCast(iconPressCB, to: GCallback.self), w)
            box(field).setClass("rw-search", true)
        }
    }

    public func setKeyEquivalent(_ button: NativeWidget, _ key: KeyPress?) {
        let w = box(button).outer
        let s = akState(w)
        let first = s.keyEquivalent == nil && s.keyController == nil
        s.keyEquivalent = key
        box(button).setClass("default", key?.key == "return" && !key!.command)
        if first, key != nil {
            connectState(UnsafeMutableRawPointer(w), "notify::root", unsafeBitCast(rootChangedCB, to: GCallback.self), w)
        }
        Self.attachKeyEquivalent(w)
    }

    /// The key equivalent listens on the button's window, ahead of focus.
    static func attachKeyEquivalent(_ w: GW) {
        let s = akState(w)
        let root = gtk_widget_get_root(w).map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWidget.self) }
        if let c = s.keyController, let old = s.keyRootWidget, old != root || s.keyEquivalent == nil {
            gtk_widget_remove_controller(old, c)
            s.keyController = nil
            s.keyRootWidget = nil
        }
        guard s.keyEquivalent != nil, let root, s.keyController == nil else { return }
        let k = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(k, GTK_PHASE_CAPTURE)
        connectState(UnsafeMutableRawPointer(k), "key-pressed", unsafeBitCast(rootKeyCB, to: GCallback.self), w)
        gtk_widget_add_controller(root, k)
        s.keyController = k
        s.keyRootWidget = root
    }

    public func setRadio(_ checkbox: NativeWidget) {
        let w = box(checkbox).outer
        // A check button drawn as a radio is one in a group; its partner
        // is never shown.
        let partner = gtk_check_button_new()!
        g_object_ref_sink(UnsafeMutableRawPointer(partner))
        gtk_check_button_set_group(typed(w), typed(partner))
        g_object_set_data_full(UnsafeMutablePointer<GObject>(OpaquePointer(w)), "rw-radio-partner", UnsafeMutableRawPointer(partner), { p in g_object_unref(p) })
    }

    public func setStyleClass(_ widget: NativeWidget, _ name: String, _ on: Bool) {
        Self.installAppKitCSS()
        box(widget).setClass(name, on)
    }

    public func setTextFieldAlignment(_ field: NativeWidget, _ alignment: TextAlignmentValue) {
        let b = box(field)
        guard case .textField = b.kind else { return }
        gtk_entry_set_alignment(typed(b.outer), alignment == .center ? 0.5 : alignment == .trailing ? 1 : 0)
    }
    public func setTextFieldEditable(_ field: NativeWidget, _ editable: Bool) {
        let b = box(field)
        guard case .textField = b.kind else { return }
        gtk_editable_set_editable(OpaquePointer(b.outer), editable ? 1 : 0)
        gtk_widget_set_can_focus(b.outer, editable ? 1 : 0)
    }

    // MARK: Rich text

    public func makeTextView() -> NativeWidget {
        Self.installAppKitCSS()
        let tv = runway_text_view_new()!
        gtk_text_view_set_wrap_mode(typed(tv), GTK_WRAP_WORD_CHAR)
        // AppKit keeps the undo stack (NSTextView registers its changes).
        gtk_text_buffer_set_enable_undo(gtk_text_view_get_buffer(typed(tv)), 0)
        let b = GtkBox(kind: .textEditor, outer: tv)
        b.setClass("rw-textview", true)
        let s = akState(tv)
        s.box = b
        var cb = RunwayTextViewCallbacks()
        cb.draw = textDrawCB
        cb.pointer = textPointerCB
        cb.insert = textInsertCB
        cb.delete_range = textDeleteCB
        cb.selection = textSelectionCB
        cb.height = textHeightCB
        cb.data = UnsafeMutableRawPointer(tv)
        runway_text_view_set_callbacks(tv, &cb)
        addFocusController(tv)
        let k = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(k, GTK_PHASE_CAPTURE)
        connectState(UnsafeMutableRawPointer(k), "key-pressed", unsafeBitCast(keyCB, to: GCallback.self), tv)
        gtk_widget_add_controller(tv, k)
        return b
    }

    public func configureTextView(_ view: NativeWidget, _ c: TextViewConfig, events: TextViewEvents) {
        let tv = box(view).outer
        let s = akState(tv)
        s.textEvents = events
        let o: UnsafeMutablePointer<GtkTextView> = typed(tv)
        gtk_text_view_set_editable(o, c.editable ? 1 : 0)
        gtk_text_view_set_cursor_visible(o, c.editable ? 1 : 0)
        gtk_text_view_set_wrap_mode(o, c.wraps ? GTK_WRAP_WORD_CHAR : GTK_WRAP_NONE)
        gtk_text_view_set_left_margin(o, Int32(c.insets.leading))
        gtk_text_view_set_right_margin(o, Int32(c.insets.trailing))
        gtk_text_view_set_top_margin(o, Int32(c.insets.top))
        gtk_text_view_set_bottom_margin(o, Int32(c.insets.bottom))
        gtk_widget_set_can_focus(tv, c.selectable || c.editable ? 1 : 0)
        box(view).setClass("rw-textview-clear", !c.drawsBackground)
        if c.drawsBackground, let bg = c.background { applyColorClass(tv, bg, property: "background-color", prefix: "rw-tvbg-") }
        if let caret = c.caretColor { applyColorClass(tv, caret, property: "caret-color", prefix: "rw-tvcaret-") }
        if c.insets != s.textConfig.insets {
            // A tag's margins replace the view's, so they include its insets.
            for (run, tag) in s.tags {
                guard let p = run.paragraph else { continue }
                runway_text_tag_set_margins(tag, Int32(c.insets.leading + p.headIndent), Int32(c.insets.trailing + max(0, -p.tailIndent)))
            }
        }
        s.textConfig = c
    }

    /// Background colours for text views, as generated CSS classes.
    private func applyColorClass(_ w: GW, _ c: RGBA, property: String, prefix: String) {
        let name = prefix + String(c.hexString.dropFirst())
        if Self.colorClasses.insert(name).inserted {
            let p = gtk_css_provider_new()
            gtk_css_provider_load_from_string(p, "textview.\(name), textview.\(name) > text { \(property): rgba(\(Int(c.r * 255)), \(Int(c.g * 255)), \(Int(c.b * 255)), \(c.a)); }")
            gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(p), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 3))
        }
        let id = ObjectIdentifier(akState(w))
        if let old = Self.appliedColor[id]?[prefix], old != name { runway_widget_remove_css(w, old) }
        Self.appliedColor[id, default: [:]][prefix] = name
        runway_widget_add_css(w, name)
    }
    private static var colorClasses: Set<String> = []
    /// Each widget's generated colour class, by kind (prefix).
    private static var appliedColor: [ObjectIdentifier: [String: String]] = [:]

    static func pangoFont(_ f: FontSpec) -> String {
        var d: [String] = []
        switch f.design {
        case .monospaced: d.append("\(BundledFonts.monoFamily),Monospace")
        case .serif: d.append("Serif")
        default: d.append(f.family ?? MacTheme.pangoFamilies)
        }
        switch f.weight {
        case .ultraLight: d.append("Ultra-Light")
        case .thin: d.append("Thin")
        case .light: d.append("Light")
        case .medium: d.append("Medium")
        case .semibold: d.append("Semi-Bold")
        case .bold: d.append("Bold")
        case .heavy: d.append("Heavy")
        case .black: d.append("Ultra-Heavy")
        case .regular: break
        }
        if f.italic { d.append("Italic") }
        // Fractional sizes (15.5 pt) stay fractional.
        let tenths = Int((max(1, f.size) * 10).rounded())
        d.append(tenths % 10 == 0 ? "\(tenths / 10)px" : "\(tenths / 10).\(tenths % 10)px")
        return d.joined(separator: " ")
    }

    private func tag(for run: RichTextRun, buffer: UnsafeMutablePointer<GtkTextBuffer>, view: GW, _ s: AKState) -> UnsafeMutablePointer<GtkTextTag> {
        var key = run
        // A spacer's character only matters for its natural width.
        if run.spacerWidth == nil { key.string = "" }
        if let t = s.tags[key] { return t }
        let p = run.paragraph
        let just: Int32 = p.map { $0.justified ? 3 : $0.alignment == .center ? 2 : $0.alignment == .trailing ? 1 : 0 } ?? -1
        let font = Self.pangoFont(run.font)
        var kern = run.kern
        // Pango takes a foreground alpha of 0 as "not set" (opaque): clear text gets the least alpha instead.
        var color = run.color.map { $0.a > 0 ? $0.hexString : String($0.hexString.dropLast(2)) + "01" }
        if let w = run.spacerWidth {
            // Blank space of the width asked for: the character, unseen, spaced out to it.
            kern = w - CGFloat(runway_text_width(view, font, run.string))
            color = "#00000001"
        }
        let background: String? = run.spacerWidth == nil ? run.background.flatMap { $0.a > 0 ? $0.hexString : nil } : nil
        let t = runway_text_tag_new(buffer, font, color, background,
                                    run.underline && run.spacerWidth == nil ? 1 : 0, run.strikethrough && run.spacerWidth == nil ? 1 : 0,
                                    Int32(run.baselineOffset * 1024), Double(kern * 1024),
                                    just, p.map { Int32(s.textConfig.insets.leading + $0.headIndent) } ?? -1,
                                    p.map { Int32($0.firstLineHeadIndent - $0.headIndent) } ?? Int32.min,
                                    p.map { Int32(s.textConfig.insets.trailing + max(0, -$0.tailIndent)) } ?? -1,
                                    p.map { Int32($0.paragraphSpacingBefore) } ?? -1, p.map { Int32($0.paragraphSpacing) } ?? -1,
                                    p.map { Int32($0.lineSpacing) } ?? -1)!
        runway_text_tag_set_more(t, run.hidden ? 1 : 0, Double(p?.lineHeightMultiple ?? 0), run.underline ? run.underlineColor?.hexString : nil,
                                 run.strikethrough ? run.strikethroughColor?.hexString : nil, run.underline ? Int32(run.underlineStyle) : 1)
        s.tags[key] = t
        return t
    }

    /// Runs the program's own changes to a text view's buffer (not reported back as the user's).
    private func programmatic<R>(_ tv: GW, _ body: () -> R) -> R {
        runway_text_view_set_programmatic(tv, 1)
        defer { runway_text_view_set_programmatic(tv, 0) }
        return body()
    }

    public func setTextViewContent(_ view: NativeWidget, _ runs: [RichTextRun]) {
        let tv = box(view).outer
        guard let buffer = gtk_text_view_get_buffer(typed(tv)) else { return }
        editTextView(view, replacing: 0..<Int(gtk_text_buffer_get_char_count(buffer)), with: runs, all: { runs })
    }

    public func editTextView(_ view: NativeWidget, replacing range: Range<Int>, with runs: [RichTextRun], all: () -> [RichTextRun]) {
        let tv = box(view).outer
        let s = akState(tv)
        guard let buffer = gtk_text_view_get_buffer(typed(tv)) else { return }
        programmatic(tv) {
            let count = Int(gtk_text_buffer_get_char_count(buffer))
            let r = range.clamped(to: 0..<count)
            var a = GtkTextIter(), b = GtkTextIter()
            gtk_text_buffer_get_iter_at_offset(buffer, &a, Int32(r.lowerBound))
            gtk_text_buffer_get_iter_at_offset(buffer, &b, Int32(r.upperBound))
            let new = runs.map(\.string).joined()
            let old = gtk_text_buffer_get_text(buffer, &a, &b, 1).map { p in defer { g_free(p) }; return String(cString: p) } ?? ""
            if old != new {
                gtk_text_buffer_delete(buffer, &a, &b)
                gtk_text_buffer_get_iter_at_offset(buffer, &a, Int32(r.lowerBound))
                gtk_text_buffer_insert(buffer, &a, new, -1)
            }
            let n = Int32(new.unicodeScalars.count)
            gtk_text_buffer_get_iter_at_offset(buffer, &a, Int32(r.lowerBound))
            gtk_text_buffer_get_iter_at_offset(buffer, &b, Int32(r.lowerBound) + n)
            gtk_text_buffer_remove_all_tags(buffer, &a, &b)
            var offset = Int32(r.lowerBound)
            for run in runs where !run.string.isEmpty {
                let len = Int32(run.string.unicodeScalars.count)
                gtk_text_buffer_get_iter_at_offset(buffer, &a, offset)
                gtk_text_buffer_get_iter_at_offset(buffer, &b, offset + len)
                gtk_text_buffer_apply_tag(buffer, tag(for: run, buffer: buffer, view: tv, s), &a, &b)
                offset += len
            }
        }
    }

    public func setTextViewLayers(_ view: NativeWidget, below: CGDisplayList?, above: CGDisplayList?) {
        let tv = box(view).outer
        let s = akState(tv)
        guard s.textLayers.0 != below || s.textLayers.1 != above else { return }
        s.textLayers = (below, above)
        runway_text_view_set_layers(tv, below?.isEmpty == false ? 1 : 0, above?.isEmpty == false ? 1 : 0)
    }

    public func textViewMove(_ view: NativeWidget, by step: TextMoveStep, count: Int, extend: Bool) {
        let index: Int32 = switch step {
        case .character: 0
        case .word: 1
        case .displayLine: 2
        case .displayLineEnd: 3
        case .paragraph: 4
        case .paragraphEnd: 5
        case .page: 6
        case .document: 7
        }
        runway_text_view_move(box(view).outer, index, Int32(count), extend ? 1 : 0)
    }

    public func textViewCharacterLayout(_ view: NativeWidget, at offset: Int) -> TextCharacterLayout {
        var out = [Double](repeating: 0, count: 7)
        runway_text_view_char_layout(box(view).outer, Int32(offset), &out)
        return TextCharacterLayout(rect: CGRect(x: out[0], y: out[1], width: out[2], height: out[3]), lineTop: out[4], lineBottom: out[5], baseline: out[6])
    }

    static func selection(_ buffer: UnsafeMutablePointer<GtkTextBuffer>) -> Range<Int> {
        var a = GtkTextIter(), b = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &a, gtk_text_buffer_get_insert(buffer))
        gtk_text_buffer_get_iter_at_mark(buffer, &b, gtk_text_buffer_get_selection_bound(buffer))
        let x = Int(gtk_text_iter_get_offset(&a)), y = Int(gtk_text_iter_get_offset(&b))
        return min(x, y)..<max(x, y)
    }
    static func select(_ buffer: UnsafeMutablePointer<GtkTextBuffer>, _ r: Range<Int>) {
        var a = GtkTextIter(), b = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &a, Int32(r.lowerBound))
        gtk_text_buffer_get_iter_at_offset(buffer, &b, Int32(r.upperBound))
        gtk_text_buffer_select_range(buffer, &b, &a)
    }

    public func textViewSelection(_ view: NativeWidget) -> Range<Int> {
        guard let buffer = gtk_text_view_get_buffer(typed(box(view).outer)) else { return 0..<0 }
        return Self.selection(buffer)
    }
    public func setTextViewSelection(_ view: NativeWidget, _ range: Range<Int>) {
        let tv = box(view).outer
        guard let buffer = gtk_text_view_get_buffer(typed(tv)) else { return }
        guard Self.selection(buffer) != range else { return }
        programmatic(tv) { Self.select(buffer, range) }
    }
    public func textViewUndo(_ view: NativeWidget, redo: Bool) {
        guard let buffer = gtk_text_view_get_buffer(typed(box(view).outer)) else { return }
        if redo { gtk_text_buffer_redo(buffer) } else { gtk_text_buffer_undo(buffer) }
    }

    public func textViewHeight(_ view: NativeWidget, width: CGFloat) -> CGFloat {
        let tv = box(view).outer
        let s = akState(tv)
        let ins = s.textConfig.insets
        // Before the view has been laid out, Pango measures the text as it will be.
        if gtk_widget_get_width(tv) <= 0 {
            let w = Int32(max(1, width - ins.leading - ins.trailing))
            var a = GtkTextIter(), b = GtkTextIter()
            let buffer = gtk_text_view_get_buffer(typed(tv))
            gtk_text_buffer_get_bounds(buffer, &a, &b)
            let all = gtk_text_buffer_get_text(buffer, &a, &b, 1).map { p in defer { g_free(p) }; return String(cString: p) } ?? ""
            let text = all.isEmpty ? " " : all
            let markup = Self.markup(StyledText(runs: [TextRun(string: text, font: s.textConfig.font, color: nil)]))
            return (CGFloat(runway_markup_height(tv, markup, w, s.textConfig.wraps ? 1 : 0)) + ins.top + ins.bottom).rounded(.up)
        }
        return CGFloat(runway_text_view_content_height(tv))
    }

    public func textViewCharacterRect(_ view: NativeWidget, at offset: Int) -> CGRect {
        var out = [Double](repeating: 0, count: 4)
        runway_text_view_char_rect(box(view).outer, Int32(offset), &out)
        return CGRect(x: out[0], y: out[1], width: out[2], height: out[3])
    }
    public func textViewCharacterIndex(_ view: NativeWidget, at point: CGPoint) -> Int {
        let tv: UnsafeMutablePointer<GtkTextView> = typed(box(view).outer)
        var bx: Int32 = 0, by: Int32 = 0
        gtk_text_view_window_to_buffer_coords(tv, GTK_TEXT_WINDOW_WIDGET, Int32(point.x), Int32(point.y), &bx, &by)
        var it = GtkTextIter()
        _ = gtk_text_view_get_iter_at_location(tv, &it, bx, by)
        return Int(gtk_text_iter_get_offset(&it))
    }

    // MARK: Popovers

    public func showPopover(_ content: NativeWidget, size: CGSize, anchor: NativeWidget, rect: CGRect, edge: PopoverEdge,
                            transient: Bool, onClose: @escaping @MainActor () -> Void) -> AnyObject {
        Self.installAppKitCSS()
        let c = box(content)
        let pop = gtk_popover_new()!
        runway_widget_add_css(pop, "rw-popover")
        runway_canvas_set_content_size(c.outer, Int32(size.width), Int32(size.height))
        gtk_popover_set_child(typed(pop), c.outer)
        gtk_widget_set_parent(pop, box(anchor).outer)
        var r = GdkRectangle(x: Int32(rect.minX), y: Int32(rect.minY), width: Int32(max(1, rect.width)), height: Int32(max(1, rect.height)))
        gtk_popover_set_pointing_to(typed(pop), &r)
        let pos: GtkPositionType = switch edge {
        case .top: GTK_POS_TOP
        case .bottom: GTK_POS_BOTTOM
        case .leading: GTK_POS_LEFT
        case .trailing: GTK_POS_RIGHT
        }
        gtk_popover_set_position(typed(pop), pos)
        gtk_popover_set_autohide(typed(pop), transient ? 1 : 0)
        let handle = GTKPopover(popover: pop, content: c, onClose: onClose)
        handle.pointsAtAnchor = rect == .zero
        Self.openPopovers.append(handle)
        _ = g_signal_connect_data(UnsafeMutableRawPointer(pop), "closed", unsafeBitCast(popoverClosedCB, to: GCallback.self),
                                  Unmanaged.passUnretained(handle).toOpaque(), nil, GConnectFlags(rawValue: 0))
        Self.popUpWhenMapped(handle, anchor: box(anchor).outer, tries: 100)
        return handle
    }
    /// GTK shows a popover only over a mapped widget: wait for the window.
    static func popUpWhenMapped(_ p: GTKPopover, anchor: GW, tries: Int) {
        guard p.isOpen else { return }
        if gtk_widget_get_mapped(anchor) != 0 {
            if p.pointsAtAnchor {
                var r = GdkRectangle(x: 0, y: 0, width: max(1, gtk_widget_get_width(anchor)), height: max(1, gtk_widget_get_height(anchor)))
                gtk_popover_set_pointing_to(typed(p.popover), &r)
            }
            gtk_popover_popup(typed(p.popover))
            gtk_widget_queue_allocate(anchor)
            // GTK focuses the first focusable child once the popover maps.
            current?.after(0.03) { if p.isOpen { runway_popover_focus_initial(p.popover) } }
            return
        }
        guard tries > 0 else { return }
        current?.after(0.05) { popUpWhenMapped(p, anchor: anchor, tries: tries - 1) }
    }

    public func setPopoverSize(_ popover: AnyObject, _ size: CGSize) {
        guard let p = popover as? GTKPopover else { return }
        runway_canvas_set_content_size(p.content.outer, Int32(size.width), Int32(size.height))
    }
    public func setPopoverKeyHandler(_ popover: AnyObject, _ handler: @escaping @MainActor (KeyPress) -> Bool) {
        guard let p = popover as? GTKPopover else { return }
        p.keys = addCaptureKeyHandler(p.popover) { key in MainActor.assumeIsolated { handler(key) } }
    }
    public func closePopover(_ popover: AnyObject) {
        guard let p = popover as? GTKPopover, p.isOpen else { return }
        gtk_popover_popdown(typed(p.popover))
    }

    // MARK: Titlebar

    public func setTitlebarShowsTitle(_ window: NativeWindow, _ shows: Bool) {
        (window as? GtkNativeWindow)?.setShowsTitle(shows)
    }
    public func setToolbarBand(_ window: NativeWindow, height: CGFloat) {
        (window as? GtkNativeWindow)?.setBandHeight(height)
    }
    public func setContentUnderToolbarBand(_ window: NativeWindow, _ under: Bool) {
        (window as? GtkNativeWindow)?.setContentUnderBand(under)
    }

    public func windowButtonFrames(_ window: NativeWindow) -> [CGRect]? {
        (window as? GtkNativeWindow)?.windowButtonFrames
    }

    public func setPassesThrough(_ container: NativeWidget, _ passes: Bool) {
        guard let c = (container as? GtkBox)?.canvas else { return }
        runway_canvas_set_pass_through(c, passes ? 1 : 0)
    }

    // MARK: Status items

    public func makeStatusItem(_ spec: StatusItemSpec, menu: @escaping @MainActor () -> [MenuItemSpec], activate: @escaping @MainActor () -> Void) -> AnyObject? {
        let item = GTKStatusItem(menu: menu, activate: activate)
        let icon = spec.symbol.map { SymbolMap.iconName(for: $0) } ?? "application-x-executable-symbolic"
        let id = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        // The tray names items by their title: the app's name when the item shows only an icon.
        let title = spec.title.isEmpty ? ProcessInfo.processInfo.processName : spec.title
        guard let n = runway_status_item_new(id, title, icon, spec.tooltip, statusCB, Unmanaged.passRetained(item).toOpaque()) else {
            Unmanaged.passUnretained(item).release()
            return nil
        }
        item.native = n
        item.refreshMenu()
        return item
    }
    public func updateStatusItem(_ item: AnyObject, _ spec: StatusItemSpec) {
        guard let i = item as? GTKStatusItem else { return }
        let icon = spec.symbol.map { SymbolMap.iconName(for: $0) } ?? "application-x-executable-symbolic"
        runway_status_item_set(i.native, spec.title, icon, spec.tooltip, spec.visible ? 1 : 0)
        i.refreshMenu()
    }
    public func removeStatusItem(_ item: AnyObject) {
        guard let i = item as? GTKStatusItem, let n = i.native else { return }
        runway_status_item_free(n)
        i.native = nil
        Unmanaged.passUnretained(i).release()
    }

    // MARK: Timing and menus

    public func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        runway_timeout(UInt32(max(0, seconds * 1000)), timeoutCB, Unmanaged.passRetained(WorkBox(work)).toOpaque())
    }

    public func popUpMenu(_ items: [MenuItemSpec], in widget: NativeWidget, at point: CGPoint) {
        let b = box(widget)
        guard let canvas = b.canvas else { return }
        var titles: [String] = [], kinds: [Int32] = [], depths: [Int32] = [], enabled: [gboolean] = [], checked: [gboolean] = []
        var flat: [MenuItemSpec] = []
        func walk(_ list: [MenuItemSpec], _ depth: Int32) {
            for i in list {
                titles.append(i.shortcut.map { i.title + "\t" + $0.gtkAccelerator } ?? i.title); depths.append(depth); enabled.append(i.enabled ? 1 : 0); checked.append(i.checked ? 1 : 0); flat.append(i)
                if i.isSeparator { kinds.append(1) } else if !i.children.isEmpty { kinds.append(2); walk(i.children, depth + 1) } else { kinds.append(0) }
            }
        }
        walk(items, 0)
        let actions = GTKMenuActions(flat)
        Self.menuActions = actions
        withCStringArray(titles) { t in
            runway_popup_menu(canvas, Int32(point.x), Int32(point.y), t, kinds, depths, enabled, checked, Int32(flat.count),
                              menuIndexCB, Unmanaged.passUnretained(actions).toOpaque())
        }
    }
    private static var menuActions: GTKMenuActions?
}
final class OwnsPointBox {
    let f: @MainActor (CGPoint) -> Bool
    init(_ f: @escaping @MainActor (CGPoint) -> Bool) { self.f = f }
}
#endif
