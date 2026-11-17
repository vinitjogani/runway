// NSTextField as a label (GtkLabel) or an editable field (GtkEntry), with
// NSTextFieldDelegate's editing callbacks and commands (Return, Escape,
// Tab, arrows through `control(_:textView:doCommandBy:)`); NSSecureTextField,
// NSSearchField, NSTokenField and NSComboBox build on it.

import Foundation
import CoreGraphics
import RunwayCore

@preconcurrency @MainActor public protocol NSTextFieldDelegate: NSControlTextEditingDelegate {}

@preconcurrency @MainActor
open class NSTextField: NSControl {
    public enum BezelStyle: UInt, Sendable { case squareBezel = 0, roundedBezel = 1 }

    open weak var delegate: NSTextFieldDelegate?
    open var placeholderString: String? { didSet { controlStateChanged() } }
    open var placeholderAttributedString: NSAttributedString? {
        get { placeholderString.map { NSAttributedString(string: $0) } }
        set { placeholderString = newValue?.string }
    }
    open var textColor: NSColor? { didSet { controlStateChanged() } }
    open var backgroundColor: NSColor? { didSet { controlStateChanged() } }
    open var drawsBackground = false { didSet { controlStateChanged() } }
    open var isEditable = true { didSet { if isEditable != oldValue { rebuild() } } }
    open var isSelectable = true
    open var isBezeled = true {
        didSet {
            if isBezeled { borderRemoved = false }
            if isBezeled != oldValue { rebuild() } else { controlStateChanged() }
        }
    }
    /// AppKit keeps one border type (none, line, bezel): setting either
    /// property replaces it, so `isBordered = false` leaves no border.
    open var isBordered = false {
        didSet {
            borderRemoved = !isBordered
            controlStateChanged()
        }
    }
    private var borderRemoved = false
    /// Whether the field draws a border or bezel.
    var hasBorder: Bool { isBordered || (isBezeled && !borderRemoved) }
    open var bezelStyle: BezelStyle = .squareBezel { didSet { controlStateChanged() } }
    open var maximumNumberOfLines = 0 { didSet { controlStateChanged(); invalidateIntrinsicContentSize() } }
    open var preferredMaxLayoutWidth: CGFloat = 0 { didSet { invalidateIntrinsicContentSize() } }
    open var allowsEditingTextAttributes = false
    open var importsGraphics = false
    open var isAutomaticTextCompletionEnabled = false
    open var allowsDefaultTighteningForTruncation = false
    open var allowsCharacterPickerTouchBarItem = false
    /// What the field holds, for autofill (user names, passwords…).
    open var contentType: NSTextContentType?
    /// How the field draws over its background: emphasized (a selected
    /// table row) turns label colours white, as AppKit's cells do.
    open var backgroundStyle: NSView.BackgroundStyle = .normal { didSet { if backgroundStyle != oldValue { controlStateChanged() } } }
    /// Whether the action goes on every change rather than on Return or end of editing.
    var sendsActionOnChange: Bool { false }

    private(set) var native: NativeWidget
    private var isEntry: Bool
    private var editing = false
    private var edited = false
    var secure: Bool { false }

    public override init(frame frameRect: CGRect) {
        native = makeNative(.textField(secure: false))
        isEntry = true
        super.init(frame: frameRect)
        onMain {
            cell = NSTextFieldCell()
            didMakeNative()
            controlStateChanged()
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        native = makeNative(.textField(secure: false))
        isEntry = true
        super.init(coder: coder)
        onMain {
            cell = NSTextFieldCell()
            didMakeNative()
            controlStateChanged()
        }
        IBDecoding.leave(self, coder)
    }

    public convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
        sizeToFit()
    }
    public convenience init(labelWithString string: String) {
        self.init(frame: .zero)
        configureAsLabel()
        stringValue = string
        sizeToFit()
    }
    public convenience init(wrappingLabelWithString string: String) {
        self.init(frame: .zero)
        configureAsLabel()
        maximumNumberOfLines = 0
        lineBreakMode = .byWordWrapping
        isSelectable = true
        stringValue = string
        sizeToFit()
    }
    public convenience init(labelWithAttributedString s: NSAttributedString) {
        self.init(frame: .zero)
        configureAsLabel()
        attributedStringValue = s
        sizeToFit()
    }

    private func configureAsLabel() {
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        maximumNumberOfLines = 1
        textColor = .labelColor
    }

    /// Entries take typing themselves; AppKit routes only key equivalents.
    open override var usesNativeKeyboardFocus: Bool { isEntry }
    open override var acceptsFirstResponder: Bool { isEntry && isEnabled && (isEditable || isSelectable) }

    /// Labels are GtkLabels; editable or bezeled fields are entries.
    var wantsEntry: Bool { isEditable || isBezeled }

    private func rebuild() {
        let want = wantsEntry
        if want != isEntry {
            Runway.backend.destroy(native)
            native = Runway.backend.makeWidget(want ? .textField(secure: secure) : .text)
            isEntry = want
            didMakeNative()
        }
        controlStateChanged()
        invalidateIntrinsicContentSize()
        layoutSubviews()
    }

    /// Hooks the entry's focus and keys up to the delegate.
    func didMakeNative() {
        if secure, isEntry {
            Runway.backend.destroy(native)
            native = Runway.backend.makeWidget(.textField(secure: true))
        }
        guard isEntry, let ak = Runway.appKit else { return }
        ak.observeTextField(native, focus: { [weak self] f in self?.focusChanged(f) }, key: { [weak self] k in self?.handleKey(k) ?? false })
    }

    // MARK: Display

    var attributedValue: NSAttributedString? { objectValue as? NSAttributedString }

    /// A label sizes to its text (as AppKit, its intrinsic size follows the value).
    open override func controlValueChanged() { controlStateChanged(); if !isEntry { invalidateIntrinsicContentSize() } }
    open override func controlStateChanged() {
        var p = WidgetProps()
        p.enabled = isEnabled
        p.tooltip = toolTip
        p.controlSize = controlSize.value
        var e = WidgetEvents()
        if isEntry {
            p.string = stringValue
            p.placeholder = placeholderString ?? ""
            p.bordered = hasBorder
            // The field's font and colour (the placeholder's too, in its own colour).
            if font != nil || textColor != nil {
                p.text = StyledText(runs: [TextRun(string: "", font: fontSpec, color: textColor.map { (isEnabled ? $0 : .disabledControlTextColor).rgbaValue })])
            }
            e.onText = { [weak self] s in self?.textChanged(s) }
            e.onSubmit = { [weak self] in self?.submitted() }
            Runway.backend.update(native, props: p, events: e)
            Runway.appKit?.setTextFieldAlignment(native, alignment.value)
            Runway.appKit?.setTextFieldEditable(native, isEditable)
        } else {
            p.text = styledText()
            Runway.backend.update(native, props: p, events: e)
        }
        layoutSubviews()
    }

    /// The label's text with its font, colour and wrapping.
    func styledText() -> StyledText {
        var color = (isEnabled ? (textColor ?? .labelColor) : .disabledControlTextColor).rgbaValue
        if backgroundStyle == .emphasized, Self.isLabelColor(textColor) { color = RGBA(1, 1, 1, textColor === NSColor.secondaryLabelColor ? 0.75 : 1) }
        var runs: [TextRun]
        if let a = attributedValue, a.length > 0 {
            let emphasized = backgroundStyle == .emphasized
            runs = a.richRuns(defaultFont: fontSpec, defaultColor: color).map {
                TextRun(string: $0.string, font: $0.font, color: emphasized ? color : $0.color, underline: $0.underline, strikethrough: $0.strikethrough)
            }
        } else {
            runs = [TextRun(string: stringValue, font: fontSpec, color: color)]
        }
        let lines: Int? = maximumNumberOfLines == 1 || usesSingleLineMode || (maximumNumberOfLines == 0 && lineBreakMode != .byWordWrapping && lineBreakMode != .byCharWrapping && !(cell?.wraps ?? false) && preferredMaxLayoutWidth == 0) ? 1 : (maximumNumberOfLines == 0 ? nil : maximumNumberOfLines)
        let trunc: TruncationValue = lineBreakMode == .byTruncatingHead ? .head : lineBreakMode == .byTruncatingMiddle ? .middle : .tail
        return StyledText(runs: runs, alignment: alignment.value, lineLimit: lines, truncation: trunc)
    }

    static func isLabelColor(_ c: NSColor?) -> Bool {
        guard let c else { return true }
        return [NSColor.labelColor, .secondaryLabelColor, .tertiaryLabelColor, .controlTextColor, .textColor, .headerTextColor].contains { $0 === c }
    }

    override func place() {
        placementDirty = false
        if isEntry, !hasBorder {
            // A borderless field is its text: the frame's height, text at the top.
            placeChildren(below: [(native, bounds)])
        } else if isEntry {
            // Entries keep their natural height, centred, as AppKit draws them.
            let h = min(bounds.height, max(controlSize.height, 0))
            placeChildren(below: [(native, CGRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h > 0 ? h : bounds.height))])
        } else {
            placeChildren(below: [(native, bounds)])
        }
    }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }

    open override var intrinsicContentSize: CGSize {
        if isEntry {
            // Editable fields have no intrinsic width in AppKit.
            return CGSize(width: -1, height: controlSize.height)
        }
        let wraps = styledText().lineLimit != 1
        let width: CGFloat? = wraps && preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : nil
        let s = measured(native, width: width)
        return CGSize(width: s.width.rounded(.up), height: s.height.rounded(.up))
    }

    open override func sizeToFit() {
        if isEntry {
            setFrameSize(CGSize(width: frame.width > 0 ? frame.width : 96, height: controlSize.height))
        } else {
            super.sizeToFit()
        }
    }

    /// A label's height at a width (stack views and tables wrap labels).
    func height(forWidth w: CGFloat) -> CGFloat {
        if isEntry { return controlSize.height }
        return Runway.backend.measure(native, proposal: ProposedSize(width: w, height: nil)).height.rounded(.up)
    }

    // MARK: Editing

    private func notify(_ name: Notification.Name) -> Notification {
        Notification(name: name, object: self, userInfo: ["NSFieldEditor": NSTextView.fieldEditor(for: self)])
    }

    func textChanged(_ s: String) {
        NSTextView.fieldEditor(for: self).string = s
        if !editing {
            editing = true
            let n = notify(NSControl.textDidBeginEditingNotification)
            delegate?.controlTextDidBeginEditing(n)
            NotificationCenter.default.post(n)
        }
        edited = true
        setValueFromField(s)
        let n = notify(NSControl.textDidChangeNotification)
        delegate?.controlTextDidChange(n)
        NotificationCenter.default.post(n)
        if sendsActionOnChange || isContinuous { fireAction() }
    }

    /// Stores the field's text without pushing it back to the field.
    func setValueFromField(_ s: String) {
        if let f = formatter {
            if let n = (f as? NumberFormatter)?.number(from: s) { super.objectValue = n; return }
            if let d = (f as? DateFormatter)?.date(from: s) { super.objectValue = d; return }
        }
        super.objectValue = s
    }

    func endEditing() {
        guard editing else { return }
        editing = false
        let n = Notification(name: NSControl.textDidEndEditingNotification, object: self,
                             userInfo: ["NSFieldEditor": NSTextView.fieldEditor(for: self), "NSTextMovement": NSTextMovement.other.rawValue])
        delegate?.controlTextDidEndEditing(n)
        NotificationCenter.default.post(n)
        if edited, cell?.sendsActionOnEndEditing ?? false { fireAction() }
        edited = false
    }

    private var hasFocus = false
    func focusChanged(_ focused: Bool) {
        hasFocus = focused
        if !focused { endEditing() }
    }

    /// The window's field editor while the field has keyboard focus.
    open override func currentEditor() -> NSText? {
        guard hasFocus else { return nil }
        let editor = NSTextView.fieldEditor(for: self)
        editor.string = stringValue
        editor.fieldEditorClient = self
        return editor
    }

    /// Asks the delegate to handle a command, as the field editor does.
    func doCommand(_ selector: Selector) -> Bool {
        let editor = NSTextView.fieldEditor(for: self)
        editor.string = stringValue
        return delegate?.control(self, textView: editor, doCommandBy: selector) ?? false
    }

    /// Keys before the entry handles them.
    func handleKey(_ k: KeyPress) -> Bool {
        guard !k.command else { return false }
        switch k.key {
        case "return": return doCommand(Selector(k.option ? "insertNewlineIgnoringFieldEditor:" : "insertNewline:"))
        case "escape": return doCommand(Selector("cancelOperation:")) || cancelled()
        case "tab": return doCommand(Selector(k.shift ? "insertBacktab:" : "insertTab:"))
        case "up": return doCommand(Selector("moveUp:"))
        case "down": return doCommand(Selector("moveDown:"))
        default: return false
        }
    }

    /// Escape not handled by the delegate (search fields clear).
    func cancelled() -> Bool { false }

    /// Return: AppKit sends the action and stays in the field.
    func submitted() {
        fireAction()
        if editing {
            let n = Notification(name: NSControl.textDidEndEditingNotification, object: self,
                                 userInfo: ["NSFieldEditor": NSTextView.fieldEditor(for: self), "NSTextMovement": NSTextMovement.return.rawValue])
            editing = false
            edited = false
            delegate?.controlTextDidEndEditing(n)
            NotificationCenter.default.post(n)
        }
    }

    open func selectText(_ sender: Any?) { Runway.appKit?.focus(native) }

    /// NSAccessibilityStaticText's `accessibilityValue`: the field's text.
    /// (An overload of NSView's `Any?`-returning method, for subclasses that
    /// override it with this type as they do against AppKit.)
    open func accessibilityValue() -> String? { stringValue }

    /// Runway: puts keyboard focus in the field.
    open func _runwayFocus() { Runway.appKit?.focus(native) }
}

public enum NSTextMovement: Int, Sendable {
    case other = 0, `return` = 0x10, tab = 0x11, backtab = 0x12, left = 0x13, right = 0x14, up = 0x15, down = 0x16, cancel = 0x17
}

/// A password field (GtkEntry without visible characters).
@preconcurrency @MainActor open class NSSecureTextField: NSTextField {
    override var secure: Bool { true }
    open var echosBullets = true
}

// MARK: Search field

@preconcurrency @MainActor public protocol NSSearchFieldDelegate: NSTextFieldDelegate {
    func searchFieldDidStartSearching(_ sender: NSSearchField)
    func searchFieldDidEndSearching(_ sender: NSSearchField)
}
extension NSSearchFieldDelegate {
    public func searchFieldDidStartSearching(_ sender: NSSearchField) {}
    public func searchFieldDidEndSearching(_ sender: NSSearchField) {}
}

/// A search field: magnifier, clear button, and an action on each change
/// (or on Return with `sendsWholeSearchString`).
@preconcurrency @MainActor open class NSSearchField: NSTextField {
    open var sendsSearchStringImmediately = false
    open var sendsWholeSearchString = false
    open var recentSearches: [String] = []
    open var recentsAutosaveName: String?
    open var maximumRecents = 10
    open var searchMenuTemplate: NSMenu?
    open var centersPlaceholder = false
    open var searchTextBounds: CGRect { bounds.insetBy(dx: 22, dy: 0) }
    private var searching = false

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain {
            bezelStyle = .roundedBezel
            if placeholderString == nil { placeholderString = "Search" }
            Runway.appKit?.setSearchField(native, true)
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        onMain {
            bezelStyle = .roundedBezel
            if placeholderString == nil { placeholderString = "Search" }
            Runway.appKit?.setSearchField(native, true)
        }
        IBDecoding.leave(self, coder)
    }

    override var sendsActionOnChange: Bool { !sendsWholeSearchString }

    override func textChanged(_ s: String) {
        super.textChanged(s)
        let delegate = self.delegate as? NSSearchFieldDelegate
        if !s.isEmpty, !searching { searching = true; delegate?.searchFieldDidStartSearching(self) }
        if s.isEmpty, searching { searching = false; delegate?.searchFieldDidEndSearching(self) }
    }

    override func submitted() {
        if sendsWholeSearchString { fireAction() }
        let s = stringValue
        if !s.isEmpty, !recentSearches.contains(s) {
            recentSearches.insert(s, at: 0)
            if recentSearches.count > maximumRecents { recentSearches.removeLast() }
        }
    }

    override func cancelled() -> Bool {
        guard !stringValue.isEmpty else { return false }
        stringValue = ""
        textChanged("")
        return true
    }
}

// MARK: Token field

@preconcurrency @MainActor public protocol NSTokenFieldDelegate: NSTextFieldDelegate {}

/// A token field, edited as text: tokens are separated by the tokenizing
/// characters (comma by default) and its value is the array of tokens.
@preconcurrency @MainActor open class NSTokenField: NSTextField {
    public enum TokenStyle: UInt, Sendable { case `default`, none, rounded, squared, plainSquared }
    open var tokenStyle: TokenStyle = .default
    open var tokenizingCharacterSet: CharacterSet = CharacterSet(charactersIn: ",")
    open var completionDelay: TimeInterval = 0
    public static var defaultTokenizingCharacterSet: CharacterSet { CharacterSet(charactersIn: ",") }

    open override var objectValue: Any? {
        get {
            stringValue.components(separatedBy: tokenizingCharacterSet).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        set {
            if let tokens = newValue as? [Any] { stringValue = tokens.map { "\($0)" }.joined(separator: ", ") }
            else { super.objectValue = newValue }
        }
    }
    open override var stringValue: String {
        get { (super.objectValue as? String) ?? "" }
        set { super.objectValue = newValue }
    }
    override func setValueFromField(_ s: String) { super.objectValue = s }
}

// MARK: Combo box

@preconcurrency @MainActor public protocol NSComboBoxDataSource: AnyObject {
    func numberOfItems(in comboBox: NSComboBox) -> Int
    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any?
    func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int
    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String?
}
extension NSComboBoxDataSource {
    public func numberOfItems(in comboBox: NSComboBox) -> Int { 0 }
    public func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? { nil }
    public func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int { NSNotFound }
    public func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? { nil }
}

@preconcurrency @MainActor public protocol NSComboBoxDelegate: NSTextFieldDelegate {
    func comboBoxSelectionDidChange(_ notification: Notification)
    func comboBoxSelectionIsChanging(_ notification: Notification)
    func comboBoxWillPopUp(_ notification: Notification)
    func comboBoxWillDismiss(_ notification: Notification)
}
extension NSComboBoxDelegate {
    public func comboBoxSelectionDidChange(_ notification: Notification) {}
    public func comboBoxSelectionIsChanging(_ notification: Notification) {}
    public func comboBoxWillPopUp(_ notification: Notification) {}
    public func comboBoxWillDismiss(_ notification: Notification) {}
}

/// An editable field with a list of choices: a GtkEntry with a pop-up
/// menu button at its trailing edge.
@preconcurrency @MainActor open class NSComboBox: NSTextField {
    public static let selectionDidChangeNotification = Notification.Name("NSComboBoxSelectionDidChangeNotification")
    public static let selectionIsChangingNotification = Notification.Name("NSComboBoxSelectionIsChangingNotification")
    public static let willPopUpNotification = Notification.Name("NSComboBoxWillPopUpNotification")
    public static let willDismissNotification = Notification.Name("NSComboBoxWillDismissNotification")

    open var usesDataSource = false { didSet { updateMenu() } }
    open weak var dataSource: NSComboBoxDataSource? { didSet { updateMenu() } }
    open var hasVerticalScroller = true
    open var numberOfVisibleItems = 5
    open var itemHeight: CGFloat = 16
    open var intercellSpacing = CGSize(width: 3, height: 2)
    open var completes = false
    open var isButtonBordered = true
    open private(set) var objectValues: [Any] = []
    open private(set) var indexOfSelectedItem = -1
    private let menuButton: NativeWidget

    public override init(frame frameRect: CGRect) {
        menuButton = makeNative(.menuButton)
        super.init(frame: frameRect)
        onMain { updateMenu() }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        menuButton = makeNative(.menuButton)
        super.init(coder: coder)
        onMain { updateMenu() }
        IBDecoding.leave(self, coder)
    }

    open var numberOfItems: Int { usesDataSource ? (dataSource?.numberOfItems(in: self) ?? 0) : objectValues.count }
    open func itemObjectValue(at index: Int) -> Any {
        if usesDataSource { return dataSource?.comboBox(self, objectValueForItemAt: index) ?? "" }
        return objectValues[index]
    }
    open var objectValueOfSelectedItem: Any? { indexOfSelectedItem >= 0 && indexOfSelectedItem < numberOfItems ? itemObjectValue(at: indexOfSelectedItem) : nil }
    open func addItem(withObjectValue v: Any) { objectValues.append(v); updateMenu() }
    open func addItems(withObjectValues vs: [Any]) { objectValues += vs; updateMenu() }
    open func insertItem(withObjectValue v: Any, at i: Int) { objectValues.insert(v, at: min(i, objectValues.count)); updateMenu() }
    open func removeItem(withObjectValue v: Any) { objectValues.removeAll { "\($0)" == "\(v)" }; updateMenu() }
    open func removeItem(at i: Int) { objectValues.remove(at: i); updateMenu() }
    open func removeAllItems() { objectValues.removeAll(); indexOfSelectedItem = -1; updateMenu() }
    open func indexOfItem(withObjectValue v: Any) -> Int {
        if usesDataSource { return dataSource?.comboBox(self, indexOfItemWithStringValue: "\(v)") ?? NSNotFound }
        return objectValues.firstIndex { "\($0)" == "\(v)" } ?? NSNotFound
    }
    open func selectItem(at i: Int) {
        guard i >= 0, i < numberOfItems else { deselectItem(at: indexOfSelectedItem); return }
        indexOfSelectedItem = i
        stringValue = "\(itemObjectValue(at: i))"
        let n = Notification(name: Self.selectionDidChangeNotification, object: self)
        (delegate as? NSComboBoxDelegate)?.comboBoxSelectionDidChange(n)
        NotificationCenter.default.post(n)
    }
    open func selectItem(withObjectValue v: Any?) { if let v { selectItem(at: indexOfItem(withObjectValue: v)) } }
    open func deselectItem(at i: Int) { indexOfSelectedItem = -1 }
    open func reloadData() { updateMenu() }
    open func noteNumberOfItemsChanged() { updateMenu() }
    open func scrollItemAtIndexToTop(_ i: Int) {}
    open func scrollItemAtIndexToVisible(_ i: Int) {}

    private func updateMenu() {
        var p = WidgetProps()
        p.image = .symbol("chevron.down")
        p.bordered = false
        p.enabled = isEnabled
        var e = WidgetEvents()
        e.menu = (0..<numberOfItems).map { i in
            MenuItemSpec(title: "\(itemObjectValue(at: i))", checked: i == indexOfSelectedItem) { [weak self] in
                self?.selectItem(at: i)
                self?.fireAction()
            }
        }
        Runway.backend.update(menuButton, props: p, events: e)
    }

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        super.controlStateChanged()
        if numberOfItems > 0 || !usesDataSource { updateMenu() }
    }

    override func textChanged(_ s: String) {
        indexOfSelectedItem = (0..<numberOfItems).first { "\(itemObjectValue(at: $0))" == s } ?? -1
        super.textChanged(s)
    }

    override func place() {
        placementDirty = false
        let h = min(bounds.height, controlSize.height)
        let y = ((bounds.height - h) / 2).rounded()
        let b: CGFloat = h
        placeChildren(below: [(native, CGRect(x: 0, y: y, width: bounds.width, height: h)),
                              (menuButton, CGRect(x: bounds.width - b - 1, y: y + 1, width: b, height: h - 2))])
    }
}

/// The kind of content a text field holds, for autofill.
public struct NSTextContentType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let username = NSTextContentType("username"), password = NSTextContentType("password")
    public static let newPassword = NSTextContentType("new-password"), oneTimeCode = NSTextContentType("one-time-code")
    public static let emailAddress = NSTextContentType("email"), URL = NSTextContentType("url")
    public static let name = NSTextContentType("name"), givenName = NSTextContentType("given-name"), familyName = NSTextContentType("family-name")
    public static let telephoneNumber = NSTextContentType("tel"), fullStreetAddress = NSTextContentType("street-address")
    public static let postalCode = NSTextContentType("postal-code"), organizationName = NSTextContentType("organization")
    public static let addressCity = NSTextContentType("address-level2"), countryName = NSTextContentType("country-name")
    public static let dateTime = NSTextContentType("date-time"), flightNumber = NSTextContentType("flight-number")
    public static let shipmentTrackingNumber = NSTextContentType("shipment-tracking-number")
}

