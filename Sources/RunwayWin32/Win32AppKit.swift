// AppKit's view system and controls on the drawn backend: raw window input
// (AppKit hit-tests and dispatches it itself), the menu bar, context menus,
// cursors, drag and drop, screens, focus, scroll views, text fields, rich
// text views (RichEdit), popovers (owned popup windows) and tray icons.
//
// The routing mirrors the GTK backend's: presses, releases and drags go to
// AppKit's local monitors first (`monitorPhase`), then to the control under
// the pointer, then to AppKit as ordinary events; keys go to AppKit before
// any control sees them.

#if os(Windows)
import Foundation
import RunwayCore
import CoreGraphics
import CRunwayWin32

extension RawModifiers {
    init(_ mods: UInt32) {
        var m: RawModifiers = []
        if mods & UInt32(RW_MOD_SHIFT) != 0 { m.insert(.shift) }
        if mods & UInt32(RW_MOD_CTRL) != 0 { m.insert(.control) }
        if mods & UInt32(RW_MOD_ALT) != 0 { m.insert(.alt) }
        if mods & UInt32(RW_MOD_WIN) != 0 { m.insert(.super) }
        if mods & 16 != 0 { m.insert(.capsLock) }
        self = m
    }
}

extension KeyModifiers {
    init(raw: RawModifiers) {
        var m: KeyModifiers = []
        if raw.contains(.control) { m.insert(.command) }
        if raw.contains(.shift) { m.insert(.shift) }
        if raw.contains(.alt) { m.insert(.option) }
        if raw.contains(.super) { m.insert(.control) }
        self = m
    }
}

private func string(_ p: UnsafePointer<CChar>?) -> String { p.map { String(cString: $0) } ?? "" }

// MARK: Window routing

extension W32Window {
    func countClick(_ p: CGPoint, button: Int) {
        let now = uptime
        if let l = lastClick, l.button == button, now - l.time < 0.5, abs(l.point.x - p.x) < 5, abs(l.point.y - p.y) < 5 {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastClick = (now, p, button)
    }

    func rawEvent(_ kind: RawEvent.Kind, at p: CGPoint, mods: RawModifiers) -> RawEvent {
        var e = RawEvent(kind: kind)
        e.location = p
        e.modifiers = mods
        e.timestamp = uptime
        return e
    }

    /// Offers a pointer event to AppKit; true when it was consumed.
    func sendRaw(_ kind: RawEvent.Kind, at p: CGPoint, mods: RawModifiers, button: Int = 0, monitor: Bool = false, onNative: Bool = false) -> Bool {
        guard let handler = rawHandler else { return false }
        var e = rawEvent(kind, at: p, mods: mods)
        e.button = button
        e.monitorPhase = monitor
        e.onNativeControl = onNative
        return handler(e)
    }

    func rawKey(_ ev: rw_event) -> Bool {
        let up = ev.flags & UInt32(RW_KEY_UP) != 0
        let modifier = ev.flags & UInt32(RW_KEY_MODIFIER) != 0
        // A popover's own keys come first (they don't reach its anchor's window).
        if let pop = popover, !up, !modifier, let handler = pop.keyHandler, let press = Keys.press(Int(ev.key), mods: ev.mods), handler(press) { return true }
        guard let handler = rawHandler else { return false }
        var e = RawEvent(kind: modifier ? .flagsChanged : (up ? .keyUp : .keyDown))
        e.modifiers = RawModifiers(ev.mods)
        e.timestamp = uptime
        e.keyCode = UInt32(ev.key)
        e.keyName = string(ev.text2)
        e.characters = string(ev.text)
        e.charactersIgnoringModifiers = e.characters
        e.isRepeat = ev.flags & UInt32(RW_KEY_REPEAT) != 0
        e.nativeTextFocus = ev.flags & UInt32(RW_KEY_NATIVE_TEXT) != 0
        e.location = mouse
        return handler(e)
    }

    func dragEvent(_ ev: rw_event) -> RawDragOperation {
        guard let handler = dropHandler else { return [] }
        let kind: RawDragEvent.Kind = switch ev.button { case 0: .entered; case 1: .updated; case 2: .exited; default: .perform }
        let files = string(ev.text).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        let text = string(ev.text2)
        return handler(RawDragEvent(kind: kind, location: CGPoint(x: ev.x, y: ev.y), fileURLs: files, strings: text.isEmpty ? [] : [text]))
    }

    func setFocusedContainer(_ w: W32Widget?) {
        guard w !== focusedContainer else { return }
        let old = focusedContainer
        focusedContainer = w
        old?.focusObserver?(false)
        if let n = native, w != nil { rw_window_focus(n) }
        w?.focusObserver?(true)
        invalidate()
    }

    /// A button whose key equivalent this is, anywhere in the window.
    func pressKeyEquivalent(_ press: KeyPress) -> Bool {
        func find(_ w: W32Widget) -> W32Widget? {
            if w.keyEquivalent == press, w.props.enabled, w.props.opacity > 0.01 { return w }
            for c in w.children { if let f = find(c) { return f } }
            if let d = w.document { return find(d) }
            return nil
        }
        guard let b = find(root) else { return false }
        if case .toggle = b.kind { b.events.onToggle?(!b.props.isOn) } else { b.events.onTap?() }
        return true
    }

    func closePopoverWindow() {
        guard let pop = popover else { return }
        popover = nil
        close()
        pop.onClose()
    }

    /// Creates or moves `w`'s RichEdit to its frame (called while painting).
    func placeRich(_ w: W32Widget, frame: CGRect, clip: CGRect, background: RGBA) {
        guard let n = native else { return }
        let id = ObjectIdentifier(w)
        backend.ensureRich(w, in: self)
        guard let r = w.rich?.pointer else { return }
        if riches[id]?.widget !== w { riches[id] = Weak(w) }
        richesSeen.insert(id)
        _ = n
        backend.applyRichConfig(w, background: background)
        rw_rich_set_frame(r, Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height),
                          Double(clip.minX), Double(clip.minY), Double(clip.width), Double(clip.height), 1)
        if w.wantsFocus {
            w.wantsFocus = false
            rw_rich_focus(r)
        }
    }
}

// MARK: Menu bar

/// A window's menu bar: native ids (1…65535) for the AppKit layer's.
@MainActor final class MenuBarState {
    var ids: [Int32: Int] = [:]
    var callbacks: MenuCallbacks
    init(callbacks: MenuCallbacks) { self.callbacks = callbacks }

    func activate(_ native: Int) {
        guard let id = ids[Int32(native)] else { return }
        callbacks.activate(id)
    }

    func refresh(_ window: OpaquePointer) {
        let reverse = Dictionary(ids.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for s in callbacks.validate() {
            if let n = reverse[s.id] { rw_window_menu_item_state(window, n, s.enabled ? 1 : 0, s.checked ? 1 : 0) }
        }
    }
}

enum MenuText {
    /// "<Control><Shift>z" → "Ctrl+Shift+Z".
    static func accelerator(_ a: String?) -> String? {
        guard var s = a, !s.isEmpty else { return nil }
        var parts: [String] = []
        let names = ["<Control>": "Ctrl", "<Primary>": "Ctrl", "<Shift>": "Shift", "<Alt>": "Alt", "<Super>": "Win", "<Meta>": "Win"]
        while s.hasPrefix("<"), let end = s.firstIndex(of: ">") {
            let tag = String(s[s.startIndex...end])
            if let n = names[tag] { parts.append(n) }
            s = String(s[s.index(after: end)...])
        }
        let keys = ["Return": "Enter", "Escape": "Esc", "BackSpace": "Backspace", "Delete": "Del", "comma": ",", "period": ".",
                    "slash": "/", "semicolon": ";", "bracketleft": "[", "bracketright": "]", "minus": "-", "equal": "=", "plus": "+",
                    "Left": "Left", "Right": "Right", "Up": "Up", "Down": "Down", "space": "Space", "Tab": "Tab", "backslash": "\\",
                    "apostrophe": "'", "grave": "`", "Page_Up": "PgUp", "Page_Down": "PgDn"]
        parts.append(keys[s] ?? (s.count == 1 ? s.uppercased() : s))
        return parts.joined(separator: "+")
    }

    static func title(_ node: MenuNode) -> String {
        if let a = accelerator(node.accelerator) { return node.title + "\t" + a }
        return node.title
    }
}

// MARK: Popovers

@MainActor final class PopoverState {
    let transient: Bool
    let onClose: @MainActor () -> Void
    var keyHandler: (@MainActor (KeyPress) -> Bool)?
    weak var anchor: W32Widget?
    var rect: CGRect
    var edge: PopoverEdge
    init(transient: Bool, anchor: W32Widget, rect: CGRect, edge: PopoverEdge, onClose: @escaping @MainActor () -> Void) {
        self.transient = transient; self.anchor = anchor; self.rect = rect; self.edge = edge; self.onClose = onClose
    }
}

// MARK: Tray

@MainActor final class W32Tray {
    var native: OpaquePointer?
    let menu: @MainActor () -> [MenuItemSpec]
    let activate: @MainActor () -> Void
    init(menu: @escaping @MainActor () -> [MenuItemSpec], activate: @escaping @MainActor () -> Void) {
        self.menu = menu; self.activate = activate
    }
    func clicked(secondary: Bool) {
        let items = menu()
        if secondary || !items.isEmpty, let w = Win32Backend.current?.activeWindow, let n = w.native, !items.isEmpty {
            // At the pointer: the tray sits outside every window.
            w.showMenu(items, at: w.screenPointer(), n)
        } else {
            activate()
        }
    }
}

extension W32Window {
    /// The pointer in this window's coordinates, wherever it is on screen.
    func screenPointer() -> CGPoint { mouse }
}

// MARK: The view system

extension Win32Backend: ViewSystemBackend {
    func w32(_ w: NativeWindow) -> W32Window? { w as? W32Window }

    public func setEventHandler(_ window: NativeWindow, _ handler: ((RawEvent) -> Bool)?) { w32(window)?.rawHandler = handler }
    public func setActivationHandler(_ window: NativeWindow, _ handler: ((Bool) -> Void)?) { w32(window)?.activationHandler = handler }
    public func setDropHandler(_ window: NativeWindow, _ handler: ((RawDragEvent) -> RawDragOperation)?) {
        guard let w = w32(window) else { return }
        w.dropHandler = handler
        if let n = w.native { rw_window_accept_drops(n, handler == nil ? 0 : 1) }
    }
    public func setCursor(_ cursor: CursorSpec, in window: NativeWindow) { w32(window)?.windowCursor = cursor }

    public func setMenuBar(_ menu: [MenuNode]?, in window: NativeWindow, callbacks: MenuCallbacks) {
        guard let w = w32(window), let n = w.native else { return }
        guard let menu, let bar = rw_menubar_create() else {
            rw_window_set_menubar(n, nil)
            w.menuBar = nil
            return
        }
        let state = MenuBarState(callbacks: callbacks)
        var next: Int32 = 1
        func add(_ nodes: [MenuNode], to m: OpaquePointer) {
            for node in nodes {
                switch node.kind {
                case .separator: rw_menu_add_separator(m)
                case .submenu:
                    if let sub = rw_menu_add_submenu(m, node.title, node.enabled ? 1 : 0) { add(node.children, to: sub) }
                case .item:
                    guard next < 65535 else { continue }
                    state.ids[next] = node.id
                    rw_menu_add(m, MenuText.title(node), next, node.enabled ? 1 : 0, node.checked ? 1 : 0)
                    next += 1
                }
            }
        }
        add(menu, to: bar)
        rw_window_set_menubar(n, bar)   // the window owns it now
        w.menuBar = state
    }

    public func popUpMenu(_ menu: [MenuNode], in window: NativeWindow, at point: CGPoint, callbacks: MenuCallbacks) {
        guard let w = w32(window) else { return }
        let states = Dictionary(callbacks.validate().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func specs(_ nodes: [MenuNode]) -> [MenuItemSpec] {
            nodes.map { node in
                switch node.kind {
                case .separator: return .separator
                case .submenu: return MenuItemSpec(title: node.title, enabled: node.enabled, children: specs(node.children)) {}
                case .item:
                    let s = states[node.id]
                    return MenuItemSpec(title: MenuText.title(node), enabled: s?.enabled ?? node.enabled, checked: s?.checked ?? node.checked) {
                        callbacks.activate(node.id)
                    }
                }
            }
        }
        if let n = w.native { w.showMenu(specs(menu), at: point, n) }
    }

    public func screens() -> [ScreenSpec] {
        var values = [Double](repeating: 0, count: 9 * 16)
        let count = Int(values.withUnsafeMutableBufferPointer { rw_screens($0.baseAddress, 16) })
        return (0..<count).map { i in
            let v = Array(values[i * 9..<i * 9 + 9])
            return ScreenSpec(frame: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]),
                              visibleFrame: CGRect(x: v[4], y: v[5], width: v[6], height: v[7]), scale: CGFloat(v[8]), name: "Display \(i + 1)")
        }
    }

    public func measureText(_ layout: CGTextLayout) -> CGSize { DisplayListPlayer.measure(layout) }

    public func setKeyboardFocus(_ widget: NativeWidget?, in window: NativeWindow) {
        guard let win = w32(window) else { return }
        if let w = widget as? W32Widget {
            focus(w)
        } else {
            win.setFocusedContainer(nil)
            if let n = win.native { rw_window_focus(n) }
        }
    }

    public func setDecorated(_ decorated: Bool, window: NativeWindow) {
        if let n = w32(window)?.native { rw_window_set_decorated(n, decorated ? 1 : 0) }
    }

    public func setPreferredColorScheme(_ scheme: ColorSchemeValue?) {
        let s = scheme ?? (rw_dark_mode() != 0 ? .dark : .light)
        preferredScheme = scheme
        guard s != colorScheme else { return }
        setColorScheme(s)
    }

    public func activate(_ window: NativeWindow) { if let n = w32(window)?.native { rw_window_activate(n) } }

    static func cursorID(named name: String) -> Int32 {
        switch name {
        case "pointer": RW_CURSOR_HAND
        case "text", "vertical-text": RW_CURSOR_IBEAM
        case "crosshair", "cell": RW_CURSOR_CROSS
        case "ew-resize", "col-resize", "e-resize", "w-resize": RW_CURSOR_SIZEWE
        case "ns-resize", "row-resize", "n-resize", "s-resize": RW_CURSOR_SIZENS
        case "move", "grab", "grabbing", "all-scroll": RW_CURSOR_SIZEALL
        case "not-allowed", "no-drop": RW_CURSOR_NO
        case "wait": RW_CURSOR_WAIT
        case "progress": RW_CURSOR_PROGRESS
        case "help", "context-menu": RW_CURSOR_HELP
        case "nwse-resize", "nw-resize", "se-resize": RW_CURSOR_SIZENWSE
        case "nesw-resize", "ne-resize", "sw-resize": RW_CURSOR_SIZENESW
        case "none": RW_CURSOR_HIDDEN
        default: RW_CURSOR_ARROW
        }
    }

    static func cursorID(_ kind: CursorKind) -> Int32 {
        switch kind {
        case .arrow: RW_CURSOR_ARROW
        case .pointingHand: RW_CURSOR_HAND
        case .iBeam: RW_CURSOR_IBEAM
        case .resizeLeftRight: RW_CURSOR_SIZEWE
        case .resizeUpDown: RW_CURSOR_SIZENS
        }
    }
}

// MARK: AppKit's controls

extension Win32Backend: AppKitBackend {
    private func widget(_ w: NativeWidget) -> W32Widget { w as! W32Widget }

    public func makeEventContainer(focusable: Bool, pointer: @escaping @MainActor (PointerEvent) -> Bool,
                                   key: @escaping @MainActor (KeyPress) -> Bool) -> NativeWidget {
        let w = W32Widget(.container)
        w.pointerHandler = pointer
        w.keyHandler = key
        w.focusable = focusable
        return w
    }

    public func focus(_ native: NativeWidget) {
        let w = widget(native)
        guard let win = w.window else { w.wantsFocus = true; return }
        if w.isRich {
            ensureRich(w, in: win)
            if let r = w.rich { rw_rich_focus(r.pointer) } else { w.wantsFocus = true }
        } else if w.edit != nil || w.kind == .textEditor || { if case .textField = w.kind { return true }; return false }() {
            if let e = w.edit { rw_edit_focus(e.pointer, 0) } else { w.wantsFocus = true; win.invalidate() }
        } else if w.focusable || w.keyHandler != nil {
            win.setFocusedContainer(w)
        } else if let n = win.native {
            win.setFocusedContainer(nil)
            rw_window_focus(n)
        }
    }

    public func resignFocus(_ native: NativeWidget) {
        let w = widget(native)
        guard let win = w.window, let n = win.native else { return }
        if win.focusedContainer === w { win.setFocusedContainer(nil) }
        if let e = w.edit, rw_edit_has_focus(e.pointer) != 0 { rw_window_focus(n) }
        if let r = w.rich, rw_rich_has_focus(r.pointer) != 0 { rw_window_focus(n) }
    }

    public func setHitTestable(_ native: NativeWidget, _ testable: Bool) { widget(native).hitTestable = testable }
    public func setOwnsPoint(_ container: NativeWidget, _ owns: (@MainActor (CGPoint) -> Bool)?) { widget(container).ownsPoint = owns }
    public func observeFocus(_ native: NativeWidget, _ changed: @escaping @MainActor (Bool) -> Void) { widget(native).focusObserver = changed }
    public func setCursor(_ native: NativeWidget, _ cursor: CursorKind) {
        let w = widget(native)
        w.cursor = cursor
        if w.window?.hovered === w { w.window?.applyCursor() }
    }

    // Scroll views.
    public func scrollOffset(_ scroll: NativeWidget) -> CGPoint { widget(scroll).scrollOffset }
    public func setScrollOffset(_ scroll: NativeWidget, _ offset: CGPoint) {
        let w = widget(scroll)
        let m = w.maxScroll
        let p = CGPoint(x: max(0, min(offset.x, m.x)), y: max(0, min(offset.y, m.y)))
        guard p != w.scrollOffset else { return }
        w.scrollOffset = p
        w.invalidate()
    }
    public func scrollViewportSize(_ scroll: NativeWidget) -> CGSize { widget(scroll).frame.size }
    public func observeScroll(_ scroll: NativeWidget, _ changed: @escaping @MainActor (CGPoint) -> Void) { widget(scroll).scrollObserver = changed }
    public func setScrollers(_ scroll: NativeWidget, horizontal: Bool, vertical: Bool, autohides: Bool, bordered: Bool) {
        let w = widget(scroll)
        w.scrollers = (horizontal, vertical)
        w.invalidate()
    }

    // Text fields and buttons.
    public func observeTextField(_ field: NativeWidget, focus: @escaping @MainActor (Bool) -> Void, key: @escaping @MainActor (KeyPress) -> Bool) {
        let w = widget(field)
        w.fieldFocus = focus
        w.fieldKey = key
    }
    public func setSearchField(_ field: NativeWidget, _ search: Bool) { widget(field).searchField = search; widget(field).invalidate() }
    public func setKeyEquivalent(_ button: NativeWidget, _ key: KeyPress?) { widget(button).keyEquivalent = key }
    public func setRadio(_ checkbox: NativeWidget) { widget(checkbox).radio = true; widget(checkbox).invalidate() }
    public func setStyleClass(_ native: NativeWidget, _ name: String, _ on: Bool) {
        let w = widget(native)
        if on { w.styleClasses.insert(name) } else { w.styleClasses.remove(name) }
        w.invalidate()
    }
    public func setTextFieldAlignment(_ field: NativeWidget, _ alignment: TextAlignmentValue) {
        let w = widget(field)
        w.fieldAlignment = alignment
        if let e = w.edit { rw_edit_set_alignment(e.pointer, alignment == .center ? RW_ALIGN_CENTER : alignment == .trailing ? RW_ALIGN_TRAILING : RW_ALIGN_LEADING) }
    }
    public func setTextFieldEditable(_ field: NativeWidget, _ editable: Bool) {
        let w = widget(field)
        w.fieldEditable = editable
        if let e = w.edit { rw_edit_set_readonly(e.pointer, editable ? 0 : 1) }
    }

    // Rich text.
    public func makeTextView() -> NativeWidget {
        let w = W32Widget(.textEditor)
        w.isRich = true
        return w
    }

    public func configureTextView(_ view: NativeWidget, _ config: TextViewConfig, events: TextViewEvents) {
        let w = widget(view)
        w.richConfig = config
        w.richEvents = events
        w.richConfigApplied = nil
        w.invalidate()
    }

    public func setTextViewContent(_ view: NativeWidget, _ runs: [RichTextRun]) {
        let w = widget(view)
        w.richRuns = runs
        w.richString = runs.map(\.string).joined()
        let count = w.richString.unicodeScalars.count
        if w.richSelection.upperBound > count { w.richSelection = count..<count }
        if let r = w.rich?.pointer {
            withRichRuns(runs, w.richConfig) { rw_rich_set_runs(r, $0, $1) }
            setNativeSelection(w, w.richSelection)
        }
        w.richHeight = 0
        w.invalidate()
    }

    public func textViewSelection(_ view: NativeWidget) -> Range<Int> {
        let w = widget(view)
        if let r = w.rich?.pointer {
            var a: Int32 = 0, b: Int32 = 0
            rw_rich_get_selection(r, &a, &b)
            let s = TextOffsets.scalarOffset(utf16: Int(a), in: w.richString)
            let e = TextOffsets.scalarOffset(utf16: Int(b), in: w.richString)
            w.richSelection = s..<max(s, e)
        }
        return w.richSelection
    }

    public func setTextViewSelection(_ view: NativeWidget, _ range: Range<Int>) {
        let w = widget(view)
        w.richSelection = range
        setNativeSelection(w, range)
    }

    private func setNativeSelection(_ w: W32Widget, _ range: Range<Int>) {
        guard let r = w.rich?.pointer else { return }
        let a = TextOffsets.utf16Offset(scalar: range.lowerBound, in: w.richString)
        let b = TextOffsets.utf16Offset(scalar: range.upperBound, in: w.richString)
        rw_rich_set_selection(r, Int32(a), Int32(b))
    }

    public func textViewUndo(_ view: NativeWidget, redo: Bool) {
        if let r = widget(view).rich?.pointer { rw_rich_undo(r, redo ? 1 : 0) }
    }

    public func textViewHeight(_ view: NativeWidget, width: CGFloat) -> CGFloat {
        let w = widget(view)
        if w.rich == nil, let win = w.window ?? activeWindow { ensureRich(w, in: win) }
        if let r = w.rich?.pointer { return CGFloat(rw_rich_height(r, Double(width))) }
        // No window yet: measure the runs as plain styled text.
        let box = TextBox()
        box.set(StyledText(runs: w.richRuns.map { TextRun(string: $0.string, font: $0.font, color: $0.color) }))
        let c = w.richConfig
        return box.measure(max(1, width - c.insets.leading - c.insets.trailing)).height + c.insets.top + c.insets.bottom
    }

    public func textViewCharacterRect(_ view: NativeWidget, at offset: Int) -> CGRect {
        textViewCharacterLayout(view, at: offset).rect
    }

    public func textViewCharacterLayout(_ view: NativeWidget, at offset: Int) -> TextCharacterLayout {
        let w = widget(view)
        guard let r = w.rich?.pointer else {
            let h = w.richConfig.font.size * 1.3
            let rect = CGRect(x: w.richConfig.insets.leading, y: w.richConfig.insets.top, width: 0, height: h)
            return TextCharacterLayout(rect: rect, lineTop: rect.minY, lineBottom: rect.maxY, baseline: rect.minY + h * 0.8)
        }
        let u = TextOffsets.utf16Offset(scalar: offset, in: w.richString)
        var x = 0.0, y = 0.0, cw = 0.0, ch = 0.0
        rw_rich_char_rect(r, Int32(u), &x, &y, &cw, &ch)
        let rect = CGRect(x: x, y: y, width: cw, height: ch)
        return TextCharacterLayout(rect: rect, lineTop: rect.minY, lineBottom: rect.maxY, baseline: rect.minY + rect.height * 0.8)
    }

    public func textViewCharacterIndex(_ view: NativeWidget, at point: CGPoint) -> Int {
        let w = widget(view)
        guard let r = w.rich?.pointer else { return 0 }
        let u = Int(rw_rich_char_index(r, Double(point.x), Double(point.y)))
        return TextOffsets.scalarOffset(utf16: u, in: w.richString)
    }

    public func editTextView(_ view: NativeWidget, replacing range: Range<Int>, with runs: [RichTextRun], all: () -> [RichTextRun]) {
        let w = widget(view)
        let old = w.richString
        let everything = all()
        w.richRuns = everything
        w.richString = everything.map(\.string).joined()
        guard let r = w.rich?.pointer else { w.invalidate(); return }
        let a = TextOffsets.utf16Offset(scalar: range.lowerBound, in: old)
        let b = TextOffsets.utf16Offset(scalar: range.upperBound, in: old)
        withRichRuns(runs, w.richConfig) { rw_rich_replace(r, Int32(a), Int32(b), $0, $1) }
    }

    public func textViewMove(_ view: NativeWidget, by step: TextMoveStep, count: Int, extend: Bool) {
        let w = widget(view)
        guard let r = w.rich?.pointer else { return }
        let s: Int32 = switch step {
        case .character: 0
        case .word: 1
        case .displayLine: 2
        case .displayLineEnd: 3
        case .paragraph: 4
        case .paragraphEnd: 5
        case .page: 6
        case .document: 7
        }
        rw_rich_move(r, s, Int32(count), extend ? 1 : 0)
        let sel = textViewSelection(view)
        w.richEvents.selectionChanged?(sel)
    }

    // Popovers.
    public func showPopover(_ content: NativeWidget, size: CGSize, anchor: NativeWidget, rect: CGRect, edge: PopoverEdge,
                            transient: Bool, onClose: @escaping @MainActor () -> Void) -> AnyObject {
        let a = widget(anchor)
        guard let owner = a.window else { return PopoverState(transient: transient, anchor: a, rect: rect, edge: edge, onClose: onClose) }
        let pop = W32Window(WindowOptions(title: "", size: size, resizable: false, modal: false), parent: owner, backend: self, popup: true)
        windows.append(pop)
        let state = PopoverState(transient: transient, anchor: a, rect: rect, edge: edge, onClose: onClose)
        pop.popover = state
        let c = widget(content)
        setChildren(pop.root, [(c, CGRect(origin: .zero, size: size))], contentSize: size)
        placePopover(pop, size: size)
        if let n = pop.native {
            rw_window_set_dark(n, colorScheme == .dark ? 1 : 0)
            rw_window_show(n)
        }
        return pop
    }

    private func placePopover(_ pop: W32Window, size: CGSize) {
        guard let state = pop.popover, let a = state.anchor, let n = pop.native else { return }
        let f = a.windowFrame
        let r = state.rect == .zero ? CGRect(origin: f.origin, size: f.size) : state.rect.offsetBy(dx: f.minX, dy: f.minY)
        let gap: CGFloat = 4
        var origin: CGPoint
        switch state.edge {
        case .bottom: origin = CGPoint(x: r.midX - size.width / 2, y: r.maxY + gap)
        case .top: origin = CGPoint(x: r.midX - size.width / 2, y: r.minY - size.height - gap)
        case .leading: origin = CGPoint(x: r.minX - size.width - gap, y: r.midY - size.height / 2)
        case .trailing: origin = CGPoint(x: r.maxX + gap, y: r.midY - size.height / 2)
        }
        rw_popup_place(n, Double(origin.x), Double(origin.y), Double(size.width), Double(size.height))
    }

    public func setPopoverSize(_ popover: AnyObject, _ size: CGSize) {
        guard let pop = popover as? W32Window else { return }
        pop.root.frame.size = size
        if let c = pop.root.children.first { setChildren(pop.root, [(c, CGRect(origin: .zero, size: size))], contentSize: size) }
        placePopover(pop, size: size)
        pop.invalidate()
    }

    public func setPopoverKeyHandler(_ popover: AnyObject, _ handler: @escaping @MainActor (KeyPress) -> Bool) {
        (popover as? W32Window)?.popover?.keyHandler = handler
    }

    public func closePopover(_ popover: AnyObject) {
        guard let pop = popover as? W32Window else { return }
        pop.closePopoverWindow()
    }

    // Window chrome: the system title bar holds the title and buttons.
    public func labelAreaInsets(_ native: NativeWidget) -> EdgeInsetsValue { contentInsets(native) }
    public func beginWindowMove(_ window: NativeWindow, button: Int, at point: CGPoint, timestamp: TimeInterval) {
        if button == 0, let n = w32(window)?.native { rw_window_begin_move(n) }
    }
    public func setPassesThrough(_ container: NativeWidget, _ passes: Bool) { widget(container).passesThrough = passes }

    // Status items.
    public func makeStatusItem(_ spec: StatusItemSpec, menu: @escaping @MainActor () -> [MenuItemSpec], activate: @escaping @MainActor () -> Void) -> AnyObject? {
        let t = W32Tray(menu: menu, activate: activate)
        let tip = spec.tooltip ?? spec.title
        guard let n = rw_tray_create(tip.isEmpty ? (ProcessInfo.processInfo.processName) : tip, Unmanaged.passUnretained(t).toOpaque()) else { return nil }
        t.native = n
        trays.append(t)
        if !spec.visible { rw_tray_update(n, tip, 0) }
        return t
    }
    public func updateStatusItem(_ item: AnyObject, _ spec: StatusItemSpec) {
        guard let t = item as? W32Tray, let n = t.native else { return }
        let tip = spec.tooltip ?? spec.title
        rw_tray_update(n, tip.isEmpty ? ProcessInfo.processInfo.processName : tip, spec.visible ? 1 : 0)
    }
    public func removeStatusItem(_ item: AnyObject) {
        guard let t = item as? W32Tray else { return }
        if let n = t.native { rw_tray_destroy(n) }
        t.native = nil
        trays.removeAll { $0 === t }
    }

    // Timing.
    public func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { MainActor.assumeIsolated { work() } }
    }

    // Menus.
    public func popUpMenu(_ items: [MenuItemSpec], in native: NativeWidget, at point: CGPoint) {
        let w = widget(native)
        guard let win = w.window, let n = win.native else { return }
        let f = w.windowFrame
        win.showMenu(items, at: CGPoint(x: f.minX + point.x, y: f.minY + point.y), n)
    }
}

// MARK: Rich text plumbing

extension Win32Backend {
    /// Makes `w`'s RichEdit in `window` (or moves it there).
    func ensureRich(_ w: W32Widget, in window: W32Window) {
        if w.rich != nil, w.richWindow === window { return }
        guard let n = window.native else { return }
        w.rich = nil
        guard let r = rw_rich_create(n, Unmanaged.passUnretained(w).toOpaque()) else { return }
        w.rich = NativeHandle(r, release: { rw_rich_destroy($0) })
        w.richWindow = window
        w.richConfigApplied = nil
        applyRichConfig(w, background: w.richConfig.background ?? theme.textBackground)
        withRichRuns(w.richRuns, w.richConfig) { rw_rich_set_runs(r, $0, $1) }
        let a = TextOffsets.utf16Offset(scalar: w.richSelection.lowerBound, in: w.richString)
        let b = TextOffsets.utf16Offset(scalar: w.richSelection.upperBound, in: w.richString)
        rw_rich_set_selection(r, Int32(a), Int32(b))
    }

    func applyRichConfig(_ w: W32Widget, background: RGBA) {
        guard let r = w.rich?.pointer else { return }
        let key = W32Widget.RichApplied(config: w.richConfig, background: background, typing: w.richEvents.insertText != nil)
        guard key != w.richConfigApplied else { return }
        w.richConfigApplied = key
        let c = w.richConfig
        var typing = RichTextRun(string: "", font: c.font, color: c.textColor ?? theme.label)
        if c.monospaced { typing.font.family = Fonts.mono }
        withRichRuns([typing], c) { runs, _ in
            rw_rich_configure(r, c.editable ? 1 : 0, c.wraps ? 1 : 0, Double(c.insets.leading), Double(c.insets.top),
                              Double(c.insets.trailing), Double(c.insets.bottom), background.over(theme.windowBackground).rw,
                              runs, w.richEvents.insertText != nil ? 1 : 0)
        }
    }

    /// The runs as native ones for the duration of `body`.
    func withRichRuns(_ runs: [RichTextRun], _ config: TextViewConfig, _ body: (UnsafePointer<rw_rich_run>?, Int32) -> Void) {
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func dup(_ s: String) -> UnsafePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            owned.append(p)
            return UnsafePointer(p)
        }
        let defaultColor = config.textColor ?? theme.label
        let native: [rw_rich_run] = runs.map { run in
            var n = rw_rich_run()
            n.text = dup(run.string)
            n.family = Fonts.family(for: config.monospaced && run.font.family == nil ? FontSpec(size: run.font.size, design: .monospaced) : run.font).flatMap(dup)
            n.size = Float(run.font.size)
            n.weight = Int32(run.font.weight.rawValue)
            n.italic = run.font.italic ? 1 : 0
            n.has_color = 1
            n.color = (run.color ?? defaultColor).rw
            if let bg = run.background { n.has_background = 1; n.background = bg.rw }
            n.underline = run.underline ? Int32(run.underlineStyle) : 0
            n.strikethrough = run.strikethrough ? 1 : 0
            n.baseline_offset = Float(run.baselineOffset)
            n.hidden = run.hidden ? 1 : 0
            if let p = run.paragraph {
                n.has_paragraph = 1
                n.alignment = p.justified ? 3 : (p.alignment == .center ? RW_ALIGN_CENTER : p.alignment == .trailing ? RW_ALIGN_TRAILING : RW_ALIGN_LEADING)
                n.line_spacing = Float(p.lineSpacing)
                n.paragraph_spacing = Float(p.paragraphSpacing)
                n.spacing_before = Float(p.paragraphSpacingBefore)
                n.first_indent = Float(p.firstLineHeadIndent)
                n.head_indent = Float(p.headIndent)
                n.tail_indent = Float(p.tailIndent)
                n.line_height_multiple = Float(p.lineHeightMultiple)
            }
            return n
        }
        native.withUnsafeBufferPointer { body($0.baseAddress, Int32($0.count)) }
    }

    func richEvent(_ w: W32Widget, _ ev: rw_event) -> Bool {
        let e = w.richEvents
        switch ev.type {
        case RW_EV_RICH_CHANGED:
            guard let r = w.rich?.pointer, let c = rw_rich_copy_text(r) else { return false }
            let new = String(cString: c)
            rw_free(c)
            let old = w.richString
            guard new != old else { return true }
            // The changed range: what differs between the common ends.
            let o = Array(old.unicodeScalars), n = Array(new.unicodeScalars)
            var p = 0
            while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
            var s = 0
            while s < o.count - p, s < n.count - p, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
            let replaced = p..<(o.count - s)
            var inserted = String.UnicodeScalarView()
            inserted.append(contentsOf: n[p..<(n.count - s)])
            w.richString = new
            e.didChange?(replaced, String(inserted))
            return true
        case RW_EV_RICH_SELECTION:
            let sel = textViewSelection(w)
            e.userSelection?(sel, ev.flags & UInt32(RW_KEY_REPEAT) != 0)
            e.selectionChanged?(sel)
            return true
        case RW_EV_RICH_FOCUS:
            let focused = ev.button != 0
            w.editFocused = focused
            if focused { w.window?.setFocusedContainer(nil) }
            e.focusChanged?(focused)
            w.invalidate()
            return true
        case RW_EV_RICH_CHAR:
            return e.insertText?(String(cString: ev.text)) ?? false
        case RW_EV_RICH_KEY:
            guard let k = e.key, let press = Keys.press(Int(ev.key), mods: ev.mods) else { return false }
            return k(press)
        case RW_EV_RICH_POINTER:
            guard let handler = e.pointer else { return false }
            let up = ev.flags & UInt32(RW_MOUSE_RELEASE) != 0
            return handler(PointerEvent(kind: up ? .up : .down, location: CGPoint(x: ev.x, y: ev.y), button: Int(ev.button),
                                        clickCount: max(1, Int(ev.clicks)), modifiers: KeyModifiers(raw: RawModifiers(ev.mods))))
        case RW_EV_RICH_HEIGHT:
            w.richHeight = CGFloat(ev.dy)
            e.heightChanged?(CGFloat(ev.dy))
            return true
        default:
            return false
        }
    }
}
#endif
