// Core Image for Linux and Windows, on the CPU. A CIImage is a recipe (a
// tree of sources, transforms, crops and filters) with an extent in Core
// Image's bottom-left space; a CIContext evaluates the part it's asked for,
// tile by tile, in linear-light premultiplied Float32 (Core Image's default
// working space), and writes sRGB 8-bit or float results into CGImages,
// pixel buffers and bitmaps. Nothing is evaluated until something renders.

@_exported import CoreGraphics
@_exported import CoreVideo
@_exported import Foundation
@_exported import ImageIO
import Metal

// MARK: Colour conversion

enum Gamma {
    /// sRGB-encoded byte → linear.
    static let toLinear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }
    /// Linear → sRGB byte, by a 4096-step table.
    static let toSRGB: [UInt8] = (0..<4097).map { i in
        let c = Float(i) / 4096
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255).rounded())))
    }
    @inline(__always) static func encode(_ v: Float) -> UInt8 {
        guard v > 0 else { return 0 }
        guard v < 1 else { return 255 }
        return toSRGB[Int(v * 4096)]
    }
    static func linear(_ c: CGFloat) -> Float {
        let c = Float(c)
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }
    static func srgb(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
    }
}

/// A rectangle of linear premultiplied RGBA: `rect` is integral, rows bottom to top.
struct Tile {
    let x: Int, y: Int, w: Int, h: Int
    var px: [Float]
    init(_ r: (Int, Int, Int, Int), fill: Float = 0) {
        (x, y, w, h) = r
        px = [Float](repeating: fill, count: max(r.2 * r.3 * 4, 0))
    }
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    @inline(__always) func index(_ px: Int, _ py: Int) -> Int { ((py - y) * w + (px - x)) * 4 }
}

func ints(_ r: CGRect) -> (Int, Int, Int, Int) {
    guard !r.isNull, !r.isEmpty, r.width.isFinite, r.height.isFinite else { return (0, 0, 0, 0) }
    let x0 = Int(r.minX.rounded(.down)), y0 = Int(r.minY.rounded(.down))
    let x1 = Int(r.maxX.rounded(.up)), y1 = Int(r.maxY.rounded(.up))
    return (x0, y0, max(x1 - x0, 0), max(y1 - y0, 0))
}

// MARK: Colours and vectors

public final class CIColor: NSObject, @unchecked Sendable {
    public let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    public let colorSpace: CGColorSpace
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        colorSpace = CGColorSpace()
        super.init()
    }
    public convenience init(red: CGFloat, green: CGFloat, blue: CGFloat) { self.init(red: red, green: green, blue: blue, alpha: 1) }
    public convenience init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, colorSpace: CGColorSpace) { self.init(red: red, green: green, blue: blue, alpha: alpha) }
    public convenience init(cgColor c: CGColor) {
        let v = c.components ?? [0, 0, 0, 1]
        if v.count >= 4 { self.init(red: v[0], green: v[1], blue: v[2], alpha: v[3]) } else if v.count == 2 {
            self.init(red: v[0], green: v[0], blue: v[0], alpha: v[1])
        } else { self.init(red: 0, green: 0, blue: 0, alpha: 1) }
    }
    public convenience init(string: String) {
        let v = string.split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) }
        self.init(red: v.count > 0 ? v[0] : 0, green: v.count > 1 ? v[1] : 0, blue: v.count > 2 ? v[2] : 0, alpha: v.count > 3 ? v[3] : 1)
    }
    public var numberOfComponents: Int { 4 }
    public var components: [CGFloat] { [red, green, blue, alpha] }
    public var stringRepresentation: String { "\(red) \(green) \(blue) \(alpha)" }
    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    /// Linear premultiplied.
    var linear: (Float, Float, Float, Float) {
        let a = Float(alpha)
        return (Gamma.linear(red) * a, Gamma.linear(green) * a, Gamma.linear(blue) * a, a)
    }
    public static let black = CIColor(red: 0, green: 0, blue: 0), white = CIColor(red: 1, green: 1, blue: 1)
    public static let gray = CIColor(red: 0.5, green: 0.5, blue: 0.5), red = CIColor(red: 1, green: 0, blue: 0)
    public static let green = CIColor(red: 0, green: 1, blue: 0), blue = CIColor(red: 0, green: 0, blue: 1)
    public static let cyan = CIColor(red: 0, green: 1, blue: 1), magenta = CIColor(red: 1, green: 0, blue: 1)
    public static let yellow = CIColor(red: 1, green: 1, blue: 0), clear = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CIColor else { return false }
        return components == o.components
    }
}

public final class CIVector: NSObject, @unchecked Sendable {
    let values: [CGFloat]
    public init(values: UnsafePointer<CGFloat>, count: Int) { self.values = Array(UnsafeBufferPointer(start: values, count: count)); super.init() }
    public init(_ values: [CGFloat]) { self.values = values; super.init() }
    public convenience init(x: CGFloat) { self.init([x]) }
    public convenience init(x: CGFloat, y: CGFloat) { self.init([x, y]) }
    public convenience init(x: CGFloat, y: CGFloat, z: CGFloat) { self.init([x, y, z]) }
    public convenience init(x: CGFloat, y: CGFloat, z: CGFloat, w: CGFloat) { self.init([x, y, z, w]) }
    public convenience init(cgPoint p: CGPoint) { self.init([p.x, p.y]) }
    public convenience init(cgRect r: CGRect) { self.init([r.minX, r.minY, r.width, r.height]) }
    public convenience init(cgAffineTransform t: CGAffineTransform) { self.init([t.a, t.b, t.c, t.d, t.tx, t.ty]) }
    public convenience init(string: String) {
        self.init(string.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: " ").compactMap { Double($0) }.map { CGFloat($0) })
    }
    public var count: Int { values.count }
    public func value(at index: Int) -> CGFloat { index < values.count ? values[index] : 0 }
    public var x: CGFloat { value(at: 0) }
    public var y: CGFloat { value(at: 1) }
    public var z: CGFloat { value(at: 2) }
    public var w: CGFloat { value(at: 3) }
    public var cgPointValue: CGPoint { CGPoint(x: x, y: y) }
    public var cgRectValue: CGRect { CGRect(x: x, y: y, width: z, height: w) }
    public var cgAffineTransformValue: CGAffineTransform {
        values.count >= 6 ? CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5]) : .identity
    }
    public var stringRepresentation: String { "[" + values.map { "\($0)" }.joined(separator: " ") + "]" }
}

// MARK: Images

public struct CIImageOption: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let colorSpace = Self(rawValue: "kCIImageColorSpace"), properties = Self(rawValue: "kCIImageProperties")
    public static let applyOrientationProperty = Self(rawValue: "kCIImageApplyOrientationProperty")
    public static let nearestSampling = Self(rawValue: "kCIImageNearestSampling"), cacheImmediately = Self(rawValue: "kCIImageCacheImmediately")
    public static let toneMapHDRtoSDR = Self(rawValue: "kCIImageToneMapHDRtoSDR"), expandToHDR = Self(rawValue: "kCIImageExpandToHDR")
    public static let auxiliaryDepth = Self(rawValue: "kCIImageAuxiliaryDepth"), auxiliaryDisparity = Self(rawValue: "kCIImageAuxiliaryDisparity")
}

public struct CIFormat: RawRepresentable, Hashable, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public static let ARGB8 = CIFormat(rawValue: 264), BGRA8 = CIFormat(rawValue: 266), RGBA8 = CIFormat(rawValue: 265)
    public static let ABGR8 = CIFormat(rawValue: 263), RGBAh = CIFormat(rawValue: 2056), RGBAf = CIFormat(rawValue: 2312)
    public static let RGBA16 = CIFormat(rawValue: 1291), A8 = CIFormat(rawValue: 267), L8 = CIFormat(rawValue: 268), R8 = CIFormat(rawValue: 259)
    public static let Rf = CIFormat(rawValue: 2052), RGhA = RGBAh
    var bytesPerPixel: Int {
        switch self {
        case .RGBAf: 16
        case .RGBAh, .RGBA16: 8
        case .A8, .L8, .R8: 1
        case .Rf: 4
        default: 4
        }
    }
}

public let kCIFormatRGBA8 = CIFormat.RGBA8
public let kCIFormatBGRA8 = CIFormat.BGRA8
public let kCIFormatARGB8 = CIFormat.ARGB8
public let kCIFormatRGBAh = CIFormat.RGBAh
public let kCIFormatRGBAf = CIFormat.RGBAf

/// What an image is made of.
indirect enum Recipe {
    case empty
    case color(Float, Float, Float, Float)
    /// Source pixels (straight sRGB RGBA8 or premultiplied BGRA8), top row first, at the origin.
    case pixels(Pixels)
    case transform(CIImage, CGAffineTransform, nearest: Bool)
    case crop(CIImage, CGRect)
    case clamp(CIImage, CGRect)
    case filter(Kernel, [CIImage], extent: CGRect)
}

/// Decoded source pixels.
final class Pixels: @unchecked Sendable {
    let width: Int, height: Int
    private let fetch: () -> (bytes: [UInt8], bgra: Bool, premultiplied: Bool)
    private var cached: (bytes: [UInt8], bgra: Bool, premultiplied: Bool)?
    private let lock = NSLock()
    let buffer: CVPixelBuffer?
    init(width: Int, height: Int, buffer: CVPixelBuffer? = nil, _ fetch: @escaping () -> (bytes: [UInt8], bgra: Bool, premultiplied: Bool)) {
        self.width = width; self.height = height; self.buffer = buffer; self.fetch = fetch
    }
    var data: (bytes: [UInt8], bgra: Bool, premultiplied: Bool) {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let d = fetch()
        cached = d
        return d
    }
}

/// A per-pixel or neighbourhood operation over input tiles.
struct Kernel {
    let name: String
    /// The input region needed for output `rect`, per input.
    let roi: (Int, CGRect) -> CGRect
    let apply: ([Tile], inout Tile) -> Void
}

public final class CIImage: NSObject, @unchecked Sendable {
    let recipe: Recipe
    public let extent: CGRect
    public private(set) var properties: [String: Any] = [:]
    public var url: URL? { nil }
    public var colorSpace: CGColorSpace? { CGColorSpace() }
    public var cgImage: CGImage? { if case let .pixels(p) = recipe, p.buffer == nil { return cgSource } else { return nil } }
    public var pixelBuffer: CVPixelBuffer? { if case let .pixels(p) = recipe { return p.buffer } else { return nil } }
    private var cgSource: CGImage?

    init(recipe: Recipe, extent: CGRect) {
        self.recipe = recipe
        self.extent = extent
        super.init()
    }

    public static func empty() -> CIImage { CIImage(recipe: .empty, extent: .null) }
    public override convenience init() { self.init(recipe: .empty, extent: .null) }

    public convenience init(color: CIColor) {
        let c = color.linear
        self.init(recipe: .color(c.0, c.1, c.2, c.3), extent: .infinite)
    }

    public convenience init(cgImage image: CGImage) {
        let px = image.pixels
        self.init(recipe: .pixels(Pixels(width: image.width, height: image.height) { (px, false, false) }),
                  extent: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        cgSource = image
    }
    public convenience init(cgImage image: CGImage, options: [CIImageOption: Any]?) { self.init(cgImage: image) }

    public convenience init(cvPixelBuffer pb: CVPixelBuffer) {
        let fetch: () -> (bytes: [UInt8], bgra: Bool, premultiplied: Bool)
        if pb.pixelFormatType == kCVPixelFormatType_32BGRA {
            fetch = {
                var out = [UInt8](repeating: 0, count: pb.width * pb.height * 4)
                out.withUnsafeMutableBytes { d in
                    for y in 0..<pb.height { memcpy(d.baseAddress! + y * pb.width * 4, pb.base + y * pb.bytesPerRow, pb.width * 4) }
                }
                return (out, true, true)
            }
        } else {
            let opaque = pb.pixelFormatType != kCVPixelFormatType_32RGBA && pb.pixelFormatType != kCVPixelFormatType_32ARGB
            fetch = { (pb.rgba(), false, !opaque) }
        }
        self.init(recipe: .pixels(Pixels(width: pb.width, height: pb.height, buffer: pb, fetch)), extent: CGRect(x: 0, y: 0, width: pb.width, height: pb.height))
    }
    public convenience init(cvPixelBuffer pb: CVPixelBuffer, options: [CIImageOption: Any]?) { self.init(cvPixelBuffer: pb) }
    public convenience init(cvImageBuffer b: CVImageBuffer) {
        if let pb = b as? CVPixelBuffer { self.init(cvPixelBuffer: pb) } else { self.init(recipe: .empty, extent: .null) }
    }
    public convenience init(cvImageBuffer b: CVImageBuffer, options: [CIImageOption: Any]?) { self.init(cvImageBuffer: b) }

    public convenience init?(contentsOf url: URL, options: [CIImageOption: Any]? = nil) {
        guard let d = try? Data(contentsOf: url) else { return nil }
        self.init(data: d, options: options)
    }
    public convenience init?(contentsOf url: URL) { self.init(contentsOf: url, options: nil) }
    public convenience init?(data: Data, options: [CIImageOption: Any]? = nil) {
        guard let src = CGImageSourceCreateWithData(data as NSData, nil) else { return nil }
        let upright = (options?[.applyOrientationProperty] as? Bool) ?? false
        let img = upright
            ? CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceCreateThumbnailFromImageAlways: true] as NSDictionary)
            : CGImageSourceCreateImageAtIndex(src, 0, nil)
        guard let img else { return nil }
        self.init(cgImage: img)
        if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] { properties = p }
    }
    public convenience init?(data: Data) { self.init(data: data, options: nil) }

    public convenience init(bitmapData data: Data, bytesPerRow: Int, size: CGSize, format: CIFormat, colorSpace: CGColorSpace?) {
        let w = Int(size.width), h = Int(size.height)
        self.init(recipe: .pixels(Pixels(width: w, height: h) {
            var out = [UInt8](repeating: 0, count: w * h * 4)
            data.withUnsafeBytes { s in
                let b = s.bindMemory(to: UInt8.self)
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y * bytesPerRow + x * format.bytesPerPixel, o = (y * w + x) * 4
                        guard i + 3 < b.count else { continue }
                        switch format {
                        case .BGRA8: out[o] = b[i + 2]; out[o + 1] = b[i + 1]; out[o + 2] = b[i]; out[o + 3] = b[i + 3]
                        case .ARGB8: out[o] = b[i + 1]; out[o + 1] = b[i + 2]; out[o + 2] = b[i + 3]; out[o + 3] = b[i]
                        default: out[o] = b[i]; out[o + 1] = b[i + 1]; out[o + 2] = b[i + 2]; out[o + 3] = b[i + 3]
                        }
                    }
                }
            }
            return (out, false, true)
        }), extent: CGRect(x: 0, y: 0, width: w, height: h))
    }

    // Named constants (macOS 13+).
    public static var black: CIImage { CIImage(color: .black) }
    public static var white: CIImage { CIImage(color: .white) }
    public static var gray: CIImage { CIImage(color: .gray) }
    public static var red: CIImage { CIImage(color: .red) }
    public static var green: CIImage { CIImage(color: .green) }
    public static var blue: CIImage { CIImage(color: .blue) }
    public static var cyan: CIImage { CIImage(color: .cyan) }
    public static var magenta: CIImage { CIImage(color: .magenta) }
    public static var yellow: CIImage { CIImage(color: .yellow) }
    public static var clear: CIImage { CIImage(color: .clear) }

    var isEmpty: Bool { if case .empty = recipe { return true }; return extent.isNull || extent.isEmpty }

    // MARK: Operations

    public func transformed(by t: CGAffineTransform) -> CIImage {
        if t.isIdentity || isEmpty { return self }
        if case let .transform(inner, t0, nearest) = recipe { return CIImage(recipe: .transform(inner, t0.concatenating(t), nearest: nearest), extent: extent.applying(t)) }
        if case .color = recipe { return self }
        return CIImage(recipe: .transform(self, t, nearest: false), extent: extent.isInfinite ? .infinite : extent.applying(t))
    }
    public func transformed(by t: CGAffineTransform, highQualityDownsample: Bool) -> CIImage { transformed(by: t) }

    public func cropped(to rect: CGRect) -> CIImage {
        if isEmpty { return self }
        let r = extent.intersection(rect)
        guard !r.isNull, !r.isEmpty else { return .empty() }
        if r == extent { return self }
        if case let .crop(inner, c) = recipe { return CIImage(recipe: .crop(inner, c.intersection(rect)), extent: r) }
        return CIImage(recipe: .crop(self, rect), extent: r)
    }

    public func clampedToExtent() -> CIImage {
        guard !isEmpty, !extent.isInfinite else { return self }
        return CIImage(recipe: .clamp(self, extent), extent: .infinite)
    }
    public func clamped(to rect: CGRect) -> CIImage { cropped(to: rect).clampedToExtent() }

    public func composited(over dest: CIImage) -> CIImage { Filters.compose("CISourceOverCompositing", self, dest) }

    public func samplingLinear() -> CIImage { self }
    public func samplingNearest() -> CIImage {
        if case let .transform(inner, t, _) = recipe { return CIImage(recipe: .transform(inner, t, nearest: true), extent: extent) }
        return self
    }
    public func insertingIntermediate() -> CIImage { self }
    public func insertingIntermediate(cache: Bool) -> CIImage { self }
    public func matchedToWorkingSpace(from colorSpace: CGColorSpace) -> CIImage? { self }
    public func matchedFromWorkingSpace(to colorSpace: CGColorSpace) -> CIImage? { self }
    public func settingProperties(_ p: [AnyHashable: Any]) -> CIImage {
        let i = CIImage(recipe: recipe, extent: extent)
        i.properties = p.reduce(into: [:]) { $0["\($1.key)"] = $1.value }
        return i
    }

    public func applyingFilter(_ name: String, parameters: [String: Any]) -> CIImage {
        guard let f = CIFilter(name: name) else { return .empty() }
        f.setValue(self, forKey: kCIInputImageKey)
        for (k, v) in parameters { f.setValue(v, forKey: k) }
        return f.outputImage ?? .empty()
    }
    public func applyingFilter(_ name: String) -> CIImage { applyingFilter(name, parameters: [:]) }
    public func applyingGaussianBlur(sigma: Double) -> CIImage { applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma]) }

    public func premultiplyingAlpha() -> CIImage { self }
    public func unpremultiplyingAlpha() -> CIImage { self }
    public func settingAlphaOne(in extent: CGRect) -> CIImage {
        Filters.unary("settingAlphaOne", self) { r, g, b, a in a > 0 ? (r / a, g / a, b / a, 1) : (0, 0, 0, 1) }.cropped(to: extent)
    }
    public func composited(over dest: CIImage, using: Void = ()) -> CIImage { composited(over: dest) }

    // Orientation.
    public func orientationTransform(for o: CGImagePropertyOrientation) -> CGAffineTransform {
        let w = extent.width, h = extent.height, x = extent.minX, y = extent.minY
        let toOrigin = CGAffineTransform(translationX: -x, y: -y)
        let t: CGAffineTransform = switch o {
        case .up: .identity
        case .upMirrored: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        return toOrigin.concatenating(t).concatenating(CGAffineTransform(translationX: x, y: y))
    }
    public func oriented(_ o: CGImagePropertyOrientation) -> CIImage { o == .up ? self : transformed(by: orientationTransform(for: o)) }
    public func oriented(forExifOrientation o: Int32) -> CIImage { oriented(CGImagePropertyOrientation(rawValue: UInt32(o)) ?? .up) }
    public func orientationTransform(forExifOrientation o: Int32) -> CGAffineTransform { orientationTransform(for: CGImagePropertyOrientation(rawValue: UInt32(o)) ?? .up) }

    public func regionOfInterest(for image: CIImage, in rect: CGRect) -> CGRect { rect }
    public override var description: String { "CIImage(\(recipeName), extent: \(extent))" }
    private var recipeName: String {
        switch recipe {
        case .empty: "empty"
        case .color: "color"
        case .pixels: "pixels"
        case .transform: "transform"
        case .crop: "crop"
        case .clamp: "clamp"
        case let .filter(k, _, _): k.name
        }
    }
}

// MARK: Evaluation

enum Renderer {
    /// `image` over integral `rect`, as a tile.
    static func render(_ image: CIImage, _ r: (Int, Int, Int, Int)) -> Tile {
        var t = Tile(r)
        guard r.2 > 0, r.3 > 0, !image.isEmpty else { return t }
        let rect = CGRect(x: r.0, y: r.1, width: r.2, height: r.3)
        guard image.extent.intersects(rect) else { return t }
        switch image.recipe {
        case .empty: break
        case let .color(cr, cg, cb, ca):
            t.px.withUnsafeMutableBufferPointer { p in
                var i = 0
                while i < p.count { p[i] = cr; p[i + 1] = cg; p[i + 2] = cb; p[i + 3] = ca; i += 4 }
            }
        case let .pixels(src): drawPixels(src, into: &t)
        case let .crop(inner, c):
            let clip = ints(c.intersection(rect))
            guard clip.2 > 0, clip.3 > 0 else { break }
            let sub = render(inner, clip)
            copy(sub, into: &t)
        case let .clamp(inner, ext):
            let e = ints(ext)
            guard e.2 > 0, e.3 > 0 else { break }
            // Only the edge rows/columns the request touches are needed; render the clamped request region.
            let need = ints(CGRect(x: max(CGFloat(r.0), CGFloat(e.0)), y: max(CGFloat(r.1), CGFloat(e.1)),
                                   width: 1, height: 1).union(CGRect(x: min(CGFloat(r.0 + r.2), CGFloat(e.0 + e.2)) - 1,
                                                                     y: min(CGFloat(r.1 + r.3), CGFloat(e.1 + e.3)) - 1, width: 1, height: 1))
                .intersection(CGRect(x: e.0, y: e.1, width: e.2, height: e.3)))
            guard need.2 > 0, need.3 > 0 else { break }
            let sub = render(inner, need)
            for y in r.1..<(r.1 + r.3) {
                let sy = min(max(y, need.1), need.1 + need.3 - 1)
                for x in r.0..<(r.0 + r.2) {
                    let sx = min(max(x, need.0), need.0 + need.2 - 1)
                    let s = sub.index(sx, sy), d = t.index(x, y)
                    t.px[d] = sub.px[s]; t.px[d + 1] = sub.px[s + 1]; t.px[d + 2] = sub.px[s + 2]; t.px[d + 3] = sub.px[s + 3]
                }
            }
        case let .transform(inner, m, nearest): drawTransformed(inner, m, nearest: nearest, into: &t)
        case let .filter(k, inputs, _):
            let tiles = inputs.enumerated().map { i, img in render(img, ints(k.roi(i, rect))) }
            k.apply(tiles, &t)
        }
        return t
    }

    static func copy(_ s: Tile, into t: inout Tile) {
        let x0 = max(s.x, t.x), x1 = min(s.x + s.w, t.x + t.w), y0 = max(s.y, t.y), y1 = min(s.y + s.h, t.y + t.h)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            let si = s.index(x0, y), di = t.index(x0, y), n = (x1 - x0) * 4
            t.px.withUnsafeMutableBufferPointer { d in s.px.withUnsafeBufferPointer { sp in
                (d.baseAddress! + di).update(from: sp.baseAddress! + si, count: n)
            } }
        }
    }

    /// Source pixels (top row first) into the tile (bottom row first).
    static func drawPixels(_ src: Pixels, into t: inout Tile) {
        let (bytes, bgra, premul) = src.data
        let w = src.width, h = src.height
        let x0 = max(t.x, 0), x1 = min(t.x + t.w, w), y0 = max(t.y, 0), y1 = min(t.y + t.h, h)
        guard x0 < x1, y0 < y1 else { return }
        let lin = Gamma.toLinear
        bytes.withUnsafeBufferPointer { b in
            t.px.withUnsafeMutableBufferPointer { p in
                for y in y0..<y1 {
                    let row = (h - 1 - y) * w
                    var d = ((y - t.y) * t.w + (x0 - t.x)) * 4
                    for x in x0..<x1 {
                        let s = (row + x) * 4
                        let (r, g, bl) = bgra ? (b[s + 2], b[s + 1], b[s]) : (b[s], b[s + 1], b[s + 2])
                        let a = Float(b[s + 3]) / 255
                        if premul {
                            // Premultiplied sRGB bytes: unpremultiply to linearise, then premultiply.
                            if a > 0 {
                                let k: Float = 1 / a
                                p[d] = lin[Int(min(255, (Float(r) * k).rounded()))] * a
                                p[d + 1] = lin[Int(min(255, (Float(g) * k).rounded()))] * a
                                p[d + 2] = lin[Int(min(255, (Float(bl) * k).rounded()))] * a
                            }
                        } else {
                            p[d] = lin[Int(r)] * a; p[d + 1] = lin[Int(g)] * a; p[d + 2] = lin[Int(bl)] * a
                        }
                        p[d + 3] = a
                        d += 4
                    }
                }
            }
        }
    }

    static func drawTransformed(_ inner: CIImage, _ m: CGAffineTransform, nearest: Bool, into t: inout Tile) {
        let inv = m.inverted()
        let out = CGRect(x: t.x, y: t.y, width: t.w, height: t.h)
        var need = out.applying(inv).insetBy(dx: -2, dy: -2)
        if !inner.extent.isInfinite { need = need.intersection(inner.extent.insetBy(dx: -1, dy: -1)) }
        guard !need.isNull, !need.isEmpty else { return }
        // Pure integer translations copy.
        if m.a == 1, m.b == 0, m.c == 0, m.d == 1, m.tx == m.tx.rounded(), m.ty == m.ty.rounded() {
            let src = render(inner, (t.x - Int(m.tx), t.y - Int(m.ty), t.w, t.h))
            t.px = src.px
            return
        }
        let s = render(inner, ints(need))
        guard s.w > 0, s.h > 0 else { return }
        let scale = abs(m.a * m.d - m.b * m.c).squareRoot()
        let n = nearest ? 1 : max(1, min(6, Int((1 / max(scale, 1e-6)).rounded(.up))))
        let inner0 = inner.extent
        s.px.withUnsafeBufferPointer { sp in
            t.px.withUnsafeMutableBufferPointer { p in
                for y in 0..<t.h {
                    for x in 0..<t.w {
                        var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
                        for j in 0..<n {
                            for i in 0..<n {
                                let ox = CGFloat(t.x + x) + (CGFloat(i) + 0.5) / CGFloat(n), oy = CGFloat(t.y + y) + (CGFloat(j) + 0.5) / CGFloat(n)
                                var q = CGPoint(x: ox, y: oy).applying(inv)
                                // As Core Image samples: clamped to the edge pixels inside the
                                // image's extent (hard, exact edges), nothing outside it.
                                if !inner0.isInfinite {
                                    if !inner0.contains(q) { continue }
                                    q.x = min(max(q.x, min(inner0.minX + 0.5, inner0.midX)), max(inner0.maxX - 0.5, inner0.midX))
                                    q.y = min(max(q.y, min(inner0.minY + 0.5, inner0.midY)), max(inner0.maxY - 0.5, inner0.midY))
                                }
                                let v = nearest ? sampleNearest(sp, s, q) : sampleBilinear(sp, s, q)
                                acc.0 += v.0; acc.1 += v.1; acc.2 += v.2; acc.3 += v.3
                            }
                        }
                        let k = 1 / Float(n * n), d = (y * t.w + x) * 4
                        p[d] = acc.0 * k; p[d + 1] = acc.1 * k; p[d + 2] = acc.2 * k; p[d + 3] = acc.3 * k
                    }
                }
            }
        }
    }

    @inline(__always) static func px(_ sp: UnsafeBufferPointer<Float>, _ s: Tile, _ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
        guard x >= s.x, y >= s.y, x < s.x + s.w, y < s.y + s.h else { return (0, 0, 0, 0) }
        let i = ((y - s.y) * s.w + (x - s.x)) * 4
        return (sp[i], sp[i + 1], sp[i + 2], sp[i + 3])
    }
    @inline(__always) static func sampleNearest(_ sp: UnsafeBufferPointer<Float>, _ s: Tile, _ q: CGPoint) -> (Float, Float, Float, Float) {
        px(sp, s, Int(q.x.rounded(.down)), Int(q.y.rounded(.down)))
    }
    @inline(__always) static func sampleBilinear(_ sp: UnsafeBufferPointer<Float>, _ s: Tile, _ q: CGPoint) -> (Float, Float, Float, Float) {
        let fx = Float(q.x) - 0.5, fy = Float(q.y) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let a = px(sp, s, x0, y0), b = px(sp, s, x0 + 1, y0), c = px(sp, s, x0, y0 + 1), d = px(sp, s, x0 + 1, y0 + 1)
        func m(_ p: Float, _ q: Float, _ r: Float, _ u: Float) -> Float { (p * (1 - tx) + q * tx) * (1 - ty) + (r * (1 - tx) + u * tx) * ty }
        return (m(a.0, b.0, c.0, d.0), m(a.1, b.1, c.1, d.1), m(a.2, b.2, c.2, d.2), m(a.3, b.3, c.3, d.3))
    }
}
