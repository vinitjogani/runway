// NSFontDescriptor (toll-free bridged with CoreText's CTFontDescriptor, as
// on the Mac: one class, so `as CTFontDescriptor` and `as NSFontDescriptor`
// convert), NSFont ↔ descriptors, and NSFontManager.

import Foundation
import CoreText
import RunwayCore

public typealias NSFontDescriptor = CTFontDescriptor

extension CTFontDescriptor {
    public struct AttributeName: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let family = AttributeName("NSFontFamilyAttribute")
        public static let name = AttributeName("NSFontNameAttribute")
        public static let face = AttributeName("NSFontFaceAttribute")
        public static let size = AttributeName("NSFontSizeAttribute")
        public static let visibleName = AttributeName("NSFontVisibleNameAttribute")
        public static let matrix = AttributeName("NSFontMatrixAttribute")
        public static let variation = AttributeName("NSCTFontVariationAttribute")
        public static let characterSet = AttributeName("NSCTFontCharacterSetAttribute")
        public static let cascadeList = AttributeName("NSCTFontCascadeListAttribute")
        public static let traits = AttributeName("NSCTFontTraitsAttribute")
        public static let fixedAdvance = AttributeName("NSCTFontFixedAdvanceAttribute")
        public static let featureSettings = AttributeName("NSCTFontFeatureSettingsAttribute")
    }
    public struct TraitKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let symbolic = TraitKey("NSCTFontSymbolicTrait")
        public static let weight = TraitKey("NSCTFontWeightTrait")
        public static let width = TraitKey("NSCTFontProportionTrait")
        public static let slant = TraitKey("NSCTFontSlantTrait")
    }
    /// The system font's designs.
    public struct SystemDesign: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let `default` = SystemDesign(String(describing: kCTFontUIFontDesignDefault))
        public static let serif = SystemDesign(String(describing: kCTFontUIFontDesignSerif))
        public static let monospaced = SystemDesign(String(describing: kCTFontUIFontDesignMonospaced))
        public static let rounded = SystemDesign(String(describing: kCTFontUIFontDesignRounded))
    }
    public struct SymbolicTraits: OptionSet, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let italic = SymbolicTraits(rawValue: 1 << 0), bold = SymbolicTraits(rawValue: 1 << 1)
        public static let expanded = SymbolicTraits(rawValue: 1 << 5), condensed = SymbolicTraits(rawValue: 1 << 6)
        public static let monoSpace = SymbolicTraits(rawValue: 1 << 10), vertical = SymbolicTraits(rawValue: 1 << 11)
        public static let uiOptimized = SymbolicTraits(rawValue: 1 << 12), tightLeading = SymbolicTraits(rawValue: 1 << 15)
        public static let looseLeading = SymbolicTraits(rawValue: 1 << 16)
    }

    public convenience init(fontAttributes attributes: [AttributeName: Any]? = nil) {
        var a: [String: Any] = [:]
        for (k, v) in attributes ?? [:] {
            if k == .traits, let t = v as? [TraitKey: Any] {
                a[k.rawValue] = Dictionary(uniqueKeysWithValues: t.map { ($0.key.rawValue, $0.value) })
            } else {
                a[k.rawValue] = v
            }
        }
        self.init(attributes: a)
    }
    public convenience init(name fontName: String, size: CGFloat) {
        self.init(attributes: [AttributeName.name.rawValue: fontName, AttributeName.size.rawValue: size])
    }
    public convenience init(name fontName: String, matrix: AffineTransform) { self.init(name: fontName, size: 0) }

    public var fontAttributes: [AttributeName: Any] {
        var out: [AttributeName: Any] = [:]
        for (k, v) in attributes {
            if k == AttributeName.traits.rawValue, let t = v as? [String: Any] {
                out[.traits] = Dictionary(uniqueKeysWithValues: t.map { (TraitKey($0.key), $0.value) })
            } else {
                out[AttributeName(k)] = v
            }
        }
        return out
    }
    public func object(forKey attribute: AttributeName) -> Any? { attributes[attribute.rawValue] }

    public var pointSize: CGFloat {
        let v = attributes[AttributeName.size.rawValue]
        return (v as? CGFloat) ?? (v as? Double).map { CGFloat($0) } ?? (v as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }
    public var postscriptName: String? {
        (attributes[AttributeName.name.rawValue] as? String) ?? (attributes[AttributeName.family.rawValue] as? String).map { $0.replacingOccurrences(of: " ", with: "") }
    }
    public var matrix: AffineTransform? { nil }
    public var symbolicTraits: SymbolicTraits { SymbolicTraits(rawValue: traitsDictionary[TraitKey.symbolic.rawValue].map(Self.uint32) ?? 0) }
    public var requiresFontAssetRequest: Bool { false }

    var traitsDictionary: [String: Any] { attributes[AttributeName.traits.rawValue] as? [String: Any] ?? [:] }
    static func uint32(_ v: Any) -> UInt32 {
        if let n = v as? UInt32 { return n }
        if let n = v as? Int { return UInt32(truncatingIfNeeded: n) }
        if let n = v as? NSNumber { return n.uint32Value }
        return 0
    }

    /// A copy with `attributes` added (replacing any with the same name).
    public func addingAttributes(_ more: [AttributeName: Any]) -> NSFontDescriptor {
        var a = attributes
        for (k, v) in more {
            if k == .traits, let t = v as? [TraitKey: Any] {
                var traits = traitsDictionary
                for (tk, tv) in t { traits[tk.rawValue] = tv }
                a[k.rawValue] = traits
            } else {
                a[k.rawValue] = v
            }
        }
        return NSFontDescriptor(attributes: a)
    }
    private func withTraits(_ change: (inout [String: Any]) -> Void) -> NSFontDescriptor {
        var a = attributes
        var t = traitsDictionary
        change(&t)
        a[AttributeName.traits.rawValue] = t
        return NSFontDescriptor(attributes: a)
    }
    public func withSize(_ newPointSize: CGFloat) -> NSFontDescriptor {
        var a = attributes
        a[AttributeName.size.rawValue] = newPointSize
        return NSFontDescriptor(attributes: a)
    }
    public func withFamily(_ newFamily: String) -> NSFontDescriptor {
        var a = attributes
        a[AttributeName.family.rawValue] = newFamily
        a[AttributeName.name.rawValue] = nil
        return NSFontDescriptor(attributes: a)
    }
    public func withFace(_ newFace: String) -> NSFontDescriptor {
        var a = attributes
        a[AttributeName.face.rawValue] = newFace
        return NSFontDescriptor(attributes: a)
    }
    public func withSymbolicTraits(_ symbolicTraits: SymbolicTraits) -> NSFontDescriptor {
        withTraits { $0[TraitKey.symbolic.rawValue] = symbolicTraits.rawValue }
    }
    public func withMatrix(_ matrix: AffineTransform) -> NSFontDescriptor { self }
    /// The descriptor in one of the system font's designs; nil for a font
    /// that isn't the system font (named fonts have no designs).
    public func withDesign(_ design: SystemDesign) -> NSFontDescriptor? {
        if let f = attributes[AttributeName.family.rawValue] as? String, !Self.isSystemFamily(f) { return nil }
        if let n = attributes[AttributeName.name.rawValue] as? String, !Self.isSystemFamily(n) { return nil }
        var a = attributes
        a[AttributeName.family.rawValue] = nil
        a[AttributeName.name.rawValue] = nil
        var t = traitsDictionary
        t[String(describing: kCTFontUIFontDesignTrait)] = design.rawValue
        a[AttributeName.traits.rawValue] = t
        return NSFontDescriptor(attributes: a)
    }
    static func isSystemFamily(_ name: String) -> Bool { name.hasPrefix(".") || name == "System" || name == "System Font" }

    public func matchingFontDescriptors(withMandatoryKeys mandatoryKeys: Set<AttributeName>?) -> [NSFontDescriptor] {
        matchingFontDescriptor(withMandatoryKeys: mandatoryKeys).map { [$0] } ?? []
    }
    public func matchingFontDescriptor(withMandatoryKeys mandatoryKeys: Set<AttributeName>?) -> NSFontDescriptor? {
        CTFontDescriptorCreateMatchingFontDescriptor(self, mandatoryKeys.map { Set($0.map(\.rawValue)) as NSSet })
    }

    public static func preferredFontDescriptor(forTextStyle style: NSFont.TextStyle, options: [AnyHashable: Any] = [:]) -> NSFontDescriptor {
        NSFont.preferredFont(forTextStyle: style, options: options).fontDescriptor
    }
}

extension NSFont {
    /// The font's descriptor: family (none for the system font), size and
    /// traits (weight, italic, monospace, design).
    public var fontDescriptor: NSFontDescriptor {
        var traits: [String: Any] = [:]
        traits[NSFontDescriptor.TraitKey.weight.rawValue] = Double(Self.appleWeight(spec.weight))
        var sym: NSFontDescriptor.SymbolicTraits = []
        if spec.italic { sym.insert(.italic) }
        if spec.weight >= .semibold { sym.insert(.bold) }
        if spec.design == .monospaced { sym.insert(.monoSpace) }
        traits[NSFontDescriptor.TraitKey.symbolic.rawValue] = sym.rawValue
        let design: NSFontDescriptor.SystemDesign? = switch spec.design {
        case .serif: .serif
        case .monospaced: .monospaced
        case .rounded: .rounded
        case .default: spec.family == nil ? .default : nil
        }
        if let design { traits[String(describing: kCTFontUIFontDesignTrait)] = design.rawValue }
        var a: [String: Any] = [NSFontDescriptor.AttributeName.size.rawValue: spec.size, NSFontDescriptor.AttributeName.traits.rawValue: traits]
        if let f = spec.family { a[NSFontDescriptor.AttributeName.family.rawValue] = f }
        return NSFontDescriptor(attributes: a)
    }

    /// The font a descriptor describes at `fontSize` (0: the descriptor's
    /// size). Named families resolve through fontconfig when drawn.
    public convenience init?(descriptor fontDescriptor: NSFontDescriptor, size fontSize: CGFloat) {
        let size = fontSize > 0 ? fontSize : (fontDescriptor.pointSize > 0 ? fontDescriptor.pointSize : NSFont.systemFontSize)
        let t = fontDescriptor.traitsDictionary
        let sym = fontDescriptor.symbolicTraits
        var weight: FontWeightValue = sym.contains(.bold) ? .bold : .regular
        if let w = t[NSFontDescriptor.TraitKey.weight.rawValue] {
            let v = (w as? Double) ?? (w as? CGFloat).map(Double.init) ?? (w as? NSNumber)?.doubleValue ?? 0
            weight = NSFont.Weight(rawValue: CGFloat(v)).spec
        }
        var design: FontDesignValue = sym.contains(.monoSpace) ? .monospaced : .default
        switch t[String(describing: kCTFontUIFontDesignTrait)] as? String {
        case NSFontDescriptor.SystemDesign.serif.rawValue?: design = .serif
        case NSFontDescriptor.SystemDesign.monospaced.rawValue?: design = .monospaced
        case NSFontDescriptor.SystemDesign.rounded.rawValue?: design = .rounded
        default: break
        }
        var family = (fontDescriptor.attributes[NSFontDescriptor.AttributeName.family.rawValue] as? String)
            ?? (fontDescriptor.attributes[NSFontDescriptor.AttributeName.name.rawValue] as? String)
        if let f = family, NSFontDescriptor.isSystemFamily(f) { family = nil }
        self.init(spec: FontSpec(size: size, weight: weight, design: design, italic: sym.contains(.italic), family: family))
    }

    /// Apple's −1…1 weight for a CSS-style weight.
    static func appleWeight(_ w: FontWeightValue) -> CGFloat {
        switch w {
        case .ultraLight: Weight.ultraLight.rawValue
        case .thin: Weight.thin.rawValue
        case .light: Weight.light.rawValue
        case .regular: Weight.regular.rawValue
        case .medium: Weight.medium.rawValue
        case .semibold: Weight.semibold.rawValue
        case .bold: Weight.bold.rawValue
        case .heavy: Weight.heavy.rawValue
        case .black: Weight.black.rawValue
        }
    }
}

extension NSFont: CTFontRepresentable {
    /// The CoreText font for this font (toll-free bridged on the Mac).
    public var ctFont: CTFont { CTFontCreateWithFontDescriptor(fontDescriptor, spec.size, nil) }
    /// Every glyph the same width: the monospaced design or a monospaced family.
    public var isFixedPitch: Bool { spec.design == .monospaced || CTFontGetSymbolicTraits(ctFont).contains(.traitMonoSpace) }
}

// MARK: Font manager

public struct NSFontTraitMask: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let italicFontMask = NSFontTraitMask(rawValue: 0x1), boldFontMask = NSFontTraitMask(rawValue: 0x2)
    public static let unboldFontMask = NSFontTraitMask(rawValue: 0x4), nonStandardCharacterSetFontMask = NSFontTraitMask(rawValue: 0x8)
    public static let narrowFontMask = NSFontTraitMask(rawValue: 0x10), expandedFontMask = NSFontTraitMask(rawValue: 0x20)
    public static let condensedFontMask = NSFontTraitMask(rawValue: 0x40), smallCapsFontMask = NSFontTraitMask(rawValue: 0x80)
    public static let posterFontMask = NSFontTraitMask(rawValue: 0x100), compressedFontMask = NSFontTraitMask(rawValue: 0x200)
    public static let fixedPitchFontMask = NSFontTraitMask(rawValue: 0x400), unitalicFontMask = NSFontTraitMask(rawValue: 0x1000000)
}

/// The installed font families (fontconfig) and conversions between fonts.
open class NSFontManager: NSObject, @unchecked Sendable {
    public static let shared = NSFontManager()

    /// Every installed family, by name.
    open var availableFontFamilies: [String] { (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [] }
    open var availableFonts: [String] { (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? [] }
    /// Members of a family: [name, face, weight (0…15), traits].
    open func availableMembers(ofFontFamily family: String) -> [[Any]]? {
        guard availableFontFamilies.contains(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) else { return nil }
        return [[family, "Regular", 5, UInt(0)], [family + "-Bold", "Bold", 9, NSFontTraitMask.boldFontMask.rawValue]]
    }
    open func font(withFamily family: String, traits: NSFontTraitMask, weight: Int, size: CGFloat) -> NSFont? {
        guard availableFontFamilies.contains(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) else { return nil }
        let w: FontWeightValue = traits.contains(.boldFontMask) ? .bold : Self.weight(fromManagerWeight: weight)
        return NSFont(spec: FontSpec(size: size, weight: w, italic: traits.contains(.italicFontMask), family: family))
    }
    open func traits(of font: NSFont) -> NSFontTraitMask {
        var t: NSFontTraitMask = []
        if font.spec.weight >= .semibold { t.insert(.boldFontMask) } else { t.insert(.unboldFontMask) }
        if font.spec.italic { t.insert(.italicFontMask) } else { t.insert(.unitalicFontMask) }
        if font.spec.design == .monospaced { t.insert(.fixedPitchFontMask) }
        return t
    }
    /// The font's weight on the font manager's 0…15 scale (5 is regular, 9 bold).
    open func weight(of font: NSFont) -> Int {
        switch font.spec.weight {
        case .ultraLight: 1
        case .thin: 2
        case .light: 3
        case .regular: 5
        case .medium: 6
        case .semibold: 8
        case .bold: 9
        case .heavy: 11
        case .black: 14
        }
    }
    static func weight(fromManagerWeight w: Int) -> FontWeightValue {
        switch w {
        case ...1: .ultraLight
        case 2: .thin
        case 3...4: .light
        case 5: .regular
        case 6...7: .medium
        case 8: .semibold
        case 9...10: .bold
        case 11...12: .heavy
        default: .black
        }
    }
    open func convert(_ font: NSFont, toHaveTrait trait: NSFontTraitMask) -> NSFont {
        var s = font.spec
        if trait.contains(.boldFontMask) { s.weight = .bold }
        if trait.contains(.unboldFontMask) { s.weight = .regular }
        if trait.contains(.italicFontMask) { s.italic = true }
        if trait.contains(.unitalicFontMask) { s.italic = false }
        if trait.contains(.fixedPitchFontMask) { s.design = .monospaced }
        return NSFont(spec: s)
    }
    open func convert(_ font: NSFont, toNotHaveTrait trait: NSFontTraitMask) -> NSFont {
        var s = font.spec
        if trait.contains(.boldFontMask) { s.weight = .regular }
        if trait.contains(.italicFontMask) { s.italic = false }
        if trait.contains(.fixedPitchFontMask), s.design == .monospaced { s.design = .default }
        return NSFont(spec: s)
    }
    open func convert(_ font: NSFont, toFamily family: String) -> NSFont {
        var s = font.spec
        s.family = NSFontDescriptor.isSystemFamily(family) ? nil : family
        return NSFont(spec: s)
    }
    open func convert(_ font: NSFont, toSize size: CGFloat) -> NSFont {
        var s = font.spec
        s.size = size
        return NSFont(spec: s)
    }
    open func convertWeight(_ upFlag: Bool, of font: NSFont) -> NSFont {
        var s = font.spec
        let all: [FontWeightValue] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        if let i = all.firstIndex(of: s.weight) { s.weight = all[max(0, min(all.count - 1, i + (upFlag ? 1 : -1)))] }
        return NSFont(spec: s)
    }
}
