// What each Interface Builder element sets on its object: views and their
// subviews, constraints and cells; the standard controls; windows, menus,
// tables, stacks, splits, tabs, boxes, scroll views; controllers.
//
// IB omits values that equal the archived object's defaults, and a cell's
// unset flags are off (a text field's cell without `editable` isn't
// editable), so flags are set explicitly from the attribute's presence.

import Foundation
import RunwayCore

extension IBLoader {
    // MARK: Views

    func decodeView(_ v: NSView, _ e: IBElement) {
        _ = e.child(key: "frame", "rect")
        if let m = IBValue.autoresizingMask(e.child(key: "autoresizingMask")) { v.autoresizingMask = m }
        if e.bool("translatesAutoresizingMaskIntoConstraints") == false { v.translatesAutoresizingMaskIntoConstraints = false }
        _ = e["fixedFrame"]
        if e.bool("hidden") == true { v.isHidden = true }
        if let id = e["identifier"] { v.identifier = NSUserInterfaceItemIdentifier(id) }
        if let t = localized(e, "toolTip") ?? e["toolTip"] { v.toolTip = t }
        if let p = IBValue.priority(e["horizontalHuggingPriority"]) { v.setContentHuggingPriority(p, for: .horizontal) }
        if let p = IBValue.priority(e["verticalHuggingPriority"]) { v.setContentHuggingPriority(p, for: .vertical) }
        if let p = IBValue.priority(e["horizontalCompressionResistancePriority"]) { v.setContentCompressionResistancePriority(p, for: .horizontal) }
        if let p = IBValue.priority(e["verticalCompressionResistancePriority"]) { v.setContentCompressionResistancePriority(p, for: .vertical) }
        if e.bool("wantsLayer") == true { v.wantsLayer = true }
        if e.bool("autoresizesSubviews") == false { v.autoresizesSubviews = false }
        if let c = e.bool("clipsToBounds") { v.clipsToBounds = c }
        _ = e["mirrorLayoutDirectionWhenInternationalizing"]
        if let a = e.double("alphaValue") { v.alphaValue = CGFloat(a) }
        if let f = e["focusRingType"] { v.focusRingType = f == "none" ? .none : f == "exterior" ? .exterior : .default }
        if let ap = e.child(key: "appearance") ?? e.child("appearance") { v.appearance = appearance(ap) }
        if let a = e["appearanceType"] { v.appearance = appearance(named: a) }
        _ = e.child("accessibility"); _ = e.child(key: "shadow"); _ = e.child("animations")
        _ = e["layerContentsRedrawPolicy"]; _ = e["canDrawConcurrently"]

        switch e.name {
        case "scrollView": decodeScrollView(v as! NSScrollView, e)
        case "clipView":
            // A clip view outside a scroll view's contentView key.
            if let first = e.child("subviews")?.children.first, let doc = object(for: first) as? NSView { (v as! NSClipView).documentView = doc }
        case "box": decodeBox(v as! NSBox, e)
        case "stackView": decodeStackView(v as! NSStackView, e)
        case "splitView": decodeSplitView(v as! NSSplitView, e)
        case "tabView": decodeTabView(v as! NSTabView, e)
        case "gridView": decodeGridView(v as! NSGridView, e)
        default: addSubviews(v, e)
        }
        if let cs = e.child("constraints") { addConstraints(cs, to: v) }

        if let c = v as? NSControl { decodeControl(c, e) }
        switch e.name {
        case "tableView", "outlineView": decodeTableView(v as! NSTableView, e)
        case "textView": decodeTextView(v as! NSTextView, e)
        case "progressIndicator": decodeProgressIndicator(v as! NSProgressIndicator, e)
        case "visualEffectView": decodeVisualEffectView(v as! NSVisualEffectView, e)
        case "tableCellView": decodeTableCellView(v as! NSTableCellView, e)
        case "collectionView":
            let cv = v as! NSCollectionView
            if let s = e.bool("selectable") { cv.isSelectable = s }
            if let m = e.bool("allowsMultipleSelection") { cv.allowsMultipleSelection = m }
            if let c = e.child(key: "primaryBackgroundColor", "color").flatMap({ IBValue.color($0, resources: resources) }) { cv.backgroundColors = [c] }
            if let l = e.child(key: "collectionViewLayout") { decodeFlowLayout(l, cv) }
        default: break
        }
    }

    func addSubviews(_ v: NSView, _ e: IBElement) {
        guard let list = e.child("subviews") else { return }
        for s in list.children {
            s.consumed = true
            if let sv = object(for: s) as? NSView, sv.superview !== v { v.addSubview(sv) }
        }
    }

    func appearance(_ e: IBElement) -> NSAppearance? {
        appearance(named: e["name"] ?? e.attributes["appearanceType"] ?? "")
    }
    func appearance(named n: String) -> NSAppearance? {
        if n.lowercased().contains("dark") { return NSAppearance(named: .darkAqua) }
        if n.lowercased().contains("aqua") || n.lowercased().contains("light") { return NSAppearance(named: .aqua) }
        return nil
    }

    /// A localized override (Base internationalization) for `property` of `e`.
    func localized(_ e: IBElement, _ property: String) -> String? {
        document.localized(e.id, property)
    }

    // MARK: Controls

    func decodeControl(_ c: NSControl, _ e: IBElement) {
        if e.bool("enabled") == false { c.isEnabled = false }
        if let t = e.bool("allowsExpansionToolTips") { c.allowsExpansionToolTips = t }
        if let s = IBValue.controlSize(e["controlSize"]) { c.controlSize = s }
        if let a = IBValue.alignment(e["alignment"]) { c.alignment = a }
        _ = e["baseWritingDirection"]; _ = e["imageHugsTitle"]
        if let cv = e.bool("continuous") { c.isContinuous = cv }
        if let cell = e.children.first(where: { $0.attributes["key"] == "cell" }) {
            cell.consumed = true
            if let id = cell.id { objects[id] = c.cell ?? c }
            // A cell's target/action is its control's.
            if let conns = cell.child("connections") { queueConnections(conns, c) }
            _ = cell["identifier"]; _ = cell["customClass"]; _ = cell["customModule"]
            _ = cell.child("allowedInputSourceLocales")
            decodeCell(c, cell, control: e)
        } else {
            decodeCell(c, e, control: e)
        }
    }

    /// A control's cell (or, for cell-less controls like NSSwitch, the control element).
    func decodeCell(_ c: NSControl, _ cell: IBElement, control e: IBElement) {
        if let f = IBValue.font(cell.child(key: "font", "font")) { c.font = f }
        if let a = IBValue.alignment(cell["alignment"]) { c.alignment = a }
        if let l = IBValue.lineBreakMode(cell["lineBreakMode"]) { c.lineBreakMode = l }
        if let s = IBValue.controlSize(cell["controlSize"]) { c.controlSize = s }
        if cell.bool("enabled") == false { c.isEnabled = false }
        if let cv = cell.bool("continuous") { c.isContinuous = cv }
        if cell.bool("usesSingleLineMode") == true { c.usesSingleLineMode = true }
        if cell.bool("refusesFirstResponder") == true { c.refusesFirstResponder = true }
        _ = cell["sendsActionOnEndEditing"]; _ = cell["truncatesLastVisibleLine"]; _ = cell["scrollable"]; _ = cell["allowsUndo"]
        _ = cell["id"]; _ = cell["key"]; _ = cell["inset"]; _ = cell["focusRingType"]; _ = cell["baseWritingDirection"]
        _ = cell["allowsMixedState"]; _ = cell["wraps"]; _ = cell["allowsEditingTextAttributes"]
        if let fmt = cell.child(key: "formatter") { c.formatter = formatter(fmt) }

        switch c {
        case let p as NSPopUpButton: decodePopUp(p, cell)
        case let b as NSButton: decodeButton(b, cell)
        case let t as NSTextField: decodeTextField(t, cell, control: e)
        case let s as NSSegmentedControl: decodeSegmented(s, cell)
        case let s as NSSlider: decodeSlider(s, cell)
        case let s as NSStepper:
            if let v = cell.double("minValue") { s.minValue = v }
            if let v = cell.double("maxValue") { s.maxValue = v }
            if let v = cell.double("increment") { s.increment = v }
            s.valueWraps = cell.bool("valueWraps") ?? false
            s.autorepeat = cell.bool("autorepeat") ?? true
            if let v = cell.double("doubleValue") { s.doubleValue = v }
        case let l as NSLevelIndicator:
            if let v = cell.double("minValue") { l.minValue = v }
            if let v = cell.double("maxValue") { l.maxValue = v }
            if let v = cell.double("warningValue") { l.warningValue = v }
            if let v = cell.double("criticalValue") { l.criticalValue = v }
            if let v = cell.int("numberOfTickMarks") { l.numberOfTickMarks = v }
            if let v = cell.int("numberOfMajorTickMarks") { l.numberOfMajorTickMarks = v }
            if cell.bool("editable") == true { l.isEditable = true }
            switch cell["levelIndicatorStyle"] {
            case "relevancy": l.levelIndicatorStyle = .relevancy
            case "discreteCapacity": l.levelIndicatorStyle = .discreteCapacity
            case "rating": l.levelIndicatorStyle = .rating
            case "continuousCapacity": l.levelIndicatorStyle = .continuousCapacity
            default: break
            }
            if let v = cell.double("doubleValue") { l.doubleValue = v }
        case let w as NSColorWell:
            if let col = IBValue.color(cell.child(key: "color", "color"), resources: resources) { w.color = col }
            if cell.bool("bordered") == false { w.isBordered = false }
            switch cell["colorWellStyle"] { case "minimal": w.colorWellStyle = .minimal; case "expanded": w.colorWellStyle = .expanded; default: break }
        case let d as NSDatePicker:
            if let t = cell.child(key: "date", "date")?.double("timeIntervalSinceReferenceDate") { d.dateValue = Date(timeIntervalSinceReferenceDate: t) }
            if let t = cell.child(key: "minDate", "date")?.double("timeIntervalSinceReferenceDate") { d.minDate = Date(timeIntervalSinceReferenceDate: t) }
            if let t = cell.child(key: "maxDate", "date")?.double("timeIntervalSinceReferenceDate") { d.maxDate = Date(timeIntervalSinceReferenceDate: t) }
            switch cell["datePickerStyle"] {
            case "clockAndCalendar": d.datePickerStyle = .clockAndCalendar
            case "textField": d.datePickerStyle = .textField
            default: break
            }
            if let el = cell["datePickerElements"] ?? cell.child(key: "datePickerElements").flatMap({ _ in nil }) { _ = el }
            if let c = IBValue.color(cell.child(key: "textColor", "color"), resources: resources) { d.textColor = c }
            if let c = IBValue.color(cell.child(key: "backgroundColor", "color"), resources: resources) { d.backgroundColor = c }
            d.drawsBackground = cell.bool("drawsBackground") ?? false
            if cell["borderStyle"] == nil { d.isBezeled = false }
        case let i as NSImageView:
            if let img = image(cell) { i.image = img }
            if let s = IBValue.imageScaling(cell["imageScaling"]) { i.imageScaling = s }
            if let a = cell["imageAlignment"] {
                let map: [String: NSImageAlignment] = ["center": .alignCenter, "top": .alignTop, "topLeft": .alignTopLeft, "topRight": .alignTopRight,
                                                       "left": .alignLeft, "bottom": .alignBottom, "bottomLeft": .alignBottomLeft,
                                                       "bottomRight": .alignBottomRight, "right": .alignRight]
                if let v = map[a] { i.imageAlignment = v }
            }
            switch cell["imageFrameStyle"] {
            case "photo": i.imageFrameStyle = .photo
            case "grayBezel": i.imageFrameStyle = .grayBezel
            case "groove": i.imageFrameStyle = .groove
            case "button": i.imageFrameStyle = .button
            default: break
            }
            if cell.bool("editable") == true { i.isEditable = true }
            if let t = IBValue.color(e.child(key: "contentTintColor", "color"), resources: resources) { i.contentTintColor = t }
            if let a = e.bool("animates") { i.animates = a }
        case let s as NSSwitch:
            s.state = state(cell["state"])
        default: break
        }
        if let tag = cell.int("tag") ?? e.int("tag") { c.tag = tag }
    }

    func state(_ s: String?) -> NSControl.StateValue {
        switch s { case "on": return .on; case "mixed": return .mixed; default: return .off }
    }

    /// `image="name"` with the document's `<resources><image name=… catalog=…>`.
    func image(_ e: IBElement, _ key: String = "image") -> NSImage? {
        if let ref = e.child(key: key, "imageReference") {
            return IBValue.image(named: ref["image"], catalog: ref["catalog"])
        }
        if let img = e.child(key: key, "image") { return IBValue.image(named: img["name"], catalog: img["catalog"]) }
        guard let name = e[key] else { return nil }
        let res = resources?.children.first { $0.name == "image" && $0.attributes["name"] == name }
        res?.consumed = true
        return IBValue.image(named: name, catalog: res?.attributes["catalog"])
    }

    func formatter(_ e: IBElement) -> Formatter? {
        switch e.name {
        case "numberFormatter":
            let f = NumberFormatter()
            switch e["numberStyle"] {
            case "decimal": f.numberStyle = .decimal
            case "percent": f.numberStyle = .percent
            case "currency": f.numberStyle = .currency
            default: break
            }
            if let m = e.int("minimumFractionDigits") { f.minimumFractionDigits = m }
            if let m = e.int("maximumFractionDigits") { f.maximumFractionDigits = m }
            if let m = e.int("minimumIntegerDigits") { f.minimumIntegerDigits = m }
            if let m = e.int("maximumIntegerDigits") { f.maximumIntegerDigits = m }
            if let w = e.int("formatWidth") { f.formatWidth = w }
            if let v = e.child(key: "minimum", "real")?.double("value") ?? e.child(key: "minimum", "integer")?.double("value") { f.minimum = NSNumber(value: v) }
            if let v = e.child(key: "maximum", "real")?.double("value") ?? e.child(key: "maximum", "integer")?.double("value") { f.maximum = NSNumber(value: v) }
            _ = e["formatterBehavior"]; _ = e["usesGroupingSeparator"]; _ = e["groupingSize"]; _ = e["id"]
            return f
        case "dateFormatter":
            let f = DateFormatter()
            if let d = e["dateFormat"] { f.dateFormat = d }
            switch e["dateStyle"] { case "short": f.dateStyle = .short; case "medium": f.dateStyle = .medium; case "long": f.dateStyle = .long; default: break }
            switch e["timeStyle"] { case "short": f.timeStyle = .short; case "medium": f.timeStyle = .medium; case "long": f.timeStyle = .long; default: break }
            return f
        default:
            if let name = e["customClass"], let cls = ClassRegistry.lookup(name, module: e["customModule"]),
               let f = ClassRegistry.factory(for: cls)?() as? Formatter { return f }
            return nil
        }
    }

    func decodeButton(_ b: NSButton, _ cell: IBElement) {
        // Type and bezel: `type` is IB's button kind, `bezelStyle` the bezel.
        let type = cell["type"]
        let behavior = cell.child(key: "behavior", "behavior")
        switch type {
        case "check", "radio":
            b.setButtonType(type == "check" ? .switch : .radio)
            if let beh = behavior { for a in beh.attributes.keys { _ = beh[a] } }
        default:
            if let beh = behavior {
                let pushIn = beh.bool("pushIn") == true, changeContents = beh.bool("changeContents") == true
                let lightByContents = beh.bool("lightByContents") == true, lightByBackground = beh.bool("lightByBackground") == true
                let lightByGray = beh.bool("lightByGray") == true
                let changeBackground = beh.bool("changeBackground") == true || beh.bool("changeGray") == true
                _ = beh["doesNotDimImage"]; _ = beh["key"]
                if changeBackground && pushIn { b.setButtonType(.pushOnPushOff) }
                else if changeBackground { b.setButtonType(.onOff) }
                else if changeContents && lightByBackground && lightByGray { b.setButtonType(.toggle) }
                else if changeContents && lightByContents { b.setButtonType(.toggle) }
                else if changeContents && !pushIn { b.setButtonType(.onOff) }
                else if pushIn && lightByGray { b.setButtonType(.momentaryPushIn) }
                else if pushIn && changeContents { b.setButtonType(.pushOnPushOff) }
                else if lightByContents { b.setButtonType(.momentaryChange) }
                else if lightByBackground || lightByGray { b.setButtonType(.momentaryLight) }
            }
        }
        if let bz = IBValue.bezelStyle(cell["bezelStyle"]) ?? IBValue.bezelStyle(type) { b.bezelStyle = bz }
        // Without a border style IB draws no bezel (image and inline buttons).
        if type != "check" && type != "radio" { b.isBordered = cell["borderStyle"] != nil }
        if cell.bool("transparent") == true { b.isTransparent = true }
        if let t = localized(cell, "title") ?? cell["title"] ?? IBValue.string(cell.child(key: "title", "string")) { b.title = t }
        else if type != "check" && type != "radio" && cell.child(key: "attributedTitle") == nil { b.title = "" }
        if let at = cell.child(key: "attributedTitle") { b.title = attributedText(at) }
        if let t = localized(cell, "alternateTitle") ?? cell["alternateTitle"] { b.alternateTitle = t }
        if let img = image(cell) { b.image = img }
        if let img = image(cell, "alternateImage") { b.alternateImage = img }
        if let p = IBValue.imagePosition(cell["imagePosition"]) { b.imagePosition = p }
        else if b.image != nil && b.title.isEmpty { b.imagePosition = .imageOnly }
        if let s = IBValue.imageScaling(cell["imageScaling"]) { b.imageScaling = s }
        b.state = state(cell["state"])
        if cell.bool("allowsMixedState") == true { b.allowsMixedState = true }
        if let k = IBValue.string(cell.child(key: "keyEquivalent", "string")) ?? cell["keyEquivalent"] { b.keyEquivalent = k }
        if let m = cell.child(key: "keyEquivalentModifierMask", "modifierMask") { b.keyEquivalentModifierMask = modifiers(m) }
        if let c = IBValue.color(cell.child(key: "bezelColor", "color") ?? cell.parent?.child(key: "bezelColor", "color"), resources: resources) { b.bezelColor = c }
        if let c = IBValue.color(cell.parent?.child(key: "contentTintColor", "color"), resources: resources) { b.contentTintColor = c }
        if let sc = cell.parent?.child(key: "symbolConfiguration") { _ = sc }
        if cell.bool("showsBorderOnlyWhileMouseInside") == true { b.showsBorderOnlyWhileMouseInside = true }
        if let h = cell.parent?.bool("imageHugsTitle") { b.imageHugsTitle = h }
        _ = cell["borderStyle"]; _ = cell["imageAlignment"]; _ = cell["highlightsBy"]; _ = cell["showsStateBy"]
    }

    func attributedText(_ e: IBElement) -> String {
        e.consumed = true
        return e.children("fragment").map { $0["content"] ?? IBValue.string($0.child(key: "content", "string")) ?? "" }.joined()
    }

    func modifiers(_ m: IBElement) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.bool("command") == true { f.insert(.command) }
        if m.bool("shift") == true { f.insert(.shift) }
        if m.bool("option") == true { f.insert(.option) }
        if m.bool("control") == true { f.insert(.control) }
        if m.bool("function") == true { f.insert(.function) }
        return f
    }

    func decodeTextField(_ t: NSTextField, _ cell: IBElement, control e: IBElement) {
        let title = localized(cell, "title") ?? cell["title"] ?? IBValue.string(cell.child(key: "title", "string"))
        if let at = cell.child(key: "attributedStringValue") { t.stringValue = attributedText(at) }
        else { t.stringValue = title ?? "" }
        if let p = localized(cell, "placeholderString") ?? cell["placeholderString"] { t.placeholderString = p }
        else if t is NSSearchField == false { t.placeholderString = nil }
        _ = cell["state"]  // meaningless on text cells
        let border = cell["borderStyle"]
        // One border type (in AppKit, isBordered = false after a bezel removes it).
        if border == "border" { t.isBordered = true }
        t.isBezeled = border == "bezel"
        if let bz = cell["bezelStyle"] { t.bezelStyle = bz == "round" ? .roundedBezel : .squareBezel }
        t.isEditable = cell.bool("editable") ?? false
        t.isSelectable = cell.bool("selectable") ?? t.isEditable
        t.drawsBackground = cell.bool("drawsBackground") ?? false
        if let c = IBValue.color(cell.child(key: "textColor", "color"), resources: resources) { t.textColor = c }
        if let c = IBValue.color(cell.child(key: "backgroundColor", "color"), resources: resources) { t.backgroundColor = c }
        if let n = e.int("maximumNumberOfLines") ?? cell.int("maximumNumberOfLines") { t.maximumNumberOfLines = n }
        if let w = e.double("preferredMaxLayoutWidth") { t.preferredMaxLayoutWidth = CGFloat(w) }
        if let s = t as? NSSearchField {
            s.sendsWholeSearchString = cell.bool("sendsWholeSearchString") ?? false
            s.sendsSearchStringImmediately = cell.bool("sendsSearchStringImmediately") ?? false
            if let n = cell.int("maximumRecents") { s.maximumRecents = n }
            if let n = cell["recentsAutosaveName"] { s.recentsAutosaveName = n }
        }
        if let c = t as? NSComboBox, let values = cell.child("objectValues") {
            c.addItems(withObjectValues: values.children.map { IBValue.string($0) ?? "" })
            if let n = cell.int("numberOfVisibleItems") { c.numberOfVisibleItems = n }
            c.completes = cell.bool("completes") ?? false
            c.usesDataSource = cell.bool("usesDataSource") ?? false
        }
        if let ct = e["contentType"] { t.contentType = NSTextContentType(ct) }
    }

    func decodePopUp(_ p: NSPopUpButton, _ cell: IBElement) {
        if let bz = IBValue.bezelStyle(cell["bezelStyle"]) { p.bezelStyle = bz }
        p.isBordered = cell["borderStyle"] != nil
        if let f = IBValue.font(cell.child(key: "font", "font")) { p.font = f }
        if cell.bool("pullsDown") == true { p.pullsDown = true }
        if let a = cell.bool("autoenablesItems") { p.autoenablesItems = a }
        _ = cell["type"]; _ = cell["title"]; _ = cell["state"]; _ = cell["imageScaling"]; _ = cell["borderStyle"]
        cell.child(key: "behavior")?.ignoreSubtree(); _ = cell["altersStateOfSelectedItem"]; _ = cell["arrowPosition"]; _ = cell["preferredEdge"]
        if let m = cell.child(key: "menu", "menu"), let menu = object(for: m) as? NSMenu { p.menu = menu }
        if let sel = cell["selectedItem"] {
            afterConnecting.append { [weak p, weak self] in
                guard let p, let item = self?.objects[sel] as? NSMenuItem else { return }
                p.selectItem(item)
            }
        } else if !p.pullsDown, p.numberOfItems > 0 {
            p.selectItem(at: 0)
        }
    }

    func decodeSegmented(_ s: NSSegmentedControl, _ cell: IBElement) {
        switch cell["trackingMode"] {
        case "selectAny": s.trackingMode = .selectAny
        case "momentary": s.trackingMode = .momentary
        case "momentaryAccelerator": s.trackingMode = .momentaryAccelerator
        default: s.trackingMode = .selectOne
        }
        switch cell["style"] {
        case "rounded": s.segmentStyle = .rounded
        case "texturedRounded": s.segmentStyle = .texturedRounded
        case "roundRect": s.segmentStyle = .roundRect
        case "texturedSquare": s.segmentStyle = .texturedSquare
        case "capsule": s.segmentStyle = .capsule
        case "smallSquare": s.segmentStyle = .smallSquare
        case "separated": s.segmentStyle = .separated
        default: break
        }
        _ = cell["borderStyle"]
        switch cell["segmentDistribution"] {
        case "fill": s.segmentDistribution = .fill
        case "fillEqually": s.segmentDistribution = .fillEqually
        case "fillProportionally": s.segmentDistribution = .fillProportionally
        case "fit": s.segmentDistribution = .fit
        default: break
        }
        let segs = cell.child("segments")?.children("segment") ?? []
        s.segmentCount = segs.count
        for (i, seg) in segs.enumerated() {
            if let l = localized(seg, "label") ?? seg["label"] { s.setLabel(l, forSegment: i) }
            if let img = image(seg) { s.setImage(img, forSegment: i) }
            if let w = seg.double("width") { s.setWidth(CGFloat(w), forSegment: i) }
            if let t = seg.int("tag") { s.setTag(t, forSegment: i) }
            if let tip = seg["toolTip"] { s.setToolTip(tip, forSegment: i) }
            if seg.bool("enabled") == false { s.setEnabled(false, forSegment: i) }
            if seg.bool("selected") == true { s.setSelected(true, forSegment: i) }
            if let m = seg.child(key: "menu", "menu"), let menu = object(for: m) as? NSMenu { s.setMenu(menu, forSegment: i) }
            _ = seg["imageScaling"]; _ = seg["alignment"]
        }
    }

    func decodeSlider(_ s: NSSlider, _ cell: IBElement) {
        if let v = cell.double("minValue") { s.minValue = v }
        if let v = cell.double("maxValue") { s.maxValue = v }
        if let v = cell.int("numberOfTickMarks") { s.numberOfTickMarks = v }
        if let v = cell.bool("allowsTickMarkValuesOnly") { s.allowsTickMarkValuesOnly = v }
        s.tickMarkPosition = cell["tickMarkPosition"] == "above" ? .above : .below
        if cell["sliderType"] == "circular" { s.sliderType = .circular }
        if let v = cell.double("doubleValue") { s.doubleValue = v }
        if let v = cell.double("altIncrementValue") { s.altIncrementValue = v }
        if let f = s.frame.size as CGSize?, f.height > f.width * 1.5, s.sliderType == .linear { s.isVertical = true }
        _ = cell["state"]
    }

    func decodeProgressIndicator(_ p: NSProgressIndicator, _ e: IBElement) {
        if let v = e.double("minValue") { p.minValue = v }
        if let v = e.double("maxValue") { p.maxValue = v }
        if let v = e.double("doubleValue") { p.doubleValue = v }
        p.isIndeterminate = e.bool("indeterminate") ?? false
        if e["style"] == "spinning" { p.style = .spinning }
        if let d = e.bool("displayedWhenStopped") { p.isDisplayedWhenStopped = d }
        if let s = IBValue.controlSize(e["controlSize"]) { p.controlSize = s }
        if e.bool("bezeled") == false { p.isBezeled = false }
        _ = e["usesThreadedAnimation"]
    }

    func decodeVisualEffectView(_ v: NSVisualEffectView, _ e: IBElement) {
        let materials: [String: NSVisualEffectView.Material] = [
            "appearanceBased": .appearanceBased, "light": .light, "dark": .dark, "titlebar": .titlebar, "selection": .selection,
            "menu": .menu, "popover": .popover, "sidebar": .sidebar, "mediumLight": .mediumLight, "ultraDark": .ultraDark,
            "headerView": .headerView, "sheet": .sheet, "windowBackground": .windowBackground, "HUDWindow": .hudWindow,
            "hudWindow": .hudWindow, "fullScreenUI": .fullScreenUI, "toolTip": .toolTip, "contentBackground": .contentBackground,
            "underWindowBackground": .underWindowBackground, "underPageBackground": .underPageBackground,
        ]
        if let m = e["material"].flatMap({ materials[$0] }) { v.material = m }
        if e["blendingMode"] == "withinWindow" { v.blendingMode = .withinWindow }
        switch e["state"] { case "active": v.state = .active; case "inactive": v.state = .inactive; default: break }
        if e.bool("emphasized") == true { v.isEmphasized = true }
    }

    func decodeTextView(_ t: NSTextView, _ e: IBElement) {
        t.isEditable = e.bool("editable") ?? true
        t.isSelectable = e.bool("selectable") ?? true
        if let r = e.bool("richText") { t.isRichText = r }
        if let u = e.bool("allowsUndo") { t.allowsUndo = u }
        if let f = e.bool("usesFindBar") { t.usesFindBar = f }
        if let v = e.bool("importsGraphics") { t.importsGraphics = v }
        if let v = e.bool("continuousSpellChecking") { t.isContinuousSpellCheckingEnabled = v }
        if let v = e.bool("smartInsertDelete") { t.smartInsertDeleteEnabled = v }
        if let v = e.bool("verticallyResizable") { t.isVerticallyResizable = v }
        if let v = e.bool("horizontallyResizable") { t.isHorizontallyResizable = v }
        if let v = e.bool("drawsBackground") { t.drawsBackground = v }
        if let c = IBValue.color(e.child(key: "backgroundColor", "color"), resources: resources) { t.backgroundColor = c }
        if let c = IBValue.color(e.child(key: "textColor", "color"), resources: resources) { t.textColor = c }
        if let c = IBValue.color(e.child(key: "insertionPointColor", "color"), resources: resources) { t.insertionPointColor = c }
        if let s = IBValue.size(e.child(key: "minSize", "size")) { t.minSize = s }
        if let s = IBValue.size(e.child(key: "maxSize", "size")) { t.maxSize = s }
        if let s = IBValue.size(e.child(key: "textContainerInset", "size")) { t.textContainerInset = s }
        if let f = IBValue.font(e.child(key: "font", "font")) { t.font = f }
        if let s = e.child(key: "textStorage") ?? e.child("attributedString") { t.string = attributedText(s.child("attributedString") ?? s) }
        for (k, set) in [("quoteSubstitution", { (v: Bool) in t.isAutomaticQuoteSubstitutionEnabled = v }),
                         ("dashSubstitution", { t.isAutomaticDashSubstitutionEnabled = $0 }),
                         ("textReplacement", { t.isAutomaticTextReplacementEnabled = $0 }),
                         ("spellingCorrection", { t.isAutomaticSpellingCorrectionEnabled = $0 }),
                         ("linkDetection", { t.isAutomaticLinkDetectionEnabled = $0 }),
                         ("dataDetection", { t.isAutomaticDataDetectionEnabled = $0 })] {
            if let v = e.bool(k) { set(v) }
        }
        _ = e["findStyle"]; _ = e["incrementalSearchingEnabled"]; _ = e["allowsDocumentBackgroundColorChange"]; _ = e["usesFontPanel"]
        _ = e["spellingCorrection"]; _ = e["usesRuler"]; _ = e["allowsNonContiguousLayout"]; _ = e["allowsCharacterPickerTouchBarItem"]
        _ = e["textCompletion"]; _ = e["grammarChecking"]; _ = e["smartInsertDelete"]
        _ = e.child(key: "defaultParagraphStyle"); _ = e.child(key: "linkTextAttributes"); _ = e.child(key: "markedTextAttributes")
        _ = e.child(key: "selectedTextAttributes"); _ = e.child(key: "allowedInputSourceLocales")
    }

    func decodeTableCellView(_ v: NSTableCellView, _ e: IBElement) {
        // textField / imageView come as outlets.
    }

    func decodeFlowLayout(_ l: IBElement, _ cv: NSCollectionView) {
        guard l.name == "collectionViewFlowLayout" else { return }
        let f = NSCollectionViewFlowLayout()
        if let v = l.double("minimumInteritemSpacing") { f.minimumInteritemSpacing = CGFloat(v) }
        if let v = l.double("minimumLineSpacing") { f.minimumLineSpacing = CGFloat(v) }
        if let s = IBValue.size(l.child(key: "itemSize", "size")) { f.itemSize = s }
        if let i = IBValue.insets(l.child(key: "sectionInset", "edgeInsets")) { f.sectionInset = i }
        cv.collectionViewLayout = f
        if let id = l.id { objects[id] = f }
    }

    // MARK: Containers

    func decodeScrollView(_ s: NSScrollView, _ e: IBElement) {
        s.hasHorizontalScroller = e.bool("hasHorizontalScroller") ?? true
        s.hasVerticalScroller = e.bool("hasVerticalScroller") ?? true
        if let a = e.bool("autohidesScrollers") { s.autohidesScrollers = a }
        switch e["borderType"] {
        case "none": s.borderType = .noBorder
        case "line": s.borderType = .lineBorder
        case "groove": s.borderType = .grooveBorder
        default: s.borderType = e.attributes["borderType"] == nil ? .bezelBorder : s.borderType
        }
        if let d = e.bool("drawsBackground") { s.drawsBackground = d }
        if let a = e.bool("automaticallyAdjustsContentInsets") { s.automaticallyAdjustsContentInsets = a }
        if let i = IBValue.insets(e.child(key: "contentInsets", "edgeInsets")) { s.contentInsets = i }
        if let i = IBValue.insets(e.child(key: "scrollerInsets", "edgeInsets")) { s.scrollerInsets = i }
        if let m = e.bool("allowsMagnification") { s.allowsMagnification = m }
        if let v = e.double("magnification") { s.magnification = CGFloat(v) }
        if let v = e.double("minMagnification") { s.minMagnification = CGFloat(v) }
        if let v = e.double("maxMagnification") { s.maxMagnification = CGFloat(v) }
        let elasticity: [String: NSScrollView.Elasticity] = ["automatic": .automatic, "none": .none, "allowed": .allowed]
        if let v = e["horizontalScrollElasticity"].flatMap({ elasticity[$0] }) { s.horizontalScrollElasticity = v }
        if let v = e["verticalScrollElasticity"].flatMap({ elasticity[$0] }) { s.verticalScrollElasticity = v }
        _ = e["horizontalLineScroll"]; _ = e["horizontalPageScroll"]; _ = e["verticalLineScroll"]; _ = e["verticalPageScroll"]
        _ = e["usesPredominantAxisScrolling"]; _ = e["findBarPosition"]; _ = e["scrollerKnobStyle"]
        if let h = e.child(key: "headerView", "tableHeaderView"), let id = h.id {
            // The table makes its own header view; IB's maps onto it.
            afterHeader[id] = h
        }
        if let clip = e.child(key: "contentView", "clipView") {
            decodeExisting(s.contentView, clip)
        }
        for k in ["horizontalScroller", "verticalScroller"] {
            if let sc = e.child(key: k, "scroller") {
                if let id = sc.id { objects[id] = NSNull() }
                sc.consumed = true
                if sc.bool("hidden") == true { if k == "horizontalScroller" { s.hasHorizontalScroller = false } else { s.hasVerticalScroller = false } }
                _ = sc["verticalHuggingPriority"]; _ = sc["horizontal"]; _ = sc["doubleValue"]; _ = sc["knobProportion"]
                _ = IBValue.rect(sc.child(key: "frame")); _ = sc.child(key: "autoresizingMask"); _ = sc["wantsLayer"]; _ = sc["controlSize"]
            }
        }
        for sv in e.child("subviews")?.children ?? [] {
            sv.consumed = true
            if let v = object(for: sv) as? NSView, v.superview == nil { s.addSubview(v) }
        }
    }

    /// The clip view a scroll view made: IB's properties and document view go onto it.
    func decodeExisting(_ clip: NSClipView, _ e: IBElement) {
        e.consumed = true
        if let id = e.id { objects[id] = clip }
        collectConnections(clip, e)
        if let d = e.bool("drawsBackground") { clip.drawsBackground = d }
        if let c = IBValue.color(e.child(key: "backgroundColor", "color"), resources: resources) { clip.backgroundColor = c }
        _ = e.child(key: "backgroundColor", "nil"); _ = e["copiesOnScroll"]
        if let i = IBValue.insets(e.child(key: "contentInsets", "edgeInsets")) { clip.contentInsets = i }
        _ = e["wantsLayer"]
        _ = IBValue.rect(e.child(key: "frame")); _ = IBValue.autoresizingMask(e.child(key: "autoresizingMask"))
        if let first = e.child("subviews")?.children.first {
            e.child("subviews")?.consumed = true
            first.consumed = true
            if let doc = object(for: first) as? NSView { clip.documentView = doc }
        }
        if let cs = e.child("constraints") { addConstraints(cs, to: clip) }
    }

    func decodeBox(_ b: NSBox, _ e: IBElement) {
        switch e["boxType"] {
        case "secondary": b.boxType = .secondary
        case "separator": b.boxType = .separator
        case "oldStyle": b.boxType = .oldStyle
        case "custom": b.boxType = .custom
        default: break
        }
        if let t = localized(e, "title") ?? e["title"] { b.title = t }
        let positions: [String: NSBox.TitlePosition] = ["noTitle": .noTitle, "aboveTop": .aboveTop, "atTop": .atTop, "belowTop": .belowTop,
                                                        "aboveBottom": .aboveBottom, "atBottom": .atBottom, "belowBottom": .belowBottom]
        if let p = e["titlePosition"].flatMap({ positions[$0] }) { b.titlePosition = p }
        else if e["title"] == nil && e.child(key: "title") == nil { b.titlePosition = .noTitle }
        switch e["borderType"] { case "none": b.borderType = .noBorder; case "bezel": b.borderType = .bezelBorder; case "groove": b.borderType = .grooveBorder; default: break }
        if let w = e.double("borderWidth") { b.borderWidth = CGFloat(w) }
        if let r = e.double("cornerRadius") { b.cornerRadius = CGFloat(r) }
        if let c = IBValue.color(e.child(key: "borderColor", "color"), resources: resources) { b.borderColor = c }
        if let c = IBValue.color(e.child(key: "fillColor", "color"), resources: resources) { b.fillColor = c }
        if e.bool("transparent") == true { b.isTransparent = true }
        if let m = IBValue.size(e.child(key: "contentViewMargins", "size")) { b.contentViewMargins = m }
        if let f = IBValue.font(e.child(key: "titleFont", "font")) { b.titleFont = f }
        if let cv = e.child(key: "contentView"), let v = object(for: cv) as? NSView { b.contentView = v }
        addSubviews(b, e)
    }

    func decodeStackView(_ s: NSStackView, _ e: IBElement) {
        s.orientation = e["orientation"] == "vertical" ? .vertical : .horizontal
        let attrs: [String: NSLayoutConstraint.Attribute] = ["leading": .leading, "trailing": .trailing, "top": .top, "bottom": .bottom,
                                                              "centerX": .centerX, "centerY": .centerY, "firstBaseline": .firstBaseline,
                                                              "baseline": .lastBaseline, "lastBaseline": .lastBaseline, "left": .left,
                                                              "right": .right, "width": .width, "height": .height]
        if let a = e["alignment"].flatMap({ attrs[$0] }) { s.alignment = a }
        let dist: [String: NSStackView.Distribution] = ["gravityAreas": .gravityAreas, "fill": .fill, "fillEqually": .fillEqually,
                                                       "fillProportionally": .fillProportionally, "equalSpacing": .equalSpacing,
                                                       "equalCentering": .equalCentering]
        if let d = e["distribution"].flatMap({ dist[$0] }) { s.distribution = d }
        if let v = e.double("spacing") { s.spacing = CGFloat(v) }
        s.detachesHiddenViews = e.bool("detachesHiddenViews") ?? false
        if let i = IBValue.insets(e.child(key: "edgeInsets", "edgeInsets")) { s.edgeInsets = i }
        if let p = IBValue.priority(e["horizontalStackHuggingPriority"]) { s.setHuggingPriority(p, for: .horizontal) }
        if let p = IBValue.priority(e["verticalStackHuggingPriority"]) { s.setHuggingPriority(p, for: .vertical) }
        if let p = IBValue.priority(e["horizontalClippingResistancePriority"]) { s.setClippingResistancePriority(p, for: .horizontal) }
        if let p = IBValue.priority(e["verticalClippingResistancePriority"]) { s.setClippingResistancePriority(p, for: .vertical) }
        var arranged: [NSView] = []
        for sv in e.child("subviews")?.children ?? [] {
            sv.consumed = true
            if let v = object(for: sv) as? NSView { arranged.append(v); s.addArrangedSubview(v) }
        }
        for (key, g) in [("beginningViews", NSStackView.Gravity.leading), ("middleViews", .center), ("endViews", .trailing)] {
            for sv in e.child(key)?.children ?? [] {
                sv.consumed = true
                if let v = object(for: sv) as? NSView {
                    if let i = arranged.firstIndex(where: { $0 === v }) { arranged.remove(at: i); s.removeArrangedSubview(v); v.removeFromSuperview() }
                    s.addView(v, in: g)
                }
            }
        }
        let views = s.arrangedSubviews
        if let vp = e.child("visibilityPriorities") {
            for (i, p) in vp.children.enumerated() where i < views.count {
                p.consumed = true
                if let f = p.double("value") { s.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(f)), for: views[i]) }
            }
        }
        if let cs = e.child("customSpacing") {
            for (i, p) in cs.children.enumerated() where i < views.count {
                p.consumed = true
                if let f = p.double("value"), f < 3.0e38 { s.setCustomSpacing(CGFloat(f), after: views[i]) }
            }
        }
    }

    func decodeSplitView(_ s: NSSplitView, _ e: IBElement) {
        s.isVertical = e.bool("vertical") ?? false
        switch e["dividerStyle"] { case "thin": s.dividerStyle = .thin; case "paneSplitter": s.dividerStyle = .paneSplitter; default: break }
        if let a = e.bool("arrangesAllSubviews") { s.arrangesAllSubviews = a }
        if let n = e["autosaveName"] { s.autosaveName = n }
        addSubviews(s, e)
        if let hp = e.child("holdingPriorities") {
            for (i, p) in hp.children.enumerated() {
                p.consumed = true
                if let v = p.double("value") { s.setHoldingPriority(NSLayoutConstraint.Priority(Float(v)), forSubviewAt: i) }
            }
        }
    }

    func decodeTabView(_ t: NSTabView, _ e: IBElement) {
        let types: [String: NSTabView.TabType] = ["topTabsBezelBorder": .topTabsBezelBorder, "leftTabsBezelBorder": .leftTabsBezelBorder,
                                                 "bottomTabsBezelBorder": .bottomTabsBezelBorder, "rightTabsBezelBorder": .rightTabsBezelBorder,
                                                 "noTabsBezelBorder": .noTabsBezelBorder, "noTabsLineBorder": .noTabsLineBorder,
                                                 "noTabsNoBorder": .noTabsNoBorder]
        if let ty = e["type"].flatMap({ types[$0] }) { t.tabViewType = ty }
        if let f = IBValue.font(e.child(key: "font", "font")) { t.font = f }
        if let d = e.bool("drawsBackground") { t.drawsBackground = d }
        if let s = IBValue.controlSize(e["controlSize"]) { t.controlSize = s }
        if let a = e.bool("allowsTruncatedLabels") { t.allowsTruncatedLabels = a }
        _ = e["initialItem"]
        for item in e.child("tabViewItems")?.children("tabViewItem") ?? [] {
            let ti = NSTabViewItem(identifier: item["identifier"])
            if let id = item.id { objects[id] = ti; made.append(ti) }
            ti.label = localized(item, "label") ?? item["label"] ?? IBValue.string(item.child(key: "label", "string")) ?? ""
            _ = item.child(key: "label", "nil")
            if let tip = item["toolTip"] { ti.toolTip = tip }
            if let img = image(item) { ti.image = img }
            if let v = item.child(key: "view"), let view = object(for: v) as? NSView { ti.view = view }
            collectConnections(ti, item)
            t.addTabViewItem(ti)
        }
        if let initial = e["initialItem"], let ti = objects[initial] as? NSTabViewItem { t.selectTabViewItem(ti) }
    }

    func decodeGridView(_ g: NSGridView, _ e: IBElement) {
        let placements: [String: NSGridView.CellPlacement] = ["inherited": .inherited, "none": .none, "leading": .leading, "top": .top,
                                                              "trailing": .trailing, "bottom": .bottom, "center": .center, "fill": .fill]
        if let p = e["xPlacement"].flatMap({ placements[$0] }) { g.xPlacement = p }
        if let p = e["yPlacement"].flatMap({ placements[$0] }) { g.yPlacement = p }
        switch e["rowAlignment"] { case "firstBaseline": g.rowAlignment = .firstBaseline; case "lastBaseline": g.rowAlignment = .lastBaseline; case "none": g.rowAlignment = .none; default: break }
        if let v = e.double("rowSpacing") { g.rowSpacing = CGFloat(v) }
        if let v = e.double("columnSpacing") { g.columnSpacing = CGFloat(v) }
        let rows = e.child("rows")?.children("gridRow") ?? []
        let cols = e.child("columns")?.children("gridColumn") ?? []
        var contents: [String: NSView] = [:]
        var cellElements: [String: IBElement] = [:]
        for c in e.child("gridCells")?.children("gridCell") ?? [] {
            guard let r = c["row"], let col = c["column"] else { continue }
            cellElements[r + "|" + col] = c
            if let cv = c.child(key: "contentView"), let v = object(for: cv) as? NSView { contents[r + "|" + col] = v }
        }
        for (ri, r) in rows.enumerated() {
            let views = cols.map { contents[(r.id ?? "") + "|" + ($0.id ?? "")] ?? NSGridCell.emptyContentView }
            let row = g.addRow(with: views)
            if let id = r.id { objects[id] = row }
            if let p = r["yPlacement"].flatMap({ placements[$0] }) { row.yPlacement = p }
            if let v = r.double("height") { row.height = CGFloat(v) }
            if let v = r.double("topPadding") { row.topPadding = CGFloat(v) }
            if let v = r.double("bottomPadding") { row.bottomPadding = CGFloat(v) }
            if r.bool("hidden") == true { row.isHidden = true }
            _ = r["rowAlignment"]; _ = ri
        }
        for (ci, c) in cols.enumerated() where ci < g.numberOfColumns {
            let col = g.column(at: ci)
            if let id = c.id { objects[id] = col }
            if let p = c["xPlacement"].flatMap({ placements[$0] }) { col.xPlacement = p }
            if let v = c.double("width") { col.width = CGFloat(v) }
            if let v = c.double("leadingPadding") { col.leadingPadding = CGFloat(v) }
            if let v = c.double("trailingPadding") { col.trailingPadding = CGFloat(v) }
            if c.bool("hidden") == true { col.isHidden = true }
        }
        // Merged cells: every cell of a merge names its head.
        var merges: [String: (r0: Int, r1: Int, c0: Int, c1: Int)] = [:]
        for (ri, r) in rows.enumerated() {
            for (ci, c) in cols.enumerated() {
                guard let head = cellElements[(r.id ?? "") + "|" + (c.id ?? "")]?["headOfMergedCell"] else { continue }
                let m = merges[head] ?? (ri, ri, ci, ci)
                merges[head] = (min(m.r0, ri), max(m.r1, ri), min(m.c0, ci), max(m.c1, ci))
            }
        }
        for m in merges.values where m.r1 > m.r0 || m.c1 > m.c0 {
            g.mergeCells(inHorizontalRange: NSRange(location: m.c0, length: m.c1 - m.c0 + 1),
                         verticalRange: NSRange(location: m.r0, length: m.r1 - m.r0 + 1))
        }
        for (ri, r) in rows.enumerated() {
            for (ci, c) in cols.enumerated() {
                guard let ce = cellElements[(r.id ?? "") + "|" + (c.id ?? "")], ri < g.numberOfRows, ci < g.numberOfColumns else { continue }
                let cell = g.cell(atColumnIndex: ci, rowIndex: ri)
                if let id = ce.id { objects[id] = cell }
                if let p = ce["xPlacement"].flatMap({ placements[$0] }) { cell.xPlacement = p }
                if let p = ce["yPlacement"].flatMap({ placements[$0] }) { cell.yPlacement = p }
                _ = ce["rowAlignment"]
            }
        }
    }

    // MARK: Tables

    func decodeTableView(_ t: NSTableView, _ e: IBElement) {
        if let h = e.double("rowHeight") { t.rowHeight = CGFloat(h) }
        if e.bool("usesAutomaticRowHeights") == true { t.usesAutomaticRowHeights = true }
        if let s = IBValue.size(e.child(key: "intercellSpacing", "size")) { t.intercellSpacing = s }
        if let c = IBValue.color(e.child(key: "backgroundColor", "color"), resources: resources) { t.backgroundColor = c }
        if let c = IBValue.color(e.child(key: "gridColor", "color"), resources: resources) { t.gridColor = c }
        t.allowsMultipleSelection = e.bool("multipleSelection") ?? true
        if let v = e.bool("emptySelection") { t.allowsEmptySelection = v }
        if let v = e.bool("columnReordering") ?? e.bool("allowsColumnReordering") { t.allowsColumnReordering = v }
        if let v = e.bool("columnResizing") ?? e.bool("allowsColumnResizing") { t.allowsColumnResizing = v }
        if let v = e.bool("columnSelection") ?? e.bool("allowsColumnSelection") { t.allowsColumnSelection = v }
        if let v = e.bool("typeSelect") { t.allowsTypeSelect = v }
        if let v = e.bool("alternatingRowBackgroundColors") { t.usesAlternatingRowBackgroundColors = v }
        if let n = e["autosaveName"] { t.autosaveName = n }
        if let v = e.bool("autosaveColumns") { t.autosaveTableColumns = v }
        if let v = e.bool("floatsGroupRows") { t.floatsGroupRows = v }
        switch e["selectionHighlightStyle"] { case "none": t.selectionHighlightStyle = .none; case "sourceList": t.selectionHighlightStyle = .sourceList; default: break }
        switch e["tableStyle"] ?? e["style"] {
        case "fullWidth": t.style = .fullWidth
        case "inset": t.style = .inset
        case "sourceList": t.style = .sourceList
        case "plain": t.style = .plain
        default: break
        }
        switch e["rowSizeStyle"] {
        case "small": t.rowSizeStyle = .small
        case "medium": t.rowSizeStyle = .medium
        case "large": t.rowSizeStyle = .large
        case "custom": t.rowSizeStyle = .custom
        default: break
        }
        let resizing: [String: NSTableView.ColumnAutoresizingStyle] = [
            "none": .noColumnAutoresizing, "uniform": .uniformColumnAutoresizingStyle, "sequential": .sequentialColumnAutoresizingStyle,
            "reverseSequential": .reverseSequentialColumnAutoresizingStyle, "lastColumnOnly": .lastColumnOnlyAutoresizingStyle,
            "firstColumnOnly": .firstColumnOnlyAutoresizingStyle]
        if let r = e["columnAutoresizingStyle"] ?? e["columnAutoresizing"], let s = resizing[r] { t.columnAutoresizingStyle = s }
        if let g = e.child(key: "gridStyleMask") ?? e.child("tableViewGridLines") {
            var m: NSTableView.GridLineStyle = []
            if g.bool("horizontal") == true { m.insert(.solidHorizontalGridLineMask) }
            if g.bool("vertical") == true { m.insert(.solidVerticalGridLineMask) }
            if g.bool("dashedHorizontal") == true { m.insert(.dashedHorizontalGridLineMask) }
            t.gridStyleMask = m
        }
        _ = e["viewBased"]; _ = e["allowsExpansionToolTips"]; _ = e["columnSelection"]; _ = e["dataSource"]; _ = e["indentationMarkerFollowsCell"]
        for col in e.child("tableColumns")?.children("tableColumn") ?? [] {
            col.consumed = true
            if let c = object(for: col) as? NSTableColumn { t.addTableColumn(c) }
        }
        if let ov = t as? NSOutlineView {
            if let v = e.double("indentationPerLevel") { ov.indentationPerLevel = CGFloat(v) }
            if let v = e.bool("autosaveExpandedItems") { ov.autosaveExpandedItems = v }
            if let v = e.bool("autoresizesOutlineColumn") { ov.autoresizesOutlineColumn = v }
            if let id = e["outlineTableColumn"], let c = objects[id] as? NSTableColumn { ov.outlineTableColumn = c }
        }
        if let hid = e["headerView"] {
            if let h = t.headerView { objects[hid] = h }
            if let he = afterHeader[hid] {
                he.consumed = true
                _ = IBValue.rect(he.child(key: "frame")); _ = IBValue.autoresizingMask(he.child(key: "autoresizingMask")); _ = he["wantsLayer"]
            }
        } else if e.child(key: "headerView") == nil, t.enclosingScrollView != nil || e.parent?.parent?.name == "clipView" {
            // No header view in the document: the table has none.
            afterConnecting.append { [weak t] in if let t, t.headerView != nil, hidesHeader(t) { t.headerView = nil } }
        }
        func hidesHeader(_ t: NSTableView) -> Bool { e.attributes["headerView"] == nil }
        if let sd = e.child("sortDescriptors") { _ = sd }
    }

    func makeTableColumn(_ e: IBElement) -> NSTableColumn {
        if e["customClass"] != nil { report("custom NSTableColumn classes aren't instantiated; using NSTableColumn") }
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(e["identifier"] ?? ""))
        if let id = e.id { objects[id] = c; made.append(c) }
        collectConnections(c, e)
        if let w = e.double("width") { c.width = CGFloat(w) }
        if let w = e.double("minWidth") { c.minWidth = CGFloat(w) }
        if let w = e.double("maxWidth") { c.maxWidth = CGFloat(w) }
        if e.bool("hidden") == true { c.isHidden = true }
        if let ed = e.bool("editable") { c.isEditable = ed }
        if let tip = e["headerToolTip"] { c.headerToolTip = tip }
        if let h = e.child(key: "headerCell") {
            if let t = localized(h, "title") ?? h["title"] { c.title = t }
            _ = h["lineBreakMode"]; _ = h["borderStyle"]; _ = h["alignment"]; _ = h.child(key: "font"); _ = h.child(key: "textColor"); _ = h.child(key: "backgroundColor")
        }
        if let m = e.child(key: "resizingMask") {
            var r: NSTableColumn.ResizingOptions = []
            if m.bool("resizeWithTable") == true { r.insert(.autoresizingMask) }
            if m.bool("userResizable") == true { r.insert(.userResizingMask) }
            c.resizingMask = r
        }
        if let sd = e.child(key: "sortDescriptorPrototype") {
            // corelibs' NSSortDescriptor has no string keys.
            _ = sd["key"]; _ = sd["ascending"]; _ = sd["selector"]
        }
        // Cell-based tables' data cells: vestigial when the column has
        // view prototypes (Runway's tables are view-based).
        if e.child("prototypeCellViews") != nil { e.child(key: "dataCell")?.ignoreSubtree() }
        // View-based prototypes: nibs the table makes cell views from.
        for proto in e.child("prototypeCellViews")?.children ?? [] {
            proto.consumed = true
            let ident = proto.attributes["identifier"] ?? e.attributes["identifier"] ?? ""
            let nib = NSNib(prototype: proto, loader: self)
            pendingPrototypes.append((c, NSUserInterfaceItemIdentifier(ident), nib))
            if let id = proto.id { skip.insert(id) }
        }
        let protos = pendingPrototypes
        pendingPrototypes = []
        afterConnecting.append { [weak c] in
            guard let c, let t = c.tableView else { return }
            for (_, ident, nib) in protos { IBTableCellNibs.register(nib, t, ident, prototype: true) }
        }
        return c
    }

    // MARK: Windows

    func makeWindow(_ e: IBElement) -> NSWindow? {
        var style: NSWindow.StyleMask = []
        if let m = e.child(key: "styleMask") {
            let flags: [(String, NSWindow.StyleMask)] = [("titled", .titled), ("closable", .closable), ("miniaturizable", .miniaturizable),
                                                         ("resizable", .resizable), ("utility", .utilityWindow), ("nonactivatingPanel", .nonactivatingPanel),
                                                         ("fullSizeContentView", .fullSizeContentView), ("unifiedTitleAndToolbar", .unifiedTitleAndToolbar),
                                                         ("HUD", .hudWindow), ("docModal", .docModalWindow), ("texturedBackground", [])]
            for (k, f) in flags where m.bool(k) == true { style.insert(f) }
        }
        let content = IBValue.rect(e.child(key: "contentRect", "rect")) ?? CGRect(x: 0, y: 0, width: 480, height: 270)
        _ = IBValue.rect(e.child(key: "screenRect", "rect"))
        let fallback: NSWindow.Type = e.name == "panel" || e.attributes["customClass"] == "NSPanel" ? NSPanel.self : NSWindow.self
        let cls = classFor(e, NSWindow.self, fallback: fallback)
        let w: NSWindow
        func plain(_ t: NSWindow.Type) -> NSWindow {
            t == NSPanel.self ? NSPanel(contentRect: content, styleMask: style, backing: .buffered, defer: true)
                : NSWindow(contentRect: content, styleMask: style, backing: .buffered, defer: true)
        }
        if cls == NSWindow.self || cls == NSPanel.self {
            w = plain(cls)
        } else if let factory = ClassRegistry.windowFactory(for: cls), let made = factory(content, style.rawValue) as? NSWindow {
            w = made
        } else if let factory = IBWindowFactories.factory(for: cls) {
            w = factory(content, style)
        } else {
            report("can't make a \(cls) (no init(contentRect:styleMask:backing:defer:) registered): using \(fallback)")
            w = plain(fallback)
        }
        if let id = e.id { objects[id] = w; made.append(w) }
        collectConnections(w, e)
        w.title = localized(e, "title") ?? e["title"] ?? ""
        if let s = e["subtitle"] { w.subtitle = s }
        if let r = e.bool("releasedWhenClosed") { w.isReleasedWhenClosed = r } else { w.isReleasedWhenClosed = true }
        if let v = e.bool("allowsToolTipsWhenApplicationIsInactive") { w.allowsToolTipsWhenApplicationIsInactive = v }
        if let v = e.bool("autorecalculatesKeyViewLoop") { w.autorecalculatesKeyViewLoop = v }
        if let v = e.bool("hidesOnDeactivate") { w.hidesOnDeactivate = v }
        if let v = e.bool("titlebarAppearsTransparent") { w.titlebarAppearsTransparent = v }
        if e["titleVisibility"] == "hidden" { w.titleVisibility = .hidden }
        if let v = e.bool("hasShadow") { w.hasShadow = v }
        if let v = e.bool("movableByWindowBackground") { w.isMovableByWindowBackground = v }
        if let v = e.bool("restorable") { w.isRestorable = v }
        if let id = e["identifier"] { w.identifier = NSUserInterfaceItemIdentifier(id) }
        if let tm = e["tabbingMode"] { w.tabbingMode = tm == "disallowed" ? .disallowed : tm == "preferred" ? .preferred : .automatic }
        if let ti = e["tabbingIdentifier"] { w.tabbingIdentifier = ti }
        switch e["animationBehavior"] { case "none": w.animationBehavior = .none; case "documentWindow": w.animationBehavior = .documentWindow; case "utilityWindow": w.animationBehavior = .utilityWindow; case "alertPanel": w.animationBehavior = .alertPanel; default: break }
        switch e["level"] { case "floating": w.level = .floating; case "modalPanel": w.level = .modalPanel; case "statusBar": w.level = .statusBar; default: break }
        if let p = w as? NSPanel {
            if e.bool("isFloatingPanel") == true || e.bool("floatingPanel") == true { p.isFloatingPanel = true }
            if e.bool("becomesKeyOnlyIfNeeded") == true { p.becomesKeyOnlyIfNeeded = true }
            _ = e["worksWhenModal"]
        }
        if let c = IBValue.color(e.child(key: "backgroundColor", "color"), resources: resources) { w.backgroundColor = c }
        if let ap = e.child(key: "appearance") { w.appearance = appearance(ap) }
        if let cb = e.child(key: "collectionBehavior") {
            var b: NSWindow.CollectionBehavior = []
            for (k, f) in [("canJoinAllSpaces", NSWindow.CollectionBehavior.canJoinAllSpaces), ("moveToActiveSpace", .moveToActiveSpace),
                           ("managed", .managed), ("transient", .transient), ("stationary", .stationary),
                           ("participatesInCycle", .participatesInCycle), ("ignoresCycle", .ignoresCycle),
                           ("fullScreenPrimary", .fullScreenPrimary), ("fullScreenAuxiliary", .fullScreenAuxiliary),
                           ("fullScreenNone", .fullScreenNone)] where cb.bool(k) == true { b.insert(f) }
            w.collectionBehavior = b
        }
        // Where a window first opens is the window manager's (README: Window chrome).
        e.child(key: "initialPositionMask")?.ignoreSubtree(); e.child(key: "windowPositionMask")?.ignoreSubtree()
        _ = e.child(key: "windowCollectionBehavior")
        let separators: [String: NSWindow.TitlebarSeparatorStyle] = ["automatic": .automatic, "none": .none, "line": .line, "shadow": .shadow]
        if let s = e["separatorStyle"].flatMap({ separators[$0] }) { w.titlebarSeparatorStyle = s }
        let toolbarStyles: [String: NSWindow.ToolbarStyle] = ["automatic": .automatic, "expanded": .expanded, "preference": .preference,
                                                              "unified": .unified, "unifiedCompact": .unifiedCompact]
        if let ts = e["toolbarStyle"].flatMap({ toolbarStyles[$0] }) { w.toolbarStyle = ts }
        _ = e["oneShot"]; _ = e["frameAutosaveName"]
        _ = e["deferred"]; _ = e["showsToolbarButton"]; _ = e["visibleAtLaunch"]; _ = e["contentBorderThickness"]
        if let s = IBValue.size(e.child(key: "minSize")) { w.minSize = s }
        if let s = IBValue.size(e.child(key: "maxSize")) { w.maxSize = s }
        if let s = IBValue.size(e.child(key: "contentMinSize")) { w.contentMinSize = s }
        if let s = IBValue.size(e.child(key: "contentMaxSize")) { w.contentMaxSize = s }
        if let cv = e.child(key: "contentView"), let v = object(for: cv) as? NSView {
            v.frame = CGRect(origin: .zero, size: content.size)
            w.contentView = v
        }
        if let tb = e.child(key: "toolbar"), let toolbar = object(for: tb) as? NSToolbar { w.toolbar = toolbar }
        if let name = e["frameAutosaveName"], !name.isEmpty { w.setFrameAutosaveName(name) }
        if let ifr = e["initialFirstResponder"] {
            afterConnecting.append { [weak w, weak self] in if let v = self?.objects[ifr] as? NSView { w?.initialFirstResponder = v } }
        }
        if e.bool("visibleAtLaunch") ?? true { windowsToShow.append(w) }
        return w
    }

    // MARK: Menus

    func makeMenu(_ e: IBElement) -> NSMenu {
        let cls = classFor(e, NSMenu.self, fallback: NSMenu.self)
        let m = cls == NSMenu.self ? NSMenu(title: "") : cls.init(coder: IBCoder(e, self))
        m.title = localized(e, "title") ?? e["title"] ?? ""
        if let id = e.id { objects[id] = m; made.append(m) }
        collectConnections(m, e)
        if let a = e.bool("autoenablesItems") { m.autoenablesItems = a }
        if let f = IBValue.font(e.child(key: "font", "font")) { m.font = f }
        if let id = e["identifier"] { m.identifier = NSUserInterfaceItemIdentifier(id) }
        if let w = e.double("minimumWidth") { m.minimumWidth = CGFloat(w) }
        if let s = e.bool("showsStateColumn") { m.showsStateColumn = s }
        for i in e.child("items")?.children("menuItem") ?? [] {
            if let item = object(for: i) as? NSMenuItem { m.addItem(item) }
        }
        switch e["systemMenu"] {
        case "main": if isMainInterface || owner is NSApplication { NSApplication.shared.mainMenu = m }
        case "services": NSApplication.shared.servicesMenu = m
        case "window": NSApplication.shared.windowsMenu = m
        case "help": NSApplication.shared.helpMenu = m
        default: break
        }
        _ = e["userLabel"]
        return m
    }

    func makeMenuItem(_ e: IBElement) -> NSMenuItem {
        let item: NSMenuItem
        if e.bool("isSeparatorItem") == true {
            item = NSMenuItem.separator()
        } else {
            let cls = classFor(e, NSMenuItem.self, fallback: NSMenuItem.self)
            item = cls == NSMenuItem.self ? NSMenuItem(title: "", action: nil, keyEquivalent: "") : cls.init(coder: IBCoder(e, self))
            item.title = localized(e, "title") ?? IBValue.text(e, "title") ?? ""
            item.keyEquivalent = IBValue.text(e, "keyEquivalent") ?? ""
            _ = e["mirroring"]; _ = e["localization"]
        }
        if let id = e.id { objects[id] = item; made.append(item) }
        collectConnections(item, e)
        if let m = e.child(key: "keyEquivalentModifierMask", "modifierMask") { item.keyEquivalentModifierMask = modifiers(m) }
        else if item.keyEquivalent.isEmpty == false { item.keyEquivalentModifierMask = .command }
        if let t = e.int("tag") { item.tag = t }
        item.state = state(e["state"])
        if e.bool("hidden") == true { item.isHidden = true }
        if e.bool("enabled") == false { item.isEnabled = false }
        if e.bool("alternate") == true { item.isAlternate = true }
        if let l = e.int("indentationLevel") { item.indentationLevel = l }
        if let tip = localized(e, "toolTip") ?? e["toolTip"] { item.toolTip = tip }
        if let img = image(e) { item.image = img }
        if let img = image(e, "onStateImage") { item.onStateImage = img }
        if let img = image(e, "mixedStateImage") { item.mixedStateImage = img }
        if let id = e["identifier"] { item.identifier = NSUserInterfaceItemIdentifier(id) }
        if let at = e.child(key: "attributedTitle") { item.title = attributedText(at) }
        if let sub = e.child(key: "submenu", "menu"), let m = object(for: sub) as? NSMenu { item.submenu = m }
        if let v = e.child(key: "view"), let view = object(for: v) as? NSView { item.view = view }
        _ = e["userLabel"]
        return item
    }

    // MARK: Objects and controllers

    func makeCustomObject(_ e: IBElement) -> AnyObject? {
        let fallback: NSObject.Type = e.name == "userDefaultsController" ? NSUserDefaultsController.self : NSObject.self
        if e.name != "customObject" && e.name != "userDefaultsController" { report("<\(e.name)> (Cocoa bindings controller) stands in as NSObject") }
        let cls = classFor(e, NSObject.self, fallback: fallback)
        let o: NSObject
        if cls == NSUserDefaultsController.self { o = NSUserDefaultsController.shared }
        else if cls == NSObject.self { o = NSObject() }
        else if cls == NSFontManager.self { o = NSFontManager.shared }
        else if let made = ClassRegistry.factory(for: cls)?() as? NSObject { o = made }
        else {
            report("can't make a \(cls): no init() in the class registry (the build tool generates it)")
            missingClasses.append(String(reflecting: cls) + " (init)")
            o = NSObject()
        }
        if let id = e.id { objects[id] = o; made.append(o) }
        collectConnections(o, e)
        _ = e["representsSharedInstance"]
        return o
    }

    func decodeViewController(_ vc: NSViewController, _ e: IBElement) {
        if let t = localized(e, "title") ?? e["title"] { vc.title = t }
        if let id = e["identifier"] { vc.identifier = NSUserInterfaceItemIdentifier(id) }
        if let s = IBValue.size(e.child(key: "preferredContentSize", "size")) { vc.preferredContentSize = s }
        _ = e["storyboardIdentifier"]; _ = e["showSeguePresentationStyle"]
        IBStoryboardState.attach(vc, element: e, loader: self)
        if let sv = vc as? NSSplitViewController {
            if let s = e.child(key: "splitView"), let split = object(for: s) as? NSSplitView { sv.splitView = split }
            let items = e.child("splitViewItems")?.children("splitViewItem") ?? []
            IBStoryboardState.splitItems[ObjectIdentifier(sv)] = items
        }
        if let tv = vc as? NSTabViewController {
            switch e["tabStyle"] {
            case "segmentedControlOnBottom": tv.tabStyle = .segmentedControlOnBottom
            case "toolbar": tv.tabStyle = .toolbar
            case "unspecified": tv.tabStyle = .unspecified
            default: break
            }
            if let t = e.child(key: "tabView"), let tab = object(for: t) as? NSTabView { tv.tabView = tab }
            IBStoryboardState.tabItems[ObjectIdentifier(tv)] = e.child("tabViewItems")?.children("tabViewItem") ?? []
            if let i = e.int("selectedTabViewItemIndex") { afterConnecting.append { [weak tv] in if let tv, i < tv.tabViewItems.count { tv.selectedTabViewItemIndex = i } } }
        }
    }

    func decodeWindowController(_ wc: NSWindowController, _ e: IBElement) {
        IBStoryboardState.attach(wc, element: e, loader: self)
        if let s = e.bool("shouldCascadeWindows") { wc.shouldCascadeWindows = s }
        if let n = e["windowFrameAutosaveName"] { wc.windowFrameAutosaveName = n }
        _ = e["storyboardIdentifier"]; _ = e["showSeguePresentationStyle"]
    }

    func decodePopover(_ p: NSPopover, _ e: IBElement) {
        switch e["behavior"] { case "t": p.behavior = .transient; case "s": p.behavior = .semitransient; default: break }
        if let a = e.bool("animates") { p.animates = a }
        if let s = IBValue.size(e.child(key: "contentSize", "size")) { p.contentSize = s }
    }

    func decodeApplication(_ e: IBElement) {
        e.consumed = true
        isMainInterface = true
        if let m = e.child(key: "mainMenu", "menu"), let menu = object(for: m) as? NSMenu { NSApplication.shared.mainMenu = menu }
        if let c = e.child("connections") { queueConnections(c, NSApplication.shared) }
        _ = e["sceneMemberID"]; _ = e["id"]
    }

    // MARK: Toolbars

    func makeToolbar(_ e: IBElement) -> NSToolbar {
        let t = NSToolbar(identifier: NSToolbar.Identifier(e["implicitIdentifier"] ?? e["identifier"] ?? ""))
        if let id = e.id { objects[id] = t; made.append(t) }
        collectConnections(t, e)
        switch e["displayMode"] { case "iconOnly": t.displayMode = .iconOnly; case "labelOnly": t.displayMode = .labelOnly; case "iconAndLabel": t.displayMode = .iconAndLabel; default: break }
        if let v = e.bool("allowsUserCustomization") { t.allowsUserCustomization = v }
        if let v = e.bool("autosavesConfiguration") { t.autosavesConfiguration = v }
        if let v = e.bool("showsBaselineSeparator") { t.showsBaselineSeparator = v }
        _ = e["sizeMode"]; _ = e["prefersToBeShown"]; _ = e["centeredItem"]
        var allowed: [NSToolbarItem] = []
        for i in e.child("allowedToolbarItems")?.children("toolbarItem") ?? [] {
            if let item = object(for: i) as? NSToolbarItem { allowed.append(item) }
        }
        var defaults: [NSToolbarItem] = []
        for i in e.child("defaultToolbarItems")?.children("toolbarItem") ?? [] {
            i.consumed = true
            if let item = object(for: i) as? NSToolbarItem { defaults.append(item) }
        }
        IBToolbarProvider.install(t, allowed: allowed, defaults: defaults)
        return t
    }

    func makeToolbarItem(_ e: IBElement) -> NSToolbarItem? {
        let implicit = e["implicitItemIdentifier"]
        let ident = e["explicitItemIdentifier"] ?? implicit ?? e["itemIdentifier"] ?? e["identifier"] ?? ""
        let known: [String: NSToolbarItem.Identifier] = ["NSToolbarSpaceItem": .space, "NSToolbarFlexibleSpaceItem": .flexibleSpace,
                                                         "NSToolbarSeparatorItem": .separator, "NSToolbarToggleSidebarItem": .toggleSidebar,
                                                         "NSToolbarSidebarTrackingSeparatorItemIdentifier": .sidebarTrackingSeparator]
        let id = known[ident] ?? NSToolbarItem.Identifier(ident)
        if e["customClass"] != nil { report("custom NSToolbarItem classes aren't instantiated; using NSToolbarItem") }
        let item = NSToolbarItem(itemIdentifier: id)
        if let i = e.id { objects[i] = item; made.append(item) }
        collectConnections(item, e)
        item.label = localized(e, "label") ?? e["label"] ?? ""
        item.paletteLabel = localized(e, "paletteLabel") ?? e["paletteLabel"] ?? item.label
        if let tip = localized(e, "toolTip") ?? e["toolTip"] { item.toolTip = tip }
        if let t = e.int("tag") { item.tag = t }
        if let img = image(e) { item.image = img }
        if let b = e.bool("bordered") { item.isBordered = b }
        if let n = e.bool("navigational") { item.isNavigational = n }
        if let s = IBValue.size(e.child(key: "minSize", "size")) { item.minSize = s }
        if let s = IBValue.size(e.child(key: "maxSize", "size")) { item.maxSize = s }
        if let v = e.children.first(where: { $0.attributes["key"] == "view" }) { v.consumed = true; item.view = object(for: v) as? NSView }
        _ = e.child(key: "toolTip", "nil"); _ = e["sizingBehavior"]; _ = e["autovalidates"]; _ = e["selectable"]
        return item
    }
}

/// Header views IB describes under a scroll view, matched by id once the
/// table (which makes its own) decodes.
@MainActor private var afterHeaderStore: [ObjectIdentifier: [String: IBElement]] = [:]
@MainActor private var prototypeStore: [ObjectIdentifier: [(NSTableColumn, NSUserInterfaceItemIdentifier, NSNib)]] = [:]
extension IBLoader {
    var afterHeader: [String: IBElement] {
        get { afterHeaderStore[ObjectIdentifier(self)] ?? [:] }
        set { afterHeaderStore[ObjectIdentifier(self)] = newValue }
    }
    var pendingPrototypes: [(NSTableColumn, NSUserInterfaceItemIdentifier, NSNib)] {
        get { prototypeStore[ObjectIdentifier(self)] ?? [] }
        set { prototypeStore[ObjectIdentifier(self)] = newValue }
    }
}

/// Factories for an app's NSWindow subclasses (nib windows are made with
/// `init(contentRect:styleMask:backing:defer:)`, which a Swift metatype
/// can't call unless it's `required`). The generated class table or the app
/// can register them.
@preconcurrency @MainActor public enum IBWindowFactories {
    static var factories: [ObjectIdentifier: (CGRect, NSWindow.StyleMask) -> NSWindow] = [:]
    public static func register(_ cls: NSWindow.Type, _ make: @escaping (CGRect, NSWindow.StyleMask) -> NSWindow) {
        factories[ObjectIdentifier(cls)] = make
    }
    static func factory(for cls: NSWindow.Type) -> ((CGRect, NSWindow.StyleMask) -> NSWindow)? { factories[ObjectIdentifier(cls)] }
}

/// Supplies an IB toolbar's items (Cocoa's toolbars from nibs need no
/// delegate); identifiers it doesn't know go to the app's delegate.
@MainActor final class IBToolbarProvider: NSObject, NSToolbarDelegate {
    var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    var defaults: [NSToolbarItem.Identifier] = []
    var allowed: [NSToolbarItem.Identifier] = []
    weak var appDelegate: NSToolbarDelegate?
    static var providers: [ObjectIdentifier: IBToolbarProvider] = [:]

    static func install(_ t: NSToolbar, allowed: [NSToolbarItem], defaults: [NSToolbarItem]) {
        let p = IBToolbarProvider()
        for i in allowed + defaults { p.items[i.itemIdentifier] = i }
        p.allowed = allowed.map(\.itemIdentifier)
        p.defaults = defaults.map(\.itemIdentifier)
        providers[ObjectIdentifier(t)] = p
        t.delegate = p
    }
    static func provider(_ t: NSToolbar) -> IBToolbarProvider? { providers[ObjectIdentifier(t)] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        items[id] ?? appDelegate?.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: flag)
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        defaults.isEmpty ? (appDelegate?.toolbarDefaultItemIdentifiers(toolbar) ?? []) : defaults
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        allowed + (appDelegate?.toolbarAllowedItemIdentifiers(toolbar) ?? [])
    }
}
