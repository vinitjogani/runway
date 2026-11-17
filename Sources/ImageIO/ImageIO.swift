// ImageIO for Linux: image sources and destinations over GdkPixbuf (its
// loaders read PNG, JPEG, GIF, WebP, TIFF, BMP, ICO… with EXIF orientation),
// decoding into CoreGraphics' RGBA8 CGImage. On Windows the same API is a
// stub that reads nothing (WIC is the native route; not implemented yet).

@_exported import CoreGraphics
import Foundation
import RunwayFoundation
import UniformTypeIdentifiers
#if os(Linux)
import CGdkPixbuf
#endif

// MARK: Keys

public let kCGImageSourceCreateThumbnailFromImageAlways: CFString = "kCGImageSourceCreateThumbnailFromImageAlways"
public let kCGImageSourceCreateThumbnailFromImageIfAbsent: CFString = "kCGImageSourceCreateThumbnailFromImageIfAbsent"
public let kCGImageSourceCreateThumbnailWithTransform: CFString = "kCGImageSourceCreateThumbnailWithTransform"
public let kCGImageSourceThumbnailMaxPixelSize: CFString = "kCGImageSourceThumbnailMaxPixelSize"
public let kCGImageSourceShouldAllowFloat: CFString = "kCGImageSourceShouldAllowFloat"
public let kCGImageSourceShouldCache: CFString = "kCGImageSourceShouldCache"
public let kCGImageSourceShouldCacheImmediately: CFString = "kCGImageSourceShouldCacheImmediately"
public let kCGImageSourceTypeIdentifierHint: CFString = "kCGImageSourceTypeIdentifierHint"
public let kCGImageDestinationLossyCompressionQuality: CFString = "kCGImageDestinationLossyCompressionQuality"
public let kCGImagePropertyPixelWidth: CFString = "PixelWidth"
public let kCGImagePropertyPixelHeight: CFString = "PixelHeight"
public let kCGImagePropertyOrientation: CFString = "Orientation"
public let kCGImagePropertyHasAlpha: CFString = "HasAlpha"
public let kCGImagePropertyDPIWidth: CFString = "DPIWidth"
public let kCGImagePropertyDPIHeight: CFString = "DPIHeight"

/// Reads an option whether the dictionary bridged its keys to String or not.
func option(_ options: CFDictionary?, _ key: CFString) -> Any? {
    guard let options else { return nil }
    return options.object(forKey: key) ?? options.object(forKey: key as String)
}

/// EXIF orientations (1…8), as ImageIO names them.
public enum CGImagePropertyOrientation: UInt32, Sendable {
    case up = 1, upMirrored, down, downMirrored, leftMirrored, right, rightMirrored, left
}

// MARK: Sources

public final class CGImageSource: @unchecked Sendable {
    let data: Data
    /// Decoded once: RGBA8, upright when `transformed` (EXIF applied).
    private var cache: [Bool: CGImage] = [:]
    let typeIdentifier: String?
    init(data: Data) {
        self.data = data
        typeIdentifier = CGImageSource.sniff(data)
    }

    static func sniff(_ d: Data) -> String? {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return UTType.png.identifier }
        if b.starts(with: [0xff, 0xd8, 0xff]) { return UTType.jpeg.identifier }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return UTType.gif.identifier }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return UTType.webP.identifier }
        if b.starts(with: [0x49, 0x49, 0x2a, 0x00]) || b.starts(with: [0x4d, 0x4d, 0x00, 0x2a]) { return UTType.tiff.identifier }
        if b.starts(with: [0x42, 0x4d]) { return UTType.bmp.identifier }
        return nil
    }

    func image(transformed: Bool) -> CGImage? {
        if let c = cache[transformed] { return c }
        let img = Codec.decode(data, applyOrientation: transformed)
        cache[transformed] = img
        return img
    }
}

public func CGImageSourceCreateWithData(_ data: CFData, _ options: CFDictionary?) -> CGImageSource? {
    let d = Data(referencing: data)
    guard !d.isEmpty else { return nil }
    return CGImageSource(data: d)
}

public func CGImageSourceCreateWithURL(_ url: CFURL, _ options: CFDictionary?) -> CGImageSource? {
    guard let d = try? Data(contentsOf: url as URL) else { return nil }
    return CGImageSource(data: d)
}

public func CGImageSourceGetCount(_ source: CGImageSource) -> Int { source.image(transformed: false) == nil ? 0 : 1 }

public func CGImageSourceGetType(_ source: CGImageSource) -> CFString? { source.typeIdentifier.map { $0 as NSString } }

public func CGImageSourceCreateImageAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    index == 0 ? source.image(transformed: false) : nil
}

public func CGImageSourceCreateThumbnailAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CGImage? {
    guard index == 0 else { return nil }
    let transform = (option(options, kCGImageSourceCreateThumbnailWithTransform) as? Bool) ?? false
    guard let image = source.image(transformed: transform) else { return nil }
    let maxEdge = (option(options, kCGImageSourceThumbnailMaxPixelSize) as? NSNumber)?.intValue
        ?? (option(options, kCGImageSourceThumbnailMaxPixelSize) as? Int)
    guard let maxEdge, max(image.width, image.height) > maxEdge else { return image }
    let scale = Double(maxEdge) / Double(max(image.width, image.height))
    let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(),
                              bitmapInfo: (image.hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

public func CGImageSourceCopyPropertiesAtIndex(_ source: CGImageSource, _ index: Int, _ options: CFDictionary?) -> CFDictionary? {
    guard let image = source.image(transformed: false) else { return nil }
    let d = NSMutableDictionary()
    d[kCGImagePropertyPixelWidth] = NSNumber(value: image.width)
    d[kCGImagePropertyPixelHeight] = NSNumber(value: image.height)
    d[kCGImagePropertyHasAlpha] = NSNumber(value: image.hasAlpha)
    d[kCGImagePropertyOrientation] = NSNumber(value: Codec.orientation(source.data))
    return d
}

// MARK: Destinations

public final class CGImageDestination: @unchecked Sendable {
    let out: NSMutableData
    let type: String
    /// Each image, its lossy quality and its EXIF orientation (1…8).
    var images: [(CGImage, Double?, Int)] = []
    init(out: NSMutableData, type: String) { self.out = out; self.type = type }
}

public func CGImageDestinationCreateWithData(_ data: CFMutableData, _ type: CFString, _ count: Int, _ options: CFDictionary?) -> CGImageDestination? {
    let t = type as String
    guard t == UTType.png.identifier || t == UTType.jpeg.identifier || t == UTType.tiff.identifier || t == UTType.bmp.identifier || t == UTType.ico.identifier else { return nil }
    return CGImageDestination(out: data, type: t)
}

public func CGImageDestinationCreateWithURL(_ url: CFURL, _ type: CFString, _ count: Int, _ options: CFDictionary?) -> CGImageDestination? {
    let d = CGImageDestinationCreateWithData(NSMutableData(), type, count, options)
    d?.fileURL = url as URL
    return d
}

extension CGImageDestination {
    private static var urls: [ObjectIdentifier: URL] = [:]
    var fileURL: URL? {
        get { Self.urls[ObjectIdentifier(self)] }
        set { Self.urls[ObjectIdentifier(self)] = newValue }
    }
}

public func CGImageDestinationAddImage(_ dest: CGImageDestination, _ image: CGImage, _ properties: CFDictionary?) {
    let q = (option(properties, kCGImageDestinationLossyCompressionQuality) as? NSNumber)?.doubleValue
        ?? (option(properties, kCGImageDestinationLossyCompressionQuality) as? Double)
    let o = (option(properties, kCGImagePropertyOrientation) as? NSNumber)?.intValue
        ?? (option(properties, kCGImagePropertyOrientation) as? Int) ?? 1
    dest.images.append((image, q, max(1, min(8, o))))
}

public func CGImageDestinationFinalize(_ dest: CGImageDestination) -> Bool {
    guard let (image, quality, orientation) = dest.images.first,
          let data = Codec.encode(image, type: dest.type, quality: quality).map({ Codec.tagged($0, orientation: orientation) })
    else { return false }
    dest.out.setData(data)
    if let url = dest.fileURL { return (try? data.write(to: url)) != nil }
    return true
}

public func CGImageDestinationCopyTypeIdentifiers() -> CFArray {
    [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier, UTType.bmp.identifier] as NSArray
}

public func CGImageSourceCopyTypeIdentifiers() -> CFArray {
    [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier, UTType.webP.identifier, UTType.tiff.identifier, UTType.bmp.identifier] as NSArray
}

// MARK: Codec

enum Codec {
    /// The EXIF orientation (1…8) of JPEG or PNG (eXIf) data, else 1.
    static func orientation(_ d: Data) -> Int {
        if let exif = pngChunk(d, "eXIf") { return tiffOrientation(exif, at: 0) }
        let b = [UInt8](d.prefix(64 * 1024))
        guard b.count > 4, b[0] == 0xff, b[1] == 0xd8 else { return 1 }
        var i = 2
        while i + 4 < b.count, b[i] == 0xff {
            let marker = b[i + 1], len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if marker == 0xe1, i + 10 < b.count, b[(i + 4)..<(i + 8)] == [0x45, 0x78, 0x69, 0x66] {
                let t = i + 10
                guard t + 8 < b.count else { return 1 }
                let le = b[t] == 0x49
                func u16(_ o: Int) -> Int { o + 1 < b.count ? (le ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])) : 0 }
                func u32(_ o: Int) -> Int { (le ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2)) }
                let ifd = t + u32(t + 4)
                let n = u16(ifd)
                for e in 0..<n {
                    let entry = ifd + 2 + e * 12
                    if u16(entry) == 0x0112 { return max(1, min(8, u16(entry + 8))) }
                }
                return 1
            }
            i += 2 + len
        }
        return 1
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// A PNG chunk's data, by type (before the image data).
    static func pngChunk(_ d: Data, _ type: String) -> [UInt8]? {
        let b = [UInt8](d.prefix(256 * 1024))
        guard b.count > 8, Array(b[0..<8]) == pngSignature else { return nil }
        var i = 8
        while i + 8 <= b.count {
            let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            let name = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            if name == type { return i + 8 + len <= b.count ? Array(b[(i + 8)..<(i + 8 + len)]) : nil }
            if name == "IDAT" || name == "IEND" { return nil }
            i += 12 + len
        }
        return nil
    }

    /// The orientation tag (0x0112) of TIFF/EXIF data starting at `t`, else 1.
    static func tiffOrientation(_ b: [UInt8], at t: Int) -> Int {
        guard t + 8 < b.count else { return 1 }
        let le = b[t] == 0x49
        func u16(_ o: Int) -> Int { o + 1 < b.count ? (le ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])) : 0 }
        func u32(_ o: Int) -> Int { (le ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2)) }
        let ifd = t + u32(t + 4)
        for e in 0..<min(u16(ifd), 512) {
            let entry = ifd + 2 + e * 12
            if u16(entry) == 0x0112 { return max(1, min(8, u16(entry + 8))) }
        }
        return 1
    }

    /// Minimal big-endian EXIF (TIFF) holding only the orientation.
    static func exif(orientation o: Int) -> [UInt8] {
        [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // header, IFD at 8
         0x00, 0x01, // one entry
         0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, UInt8(o >> 8), UInt8(o & 0xff), 0x00, 0x00, // Orientation, SHORT, 1
         0x00, 0x00, 0x00, 0x00] // no next IFD
    }

    /// Encoded PNG or JPEG data carrying an EXIF orientation (as ImageIO
    /// writes kCGImagePropertyOrientation): an eXIf chunk, an APP1 segment.
    static func tagged(_ d: Data, orientation o: Int) -> Data {
        guard o != 1 else { return d }
        var b = [UInt8](d)
        let tiff = exif(orientation: o)
        if b.count > 33, Array(b[0..<8]) == pngSignature {
            // After IHDR (8 + 4 + 4 + 13 + 4 bytes).
            let body = Array("eXIf".utf8) + tiff
            var chunk = [UInt8(tiff.count >> 24 & 0xff), UInt8(tiff.count >> 16 & 0xff), UInt8(tiff.count >> 8 & 0xff), UInt8(tiff.count & 0xff)] + body
            let c = crc32(body)
            chunk += [UInt8(c >> 24 & 0xff), UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff)]
            b.insert(contentsOf: chunk, at: 33)
        } else if b.count > 2, b[0] == 0xff, b[1] == 0xd8 {
            let payload = Array("Exif".utf8) + [0, 0] + tiff
            let len = payload.count + 2
            b.insert(contentsOf: [0xff, 0xe1, UInt8(len >> 8), UInt8(len & 0xff)] + payload, at: 2)
        }
        return Data(b)
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for x in bytes { c = crcTable[Int((c ^ UInt32(x)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    /// `image` turned upright for EXIF orientation `o`.
    static func upright(_ image: CGImage, _ o: Int) -> CGImage {
        guard o > 1, o <= 8 else { return image }
        let w = image.width, h = image.height
        let swap = o >= 5
        let ow = swap ? h : w, oh = swap ? w : h
        let src = image.pixels
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        for sy in 0..<h {
            for sx in 0..<w {
                let (dx, dy): (Int, Int) = switch o {
                case 2: (w - 1 - sx, sy)
                case 3: (w - 1 - sx, h - 1 - sy)
                case 4: (sx, h - 1 - sy)
                case 5: (sy, sx)
                case 6: (h - 1 - sy, sx)
                case 7: (h - 1 - sy, w - 1 - sx)
                default: (sy, w - 1 - sx) // 8
                }
                let s = (sy * w + sx) * 4, d = (dy * ow + dx) * 4
                out[d] = src[s]; out[d + 1] = src[s + 1]; out[d + 2] = src[s + 2]; out[d + 3] = src[s + 3]
            }
        }
        return CGImage(width: ow, height: oh, rgba: out, hasAlpha: image.hasAlpha)
    }

    #if os(Linux)
    static func decode(_ data: Data, applyOrientation: Bool) -> CGImage? {
        guard let loader = gdk_pixbuf_loader_new() else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(loader)) }
        let ok = data.withUnsafeBytes { buf -> Bool in
            gdk_pixbuf_loader_write(loader, buf.bindMemory(to: guchar.self).baseAddress, gsize(buf.count), nil) != 0
        }
        _ = gdk_pixbuf_loader_close(loader, nil)
        guard ok, var pixbuf = gdk_pixbuf_loader_get_pixbuf(loader) else { return nil }
        g_object_ref(UnsafeMutableRawPointer(pixbuf))
        // GdkPixbuf's loaders tag JPEG and TIFF orientation; PNG's eXIf is read here.
        var manual = 1
        if applyOrientation {
            if gdk_pixbuf_get_option(pixbuf, "orientation") == nil { manual = orientation(data) }
            if let upright = gdk_pixbuf_apply_embedded_orientation(pixbuf) {
                g_object_unref(UnsafeMutableRawPointer(pixbuf))
                pixbuf = upright
            }
        }
        defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }
        let w = Int(gdk_pixbuf_get_width(pixbuf)), h = Int(gdk_pixbuf_get_height(pixbuf))
        let stride = Int(gdk_pixbuf_get_rowstride(pixbuf)), channels = Int(gdk_pixbuf_get_n_channels(pixbuf))
        let alpha = gdk_pixbuf_get_has_alpha(pixbuf) != 0
        guard let src = gdk_pixbuf_read_pixels(pixbuf), w > 0, h > 0 else { return nil }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = y * stride + x * channels, d = (y * w + x) * 4
                out[d] = src[s]; out[d + 1] = src[s + 1]; out[d + 2] = src[s + 2]
                if alpha { out[d + 3] = src[s + 3] }
            }
        }
        return upright(CGImage(width: w, height: h, rgba: out, hasAlpha: alpha), manual)
    }

    static func encode(_ image: CGImage, type: String, quality: Double?) -> Data? {
        let format: String
        switch type {
        case UTType.png.identifier: format = "png"
        case UTType.jpeg.identifier: format = "jpeg"
        case UTType.tiff.identifier: format = "tiff"
        case UTType.bmp.identifier: format = "bmp"
        case UTType.ico.identifier: format = "ico"
        default: return nil
        }
        let alpha = image.hasAlpha && format != "jpeg"
        let channels = alpha ? 4 : 3
        var px = [UInt8](repeating: 0, count: image.width * image.height * channels)
        for i in 0..<(image.width * image.height) {
            px[i * channels] = image.pixels[i * 4]
            px[i * channels + 1] = image.pixels[i * 4 + 1]
            px[i * channels + 2] = image.pixels[i * 4 + 2]
            if alpha { px[i * channels + 3] = image.pixels[i * 4 + 3] }
        }
        return px.withUnsafeMutableBufferPointer { buf -> Data? in
            guard let pixbuf = gdk_pixbuf_new_from_data(buf.baseAddress, GDK_COLORSPACE_RGB, alpha ? 1 : 0, 8,
                                                        Int32(image.width), Int32(image.height), Int32(image.width * channels), nil, nil) else { return nil }
            defer { g_object_unref(UnsafeMutableRawPointer(pixbuf)) }
            var keys: [UnsafeMutablePointer<CChar>?] = []
            var values: [UnsafeMutablePointer<CChar>?] = []
            if format == "jpeg" {
                keys.append(strdup("quality"))
                values.append(strdup(String(Int(((quality ?? 0.9) * 100).rounded()).clamped(1, 100))))
            } else if format == "png" {
                keys.append(strdup("compression"))
                values.append(strdup("9"))
            }
            keys.append(nil); values.append(nil)
            defer { keys.forEach { free($0) }; values.forEach { free($0) } }
            var buffer: UnsafeMutablePointer<gchar>?
            var size: gsize = 0
            let ok = gdk_pixbuf_save_to_bufferv(pixbuf, &buffer, &size, format, &keys, &values, nil)
            guard ok != 0, let buffer else { return nil }
            defer { g_free(buffer) }
            return Data(bytes: buffer, count: Int(size))
        }
    }
    #else
    static func decode(_ data: Data, applyOrientation: Bool) -> CGImage? { nil }
    static func encode(_ image: CGImage, type: String, quality: Double?) -> Data? { nil }
    #endif
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(hi, Swift.max(lo, self)) }
}
