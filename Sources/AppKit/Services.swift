// NSColor, NSAppearance, NSFont, NSImage, and the desktop services:
// NSPasteboard, NSWorkspace, NSSound, NSOpenPanel/NSSavePanel, NSAlert.

import Foundation
import CoreGraphics
import RunwayCore
import UniformTypeIdentifiers
import RunwayFoundation
import ImageIO
#if canImport(Glibc)
import Glibc
#endif

// MARK: Appearance

public final class NSAppearance: @unchecked Sendable {
    public struct Name: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let aqua = Name("NSAppearanceNameAqua")
        public static let darkAqua = Name("NSAppearanceNameDarkAqua")
        public static let vibrantLight = Name("NSAppearanceNameVibrantLight")
        public static let vibrantDark = Name("NSAppearanceNameVibrantDark")
        public static let accessibilityHighContrastAqua = Name("NSAppearanceNameAccessibilityAqua")
        public static let accessibilityHighContrastDarkAqua = Name("NSAppearanceNameAccessibilityDarkAqua")
    }
    public let name: Name
    public init?(named name: Name) { self.name = name }
    init(_ name: Name) { self.name = name }
    public var isDark: Bool { name == .darkAqua || name == .vibrantDark || name == .accessibilityHighContrastDarkAqua }
    public func bestMatch(from names: [Name]) -> Name? {
        let dark = names.first { [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua].contains($0) }
        let light = names.first { [.aqua, .vibrantLight, .accessibilityHighContrastAqua].contains($0) }
        return isDark ? (dark ?? light) : (light ?? dark)
    }
    /// The system's: follows the backend's light/dark.
    public static var system: NSAppearance {
        let dark = MainActor.assumeIsolated { Runway.backend.colorScheme == .dark }
        return dark ? darkShared : aquaShared
    }
    private static let aquaShared = NSAppearance(.aqua), darkShared = NSAppearance(.darkAqua)
    nonisolated(unsafe) private static var override: NSAppearance?
    /// The appearance colours resolve against: the drawing view's while it
    /// draws, else the app's.
    public static var current: NSAppearance {
        get { override ?? MainActor.assumeIsolated { NSApplication.shared.appearance } ?? system }
        set { override = newValue }
    }
    public static var currentDrawing: NSAppearance { current }
    public func performAsCurrentDrawingAppearance(_ block: () -> Void) {
        let old = NSAppearance.override
        NSAppearance.override = self
        block()
        NSAppearance.override = old
    }
    public var allowsVibrancy: Bool { name == .vibrantDark || name == .vibrantLight }
}

/// Objects with an appearance of their own (views, windows, the app).
@preconcurrency @MainActor public protocol NSAppearanceCustomization: AnyObject {
    var appearance: NSAppearance? { get set }
    var effectiveAppearance: NSAppearance { get }
}

// MARK: Colour

public final class NSColorSpace: @unchecked Sendable {
    public static let sRGB = NSColorSpace(), deviceRGB = NSColorSpace(), genericRGB = NSColorSpace(), displayP3 = NSColorSpace(), extendedSRGB = NSColorSpace()
}

/// A colour: fixed, or resolved per appearance by a provider. Dynamic
/// colours register with SwiftUI's colour providers so `Color(nsColor:)`
/// follows light and dark.
public final class NSColor: NSObject, NSSecureCoding, @unchecked Sendable {
    /// A colour's name (a String, as on the Mac).
    public typealias Name = String
    let fixed: RGBA?
    let provider: ((NSAppearance) -> NSColor)?
    public let providerID: Int?

    public init(rgba: RGBA) { fixed = rgba; provider = nil; providerID = nil; super.init() }
    /// A clear color (what an uninitialized NSColor is).
    public override convenience init() { self.init(rgba: .clear) }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        let l = rgba(dark: false), d = rgba(dark: true)
        for (k, v) in [("r", l.r), ("g", l.g), ("b", l.b), ("a", l.a), ("dr", d.r), ("dg", d.g), ("db", d.b), ("da", d.a)] {
            coder.encode(v, forKey: "NSColor." + k)
        }
    }
    public convenience init?(coder: NSCoder) {
        func v(_ k: String) -> Double { coder.decodeDouble(forKey: "NSColor." + k) }
        let light = RGBA(v("r"), v("g"), v("b"), v("a")), dark = RGBA(v("dr"), v("dg"), v("db"), v("da"))
        if light == dark { self.init(rgba: light) } else {
            self.init(name: nil) { $0.isDark ? NSColor(rgba: dark) : NSColor(rgba: light) }
        }
    }

    /// Equal colours compare equal (attributed strings coalesce runs by it).
    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? NSColor else { return false }
        return o === self || (o.fixed == fixed && o.providerID == providerID)
    }
    public override var hash: Int {
        var h = Hasher()
        h.combine(fixed)
        h.combine(providerID)
        return h.finalize()
    }

    public init(name: String?, dynamicProvider: @escaping @Sendable (NSAppearance) -> NSColor) {
        fixed = nil
        provider = dynamicProvider
        providerID = ColorProviderRegistry.register { dark in dynamicProvider(NSAppearance(dark ? .darkAqua : .aqua)).rgba(dark: dark) }
        super.init()
    }

    public convenience init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(rgba: RGBA(Double(r), Double(g), Double(b), Double(a))) }
    public convenience init(red r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(srgbRed: r, green: g, blue: b, alpha: a) }
    public convenience init(calibratedRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(srgbRed: r, green: g, blue: b, alpha: a) }
    public convenience init(deviceRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(srgbRed: r, green: g, blue: b, alpha: a) }
    public convenience init(displayP3Red r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(srgbRed: r, green: g, blue: b, alpha: a) }
    public convenience init(white w: CGFloat, alpha a: CGFloat) { self.init(srgbRed: w, green: w, blue: w, alpha: a) }
    public convenience init(calibratedWhite w: CGFloat, alpha a: CGFloat) { self.init(white: w, alpha: a) }
    public convenience init(hue h: CGFloat, saturation s: CGFloat, brightness v: CGFloat, alpha a: CGFloat) {
        let hh = Double(h) * 6, c = Double(v * s), x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1)), m = Double(v) - c
        let (r, g, b): (Double, Double, Double) = switch Int(hh) % 6 {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        self.init(rgba: RGBA(r + m, g + m, b + m, Double(a)))
    }
    public convenience init?(cgColor: CGColor) {
        guard let c = cgColor.components, c.count >= 3 else { return nil }
        self.init(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
    }
    public convenience init(cgColor: CGColor, _: Void = ()) {
        let c = cgColor.components ?? [0, 0, 0, 1]
        self.init(srgbRed: c[0], green: c.count > 2 ? c[1] : c[0], blue: c.count > 2 ? c[2] : c[0], alpha: c.last ?? 1)
    }

    /// The colour for light or dark.
    public func rgba(dark: Bool) -> RGBA {
        if let fixed { return fixed }
        return provider?(NSAppearance(dark ? .darkAqua : .aqua)).rgba(dark: dark) ?? .black
    }
    var current: RGBA { rgba(dark: NSAppearance.current.isDark) }

    public func usingColorSpace(_ space: NSColorSpace) -> NSColor? { NSColor(rgba: current) }
    public func usingType(_ type: Int) -> NSColor? { self }
    public var redComponent: CGFloat { CGFloat(current.r) }
    public var greenComponent: CGFloat { CGFloat(current.g) }
    public var blueComponent: CGFloat { CGFloat(current.b) }
    public var alphaComponent: CGFloat { CGFloat(current.a) }
    public var whiteComponent: CGFloat { CGFloat((current.r + current.g + current.b) / 3) }
    public func getRed(_ r: UnsafeMutablePointer<CGFloat>?, green g: UnsafeMutablePointer<CGFloat>?, blue b: UnsafeMutablePointer<CGFloat>?, alpha a: UnsafeMutablePointer<CGFloat>?) {
        let c = current
        r?.pointee = CGFloat(c.r); g?.pointee = CGFloat(c.g); b?.pointee = CGFloat(c.b); a?.pointee = CGFloat(c.a)
    }
    public var cgColor: CGColor { let c = current; return CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a)) }
    public func withAlphaComponent(_ a: CGFloat) -> NSColor {
        if let fixed { return NSColor(rgba: fixed.withAlpha(Double(a))) }
        let base = self
        return NSColor(name: nil) { ap in NSColor(rgba: base.rgba(dark: ap.isDark).withAlpha(Double(a))) }
    }
    public func blended(withFraction f: CGFloat, of other: NSColor) -> NSColor? {
        let a = current, b = other.current, t = Double(f)
        return NSColor(rgba: RGBA(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t))
    }
    public func highlight(withLevel l: CGFloat) -> NSColor? { blended(withFraction: l, of: .white) }
    public func shadow(withLevel l: CGFloat) -> NSColor? { blended(withFraction: l, of: .black) }

    static func dynamic(_ light: UInt32, _ dark: UInt32, _ la: Double = 1, _ da: Double? = nil) -> NSColor {
        NSColor(name: nil) { a in NSColor(rgba: a.isDark ? RGBA(hex: dark, alpha: da ?? la) : RGBA(hex: light, alpha: la)) }
    }

    // Fixed and system colours (macOS's values).
    public static let clear = NSColor(rgba: .clear)
    public static let black = NSColor(rgba: .black)
    public static let white = NSColor(rgba: .white)
    public static let gray = NSColor(rgba: RGBA(0.5, 0.5, 0.5))
    public static let darkGray = NSColor(rgba: RGBA(1 / 3.0, 1 / 3.0, 1 / 3.0))
    public static let lightGray = NSColor(rgba: RGBA(2 / 3.0, 2 / 3.0, 2 / 3.0))
    public static let red = NSColor(rgba: RGBA(1, 0, 0)), green = NSColor(rgba: RGBA(0, 1, 0)), blue = NSColor(rgba: RGBA(0, 0, 1))
    public static let orange = NSColor(rgba: RGBA(1, 0.5, 0)), yellow = NSColor(rgba: RGBA(1, 1, 0)), purple = NSColor(rgba: RGBA(0.5, 0, 0.5))
    public static let brown = NSColor(rgba: RGBA(0.6, 0.4, 0.2)), cyan = NSColor(rgba: RGBA(0, 1, 1)), magenta = NSColor(rgba: RGBA(1, 0, 1))
    public static let systemRed = dynamic(0xff3b30, 0xff453a), systemOrange = dynamic(0xff9500, 0xff9f0a), systemYellow = dynamic(0xffcc00, 0xffd60a)
    public static let systemGreen = dynamic(0x28cd41, 0x32d74b), systemMint = dynamic(0x00c7be, 0x66d4cf), systemTeal = dynamic(0x59adc4, 0x6ac4dc)
    public static let systemCyan = dynamic(0x55bef0, 0x5ac8f5), systemBlue = dynamic(0x007aff, 0x0a84ff), systemIndigo = dynamic(0x5856d6, 0x5e5ce6)
    public static let systemPurple = dynamic(0xaf52de, 0xbf5af2), systemPink = dynamic(0xff2d55, 0xff375f), systemBrown = dynamic(0xa2845e, 0xac8e68)
    public static let systemGray = dynamic(0x8e8e93, 0x98989d)
    public static let labelColor = dynamic(0x000000, 0xffffff, 0.85)
    public static let secondaryLabelColor = dynamic(0x000000, 0xffffff, 0.5)
    public static let tertiaryLabelColor = dynamic(0x000000, 0xffffff, 0.26)
    public static let quaternaryLabelColor = dynamic(0x000000, 0xffffff, 0.1)
    public static let quinaryLabel = dynamic(0x000000, 0xffffff, 0.05)
    // Fills for shapes and controls (macOS 14), most to least prominent.
    public static let systemFill = dynamic(0x000000, 0xffffff, 0.18)
    public static let secondarySystemFill = dynamic(0x000000, 0xffffff, 0.14)
    public static let tertiarySystemFill = dynamic(0x000000, 0xffffff, 0.1)
    public static let quaternarySystemFill = dynamic(0x000000, 0xffffff, 0.06)
    public static let quinarySystemFill = dynamic(0x000000, 0xffffff, 0.03)
    public static let textColor = dynamic(0x000000, 0xffffff)
    public static let placeholderTextColor = dynamic(0x000000, 0xffffff, 0.25)
    public static let selectedTextColor = dynamic(0x000000, 0xffffff)
    public static let textBackgroundColor = dynamic(0xffffff, 0x1e1e1e)
    public static let selectedTextBackgroundColor = dynamic(0xb3d7ff, 0x3f638b)
    public static let windowBackgroundColor = dynamic(0xececec, 0x323232)
    public static let underPageBackgroundColor = dynamic(0x969696, 0x282828)
    public static let controlBackgroundColor = dynamic(0xffffff, 0x1e1e1e)
    public static let controlColor = dynamic(0xffffff, 0xffffff, 1, 0.25)
    public static let controlTextColor = dynamic(0x000000, 0xffffff, 0.85)
    public static let disabledControlTextColor = dynamic(0x000000, 0xffffff, 0.25)
    public static let controlAccentColor = dynamic(0x007aff, 0x0a84ff)
    public static let keyboardFocusIndicatorColor = dynamic(0x007aff, 0x1aa9ff, 0.5)
    public static let separatorColor = dynamic(0x000000, 0xffffff, 0.1)
    public static let gridColor = dynamic(0xe6e6e6, 0x1a1a1a)
    public static let linkColor = dynamic(0x0068da, 0x419cff)
    public static let selectedContentBackgroundColor = dynamic(0x0063e1, 0x0059d1)
    public static let unemphasizedSelectedContentBackgroundColor = dynamic(0xdcdcdc, 0x464646)
    public static let alternatingContentBackgroundColors = [NSColor.white, NSColor(rgba: RGBA(hex: 0xf4f5f5))]
    public static let findHighlightColor = dynamic(0xffff00, 0xffff00)
    public static let shadowColor = NSColor(rgba: .black)
    public static let headerTextColor = dynamic(0x000000, 0xffffff, 0.85)
}

/// Bridges NSColor providers to SwiftUI without a module cycle: SwiftUI
/// installs its registrar when it loads.
public enum ColorProviderRegistry {
    public nonisolated(unsafe) static var registrar: ((@escaping (Bool) -> RGBA) -> Int)?
    nonisolated(unsafe) static var pending: [Int: (Bool) -> RGBA] = [:]
    nonisolated(unsafe) static var next = 0
    static func register(_ f: @escaping (Bool) -> RGBA) -> Int {
        if let r = registrar { return r(f) }
        next -= 1
        pending[next] = f
        return next
    }
    /// Providers made before SwiftUI loaded.
    public static func resolvePending(_ id: Int, dark: Bool) -> RGBA? { pending[id]?(dark) }
}

// MARK: Fonts

public final class NSFont: NSObject, @unchecked Sendable {
    public struct Weight: RawRepresentable, Hashable, Sendable {
        public let rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public static let ultraLight = Weight(rawValue: -0.8), thin = Weight(rawValue: -0.6), light = Weight(rawValue: -0.4)
        public static let regular = Weight(rawValue: 0), medium = Weight(rawValue: 0.23), semibold = Weight(rawValue: 0.3)
        public static let bold = Weight(rawValue: 0.4), heavy = Weight(rawValue: 0.56), black = Weight(rawValue: 0.62)
        public var spec: FontWeightValue {
            switch rawValue {
            case ..<(-0.7): .ultraLight
            case ..<(-0.5): .thin
            case ..<(-0.2): .light
            case ..<0.15: .regular
            case ..<0.27: .medium
            case ..<0.35: .semibold
            case ..<0.5: .bold
            case ..<0.6: .heavy
            default: .black
            }
        }
    }
    public enum TextStyle: Sendable { case largeTitle, title1, title2, title3, headline, subheadline, body, callout, footnote, caption1, caption2 }
    public let spec: FontSpec
    public init(spec: FontSpec) { self.spec = spec; super.init() }

    /// Fonts with the same face and size are equal, as on the Mac.
    public override func isEqual(_ object: Any?) -> Bool { (object as? NSFont)?.spec == spec }
    public override var hash: Int { spec.hashValue }
    public convenience init?(name: String, size: CGFloat) { self.init(spec: FontSpec(size: size, family: name)) }
    public var pointSize: CGFloat { spec.size }
    /// A family's name, else the system font's: "System", or for its other
    /// designs a hidden (dot) name like the Mac's, so they're told apart.
    public var fontName: String {
        if let f = spec.family { return f }
        switch spec.design {
        case .default: return "System"
        case .serif: return ".AppleSystemUIFontSerif"
        case .rounded: return ".AppleSystemUIFontRounded"
        case .monospaced: return ".AppleSystemUIFontMonospaced"
        }
    }
    public var familyName: String? { spec.family ?? "System" }
    public var displayName: String? { fontName }
    public static func systemFont(ofSize size: CGFloat) -> NSFont { NSFont(spec: FontSpec(size: size)) }
    public static func systemFont(ofSize size: CGFloat, weight: Weight) -> NSFont { NSFont(spec: FontSpec(size: size, weight: weight.spec)) }
    public static func boldSystemFont(ofSize size: CGFloat) -> NSFont { NSFont(spec: FontSpec(size: size, weight: .bold)) }
    public static func monospacedDigitSystemFont(ofSize size: CGFloat, weight: Weight) -> NSFont { NSFont(spec: FontSpec(size: size, weight: weight.spec, monospacedDigit: true)) }
    public static func monospacedSystemFont(ofSize size: CGFloat, weight: Weight) -> NSFont { NSFont(spec: FontSpec(size: size, weight: weight.spec, design: .monospaced)) }
    public static func preferredFont(forTextStyle style: TextStyle, options: [AnyHashable: Any] = [:]) -> NSFont {
        let size: CGFloat = switch style {
        case .largeTitle: 26
        case .title1: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .subheadline: 11
        case .callout: 12
        case .footnote, .caption1, .caption2: 10
        }
        return NSFont(spec: FontSpec(size: size, weight: style == .headline ? .bold : .regular))
    }
    public static var systemFontSize: CGFloat { 13 }
    public static func systemFontSize(for controlSize: NSControl.ControlSize) -> CGFloat {
        switch controlSize {
        case .mini: return 9
        case .small: return 11
        case .large, .extraLarge: return 15
        default: return 13
        }
    }
    public static var smallSystemFontSize: CGFloat { 11 }
    public static func labelFont(ofSize size: CGFloat) -> NSFont { systemFont(ofSize: size) }
    public var ascender: CGFloat { spec.size * 0.95 }
    public var descender: CGFloat { -spec.size * 0.25 }
    public var capHeight: CGFloat { spec.size * 0.7 }
    public var xHeight: CGFloat { spec.size * 0.5 }
    public var leading: CGFloat { 0 }
}

// MARK: Images

public final class NSImage: NSObject, @unchecked Sendable {
    public enum Source: Sendable { case file(String), symbol(String), pixels(Int, Int, [UInt8]), empty }
    public let source: Source
    public var size: CGSize
    public var isTemplate = false
    public var accessibilityDescription: String?

    public init(size: CGSize) { source = .empty; self.size = size; super.init() }
    /// An empty image with no size.
    public override convenience init() { self.init(size: .zero) }
    public init(width: Int, height: Int, rgba: [UInt8]) { source = .pixels(width, height, rgba); size = CGSize(width: width, height: height); super.init() }
    public init?(contentsOf url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        source = .file(url.path)
        size = CGSize(width: 0, height: 0)
        super.init()
        if let img = decoded { size = CGSize(width: img.width, height: img.height) }
    }
    /// Decodes PNG, JPEG, GIF, TIFF, WebP… (ImageIO; GdkPixbuf on Linux).
    public convenience init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as NSData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.init(cgImage: img, size: .zero)
    }
    public convenience init?(dataIgnoringOrientation data: Data) { self.init(data: data) }
    public convenience init?(byReferencing url: URL) { self.init(contentsOf: url) }
    public convenience init?(byReferencingFile path: String) { self.init(contentsOf: URL(fileURLWithPath: path)) }
    private var _decoded: CGImage??
    /// The image's pixels (files decoded once, on first use).
    var decoded: CGImage? {
        if let d = _decoded { return d }
        let img: CGImage?
        switch source {
        case let .pixels(w, h, px): img = CGImage(width: w, height: h, rgba: px)
        case let .file(p):
            img = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as NSURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        default: img = nil
        }
        _decoded = .some(img)
        return img
    }
    /// Adds a bitmap representation: an image made empty (`init(size:)`)
    /// takes its pixels, as drawing it would.
    public func addRepresentation(_ rep: NSImageRep) {
        guard decoded == nil, let bitmap = rep as? NSBitmapImageRep, let img = bitmap.cgImage else { return }
        _decoded = .some(img)
    }
    public func addRepresentations(_ reps: [NSImageRep]) { reps.forEach(addRepresentation) }
    public func removeRepresentation(_ rep: NSImageRep) {}
    public var tiffRepresentation: Data? { pngData }
    /// PNG-encoded pixels (Runway).
    public var pngData: Data? {
        guard let img = decoded else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as NSString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
    public convenience init?(contentsOfFile path: String) { self.init(contentsOf: URL(fileURLWithPath: path)) }
    public init?(systemSymbolName name: String, accessibilityDescription: String?) {
        source = .symbol(name)
        size = CGSize(width: 16, height: 16)
        self.accessibilityDescription = accessibilityDescription
        super.init()
    }
    /// An image set of the app's asset catalogs or an image file among its
    /// resources; else one of AppKit's own named images, as a symbol.
    public convenience init?(named name: String) {
        if let found = RunwayAssets.resolveImage(named: name, dark: NSAppearance.current.isDark, scale: 2) {
            self.init(contentsOf: URL(fileURLWithPath: found.path))
            isTemplate = found.template
            if found.scale > 1 { size = CGSize(width: size.width / CGFloat(found.scale), height: size.height / CGFloat(found.scale)) }
        } else if name.hasPrefix("NS"), let symbol = NSImage.systemImageSymbols[name] {
            self.init(systemSymbolName: symbol, accessibilityDescription: nil)
            isTemplate = true
        } else {
            return nil
        }
    }
    /// AppKit's named images (`NSImage.Name.addTemplate`…) as SF Symbol names.
    static let systemImageSymbols: [String: String] = [
        "NSTouchBarIconViewTemplate": "square.grid.2x2", "NSTouchBarListViewTemplate": "list.bullet", "NSTouchBarComposeTemplate": "square.and.pencil",
        "NSTouchBarDeleteTemplate": "trash", "NSActionTemplate": "gearshape", "NSAddTemplate": "plus", "NSRemoveTemplate": "minus", "NSRefreshTemplate": "arrow.clockwise",
        "NSStopProgressTemplate": "xmark", "NSShareTemplate": "square.and.arrow.up", "NSLockLockedTemplate": "lock",
        "NSLockUnlockedTemplate": "lock.open", "NSGoLeftTemplate": "chevron.left", "NSGoRightTemplate": "chevron.right",
        "NSGoBackTemplate": "chevron.left", "NSGoForwardTemplate": "chevron.right", "NSLeftFacingTriangleTemplate": "arrowtriangle.left.fill",
        "NSRightFacingTriangleTemplate": "arrowtriangle.right.fill", "NSListViewTemplate": "list.bullet", "NSIconViewTemplate": "square.grid.2x2",
        "NSColumnViewTemplate": "rectangle.split.3x1", "NSQuickLookTemplate": "eye", "NSRevealFreestandingTemplate": "magnifyingglass",
        "NSFollowLinkFreestandingTemplate": "arrow.right.circle", "NSStopProgressFreestandingTemplate": "xmark.circle.fill",
        "NSRefreshFreestandingTemplate": "arrow.clockwise.circle", "NSInvalidDataFreestandingTemplate": "exclamationmark.circle",
        "NSCaution": "exclamationmark.triangle", "NSInfo": "info.circle", "NSFolder": "folder", "NSTrashEmpty": "trash", "NSTrashFull": "trash.fill",
        "NSUser": "person", "NSUserGroup": "person.2", "NSEveryone": "person.3", "NSNetwork": "network", "NSComputer": "desktopcomputer",
        "NSPreferencesGeneral": "gearshape", "NSAdvanced": "gearshape.2", "NSUserAccounts": "person.crop.circle", "NSColorPanel": "paintpalette",
        "NSFontPanel": "textformat", "NSBookmarksTemplate": "book", "NSHomeTemplate": "house", "NSMenuOnStateTemplate": "checkmark",
        "NSMenuMixedStateTemplate": "minus", "NSStatusAvailable": "circle.fill", "NSStatusUnavailable": "circle.fill",
        "NSStatusPartiallyAvailable": "circle.fill", "NSStatusNone": "circle", "NSTouchBarAddTemplate": "plus", "NSSmartBadgeTemplate": "gearshape",
        "NSSlideshowTemplate": "play.rectangle", "NSPathTemplate": "point.topleft.down.curvedto.point.bottomright.up", "NSEnterFullScreenTemplate": "arrow.up.left.and.arrow.down.right",
        "NSExitFullScreenTemplate": "arrow.down.right.and.arrow.up.left", "NSApplicationIcon": "app", "NSMultipleDocuments": "doc.on.doc",
        "NSBluetoothTemplate": "dot.radiowaves.left.and.right", "NSTouchBarSearchTemplate": "magnifyingglass", "NSFlowViewTemplate": "rectangle.stack",
        "NSLeftFacingTriangle": "arrowtriangle.left.fill", "NSRightFacingTriangle": "arrowtriangle.right.fill", "NSMobileMe": "icloud", "NSBonjour": "network",
    ]
    public init(cgImage: CGImage, size: CGSize) {
        source = .pixels(cgImage.width, cgImage.height, cgImage.pixels)
        self.size = size == .zero ? CGSize(width: cgImage.width, height: cgImage.height) : size
        super.init()
    }
    public func cgImage(forProposedRect rect: UnsafeMutablePointer<CGRect>?, context: Any?, hints: [AnyHashable: Any]?) -> CGImage? {
        decoded
    }
    public var imageSource: ImageSource {
        switch source {
        case let .file(p): .file(p)
        case let .symbol(s): .symbol(s)
        case let .pixels(w, h, px): .pixels(width: w, height: h, rgba: px)
        case .empty: .none
        }
    }
    public func withSymbolConfiguration(_ c: SymbolConfiguration) -> NSImage? { self }
    public func lockFocus() {}
    public func unlockFocus() {}
}

// MARK: Pasteboard

public protocol NSPasteboardWriting {}
extension NSURL: NSPasteboardWriting {}
extension NSString: NSPasteboardWriting {}
extension NSImage: NSPasteboardWriting {}

@preconcurrency @MainActor
public final class NSPasteboard: NSObject {
    public struct PasteboardType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let string = PasteboardType("public.utf8-plain-text")
        public static let fileURL = PasteboardType("public.file-url")
        public static let URL = PasteboardType("public.url")
        public static let png = PasteboardType("public.png")
        public static let tiff = PasteboardType("public.tiff")
        public static let html = PasteboardType("public.html")
        public static let rtf = PasteboardType("public.rtf")
        public static let pdf = PasteboardType("com.adobe.pdf")
    }
    public struct Name: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let general = Name(rawValue: "Apple CFPasteboard general")
        public static let find = Name(rawValue: "Apple CFPasteboard find")
        public static let drag = Name(rawValue: "Apple CFPasteboard drag")
    }
    public static let general = NSPasteboard()
    /// The general pasteboard is the system clipboard; others (find, drag,
    /// unique) are kept in the app.
    public init(name: Name) {
        super.init()
        if name != .general {
            if let p = Self.named[name] { local = p.local; localData = p.localData } else { local = ([], []) }
            self.name = name
            Self.named[name] = self
        }
    }
    private static var named: [Name: NSPasteboard] = [:]
    public private(set) var name: Name = .general
    public static func withUniqueName() -> NSPasteboard { NSPasteboard.dragPasteboard(files: [], strings: []) }
    public struct ReadingOptionKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let urlReadingFileURLsOnly = ReadingOptionKey(rawValue: "NSPasteboardURLReadingFileURLsOnlyKey")
        public static let urlReadingContentsConformToTypes = ReadingOptionKey(rawValue: "NSPasteboardURLReadingContentsConformToTypesKey")
    }
    /// A drag's contents: kept here rather than on the clipboard.
    var local: (files: [URL], strings: [String])?
    /// Other types' data (an image's PNG…) on an in-app pasteboard.
    private var localData: [PasteboardType: Data] = [:]
    /// Forgets a named pasteboard.
    public func releaseGlobally() { if name != .general { Self.named[name] = nil } }
    static func dragPasteboard(files: [URL], strings: [String]) -> NSPasteboard {
        let p = NSPasteboard()
        p.local = (files, strings)
        return p
    }
    override init() { super.init() }
    public private(set) var changeCount = 0

    @discardableResult public func clearContents() -> Int {
        changeCount += 1
        if local != nil { local = ([], []); localData = [:] }
        syncNamed()
        return changeCount
    }
    private func syncNamed() { if name != .general { Self.named[name]?.local = local; Self.named[name]?.localData = localData } }
    private static let textTypes: Set<PasteboardType> = [.string, PasteboardType("public.plain-text"), PasteboardType("NSStringPboardType")]
    @discardableResult public func setString(_ string: String, forType type: PasteboardType) -> Bool {
        if local != nil { local!.strings.append(string); syncNamed(); return true }
        Runway.backend.services.copyToClipboard(string: string)
        return true
    }
    @discardableResult public func setData(_ data: Data?, forType type: PasteboardType) -> Bool {
        if local != nil, let d = data, !Self.textTypes.contains(type) {
            localData[type] = d
            syncNamed()
            return true
        }
        if let d = data, let s = String(data: d, encoding: .utf8) { return setString(s, forType: type) }
        return false
    }
    public func declareTypes(_ types: [PasteboardType], owner: Any?) -> Int { changeCount }
    @discardableResult public func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        let urls = objects.compactMap { ($0 as? NSURL).map { $0 as URL } }
        if local != nil {
            // An in-app pasteboard keeps everything: files, text and images (as PNG).
            local!.files += urls
            for o in objects {
                if let s = o as? NSString { local!.strings.append(s as String) }
                if let image = o as? NSImage, let png = image.pngData { localData[.png] = png }
            }
            syncNamed()
            return !objects.isEmpty
        }
        if !urls.isEmpty { Runway.backend.services.copyToClipboard(fileURLs: urls); return true }
        let strings = objects.compactMap { o -> String? in
            if let s = o as? NSString { return s as String }
            if let item = o as? NSPasteboardItem { return item.string(forType: .string) ?? item.types.lazy.compactMap { item.string(forType: $0) }.first }
            return nil
        }
        if let s = strings.first { return setString(s, forType: .string) }
        return false
    }
    public func string(forType type: PasteboardType) -> String? {
        if let local {
            if type == .fileURL || type == .URL { return local.files.first?.absoluteString }
            return local.strings.first ?? (local.files.isEmpty ? nil : local.files.map(\.path).joined(separator: "\n"))
        }
        return Runway.backend.services.clipboardString()
    }
    public func propertyList(forType type: PasteboardType) -> Any? {
        if let local, type.rawValue == "NSFilenamesPboardType" { return local.files.map(\.path) }
        return string(forType: type)
    }
    public func data(forType type: PasteboardType) -> Data? {
        if local != nil, let d = localData[type] { return d }
        if local != nil, !Self.textTypes.contains(type), type != .fileURL, type != .URL { return nil }
        return string(forType: type)?.data(using: .utf8)
    }
    public var types: [PasteboardType]? {
        if let local {
            return (local.files.isEmpty ? [] : [.fileURL, .URL]) + (local.strings.isEmpty ? [] : [.string]) + localData.keys.sorted { $0.rawValue < $1.rawValue }
        }
        return string(forType: .string) == nil ? [] : [.string]
    }
    public func availableType(from types: [PasteboardType]) -> PasteboardType? { types.first { self.types?.contains($0) ?? false } }
    public func canReadItem(withDataConformingToTypes types: [String]) -> Bool { !(self.types ?? []).isEmpty }
    /// The objects of the given classes (NSURL, NSString) on the
    /// pasteboard; `.urlReadingFileURLsOnly` keeps file URLs only.
    public func readObjects(forClasses classes: [AnyClass], options: [ReadingOptionKey: Any]? = nil) -> [Any]? {
        let fileURLsOnly = (options?[.urlReadingFileURLsOnly] as? Bool) ?? false
        if let local {
            let wantsURL = classes.contains { $0 == NSURL.self }
            let wantsString = classes.contains { $0 == NSString.self }
            var out: [Any] = []
            if wantsURL || !wantsString { out += local.files.filter { !fileURLsOnly || $0.isFileURL }.map { $0 as NSURL } }
            if (wantsString || !wantsURL) && !(fileURLsOnly && !wantsString) { out += local.strings.map { $0 as NSString } }
            return out.isEmpty ? nil : out
        }
        guard let s = string(forType: .string) else { return nil }
        let urls = s.split(separator: "\n").compactMap { line -> URL? in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("file://") { return URL(string: t) }
            if t.hasPrefix("/") { return URL(fileURLWithPath: t) }
            return nil
        }
        return urls.isEmpty ? [s] : urls
    }
    public func canReadObject(forClasses classes: [AnyClass], options: [ReadingOptionKey: Any]? = nil) -> Bool {
        readObjects(forClasses: classes, options: options) != nil
    }
}

// MARK: Workspace

/// Usable from any thread, as AppKit's is: the work that touches the
/// platform runs on the main thread.
public final class NSWorkspace: NSObject, @unchecked Sendable {
    public static let shared = NSWorkspace()
    public static let didWakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")
    public static let willSleepNotification = Notification.Name("NSWorkspaceWillSleepNotification")
    public let notificationCenter = NotificationCenter()

    /// xdg-open on Linux, ShellExecute on Windows.
    @discardableResult public func open(_ url: URL) -> Bool { onMainThread { Runway.backend.services.open(url) } }
    public func open(_ url: URL, configuration: OpenConfiguration, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        let ok = open(url)
        completionHandler?(nil, ok ? nil : CocoaError(.fileNoSuchFile))
    }
    /// Makes an application the handler of a URL scheme (xdg-mime on Linux).
    public func setDefaultApplication(at app: URL, toOpenURLsWithScheme scheme: String) async throws {
        guard let id = DesktopApps.desktopID(for: app) else { throw CocoaError(.fileNoSuchFile) }
        guard DesktopApps.run("xdg-mime", ["default", id + ".desktop", "x-scheme-handler/" + scheme.lowercased()]) != nil else {
            throw CocoaError(.featureUnsupported)
        }
    }
    public func setDefaultApplication(at app: URL, toOpenURLsWithScheme scheme: String, completion: @escaping ((any Error)?) -> Void) {
        Task {
            do { try await setDefaultApplication(at: app, toOpenURLsWithScheme: scheme); completion(nil) } catch { completion(error) }
        }
    }
    public func setDefaultApplication(at app: URL, toOpen type: UTType) async throws {
        guard let id = DesktopApps.desktopID(for: app), let mime = type.preferredMIMEType else { throw CocoaError(.fileNoSuchFile) }
        _ = DesktopApps.run("xdg-mime", ["default", id + ".desktop", mime])
    }

    /// The file manager, with the files selected where it can.
    public func activateFileViewerSelecting(_ urls: [URL]) { onMainThread { Runway.backend.services.reveal(urls) } }
    @discardableResult public func selectFile(_ path: String?, inFileViewerRootedAtPath root: String) -> Bool {
        if let p = path { activateFileViewerSelecting([URL(fileURLWithPath: p)]) } else { _ = open(URL(fileURLWithPath: root)) }
        return true
    }
    public func icon(forFile path: String) -> NSImage { onMainThread { NSImage(systemSymbolName: "doc", accessibilityDescription: nil)! } }
    public func icon(for type: UTType) -> NSImage { onMainThread { NSImage(systemSymbolName: "doc", accessibilityDescription: nil)! } }
    /// The application with a bundle identifier: on Linux a desktop entry
    /// (Mac identifiers of common apps map to theirs), as an app bundle.
    public func urlForApplication(withBundleIdentifier id: String) -> URL? { DesktopApps.application(withIdentifier: id) }
    /// The default handler for a URL (xdg-mime on Linux), as an app bundle.
    public func urlForApplication(toOpen url: URL) -> URL? { DesktopApps.defaultApplication(for: url) }
    public func recycle(_ urls: [URL], completionHandler: (([URL: URL], Error?) -> Void)? = nil) {
        var moved: [URL: URL] = [:]
        var lastError: Error?
        for u in urls {
            do {
                var out: NSURL?
                try FileManager.default.trashItem(at: u, resultingItemURL: &out)
                if let o = out { moved[u] = o as URL }
            } catch { lastError = error }
        }
        completionHandler?(moved, lastError)
    }
    public final class OpenConfiguration: @unchecked Sendable {
        public init() {}
        public var activates = true
        public var promptsUserIfNeeded = true
    }
    public var frontmostApplication: NSRunningApplication? { NSRunningApplication.current }
    /// The user's graphical processes (those with a display connection).
    public var runningApplications: [NSRunningApplication] { NSRunningApplication.graphicalProcesses() }
    public var menuBarOwningApplication: NSRunningApplication? { nil }
}

public final class NSRunningApplication: NSObject, @unchecked Sendable {
    public struct ActivationOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let activateAllWindows = ActivationOptions(rawValue: 1)
        public static let activateIgnoringOtherApps = ActivationOptions(rawValue: 2)
    }

    public static let current = NSRunningApplication(pid: ProcessInfo.processInfo.processIdentifier)
    public let processIdentifier: Int32
    init(pid: Int32) { processIdentifier = pid; super.init() }
    public convenience init?(processIdentifier pid: Int32) {
        guard pid == ProcessInfo.processInfo.processIdentifier || FileManager.default.fileExists(atPath: "/proc/\(pid)") else { return nil }
        self.init(pid: pid)
    }

    var isCurrent: Bool { processIdentifier == ProcessInfo.processInfo.processIdentifier }
    private func proc(_ file: String) -> String? {
        (try? String(contentsOfFile: "/proc/\(processIdentifier)/\(file)", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Other processes' apps by bundle identifier: matched against their
    /// executable name (Linux has no bundle identifiers).
    public static func runningApplications(withBundleIdentifier id: String) -> [NSRunningApplication] {
        if id == Bundle.main.bundleIdentifier { return [current] }
        let last = id.split(separator: ".").last.map { String($0).lowercased() } ?? id.lowercased()
        return NSWorkspace.shared.runningApplications.filter { !$0.isCurrent && $0.executableURL?.lastPathComponent.lowercased() == last }
    }

    public var bundleIdentifier: String? { isCurrent ? Bundle.main.bundleIdentifier : nil }
    public var localizedName: String? {
        isCurrent ? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName) : proc("comm")
    }
    public var executableURL: URL? {
        if isCurrent { return Bundle.main.executableURL }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(processIdentifier)/exe")).map { URL(fileURLWithPath: $0) }
    }
    public var bundleURL: URL? { isCurrent ? Bundle.main.bundleURL : executableURL?.deletingLastPathComponent() }
    public var executableArchitecture: Int { 0x01000007 }
    public var launchDate: Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: "/proc/\(processIdentifier)") else { return nil }
        return attrs[.modificationDate] as? Date
    }
    public var icon: NSImage? { nil }
    public var isActive: Bool { isCurrent }
    public var isHidden: Bool { false }
    public var isFinishedLaunching: Bool { true }
    public var isTerminated: Bool { !isCurrent && !FileManager.default.fileExists(atPath: "/proc/\(processIdentifier)") }
    public var ownsMenuBar: Bool { isCurrent }
    public var activationPolicy: NSApplication.ActivationPolicy { .regular }
    @discardableResult public func activate(options: ActivationOptions = []) -> Bool { isCurrent }
    @discardableResult public func activate(from app: NSRunningApplication, options: ActivationOptions = []) -> Bool { isCurrent }
    @discardableResult public func hide() -> Bool { false }
    @discardableResult public func unhide() -> Bool { false }
    @discardableResult public func terminate() -> Bool { signal(15) }
    @discardableResult public func forceTerminate() -> Bool { signal(9) }
    private func signal(_ sig: Int32) -> Bool {
        #if canImport(Glibc)
        return isCurrent ? false : kill(processIdentifier, sig) == 0
        #else
        return false
        #endif
    }
    public override func isEqual(_ object: Any?) -> Bool { (object as? NSRunningApplication)?.processIdentifier == processIdentifier }
    public override var hash: Int { Int(processIdentifier) }

    /// The user's processes with a display connection: GUI apps, roughly
    /// what the Mac's list of running applications shows.
    /// /proc files report size 0: read them in chunks.
    static func readProcFile(_ path: String) -> [UInt8]? {
        #if canImport(Glibc)
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var out: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return out
        #else
        return nil
        #endif
    }

    static func graphicalProcesses() -> [NSRunningApplication] {
        var out: [NSRunningApplication] = []
        #if canImport(Glibc)
        let uid = getuid()
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] {
            guard let pid = Int32(entry) else { continue }
            var st = stat()
            guard stat("/proc/\(entry)", &st) == 0, st.st_uid == uid else { continue }
            guard let env = readProcFile("/proc/\(entry)/environ") else { continue }
            let vars = env.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            guard vars.contains(where: { $0.hasPrefix("DISPLAY=") || $0.hasPrefix("WAYLAND_DISPLAY=") }) else { continue }
            out.append(pid == ProcessInfo.processInfo.processIdentifier ? .current : NSRunningApplication(pid: pid))
        }
        #endif
        if !out.contains(where: { $0.isCurrent }) { out.append(.current) }
        return out.sorted { $0.processIdentifier < $1.processIdentifier }
    }
}

// MARK: Sound

/// System sounds by name: Glass, Ping, Basso… map to the freedesktop sound
/// theme on Linux and to Windows' system sounds.
@preconcurrency @MainActor
public final class NSSound: NSObject {
    public typealias Name = String
    public let name: String
    public var volume: Float = 1
    public var loops = false
    public init?(named name: Name) { self.name = name; super.init() }
    public init?(contentsOf url: URL, byReference: Bool) { name = url.path; super.init() }
    @discardableResult public func play() -> Bool { Runway.backend.services.playSound(named: name) }
    @discardableResult public func stop() -> Bool { true }
    public var isPlaying: Bool { false }
    public static func beep() { Runway.backend.services.beep() }
}

// MARK: Panels and alerts

@preconcurrency @MainActor
open class NSSavePanel: NSObject {
    open var title: String?
    open var message: String?
    open var prompt: String?
    open var nameFieldStringValue = ""
    open var directoryURL: URL?
    open var allowedContentTypes: [UTType] = []
    open var canCreateDirectories = true
    open var showsHiddenFiles = false
    open var isExtensionHidden = false
    open var treatsFilePackagesAsDirectories = false
    open var allowsOtherFileTypes = false
    open var allowedFileTypes: [String]? {
        get { allowedContentTypes.isEmpty ? nil : allowedContentTypes.compactMap { $0.preferredFilenameExtension } }
        set { allowedContentTypes = (newValue ?? []).compactMap { UTType(filenameExtension: $0) } }
    }
    open var accessoryView: NSView?
    open var isAccessoryViewDisclosed = false
    open var canSelectHiddenExtension = false
    open var nameFieldLabel: String?
    open var identifier: NSUserInterfaceItemIdentifier?
    open internal(set) var url: URL?
    public override init() { super.init() }
    public static func savePanel() -> NSSavePanel { NSSavePanel() }

    open func runModal() -> NSApplication.ModalResponse {
        url = Runway.backend.services.chooseSaveLocation(title: title ?? message ?? "Save", suggestedName: nameFieldStringValue)
        return url == nil ? .cancel : .OK
    }
    open func begin(completionHandler: @escaping (NSApplication.ModalResponse) -> Void) { completionHandler(runModal()) }
    open func beginSheetModal(for window: NSWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) { completionHandler(runModal()) }
}

@preconcurrency @MainActor
public final class NSOpenPanel: NSSavePanel {
    public var allowsMultipleSelection = false
    public var canChooseDirectories = false
    public var canChooseFiles = true
    public var resolvesAliases = true
    public private(set) var urls: [URL] = []
    public static func openPanel() -> NSOpenPanel { NSOpenPanel() }
    public override func runModal() -> NSApplication.ModalResponse {
        let exts = allowedContentTypes.flatMap { $0.tags[.filenameExtension] ?? [] }
        urls = Runway.backend.services.chooseFiles(title: title ?? message ?? "Open", allowsMultiple: allowsMultipleSelection,
                                                    canChooseDirectories: canChooseDirectories, extensions: exts) ?? []
        url = urls.first
        return urls.isEmpty ? .cancel : .OK
    }
}

@preconcurrency @MainActor
public final class NSAlert: NSObject {
    public enum Style: UInt, Sendable { case warning, informational, critical }
    public var messageText = ""
    public var informativeText = ""
    public var alertStyle: Style = .warning
    public var icon: NSImage?
    public var showsSuppressionButton = false
    /// The "Do not show this message again" checkbox; its state is kept
    /// (the toolkit's alert has no checkbox of its own).
    public lazy var suppressionButton: NSButton? = NSButton(checkboxWithTitle: "Do not show this message again", target: nil, action: nil)
    public var showsHelp = false
    public var helpAnchor: String?
    /// A view shown under the informative text.
    public var accessoryView: NSView?
    /// The alert's panel.
    public private(set) lazy var window: NSWindow = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                                                            styleMask: [.titled], backing: .buffered, defer: true)
    public func layout() {}
    public private(set) var buttons: [NSAlertButton] = []
    public override init() { super.init() }
    public convenience init(error: Error) {
        self.init()
        messageText = error.localizedDescription
    }
    @discardableResult public func addButton(withTitle title: String) -> NSAlertButton {
        let b = NSAlertButton(title: title)
        buttons.append(b)
        return b
    }
    public func runModal() -> NSApplication.ModalResponse {
        let titles = buttons.isEmpty ? ["OK"] : buttons.map(\.title)
        let destructive = buttons.firstIndex { $0.hasDestructiveAction }
        let i = Runway.backend.services.alert(title: messageText, message: informativeText, buttons: titles, destructive: destructive)
        return NSApplication.ModalResponse(rawValue: 1000 + i)
    }
    public func beginSheetModal(for window: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        completionHandler?(runModal())
    }
}

public final class NSAlertButton {
    public let title: String
    public var hasDestructiveAction = false
    public var keyEquivalent = ""
    init(title: String) { self.title = title }
}

// MARK: Desktop applications as bundles

/// Desktop entries seen through AppKit's bundle-based APIs. Each is shown
/// as a small `.app` bundle (in the user's cache) whose Info.plist holds
/// the entry's id as `CFBundleIdentifier`, its name, and its URL schemes,
/// so `Bundle(url:)` and display names work on them as on a Mac.
enum DesktopApps {
    static let aliases: [String: [String]] = [
        "com.apple.Safari": ["org.gnome.Epiphany", "epiphany"],
        "com.google.Chrome": ["google-chrome", "com.google.Chrome", "chromium", "chromium-browser", "org.chromium.Chromium"],
        "org.mozilla.firefox": ["firefox", "org.mozilla.firefox", "firefox_firefox", "firefox-esr"],
        "com.microsoft.edgemac": ["microsoft-edge", "com.microsoft.Edge"],
        "com.brave.Browser": ["brave-browser", "com.brave.Browser"],
        "com.microsoft.VSCode": ["code", "com.visualstudio.code"],
        "com.apple.Terminal": ["org.gnome.Terminal", "org.gnome.Console", "konsole", "xterm"],
    ]

    static func run(_ tool: String, _ args: [String]) -> String? {
        #if os(Windows)
        return nil
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }

    static var dataDirs: [String] {
        let env = ProcessInfo.processInfo.environment
        let home = env["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.local/share")
        return [home] + (env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share").split(separator: ":").map(String.init)
            + ["/var/lib/flatpak/exports/share", NSHomeDirectory() + "/.local/share/flatpak/exports/share", "/var/lib/snapd/desktop"]
    }

    static func desktopFile(_ id: String) -> URL? {
        let name = id.hasSuffix(".desktop") ? id : id + ".desktop"
        for d in dataDirs {
            let p = d + "/applications/" + name
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    static func application(withIdentifier id: String) -> URL? {
        if id == Bundle.main.bundleIdentifier { return Bundle.main.bundleURL }
        for candidate in [id] + (aliases[id] ?? []) + [id.split(separator: ".").last.map { String($0).lowercased() } ?? id] {
            if let file = desktopFile(candidate) { return bundle(for: file) }
        }
        return nil
    }

    static func defaultApplication(for url: URL) -> URL? {
        let mime: String
        if url.isFileURL {
            guard let m = run("xdg-mime", ["query", "filetype", url.path]) ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType else { return nil }
            mime = m
        } else {
            guard let scheme = url.scheme?.lowercased() else { return nil }
            mime = "x-scheme-handler/" + scheme
        }
        guard let id = run("xdg-mime", ["query", "default", mime])?.split(separator: ";").first.map(String.init), !id.isEmpty,
              let file = desktopFile(id) else { return nil }
        return bundle(for: file)
    }

    /// The desktop id an application URL stands for (a stand-in bundle,
    /// a .desktop file, or this app).
    static func desktopID(for app: URL) -> String? {
        if app.pathExtension == "desktop" { return app.deletingPathExtension().lastPathComponent }
        if let b = Bundle(url: app), let entry = b.object(forInfoDictionaryKey: "RunwayDesktopEntry") as? String {
            return URL(fileURLWithPath: entry).deletingPathExtension().lastPathComponent
        }
        if app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL || app == Bundle.main.executableURL {
            return ownDesktopEntry().map { $0.deletingPathExtension().lastPathComponent }
        }
        return nil
    }

    /// This app's own desktop entry, written once so it can be a handler.
    static func ownDesktopEntry() -> URL? {
        guard let exe = Bundle.main.executableURL else { return nil }
        let id = (Bundle.main.bundleIdentifier ?? exe.lastPathComponent).replacingOccurrences(of: " ", with: "-")
        let dir = URL(fileURLWithPath: dataDirs[0]).appendingPathComponent("applications", isDirectory: true)
        let file = dir.appendingPathComponent(id + ".desktop")
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? exe.lastPathComponent
        let text = """
        [Desktop Entry]
        Type=Application
        Name=\(name)
        Exec="\(exe.path)" %U
        Terminal=false
        NoDisplay=false
        MimeType=x-scheme-handler/http;x-scheme-handler/https;

        """
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? String(contentsOf: file, encoding: .utf8)) != text { try? text.write(to: file, atomically: true, encoding: .utf8) }
        _ = run("update-desktop-database", [dir.path])
        return file
    }

    /// A stand-in bundle for a desktop entry.
    static func bundle(for desktop: URL) -> URL? {
        guard let text = try? String(contentsOf: desktop, encoding: .utf8) else { return nil }
        var name = desktop.deletingPathExtension().lastPathComponent
        var mimes: [String] = []
        var inEntry = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inEntry = line == "[Desktop Entry]"; continue }
            guard inEntry, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq], value = String(line[line.index(after: eq)...])
            if key == "Name" { name = value }
            if key == "MimeType" { mimes = value.split(separator: ";").map(String.init) }
        }
        let id = desktop.deletingPathExtension().lastPathComponent
        let schemes = mimes.filter { $0.hasPrefix("x-scheme-handler/") }.map { String($0.dropFirst("x-scheme-handler/".count)) }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("runway-apps/\(id)", isDirectory: true)
        let app = root.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-") + ".app", isDirectory: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleName": name, "CFBundleDisplayName": name, "CFBundlePackageType": "APPL",
            "RunwayDesktopEntry": desktop.path,
            "CFBundleURLTypes": [["CFBundleURLName": id, "CFBundleURLSchemes": schemes]],
            "CFBundleDocumentTypes": [["CFBundleTypeMIMETypes": mimes.filter { !$0.hasPrefix("x-scheme-handler/") }]],
        ]
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try? FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
            let plist = contents.appendingPathComponent("Info.plist")
            if (try? Data(contentsOf: plist)) != data { try? data.write(to: plist) }
        }
        return app
    }

    /// Starts an application with URLs: through GIO for a desktop entry, or
    /// the executable itself.
    @discardableResult
    static func launch(_ app: URL, _ urls: [URL]) -> Bool {
        #if os(Windows)
        return false
        #else
        let args = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }
        var entry: String?
        if app.pathExtension == "desktop" { entry = app.path }
        else if let b = Bundle(url: app), let e = b.object(forInfoDictionaryKey: "RunwayDesktopEntry") as? String { entry = e }
        let p = Process()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if let entry {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["gio", "launch", entry] + args
        } else if FileManager.default.isExecutableFile(atPath: app.path), !app.hasDirectoryPath {
            p.executableURL = app
            p.arguments = args
        } else if let exe = Bundle(url: app)?.executableURL {
            p.executableURL = exe
            p.arguments = args
        } else {
            return false
        }
        return (try? p.run()) != nil
        #endif
    }
}
