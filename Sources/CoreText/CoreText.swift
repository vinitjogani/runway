// CoreText for Linux (Pango + HarfBuzz + fontconfig, drawn with Cairo):
// fonts and descriptors, lines, framesetters and frames over attributed
// strings, measuring (typographic bounds, suggested frame sizes) and drawing
// into CGContexts at the device scale, and the font manager (available
// families, registering font files with fontconfig). On Windows the same API
// measures with estimates and draws nothing.
//
// Attributes are read without AppKit: fonts from CTFont, anything that
// adopts CTFontRepresentable (AppKit's NSFont should), or an object with a
// RunwayCore `FontSpec` stored as `spec`; colours from CGColor or
// CGColorRepresentable (NSColor should adopt it).

@_exported import CoreGraphics
@_exported import Foundation
@_exported import RunwayFoundation
import RunwayCore
#if os(Linux)
import CPangoCairo
#endif

// MARK: Ranges and keys


public let kCTFontAttributeName: CFString = "NSFont"
public let kCTForegroundColorAttributeName: CFString = "CTForegroundColor"
public let kCTForegroundColorFromContextAttributeName: CFString = "CTForegroundColorFromContext"
public let kCTParagraphStyleAttributeName: CFString = "NSParagraphStyle"
public let kCTKernAttributeName: CFString = "NSKern"
public let kCTUnderlineStyleAttributeName: CFString = "NSUnderline"
public let kCTStrokeWidthAttributeName: CFString = "NSStrokeWidth"
public let kCTFontFamilyNameAttribute: CFString = "NSFontFamilyAttribute"
public let kCTFontNameAttribute: CFString = "NSFontNameAttribute"
public let kCTFontDisplayNameAttribute: CFString = "NSFontVisibleNameAttribute"
public let kCTFontStyleNameAttribute: CFString = "NSFontFaceAttribute"
public let kCTFontSizeAttribute: CFString = "NSFontSizeAttribute"
public let kCTFontTraitsAttribute: CFString = "NSCTFontTraitsAttribute"
public let kCTFontWeightTrait: CFString = "NSCTFontWeightTrait"
public let kCTFontWidthTrait: CFString = "NSCTFontProportionTrait"
public let kCTFontSlantTrait: CFString = "NSCTFontSlantTrait"
public let kCTFontSymbolicTrait: CFString = "NSCTFontSymbolicTrait"
public let kCTFontURLAttribute: CFString = "NSCTFontFileURLAttribute"
public let kCTFontFeatureSettingsAttribute: CFString = "NSCTFontFeatureSettingsAttribute"

public struct CTFontSymbolicTraits: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let traitItalic = Self(rawValue: 1), traitBold = Self(rawValue: 2), traitExpanded = Self(rawValue: 1 << 5)
    public static let traitCondensed = Self(rawValue: 1 << 6), traitMonoSpace = Self(rawValue: 1 << 10), traitVertical = Self(rawValue: 1 << 11)
    public static let traitUIOptimized = Self(rawValue: 1 << 12), traitColorGlyphs = Self(rawValue: 1 << 13)
}
public enum CTFontUIFontType: UInt32, Sendable {
    case none = 4294967295, user = 0, userFixedPitch = 1, system = 2, emphasizedSystem = 3, smallSystem = 4, smallEmphasizedSystem = 5
    case miniSystem = 6, miniEmphasizedSystem = 7, views = 8, application = 9, label = 10, menuTitle = 11, menuItem = 12
    case menuItemMark = 13, menuItemCmdKey = 14, windowTitle = 15, pushButton = 16, utilityWindowTitle = 17, alertHeader = 18
    case systemDetail = 19, emphasizedSystemDetail = 20, toolbar = 21, smallToolbar = 22, message = 23, palette = 24, toolTip = 25, controlContent = 26
}
public enum CTTextAlignment: UInt8, Sendable { case left = 0, right, center, justified, natural }
public enum CTLineBreakMode: UInt8, Sendable { case byWordWrapping = 0, byCharWrapping, byClipping, byTruncatingHead, byTruncatingTail, byTruncatingMiddle }
public enum CTFontManagerScope: UInt32, Sendable { case none = 0, process, persistent, session, user }
public typealias CGGlyph = UInt16

// MARK: Fonts

/// Something that stands for a font in attribute dictionaries (AppKit's NSFont should adopt it).
public protocol CTFontRepresentable {
    var ctFont: CTFont { get }
}

public final class CTFont: @unchecked Sendable, Hashable, CTFontRepresentable {
    /// nil: the system UI font.
    public let family: String?
    public let size: CGFloat
    /// 100…900, CSS-style.
    public let weight: Int
    public let italic: Bool
    public let monospaced: Bool
    public var ctFont: CTFont { self }

    public init(family: String?, size: CGFloat, weight: Int = 400, italic: Bool = false, monospaced: Bool = false) {
        self.family = family; self.size = size > 0 ? size : 12; self.weight = weight; self.italic = italic; self.monospaced = monospaced
    }
    convenience init(spec: FontSpec) {
        let family: String? = switch spec.design {
        case .monospaced: "Monospace"
        case .serif: "Serif"
        default: spec.family
        }
        self.init(family: family, size: spec.size, weight: spec.weight.rawValue, italic: spec.italic, monospaced: spec.design == .monospaced)
    }

    /// Reads a font out of an attribute value.
    public static func from(_ value: Any?) -> CTFont? {
        guard let value else { return nil }
        if let f = value as? CTFont { return f }
        if let r = value as? CTFontRepresentable { return r.ctFont }
        for child in Mirror(reflecting: value).children where child.label == "spec" {
            if let spec = child.value as? FontSpec { return CTFont(spec: spec) }
        }
        return nil
    }

    var pangoFamily: String {
        guard let f = family, !f.isEmpty, f != "System", !f.hasPrefix(".") else { return monospaced ? "Monospace" : "Sans" }
        return f
    }

    public static func == (a: CTFont, b: CTFont) -> Bool {
        a.family == b.family && a.size == b.size && a.weight == b.weight && a.italic == b.italic && a.monospaced == b.monospaced
    }
    public func hash(into h: inout Hasher) { h.combine(family); h.combine(size); h.combine(weight); h.combine(italic) }

    /// Ascent, descent and leading from the font's metrics.
    var metrics: (ascent: CGFloat, descent: CGFloat, leading: CGFloat) { Pango.metrics(self) }
}

public func CTFontCreateWithName(_ name: CFString, _ size: CGFloat, _ matrix: UnsafePointer<CGAffineTransform>?) -> CTFont {
    let n = String(describing: name)
    let bold = n.lowercased().contains("bold")
    return CTFont(family: n.split(separator: "-").first.map(String.init) ?? n, size: size, weight: bold ? 700 : 400, italic: n.lowercased().contains("italic"))
}
public func CTFontCreateUIFontForLanguage(_ type: CTFontUIFontType, _ size: CGFloat, _ language: CFString?) -> CTFont? {
    let s = size > 0 ? size : 13
    switch type {
    case .emphasizedSystem, .smallEmphasizedSystem, .miniEmphasizedSystem, .emphasizedSystemDetail, .alertHeader: return CTFont(family: nil, size: s, weight: 700)
    case .userFixedPitch: return CTFont(family: "Monospace", size: s, monospaced: true)
    default: return CTFont(family: nil, size: s)
    }
}
public func CTFontCreateWithFontDescriptor(_ d: CTFontDescriptor, _ size: CGFloat, _ matrix: UnsafePointer<CGAffineTransform>?) -> CTFont { d.font(size: size) }
public func CTFontCreateCopyWithAttributes(_ f: CTFont, _ size: CGFloat, _ matrix: UnsafePointer<CGAffineTransform>?, _ attributes: CTFontDescriptor?) -> CTFont {
    attributes?.font(size: size > 0 ? size : f.size) ?? CTFont(family: f.family, size: size > 0 ? size : f.size, weight: f.weight, italic: f.italic, monospaced: f.monospaced)
}
public func CTFontCreateCopyWithSymbolicTraits(_ f: CTFont, _ size: CGFloat, _ matrix: UnsafePointer<CGAffineTransform>?, _ value: CTFontSymbolicTraits,
                                               _ mask: CTFontSymbolicTraits) -> CTFont? {
    CTFont(family: f.family, size: size > 0 ? size : f.size, weight: value.contains(.traitBold) ? 700 : (mask.contains(.traitBold) ? 400 : f.weight),
           italic: value.contains(.traitItalic) || (!mask.contains(.traitItalic) && f.italic), monospaced: value.contains(.traitMonoSpace) || f.monospaced)
}
public func CTFontGetSize(_ f: CTFont) -> CGFloat { f.size }
public func CTFontCopyFamilyName(_ f: CTFont) -> CFString { NSString(string: f.family ?? Pango.systemFamily) }
public func CTFontCopyFullName(_ f: CTFont) -> CFString { NSString(string: (f.family ?? Pango.systemFamily) + (f.weight >= 600 ? " Bold" : "")) }
public func CTFontCopyDisplayName(_ f: CTFont) -> CFString { CTFontCopyFullName(f) }
public func CTFontCopyPostScriptName(_ f: CTFont) -> CFString { NSString(string: (f.family ?? Pango.systemFamily).replacingOccurrences(of: " ", with: "") + (f.weight >= 600 ? "-Bold" : "-Regular")) }
public func CTFontGetAscent(_ f: CTFont) -> CGFloat { f.metrics.ascent }
public func CTFontGetDescent(_ f: CTFont) -> CGFloat { f.metrics.descent }
public func CTFontGetLeading(_ f: CTFont) -> CGFloat { f.metrics.leading }
public func CTFontGetCapHeight(_ f: CTFont) -> CGFloat { f.size * 0.7 }
public func CTFontGetXHeight(_ f: CTFont) -> CGFloat { f.size * 0.52 }
public func CTFontGetUnitsPerEm(_ f: CTFont) -> UInt32 { 2048 }
public func CTFontGetBoundingBox(_ f: CTFont) -> CGRect { let m = f.metrics; return CGRect(x: 0, y: -m.descent, width: f.size, height: m.ascent + m.descent) }
public func CTFontGetSymbolicTraits(_ f: CTFont) -> CTFontSymbolicTraits {
    var t: CTFontSymbolicTraits = []
    if f.weight >= 600 { t.insert(.traitBold) }
    if f.italic { t.insert(.traitItalic) }
    if f.monospaced { t.insert(.traitMonoSpace) }
    return t
}
public func CTFontCopyFontDescriptor(_ f: CTFont) -> CTFontDescriptor {
    CTFontDescriptor(attributes: [String(describing: kCTFontFamilyNameAttribute): f.family ?? Pango.systemFamily, String(describing: kCTFontSizeAttribute): f.size])
}

public final class CTFontDescriptor: NSObject, NSSecureCoding, @unchecked Sendable {
    public let attributes: [String: Any]
    public init(attributes: [String: Any]) { self.attributes = attributes; super.init() }
    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        let plist = attributes.filter { $0.value is String || $0.value is NSNumber || $0.value is Double || $0.value is Int || $0.value is [String: Any] }
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
            coder.encode(data, forKey: "CTFontDescriptor.attributes")
        }
    }
    public convenience init?(coder: NSCoder) {
        guard let data = coder.decodeObject(forKey: "CTFontDescriptor.attributes") as? Data,
              let a = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        self.init(attributes: a)
    }
    var family: String? { attributes[String(describing: kCTFontFamilyNameAttribute)] as? String ?? attributes[String(describing: kCTFontNameAttribute)] as? String }
    var weight: Int {
        let traits = attributes[String(describing: kCTFontTraitsAttribute)] as? [String: Any]
        let w = (traits?[String(describing: kCTFontWeightTrait)] as? NSNumber)?.doubleValue ?? (traits?[String(describing: kCTFontWeightTrait)] as? Double)
            ?? (traits?[String(describing: kCTFontWeightTrait)] as? CGFloat).map(Double.init) ?? 0
        // Apple's −1…1 weight scale to CSS weights.
        return switch w {
        case ..<(-0.5): 200
        case ..<(-0.2): 300
        case ..<0.15: 400
        case ..<0.27: 500
        case ..<0.35: 600
        case ..<0.5: 700
        case ..<0.6: 800
        default: 900
        }
    }
    /// The traits dictionary's entry for `key`, as a number.
    func trait(_ key: CFString) -> Double? {
        let traits = attributes[String(describing: kCTFontTraitsAttribute)] as? [String: Any]
        let v = traits?[String(describing: key)]
        return (v as? NSNumber)?.doubleValue ?? (v as? Double) ?? (v as? CGFloat).map(Double.init) ?? (v as? Int).map(Double.init)
            ?? (v as? UInt32).map(Double.init)
    }
    var symbolicTraits: CTFontSymbolicTraits { CTFontSymbolicTraits(rawValue: UInt32(truncatingIfNeeded: Int(trait(kCTFontSymbolicTrait) ?? 0))) }
    /// The system design (`kCTFontUIFontDesign…`) the descriptor asks for, if any.
    public var design: String? {
        let traits = attributes[String(describing: kCTFontTraitsAttribute)] as? [String: Any]
        return traits?[String(describing: kCTFontUIFontDesignTrait)] as? String
    }
    func font(size: CGFloat) -> CTFont {
        let s = size > 0 ? size : ((attributes[String(describing: kCTFontSizeAttribute)] as? NSNumber)?.doubleValue).map { CGFloat($0) } ?? 12
        let t = symbolicTraits
        let bold = t.contains(.traitBold) && trait(kCTFontWeightTrait) == nil
        var family = family
        var mono = t.contains(.traitMonoSpace)
        switch design {
        case String(describing: kCTFontUIFontDesignMonospaced)?:
            if family == nil { family = "Monospace" }
            mono = true
        case String(describing: kCTFontUIFontDesignSerif)?:
            if family == nil { family = "Serif" }
        default: break
        }
        return CTFont(family: family, size: s, weight: bold ? 700 : weight, italic: t.contains(.traitItalic), monospaced: mono)
    }
}

/// The system font designs (`NSFontDescriptor.SystemDesign`'s raw values),
/// stored in a descriptor's traits under `kCTFontUIFontDesignTrait`.
public let kCTFontUIFontDesignTrait: CFString = "NSCTFontUIFontDesignTrait"
public let kCTFontUIFontDesignDefault: CFString = "NSCTFontUIFontDesignDefault"
public let kCTFontUIFontDesignSerif: CFString = "NSCTFontUIFontDesignSerif"
public let kCTFontUIFontDesignMonospaced: CFString = "NSCTFontUIFontDesignMonospaced"
public let kCTFontUIFontDesignRounded: CFString = "NSCTFontUIFontDesignRounded"

public func CTFontDescriptorCreateWithAttributes(_ attributes: CFDictionary) -> CTFontDescriptor {
    var d: [String: Any] = [:]
    for (k, v) in attributes { d[String(describing: k)] = v }
    return CTFontDescriptor(attributes: d)
}
public func CTFontDescriptorCreateWithNameAndSize(_ name: CFString, _ size: CGFloat) -> CTFontDescriptor {
    CTFontDescriptor(attributes: [String(describing: kCTFontNameAttribute): String(describing: name), String(describing: kCTFontSizeAttribute): size])
}
public func CTFontDescriptorCopyAttribute(_ d: CTFontDescriptor, _ attribute: CFString) -> AnyObject? { d.attributes[String(describing: attribute)] as AnyObject? }
public func CTFontDescriptorCopyAttributes(_ d: CTFontDescriptor) -> CFDictionary { d.attributes as NSDictionary }
/// The descriptor itself when its family is installed (fontconfig), else nil.
public func CTFontDescriptorCreateMatchingFontDescriptor(_ d: CTFontDescriptor, _ mandatoryAttributes: CFSet?) -> CTFontDescriptor? {
    guard let family = d.family else { return d }
    return Pango.families.contains { $0.caseInsensitiveCompare(family) == .orderedSame } ? d : nil
}
public func CTFontDescriptorCreateMatchingFontDescriptors(_ d: CTFontDescriptor, _ mandatoryAttributes: CFSet?) -> CFArray? {
    CTFontDescriptorCreateMatchingFontDescriptor(d, mandatoryAttributes).map { [$0] as NSArray }
}

// MARK: Font manager

public func CTFontManagerCopyAvailableFontFamilyNames() -> CFArray { Pango.families as NSArray }
public func CTFontManagerCopyAvailablePostScriptNames() -> CFArray { Pango.families.map { $0.replacingOccurrences(of: " ", with: "") } as NSArray }
/// Adds a font file for this process (fontconfig's application fonts).
public func CTFontManagerRegisterFontsForURL(_ fontURL: CFURL, _ scope: CTFontManagerScope, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool {
    Pango.register((fontURL as URL).path)
}
public func CTFontManagerRegisterFontURLs(_ fontURLs: CFArray, _ scope: CTFontManagerScope, _ enabled: Bool, _ handler: ((CFArray, Bool) -> Bool)?) {
    let ok = (fontURLs as [AnyObject]).compactMap { ($0 as? URL) ?? ($0 as? NSURL).map { $0 as URL } }.map { Pango.register($0.path) }.allSatisfy { $0 }
    _ = handler?(NSArray(), ok)
}
public func CTFontManagerUnregisterFontsForURL(_ fontURL: CFURL, _ scope: CTFontManagerScope, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool { false }

// MARK: Paragraph styles

public final class CTParagraphStyle: @unchecked Sendable {
    public let alignment: CTTextAlignment
    public let lineBreakMode: CTLineBreakMode
    public let lineSpacing: CGFloat
    public init(alignment: CTTextAlignment = .natural, lineBreakMode: CTLineBreakMode = .byWordWrapping, lineSpacing: CGFloat = 0) {
        self.alignment = alignment; self.lineBreakMode = lineBreakMode; self.lineSpacing = lineSpacing
    }
}

/// A run of text with one font and colour.
struct Run {
    var text: String
    var font: CTFont
    /// sRGB RGBA; nil: the context's fill colour.
    var color: [CGFloat]?
}

/// The attributed string as runs, plus its paragraph settings.
struct StyledText {
    var runs: [Run] = []
    var alignment: CTTextAlignment = .natural
    var lineSpacing: CGFloat = 0
    var string: String { runs.map(\.text).joined() }

    init(_ s: NSAttributedString, range: CFRange = CFRange()) {
        let full = NSRange(location: 0, length: s.length)
        var r = full
        if range.length > 0 { r = NSRange(location: range.location, length: min(range.length, s.length - range.location)) }
        let ns = s.string as NSString
        s.enumerateAttributes(in: r, options: []) { attrs, sub, _ in
            var font: CTFont?, color: [CGFloat]?
            for (k, v) in attrs {
                switch k.rawValue {
                case "NSFont": font = CTFont.from(v)
                case "NSColor", "CTForegroundColor":
                    if let c = v as? CGColor { color = c.rgba } else if let c = v as? CGColorRepresentable { color = c.cgColor.rgba } else { color = mirrorColor(v) }
                case "NSParagraphStyle":
                    if let p = v as? CTParagraphStyle { alignment = p.alignment; lineSpacing = p.lineSpacing } else {
                        // Its stored properties, the superclasses' too (NSMutableParagraphStyle's are NSParagraphStyle's).
                        var mirrors: [Mirror] = []
                        var m: Mirror? = Mirror(reflecting: v)
                        while let x = m { mirrors.append(x); m = x.superclassMirror }
                        for c in mirrors.flatMap(\.children) {
                            if c.label == "alignment" {
                                let d = String(describing: c.value).lowercased()
                                alignment = d.contains("center") ? .center : d.contains("right") ? .right : d.contains("justified") ? .justified : d.contains("left") ? .left : .natural
                            }
                            if c.label == "lineSpacing", let ls = c.value as? CGFloat { lineSpacing = ls }
                        }
                    }
                default: break
                }
            }
            runs.append(Run(text: ns.substring(with: sub), font: font ?? CTFont(family: nil, size: 12), color: color))
        }
        if runs.isEmpty, s.length == 0 { runs = [] }
    }
}

/// NSColor's stored RGBA, found by reflection (until NSColor adopts CGColorRepresentable).
private func mirrorColor(_ v: Any) -> [CGFloat]? {
    for c in Mirror(reflecting: v).children where c.label == "fixed" {
        var rgba: [String: Double] = [:]
        let inner = Mirror(reflecting: c.value)
        let target = inner.displayStyle == .optional ? inner.children.first.map { Mirror(reflecting: $0.value) } : inner
        for f in target?.children ?? Mirror(reflecting: ()).children {
            if let l = f.label, let d = f.value as? Double { rgba[l] = d }
        }
        if let r = rgba["r"], let g = rgba["g"], let b = rgba["b"] { return [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(rgba["a"] ?? 1)] }
    }
    return nil
}

// MARK: Lines and frames

public final class CTLine: @unchecked Sendable {
    let text: StyledText
    init(_ t: StyledText) { text = t }
}
public final class CTRun: @unchecked Sendable {}
public final class CTTypesetter: @unchecked Sendable {
    let source: NSAttributedString
    init(_ s: NSAttributedString) { source = s }
}
public final class CTFramesetter: @unchecked Sendable {
    let source: NSAttributedString
    init(_ s: NSAttributedString) { source = s }
}
public final class CTFrame: @unchecked Sendable {
    let text: StyledText
    let rect: CGRect
    init(_ t: StyledText, _ r: CGRect) { text = t; rect = r }
}

public func CTLineCreateWithAttributedString(_ s: CFAttributedString) -> CTLine { CTLine(StyledText(s)) }
public typealias CFAttributedString = NSAttributedString
public func CTLineGetTypographicBounds(_ line: CTLine, _ ascent: UnsafeMutablePointer<CGFloat>?, _ descent: UnsafeMutablePointer<CGFloat>?,
                                       _ leading: UnsafeMutablePointer<CGFloat>?) -> Double {
    let m = Pango.measure(line.text, width: nil)
    ascent?.pointee = m.baseline
    descent?.pointee = m.height - m.baseline
    leading?.pointee = 0
    return Double(m.width)
}
public func CTLineGetImageBounds(_ line: CTLine, _ context: CGContext?) -> CGRect {
    let m = Pango.measure(line.text, width: nil)
    return CGRect(x: 0, y: -(m.height - m.baseline), width: m.width, height: m.height)
}
public func CTLineGetGlyphCount(_ line: CTLine) -> CFIndex { line.text.string.count }
public func CTLineGetStringRange(_ line: CTLine) -> CFRange { CFRange(location: 0, length: (line.text.string as NSString).length) }
public func CTLineGetTrailingWhitespaceWidth(_ line: CTLine) -> Double { 0 }
public func CTLineGetOffsetForStringIndex(_ line: CTLine, _ charIndex: CFIndex, _ secondaryOffset: UnsafeMutablePointer<CGFloat>?) -> CGFloat {
    let prefix = String((line.text.string as NSString).substring(to: min(charIndex, (line.text.string as NSString).length)))
    var t = line.text
    t.runs = [Run(text: prefix, font: t.runs.first?.font ?? CTFont(family: nil, size: 12), color: nil)]
    let w = Pango.measure(t, width: nil).width
    secondaryOffset?.pointee = w
    return w
}
public func CTLineGetGlyphRuns(_ line: CTLine) -> CFArray { NSArray() }
/// Draws the line with its baseline at the context's text position.
public func CTLineDraw(_ line: CTLine, _ context: CGContext) {
    Pango.draw(line.text, width: nil, at: context.textPosition, topAligned: false, in: context)
}

public func CTTypesetterCreateWithAttributedString(_ s: CFAttributedString) -> CTTypesetter { CTTypesetter(s) }
public func CTTypesetterSuggestLineBreak(_ ts: CTTypesetter, _ startIndex: CFIndex, _ width: Double) -> CFIndex {
    let t = StyledText(ts.source, range: CFRange(location: startIndex, length: ts.source.length - startIndex))
    return Pango.firstLineLength(t, width: CGFloat(width))
}
public func CTTypesetterCreateLine(_ ts: CTTypesetter, _ range: CFRange) -> CTLine { CTLine(StyledText(ts.source, range: range)) }

public func CTFramesetterCreateWithAttributedString(_ s: CFAttributedString) -> CTFramesetter { CTFramesetter(s) }
public func CTFramesetterSuggestFrameSizeWithConstraints(_ setter: CTFramesetter, _ range: CFRange, _ frameAttributes: CFDictionary?, _ constraints: CGSize,
                                                         _ fitRange: UnsafeMutablePointer<CFRange>?) -> CGSize {
    let t = StyledText(setter.source, range: range)
    let width: CGFloat? = constraints.width.isFinite && constraints.width < 1e7 ? constraints.width : nil
    let m = Pango.measure(t, width: width)
    fitRange?.pointee = CFRange(location: range.location, length: range.length > 0 ? range.length : setter.source.length)
    return CGSize(width: m.width, height: min(m.height, constraints.height))
}
public func CTFramesetterCreateFrame(_ setter: CTFramesetter, _ range: CFRange, _ path: CGPath, _ attributes: CFDictionary?) -> CTFrame {
    CTFrame(StyledText(setter.source, range: range), path.boundingBox)
}
public func CTFramesetterGetTypesetter(_ setter: CTFramesetter) -> CTTypesetter { CTTypesetter(setter.source) }
public func CTFrameGetVisibleStringRange(_ frame: CTFrame) -> CFRange { CFRange(location: 0, length: (frame.text.string as NSString).length) }
public func CTFrameGetPath(_ frame: CTFrame) -> CGPath { CGPath(rect: frame.rect, transform: nil) }
/// Draws the text wrapped to the frame's width, from the top of its rectangle.
public func CTFrameDraw(_ frame: CTFrame, _ context: CGContext) {
    Pango.draw(frame.text, width: frame.rect.width, at: CGPoint(x: frame.rect.minX, y: frame.rect.maxY), topAligned: true, in: context)
}
public func CTFrameGetLines(_ frame: CTFrame) -> CFArray { NSArray() }

// MARK: Pango

enum Pango {
    static let lock = NSRecursiveLock()
    static let systemFamily = "Sans"

    struct Measure { var width: CGFloat; var height: CGFloat; var baseline: CGFloat }

    #if os(Linux)
    static let scale = CGFloat(runway_pango_scale())

    /// A layout for `t` on a scratch Cairo context, `width` in pixels (nil: unwrapped).
    static func withLayout<T>(_ t: StyledText, width: CGFloat?, cairo cr: OpaquePointer? = nil, _ body: (OpaquePointer) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        var ownCairo: OpaquePointer?
        var surface: OpaquePointer?
        if cr == nil {
            surface = cairo_image_surface_create(CAIRO_FORMAT_A8, 1, 1)
            ownCairo = cairo_create(surface)
        }
        let ctx = cr ?? ownCairo!
        let layout = pango_cairo_create_layout(ctx)!
        let text = t.string
        pango_layout_set_text(layout, text, -1)
        let attrs = pango_attr_list_new()
        var byte = 0
        for run in t.runs {
            let n = run.text.utf8.count
            let desc = pango_font_description_new()
            pango_font_description_set_family(desc, run.font.pangoFamily)
            pango_font_description_set_absolute_size(desc, Double(run.font.size * scale))
            pango_font_description_set_weight(desc, PangoWeight(rawValue: UInt32(run.font.weight)))
            if run.font.italic { pango_font_description_set_style(desc, PANGO_STYLE_ITALIC) }
            if let a = pango_attr_font_desc_new(desc) {
                a.pointee.start_index = guint(byte); a.pointee.end_index = guint(byte + n)
                pango_attr_list_insert(attrs, a)
            }
            pango_font_description_free(desc)
            if let c = run.color {
                if let a = pango_attr_foreground_new(guint16(max(0, min(1, c[0])) * 65535), guint16(max(0, min(1, c[1])) * 65535), guint16(max(0, min(1, c[2])) * 65535)) {
                    a.pointee.start_index = guint(byte); a.pointee.end_index = guint(byte + n)
                    pango_attr_list_insert(attrs, a)
                }
                if c.count > 3, c[3] < 1, let a = pango_attr_foreground_alpha_new(guint16(max(0, min(1, c[3])) * 65535)) {
                    a.pointee.start_index = guint(byte); a.pointee.end_index = guint(byte + n)
                    pango_attr_list_insert(attrs, a)
                }
            }
            byte += n
        }
        pango_layout_set_attributes(layout, attrs)
        pango_attr_list_unref(attrs)
        if let width {
            pango_layout_set_width(layout, Int32(max(width, 1) * scale))
            pango_layout_set_wrap(layout, PANGO_WRAP_WORD_CHAR)
        }
        switch t.alignment {
        case .center: pango_layout_set_alignment(layout, PANGO_ALIGN_CENTER)
        case .right: pango_layout_set_alignment(layout, PANGO_ALIGN_RIGHT)
        case .justified: pango_layout_set_justify(layout, 1)
        default: pango_layout_set_alignment(layout, PANGO_ALIGN_LEFT)
        }
        if t.lineSpacing > 0 { pango_layout_set_spacing(layout, Int32(t.lineSpacing * scale)) }
        let r = body(layout)
        g_object_unref(UnsafeMutableRawPointer(layout))
        if let ownCairo { cairo_destroy(ownCairo) }
        if let surface { cairo_surface_destroy(surface) }
        return r
    }

    static func measure(_ t: StyledText, width: CGFloat?) -> Measure {
        guard !t.runs.isEmpty else { return Measure(width: 0, height: 0, baseline: 0) }
        return withLayout(t, width: width) { l in
            var ink = PangoRectangle(), logical = PangoRectangle()
            pango_layout_get_extents(l, &ink, &logical)
            let w = CGFloat(logical.width) / scale, h = CGFloat(logical.height) / scale
            return Measure(width: width.map { _ in w } ?? w, height: h, baseline: CGFloat(pango_layout_get_baseline(l)) / scale)
        }
    }

    static func firstLineLength(_ t: StyledText, width: CGFloat) -> Int {
        withLayout(t, width: width) { l in
            guard let line = pango_layout_get_line_readonly(l, 0) else { return 0 }
            let bytes = Int(line.pointee.length)
            return String(decoding: t.string.utf8.prefix(bytes), as: UTF8.self).utf16.count
        }
    }

    static func metrics(_ f: CTFont) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat) {
        let m = measure(StyledText(runs: [Run(text: "Hg", font: f, color: nil)]), width: nil)
        return (m.baseline, m.height - m.baseline, 0)
    }

    static var families: [String] {
        lock.lock(); defer { lock.unlock() }
        guard let map = pango_cairo_font_map_get_default() else { return [] }
        var list: UnsafeMutablePointer<UnsafeMutablePointer<PangoFontFamily>?>?
        var n: Int32 = 0
        pango_font_map_list_families(map, &list, &n)
        var out: [String] = []
        for i in 0..<Int(n) {
            if let f = list?[i], let name = pango_font_family_get_name(f) { out.append(String(cString: name)) }
        }
        g_free(list)
        return Array(Set(out)).sorted()
    }

    static func register(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let ok = FcConfigAppFontAddFile(nil, path) != 0
        if ok, let map = pango_cairo_font_map_get_default() { pango_font_map_changed(map) }
        return ok
    }

    /// The layout drawn with Cairo at `scale` pixels per point: its image
    /// (top-left at the box's) and the box's size in points. Bitmap contexts
    /// draw text with this (CGTextRasterizer); native targets lay out themselves.
    static func rasterize(_ t: StyledText, width: CGFloat?, scale s: CGFloat, fill: [CGFloat]) -> (image: CGImage, size: CGSize)? {
        guard !t.runs.isEmpty else { return nil }
        let m = measure(t, width: width)
        let box = CGSize(width: width ?? m.width, height: m.height)
        let pw = Int((box.width * s).rounded(.up)), ph = Int((box.height * s).rounded(.up))
        guard pw > 0, ph > 0, pw < 16384, ph < 16384 else { return nil }
        lock.lock()
        let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(pw), Int32(ph))
        let cr = cairo_create(surface)
        cairo_scale(cr, Double(s), Double(s))
        cairo_set_source_rgba(cr, Double(fill[0]), Double(fill[1]), Double(fill[2]), Double(fill.count > 3 ? fill[3] : 1))
        cairo_move_to(cr, 0, 0)
        withLayout(t, width: width, cairo: cr) { l in pango_cairo_show_layout(cr, l) }
        cairo_surface_flush(surface)
        let stride = Int(cairo_image_surface_get_stride(surface))
        let data = cairo_image_surface_get_data(surface)!
        var rgba = [UInt8](repeating: 0, count: pw * ph * 4)
        for y in 0..<ph {
            for x in 0..<pw {
                // Cairo: premultiplied ARGB in native (little-endian: BGRA) order.
                let p = data + y * stride + x * 4
                let a = p[3]
                guard a > 0 else { continue }
                let o = (y * pw + x) * 4
                func un(_ v: UInt8) -> UInt8 { UInt8(min(255, (Int(v) * 255 + Int(a) / 2) / Int(a))) }
                rgba[o] = un(p[2]); rgba[o + 1] = un(p[1]); rgba[o + 2] = un(p[0]); rgba[o + 3] = a
            }
        }
        cairo_destroy(cr)
        cairo_surface_destroy(surface)
        lock.unlock()
        return (CGImage(width: pw, height: ph, rgba: rgba, hasAlpha: true), CGSize(width: CGFloat(pw) / s, height: CGFloat(ph) / s))
    }
    #else
    static func measure(_ t: StyledText, width: CGFloat?) -> Measure {
        let size = t.runs.map(\.font.size).max() ?? 12
        let w = CGFloat(t.string.count) * size * 0.55
        let lines = width.map { max(1, (w / max($0, 1)).rounded(.up)) } ?? 1
        return Measure(width: width.map { min(w, $0) } ?? w, height: size * 1.2 * lines, baseline: size * 0.95)
    }
    static func firstLineLength(_ t: StyledText, width: CGFloat) -> Int { t.string.utf16.count }
    static func metrics(_ f: CTFont) -> (ascent: CGFloat, descent: CGFloat, leading: CGFloat) { (f.size * 0.95, f.size * 0.25, 0) }
    static var families: [String] { [] }
    static func register(_ path: String) -> Bool { false }
    static func rasterize(_ t: StyledText, width: CGFloat?, scale: CGFloat, fill: [CGFloat]) -> (image: CGImage, size: CGSize)? { nil }
    #endif

    /// Draws `t` as a text op: `origin` is the baseline start (a line) or the
    /// box's top-left (a frame), in user space (y up).
    static func draw(_ t: StyledText, width: CGFloat?, at origin: CGPoint, topAligned: Bool, in ctx: CGContext) {
        guard !t.runs.isEmpty else { return }
        installRasterizer
        let fill = ctx.fillColorComponents
        let runs = t.runs.map { r in
            CGTextRun(string: r.text, family: r.font.family, size: r.font.size, weight: r.font.weight, italic: r.font.italic,
                      monospaced: r.font.monospaced, color: r.color ?? fill)
        }
        var layout = CGTextLayout(runs: runs, width: width)
        layout.alignment = switch t.alignment {
        case .center: .center
        case .right: .right
        case .justified: .justified
        case .left: .left
        default: .natural
        }
        layout.lineSpacing = t.lineSpacing
        let top = topAligned ? origin.y : origin.y + measure(t, width: width).baseline
        ctx.drawText(layout, at: CGPoint(x: origin.x, y: top), flipped: false)
    }

    /// Bitmap contexts draw text ops through Pango.
    static let installRasterizer: Void = {
        CGTextRasterizer.render = { layout, scale in
            var t = StyledText(runs: layout.runs.map {
                Run(text: $0.string, font: CTFont(family: $0.family, size: $0.size, weight: $0.weight, italic: $0.italic, monospaced: $0.monospaced), color: $0.color)
            })
            t.alignment = switch layout.alignment {
            case .center: .center
            case .right: .right
            case .justified: .justified
            case .left: .left
            default: .natural
            }
            t.lineSpacing = layout.lineSpacing
            return Pango.rasterize(t, width: layout.width, scale: scale, fill: [0, 0, 0, 1])
        }
    }()
}

extension StyledText {
    init(runs: [Run]) { self.runs = runs }
}
