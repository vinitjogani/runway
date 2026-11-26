// The Windows backend: Mac-style controls drawn with Direct2D and
// DirectWrite into per-monitor-DPI-aware windows, over the native layer in
// Native/ (a flat C API implemented in C++).
//
// Every widget is a lightweight Swift object in its window's tree; the
// window paints the tree and hit-tests it, so controls can look like the
// Mac's (rounded, antialiased, accent-filled, translucent) instead of like
// Win32 common controls, and SwiftUI's layout places them exactly. Text
// input uses real EDIT controls positioned over custom-drawn fields so IME,
// selection, the clipboard and accessibility behave natively.

#if os(Windows) || os(Linux)
import Foundation
import RunwayCore
import CRunwayDrawn

/// Native events arrive here and go to the window or widget in `ctx`.
private let eventCallback: rw_event_fn = { event in
    guard let event else { return 0 }
    let ev = event.pointee
    return MainActor.assumeIsolated { DrawnBackend.current?.handle(ev) ?? 0 }
}

/// The drawn backend's former name, from when it ran on Windows only.
public typealias Win32Backend = DrawnBackend

@MainActor public final class DrawnBackend: Backend {
    #if os(Windows)
    public let name = "win32"
    #else
    public let name = "drawn"
    #endif
    public var onColorSchemeChange: (() -> Void)?
    public private(set) var colorScheme: ColorSchemeValue
    public lazy var services: PlatformServices = Win32Services(backend: self)
    static weak var current: DrawnBackend?
    /// RUNWAY_DEBUG_INPUT=1: how presses are routed, on stderr.
    static let debugInput = ProcessInfo.processInfo.environment["RUNWAY_DEBUG_INPUT"] != nil

    var windows: [DrawnWindow] = []
    var trays: [DrawnTray] = []
    /// The scheme AppKit asked for (nil: the system's).
    var preferredScheme: ColorSchemeValue?
    private var queue: [@MainActor () -> Void] = []
    private var wakePending = false
    private var timersPumped = false

    public init() {
        // Runway's bundled fonts, before any text is laid out.
        let files = BundledFonts.filesToRegister()
        let aliases = BundledFonts.aliases.flatMap { [$0.0, $0.1] }
        Self.withCStrings(files) { paths, n in
            Self.withCStrings(aliases) { names, _ in rw_register_fonts(paths, n, names, Int32(BundledFonts.aliases.count)) }
        }
        _ = rw_init(eventCallback)
        Fonts.configure()
        colorScheme = rw_dark_mode() != 0 ? .dark : .light
        Self.current = self
    }

    var theme: Theme { Theme(dark: colorScheme == .dark) }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int32) -> R) -> R {
        let owned = strings.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        let pointers = owned.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress, Int32($0.count)) }
    }

    /// The window to own dialogs: the frontmost one we made.
    var activeWindow: DrawnWindow? { windows.last { $0.isOpen } }

    // MARK: Events

    func handle(_ ev: rw_event) -> Int32 {
        let r = dispatch(ev)
        // Timers the event scheduled get their wake-up.
        if ev.type != RW_EV_PAINT, ev.type != RW_EV_WAKE, ev.type != RW_EV_RICH_PAINT { pumpRunLoop() }
        return r
    }

    private func dispatch(_ ev: rw_event) -> Int32 {
        switch ev.type {
        case RW_EV_WAKE:
            drain()
            pumpRunLoop()
            return 0
        case RW_EV_THEME_CHANGED:
            let scheme: ColorSchemeValue = preferredScheme ?? (rw_dark_mode() != 0 ? .dark : .light)
            if scheme != colorScheme { setColorScheme(scheme) }
            return 0
        case RW_EV_RICH_CHANGED, RW_EV_RICH_SELECTION, RW_EV_RICH_FOCUS, RW_EV_RICH_CHAR, RW_EV_RICH_KEY, RW_EV_RICH_POINTER, RW_EV_RICH_HEIGHT, RW_EV_RICH_PAINT:
            guard let ctx = ev.ctx else { return 0 }
            let widget = Unmanaged<DrawnWidget>.fromOpaque(ctx).takeUnretainedValue()
            return richEvent(widget, ev) ? 1 : 0
        case RW_EV_TRAY:
            guard let ctx = ev.ctx else { return 0 }
            Unmanaged<DrawnTray>.fromOpaque(ctx).takeUnretainedValue().clicked(secondary: ev.button != 0)
            return 0
        case RW_EV_EDIT_KEY:
            guard let ctx = ev.ctx else { return 0 }
            let widget = Unmanaged<DrawnWidget>.fromOpaque(ctx).takeUnretainedValue()
            guard let handler = widget.fieldKey, let press = Keys.press(Int(ev.key), mods: ev.mods) else { return 0 }
            return handler(press) ? 1 : 0
        case RW_EV_EDIT_CHANGED, RW_EV_EDIT_SUBMIT, RW_EV_EDIT_FOCUS, RW_EV_EDIT_BLUR:
            guard let ctx = ev.ctx else { return 0 }
            let widget = Unmanaged<DrawnWidget>.fromOpaque(ctx).takeUnretainedValue()
            return editEvent(widget, ev.type) ? 1 : 0
        default:
            guard let ctx = ev.ctx else { return 0 }
            let window = Unmanaged<DrawnWindow>.fromOpaque(ctx).takeUnretainedValue()
            if ev.type == RW_EV_DRAG { return Int32(window.dragEvent(ev).rawValue) }
            return window.handle(ev) ? 1 : 0
        }
    }

    func setColorScheme(_ scheme: ColorSchemeValue) {
        colorScheme = scheme
        for w in windows { w.themeChanged() }
        onColorSchemeChange?()
    }

    private func editEvent(_ w: DrawnWidget, _ type: Int32) -> Bool {
        switch type {
        case RW_EV_EDIT_CHANGED:
            guard let e = w.edit, let c = rw_edit_copy_text(e.pointer) else { return false }
            let s = String(cString: c)
            rw_free(c)
            w.editText = s
            if s != w.props.string {
                w.props.string = s
                w.events.onText?(s)
            }
            return true
        case RW_EV_EDIT_SUBMIT:
            guard let submit = w.events.onSubmit else { return false }
            submit()
            return true
        case RW_EV_EDIT_FOCUS:
            w.editFocused = true
            w.invalidate()
            w.events.onFocus?(true)
            w.fieldFocus?(true)
            return true
        case RW_EV_EDIT_BLUR:
            w.editFocused = false
            w.invalidate()
            w.events.onFocus?(false)
            w.fieldFocus?(false)
            return true
        default:
            return false
        }
    }

    // MARK: Widgets

    public func makeWidget(_ kind: WidgetKind) -> NativeWidget {
        let w = DrawnWidget(kind)
        if case .scroll = kind {
            let doc = DrawnWidget(.container)
            doc.parent = w
            w.document = doc
        }
        return w
    }

    public func update(_ widget: NativeWidget, props p: WidgetProps, events: WidgetEvents) {
        let w = widget as! DrawnWidget
        let old = w.props
        w.events = events
        w.props = p
        switch w.kind {
        case .text:
            w.label.set(p.text ?? StyledText(runs: []))
        case .toggle(.switch):
            let target: Double = p.isOn ? 1 : 0
            if !w.hasBeenDrawn { w.knob = target } else if old.isOn != p.isOn {
                w.knobFrom = w.knob
                w.knobStart = uptime
            }
        case .textField, .textEditor:
            if let e = w.edit, p.string != w.editText {
                w.editText = p.string
                rw_edit_set_text(e.pointer, p.string)
            }
        case .canvas:
            if old.drawing != p.drawing {
                w.canvasTexts.removeAll()
                w.canvasPaths.removeAll()
            }
        case .image:
            if case .symbol = p.image {} else { w.image.set(p.image) }
        default:
            break
        }
        if old != p { w.invalidate() }
    }

    public func measure(_ widget: NativeWidget, proposal: ProposedSize) -> CGSize {
        let w = widget as! DrawnWidget
        let p = w.props
        let m = Metrics(size: p.controlSize)
        func titleSize(_ s: String) -> CGSize { TextMetrics.size(s, size: m.font) }
        switch w.kind {
        case .text:
            return w.label.measure(proposal.width)
        case .button:
            if p.hasContent { return CGSize(width: m.height, height: m.height) }
            let t = titleSize(p.title)
            return CGSize(width: max(t.width + 2 * m.padding, m.height + 6), height: m.height)
        case .link:
            return titleSize(p.title)
        case let .toggle(k):
            switch k {
            case .switch:
                return m.switchSize
            case .checkbox:
                let box = m.checkbox
                guard !p.title.isEmpty else { return CGSize(width: box, height: max(box, 16)) }
                let t = titleSize(p.title)
                return CGSize(width: box + 6 + t.width, height: max(box + 2, t.height))
            case .button:
                let t = titleSize(p.title)
                return CGSize(width: t.width + 2 * m.padding, height: m.height)
            }
        case .textField:
            return CGSize(width: proposal.width ?? 120, height: m.height)
        case .textEditor:
            return CGSize(width: proposal.width ?? 200, height: proposal.height ?? 100)
        case .slider:
            return CGSize(width: proposal.width ?? 120, height: 20)
        case .stepper:
            let t = titleSize(Painter.stepperText(p))
            return CGSize(width: max(56, t.width + 30), height: m.height)
        case .dropdown:
            var widest: CGFloat = 0
            for o in p.options { widest = max(widest, titleSize(o).width) }
            if p.options.isEmpty { widest = titleSize(p.title).width }
            return CGSize(width: widest + 8 + 6 + 22, height: m.height)
        case .menuButton:
            if p.title.isEmpty, case .symbol = p.image { return CGSize(width: (p.bordered ? 16 : 6) + m.font * 1.3 + 14, height: m.height) }
            return CGSize(width: titleSize(p.title).width + 2 * m.padding + 12, height: m.height)
        case .segmented:
            var total: CGFloat = 0
            for o in p.options { total += titleSize(o).width + 2 * m.padding }
            return CGSize(width: max(total, 20), height: m.height)
        case let .progress(circular):
            if circular { let s = m.spinner; return CGSize(width: s, height: s) }
            return CGSize(width: proposal.width ?? 160, height: 6)
        case .colorWell:
            return CGSize(width: 44, height: m.height)
        case .image:
            if case .symbol = p.image {
                let s = (p.imagePointSize * 1.2).rounded()
                return CGSize(width: s, height: s)
            }
            if let s = w.image.size { return s }
            return .zero
        case .divider:
            return CGSize(width: 1, height: 1)
        case .container, .scroll, .tapArea, .canvas:
            return proposal.replacingUnspecified(by: CGSize(width: 10, height: 10))
        }
    }

    public func textBaselines(_ widget: NativeWidget, width: CGFloat?) -> (first: CGFloat, last: CGFloat)? {
        let w = widget as! DrawnWidget
        guard w.kind == .text, let p = w.label.pointer else { return nil }
        var lines = [Double](repeating: 0, count: 256)
        let n = Int(lines.withUnsafeMutableBufferPointer { rw_text_baselines(p, Double(width ?? 0), $0.baseAddress, 256) })
        guard n > 0 else { return nil }
        return (CGFloat(lines[0]), CGFloat(lines[n - 1]))
    }

    public func contentInsets(_ widget: NativeWidget) -> EdgeInsetsValue {
        let w = widget as! DrawnWidget
        guard w.kind == .button else { return .zero }
        let m = Metrics(size: w.props.controlSize)
        let h = m.padding - 2
        return EdgeInsetsValue(top: 3, leading: h, bottom: 3, trailing: h)
    }

    public func childContainer(_ widget: NativeWidget) -> NativeWidget {
        let w = widget as! DrawnWidget
        return w.document ?? w
    }

    public func setChildren(_ container: NativeWidget, _ children: [(NativeWidget, CGRect)], contentSize: CGSize) {
        let c = container as! DrawnWidget
        c.contentSize = contentSize
        var list: [DrawnWidget] = []
        list.reserveCapacity(children.count)
        var placed = Set<ObjectIdentifier>()
        for (child, frame) in children {
            let w = child as! DrawnWidget
            if let old = w.parent, old !== c { old.children.removeAll { $0 === w } }
            w.parent = c
            w.frame = frame
            list.append(w)
            placed.insert(ObjectIdentifier(w))
        }
        for old in c.children where old.parent === c && !placed.contains(ObjectIdentifier(old)) { old.parent = nil }
        c.children = list
        if let scroll = c.parent, scroll.document === c {
            c.frame = CGRect(origin: .zero, size: contentSize)
            scroll.contentSize = contentSize
            let m = scroll.maxScroll
            scroll.scrollOffset = CGPoint(x: min(scroll.scrollOffset.x, m.x), y: min(scroll.scrollOffset.y, m.y))
        }
        c.invalidate()
    }

    public func destroy(_ widget: NativeWidget) {
        let w = widget as! DrawnWidget
        let window = w.window
        window?.forget(w)
        window?.invalidate()
        w.parent?.children.removeAll { $0 === w }
        w.parent = nil
        w.edit = nil
    }

    // MARK: Windows and the loop

    public func makeWindow(_ options: WindowOptions, parent: NativeWindow?) -> NativeWindow {
        let w = DrawnWindow(options, parent: parent as? DrawnWindow, backend: self)
        windows.append(w)
        return w
    }

    func windowClosed(_ w: DrawnWindow) { windows.removeAll { $0 === w } }

    public func run(_ start: @escaping @MainActor () -> Void) {
        schedule(start)
        rw_run()
    }

    public func quit() {
        for w in windows { w.close() }
        rw_quit()
    }

    public func schedule(_ work: @escaping @MainActor () -> Void) {
        defer { if !timersPumped { timersPumped = true; pumpRunLoop() } }
        queue.append(work)
        if !wakePending {
            wakePending = true
            rw_wake()
        }
    }

    /// Fires RunLoop.main's due timers (Timer, perform(afterDelay:)) and
    /// wakes again for the next one: the loop here is the toolkit's.
    func pumpRunLoop() {
        guard let next = RunLoop.main.limitDate(forMode: .default) else { rw_wake_after(-1); return }
        let ms = next.timeIntervalSinceNow * 1000
        rw_wake_after(ms > 86_400_000 ? -1 : Int32(max(1, ms.rounded(.up))))
    }

    private func drain() {
        wakePending = false
        let batch = queue
        queue.removeAll(keepingCapacity: true)
        for work in batch { work() }
    }
}
#endif
