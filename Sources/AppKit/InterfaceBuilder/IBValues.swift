// Values in Interface Builder documents: geometry, colours (calibrated,
// sRGB, catalog/system and named asset colours), fonts (meta fonts, named
// fonts, text styles), images (asset catalog, bundle files, AppKit's named
// images, SF Symbols), strings (plain, base64, localized) and enum spellings.

import Foundation
import RunwayCore

@MainActor
enum IBValue {
    // MARK: Geometry

    static func rect(_ e: IBElement?) -> CGRect? {
        guard let e else { return nil }
        return CGRect(x: e.double("x") ?? 0, y: e.double("y") ?? 0, width: e.double("width") ?? 0, height: e.double("height") ?? 0)
    }
    static func size(_ e: IBElement?) -> CGSize? {
        guard let e else { return nil }
        _ = e["type"]
        return CGSize(width: e.double("width") ?? 0, height: e.double("height") ?? 0)
    }
    static func point(_ e: IBElement?) -> CGPoint? {
        guard let e else { return nil }
        return CGPoint(x: e.double("x") ?? 0, y: e.double("y") ?? 0)
    }
    static func insets(_ e: IBElement?) -> NSEdgeInsets? {
        guard let e else { return nil }
        return NSEdgeInsets(top: e.double("top") ?? 0, left: e.double("left") ?? 0, bottom: e.double("bottom") ?? 0, right: e.double("right") ?? 0)
    }

    static func autoresizingMask(_ e: IBElement?) -> NSView.AutoresizingMask? {
        guard let e else { return nil }
        var m: NSView.AutoresizingMask = []
        if e.bool("flexibleMinX") == true { m.insert(.minXMargin) }
        if e.bool("widthSizable") == true { m.insert(.width) }
        if e.bool("flexibleMaxX") == true { m.insert(.maxXMargin) }
        if e.bool("flexibleMinY") == true { m.insert(.minYMargin) }
        if e.bool("heightSizable") == true { m.insert(.height) }
        if e.bool("flexibleMaxY") == true { m.insert(.maxYMargin) }
        return m
    }

    static func priority(_ s: String?) -> NSLayoutConstraint.Priority? {
        guard let s, let v = Float(s) else { return nil }
        return NSLayoutConstraint.Priority(v)
    }

    // MARK: Strings

    /// A `<string key="…">` child: plain text, or base64 (`base64-UTF8="YES"`,
    /// e.g. key equivalents like Return).
    static func string(_ e: IBElement?) -> String? {
        guard let e else { return nil }
        if e.bool("base64-UTF8") == true {
            var b = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
            while b.count % 4 != 0 { b += "=" }
            return Data(base64Encoded: b).map { String(decoding: $0, as: UTF8.self) }
        }
        return e.text
    }

    /// An attribute string or a `<string key=…>` child.
    static func text(_ e: IBElement, _ key: String) -> String? {
        if let a = e[key] { return a }
        return string(e.child(key: key, "string"))
    }

    // MARK: Colours

    static func color(_ e: IBElement?, resources: IBElement? = nil) -> NSColor? {
        guard let e else { return nil }
        if let sys = e["systemColor"] { return systemColor(sys) ?? resourceColor(sys, resources) }
        if let name = e["name"] {
            let catalog = e["catalog"]
            if catalog == "System" || catalog == nil, let c = systemColor(name) { return c }
            if let c = assetColor(name) { return c }
            if let c = resourceColor(name, resources) { return c }
            return systemColor(name) ?? .labelColor
        }
        let a = CGFloat(e.double("alpha") ?? 1)
        if let w = e.double("white") { return NSColor(white: CGFloat(w), alpha: a) }
        if let r = e.double("red") {
            return NSColor(srgbRed: CGFloat(r), green: CGFloat(e.double("green") ?? 0), blue: CGFloat(e.double("blue") ?? 0), alpha: a)
        }
        if let c = e.double("cyan") {
            let m = e.double("magenta") ?? 0, y = e.double("yellow") ?? 0, k = e.double("black") ?? 0
            return NSColor(srgbRed: CGFloat((1 - c) * (1 - k)), green: CGFloat((1 - m) * (1 - k)), blue: CGFloat((1 - y) * (1 - k)), alpha: a)
        }
        _ = e["colorSpace"]; _ = e["customColorSpace"]
        return nil
    }

    /// An asset catalog colour set, following light/dark.
    static func assetColor(_ name: String) -> NSColor? {
        guard let c = RunwayAssets.color(named: name) else { return nil }
        let l = c.light, d = c.dark
        return NSColor(name: name) { ap in
            let v = ap.isDark ? d : l
            return NSColor(srgbRed: CGFloat(v.red), green: CGFloat(v.green), blue: CGFloat(v.blue), alpha: CGFloat(v.alpha))
        }
    }

    /// A colour the document's `<resources>` defines (`<namedColor>`, `<systemColor>`).
    static func resourceColor(_ name: String, _ resources: IBElement?) -> NSColor? {
        guard let r = resources else { return nil }
        for c in r.children where (c.name == "namedColor" || c.name == "systemColor") && c.attributes["name"] == name {
            c.consumed = true
            _ = c["name"]
            return color(c.child("color"))
        }
        return nil
    }

    static func systemColor(_ raw: String) -> NSColor? {
        var n = raw
        if n.hasSuffix("Color") && n != "Color" { n = String(n.dropLast(5)) }
        return systemColors[n]
    }

    /// AppKit's catalog ("System") colours by name, without "Color".
    static let systemColors: [String: NSColor] = [
        "label": .labelColor, "controlText": .controlTextColor, "headerText": .headerTextColor, "windowFrameText": .labelColor,
        "secondaryLabel": .secondaryLabelColor, "tertiaryLabel": .tertiaryLabelColor, "quaternaryLabel": .quaternaryLabelColor,
        "text": .textColor, "selectedText": .selectedTextColor, "selectedControlText": .textColor, "selectedMenuItemText": .white,
        "alternateSelectedControlText": .white, "placeholderText": .placeholderTextColor, "disabledControlText": .disabledControlTextColor,
        "textBackground": .textBackgroundColor, "controlBackground": .controlBackgroundColor,
        "selectedTextBackground": .selectedTextBackgroundColor, "unemphasizedSelectedTextBackground": .unemphasizedSelectedContentBackgroundColor,
        "windowBackground": .windowBackgroundColor, "underPageBackground": .underPageBackgroundColor,
        "control": .controlColor, "controlHighlight": .controlColor, "controlLightHighlight": .controlColor, "scrollBar": .controlColor, "knob": .controlColor,
        "selectedKnob": .controlAccentColor, "controlAccent": .controlAccentColor, "alternateSelectedControl": .controlAccentColor,
        "selectedControl": .selectedTextBackgroundColor, "highlight": .white, "keyboardFocusIndicator": .keyboardFocusIndicatorColor,
        "selectedContentBackground": .selectedContentBackgroundColor, "selectedMenuItem": .selectedContentBackgroundColor,
        "unemphasizedSelectedContentBackground": .unemphasizedSelectedContentBackgroundColor,
        "secondarySelectedControl": .unemphasizedSelectedContentBackgroundColor,
        "separator": .separatorColor, "gridLine": .separatorColor, "grid": .gridColor, "link": .linkColor, "findHighlight": .findHighlightColor,
        "shadow": .shadowColor, "controlDarkShadow": .shadowColor, "controlShadow": .gray,
        "systemFill": .systemFill, "secondarySystemFill": .secondarySystemFill, "tertiarySystemFill": .tertiarySystemFill,
        "quaternarySystemFill": .quaternarySystemFill, "quinarySystemFill": .quinarySystemFill,
        "systemRed": .systemRed, "systemOrange": .systemOrange, "systemYellow": .systemYellow, "systemGreen": .systemGreen,
        "systemMint": .systemMint, "systemTeal": .systemTeal, "systemCyan": .systemCyan, "systemBlue": .systemBlue,
        "systemIndigo": .systemIndigo, "systemPurple": .systemPurple, "systemPink": .systemPink, "systemBrown": .systemBrown,
        "systemGray": .systemGray, "clear": .clear, "black": .black, "white": .white, "gray": .gray, "darkGray": .darkGray,
        "lightGray": .lightGray, "red": .red, "green": .green, "blue": .blue, "orange": .orange, "yellow": .yellow,
        "purple": .purple, "brown": .brown, "cyan": .cyan, "magenta": .magenta,
    ]

    // MARK: Fonts

    static func font(_ e: IBElement?) -> NSFont? {
        guard let e else { return nil }
        let size = e.double("size").map { CGFloat($0) }
        if let meta = e["metaFont"] {
            switch meta {
            case "system", "message", "controlContent", "user", "menu", "menuBar":
                return .systemFont(ofSize: size ?? 13)
            case "systemBold", "titleBar": return .boldSystemFont(ofSize: size ?? 13)
            case "smallSystem", "toolTip", "palette": return .systemFont(ofSize: size ?? 11)
            case "smallSystemBold": return .boldSystemFont(ofSize: size ?? 11)
            case "miniSystem": return .systemFont(ofSize: size ?? 9)
            case "miniSystemBold": return .boldSystemFont(ofSize: size ?? 9)
            case "label": return .systemFont(ofSize: size ?? 10)
            case "fixedUser", "userFixedPitch", "fixedSystem": return .monospacedSystemFont(ofSize: size ?? 11, weight: .regular)
            default: return .systemFont(ofSize: size ?? 13)
            }
        }
        if let style = e["textStyle"] {
            let s: NSFont.TextStyle = switch style {
            case "largeTitle": .largeTitle
            case "title1": .title1
            case "title2": .title2
            case "title3": .title3
            case "headline": .headline
            case "subheadline": .subheadline
            case "callout": .callout
            case "footnote": .footnote
            case "caption1": .caption1
            case "caption2": .caption2
            default: .body
            }
            return .preferredFont(forTextStyle: s)
        }
        guard let name = e["name"] else { return size.map { .systemFont(ofSize: $0) } }
        return named(name, size: size ?? 13)
    }

    /// A PostScript font name ("Menlo-Bold", ".AppleSystemUIFontBold",
    /// "SFMono-Regular") as a family, weight and design.
    static func named(_ name: String, size: CGFloat) -> NSFont {
        var family = name, styleName = ""
        if let dash = name.lastIndex(of: "-") { family = String(name[..<dash]); styleName = String(name[name.index(after: dash)...]) }
        var weight: FontWeightValue = .regular
        var italic = false
        let st = styleName.lowercased() + (family.hasPrefix(".") ? family.lowercased() : "")
        for (k, w) in [("ultralight", FontWeightValue.ultraLight), ("thin", .thin), ("light", .light), ("medium", .medium),
                       ("semibold", .semibold), ("demibold", .semibold), ("heavy", .heavy), ("black", .black), ("bold", .bold)] where st.contains(k) {
            weight = w; break
        }
        if st.contains("italic") || st.contains("oblique") { italic = true }
        if family.hasPrefix(".") || family.hasPrefix("SFPro") || family.hasPrefix("SFNS") {
            let design: FontDesignValue = family.contains("Rounded") ? .rounded : family.contains("Serif") ? .serif : family.contains("Mono") ? .monospaced : .default
            return NSFont(spec: FontSpec(size: size, weight: weight, design: design, italic: italic))
        }
        if family.hasPrefix("SFMono") || family == "Menlo" || family == "Monaco" || family == "Courier" || family == "CourierNewPSMT" {
            return NSFont(spec: FontSpec(size: size, weight: weight, design: .monospaced, italic: italic))
        }
        return NSFont(spec: FontSpec(size: size, weight: weight, italic: italic, family: family))
    }

    // MARK: Images

    /// `<image name="…" catalog="system">` and `image="…"` attributes.
    static func image(named name: String?, catalog: String? = nil) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if catalog == "system" { return NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        if let p = RunwayAssets.imagePath(named: name) {
            let img = NSImage(contentsOf: URL(fileURLWithPath: p))
            if RunwayAssets.isTemplate(named: name) { img?.isTemplate = true }
            return img
        }
        if let img = NSImage(named: name) { return img }
        for ext in ["png", "pdf", "jpg", "jpeg", "tiff", "icns", "gif", "svg"] {
            if let u = Bundle.main.url(forResource: name, withExtension: ext) ?? IBDocument.locate(name, extensions: [ext], bundle: .main) {
                if let img = NSImage(contentsOf: u) { return img }
            }
        }
        if let sym = appKitImageSymbols[name] {
            let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            img?.isTemplate = true
            return img
        }
        // SF Symbol names used without a catalog.
        if name.contains("."), let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) { return img }
        return nil
    }

    /// AppKit's named images (NSImage.Name constants) as SF Symbols.
    static let appKitImageSymbols: [String: String] = [
        "NSActionTemplate": "gearshape", "NSAddTemplate": "plus", "NSRemoveTemplate": "minus",
        "NSAdvanced": "gearshape.2", "NSPreferencesGeneral": "gearshape", "NSUser": "person", "NSUserGroup": "person.2",
        "NSUserAccounts": "person.crop.circle", "NSEveryone": "person.3", "NSInfo": "info.circle", "NSCaution": "exclamationmark.triangle",
        "NSStopProgressTemplate": "xmark", "NSStopProgressFreestandingTemplate": "xmark.circle", "NSRefreshTemplate": "arrow.clockwise",
        "NSRefreshFreestandingTemplate": "arrow.clockwise.circle", "NSGoForwardTemplate": "chevron.right", "NSGoBackTemplate": "chevron.left",
        "NSGoRightTemplate": "chevron.right", "NSGoLeftTemplate": "chevron.left", "NSFolder": "folder", "NSFolderSmart": "folder.badge.gearshape",
        "NSHomeTemplate": "house", "NSShareTemplate": "square.and.arrow.up", "NSBookmarksTemplate": "book", "NSLockLockedTemplate": "lock",
        "NSLockUnlockedTemplate": "lock.open", "NSMenuOnStateTemplate": "checkmark", "NSMenuMixedStateTemplate": "minus",
        "NSStatusAvailable": "circle.fill", "NSStatusNone": "circle", "NSTouchBarAddTemplate": "plus", "NSRevealFreestandingTemplate": "magnifyingglass",
        "NSFollowLinkFreestandingTemplate": "arrow.right.circle", "NSInvalidDataFreestandingTemplate": "exclamationmark.circle",
        "NSQuickLookTemplate": "eye", "NSSmartBadgeTemplate": "gearshape", "NSIconViewTemplate": "square.grid.2x2",
        "NSListViewTemplate": "list.bullet", "NSColumnViewTemplate": "rectangle.split.3x1", "NSFlowViewTemplate": "rectangle.grid.1x2",
        "NSPathTemplate": "folder", "NSEnterFullScreenTemplate": "arrow.up.left.and.arrow.down.right",
        "NSExitFullScreenTemplate": "arrow.down.right.and.arrow.up.left", "NSComputer": "desktopcomputer", "NSNetwork": "network",
        "NSBonjour": "bonjour", "NSApplicationIcon": "app", "NSTrashEmpty": "trash", "NSTrashFull": "trash.fill",
        "NSColorPanel": "paintpalette", "NSFontPanel": "textformat", "NSSlideshowTemplate": "play.rectangle",
        "NSTouchBarSearchTemplate": "magnifyingglass", "NSMultipleDocuments": "doc.on.doc", "NSMobileMe": "icloud",
        "NSDotMac": "icloud", "NSStatusPartiallyAvailable": "circle.lefthalf.filled", "NSStatusUnavailable": "circle.slash",
        "NSRightFacingTriangleTemplate": "arrowtriangle.right.fill", "NSLeftFacingTriangleTemplate": "arrowtriangle.left.fill",
    ]

    // MARK: Enum spellings

    static func alignment(_ s: String?) -> NSTextAlignment? {
        switch s {
        case "left": return .left
        case "right": return .right
        case "center": return .center
        case "justified": return .justified
        case "natural": return .natural
        default: return nil
        }
    }

    static func lineBreakMode(_ s: String?) -> NSLineBreakMode? {
        switch s {
        case "wordWrapping": return .byWordWrapping
        case "charWrapping": return .byCharWrapping
        case "clipping": return .byClipping
        case "truncatingHead": return .byTruncatingHead
        case "truncatingTail": return .byTruncatingTail
        case "truncatingMiddle": return .byTruncatingMiddle
        default: return nil
        }
    }

    static func controlSize(_ s: String?) -> NSControl.ControlSize? {
        switch s {
        case "regular": return .regular
        case "small": return .small
        case "mini": return .mini
        case "large": return .large
        case "extraLarge": return .extraLarge
        default: return nil
        }
    }

    static func layoutAttribute(_ s: String?) -> NSLayoutConstraint.Attribute? {
        switch s {
        case "left": return .left
        case "right": return .right
        case "top": return .top
        case "bottom": return .bottom
        case "leading": return .leading
        case "trailing": return .trailing
        case "width": return .width
        case "height": return .height
        case "centerX": return .centerX
        case "centerY": return .centerY
        case "baseline", "lastBaseline": return .lastBaseline
        case "firstBaseline": return .firstBaseline
        case "notAnAttribute": return .notAnAttribute
        // Margin attributes have no separate solver variables here: the
        // view's edge (the margin is added by IB as a constant).
        case "leftMargin": return .left
        case "rightMargin": return .right
        case "topMargin": return .top
        case "bottomMargin": return .bottom
        case "leadingMargin": return .leading
        case "trailingMargin": return .trailing
        case "centerXWithinMargins": return .centerX
        case "centerYWithinMargins": return .centerY
        default: return nil
        }
    }

    static func imageScaling(_ s: String?) -> NSImageScaling? {
        switch s {
        case "proportionallyDown": return .scaleProportionallyDown
        case "axesIndependently": return .scaleAxesIndependently
        case "none": return NSImageScaling.scaleNone
        case "proportionallyUpOrDown": return .scaleProportionallyUpOrDown
        default: return nil
        }
    }

    static func imagePosition(_ s: String?) -> NSControl.ImagePosition? {
        switch s {
        case "noImage": return .noImage
        case "only": return .imageOnly
        case "left": return .imageLeft
        case "right": return .imageRight
        case "below": return .imageBelow
        case "above": return .imageAbove
        case "overlaps": return .imageOverlaps
        case "leading": return .imageLeading
        case "trailing": return .imageTrailing
        default: return nil
        }
    }

    static func bezelStyle(_ s: String?) -> NSButton.BezelStyle? {
        switch s {
        case "rounded", "push": return .rounded
        case "regularSquare": return .regularSquare
        case "disclosure", "disclosureTriangle": return .disclosure
        case "shadowlessSquare", "square": return .shadowlessSquare
        case "circular": return .circular
        case "texturedSquare": return .texturedSquare
        case "helpButton": return .helpButton
        case "smallSquare": return .smallSquare
        case "texturedRounded": return .texturedRounded
        case "roundRect", "roundedRect": return .roundRect
        case "recessed": return .recessed
        case "roundedDisclosure": return .roundedDisclosure
        case "inline": return .inline
        case "bevel": return .regularSquare
        case "flexiblePush": return .regularSquare
        default: return nil
        }
    }
}
