// A top-level window: paints its widget tree, hit-tests it, and turns
// mouse and keyboard input into the widgets' events.

#if os(Windows)
import Foundation
import RunwayCore
import CRunwayWin32

/// Mouse interactions that track the pointer until the button goes up.
enum Drag {
    case press(W32Widget)                         // buttons, toggles, segments…: act on release inside
    case slider(W32Widget)
    case scrollThumb(W32Widget, vertical: Bool, startMouse: CGFloat, startOffset: CGFloat)
}

@MainActor final class W32Window: NativeWindow {
    unowned let backend: Win32Backend
    let root = W32Widget(.container)
    var content: NativeWidget { root }
    private(set) var native: OpaquePointer?
    private(set) var contentSize: CGSize
    private var closed = false
    private var modal: Bool
    var onResize: ((CGSize) -> Void)?
    var onCloseRequest: (() -> Bool)?
    var onClosed: (() -> Void)?
    var onKey: ((KeyPress) -> Bool)?

    var title: String {
        didSet { if let n = native, title != oldValue { rw_window_set_title(n, title) } }
    }

    var isOpen: Bool { native != nil && !closed }
    var scale: CGFloat = 1

    // Input state.
    private(set) var drag: Drag?
    private(set) var pressedInside = false
    private(set) var hovered: W32Widget?
    private(set) var hoveredScroll: W32Widget?
    private(set) var mouse = CGPoint(x: -1, y: -1)

    // Text inputs placed in the last paint, in tab order.
    private var edits: [ObjectIdentifier: Weak] = [:]
    var editOrder: [W32Widget] = []
    var editsSeen = Set<ObjectIdentifier>()
    private(set) lazy var painter = Painter(window: self)

    final class Weak { weak var widget: W32Widget?; init(_ w: W32Widget) { widget = w } }

    init(_ o: WindowOptions, parent: W32Window?, backend: Win32Backend) {
        self.backend = backend
        title = o.title
        contentSize = o.size
        modal = o.modal
        root.hostWindow = self
        root.frame = CGRect(origin: .zero, size: o.size)
        native = rw_window_create(o.title, Double(o.size.width), Double(o.size.height), o.resizable ? 1 : 0,
                                  parent?.native, o.modal && parent != nil ? 1 : 0, Unmanaged.passUnretained(self).toOpaque())
        if let n = native { scale = CGFloat(rw_window_scale(n)) }
    }

    // MARK: NativeWindow

    func setContentSize(_ size: CGSize) {
        contentSize = size
        root.frame.size = size
        if let n = native { rw_window_set_content_size(n, Double(size.width), Double(size.height)) }
    }
    func setMinimumSize(_ size: CGSize) { if let n = native { rw_window_set_min_size(n, Double(size.width), Double(size.height)) } }
    func setResizable(_ resizable: Bool) { if let n = native { rw_window_set_resizable(n, resizable ? 1 : 0) } }
    func show() { if let n = native { rw_window_show(n) } }
    func center() { if let n = native { rw_window_center(n) } }

    func close() {
        guard !closed else { return }
        closed = true
        onClosed?()
        if let n = native {
            native = nil
            rw_window_destroy(n)
        }
        backend.windowClosed(self)
    }

    func invalidate() { if let n = native { rw_window_invalidate(n) } }

    func themeChanged() {
        if let n = native { rw_window_set_dark(n, backend.colorScheme == .dark ? 1 : 0) }
        invalidate()
    }

    /// Drops references to a destroyed widget.
    func forget(_ w: W32Widget) {
        if hovered === w { hovered = nil }
        if hoveredScroll === w { hoveredScroll = nil }
        if let d = drag {
            switch d {
            case let .press(x), let .slider(x), let .scrollThumb(x, _, _, _): if x === w { drag = nil }
            }
        }
        edits[ObjectIdentifier(w)] = nil
    }

    // MARK: Events

    func handle(_ ev: rw_event) -> Bool {
        guard let n = native else {
            if ev.type == RW_EV_DESTROYED { destroyed() }
            return false
        }
        let point = CGPoint(x: ev.x, y: ev.y)
        switch ev.type {
        case RW_EV_PAINT:
            painter.paint(n)
        case RW_EV_RESIZE:
            let s = CGSize(width: ev.dx, height: ev.dy)
            guard abs(s.width - contentSize.width) > 0.75 || abs(s.height - contentSize.height) > 0.75 else { return true }
            contentSize = s
            root.frame.size = s
            onResize?(s)
        case RW_EV_MOUSE_MOVE: mouseMoved(point)
        case RW_EV_MOUSE_LEAVE: mouseMoved(CGPoint(x: -1e6, y: -1e6))
        case RW_EV_MOUSE_DOWN: mouseDown(point, button: Int(ev.button), n)
        case RW_EV_MOUSE_UP: mouseUp(point, button: Int(ev.button), n)
        case RW_EV_WHEEL: wheel(point, CGPoint(x: ev.dx, y: ev.dy))
        case RW_EV_KEY_DOWN: return key(Int(ev.key), mods: ev.mods)
        case RW_EV_TIMER: invalidate()
        case RW_EV_DPI_CHANGED:
            scale = CGFloat(rw_window_scale(n))
            invalidate()
        case RW_EV_CLOSE_REQUEST:
            if onCloseRequest?() ?? true { close() }
        case RW_EV_DESTROYED:
            native = nil
            destroyed()
        default:
            return false
        }
        return true
    }

    private func destroyed() {
        guard !closed else { return }
        closed = true
        onClosed?()
        backend.windowClosed(self)
    }

    // MARK: Hit-testing

    /// The deepest interactive widget at a window point.
    func hit(_ point: CGPoint) -> W32Widget? { hit(root, point, origin: .zero) }

    private func hit(_ w: W32Widget, _ p: CGPoint, origin: CGPoint) -> W32Widget? {
        let f = w.frame.offsetBy(dx: origin.x, dy: origin.y)
        if w.props.opacity <= 0.01 { return nil }
        if case .scroll = w.kind {
            guard f.contains(p) else { return nil }
            if scrollbarHit(w, f, p) != nil { return w }
            if let doc = w.document {
                let o = CGPoint(x: f.minX - w.scrollOffset.x, y: f.minY - w.scrollOffset.y)
                for c in doc.children.reversed() { if let h = hit(c, p, origin: o) { return h } }
            }
            return w
        }
        if w.props.clips, !f.contains(p) { return nil }
        for c in w.children.reversed() { if let h = hit(c, p, origin: f.origin) { return h } }
        if w.isInteractive, f.contains(p) { return w }
        return nil
    }

    /// The innermost scroll view at a point, and its window frame.
    private func scrollViews(at p: CGPoint) -> [W32Widget] {
        var out: [W32Widget] = []
        func walk(_ w: W32Widget, _ origin: CGPoint) {
            let f = w.frame.offsetBy(dx: origin.x, dy: origin.y)
            if case .scroll = w.kind {
                guard f.contains(p) else { return }
                out.append(w)
                if let doc = w.document {
                    let o = CGPoint(x: f.minX - w.scrollOffset.x, y: f.minY - w.scrollOffset.y)
                    for c in doc.children { walk(c, o) }
                }
                return
            }
            if w.props.clips, !f.contains(p) { return }
            for c in w.children { walk(c, f.origin) }
        }
        walk(root, .zero)
        return out
    }

    /// Which scroll bar of `w` (at window frame `f`) is under `p`.
    func scrollbarHit(_ w: W32Widget, _ f: CGRect, _ p: CGPoint) -> Bool? {
        let m = w.maxScroll
        if m.y > 0.5, p.x >= f.maxX - 12, p.x <= f.maxX { return true }
        if m.x > 0.5, p.y >= f.maxY - 12, p.y <= f.maxY { return false }
        return nil
    }

    /// The thumb of a scroll bar: (position, length) along the track.
    func thumb(_ w: W32Widget, vertical: Bool) -> (CGFloat, CGFloat, CGFloat) {
        let view = vertical ? w.frame.height : w.frame.width
        let content = vertical ? w.contentSize.height : w.contentSize.width
        let both = w.maxScroll.x > 0.5 && w.maxScroll.y > 0.5
        let track = max(0, view - 4 - (both ? 10 : 0))
        let length = max(24, track * view / max(content, 1))
        let range = max(0, content - view)
        let offset = vertical ? w.scrollOffset.y : w.scrollOffset.x
        let pos = 2 + (range > 0 ? (track - length) * offset / range : 0)
        return (pos, min(length, track), track)
    }

    // MARK: Mouse

    private func mouseMoved(_ p: CGPoint) {
        mouse = p
        if let d = drag {
            switch d {
            case let .press(w):
                let inside = w.windowFrame.contains(p)
                if inside != pressedInside { pressedInside = inside; invalidate() }
            case let .slider(w):
                setSlider(w, p)
            case let .scrollThumb(w, vertical, startMouse, startOffset):
                let (_, length, track) = thumb(w, vertical: vertical)
                let range = vertical ? w.maxScroll.y : w.maxScroll.x
                let delta = (vertical ? p.y : p.x) - startMouse
                let travel = max(1, track - length)
                scroll(w, to: vertical ? CGPoint(x: w.scrollOffset.x, y: startOffset + delta * range / travel)
                                       : CGPoint(x: startOffset + delta * range / travel, y: w.scrollOffset.y))
            }
            return
        }
        let h = hit(p)
        if h !== hovered {
            hovered = h
            invalidate()
        }
        let s = scrollViews(at: p).last
        if s !== hoveredScroll {
            hoveredScroll = s
            invalidate()
        }
        if let n = native {
            var cursor = RW_CURSOR_ARROW
            if let h, h.props.enabled {
                if h.kind == .link { cursor = RW_CURSOR_HAND }
                if case .textField = h.kind { cursor = RW_CURSOR_IBEAM }
            }
            rw_window_set_cursor(n, cursor)
        }
    }

    private func mouseDown(_ p: CGPoint, button: Int, _ n: OpaquePointer) {
        mouse = p
        guard let w = hit(p), w.props.enabled else { return }
        if button == 1 {
            // Context menus: a control's own menu, if it has one.
            if !w.events.menu.isEmpty { showMenu(w.events.menu, at: p, n) }
            return
        }
        guard button == 0 else { return }
        let f = w.windowFrame
        switch w.kind {
        case .scroll:
            guard let vertical = scrollbarHit(w, f, p) else { return }
            let (pos, length, _) = thumb(w, vertical: vertical)
            let along = vertical ? p.y - f.minY : p.x - f.minX
            if along < pos || along > pos + length {
                // Jump so the thumb centres on the click, then drag from there.
                let range = vertical ? w.maxScroll.y : w.maxScroll.x
                let (_, _, track) = thumb(w, vertical: vertical)
                let target = (along - length / 2 - 2) / max(1, track - length) * range
                scroll(w, to: vertical ? CGPoint(x: w.scrollOffset.x, y: target) : CGPoint(x: target, y: w.scrollOffset.y))
            }
            drag = .scrollThumb(w, vertical: vertical, startMouse: vertical ? p.y : p.x,
                                startOffset: vertical ? w.scrollOffset.y : w.scrollOffset.x)
            rw_window_capture(n, 1)
        case .slider:
            drag = .slider(w)
            rw_window_capture(n, 1)
            setSlider(w, p)
        case .textField, .textEditor:
            if let e = w.edit { rw_edit_focus(e.pointer, 0) }
        case .dropdown:
            showOptions(w, f, n)
        case .menuButton:
            if w.events.onTap != nil, p.x < f.maxX - 18 {
                pressedInside = true
                drag = .press(w)
                rw_window_capture(n, 1)
            } else {
                showMenu(w.events.menu, at: CGPoint(x: f.minX, y: f.maxY + 2), n)
            }
        case .stepper:
            let up = p.y < f.midY
            let step = w.props.step ?? 1
            let v = min(w.props.range.upperBound, max(w.props.range.lowerBound, w.props.number + (up ? step : -step)))
            if v != w.props.number { w.events.onNumber?(v) }
            pressedInside = true
            drag = .press(w)
            rw_window_capture(n, 1)
        default:
            pressedInside = true
            drag = .press(w)
            rw_window_capture(n, 1)
        }
        invalidate()
    }

    private func mouseUp(_ p: CGPoint, button: Int, _ n: OpaquePointer) {
        guard let d = drag else { return }
        drag = nil
        let wasInside = pressedInside
        pressedInside = false
        rw_window_capture(n, 0)
        invalidate()
        guard button == 0, case let .press(w) = d, wasInside, w.windowFrame.contains(p), w.props.enabled else { return }
        activate(w, at: p, n)
    }

    /// A click completed on `w`.
    private func activate(_ w: W32Widget, at p: CGPoint, _ n: OpaquePointer) {
        let props = w.props
        switch w.kind {
        case .button, .link, .menuButton:
            w.events.onTap?()
        case .tapArea:
            if let action = w.events.onTapLocation {
                let frame = w.windowFrame
                action(CGPoint(x: p.x - frame.minX, y: p.y - frame.minY))
            } else { w.events.onTap?() }
        case .toggle:
            w.events.onToggle?(!props.isOn)
        case .segmented:
            let f = w.windowFrame
            if let i = painter.segmentIndex(w, x: p.x - f.minX, width: f.width), i != props.selected { w.events.onSelect?(i) }
        case .colorWell:
            var result = rw_color()
            if rw_choose_color(n, props.color.rw, &result) != 0 { w.events.onColor?(RGBA(result)) }
        default:
            break
        }
    }

    private func setSlider(_ w: W32Widget, _ p: CGPoint) {
        let f = w.windowFrame
        let knob: CGFloat = 18
        let t = Double(max(0, min(1, (p.x - f.minX - knob / 2) / max(1, f.width - knob))))
        let r = w.props.range
        var v = r.lowerBound + t * (r.upperBound - r.lowerBound)
        if let s = w.props.step, s > 0 { v = r.lowerBound + ((v - r.lowerBound) / s).rounded() * s }
        v = min(r.upperBound, max(r.lowerBound, v))
        if v != w.props.number {
            w.props.number = v   // follow the pointer before the next render
            w.events.onNumber?(v)
            invalidate()
        }
    }

    private func wheel(_ p: CGPoint, _ delta: CGPoint) {
        for s in scrollViews(at: p).reversed() {
            let m = s.maxScroll
            let canX = delta.x != 0 && m.x > 0.5, canY = delta.y != 0 && m.y > 0.5
            guard canX || canY else { continue }
            let target = CGPoint(x: s.scrollOffset.x + (canX ? delta.x : 0), y: s.scrollOffset.y + (canY ? delta.y : 0))
            let before = s.scrollOffset
            scroll(s, to: target)
            if s.scrollOffset != before { break }
        }
        if hoveredScroll == nil { hoveredScroll = scrollViews(at: p).last }
    }

    func scroll(_ s: W32Widget, to p: CGPoint) {
        let m = s.maxScroll
        let clamped = CGPoint(x: max(0, min(m.x, p.x)).rounded(), y: max(0, min(m.y, p.y)).rounded())
        guard clamped != s.scrollOffset else { return }
        s.scrollOffset = clamped
        invalidate()
    }

    // MARK: Menus

    private func showOptions(_ w: W32Widget, _ f: CGRect, _ n: OpaquePointer) {
        let items = w.props.options.enumerated().map { i, title in
            MenuItemSpec(title: title, checked: i == w.props.selected) { [weak w] in
                if let w, i != w.props.selected { w.events.onSelect?(i) }
            }
        }
        showMenu(items, at: CGPoint(x: f.minX, y: f.maxY + 2), n)
    }

    func showMenu(_ items: [MenuItemSpec], at p: CGPoint, _ n: OpaquePointer) {
        guard !items.isEmpty, let menu = rw_menu_create() else { return }
        defer { rw_menu_free(menu) }
        var actions: [(() -> Void)?] = [nil]
        func add(_ list: [MenuItemSpec], to m: OpaquePointer) {
            for item in list {
                if item.isSeparator {
                    rw_menu_add_separator(m)
                } else if !item.children.isEmpty {
                    if let sub = rw_menu_add_submenu(m, item.title, item.enabled ? 1 : 0) { add(item.children, to: sub) }
                } else {
                    actions.append(item.action)
                    rw_menu_add(m, item.title, Int32(actions.count - 1), item.enabled ? 1 : 0, item.checked ? 1 : 0)
                }
            }
        }
        add(items, to: menu)
        let chosen = Int(rw_menu_popup(menu, n, Double(p.x), Double(p.y)))
        hovered = nil
        invalidate()
        if chosen > 0, chosen < actions.count { actions[chosen]?() }
    }

    // MARK: Keyboard

    private func key(_ vk: Int, mods: UInt32) -> Bool {
        guard let name = Keys.name(vk) else { return false }
        let press = KeyPress(key: name, command: mods & UInt32(RW_MOD_CTRL) != 0, shift: mods & UInt32(RW_MOD_SHIFT) != 0,
                             option: mods & UInt32(RW_MOD_ALT) != 0, control: false)
        if onKey?(press) == true { return true }
        if name == "tab", !press.command, !press.option {
            focusNextField(backward: press.shift)
            return true
        }
        if name == "escape", focusedField != nil, let n = native {
            rw_window_focus(n)
            return true
        }
        return false
    }

    var focusedField: W32Widget? { editOrder.first { $0.editFocused } }

    private func focusNextField(backward: Bool) {
        let fields = editOrder.filter { $0.props.enabled && editsSeen.contains(ObjectIdentifier($0)) }
        guard !fields.isEmpty else { return }
        let current = fields.firstIndex { $0.editFocused }
        let next: Int
        if let c = current { next = (c + (backward ? fields.count - 1 : 1)) % fields.count } else { next = backward ? fields.count - 1 : 0 }
        if let e = fields[next].edit { rw_edit_focus(e.pointer, 1) }
    }

    // MARK: Text inputs

    /// Creates or moves `w`'s EDIT to its frame on screen (called while painting).
    func placeEdit(_ w: W32Widget, frame: CGRect, clip: CGRect, multiline: Bool, style: (size: CGFloat, text: RGBA, background: RGBA)) {
        guard let n = native else { return }
        let id = ObjectIdentifier(w)
        if w.edit == nil || w.editWindow !== self {
            w.edit = nil
            guard let e = rw_edit_create(n, multiline ? 1 : 0, Unmanaged.passUnretained(w).toOpaque()) else { return }
            w.edit = NativeHandle(e, release: { rw_edit_destroy($0) })
            w.editWindow = self
            w.editText = w.props.string
            rw_edit_set_text(e, w.props.string)
        }
        guard let e = w.edit?.pointer else { return }
        if edits[id]?.widget !== w { edits[id] = Weak(w) }
        editsSeen.insert(id)
        editOrder.append(w)
        var secure = false
        if case .textField(true) = w.kind { secure = true }
        rw_edit_set_style(e, Float(style.size), 400, style.text.rw, style.background.rw, secure ? 1 : 0)
        rw_edit_set_placeholder(e, w.props.placeholder)
        rw_edit_set_enabled(e, w.props.enabled ? 1 : 0)
        rw_edit_set_frame(e, Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height),
                          Double(clip.minX), Double(clip.minY), Double(clip.width), Double(clip.height), 1)
    }

    func beginEditPass() {
        editsSeen.removeAll(keepingCapacity: true)
        editOrder.removeAll(keepingCapacity: true)
    }

    /// Hides EDITs whose fields were not drawn (scrolled away, removed, hidden).
    func endEditPass() {
        for (id, ref) in edits {
            guard let w = ref.widget else { edits[id] = nil; continue }
            if !editsSeen.contains(id), let e = w.edit { rw_edit_set_frame(e.pointer, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        }
    }
}

/// Virtual-key codes to the key names `KeyPress` uses (SwiftUI's KeyEquivalent names).
enum Keys {
    static func name(_ vk: Int) -> String? {
        switch vk {
        case 0x08: return "backspace"
        case 0x09: return "tab"
        case 0x0D: return "return"
        case 0x1B: return "escape"
        case 0x20: return "space"
        case 0x21: return "pageup"
        case 0x22: return "pagedown"
        case 0x23: return "end"
        case 0x24: return "home"
        case 0x25: return "left"
        case 0x26: return "up"
        case 0x27: return "right"
        case 0x28: return "down"
        case 0x2E: return "delete"
        case 0x30...0x39, 0x41...0x5A: return String(UnicodeScalar(UInt8(vk))).lowercased()
        case 0x60...0x69: return String(vk - 0x60)                   // numeric keypad digits
        case 0x6A: return "*"
        case 0x6B: return "+"
        case 0x6D: return "-"
        case 0x6E: return "."
        case 0x6F: return "/"
        case 0x70...0x87: return "f\(vk - 0x6F)"
        case 0x10, 0x11, 0x12, 0x14, 0x5B, 0x5C, 0x5D, 0xA0...0xA5: return nil   // modifiers alone
        default:
            let c = Int(rw_key_char(Int32(vk)))
            guard c > 0, let u = UnicodeScalar(UInt32(c)) else { return nil }
            return String(Character(u)).lowercased()
        }
    }
}
#endif
