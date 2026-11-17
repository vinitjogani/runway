// CIContext: evaluates images on the CPU in 256-pixel tiles (memory stays
// a few tiles' worth however large the output), into CGImages, pixel
// buffers and bitmaps. There is no Metal device here, so a Metal context is
// the same CPU context (Core Image's own software-renderer fallback).

import CoreGraphics
import CoreVideo
import Foundation
import Metal

public struct CIContextOption: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let workingColorSpace = Self(rawValue: "working_color_space"), outputColorSpace = Self(rawValue: "output_color_space")
    public static let workingFormat = Self(rawValue: "working_format"), useSoftwareRenderer = Self(rawValue: "software_renderer")
    public static let cacheIntermediates = Self(rawValue: "kCIContextCacheIntermediates"), name = Self(rawValue: "kCIContextName")
    public static let highQualityDownsample = Self(rawValue: "high_quality_downsample"), priorityRequestLow = Self(rawValue: "priority_request_low")
    public static let outputPremultiplied = Self(rawValue: "output_premultiplied"), allowLowPower = Self(rawValue: "allow_low_power")
    public static let memoryTarget = Self(rawValue: "memory_target")
}

public final class CIContext: NSObject, @unchecked Sendable {
    public let options: [CIContextOption: Any]
    public var workingColorSpace: CGColorSpace? { CGColorSpace(name: CGColorSpace.linearSRGB) }
    public var workingFormat: CIFormat { .RGBAh }
    static let tileSize = 256

    public init(options: [CIContextOption: Any]?) {
        self.options = options ?? [:]
        super.init()
    }
    public override convenience init() { self.init(options: nil) }
    public convenience init(mtlDevice device: any MTLDevice) { self.init(options: nil) }
    public convenience init(mtlDevice device: any MTLDevice, options: [CIContextOption: Any]?) { self.init(options: options) }
    public convenience init(mtlCommandQueue: any MTLCommandQueue, options: [CIContextOption: Any]? = nil) { self.init(options: options) }
    public convenience init(cgContext: CGContext, options: [CIContextOption: Any]?) { self.init(options: options) }
    public static func context(options: [CIContextOption: Any]? = nil) -> CIContext { CIContext(options: options) }

    public func clearCaches() {}
    public func reclaimResources() {}

    /// Visits `rect` tile by tile (Core Image space), top row of tiles first.
    func tiles(_ image: CIImage, _ rect: CGRect, _ body: (Tile) -> Void) {
        let (x0, y0, w, h) = ints(rect)
        let n = Self.tileSize
        var ty = y0 + h
        while ty > y0 {
            let th = min(n, ty - y0)
            var rects: [(Int, Int, Int, Int)] = []
            var tx = x0
            while tx < x0 + w {
                let tw = min(n, x0 + w - tx)
                rects.append((tx, ty - th, tw, th))
                tx += tw
            }
            // A row of tiles at a time, rendered on all cores (images are
            // immutable and their caches locked); visited in order.
            if rects.count == 1 {
                body(Renderer.render(image, rects[0]))
            } else {
                let row = TileRow(count: rects.count)
                DispatchQueue.concurrentPerform(iterations: rects.count) { i in row.set(i, Renderer.render(image, rects[i])) }
                for t in row.tiles { body(t!) }
            }
            ty -= th
        }
    }

    /// RGBA bytes (top row first) for `rect`: straight alpha (CGImage) or premultiplied.
    func bytes(_ image: CIImage, _ rect: CGRect, premultiplied: Bool, order: (Int, Int, Int, Int) = (0, 1, 2, 3),
               into out: UnsafeMutableRawPointer, rowBytes: Int) {
        let (x0, y0, _, h) = ints(rect)
        let o = out.assumingMemoryBound(to: UInt8.self)
        tiles(image, rect) { t in
            t.px.withUnsafeBufferPointer { p in
                for y in 0..<t.h {
                    // Tile row y (from the bottom) is output row h-1-(t.y+y-y0).
                    let row = h - 1 - (t.y + y - y0)
                    var s = y * t.w * 4
                    var d = row * rowBytes + (t.x - x0) * 4
                    for _ in 0..<t.w {
                        let a = max(0, min(1, p[s + 3]))
                        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0
                        if a > 0 {
                            let k = 1 / a
                            r = Gamma.encode(p[s] * k); g = Gamma.encode(p[s + 1] * k); b = Gamma.encode(p[s + 2] * k)
                            if premultiplied {
                                r = UInt8((Float(r) * a).rounded()); g = UInt8((Float(g) * a).rounded()); b = UInt8((Float(b) * a).rounded())
                            }
                        }
                        let av = UInt8((a * 255).rounded())
                        let v = [r, g, b, av]
                        o[d + order.0] = v[0]; o[d + order.1] = v[1]; o[d + order.2] = v[2]; o[d + order.3] = v[3]
                        s += 4
                        d += 4
                    }
                }
            }
        }
    }

    public func createCGImage(_ image: CIImage, from fromRect: CGRect) -> CGImage? {
        let (_, _, w, h) = ints(fromRect)
        guard w > 0, h > 0, w < 32768, h < 32768 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { bytes(image, fromRect, premultiplied: false, into: $0.baseAddress!, rowBytes: w * 4) }
        return CGImage(width: w, height: h, rgba: px, hasAlpha: true)
    }
    public func createCGImage(_ image: CIImage, from fromRect: CGRect, format: CIFormat, colorSpace: CGColorSpace?) -> CGImage? {
        createCGImage(image, from: fromRect)
    }
    public func createCGImage(_ image: CIImage, from fromRect: CGRect, format: CIFormat, colorSpace: CGColorSpace?, deferred: Bool) -> CGImage? {
        createCGImage(image, from: fromRect)
    }

    public func render(_ image: CIImage, toBitmap data: UnsafeMutableRawPointer, rowBytes: Int, bounds: CGRect, format: CIFormat, colorSpace: CGColorSpace?) {
        let (_, _, w, h) = ints(bounds)
        guard w > 0, h > 0 else { return }
        switch format {
        case .RGBAf, .RGBAh:
            let f = data.assumingMemoryBound(to: Float.self)
            let (x0, y0, _, _) = ints(bounds)
            tiles(image, bounds) { t in
                for y in 0..<t.h {
                    let row = h - 1 - (t.y + y - y0)
                    for x in 0..<t.w {
                        let s = (y * t.w + x) * 4, a = t.px[s + 3]
                        let d = row * (rowBytes / 4) + (t.x - x0 + x) * 4
                        for c in 0..<3 { f[d + c] = a > 0 ? Gamma.srgb(t.px[s + c] / a) * a : 0 }
                        f[d + 3] = a
                    }
                }
            }
        case .BGRA8: bytes(image, bounds, premultiplied: true, order: (2, 1, 0, 3), into: data, rowBytes: rowBytes)
        case .ARGB8: bytes(image, bounds, premultiplied: true, order: (1, 2, 3, 0), into: data, rowBytes: rowBytes)
        case .ABGR8: bytes(image, bounds, premultiplied: true, order: (3, 2, 1, 0), into: data, rowBytes: rowBytes)
        case .A8, .L8, .R8:
            var tmp = [UInt8](repeating: 0, count: w * h * 4)
            tmp.withUnsafeMutableBytes { bytes(image, bounds, premultiplied: true, into: $0.baseAddress!, rowBytes: w * 4) }
            let o = data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<w { o[y * rowBytes + x] = tmp[(y * w + x) * 4 + (format == .A8 ? 3 : 0)] } }
        default: bytes(image, bounds, premultiplied: true, into: data, rowBytes: rowBytes)
        }
    }

    public func render(_ image: CIImage, to buffer: CVPixelBuffer) {
        render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height), colorSpace: nil)
    }

    /// Writes `bounds` of `image` into the buffer, its top row at the buffer's first row.
    public func render(_ image: CIImage, to buffer: CVPixelBuffer, bounds: CGRect, colorSpace: CGColorSpace?) {
        let w = min(Int(bounds.width.rounded()), buffer.width), h = min(Int(bounds.height.rounded()), buffer.height)
        guard w > 0, h > 0 else { return }
        let r = CGRect(x: bounds.minX, y: bounds.minY, width: CGFloat(w), height: CGFloat(h))
        switch buffer.pixelFormatType {
        case kCVPixelFormatType_32BGRA: bytes(image, r, premultiplied: true, order: (2, 1, 0, 3), into: buffer.base, rowBytes: buffer.bytesPerRow)
        case kCVPixelFormatType_32RGBA: bytes(image, r, premultiplied: true, into: buffer.base, rowBytes: buffer.bytesPerRow)
        case kCVPixelFormatType_32ARGB: bytes(image, r, premultiplied: true, order: (1, 2, 3, 0), into: buffer.base, rowBytes: buffer.bytesPerRow)
        default:
            var tmp = [UInt8](repeating: 0, count: w * h * 4)
            tmp.withUnsafeMutableBytes { bytes(image, r, premultiplied: false, into: $0.baseAddress!, rowBytes: w * 4) }
            buffer.write(rgba: tmp, width: w, height: h)
        }
    }

    public func render(_ image: CIImage, to buffer: CVPixelBuffer, bounds: CGRect, colorSpace: CGColorSpace?, completion: (() -> Void)?) {
        render(image, to: buffer, bounds: bounds, colorSpace: colorSpace)
        completion?()
    }

    public func draw(_ image: CIImage, in inRect: CGRect, from fromRect: CGRect) {}

    // Encoded output.
    public func pngRepresentation(of image: CIImage, format: CIFormat, colorSpace: CGColorSpace, options: [CIImageRepresentationOption: Any] = [:]) -> Data? {
        encode(image, type: "public.png", quality: nil)
    }
    public func jpegRepresentation(of image: CIImage, colorSpace: CGColorSpace, options: [CIImageRepresentationOption: Any] = [:]) -> Data? {
        let q = (options[.lossyCompressionQuality] as? Double) ?? (options[.lossyCompressionQuality] as? NSNumber)?.doubleValue
        return encode(image, type: "public.jpeg", quality: q)
    }
    public func writePNGRepresentation(of image: CIImage, to url: URL, format: CIFormat, colorSpace: CGColorSpace, options: [CIImageRepresentationOption: Any] = [:]) throws {
        guard let d = pngRepresentation(of: image, format: format, colorSpace: colorSpace, options: options) else {
            throw NSError(domain: "CIContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "The image couldn't be encoded."])
        }
        try d.write(to: url)
    }
    public func writeJPEGRepresentation(of image: CIImage, to url: URL, colorSpace: CGColorSpace, options: [CIImageRepresentationOption: Any] = [:]) throws {
        guard let d = jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
            throw NSError(domain: "CIContext", code: 1, userInfo: [NSLocalizedDescriptionKey: "The image couldn't be encoded."])
        }
        try d.write(to: url)
    }
    private func encode(_ image: CIImage, type: String, quality: Double?) -> Data? {
        guard !image.extent.isInfinite, let cg = createCGImage(image, from: image.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as NSString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as NSDictionary })
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

public struct CIImageRepresentationOption: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let lossyCompressionQuality = Self(rawValue: "kCGImageDestinationLossyCompressionQuality")
}

/// One row's tiles, filled concurrently (each slot by one worker).
private final class TileRow: @unchecked Sendable {
    private(set) var tiles: [Tile?]
    private let lock = NSLock()
    init(count: Int) { tiles = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ t: Tile) { lock.lock(); tiles[i] = t; lock.unlock() }
}
