// What the standard controls add to NSControl (Control.swift): a closure
// handler, measuring their native widget, the font as a backend spec; the
// text-editing delegate protocol; and the cells code configures controls
// through.

import Foundation
import CoreGraphics
import RunwayCore

extension NSControl {
    private static var handlers: [ObjectIdentifier: (weak: WeakControl, f: (NSControl) -> Void)] = [:]
    final class WeakControl { weak var value: NSControl?; init(_ v: NSControl) { value = v } }

    /// Runway: a closure run with the control's action (for code that
    /// can't name a selector target).
    public var handler: ((NSControl) -> Void)? {
        get {
            guard let e = Self.handlers[ObjectIdentifier(self)], e.weak.value === self else { return nil }
            return e.f
        }
        set {
            Self.handlers = Self.handlers.filter { $0.value.weak.value != nil }
            Self.handlers[ObjectIdentifier(self)] = newValue.map { (WeakControl(self), $0) }
        }
    }

    private static var cells: [ObjectIdentifier: (weak: WeakControl, cell: NSCell)] = [:]
    /// The cell, for code that configures controls through it.
    public var cell: NSCell? {
        get {
            guard let e = Self.cells[ObjectIdentifier(self)], e.weak.value === self else { return nil }
            return e.cell
        }
        set {
            Self.cells = Self.cells.filter { $0.value.weak.value != nil }
            newValue?.controlView = self
            Self.cells[ObjectIdentifier(self)] = newValue.map { (WeakControl(self), $0) }
        }
    }

    /// The user acted: run the handler, then send the action.
    func fireAction() {
        guard isEnabled else { return }
        handler?(self)
        sendAction(action, to: target)
    }

    /// The native widget's natural size (at a width, for wrapping).
    func measured(_ w: NativeWidget, width: CGFloat? = nil) -> CGSize {
        Runway.backend.measure(w, proposal: ProposedSize(width: width, height: nil))
    }

    /// The font as the backend's spec (control sizes' system fonts).
    var fontSpec: FontSpec {
        if let f = font { return f.spec }
        switch controlSize {
        case .small: return FontSpec(size: 11)
        case .mini: return FontSpec(size: 9)
        default: return FontSpec(size: 13)
        }
    }
}

/// Text editing callbacks controls send their delegate.
@preconcurrency @MainActor public protocol NSControlTextEditingDelegate: AnyObject {
    func controlTextDidBeginEditing(_ obj: Notification)
    func controlTextDidChange(_ obj: Notification)
    func controlTextDidEndEditing(_ obj: Notification)
    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool
}

extension NSControlTextEditingDelegate {
    public func controlTextDidBeginEditing(_ obj: Notification) {}
    public func controlTextDidChange(_ obj: Notification) {}
    public func controlTextDidEndEditing(_ obj: Notification) {}
    public func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool { true }
    public func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool { true }
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool { false }
}

extension NSControl {
    public static let textDidBeginEditingNotification = Notification.Name("NSControlTextDidBeginEditingNotification")
    public static let textDidChangeNotification = Notification.Name("NSControlTextDidChangeNotification")
    public static let textDidEndEditingNotification = Notification.Name("NSControlTextDidEndEditingNotification")
}

// MARK: Cells

/// Cells hold a control's settings in AppKit; here the control holds them
/// and the cell forwards, for code that configures controls through it.
@preconcurrency @MainActor
open class NSCell: NSObject {
    public enum CellType: UInt, Sendable { case nullCellType, textCellType, imageCellType }
    open weak var controlView: NSView?
    private var ownValue: Any?
    private var ownFont: NSFont?
    open var title: String
    open var image: NSImage?
    open var type: CellType = .textCellType
    open var isBordered = false
    open var isBezeled = false
    open var isScrollable = false
    open var wraps = false
    open var truncatesLastVisibleLine = false
    open var representedObject: Any?
    open var tag = 0
    open var sendsActionOnEndEditing = false
    open var usesSingleLineMode = false
    open var focusRingType: NSFocusRingType = .default
    open var state: NSControl.StateValue = .off
    open var isHighlighted = false
    open var showsFirstResponder = false

    public override init() { title = ""; super.init() }
    public init(textCell s: String) { title = s; super.init() }
    public init(imageCell i: NSImage?) { title = ""; image = i; type = .imageCellType; super.init() }
    /// Cells aren't archived here; this makes an empty cell.
    public required init(coder: NSCoder) { title = ""; super.init() }

    private var control: NSControl? { controlView as? NSControl }
    open var objectValue: Any? {
        get { control?.objectValue ?? ownValue }
        set { if let c = control { c.objectValue = newValue } else { ownValue = newValue } }
    }
    open var stringValue: String {
        get { control?.stringValue ?? (ownValue as? String) ?? title }
        set { if let c = control { c.objectValue = newValue } else { ownValue = newValue; title = newValue } }
    }
    open var font: NSFont? {
        get { control?.font ?? ownFont }
        set { if let c = control { c.font = newValue } else { ownFont = newValue } }
    }
    open var isEnabled: Bool {
        get { control?.isEnabled ?? true }
        set { control?.isEnabled = newValue }
    }
    private var ownAlignment: NSTextAlignment = .natural
    open var alignment: NSTextAlignment {
        get { control?.alignment ?? ownAlignment }
        set { if let c = control { c.alignment = newValue } else { ownAlignment = newValue } }
    }
    open var lineBreakMode: NSLineBreakMode {
        get { control?.lineBreakMode ?? .byTruncatingTail }
        set { control?.lineBreakMode = newValue }
    }
    open var controlSize: NSControl.ControlSize {
        get { control?.controlSize ?? .regular }
        set { control?.controlSize = newValue }
    }
    open var cellSize: CGSize { controlView?.intrinsicContentSize ?? .zero }
    open func cellSize(forBounds rect: CGRect) -> CGSize { cellSize }

    // Geometry and drawing hooks cell subclasses override. The controls
    // here draw themselves, so these are called only by code that calls them.
    open func performClick(_ sender: Any?) { (controlView as? NSControl)?.performClick(sender) }
    open var isEditable: Bool {
        get { (controlView as? NSTextField)?.isEditable ?? false }
        set { (controlView as? NSTextField)?.isEditable = newValue }
    }
    open var isSelectable: Bool {
        get { (controlView as? NSTextField)?.isSelectable ?? false }
        set { (controlView as? NSTextField)?.isSelectable = newValue }
    }
    // Mouse tracking in a cell (the controls track for themselves here).
    open func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool { true }
    open func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool { true }
    open func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {}
    open func trackMouse(with event: NSEvent, in cellFrame: NSRect, of controlView: NSView, untilMouseUp flag: Bool) -> Bool { false }
    open class var prefersTrackingUntilMouseUp: Bool { false }
    open var isContinuous: Bool {
        get { (controlView as? NSControl)?.isContinuous ?? false }
        set { (controlView as? NSControl)?.isContinuous = newValue }
    }
    open func titleRect(forBounds rect: NSRect) -> NSRect { rect }
    open func imageRect(forBounds rect: NSRect) -> NSRect { rect }
    open func drawingRect(forBounds rect: NSRect) -> NSRect { rect }
    open func draw(withFrame cellFrame: NSRect, in controlView: NSView) { drawInterior(withFrame: cellFrame, in: controlView) }
    open func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}
    open func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) { isHighlighted = flag }
    open var attributedStringValue: NSAttributedString {
        get { (controlView as? NSControl)?.attributedStringValue ?? NSAttributedString(string: stringValue) }
        set { if let c = controlView as? NSControl { c.attributedStringValue = newValue } else { stringValue = newValue.string } }
    }
    open func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {}
    open func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {}
}

@preconcurrency @MainActor open class NSActionCell: NSCell {
    open weak var target: AnyObject?
    open var action: Selector?
}

@preconcurrency @MainActor open class NSButtonCell: NSActionCell {
    open var bezelStyle: NSButton.BezelStyle {
        get { (controlView as? NSButton)?.bezelStyle ?? .rounded }
        set { (controlView as? NSButton)?.bezelStyle = newValue }
    }
    open var highlightsBy: Int = 0
    open var showsStateBy: Int = 0
    open var imageScaling: NSImageScaling = .scaleProportionallyDown
    open var backgroundColor: NSColor?
    open func setButtonType(_ t: NSButton.ButtonType) { (controlView as? NSButton)?.setButtonType(t) }
}

@preconcurrency @MainActor open class NSTextFieldCell: NSActionCell {
    open var placeholderString: String? {
        get { (controlView as? NSTextField)?.placeholderString }
        set { (controlView as? NSTextField)?.placeholderString = newValue }
    }
    open var drawsBackground = false
    open var backgroundColor: NSColor?
    open var textColor: NSColor?
    open var bezelStyle: NSTextField.BezelStyle = .squareBezel
}

@preconcurrency @MainActor open class NSSearchFieldCell: NSTextFieldCell {
    open var searchButtonCell: NSButtonCell?
    open var cancelButtonCell: NSButtonCell?
}

@preconcurrency @MainActor open class NSImageCell: NSCell {}
@preconcurrency @MainActor open class NSSliderCell: NSActionCell {
    private var slider: NSSlider? { controlView as? NSSlider }
    open var minValue: Double { get { slider?.minValue ?? 0 } set { slider?.minValue = newValue } }
    open var maxValue: Double { get { slider?.maxValue ?? 1 } set { slider?.maxValue = newValue } }
    open var doubleValue: Double { get { slider?.doubleValue ?? 0 } set { slider?.doubleValue = newValue } }
    open var floatValue: Float { get { Float(doubleValue) } set { doubleValue = Double(newValue) } }
    open var numberOfTickMarks: Int { get { slider?.numberOfTickMarks ?? 0 } set { slider?.numberOfTickMarks = newValue } }
    open var allowsTickMarkValuesOnly: Bool { get { slider?.allowsTickMarkValuesOnly ?? false } set { slider?.allowsTickMarkValuesOnly = newValue } }
    open var isVertical: Bool { slider?.isVertical ?? false }
    open var knobThickness: CGFloat { 16 }
    open var trackRect: NSRect { controlView?.bounds ?? .zero }
    // Drawing and tracking hooks subclasses override. The slider here is
    // the toolkit's widget, so the framework doesn't call them.
    open func knobRect(flipped: Bool) -> NSRect {
        let b = controlView?.bounds ?? .zero
        let span = maxValue - minValue
        let fraction = span > 0 ? CGFloat((doubleValue - minValue) / span) : 0
        return NSRect(x: b.minX + fraction * max(b.width - knobThickness, 0), y: b.midY - knobThickness / 2, width: knobThickness, height: knobThickness)
    }
    open func barRect(flipped: Bool) -> NSRect {
        let b = controlView?.bounds ?? .zero
        return NSRect(x: b.minX, y: b.midY - 2, width: b.width, height: 4)
    }
    open func drawKnob(_ knobRect: NSRect) {}
    open func drawKnob() { drawKnob(knobRect(flipped: controlView?.isFlipped ?? false)) }
    open func drawBar(inside rect: NSRect, flipped: Bool) {}
    open func drawTickMarks() {}
    open func rectOfTickMark(at index: Int) -> NSRect { .zero }
    open func tickMarkValue(at index: Int) -> Double { slider?.tickMarkValue(at: index) ?? 0 }
}
@preconcurrency @MainActor open class NSPopUpButtonCell: NSButtonCell {}
@preconcurrency @MainActor open class NSSegmentedCell: NSActionCell {
    private var segmented: NSSegmentedControl? { controlView as? NSSegmentedControl }
    open var trackingMode: NSSegmentedControl.SwitchTracking {
        get { segmented?.trackingMode ?? .selectOne }
        set { segmented?.trackingMode = newValue }
    }
    open var segmentCount: Int {
        get { segmented?.segmentCount ?? 0 }
        set { segmented?.segmentCount = newValue }
    }
    open var selectedSegment: Int {
        get { segmented?.selectedSegment ?? -1 }
        set { segmented?.selectedSegment = newValue }
    }
    open var segmentStyle: NSSegmentedControl.Style {
        get { segmented?.segmentStyle ?? .automatic }
        set { segmented?.segmentStyle = newValue }
    }
    open func setTag(_ tag: Int, forSegment segment: Int) { segmented?.setTag(tag, forSegment: segment) }
    open func tag(forSegment segment: Int) -> Int { segmented?.tag(forSegment: segment) ?? 0 }
    open func setLabel(_ label: String, forSegment segment: Int) { segmented?.setLabel(label, forSegment: segment) }
    open func label(forSegment segment: Int) -> String? { segmented?.label(forSegment: segment) }
    open func setImage(_ image: NSImage?, forSegment segment: Int) { segmented?.setImage(image, forSegment: segment) }
    open func setWidth(_ width: CGFloat, forSegment segment: Int) { segmented?.setWidth(width, forSegment: segment) }
    open func setEnabled(_ enabled: Bool, forSegment segment: Int) { segmented?.setEnabled(enabled, forSegment: segment) }
    open func setSelected(_ selected: Bool, forSegment segment: Int) { segmented?.setSelected(selected, forSegment: segment) }
    open func isSelected(forSegment segment: Int) -> Bool { segmented?.isSelected(forSegment: segment) ?? false }
    open func setToolTip(_ toolTip: String?, forSegment segment: Int) { segmented?.setToolTip(toolTip, forSegment: segment) }
    open func setMenu(_ menu: NSMenu?, forSegment segment: Int) { segmented?.setMenu(menu, forSegment: segment) }
}
@preconcurrency @MainActor open class NSComboBoxCell: NSTextFieldCell {}
@preconcurrency @MainActor open class NSSecureTextFieldCell: NSTextFieldCell {}

/// Pointer events from AppKit's own event dispatch, in a view's coordinates.
extension PointerEvent {
    @MainActor init(_ e: NSEvent, in view: NSView, kind: Kind) {
        let p = view.convert(e.locationInWindow, from: nil)
        var m: KeyModifiers = []
        if e.modifierFlags.contains(.command) { m.insert(.command) }
        if e.modifierFlags.contains(.shift) { m.insert(.shift) }
        if e.modifierFlags.contains(.option) { m.insert(.option) }
        if e.modifierFlags.contains(.control) { m.insert(.control) }
        let clicks = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(e.type) ? e.clickCount : 1
        self.init(kind: kind, location: view.isFlipped ? p : CGPoint(x: p.x, y: view.bounds.height - p.y), button: e.buttonNumber, clickCount: max(1, clicks), modifiers: m)
    }
}

extension KeyPress {
    /// An AppKit key event as Runway's key names.
    @MainActor init?(_ e: NSEvent) {
        let f = e.modifierFlags
        var name: String
        switch e.specialKey {
        case .upArrow?: name = "up"
        case .downArrow?: name = "down"
        case .leftArrow?: name = "left"
        case .rightArrow?: name = "right"
        case .home?: name = "home"
        case .end?: name = "end"
        case .pageUp?: name = "pageup"
        case .pageDown?: name = "pagedown"
        case .tab?, .backTab?: name = "tab"
        case .carriageReturn?, .enter?, .newline?: name = "return"
        case .delete?, .backspace?: name = "backspace"
        case .deleteForward?: name = "delete"
        default:
            guard let c = e.charactersIgnoringModifiers, !c.isEmpty else { return nil }
            name = c == "\u{1b}" ? "escape" : c == " " ? "space" : c.lowercased()
        }
        self.init(key: name, command: f.contains(.command), shift: f.contains(.shift), option: f.contains(.option), control: f.contains(.control))
    }
}
