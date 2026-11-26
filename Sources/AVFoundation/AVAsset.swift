// Assets: AVURLAsset over GstDiscoverer (duration, tracks, natural size,
// rotation as preferredTransform), the async `load` API, compositions
// (AVMutableComposition and its tracks as edit lists over source files) and
// audio mixes with volume ramps.

@_exported import CoreMedia
@_exported import CoreVideo
@_exported import QuartzCore
@_exported import CoreGraphics
@_exported import Foundation
@_exported import ImageIO
import RunwayFoundation

// MARK: Errors and media types

public let AVFoundationErrorDomain = "AVFoundationErrorDomain"

public struct AVError: CustomNSError, Hashable, Sendable {
    public enum Code: Int, Sendable {
        case unknown = -11800, outOfMemory = -11801, sessionNotRunning = -11803, deviceAlreadyUsedByAnotherSession = -11804
        case noDataCaptured = -11805, sessionConfigurationChanged = -11806, diskFull = -11807, deviceWasDisconnected = -11808
        case mediaChanged = -11809, maximumDurationReached = -11810, maximumFileSizeReached = -11811, mediaDiscontinuity = -11812
        case maximumNumberOfSamplesForFileFormatReached = -11813, deviceNotConnected = -11814, deviceInUseByAnotherApplication = -11815
        case deviceLockedForConfigurationByAnotherProcess = -11817, exportFailed = -11820, decodeFailed = -11821, invalidSourceMedia = -11822
        case fileAlreadyExists = -11823, compositionTrackSegmentsNotContiguous = -11824, invalidCompositionTrackSegmentDuration = -11825
        case invalidCompositionTrackSegmentSourceStartTime = -11826, invalidCompositionTrackSegmentSourceDuration = -11827
        case fileFormatNotRecognized = -11828, fileFailedToParse = -11829, maximumStillImageCaptureRequestsExceeded = -11830
        case contentIsProtected = -11831, noImageAtTime = -11832, decoderNotFound = -11833, encoderNotFound = -11834
        case contentIsNotAuthorized = -11835, applicationIsNotAuthorized = -11836, operationNotSupportedForAsset = -11838
        case decoderTemporarilyUnavailable = -11839, encoderTemporarilyUnavailable = -11840, invalidVideoComposition = -11841
        case referenceForbiddenByReferencePolicy = -11842, invalidOutputURLPathExtension = -11843, screenCaptureFailed = -11844
        case displayWasDisabled = -11845, torchLevelUnavailable = -11846, incompatibleAsset = -11848, failedToLoadMediaData = -11849
        case serverIncorrectlyConfigured = -11850, applicationIsNotAuthorizedToUseDevice = -11852, failedToParse = -11853
        case fileTypeDoesNotSupportSampleReferences = -11854, undecodableMediaData = -11855, airPlayControllerRequiresInternet = -11856
        case airPlayReceiverRequiresInternet = -11857, videoCompositorFailed = -11858, recordingAlreadyInProgress = -11859
        case unsupportedOutputSettings = -11861, operationNotAllowed = -11862, contentIsUnavailable = -11863, formatUnsupported = -11864
        case malformedDepth = -11865, contentNotUpdated = -11866, noLongerPlayable = -11867, noCompatibleAlternatesForExternalDisplay = -11868
        case noSourceTrack = -11869, externalPlaybackNotSupportedForAsset = -11870, operationNotSupportedForPreset = -11871
        case sessionHardwareCostOverage = -11872, unsupportedDeviceActiveFormat = -11873, mediaServicesWereReset = -11819
        case operationCancelled = -11878
    }
    public let _nsError: NSError
    public init(_nsError: NSError) { self._nsError = _nsError }
    public init(_ code: Code, userInfo: [String: Any] = [:]) { _nsError = NSError(domain: AVFoundationErrorDomain, code: code.rawValue, userInfo: userInfo) }
    public static var errorDomain: String { AVFoundationErrorDomain }
    public var errorCode: Int { _nsError.code }
    public var errorUserInfo: [String: Any] { _nsError.userInfo }
    public var code: Code { Code(rawValue: _nsError.code) ?? .unknown }
    public static let unknown = Code.unknown, decodeFailed = Code.decodeFailed, fileFormatNotRecognized = Code.fileFormatNotRecognized
    public static func == (a: AVError, b: AVError) -> Bool { a._nsError.code == b._nsError.code }
    public func hash(into h: inout Hasher) { h.combine(_nsError.code) }
}

public struct AVMediaType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let video = AVMediaType("vide"), audio = AVMediaType("soun"), text = AVMediaType("text")
    public static let closedCaption = AVMediaType("clcp"), subtitle = AVMediaType("sbtl"), timecode = AVMediaType("tmcd")
    public static let metadata = AVMediaType("meta"), muxed = AVMediaType("muxx"), depthData = AVMediaType("dpth")
}

public struct AVMediaCharacteristic: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let visual = AVMediaCharacteristic(rawValue: "public.visual"), audible = AVMediaCharacteristic(rawValue: "public.audible")
    public static let legible = AVMediaCharacteristic(rawValue: "public.legible")
}

public struct AVFileType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let mov = AVFileType("com.apple.quicktime-movie"), mp4 = AVFileType("public.mpeg-4"), m4v = AVFileType("com.apple.m4v-video")
    public static let m4a = AVFileType("com.apple.m4a-audio"), wav = AVFileType("com.microsoft.waveform-audio"), aiff = AVFileType("public.aiff-audio")
    public static let aifc = AVFileType("public.aifc-audio"), caf = AVFileType("com.apple.coreaudio-format"), mp3 = AVFileType("public.mp3")
    public static let ac3 = AVFileType("public.ac3-audio"), amr = AVFileType("org.3gpp.adaptive-multi-rate-audio")
    public static let mobile3GPP = AVFileType("public.3gpp"), heic = AVFileType("public.heic"), jpg = AVFileType("public.jpeg")
    public static let tif = AVFileType("public.tiff"), dng = AVFileType("com.adobe.raw-image"), heif = AVFileType("public.heif")

    var pathExtension: String {
        switch self {
        case .mov: "mov"
        case .mp4: "mp4"
        case .m4v: "m4v"
        case .m4a: "m4a"
        case .wav: "wav"
        case .aiff: "aiff"
        case .caf: "caf"
        case .mp3: "mp3"
        default: rawValue
        }
    }
}

// MARK: Async loading

public protocol AVAsynchronousKeyValueLoading {
    func statusOfValue(forKey key: String, error outError: NSErrorPointer) -> AVKeyValueStatus
    func loadValuesAsynchronously(forKeys keys: [String], completionHandler handler: (@Sendable () -> Void)?)
}

public enum AVKeyValueStatus: Int, Sendable { case unknown, loading, loaded, failed, cancelled }

public class AVAnyAsyncProperty: @unchecked Sendable {
    let key: String
    init(key: String) { self.key = key }
}

/// A property loaded with `load(_:)`: its value comes from `get`.
public final class AVAsyncProperty<Root, Value>: AVAnyAsyncProperty, @unchecked Sendable {
    let get: @Sendable (Root) async throws -> Value
    init(_ key: String, _ get: @escaping @Sendable (Root) async throws -> Value) {
        self.get = get
        super.init(key: key)
    }

    public enum Status {
        case notYetLoaded, loading, loaded(Value), failed(any Error)
    }
}

extension AVAsynchronousKeyValueLoading {
    public func load<T: Sendable>(_ p: AVAsyncProperty<Self, T>) async throws -> T { try await p.get(self) }
    public func load<A: Sendable, B: Sendable>(_ a: AVAsyncProperty<Self, A>, _ b: AVAsyncProperty<Self, B>) async throws -> (A, B) {
        (try await a.get(self), try await b.get(self))
    }
    public func load<A: Sendable, B: Sendable, C: Sendable>(_ a: AVAsyncProperty<Self, A>, _ b: AVAsyncProperty<Self, B>,
                                                          _ c: AVAsyncProperty<Self, C>) async throws -> (A, B, C) {
        (try await a.get(self), try await b.get(self), try await c.get(self))
    }
    public func load<A: Sendable, B: Sendable, C: Sendable, D: Sendable>(_ a: AVAsyncProperty<Self, A>, _ b: AVAsyncProperty<Self, B>,
                                                                       _ c: AVAsyncProperty<Self, C>, _ d: AVAsyncProperty<Self, D>) async throws -> (A, B, C, D) {
        (try await a.get(self), try await b.get(self), try await c.get(self), try await d.get(self))
    }
    public func status<T>(of property: AVAsyncProperty<Self, T>) -> AVAsyncProperty<Self, T>.Status { .notYetLoaded }
}

// MARK: Assets

/// A timed media resource. URL assets read their file with GStreamer;
/// compositions describe edits over other assets' tracks.
open class AVAsset: NSObject, AVAsynchronousKeyValueLoading, @unchecked Sendable {
    let lock = NSLock()

    public override init() { super.init() }

    /// Tracks, built once.
    func makeTracks() throws -> [AVAssetTrack] { [] }
    func computeDuration() throws -> CMTime { .zero }

    private var cachedTracks: [AVAssetTrack]?
    private var cachedError: Error?

    func loadedTracks() throws -> [AVAssetTrack] {
        lock.lock()
        if let t = cachedTracks { lock.unlock(); return t }
        if let e = cachedError { lock.unlock(); throw e }
        lock.unlock()
        do {
            let t = try makeTracks()
            lock.lock(); cachedTracks = t; lock.unlock()
            return t
        } catch {
            lock.lock(); cachedError = error; lock.unlock()
            throw error
        }
    }
    func resetTracks() { lock.lock(); cachedTracks = nil; lock.unlock() }

    // Synchronous (deprecated on Apple platforms, still widely used).
    open var duration: CMTime { (try? computeDuration()) ?? .zero }
    var allTracks: [AVAssetTrack] { (try? loadedTracks()) ?? [] }
    open var isPlayable: Bool { (try? loadedTracks()).map { !$0.isEmpty } ?? false }
    open var isExportable: Bool { isPlayable }
    open var isReadable: Bool { isPlayable }
    open var isComposable: Bool { isPlayable }
    open var hasProtectedContent: Bool { false }
    open var providesPreciseDurationAndTiming: Bool { true }
    open var preferredRate: Float { 1 }
    open var preferredVolume: Float { 1 }
    open var preferredTransform: CGAffineTransform { .identity }
    open var naturalSize: CGSize { allTracks.first { $0.mediaType == .video }?.naturalSize ?? .zero }
    open var metadata: [AVMetadataItem] { [] }
    open var commonMetadata: [AVMetadataItem] { [] }
    open var creationDate: AVMetadataItem? { nil }

    public func loadTracks(withMediaType mediaType: AVMediaType) async throws -> [AVAssetTrack] {
        try await detached { try self.loadedTracks().filter { $0.mediaType == mediaType } }
    }
    public func loadTrack(withTrackID trackID: CMPersistentTrackID) async throws -> AVAssetTrack? {
        try await detached { try self.loadedTracks().first { $0.trackID == trackID } }
    }
    public func loadTracks(withMediaCharacteristic c: AVMediaCharacteristic) async throws -> [AVAssetTrack] {
        try await detached {
            try self.loadedTracks().filter {
                switch c {
                case .visual: $0.mediaType == .video
                case .audible: $0.mediaType == .audio
                default: false
                }
            }
        }
    }

    public func statusOfValue(forKey key: String, error outError: NSErrorPointer) -> AVKeyValueStatus {
        do { _ = try loadedTracks(); return .loaded } catch {
            outError?.pointee = error as NSError
            return .failed
        }
    }
    public func loadValuesAsynchronously(forKeys keys: [String], completionHandler handler: (@Sendable () -> Void)?) {
        DispatchQueue.global().async {
            _ = try? self.loadedTracks()
            handler?()
        }
    }
    open func cancelLoading() {}
}

/// `tracks` and friends, typed per class as on Apple platforms (a
/// composition's are AVCompositionTracks, a mutable one's mutable): protocol
/// extensions here, class members in AVMutableComposition.
public protocol AVAssetTrackAccess {}
extension AVAsset: AVAssetTrackAccess {}
extension AVAssetTrackAccess where Self: AVAsset {
    public var tracks: [AVAssetTrack] { allTracks }
    public func tracks(withMediaType mediaType: AVMediaType) -> [AVAssetTrack] { allTracks.filter { $0.mediaType == mediaType } }
    public func track(withTrackID trackID: CMPersistentTrackID) -> AVAssetTrack? { allTracks.first { $0.trackID == trackID } }
}
extension AVAssetTrackAccess where Self: AVComposition {
    public var tracks: [AVCompositionTrack] { compositionTracks }
    public func tracks(withMediaType mediaType: AVMediaType) -> [AVCompositionTrack] { compositionTracks.filter { $0.mediaType == mediaType } }
    public func track(withTrackID trackID: CMPersistentTrackID) -> AVCompositionTrack? { compositionTracks.first { $0.trackID == trackID } }
}

/// Runs blocking media work off the caller's executor.
func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        DispatchQueue.global(qos: .userInitiated).async {
            do { c.resume(returning: try work()) } catch { c.resume(throwing: error) }
        }
    }
}

extension AVAsyncProperty where Root: AVAsset, Value == CMTime {
    public static var duration: AVAsyncProperty<Root, CMTime> { .init("duration") { a in try await detached { try a.computeDuration() } } }
}
extension AVAsyncProperty where Root: AVAsset, Value == [AVAssetTrack] {
    public static var tracks: AVAsyncProperty<Root, [AVAssetTrack]> { .init("tracks") { a in try await detached { try a.loadedTracks() } } }
}
extension AVAsyncProperty where Root: AVAsset, Value == Bool {
    public static var isPlayable: AVAsyncProperty<Root, Bool> { .init("playable") { a in try await detached { !(try a.loadedTracks()).isEmpty } } }
    public static var isExportable: AVAsyncProperty<Root, Bool> { .init("exportable") { a in try await detached { !(try a.loadedTracks()).isEmpty } } }
    public static var isReadable: AVAsyncProperty<Root, Bool> { .init("readable") { a in try await detached { !(try a.loadedTracks()).isEmpty } } }
    public static var isComposable: AVAsyncProperty<Root, Bool> { .init("composable") { a in try await detached { !(try a.loadedTracks()).isEmpty } } }
    public static var hasProtectedContent: AVAsyncProperty<Root, Bool> { .init("hasProtectedContent") { _ in false } }
    public static var providesPreciseDurationAndTiming: AVAsyncProperty<Root, Bool> { .init("providesPreciseDurationAndTiming") { _ in true } }
}
extension AVAsyncProperty where Root: AVAsset, Value == CGSize {
    public static var naturalSize: AVAsyncProperty<Root, CGSize> { .init("naturalSize") { a in try await detached { a.naturalSize } } }
}
extension AVAsyncProperty where Root: AVAsset, Value == CGAffineTransform {
    public static var preferredTransform: AVAsyncProperty<Root, CGAffineTransform> { .init("preferredTransform") { a in a.preferredTransform } }
}
extension AVAsyncProperty where Root: AVAsset, Value == Float {
    public static var preferredRate: AVAsyncProperty<Root, Float> { .init("preferredRate") { _ in 1 } }
    public static var preferredVolume: AVAsyncProperty<Root, Float> { .init("preferredVolume") { _ in 1 } }
}
extension AVAsyncProperty where Root: AVAsset, Value == [AVMetadataItem] {
    public static var metadata: AVAsyncProperty<Root, [AVMetadataItem]> { .init("metadata") { _ in [] } }
    public static var commonMetadata: AVAsyncProperty<Root, [AVMetadataItem]> { .init("commonMetadata") { _ in [] } }
}
extension AVAsyncProperty where Root: AVAsset, Value == AVMetadataItem? {
    public static var creationDate: AVAsyncProperty<Root, AVMetadataItem?> { .init("creationDate") { _ in nil } }
}

public final class AVMetadataItem: NSObject, @unchecked Sendable {
    public var identifier: String?
    public var value: (any NSCopying & NSObjectProtocol)?
    public var stringValue: String? { value as? String ?? (value as? NSString).map(String.init) }
    public var dateValue: Date? { value as? Date }
    public var numberValue: NSNumber? { value as? NSNumber }
    public override init() { super.init() }
}


public let AVURLAssetPreferPreciseDurationAndTimingKey = "AVURLAssetPreferPreciseDurationAndTimingKey"
public let AVURLAssetReferenceRestrictionsKey = "AVURLAssetReferenceRestrictionsKey"
public let AVURLAssetHTTPHeaderFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"
public let AVURLAssetAllowsCellularAccessKey = "AVURLAssetAllowsCellularAccessKey"

/// A file or URL, read with GstDiscoverer: one video track (id 1) and one
/// audio track per stream the file has.
open class AVURLAsset: AVAsset, @unchecked Sendable {
    public let url: URL
    public init(url URL: URL, options: [String: Any]? = nil) {
        url = URL
        super.init()
    }
    public convenience init(url URL: URL) { self.init(url: URL, options: nil) }

    var info: MediaInfo { get throws { try MediaInfo.read(url).get() } }

    override func computeDuration() throws -> CMTime {
        let d = try info.duration
        return CMTime(seconds: d, preferredTimescale: 600_000)
    }

    override func makeTracks() throws -> [AVAssetTrack] {
        let i = try info
        var out: [AVAssetTrack] = []
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: i.duration, preferredTimescale: 600_000))
        for n in 0..<i.videoCount {
            let t = AVAssetTrack(asset: self, trackID: CMPersistentTrackID(out.count + 1), mediaType: .video, timeRange: range)
            t.streamIndex = n
            if n == 0 {
                t._naturalSize = CGSize(width: i.width, height: i.height)
                t._nominalFrameRate = Float(i.fps)
                t._estimatedDataRate = Float(i.videoBitrate)
                t._preferredTransform = Self.transform(rotation: i.rotation, flipped: i.flipped, width: CGFloat(i.width), height: CGFloat(i.height))
                t._formatDescriptions = [CMFormatDescription(mediaType: kCMMediaType_Video, subType: Self.fourCC(i.videoCodec),
                                                             dimensions: .init(width: Int32(i.width), height: Int32(i.height)))]
            }
            out.append(t)
        }
        for n in 0..<i.audioCount {
            let t = AVAssetTrack(asset: self, trackID: CMPersistentTrackID(out.count + 1), mediaType: .audio, timeRange: range)
            t.streamIndex = n
            if n == 0 {
                t._estimatedDataRate = Float(i.audioBitrate)
                t._formatDescriptions = [CMFormatDescription(mediaType: kCMMediaType_Audio, subType: Self.fourCC(i.audioCodec),
                                                             audio: .pcm(rate: Double(i.rate), channels: i.channels, bits: 32, float: true))]
            }
            out.append(t)
        }
        return out
    }

    open override var preferredTransform: CGAffineTransform { .identity }

    static func fourCC(_ caps: String) -> FourCharCode {
        switch caps {
        case "video/x-h264": kCMVideoCodecType_H264
        case "video/x-h265": kCMVideoCodecType_HEVC
        case "video/x-vp9": kCMVideoCodecType_VP9
        case "video/x-av1": kCMVideoCodecType_AV1
        case "image/jpeg": kCMVideoCodecType_JPEG
        case "audio/mpeg": kAudioFormatMPEG4AAC
        case "audio/x-opus": kAudioFormatOpus
        case "audio/x-flac": kAudioFormatFLAC
        default: caps.hasPrefix("audio/x-raw") ? kAudioFormatLinearPCM : 0
        }
    }

    /// The display transform for a clockwise rotation tag, as Apple's
    /// `preferredTransform` would hold it.
    static func transform(rotation: Int, flipped: Bool, width w: CGFloat, height h: CGFloat) -> CGAffineTransform {
        var t: CGAffineTransform = switch rotation {
        case 90: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: .identity
        }
        if flipped { t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rotation == 90 || rotation == 270 ? h : w, ty: 0).concatenating(t) }
        return t
    }

    open class func audiovisualTypes() -> [AVFileType] { [.mov, .mp4, .m4v, .m4a, .wav, .mp3, .aiff, .caf] }
    open class func audiovisualMIMETypes() -> [String] { ["video/mp4", "video/quicktime", "audio/mp4", "audio/wav", "audio/mpeg", "video/webm"] }
    open class func isPlayableExtendedMIMEType(_ extendedMIMEType: String) -> Bool { true }
}

// MARK: Tracks

/// One track of an asset.
open class AVAssetTrack: NSObject, AVAsynchronousKeyValueLoading, @unchecked Sendable {
    public private(set) weak var asset: AVAsset?
    /// The file a URL asset's track reads (kept when the asset goes away).
    let sourceURL: URL?
    public let trackID: CMPersistentTrackID
    public let mediaType: AVMediaType
    var _timeRange: CMTimeRange
    var _naturalSize: CGSize = .zero
    var _preferredTransform: CGAffineTransform = .identity
    var _nominalFrameRate: Float = 0
    var _estimatedDataRate: Float = 0
    var _formatDescriptions: [CMFormatDescription] = []
    var streamIndex = 0
    public var isEnabled = true

    init(asset: AVAsset, trackID: CMPersistentTrackID, mediaType: AVMediaType, timeRange: CMTimeRange) {
        self.asset = asset
        sourceURL = (asset as? AVURLAsset)?.url
        self.trackID = trackID
        self.mediaType = mediaType
        _timeRange = timeRange
        super.init()
    }

    open var timeRange: CMTimeRange { _timeRange }
    open var naturalSize: CGSize { _naturalSize }
    open var preferredTransform: CGAffineTransform { _preferredTransform }
    open var nominalFrameRate: Float { _nominalFrameRate }
    open var minFrameDuration: CMTime { _nominalFrameRate > 0 ? CMTime(seconds: 1 / Double(_nominalFrameRate), preferredTimescale: 600) : .invalid }
    open var estimatedDataRate: Float { _estimatedDataRate }
    open var formatDescriptions: [Any] { _formatDescriptions }
    open var naturalTimeScale: CMTimeScale { 600 }
    open var isPlayable: Bool { true }
    open var isDecodable: Bool { true }
    open var isSelfContained: Bool { true }
    open var totalSampleDataLength: Int64 { Int64(Double(_estimatedDataRate / 8) * timeRange.duration.seconds) }
    open var preferredVolume: Float { 1 }
    open var languageCode: String? { nil }
    open var segments: [AVAssetTrackSegment] {
        [AVAssetTrackSegment(timeMapping: CMTimeMapping(source: timeRange, target: timeRange), isEmpty: false)]
    }
    open func hasMediaCharacteristic(_ c: AVMediaCharacteristic) -> Bool {
        (c == .visual && mediaType == .video) || (c == .audible && mediaType == .audio)
    }
    open func segment(forTrackTime trackTime: CMTime) -> AVAssetTrackSegment? { segments.first { $0.timeMapping.target.containsTime(trackTime) } }
    open func samplePresentationTime(forTrackTime trackTime: CMTime) -> CMTime { trackTime }

    public func statusOfValue(forKey key: String, error outError: NSErrorPointer) -> AVKeyValueStatus { .loaded }
    public func loadValuesAsynchronously(forKeys keys: [String], completionHandler handler: (@Sendable () -> Void)?) {
        DispatchQueue.global().async { handler?() }
    }

    /// The source a frame or sound at track time `t` comes from.
    func source(at t: CMTime) -> (url: URL, time: CMTime, track: AVAssetTrack)? {
        guard let url = sourceURL, timeRange.containsTime(t) || t == timeRange.end else { return nil }
        return (url, t, self)
    }
}

open class AVAssetTrackSegment: NSObject, @unchecked Sendable {
    public let timeMapping: CMTimeMapping
    public let isEmpty: Bool
    init(timeMapping: CMTimeMapping, isEmpty: Bool) {
        self.timeMapping = timeMapping
        self.isEmpty = isEmpty
        super.init()
    }
}

extension AVAsyncProperty where Root: AVAssetTrack, Value == CGSize {
    public static var naturalSize: AVAsyncProperty<Root, CGSize> { .init("naturalSize") { t in t.naturalSize } }
}
extension AVAsyncProperty where Root: AVAssetTrack, Value == CGAffineTransform {
    public static var preferredTransform: AVAsyncProperty<Root, CGAffineTransform> { .init("preferredTransform") { t in t.preferredTransform } }
}
extension AVAsyncProperty where Root: AVAssetTrack, Value == CMTimeRange {
    public static var timeRange: AVAsyncProperty<Root, CMTimeRange> { .init("timeRange") { t in t.timeRange } }
}
extension AVAsyncProperty where Root: AVAssetTrack, Value == Float {
    public static var nominalFrameRate: AVAsyncProperty<Root, Float> { .init("nominalFrameRate") { t in t.nominalFrameRate } }
    public static var estimatedDataRate: AVAsyncProperty<Root, Float> { .init("estimatedDataRate") { t in t.estimatedDataRate } }
    public static var preferredVolume: AVAsyncProperty<Root, Float> { .init("preferredVolume") { t in t.preferredVolume } }
}
extension AVAsyncProperty where Root: AVAssetTrack, Value == CMTime {
    public static var minFrameDuration: AVAsyncProperty<Root, CMTime> { .init("minFrameDuration") { t in t.minFrameDuration } }
}
extension AVAsyncProperty where Root: AVAssetTrack, Value == CMTimeScale {
    public static var naturalTimeScale: AVAsyncProperty<Root, CMTimeScale> { .init("naturalTimeScale") { t in t.naturalTimeScale } }
}
extension AVAsyncProperty where Root: AVAssetTrack, Value == [CMFormatDescription] {
    public static var formatDescriptions: AVAsyncProperty<Root, [CMFormatDescription]> { .init("formatDescriptions") { t in t._formatDescriptions } }
}
extension AVAsyncProperty where Root: AVAssetTrack, Value == Bool {
    public static var isPlayable: AVAsyncProperty<Root, Bool> { .init("playable") { _ in true } }
    public static var isEnabled: AVAsyncProperty<Root, Bool> { .init("enabled") { t in t.isEnabled } }
    public static var isDecodable: AVAsyncProperty<Root, Bool> { .init("decodable") { _ in true } }
}
extension AVAsyncProperty where Root: AVAssetTrack, Value == [AVAssetTrackSegment] {
    public static var segments: AVAsyncProperty<Root, [AVAssetTrackSegment]> { .init("segments") { t in t.segments } }
}
extension AVAsyncProperty where Root: AVAssetTrack, Value == Int64 {
    public static var totalSampleDataLength: AVAsyncProperty<Root, Int64> { .init("totalSampleDataLength") { t in t.totalSampleDataLength } }
}

// MARK: Compositions

/// One piece of a composition track: a span of a source track (or nothing) at a place on the timeline.
open class AVCompositionTrackSegment: AVAssetTrackSegment, @unchecked Sendable {
    public let sourceURL: URL?
    public let sourceTrackID: CMPersistentTrackID
    let sourceTrack: AVAssetTrack?
    init(sourceTrack: AVAssetTrack?, url: URL?, mapping: CMTimeMapping) {
        self.sourceTrack = sourceTrack
        sourceURL = url
        sourceTrackID = sourceTrack?.trackID ?? kCMPersistentTrackID_Invalid
        super.init(timeMapping: mapping, isEmpty: sourceTrack == nil)
    }
    public convenience init(url URL: URL, trackID: CMPersistentTrackID, sourceTimeRange: CMTimeRange, targetTimeRange: CMTimeRange) {
        let asset = AVURLAsset(url: URL)
        self.init(sourceTrack: asset.track(withTrackID: trackID), url: URL, mapping: CMTimeMapping(source: sourceTimeRange, target: targetTimeRange))
    }
    public convenience init(timeRange: CMTimeRange) {
        self.init(sourceTrack: nil, url: nil, mapping: CMTimeMapping(target: timeRange))
    }

    func moved(to target: CMTimeRange) -> AVCompositionTrackSegment {
        AVCompositionTrackSegment(sourceTrack: sourceTrack, url: sourceURL, mapping: CMTimeMapping(source: timeMapping.source, target: target))
    }

    /// Part of this segment, by target time.
    func slice(_ a: CMTime, _ b: CMTime) -> AVCompositionTrackSegment? {
        let tr = timeMapping.target
        let s = CMTimeMaximum(a, tr.start), e = CMTimeMinimum(b, tr.end)
        guard s < e else { return nil }
        if isEmpty { return AVCompositionTrackSegment(sourceTrack: nil, url: nil, mapping: CMTimeMapping(target: CMTimeRange(start: s, end: e))) }
        let src = timeMapping.source
        let ss = CMTimeMapTimeFromRangeToRange(s, fromRange: tr, toRange: src), se = CMTimeMapTimeFromRangeToRange(e, fromRange: tr, toRange: src)
        return AVCompositionTrackSegment(sourceTrack: sourceTrack, url: sourceURL, mapping: CMTimeMapping(source: CMTimeRange(start: ss, end: se), target: CMTimeRange(start: s, end: e)))
    }
}

/// A track of a composition: an ordered, contiguous edit list.
open class AVCompositionTrack: AVAssetTrack, @unchecked Sendable {
    var _segments: [AVCompositionTrackSegment] = []
    public var preferredVolumeValue: Float = 1

    open override var segments: [AVAssetTrackSegment] { _segments }
    open override var timeRange: CMTimeRange {
        guard let first = _segments.first, let last = _segments.last else { return .zero }
        return CMTimeRange(start: first.timeMapping.target.start, end: last.timeMapping.target.end)
    }
    open override var naturalSize: CGSize {
        _naturalSize != .zero ? _naturalSize : (_segments.lazy.compactMap { $0.sourceTrack?.naturalSize }.first ?? .zero)
    }
    open override var preferredTransform: CGAffineTransform { _preferredTransform }
    open override var nominalFrameRate: Float { _segments.lazy.compactMap { $0.sourceTrack?.nominalFrameRate }.first ?? 30 }
    open override var formatDescriptions: [Any] { _segments.lazy.compactMap { $0.sourceTrack?.formatDescriptions }.first ?? [] }

    /// The source at track time `t` (the last frame of a segment at its very end).
    override func source(at t: CMTime) -> (url: URL, time: CMTime, track: AVAssetTrack)? {
        guard let seg = _segments.first(where: { $0.timeMapping.target.containsTime(t) })
                ?? _segments.last(where: { $0.timeMapping.target.end == t }),
              !seg.isEmpty, let src = seg.sourceTrack else { return nil }
        let st = CMTimeMapTimeFromRangeToRange(t, fromRange: seg.timeMapping.target, toRange: seg.timeMapping.source)
        return src.source(at: st)
    }
}

open class AVMutableCompositionTrack: AVCompositionTrack, @unchecked Sendable {
    open var naturalTimeScaleValue: CMTimeScale = 600
    open override var naturalSize: CGSize {
        get { super.naturalSize }
        set { _naturalSize = newValue }
    }
    open override var preferredTransform: CGAffineTransform {
        get { _preferredTransform }
        set { _preferredTransform = newValue }
    }
    open var preferredVolume_: Float = 1
    open var languageCodeValue: String?

    /// Inserts `timeRange` of `track` at `startTime`, pushing later media back.
    open func insertTimeRange(_ timeRange: CMTimeRange, of track: AVAssetTrack, at startTime: CMTime) throws {
        guard timeRange.isValid, startTime.isNumeric, timeRange.duration > .zero else {
            throw avError(.invalidCompositionTrackSegmentDuration, "The time range is empty or invalid.")
        }
        guard track.mediaType == mediaType else { throw avError(.incompatibleAsset, "A \(track.mediaType.rawValue) track can't go into a \(mediaType.rawValue) track.") }
        // Pieces of the source: through compositions down to files.
        var pieces: [AVCompositionTrackSegment] = []
        if let c = track as? AVCompositionTrack {
            for s in c._segments {
                if let p = s.slice(timeRange.start, timeRange.end) {
                    pieces.append(p.moved(to: CMTimeRange(start: p.timeMapping.target.start - timeRange.start + startTime, duration: p.timeMapping.target.duration)))
                }
            }
        } else {
            let url = track.sourceURL
            pieces = [AVCompositionTrackSegment(sourceTrack: track, url: url,
                                                mapping: CMTimeMapping(source: timeRange, target: CMTimeRange(start: startTime, duration: timeRange.duration)))]
            if _naturalSize == .zero { _naturalSize = track.naturalSize }
        }
        insert(pieces, at: startTime, duration: timeRange.duration)
    }

    open func insertTimeRanges(_ timeRanges: [NSValue], of tracks: [AVAssetTrack], at startTime: CMTime) throws {
        var at = startTime
        for (r, t) in zip(timeRanges, tracks) {
            guard let range = r.timeRangeValue else { continue }
            try insertTimeRange(range, of: t, at: at)
            at = at + range.duration
        }
    }

    open func insertEmptyTimeRange(_ timeRange: CMTimeRange) {
        guard timeRange.isValid, timeRange.duration > .zero else { return }
        insert([AVCompositionTrackSegment(timeRange: timeRange)], at: timeRange.start, duration: timeRange.duration)
    }

    private func insert(_ pieces: [AVCompositionTrackSegment], at t: CMTime, duration: CMTime) {
        let end = timeRange.end
        var out: [AVCompositionTrackSegment] = []
        if t > end {
            out = _segments
            out.append(AVCompositionTrackSegment(timeRange: CMTimeRange(start: end, end: t)))
            out += pieces
        } else {
            for s in _segments {
                let r = s.timeMapping.target
                if r.end <= t { out.append(s); continue }
                if r.start >= t { out.append(s.moved(to: CMTimeRange(start: r.start + duration, duration: r.duration))); continue }
                // Split at t.
                if let a = s.slice(r.start, t) { out.append(a) }
                if let b = s.slice(t, r.end) { out.append(b.moved(to: CMTimeRange(start: t + duration, duration: b.timeMapping.target.duration))) }
            }
            out += pieces
            out.sort { $0.timeMapping.target.start < $1.timeMapping.target.start }
        }
        _segments = out
    }

    /// Removes `timeRange`, pulling later media forward.
    open func removeTimeRange(_ timeRange: CMTimeRange) {
        guard timeRange.isValid, timeRange.duration > .zero else { return }
        let (a, b) = (timeRange.start, timeRange.end)
        var out: [AVCompositionTrackSegment] = []
        for s in _segments {
            let r = s.timeMapping.target
            if r.end <= a { out.append(s); continue }
            if r.start >= b { out.append(s.moved(to: CMTimeRange(start: r.start - timeRange.duration, duration: r.duration))); continue }
            if let left = s.slice(r.start, a) { out.append(left) }
            if let right = s.slice(b, r.end) {
                out.append(right.moved(to: CMTimeRange(start: right.timeMapping.target.start - timeRange.duration, duration: right.timeMapping.target.duration)))
            }
        }
        _segments = out
    }

    /// Plays `timeRange` over `duration` instead (a speed change).
    open func scaleTimeRange(_ timeRange: CMTimeRange, toDuration duration: CMTime) {
        guard timeRange.isValid, timeRange.duration > .zero, duration > .zero else { return }
        let k = duration.seconds / timeRange.duration.seconds
        let delta = duration - timeRange.duration
        var out: [AVCompositionTrackSegment] = []
        for s in _segments {
            let r = s.timeMapping.target
            if r.end <= timeRange.start { out.append(s); continue }
            if r.start >= timeRange.end { out.append(s.moved(to: CMTimeRange(start: r.start + delta, duration: r.duration))); continue }
            for piece in [s.slice(r.start, timeRange.start), s.slice(timeRange.start, timeRange.end), s.slice(timeRange.end, r.end)].compactMap({ $0 }) {
                let pr = piece.timeMapping.target
                if pr.end <= timeRange.start { out.append(piece) } else if pr.start >= timeRange.end {
                    out.append(piece.moved(to: CMTimeRange(start: pr.start + delta, duration: pr.duration)))
                } else {
                    let start = timeRange.start + CMTimeMultiplyByFloat64(pr.start - timeRange.start, multiplier: k)
                    out.append(piece.moved(to: CMTimeRange(start: start, duration: CMTimeMultiplyByFloat64(pr.duration, multiplier: k))))
                }
            }
        }
        _segments = out
    }

    open func validateSegments(_ trackSegments: [AVCompositionTrackSegment]) throws {}
    open var mutableSegments: [AVCompositionTrackSegment] {
        get { _segments }
        set { _segments = newValue }
    }
    open func replaceTimeRange(_ timeRange: CMTimeRange, of track: AVAssetTrack, at startTime: CMTime) throws {
        removeTimeRange(CMTimeRange(start: startTime, duration: timeRange.duration))
        try insertTimeRange(timeRange, of: track, at: startTime)
    }
}

/// An edit over other assets' tracks.
open class AVComposition: AVAsset, @unchecked Sendable {
    var compositionTracks: [AVCompositionTrack] = []
    public var naturalSizeValue: CGSize = .zero

    override func makeTracks() throws -> [AVAssetTrack] { compositionTracks }
    override func loadedTracks() throws -> [AVAssetTrack] { compositionTracks }
    override func computeDuration() throws -> CMTime { duration }

    open override var duration: CMTime { compositionTracks.map(\.timeRange.end).max() ?? .zero }
    override var allTracks: [AVAssetTrack] { compositionTracks }
    open override var naturalSize: CGSize { naturalSizeValue != .zero ? naturalSizeValue : (compositionTracks.first { $0.mediaType == .video }?.naturalSize ?? .zero) }
    open override var isPlayable: Bool { true }
    open var urlAssetInitializationOptions: [String: Any] { [:] }
}

open class AVMutableComposition: AVComposition, @unchecked Sendable {
    public override init() { super.init() }
    public convenience init(urlAssetInitializationOptions: [String: Any]?) { self.init() }

    public var tracks: [AVMutableCompositionTrack] { compositionTracks.compactMap { $0 as? AVMutableCompositionTrack } }
    public func tracks(withMediaType mediaType: AVMediaType) -> [AVMutableCompositionTrack] { tracks.filter { $0.mediaType == mediaType } }
    public func track(withTrackID trackID: CMPersistentTrackID) -> AVMutableCompositionTrack? { tracks.first { $0.trackID == trackID } }
    open override var naturalSize: CGSize {
        get { super.naturalSize }
        set { naturalSizeValue = newValue }
    }

    open func addMutableTrack(withMediaType mediaType: AVMediaType, preferredTrackID: CMPersistentTrackID) -> AVMutableCompositionTrack? {
        var id = preferredTrackID
        if id == kCMPersistentTrackID_Invalid || compositionTracks.contains(where: { $0.trackID == id }) {
            id = (compositionTracks.map(\.trackID).max() ?? 0) + 1
        }
        let t = AVMutableCompositionTrack(asset: self, trackID: id, mediaType: mediaType, timeRange: .zero)
        compositionTracks.append(t)
        return t
    }
    open func removeTrack(_ track: AVCompositionTrack) { compositionTracks.removeAll { $0 === track } }
    open func mutableTrack(compatibleWith track: AVAssetTrack) -> AVMutableCompositionTrack? { tracks.first { $0.mediaType == track.mediaType } }

    /// Every track of `asset` over `timeRange`, inserted at `startTime`.
    open func insertTimeRange(_ timeRange: CMTimeRange, of asset: AVAsset, at startTime: CMTime) throws {
        for src in try asset.loadedTracks() {
            let dst = mutableTrack(compatibleWith: src) ?? addMutableTrack(withMediaType: src.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try dst.insertTimeRange(timeRange, of: src, at: startTime)
        }
    }
    open func insertEmptyTimeRange(_ timeRange: CMTimeRange) { for t in tracks { t.insertEmptyTimeRange(timeRange) } }
    open func removeTimeRange(_ timeRange: CMTimeRange) { for t in tracks { t.removeTimeRange(timeRange) } }
    open func scaleTimeRange(_ timeRange: CMTimeRange, toDuration duration: CMTime) { for t in tracks { t.scaleTimeRange(timeRange, toDuration: duration) } }
}

// NSErrorPointer is RunwayFoundation's.

// swift-corelibs-foundation's NSValue can't hold structs, but it holds byte
// arrays: the values are stored as their bytes, typed by size.
private let timeRangeType = "[\(MemoryLayout<CMTimeRange>.size)C]"
private let timeType = "[\(MemoryLayout<CMTime>.size)C]"

extension NSValue {
    public convenience init(timeRange: CMTimeRange) {
        var r = timeRange
        self.init(bytes: &r, objCType: timeRangeType)
    }
    public convenience init(time: CMTime) {
        var t = time
        self.init(bytes: &t, objCType: timeType)
    }
    public var timeRangeValue: CMTimeRange? {
        guard String(cString: objCType) == timeRangeType else { return nil }
        var r = CMTimeRange()
        getValue(&r)
        return r
    }
    public var timeValue: CMTime? {
        guard String(cString: objCType) == timeType else { return nil }
        var t = CMTime()
        getValue(&t)
        return t
    }
}

// MARK: Audio mixes

open class AVAudioMixInputParameters: NSObject, @unchecked Sendable {
    public internal(set) var trackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var points: [(time: CMTime, volume: Float)] = []
    var ramps: [(range: CMTimeRange, from: Float, to: Float)] = []
    open var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm?
    public override init() { super.init() }

    /// Core Audio's rule: a ramp covers its range; elsewhere the last point
    /// or ramp end before `t` holds; 1 before anything is set.
    func volume(at t: CMTime) -> Float {
        var best: (CMTime, Float)?
        for r in ramps {
            if r.range.containsTime(t) {
                let k = Float((t - r.range.start).seconds / max(r.range.duration.seconds, 1e-9))
                return r.from + (r.to - r.from) * k
            }
            if r.range.end <= t, best.map({ r.range.end >= $0.0 }) ?? true { best = (r.range.end, r.to) }
        }
        for p in points where p.time <= t {
            if best.map({ p.time >= $0.0 }) ?? true { best = (p.time, p.volume) }
        }
        return best?.1 ?? 1
    }

    /// The ramp in effect at `time` (Apple's lookup).
    open func getVolumeRamp(for time: CMTime, startVolume: UnsafeMutablePointer<Float>?, endVolume: UnsafeMutablePointer<Float>?,
                            timeRange: UnsafeMutablePointer<CMTimeRange>?) -> Bool {
        if let r = ramps.first(where: { $0.range.containsTime(time) }) {
            startVolume?.pointee = r.from; endVolume?.pointee = r.to; timeRange?.pointee = r.range
            return true
        }
        // A point holds from its time up to the next change.
        let changes = (points.map { $0.time } + ramps.map { $0.range.start }).sorted()
        if let p = points.filter({ $0.time <= time }).max(by: { $0.time < $1.time }) {
            let next = changes.first { $0 > p.time } ?? .positiveInfinity
            startVolume?.pointee = p.volume; endVolume?.pointee = p.volume
            timeRange?.pointee = CMTimeRange(start: p.time, end: next)
            return true
        }
        return false
    }
}

open class AVMutableAudioMixInputParameters: AVAudioMixInputParameters, @unchecked Sendable {
    public convenience init(track: AVAssetTrack?) {
        self.init()
        trackID = track?.trackID ?? kCMPersistentTrackID_Invalid
    }
    open override var trackID: CMPersistentTrackID {
        get { super.trackID }
        set { super.trackID = newValue }
    }
    open func setVolume(_ volume: Float, at time: CMTime) {
        points.removeAll { $0.time == time }
        points.append((time, volume))
    }
    open func setVolumeRamp(fromStartVolume startVolume: Float, toEndVolume endVolume: Float, timeRange: CMTimeRange) {
        ramps.append((timeRange, startVolume, endVolume))
    }
}

public struct AVAudioTimePitchAlgorithm: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let lowQualityZeroLatency = Self(rawValue: "LowQualityZeroLatency"), timeDomain = Self(rawValue: "TimeDomain")
    public static let spectral = Self(rawValue: "Spectral"), varispeed = Self(rawValue: "Varispeed")
}

open class AVAudioMix: NSObject, @unchecked Sendable {
    var _inputParameters: [AVAudioMixInputParameters] = []
    open var inputParameters: [AVAudioMixInputParameters] { _inputParameters }
    public override init() { super.init() }
    func volume(track: CMPersistentTrackID, at t: CMTime) -> Float {
        _inputParameters.first { $0.trackID == track }?.volume(at: t) ?? 1
    }
}

open class AVMutableAudioMix: AVAudioMix, @unchecked Sendable {
    open override var inputParameters: [AVAudioMixInputParameters] {
        get { _inputParameters }
        set { _inputParameters = newValue }
    }
}
