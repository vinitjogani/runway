// MetalKit for Linux and Windows: MTKView is an NSView whose `device` is
// nil (there's no Metal device here, see Metal), so its delegate is never
// asked to draw; MTKTextureLoader fails through its error path.

@_exported import AppKit
@_exported import Metal
@_exported import QuartzCore

@preconcurrency @MainActor
public protocol MTKViewDelegate: AnyObject {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    func draw(in view: MTKView)
}

@preconcurrency @MainActor
open class MTKView: NSView {
    open var device: (any MTLDevice)?
    open weak var delegate: MTKViewDelegate?
    open var colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    open var depthStencilPixelFormat: MTLPixelFormat = .invalid
    open var clearColor = MTLClearColor()
    open var sampleCount = 1
    open var preferredFramesPerSecond = 60
    open var enableSetNeedsDisplay = false
    open var isPaused = false
    open var autoResizeDrawable = true
    open var framebufferOnly = true
    open var drawableSize: CGSize = .zero
    open var currentDrawable: (any CAMetalDrawable)? { nil }
    open var currentRenderPassDescriptor: MTLRenderPassDescriptor? { nil }

    public init(frame frameRect: CGRect, device: (any MTLDevice)?) {
        super.init(frame: frameRect)
        self.device = device
    }
    public override convenience init(frame frameRect: CGRect) { self.init(frame: frameRect, device: nil) }
    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }
    open func draw() { if device != nil { delegate?.draw(in: self) } }
    open func releaseDrawables() {}
}

public final class MTKTextureLoader: @unchecked Sendable {
    public struct Option: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let SRGB = Option(rawValue: "MTKTextureLoaderOptionSRGB"), origin = Option(rawValue: "MTKTextureLoaderOptionOrigin")
        public static let textureUsage = Option(rawValue: "MTKTextureLoaderOptionTextureUsage")
        public static let textureStorageMode = Option(rawValue: "MTKTextureLoaderOptionTextureStorageMode")
    }
    public let device: any MTLDevice
    public init(device: any MTLDevice) { self.device = device }
    private func fail() -> NSError { NSError(domain: "MTKTextureLoaderErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "No Metal device."]) }
    public func newTexture(cgImage: CGImage, options: [Option: Any]? = nil) throws -> any MTLTexture { throw fail() }
    public func newTexture(URL: URL, options: [Option: Any]? = nil) throws -> any MTLTexture { throw fail() }
    public func newTexture(data: Data, options: [Option: Any]? = nil) throws -> any MTLTexture { throw fail() }
}
