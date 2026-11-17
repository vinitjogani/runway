// Core Image filters by name (CIFilter(name:) with input keys) and the
// CIFilterBuiltins typed API, over CPU kernels: compositing and blend
// modes, masks, colour matrix/controls/exposure/invert/monochrome, Gaussian
// and box blurs, affine and Lanczos scale transforms, crops, and the
// constant, gradient, rounded-rectangle, checkerboard and random generators.

import CoreGraphics
import Foundation

public let kCIInputImageKey = "inputImage"
public let kCIInputBackgroundImageKey = "inputBackgroundImage"
public let kCIInputMaskImageKey = "inputMaskImage"
public let kCIInputRadiusKey = "inputRadius"
public let kCIInputScaleKey = "inputScale"
public let kCIInputAspectRatioKey = "inputAspectRatio"
public let kCIInputTransformKey = "inputTransform"
public let kCIInputColorKey = "inputColor"
public let kCIInputCenterKey = "inputCenter"
public let kCIInputExtentKey = "inputExtent"
public let kCIInputIntensityKey = "inputIntensity"
public let kCIInputSaturationKey = "inputSaturation"
public let kCIInputBrightnessKey = "inputBrightness"
public let kCIInputContrastKey = "inputContrast"
public let kCIInputEVKey = "inputEV"
public let kCIInputAngleKey = "inputAngle"
public let kCIInputWidthKey = "inputWidth"
public let kCIInputSharpnessKey = "inputSharpness"
public let kCIOutputImageKey = "outputImage"
public let kCIAttributeFilterName = "CIAttributeFilterName"
public let kCIAttributeFilterDisplayName = "CIAttributeFilterDisplayName"
public let kCICategoryBuiltIn = "CICategoryBuiltIn"
public let kCICategoryBlur = "CICategoryBlur"
public let kCICategoryColorAdjustment = "CICategoryColorAdjustment"
public let kCICategoryCompositeOperation = "CICategoryCompositeOperation"
public let kCICategoryGenerator = "CICategoryGenerator"
public let kCICategoryGeometryAdjustment = "CICategoryGeometryAdjustment"

typealias RGBA = (Float, Float, Float, Float)

enum Filters {
    static func union(_ a: CIImage, _ b: CIImage) -> CGRect {
        if a.isEmpty { return b.extent }
        if b.isEmpty { return a.extent }
        return a.extent.union(b.extent)
    }

    /// A per-pixel function of premultiplied values.
    static func unary(_ name: String, _ img: CIImage, _ f: @escaping (Float, Float, Float, Float) -> RGBA) -> CIImage {
        guard !img.isEmpty else { return img }
        let k = Kernel(name: name, roi: { _, r in r }) { tiles, out in
            let s = tiles[0]
            s.px.withUnsafeBufferPointer { sp in
                out.px.withUnsafeMutableBufferPointer { p in
                    var i = 0
                    while i < p.count {
                        let v = f(sp[i], sp[i + 1], sp[i + 2], sp[i + 3])
                        p[i] = v.0; p[i + 1] = v.1; p[i + 2] = v.2; p[i + 3] = v.3
                        i += 4
                    }
                }
            }
        }
        return CIImage(recipe: .filter(k, [img], extent: img.extent), extent: img.extent)
    }

    /// A per-pixel function of unpremultiplied values (Core Image's colour filters).
    static func unpremultiplied(_ name: String, _ img: CIImage, _ f: @escaping (Float, Float, Float, Float) -> RGBA) -> CIImage {
        unary(name, img) { r, g, b, a in
            let (ur, ug, ub) = a > 0 ? (r / a, g / a, b / a) : (0, 0, 0)
            let v = f(ur, ug, ub, a)
            let na = max(0, min(1, v.3))
            return (v.0 * na, v.1 * na, v.2 * na, na)
        }
    }

    /// Porter–Duff and blend modes: `s` the input, `d` the background.
    static func compose(_ name: String, _ s: CIImage, _ d: CIImage) -> CIImage {
        let op: (RGBA, RGBA) -> RGBA
        var extent = union(s, d)
        switch name {
        case "CISourceOutCompositing":
            op = { s, d in let k = 1 - d.3; return (s.0 * k, s.1 * k, s.2 * k, s.3 * k) }
            extent = s.extent
        case "CISourceInCompositing":
            op = { s, d in (s.0 * d.3, s.1 * d.3, s.2 * d.3, s.3 * d.3) }
            extent = s.extent.intersection(d.extent)
        case "CISourceAtopCompositing":
            op = { s, d in let k = 1 - s.3; return (s.0 * d.3 + d.0 * k, s.1 * d.3 + d.1 * k, s.2 * d.3 + d.2 * k, d.3) }
            extent = d.extent
        case "CIAdditionCompositing":
            op = { s, d in (s.0 + d.0, s.1 + d.1, s.2 + d.2, min(1, s.3 + d.3)) }
        case "CIMultiplyCompositing":
            op = { s, d in (s.0 * d.0, s.1 * d.1, s.2 * d.2, s.3 * d.3) }
        case "CIMinimumCompositing":
            op = { s, d in (min(s.0, d.0), min(s.1, d.1), min(s.2, d.2), min(s.3, d.3)) }
        case "CIMaximumCompositing":
            op = { s, d in (max(s.0, d.0), max(s.1, d.1), max(s.2, d.2), max(s.3, d.3)) }
        case "CIMultiplyBlendMode":
            op = { s, d in
                func ch(_ a: Float, _ b: Float) -> Float { a * b + a * (1 - d.3) + b * (1 - s.3) }
                return (ch(s.0, d.0), ch(s.1, d.1), ch(s.2, d.2), s.3 + d.3 * (1 - s.3))
            }
        case "CIScreenBlendMode":
            op = { s, d in (s.0 + d.0 - s.0 * d.0, s.1 + d.1 - s.1 * d.1, s.2 + d.2 - s.2 * d.2, s.3 + d.3 - s.3 * d.3) }
        case "CIDarkenBlendMode":
            op = { s, d in
                func ch(_ a: Float, _ b: Float) -> Float { min(a * d.3, b * s.3) + a * (1 - d.3) + b * (1 - s.3) }
                return (ch(s.0, d.0), ch(s.1, d.1), ch(s.2, d.2), s.3 + d.3 * (1 - s.3))
            }
        case "CILightenBlendMode":
            op = { s, d in
                func ch(_ a: Float, _ b: Float) -> Float { max(a * d.3, b * s.3) + a * (1 - d.3) + b * (1 - s.3) }
                return (ch(s.0, d.0), ch(s.1, d.1), ch(s.2, d.2), s.3 + d.3 * (1 - s.3))
            }
        case "CIDifferenceBlendMode":
            op = { s, d in (abs(s.0 - d.0), abs(s.1 - d.1), abs(s.2 - d.2), s.3 + d.3 * (1 - s.3)) }
        default: // CISourceOverCompositing
            op = { s, d in let k = 1 - s.3; return (s.0 + d.0 * k, s.1 + d.1 * k, s.2 + d.2 * k, s.3 + d.3 * k) }
        }
        if s.isEmpty && d.isEmpty { return .empty() }
        let k = Kernel(name: name, roi: { _, r in r }) { tiles, out in
            let (a, b) = (tiles[0], tiles[1])
            a.px.withUnsafeBufferPointer { ap in b.px.withUnsafeBufferPointer { bp in out.px.withUnsafeMutableBufferPointer { p in
                var i = 0
                while i < p.count {
                    let v = op((ap[i], ap[i + 1], ap[i + 2], ap[i + 3]), (bp[i], bp[i + 1], bp[i + 2], bp[i + 3]))
                    p[i] = v.0; p[i + 1] = v.1; p[i + 2] = v.2; p[i + 3] = v.3
                    i += 4
                }
            } } }
        }
        guard !extent.isNull, !extent.isEmpty else { return .empty() }
        return CIImage(recipe: .filter(k, [s, d], extent: extent), extent: extent)
    }

    /// input × m + background × (1 − m), m from the mask's alpha or luminance.
    static func blend(_ input: CIImage, _ background: CIImage, mask: CIImage, alpha: Bool) -> CIImage {
        let inner = input.extent.intersection(mask.extent)
        var extent = background.isEmpty ? inner : (inner.isNull ? background.extent : inner.union(background.extent))
        if extent.isNull { extent = .null }
        guard !extent.isNull, !extent.isEmpty else { return .empty() }
        let k = Kernel(name: alpha ? "CIBlendWithAlphaMask" : "CIBlendWithMask", roi: { _, r in r }) { tiles, out in
            let (s, d, m) = (tiles[0], tiles[1], tiles[2])
            for i in stride(from: 0, to: out.px.count, by: 4) {
                let w: Float = alpha ? m.px[i + 3] : (0.2126 * m.px[i] + 0.7152 * m.px[i + 1] + 0.0722 * m.px[i + 2])
                let k = 1 - w
                out.px[i] = s.px[i] * w + d.px[i] * k; out.px[i + 1] = s.px[i + 1] * w + d.px[i + 1] * k
                out.px[i + 2] = s.px[i + 2] * w + d.px[i + 2] * k; out.px[i + 3] = s.px[i + 3] * w + d.px[i + 3] * k
            }
        }
        return CIImage(recipe: .filter(k, [input, background, mask], extent: extent), extent: extent)
    }

    /// A separable Gaussian (σ in pixels); transparent outside the input.
    static func gaussian(_ img: CIImage, sigma: Double) -> CIImage {
        guard !img.isEmpty, sigma > 0.01 else { return img }
        let r = Int((sigma * 3).rounded(.up))
        var weights = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let sum = weights.reduce(0, +)
        weights = weights.map { $0 / sum }
        let extent = img.extent.isInfinite ? img.extent : img.extent.insetBy(dx: CGFloat(-r), dy: CGFloat(-r))
        let wts = weights
        let k = Kernel(name: "CIGaussianBlur", roi: { _, rect in rect.insetBy(dx: CGFloat(-r), dy: CGFloat(-r)) }) { tiles, out in
            convolve(tiles[0], into: &out, weights: wts, radius: r)
        }
        return CIImage(recipe: .filter(k, [img], extent: extent), extent: extent)
    }

    static func box(_ img: CIImage, radius: Int) -> CIImage {
        guard !img.isEmpty, radius > 0 else { return img }
        let w = [Float](repeating: 1 / Float(radius * 2 + 1), count: radius * 2 + 1)
        let extent = img.extent.isInfinite ? img.extent : img.extent.insetBy(dx: CGFloat(-radius), dy: CGFloat(-radius))
        let k = Kernel(name: "CIBoxBlur", roi: { _, rect in rect.insetBy(dx: CGFloat(-radius), dy: CGFloat(-radius)) }) { tiles, out in
            convolve(tiles[0], into: &out, weights: w, radius: radius)
        }
        return CIImage(recipe: .filter(k, [img], extent: extent), extent: extent)
    }

    /// Horizontal then vertical pass; `src` covers `out` grown by `radius`.
    static func convolve(_ src: Tile, into out: inout Tile, weights: [Float], radius r: Int) {
        let mw = out.w, sh = src.h
        guard src.w > 0, sh > 0 else { return }
        var mid = [Float](repeating: 0, count: mw * sh * 4)
        src.px.withUnsafeBufferPointer { sp in
            weights.withUnsafeBufferPointer { wp in
                for y in 0..<sh {
                    for x in 0..<mw {
                        var a: RGBA = (0, 0, 0, 0)
                        let cx = out.x + x - src.x
                        for k in -r...r {
                            let sx = cx + k
                            guard sx >= 0, sx < src.w else { continue }
                            let i = (y * src.w + sx) * 4, w = wp[k + r]
                            a.0 += sp[i] * w; a.1 += sp[i + 1] * w; a.2 += sp[i + 2] * w; a.3 += sp[i + 3] * w
                        }
                        let d = (y * mw + x) * 4
                        mid[d] = a.0; mid[d + 1] = a.1; mid[d + 2] = a.2; mid[d + 3] = a.3
                    }
                }
            }
        }
        mid.withUnsafeBufferPointer { mp in
            weights.withUnsafeBufferPointer { wp in
                out.px.withUnsafeMutableBufferPointer { p in
                    for y in 0..<out.h {
                        let cy = out.y + y - src.y
                        for x in 0..<mw {
                            var a: RGBA = (0, 0, 0, 0)
                            for k in -r...r {
                                let sy = cy + k
                                guard sy >= 0, sy < sh else { continue }
                                let i = (sy * mw + x) * 4, w = wp[k + r]
                                a.0 += mp[i] * w; a.1 += mp[i + 1] * w; a.2 += mp[i + 2] * w; a.3 += mp[i + 3] * w
                            }
                            let d = (y * mw + x) * 4
                            p[d] = a.0; p[d + 1] = a.1; p[d + 2] = a.2; p[d + 3] = a.3
                        }
                    }
                }
            }
        }
    }

    /// A generator: a function of the pixel centre (CI space), within `extent`.
    static func generator(_ name: String, extent: CGRect, _ f: @escaping (Double, Double) -> RGBA) -> CIImage {
        let k = Kernel(name: name, roi: { _, r in r }) { _, out in
            out.px.withUnsafeMutableBufferPointer { p in
                for y in 0..<out.h {
                    for x in 0..<out.w {
                        let v = f(Double(out.x + x) + 0.5, Double(out.y + y) + 0.5)
                        let d = (y * out.w + x) * 4
                        p[d] = v.0; p[d + 1] = v.1; p[d + 2] = v.2; p[d + 3] = v.3
                    }
                }
            }
        }
        let img = CIImage(recipe: .filter(k, [], extent: extent), extent: extent)
        return extent.isInfinite ? img : img
    }

    static func mix(_ a: RGBA, _ b: RGBA, _ t: Float) -> RGBA {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t, a.3 + (b.3 - a.3) * t)
    }
}

// MARK: CIFilter

/// A filter: input values by key, and the output they make.
open class CIFilter: NSObject, @unchecked Sendable {
    public let name: String
    var values: [String: Any] = [:]
    open var isEnabled = true

    static let known: Set<String> = [
        "CISourceOverCompositing", "CISourceOutCompositing", "CISourceInCompositing", "CISourceAtopCompositing", "CIAdditionCompositing",
        "CIMultiplyCompositing", "CIMinimumCompositing", "CIMaximumCompositing", "CIMultiplyBlendMode", "CIScreenBlendMode",
        "CIDarkenBlendMode", "CILightenBlendMode", "CIDifferenceBlendMode", "CIBlendWithMask", "CIBlendWithAlphaMask",
        "CIColorMatrix", "CIColorControls", "CIExposureAdjust", "CIColorInvert", "CIColorMonochrome", "CIPhotoEffectMono", "CISepiaTone",
        "CIGammaAdjust", "CIColorClamp", "CIMaskToAlpha", "CIGaussianBlur", "CIBoxBlur", "CIAffineTransform", "CILanczosScaleTransform", "CICrop",
        "CIConstantColorGenerator", "CILinearGradient", "CISmoothLinearGradient", "CIRadialGradient", "CIRoundedRectangleGenerator",
        "CIRandomGenerator", "CICheckerboardGenerator", "CIVignette", "CIAffineClamp", "CISharpenLuminance", "CIUnsharpMask",
    ]

    public init?(name: String) {
        guard CIFilter.known.contains(name) else { return nil }
        self.name = name
        super.init()
        setDefaults()
    }
    public convenience init?(name: String, parameters params: [String: Any]?) {
        self.init(name: name)
        for (k, v) in params ?? [:] { setValue(v, forKey: k) }
    }
    public convenience init?(name: String, withInputParameters params: [String: Any]?) { self.init(name: name, parameters: params) }
    init(builtin name: String) {
        self.name = name
        super.init()
        setDefaults()
    }

    open class func filterNames(inCategory category: String?) -> [String] { known.sorted() }
    open class func filterNames(inCategories categories: [String]?) -> [String] { known.sorted() }
    open class func localizedName(forFilterName filterName: String) -> String? { filterName }

    open var inputKeys: [String] { values.keys.filter { $0.hasPrefix("input") }.sorted() }
    open var outputKeys: [String] { [kCIOutputImageKey] }
    open var attributes: [String: Any] { [kCIAttributeFilterName: name, kCIAttributeFilterDisplayName: name] }

    open func setValue(_ value: Any?, forKey key: String) { values[key] = value }
    open func value(forKey key: String) -> Any? { key == kCIOutputImageKey ? outputImage : values[key] }
    open func setValuesForKeys(_ keyedValues: [String: Any]) { for (k, v) in keyedValues { values[k] = v } }

    open func setDefaults() {
        switch name {
        case "CIGaussianBlur": values[kCIInputRadiusKey] = 10.0
        case "CIBoxBlur": values[kCIInputRadiusKey] = 10.0
        case "CIColorControls": values[kCIInputSaturationKey] = 1.0; values[kCIInputBrightnessKey] = 0.0; values[kCIInputContrastKey] = 1.0
        case "CIColorMatrix":
            values["inputRVector"] = CIVector(x: 1, y: 0, z: 0, w: 0); values["inputGVector"] = CIVector(x: 0, y: 1, z: 0, w: 0)
            values["inputBVector"] = CIVector(x: 0, y: 0, z: 1, w: 0); values["inputAVector"] = CIVector(x: 0, y: 0, z: 0, w: 1)
            values["inputBiasVector"] = CIVector(x: 0, y: 0, z: 0, w: 0)
        case "CILanczosScaleTransform": values[kCIInputScaleKey] = 1.0; values[kCIInputAspectRatioKey] = 1.0
        case "CIRoundedRectangleGenerator":
            values[kCIInputExtentKey] = CIVector(x: 0, y: 0, z: 100, w: 100); values[kCIInputRadiusKey] = 10.0; values[kCIInputColorKey] = CIColor.white
        case "CIRadialGradient":
            values[kCIInputCenterKey] = CIVector(x: 150, y: 150); values["inputRadius0"] = 5.0; values["inputRadius1"] = 100.0
            values["inputColor0"] = CIColor.white; values["inputColor1"] = CIColor.black
        case "CILinearGradient", "CISmoothLinearGradient":
            values["inputPoint0"] = CIVector(x: 0, y: 0); values["inputPoint1"] = CIVector(x: 200, y: 200)
            values["inputColor0"] = CIColor.white; values["inputColor1"] = CIColor.black
        case "CIExposureAdjust": values[kCIInputEVKey] = 0.5
        case "CISepiaTone": values[kCIInputIntensityKey] = 1.0
        case "CIColorMonochrome": values[kCIInputColorKey] = CIColor(red: 0.6, green: 0.45, blue: 0.3); values[kCIInputIntensityKey] = 1.0
        case "CIGammaAdjust": values["inputPower"] = 1.0
        case "CICheckerboardGenerator":
            values[kCIInputCenterKey] = CIVector(x: 150, y: 150); values["inputColor0"] = CIColor.white; values["inputColor1"] = CIColor.black
            values[kCIInputWidthKey] = 80.0; values[kCIInputSharpnessKey] = 1.0
        case "CIVignette": values[kCIInputIntensityKey] = 0.0; values[kCIInputRadiusKey] = 1.0
        case "CIAffineTransform", "CIAffineClamp": values[kCIInputTransformKey] = CGAffineTransform.identity
        case "CIConstantColorGenerator": values[kCIInputColorKey] = CIColor.black
        default: break
        }
    }

    // Typed reads of inputs.
    func image(_ key: String) -> CIImage? { values[key] as? CIImage }
    func double(_ key: String, _ d: Double = 0) -> Double {
        switch values[key] {
        case let n as NSNumber: n.doubleValue
        case let x as Double: x
        case let x as Float: Double(x)
        case let x as CGFloat: Double(x)
        case let x as Int: Double(x)
        default: d
        }
    }
    func vector(_ key: String) -> CIVector? {
        switch values[key] {
        case let v as CIVector: v
        case let p as CGPoint: CIVector(cgPoint: p)
        case let r as CGRect: CIVector(cgRect: r)
        default: nil
        }
    }
    func color(_ key: String) -> CIColor {
        switch values[key] {
        case let c as CIColor: c
        case let c as CGColor: CIColor(cgColor: c)
        default: .black
        }
    }
    func transform(_ key: String) -> CGAffineTransform {
        switch values[key] {
        case let t as CGAffineTransform: t
        case let v as CIVector: v.cgAffineTransformValue
        default: .identity
        }
    }

    open var outputImage: CIImage? {
        let input = image(kCIInputImageKey) ?? .empty()
        switch name {
        case "CISourceOverCompositing", "CISourceOutCompositing", "CISourceInCompositing", "CISourceAtopCompositing", "CIAdditionCompositing",
             "CIMultiplyCompositing", "CIMinimumCompositing", "CIMaximumCompositing", "CIMultiplyBlendMode", "CIScreenBlendMode",
             "CIDarkenBlendMode", "CILightenBlendMode", "CIDifferenceBlendMode":
            return Filters.compose(name, input, image(kCIInputBackgroundImageKey) ?? .empty())
        case "CIBlendWithMask", "CIBlendWithAlphaMask":
            return Filters.blend(input, image(kCIInputBackgroundImageKey) ?? .empty(), mask: image(kCIInputMaskImageKey) ?? .empty(), alpha: name == "CIBlendWithAlphaMask")
        case "CIColorMatrix":
            let v: [[Float]] = ["inputRVector", "inputGVector", "inputBVector", "inputAVector"].map { k -> [Float] in
                let x = vector(k) ?? CIVector(x: 0, y: 0, z: 0, w: 0)
                return [Float(x.x), Float(x.y), Float(x.z), Float(x.w)]
            }
            let bias = vector("inputBiasVector"); let b: [Float] = bias.map { [Float($0.x), Float($0.y), Float($0.z), Float($0.w)] } ?? [0, 0, 0, 0]
            return Filters.unpremultiplied(name, input) { r, g, bl, a in
                func dot(_ m: [Float]) -> Float { m[0] * r + m[1] * g + m[2] * bl + m[3] * a }
                return (dot(v[0]) + b[0], dot(v[1]) + b[1], dot(v[2]) + b[2], dot(v[3]) + b[3])
            }
        case "CIColorControls":
            let s = Float(double(kCIInputSaturationKey, 1)), br = Float(double(kCIInputBrightnessKey)), c = Float(double(kCIInputContrastKey, 1))
            return Filters.unpremultiplied(name, input) { r, g, b, a in
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                func ch(_ v: Float) -> Float { ((l + (v - l) * s + br) - 0.5) * c + 0.5 }
                return (max(0, ch(r)), max(0, ch(g)), max(0, ch(b)), a)
            }
        case "CIExposureAdjust":
            let k = Float(pow(2, double(kCIInputEVKey)))
            return Filters.unary(name, input) { r, g, b, a in (r * k, g * k, b * k, a) }
        case "CIGammaAdjust":
            let p = Float(double("inputPower", 1))
            return Filters.unpremultiplied(name, input) { r, g, b, a in (powf(r, p), powf(g, p), powf(b, p), a) }
        case "CIColorInvert":
            return Filters.unpremultiplied(name, input) { r, g, b, a in
                (Gamma.linear(CGFloat(1 - Gamma.srgb(r))), Gamma.linear(CGFloat(1 - Gamma.srgb(g))), Gamma.linear(CGFloat(1 - Gamma.srgb(b))), a)
            }
        case "CIColorMonochrome", "CIPhotoEffectMono", "CISepiaTone":
            let tint = name == "CISepiaTone" ? CIColor(red: 0.7, green: 0.55, blue: 0.4) : (name == "CIPhotoEffectMono" ? CIColor.white : color(kCIInputColorKey))
            let t = tint.linear, k = Float(double(kCIInputIntensityKey, 1))
            return Filters.unpremultiplied(name, input) { r, g, b, a in
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                return (r + (l * t.0 - r) * k, g + (l * t.1 - g) * k, b + (l * t.2 - b) * k, a)
            }
        case "CIColorClamp":
            return Filters.unpremultiplied(name, input) { r, g, b, a in (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1), a) }
        case "CIMaskToAlpha":
            return Filters.unary(name, input) { r, g, b, a in
                let l = a > 0 ? Gamma.srgb((0.2126 * r + 0.7152 * g + 0.0722 * b) / a) * a : 0
                return (l, l, l, l)
            }
        case "CIGaussianBlur": return Filters.gaussian(input, sigma: double(kCIInputRadiusKey, 10))
        case "CIBoxBlur": return Filters.box(input, radius: Int(double(kCIInputRadiusKey, 10) / 2))
        case "CIUnsharpMask", "CISharpenLuminance": return input
        case "CIAffineTransform": return input.transformed(by: transform(kCIInputTransformKey))
        case "CIAffineClamp": return input.clampedToExtent().transformed(by: transform(kCIInputTransformKey))
        case "CILanczosScaleTransform":
            let s = double(kCIInputScaleKey, 1), ar = double(kCIInputAspectRatioKey, 1)
            return input.transformed(by: CGAffineTransform(scaleX: CGFloat(s * ar), y: CGFloat(s)))
        case "CICrop": return input.cropped(to: vector("inputRectangle")?.cgRectValue ?? .infinite)
        case "CIConstantColorGenerator": return CIImage(color: color(kCIInputColorKey))
        case "CILinearGradient", "CISmoothLinearGradient":
            let p0 = vector("inputPoint0")?.cgPointValue ?? .zero, p1 = vector("inputPoint1")?.cgPointValue ?? CGPoint(x: 200, y: 200)
            let c0 = color("inputColor0").linear, c1 = color("inputColor1").linear
            let dx = Double(p1.x - p0.x), dy = Double(p1.y - p0.y), len2 = max(dx * dx + dy * dy, 1e-9)
            let smooth = name == "CISmoothLinearGradient"
            return Filters.generator(name, extent: .infinite) { x, y in
                var t = Float(((x - Double(p0.x)) * dx + (y - Double(p0.y)) * dy) / len2)
                t = min(max(t, 0), 1)
                if smooth { t = t * t * (3 - 2 * t) }
                return Filters.mix(c0, c1, t)
            }
        case "CIRadialGradient":
            let c = vector(kCIInputCenterKey)?.cgPointValue ?? .zero
            let r0 = double("inputRadius0", 5), r1 = double("inputRadius1", 100)
            let c0 = color("inputColor0").linear, c1 = color("inputColor1").linear
            return Filters.generator(name, extent: .infinite) { x, y in
                let d = ((x - Double(c.x)) * (x - Double(c.x)) + (y - Double(c.y)) * (y - Double(c.y))).squareRoot()
                let t = r1 == r0 ? (d < r0 ? 0 : 1) : Float(min(max((d - r0) / (r1 - r0), 0), 1))
                return Filters.mix(c0, c1, t)
            }
        case "CIRoundedRectangleGenerator":
            let e = vector(kCIInputExtentKey)?.cgRectValue ?? .zero
            guard e.width > 0, e.height > 0 else { return .empty() }
            let rad = min(max(double(kCIInputRadiusKey, 10), 0), Double(min(e.width, e.height)) / 2)
            let col = color(kCIInputColorKey).linear
            let ext = ints(e)
            let rect = CGRect(x: ext.0, y: ext.1, width: ext.2, height: ext.3)
            return Filters.generator(name, extent: rect) { x, y in
                // Coverage from the signed distance to the rounded box (a pixel-wide edge).
                let cx = Double(e.midX), cy = Double(e.midY)
                let hx = Double(e.width) / 2 - rad, hy = Double(e.height) / 2 - rad
                let qx = abs(x - cx) - hx, qy = abs(y - cy) - hy
                let outside = (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0) - rad
                let k = Float(min(max(0.5 - outside, 0), 1))
                return (col.0 * k, col.1 * k, col.2 * k, col.3 * k)
            }
        case "CIRandomGenerator":
            return Filters.generator(name, extent: .infinite) { x, y in
                func h(_ s: UInt64) -> Float {
                    var z = UInt64(bitPattern: Int64(x.rounded(.down))) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(y.rounded(.down))) &* 0xC2B2_AE3D_27D4_EB4F ^ s
                    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                    z ^= z >> 31
                    return Float(z >> 40) / Float(1 << 24)
                }
                return (h(1), h(2), h(3), h(4))
            }
        case "CICheckerboardGenerator":
            let c = vector(kCIInputCenterKey)?.cgPointValue ?? .zero, w = max(double(kCIInputWidthKey, 80), 1)
            let c0 = color("inputColor0").linear, c1 = color("inputColor1").linear
            return Filters.generator(name, extent: .infinite) { x, y in
                let i = Int(((x - Double(c.x)) / w).rounded(.down)) + Int(((y - Double(c.y)) / w).rounded(.down))
                return i & 1 == 0 ? c0 : c1
            }
        case "CIVignette":
            let k = Float(double(kCIInputIntensityKey)), e = input.extent
            guard !input.isEmpty, !e.isInfinite else { return input }
            let cx = Float(e.midX), cy = Float(e.midY), rr = Float(max(e.width, e.height) / 2) * Float(double(kCIInputRadiusKey, 1))
            let mask = Filters.generator(name, extent: e) { x, y in
                let d = ((Float(x) - cx) * (Float(x) - cx) + (Float(y) - cy) * (Float(y) - cy)).squareRoot() / max(rr, 1)
                let v = max(0, 1 - k * d * d)
                return (v, v, v, 1)
            }
            return Filters.compose("CIMultiplyCompositing", input, mask)
        default:
            return nil
        }
    }
}
