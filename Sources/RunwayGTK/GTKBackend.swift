// The Linux backend: GTK 4 widgets, Cairo drawing, GIO services.
//
// Every widget sits in a RunwayCanvas (see CRunwayGtk) at the frame
// Runway's layout computed, so SwiftUI's layout rules hold exactly while
// the controls themselves are GTK's own: native look, theming, input
// methods, accessibility.

#if os(Linux)
import Foundation
import CGtk
import CRunwayGtk
import RunwayCore

typealias GW = UnsafeMutablePointer<GtkWidget>

@inline(__always) func raw(_ w: GW) -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(w) }
@inline(__always) func typed<T>(_ w: GW) -> UnsafeMutablePointer<T> { raw(w).assumingMemoryBound(to: T.self) }
@inline(__always) func opaque(_ w: GW) -> OpaquePointer { OpaquePointer(w) }

/// A closure GTK calls back, kept alive by its widget.
final class Handler {
    let fire: (UnsafeMutableRawPointer?) -> Void
    init(_ fire: @escaping (UnsafeMutableRawPointer?) -> Void) { self.fire = fire }
}

private let signalCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { instance, data in
    guard let data else { return }
    Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue().fire(instance)
}
/// For signals with one extra argument (notify::, toggled with a param…).
private let signalCallback1: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void = { instance, _, data in
    guard let data else { return }
    Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue().fire(instance)
}
/// GtkGestureClick::released (gesture, n_press, x, y, data).
private final class ClickHandler {
    let fire: (CGPoint) -> Void
    init(_ fire: @escaping (CGPoint) -> Void) { self.fire = fire }
}

private let clickCallback: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void = { _, _, x, y, data in
    guard let data else { return }
    Unmanaged<ClickHandler>.fromOpaque(data).takeUnretainedValue().fire(CGPoint(x: x, y: y))
}
/// Signals returning gboolean (activate-link, close-request).
private let boolCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = { instance, data in
    guard let data else { return 0 }
    Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue().fire(instance)
    return 1
}

@MainActor final class GtkBox: NativeWidget {
    let kind: WidgetKind
    /// What a parent places.
    let outer: GW
    /// Where children go (containers, scroll documents, button labels).
    var canvas: GW?
    /// An inner widget filling `outer` (images, text views).
    var inner: GW?
    var props = WidgetProps()
    /// update() has run at least once.
    var configured = false
    var events = WidgetEvents()
    var handlers: [Handler] = []
    private var clickHandler: ClickHandler?
    var updating = false
    var segments: [GW] = []
    var cssClasses: Set<String> = []
    var markup: String?
    var options: [String] = []
    var menuModelInstalled = false
    var menuItems: [MenuItemSpec] = []
    var size: CGSize = .zero
    var textureSize: CGSize?

    init(kind: WidgetKind, outer: GW) {
        self.kind = kind
        self.outer = outer
        g_object_ref_sink(raw(outer))
    }

    func connect(_ instance: UnsafeMutableRawPointer, _ signal: String, arity: Int = 0, _ f: @escaping (UnsafeMutableRawPointer?) -> Void) {
        let h = Handler(f)
        handlers.append(h)
        let cb: GCallback = arity == 0 ? unsafeBitCast(signalCallback, to: GCallback.self) : unsafeBitCast(signalCallback1, to: GCallback.self)
        _ = runway_connect(instance, signal, cb, Unmanaged.passUnretained(h).toOpaque())
    }

    func connectBool(_ instance: UnsafeMutableRawPointer, _ signal: String, _ f: @escaping (UnsafeMutableRawPointer?) -> Void) {
        let h = Handler(f)
        handlers.append(h)
        _ = runway_connect(instance, signal, unsafeBitCast(boolCallback, to: GCallback.self), Unmanaged.passUnretained(h).toOpaque())
    }

    func onClick(_ f: @escaping (CGPoint) -> Void) {
        let g = gtk_gesture_click_new()!
        let h = ClickHandler(f)
        clickHandler = h
        _ = runway_connect(UnsafeMutableRawPointer(g), "released", unsafeBitCast(clickCallback, to: GCallback.self), Unmanaged.passUnretained(h).toOpaque())
        gtk_widget_add_controller(outer, g)
    }

    func setClass(_ name: String, _ on: Bool) {
        if on, !cssClasses.contains(name) { runway_widget_add_css(outer, name); cssClasses.insert(name) }
        if !on, cssClasses.contains(name) { runway_widget_remove_css(outer, name); cssClasses.remove(name) }
    }
}

@MainActor final class GtkNativeWindow: NativeWindow {
    let window: GW
    let content: NativeWidget
    var onResize: ((CGSize) -> Void)?
    var onCloseRequest: (() -> Bool)?
    var onClosed: (() -> Void)?
    var onKey: ((KeyPress) -> Bool)?
    private(set) var contentSize: CGSize
    private var handlers: [Handler] = []
    private var closed = false
    private var keyHandler: KeyHandlerBox?

    var title: String {
        didSet {
            gtk_window_set_title(typed(window), title)
            if let titleLabel { gtk_label_set_text(opaque(titleLabel), title) }
        }
    }

    /// The titlebar row (client-side, so it looks the same under every
    /// window manager, or none): the window buttons at the leading edge as
    /// on the Mac, then the menu bar (the Mac's is at the top of the
    /// screen), and the title centred.
    private(set) var titlebar: GW?
    /// Holds the menu bar, beside the window buttons.
    private(set) var menuSlot: GW?
    private(set) var titleLabel: GW?

    private func makeTitlebar(_ o: WindowOptions) {
        guard o.titlebar == .standard else {
            // A sheet: no titlebar row at all (and none from the window manager).
            let bare = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
            runway_widget_add_css(bare, "rw-titlebar-none")
            gtk_window_set_titlebar(typed(window), bare)
            return
        }
        let handle = gtk_window_handle_new()!
        let row = gtk_center_box_new()!
        let start = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        let controls = gtk_window_controls_new(GTK_PACK_START)!
        gtk_window_controls_set_decoration_layout(opaque(controls), "close,minimize,maximize:")
        gtk_widget_set_valign(controls, GTK_ALIGN_CENTER)
        gtk_box_append(typed(start), controls)
        let slot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_widget_set_valign(slot, GTK_ALIGN_CENTER)
        runway_widget_add_css(slot, "rw-menu-slot")
        gtk_box_append(typed(start), slot)
        let label = gtk_label_new(o.title)!
        gtk_label_set_ellipsize(opaque(label), PANGO_ELLIPSIZE_END)
        gtk_label_set_single_line_mode(opaque(label), 1)
        runway_widget_add_css(label, "rw-titlebar-title")
        gtk_center_box_set_start_widget(opaque(row), start)
        gtk_center_box_set_center_widget(opaque(row), label)
        gtk_window_handle_set_child(opaque(handle), row)
        runway_widget_add_css(handle, "titlebar")
        runway_widget_add_css(handle, "rw-titlebar")
        gtk_window_set_titlebar(typed(window), handle)
        titlebar = handle; menuSlot = slot; titleLabel = label; rowControls = controls
    }
    /// The window buttons in the titlebar row (hidden while they float in
    /// the toolbar band).
    private var rowControls: GW?

    /// Shows the menu bar in the titlebar row (false: no row to show it in).
    func setMenuBar(_ bar: GW?) -> Bool {
        guard let slot = menuSlot else { return false }
        while let c = gtk_widget_get_first_child(slot) { gtk_box_remove(typed(slot), c) }
        if let bar { gtk_box_append(typed(slot), bar) }
        return true
    }

    /// The desktop shows the menu bar (or stopped): the titlebar row keeps
    /// just the window buttons and title, as a Mac window's does.
    func globalMenuChanged(_ shown: Bool) {
        if let menuSlot { gtk_widget_set_visible(menuSlot, shown ? 0 : 1) }
        globalMenu = shown
        updateMerge()
    }

    // MARK: Window buttons in the toolbar band

    /// Window buttons floating over the content's toolbar band, as the Mac
    /// draws them for a full-size-content window with a toolbar: apps leave
    /// room for them at the band's leading edge. With the menu bar on the
    /// desktop's top bar the titlebar row then goes away; with the menu bar
    /// in the window, the row stays for the menu alone, so the room the app
    /// left in its band still holds the buttons rather than a gap.
    private var floatingControls: GW?
    private var globalMenu = false
    private(set) var bandHeight: CGFloat = 0
    private(set) var buttonsInBand = false
    private var rowHidden = false
    static let lightSize: CGFloat = 12, lightGap: CGFloat = 8, lightInset: CGFloat = 12

    func setBandHeight(_ h: CGFloat) {
        guard h != bandHeight else { return }
        bandHeight = h
        updateMerge()
    }

    private var contentUnderBand = false
    func setContentUnderBand(_ under: Bool) {
        guard under != contentUnderBand else { return }
        contentUnderBand = under
        updateMerge()
    }

    private func updateMerge() {
        // In the band when the row would hold nothing else (global menu), or
        // when the content runs under the band and has room for them.
        let inBand = bandHeight > 0 && titlebar != nil && (globalMenu || contentUnderBand)
        let hideRow = inBand && globalMenu
        if let floatingControls {
            gtk_widget_set_margin_top(floatingControls, Int32(((bandHeight - Self.lightSize) / 2).rounded()))
        }
        guard let titlebar, let floatingControls else { return }
        if inBand != buttonsInBand {
            buttonsInBand = inBand
            gtk_widget_set_visible(floatingControls, inBand ? 1 : 0)
            if let rowControls { gtk_widget_set_visible(rowControls, inBand ? 0 : 1) }
            if inBand { runway_widget_add_css(titlebar, "rw-titlebar-menu-only") } else { runway_widget_remove_css(titlebar, "rw-titlebar-menu-only") }
        }
        if hideRow != rowHidden {
            rowHidden = hideRow
            if hideRow { runway_widget_add_css(titlebar, "rw-titlebar-merged") } else { runway_widget_remove_css(titlebar, "rw-titlebar-merged") }
            if let row = gtk_widget_get_first_child(titlebar) { gtk_widget_set_visible(row, hideRow ? 0 : 1) }
            // The row's height goes to the content (the window keeps its size).
        }
    }

    /// Close, minimise and zoom, in the canvas (y down), while in the band.
    var windowButtonFrames: [CGRect]? {
        guard buttonsInBand else { return nil }
        let y = ((bandHeight - Self.lightSize) / 2).rounded()
        return (0..<3).map { i in
            CGRect(x: Self.lightInset + CGFloat(i) * (Self.lightSize + Self.lightGap), y: y, width: Self.lightSize, height: Self.lightSize)
        }
    }

    private func makeFloatingControls(over canvas: GW) -> GW {
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(opaque(overlay), canvas)
        let handle = gtk_window_handle_new()!
        let controls = gtk_window_controls_new(GTK_PACK_START)!
        gtk_window_controls_set_decoration_layout(opaque(controls), "close,minimize,maximize:")
        runway_widget_add_css(controls, "rw-band-controls")
        gtk_window_handle_set_child(opaque(handle), controls)
        gtk_widget_set_halign(handle, GTK_ALIGN_START)
        gtk_widget_set_valign(handle, GTK_ALIGN_START)
        gtk_widget_set_margin_start(handle, Int32(Self.lightInset))
        gtk_widget_set_visible(handle, 0)
        gtk_overlay_add_overlay(opaque(overlay), handle)
        floatingControls = handle
        return overlay
    }

    func setShowsTitle(_ shows: Bool) {
        if let titleLabel { gtk_widget_set_visible(titleLabel, shows ? 1 : 0) }
    }

    init(_ o: WindowOptions, parent: GtkNativeWindow?, backend: GTKBackend) {
        window = gtk_window_new()
        g_object_ref_sink(raw(window))
        title = o.title
        contentSize = o.size
        let canvas = backend.makeWidget(.container) as! GtkBox
        content = canvas
        makeTitlebar(o)
        gtk_window_set_title(typed(window), o.title)
        setContentSize(o.size)
        gtk_window_set_resizable(typed(window), o.resizable ? 1 : 0)
        if let parent {
            gtk_window_set_transient_for(typed(window), typed(parent.window))
            gtk_window_set_modal(typed(window), o.modal ? 1 : 0)
            gtk_window_set_destroy_with_parent(typed(window), 1)
        }
        runway_window_set_child(window, makeFloatingControls(over: canvas.outer))

        // Resizes arrive mid-allocation; handle them on the next turn.
        let resize = ResizeBox { [weak self] w, h in
            guard let self else { return }
            let s = CGSize(width: CGFloat(w), height: CGFloat(h))
            guard s != self.contentSize else { return }
            self.contentSize = s
            backend.schedule { [weak self] in self?.onResize?(s) }
        }
        resizeBox = resize
        runway_canvas_set_resize_callback(canvas.outer, { w, h, data in
            guard let data else { return }
            Unmanaged<ResizeBox>.fromOpaque(data).takeUnretainedValue().f(Int(w), Int(h))
        }, Unmanaged.passUnretained(resize).toOpaque())

        let close = Handler { [weak self] _ in self?.requestClose() }
        handlers.append(close)
        _ = runway_connect(raw(window), "close-request", unsafeBitCast(closeRequestCallback, to: GCallback.self), Unmanaged.passUnretained(close).toOpaque())

        let keys = KeyHandlerBox { [weak self] key in self?.onKey?(key) ?? false }
        keyHandler = keys
        let controller = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        _ = runway_connect(UnsafeMutableRawPointer(controller), "key-pressed", unsafeBitCast(keyCallback, to: GCallback.self), Unmanaged.passUnretained(keys).toOpaque())
        gtk_widget_add_controller(window, controller)
    }

    private var resizeBox: ResizeBox?

    func requestClose() {
        if onCloseRequest?() ?? true { close() }
    }

    /// The size the window opens at (and is resized to) is the window's
    /// default size; the content's minimum is only the window's minimum,
    /// so users can still make it smaller than it opened.
    func setContentSize(_ size: CGSize) {
        contentSize = size
        var titlebarHeight: Int32 = 0
        if let titlebar, gtk_widget_get_visible(titlebar) != 0 {
            var nat: Int32 = 0
            gtk_widget_measure(titlebar, GTK_ORIENTATION_VERTICAL, Int32(size.width), &titlebarHeight, &nat, nil, nil)
        }
        // The default size counts the titlebar row (the content goes under it).
        gtk_window_set_default_size(typed(window), Int32(size.width), Int32(size.height) + titlebarHeight)
        runway_canvas_set_content_size((content as! GtkBox).outer, Int32(size.width), Int32(size.height))
    }
    func setMinimumSize(_ size: CGSize) {
        runway_canvas_set_min_size((content as! GtkBox).outer, Int32(size.width), Int32(size.height))
    }
    func setResizable(_ resizable: Bool) { gtk_window_set_resizable(typed(window), resizable ? 1 : 0) }
    func show() { gtk_window_present(typed(window)) }
    func showWithoutActivating() {
        // Mapped, not presented: presenting gives it the keyboard focus.
        if gtk_widget_get_visible(window) == 0 { gtk_widget_set_visible(window, 1) }
    }
    func center() {}
    func close() {
        guard !closed else { return }
        closed = true
        onClosed?()
        gtk_window_destroy(typed(window))
        GTKBackend.current?.windowClosed(self)
    }
}

final class ResizeBox {
    let f: (Int, Int) -> Void
    init(_ f: @escaping (Int, Int) -> Void) { self.f = f }
}

final class KeyHandlerBox {
    let f: (KeyPress) -> Bool
    init(_ f: @escaping (KeyPress) -> Bool) { self.f = f }
}

private let closeRequestCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> gboolean = { _, data in
    guard let data else { return 0 }
    Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue().fire(nil)
    return 1   // we destroy the window ourselves when allowed
}

private let keyCallback: @convention(c) (UnsafeMutableRawPointer?, guint, guint, GdkModifierType, UnsafeMutableRawPointer?) -> gboolean = { _, keyval, _, state, data in
    guard let data else { return 0 }
    let box = Unmanaged<KeyHandlerBox>.fromOpaque(data).takeUnretainedValue()
    guard let cname = gdk_keyval_name(gdk_keyval_to_lower(keyval)) else { return 0 }
    var name = String(cString: cname).lowercased()
    switch name {
    case "return", "kp_enter": name = "return"
    case "escape": name = "escape"
    case "backspace": name = "backspace"
    case "comma": name = ","
    case "period": name = "."
    case "slash": name = "/"
    case "space": name = "space"
    default: break
    }
    let s = state.rawValue
    let key = KeyPress(key: name,
                       command: s & GDK_CONTROL_MASK.rawValue != 0,
                       shift: s & GDK_SHIFT_MASK.rawValue != 0,
                       option: s & GDK_ALT_MASK.rawValue != 0,
                       control: false)
    return MainActor.assumeIsolated { box.f(key) } ? 1 : 0
}

final class WorkBox {
    let work: @MainActor () -> Void
    init(_ w: @escaping @MainActor () -> Void) { work = w }
}

@MainActor public final class GTKBackend: Backend {
    public let name = "gtk4"
    public var onColorSchemeChange: (() -> Void)?
    public private(set) var colorScheme: ColorSchemeValue = .light
    public lazy var services: PlatformServices = GTKServices(backend: self)
    static weak var current: GTKBackend?
    private var loop: OpaquePointer?
    private var windows: [GtkNativeWindow] = []
    private var cssProvider: UnsafeMutablePointer<GtkCssProvider>?
    private var colorRules: [String: String] = [:]

    public init() {
        gtk_init()
        colorScheme = runway_prefers_dark() != 0 ? .dark : .light
        if colorScheme == .dark, let s = gtk_settings_get_default() {
            var v = GValue()
            g_value_init(&v, GType(5 << 2))   // G_TYPE_BOOLEAN
            g_value_set_boolean(&v, 1)
            g_object_set_property(UnsafeMutablePointer<GObject>(s), "gtk-application-prefer-dark-theme", &v)
            g_value_unset(&v)
        }
        let env = ProcessInfo.processInfo.environment
        let nativeFont = mobilePreview ? mobileFont.useToolkitFont : env["RUNWAY_NATIVE_FONT"] != nil
        if !nativeFont, macLook || mobilePreview {
            // Detached measuring widgets inherit the same family as native controls.
            runway_settings_set_string("gtk-font-name", systemFontFamilies.joined(separator: ",") + " 10")
        }
        if macLook {
            runway_settings_set_string("gtk-decoration-layout", "close,minimize,maximize:")
        }
        let dark = colorScheme == .dark
        let controls = mobilePreview && macLook ? MacTheme.mobileControlCSS(dark: dark) : ""
        runway_install_css(Self.css(nativeFont: nativeFont, dark: dark, macLook: macLook, families: systemFontFamilies) + controls)
        Self.current = self
    }

    /// Whether controls take the Mac look (MacTheme) or the desktop's own
    /// theme (RUNWAY_NATIVE_LOOK).
    let macLook = ProcessInfo.processInfo.environment["RUNWAY_NATIVE_LOOK"] == nil
    private let mobilePreview = ["iphone-pro", "iphone", "ipad"].contains(ProcessInfo.processInfo.environment["RUNWAY_PREVIEW_DEVICE"] ?? "")
    private let mobileFont = MobileSystemFont()
    private var systemFontFamilies: [String] { mobilePreview ? mobileFont.candidates + ["sans-serif"] : MacTheme.fontFamilies }

    /// The Mac look and metrics (13 px text) unless RUNWAY_NATIVE_LOOK /
    /// RUNWAY_NATIVE_FONT are set, so apps designed on the Mac keep their
    /// appearance and proportions.
    static func css(nativeFont: Bool, dark: Bool = false, macLook: Bool = true, families: [String]? = nil) -> String {
        macLook ? MacTheme.css(dark: dark, nativeFont: nativeFont, families: families) : MacTheme.nativeCSS(nativeFont: nativeFont)
    }

    // MARK: Widgets

    public func makeWidget(_ kind: WidgetKind) -> NativeWidget {
        switch kind {
        case .container:
            let c = runway_canvas_new()!
            let b = GtkBox(kind: kind, outer: c)
            b.canvas = c
            return b
        case let .scroll(h, v):
            let s = gtk_scrolled_window_new()!
            gtk_scrolled_window_set_policy(opaque(s), h ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER, v ? GTK_POLICY_AUTOMATIC : GTK_POLICY_NEVER)
            let doc = runway_canvas_new()!
            gtk_scrolled_window_set_child(opaque(s), doc)
            let b = GtkBox(kind: kind, outer: s)
            b.canvas = doc
            b.setClass("rw-scroll", true)
            return b
        case .text:
            let l = gtk_label_new(nil)!
            gtk_label_set_xalign(opaque(l), 0)
            gtk_label_set_yalign(opaque(l), 0.5)
            return GtkBox(kind: kind, outer: l)
        case .button:
            let btn = gtk_button_new()!
            let b = GtkBox(kind: kind, outer: btn)
            b.connect(raw(btn), "clicked") { [unowned b] _ in b.events.onTap?() }
            return b
        case .tapArea:
            let c = runway_canvas_new()!
            let b = GtkBox(kind: kind, outer: c)
            b.canvas = c
            runway_widget_set_interactive(c, 1)
            b.onClick { [unowned b] point in
                guard b.props.enabled else { return }
                if let action = b.events.onTapLocation { action(point) }
                else { b.events.onTap?() }
            }
            gtk_widget_set_cursor_from_name(c, "pointer")
            return b
        case let .toggle(k):
            switch k {
            case .switch:
                let s = gtk_switch_new()!
                gtk_widget_set_valign(s, GTK_ALIGN_CENTER)
                let b = GtkBox(kind: kind, outer: s)
                b.connect(raw(s), "notify::active", arity: 1) { [unowned b] _ in
                    guard !b.updating else { return }
                    b.events.onToggle?(gtk_switch_get_active(opaque(s)) != 0)
                }
                return b
            case .checkbox:
                let c = gtk_check_button_new()!
                let b = GtkBox(kind: kind, outer: c)
                b.connect(raw(c), "toggled") { [unowned b] _ in
                    guard !b.updating else { return }
                    b.events.onToggle?(gtk_check_button_get_active(typed(c)) != 0)
                }
                return b
            case .button:
                let t = gtk_toggle_button_new()!
                let b = GtkBox(kind: kind, outer: t)
                b.connect(raw(t), "toggled") { [unowned b] _ in
                    guard !b.updating else { return }
                    b.events.onToggle?(gtk_toggle_button_get_active(typed(t)) != 0)
                }
                return b
            }
        case let .textField(secure):
            let e = gtk_entry_new()!
            if secure { gtk_entry_set_visibility(typed(e), 0) }
            let b = GtkBox(kind: kind, outer: e)
            b.connect(raw(e), "changed") { [unowned b] _ in
                guard !b.updating else { return }
                b.events.onText?(String(cString: gtk_editable_get_text(opaque(e))))
            }
            b.connect(raw(e), "activate") { [unowned b] _ in b.events.onSubmit?() }
            return b
        case .textEditor:
            let s = gtk_scrolled_window_new()!
            let tv = gtk_text_view_new()!
            gtk_text_view_set_wrap_mode(typed(tv), GTK_WRAP_WORD_CHAR)
            gtk_scrolled_window_set_child(opaque(s), tv)
            gtk_text_view_set_left_margin(typed(tv), 4)
            gtk_text_view_set_right_margin(typed(tv), 4)
            gtk_text_view_set_top_margin(typed(tv), 2)
            let b = GtkBox(kind: kind, outer: s)
            b.setClass("rw-editor", true)
            // The box holds its own reference to `inner` (released in destroy).
            g_object_ref(raw(tv))
            b.inner = tv
            let buffer = gtk_text_view_get_buffer(typed(tv))!
            b.connect(UnsafeMutableRawPointer(buffer), "changed") { [unowned b] _ in
                guard !b.updating else { return }
                var start = GtkTextIter(), end = GtkTextIter()
                gtk_text_buffer_get_bounds(buffer, &start, &end)
                let c = gtk_text_buffer_get_text(buffer, &start, &end, 0)!
                b.events.onText?(String(cString: c))
                g_free(c)
            }
            b.connect(UnsafeMutableRawPointer(buffer), "notify::cursor-position", arity: 1) { [unowned b] _ in
                guard !b.updating, let report = b.events.onSelection else { return }
                var start = GtkTextIter(), end = GtkTextIter()
                gtk_text_buffer_get_selection_bounds(buffer, &start, &end)
                let a = Int(gtk_text_iter_get_offset(&start)), z = Int(gtk_text_iter_get_offset(&end))
                report(min(a, z)..<max(a, z))
            }
            return b
        case .slider:
            let s = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 1, 0.001)!
            gtk_scale_set_draw_value(typed(s), 0)
            let b = GtkBox(kind: kind, outer: s)
            b.connect(raw(s), "value-changed") { [unowned b] _ in
                guard !b.updating else { return }
                b.events.onNumber?(gtk_range_get_value(typed(s)))
            }
            return b
        case .stepper:
            // The Mac's stepper: a pair of arrows, the value shown by the
            // label beside it.
            let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
            gtk_widget_set_valign(box, GTK_ALIGN_CENTER)
            gtk_widget_set_halign(box, GTK_ALIGN_CENTER)
            let b = GtkBox(kind: kind, outer: box)
            b.setClass("rw-stepper", true)
            for i in 0..<2 {
                let arrow = gtk_button_new()!
                gtk_widget_set_focus_on_click(arrow, 0)
                // The Mac look draws the arrows in CSS; the desktop's theme
                // gets its own icons.
                if !macLook { gtk_button_set_icon_name(typed(arrow), i == 0 ? "pan-up-symbolic" : "pan-down-symbolic") }
                gtk_box_append(typed(box), arrow)
                b.segments.append(arrow)
                b.connect(raw(arrow), "clicked") { [unowned b] _ in
                    let p = b.props
                    let step = (p.step ?? 1) * (i == 0 ? 1 : -1)
                    let v = min(max(p.number + step, p.range.lowerBound), p.range.upperBound)
                    if v != p.number { b.events.onNumber?(v) }
                }
            }
            return b
        case .dropdown:
            let d = runway_drop_down_new()!
            if macLook {
                runway_popovers_plain(d)
                runway_drop_down_mac_menu(d)
            }
            let b = GtkBox(kind: kind, outer: d)
            b.setClass("rw-mobile-dropdown", mobilePreview)
            if mobilePreview { runway_popovers_constrain_to_window(d) }
            b.connect(raw(d), "notify::selected", arity: 1) { [unowned b] _ in
                guard !b.updating else { return }
                let i = gtk_drop_down_get_selected(opaque(d))
                if i != UInt32.max { b.events.onSelect?(Int(i)) }
            }
            return b
        case .segmented:
            let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
            let b = GtkBox(kind: kind, outer: box)
            if macLook {
                // Equal segments on a shared track, as NSSegmentedControl.
                gtk_box_set_homogeneous(typed(box), 1)
            } else {
                b.setClass("linked", true)
            }
            b.setClass("rw-segmented", true)
            b.setClass("rw-mobile-segmented", mobilePreview)
            return b
        case let .progress(circular):
            if circular {
                // Not GtkSpinner: its CSS animation ticks the frame clock
                // (and re-lays out the window) every frame; see runway_spinner.c.
                return GtkBox(kind: kind, outer: runway_spinner_new()!)
            }
            let p = gtk_progress_bar_new()!
            gtk_widget_set_valign(p, GTK_ALIGN_CENTER)
            return GtkBox(kind: kind, outer: p)
        case .image:
            let c = runway_canvas_new()!
            let b = GtkBox(kind: kind, outer: c)
            b.canvas = c
            return b
        case .canvas, .divider:
            let d = gtk_drawing_area_new()!
            let b = GtkBox(kind: kind, outer: d)
            gtk_drawing_area_set_draw_func(typed(d), drawCallback, Unmanaged.passUnretained(b).toOpaque(), nil)
            gtk_widget_set_can_target(d, 0)
            return b
        case .link:
            let l = gtk_link_button_new("https://")!
            let b = GtkBox(kind: kind, outer: l)
            b.connectBool(raw(l), "activate-link") { [unowned b] _ in b.events.onTap?() }
            return b
        case .colorWell:
            let dialog = gtk_color_dialog_new()
            let w = gtk_color_dialog_button_new(dialog)!
            let b = GtkBox(kind: kind, outer: w)
            b.connect(raw(w), "notify::rgba", arity: 1) { [unowned b] _ in
                guard !b.updating, let c = gtk_color_dialog_button_get_rgba(opaque(w)) else { return }
                b.events.onColor?(RGBA(Double(c.pointee.red), Double(c.pointee.green), Double(c.pointee.blue), Double(c.pointee.alpha)))
            }
            return b
        case .menuButton:
            let m = gtk_menu_button_new()!
            let b = GtkBox(kind: kind, outer: m)
            b.setClass("rw-mobile-menu", mobilePreview)
            return b
        }
    }

    public func update(_ widget: NativeWidget, props p: WidgetProps, events: WidgetEvents) {
        let b = widget as! GtkBox
        let old = b.props
        b.events = events
        // Display-only widgets whose props didn't change need nothing from
        // GTK (re-renders hand every widget its props again). Controls are
        // always re-applied: a binding may have refused the user's edit.
        if b.configured, old == p, Self.displayOnly(b.kind) { return }
        b.configured = true
        b.updating = true
        defer { b.updating = false }
        let w = b.outer
        if old.enabled != p.enabled || b.props == WidgetProps() { gtk_widget_set_sensitive(w, p.enabled ? 1 : 0) }
        if old.tooltip != p.tooltip { gtk_widget_set_tooltip_text(w, p.tooltip) }
        if old.opacity != p.opacity { gtk_widget_set_opacity(w, p.opacity) }
        b.setClass("rw-small", p.controlSize == .small || p.controlSize == .mini)
        b.setClass("rw-large", p.controlSize == .large || p.controlSize == .extraLarge)

        switch b.kind {
        case .text:
            if let t = p.text { applyText(b, t) }
        case .button:
            b.setClass("rw-capsule-button", p.capsuleButton)
            if p.hasContent {
                if b.canvas == nil {
                    let c = runway_canvas_new()!
                    gtk_button_set_child(typed(w), c)
                    b.canvas = c
                }
                b.setClass("rw-content", true)
            } else if old.title != p.title || b.props == WidgetProps() {
                gtk_button_set_label(typed(w), p.title)
            }
            if macLook {
                b.setClass("rw-default", p.prominent)
                b.setClass("rw-destructive", p.isDestructive)
                applyTint(b, p.prominent ? p.tint : nil)
            } else {
                b.setClass("suggested-action", p.prominent && !p.isDestructive)
                b.setClass("destructive-action", p.isDestructive)
            }
            b.setClass("flat", !p.bordered)
        case .tapArea:
            break
        case let .toggle(k):
            applyTint(b, p.tint)
            switch k {
            case .switch:
                if gtk_switch_get_active(opaque(w)) != (p.isOn ? 1 : 0) { gtk_switch_set_active(opaque(w), p.isOn ? 1 : 0) }
            case .checkbox:
                gtk_check_button_set_label(typed(w), p.title.isEmpty ? nil : p.title)
                if gtk_check_button_get_active(typed(w)) != (p.isOn ? 1 : 0) { gtk_check_button_set_active(typed(w), p.isOn ? 1 : 0) }
            case .button:
                // An image button that stays pressed (a preferences toolbar's
                // selected tab): its content goes in a canvas, as a button's.
                if p.hasContent {
                    if b.canvas == nil {
                        let c = runway_canvas_new()!
                        gtk_button_set_child(typed(w), c)
                        b.canvas = c
                    }
                    b.setClass("rw-content", true)
                } else {
                    gtk_button_set_label(typed(w), p.title)
                }
                b.setClass("flat", !p.bordered)
                if gtk_toggle_button_get_active(typed(w)) != (p.isOn ? 1 : 0) { gtk_toggle_button_set_active(typed(w), p.isOn ? 1 : 0) }
            }
        case .textField:
            let current = String(cString: gtk_editable_get_text(opaque(w)))
            if current != p.string { gtk_editable_set_text(opaque(w), p.string) }
            if old.placeholder != p.placeholder || b.props == WidgetProps() { gtk_entry_set_placeholder_text(typed(w), p.placeholder) }
            gtk_entry_set_has_frame(typed(w), p.bordered ? 1 : 0)
            b.setClass("rw-plain", !p.bordered)
            if old.text != p.text || b.props == WidgetProps() { applyEntryFont(b, p.text?.runs.first) }
        case .textEditor:
            b.setClass("rw-clear-background", p.clearBackground)
            if old.text != p.text { applyEntryFont(b, p.text?.runs.first) }
            if let tv = b.inner, let buffer = gtk_text_view_get_buffer(typed(tv)) {
                var start = GtkTextIter(), end = GtkTextIter()
                gtk_text_buffer_get_bounds(buffer, &start, &end)
                let c = gtk_text_buffer_get_text(buffer, &start, &end, 0)!
                if String(cString: c) != p.string { gtk_text_buffer_set_text(buffer, p.string, -1) }
                g_free(c)
                if let r = p.selection, r != old.selection {
                    var a = GtkTextIter(), z = GtkTextIter()
                    gtk_text_buffer_get_iter_at_offset(buffer, &a, Int32(r.lowerBound))
                    gtk_text_buffer_get_iter_at_offset(buffer, &z, Int32(r.upperBound))
                    gtk_text_buffer_select_range(buffer, &z, &a)
                    gtk_text_view_scroll_mark_onscreen(typed(tv), gtk_text_buffer_get_insert(buffer))
                }
            }
        case .slider:
            applyTint(b, p.tint)
            gtk_range_set_range(typed(w), p.range.lowerBound, max(p.range.upperBound, p.range.lowerBound + 1e-9))
            if let s = p.step { gtk_range_set_increments(typed(w), s, s * 10) }
            if gtk_range_get_value(typed(w)) != p.number { gtk_range_set_value(typed(w), p.number) }
        case .stepper:
            if b.segments.count == 2 {
                gtk_widget_set_sensitive(b.segments[0], p.enabled && p.number < p.range.upperBound ? 1 : 0)
                gtk_widget_set_sensitive(b.segments[1], p.enabled && p.number > p.range.lowerBound ? 1 : 0)
            }
        case .dropdown:
            if b.options != p.options {
                b.options = p.options
                withCStrings(p.options) { runway_drop_down_set_strings(w, $0) }
            }
            let sel = p.selected >= 0 ? UInt32(p.selected) : UInt32.max
            if gtk_drop_down_get_selected(opaque(w)) != sel { gtk_drop_down_set_selected(opaque(w), sel) }
            b.setClass("rw-borderless", !p.bordered)
            if mobilePreview { applyTint(b, p.tint) }
        case .segmented:
            updateSegments(b, p)
            if mobilePreview {
                applyTint(b, p.tint)
                if old.title != p.title { runway_accessible_label(w, p.title) }
            }
        case .progress(let circular):
            applyTint(b, p.tint)
            if !circular {
                if p.indeterminate { gtk_progress_bar_pulse(opaque(w)) } else { gtk_progress_bar_set_fraction(opaque(w), p.number) }
            }
        case .image:
            if old.image != p.image || old.imageSymbolVariant != p.imageSymbolVariant || old.imageTint != p.imageTint
                || old.imagePointSize != p.imagePointSize || b.inner == nil {
                updateImage(b, p)
            }
        case .canvas, .divider:
            if old.hitTestable != p.hitTestable { gtk_widget_set_can_target(w, p.hitTestable ? 1 : 0) }
            if old.backdropBlur != p.backdropBlur {
                runway_widget_set_backdrop_blur(w, Float(p.backdropBlur?.radius ?? 0), Float(p.backdropBlur?.cornerRadius ?? 0))
            }
            gtk_widget_queue_draw(w)
        case .link:
            gtk_button_set_label(typed(w), p.title)
            gtk_button_set_has_frame(typed(w), 0)
        case .colorWell:
            var c = GdkRGBA(red: Float(p.color.r), green: Float(p.color.g), blue: Float(p.color.b), alpha: Float(p.color.a))
            gtk_color_dialog_button_set_rgba(opaque(w), &c)
        case .menuButton:
            if p.hasContent {
                if b.canvas == nil {
                    let canvas = runway_canvas_new()!
                    gtk_menu_button_set_always_show_arrow(opaque(w), 0)
                    gtk_menu_button_set_child(opaque(w), canvas)
                    b.canvas = canvas
                }
                if old.title != p.title { runway_accessible_label(w, p.title) }
            } else if old.hasContent || old.title != p.title || old.image != p.image || old == WidgetProps() {
                b.canvas = nil
                if case let .symbol(s) = p.image, p.title.isEmpty {
                    if let img = symbolArtwork(s, size: 16, builtInSize: 16) {
                        gtk_menu_button_set_child(opaque(w), img)
                    } else {
                        gtk_menu_button_set_icon_name(opaque(w), SymbolMap.iconName(for: s))
                    }
                } else {
                    gtk_menu_button_set_label(opaque(w), p.title)
                }
            }
            gtk_menu_button_set_has_frame(opaque(w), p.bordered ? 1 : 0)
            setMenu(b, events.menu)
            if macLook || mobilePreview { runway_popovers_plain(w) }
            if mobilePreview { runway_popovers_constrain_to_window(w) }
        case .container, .scroll:
            if old.clips != p.clips, let c = b.canvas { runway_canvas_set_clip(c, p.clips ? 1 : 0) }
        }
        b.props = p
    }

    private static func displayOnly(_ k: WidgetKind) -> Bool {
        switch k {
        case .text, .image, .divider, .canvas, .container, .scroll, .tapArea, .button, .link: return true
        default: return false
        }
    }

    private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let dup = strings.map { strdup($0) }
        defer { dup.forEach { free($0) } }
        var ptrs: [UnsafePointer<CChar>?] = dup.map { UnsafePointer($0) }
        ptrs.append(nil)
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    // MARK: Text

    static func markup(_ t: StyledText) -> String {
        var out = ""
        for run in t.runs {
            let f = run.font
            var desc: [String] = []
            switch f.design {
            case .monospaced: desc.append("Monospace")
            case .serif: desc.append("Serif")
            default: if let fam = f.family { desc.append(fam) }
            }
            switch f.weight {
            case .ultraLight: desc.append("Ultra-Light")
            case .thin: desc.append("Thin")
            case .light: desc.append("Light")
            case .medium: desc.append("Medium")
            case .semibold: desc.append("Semi-Bold")
            case .bold: desc.append("Bold")
            case .heavy: desc.append("Heavy")
            case .black: desc.append("Ultra-Heavy")
            case .regular: break
            }
            if f.italic { desc.append("Italic") }
            desc.append("\(Int(f.size.rounded()))px")
            let escapedDescription = g_markup_escape_text(desc.joined(separator: " "), -1)!
            var attrs = "font_desc=\"\(String(cString: escapedDescription))\""
            g_free(escapedDescription)
            if let c = run.color {
                attrs += " foreground=\"\(String(c.hexString.prefix(7)))\" alpha=\"\(max(1, Int((c.a * 100).rounded())))%\""
            }
            if f.monospacedDigit { attrs += " font_features=\"tnum\"" }
            if t.lineSpacing > 0, t.lineLimit != 1 {
                // An absolute line height (Pango units), as AppKit adds spacing below each line.
                attrs += " line_height=\"\(Int(((f.size * 1.2 + t.lineSpacing) * CGFloat(PANGO_SCALE)).rounded()))\""
            }
            if run.underline { attrs += " underline=\"single\"" }
            if run.strikethrough { attrs += " strikethrough=\"true\"" }
            if run.tracking.isFinite, run.tracking != 0 {
                let units = run.tracking * CGFloat(PANGO_SCALE)
                let tracking = Int32(max(CGFloat(Int32.min), min(CGFloat(Int32.max), units.rounded())))
                attrs += " letter_spacing=\"\(tracking)\""
            }
            if let bg = run.background {
                attrs += " background=\"\(String(bg.hexString.prefix(7)))\" bgalpha=\"\(max(1, Int((bg.a * 100).rounded())))%\""
            }
            let escaped = g_markup_escape_text(run.string, -1)!
            var span = "<span \(attrs)>\(String(cString: escaped))</span>"
            g_free(escaped)
            if let link = run.link {
                let href = g_markup_escape_text(link, -1)!
                span = "<a href=\"\(String(cString: href))\">\(span)</a>"
                g_free(href)
            }
            out += span
        }
        return out
    }

    private func applyText(_ b: GtkBox, _ t: StyledText) {
        let l = opaque(b.outer)
        let m = Self.markup(t)
        if m != b.markup {
            gtk_label_set_markup(l, m)
            b.markup = m
        }
        let x: Float = t.alignment == .center ? 0.5 : t.alignment == .trailing ? 1 : 0
        gtk_label_set_xalign(l, x)
        if (gtk_label_get_selectable(l) != 0) != t.selectable {
            gtk_label_set_selectable(l, t.selectable ? 1 : 0)
            // Selecting shouldn't put a focus ring on every label clicked.
            if t.selectable { gtk_widget_set_focus_on_click(b.outer, 0) }
        }
        gtk_label_set_justify(l, t.alignment == .center ? GTK_JUSTIFY_CENTER : t.alignment == .trailing ? GTK_JUSTIFY_RIGHT : GTK_JUSTIFY_LEFT)
        let ell: PangoEllipsizeMode = t.truncation == .head ? PANGO_ELLIPSIZE_START : t.truncation == .middle ? PANGO_ELLIPSIZE_MIDDLE : PANGO_ELLIPSIZE_END
        if t.lineLimit == 1 {
            gtk_label_set_wrap(l, 0)
            gtk_label_set_ellipsize(l, ell)
            gtk_label_set_lines(l, -1)
        } else {
            gtk_label_set_wrap(l, 1)
            gtk_label_set_wrap_mode(l, PANGO_WRAP_WORD_CHAR)
            gtk_label_set_lines(l, Int32(t.lineLimit ?? -1))
            gtk_label_set_ellipsize(l, t.lineLimit == nil ? PANGO_ELLIPSIZE_NONE : ell)
        }
    }

    // MARK: Segmented controls

    private func updateSegments(_ b: GtkBox, _ p: WidgetProps) {
        if b.options != p.options {
            for s in b.segments { gtk_box_remove(typed(b.outer), s) }
            b.segments.removeAll()
            b.options = p.options
            var first: GW?
            for (i, title) in p.options.enumerated() {
                let t = gtk_toggle_button_new_with_label(title)!
                if let f = first { gtk_toggle_button_set_group(typed(t), typed(f)) } else { first = t }
                b.connect(raw(t), "toggled") { [unowned b] _ in
                    guard !b.updating, gtk_toggle_button_get_active(typed(t)) != 0 else { return }
                    b.events.onSelect?(i)
                }
                gtk_box_append(typed(b.outer), t)
                b.segments.append(t)
            }
        }
        for (i, s) in b.segments.enumerated() {
            let on: gboolean = i == p.selected ? 1 : 0
            if gtk_toggle_button_get_active(typed(s)) != on { gtk_toggle_button_set_active(typed(s), on) }
        }
    }

    // MARK: Images

    private func symbolArtwork(_ name: String, size: Int32, builtInSize: Int32, variant: String? = nil) -> GW? {
        let names = variant.map { [$0, name] } ?? [name]
        for candidate in names {
            if let svg = SymbolArt.overrideSVG(candidate), let image = runway_symbol_template_image(svg, size) { return image }
        }
        for candidate in names {
            if let svg = SymbolArt.svg(candidate) { return runway_symbol_image(svg, builtInSize) }
        }
        return nil
    }

    private func updateImage(_ b: GtkBox, _ p: WidgetProps) {
        if let old = b.inner { runway_canvas_remove(b.outer, old); g_object_unref(raw(old)); b.inner = nil }
        b.textureSize = nil
        let child: GW
        switch p.image {
        case let .symbol(name):
            let img: GW
            // Runway's built-in art has margins on its 24-point grid.
            if let artwork = symbolArtwork(name, size: Int32(p.imagePointSize.rounded()),
                                           builtInSize: Int32((p.imagePointSize * 1.25).rounded()),
                                           variant: p.imageSymbolVariant) {
                img = artwork
            } else {
                img = gtk_image_new_from_icon_name(SymbolMap.iconName(for: name))!
                gtk_image_set_pixel_size(opaque(img), Int32((p.imagePointSize * 1.1).rounded()))
            }
            if let tint = p.imageTint { applyColor(img, tint) }
            child = img
        case let .file(path):
            let pic = gtk_picture_new_for_filename(path)!
            gtk_picture_set_content_fit(opaque(pic), GTK_CONTENT_FIT_FILL)
            if let paintable = gtk_picture_get_paintable(opaque(pic)) {
                b.textureSize = CGSize(width: Int(gdk_paintable_get_intrinsic_width(paintable)), height: Int(gdk_paintable_get_intrinsic_height(paintable)))
            }
            child = pic
        case let .pixels(w, h, rgba):
            let bytes = rgba.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
            let tex = gdk_memory_texture_new(Int32(w), Int32(h), GDK_MEMORY_R8G8B8A8, bytes, gsize(w * 4))
            g_bytes_unref(bytes)
            let pic = gtk_picture_new_for_paintable(tex)!
            gtk_picture_set_content_fit(opaque(pic), GTK_CONTENT_FIT_FILL)
            g_object_unref(UnsafeMutableRawPointer(tex))
            b.textureSize = CGSize(width: w, height: h)
            child = pic
        case .none:
            child = gtk_image_new()!
        }
        g_object_ref_sink(raw(child))
        b.inner = child
        runway_canvas_place(b.outer, child, 0, 0, Int32(b.size.width), Int32(b.size.height))
    }

    /// Colours symbolic icons (and anything CSS `color` reaches) via a
    /// shared stylesheet of generated classes.
    func applyColor(_ w: GW, _ c: RGBA) {
        let name = "rw-c-" + String(c.hexString.dropFirst())
        if colorRules[name] == nil {
            colorRules[name] = ".\(name) { color: rgba(\(Int(c.r * 255)), \(Int(c.g * 255)), \(Int(c.b * 255)), \(c.a)); }"
            loadColorRules()
        }
        runway_widget_add_css(w, name)
    }

    /// Tints a control's accent parts (a prominent button's fill, a
    /// switch's or checkbox's on state, a slider's or progress bar's fill)
    /// through generated classes in the shared colour stylesheet.
    func applyTint(_ b: GtkBox, _ c: RGBA?) {
        guard macLook else { return }
        let name = c.map { "rw-tint-" + String($0.hexString.dropFirst()) }
        for old in b.cssClasses where old.hasPrefix("rw-tint-") && old != name { b.setClass(old, false) }
        guard let c, let name else { return }
        if colorRules[name] == nil {
            let col = "rgba(\(Int(c.r * 255)), \(Int(c.g * 255)), \(Int(c.b * 255)), \(c.a))"
            colorRules[name] = """
            button.\(name).rw-default, switch.\(name):checked, checkbutton.\(name) > check:checked,
            scale.\(name) > trough > highlight, progressbar.\(name) > trough > progress { background-color: \(col); }
            box.rw-mobile-segmented.\(name) > button:checked, dropdown.rw-mobile-dropdown.\(name) > button { color: \(col); }
            """
            loadColorRules()
        }
        b.setClass(name, true)
    }

    /// An entry's font and text colour (an NSTextField's `font` and
    /// `textColor`), as a generated class; the placeholder takes the font.
    func applyEntryFont(_ b: GtkBox, _ run: TextRun?) {
        let name = run.map { r -> String in
            var h = Hasher()
            h.combine(r.font)
            h.combine(r.color)
            return "rw-ef-" + String(UInt(bitPattern: h.finalize()), radix: 36)
        }
        for old in b.cssClasses where old.hasPrefix("rw-ef-") && old != name { b.setClass(old, false) }
        guard let run, let name else { return }
        if colorRules[name] == nil {
            let f = run.font
            let family = f.design == .monospaced ? "monospace" : f.design == .serif ? "serif"
                : MacTheme.fontFamilyCSS(f.family.map { [$0] } ?? systemFontFamilies)
            let weight: Int = switch f.weight {
            case .ultraLight: 100
            case .thin: 200
            case .light: 300
            case .regular: 400
            case .medium: 500
            case .semibold: 600
            case .bold: 700
            case .heavy: 800
            case .black: 900
            }
            let font = "font-family: \(family); font-size: \(f.size)px; font-weight: \(weight); font-style: \(f.italic ? "italic" : "normal");"
            let color = run.color.map { c in "color: rgba(\(Int(c.r * 255)), \(Int(c.g * 255)), \(Int(c.b * 255)), \(c.a));" } ?? ""
            colorRules[name] = """
            entry.\(name), entry.\(name) > text { \(font) \(color) }
            entry.\(name) > text > placeholder { \(font) }
            scrolledwindow.\(name) textview, scrolledwindow.\(name) textview > text { \(font) \(color) }
            """
            loadColorRules()
        }
        b.setClass(name, true)
    }

    private func loadColorRules() {
        if cssProvider == nil {
            cssProvider = gtk_css_provider_new()
            gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(cssProvider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1))
        }
        gtk_css_provider_load_from_string(cssProvider, colorRules.values.sorted().joined(separator: "\n"))
    }

    // MARK: Menus

    private func setMenu(_ b: GtkBox, _ items: [MenuItemSpec]) {
        var titles: [String] = [], kinds: [Int32] = [], depths: [Int32] = [], enabled: [gboolean] = [], checked: [gboolean] = []
        var flat: [MenuItemSpec] = []
        func walk(_ list: [MenuItemSpec], _ depth: Int32) {
            for i in list {
                titles.append(i.title)
                depths.append(depth)
                enabled.append(i.enabled ? 1 : 0)
                checked.append(i.checked ? 1 : 0)
                flat.append(i)
                if i.isSeparator { kinds.append(1) } else if !i.children.isEmpty {
                    kinds.append(2)
                    walk(i.children, depth + 1)
                } else { kinds.append(0) }
            }
        }
        walk(items, 0)
        // Keep an open menu mounted across renders that only replace actions.
        let previous = b.menuItems
        b.menuItems = flat
        if b.menuModelInstalled, previous.elementsEqual(flat, by: { old, new in
            old.title == new.title && old.enabled == new.enabled && old.checked == new.checked &&
                old.isSeparator == new.isSeparator && old.children.count == new.children.count
        }) { return }
        b.menuModelInstalled = true
        let box = Unmanaged.passUnretained(b).toOpaque()
        withCStrings(titles) { t in
            runway_menu_button_set(b.outer, t, kinds, depths, enabled, checked, Int32(flat.count), { index, data in
                guard let data else { return }
                let b = Unmanaged<GtkBox>.fromOpaque(data).takeUnretainedValue()
                MainActor.assumeIsolated {
                    let i = Int(index)
                    if b.menuItems.indices.contains(i) { b.menuItems[i].action?() }
                }
            }, box)
        }
    }

    // MARK: Measuring and placing

    public func measure(_ widget: NativeWidget, proposal: ProposedSize) -> CGSize {
        let b = widget as! GtkBox
        let w = b.outer
        var minW: Int32 = 0, natW: Int32 = 0, minH: Int32 = 0, natH: Int32 = 0
        switch b.kind {
        case .image:
            if let t = b.textureSize { return t }
            let s = (b.props.imagePointSize * 1.1).rounded()
            return CGSize(width: s, height: s)
        case .canvas, .container, .scroll, .tapArea:
            return proposal.replacingUnspecified(by: CGSize(width: 10, height: 10))
        case .divider:
            return CGSize(width: 1, height: 1)
        default:
            break
        }
        gtk_widget_measure(w, GTK_ORIENTATION_HORIZONTAL, -1, &minW, &natW, nil, nil)
        var width = CGFloat(natW)
        if b.kind == .dropdown {
            // GTK sizes the selected row lazily; size for the longest option
            // (a pop-up button keeps its width), or for the value shown when
            // borderless (it sits beside its chevrons, as in Mac forms).
            let borderless = macLook && !b.props.bordered
            let shown = borderless && b.options.indices.contains(b.props.selected) ? [b.options[b.props.selected]] : b.options
            let longest = shown.map { textWidth($0) }.max() ?? 0
            let chrome: CGFloat = !macLook ? 46 : borderless ? 26 : 38
            width = max(CGFloat(minW), longest + chrome)
        }
        if b.kind == .text {
            // Pango includes trailing letter spacing when deciding whether a line wraps,
            // though GTK's natural-width measurement omits that spacing.
            let tracking = b.props.text?.runs.map(\.tracking).filter { $0.isFinite && $0 > 0 }.max() ?? 0
            width += min(tracking.rounded(.up), CGFloat(Int32.max) - width)
            if let pw = proposal.width, pw < width { width = max(CGFloat(minW), pw.rounded(.down)) }
        }
        gtk_widget_measure(w, GTK_ORIENTATION_VERTICAL, Int32(width), &minH, &natH, nil, nil)
        return CGSize(width: width, height: CGFloat(natH))
    }

    private var scratchLabel: GW?
    private var textWidths: [String: CGFloat] = [:]

    /// A string's width in the default UI font.
    func textWidth(_ text: String) -> CGFloat {
        if let w = textWidths[text] { return w }
        if scratchLabel == nil {
            let l = gtk_label_new(nil)!
            g_object_ref_sink(raw(l))
            scratchLabel = l
        }
        let l = scratchLabel!
        gtk_label_set_markup(opaque(l), Self.markup(StyledText(runs: [TextRun(string: text, font: FontSpec(), color: nil)])))
        var minW: Int32 = 0, natW: Int32 = 0
        gtk_widget_measure(l, GTK_ORIENTATION_HORIZONTAL, -1, &minW, &natW, nil, nil)
        textWidths[text] = CGFloat(natW)
        return CGFloat(natW)
    }

    public func contentInsets(_ widget: NativeWidget) -> EdgeInsetsValue {
        let b = widget as! GtkBox
        if b.kind == .menuButton, b.canvas != nil {
            return EdgeInsetsValue(top: 0, leading: 10, bottom: 0, trailing: 10)
        }
        guard b.kind == .button || b.kind == .toggle(.button), let c = b.canvas else { return .zero }
        // The chrome is the button's size around an empty label area.
        runway_canvas_set_content_size(c, 0, 0)
        var minW: Int32 = 0, natW: Int32 = 0, minH: Int32 = 0, natH: Int32 = 0
        gtk_widget_measure(b.outer, GTK_ORIENTATION_HORIZONTAL, -1, &minW, &natW, nil, nil)
        gtk_widget_measure(b.outer, GTK_ORIENTATION_VERTICAL, -1, &minH, &natH, nil, nil)
        let h = CGFloat(natW) / 2, v = CGFloat(natH) / 2
        return EdgeInsetsValue(top: v, leading: h, bottom: v, trailing: h)
    }

    /// The button's padding and border alone: where GTK puts its child
    /// (the whole content box), unlike `contentInsets`, which also counts
    /// the button's minimum size.
    public func labelAreaInsets(_ widget: NativeWidget) -> EdgeInsetsValue {
        let b = widget as! GtkBox
        guard b.kind == .button || b.kind == .toggle(.button), let c = b.canvas else { return .zero }
        let big: Int32 = 400
        runway_canvas_set_content_size(c, big, big)
        var minW: Int32 = 0, natW: Int32 = 0, minH: Int32 = 0, natH: Int32 = 0
        gtk_widget_measure(b.outer, GTK_ORIENTATION_HORIZONTAL, -1, &minW, &natW, nil, nil)
        gtk_widget_measure(b.outer, GTK_ORIENTATION_VERTICAL, -1, &minH, &natH, nil, nil)
        let h = CGFloat(max(0, natW - big)) / 2, v = CGFloat(max(0, natH - big)) / 2
        return EdgeInsetsValue(top: v, leading: h, bottom: v, trailing: h)
    }

    public func childContainer(_ widget: NativeWidget) -> NativeWidget {
        let b = widget as! GtkBox
        guard let c = b.canvas, c != b.outer else { return b }
        return CanvasRef.wrap(c, owner: b)
    }

    public func setChildren(_ container: NativeWidget, _ children: [(NativeWidget, CGRect)], contentSize: CGSize) {
        let canvas: GW
        if let ref = container as? CanvasRef { canvas = ref.canvas } else {
            let b = container as! GtkBox
            guard let c = b.canvas else { return }
            canvas = c
        }
        runway_canvas_set_content_size(canvas, Int32(contentSize.width.isFinite ? contentSize.width : 0), Int32(contentSize.height.isFinite ? contentSize.height : 0))
        var keep = Set<UnsafeMutableRawPointer>()
        for (child, f) in children {
            let b = child as! GtkBox
            keep.insert(raw(b.outer))
            // A null or infinite frame (a view laid out before it has room) places nothing visible.
            let frame = f.isNull || f.isInfinite || !f.minX.isFinite || !f.minY.isFinite || !f.width.isFinite || !f.height.isFinite ? .zero : f
            b.size = frame.size
            runway_canvas_place(canvas, b.outer, Int32(frame.minX), Int32(frame.minY), Int32(frame.width), Int32(frame.height))
            runway_canvas_raise(canvas, b.outer)
            if let inner = b.inner, b.kind == .image {
                runway_canvas_place(b.outer, inner, 0, 0, Int32(frame.width), Int32(frame.height))
            }
            if b.kind == .button || b.kind == .toggle(.button), let c = b.canvas {
                let ins = contentInsets(b)
                runway_canvas_set_content_size(c, Int32(max(0, frame.width - ins.leading - ins.trailing)), Int32(max(0, frame.height - ins.top - ins.bottom)))
            }
        }
        // Remove children no longer placed here.
        var c = gtk_widget_get_first_child(canvas)
        while let w = c {
            c = gtk_widget_get_next_sibling(w)
            // Popovers (NSPopover) belong to the canvas but aren't placed children.
            if !keep.contains(raw(w)), runway_is_popover(w) == 0 { runway_canvas_remove(canvas, w) }
        }
    }

    public func destroy(_ widget: NativeWidget) {
        let b = widget as! GtkBox
        if let p = gtk_widget_get_parent(b.outer) {
            if gtk_widget_get_parent(p) != nil || true { runway_canvas_remove(p, b.outer) }
        }
        if let i = b.inner { g_object_unref(raw(i)) }
        b.inner = nil
        g_object_unref(raw(b.outer))
    }

    // MARK: Windows and the loop

    public func makeWindow(_ options: WindowOptions, parent: NativeWindow?) -> NativeWindow {
        let w = GtkNativeWindow(options, parent: parent as? GtkNativeWindow, backend: self)
        windows.append(w)
        return w
    }

    func windowClosed(_ w: GtkNativeWindow) { windows.removeAll { $0 === w } }

    var activeWindow: GW? { windows.last?.window }

    public func run(_ start: @escaping @MainActor () -> Void) {
        loop = g_main_loop_new(nil, 0)
        schedule(start)
        // RUNWAY_SCREENSHOT=path.png: render every window to PNGs once the
        // UI has settled, then quit (CI and docs).
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["RUNWAY_SCREENSHOT"] {
            let delay = environment["RUNWAY_SCREENSHOT_DELAY"].flatMap(UInt32.init) ?? 1500
            let scale = environment["RUNWAY_SCREENSHOT_SCALE"].flatMap(UInt32.init).flatMap { (1...4).contains($0) ? $0 : nil } ?? 1
            let mobilePreview = self.mobilePreview
            // RUNWAY_SCREENSHOT_POPUP=n: also open the window's nth pop-up or
            // pull-down button and save its menu (path-menu.png).
            var popover: GW?
            if let n = environment["RUNWAY_SCREENSHOT_POPUP"].flatMap(Int32.init) {
                let open = WorkBox { [weak self] in
                    if let w = self?.windows.first { popover = runway_debug_popup(w.window, n) }
                }
                runway_timeout(delay / 2, { data in
                    guard let data else { return }
                    let b = Unmanaged<WorkBox>.fromOpaque(data).takeRetainedValue()
                    MainActor.assumeIsolated { b.work() }
                }, Unmanaged.passRetained(open).toOpaque())
            }
            let box = WorkBox { [weak self] in
                guard let self else { return }
                for (i, w) in self.windows.enumerated() {
                    let out = i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png")
                    let content = mobilePreview ? (w.content as? GtkBox)?.outer : nil
                    let ok = runway_widget_save_scaled_png(w.window, content, out, scale) != 0
                    FileHandle.standardError.write(Data("runway: \(ok ? "saved" : "could not save") \(out) (\(w.title))\n".utf8))
                }
                if let popover {
                    let out = path.replacingOccurrences(of: ".png", with: "-menu.png")
                    let ok = runway_widget_save_scaled_png(popover, nil, out, scale) != 0
                    FileHandle.standardError.write(Data("runway: \(ok ? "saved" : "could not save") \(out) (menu)\n".utf8))
                }
                self.quit()
            }
            runway_timeout(delay, { data in
                guard let data else { return }
                let b = Unmanaged<WorkBox>.fromOpaque(data).takeRetainedValue()
                MainActor.assumeIsolated { b.work() }
            }, Unmanaged.passRetained(box).toOpaque())
        }
        // DispatchQueue.main / MainActor and RunLoop.main timers run here too.
        runway_loop_attach({ _ in
            guard let next = RunLoop.main.limitDate(forMode: .default) else { return -1 }
            let ms = next.timeIntervalSinceNow * 1000
            if ms > 86_400_000 { return -1 }
            return Int32(max(0, ms.rounded(.up)))
        }, nil)
        g_main_loop_run(loop)
    }

    public func quit() {
        for w in windows { w.close() }
        if let loop { g_main_loop_quit(loop) }
    }

    public func schedule(_ work: @escaping @MainActor () -> Void) {
        let box = WorkBox(work)
        runway_idle({ data in
            guard let data else { return }
            let b = Unmanaged<WorkBox>.fromOpaque(data).takeRetainedValue()
            MainActor.assumeIsolated { b.work() }
        }, Unmanaged.passRetained(box).toOpaque())
    }

    /// Runs the loop until `done` (tests and screenshots).
    public func iterate(until done: () -> Bool, timeout: TimeInterval = 5) {
        let end = Date().addingTimeInterval(timeout)
        while !done(), Date() < end { g_main_context_iteration(nil, 0) ; usleep(1000) }
    }
}

/// A canvas inside another widget (a scroll view's document, a button's
/// label area), as a container the layer above can address.
@MainActor final class CanvasRef: NativeWidget {
    let canvas: GW
    unowned let owner: GtkBox
    private init(_ c: GW, owner: GtkBox) { canvas = c; self.owner = owner }
    private static var refs: [UnsafeMutableRawPointer: CanvasRef] = [:]
    static func wrap(_ c: GW, owner: GtkBox) -> CanvasRef {
        if let r = refs[raw(c)], r.owner === owner { return r }
        let r = CanvasRef(c, owner: owner)
        refs[raw(c)] = r
        return r
    }
}

// MARK: Drawing (Cairo)

private let drawCallback: @convention(c) (UnsafeMutablePointer<GtkDrawingArea>?, OpaquePointer?, Int32, Int32, UnsafeMutableRawPointer?) -> Void = { _, cr, w, h, data in
    guard let cr, let data else { return }
    let b = Unmanaged<GtkBox>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated {
        if b.kind == .divider {
            let dark = GTKBackend.current?.colorScheme == .dark
            cairo_set_source_rgba(cr, dark ? 1 : 0, dark ? 1 : 0, dark ? 1 : 0, 0.1)
            cairo_rectangle(cr, 0, 0, Double(w), Double(h))
            cairo_fill(cr)
            return
        }
        for cmd in b.props.drawing { Cairo.draw(cmd, cr) }
    }
}

enum Cairo {
    static func path(_ p: ShapePath, _ cr: OpaquePointer) {
        cairo_new_path(cr)
        switch p {
        case let .rect(r):
            cairo_rectangle(cr, r.minX, r.minY, r.width, r.height)
        case let .roundedRect(r, radius):
            let rad = min(radius, r.width / 2, r.height / 2)
            guard rad > 0 else { cairo_rectangle(cr, r.minX, r.minY, r.width, r.height); return }
            cairo_new_sub_path(cr)
            cairo_arc(cr, r.maxX - rad, r.minY + rad, rad, -.pi / 2, 0)
            cairo_arc(cr, r.maxX - rad, r.maxY - rad, rad, 0, .pi / 2)
            cairo_arc(cr, r.minX + rad, r.maxY - rad, rad, .pi / 2, .pi)
            cairo_arc(cr, r.minX + rad, r.minY + rad, rad, .pi, 3 * .pi / 2)
            cairo_close_path(cr)
        case let .ellipse(r):
            guard r.width > 0, r.height > 0 else { return }
            cairo_save(cr)
            cairo_translate(cr, r.midX, r.midY)
            cairo_scale(cr, r.width / 2, r.height / 2)
            cairo_arc(cr, 0, 0, 1, 0, 2 * .pi)
            cairo_restore(cr)
        case let .inset(s, d):
            path(s.insetBy(d), cr)
        case let .path(els):
            var current = CGPoint.zero
            for e in els {
                switch e {
                case let .move(p): cairo_move_to(cr, p.x, p.y); current = p
                case let .line(p): cairo_line_to(cr, p.x, p.y); current = p
                case let .quad(p, c):
                    let c1 = CGPoint(x: current.x + 2 / 3 * (c.x - current.x), y: current.y + 2 / 3 * (c.y - current.y))
                    let c2 = CGPoint(x: p.x + 2 / 3 * (c.x - p.x), y: p.y + 2 / 3 * (c.y - p.y))
                    cairo_curve_to(cr, c1.x, c1.y, c2.x, c2.y, p.x, p.y)
                    current = p
                case let .curve(p, c1, c2): cairo_curve_to(cr, c1.x, c1.y, c2.x, c2.y, p.x, p.y); current = p
                case .close: cairo_close_path(cr)
                }
            }
        }
    }

    static func source(_ paint: Paint, bounds: CGRect, _ cr: OpaquePointer) -> OpaquePointer? {
        switch paint {
        case let .color(c):
            cairo_set_source_rgba(cr, c.r, c.g, c.b, c.a)
            return nil
        case let .linearGradient(stops, s, e):
            let pat = cairo_pattern_create_linear(bounds.minX + s.x * bounds.width, bounds.minY + s.y * bounds.height,
                                                  bounds.minX + e.x * bounds.width, bounds.minY + e.y * bounds.height)
            for st in stops { cairo_pattern_add_color_stop_rgba(pat, st.location, st.color.r, st.color.g, st.color.b, st.color.a) }
            cairo_set_source(cr, pat)
            return pat
        case let .radialGradient(stops, c, r0, r1):
            let cx = bounds.minX + c.x * bounds.width, cy = bounds.minY + c.y * bounds.height
            let pat = cairo_pattern_create_radial(cx, cy, r0, cx, cy, r1)
            for st in stops { cairo_pattern_add_color_stop_rgba(pat, st.location, st.color.r, st.color.g, st.color.b, st.color.a) }
            cairo_set_source(cr, pat)
            return pat
        }
    }

    static func draw(_ cmd: DrawCommand, _ cr: OpaquePointer) {
        switch cmd {
        case let .fill(p, paint):
            path(p, cr)
            let pat = source(paint, bounds: p.bounds, cr)
            cairo_fill(cr)
            if let pat { cairo_pattern_destroy(pat) }
        case let .stroke(p, paint, style):
            cairo_save(cr)
            path(p, cr)
            let pat = source(paint, bounds: p.bounds, cr)
            AppKitCairo.strokeStyle(cr, style)
            cairo_stroke(cr)
            if let pat { cairo_pattern_destroy(pat) }
            cairo_restore(cr)
        case .image, .text:
            break
        case let .displayList(list): AppKitCairo.replay(list, cr)
        }
    }
}
#endif
