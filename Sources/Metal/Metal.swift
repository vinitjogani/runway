// Metal for Linux and Windows: there is no Metal GPU here, so
// `MTLCreateSystemDefaultDevice()` returns nil and `MTLCopyAllDevices()` is
// empty — the answer Apple gives on a Mac without a supported GPU, which
// apps already handle (Core Image, for one, falls back to its CPU path).
// The protocol and value types exist so code that names them compiles.

@_exported import Foundation

public func MTLCreateSystemDefaultDevice() -> (any MTLDevice)? { nil }
public func MTLCopyAllDevices() -> [any MTLDevice] { [] }

public enum MTLPixelFormat: UInt, Sendable {
    case invalid = 0, a8Unorm = 1, r8Unorm = 10, r16Float = 25, rg8Unorm = 30, r32Float = 55
    case rgba8Unorm = 70, rgba8Unorm_srgb = 71, bgra8Unorm = 80, bgra8Unorm_srgb = 81, rgb10a2Unorm = 90, bgr10a2Unorm = 94
    case rgba16Float = 115, rgba32Float = 125, depth32Float = 252, stencil8 = 253, depth32Float_stencil8 = 260
}
public enum MTLStorageMode: UInt, Sendable { case shared = 0, managed = 1, `private` = 2, memoryless = 3 }
public enum MTLCPUCacheMode: UInt, Sendable { case defaultCache = 0, writeCombined = 1 }
public enum MTLTextureType: UInt, Sendable { case type1D = 0, type1DArray, type2D, type2DArray, type2DMultisample, typeCube, typeCubeArray, type3D }
public enum MTLLoadAction: UInt, Sendable { case dontCare = 0, load, clear }
public enum MTLStoreAction: UInt, Sendable { case dontCare = 0, store, multisampleResolve }
public enum MTLPrimitiveType: UInt, Sendable { case point = 0, line, lineStrip, triangle, triangleStrip }
public enum MTLCommandBufferStatus: UInt, Sendable { case notEnqueued = 0, enqueued, committed, scheduled, completed, error }
public enum MTLGPUFamily: Int, Sendable { case apple1 = 1001, apple7 = 1007, apple8 = 1008, apple9 = 1009, mac2 = 2002, common1 = 3001, common2, common3, metal3 = 5001 }

public struct MTLTextureUsage: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let unknown = MTLTextureUsage([]), shaderRead = MTLTextureUsage(rawValue: 1), shaderWrite = MTLTextureUsage(rawValue: 2)
    public static let renderTarget = MTLTextureUsage(rawValue: 4), pixelFormatView = MTLTextureUsage(rawValue: 0x10)
}
public struct MTLResourceOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let storageModeShared = MTLResourceOptions([]), storageModeManaged = MTLResourceOptions(rawValue: 16)
    public static let storageModePrivate = MTLResourceOptions(rawValue: 32), cpuCacheModeWriteCombined = MTLResourceOptions(rawValue: 1)
}

public struct MTLSize: Sendable, Equatable {
    public var width: Int, height: Int, depth: Int
    public init(width: Int, height: Int, depth: Int) { self.width = width; self.height = height; self.depth = depth }
    public init() { self.init(width: 0, height: 0, depth: 0) }
}
public struct MTLOrigin: Sendable, Equatable {
    public var x: Int, y: Int, z: Int
    public init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }
    public init() { self.init(x: 0, y: 0, z: 0) }
}
public struct MTLRegion: Sendable, Equatable {
    public var origin: MTLOrigin, size: MTLSize
    public init(origin: MTLOrigin, size: MTLSize) { self.origin = origin; self.size = size }
    public init() { self.init(origin: .init(), size: .init()) }
}
public func MTLRegionMake2D(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> MTLRegion {
    MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0), size: MTLSize(width: w, height: h, depth: 1))
}
public struct MTLClearColor: Sendable, Equatable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double) { self.red = red; self.green = green; self.blue = blue; self.alpha = alpha }
    public init() { self.init(red: 0, green: 0, blue: 0, alpha: 1) }
}
public func MTLClearColorMake(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> MTLClearColor { MTLClearColor(red: r, green: g, blue: b, alpha: a) }

public protocol MTLResource: AnyObject, Sendable {
    var label: String? { get set }
    var device: any MTLDevice { get }
    var storageMode: MTLStorageMode { get }
}
public protocol MTLTexture: MTLResource {
    var width: Int { get }
    var height: Int { get }
    var depth: Int { get }
    var pixelFormat: MTLPixelFormat { get }
    var textureType: MTLTextureType { get }
    var usage: MTLTextureUsage { get }
    func getBytes(_ pixelBytes: UnsafeMutableRawPointer, bytesPerRow: Int, from region: MTLRegion, mipmapLevel level: Int)
    func replace(region: MTLRegion, mipmapLevel level: Int, withBytes pixelBytes: UnsafeRawPointer, bytesPerRow: Int)
}
public protocol MTLBuffer: MTLResource {
    var length: Int { get }
    func contents() -> UnsafeMutableRawPointer
}
public protocol MTLFunction: AnyObject, Sendable { var name: String { get } }
public protocol MTLLibrary: AnyObject, Sendable {
    func makeFunction(name functionName: String) -> (any MTLFunction)?
    var functionNames: [String] { get }
}
public protocol MTLCommandEncoder: AnyObject { func endEncoding() }
public protocol MTLRenderCommandEncoder: MTLCommandEncoder {}
public protocol MTLComputeCommandEncoder: MTLCommandEncoder {}
public protocol MTLBlitCommandEncoder: MTLCommandEncoder {}
public protocol MTLDrawable: AnyObject, Sendable {
    func present()
}
public protocol MTLCommandBuffer: AnyObject, Sendable {
    var status: MTLCommandBufferStatus { get }
    var error: Error? { get }
    func commit()
    func waitUntilCompleted()
    func present(_ drawable: any MTLDrawable)
    func makeRenderCommandEncoder(descriptor: MTLRenderPassDescriptor) -> (any MTLRenderCommandEncoder)?
    func makeComputeCommandEncoder() -> (any MTLComputeCommandEncoder)?
    func makeBlitCommandEncoder() -> (any MTLBlitCommandEncoder)?
}
public protocol MTLCommandQueue: AnyObject, Sendable {
    var label: String? { get set }
    func makeCommandBuffer() -> (any MTLCommandBuffer)?
}
public protocol MTLRenderPipelineState: AnyObject, Sendable {}
public protocol MTLComputePipelineState: AnyObject, Sendable {}
public protocol MTLSamplerState: AnyObject, Sendable {}

/// A GPU. None exist here; the protocol is for code that names it.
public protocol MTLDevice: AnyObject, Sendable {
    var name: String { get }
    var registryID: UInt64 { get }
    var isLowPower: Bool { get }
    var isHeadless: Bool { get }
    var hasUnifiedMemory: Bool { get }
    var recommendedMaxWorkingSetSize: UInt64 { get }
    var maxBufferLength: Int { get }
    func supportsFamily(_ gpuFamily: MTLGPUFamily) -> Bool
    func makeCommandQueue() -> (any MTLCommandQueue)?
    func makeCommandQueue(maxCommandBufferCount: Int) -> (any MTLCommandQueue)?
    func makeTexture(descriptor: MTLTextureDescriptor) -> (any MTLTexture)?
    func makeBuffer(length: Int, options: MTLResourceOptions) -> (any MTLBuffer)?
    func makeBuffer(bytes pointer: UnsafeRawPointer, length: Int, options: MTLResourceOptions) -> (any MTLBuffer)?
    func makeDefaultLibrary() -> (any MTLLibrary)?
    func makeLibrary(source: String, options: MTLCompileOptions?) throws -> any MTLLibrary
    func makeRenderPipelineState(descriptor: MTLRenderPipelineDescriptor) throws -> any MTLRenderPipelineState
    func makeComputePipelineState(function computeFunction: any MTLFunction) throws -> any MTLComputePipelineState
    func makeSamplerState(descriptor: MTLSamplerDescriptor) -> (any MTLSamplerState)?
}

open class MTLTextureDescriptor: NSObject, @unchecked Sendable {
    open var textureType: MTLTextureType = .type2D
    open var pixelFormat: MTLPixelFormat = .rgba8Unorm
    open var width = 1, height = 1, depth = 1, mipmapLevelCount = 1, sampleCount = 1, arrayLength = 1
    open var usage: MTLTextureUsage = .shaderRead
    open var storageMode: MTLStorageMode = .managed
    open var resourceOptions: MTLResourceOptions = []
    public override init() { super.init() }
    open class func texture2DDescriptor(pixelFormat: MTLPixelFormat, width: Int, height: Int, mipmapped: Bool) -> MTLTextureDescriptor {
        let d = MTLTextureDescriptor()
        d.pixelFormat = pixelFormat; d.width = width; d.height = height
        return d
    }
}
open class MTLRenderPassColorAttachmentDescriptor: NSObject, @unchecked Sendable {
    open var texture: (any MTLTexture)?
    open var loadAction: MTLLoadAction = .dontCare
    open var storeAction: MTLStoreAction = .dontCare
    open var clearColor = MTLClearColor()
}
open class MTLRenderPassDescriptor: NSObject, @unchecked Sendable {
    public let colorAttachments = MTLRenderPassColorAttachmentDescriptorArray()
    public override init() { super.init() }
}
public final class MTLRenderPassColorAttachmentDescriptorArray: @unchecked Sendable {
    private var items: [Int: MTLRenderPassColorAttachmentDescriptor] = [:]
    public subscript(i: Int) -> MTLRenderPassColorAttachmentDescriptor! {
        get { if let d = items[i] { return d }; let d = MTLRenderPassColorAttachmentDescriptor(); items[i] = d; return d }
        set { items[i] = newValue }
    }
}
open class MTLRenderPipelineDescriptor: NSObject, @unchecked Sendable {
    open var label: String?
    open var vertexFunction: (any MTLFunction)?
    open var fragmentFunction: (any MTLFunction)?
    public override init() { super.init() }
}
open class MTLSamplerDescriptor: NSObject, @unchecked Sendable { public override init() { super.init() } }
open class MTLCompileOptions: NSObject, @unchecked Sendable { public override init() { super.init() } }
