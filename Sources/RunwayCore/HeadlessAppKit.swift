// The headless backend's AppKit extras: everything is recorded per widget
// so tests can inspect state and simulate the user (clicks, keys, typing,
// scrolling, closing popovers).

import CoreGraphics

/// What the headless backend remembers about a widget beyond its props.
@MainActor public final class HeadlessAppKitRecord {
    public var pointer: ((PointerEvent) -> Bool)?
    public var key: ((KeyPress) -> Bool)?
    public var focusable = false
    public var onFocus: ((Bool) -> Void)?
    public var cursor: CursorKind = .arrow
    public var scrollOffset: CGPoint = .zero
    public var onScroll: ((CGPoint) -> Void)?
    public var scrollers = (horizontal: false, vertical: true, autohides: true, bordered: false)
    public var textFocus: ((Bool) -> Void)?
    public var textKey: ((KeyPress) -> Bool)?
    public var search = false
    public var radio = false
    public var keyEquivalent: KeyPress?
    public var styleClasses: Set<String> = []
    public var alignment: TextAlignmentValue = .leading
    public var editable = true
    // Text views.
    public var isTextView = false
    public var textConfig = TextViewConfig()
    public var textEvents = TextViewEvents()
    public var runs: [RichTextRun] = []
    public var selection: Range<Int> = 0..<0
    public var undoStack: [String] = []
    public var redoStack: [String] = []
    public var text: String { runs.map(\.string).joined() }
    init() {}
}

@MainActor public final class HeadlessPopover {
    public let content: NativeWidget
    public var size: CGSize
    public let anchor: NativeWidget
    public let rect: CGRect
    public let edge: PopoverEdge
    public var isShown = true
    let onClose: () -> Void
    init(content: NativeWidget, size: CGSize, anchor: NativeWidget, rect: CGRect, edge: PopoverEdge, onClose: @escaping () -> Void) {
        self.content = content; self.size = size; self.anchor = anchor; self.rect = rect; self.edge = edge; self.onClose = onClose
    }
    /// Simulates a click outside a transient popover.
    public func dismiss() {
        guard isShown else { return }
        isShown = false
        onClose()
    }
}

@MainActor public final class HeadlessStatusItem {
    public var spec: StatusItemSpec
    public let menu: () -> [MenuItemSpec]
    public let activate: () -> Void
    public var removed = false
    init(spec: StatusItemSpec, menu: @escaping () -> [MenuItemSpec], activate: @escaping () -> Void) {
        self.spec = spec; self.menu = menu; self.activate = activate
    }
}

extension HeadlessBackend: AppKitBackend {
    private static var records: [ObjectIdentifier: (widget: Weak, record: HeadlessAppKitRecord)] = [:]
    final class Weak { weak var value: HeadlessWidget?; init(_ v: HeadlessWidget) { value = v } }
    public static var popovers: [HeadlessPopover] = []
    public static var statusItems: [HeadlessStatusItem] = []
    /// Whether each window's titlebar row shows its title.
    public static var titlebarShowsTitle: [ObjectIdentifier: Bool] = [:]
    public static var poppedUpMenus: [[MenuItemSpec]] = []
    public static weak var focused: HeadlessWidget?

    /// The record for a widget, made on first use.
    public static func record(_ widget: NativeWidget) -> HeadlessAppKitRecord {
        let w = widget as! HeadlessWidget
        let id = ObjectIdentifier(w)
        if let r = records[id], r.widget.value === w { return r.record }
        let r = HeadlessAppKitRecord()
        records[id] = (Weak(w), r)
        return r
    }

    /// Simulates a pointer event on a widget; returns whether it was handled.
    @discardableResult public static func send(_ event: PointerEvent, to widget: NativeWidget) -> Bool {
        record(widget).pointer?(event) ?? false
    }
    /// Simulates a click (down and up) at a point in the widget.
    public static func click(_ widget: NativeWidget, at p: CGPoint, count: Int = 1, modifiers: KeyModifiers = [], button: Int = 0) {
        for n in 1...count {
            send(PointerEvent(kind: .down, location: p, button: button, clickCount: n, modifiers: modifiers), to: widget)
            send(PointerEvent(kind: .up, location: p, button: button, clickCount: n, modifiers: modifiers), to: widget)
        }
    }
    /// Simulates a drag from `a` to `b`.
    public static func drag(_ widget: NativeWidget, from a: CGPoint, to b: CGPoint) {
        send(PointerEvent(kind: .down, location: a), to: widget)
        send(PointerEvent(kind: .dragged, location: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)), to: widget)
        send(PointerEvent(kind: .dragged, location: b), to: widget)
        send(PointerEvent(kind: .up, location: b), to: widget)
    }
    /// Simulates a key press on a focusable container or text field.
    @discardableResult public static func press(_ key: KeyPress, on widget: NativeWidget) -> Bool {
        let r = record(widget)
        if r.isTextView { return r.textEvents.key?(key) ?? false }
        return (r.textKey ?? r.key)?(key) ?? false
    }
    /// Simulates the user scrolling a scroll view.
    public static func scroll(_ scroll: NativeWidget, to p: CGPoint) {
        let r = record(scroll)
        r.scrollOffset = p
        r.onScroll?(p)
    }
    /// Simulates focus entering or leaving a text field.
    public static func setTextFocus(_ field: NativeWidget, _ focused: Bool) { record(field).textFocus?(focused) }
    /// Simulates the user typing into a text view: replaces `range`
    /// (scalars) with `string`, asking `shouldChange` first.
    @discardableResult public static func type(_ string: String, replacing range: Range<Int>? = nil, in view: NativeWidget) -> Bool {
        let r = record(view)
        let text = r.text
        let count = text.unicodeScalars.count
        let range = range ?? r.selection.clamped(to: 0..<count)
        if let insert = r.textEvents.insertText {
            // The view edits its own text (as AppKit's does): the selection is what's replaced.
            r.selection = range
            r.textEvents.userSelection?(range, false)
            return insert(string)
        }
        guard r.textEvents.shouldChange?(range, string) ?? true else { return false }
        guard r.textConfig.editable else { return false }
        var scalars = Array(text.unicodeScalars)
        scalars.replaceSubrange(range, with: Array(string.unicodeScalars))
        r.undoStack.append(text)
        r.redoStack.removeAll()
        let font = r.runs.first?.font ?? r.textConfig.font
        var s = String.UnicodeScalarView()
        s.append(contentsOf: scalars)
        r.runs = [RichTextRun(string: String(s), font: font, color: r.textConfig.textColor)]
        let caret = range.lowerBound + string.unicodeScalars.count
        r.selection = caret..<caret
        r.textEvents.didChange?(range, string)
        r.textEvents.selectionChanged?(r.selection)
        return true
    }

    public func makeEventContainer(focusable: Bool, pointer: @escaping @MainActor (PointerEvent) -> Bool, key: @escaping @MainActor (KeyPress) -> Bool) -> NativeWidget {
        let w = makeWidget(.container)
        let r = Self.record(w)
        r.pointer = pointer
        r.key = key
        r.focusable = focusable
        return w
    }
    public func focus(_ widget: NativeWidget) {
        let w = widget as? HeadlessWidget
        guard w !== Self.focused else { return }
        if let old = Self.focused { Self.record(old).onFocus?(false); Self.record(old).textFocus?(false) }
        Self.focused = w
        if let w { Self.record(w).onFocus?(true); Self.record(w).textFocus?(true) }
    }
    public func observeFocus(_ widget: NativeWidget, _ changed: @escaping @MainActor (Bool) -> Void) { Self.record(widget).onFocus = changed }
    public func setCursor(_ widget: NativeWidget, _ cursor: CursorKind) { Self.record(widget).cursor = cursor }

    public func scrollOffset(_ scroll: NativeWidget) -> CGPoint { Self.record(scroll).scrollOffset }
    public func setScrollOffset(_ scroll: NativeWidget, _ offset: CGPoint) {
        let r = Self.record(scroll)
        let w = scroll as! HeadlessWidget
        let doc = w.children.first?.contentSize ?? .zero
        let clamped = CGPoint(x: max(0, min(offset.x, doc.width - w.frame.width)), y: max(0, min(offset.y, doc.height - w.frame.height)))
        guard clamped != r.scrollOffset else { return }
        r.scrollOffset = clamped
        r.onScroll?(clamped)
    }
    public func scrollViewportSize(_ scroll: NativeWidget) -> CGSize { (scroll as! HeadlessWidget).frame.size }
    public func observeScroll(_ scroll: NativeWidget, _ changed: @escaping @MainActor (CGPoint) -> Void) { Self.record(scroll).onScroll = changed }
    public func setScrollers(_ scroll: NativeWidget, horizontal: Bool, vertical: Bool, autohides: Bool, bordered: Bool) {
        Self.record(scroll).scrollers = (horizontal, vertical, autohides, bordered)
    }

    public func observeTextField(_ field: NativeWidget, focus: @escaping @MainActor (Bool) -> Void, key: @escaping @MainActor (KeyPress) -> Bool) {
        let r = Self.record(field)
        r.textFocus = focus
        r.textKey = key
    }
    public func setSearchField(_ field: NativeWidget, _ search: Bool) { Self.record(field).search = search }
    public func setKeyEquivalent(_ button: NativeWidget, _ key: KeyPress?) { Self.record(button).keyEquivalent = key }
    public func setRadio(_ checkbox: NativeWidget) { Self.record(checkbox).radio = true }
    public func setStyleClass(_ widget: NativeWidget, _ name: String, _ on: Bool) {
        if on { Self.record(widget).styleClasses.insert(name) } else { Self.record(widget).styleClasses.remove(name) }
    }
    public func setTextFieldAlignment(_ field: NativeWidget, _ alignment: TextAlignmentValue) { Self.record(field).alignment = alignment }
    public func setTextFieldEditable(_ field: NativeWidget, _ editable: Bool) { Self.record(field).editable = editable }

    public func makeTextView() -> NativeWidget {
        let w = makeWidget(.textEditor)
        Self.record(w).isTextView = true
        return w
    }
    public func configureTextView(_ view: NativeWidget, _ config: TextViewConfig, events: TextViewEvents) {
        let r = Self.record(view)
        r.textConfig = config
        r.textEvents = events
    }
    public func setTextViewContent(_ view: NativeWidget, _ runs: [RichTextRun]) {
        let r = Self.record(view)
        r.runs = runs
        let n = r.text.unicodeScalars.count
        r.selection = r.selection.clamped(to: 0..<n)
    }
    public func textViewMove(_ view: NativeWidget, by step: TextMoveStep, count: Int, extend: Bool) {
        let r = Self.record(view)
        let scalars = Array(r.text.unicodeScalars)
        let caret = count < 0 ? r.selection.lowerBound : r.selection.upperBound
        var to = caret
        switch step {
        case .character: to = caret + count
        case .document, .page: to = count < 0 ? 0 : scalars.count
        default:
            // Lines and paragraphs: to the line's start or end.
            if count < 0 {
                to = caret
                while to > 0, scalars[to - 1] != "\n" { to -= 1 }
            } else {
                while to < scalars.count, scalars[to] != "\n" { to += 1 }
            }
        }
        to = max(0, min(scalars.count, to))
        let anchor = count < 0 ? r.selection.upperBound : r.selection.lowerBound
        r.selection = extend ? min(anchor, to)..<max(anchor, to) : to..<to
        r.textEvents.userSelection?(r.selection, false)
    }
    public func textViewSelection(_ view: NativeWidget) -> Range<Int> { Self.record(view).selection }
    public func setTextViewSelection(_ view: NativeWidget, _ range: Range<Int>) { Self.record(view).selection = range }
    public func textViewUndo(_ view: NativeWidget, redo: Bool) {
        let r = Self.record(view)
        let font = r.runs.first?.font ?? r.textConfig.font
        if redo {
            guard let s = r.redoStack.popLast() else { return }
            r.undoStack.append(r.text)
            r.runs = [RichTextRun(string: s, font: font)]
        } else {
            guard let s = r.undoStack.popLast() else { return }
            r.redoStack.append(r.text)
            r.runs = [RichTextRun(string: s, font: font)]
        }
        let all = 0..<r.text.unicodeScalars.count
        r.textEvents.didChange?(all, r.text)
    }
    public func textViewHeight(_ view: NativeWidget, width: CGFloat) -> CGFloat {
        let r = Self.record(view)
        let t = StyledText(runs: r.runs.map { TextRun(string: $0.string, font: $0.font, color: $0.color) })
        return Self.measureText(t, width: max(1, width - r.textConfig.insets.leading - r.textConfig.insets.trailing)).height
            + r.textConfig.insets.top + r.textConfig.insets.bottom
    }

    /// Monospaced metrics: each character 0.55 em wide, lines 1.25 em tall.
    public func textViewCharacterRect(_ view: NativeWidget, at offset: Int) -> CGRect {
        let r = Self.record(view)
        let size = r.runs.first?.font.size ?? r.textConfig.font.size
        let scalars = Array(r.text.unicodeScalars.prefix(offset))
        let line = scalars.filter { $0 == "\n" }.count
        let col = scalars.count - (scalars.lastIndex(of: "\n").map { $0 + 1 } ?? 0)
        return CGRect(x: r.textConfig.insets.leading + CGFloat(col) * size * Self.advance, y: r.textConfig.insets.top + CGFloat(line) * Self.lineHeight(size),
                      width: size * Self.advance, height: Self.lineHeight(size))
    }
    public func textViewCharacterIndex(_ view: NativeWidget, at point: CGPoint) -> Int {
        let r = Self.record(view)
        let size = r.runs.first?.font.size ?? r.textConfig.font.size
        let lines = r.text.split(separator: "\n", omittingEmptySubsequences: false)
        let line = max(0, min(lines.count - 1, Int((point.y - r.textConfig.insets.top) / Self.lineHeight(size))))
        let col = max(0, min(lines[line].unicodeScalars.count, Int(((point.x - r.textConfig.insets.leading) / (size * Self.advance)).rounded())))
        return lines[..<line].map { $0.unicodeScalars.count + 1 }.reduce(0, +) + col
    }

    public func showPopover(_ content: NativeWidget, size: CGSize, anchor: NativeWidget, rect: CGRect, edge: PopoverEdge, transient: Bool, onClose: @escaping @MainActor () -> Void) -> AnyObject {
        let p = HeadlessPopover(content: content, size: size, anchor: anchor, rect: rect, edge: edge, onClose: onClose)
        (content as? HeadlessWidget)?.frame = CGRect(origin: .zero, size: size)
        Self.popovers.append(p)
        return p
    }
    public func setPopoverSize(_ popover: AnyObject, _ size: CGSize) { (popover as? HeadlessPopover)?.size = size }
    public func closePopover(_ popover: AnyObject) {
        guard let p = popover as? HeadlessPopover, p.isShown else { return }
        p.isShown = false
        Self.popovers.removeAll { $0 === p }
    }

    public func setTitlebarShowsTitle(_ window: NativeWindow, _ shows: Bool) {
        Self.titlebarShowsTitle[ObjectIdentifier(window)] = shows
    }

    public func makeStatusItem(_ spec: StatusItemSpec, menu: @escaping @MainActor () -> [MenuItemSpec], activate: @escaping @MainActor () -> Void) -> AnyObject? {
        let i = HeadlessStatusItem(spec: spec, menu: menu, activate: activate)
        Self.statusItems.append(i)
        return i
    }
    public func updateStatusItem(_ item: AnyObject, _ spec: StatusItemSpec) { (item as? HeadlessStatusItem)?.spec = spec }
    public func removeStatusItem(_ item: AnyObject) {
        guard let i = item as? HeadlessStatusItem else { return }
        i.removed = true
        Self.statusItems.removeAll { $0 === i }
    }

    /// Delayed work runs when tests call `HeadlessBackend.fireTimers()`.
    public static var timers: [@MainActor () -> Void] = []
    public static func fireTimers() { let t = timers; timers = []; t.forEach { $0() } }
    public func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) { Self.timers.append(work) }

    public func popUpMenu(_ items: [MenuItemSpec], in widget: NativeWidget, at point: CGPoint) { Self.poppedUpMenus.append(items) }
}
