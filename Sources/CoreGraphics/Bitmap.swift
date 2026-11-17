// Bitmap contexts' software rasterizer, and CGImage.
//
// A bitmap CGContext sends its CGDisplayOps here (see Context.swift). Device
// space is the bitmap's, origin bottom-left as in Core Graphics. Every op
// becomes a layer of premultiplied colour over its device bounding box (a
// path's coverage times its colour, an image's samples, a gradient, text
// from CGTextRasterizer), which is then shadowed, clipped, faded by the op's
// alpha and blended into the bitmap (or the open transparency layer).
// Components stay in the context's own encoding: sRGB-encoded for sRGB and
// gray spaces, linear for linear spaces. Pixel layouts: RGBA/BGRA/ARGB/ABGR
// 8-bit (premultiplied, straight or opaque), alpha-only, gray (± alpha),
// 16-bit integer, half and full float RGBA.

import Foundation

// MARK: Bitmap layout

public enum CGImageAlphaInfo: UInt32, Sendable {
    case none = 0, premultipliedLast, premultipliedFirst, last, first, noneSkipLast, noneSkipFirst, alphaOnly
}

public enum CGImageByteOrderInfo: UInt32, Sendable {
    case orderMask = 0x7000, orderDefault = 0, order16Little = 0x1000, order32Little = 0x2000, order16Big = 0x3000, order32Big = 0x4000
}

public struct CGBitmapInfo: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(alpha: CGImageAlphaInfo) { rawValue = alpha.rawValue }
    public static let alphaInfoMask = CGBitmapInfo(rawValue: 0x1f)
    public static let floatInfoMask = CGBitmapInfo(rawValue: 0xf00)
    public static let floatComponents = CGBitmapInfo(rawValue: 1 << 8)
    public static let byteOrderMask = CGBitmapInfo(rawValue: 0x7000)
    public static let byteOrderDefault = CGBitmapInfo([])
    public static let byteOrder16Little = CGBitmapInfo(rawValue: 1 << 12)
    public static let byteOrder32Little = CGBitmapInfo(rawValue: 2 << 12)
    public static let byteOrder16Big = CGBitmapInfo(rawValue: 3 << 12)
    public static let byteOrder32Big = CGBitmapInfo(rawValue: 4 << 12)
}

public enum CGInterpolationQuality: Int32, Sendable { case `default` = 0, none, low, medium, high }

public enum CGTextDrawingMode: Int32, Sendable { case fill = 0, stroke, fillStroke, invisible, fillClip, strokeClip, fillStrokeClip, clip }

/// How a bitmap's pixels sit in memory.
struct PixelLayout {
    enum Kind { case rgba8, a8, gray8, grayAlpha8, half, float, rgba16 }
    var kind: Kind
    /// Byte (or component) offsets of r, g, b, a within a pixel.
    var order: (Int, Int, Int, Int) = (0, 1, 2, 3)
    var premultiplied = true
    var hasAlpha = true
    var bytesPerPixel: Int {
        switch kind {
        case .rgba8: 4
        case .a8, .gray8: 1
        case .grayAlpha8: 2
        case .half, .rgba16: 8
        case .float: 16
        }
    }

    init?(bitsPerComponent bpc: Int, components: Int, info: UInt32) {
        let alpha = CGImageAlphaInfo(rawValue: info & CGBitmapInfo.alphaInfoMask.rawValue) ?? .premultipliedLast
        let order = info & CGBitmapInfo.byteOrderMask.rawValue
        let isFloat = info & CGBitmapInfo.floatComponents.rawValue != 0
        premultiplied = alpha == .premultipliedLast || alpha == .premultipliedFirst
        hasAlpha = !(alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst)
        if alpha == .alphaOnly {
            guard bpc == 8 else { return nil }
            kind = .a8
            return
        }
        if components == 1 {
            guard bpc == 8 else { return nil }
            kind = hasAlpha ? .grayAlpha8 : .gray8
            return
        }
        let first = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        switch (bpc, isFloat) {
        case (8, false):
            kind = .rgba8
            let little = order == CGBitmapInfo.byteOrder32Little.rawValue
            switch (first, little) {
            case (false, false): self.order = (0, 1, 2, 3)
            case (true, false): self.order = (1, 2, 3, 0)
            case (true, true): self.order = (2, 1, 0, 3)
            case (false, true): self.order = (3, 2, 1, 0)
            }
        case (16, true): kind = .half; self.order = first ? (1, 2, 3, 0) : (0, 1, 2, 3)
        case (32, true): kind = .float; self.order = first ? (1, 2, 3, 0) : (0, 1, 2, 3)
        case (16, false): kind = .rgba16; self.order = first ? (1, 2, 3, 0) : (0, 1, 2, 3)
        default: return nil
        }
    }
}

// MARK: Images

/// An image as straight (non-premultiplied) sRGB RGBA8, row-major, top row first.
public final class CGImage: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let hasAlpha: Bool
    /// RGBA8, `width * 4` bytes per row.
    public let pixels: [UInt8]
    public var bitsPerComponent: Int { 8 }
    public var bitsPerPixel: Int { 32 }
    public var bytesPerRow: Int { width * 4 }
    public var colorSpace: CGColorSpace? { CGColorSpace() }
    public var alphaInfo: CGImageAlphaInfo { hasAlpha ? .last : .noneSkipLast }
    public var bitmapInfo: CGBitmapInfo { CGBitmapInfo(rawValue: alphaInfo.rawValue) }
    public var byteOrderInfo: CGImageByteOrderInfo { .orderDefault }
    public var isMask: Bool { false }
    public var shouldInterpolate: Bool { true }
    public var renderingIntent: CGColorRenderingIntent { .defaultIntent }
    public var dataProvider: CGDataProvider? { CGDataProvider(data: Data(pixels) as NSData) }

    public init(width: Int, height: Int, rgba: [UInt8], hasAlpha: Bool = true) {
        precondition(rgba.count >= width * height * 4, "CGImage: pixel buffer too small")
        self.width = width
        self.height = height
        self.pixels = rgba
        self.hasAlpha = hasAlpha
    }

    /// An image from raw pixels in any layout a bitmap context understands.
    public convenience init?(width: Int, height: Int, bitsPerComponent: Int, bitsPerPixel: Int, bytesPerRow: Int, space: CGColorSpace,
                             bitmapInfo: CGBitmapInfo, provider: CGDataProvider, decode: UnsafePointer<CGFloat>?, shouldInterpolate: Bool,
                             intent: CGColorRenderingIntent) {
        guard width > 0, height > 0, let layout = PixelLayout(bitsPerComponent: bitsPerComponent, components: space.numberOfComponents, info: bitmapInfo.rawValue),
              let data = provider.data as Data?, data.count >= bytesPerRow * (height - 1) + width * layout.bytesPerPixel else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeBytes { raw in
            let base = UnsafeMutableRawPointer(mutating: raw.baseAddress!)
            let surface = Surface(base: base, width: width, height: height, rowBytes: bytesPerRow, layout: layout)
            for y in 0..<height {
                for x in 0..<width {
                    let p = surface.read(x, height - 1 - y)
                    let a = p.3, o = (y * width + x) * 4
                    func enc(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
                    out[o] = enc(a > 0 ? p.0 / a : 0); out[o + 1] = enc(a > 0 ? p.1 / a : 0); out[o + 2] = enc(a > 0 ? p.2 / a : 0); out[o + 3] = enc(a)
                }
            }
        }
        if space.isLinear {
            for i in Swift.stride(from: 0, to: out.count, by: 4) {
                for c in 0..<3 { out[i + c] = UInt8(max(0, min(255, (Transfer.encode(CGFloat(out[i + c]) / 255) * 255).rounded()))) }
            }
        }
        self.init(width: width, height: height, rgba: out, hasAlpha: layout.hasAlpha)
    }

    public func cropping(to rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        let (x0, y0, w, h) = (Int(r.minX), Int(r.minY), Int(r.width), Int(r.height))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let src = ((y0 + y) * width + x0) * 4
            out.replaceSubrange(y * w * 4..<(y + 1) * w * 4, with: pixels[src..<src + w * 4])
        }
        return CGImage(width: w, height: h, rgba: out, hasAlpha: hasAlpha)
    }
    public func copy() -> CGImage? { self }
    public func copy(colorSpace: CGColorSpace) -> CGImage? { self }
}

public final class CGDataProvider: @unchecked Sendable {
    public let data: CFData?
    public init?(data: CFData) { self.data = data }
    public init?(url: CFURL) {
        guard let d = try? Data(contentsOf: url as URL) else { return nil }
        data = d as NSData
    }
    public init?(dataInfo: UnsafeMutableRawPointer?, data: UnsafeRawPointer, size: Int, releaseData: (@convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer, Int) -> Void)?) {
        self.data = Data(bytes: data, count: size) as NSData
        releaseData?(dataInfo, data, size)
    }
}

// MARK: Pixel access

struct Surface {
    let base: UnsafeMutableRawPointer
    let width: Int, height: Int, rowBytes: Int
    let layout: PixelLayout

    /// Premultiplied RGBA at device (x, y), y from the bottom.
    @inline(__always) func read(_ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
        let p = base + (height - 1 - y) * rowBytes + x * layout.bytesPerPixel
        let o = layout.order
        switch layout.kind {
        case .rgba8:
            let b = p.assumingMemoryBound(to: UInt8.self)
            var v = (Float(b[o.0]) / 255, Float(b[o.1]) / 255, Float(b[o.2]) / 255, layout.hasAlpha ? Float(b[o.3]) / 255 : 1)
            if !layout.premultiplied { v = (v.0 * v.3, v.1 * v.3, v.2 * v.3, v.3) }
            return v
        case .a8:
            return (0, 0, 0, Float(p.assumingMemoryBound(to: UInt8.self)[0]) / 255)
        case .gray8:
            let g = Float(p.assumingMemoryBound(to: UInt8.self)[0]) / 255
            return (g, g, g, 1)
        case .grayAlpha8:
            let b = p.assumingMemoryBound(to: UInt8.self)
            let a = Float(b[1]) / 255, g = Float(b[0]) / 255 * (layout.premultiplied ? 1 : a)
            return (g, g, g, a)
        case .half:
            let h = p.assumingMemoryBound(to: UInt16.self)
            func f(_ i: Int) -> Float { Float(Float16(bitPattern: UInt16(littleEndian: h[i]))) }
            var v = (f(o.0), f(o.1), f(o.2), layout.hasAlpha ? f(o.3) : 1)
            if !layout.premultiplied { v = (v.0 * v.3, v.1 * v.3, v.2 * v.3, v.3) }
            return v
        case .float:
            let fl = p.assumingMemoryBound(to: Float.self)
            var v = (fl[o.0], fl[o.1], fl[o.2], layout.hasAlpha ? fl[o.3] : 1)
            if !layout.premultiplied { v = (v.0 * v.3, v.1 * v.3, v.2 * v.3, v.3) }
            return v
        case .rgba16:
            let s = p.assumingMemoryBound(to: UInt16.self)
            var v = (Float(s[o.0]) / 65535, Float(s[o.1]) / 65535, Float(s[o.2]) / 65535, layout.hasAlpha ? Float(s[o.3]) / 65535 : 1)
            if !layout.premultiplied { v = (v.0 * v.3, v.1 * v.3, v.2 * v.3, v.3) }
            return v
        }
    }

    @inline(__always) func write(_ x: Int, _ y: Int, _ v: (Float, Float, Float, Float)) {
        let p = base + (height - 1 - y) * rowBytes + x * layout.bytesPerPixel
        let o = layout.order
        var c = v
        if !layout.premultiplied || !layout.hasAlpha {
            let a = layout.hasAlpha ? v.3 : 1
            c = v.3 > 0 ? (v.0 / v.3 * (layout.hasAlpha ? 1 : 1), v.1 / v.3, v.2 / v.3, a) : (0, 0, 0, layout.hasAlpha ? 0 : 1)
            if !layout.hasAlpha { c = (v.0, v.1, v.2, 1) }
        }
        @inline(__always) func u8(_ f: Float) -> UInt8 { UInt8(max(0, min(255, (f * 255).rounded()))) }
        switch layout.kind {
        case .rgba8:
            let b = p.assumingMemoryBound(to: UInt8.self)
            b[o.0] = u8(c.0); b[o.1] = u8(c.1); b[o.2] = u8(c.2); b[o.3] = layout.hasAlpha ? u8(c.3) : 255
        case .a8:
            p.assumingMemoryBound(to: UInt8.self)[0] = u8(v.3)
        case .gray8:
            p.assumingMemoryBound(to: UInt8.self)[0] = u8(0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2)
        case .grayAlpha8:
            let b = p.assumingMemoryBound(to: UInt8.self)
            b[0] = u8(0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2); b[1] = u8(c.3)
        case .half:
            let h = p.assumingMemoryBound(to: UInt16.self)
            h[o.0] = Float16(c.0).bitPattern.littleEndian; h[o.1] = Float16(c.1).bitPattern.littleEndian
            h[o.2] = Float16(c.2).bitPattern.littleEndian; h[o.3] = Float16(layout.hasAlpha ? c.3 : 1).bitPattern.littleEndian
        case .float:
            let f = p.assumingMemoryBound(to: Float.self)
            f[o.0] = c.0; f[o.1] = c.1; f[o.2] = c.2; f[o.3] = layout.hasAlpha ? c.3 : 1
        case .rgba16:
            let s = p.assumingMemoryBound(to: UInt16.self)
            func u16(_ f: Float) -> UInt16 { UInt16(max(0, min(65535, (f * 65535).rounded()))) }
            s[o.0] = u16(c.0); s[o.1] = u16(c.1); s[o.2] = u16(c.2); s[o.3] = layout.hasAlpha ? u16(c.3) : 65535
        }
    }
}

/// Premultiplied colour over a device rectangle, rows from the bottom.
struct Layer {
    var x: Int, y: Int, w: Int, h: Int
    var px: [Float]
    init(x: Int, y: Int, w: Int, h: Int) {
        self.x = x; self.y = y; self.w = max(w, 0); self.h = max(h, 0)
        px = [Float](repeating: 0, count: self.w * self.h * 4)
    }
    var isEmpty: Bool { w <= 0 || h <= 0 }
}

// MARK: The bitmap target

/// Renders text layouts for bitmap contexts (CoreText installs one; native
/// targets draw text themselves). Returns the layout drawn at `scale`
/// pixels per point, its top-left at the image's, and the layout's size in points.
public enum CGTextRasterizer {
    nonisolated(unsafe) public static var render: ((CGTextLayout, CGFloat) -> (image: CGImage, size: CGSize)?)?
}

/// A bitmap as a CGRenderTarget.
final class SurfaceRaster: CGRenderTarget {
    let surface: Surface
    let linear: Bool
    var width: Int { surface.width }
    var height: Int { surface.height }
    private var clip: [Float]?
    private var clipStack: [[Float]?] = []
    /// Open transparency layers (full-size), each with the state to paint it with.
    private var groups: [(layer: Layer, state: CGDrawState)] = []

    init(surface: Surface, linear: Bool) {
        self.surface = surface
        self.linear = linear
    }

    /// RGBA (sRGB-encoded) as premultiplied components in this bitmap's encoding.
    func premultiplied(_ c: [CGFloat]) -> (Float, Float, Float, Float) {
        let v = c.count >= 4 ? c : (c.count == 2 ? [c[0], c[0], c[0], c[1]] : [0, 0, 0, 1])
        var (r, g, b) = (v[0], v[1], v[2])
        if linear { (r, g, b) = (Transfer.linear(r), Transfer.linear(g), Transfer.linear(b)) }
        let a = Float(max(0, min(1, v[3])))
        return (Float(r) * a, Float(g) * a, Float(b) * a, a)
    }

    func execute(_ op: CGDisplayOp) {
        switch op {
        case .save: clipStack.append(clip)
        case .restore: if let c = clipStack.popLast() { clip = c }
        case let .clip(p, rule, ctm):
            let cov = Raster.fill(p.copy(using: ctm).flattened(tolerance: 0.2).map(\.points), rule: rule, width: width, height: height, antialias: true)
            var mask = [Float](repeating: 0, count: width * height)
            for y in 0..<cov.h { for x in 0..<cov.w { mask[(cov.y + y) * width + cov.x + x] = cov.px[(y * cov.w + x) * 4 + 3] } }
            if let old = clip { for i in 0..<mask.count { mask[i] *= old[i] } }
            clip = mask
        case let .fill(p, rule, color, s):
            let cov = Raster.fill(p.copy(using: s.ctm).flattened(tolerance: 0.2).map(\.points), rule: rule, width: width, height: height, antialias: s.antialias)
            paintCoverage(cov, color, s)
        case let .stroke(p, style, color, s):
            let t = s.ctm
            let scale = abs(t.a * t.d - t.b * t.c).squareRoot()
            let lines = p.copy(using: t).flattened(tolerance: 0.2).map { (points: $0.points, closed: $0.closed) }
            let polys = Raster.strokePolygons(lines, width: max(style.lineWidth * scale, 0.5), join: style.lineJoin, cap: style.lineCap,
                                              miterLimit: style.miterLimit, dash: (style.dashPhase * scale, style.dashLengths.map { $0 * scale }))
            paintCoverage(Raster.fill(polys, rule: .winding, width: width, height: height, antialias: s.antialias), color, s)
        case let .clear(r, ctm):
            let p = CGMutablePath()
            p.addRect(r)
            let cov = Raster.fill(p.copy(using: ctm).flattened().map(\.points), rule: .winding, width: width, height: height, antialias: false)
            for y in 0..<cov.h {
                for x in 0..<cov.w where cov.px[(y * cov.w + x) * 4 + 3] > 0.5 { write(cov.x + x, cov.y + y, (0, 0, 0, 0)) }
            }
        case let .image(img, rect, q, s):
            paint(Raster.image(img, in: rect, ctm: s.ctm, width: width, height: height, quality: q, linear: linear), s)
        case let .linearGradient(g, a, b, o, s):
            let inv = s.ctm.inverted()
            let dx = b.x - a.x, dy = b.y - a.y, len2 = max(dx * dx + dy * dy, 1e-12)
            paintGradient(g, s) { x, y in
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inv)
                let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
                if t < 0, !o.contains(.drawsBeforeStartLocation) { return nil }
                if t > 1, !o.contains(.drawsAfterEndLocation) { return nil }
                return min(max(t, 0), 1)
            }
        case let .radialGradient(g, c0, r0, c1, r1, o, s):
            let inv = s.ctm.inverted()
            let cdx = c1.x - c0.x, cdy = c1.y - c0.y, dr = r1 - r0
            let A = cdx * cdx + cdy * cdy - dr * dr
            paintGradient(g, s) { x, y in
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inv)
                let pdx = p.x - c0.x, pdy = p.y - c0.y
                let B = pdx * cdx + pdy * cdy + r0 * dr
                let C = pdx * pdx + pdy * pdy - r0 * r0
                var t: CGFloat
                if abs(A) < 1e-9 {
                    guard abs(B) > 1e-12 else { return nil }
                    t = C / (2 * B)
                } else {
                    let disc = B * B - A * C
                    guard disc >= 0 else { return nil }
                    t = (B + disc.squareRoot()) / A
                    if r0 + t * dr < 0 { t = (B - disc.squareRoot()) / A }
                }
                if r0 + t * dr < 0 { return nil }
                if t < 0, !o.contains(.drawsBeforeStartLocation) { return nil }
                if t > 1, !o.contains(.drawsAfterEndLocation) { return nil }
                return min(max(t, 0), 1)
            }
        case let .text(layout, origin, flipped, s):
            let scale = max(abs(s.ctm.a * s.ctm.d - s.ctm.b * s.ctm.c).squareRoot(), 1e-3)
            guard let (image, size) = CGTextRasterizer.render?(layout, scale) else { return }
            // The box's top-left at `origin`; glyphs upright in either space.
            let local: CGAffineTransform = flipped
                ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x, ty: origin.y + size.height)
                : CGAffineTransform(translationX: origin.x, y: origin.y - size.height)
            var st = s
            st.ctm = local.concatenating(s.ctm)
            paint(Raster.image(image, in: CGRect(origin: .zero, size: size), ctm: st.ctm, width: width, height: height, quality: .high, linear: linear), st)
        }
    }

    // MARK: Painting

    private func paintCoverage(_ cov: Layer, _ color: [CGFloat], _ s: CGDrawState) {
        guard !cov.isEmpty else { return }
        let c = premultiplied(color)
        var l = cov
        l.px.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                let k = p[i + 3]
                p[i] = c.0 * k; p[i + 1] = c.1 * k; p[i + 2] = c.2 * k; p[i + 3] = c.3 * k
                i += 4
            }
        }
        paint(l, s)
    }

    private func paintGradient(_ g: CGGradient, _ s: CGDrawState, _ t: (Int, Int) -> CGFloat?) {
        var l = Layer(x: 0, y: 0, w: width, h: height)
        for y in 0..<height {
            for x in 0..<width {
                guard let v = t(x, y) else { continue }
                // Interpolated in the gradient's space; delivered in the bitmap's.
                var c = g.color(at: v, linear: g.interpolatesInLinearLight)
                if g.interpolatesInLinearLight != linear {
                    c = linear ? c.prefix(3).map(Transfer.linear) + [c[3]] : c.prefix(3).map(Transfer.encode) + [c[3]]
                }
                let i = (y * width + x) * 4, a = Float(c[3])
                l.px[i] = Float(c[0]) * a; l.px[i + 1] = Float(c[1]) * a; l.px[i + 2] = Float(c[2]) * a; l.px[i + 3] = a
            }
        }
        paint(l, s)
    }

    /// Shadow, clip, alpha and blend a layer into the bitmap (or the open group).
    func paint(_ layer: Layer, _ s: CGDrawState) {
        guard !layer.isEmpty else { return }
        if let sh = s.shadow, sh.color.count >= 4, sh.color[3] > 0 {
            let shadow = Raster.shadow(of: layer, offset: sh.offset, blur: sh.blur, color: premultiplied(sh.color), width: width, height: height)
            composite(shadow, alpha: Float(s.alpha), blend: .normal)
        }
        composite(layer, alpha: Float(s.alpha), blend: s.blendMode)
    }

    @inline(__always) private func read(_ x: Int, _ y: Int) -> (Float, Float, Float, Float) {
        guard let top = groups.last else { return surface.read(x, y) }
        let i = (y * width + x) * 4, p = top.layer.px
        return (p[i], p[i + 1], p[i + 2], p[i + 3])
    }
    @inline(__always) private func write(_ x: Int, _ y: Int, _ v: (Float, Float, Float, Float)) {
        guard !groups.isEmpty else { return surface.write(x, y, v) }
        let i = (y * width + x) * 4, g = groups.count - 1
        groups[g].layer.px[i] = v.0; groups[g].layer.px[i + 1] = v.1; groups[g].layer.px[i + 2] = v.2; groups[g].layer.px[i + 3] = v.3
    }

    private func composite(_ layer: Layer, alpha: Float, blend: CGBlendMode) {
        let x0 = max(layer.x, 0), y0 = max(layer.y, 0), x1 = min(layer.x + layer.w, width), y1 = min(layer.y + layer.h, height)
        guard x0 < x1, y0 < y1 else { return }
        let clip = self.clip
        for y in y0..<y1 {
            for x in x0..<x1 {
                let li = ((y - layer.y) * layer.w + (x - layer.x)) * 4
                var k = alpha
                if let clip { k *= clip[y * width + x] }
                let src = (layer.px[li] * k, layer.px[li + 1] * k, layer.px[li + 2] * k, layer.px[li + 3] * k)
                if src.3 <= 0, blend != .copy, blend != .sourceIn, blend != .destinationIn, blend != .sourceOut, blend != .clear { continue }
                write(x, y, Raster.blend(src, read(x, y), blend, coverage: k))
            }
        }
    }

    // MARK: Transparency layers

    func beginGroup(_ state: CGDrawState) { groups.append((Layer(x: 0, y: 0, w: width, h: height), state)) }
    func endGroup() {
        guard let (layer, state) = groups.popLast() else { return }
        paint(layer, state)
    }

    // MARK: Output

    func makeImage() -> CGImage {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let s = surface
        for y in 0..<height {
            for x in 0..<width {
                let p = s.read(x, height - 1 - y), d = (y * width + x) * 4
                let a = max(0, min(1, p.3))
                var c = a > 0 ? (p.0 / a, p.1 / a, p.2 / a) : (0, 0, 0)
                if linear { c = (Float(Transfer.encode(CGFloat(c.0))), Float(Transfer.encode(CGFloat(c.1))), Float(Transfer.encode(CGFloat(c.2)))) }
                func u8(_ f: Float) -> UInt8 { UInt8(max(0, min(255, (f * 255).rounded()))) }
                out[d] = u8(c.0); out[d + 1] = u8(c.1); out[d + 2] = u8(c.2)
                out[d + 3] = s.layout.hasAlpha ? u8(a) : 255
            }
        }
        return CGImage(width: width, height: height, rgba: out, hasAlpha: surface.layout.hasAlpha)
    }
}

// MARK: Rasterizer

enum Raster {
    static func blend(_ s: (Float, Float, Float, Float), _ d: (Float, Float, Float, Float), _ m: CGBlendMode, coverage: Float) -> (Float, Float, Float, Float) {
        func over(_ c: (Float, Float, Float, Float)) -> (Float, Float, Float, Float) { c }
        switch m {
        case .copy:
            // Replaces within the coverage.
            let k = 1 - coverage
            return (s.0 + d.0 * k, s.1 + d.1 * k, s.2 + d.2 * k, s.3 + d.3 * k)
        case .clear: let k = 1 - coverage; return (d.0 * k, d.1 * k, d.2 * k, d.3 * k)
        case .sourceIn: return (s.0 * d.3, s.1 * d.3, s.2 * d.3, s.3 * d.3)
        case .sourceOut: let k = 1 - d.3; return (s.0 * k, s.1 * k, s.2 * k, s.3 * k)
        case .sourceAtop: let k = 1 - s.3; return (s.0 * d.3 + d.0 * k, s.1 * d.3 + d.1 * k, s.2 * d.3 + d.2 * k, d.3)
        case .destinationOver: let k = 1 - d.3; return (d.0 + s.0 * k, d.1 + s.1 * k, d.2 + s.2 * k, d.3 + s.3 * k)
        case .destinationIn: return (d.0 * s.3, d.1 * s.3, d.2 * s.3, d.3 * s.3)
        case .destinationOut: let k = 1 - s.3; return (d.0 * k, d.1 * k, d.2 * k, d.3 * k)
        case .destinationAtop: let k = 1 - d.3; return (d.0 * s.3 + s.0 * k, d.1 * s.3 + s.1 * k, d.2 * s.3 + s.2 * k, s.3)
        case .xor:
            let ks = 1 - d.3, kd = 1 - s.3
            return (s.0 * ks + d.0 * kd, s.1 * ks + d.1 * kd, s.2 * ks + d.2 * kd, s.3 * ks + d.3 * kd)
        case .plusLighter: return (min(1, s.0 + d.0), min(1, s.1 + d.1), min(1, s.2 + d.2), min(1, s.3 + d.3))
        case .plusDarker:
            return (max(0, s.0 + d.0 - 1), max(0, s.1 + d.1 - 1), max(0, s.2 + d.2 - 1), min(1, s.3 + d.3))
        case .multiply, .screen, .darken, .lighten, .difference, .exclusion, .overlay:
            func f(_ sc: Float, _ dc: Float) -> Float {
                let b: Float
                switch m {
                case .multiply: b = sc * dc
                case .screen: b = sc * d.3 + dc * s.3 - sc * dc
                case .darken: b = min(sc * d.3, dc * s.3)
                case .lighten: b = max(sc * d.3, dc * s.3)
                case .difference: b = abs(sc * d.3 - dc * s.3)
                case .exclusion: b = sc * d.3 + dc * s.3 - 2 * sc * dc
                default: b = 2 * dc < d.3 ? 2 * sc * dc : s.3 * d.3 - 2 * (d.3 - dc) * (s.3 - sc)
                }
                return b + sc * (1 - d.3) + dc * (1 - s.3)
            }
            return (f(s.0, d.0), f(s.1, d.1), f(s.2, d.2), s.3 + d.3 * (1 - s.3))
        default:
            let k = 1 - s.3
            return (s.0 + d.0 * k, s.1 + d.1 * k, s.2 + d.2 * k, s.3 + d.3 * k)
        }
    }

    /// Anti-aliased coverage of polygons (device space) as a layer's alpha.
    static func fill(_ polys: [[CGPoint]], rule: CGPathFillRule, width: Int, height: Int, antialias: Bool) -> Layer {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for p in polys { for q in p { minX = min(minX, q.x); maxX = max(maxX, q.x); minY = min(minY, q.y); maxY = max(maxY, q.y) } }
        guard minX.isFinite, maxX > minX || maxY > minY else { return Layer(x: 0, y: 0, w: 0, h: 0) }
        let x0 = max(0, Int(minX.rounded(.down))), x1 = min(width, Int(maxX.rounded(.up)))
        let y0 = max(0, Int(minY.rounded(.down))), y1 = min(height, Int(maxY.rounded(.up)))
        var l = Layer(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        guard !l.isEmpty else { return l }
        // Edges, oriented with their winding direction.
        var edges: [(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, dir: Int)] = []
        for p in polys where p.count > 1 {
            for i in 0..<p.count {
                let a = p[i], b = p[(i + 1) % p.count]
                if a.y == b.y { continue }
                edges.append(a.y < b.y ? (a.x, a.y, b.x, b.y, 1) : (b.x, b.y, a.x, a.y, -1))
            }
        }
        let sub = antialias ? 4 : 1
        let w = l.w
        var acc = [Float](repeating: 0, count: w)
        var xs: [(CGFloat, Int)] = []
        for row in 0..<l.h {
            for i in 0..<w { acc[i] = 0 }
            let py = CGFloat(y0 + row)
            for s in 0..<sub {
                let sy = py + (CGFloat(s) + 0.5) / CGFloat(sub)
                xs.removeAll(keepingCapacity: true)
                for e in edges where sy >= e.y0 && sy < e.y1 {
                    xs.append((e.x0 + (sy - e.y0) / (e.y1 - e.y0) * (e.x1 - e.x0), e.dir))
                }
                guard xs.count > 1 else { continue }
                xs.sort { $0.0 < $1.0 }
                var wind = 0
                for k in 0..<(xs.count - 1) {
                    wind += xs[k].1
                    let inside = rule == .winding ? wind != 0 : wind & 1 != 0
                    guard inside else { continue }
                    var a = xs[k].0 - CGFloat(x0), b = xs[k + 1].0 - CGFloat(x0)
                    if !antialias { a = a.rounded(); b = b.rounded() }
                    a = max(a, 0); b = min(b, CGFloat(w))
                    guard b > a else { continue }
                    let ia = Int(a), ib = min(Int(b.rounded(.up)), w)
                    let weight = 1 / Float(sub)
                    for px in ia..<ib {
                        let o = min(b, CGFloat(px + 1)) - max(a, CGFloat(px))
                        if o > 0 { acc[px] += Float(o) * weight }
                    }
                }
            }
            let base = row * w * 4
            for i in 0..<w { l.px[base + i * 4 + 3] = min(acc[i], 1) }
        }
        return l
    }

    /// Outline polygons of a stroke (each wound the same way).
    static func strokePolygons(_ subpaths: [(points: [CGPoint], closed: Bool)], width: CGFloat, join: CGLineJoin, cap: CGLineCap,
                               miterLimit: CGFloat, dash: (phase: CGFloat, lengths: [CGFloat])) -> [[CGPoint]] {
        let hw = width / 2
        var out: [[CGPoint]] = []
        func oriented(_ p: [CGPoint]) -> [CGPoint] {
            var area: CGFloat = 0
            for i in 0..<p.count { let a = p[i], b = p[(i + 1) % p.count]; area += a.x * b.y - b.x * a.y }
            return area < 0 ? p.reversed() : p
        }
        func circle(_ c: CGPoint) {
            let n = max(8, min(48, Int(hw * 2)))
            out.append(oriented((0..<n).map { i in
                let a = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: c.x + hw * cos(a), y: c.y + hw * sin(a))
            }))
        }
        var lines: [(points: [CGPoint], closed: Bool)] = []
        let pattern = dash.lengths.filter { $0 > 0 }
        if pattern.isEmpty || pattern.reduce(0, +) <= 0 {
            lines = subpaths
        } else {
            // Split into dashes.
            for (pts, closed) in subpaths {
                var seq = pts
                if closed, let f = pts.first { seq.append(f) }
                var idx = 0, left = pattern[0], on = true
                var phase = dash.phase.truncatingRemainder(dividingBy: pattern.reduce(0, +))
                while phase > 0 {
                    if phase >= left { phase -= left; idx = (idx + 1) % pattern.count; left = pattern[idx]; on.toggle() } else { left -= phase; phase = 0 }
                }
                var cur: [CGPoint] = on ? [seq[0]] : []
                for i in 1..<max(seq.count, 1) {
                    var a = seq[i - 1]
                    let b = seq[i]
                    var segLen = hypot(b.x - a.x, b.y - a.y)
                    while segLen > 0 {
                        if segLen <= left {
                            left -= segLen
                            if on { cur.append(b) }
                            segLen = 0
                        } else {
                            let k = left / segLen
                            let m = CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
                            if on { cur.append(m); lines.append((cur, false)); cur = [] } else { cur = [m] }
                            segLen -= left
                            a = m
                            idx = (idx + 1) % pattern.count
                            left = pattern[idx]
                            on.toggle()
                        }
                    }
                }
                if on, cur.count > 1 { lines.append((cur, false)) }
            }
        }
        for (raw, closed) in lines {
            var pts: [CGPoint] = []
            for p in raw where pts.last.map({ hypot($0.x - p.x, $0.y - p.y) > 1e-6 }) ?? true { pts.append(p) }
            if closed, pts.count > 2, let f = pts.first, let l = pts.last, hypot(f.x - l.x, f.y - l.y) < 1e-6 { pts.removeLast() }
            if pts.count == 1 {
                if cap == .round { circle(pts[0]) }
                if cap == .square { let p = pts[0]; out.append(oriented([CGPoint(x: p.x - hw, y: p.y - hw), CGPoint(x: p.x + hw, y: p.y - hw), CGPoint(x: p.x + hw, y: p.y + hw), CGPoint(x: p.x - hw, y: p.y + hw)])) }
                continue
            }
            guard pts.count > 1 else { continue }
            let n = closed ? pts.count : pts.count - 1
            for i in 0..<n {
                var a = pts[i], b = pts[(i + 1) % pts.count]
                let len = hypot(b.x - a.x, b.y - a.y)
                guard len > 0 else { continue }
                let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
                if !closed, cap == .square {
                    if i == 0 { a = CGPoint(x: a.x - ux * hw, y: a.y - uy * hw) }
                    if i == n - 1 { b = CGPoint(x: b.x + ux * hw, y: b.y + uy * hw) }
                }
                let nx = -uy * hw, ny = ux * hw
                out.append(oriented([CGPoint(x: a.x + nx, y: a.y + ny), CGPoint(x: b.x + nx, y: b.y + ny), CGPoint(x: b.x - nx, y: b.y - ny), CGPoint(x: a.x - nx, y: a.y - ny)]))
            }
            // Joins.
            let joints = closed ? Array(0..<pts.count) : Array(1..<(pts.count - 1))
            for j in joints {
                let p = pts[j], prev = pts[(j - 1 + pts.count) % pts.count], next = pts[(j + 1) % pts.count]
                let l1 = hypot(p.x - prev.x, p.y - prev.y), l2 = hypot(next.x - p.x, next.y - p.y)
                guard l1 > 0, l2 > 0 else { continue }
                let u1 = CGPoint(x: (p.x - prev.x) / l1, y: (p.y - prev.y) / l1), u2 = CGPoint(x: (next.x - p.x) / l2, y: (next.y - p.y) / l2)
                let cross = u1.x * u2.y - u1.y * u2.x
                if abs(cross) < 1e-6, u1.x * u2.x + u1.y * u2.y > 0 { continue }
                switch join {
                case .round: circle(p)
                case .bevel, .miter:
                    // The outer side of the turn.
                    let s: CGFloat = cross > 0 ? -1 : 1
                    let n1 = CGPoint(x: -u1.y * hw * s, y: u1.x * hw * s), n2 = CGPoint(x: -u2.y * hw * s, y: u2.x * hw * s)
                    let a = CGPoint(x: p.x + n1.x, y: p.y + n1.y), b = CGPoint(x: p.x + n2.x, y: p.y + n2.y)
                    let cosT = max(-1, min(1, u1.x * u2.x + u1.y * u2.y))
                    let theta = acos(-cosT) // angle between the segments
                    let miter = theta > 1e-6 ? 1 / sin(theta / 2) : .infinity
                    if join == .miter, miter <= miterLimit {
                        let bis = CGPoint(x: n1.x + n2.x, y: n1.y + n2.y), bl = hypot(bis.x, bis.y)
                        if bl > 1e-9 {
                            let m = CGPoint(x: p.x + bis.x / bl * hw * miter, y: p.y + bis.y / bl * hw * miter)
                            out.append(oriented([p, a, m, b]))
                            continue
                        }
                    }
                    out.append(oriented([p, a, b]))
                }
            }
            if !closed, cap == .round { circle(pts[0]); circle(pts[pts.count - 1]) }
        }
        return out
    }

    /// `image` drawn into user `rect` through `ctm`, as a layer.
    static func image(_ image: CGImage, in rect: CGRect, ctm: CGAffineTransform, width: Int, height: Int, quality: CGInterpolationQuality, linear: Bool) -> Layer {
        let dev = rect.applying(ctm)
        let x0 = max(0, Int(dev.minX.rounded(.down))), x1 = min(width, Int(dev.maxX.rounded(.up)))
        let y0 = max(0, Int(dev.minY.rounded(.down))), y1 = min(height, Int(dev.maxY.rounded(.up)))
        var l = Layer(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        guard !l.isEmpty else { return l }
        let inv = ctm.inverted()
        let iw = image.width, ih = image.height
        let sx = CGFloat(iw) / abs(rect.width), sy = CGFloat(ih) / abs(rect.height)
        let devScale = abs(ctm.a * ctm.d - ctm.b * ctm.c).squareRoot()
        let shrink = max(sx, sy) / max(devScale, 1e-9)
        let nearest = quality == .none
        let n = nearest ? 1 : max(1, min(8, Int(shrink.rounded(.up))))
        let px = image.pixels
        let lin: [Float] = (0..<256).map { i in
            let c = CGFloat(i) / 255
            return Float(linear ? Transfer.linear(c) : c)
        }
        // Premultiplied sample of image pixel (ix, iy from the top).
        @inline(__always) func at(_ ix: Int, _ iy: Int) -> (Float, Float, Float, Float) {
            let i = (iy * iw + ix) * 4
            let a = Float(px[i + 3]) / 255
            return (lin[Int(px[i])] * a, lin[Int(px[i + 1])] * a, lin[Int(px[i + 2])] * a, a)
        }
        px.withUnsafeBufferPointer { _ in
            for y in 0..<l.h {
                for x in 0..<l.w {
                    var acc: (Float, Float, Float, Float) = (0, 0, 0, 0)
                    var hits = 0
                    for j in 0..<n {
                        for i in 0..<n {
                            let d = CGPoint(x: CGFloat(x0 + x) + (CGFloat(i) + 0.5) / CGFloat(n), y: CGFloat(y0 + y) + (CGFloat(j) + 0.5) / CGFloat(n))
                            let u = d.applying(inv)
                            let fu = (u.x - rect.minX) / rect.width, fv = (u.y - rect.minY) / rect.height
                            guard fu >= 0, fu < 1, fv >= 0, fv < 1 else { continue }
                            hits += 1
                            let fx = fu * CGFloat(iw), fy = (1 - fv) * CGFloat(ih)
                            if nearest || n > 1 {
                                let v = at(min(iw - 1, Int(fx)), min(ih - 1, Int(fy)))
                                acc.0 += v.0; acc.1 += v.1; acc.2 += v.2; acc.3 += v.3
                            } else {
                                let gx = fx - 0.5, gy = fy - 0.5
                                let ax = max(0, min(iw - 1, Int(gx.rounded(.down)))), ay = max(0, min(ih - 1, Int(gy.rounded(.down))))
                                let bx = min(iw - 1, ax + 1), by = min(ih - 1, ay + 1)
                                let tx = Float(max(0, min(1, gx - CGFloat(ax)))), ty = Float(max(0, min(1, gy - CGFloat(ay))))
                                let p00 = at(ax, ay), p10 = at(bx, ay), p01 = at(ax, by), p11 = at(bx, by)
                                func m(_ a: Float, _ b: Float, _ c: Float, _ e: Float) -> Float { (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + e * tx) * ty }
                                acc.0 += m(p00.0, p10.0, p01.0, p11.0); acc.1 += m(p00.1, p10.1, p01.1, p11.1)
                                acc.2 += m(p00.2, p10.2, p01.2, p11.2); acc.3 += m(p00.3, p10.3, p01.3, p11.3)
                            }
                        }
                    }
                    guard hits > 0 else { continue }
                    let k = 1 / Float(n * n), o = (y * l.w + x) * 4
                    l.px[o] = acc.0 * k; l.px[o + 1] = acc.1 * k; l.px[o + 2] = acc.2 * k; l.px[o + 3] = acc.3 * k
                }
            }
        }
        return l
    }

    /// The layer's alpha, blurred (σ = blur / 2), offset and coloured.
    static func shadow(of layer: Layer, offset: CGSize, blur: CGFloat, color: (Float, Float, Float, Float), width: Int, height: Int) -> Layer {
        let sigma = Double(blur) / 2
        let r = sigma > 0.01 ? Int((sigma * 3).rounded(.up)) : 0
        var out = Layer(x: layer.x + Int(offset.width.rounded()) - r, y: layer.y + Int(offset.height.rounded()) - r, w: layer.w + 2 * r, h: layer.h + 2 * r)
        guard !out.isEmpty else { return out }
        var a = [Float](repeating: 0, count: out.w * out.h)
        for y in 0..<layer.h { for x in 0..<layer.w { a[(y + r) * out.w + x + r] = layer.px[(y * layer.w + x) * 4 + 3] } }
        if r > 0 {
            var k = (-r...r).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
            let s = k.reduce(0, +)
            k = k.map { $0 / s }
            var tmp = [Float](repeating: 0, count: a.count)
            for y in 0..<out.h { for x in 0..<out.w {
                var v: Float = 0
                for d in -r...r { let xx = x + d; if xx >= 0, xx < out.w { v += a[y * out.w + xx] * k[d + r] } }
                tmp[y * out.w + x] = v
            } }
            for y in 0..<out.h { for x in 0..<out.w {
                var v: Float = 0
                for d in -r...r { let yy = y + d; if yy >= 0, yy < out.h { v += tmp[yy * out.w + x] * k[d + r] } }
                a[y * out.w + x] = v
            } }
        }
        for i in 0..<a.count {
            out.px[i * 4] = color.0 * a[i]; out.px[i * 4 + 1] = color.1 * a[i]; out.px[i * 4 + 2] = color.2 * a[i]; out.px[i * 4 + 3] = color.3 * a[i]
        }
        return out
    }
}

