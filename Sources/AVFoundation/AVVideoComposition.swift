// Video compositions: AVVideoComposition (and the macOS 26 Configuration
// value), instructions and layer instructions, the custom-compositor
// protocol with its render context and requests, and FrameComposer, the
// engine that turns "composition time t" into a picture for the image
// generator, readers, exports and the player's outputs: it finds each
// track's source frame through the edit list, then runs the app's own
// compositor, or the built-in one (layer transforms and opacity, on the CPU).

import CoreMedia
import CoreVideo
import Foundation

// MARK: Protocols

public protocol AVVideoCompositionInstructionProtocol: NSObjectProtocol, Sendable {
    var timeRange: CMTimeRange { get }
    var enablePostProcessing: Bool { get }
    var containsTweening: Bool { get }
    var requiredSourceTrackIDs: [NSValue]? { get }
    var passthroughTrackID: CMPersistentTrackID { get }
}

extension AVVideoCompositionInstructionProtocol {
    public var requiredSourceSampleDataTrackIDs: [NSNumber] { [] }
}

public protocol AVVideoCompositing: NSObjectProtocol, Sendable {
    init()
    var sourcePixelBufferAttributes: [String: any Sendable]? { get }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { get }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext)
    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest)
    func cancelAllPendingVideoCompositionRequests()
    var supportsWideColorSourceFrames: Bool { get }
    var supportsHDRSourceFrames: Bool { get }
    var canConformColorOfSourceFrames: Bool { get }
}

extension AVVideoCompositing {
    public func cancelAllPendingVideoCompositionRequests() {}
    public var supportsWideColorSourceFrames: Bool { false }
    public var supportsHDRSourceFrames: Bool { false }
    public var canConformColorOfSourceFrames: Bool { false }
}

public final class AVVideoCompositionRenderContext: NSObject, @unchecked Sendable {
    public let size: CGSize
    public let renderTransform: CGAffineTransform
    public let renderScale: Float
    public let pixelAspectRatio: AVPixelAspectRatio
    public let edgeWidths: AVEdgeWidths
    public let highQualityRendering: Bool
    public let videoComposition: AVVideoComposition
    let pixelFormat: OSType

    init(size: CGSize, composition: AVVideoComposition, pixelFormat: OSType) {
        self.size = size
        renderTransform = .identity
        renderScale = composition.renderScale
        pixelAspectRatio = AVPixelAspectRatio(horizontalSpacing: 1, verticalSpacing: 1)
        edgeWidths = AVEdgeWidths(left: 0, top: 0, right: 0, bottom: 0)
        highQualityRendering = true
        videoComposition = composition
        self.pixelFormat = pixelFormat
        super.init()
    }

    public func newPixelBuffer() -> CVPixelBuffer? {
        CVPixelBuffer(width: max(Int(size.width.rounded()), 1), height: max(Int(size.height.rounded()), 1), pixelFormat: pixelFormat)
    }
}

public struct AVPixelAspectRatio: Sendable, Equatable {
    public var horizontalSpacing: Int
    public var verticalSpacing: Int
    public init(horizontalSpacing: Int, verticalSpacing: Int) { self.horizontalSpacing = horizontalSpacing; self.verticalSpacing = verticalSpacing }
}
public struct AVEdgeWidths: Sendable, Equatable {
    public var left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat
    public init(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) { self.left = left; self.top = top; self.right = right; self.bottom = bottom }
}

/// One frame to compose; finished exactly once, from any thread.
public final class AVAsynchronousVideoCompositionRequest: NSObject, @unchecked Sendable {
    public let renderContext: AVVideoCompositionRenderContext
    public let compositionTime: CMTime
    public let sourceTrackIDs: [NSNumber]
    public let videoCompositionInstruction: any AVVideoCompositionInstructionProtocol
    private let frames: [CMPersistentTrackID: CVPixelBuffer]
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var finished = false
    private(set) var result: Result<CVPixelBuffer, Error>?

    init(context: AVVideoCompositionRenderContext, time: CMTime, instruction: any AVVideoCompositionInstructionProtocol,
         frames: [CMPersistentTrackID: CVPixelBuffer]) {
        renderContext = context
        compositionTime = time
        videoCompositionInstruction = instruction
        self.frames = frames
        sourceTrackIDs = frames.keys.sorted().map { NSNumber(value: $0) }
        super.init()
    }

    public func sourceFrame(byTrackID trackID: CMPersistentTrackID) -> CVPixelBuffer? { frames[trackID] }
    public func sourceSampleBuffer(byTrackID trackID: CMPersistentTrackID) -> CMSampleBuffer? { nil }
    public func sourceTimedMetadata(byTrackID trackID: CMPersistentTrackID) -> AnyObject? { nil }

    private func complete(_ r: Result<CVPixelBuffer, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        result = r
        lock.unlock()
        done.signal()
    }
    public func finish(withComposedVideoFrame composedVideoFrame: CVPixelBuffer) { complete(.success(composedVideoFrame)) }
    public func finish(with error: Error) { complete(.failure(error)) }
    public func finishCancelledRequest() { complete(.failure(avError(.operationCancelled, "The frame was cancelled."))) }

    func wait(timeout: Double) -> Result<CVPixelBuffer, Error> {
        if done.wait(timeout: .now() + timeout) == .timedOut { return .failure(avError(.videoCompositorFailed, "The video compositor didn't finish a frame.")) }
        return result ?? .failure(avError(.videoCompositorFailed, "No frame."))
    }
}

// MARK: Instructions

open class AVVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public internal(set) var timeRange: CMTimeRange = .invalid
    public internal(set) var backgroundColor: CGColor?
    public internal(set) var layerInstructions: [AVVideoCompositionLayerInstruction] = []
    public internal(set) var enablePostProcessing = true
    public let containsTweening = true
    public var requiredSourceTrackIDs: [NSValue]? { layerInstructions.map { NSNumber(value: $0.trackID) } }
    public let passthroughTrackID = kCMPersistentTrackID_Invalid
    public override init() { super.init() }

    public struct Configuration: Sendable {
        public var backgroundColor: CGColor?
        public var enablePostProcessing: Bool
        public var layerInstructions: [AVVideoCompositionLayerInstruction]
        public var timeRange: CMTimeRange
        public init(backgroundColor: CGColor? = nil, enablePostProcessing: Bool = true, layerInstructions: [AVVideoCompositionLayerInstruction] = [],
                    timeRange: CMTimeRange = .invalid) {
            self.backgroundColor = backgroundColor
            self.enablePostProcessing = enablePostProcessing
            self.layerInstructions = layerInstructions
            self.timeRange = timeRange
        }
    }
    public convenience init(configuration c: Configuration) {
        self.init()
        timeRange = c.timeRange
        backgroundColor = c.backgroundColor
        layerInstructions = c.layerInstructions
        enablePostProcessing = c.enablePostProcessing
    }
}

open class AVMutableVideoCompositionInstruction: AVVideoCompositionInstruction, @unchecked Sendable {
    open override var timeRange: CMTimeRange { get { super.timeRange } set { super.timeRange = newValue } }
    open override var backgroundColor: CGColor? { get { super.backgroundColor } set { super.backgroundColor = newValue } }
    open override var layerInstructions: [AVVideoCompositionLayerInstruction] { get { super.layerInstructions } set { super.layerInstructions = newValue } }
    open override var enablePostProcessing: Bool { get { super.enablePostProcessing } set { super.enablePostProcessing = newValue } }
    public override init() { super.init() }
}

open class AVVideoCompositionLayerInstruction: NSObject, @unchecked Sendable {
    public internal(set) var trackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var transforms: [(range: CMTimeRange, from: CGAffineTransform, to: CGAffineTransform)] = []
    var opacities: [(range: CMTimeRange, from: Float, to: Float)] = []
    var crops: [(range: CMTimeRange, from: CGRect, to: CGRect)] = []
    public override init() { super.init() }

    private static func value<T>(_ list: [(range: CMTimeRange, from: T, to: T)], at t: CMTime, lerp: (T, T, Double) -> T) -> T? {
        var best: (CMTime, T)?
        for e in list {
            if e.range.containsTime(t) {
                let k = e.range.duration.seconds > 0 ? (t - e.range.start).seconds / e.range.duration.seconds : 0
                return lerp(e.from, e.to, k)
            }
            if e.range.start <= t, best.map({ e.range.start >= $0.0 }) ?? true {
                best = (e.range.start, e.range.duration == .zero || !e.range.duration.isNumeric ? e.to : e.to)
            }
        }
        return best?.1
    }
    func transform(at t: CMTime) -> CGAffineTransform {
        Self.value(transforms, at: t) { a, b, k in
            let k = CGFloat(k)
            return CGAffineTransform(a: a.a + (b.a - a.a) * k, b: a.b + (b.b - a.b) * k, c: a.c + (b.c - a.c) * k, d: a.d + (b.d - a.d) * k,
                                     tx: a.tx + (b.tx - a.tx) * k, ty: a.ty + (b.ty - a.ty) * k)
        } ?? .identity
    }
    func opacity(at t: CMTime) -> Float { Self.value(opacities, at: t) { a, b, k in a + (b - a) * Float(k) } ?? 1 }
    func crop(at t: CMTime) -> CGRect? {
        Self.value(crops, at: t) { a, b, k in
            let k = CGFloat(k)
            return CGRect(x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k,
                          width: a.width + (b.width - a.width) * k, height: a.height + (b.height - a.height) * k)
        }
    }

    open func getTransformRamp(for time: CMTime, start: UnsafeMutablePointer<CGAffineTransform>?, end: UnsafeMutablePointer<CGAffineTransform>?,
                               timeRange: UnsafeMutablePointer<CMTimeRange>?) -> Bool {
        guard let e = transforms.first(where: { $0.range.containsTime(time) }) else { return false }
        start?.pointee = e.from; end?.pointee = e.to; timeRange?.pointee = e.range
        return true
    }
    open func getOpacityRamp(for time: CMTime, startOpacity: UnsafeMutablePointer<Float>?, endOpacity: UnsafeMutablePointer<Float>?,
                             timeRange: UnsafeMutablePointer<CMTimeRange>?) -> Bool {
        guard let e = opacities.first(where: { $0.range.containsTime(time) }) else { return false }
        startOpacity?.pointee = e.from; endOpacity?.pointee = e.to; timeRange?.pointee = e.range
        return true
    }
}

open class AVMutableVideoCompositionLayerInstruction: AVVideoCompositionLayerInstruction, @unchecked Sendable {
    public convenience init(assetTrack track: AVAssetTrack) {
        self.init()
        trackID = track.trackID
    }
    open override var trackID: CMPersistentTrackID { get { super.trackID } set { super.trackID = newValue } }
    open func setTransform(_ transform: CGAffineTransform, at time: CMTime) {
        transforms.append((CMTimeRange(start: time, duration: .zero), transform, transform))
    }
    open func setTransformRamp(fromStart startTransform: CGAffineTransform, toEnd endTransform: CGAffineTransform, timeRange: CMTimeRange) {
        transforms.append((timeRange, startTransform, endTransform))
    }
    open func setOpacity(_ opacity: Float, at time: CMTime) { opacities.append((CMTimeRange(start: time, duration: .zero), opacity, opacity)) }
    open func setOpacityRamp(fromStartOpacity startOpacity: Float, toEndOpacity endOpacity: Float, timeRange: CMTimeRange) {
        opacities.append((timeRange, startOpacity, endOpacity))
    }
    open func setCropRectangle(_ cropRectangle: CGRect, at time: CMTime) { crops.append((CMTimeRange(start: time, duration: .zero), cropRectangle, cropRectangle)) }
    open func setCropRectangleRamp(fromStartCropRectangle a: CGRect, toEndCropRectangle b: CGRect, timeRange: CMTimeRange) { crops.append((timeRange, a, b)) }
}

/// Core Animation in exports: accepted, not rendered (no layer renderer here).
open class AVVideoCompositionCoreAnimationTool: NSObject, @unchecked Sendable {
    public init(postProcessingAsVideoLayer videoLayer: CALayer, in animationLayer: CALayer) { super.init() }
    public init(postProcessingAsVideoLayers videoLayers: [CALayer], in animationLayer: CALayer) { super.init() }
    public init(additionalLayer layer: CALayer, asTrackID trackID: CMPersistentTrackID) { super.init() }
}

// MARK: Video compositions

open class AVVideoComposition: NSObject, @unchecked Sendable {
    public internal(set) var frameDuration: CMTime = CMTime(value: 1, timescale: 30)
    public internal(set) var renderSize: CGSize = .zero
    public internal(set) var renderScale: Float = 1
    public internal(set) var instructions: [any AVVideoCompositionInstructionProtocol] = []
    public internal(set) var customVideoCompositorClass: (any AVVideoCompositing.Type)?
    public internal(set) var animationTool: AVVideoCompositionCoreAnimationTool?
    public internal(set) var sourceTrackIDForFrameTiming: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    public internal(set) var colorPrimaries: String?
    public internal(set) var colorTransferFunction: String?
    public internal(set) var colorYCbCrMatrix: String?

    public override init() { super.init() }

    /// The macOS 26 value form.
    public struct Configuration: @unchecked Sendable {
        public var animationTool: AVVideoCompositionCoreAnimationTool?
        public var colorPrimaries: String?
        public var colorTransferFunction: String?
        public var colorYCbCrMatrix: String?
        public var customVideoCompositorClass: (any AVVideoCompositing.Type)?
        public var frameDuration: CMTime
        public var instructions: [any AVVideoCompositionInstructionProtocol]
        public var perFrameHDRDisplayMetadataPolicy: String?
        public var renderScale: Float
        public var renderSize: CGSize
        public var sourceSampleDataTrackIDs: [CMPersistentTrackID]
        public var sourceTrackIDForFrameTiming: CMPersistentTrackID

        public init(animationTool: AVVideoCompositionCoreAnimationTool? = nil, colorPrimaries: String? = nil, colorTransferFunction: String? = nil,
                    colorYCbCrMatrix: String? = nil, customVideoCompositorClass: (any AVVideoCompositing.Type)? = nil,
                    frameDuration: CMTime = .invalid, instructions: [any AVVideoCompositionInstructionProtocol] = [],
                    perFrameHDRDisplayMetadataPolicy: String? = nil, renderScale: Float = 1, renderSize: CGSize = .zero,
                    sourceSampleDataTrackIDs: [CMPersistentTrackID] = [], sourceTrackIDForFrameTiming: CMPersistentTrackID = kCMPersistentTrackID_Invalid) {
            self.animationTool = animationTool
            self.colorPrimaries = colorPrimaries
            self.colorTransferFunction = colorTransferFunction
            self.colorYCbCrMatrix = colorYCbCrMatrix
            self.customVideoCompositorClass = customVideoCompositorClass
            self.frameDuration = frameDuration
            self.instructions = instructions
            self.perFrameHDRDisplayMetadataPolicy = perFrameHDRDisplayMetadataPolicy
            self.renderScale = renderScale
            self.renderSize = renderSize
            self.sourceSampleDataTrackIDs = sourceSampleDataTrackIDs
            self.sourceTrackIDForFrameTiming = sourceTrackIDForFrameTiming
        }

        /// Defaults for `asset`: one passthrough-style instruction over its video tracks.
        public init(for asset: AVAsset) async throws {
            let c = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
            self.init(customVideoCompositorClass: nil, frameDuration: c.frameDuration, instructions: c.instructions, renderSize: c.renderSize)
        }
    }

    public convenience init(configuration c: Configuration) {
        self.init()
        frameDuration = c.frameDuration.isValid ? c.frameDuration : CMTime(value: 1, timescale: 30)
        renderSize = c.renderSize
        renderScale = c.renderScale
        instructions = c.instructions
        customVideoCompositorClass = c.customVideoCompositorClass
        animationTool = c.animationTool
        sourceTrackIDForFrameTiming = c.sourceTrackIDForFrameTiming
        colorPrimaries = c.colorPrimaries
        colorTransferFunction = c.colorTransferFunction
        colorYCbCrMatrix = c.colorYCbCrMatrix
    }

    /// One instruction over the asset, every video track layered (first on top), sized to the first.
    public static func videoComposition(withPropertiesOf asset: AVAsset) async throws -> AVVideoComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        let v = AVMutableVideoComposition()
        let fps = tracks.first.map { $0.nominalFrameRate > 0 ? $0.nominalFrameRate : 30 } ?? 30
        v.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        if let first = tracks.first {
            let r = CGRect(origin: .zero, size: first.naturalSize).applying(first.preferredTransform)
            v.renderSize = CGSize(width: abs(r.width), height: abs(r.height))
        }
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: duration)
        ins.layerInstructions = tracks.map {
            let l = AVMutableVideoCompositionLayerInstruction(assetTrack: $0)
            l.setTransform($0.preferredTransform, at: .zero)
            return l
        }
        v.instructions = [ins]
        return v
    }
    public convenience init(propertiesOf asset: AVAsset) {
        self.init()
        let tracks = asset.allTracks.filter { $0.mediaType == .video }
        let fps = tracks.first.map { $0.nominalFrameRate > 0 ? $0.nominalFrameRate : 30 } ?? 30
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        if let first = tracks.first {
            let r = CGRect(origin: .zero, size: first.naturalSize).applying(first.preferredTransform)
            renderSize = CGSize(width: abs(r.width), height: abs(r.height))
        }
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        ins.layerInstructions = tracks.map {
            let l = AVMutableVideoCompositionLayerInstruction(assetTrack: $0)
            l.setTransform($0.preferredTransform, at: .zero)
            return l
        }
        instructions = [ins]
    }

    open func isValid(for asset: AVAsset?, timeRange: CMTimeRange, validationDelegate: AnyObject?) -> Bool { renderSize.width > 0 && renderSize.height > 0 }
    public func isValid(forTracks tracks: [AVAssetTrack], assetDuration: CMTime, timeRange: CMTimeRange) async throws -> Bool { renderSize != .zero }
}

open class AVMutableVideoComposition: AVVideoComposition, @unchecked Sendable {
    open override var frameDuration: CMTime { get { super.frameDuration } set { super.frameDuration = newValue } }
    open override var renderSize: CGSize { get { super.renderSize } set { super.renderSize = newValue } }
    open override var renderScale: Float { get { super.renderScale } set { super.renderScale = newValue } }
    open override var instructions: [any AVVideoCompositionInstructionProtocol] { get { super.instructions } set { super.instructions = newValue } }
    open override var customVideoCompositorClass: (any AVVideoCompositing.Type)? { get { super.customVideoCompositorClass } set { super.customVideoCompositorClass = newValue } }
    open override var animationTool: AVVideoCompositionCoreAnimationTool? { get { super.animationTool } set { super.animationTool = newValue } }
    open override var sourceTrackIDForFrameTiming: CMPersistentTrackID { get { super.sourceTrackIDForFrameTiming } set { super.sourceTrackIDForFrameTiming = newValue } }
    open override var colorPrimaries: String? { get { super.colorPrimaries } set { super.colorPrimaries = newValue } }
    open override var colorTransferFunction: String? { get { super.colorTransferFunction } set { super.colorTransferFunction = newValue } }
    open override var colorYCbCrMatrix: String? { get { super.colorYCbCrMatrix } set { super.colorYCbCrMatrix = newValue } }
    public override init() { super.init() }
    public convenience init(propertiesOf asset: AVAsset, prototypeInstruction: AVVideoCompositionInstruction? = nil) {
        self.init()
        let base = AVVideoComposition(propertiesOf: asset)
        frameDuration = base.frameDuration
        renderSize = base.renderSize
        instructions = base.instructions
    }
}

// MARK: The frame engine

/// Pictures of an asset (with or without a video composition) by time.
/// Decoders are per track, so tracks reading one file at different times
/// don't fight; everything is released with the composer.
final class FrameComposer: @unchecked Sendable {
    let asset: AVAsset
    let composition: AVVideoComposition?
    private var decoders: [String: VideoDecoder] = [:]
    private var compositor: (any AVVideoCompositing)?
    private var context: AVVideoCompositionRenderContext?
    private let lock = NSLock()
    private(set) var lastError: Error?

    init(asset: AVAsset, composition: AVVideoComposition?) {
        self.asset = asset
        self.composition = composition
    }

    deinit { compositor?.cancelAllPendingVideoCompositionRequests() }

    var videoTracks: [AVAssetTrack] { asset.allTracks.filter { $0.mediaType == .video && $0.isEnabled } }

    var renderSize: CGSize {
        if let c = composition, c.renderSize != .zero { return c.renderSize }
        guard let t = videoTracks.first else { return .zero }
        return t.naturalSize
    }

    var frameDuration: CMTime {
        if let c = composition, c.frameDuration.isNumeric, c.frameDuration > .zero { return c.frameDuration }
        let fps = videoTracks.first.map { $0.nominalFrameRate > 0 ? Double($0.nominalFrameRate) : 30 } ?? 30
        return CMTime(seconds: 1 / fps, preferredTimescale: 600)
    }

    /// The source frame of composition track `track` at composition time `t`.
    func sourceFrame(_ track: AVAssetTrack, at t: CMTime) -> CVPixelBuffer? {
        guard let src = track.source(at: t) else { return nil }
        let key = "\(track.trackID)|\(src.url.absoluteString)"
        let dec: VideoDecoder
        if let d = decoders[key] { dec = d } else {
            dec = VideoDecoder(url: src.url)
            decoders[key] = dec
        }
        let f = dec.frame(at: src.time.seconds)
        if f == nil, let why = dec.failure { lastError = avError(.decodeFailed, why) }
        return f?.buffer
    }

    /// The composed picture at `t`, or nil (with `lastError`) when there's none.
    func frame(at t: CMTime) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        lastError = nil
        guard let c = composition, !c.instructions.isEmpty else {
            // No composition: the first video track showing at t.
            for track in videoTracks { if let f = sourceFrame(track, at: t) { return f } }
            if lastError == nil { lastError = avError(.noImageAtTime, "There is no picture at \(t.seconds) s.") }
            return nil
        }
        let ins = c.instructions.first { $0.timeRange.containsTime(t) } ?? c.instructions.last { $0.timeRange.end == t }
        guard let ins else {
            lastError = avError(.noImageAtTime, "No video composition instruction covers \(t.seconds) s.")
            return nil
        }
        let ids: [CMPersistentTrackID] = ins.requiredSourceTrackIDs.map { $0.compactMap { ($0 as? NSNumber)?.int32Value } }
            ?? videoTracks.map(\.trackID)
        var frames: [CMPersistentTrackID: CVPixelBuffer] = [:]
        for id in ids {
            guard let track = asset.allTracks.first(where: { $0.trackID == id }) else { continue }
            if let f = sourceFrame(track, at: t) { frames[id] = f }
        }
        let size = renderSize
        if let cls = c.customVideoCompositorClass {
            let comp: any AVVideoCompositing
            if let existing = compositor { comp = existing } else {
                comp = cls.init()
                compositor = comp
            }
            if context == nil {
                let fmt = (comp.requiredPixelBufferAttributesForRenderContext[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
                    ?? (comp.requiredPixelBufferAttributesForRenderContext[kCVPixelBufferPixelFormatTypeKey as String] as? OSType)
                    ?? kCVPixelFormatType_32BGRA
                let ctx = AVVideoCompositionRenderContext(size: size, composition: c, pixelFormat: fmt)
                context = ctx
                comp.renderContextChanged(ctx)
            }
            let request = AVAsynchronousVideoCompositionRequest(context: context!, time: t, instruction: ins, frames: frames)
            comp.startRequest(request)
            switch request.wait(timeout: 60) {
            case let .success(pb): return pb
            case let .failure(e):
                lastError = e
                return nil
            }
        }
        // The built-in compositor: layers bottom to top.
        guard let out = CVPixelBuffer(width: max(Int(size.width), 1), height: max(Int(size.height), 1), pixelFormat: kCVPixelFormatType_32BGRA) else { return nil }
        let bg = (ins as? AVVideoCompositionInstruction)?.backgroundColor?.components ?? [0, 0, 0, 1]
        fill(out, bg)
        let layers = (ins as? AVVideoCompositionInstruction)?.layerInstructions ?? ids.map {
            let l = AVMutableVideoCompositionLayerInstruction()
            l.trackID = $0
            return l
        }
        for l in layers.reversed() {
            guard let src = frames[l.trackID] else { continue }
            blit(src, into: out, transform: l.transform(at: t), opacity: l.opacity(at: t), crop: l.crop(at: t))
        }
        return out
    }
}

private func fill(_ pb: CVPixelBuffer, _ c: [CGFloat]) {
    let rgba = c.count >= 4 ? c : (c.count == 2 ? [c[0], c[0], c[0], c[1]] : [0, 0, 0, 1])
    let px: (UInt8, UInt8, UInt8, UInt8) = (UInt8(rgba[2] * 255), UInt8(rgba[1] * 255), UInt8(rgba[0] * 255), UInt8(rgba[3] * 255))
    let d = pb.base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<pb.height {
        let row = d + y * pb.bytesPerRow
        for x in 0..<pb.width { row[x * 4] = px.0; row[x * 4 + 1] = px.1; row[x * 4 + 2] = px.2; row[x * 4 + 3] = px.3 }
    }
}

/// Draws `src` (any format) through `transform` over BGRA `dst`, bilinear.
func blit(_ src: CVPixelBuffer, into dst: CVPixelBuffer, transform: CGAffineTransform, opacity: Float, crop: CGRect?) {
    guard opacity > 0 else { return }
    let rgba: [UInt8] = src.pixelFormatType == kCVPixelFormatType_32BGRA ? [] : src.rgba()
    let sw = src.width, sh = src.height, sRow = src.bytesPerRow
    let sp = src.base.assumingMemoryBound(to: UInt8.self)
    let inv = transform.inverted()
    let bounds = CGRect(x: 0, y: 0, width: sw, height: sh).intersection(crop ?? .infinite)
    let box = bounds.applying(transform).intersection(CGRect(x: 0, y: 0, width: dst.width, height: dst.height))
    guard !box.isNull, box.width > 0, box.height > 0 else { return }
    let dp = dst.base.assumingMemoryBound(to: UInt8.self)
    let op = Double(opacity)
    @inline(__always) func sample(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
        if rgba.isEmpty {
            let p = sp + y * sRow + x * 4
            return (Double(p[2]), Double(p[1]), Double(p[0]), Double(p[3]))
        }
        let i = (y * sw + x) * 4
        return (Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2]), Double(rgba[i + 3]))
    }
    for y in Int(box.minY)..<Int(box.maxY.rounded(.up)) {
        for x in Int(box.minX)..<Int(box.maxX.rounded(.up)) {
            let s = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inv)
            guard bounds.contains(s) else { continue }
            let fx = Double(s.x) - 0.5, fy = Double(s.y) - 0.5
            let x0 = max(0, min(sw - 1, Int(fx.rounded(.down)))), y0 = max(0, min(sh - 1, Int(fy.rounded(.down))))
            let x1 = min(sw - 1, x0 + 1), y1 = min(sh - 1, y0 + 1)
            let tx = max(0, min(1, fx - Double(x0))), ty = max(0, min(1, fy - Double(y0)))
            let a = sample(x0, y0), b = sample(x1, y0), c = sample(x0, y1), d = sample(x1, y1)
            func mix(_ p: Double, _ q: Double, _ r: Double, _ s: Double) -> Double { (p * (1 - tx) + q * tx) * (1 - ty) + (r * (1 - tx) + s * tx) * ty }
            let r = mix(a.0, b.0, c.0, d.0), g = mix(a.1, b.1, c.1, d.1), bl = mix(a.2, b.2, c.2, d.2)
            let al = mix(a.3, b.3, c.3, d.3) / 255 * op
            let p = dp + y * dst.bytesPerRow + x * 4
            p[2] = UInt8(max(0, min(255, (r * al + Double(p[2]) * (1 - al)).rounded())))
            p[1] = UInt8(max(0, min(255, (g * al + Double(p[1]) * (1 - al)).rounded())))
            p[0] = UInt8(max(0, min(255, (bl * al + Double(p[0]) * (1 - al)).rounded())))
            p[3] = UInt8(max(0, min(255, (255 * al + Double(p[3]) * (1 - al)).rounded())))
        }
    }
}
