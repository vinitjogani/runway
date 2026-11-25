// What AppKit's controls need from a toolkit beyond the widgets SwiftUI
// uses: pointer and key events on containers (tables, split views, drawn
// controls), scroll positions, rich text, popovers, a titlebar strip for
// toolbars, radio buttons and search fields, status items.
//
// It's a separate, optional protocol so backends adopt it at their own
// pace: AppKit asks `Runway.backend as? AppKitBackend` and falls back to
// plain containers (no events) where a backend doesn't provide it.

import CoreGraphics

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// ⌘ on macOS; Ctrl on Linux and Windows.
    public static let command = KeyModifiers(rawValue: 1)
    public static let shift = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
}

/// A pointer event in a widget's own coordinates (top-left origin).
public struct PointerEvent: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case down, up, dragged, moved, entered, exited, scroll }
    public var kind: Kind
    public var location: CGPoint
    /// 0 primary, 1 secondary, 2 middle.
    public var button: Int
    public var clickCount: Int
    public var modifiers: KeyModifiers
    /// Scroll deltas (points), for `.scroll`.
    public var delta: CGSize
    public init(kind: Kind, location: CGPoint, button: Int = 0, clickCount: Int = 1, modifiers: KeyModifiers = [], delta: CGSize = .zero) {
        self.kind = kind; self.location = location; self.button = button; self.clickCount = clickCount; self.modifiers = modifiers; self.delta = delta
    }
}

public enum CursorKind: Hashable, Sendable { case arrow, pointingHand, iBeam, resizeLeftRight, resizeUpDown }

public enum PopoverEdge: Hashable, Sendable { case top, bottom, leading, trailing }

/// A paragraph's layout, for rich text.
public struct ParagraphSpec: Hashable, Sendable {
    public var alignment: TextAlignmentValue = .leading
    public var justified = false
    public var lineSpacing: CGFloat = 0
    public var paragraphSpacing: CGFloat = 0
    public var paragraphSpacingBefore: CGFloat = 0
    public var firstLineHeadIndent: CGFloat = 0
    public var headIndent: CGFloat = 0
    public var tailIndent: CGFloat = 0
    /// A multiple of the font's natural line height (0: natural).
    public var lineHeightMultiple: CGFloat = 0
    public var minimumLineHeight: CGFloat = 0
    public var maximumLineHeight: CGFloat = 0
    public init() {}
}

/// A run of rich text: its characters and every attribute a text view shows.
public struct RichTextRun: Hashable, Sendable {
    public var string: String
    public var font: FontSpec
    public var color: RGBA?
    public var background: RGBA?
    public var underline = false
    public var strikethrough = false
    public var baselineOffset: CGFloat = 0
    public var kern: CGFloat = 0
    public var link: String?
    public var paragraph: ParagraphSpec?
    /// Laid out as nothing (TextKit's null glyphs): no width, not drawn.
    public var hidden = false
    /// Laid out as blank space this wide (a control glyph shown as
    /// whitespace with a width of its own); not drawn.
    public var spacerWidth: CGFloat?
    public var underlineColor: RGBA?
    public var strikethroughColor: RGBA?
    /// Underline thickness: 1 single, 2 thick, 3 double.
    public var underlineStyle = 1
    public init(string: String, font: FontSpec, color: RGBA? = nil) {
        self.string = string; self.font = font; self.color = color
    }
}

/// How a text view behaves.
public struct TextViewConfig: Hashable, Sendable {
    public var editable = true
    public var selectable = true
    public var wraps = true
    public var insets = EdgeInsetsValue(top: 0, leading: 5, bottom: 0, trailing: 5)
    public var background: RGBA?
    public var drawsBackground = true
    public var font = FontSpec()
    public var textColor: RGBA?
    public var allowsUndo = true
    public var monospaced = false
    /// The insertion point's colour (nil: the theme's).
    public var caretColor: RGBA?
    public init() {}
}

/// Text view callbacks. Ranges are in Unicode scalars (code points), the
/// unit GTK and most toolkits count in; AppKit converts to UTF-16.
@MainActor public struct TextViewEvents {
    /// Before the user's edit: replace `range` with `string`? false vetoes it.
    public var shouldChange: ((Range<Int>, String) -> Bool)?
    /// After the user's edit (not after `setTextViewContent`).
    public var didChange: ((Range<Int>, String) -> Void)?
    public var selectionChanged: ((Range<Int>) -> Void)?
    public var focusChanged: ((Bool) -> Void)?
    /// Keys before the text view handles them (Tab, Return, Escape…); true consumes.
    public var key: ((KeyPress) -> Bool)?
    /// Text the user typed or an input method committed. When set, the
    /// toolkit doesn't edit its text itself: the handler does, and sends the
    /// result back with `editTextView`. Returns whether it was taken.
    public var insertText: ((String) -> Bool)?
    /// The user's own selection changes (dragging, or the toolkit's caret
    /// movement), with whether a drag is still selecting.
    public var userSelection: ((Range<Int>, Bool) -> Void)?
    /// Presses and releases in the view (its own coordinates) before the
    /// toolkit handles them; true consumes the event.
    public var pointer: ((PointerEvent) -> Bool)?
    /// The text's laid-out height changed (layout finishes after edits).
    public var heightChanged: ((CGFloat) -> Void)?
    public init() {}
}

/// Where the caret moves (`textViewMove`).
public enum TextMoveStep: Hashable, Sendable {
    case character, word, displayLine, displayLineEnd, paragraph, paragraphEnd, page, document
}

/// A character's place in the text view's layout, in the view's coordinates.
public struct TextCharacterLayout: Hashable, Sendable {
    /// The character's box (its line's height; zero width when hidden).
    public var rect: CGRect
    /// The line (display line) it's on: top and bottom, with the spacing
    /// before the paragraph on its first line and after it on its last.
    public var lineTop: CGFloat
    public var lineBottom: CGFloat
    /// The line's baseline.
    public var baseline: CGFloat
    public init(rect: CGRect, lineTop: CGFloat, lineBottom: CGFloat, baseline: CGFloat) {
        self.rect = rect; self.lineTop = lineTop; self.lineBottom = lineBottom; self.baseline = baseline
    }
}

/// A status-bar (system tray) item's look and menu.
public struct StatusItemSpec {
    public var title: String
    public var symbol: String?
    public var tooltip: String?
    public var visible = true
    public init(title: String = "", symbol: String? = nil, tooltip: String? = nil) {
        self.title = title; self.symbol = symbol; self.tooltip = tooltip
    }
}

@MainActor public protocol AppKitBackend: Backend {
    // Events.
    /// A container (as `.container`) that reports pointer events, and key
    /// events while focused when `focusable`. Handlers return true to
    /// consume the event.
    func makeEventContainer(focusable: Bool,
                            pointer: @escaping @MainActor (PointerEvent) -> Bool,
                            key: @escaping @MainActor (KeyPress) -> Bool) -> NativeWidget
    /// Gives a widget keyboard focus.
    func focus(_ widget: NativeWidget)
    /// Takes keyboard focus away from a widget (its window keeps none).
    func resignFocus(_ widget: NativeWidget)
    /// Whether a widget and what's inside it take pointer events.
    func setHitTestable(_ widget: NativeWidget, _ testable: Bool)
    /// Which points of a container are its own when the toolkit picks the
    /// widget under the pointer (what's inside it is asked first): an
    /// AppKit view answers as its `hitTest(_:)` does, so a view that lets
    /// clicks through doesn't hide the controls beneath it. Points are in
    /// the container's top-left coordinates.
    func setOwnsPoint(_ container: NativeWidget, _ owns: (@MainActor (CGPoint) -> Bool)?)
    /// Focus entering (true) or leaving a focusable container.
    func observeFocus(_ widget: NativeWidget, _ changed: @escaping @MainActor (Bool) -> Void)
    func setCursor(_ widget: NativeWidget, _ cursor: CursorKind)

    // Scroll views (`.scroll` widgets).
    func scrollOffset(_ scroll: NativeWidget) -> CGPoint
    func setScrollOffset(_ scroll: NativeWidget, _ offset: CGPoint)
    /// The visible area's size (excluding scroll bars).
    func scrollViewportSize(_ scroll: NativeWidget) -> CGSize
    func observeScroll(_ scroll: NativeWidget, _ changed: @escaping @MainActor (CGPoint) -> Void)
    func setScrollers(_ scroll: NativeWidget, horizontal: Bool, vertical: Bool, autohides: Bool, bordered: Bool)

    // Text fields (`.textField` widgets) and buttons.
    /// Focus changes and keys (before the field handles them) for a text field.
    func observeTextField(_ field: NativeWidget, focus: @escaping @MainActor (Bool) -> Void, key: @escaping @MainActor (KeyPress) -> Bool)
    /// Search look: a magnifier and a clear button (which clears and reports the change).
    func setSearchField(_ field: NativeWidget, _ search: Bool)
    /// A key that clicks a button wherever focus is in its window (Return
    /// for the default button, Escape for cancel, ⌘-keys); nil removes it.
    func setKeyEquivalent(_ button: NativeWidget, _ key: KeyPress?)
    /// Makes a `.toggle(.checkbox)` draw as a radio button.
    func setRadio(_ checkbox: NativeWidget)
    /// Adds or removes a style class (the stylesheet's names).
    func setStyleClass(_ widget: NativeWidget, _ name: String, _ on: Bool)
    /// A text field's text alignment (labels align through `StyledText`).
    func setTextFieldAlignment(_ field: NativeWidget, _ alignment: TextAlignmentValue)
    /// A text field's editability without making it insensitive.
    func setTextFieldEditable(_ field: NativeWidget, _ editable: Bool)

    // Rich text.
    func makeTextView() -> NativeWidget
    func configureTextView(_ view: NativeWidget, _ config: TextViewConfig, events: TextViewEvents)
    func setTextViewContent(_ view: NativeWidget, _ runs: [RichTextRun])
    func textViewSelection(_ view: NativeWidget) -> Range<Int>
    func setTextViewSelection(_ view: NativeWidget, _ range: Range<Int>)
    func textViewUndo(_ view: NativeWidget, redo: Bool)
    /// The height the text needs at `width`.
    func textViewHeight(_ view: NativeWidget, width: CGFloat) -> CGFloat
    /// The rect (in the view) of the character at a scalar offset.
    func textViewCharacterRect(_ view: NativeWidget, at offset: Int) -> CGRect
    /// The scalar offset of the character nearest a point in the view.
    func textViewCharacterIndex(_ view: NativeWidget, at point: CGPoint) -> Int
    /// Replaces the characters in `range` (scalars) with `runs`, or, when
    /// their text is the same, only restyles them. `all` is the whole text.
    func editTextView(_ view: NativeWidget, replacing range: Range<Int>, with runs: [RichTextRun], all: () -> [RichTextRun])
    /// Drawing under the text (backgrounds, decorations) and over it, in
    /// the view's coordinates; the visible part is drawn.
    func setTextViewLayers(_ view: NativeWidget, below: CGDisplayList?, above: CGDisplayList?)
    /// Moves the caret (or extends the selection) as the toolkit's keys do.
    func textViewMove(_ view: NativeWidget, by step: TextMoveStep, count: Int, extend: Bool)
    /// Where a character (scalar offset) is laid out.
    func textViewCharacterLayout(_ view: NativeWidget, at offset: Int) -> TextCharacterLayout

    // Popovers.
    /// Shows `content` (a container) in a popover pointing at `rect` in
    /// `anchor`'s coordinates; returns a handle.
    func showPopover(_ content: NativeWidget, size: CGSize, anchor: NativeWidget, rect: CGRect, edge: PopoverEdge,
                     transient: Bool, onClose: @escaping @MainActor () -> Void) -> AnyObject
    func setPopoverSize(_ popover: AnyObject, _ size: CGSize)
    func closePopover(_ popover: AnyObject)

    // Window chrome.
    /// Whether the window's titlebar row (window buttons, menu bar) shows
    /// the window's title, centred as on the Mac. AppKit hides it when the
    /// title is hidden or a toolbar shows it.
    func setTitlebarShowsTitle(_ window: NativeWindow, _ shows: Bool)
    /// The toolbar band's height (0: none). A backend whose titlebar row
    /// would hold only the window buttons (the desktop shows the menu bar)
    /// may float them at the band's leading edge, as a Mac window with a
    /// unified toolbar has them.
    func setToolbarBand(_ window: NativeWindow, height: CGFloat)
    /// Whether the content runs under the toolbar band (full-size content):
    /// apps then leave room at its leading edge for the window buttons.
    func setContentUnderToolbarBand(_ window: NativeWindow, _ under: Bool)
    /// The close, minimise and zoom buttons' frames in the window's canvas
    /// (y down from its top) while they're over the content; nil while they
    /// have a titlebar row of their own.
    func windowButtonFrames(_ window: NativeWindow) -> [CGRect]?
    /// Lets clicks on a container's empty parts through to what's under
    /// it (its subviews still take theirs): a toolbar floating over
    /// full-size content.
    func setPassesThrough(_ container: NativeWidget, _ passes: Bool)
    /// Where a button with content puts it: its size less padding and
    /// border (`contentInsets` may also count a minimum size).
    func labelAreaInsets(_ widget: NativeWidget) -> EdgeInsetsValue
    /// Moves the window with the pointer from a press of `button` (0 left)
    /// at `point` (window coordinates, top-left), as a title bar drag does.
    func beginWindowMove(_ window: NativeWindow, button: Int, at point: CGPoint, timestamp: TimeInterval)

    // Status items.
    /// A system tray item (StatusNotifierItem on Linux); nil when the
    /// desktop has no tray.
    func makeStatusItem(_ spec: StatusItemSpec, menu: @escaping @MainActor () -> [MenuItemSpec], activate: @escaping @MainActor () -> Void) -> AnyObject?
    func updateStatusItem(_ item: AnyObject, _ spec: StatusItemSpec)
    func removeStatusItem(_ item: AnyObject)

    // Timing.
    /// Runs `work` once after `seconds` (progress animation, autorepeat).
    func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void)

    // Menus.
    /// Pops up a menu at a point in `widget`'s coordinates.
    func popUpMenu(_ items: [MenuItemSpec], in widget: NativeWidget, at point: CGPoint)
}

extension Runway {
    /// The backend's AppKit extras, when it has them.
    @MainActor public static var appKit: AppKitBackend? { backend as? AppKitBackend }
}

/// Unicode-scalar offsets ↔ UTF-16 offsets, for text views.
public enum TextOffsets {
    public static func scalarOffset(utf16 offset: Int, in s: String) -> Int {
        var u = 0, n = 0
        for sc in s.unicodeScalars {
            if u >= offset { break }
            u += sc.utf16.count
            n += 1
        }
        return n
    }
    public static func utf16Offset(scalar offset: Int, in s: String) -> Int {
        var u = 0, n = 0
        for sc in s.unicodeScalars {
            if n >= offset { break }
            u += sc.utf16.count
            n += 1
        }
        return u
    }
}

extension AppKitBackend {
    public func editTextView(_ view: NativeWidget, replacing range: Range<Int>, with runs: [RichTextRun], all: () -> [RichTextRun]) {
        setTextViewContent(view, all())
    }
    public func setTextViewLayers(_ view: NativeWidget, below: CGDisplayList?, above: CGDisplayList?) {}
    public func textViewMove(_ view: NativeWidget, by step: TextMoveStep, count: Int, extend: Bool) {}
    public func textViewCharacterLayout(_ view: NativeWidget, at offset: Int) -> TextCharacterLayout {
        let r = textViewCharacterRect(view, at: offset)
        return TextCharacterLayout(rect: r, lineTop: r.minY, lineBottom: r.maxY, baseline: r.minY + r.height * 0.8)
    }

    public func resignFocus(_ widget: NativeWidget) {}
    public func setHitTestable(_ widget: NativeWidget, _ testable: Bool) {}
    public func setOwnsPoint(_ container: NativeWidget, _ owns: (@MainActor (CGPoint) -> Bool)?) {}
    /// Backends without interactive moves leave the window where it is.
    public func beginWindowMove(_ window: NativeWindow, button: Int, at point: CGPoint, timestamp: TimeInterval) {}
    /// Backends that route input themselves needn't do anything.
    public func setPassesThrough(_ container: NativeWidget, _ passes: Bool) {}
    public func setTitlebarShowsTitle(_ window: NativeWindow, _ shows: Bool) {}
    public func setToolbarBand(_ window: NativeWindow, height: CGFloat) {}
    public func setContentUnderToolbarBand(_ window: NativeWindow, _ under: Bool) {}
    public func windowButtonFrames(_ window: NativeWindow) -> [CGRect]? { nil }
    public func labelAreaInsets(_ widget: NativeWidget) -> EdgeInsetsValue { contentInsets(widget) }
}
