// NSBitmapImageRep: pixels in memory, drawn into through a bitmap
// CGContext (`NSGraphicsContext(bitmapImageRep:)`) and encoded with ImageIO;
// and NSView's `cacheDisplay(in:to:)`, which draws a view and its subviews
// (their `draw(_:)` and layer styling) into one.

import Foundation
import CoreGraphics
import ImageIO

open class NSBitmapImageRep: NSImageRep, @unchecked Sendable {
    public enum FileType: UInt, Sendable { case tiff, bmp, gif, jpeg, png, jpeg2000 }
    public struct PropertyKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let compressionFactor = PropertyKey(rawValue: "NSImageCompressionFactor")
        public static let interlaced = PropertyKey(rawValue: "NSImageInterlaced")
        public static let gamma = PropertyKey(rawValue: "NSImageGamma")
    }

    /// The context drawing goes to (premultiplied RGBA, 8 bits).
    let context: CGContext
    open var size: NSSize
    open var pixelsWide: Int { context.width }
    open var pixelsHigh: Int { context.height }
    open var bitsPerSample: Int { 8 }
    open var samplesPerPixel: Int { 4 }
    open var hasAlpha: Bool { true }
    open var bytesPerRow: Int { context.bytesPerRow }
    open var bitmapData: UnsafeMutablePointer<UInt8>? { context.data?.assumingMemoryBound(to: UInt8.self) }

    init?(pixelsWide w: Int, pixelsHigh h: Int, size: NSSize) {
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context = ctx
        self.size = size
        super.init()
    }
    public convenience init?(bitmapDataPlanes planes: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?, pixelsWide width: Int, pixelsHigh height: Int,
                             bitsPerSample bps: Int, samplesPerPixel spp: Int, hasAlpha alpha: Bool, isPlanar: Bool,
                             colorSpaceName: NSColorSpaceName, bytesPerRow rBytes: Int, bitsPerPixel pBits: Int) {
        self.init(pixelsWide: width, pixelsHigh: height, size: NSSize(width: width, height: height))
    }
    public convenience init(cgImage: CGImage) {
        self.init(pixelsWide: max(1, cgImage.width), pixelsHigh: max(1, cgImage.height), size: NSSize(width: cgImage.width, height: cgImage.height))!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    }
    /// Decodes PNG, JPEG, GIF, TIFF… (ImageIO).
    public convenience init?(data: Data) {
        guard let src = CGImageSourceCreateWithData(data as NSData, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        self.init(cgImage: img)
    }
    public static func imageReps(with data: Data) -> [NSImageRep] { NSBitmapImageRep(data: data).map { [$0] } ?? [] }

    open var cgImage: CGImage? { context.makeImage() }

    /// The pixels encoded as `fileType`.
    open func representation(using fileType: FileType, properties: [PropertyKey: Any]) -> Data? {
        guard let img = cgImage else { return nil }
        let uti: String = switch fileType {
        case .png: "public.png"
        case .jpeg, .jpeg2000: "public.jpeg"
        case .tiff: "public.tiff"
        case .gif: "com.compuserve.gif"
        case .bmp: "com.microsoft.bmp"
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti as NSString, 1, nil) else { return nil }
        var opts: [String: Any] = [:]
        if let q = properties[.compressionFactor] { opts["kCGImageDestinationLossyCompressionQuality"] = q }
        CGImageDestinationAddImage(dest, img, opts.isEmpty ? nil : opts as NSDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
    open var tiffRepresentation: Data? { representation(using: .tiff, properties: [:]) }
    public static func representationOfImageReps(in reps: [NSImageRep], using type: FileType, properties: [PropertyKey: Any]) -> Data? {
        (reps.first as? NSBitmapImageRep)?.representation(using: type, properties: properties)
    }

    /// Draws the pixels into the current graphics context.
    @discardableResult
    @preconcurrency @MainActor open func draw(in rect: NSRect) -> Bool {
        guard let img = cgImage, let gc = NSGraphicsContext.current else { return false }
        gc.cgContext.draw(img, in: rect)
        return true
    }
    @discardableResult
    @preconcurrency @MainActor open func draw() -> Bool { draw(in: NSRect(origin: .zero, size: size)) }
}

public typealias NSColorSpaceName = String
extension NSColorSpaceName {
    public static let deviceRGB = "NSDeviceRGBColorSpace", calibratedRGB = "NSCalibratedRGBColorSpace"
}

extension NSGraphicsContext {
    /// A context that draws into the rep's pixels (y up, as AppKit's is).
    public convenience init(bitmapImageRep rep: NSBitmapImageRep) {
        let ctx = rep.context
        ctx.resetClip()
        self.init(cgContext: ctx, flipped: false)
    }
}

extension NSImage {
    /// An image of the rep's pixels.
    public convenience init(bitmapRep rep: NSBitmapImageRep) {
        if let img = rep.cgImage { self.init(cgImage: img, size: rep.size) } else { self.init(size: rep.size) }
    }
}

extension NSView {
    /// A bitmap sized for caching the view's drawing of `rect`.
    public func bitmapImageRepForCachingDisplay(in rect: NSRect) -> NSBitmapImageRep? {
        let scale = window?.backingScaleFactor ?? 1
        return NSBitmapImageRep(pixelsWide: Int((rect.width * scale).rounded(.up)), pixelsHigh: Int((rect.height * scale).rounded(.up)), size: rect.size)
    }

    /// Draws `rect` of the view, with its subviews, into `rep`: each view's
    /// layer styling and `draw(_:)` (native controls draw themselves on
    /// screen and aren't included).
    public func cacheDisplay(in rect: NSRect, to rep: NSBitmapImageRep) {
        let ctx = rep.context
        let scaleX = CGFloat(rep.pixelsWide) / max(1, rect.width), scaleY = CGFloat(rep.pixelsHigh) / max(1, rect.height)
        func paint(_ v: NSView) {
            guard !v.isHidden else { return }
            // The view's bounds in this view's coordinates, then its
            // top-left corner relative to `rect`'s top-left.
            let r = v === self ? v.bounds : v.convert(v.bounds, to: self)
            let top = isFlipped ? r.minY - rect.minY : rect.maxY - r.maxY
            let left = r.minX - rect.minX
            ctx.saveGState()
            // Into user space with y down from the view's top-left, the
            // space its recorded drawing uses.
            ctx.translateBy(x: left * scaleX, y: CGFloat(rep.pixelsHigh) - top * scaleY)
            ctx.scaleBy(x: scaleX, y: -scaleY)
            ctx.draw(v.recordDrawing())
            ctx.restoreGState()
            v.subviews.forEach(paint)
        }
        paint(self)
    }
}

extension NSImage {
    /// The image's bitmap representation (its decoded pixels).
    public var representations: [NSImageRep] {
        guard let img = decoded else { return [] }
        let rep = NSBitmapImageRep(cgImage: img)
        rep.size = size
        return [rep]
    }
    /// The types an image can be read from (ImageIO's decoders).
    public static var imageTypes: [String] {
        ["public.png", "public.jpeg", "public.tiff", "com.compuserve.gif", "public.heic", "org.webmproject.webp", "com.microsoft.bmp"]
    }
    public static var imageUnfilteredTypes: [String] { imageTypes }

    /// Whether the pasteboard holds an image (or an image file).
    @preconcurrency @MainActor public static func canInit(with pasteboard: NSPasteboard) -> Bool {
        if let types = pasteboard.types, types.contains(where: { [.png, .tiff].contains($0) || imageTypes.contains($0.rawValue) }) { return true }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.contains { ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp", "bmp"].contains($0.pathExtension.lowercased()) }
    }
    /// The pasteboard's image: its image data, else an image file on it.
    @preconcurrency @MainActor public convenience init?(pasteboard: NSPasteboard) {
        for t in [NSPasteboard.PasteboardType.png, .tiff] {
            if let d = pasteboard.data(forType: t), NSImage(data: d) != nil { self.init(data: d); return }
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard let url = urls.first(where: { NSImage(contentsOf: $0) != nil }) else { return nil }
        self.init(contentsOf: url)
    }
}
