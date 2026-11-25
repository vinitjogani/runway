// The GTK side of AppKit's view system (RunwayCore.ViewSystemBackend):
// raw input from event controllers, activation, drops, cursors, the menu
// bar (GtkPopoverMenuBar over a GMenu) and context menus (GtkPopoverMenu),
// screens from GDK monitors, text metrics from Pango, focus.

#if os(Linux)
import Foundation
import CGtk
import CRunwayGtk
import RunwayCore
import CoreGraphics

/// Callbacks kept alive by GTK (released when the window goes).
final class AppKitEventBox {
    let f: (RawEvent) -> Bool
    init(_ f: @escaping (RawEvent) -> Bool) { self.f = f }
}
final class AppKitBoolBox {
    let f: (Bool) -> Void
    init(_ f: @escaping (Bool) -> Void) { self.f = f }
}
final class AppKitDropBox {
    let f: (RawDragEvent) -> RawDragOperation
    init(_ f: @escaping (RawDragEvent) -> RawDragOperation) { self.f = f }
}
final class AppKitIndexBox {
    let f: (Int) -> Void
    init(_ f: @escaping (Int) -> Void) { self.f = f }
}

private let releaseBox: @convention(c) (UnsafeMutableRawPointer?) -> Void = { p in
    guard let p else { return }
    Unmanaged<AnyObject>.fromOpaque(p).release()
}

private let eventTrampoline: @convention(c) (UnsafePointer<RunwayAppKitEvent>?, UnsafeMutableRawPointer?) -> gboolean = { ep, data in
    guard let ep, let data else { return 0 }
    let box = Unmanaged<AppKitEventBox>.fromOpaque(data).takeUnretainedValue()
    let c = ep.pointee
    let kind: RawEvent.Kind
    switch Int(c.kind) {
    case RUNWAY_EV_DOWN: kind = .mouseDown
    case RUNWAY_EV_UP: kind = .mouseUp
    case RUNWAY_EV_MOTION: kind = .mouseMoved
    case RUNWAY_EV_SCROLL: kind = .scroll
    case RUNWAY_EV_ENTER: kind = .mouseEntered
    case RUNWAY_EV_LEAVE: kind = .mouseExited
    case RUNWAY_EV_KEY_DOWN: kind = .keyDown
    case RUNWAY_EV_KEY_UP: kind = .keyUp
    default: kind = .flagsChanged
    }
    var e = RawEvent(kind: kind)
    e.button = Int(c.button)
    e.location = CGPoint(x: c.x, y: c.y)
    e.modifiers = RawModifiers(rawValue: UInt32(c.modifiers))
    e.timestamp = c.time
    e.scrollDelta = CGSize(width: c.dx, height: c.dy)
    e.preciseScrolling = c.precise != 0
    e.keyCode = UInt32(c.keycode)
    e.keyName = c.keyname.map { String(cString: $0) } ?? ""
    let chars = c.chars.map { String(cString: $0) } ?? ""
    e.characters = chars
    e.charactersIgnoringModifiers = chars
    e.isRepeat = c.is_repeat != 0
    e.nativeTextFocus = c.native_text_focus != 0
    return MainActor.assumeIsolated { box.f(e) } ? 1 : 0
}

private let boolTrampoline: @convention(c) (gboolean, UnsafeMutableRawPointer?) -> Void = { v, data in
    guard let data else { return }
    let box = Unmanaged<AppKitBoolBox>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { box.f(v != 0) }
}

private let indexTrampoline: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { i, data in
    guard let data else { return }
    let box = Unmanaged<AppKitIndexBox>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { box.f(Int(i)) }
}

private let dropTrampoline: @convention(c) (Int32, Double, Double, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = { kind, x, y, uris, text, data in
    guard let data else { return 0 }
    let box = Unmanaged<AppKitDropBox>.fromOpaque(data).takeUnretainedValue()
    let u = uris.map { String(cString: $0) } ?? ""
    let t = text.map { String(cString: $0) } ?? ""
    let files = u.split(separator: "\n").compactMap { URL(string: String($0)) }
    let k: RawDragEvent.Kind = kind == 0 ? .entered : kind == 1 ? .updated : kind == 2 ? .exited : .perform
    let e = RawDragEvent(kind: k, location: CGPoint(x: x, y: y), fileURLs: files, strings: t.isEmpty ? [] : [t])
    return Int32(MainActor.assumeIsolated { box.f(e) }.rawValue)
}

/// A built menu: the GMenu model and its actions.
@MainActor final class GtkMenuState {
    var model: OpaquePointer?          // GMenu*
    var group: OpaquePointer?          // GSimpleActionGroup*
    var actions: [Int: OpaquePointer] = [:]   // id -> GSimpleAction*
    var activateBox: AppKitIndexBox?
    var validate: (() -> [MenuItemState])?
    var bar: GW?
    deinit {
        if let model { g_object_unref(UnsafeMutableRawPointer(model)) }
        if let group { g_object_unref(UnsafeMutableRawPointer(group)) }
    }

    /// Builds the GMenu for `nodes` with actions "<prefix>.m<id>".
    init(_ nodes: [MenuNode], prefix: String, callbacks: MenuCallbacks) {
        group = OpaquePointer(g_simple_action_group_new())
        let box = AppKitIndexBox { id in callbacks.activate(id) }
        activateBox = box
        validate = callbacks.validate
        model = build(nodes, prefix: prefix, box: box)
    }

    private func build(_ nodes: [MenuNode], prefix: String, box: AppKitIndexBox) -> OpaquePointer {
        let menu = g_menu_new()!
        var section = g_menu_new()!
        g_menu_append_section(menu, nil, UnsafeMutablePointer<GMenuModel>(section))
        for n in nodes {
            switch n.kind {
            case .separator:
                g_object_unref(UnsafeMutableRawPointer(section))
                section = g_menu_new()!
                g_menu_append_section(menu, nil, UnsafeMutablePointer<GMenuModel>(section))
            case .submenu:
                let sub = build(n.children, prefix: prefix, box: box)
                g_menu_append_submenu(section, Self.label(n.title), UnsafeMutablePointer<GMenuModel>(sub))
                g_object_unref(UnsafeMutableRawPointer(sub))
            case .item:
                let name = "m\(n.id)"
                let action: OpaquePointer
                if n.checked {
                    action = g_simple_action_new_stateful(name, nil, g_variant_new_boolean(1))!
                } else {
                    action = g_simple_action_new(name, nil)!
                }
                g_simple_action_set_enabled(action, n.enabled ? 1 : 0)
                runway_appkit_action_connect(action, indexTrampoline, Unmanaged.passUnretained(box).toOpaque(), Int32(n.id))
                g_action_map_add_action(group, action)
                actions[n.id] = action
                let item = g_menu_item_new(Self.label(n.title), "\(prefix).\(name)")!
                if let accel = n.accelerator.flatMap(Self.gtkAccelerator) {
                    g_menu_item_set_attribute_value(item, "accel", g_variant_new_string(accel))
                }
                g_menu_append_item(section, item)
                g_object_unref(UnsafeMutableRawPointer(item))
                g_object_unref(UnsafeMutableRawPointer(action))
            }
        }
        g_object_unref(UnsafeMutableRawPointer(section))
        return menu
    }

    /// Mnemonic underscores are literal in Mac titles.
    static func label(_ s: String) -> String { s.replacingOccurrences(of: "_", with: "__") }

    /// "<Control>," → "<Control>comma": the key part becomes a keysym name.
    static func gtkAccelerator(_ a: String) -> String? {
        var mods = ""
        var rest = Substring(a)
        while rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
            mods += rest[...close]
            rest = rest[rest.index(after: close)...]
        }
        guard !rest.isEmpty else { return nil }
        if rest.count > 1 { return mods + rest }
        let scalar = rest.unicodeScalars.first!
        let keyval = gdk_unicode_to_keyval(scalar.value)
        guard let name = gdk_keyval_name(keyval) else { return nil }
        return mods + String(cString: name)
    }

    /// Pushes fresh enabled/checked states into the actions.
    func refresh() {
        guard let states = validate?() else { return }
        for s in states {
            guard let a = actions[s.id] else { continue }
            g_simple_action_set_enabled(a, s.enabled ? 1 : 0)
            if g_action_get_state_type(a) != nil {
                g_simple_action_set_state(a, g_variant_new_boolean(s.checked ? 1 : 0))
            }
        }
    }
}

/// A window's menu on the desktop's global menu bar, when there is one.
@MainActor final class GtkAppMenu {
    var native: OpaquePointer?
    weak var window: GtkNativeWindow?
    var hasHost = false
    init(_ window: GtkNativeWindow) {
        self.window = window
        native = runway_appmenu_new(window.window, { present, data in
            let m = Unmanaged<GtkAppMenu>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated { m.hostChanged(present != 0) }
        }, { data in
            let m = Unmanaged<GtkAppMenu>.fromOpaque(data!).takeUnretainedValue()
            MainActor.assumeIsolated {
                guard let w = m.window else { return }
                GtkAppKit.menuBars[ObjectIdentifier(w)]?.refresh()
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    deinit { if let native { runway_appmenu_free(native) } }

    /// The bar moves to the top of the screen while a host shows it, and
    /// back into the window when there is none.
    func hostChanged(_ present: Bool) {
        hasHost = present
        guard let w = window, let bar = GtkAppKit.menuBars[ObjectIdentifier(w)]?.bar else { return }
        gtk_widget_set_visible(bar, present ? 0 : 1)
        w.globalMenuChanged(present)
    }
}

@MainActor enum GtkAppKit {
    static var menuBars: [ObjectIdentifier: GtkMenuState] = [:]
    static var appMenus: [ObjectIdentifier: GtkAppMenu] = [:]
}

extension GTKBackend: ViewSystemBackend {
    private func gtkWindow(_ w: NativeWindow) -> GtkNativeWindow? { w as? GtkNativeWindow }

    public func setEventHandler(_ window: NativeWindow, _ handler: ((RawEvent) -> Bool)?) {
        guard let w = gtkWindow(window), let handler else { return }
        let box = AppKitEventBox(handler)
        let content = (w.content as! GtkBox).outer
        runway_appkit_install_events(w.window, content, eventTrampoline, Unmanaged.passRetained(box).toOpaque(), releaseBox)
    }

    public func setActivationHandler(_ window: NativeWindow, _ handler: ((Bool) -> Void)?) {
        guard let w = gtkWindow(window), let handler else { return }
        let box = AppKitBoolBox(handler)
        runway_appkit_install_activation(w.window, boolTrampoline, Unmanaged.passRetained(box).toOpaque(), releaseBox)
    }

    public func setDropHandler(_ window: NativeWindow, _ handler: ((RawDragEvent) -> RawDragOperation)?) {
        guard let w = gtkWindow(window), let handler else { return }
        guard !GtkAppKit.dropInstalled.contains(ObjectIdentifier(w)) else {
            GtkAppKit.dropHandlers[ObjectIdentifier(w)]?.handler = handler
            return
        }
        GtkAppKit.dropInstalled.insert(ObjectIdentifier(w))
        let holder = GtkAppKit.DropHolder(handler)
        GtkAppKit.dropHandlers[ObjectIdentifier(w)] = holder
        let box = AppKitDropBox { [weak holder] e in holder?.handler(e) ?? [] }
        runway_appkit_install_drop((w.content as! GtkBox).outer, dropTrampoline, Unmanaged.passRetained(box).toOpaque(), releaseBox)
    }

    public func setCursor(_ cursor: CursorSpec, in window: NativeWindow) {
        guard let w = gtkWindow(window) else { return }
        let content = (w.content as! GtkBox).outer
        switch cursor {
        case let .named(n): runway_appkit_set_cursor(content, n, nil, 0, 0, 0, 0)
        case .hidden: runway_appkit_set_cursor(content, "none", nil, 0, 0, 0, 0)
        case let .image(width, height, rgba, hot):
            rgba.withUnsafeBufferPointer { runway_appkit_set_cursor(content, nil, $0.baseAddress, Int32(width), Int32(height), Int32(hot.x), Int32(hot.y)) }
        }
    }

    public func setMenuBar(_ menu: [MenuNode]?, in window: NativeWindow, callbacks: MenuCallbacks) {
        guard let w = gtkWindow(window) else { return }
        let id = ObjectIdentifier(w)
        guard let menu else {
            if !w.setMenuBar(nil) { runway_appkit_set_menubar(w.window, nil) }
            GtkAppKit.menuBars[id] = nil
            GtkAppKit.appMenus[id] = nil
            return
        }
        let state = GtkMenuState(menu, prefix: "rwm", callbacks: callbacks)
        let bar = gtk_popover_menu_bar_new_from_model(UnsafeMutablePointer<GMenuModel>(state.model))!
        state.bar = bar
        gtk_widget_insert_action_group(w.window, "rwm", state.group)
        let refresh = AppKitBoolBox { [weak state] _ in state?.refresh() }
        runway_appkit_on_press(bar, boolTrampoline, Unmanaged.passRetained(refresh).toOpaque(), releaseBox)
        // In the titlebar row, beside the window buttons (a window without
        // one gets the bar along the top of its content).
        if !w.setMenuBar(bar) { runway_appkit_set_menubar(w.window, bar) }
        GtkAppKit.menuBars[id] = state
        // The same menu, on the desktop's global menu bar where there is one.
        let app = GtkAppKit.appMenus[id] ?? GtkAppMenu(w)
        GtkAppKit.appMenus[id] = app
        runway_appmenu_set(app.native, UnsafeMutablePointer<GMenuModel>(state.model), state.group, "rwm")
        if app.hasHost { gtk_widget_set_visible(bar, 0) }
    }

    public func popUpMenu(_ menu: [MenuNode], in window: NativeWindow, at point: CGPoint, callbacks: MenuCallbacks) {
        guard let w = gtkWindow(window) else { return }
        let state = GtkMenuState(menu, prefix: "rwc", callbacks: callbacks)
        state.refresh()
        runway_appkit_popup_menu((w.content as! GtkBox).outer, UnsafeMutablePointer<GMenuModel>(state.model), state.group, point.x, point.y)
    }

    public func screens() -> [ScreenSpec] {
        guard let display = gdk_display_get_default(), let monitors = gdk_display_get_monitors(display) else { return [] }
        var out: [ScreenSpec] = []
        let n = g_list_model_get_n_items(monitors)
        for i in 0..<n {
            guard let item = g_list_model_get_item(monitors, i) else { continue }
            let m = OpaquePointer(item)
            var r = GdkRectangle()
            gdk_monitor_get_geometry(m, &r)
            let frame = CGRect(x: CGFloat(r.x), y: CGFloat(r.y), width: CGFloat(r.width), height: CGFloat(r.height))
            let scale = CGFloat(gdk_monitor_get_scale_factor(m))
            let name = gdk_monitor_get_model(m).map { String(cString: $0) } ?? gdk_monitor_get_connector(m).map { String(cString: $0) } ?? "Display \(i + 1)"
            out.append(ScreenSpec(frame: frame, visibleFrame: frame, scale: scale, name: name))
            g_object_unref(item)
        }
        // The primary display first (the one at the origin).
        if let p = out.firstIndex(where: { $0.frame.origin == .zero }), p != 0 { out.insert(out.remove(at: p), at: 0) }
        return out
    }

    public func measureText(_ layout: CGTextLayout) -> CGSize { PangoText.measure(layout) }

    public func setKeyboardFocus(_ widget: NativeWidget?, in window: NativeWindow) {
        guard let w = gtkWindow(window) else { return }
        if let b = widget as? GtkBox {
            _ = gtk_widget_grab_focus(b.inner ?? b.outer)
        } else {
            gtk_window_set_focus(typed(w.window), nil)
        }
    }

    public func setDecorated(_ decorated: Bool, window: NativeWindow) {
        guard let w = gtkWindow(window) else { return }
        gtk_window_set_decorated(typed(w.window), decorated ? 1 : 0)
    }

    public func setPreferredColorScheme(_ scheme: ColorSchemeValue?) {
        guard let s = gtk_settings_get_default() else { return }
        var v = GValue()
        g_value_init(&v, GType(5 << 2))   // G_TYPE_BOOLEAN
        g_value_set_boolean(&v, (scheme ?? colorScheme) == .dark ? 1 : 0)
        g_object_set_property(UnsafeMutablePointer<GObject>(s), "gtk-application-prefer-dark-theme", &v)
        g_value_unset(&v)
    }

    public func activate(_ window: NativeWindow) {
        guard let w = gtkWindow(window) else { return }
        gtk_window_present(typed(w.window))
    }
}

extension GtkAppKit {
    final class DropHolder {
        var handler: (RawDragEvent) -> RawDragOperation
        init(_ h: @escaping (RawDragEvent) -> RawDragOperation) { handler = h }
    }
    static var dropInstalled = Set<ObjectIdentifier>()
    static var dropHandlers: [ObjectIdentifier: DropHolder] = [:]
}
#endif
