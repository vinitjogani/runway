// CoreVideo for Linux and Windows: CVPixelBuffer backed by ordinary memory
// (packed or bi-planar), lock/unlock, planes, the pixel formats apps name,
// attachments, pools, and CVDisplayLink as a frame clock (a thread that
// ticks only while the link runs).
//
// Also home to the MacTypes names media code compares against (OSType,
// FourCharCode, OSStatus results like noErr), so every media framework
// shares one definition.

@_exported import CoreGraphics
@_exported import Foundation
@_exported import RunwayFoundation

// MARK: MacTypes

public typealias OSType = UInt32
public typealias FourCharCode = UInt32
public typealias Boolean = UInt8

/// Foundation's autorelease pool (missing from swift-corelibs-foundation):
/// there's nothing to drain without Objective-C, so it just runs `body`.
/// Media code wraps per-frame work in it.
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result { try body() }

extension FourCharCode {
    /// 'BGRA' and friends.
    @inlinable public init(fourCC s: StaticString) {
        var v: UInt32 = 0
        s.withUTF8Buffer { for b in $0.prefix(4) { v = v << 8 | UInt32(b) } }
        self = v
    }
}

// MARK: Results

public typealias CVReturn = Int32
public let kCVReturnSuccess: CVReturn = 0
public let kCVReturnFirst: CVReturn = -6660
public let kCVReturnError: CVReturn = -6660
public let kCVReturnInvalidArgument: CVReturn = -6661
public let kCVReturnAllocationFailed: CVReturn = -6662
public let kCVReturnUnsupported: CVReturn = -6663
public let kCVReturnInvalidDisplay: CVReturn = -6670
public let kCVReturnDisplayLinkAlreadyRunning: CVReturn = -6671
public let kCVReturnDisplayLinkNotRunning: CVReturn = -6672
public let kCVReturnDisplayLinkCallbacksNotSet: CVReturn = -6673
public let kCVReturnInvalidPixelFormat: CVReturn = -6680
public let kCVReturnInvalidSize: CVReturn = -6681
public let kCVReturnInvalidPixelBufferAttributes: CVReturn = -6682
public let kCVReturnPixelBufferNotOpenGLCompatible: CVReturn = -6683
public let kCVReturnPixelBufferNotMetalCompatible: CVReturn = -6684
public let kCVReturnWouldExceedAllocationThreshold: CVReturn = -6689
public let kCVReturnPoolAllocationFailed: CVReturn = -6690
public let kCVReturnInvalidPoolAttributes: CVReturn = -6691
public let kCVReturnRetry: CVReturn = -6692

// MARK: Pixel formats

public let kCVPixelFormatType_1Monochrome: OSType = 0x01
public let kCVPixelFormatType_16BE555: OSType = 0x10
public let kCVPixelFormatType_24RGB: OSType = 0x18
public let kCVPixelFormatType_32ARGB: OSType = 0x20
public let kCVPixelFormatType_32BGRA = OSType(fourCC: "BGRA")
public let kCVPixelFormatType_32ABGR = OSType(fourCC: "ABGR")
public let kCVPixelFormatType_32RGBA = OSType(fourCC: "RGBA")
public let kCVPixelFormatType_24BGR = OSType(fourCC: "24BG")
public let kCVPixelFormatType_OneComponent8 = OSType(fourCC: "L008")
public let kCVPixelFormatType_OneComponent16Half = OSType(fourCC: "L00h")
public let kCVPixelFormatType_OneComponent32Float = OSType(fourCC: "L00f")
public let kCVPixelFormatType_TwoComponent8 = OSType(fourCC: "2C08")
public let kCVPixelFormatType_64RGBAHalf = OSType(fourCC: "RGhA")
public let kCVPixelFormatType_128RGBAFloat = OSType(fourCC: "RGfA")
public let kCVPixelFormatType_64ARGB = OSType(fourCC: "b64a")
public let kCVPixelFormatType_30RGB = OSType(fourCC: "R10k")
public let kCVPixelFormatType_422YpCbCr8 = OSType(fourCC: "2vuy")
public let kCVPixelFormatType_422YpCbCr8_yuvs = OSType(fourCC: "yuvs")
public let kCVPixelFormatType_420YpCbCr8Planar = OSType(fourCC: "y420")
public let kCVPixelFormatType_420YpCbCr8PlanarFullRange = OSType(fourCC: "f420")
public let kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange = OSType(fourCC: "420v")
public let kCVPixelFormatType_420YpCbCr8BiPlanarFullRange = OSType(fourCC: "420f")
public let kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange = OSType(fourCC: "x420")
public let kCVPixelFormatType_420YpCbCr10BiPlanarFullRange = OSType(fourCC: "xf20")
public let kCVPixelFormatType_ARGB2101010LEPacked = OSType(fourCC: "l10r")

/// How a format lays out in memory.
public struct CVPixelFormatLayout: Sendable, Equatable {
    /// Per plane: bytes per pixel (for chroma planes: per sample pair) and the
    /// plane's size relative to the image (1 or 2 = half).
    public var planes: [(bytesPerPixel: Int, xDiv: Int, yDiv: Int)]
    public static func == (a: Self, b: Self) -> Bool {
        a.planes.count == b.planes.count && zip(a.planes, b.planes).allSatisfy { $0 == $1 }
    }

    public static func of(_ format: OSType) -> CVPixelFormatLayout? {
        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_32ABGR, kCVPixelFormatType_32RGBA,
             kCVPixelFormatType_30RGB, kCVPixelFormatType_ARGB2101010LEPacked:
            return .init(planes: [(4, 1, 1)])
        case kCVPixelFormatType_24RGB, kCVPixelFormatType_24BGR: return .init(planes: [(3, 1, 1)])
        case kCVPixelFormatType_OneComponent8: return .init(planes: [(1, 1, 1)])
        case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_TwoComponent8: return .init(planes: [(2, 1, 1)])
        case kCVPixelFormatType_OneComponent32Float: return .init(planes: [(4, 1, 1)])
        case kCVPixelFormatType_64RGBAHalf, kCVPixelFormatType_64ARGB: return .init(planes: [(8, 1, 1)])
        case kCVPixelFormatType_128RGBAFloat: return .init(planes: [(16, 1, 1)])
        case kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs: return .init(planes: [(2, 1, 1)])
        case kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            return .init(planes: [(1, 1, 1), (1, 2, 2), (1, 2, 2)])
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return .init(planes: [(1, 1, 1), (2, 2, 2)])
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return .init(planes: [(2, 1, 1), (4, 2, 2)])
        default: return nil
        }
    }
}

// MARK: Keys

public let kCVPixelBufferPixelFormatTypeKey: CFString = "PixelFormatType"
public let kCVPixelBufferWidthKey: CFString = "Width"
public let kCVPixelBufferHeightKey: CFString = "Height"
public let kCVPixelBufferBytesPerRowAlignmentKey: CFString = "BytesPerRowAlignment"
public let kCVPixelBufferExtendedPixelsLeftKey: CFString = "ExtendedPixelsLeft"
public let kCVPixelBufferIOSurfacePropertiesKey: CFString = "IOSurfaceProperties"
public let kCVPixelBufferMetalCompatibilityKey: CFString = "MetalCompatibility"
public let kCVPixelBufferOpenGLCompatibilityKey: CFString = "OpenGLCompatibility"
public let kCVPixelBufferCGImageCompatibilityKey: CFString = "CGImageCompatibility"
public let kCVPixelBufferCGBitmapContextCompatibilityKey: CFString = "CGBitmapContextCompatibility"
public let kCVPixelBufferPoolMinimumBufferCountKey: CFString = "MinimumBufferCount"
public let kCVPixelBufferPoolMaximumBufferAgeKey: CFString = "MaximumBufferAge"
public let kCVImageBufferColorPrimariesKey: CFString = "CVImageBufferColorPrimaries"
public let kCVImageBufferTransferFunctionKey: CFString = "CVImageBufferTransferFunction"
public let kCVImageBufferYCbCrMatrixKey: CFString = "CVImageBufferYCbCrMatrix"
public let kCVImageBufferColorPrimaries_ITU_R_709_2: CFString = "ITU_R_709_2"
public let kCVImageBufferTransferFunction_ITU_R_709_2: CFString = "ITU_R_709_2"
public let kCVImageBufferYCbCrMatrix_ITU_R_709_2: CFString = "ITU_R_709_2"
public let kCVImageBufferYCbCrMatrix_ITU_R_601_4: CFString = "ITU_R_601_4"
public let kCVImageBufferColorPrimaries_P3_D65: CFString = "P3_D65"
public let kCVImageBufferTransferFunction_sRGB: CFString = "IEC_sRGB"

public enum CVAttachmentMode: UInt32, Sendable { case shouldNotPropagate = 0, shouldPropagate = 1 }

// MARK: Pixel buffers

public struct CVPixelBufferLockFlags: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let readOnly = CVPixelBufferLockFlags(rawValue: 1)
}

/// CVBuffer, CVImageBuffer and CVPixelBuffer are one type, as on Apple
/// platforms (where they're the same CF type): pixel buffers are the only
/// buffers here.
public typealias CVImageBuffer = CVBuffer
public typealias CVPixelBuffer = CVBuffer

/// Pixels in memory, one allocation, planes laid out back to back with
/// 64-byte-aligned rows. Lock/unlock count but never move the memory.
public final class CVBuffer: @unchecked Sendable {
    fileprivate var attachments: [String: (Any, CVAttachmentMode)] = [:]
    fileprivate let attachmentLock = NSLock()
    public let width: Int
    public let height: Int
    public let pixelFormatType: OSType
    public let planeCount: Int
    let planeOffsets: [Int]
    let planeRows: [Int]
    let planeWidths: [Int]
    let planeHeights: [Int]
    public let dataSize: Int
    public let base: UnsafeMutableRawPointer
    private let owned: Bool
    private let release: (() -> Void)?
    private let lock = NSLock()
    public private(set) var lockCount = 0

    /// Memory for `width × height` of `format`; nil for formats with no known layout.
    public init?(width: Int, height: Int, pixelFormat: OSType, alignment: Int = 64) {
        guard width > 0, height > 0, let layout = CVPixelFormatLayout.of(pixelFormat) else { return nil }
        var offsets: [Int] = [], rows: [Int] = [], ws: [Int] = [], hs: [Int] = []
        var size = 0
        for p in layout.planes {
            let w = (width + p.xDiv - 1) / p.xDiv, h = (height + p.yDiv - 1) / p.yDiv
            let row = (w * p.bytesPerPixel + alignment - 1) / alignment * alignment
            offsets.append(size); rows.append(row); ws.append(w); hs.append(h)
            size += row * h
        }
        guard size < Int(Int32.max) else { return nil }
        self.width = width
        self.height = height
        pixelFormatType = pixelFormat
        planeCount = layout.planes.count == 1 ? 0 : layout.planes.count
        planeOffsets = offsets; planeRows = rows; planeWidths = ws; planeHeights = hs
        dataSize = size
        base = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 64)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        owned = true
        release = nil
    }

    /// Wraps caller memory (packed, one plane).
    public init(width: Int, height: Int, pixelFormat: OSType, bytes: UnsafeMutableRawPointer, bytesPerRow: Int, release: (() -> Void)?) {
        self.width = width
        self.height = height
        pixelFormatType = pixelFormat
        planeCount = 0
        planeOffsets = [0]; planeRows = [bytesPerRow]; planeWidths = [width]; planeHeights = [height]
        dataSize = bytesPerRow * height
        base = bytes
        owned = false
        self.release = release
    }

    deinit {
        if owned { base.deallocate() }
        release?()
    }

    public var isPlanar: Bool { planeCount > 0 }
    public var bytesPerRow: Int { planeRows[0] }
    public func bytesPerRow(ofPlane i: Int) -> Int { i < planeRows.count ? planeRows[i] : 0 }
    public func width(ofPlane i: Int) -> Int { i < planeWidths.count ? planeWidths[i] : 0 }
    public func height(ofPlane i: Int) -> Int { i < planeHeights.count ? planeHeights[i] : 0 }
    public func baseAddress(ofPlane i: Int) -> UnsafeMutableRawPointer? { i < planeOffsets.count ? base + planeOffsets[i] : nil }

    func lockBase() { lock.lock(); lockCount += 1; lock.unlock() }
    func unlockBase() { lock.lock(); lockCount = max(lockCount - 1, 0); lock.unlock() }
}

public func CVPixelBufferCreate(_ allocator: CFAllocator?, _ width: Int, _ height: Int, _ pixelFormatType: OSType,
                                _ pixelBufferAttributes: CFDictionary?, _ pixelBufferOut: UnsafeMutablePointer<CVPixelBuffer?>) -> CVReturn {
    guard width > 0, height > 0 else { pixelBufferOut.pointee = nil; return kCVReturnInvalidSize }
    guard let pb = CVPixelBuffer(width: width, height: height, pixelFormat: pixelFormatType) else {
        pixelBufferOut.pointee = nil
        return kCVReturnInvalidPixelFormat
    }
    pixelBufferOut.pointee = pb
    return kCVReturnSuccess
}

public typealias CVPixelBufferReleaseBytesCallback = (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void

public func CVPixelBufferCreateWithBytes(_ allocator: CFAllocator?, _ width: Int, _ height: Int, _ pixelFormatType: OSType,
                                         _ baseAddress: UnsafeMutableRawPointer, _ bytesPerRow: Int,
                                         _ releaseCallback: CVPixelBufferReleaseBytesCallback?, _ releaseRefCon: UnsafeMutableRawPointer?,
                                         _ pixelBufferAttributes: CFDictionary?, _ pixelBufferOut: UnsafeMutablePointer<CVPixelBuffer?>) -> CVReturn {
    guard CVPixelFormatLayout.of(pixelFormatType)?.planes.count == 1 else { pixelBufferOut.pointee = nil; return kCVReturnInvalidPixelFormat }
    pixelBufferOut.pointee = CVPixelBuffer(width: width, height: height, pixelFormat: pixelFormatType, bytes: baseAddress,
                                           bytesPerRow: bytesPerRow, release: releaseCallback.map { cb in { cb(releaseRefCon, UnsafeRawPointer(baseAddress)) } })
    return kCVReturnSuccess
}


@discardableResult
public func CVPixelBufferLockBaseAddress(_ pb: CVPixelBuffer, _ flags: CVPixelBufferLockFlags) -> CVReturn { pb.lockBase(); return kCVReturnSuccess }
@discardableResult
public func CVPixelBufferUnlockBaseAddress(_ pb: CVPixelBuffer, _ flags: CVPixelBufferLockFlags) -> CVReturn { pb.unlockBase(); return kCVReturnSuccess }
public func CVPixelBufferGetBaseAddress(_ pb: CVPixelBuffer) -> UnsafeMutableRawPointer? { pb.base }
public func CVPixelBufferGetBytesPerRow(_ pb: CVPixelBuffer) -> Int { pb.bytesPerRow }
public func CVPixelBufferGetWidth(_ pb: CVPixelBuffer) -> Int { pb.width }
public func CVPixelBufferGetHeight(_ pb: CVPixelBuffer) -> Int { pb.height }
public func CVPixelBufferGetPixelFormatType(_ pb: CVPixelBuffer) -> OSType { pb.pixelFormatType }
public func CVPixelBufferGetDataSize(_ pb: CVPixelBuffer) -> Int { pb.dataSize }
public func CVPixelBufferIsPlanar(_ pb: CVPixelBuffer) -> Bool { pb.isPlanar }
public func CVPixelBufferGetPlaneCount(_ pb: CVPixelBuffer) -> Int { pb.planeCount }
public func CVPixelBufferGetBaseAddressOfPlane(_ pb: CVPixelBuffer, _ plane: Int) -> UnsafeMutableRawPointer? { pb.baseAddress(ofPlane: plane) }
public func CVPixelBufferGetBytesPerRowOfPlane(_ pb: CVPixelBuffer, _ plane: Int) -> Int { pb.bytesPerRow(ofPlane: plane) }
public func CVPixelBufferGetWidthOfPlane(_ pb: CVPixelBuffer, _ plane: Int) -> Int { pb.width(ofPlane: plane) }
public func CVPixelBufferGetHeightOfPlane(_ pb: CVPixelBuffer, _ plane: Int) -> Int { pb.height(ofPlane: plane) }
public func CVImageBufferGetEncodedSize(_ b: CVImageBuffer) -> CGSize {
    CGSize(width: b.width, height: b.height)
}
public func CVImageBufferGetDisplaySize(_ b: CVImageBuffer) -> CGSize { CVImageBufferGetEncodedSize(b) }
public func CVImageBufferGetCleanRect(_ b: CVImageBuffer) -> CGRect { CGRect(origin: .zero, size: CVImageBufferGetEncodedSize(b)) }
public func CVPixelBufferGetTypeID() -> UInt { 0x4356_5042 }

// MARK: Attachments

public func CVBufferSetAttachment(_ buffer: CVBuffer, _ key: CFString, _ value: AnyObject, _ mode: CVAttachmentMode) {
    buffer.attachmentLock.lock(); defer { buffer.attachmentLock.unlock() }
    buffer.attachments[String(key)] = (value, mode)
}
public func CVBufferCopyAttachment(_ buffer: CVBuffer, _ key: CFString, _ mode: UnsafeMutablePointer<CVAttachmentMode>?) -> AnyObject? {
    buffer.attachmentLock.lock(); defer { buffer.attachmentLock.unlock() }
    guard let (v, m) = buffer.attachments[String(key)] else { return nil }
    mode?.pointee = m
    return v as AnyObject
}
public func CVBufferRemoveAttachment(_ buffer: CVBuffer, _ key: CFString) {
    buffer.attachmentLock.lock(); defer { buffer.attachmentLock.unlock() }
    buffer.attachments[String(key)] = nil
}
public func CVBufferRemoveAllAttachments(_ buffer: CVBuffer) {
    buffer.attachmentLock.lock(); defer { buffer.attachmentLock.unlock() }
    buffer.attachments.removeAll()
}
public func CVBufferCopyAttachments(_ buffer: CVBuffer, _ mode: CVAttachmentMode) -> CFDictionary? {
    buffer.attachmentLock.lock(); defer { buffer.attachmentLock.unlock() }
    let d = NSMutableDictionary()
    for (k, (v, m)) in buffer.attachments where m == mode { d[NSString(string: k)] = v }
    return d
}
public func CVBufferPropagateAttachments(_ source: CVBuffer, _ destination: CVBuffer) {
    source.attachmentLock.lock()
    let a = source.attachments.filter { $0.value.1 == .shouldPropagate }
    source.attachmentLock.unlock()
    destination.attachmentLock.lock()
    for (k, v) in a { destination.attachments[k] = v }
    destination.attachmentLock.unlock()
}

// MARK: Pools

/// Buffers of one size and format. Each is a fresh allocation, freed when
/// its last holder lets go, so a pool never holds memory between frames.
public final class CVPixelBufferPool: @unchecked Sendable {
    public let width: Int, height: Int, pixelFormat: OSType
    public let attributes: [String: Any]
    public init(width: Int, height: Int, pixelFormat: OSType, attributes: [String: Any] = [:]) {
        self.width = width; self.height = height; self.pixelFormat = pixelFormat; self.attributes = attributes
    }
    public func makeBuffer() -> CVPixelBuffer? { CVPixelBuffer(width: width, height: height, pixelFormat: pixelFormat) }
    public var pixelBufferAttributes: [String: Any] {
        var a = attributes
        a[kCVPixelBufferWidthKey as String] = width
        a[kCVPixelBufferHeightKey as String] = height
        a[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
        return a
    }
}

public func CVPixelBufferPoolCreate(_ allocator: CFAllocator?, _ poolAttributes: CFDictionary?, _ pixelBufferAttributes: CFDictionary?,
                                    _ poolOut: UnsafeMutablePointer<CVPixelBufferPool?>) -> CVReturn {
    let a = (pixelBufferAttributes as? [String: Any]) ?? [:]
    guard let w = (a[kCVPixelBufferWidthKey as String] as? NSNumber)?.intValue, let h = (a[kCVPixelBufferHeightKey as String] as? NSNumber)?.intValue,
          let f = (a[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value else {
        poolOut.pointee = nil
        return kCVReturnInvalidPoolAttributes
    }
    poolOut.pointee = CVPixelBufferPool(width: w, height: h, pixelFormat: f, attributes: a)
    return kCVReturnSuccess
}

public func CVPixelBufferPoolCreatePixelBuffer(_ allocator: CFAllocator?, _ pool: CVPixelBufferPool,
                                               _ pixelBufferOut: UnsafeMutablePointer<CVPixelBuffer?>) -> CVReturn {
    pixelBufferOut.pointee = pool.makeBuffer()
    return pixelBufferOut.pointee == nil ? kCVReturnPoolAllocationFailed : kCVReturnSuccess
}
public func CVPixelBufferPoolGetPixelBufferAttributes(_ pool: CVPixelBufferPool) -> CFDictionary? { pool.pixelBufferAttributes as NSDictionary }

// MARK: Pixel access helpers (used by CoreImage, AVFoundation)

extension CVPixelBuffer {
    /// The picture as straight RGBA8 rows (top row first): BGRA/RGBA/ARGB
    /// copied, 4:2:0 YCbCr converted with BT.709 (video or full range).
    public func rgba() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let src = base.assumingMemoryBound(to: UInt8.self)
        switch pixelFormatType {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_32ABGR:
            let order: (Int, Int, Int, Int) = switch pixelFormatType {
            case kCVPixelFormatType_32BGRA: (2, 1, 0, 3)
            case kCVPixelFormatType_32RGBA: (0, 1, 2, 3)
            case kCVPixelFormatType_32ARGB: (1, 2, 3, 0)
            default: (3, 2, 1, 0)
            }
            let row = bytesPerRow
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<height {
                    let s = src + y * row
                    var d = y * width * 4
                    for x in 0..<width {
                        let p = s + x * 4
                        o[d] = p[order.0]; o[d + 1] = p[order.1]; o[d + 2] = p[order.2]; o[d + 3] = p[order.3]
                        d += 4
                    }
                }
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            let full = pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || pixelFormatType == kCVPixelFormatType_420YpCbCr8PlanarFullRange
            let bi = planeCount == 2
            let yp = src, yr = planeRows[0]
            let cp = src + planeOffsets[1], cr = planeRows[1]
            let vp = bi ? cp : src + planeOffsets[2], vr = bi ? cr : planeRows[2]
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<height {
                    for x in 0..<width {
                        let Y = Double(yp[y * yr + x])
                        let cb: Double, crv: Double
                        if bi {
                            cb = Double(cp[(y / 2) * cr + (x / 2) * 2]); crv = Double(cp[(y / 2) * cr + (x / 2) * 2 + 1])
                        } else {
                            cb = Double(cp[(y / 2) * cr + x / 2]); crv = Double(vp[(y / 2) * vr + x / 2])
                        }
                        let (l, u, v) = full ? (Y, cb - 128, crv - 128) : ((Y - 16) * 255 / 219, (cb - 128) * 255 / 224, (crv - 128) * 255 / 224)
                        let r = l + 1.5748 * v, g = l - 0.1873 * u - 0.4681 * v, b = l + 1.8556 * u
                        let d = (y * width + x) * 4
                        o[d] = UInt8(max(0, min(255, r.rounded()))); o[d + 1] = UInt8(max(0, min(255, g.rounded())))
                        o[d + 2] = UInt8(max(0, min(255, b.rounded()))); o[d + 3] = 255
                    }
                }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height { for x in 0..<width { let v = src[y * bytesPerRow + x]; let d = (y * width + x) * 4; out[d] = v; out[d + 1] = v; out[d + 2] = v; out[d + 3] = 255 } }
        case kCVPixelFormatType_24RGB:
            for y in 0..<height { for x in 0..<width { let s = y * bytesPerRow + x * 3, d = (y * width + x) * 4; out[d] = src[s]; out[d + 1] = src[s + 1]; out[d + 2] = src[s + 2]; out[d + 3] = 255 } }
        default:
            break
        }
        return out
    }

    /// Writes straight RGBA8 rows into the buffer in its own format.
    public func write(rgba: [UInt8], width w: Int, height h: Int) {
        let dst = base.assumingMemoryBound(to: UInt8.self)
        let cw = min(w, width), ch = min(h, height)
        switch pixelFormatType {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA, kCVPixelFormatType_32ARGB, kCVPixelFormatType_32ABGR:
            let order: (Int, Int, Int, Int) = switch pixelFormatType {
            case kCVPixelFormatType_32BGRA: (2, 1, 0, 3)
            case kCVPixelFormatType_32RGBA: (0, 1, 2, 3)
            case kCVPixelFormatType_32ARGB: (1, 2, 3, 0)
            default: (3, 2, 1, 0)
            }
            rgba.withUnsafeBufferPointer { s in
                for y in 0..<ch {
                    let row = dst + y * bytesPerRow
                    for x in 0..<cw {
                        let i = (y * w + x) * 4, p = row + x * 4
                        p[order.0] = s[i]; p[order.1] = s[i + 1]; p[order.2] = s[i + 2]; p[order.3] = s[i + 3]
                    }
                }
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            let full = pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let yr = planeRows[0], cp = dst + planeOffsets[1], cr = planeRows[1]
            for y in 0..<ch {
                for x in 0..<cw {
                    let i = (y * w + x) * 4
                    let r = Double(rgba[i]), g = Double(rgba[i + 1]), b = Double(rgba[i + 2])
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    dst[y * yr + x] = UInt8(max(0, min(255, (full ? l : 16 + l * 219 / 255).rounded())))
                    if y % 2 == 0, x % 2 == 0 {
                        let u = (b - l) / 1.8556, v = (r - l) / 1.5748
                        let k = full ? 1.0 : 224.0 / 255
                        cp[(y / 2) * cr + x] = UInt8(max(0, min(255, (128 + u * k).rounded())))
                        cp[(y / 2) * cr + x + 1] = UInt8(max(0, min(255, (128 + v * k).rounded())))
                    }
                }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<ch { for x in 0..<cw { let i = (y * w + x) * 4; dst[y * bytesPerRow + x] = rgba[i] } }
        default:
            break
        }
    }
}

// MARK: Display link

public typealias CGDirectDisplayIDValue = UInt32

public struct CVTimeStamp: Sendable {
    public var version: UInt32 = 0
    public var videoTimeScale: Int32 = 1_000_000_000
    public var videoTime: Int64 = 0
    public var hostTime: UInt64 = 0
    public var rateScalar: Double = 1
    public var videoRefreshPeriod: Int64 = 16_666_667
    public var smpteTime = CVSMPTETime()
    public var flags: UInt64 = 0
    public var reserved: UInt64 = 0
    public init() {}
}
public struct CVSMPTETime: Sendable {
    public var subframes: Int16 = 0, subframeDivisor: Int16 = 0
    public var counter: UInt32 = 0, type: UInt32 = 0, flags: UInt32 = 0
    public var hours: Int16 = 0, minutes: Int16 = 0, seconds: Int16 = 0, frames: Int16 = 0
    public init() {}
}
public typealias CVOptionFlags = UInt64

public typealias CVDisplayLinkOutputCallback = (CVDisplayLink, UnsafePointer<CVTimeStamp>, UnsafePointer<CVTimeStamp>, CVOptionFlags,
                                                UnsafeMutablePointer<CVOptionFlags>, UnsafeMutableRawPointer?) -> CVReturn
public typealias CVDisplayLinkOutputHandler = (CVDisplayLink, UnsafePointer<CVTimeStamp>, UnsafePointer<CVTimeStamp>, CVOptionFlags,
                                               UnsafeMutablePointer<CVOptionFlags>) -> CVReturn

/// A frame clock at the display's refresh (60 Hz here): a thread that runs
/// only between Start and Stop, so an idle app has no timer.
public final class CVDisplayLink: @unchecked Sendable {
    public var refreshPeriod: Double = 1.0 / 60
    private var callback: CVDisplayLinkOutputCallback?
    private var context: UnsafeMutableRawPointer?
    private var handler: CVDisplayLinkOutputHandler?
    private var thread: Thread?
    private let lock = NSLock()
    private var running = false
    init() {}

    func setCallback(_ cb: CVDisplayLinkOutputCallback?, _ ctx: UnsafeMutableRawPointer?) { lock.lock(); callback = cb; context = ctx; handler = nil; lock.unlock() }
    func setHandler(_ h: @escaping CVDisplayLinkOutputHandler) { lock.lock(); handler = h; callback = nil; lock.unlock() }

    func start() -> CVReturn {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return kCVReturnDisplayLinkAlreadyRunning }
        guard callback != nil || handler != nil else { return kCVReturnDisplayLinkCallbacksNotSet }
        running = true
        let t = Thread { [self] in loop() }
        t.name = "CVDisplayLink"
        thread = t
        t.start()
        return kCVReturnSuccess
    }

    func stop() -> CVReturn {
        lock.lock(); defer { lock.unlock() }
        guard running else { return kCVReturnDisplayLinkNotRunning }
        running = false
        thread = nil
        return kCVReturnSuccess
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func loop() {
        let start = DispatchTime.now().uptimeNanoseconds
        var frame: UInt64 = 0
        while isRunning {
            frame += 1
            let period = UInt64(refreshPeriod * 1e9)
            let target = start + frame * period
            let now = DispatchTime.now().uptimeNanoseconds
            if target > now { Thread.sleep(forTimeInterval: Double(target - now) / 1e9) }
            guard isRunning else { break }
            var nowStamp = CVTimeStamp(), out = CVTimeStamp()
            nowStamp.hostTime = DispatchTime.now().uptimeNanoseconds
            nowStamp.videoTime = Int64(frame * period)
            out.hostTime = target + period
            out.videoTime = Int64((frame + 1) * period)
            var flagsOut: CVOptionFlags = 0
            lock.lock()
            let (cb, ctx, h) = (callback, context, handler)
            lock.unlock()
            if let h { _ = h(self, &nowStamp, &out, 0, &flagsOut) } else if let cb { _ = cb(self, &nowStamp, &out, 0, &flagsOut, ctx) }
        }
    }
}

public func CVDisplayLinkCreateWithActiveCGDisplays(_ out: UnsafeMutablePointer<CVDisplayLink?>) -> CVReturn {
    out.pointee = CVDisplayLink()
    return kCVReturnSuccess
}
public func CVDisplayLinkCreateWithCGDisplay(_ display: CGDirectDisplayIDValue, _ out: UnsafeMutablePointer<CVDisplayLink?>) -> CVReturn {
    out.pointee = CVDisplayLink()
    return kCVReturnSuccess
}
public func CVDisplayLinkSetOutputCallback(_ link: CVDisplayLink, _ cb: CVDisplayLinkOutputCallback?, _ ctx: UnsafeMutableRawPointer?) -> CVReturn {
    link.setCallback(cb, ctx)
    return kCVReturnSuccess
}
public func CVDisplayLinkSetOutputHandler(_ link: CVDisplayLink, _ handler: @escaping CVDisplayLinkOutputHandler) -> CVReturn {
    link.setHandler(handler)
    return kCVReturnSuccess
}
public func CVDisplayLinkStart(_ link: CVDisplayLink) -> CVReturn { link.start() }
public func CVDisplayLinkStop(_ link: CVDisplayLink) -> CVReturn { link.stop() }
public func CVDisplayLinkIsRunning(_ link: CVDisplayLink) -> Bool { link.isRunning }
public func CVDisplayLinkSetCurrentCGDisplay(_ link: CVDisplayLink, _ display: CGDirectDisplayIDValue) -> CVReturn { kCVReturnSuccess }
public func CVDisplayLinkGetActualOutputVideoRefreshPeriod(_ link: CVDisplayLink) -> Double { link.refreshPeriod }
public func CVGetCurrentHostTime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
public func CVGetHostClockFrequency() -> Double { 1e9 }
