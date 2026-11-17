// NSControl: the base the standard controls (NSButton, NSTextField,
// NSSlider… in their own files) build on: target/action through
// RunwayObjC, enabled state, values, font and alignment, control size.
//
// Controls that are native widgets put their widget in `widget` (an
// NSView's container) via `nativeControl`, report user changes by calling
// `sendAction(action, to: target)`, and override `usesNativeKeyboardFocus`
// when the widget takes typing itself.

import Foundation
import RunwayCore
import RunwayObjC

@preconcurrency @MainActor
open class NSControl: NSView {
    public struct StateValue: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let on = StateValue(rawValue: 1), off = StateValue(rawValue: 0), mixed = StateValue(rawValue: -1)
    }
    public enum ControlSize: UInt, Sendable { case regular, small, mini, large, extraLarge }

    open weak var target: AnyObject?
    open var action: Selector?
    open override var tag: Int { get { _tag } set { _tag = newValue } }
    private var _tag = 0
    open var isEnabled = true { didSet { if isEnabled != oldValue { controlStateChanged() } } }
    open var isHighlighted = false
    open var isContinuous = false
    open var refusesFirstResponder = false
    open var ignoresMultiClick = false
    open var controlSize: ControlSize = .regular { didSet { controlStateChanged() } }
    open var font: NSFont? { didSet { controlStateChanged() } }
    open var alignment: NSTextAlignment = .natural { didSet { controlStateChanged() } }
    open var lineBreakMode: NSLineBreakMode = .byTruncatingTail { didSet { controlStateChanged() } }
    open var baseWritingDirection: NSWritingDirection = .natural
    open var usesSingleLineMode = false
    open var allowsExpansionToolTips = false
    open var formatter: Formatter?
    private var actionMask: NSEvent.EventTypeMask = .leftMouseUp

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }

    // Values: one stored object, the typed accessors convert.
    private var _objectValue: Any?
    open var objectValue: Any? {
        get { _objectValue }
        set { _objectValue = newValue; controlValueChanged() }
    }
    open var stringValue: String {
        get {
            if let f = formatter, let v = _objectValue { return f.string(for: v) ?? "" }
            if let s = _objectValue as? String { return s }
            if let a = _objectValue as? NSAttributedString { return a.string }
            return _objectValue.map { "\($0)" } ?? ""
        }
        set { objectValue = newValue }
    }
    open var attributedStringValue: NSAttributedString {
        get { (_objectValue as? NSAttributedString) ?? NSAttributedString(string: stringValue) }
        set { objectValue = newValue }
    }
    open var doubleValue: Double {
        get { (_objectValue as? Double) ?? (_objectValue as? NSNumber)?.doubleValue ?? (_objectValue as? Int).map(Double.init) ?? Double(stringValue) ?? 0 }
        set { objectValue = newValue }
    }
    open var floatValue: Float { get { Float(doubleValue) } set { doubleValue = Double(newValue) } }
    open var intValue: Int32 { get { Int32(clamping: Int(doubleValue.rounded(.towardZero))) } set { objectValue = Int(newValue) } }
    open var integerValue: Int { get { Int(doubleValue.rounded(.towardZero)) } set { objectValue = newValue } }

    open func takeStringValueFrom(_ sender: Any?) { if let c = sender as? NSControl { stringValue = c.stringValue } }
    open func takeDoubleValueFrom(_ sender: Any?) { if let c = sender as? NSControl { doubleValue = c.doubleValue } }
    open func takeIntValueFrom(_ sender: Any?) { if let c = sender as? NSControl { intValue = c.intValue } }
    open func takeIntegerValueFrom(_ sender: Any?) { if let c = sender as? NSControl { integerValue = c.integerValue } }
    open func takeFloatValueFrom(_ sender: Any?) { if let c = sender as? NSControl { floatValue = c.floatValue } }
    open func takeObjectValueFrom(_ sender: Any?) { if let c = sender as? NSControl { objectValue = c.objectValue } }

    /// Sends the action to the target, or along the responder chain when
    /// the target is nil (`NSApp.sendAction`).
    @discardableResult
    open func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard let action, isEnabled else { return false }
        return NSApp.sendAction(action, to: target, from: self)
    }
    @discardableResult
    open func sendAction(on mask: NSEvent.EventTypeMask) -> Int {
        let old = Int(actionMask.rawValue)
        actionMask = mask
        return old
    }
    /// Acts as if clicked: sends the action.
    open func performClick(_ sender: Any?) { sendAction(action, to: target) }

    open func sizeToFit() {
        let s = fittingSize
        if s.width > 0 || s.height > 0 { setFrameSize(s) }
    }
    open func abortEditing() -> Bool { false }
    open func validateEditing() {}
    /// The field editor while the control's text is being edited, else nil.
    open func currentEditor() -> NSText? { nil }
    open func edit(withFrame rect: NSRect, editor: NSView, delegate: Any?, event: NSEvent) {}
    open func expansionFrame(withFrame contentFrame: NSRect) -> NSRect { .zero }

    open override var acceptsFirstResponder: Bool { isEnabled && !refusesFirstResponder }
    open override var acceptsFirstMouse: Bool { true }

    /// Hooks for subclasses: the value or the look changed (update the
    /// native widget here).
    open func controlValueChanged() { needsDisplay = true }
    open func controlStateChanged() { needsDisplay = true }

    /// Runway: puts a native widget made by the backend inside this control,
    /// filling its bounds (controls built on GTK widgets use this).
    open func setNativeControl(_ w: NativeWidget?) {
        nativeControl = w
        setNeedsPlacement()
    }
    open private(set) var nativeControl: NativeWidget?
    override func place() {
        if let w = nativeControl {
            placementDirty = false
            var children: [(NativeWidget, CGRect)] = [(w, CGRect(origin: .zero, size: frame.size))]
            if let d = drawingWidget { children.insert((d, CGRect(origin: .zero, size: frame.size)), at: 0) }
            for s in subviews where !s.isHidden { children.append((s.widget, widgetRect(of: s))) }
            Runway.backend.setChildren(widget, children, contentSize: frame.size)
        } else {
            super.place()
        }
    }
}
