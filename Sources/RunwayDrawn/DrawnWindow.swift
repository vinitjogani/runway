// A top-level window: paints its widget tree, hit-tests it, and turns
// mouse and keyboard input into the widgets' events.

#if os(Windows) || os(Linux)
import Foundation
import RunwayCore
import CRunwayDrawn

/// Mouse interactions that track the pointer until the button goes up.
enum Drag {
    case press(DrawnWidget)                         // buttons, toggles, segments…: act on release inside
    case slider(DrawnWidget)
    case scrollThumb(DrawnWidget, vertical: Bool, startMouse: CGFloat, startOffset: CGFloat)
}

@MainActor final class DrawnWindow: NativeWindow {
    unowned let backend: DrawnBackend
    let root = DrawnWidget(.container)
    var content: NativeWidget { root }
    private(set) var native: OpaquePointer?
    private(set) var contentSize: CGSize
    private var closed = false
    private var modal: Bool
    var onResize: ((CGSize) -> Void)?
    var onMove: ((CGPoint) -> Void)?
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
    private(set) var hovered: DrawnWidget?
    private(set) var hoveredScroll: DrawnWidget?
    private(set) var mouse = CGPoint(x: -1, y: -1)

    // Text inputs placed in the last paint, in tab order.
    private var edits: [ObjectIdentifier: Weak] = [:]
    var editOrder: [DrawnWidget] = []
    var editsSeen = Set<ObjectIdentifier>()
    private(set) lazy var painter = Painter(window: self)

    final class Weak { weak var widget: DrawnWidget?; init(_ w: DrawnWidget) { widget = w } }

    // AppKit's view system (Win32AppKit.swift).
    var rawHandler: ((RawEvent) -> Bool)?
    var activationHandler: ((Bool) -> Void)?
    var dropHandler: ((RawDragEvent) -> RawDragOperation)?
    var pointerInside = false
    var buttonsDown = 0
    var keyModifiers: KeyModifiers = []
    var clickCount = 1
    var lastClick: (time: Double, point: CGPoint, button: Int)?
    var pressChain: [DrawnWidget] = []
    // Tooltips: the text under the pointer, shown after a pause.
    var tooltipText: String?
    var tooltipShown = false
    var tooltipGeneration = 0
    var hoverChain: [DrawnWidget] = []
    weak var focusedContainer: DrawnWidget?
    var menuBar: MenuBarState?
    var popover: PopoverState?
    var riches: [ObjectIdentifier: Weak] = [:]
    var richesSeen = Set<ObjectIdentifier>()

    init(_ o: WindowOptions, parent: DrawnWindow?, backend: DrawnBackend, popup: Bool = false) {
        self.backend = backend
        title = o.title
        contentSize = o.size
        modal = o.modal
        root.hostWindow = self
        root.frame = CGRect(origin: .zero, size: o.size)
        if popup, let owner = parent?.native {
            native = rw_popup_create(owner, Unmanaged.passUnretained(self).toOpaque())
        } else {
            native = rw_window_create(o.title, Double(o.size.width), Double(o.size.height), o.resizable ? 1 : 0,
                                      parent?.native, o.modal && parent != nil ? 1 : 0, Unmanaged.passUnretained(self).toOpaque())
        }
        if let n = native {
            scale = CGFloat(rw_window_scale(n))
            if o.titlebar == .none, !popup { rw_window_set_decorated(n, 0) }
        }
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
    func showWithoutActivating() { if let n = native { rw_window_show_inactive(n) } }
    func center() { if let n = native { rw_window_center(n) } }
    func setPosition(_ topLeft: CGPoint) { if let n = native { rw_window_set_position(n, Double(topLeft.x), Double(topLeft.y)) } }

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
    func forget(_ w: DrawnWidget) {
        if hovered === w { hovered = nil }
        if hoveredScroll === w { hoveredScroll = nil }
        if let d = drag {
            switch d {
            case let .press(x), let .slider(x), let .scrollThumb(x, _, _, _): if x === w { drag = nil }
            }
        }
        edits[ObjectIdentifier(w)] = nil
        riches[ObjectIdentifier(w)] = nil
        pressChain.removeAll { $0 === w }
        hoverChain.removeAll { $0 === w }
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
        case RW_EV_MOUSE_MOVE:
            let mods = RawModifiers(ev.mods)
            if !pointerInside {
                pointerInside = true
                _ = sendRaw(.mouseEntered, at: point, mods: mods)
            }
            if buttonsDown != 0, sendRaw(.mouseMoved, at: point, mods: mods, monitor: true) { return true }
            for c in pressChain { _ = deliver(.dragged, to: c, at: point) }
            mouseMoved(point)
            updateHover(point)
            updateTooltip(buttonsDown == 0 ? point : nil)
            _ = sendRaw(.mouseMoved, at: point, mods: mods)
        case RW_EV_MOUSE_LEAVE:
            mouseMoved(CGPoint(x: -1e6, y: -1e6))
            if pressChain.isEmpty { updateHover(CGPoint(x: -1e6, y: -1e6)) }
            if DrawnBackend.debugInput { FileHandle.standardError.write("leave\n".data(using: .utf8)!) }
            updateTooltip(nil)
            if pointerInside {
                pointerInside = false
                _ = sendRaw(.mouseExited, at: mouse, mods: RawModifiers(ev.mods))
            }
        case RW_EV_MOUSE_DOWN:
            let b = Int(ev.button)
            updateTooltip(nil)
            countClick(point, button: b)
            buttonsDown |= 1 << b
            keyModifiers = KeyModifiers(raw: RawModifiers(ev.mods))
            let onNative = hit(point) != nil
            if DrawnBackend.debugInput { FileHandle.standardError.write("down \(point) path=\(pick(point).map { "\($0.kind)" }.joined(separator: ">")) hit=\(String(describing: hit(point)?.kind))\n".data(using: .utf8)!) }
            if sendRaw(.mouseDown, at: point, mods: RawModifiers(ev.mods), button: b, monitor: true, onNative: onNative) {
                if DrawnBackend.debugInput { FileHandle.standardError.write("  monitor took it\n".data(using: .utf8)!) }
                return true
            }
            mouseDown(point, button: b, n)
            _ = sendRaw(.mouseDown, at: point, mods: RawModifiers(ev.mods), button: b, onNative: onNative)
        case RW_EV_MOUSE_UP:
            let b = Int(ev.button)
            if b >= 0 { buttonsDown &= ~(1 << b) } else { buttonsDown = 0 }
            if b >= 0, sendRaw(.mouseUp, at: point, mods: RawModifiers(ev.mods), button: b, monitor: true) {
                // A monitor took the release: the control under the press lets go.
                mouseUp(CGPoint(x: -1e6, y: -1e6), button: b, n)
                return true
            }
            mouseUp(point, button: b, n)
            if b >= 0 { _ = sendRaw(.mouseUp, at: point, mods: RawModifiers(ev.mods), button: b) }
        case RW_EV_WHEEL:
            if !wheel(point, CGPoint(x: ev.dx, y: ev.dy)) {
                var e = rawEvent(.scroll, at: point, mods: RawModifiers(ev.mods))
                e.scrollDelta = CGSize(width: -ev.dx, height: -ev.dy)
                e.preciseScrolling = true
                _ = rawHandler?(e)
            }
        case RW_EV_KEY_DOWN: return key(Int(ev.key), mods: ev.mods)
        case RW_EV_RAW_KEY:
            if ev.flags & UInt32(RW_KEY_UP) == 0 { updateTooltip(nil) }
            return rawKey(ev)
        case RW_EV_ACTIVATE:
            let active = ev.button != 0
            activationHandler?(active)
            if !active, popover?.transient == true { closePopoverWindow() }
            return false
        case RW_EV_MENU_COMMAND:
            menuBar?.activate(Int(ev.key))
        case RW_EV_MENU_OPENING:
            menuBar?.refresh(n)
        case RW_EV_CHILD_MOUSE, RW_EV_CHILD_MOUSE_AFTER:
            let up = ev.flags & UInt32(RW_MOUSE_RELEASE) != 0
            let b = Int(ev.button)
            if ev.type == RW_EV_CHILD_MOUSE {
                countClick(point, button: b)
                if up { buttonsDown &= ~(1 << b) } else { buttonsDown |= 1 << b }
            }
            return sendRaw(up ? .mouseUp : .mouseDown, at: point, mods: RawModifiers(ev.mods), button: b,
                           monitor: ev.type == RW_EV_CHILD_MOUSE, onNative: true)
        case RW_EV_TIMER: invalidate()
        case RW_EV_MOVED: onMove?(CGPoint(x: ev.x, y: ev.y))
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

    /// The deepest native control at a window point (the picked widget or
    /// the nearest of its ancestors that handles the pointer itself).
    func hit(_ point: CGPoint) -> DrawnWidget? {
        pick(point).last { $0.isInteractive }
    }

    /// The widgets under a point, outermost first, ending with the deepest
    /// one that takes it: as a toolkit picks, a container counts where it
    /// has no child, unless it lets the pointer through its gaps or (an
    /// AppKit view) says the point isn't its own.
    func pick(_ point: CGPoint) -> [DrawnWidget] { pickPath(root, point, origin: .zero) ?? [] }

    private func pickPath(_ w: DrawnWidget, _ p: CGPoint, origin: CGPoint) -> [DrawnWidget]? {
        let f = w.frame.offsetBy(dx: origin.x, dy: origin.y)
        if w.props.opacity <= 0.01 || !w.hitTestable { return nil }
        if case .scroll = w.kind {
            guard f.contains(p) else { return nil }
            if scrollbarHit(w, f, p) != nil { return [w] }
            if let doc = w.document {
                let o = CGPoint(x: f.minX - w.scrollOffset.x, y: f.minY - w.scrollOffset.y)
                for c in doc.children.reversed() { if let s = pickPath(c, p, origin: o) { return [w] + s } }
            }
            return [w]
        }
        if w.props.clips, !f.contains(p) { return nil }
        for c in w.children.reversed() { if let s = pickPath(c, p, origin: f.origin) { return [w] + s } }
        guard f.contains(p) else { return nil }
        // Shapes and dividers are drawing only, unless they ask for the pointer.
        if w.kind == .canvas || w.kind == .divider, !w.props.hitTestable { return nil }
        if w.kind == .container, w !== root {
            if w.passesThrough { return nil }
            if let owns = w.ownsPoint, !owns(CGPoint(x: p.x - f.minX, y: p.y - f.minY)) { return nil }
        }
        return [w]
    }

    /// Sends a pointer event to a container in its own coordinates.
    @discardableResult
    func deliver(_ kind: PointerEvent.Kind, to c: DrawnWidget, at p: CGPoint, button: Int = 0) -> Bool {
        guard let handler = c.pointerHandler else { return false }
        let f = c.windowFrame
        return handler(PointerEvent(kind: kind, location: CGPoint(x: p.x - f.minX, y: p.y - f.minY), button: button,
                                    clickCount: clickCount, modifiers: keyModifiers))
    }

    /// Entered, moved and exited for the containers the pointer is over.
    func updateHover(_ p: CGPoint) {
        let now = p.x < -1e5 ? [] : pointerContainers(at: p)
        let old = hoverChain
        hoverChain = now
        for c in old where !now.contains(where: { $0 === c }) { deliver(.exited, to: c, at: p) }
        for c in now {
            if !old.contains(where: { $0 === c }) { deliver(.entered, to: c, at: p) }
            deliver(.moved, to: c, at: p)
        }
    }

    /// The tooltip of what's under `p` (the innermost widget with one),
    /// shown after a pause as on the Mac and hidden once the pointer
    /// leaves it, presses or types (nil).
    func updateTooltip(_ p: CGPoint?) {
        let text = p.flatMap { point in pick(point).reversed().lazy.compactMap { $0.props.tooltip }.first { !$0.isEmpty } }
        guard text != tooltipText else { return }
        if DrawnBackend.debugInput { FileHandle.standardError.write("tooltip \(text ?? "-")\n".data(using: .utf8)!) }
        tooltipText = text
        tooltipGeneration += 1
        if tooltipShown, let n = native {
            rw_window_set_tooltip(n, nil, 0, 0)
            tooltipShown = false
        }
        guard let text else { return }
        let generation = tooltipGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.tooltipGeneration == generation, let n = self.native else { return }
                self.tooltipShown = true
                rw_window_set_tooltip(n, text, Double(self.mouse.x), Double(self.mouse.y))
            }
        }
    }

    /// The pointer containers (SwiftUI's gestures, hover and context menus)
    /// a point is over, innermost first.
    func pointerContainers(at p: CGPoint) -> [DrawnWidget] {
        pick(p).reversed().filter { $0.pointerHandler != nil }
    }

    /// The innermost scroll view at a point, and its window frame.
    private func scrollViews(at p: CGPoint) -> [DrawnWidget] {
        var out: [DrawnWidget] = []
        func walk(_ w: DrawnWidget, _ origin: CGPoint) {
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
    func scrollbarHit(_ w: DrawnWidget, _ f: CGRect, _ p: CGPoint) -> Bool? {
        let m = w.maxScroll
        if m.y > 0.5, p.x >= f.maxX - 12, p.x <= f.maxX { return true }
        if m.x > 0.5, p.y >= f.maxY - 12, p.y <= f.maxY { return false }
        return nil
    }

    /// The thumb of a scroll bar: (position, length) along the track.
    func thumb(_ w: DrawnWidget, vertical: Bool) -> (CGFloat, CGFloat, CGFloat) {
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
        applyCursor()
    }

    /// The pointer's shape: the hovered control's, else what AppKit set for
    /// the window (cursor rects), else an arrow.
    func applyCursor() {
        guard let n = native else { return }
        if let h = hovered, h.props.enabled {
            if let c = h.cursor { rw_window_set_cursor(n, DrawnBackend.cursorID(c)); return }
            if h.kind == .link { rw_window_set_cursor(n, RW_CURSOR_HAND); return }
            if case .textField = h.kind { rw_window_set_cursor(n, RW_CURSOR_IBEAM); return }
        }
        switch windowCursor {
        case let .named(name)?: rw_window_set_cursor(n, DrawnBackend.cursorID(named: name))
        case .hidden?: rw_window_set_cursor(n, RW_CURSOR_HIDDEN)
        case let .image(width, height, rgba, hot)?:
            rgba.withUnsafeBufferPointer { rw_window_set_cursor_image(n, Int32(width), Int32(height), $0.baseAddress, Int32(hot.x), Int32(hot.y)) }
        case nil: rw_window_set_cursor(n, RW_CURSOR_ARROW)
        }
    }
    var windowCursor: CursorSpec? {
        didSet { if windowCursor != oldValue { applyCursor() } }
    }

    private func mouseDown(_ p: CGPoint, button: Int, _ n: OpaquePointer) {
        mouse = p
        let native = hit(p)
        let claimed = native.map { $0.props.enabled && (button == 0 || (button == 1 && !$0.events.menu.isEmpty)) } ?? false
        if !claimed {
            // Gesture and hover containers under the press, innermost first,
            // until one takes it; they follow the pointer until release.
            let chain = pointerContainers(at: p)
            if let f = chain.first(where: { $0.focusable }) { setFocusedContainer(f) } else if focusedContainer != nil { setFocusedContainer(nil) }
            pressChain = []
            for c in chain {
                pressChain.append(c)
                if deliver(.down, to: c, at: p, button: button) { break }
            }
            if !pressChain.isEmpty { rw_window_capture(n, 1) }
            if native == nil || button != 0 { return }
        }
        guard let w = native, w.props.enabled else { return }
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
            if let r = w.rich { rw_rich_focus(r.pointer) } else if let e = w.edit { rw_edit_focus(e.pointer, 0) }
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
        if !pressChain.isEmpty {
            let chain = pressChain
            pressChain = []
            rw_window_capture(n, 0)
            for c in chain where deliver(.up, to: c, at: p, button: button) { break }
            updateHover(p)
            if drag == nil { return }
        }
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
    private func activate(_ w: DrawnWidget, at p: CGPoint, _ n: OpaquePointer) {
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

    private func setSlider(_ w: DrawnWidget, _ p: CGPoint) {
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

    @discardableResult
    private func wheel(_ p: CGPoint, _ delta: CGPoint) -> Bool {
        var scrolled = false
        defer { if hoveredScroll == nil { hoveredScroll = scrollViews(at: p).last } }
        for s in scrollViews(at: p).reversed() {
            let m = s.maxScroll
            let canX = delta.x != 0 && m.x > 0.5, canY = delta.y != 0 && m.y > 0.5
            guard canX || canY else { continue }
            let target = CGPoint(x: s.scrollOffset.x + (canX ? delta.x : 0), y: s.scrollOffset.y + (canY ? delta.y : 0))
            let before = s.scrollOffset
            scroll(s, to: target)
            if s.scrollOffset != before { scrolled = true; break }
        }
        return scrolled
    }

    func scroll(_ s: DrawnWidget, to p: CGPoint) {
        let m = s.maxScroll
        let clamped = CGPoint(x: max(0, min(m.x, p.x)).rounded(), y: max(0, min(m.y, p.y)).rounded())
        guard clamped != s.scrollOffset else { return }
        s.scrollOffset = clamped
        invalidate()
        s.scrollObserver?(clamped)
    }

    // MARK: Menus

    private func showOptions(_ w: DrawnWidget, _ f: CGRect, _ n: OpaquePointer) {
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
        guard let press = Keys.press(vk, mods: mods) else { return false }
        let name = press.key
        if name == "f12", press.command, press.shift { dumpTree(); return true }
        if let c = focusedContainer, let k = c.keyHandler, k(press) { return true }
        if pressKeyEquivalent(press) { return true }
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

    /// Ctrl+Shift+F12: the widget tree on stderr (diagnostics).
    func dumpTree() {
        var out = ""
        func walk(_ w: DrawnWidget, _ depth: Int) {
            let f = w.frame
            out += String(repeating: "  ", count: depth) + "\(w.kind) [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]"
            if w.props.opacity < 1 { out += " a=\(w.props.opacity)" }
            if case let .symbol(n) = w.props.image { out += " symbol=\(n) pt=\(w.props.imagePointSize) tint=\(String(describing: w.props.imageTint))" }
            if let t = w.props.text { out += " \"" + t.runs.map(\.string).joined().prefix(30) + "\"" }
            if !w.props.title.isEmpty { out += " title=\(w.props.title)" }
            if w.pointerHandler != nil { out += " pointer" }
            if w.passesThrough { out += " through" }
            out += "\n"
            for c in w.children { walk(c, depth + 1) }
            if let d = w.document { walk(d, depth + 1) }
        }
        walk(root, 0)
        FileHandle.standardError.write(out.data(using: .utf8) ?? Data())
    }

    var focusedField: DrawnWidget? { editOrder.first { $0.editFocused } }

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
    func placeEdit(_ w: DrawnWidget, frame: CGRect, clip: CGRect, multiline: Bool, style: (size: CGFloat, text: RGBA, background: RGBA)) {
        guard let n = native else { return }
        let id = ObjectIdentifier(w)
        if w.edit == nil || w.editWindow !== self {
            w.edit = nil
            guard let e = rw_edit_create(n, multiline ? 1 : 0, Unmanaged.passUnretained(w).toOpaque()) else { return }
            w.edit = NativeHandle(e, release: { rw_edit_destroy($0) })
            w.editWindow = self
            w.editText = w.props.string
            rw_edit_set_text(e, w.props.string)
            rw_edit_set_alignment(e, w.fieldAlignment == .center ? RW_ALIGN_CENTER : w.fieldAlignment == .trailing ? RW_ALIGN_TRAILING : RW_ALIGN_LEADING)
            rw_edit_set_readonly(e, w.fieldEditable ? 0 : 1)
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
        if w.wantsFocus {
            w.wantsFocus = false
            rw_edit_focus(e, 0)
        }
    }

    func beginEditPass() {
        richesSeen.removeAll(keepingCapacity: true)
        editsSeen.removeAll(keepingCapacity: true)
        editOrder.removeAll(keepingCapacity: true)
    }

    /// Hides EDITs whose fields were not drawn (scrolled away, removed, hidden).
    func endEditPass() {
        for (id, ref) in edits {
            guard let w = ref.widget else { edits[id] = nil; continue }
            if !editsSeen.contains(id), let e = w.edit { rw_edit_set_frame(e.pointer, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        }
        for (id, ref) in riches {
            guard let w = ref.widget else { riches[id] = nil; continue }
            if !richesSeen.contains(id), let r = w.rich { rw_rich_set_frame(r.pointer, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        }
    }
}

/// Virtual-key codes to the key names `KeyPress` uses (SwiftUI's KeyEquivalent names).
enum Keys {
    static func press(_ vk: Int, mods: UInt32) -> KeyPress? {
        guard let name = name(vk) else { return nil }
        return KeyPress(key: name, command: mods & UInt32(RW_MOD_CTRL) != 0, shift: mods & UInt32(RW_MOD_SHIFT) != 0,
                        option: mods & UInt32(RW_MOD_ALT) != 0, control: mods & UInt32(RW_MOD_WIN) != 0)
    }

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
