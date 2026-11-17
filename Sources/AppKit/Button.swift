// NSButton (push, toggle, checkbox, radio, image and bezel styles, key
// equivalents) and NSSwitch, each on the platform's own control: GtkButton,
// GtkToggleButton, GtkCheckButton (grouped for radios) and GtkSwitch.

import Foundation
import CoreGraphics
import RunwayCore

public enum NSImageScaling: UInt, Sendable { case scaleProportionallyDown = 0, scaleAxesIndependently, scaleNone, scaleProportionallyUpOrDown }

@preconcurrency @MainActor
open class NSButton: NSControl {
    public enum ButtonType: UInt, Sendable {
        case momentaryLight = 0, pushOnPushOff = 1, toggle = 2, `switch` = 3, radio = 4, momentaryChange = 5, onOff = 6,
             momentaryPushIn = 7, accelerator = 8, multiLevelAccelerator = 9
    }
    public enum BezelStyle: UInt, Sendable {
        case rounded = 1, regularSquare = 2, disclosure = 5, shadowlessSquare = 6, circular = 7, texturedSquare = 8,
             helpButton = 9, smallSquare = 10, texturedRounded = 11, roundRect = 12, recessed = 13, roundedDisclosure = 14, inline = 15
        // macOS 14's names.
        public static var push: BezelStyle { .rounded }
        public static var flexiblePush: BezelStyle { .regularSquare }
        public static var toolbar: BezelStyle { .texturedRounded }
        public static var accessoryBarAction: BezelStyle { .roundRect }
        public static var accessoryBar: BezelStyle { .recessed }
        public static var pushDisclosure: BezelStyle { .roundedDisclosure }
        public static var badge: BezelStyle { .inline }
        public static var automatic: BezelStyle { .rounded }
    }

    open var title: String = "" { didSet { if title != oldValue { controlStateChanged(); invalidateIntrinsicContentSize() } } }
    open var alternateTitle = ""
    open var attributedTitle: NSAttributedString {
        get { NSAttributedString(string: title) }
        set { title = newValue.string }
    }
    open var attributedAlternateTitle = NSAttributedString(string: "")
    open var image: NSImage? { didSet { controlStateChanged(); invalidateIntrinsicContentSize() } }
    open var alternateImage: NSImage? { didSet { controlStateChanged() } }
    open var imagePosition: NSControl.ImagePosition = .imageLeading { didSet { controlStateChanged(); invalidateIntrinsicContentSize() } }
    open var imageScaling: NSImageScaling = .scaleProportionallyDown
    open var imageHugsTitle = false
    open var symbolConfiguration: NSImage.SymbolConfiguration? { didSet { controlStateChanged() } }
    open var isBordered = true { didSet { if isBordered != oldValue { controlStateChanged() } } }
    open var isTransparent = false { didSet { controlStateChanged() } }
    open var bezelStyle: BezelStyle = .rounded { didSet { if bezelStyle != oldValue { rebuildIfNeeded(); controlStateChanged(); invalidateIntrinsicContentSize() } } }
    open var bezelColor: NSColor? { didSet { controlStateChanged() } }
    open var contentTintColor: NSColor? { didSet { controlStateChanged() } }
    open var showsBorderOnlyWhileMouseInside = false { didSet { controlStateChanged() } }
    open var hasDestructiveAction = false { didSet { controlStateChanged() } }
    open var allowsMixedState = false
    open var isSpringLoaded = false
    open var maxAcceleratorLevel = 1
    open var sound: NSSound?
    open var keyEquivalent = "" { didSet { if keyEquivalent != oldValue { controlStateChanged(); updateKeyEquivalent() } } }
    open var keyEquivalentModifierMask: NSEvent.ModifierFlags = [] { didSet { updateKeyEquivalent() } }
    open var state: NSControl.StateValue = .off { didSet { if state != oldValue { controlStateChanged() } } }
    open private(set) var buttonType: ButtonType = .momentaryPushIn

    /// The native control, remade when the button's type changes kind.
    private(set) var native: NativeWidget
    private var nativeKind: WidgetKind
    private var imageWidget: NativeWidget?
    private var labelWidget: LabelWidget?

    public override init(frame frameRect: CGRect) {
        nativeKind = .button
        native = makeNative(.button)
        super.init(frame: frameRect)
        onMain {
            cell = NSButtonCell()
            controlStateChanged()
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        nativeKind = .button
        native = makeNative(.button)
        super.init(coder: coder)
        onMain {
            cell = NSButtonCell()
            controlStateChanged()
        }
        IBDecoding.leave(self, coder)
    }

    public convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        rebuildIfNeeded()
        controlStateChanged()
        sizeToFit()
    }
    public convenience init(image: NSImage, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        self.target = target
        self.action = action
        rebuildIfNeeded()
        controlStateChanged()
        sizeToFit()
    }
    public convenience init(title: String, image: NSImage, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.image = image
        imagePosition = .imageLeading
        self.target = target
        self.action = action
        rebuildIfNeeded()
        controlStateChanged()
        sizeToFit()
    }
    public convenience init(checkboxWithTitle title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        self.target = target
        self.action = action
        rebuildIfNeeded()
        controlStateChanged()
        sizeToFit()
    }
    public convenience init(radioButtonWithTitle title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        setButtonType(.radio)
        self.title = title
        self.target = target
        self.action = action
        rebuildIfNeeded()
        controlStateChanged()
        sizeToFit()
    }

    open func setButtonType(_ type: ButtonType) {
        buttonType = type
        rebuildIfNeeded()
        controlStateChanged()
        invalidateIntrinsicContentSize()
    }

    // MARK: Values

    open override var objectValue: Any? {
        get { state.rawValue }
        set {
            switch newValue {
            case let i as Int: state = NSControl.StateValue(rawValue: i)
            case let n as NSNumber: state = NSControl.StateValue(rawValue: n.intValue)
            case let b as Bool: state = b ? .on : .off
            default: state = .off
            }
        }
    }
    open override var stringValue: String {
        get { String(state.rawValue) }
        set { state = NSControl.StateValue(rawValue: Int(newValue) ?? 0) }
    }

    /// The state after a click (cycling through mixed when allowed).
    var nextState: NSControl.StateValue {
        switch state {
        case .on: return allowsMixedState ? .mixed : .off
        case .mixed: return .off
        default: return .on
        }
    }

    var isToggle: Bool { [.pushOnPushOff, .toggle, .onOff, .switch, .radio].contains(buttonType) }
    var isCheckbox: Bool { buttonType == .switch }
    var isRadio: Bool { buttonType == .radio }

    open override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        clicked()
    }

    /// A click: toggles state where the type keeps one, then sends the action.
    private func clicked() {
        if isRadio {
            state = .on
            turnOffSiblingRadios()
        } else if isToggle {
            state = nextState
        }
        sound?.play()
        fireAction()
    }

    /// Radios sharing a superview and an action act as one group, as in AppKit.
    private func turnOffSiblingRadios() {
        for case let b as NSButton in superview?.subviews ?? [] where b !== self && b.isRadio && b.action == action {
            b.state = .off
        }
    }

    // MARK: Native widget

    private var wantedKind: WidgetKind {
        switch buttonType {
        case .switch, .radio: return .toggle(.checkbox)
        case .pushOnPushOff, .toggle, .onOff: return .toggle(.button)
        default: return .button
        }
    }

    private func rebuildIfNeeded() {
        guard wantedKind != nativeKind else { return }
        Runway.backend.destroy(native)
        imageWidget = nil
        labelWidget = nil
        nativeKind = wantedKind
        native = Runway.backend.makeWidget(nativeKind)
        if isRadio { Runway.appKit?.setRadio(native) }
        updateKeyEquivalent()
        layoutSubviews()
    }

    /// Whether the button shows an image (and so lays out its own label).
    private var hasImageContent: Bool { image != nil && nativeKind == .button && imagePosition != .noImage }

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        var p = WidgetProps()
        p.title = hasImageContent ? "" : title
        p.enabled = isEnabled
        p.tooltip = toolTip
        p.controlSize = controlSize.value
        p.isOn = state == .on
        p.indeterminate = state == .mixed
        p.isDefault = keyEquivalent == "\r"
        p.isCancel = keyEquivalent == "\u{1b}"
        p.prominent = p.isDefault && isBordered && (bezelStyle == .rounded || bezelStyle == .regularSquare)
        p.isDestructive = hasDestructiveAction
        p.tint = bezelColor?.rgbaValue
        p.bordered = isBordered && !isTransparent && ![.recessed, .inline].contains(bezelStyle) || bezelStyle == .inline
        p.hasContent = hasImageContent
        var e = WidgetEvents()
        e.onTap = { [weak self] in self?.nativeTapped() }
        e.onToggle = { [weak self] on in self?.nativeToggled(on) }
        Runway.backend.update(native, props: p, events: e)
        if let ak = Runway.appKit {
            for style in ["rw-bezel-textured", "rw-bezel-recessed", "rw-bezel-inline", "rw-bezel-accessory", "rw-bezel-circular", "rw-bezel-help",
                          "rw-bezel-square", "rw-hover-border"] {
                ak.setStyleClass(native, style, false)
            }
            switch bezelStyle {
            case .texturedRounded, .texturedSquare: ak.setStyleClass(native, "rw-bezel-textured", true)
            case .recessed: ak.setStyleClass(native, "rw-bezel-recessed", true)
            case .inline: ak.setStyleClass(native, "rw-bezel-inline", true)
            case .roundRect: ak.setStyleClass(native, "rw-bezel-accessory", true)
            case .circular: ak.setStyleClass(native, "rw-bezel-circular", true)
            case .helpButton: ak.setStyleClass(native, "rw-bezel-help", true)
            case .smallSquare, .shadowlessSquare, .regularSquare: ak.setStyleClass(native, "rw-bezel-square", true)
            default: break
            }
            if showsBorderOnlyWhileMouseInside { ak.setStyleClass(native, "rw-hover-border", true) }
        }
        if hasImageContent { updateImageContent() }
        layoutSubviews()
    }

    private func nativeTapped() {
        guard isEnabled else { return }
        clicked()
    }

    private func nativeToggled(_ on: Bool) {
        guard isEnabled else { controlStateChanged(); return }
        // A radio clicked while on stays on (GTK may report it turning off).
        if isRadio, !on, state == .on { controlStateChanged(); return }
        clicked()
        controlStateChanged()
    }

    private func updateKeyEquivalent() {
        guard let ak = Runway.appKit else { return }
        _ = ak
        Runway.appKit?.setKeyEquivalent(native, Self.keyPress(keyEquivalent, keyEquivalentModifierMask))
    }

    static func keyPress(_ key: String, _ mask: NSEvent.ModifierFlags) -> KeyPress? {
        guard !key.isEmpty else { return nil }
        let name: String
        switch key {
        case "\r", "\n": name = "return"
        case "\u{1b}": name = "escape"
        case "\t": name = "tab"
        case " ": name = "space"
        case "\u{7f}", "\u{8}": name = "backspace"
        default: name = key.lowercased()
        }
        let shift = mask.contains(.shift) || (key != key.lowercased())
        return KeyPress(key: name, command: mask.contains(.command), shift: shift, option: mask.contains(.option), control: mask.contains(.control))
    }

    // MARK: Image content

    private func updateImageContent() {
        guard let image else { return }
        if imageWidget == nil { imageWidget = Runway.backend.makeWidget(.image) }
        var ip = WidgetProps()
        ip.image = (state == .on ? alternateImage ?? image : image).imageSource
        ip.imageTint = contentTintColor?.rgbaValue ?? (isEnabled ? nil : NSColor.tertiaryLabelColor.rgbaValue)
        ip.imagePointSize = symbolConfiguration?.pointSize ?? (controlSize == .small ? 11 : controlSize == .large ? 15 : 13)
        Runway.backend.update(imageWidget!, props: ip, events: WidgetEvents())
        if imagePosition != .imageOnly, !title.isEmpty {
            if labelWidget == nil { labelWidget = LabelWidget() }
            labelWidget!.set(title, font: NSFont(spec: fontSpec), color: isEnabled ? (contentTintColor ?? .controlTextColor) : .disabledControlTextColor)
        } else {
            labelWidget = nil
        }
        layoutImageContent()
    }

    private func imageSize() -> CGSize {
        guard let w = imageWidget else { return .zero }
        if let image, image.size.width > 0, case .file = image.imageSource { return image.size }
        return Runway.backend.measure(w, proposal: .unspecified)
    }

    /// Image and title inside the button's label area, by `imagePosition`.
    private func layoutImageContent() {
        guard let imageWidget else { return }
        let container = Runway.backend.childContainer(native)
        // The area the toolkit gives the content (the button less its
        // padding and border), so the image centres in the button.
        let ins = Runway.appKit?.labelAreaInsets(native) ?? Runway.backend.contentInsets(native)
        let area = CGSize(width: max(0, bounds.width - ins.leading - ins.trailing), height: max(0, bounds.height - ins.top - ins.bottom))
        let i = imageSize()
        guard let label = labelWidget else {
            Runway.backend.setChildren(container, [(imageWidget, CGRect(x: ((area.width - i.width) / 2).rounded(), y: ((area.height - i.height) / 2).rounded(), width: i.width, height: i.height))], contentSize: area)
            return
        }
        let t = label.size()
        let gap: CGFloat = 4
        var ir = CGRect(origin: .zero, size: i), tr = CGRect(origin: .zero, size: t)
        switch imagePosition {
        case .imageAbove, .imageBelow:
            let total = i.height + gap + t.height
            let top = ((area.height - total) / 2).rounded()
            let imageFirst = imagePosition == .imageAbove
            ir.origin = CGPoint(x: ((area.width - i.width) / 2).rounded(), y: imageFirst ? top : top + t.height + gap)
            tr.origin = CGPoint(x: ((area.width - t.width) / 2).rounded(), y: imageFirst ? top + i.height + gap : top)
        case .imageOverlaps:
            ir.origin = CGPoint(x: ((area.width - i.width) / 2).rounded(), y: ((area.height - i.height) / 2).rounded())
            tr.origin = CGPoint(x: ((area.width - t.width) / 2).rounded(), y: ((area.height - t.height) / 2).rounded())
        default:
            let imageFirst = imagePosition != .imageRight && imagePosition != .imageTrailing
            let total = i.width + gap + t.width
            let left = max(0, ((area.width - total) / 2).rounded())
            ir.origin = CGPoint(x: imageFirst ? left : left + t.width + gap, y: ((area.height - i.height) / 2).rounded())
            tr.origin = CGPoint(x: imageFirst ? left + i.width + gap : left, y: ((area.height - t.height) / 2).rounded())
        }
        Runway.backend.setChildren(container, [(imageWidget, ir), (label.widget, tr)], contentSize: area)
    }

    // MARK: Layout

    override func place() {
        placementDirty = false
        placeChildren(below: [(native, bounds)])
        if hasImageContent { layoutImageContent() }
    }

    open override func frameSizeChanged(from old: CGSize) {
        super.frameSizeChanged(from: old)
        layoutSubviews()
    }

    open override var intrinsicContentSize: CGSize {
        var s: CGSize
        if hasImageContent {
            let ins = Runway.backend.contentInsets(native)
            let i = imageSize()
            let t = labelWidget?.size() ?? .zero
            switch imagePosition {
            case .imageOnly, .imageOverlaps: s = CGSize(width: max(i.width, t.width), height: max(i.height, t.height))
            case .imageAbove, .imageBelow: s = CGSize(width: max(i.width, t.width), height: i.height + (t == .zero ? 0 : 4 + t.height))
            default: s = CGSize(width: i.width + (t == .zero ? 0 : 4 + t.width), height: max(i.height, t.height))
            }
            s.width += ins.leading + ins.trailing
            s.height += ins.top + ins.bottom
            if imagePosition == .imageOnly, !isBordered { s = CGSize(width: i.width + 6, height: max(i.height + 4, controlSize.height - 2)) }
        } else {
            s = measured(native)
        }
        if nativeKind == .button || nativeKind == .toggle(.button) {
            if isBordered, bezelStyle == .rounded { s.height = max(s.height, controlSize.height) }
            if bezelStyle == .rounded, !title.isEmpty, imagePosition != .imageOnly { s.width = max(s.width, title.count <= 2 ? 32 : 0) }
        }
        return CGSize(width: s.width.rounded(.up), height: s.height.rounded(.up))
    }
}

extension NSControl {
    public enum ImagePosition: UInt, Sendable {
        case noImage = 0, imageOnly, imageLeft, imageRight, imageBelow, imageAbove, imageOverlaps, imageLeading, imageTrailing
    }
}

extension NSImage {
    /// Symbol sizing; Runway reads the point size.
    public final class SymbolConfiguration: @unchecked Sendable {
        public let pointSize: CGFloat?
        public enum Scale: Int, Sendable { case small = 1, medium, large }
        public init(pointSize: CGFloat, weight: NSFont.Weight) { self.pointSize = pointSize }
        public init(pointSize: CGFloat, weight: NSFont.Weight, scale: Scale) { self.pointSize = pointSize }
        public init(scale: Scale) { pointSize = scale == .small ? 11 : scale == .large ? 16 : 13 }
        public init(textStyle: NSFont.TextStyle) { pointSize = nil }
        public init(textStyle: NSFont.TextStyle, scale: Scale) { pointSize = nil }
        public init(hierarchicalColor: NSColor) { pointSize = nil }
        public init(paletteColors: [NSColor]) { pointSize = nil }
        public static func preferringMulticolor() -> SymbolConfiguration { SymbolConfiguration(scale: .medium) }
        public func applying(_ other: SymbolConfiguration) -> SymbolConfiguration { other.pointSize == nil ? self : other }
    }
}

/// An on/off switch (GtkSwitch).
@preconcurrency @MainActor
open class NSSwitch: NSControl {
    open var state: NSControl.StateValue = .off { didSet { if state != oldValue { controlStateChanged() } } }
    private let native: NativeWidget

    public override init(frame frameRect: CGRect) {
        native = makeNative(.toggle(.switch))
        super.init(frame: frameRect)
        onMain { controlStateChanged() }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        native = makeNative(.toggle(.switch))
        super.init(coder: coder)
        onMain { controlStateChanged() }
        IBDecoding.leave(self, coder)
    }

    open override var objectValue: Any? {
        get { state.rawValue }
        set { state = ((newValue as? Int) ?? (newValue as? NSNumber)?.intValue ?? 0) != 0 ? .on : .off }
    }
    open override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        state = state == .on ? .off : .on
        fireAction()
    }

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        var p = WidgetProps()
        p.isOn = state == .on
        p.enabled = isEnabled
        p.controlSize = controlSize.value
        p.tooltip = toolTip
        var e = WidgetEvents()
        e.onToggle = { [weak self] on in
            guard let self, self.isEnabled else { return }
            self.state = on ? .on : .off
            self.fireAction()
        }
        Runway.backend.update(native, props: p, events: e)
    }

    override func place() {
        placementDirty = false; placeChildren(below: [(native, bounds)]) }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }
    open override var intrinsicContentSize: CGSize {
        switch controlSize {
        case .mini: CGSize(width: 26, height: 15)
        case .small: CGSize(width: 32, height: 18)
        default: CGSize(width: 38, height: 22)
        }
    }
}
