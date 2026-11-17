// Colours and colour spaces. Spaces are named as on Apple platforms; what
// drawing needs from them is whether components are linear light (linear
// sRGB family) or sRGB-encoded (everything else), and how many there are.

import Foundation

public enum CGColorSpaceModel: Int32, Sendable { case unknown = -1, monochrome = 0, rgb, cmyk, lab, deviceN, indexed, pattern, XYZ }
public enum CGColorRenderingIntent: Int32, Sendable { case defaultIntent = 0, absoluteColorimetric, relativeColorimetric, perceptual, saturation }

public final class CGColorSpace: @unchecked Sendable, Equatable {
    public static let sRGB: CFString = "kCGColorSpaceSRGB"
    public static let displayP3: CFString = "kCGColorSpaceDisplayP3"
    public static let linearSRGB: CFString = "kCGColorSpaceLinearSRGB"
    public static let extendedSRGB: CFString = "kCGColorSpaceExtendedSRGB"
    public static let extendedLinearSRGB: CFString = "kCGColorSpaceExtendedLinearSRGB"
    public static let extendedDisplayP3: CFString = "kCGColorSpaceExtendedDisplayP3"
    public static let linearDisplayP3: CFString = "kCGColorSpaceLinearDisplayP3"
    public static let extendedLinearDisplayP3: CFString = "kCGColorSpaceExtendedLinearDisplayP3"
    public static let genericRGBLinear: CFString = "kCGColorSpaceGenericRGBLinear"
    public static let genericGrayGamma2_2: CFString = "kCGColorSpaceGenericGrayGamma2_2"
    public static let linearGray: CFString = "kCGColorSpaceLinearGray"
    public static let extendedGray: CFString = "kCGColorSpaceExtendedGray"
    public static let extendedLinearGray: CFString = "kCGColorSpaceExtendedLinearGray"
    public static let genericGray: CFString = "kCGColorSpaceGenericGray"
    public static let genericRGB: CFString = "kCGColorSpaceGenericRGB"
    public static let itur_709: CFString = "kCGColorSpaceITUR_709"
    public static let itur_2020: CFString = "kCGColorSpaceITUR_2020"
    public static let adobeRGB1998: CFString = "kCGColorSpaceAdobeRGB1998"
    public static let genericCMYK: CFString = "kCGColorSpaceGenericCMYK"
    public static let dcip3: CFString = "kCGColorSpaceDCIP3"
    public static let rommrgb: CFString = "kCGColorSpaceROMMRGB"
    public static let acescgLinear: CFString = "kCGColorSpaceACESCGLinear"

    public let name: CFString?
    private let nameString: String
    public init?(name: CFString) {
        nameString = String(describing: name)
        self.name = name
    }
    public init() {
        nameString = String(describing: CGColorSpace.sRGB)
        name = CGColorSpace.sRGB
    }
    public convenience init?(iccData: CFData) { self.init(name: CGColorSpace.sRGB) }

    var isGray: Bool { nameString.contains("Gray") }
    /// Components are linear light (not sRGB-encoded).
    public var isLinear: Bool { nameString.contains("Linear") }
    public var numberOfComponents: Int { isGray ? 1 : (nameString.contains("CMYK") ? 4 : 3) }
    public var model: CGColorSpaceModel { isGray ? .monochrome : (nameString.contains("CMYK") ? .cmyk : .rgb) }
    public var isWideGamutRGB: Bool { nameString.contains("P3") || nameString.contains("2020") || nameString.contains("Extended") }
    public var supportsOutput: Bool { true }
    public var copyICCData: CFData? { nil }
    public static func == (a: CGColorSpace, b: CGColorSpace) -> Bool { a.nameString == b.nameString }
}

public func CGColorSpaceCreateDeviceRGB() -> CGColorSpace { CGColorSpace() }
public func CGColorSpaceCreateDeviceGray() -> CGColorSpace { CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! }
public func CGColorSpaceCreateWithName(_ name: CFString) -> CGColorSpace? { CGColorSpace(name: name) }

public final class CGColor: @unchecked Sendable, Equatable, CustomStringConvertible {
    public let components: [CGFloat]?
    public let colorSpace: CGColorSpace?
    public var alpha: CGFloat { components?.last ?? 1 }
    public var numberOfComponents: Int { components?.count ?? 0 }
    public init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) {
        components = [r, g, b, a]
        colorSpace = CGColorSpace()
    }
    public convenience init(red r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(srgbRed: r, green: g, blue: b, alpha: a) }
    public convenience init(gray: CGFloat, alpha: CGFloat) { self.init(srgbRed: gray, green: gray, blue: gray, alpha: alpha) }
    public convenience init(genericGrayGamma2_2Gray gray: CGFloat, alpha: CGFloat) { self.init(gray: gray, alpha: alpha) }
    public init?(colorSpace: CGColorSpace, components: UnsafePointer<CGFloat>) {
        let n = colorSpace.numberOfComponents + 1
        var c = Array(UnsafeBufferPointer(start: components, count: n))
        if colorSpace.isGray { c = [c[0], c[0], c[0], c[1]] }
        if colorSpace.isLinear {
            // Stored as sRGB-encoded, like every CGColor here.
            func enc(_ v: CGFloat) -> CGFloat { v <= 0.0031308 ? v * 12.92 : 1.055 * CGFloat(pow(Double(v), 1 / 2.4)) - 0.055 }
            c = [enc(c[0]), enc(c[1]), enc(c[2]), c[3]]
        }
        self.components = c
        self.colorSpace = CGColorSpace()
    }
    public static let white = CGColor(gray: 1, alpha: 1)
    public static let black = CGColor(gray: 0, alpha: 1)
    public static let clear = CGColor(gray: 0, alpha: 0)
    public static func == (l: CGColor, r: CGColor) -> Bool { l.components == r.components }
    public func copy(alpha: CGFloat) -> CGColor? {
        guard let c = components, c.count == 4 else { return nil }
        return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: alpha)
    }
    public func copy() -> CGColor? { self }
    public func converted(to space: CGColorSpace, intent: CGColorRenderingIntent, options: CFDictionary?) -> CGColor? { self }
    public var pattern: AnyObject? { nil }
    public var description: String { "CGColor(\(components ?? []))" }
}

public func CGColorCreateGenericRGB(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
public func CGColorCreateGenericGray(_ gray: CGFloat, _ a: CGFloat) -> CGColor { CGColor(gray: gray, alpha: a) }
public func CGColorGetComponents(_ c: CGColor) -> UnsafePointer<CGFloat>? { nil }
public func CGColorGetAlpha(_ c: CGColor) -> CGFloat { c.alpha }

/// Runway: anything that stands for a colour in attribute dictionaries
/// (AppKit's NSColor should conform), so CoreText can read text colours
/// without depending on AppKit.
public protocol CGColorRepresentable {
    var cgColor: CGColor { get }
}

/// sRGB transfer functions, shared by contexts and gradients.
enum Transfer {
    static func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : CGFloat(pow((Double(v) + 0.055) / 1.055, 2.4)) }
    static func encode(_ v: CGFloat) -> CGFloat { v <= 0.0031308 ? v * 12.92 : 1.055 * CGFloat(pow(Double(max(v, 0)), 1 / 2.4)) - 0.055 }
}
