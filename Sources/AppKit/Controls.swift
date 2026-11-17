// The rest of AppKit's standard controls: NSPopUpButton (GtkDropDown, or a
// menu button when it pulls down), NSSegmentedControl (linked toggle
// buttons, drawn when segments carry images or select several), NSSlider,
// NSStepper, NSProgressIndicator, NSLevelIndicator (drawn), NSColorWell,
// NSDatePicker, NSImageView and NSBox.

import Foundation
import CoreGraphics
import RunwayCore

// MARK: Pop-up button

// NSRectEdge is Foundation's (NSGeometry).

@preconcurrency @MainActor
open class NSPopUpButton: NSButton {
    public static let willPopUpNotification = Notification.Name("NSPopUpButtonWillPopUpNotification")
    open override var menu: NSMenu? { didSet { sync() } }
    open var pullsDown = false { didSet { if pullsDown != oldValue { remake(); sync() } } }
    open var autoenablesItems = true
    open var preferredEdge: NSRectEdge = .maxY
    open var usesItemFromMenu = true
    open var altersStateOfSelectedItem = true
    open private(set) var indexOfSelectedItem = -1
    private var popup: NativeWidget
    /// The native pop-up (tests).
    var popupWidget: NativeWidget { popup }

    public override init(frame frameRect: CGRect) {
        popup = makeNative(.dropdown)
        super.init(frame: frameRect)
        onMain {
            menu = NSMenu(title: "")
            Runway.backend.destroy(native)
            sync()
        }
    }
    public convenience init(frame: CGRect, pullsDown: Bool) {
        self.init(frame: frame)
        self.pullsDown = pullsDown
        if pullsDown { remake(); sync() }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        popup = makeNative(.dropdown)
        super.init(coder: coder)
        onMain {
            menu = NSMenu(title: "")
            Runway.backend.destroy(native)
            sync()
        }
        IBDecoding.leave(self, coder)
    }

    private func remake() {
        Runway.backend.destroy(popup)
        popup = Runway.backend.makeWidget(pullsDown ? .menuButton : .dropdown)
        layoutSubviews()
    }

    // MARK: Items

    open var itemArray: [NSMenuItem] { menu?.items ?? [] }
    open var numberOfItems: Int { itemArray.count }
    open var itemTitles: [String] { itemArray.map(\.title) }
    open var lastItem: NSMenuItem? { itemArray.last }
    open var selectedItem: NSMenuItem? { item(at: indexOfSelectedItem) }
    open var titleOfSelectedItem: String? { selectedItem?.title }
    /// The selected item's tag (a method in AppKit).
    open func selectedTag() -> Int { selectedItem?.tag ?? -1 }
    open func item(at i: Int) -> NSMenuItem? { itemArray.indices.contains(i) ? itemArray[i] : nil }
    open func item(withTitle t: String) -> NSMenuItem? { itemArray.first { $0.title == t } }
    open func itemTitle(at i: Int) -> String { item(at: i)?.title ?? "" }
    open func indexOfItem(withTitle t: String) -> Int { itemArray.firstIndex { $0.title == t } ?? -1 }
    open func indexOfItem(withTag t: Int) -> Int { itemArray.firstIndex { $0.tag == t } ?? -1 }
    open func indexOfItem(withRepresentedObject o: Any?) -> Int {
        itemArray.firstIndex { i in
            if let a = i.representedObject as? AnyHashable, let b = o as? AnyHashable { return a == b }
            return false
        } ?? -1
    }
    open func index(of item: NSMenuItem) -> Int { itemArray.firstIndex { $0 === item } ?? -1 }

    open func addItem(withTitle t: String) { menu?.addItem(withTitle: t, action: nil, keyEquivalent: ""); itemsChanged() }
    open func addItems(withTitles ts: [String]) { for t in ts { menu?.addItem(withTitle: t, action: nil, keyEquivalent: "") }; itemsChanged() }
    open func insertItem(withTitle t: String, at i: Int) { menu?.insertItem(NSMenuItem(title: t, action: nil, keyEquivalent: ""), at: i); itemsChanged() }
    open func removeItem(withTitle t: String) { if let i = item(withTitle: t) { menu?.removeItem(i) }; itemsChanged() }
    open func removeItem(at i: Int) { menu?.removeItem(at: i); itemsChanged() }
    open func removeAllItems() { menu?.removeAllItems(); itemsChanged() }

    private func itemsChanged() {
        if indexOfSelectedItem >= numberOfItems { indexOfSelectedItem = numberOfItems - 1 }
        if indexOfSelectedItem < 0, numberOfItems > 0, !pullsDown { indexOfSelectedItem = 0 }
        sync()
        invalidateIntrinsicContentSize()
    }

    open func selectItem(at i: Int) {
        indexOfSelectedItem = i >= 0 && i < numberOfItems ? i : -1
        if altersStateOfSelectedItem, !pullsDown {
            for (n, it) in itemArray.enumerated() { it.state = n == indexOfSelectedItem ? .on : .off }
        }
        sync()
    }
    open func selectItem(withTitle t: String) { selectItem(at: indexOfItem(withTitle: t)) }
    @discardableResult open func selectItem(withTag t: Int) -> Bool { let i = indexOfItem(withTag: t); selectItem(at: i); return i >= 0 }
    open func selectItem(_ item: NSMenuItem?) { selectItem(at: item.map { index(of: $0) } ?? -1) }
    open func setTitle(_ t: String) {
        if pullsDown { title = t; sync() } else if indexOfItem(withTitle: t) >= 0 { selectItem(withTitle: t) } else { addItem(withTitle: t); selectItem(withTitle: t) }
    }
    open func synchronizeTitleAndSelectedItem() { sync() }

    open override var doubleValue: Double {
        get { (objectValue as? Double) ?? (objectValue as? Int).map(Double.init) ?? 0 }
        set { objectValue = newValue }
    }
    open override var objectValue: Any? {
        get { indexOfSelectedItem }
        set { selectItem(at: (newValue as? Int) ?? (newValue as? NSNumber)?.intValue ?? -1) }
    }
    open override var stringValue: String {
        get { titleOfSelectedItem ?? "" }
        set { selectItem(withTitle: newValue) }
    }

    // MARK: Native

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() { sync() }

    private func chose(_ i: Int) {
        guard isEnabled, let it = item(at: i) else { return }
        if !pullsDown { selectItem(at: i) }
        if it.handler != nil || it.action != nil { it.perform() }
        if !pullsDown || it.action == nil { fireAction() }
    }

    private func sync() {
        guard menu != nil else { return }
        var p = WidgetProps()
        p.enabled = isEnabled
        p.tooltip = toolTip
        p.controlSize = controlSize.value
        p.bordered = isBordered
        var e = WidgetEvents()
        if pullsDown {
            p.title = usesItemFromMenu ? (itemArray.first?.title ?? title) : title
            if let img = image, p.title.isEmpty { p.image = img.imageSource }
            e.menu = itemArray.dropFirst().enumerated().map { n, it in
                if it.isSeparatorItem { return .separator }
                return MenuItemSpec(title: it.title, enabled: it.isEnabled, checked: it.state == .on,
                                    children: it.submenu?.specs() ?? []) { [weak self] in self?.chose(n + 1) }
            }
        } else {
            // GtkDropDown lists titles; separators show as blank rows.
            p.options = itemArray.map { $0.isSeparatorItem ? "" : $0.title }
            p.selected = indexOfSelectedItem
            e.onSelect = { [weak self] i in self?.chose(i) }
        }
        Runway.backend.update(popup, props: p, events: e)
        layoutSubviews()
    }

    override func place() {
        placementDirty = false
        let h = min(bounds.height, controlSize.height)
        placeChildren(below: [(popup, CGRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h))])
    }
    open override var intrinsicContentSize: CGSize {
        let s = measured(popup)
        return CGSize(width: s.width.rounded(.up), height: controlSize.height)
    }
}

// MARK: Segmented control

@preconcurrency @MainActor
open class NSSegmentedControl: NSControl {
    // AppKit's event dispatch (when the backend reports raw input).
    open override func mouseDown(with e: NSEvent) { if !drawnPointer(PointerEvent(e, in: self, kind: .down)) { super.mouseDown(with: e) } }
    open override func mouseDragged(with e: NSEvent) { _ = drawnPointer(PointerEvent(e, in: self, kind: .dragged)) }
    open override func mouseUp(with e: NSEvent) { _ = drawnPointer(PointerEvent(e, in: self, kind: .up)) }
    open override func mouseMoved(with e: NSEvent) { _ = drawnPointer(PointerEvent(e, in: self, kind: .moved)) }
    open override func rightMouseDown(with e: NSEvent) { if !drawnPointer(PointerEvent(e, in: self, kind: .down)) { super.rightMouseDown(with: e) } }

    public enum SwitchTracking: UInt, Sendable { case selectOne = 0, selectAny, momentary, momentaryAccelerator }
    public enum Style: Int, Sendable { case automatic = 0, rounded, texturedRounded, roundRect, texturedSquare, capsule, smallSquare, separated }
    public enum Distribution: Int, Sendable { case fit = 0, fill, fillEqually, fillProportionally }

    private struct Segment {
        var label = ""
        var image: NSImage?
        var width: CGFloat = 0
        var selected = false
        var enabled = true
        var tag = 0
        var toolTip: String?
        var menu: NSMenu?
    }
    private var segments: [Segment] = []
    open var trackingMode: SwitchTracking = .selectOne { didSet { rebuild() } }
    open var segmentStyle: Style = .automatic { didSet { controlStateChanged() } }
    open var segmentDistribution: Distribution = .fit { didSet { controlStateChanged() } }
    open var selectedSegmentBezelColor: NSColor? { didSet { controlStateChanged() } }
    open var isSpringLoaded = false
    open var showsMenuIndicator = false
    private var native: NativeWidget?
    private var drawn: (events: NativeWidget, backdrop: DrawnLayer)?
    private var labels: [LabelWidget] = []
    private var images: [NativeWidget] = []
    private var pressed = -1

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain { rebuild() }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        onMain { rebuild() }
        IBDecoding.leave(self, coder)
    }

    public convenience init(labels: [String], trackingMode: SwitchTracking, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        segmentCount = labels.count
        for (i, l) in labels.enumerated() { setLabel(l, forSegment: i) }
        self.trackingMode = trackingMode
        self.target = target
        self.action = action
        rebuild()
        sizeToFit()
    }
    public convenience init(images: [NSImage], trackingMode: SwitchTracking, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        segmentCount = images.count
        for (i, img) in images.enumerated() { setImage(img, forSegment: i) }
        self.trackingMode = trackingMode
        self.target = target
        self.action = action
        rebuild()
        sizeToFit()
    }

    open var segmentCount: Int {
        get { segments.count }
        set {
            if newValue < segments.count { segments.removeLast(segments.count - newValue) }
            while segments.count < newValue { segments.append(Segment()) }
            rebuild()
        }
    }
    open func setLabel(_ l: String, forSegment s: Int) { guard segments.indices.contains(s) else { return }; segments[s].label = l; controlStateChanged(); invalidateIntrinsicContentSize() }
    open func label(forSegment s: Int) -> String? { segments.indices.contains(s) ? segments[s].label : nil }
    open func setImage(_ i: NSImage?, forSegment s: Int) { guard segments.indices.contains(s) else { return }; segments[s].image = i; rebuild() }
    open func image(forSegment s: Int) -> NSImage? { segments.indices.contains(s) ? segments[s].image : nil }
    open func setImageScaling(_ scaling: NSImageScaling, forSegment s: Int) {}
    open func setWidth(_ w: CGFloat, forSegment s: Int) { guard segments.indices.contains(s) else { return }; segments[s].width = w; invalidateIntrinsicContentSize(); controlStateChanged() }
    open func width(forSegment s: Int) -> CGFloat { segments.indices.contains(s) ? segments[s].width : 0 }
    open func setEnabled(_ e: Bool, forSegment s: Int) { guard segments.indices.contains(s) else { return }; segments[s].enabled = e; controlStateChanged() }
    open func isEnabled(forSegment s: Int) -> Bool { segments.indices.contains(s) && segments[s].enabled }
    open func setTag(_ t: Int, forSegment s: Int) { if segments.indices.contains(s) { segments[s].tag = t } }
    open func tag(forSegment s: Int) -> Int { segments.indices.contains(s) ? segments[s].tag : 0 }
    open func setToolTip(_ t: String?, forSegment s: Int) { if segments.indices.contains(s) { segments[s].toolTip = t } }
    open func toolTip(forSegment s: Int) -> String? { segments.indices.contains(s) ? segments[s].toolTip : nil }
    open func setMenu(_ m: NSMenu?, forSegment s: Int) { if segments.indices.contains(s) { segments[s].menu = m } }
    open func menu(forSegment s: Int) -> NSMenu? { segments.indices.contains(s) ? segments[s].menu : nil }
    open func setShowsMenuIndicator(_ show: Bool, forSegment s: Int) {}
    open func setAlignment(_ a: NSTextAlignment, forSegment s: Int) {}

    open func setSelected(_ on: Bool, forSegment s: Int) {
        guard segments.indices.contains(s) else { return }
        if on, trackingMode == .selectOne { for i in segments.indices { segments[i].selected = false } }
        segments[s].selected = on
        controlStateChanged()
    }
    open func isSelected(forSegment s: Int) -> Bool { segments.indices.contains(s) && segments[s].selected }
    open var selectedSegment: Int {
        get { segments.lastIndex { $0.selected } ?? -1 }
        set {
            if trackingMode != .selectAny { for i in segments.indices { segments[i].selected = false } }
            if segments.indices.contains(newValue) { segments[newValue].selected = true }
            controlStateChanged()
        }
    }
    open var indexOfSelectedItem: Int { selectedSegment }
    @discardableResult open func selectSegment(withTag t: Int) -> Bool {
        guard let i = segments.firstIndex(where: { $0.tag == t }) else { return false }
        selectedSegment = i
        return true
    }
    open override var objectValue: Any? {
        get { selectedSegment }
        set { selectedSegment = (newValue as? Int) ?? -1 }
    }
    open var selectedSegmentTag: Int { selectedSegment >= 0 ? segments[selectedSegment].tag : -1 }

    /// The user picked segment `i`.
    private func picked(_ i: Int) {
        guard isEnabled, segments.indices.contains(i), segments[i].enabled else { controlStateChanged(); return }
        switch trackingMode {
        case .selectOne: selectedSegment = i
        case .selectAny: segments[i].selected.toggle()
        case .momentary, .momentaryAccelerator: for n in segments.indices { segments[n].selected = n == i }
        }
        controlStateChanged()
        fireAction()
        if trackingMode == .momentary || trackingMode == .momentaryAccelerator {
            // Momentary segments report the click, then release.
            lastClicked = i
            for n in segments.indices { segments[n].selected = false }
            controlStateChanged()
        }
    }
    private var lastClicked = -1

    private var wantsDrawn: Bool { trackingMode == .selectAny || segments.contains { $0.image != nil } || Runway.appKit == nil && false }

    private func rebuild() {
        if wantsDrawn {
            if let n = native { Runway.backend.destroy(n); native = nil }
            if drawn == nil {
                let ev = makeEventWidget(focusable: false, pointer: { [weak self] e in self?.pointer(e) ?? false })
                drawn = (ev, DrawnLayer())
            }
        } else {
            drawn = nil
            labels = []
            images = []
            if native == nil { native = Runway.backend.makeWidget(.segmented) }
        }
        controlStateChanged()
        invalidateIntrinsicContentSize()
    }

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        if let native {
            var p = WidgetProps()
            p.options = segments.map(\.label)
            p.selected = trackingMode == .selectOne || trackingMode == .momentary ? selectedSegment : -1
            p.enabled = isEnabled
            p.controlSize = controlSize.value
            p.tint = selectedSegmentBezelColor?.rgbaValue
            var e = WidgetEvents()
            e.onSelect = { [weak self] i in self?.picked(i) }
            Runway.backend.update(native, props: p, events: e)
        }
        if drawn != nil { drawSegments() }
        layoutSubviews()
    }

    // MARK: Drawn segments

    private func segmentRects() -> [CGRect] {
        guard !segments.isEmpty else { return [] }
        let natural = segments.map { naturalWidth($0) }
        let total = natural.reduce(0, +)
        let extra = max(0, bounds.width - total)
        var x: CGFloat = 0
        return segments.indices.map { i in
            var w = natural[i]
            if segmentDistribution != .fit || bounds.width > total {
                w = segmentDistribution == .fillEqually || segments[i].width == 0 && extra > 0 && segmentDistribution != .fit
                    ? bounds.width / CGFloat(segments.count) : w + extra / CGFloat(segments.count)
            }
            defer { x += w }
            return CGRect(x: x.rounded(), y: 0, width: w.rounded(), height: bounds.height)
        }
    }

    private func naturalWidth(_ s: Segment) -> CGFloat {
        if s.width > 0 { return s.width }
        var w: CGFloat = 0
        if s.image != nil { w += 16 }
        if !s.label.isEmpty {
            let l = LabelWidget()
            l.set(s.label, font: NSFont(spec: fontSpec))
            w += l.size().width + (s.image != nil ? 4 : 0)
        }
        return max(w + 18, 28)
    }

    private func drawSegments() {
        guard let drawn else { return }
        let rects = segmentRects()
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let dark = NSAppearance.current.isDark
        var cmds: [DrawCommand] = []
        let textured = segmentStyle == .texturedRounded || segmentStyle == .separated
        if !textured { cmds.append(.fill(.roundedRect(r, radius: 6), .color(RGBA(0, 0, 0, dark ? 0.25 : 0.06)))) }
        let accent = (selectedSegmentBezelColor ?? .controlAccentColor).rgbaValue
        for (i, s) in segments.enumerated() where i < rects.count {
            let sr = rects[i].insetBy(dx: textured ? 1 : 2, dy: 2)
            if s.selected || pressed == i {
                let fill: RGBA = trackingMode == .selectAny && s.selected && !textured ? accent : (dark ? RGBA(1, 1, 1, 0.22) : .white)
                cmds.append(.fill(.roundedRect(sr.offsetBy(dx: 0, dy: 0.5), radius: 4.5), .color(RGBA(0, 0, 0, 0.12))))
                cmds.append(.fill(.roundedRect(sr, radius: 4.5), .color(pressed == i && !s.selected ? RGBA(0, 0, 0, 0.08) : fill)))
            }
            if i > 0, !s.selected, !segments[i - 1].selected, !textured {
                cmds.append(.fill(.rect(CGRect(x: rects[i].minX - 0.5, y: 6, width: 1, height: max(0, bounds.height - 12))), .color(NSColor.separatorColor.rgbaValue)))
            }
        }
        drawn.backdrop.draw(cmds)
        while labels.count < segments.count { labels.append(LabelWidget()) }
        while images.count < segments.count { images.append(Runway.backend.makeWidget(.image)) }
        var placed: [(NativeWidget, CGRect)] = [(drawn.backdrop.widget, bounds)]
        for (i, s) in segments.enumerated() where i < rects.count {
            let sr = rects[i]
            let white = trackingMode == .selectAny && s.selected && !textured
            let color: NSColor = !(isEnabled && s.enabled) ? .disabledControlTextColor : white ? .white : .controlTextColor
            var contentW: CGFloat = 0
            var ts = CGSize.zero
            if !s.label.isEmpty {
                labels[i].set(s.label, font: NSFont(spec: fontSpec), color: color)
                ts = labels[i].size()
                contentW += ts.width
            }
            let isz: CGFloat = s.image != nil ? 16 : 0
            if s.image != nil { contentW += isz + (s.label.isEmpty ? 0 : 4) }
            var x = (sr.midX - contentW / 2).rounded()
            if let img = s.image {
                var p = WidgetProps()
                p.image = img.imageSource
                p.imagePointSize = 13
                p.imageTint = color.rgbaValue
                Runway.backend.update(images[i], props: p, events: WidgetEvents())
                placed.append((images[i], CGRect(x: x, y: ((bounds.height - isz) / 2).rounded(), width: isz, height: isz)))
                x += isz + 4
            }
            if !s.label.isEmpty { placed.append((labels[i].widget, CGRect(x: x, y: ((bounds.height - ts.height) / 2).rounded(), width: ts.width, height: ts.height))) }
        }
        Runway.backend.setChildren(drawn.events, placed, contentSize: bounds.size)
    }

    private func drawnPointer(_ e: PointerEvent) -> Bool { drawn == nil ? false : pointer(e) }
    private func pointer(_ e: PointerEvent) -> Bool {
        let i = segmentRects().firstIndex { $0.contains(CGPoint(x: e.location.x, y: min(e.location.y, bounds.height - 1))) } ?? -1
        switch e.kind {
        case .down: pressed = i; drawSegments()
        case .up:
            let p = pressed
            pressed = -1
            if p == i, i >= 0 { picked(i) } else { drawSegments() }
        default: return false
        }
        return true
    }

    override func place() {
        placementDirty = false
        if let native { placeChildren(below: [(native, bounds)]) }
        else if let drawn { placeChildren(below: [(drawn.events, bounds)]) }
    }
    open override func frameSizeChanged(from old: CGSize) {
        super.frameSizeChanged(from: old)
        if drawn != nil { drawSegments() }
        layoutSubviews()
    }
    open override var intrinsicContentSize: CGSize {
        if let native {
            var s = measured(native)
            let fixed = segments.map(\.width).reduce(0, +)
            if fixed > 0, segments.allSatisfy({ $0.width > 0 }) { s.width = fixed }
            return CGSize(width: s.width.rounded(.up), height: max(controlSize.height, s.height.rounded(.up)))
        }
        return CGSize(width: segments.map { naturalWidth($0) }.reduce(0, +).rounded(.up), height: controlSize.height)
    }
}

// MARK: Slider and stepper

@preconcurrency @MainActor
open class NSSlider: NSControl {
    public enum SliderType: UInt, Sendable { case linear = 0, circular = 1 }
    public enum TickMarkPosition: UInt, Sendable { case below = 0, above = 1 }
    open var minValue: Double = 0 { didSet { controlStateChanged() } }
    open var maxValue: Double = 1 { didSet { controlStateChanged() } }
    open var altIncrementValue: Double = 0
    open var numberOfTickMarks = 0 { didSet { controlStateChanged() } }
    open var allowsTickMarkValuesOnly = false { didSet { controlStateChanged() } }
    open var tickMarkPosition: TickMarkPosition = .below
    open var sliderType: SliderType = .linear
    open var isVertical = false
    open var trackFillColor: NSColor? { didSet { controlStateChanged() } }
    let native: NativeWidget
    private var value: Double = 0

    public override init(frame frameRect: CGRect) {
        native = makeNative(.slider)
        super.init(frame: frameRect)
        onMain {
            isContinuous = true
            controlStateChanged()
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        native = makeNative(.slider)
        super.init(coder: coder)
        onMain {
            isContinuous = true
            controlStateChanged()
        }
        IBDecoding.leave(self, coder)
    }
    public convenience init(value: Double, minValue: Double, maxValue: Double, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        doubleValue = value
        self.target = target
        self.action = action
        controlStateChanged()
        sizeToFit()
    }
    public convenience init(target: AnyObject?, action: Selector?) { self.init(value: 0, minValue: 0, maxValue: 1, target: target, action: action) }

    open override var doubleValue: Double {
        get { (objectValue as? Double) ?? (objectValue as? Int).map(Double.init) ?? 0 }
        set { objectValue = newValue }
    }
    open override var objectValue: Any? {
        get { value }
        set {
            let d = (newValue as? Double) ?? (newValue as? NSNumber)?.doubleValue ?? (newValue as? Int).map(Double.init) ?? 0
            value = max(minValue, min(maxValue, d))
            controlStateChanged()
        }
    }
    open func tickMarkValue(at i: Int) -> Double {
        guard numberOfTickMarks > 1 else { return minValue }
        return minValue + (maxValue - minValue) * Double(i) / Double(numberOfTickMarks - 1)
    }
    open func closestTickMarkValue(toValue v: Double) -> Double {
        guard numberOfTickMarks > 1 else { return v }
        let step = (maxValue - minValue) / Double(numberOfTickMarks - 1)
        return minValue + ((v - minValue) / step).rounded() * step
    }

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        var p = WidgetProps()
        p.number = value
        p.range = minValue...max(maxValue, minValue)
        p.step = allowsTickMarkValuesOnly && numberOfTickMarks > 1 ? (maxValue - minValue) / Double(numberOfTickMarks - 1) : nil
        p.enabled = isEnabled
        p.controlSize = controlSize.value
        p.tint = trackFillColor?.rgbaValue
        var e = WidgetEvents()
        e.onNumber = { [weak self] v in
            guard let self, self.isEnabled else { return }
            let nv = self.allowsTickMarkValuesOnly ? self.closestTickMarkValue(toValue: v) : v
            guard nv != self.value else { return }
            self.value = nv
            self.fireAction()
        }
        Runway.backend.update(native, props: p, events: e)
    }
    override func place() {
        placementDirty = false; placeChildren(below: [(native, bounds)]) }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }
    open override var intrinsicContentSize: CGSize { CGSize(width: -1, height: controlSize == .small ? 15 : 21) }
}

@preconcurrency @MainActor
open class NSStepper: NSControl {
    open var minValue: Double = 0 { didSet { controlStateChanged() } }
    open var maxValue: Double = 59 { didSet { controlStateChanged() } }
    open var increment: Double = 1 { didSet { controlStateChanged() } }
    open var valueWraps = true
    open var autorepeat = true
    let native: NativeWidget
    private var value: Double = 0

    public override init(frame frameRect: CGRect) {
        native = makeNative(.stepper)
        super.init(frame: frameRect)
        onMain { controlStateChanged() }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        native = makeNative(.stepper)
        super.init(coder: coder)
        onMain { controlStateChanged() }
        IBDecoding.leave(self, coder)
    }

    open override var doubleValue: Double {
        get { (objectValue as? Double) ?? (objectValue as? Int).map(Double.init) ?? 0 }
        set { objectValue = newValue }
    }
    open override var objectValue: Any? {
        get { value }
        set {
            let d = (newValue as? Double) ?? (newValue as? NSNumber)?.doubleValue ?? (newValue as? Int).map(Double.init) ?? 0
            value = max(minValue, min(maxValue, d))
            controlStateChanged()
        }
    }
    /// One step up or down, wrapping if `valueWraps`.
    open func step(up: Bool) {
        var v = value + (up ? increment : -increment)
        if v > maxValue { v = valueWraps ? minValue : maxValue }
        if v < minValue { v = valueWraps ? maxValue : minValue }
        guard v != value else { return }
        value = v
        controlStateChanged()
        fireAction()
    }

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        var p = WidgetProps()
        p.number = value
        p.range = minValue...max(maxValue, minValue)
        p.step = increment
        p.enabled = isEnabled
        p.controlSize = controlSize.value
        var e = WidgetEvents()
        e.onNumber = { [weak self] v in
            guard let self, self.isEnabled, v != self.value else { return }
            self.value = max(self.minValue, min(self.maxValue, v))
            self.fireAction()
        }
        Runway.backend.update(native, props: p, events: e)
    }
    override func place() {
        placementDirty = false; placeChildren(below: [(native, bounds)]) }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }
    open override var intrinsicContentSize: CGSize {
        let s = measured(native)
        return CGSize(width: s.width.rounded(.up), height: max(controlSize.height, s.height.rounded(.up)))
    }
}

// MARK: Progress and level indicators

@preconcurrency @MainActor
open class NSProgressIndicator: NSView {
    public enum Style: UInt, Sendable { case bar = 0, spinning = 1 }
    public enum ThicknessValue: UInt, Sendable { case small = 10, regular = 14, aqua = 12, large = 18 }
    open var style: Style = .bar { didSet { if style != oldValue { remake() } } }
    open var isIndeterminate = true { didSet { update() } }
    open var doubleValue: Double = 0 { didSet { update() } }
    open var minValue: Double = 0 { didSet { update() } }
    open var maxValue: Double = 100 { didSet { update() } }
    open var isDisplayedWhenStopped = true { didSet { update() } }
    open var usesThreadedAnimation = false
    open var isBezeled = true
    open var controlSize: NSControl.ControlSize = .regular { didSet { update() } }
    open var controlTint: Int = 0
    open var observedProgress: Progress?
    open private(set) var isAnimating = false
    var native: NativeWidget

    public override init(frame frameRect: CGRect) {
        native = makeNative(.progress(circular: false))
        super.init(frame: frameRect)
        onMain { update() }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        native = makeNative(.progress(circular: false))
        super.init(coder: coder)
        onMain { update() }
        IBDecoding.leave(self, coder)
    }

    private func remake() {
        Runway.backend.destroy(native)
        native = Runway.backend.makeWidget(.progress(circular: style == .spinning))
        update()
    }

    open func startAnimation(_ sender: Any?) {
        guard !isAnimating else { return }
        isAnimating = true
        update()
        pulse()
    }
    open func stopAnimation(_ sender: Any?) { isAnimating = false; update() }
    open func increment(by delta: Double) { doubleValue += delta }
    open func sizeToFit() { setFrameSize(intrinsicContentSize) }

    /// Indeterminate bars move only while animating (no timer otherwise).
    private func pulse() {
        guard isAnimating, style == .bar, isIndeterminate else { return }
        update()
        Runway.appKit?.after(0.1) { [weak self] in self?.pulse() }
    }

    private func update() {
        var p = WidgetProps()
        p.indeterminate = isIndeterminate && isAnimating
        p.number = maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
        p.controlSize = controlSize.value
        Runway.backend.update(native, props: p, events: WidgetEvents())
        layoutSubviews()
    }

    private var shown: Bool { style == .bar ? (isDisplayedWhenStopped || isAnimating) : (isAnimating || isDisplayedWhenStopped && !isIndeterminate) }

    override func place() {
        placementDirty = false
        if !shown { placeChildren(below: []); return }
        if style == .spinning {
            let s = min(bounds.width, bounds.height)
            placeChildren(below: [(native, CGRect(x: ((bounds.width - s) / 2).rounded(), y: ((bounds.height - s) / 2).rounded(), width: s, height: s))])
        } else {
            let h: CGFloat = controlSize == .small ? 4 : 6
            placeChildren(below: [(native, CGRect(x: 0, y: ((bounds.height - h) / 2).rounded(), width: bounds.width, height: h))])
        }
    }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }
    open override var intrinsicContentSize: CGSize {
        if style == .spinning {
            let s: CGFloat = controlSize == .small ? 16 : controlSize == .mini ? 10 : controlSize == .large ? 48 : 32
            return CGSize(width: s, height: s)
        }
        return CGSize(width: -1, height: controlSize == .small ? 12 : 20)
    }
}

@preconcurrency @MainActor
open class NSLevelIndicator: NSControl {
    // AppKit's event dispatch (when the backend reports raw input).
    open override func mouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.mouseDown(with: e) } }
    open override func mouseDragged(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .dragged)) }
    open override func mouseUp(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .up)) }
    open override func mouseMoved(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .moved)) }
    open override func rightMouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.rightMouseDown(with: e) } }

    public enum Style: UInt, Sendable { case relevancy = 0, continuousCapacity, discreteCapacity, rating }
    public enum PlaceholderVisibility: Int, Sendable { case automatic = 0, always, whileEditing }
    open var levelIndicatorStyle: Style = .continuousCapacity { didSet { draw() } }
    open var minValue: Double = 0 { didSet { draw() } }
    open var maxValue: Double = 2 { didSet { draw() } }
    open var warningValue: Double = 0 { didSet { draw() } }
    open var criticalValue: Double = 0 { didSet { draw() } }
    open var fillColor: NSColor? { didSet { draw() } }
    open var warningFillColor: NSColor? { didSet { draw() } }
    open var criticalFillColor: NSColor? { didSet { draw() } }
    open var isEditable = false
    open var drawsTieredCapacityLevels = false
    open var tickMarkPosition: NSSlider.TickMarkPosition = .below
    open var numberOfTickMarks = 0
    open var numberOfMajorTickMarks = 0
    open var ratingImage: NSImage?
    open var ratingPlaceholderImage: NSImage?
    open var placeholderVisibility: PlaceholderVisibility = .automatic
    private var value: Double = 0
    private var events: NativeWidget!
    private let backdrop = DrawnLayer()

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain {
            events = makeEventWidget(focusable: false, pointer: { [weak self] e in self?.pointer(e) ?? false })
            draw()
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        onMain {
            events = makeEventWidget(focusable: false, pointer: { [weak self] e in self?.pointer(e) ?? false })
            draw()
        }
        IBDecoding.leave(self, coder)
    }

    open override var doubleValue: Double {
        get { (objectValue as? Double) ?? (objectValue as? Int).map(Double.init) ?? 0 }
        set { objectValue = newValue }
    }
    open override var objectValue: Any? {
        get { value }
        set {
            value = (newValue as? Double) ?? (newValue as? NSNumber)?.doubleValue ?? (newValue as? Int).map(Double.init) ?? 0
            draw()
        }
    }
    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() { draw() }

    private var fraction: Double { maxValue > minValue ? max(0, min(1, (value - minValue) / (maxValue - minValue))) : 0 }

    private func levelColor(_ v: Double) -> RGBA {
        let warnFirst = criticalValue >= warningValue
        let critical = criticalValue != warningValue && (warnFirst ? v >= criticalValue : v <= criticalValue)
        let warning = warningValue != 0 && (warnFirst ? v >= warningValue : v <= warningValue)
        if critical, criticalValue != 0 { return (criticalFillColor ?? .systemRed).rgbaValue }
        if warning { return (warningFillColor ?? .systemYellow).rgbaValue }
        return (fillColor ?? .systemGreen).rgbaValue
    }

    private func draw() {
        guard events != nil else { return }
        let b = bounds
        var cmds: [DrawCommand] = []
        let dark = NSAppearance.current.isDark
        let track = RGBA(0, 0, 0, dark ? 0.3 : 0.08), border = RGBA(0, 0, 0, dark ? 0.4 : 0.15)
        switch levelIndicatorStyle {
        case .continuousCapacity:
            let r = CGRect(x: 0.5, y: max(0.5, (b.height - 16) / 2), width: max(0, b.width - 1), height: min(16, b.height - 1))
            cmds.append(.fill(.roundedRect(r, radius: 3), .color(track)))
            let w = r.width * fraction
            if w > 0 { cmds.append(.fill(.roundedRect(CGRect(x: r.minX, y: r.minY, width: w, height: r.height), radius: 3), .color(levelColor(value)))) }
            cmds.append(.stroke(.roundedRect(r, radius: 3), .color(border), lineWidth: 1, dash: []))
        case .discreteCapacity:
            let n = max(1, Int(maxValue - minValue))
            let gap: CGFloat = 2
            let h = min(16, b.height - 1)
            let w = (b.width - gap * CGFloat(n - 1)) / CGFloat(n)
            for i in 0..<n {
                let r = CGRect(x: CGFloat(i) * (w + gap), y: ((b.height - h) / 2).rounded(), width: w, height: h)
                let on = minValue + Double(i) < value
                cmds.append(.fill(.roundedRect(r, radius: 2), .color(on ? levelColor(minValue + Double(i + 1)) : track)))
                cmds.append(.stroke(.roundedRect(r.insetBy(dx: 0.5, dy: 0.5), radius: 2), .color(border), lineWidth: 1, dash: []))
            }
        case .relevancy:
            let n = max(1, Int(b.width / 3))
            let on = Int((Double(n) * fraction).rounded())
            for i in 0..<min(on, n) {
                cmds.append(.fill(.rect(CGRect(x: CGFloat(i) * 3, y: (b.height - 10) / 2, width: 2, height: 10)), .color(NSColor.secondaryLabelColor.rgbaValue)))
            }
        case .rating:
            let n = max(1, Int(maxValue - minValue))
            let s = min(b.height, 13)
            for i in 0..<n {
                let filled = minValue + Double(i) < value
                let c = CGPoint(x: CGFloat(i) * (s + 2) + s / 2, y: b.height / 2)
                if filled || placeholderVisibility == .always || isEditable {
                    cmds.append(.fill(.path(Self.star(center: c, radius: s / 2)), .color(filled ? NSColor.labelColor.rgbaValue : NSColor.tertiaryLabelColor.rgbaValue)))
                } else {
                    cmds.append(.fill(.ellipse(CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3)), .color(NSColor.tertiaryLabelColor.rgbaValue)))
                }
            }
        }
        backdrop.draw(cmds)
        Runway.backend.setChildren(events, [(backdrop.widget, b)], contentSize: b.size)
        placeChildren(below: [(events, b)])
    }

    static func star(center c: CGPoint, radius r: CGFloat) -> [PathElement] {
        var els: [PathElement] = []
        for i in 0..<10 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let rr = i % 2 == 0 ? r : r * 0.45
            let p = CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr)
            els.append(i == 0 ? .move(p) : .line(p))
        }
        els.append(.close)
        return els
    }

    private func pointer(_ e: PointerEvent) -> Bool {
        guard isEditable, isEnabled, e.kind == .down || e.kind == .dragged else { return false }
        let n = levelIndicatorStyle == .rating ? 13 + 2.0 : Double(bounds.width) / max(1, maxValue - minValue)
        let v = min(maxValue, max(minValue, minValue + (Double(e.location.x) / n).rounded(.up)))
        if v != value { value = v; draw(); fireAction() }
        return true
    }

    override func place() {
        placementDirty = false; placeChildren(below: [(events, bounds)]) }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); draw() }
    open override var intrinsicContentSize: CGSize {
        levelIndicatorStyle == .rating ? CGSize(width: CGFloat(max(1, Int(maxValue - minValue))) * 15, height: 14) : CGSize(width: -1, height: 18)
    }
}

// MARK: Colour well

@preconcurrency @MainActor
open class NSColorWell: NSControl {
    public enum Style: Int, Sendable { case `default` = 0, minimal, expanded }
    open var color: NSColor = .white { didSet { controlStateChanged() } }
    open var colorWellStyle: Style = .default
    open var supportsAlpha = true
    open var isBordered = true
    open var isActive = false
    let native: NativeWidget

    public override init(frame frameRect: CGRect) {
        native = makeNative(.colorWell)
        super.init(frame: frameRect)
        onMain { controlStateChanged() }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        native = makeNative(.colorWell)
        super.init(coder: coder)
        onMain { controlStateChanged() }
        IBDecoding.leave(self, coder)
    }
    public convenience init(style: Style) { self.init(frame: .zero); colorWellStyle = style }

    open func activate(_ exclusive: Bool) { isActive = true }
    open func deactivate() { isActive = false }
    open override var objectValue: Any? { get { color } set { if let c = newValue as? NSColor { color = c } } }

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        var p = WidgetProps()
        p.color = color.rgbaValue
        p.enabled = isEnabled
        var e = WidgetEvents()
        e.onColor = { [weak self] c in
            guard let self, self.isEnabled else { return }
            self.color = NSColor(rgba: c)
            self.fireAction()
        }
        Runway.backend.update(native, props: p, events: e)
    }
    override func place() {
        placementDirty = false; placeChildren(below: [(native, bounds)]) }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }
    open override var intrinsicContentSize: CGSize { CGSize(width: 44, height: 23) }
}

// MARK: Date picker

@preconcurrency @MainActor public protocol NSDatePickerCellDelegate: AnyObject {}

@preconcurrency @MainActor
open class NSDatePicker: NSControl {
    public enum Style: UInt, Sendable { case textFieldAndStepper = 0, clockAndCalendar, textField }
    public enum Mode: UInt, Sendable { case single = 0, range }
    public struct ElementFlags: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let hourMinute = ElementFlags(rawValue: 0x000c)
        public static let hourMinuteSecond = ElementFlags(rawValue: 0x000e)
        public static let timeZone = ElementFlags(rawValue: 0x0010)
        public static let yearMonth = ElementFlags(rawValue: 0x00c0)
        public static let yearMonthDay = ElementFlags(rawValue: 0x00e0)
        public static let era = ElementFlags(rawValue: 0x0100)
    }
    open var datePickerStyle: Style = .textFieldAndStepper { didSet { controlStateChanged() } }
    open var datePickerMode: Mode = .single
    open var datePickerElements: ElementFlags = [.yearMonthDay, .hourMinuteSecond] { didSet { controlStateChanged() } }
    open var dateValue = Date() { didSet { controlStateChanged() } }
    open var timeInterval: TimeInterval = 0
    open var minDate: Date?
    open var maxDate: Date?
    open var calendar: Calendar?
    open var locale: Locale?
    open var timeZone: TimeZone?
    open var isBezeled = true
    open var isBordered = false
    open var drawsBackground = true
    open var backgroundColor: NSColor = .controlBackgroundColor
    open var textColor: NSColor = .controlTextColor
    open var presentsCalendarOverlay = false
    open weak var delegate: NSDatePickerCellDelegate?
    private let field: NativeWidget
    private let stepper: NativeWidget

    public override init(frame frameRect: CGRect) {
        field = makeNative(.textField(secure: false))
        stepper = makeNative(.stepper)
        super.init(frame: frameRect)
        onMain {
            Runway.appKit?.observeTextField(field, focus: { [weak self] f in if !f { self?.commitText() } }, key: { _ in false })
            controlStateChanged()
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        field = makeNative(.textField(secure: false))
        stepper = makeNative(.stepper)
        super.init(coder: coder)
        onMain {
            Runway.appKit?.observeTextField(field, focus: { [weak self] f in if !f { self?.commitText() } }, key: { _ in false })
            controlStateChanged()
        }
        IBDecoding.leave(self, coder)
    }

    open override var objectValue: Any? { get { dateValue } set { if let d = newValue as? Date { dateValue = d } } }

    var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = locale ?? Locale(identifier: "en_US_POSIX")
        if let tz = timeZone { f.timeZone = tz }
        let hasDate = datePickerElements.contains(.yearMonth)
        let hasTime = datePickerElements.contains(.hourMinute)
        f.dateFormat = [hasDate ? (datePickerElements.contains(.yearMonthDay) ? "d MMM yyyy" : "MMM yyyy") : nil,
                        hasTime ? (datePickerElements.contains(.hourMinuteSecond) ? "HH:mm:ss" : "HH:mm") : nil].compactMap { $0 }.joined(separator: ", ")
        return f
    }
    private var text = ""

    private func clamp(_ d: Date) -> Date {
        var d = d
        if let m = minDate, d < m { d = m }
        if let m = maxDate, d > m { d = m }
        return d
    }

    private func commitText() {
        guard let d = dateFormatter.date(from: text), d != dateValue else { return }
        dateValue = clamp(d)
        fireAction()
    }

    private func step(_ delta: Double) {
        let unit: Calendar.Component = datePickerElements.contains(.yearMonthDay) ? .day : datePickerElements.contains(.yearMonth) ? .month : .minute
        let cal = calendar ?? Calendar(identifier: .gregorian)
        if let d = cal.date(byAdding: unit, value: delta > 0 ? 1 : -1, to: dateValue) {
            dateValue = clamp(d)
            fireAction()
        }
    }
    private var stepBase: Double = 0

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        text = dateFormatter.string(from: dateValue)
        var p = WidgetProps()
        p.string = text
        p.enabled = isEnabled
        p.bordered = isBezeled || isBordered
        p.controlSize = controlSize.value
        var e = WidgetEvents()
        e.onText = { [weak self] s in self?.text = s }
        e.onSubmit = { [weak self] in self?.commitText() }
        Runway.backend.update(field, props: p, events: e)
        var sp = WidgetProps()
        sp.number = stepBase
        sp.range = -1e9...1e9
        sp.step = 1
        sp.enabled = isEnabled
        var se = WidgetEvents()
        se.onNumber = { [weak self] v in
            guard let self else { return }
            let d = v - self.stepBase
            self.stepBase = v
            if d != 0 { self.step(d) }
        }
        Runway.backend.update(stepper, props: sp, events: se)
        layoutSubviews()
    }

    override func place() {
        placementDirty = false
        let h = min(bounds.height, controlSize.height)
        let y = ((bounds.height - h) / 2).rounded()
        if datePickerStyle == .textFieldAndStepper {
            let sw = Runway.backend.measure(stepper, proposal: .unspecified).width
            placeChildren(below: [(field, CGRect(x: 0, y: y, width: max(0, bounds.width - sw - 4), height: h)),
                                  (stepper, CGRect(x: bounds.width - sw, y: y, width: sw, height: h))])
        } else {
            placeChildren(below: [(field, CGRect(x: 0, y: y, width: bounds.width, height: h))])
        }
    }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }
    open override var intrinsicContentSize: CGSize {
        let l = LabelWidget()
        l.set(dateFormatter.string(from: dateValue), font: NSFont(spec: fontSpec))
        let sw = datePickerStyle == .textFieldAndStepper ? Runway.backend.measure(stepper, proposal: .unspecified).width + 4 : 0
        return CGSize(width: (l.size().width + 20 + sw).rounded(.up), height: controlSize.height)
    }
}

// MARK: Image view

public enum NSImageAlignment: UInt, Sendable {
    case alignCenter = 0, alignTop, alignTopLeft, alignTopRight, alignLeft, alignBottom, alignBottomLeft, alignBottomRight, alignRight
}
public enum NSImageFrameStyle: UInt, Sendable { case none = 0, photo, grayBezel, groove, button }

@preconcurrency @MainActor
open class NSImageView: NSControl {
    open var image: NSImage? { didSet { controlStateChanged(); invalidateIntrinsicContentSize() } }
    open var imageScaling: NSImageScaling = .scaleProportionallyDown { didSet { layoutSubviews() } }
    open var imageAlignment: NSImageAlignment = .alignCenter { didSet { layoutSubviews() } }
    open var imageFrameStyle: NSImageFrameStyle = .none
    open var isEditable = false
    open var animates = true
    open var allowsCutCopyPaste = false
    open var contentTintColor: NSColor? { didSet { controlStateChanged() } }
    open var symbolConfiguration: NSImage.SymbolConfiguration? { didSet { controlStateChanged() } }
    var backgroundStyle: NSView.BackgroundStyle = .normal { didSet { if backgroundStyle != oldValue { controlStateChanged() } } }
    let native: NativeWidget

    public override init(frame frameRect: CGRect) {
        native = makeNative(.image)
        super.init(frame: frameRect)
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        native = makeNative(.image)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }
    public convenience init(image: NSImage) {
        self.init(frame: .zero)
        self.image = image
        controlStateChanged()
        sizeToFit()
    }

    open override var objectValue: Any? { get { image } set { image = newValue as? NSImage } }

    private var isSymbol: Bool { if case .symbol = image?.imageSource { return true }; return false }

    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        var p = WidgetProps()
        p.image = image?.imageSource ?? .none
        var tint = contentTintColor?.rgbaValue
        if isSymbol || image?.isTemplate == true {
            if backgroundStyle == .emphasized { tint = .white } else if tint == nil { tint = NSColor.secondaryLabelColor.rgbaValue }
        }
        p.imageTint = tint
        p.imagePointSize = symbolConfiguration?.pointSize ?? (isSymbol ? min(max(bounds.height, 13) / 1.25, 15).rounded() : 13)
        p.enabled = isEnabled
        Runway.backend.update(native, props: p, events: WidgetEvents())
        layoutSubviews()
    }

    private var naturalSize: CGSize {
        guard let image else { return .zero }
        if image.size.width > 0, !isSymbol { return image.size }
        return Runway.backend.measure(native, proposal: .unspecified)
    }

    /// The image's rect by scaling and alignment.
    override func place() {
        placementDirty = false
        let n = naturalSize
        guard n.width > 0, n.height > 0 else { placeChildren(below: [(native, bounds)]); return }
        var s = n
        switch imageScaling {
        case .scaleAxesIndependently: s = bounds.size
        case .scaleNone: break
        case .scaleProportionallyDown, .scaleProportionallyUpOrDown:
            let f = min(bounds.width / n.width, bounds.height / n.height)
            if imageScaling == .scaleProportionallyUpOrDown || f < 1 { s = CGSize(width: n.width * f, height: n.height * f) }
        }
        var x = (bounds.width - s.width) / 2, y = (bounds.height - s.height) / 2
        switch imageAlignment {
        case .alignLeft, .alignTopLeft, .alignBottomLeft: x = 0
        case .alignRight, .alignTopRight, .alignBottomRight: x = bounds.width - s.width
        default: break
        }
        switch imageAlignment {
        case .alignTop, .alignTopLeft, .alignTopRight: y = 0
        case .alignBottom, .alignBottomLeft, .alignBottomRight: y = bounds.height - s.height
        default: break
        }
        placeChildren(below: [(native, CGRect(x: x.rounded(), y: y.rounded(), width: s.width.rounded(), height: s.height.rounded()))])
    }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); controlStateChanged() }
    open override var intrinsicContentSize: CGSize { image == nil ? CGSize(width: -1, height: -1) : naturalSize }
}

// MARK: Box

@preconcurrency @MainActor
open class NSBox: NSView {
    open override var isFlipped: Bool { true }
    public enum BoxType: UInt, Sendable { case primary = 0, secondary, separator, oldStyle, custom }
    public enum TitlePosition: UInt, Sendable { case noTitle = 0, aboveTop, atTop, belowTop, aboveBottom, atBottom, belowBottom }
    open var boxType: BoxType = .primary { didSet { update() } }
    open var title = "Title" { didSet { update() } }
    open var titlePosition: TitlePosition = .atTop { didSet { update() } }
    open var titleFont: NSFont = .systemFont(ofSize: 11) { didSet { update() } }
    open var borderColor: NSColor = .separatorColor { didSet { update() } }
    open var fillColor: NSColor = .clear { didSet { update() } }
    open var borderWidth: CGFloat = 1 { didSet { update() } }
    open var cornerRadius: CGFloat = 0 { didSet { update() } }
    open var isTransparent = false { didSet { update() } }
    open var borderType: NSBorderType = .lineBorder
    open var contentViewMargins = CGSize(width: 5, height: 5) { didSet { layoutContent() } }
    open var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let c = contentView { addSubview(c) }
            layoutContent()
        }
    }
    private let backdrop = DrawnLayer()
    private let label = LabelWidget()
    private let separator: NativeWidget

    public override init(frame frameRect: CGRect) {
        separator = makeNative(.divider)
        super.init(frame: frameRect)
        onMain {
            contentView = NSView(frame: .zero)
            update()
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        separator = makeNative(.divider)
        super.init(coder: coder)
        onMain {
            contentView = NSView(frame: .zero)
            update()
        }
        IBDecoding.leave(self, coder)
    }

    open func setContentViewMargins(_ m: CGSize) { contentViewMargins = m }
    open func sizeToFit() {
        guard let c = contentView else { return }
        let s = c.fittingSize
        setFrameSize(CGSize(width: s.width + contentViewMargins.width * 2, height: s.height + contentViewMargins.height * 2 + titleHeight))
    }
    open var titleRect: CGRect { CGRect(x: 4, y: 0, width: bounds.width - 8, height: titleHeight) }
    private var showsTitle: Bool { titlePosition != .noTitle && boxType != .separator && !title.isEmpty && boxType != .custom }
    private var titleHeight: CGFloat { showsTitle ? label.size().height + 4 : 0 }
    /// The box's border rect (below the title).
    open var borderRect: CGRect { CGRect(x: 0, y: titleHeight, width: bounds.width, height: max(0, bounds.height - titleHeight)) }

    private func update() {
        if showsTitle { label.set(title, font: titleFont, color: .labelColor) }
        let r = borderRect.insetBy(dx: 0.5, dy: 0.5)
        var cmds: [DrawCommand] = []
        if !isTransparent {
            switch boxType {
            case .primary, .secondary, .oldStyle:
                let dark = NSAppearance.current.isDark
                cmds.append(.fill(.roundedRect(r, radius: 5), .color(RGBA(0, 0, 0, dark ? 0.1 : 0.04))))
                cmds.append(.stroke(.roundedRect(r, radius: 5), .color(RGBA(0, 0, 0, dark ? 0.25 : 0.09)), lineWidth: 1, dash: []))
            case .custom:
                if fillColor.rgbaValue.a > 0 { cmds.append(.fill(.roundedRect(borderRect, radius: cornerRadius), .color(fillColor.rgbaValue))) }
                if borderWidth > 0, borderColor.rgbaValue.a > 0 {
                    cmds.append(.stroke(.roundedRect(borderRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2), radius: cornerRadius), .color(borderColor.rgbaValue), lineWidth: borderWidth, dash: []))
                }
            case .separator: break
            }
        }
        backdrop.draw(cmds)
        layoutContent()
    }

    private func layoutContent() {
        if let c = contentView, boxType != .separator {
            var f = borderRect.insetBy(dx: contentViewMargins.width, dy: contentViewMargins.height)
            // Margins wider than the box (a box not yet sized) leave no room.
            if f.isNull { f = CGRect(x: borderRect.midX, y: borderRect.midY, width: 0, height: 0) }
            if c.frame != f { c.frame = f }
        }
        layoutSubviews()
    }

    override func place() {
        placementDirty = false
        if boxType == .separator {
            let horizontal = bounds.width >= bounds.height
            let r = horizontal ? CGRect(x: 0, y: (bounds.height / 2).rounded(.down), width: bounds.width, height: 1)
                               : CGRect(x: (bounds.width / 2).rounded(.down), y: 0, width: 1, height: bounds.height)
            placeChildren(below: [(separator, r)])
            return
        }
        var below: [(NativeWidget, CGRect)] = [(backdrop.widget, bounds)]
        if showsTitle { below.append((label.widget, CGRect(x: 6, y: 0, width: bounds.width - 12, height: label.size().height))) }
        placeChildren(below: below)
    }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); update() }
    open override var intrinsicContentSize: CGSize { boxType == .separator ? CGSize(width: -1, height: 1) : CGSize(width: -1, height: -1) }
}
