// Reading and writing: AVAssetReader with track, video-composition and
// audio-mix outputs (decoded through FrameComposer / AudioMixer), the image
// generator, AVAssetWriter with inputs and a pixel buffer adaptor (appsrc →
// x264/x265/openh264 + AAC → mp4mux/qtmux/wavenc), and AVAssetExportSession
// (reader + writer).

import CRunwayGst
import CoreMedia
import CoreVideo
import Foundation

// MARK: Settings keys

public let AVVideoCodecKey = "AVVideoCodecKey"
public let AVVideoWidthKey = "AVVideoWidthKey"
public let AVVideoHeightKey = "AVVideoHeightKey"
public let AVVideoCompressionPropertiesKey = "AVVideoCompressionPropertiesKey"
public let AVVideoAverageBitRateKey = "AverageBitRate"
public let AVVideoQualityKey = "Quality"
public let AVVideoMaxKeyFrameIntervalKey = "MaxKeyFrameInterval"
public let AVVideoMaxKeyFrameIntervalDurationKey = "MaxKeyFrameIntervalDuration"
public let AVVideoAllowFrameReorderingKey = "AllowFrameReordering"
public let AVVideoExpectedSourceFrameRateKey = "ExpectedFrameRate"
public let AVVideoAverageNonDroppableFrameRateKey = "AverageNonDroppableFrameRate"
public let AVVideoProfileLevelKey = "ProfileLevel"
public let AVVideoH264EntropyModeKey = "H264EntropyMode"
public let AVVideoScalingModeKey = "AVVideoScalingModeKey"
public let AVVideoPixelAspectRatioKey = "AVVideoPixelAspectRatioKey"
public let AVVideoCleanApertureKey = "AVVideoCleanApertureKey"
public let AVVideoColorPropertiesKey = "AVVideoColorPropertiesKey"
public let AVVideoColorPrimariesKey = "ColorPrimaries"
public let AVVideoTransferFunctionKey = "TransferFunction"
public let AVVideoYCbCrMatrixKey = "YCbCrMatrix"
public let AVVideoColorPrimaries_ITU_R_709_2 = "ITU_R_709_2"
public let AVVideoColorPrimaries_P3_D65 = "P3_D65"
public let AVVideoColorPrimaries_ITU_R_2020 = "ITU_R_2020"
public let AVVideoTransferFunction_ITU_R_709_2 = "ITU_R_709_2"
public let AVVideoTransferFunction_SMPTE_ST_2084_PQ = "SMPTE_ST_2084_PQ"
public let AVVideoTransferFunction_ITU_R_2100_HLG = "ITU_R_2100_HLG"
public let AVVideoYCbCrMatrix_ITU_R_709_2 = "ITU_R_709_2"
public let AVVideoYCbCrMatrix_ITU_R_601_4 = "ITU_R_601_4"
public let AVVideoYCbCrMatrix_ITU_R_2020 = "ITU_R_2020"
public let AVVideoProfileLevelH264HighAutoLevel = "H264_High_AutoLevel"
public let AVVideoProfileLevelH264MainAutoLevel = "H264_Main_AutoLevel"
public let AVVideoProfileLevelH264BaselineAutoLevel = "H264_Baseline_AutoLevel"
public let AVVideoH264EntropyModeCABAC = "CABAC"
public let AVFormatIDKey = "AVFormatIDKey"
public let AVSampleRateKey = "AVSampleRateKey"
public let AVNumberOfChannelsKey = "AVNumberOfChannelsKey"
public let AVChannelLayoutKey = "AVChannelLayoutKey"
public let AVEncoderBitRateKey = "AVEncoderBitRateKey"
public let AVEncoderBitRatePerChannelKey = "AVEncoderBitRatePerChannelKey"
public let AVEncoderBitRateStrategyKey = "AVEncoderBitRateStrategyKey"
public let AVEncoderAudioQualityKey = "AVEncoderAudioQualityKey"
public let AVEncoderBitDepthHintKey = "AVEncoderBitDepthHintKey"
public let AVSampleRateConverterAudioQualityKey = "AVSampleRateConverterAudioQualityKey"
public let AVLinearPCMBitDepthKey = "AVLinearPCMBitDepthKey"
public let AVLinearPCMIsBigEndianKey = "AVLinearPCMIsBigEndianKey"
public let AVLinearPCMIsFloatKey = "AVLinearPCMIsFloatKey"
public let AVLinearPCMIsNonInterleaved = "AVLinearPCMIsNonInterleaved"

public struct AVVideoCodecType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let h264 = AVVideoCodecType("avc1"), hevc = AVVideoCodecType("hvc1"), hevcWithAlpha = AVVideoCodecType("muxa")
    public static let jpeg = AVVideoCodecType("jpeg"), proRes422 = AVVideoCodecType("apcn"), proRes4444 = AVVideoCodecType("ap4h")
    public static let proRes422HQ = AVVideoCodecType("apch"), proRes422LT = AVVideoCodecType("apcs"), proRes422Proxy = AVVideoCodecType("apco")
    public static let appleProRes4444XQ = AVVideoCodecType("ap4x")
}

public enum AVKeyFrameOrderingError: Error {}

/// Reads an output-settings value whatever its bridged type.
func setting<T>(_ d: [String: Any]?, _ key: String, _ type: T.Type) -> T? {
    guard let v = d?[key] else { return nil }
    if let t = v as? T { return t }
    if let n = v as? NSNumber {
        switch type {
        case is Int.Type: return n.intValue as? T
        case is Double.Type: return n.doubleValue as? T
        case is Bool.Type: return n.boolValue as? T
        case is UInt32.Type: return n.uint32Value as? T
        default: return nil
        }
    }
    if let c = v as? AVVideoCodecType, type == String.self { return c.rawValue as? T }
    if let s = v as? String, type == AVVideoCodecType.self { return AVVideoCodecType(s) as? T }
    return nil
}
func number(_ d: [String: Any]?, _ key: String) -> Double? {
    guard let v = d?[key] else { return nil }
    if let n = v as? NSNumber { return n.doubleValue }
    if let i = v as? Int { return Double(i) }
    if let x = v as? Double { return x }
    if let f = v as? Float { return Double(f) }
    if let u = v as? UInt32 { return Double(u) }
    return nil
}
func dict(_ d: [String: Any]?, _ key: String) -> [String: Any]? {
    guard let v = d?[key] else { return nil }
    if let x = v as? [String: Any] { return x }
    if let x = v as? [String: any Sendable] { return x }
    if let x = v as? NSDictionary { return x as? [String: Any] }
    return nil
}

/// What PCM an output or input wants: rate, channels, bits, float, endianness.
struct PCMFormat: Equatable {
    var rate: Double
    var channels: Int
    var bits: Int
    var float: Bool
    var bigEndian: Bool

    init(rate: Double = 48000, channels: Int = 2, bits: Int = 32, float: Bool = true, bigEndian: Bool = false) {
        self.rate = rate; self.channels = channels; self.bits = bits; self.float = float; self.bigEndian = bigEndian
    }
    init(settings s: [String: Any]?, defaultRate: Double, defaultChannels: Int) {
        rate = number(s, AVSampleRateKey) ?? defaultRate
        channels = Int(number(s, AVNumberOfChannelsKey) ?? Double(defaultChannels))
        bits = Int(number(s, AVLinearPCMBitDepthKey) ?? 32)
        let fl = s?[AVLinearPCMIsFloatKey].flatMap { ($0 as? Bool) ?? ($0 as? NSNumber)?.boolValue }
        float = fl ?? (s?[AVLinearPCMBitDepthKey] == nil)
        bigEndian = s?[AVLinearPCMIsBigEndianKey].flatMap { ($0 as? Bool) ?? ($0 as? NSNumber)?.boolValue } ?? false
        if float, bits != 32, bits != 64 { bits = 32 }
        if !float, ![8, 16, 24, 32].contains(bits) { bits = 16 }
    }
    var asbd: AudioStreamBasicDescription { .pcm(rate: rate, channels: channels, bits: bits, float: float, bigEndian: bigEndian) }

    /// Float samples → this format's bytes.
    func encode(_ samples: [Float]) -> Data {
        if float && bits == 32 && !bigEndian { return samples.withUnsafeBufferPointer { Data(buffer: $0) } }
        var d = Data(capacity: samples.count * bits / 8)
        for s in samples {
            let c = max(-1, min(1, s))
            switch (float, bits) {
            case (true, 64):
                var v = Double(c).bitPattern; if bigEndian { v = v.bigEndian }
                withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
            case (true, _):
                var v = c.bitPattern; if bigEndian { v = v.bigEndian }
                withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
            case (false, 8): d.append(UInt8(Int((c * 127).rounded()) + 128))
            case (false, 24):
                let v = Int32((c * 8_388_607).rounded())
                let bytes = [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16)]
                d.append(contentsOf: bigEndian ? bytes.reversed() : bytes)
            case (false, 32):
                var v = Int32((Double(c) * 2_147_483_647).rounded()); v = bigEndian ? v.bigEndian : v.littleEndian
                withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
            default:
                var v = Int16((c * 32767).rounded()); v = bigEndian ? v.bigEndian : v.littleEndian
                withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
            }
        }
        return d
    }
}

// MARK: Audio mixing

/// The audible tracks of an asset summed through their edit lists, each at
/// its audio-mix volume, as interleaved Float32.
final class AudioMixer: @unchecked Sendable {
    let tracks: [AVAssetTrack]
    let mix: AVAudioMix?
    let rate: Int
    let channels: Int
    private var decoders: [String: AudioDecoder] = [:]

    init(tracks: [AVAssetTrack], mix: AVAudioMix?, rate: Int, channels: Int) {
        self.tracks = tracks
        self.mix = mix
        self.rate = rate
        self.channels = channels
    }

    var duration: Double { tracks.map { $0.timeRange.end.seconds }.max() ?? 0 }

    /// Pieces of `track` over output time [a, b): (source url, source start, output start, frames).
    private func pieces(_ track: AVAssetTrack, _ a: Double, _ b: Double) -> [(URL, Double, Double, Double)] {
        if let c = track as? AVCompositionTrack {
            var out: [(URL, Double, Double, Double)] = []
            for s in c._segments where !s.isEmpty {
                let tr = s.timeMapping.target, sr = s.timeMapping.source
                let s0 = max(a, tr.start.seconds), s1 = min(b, tr.end.seconds)
                guard s1 > s0, let src = s.sourceTrack else { continue }
                // Speed changes aren't resampled: the source plays from its mapped start.
                let srcStart = sr.start.seconds + (s0 - tr.start.seconds) * (sr.duration.seconds / max(tr.duration.seconds, 1e-9))
                for (u, st, ot, d) in pieces(src, srcStart, srcStart + (s1 - s0)) {
                    out.append((u, st, ot - srcStart + s0, d))
                }
            }
            return out
        }
        guard let url = track.sourceURL else { return [] }
        let r = track.timeRange
        let s0 = max(a, r.start.seconds), s1 = min(b, r.end.seconds)
        return s1 > s0 ? [(url, s0, s0, s1 - s0)] : []
    }

    /// `frames` frames of the mix from output time `t`.
    func render(at t: Double, frames: Int) -> [Float] {
        var out = [Float](repeating: 0, count: frames * channels)
        let end = t + Double(frames) / Double(rate)
        for track in tracks {
            for (url, srcStart, outStart, length) in pieces(track, t, end) {
                let key = "\(track.trackID)|\(url.absoluteString)"
                let dec: AudioDecoder
                if let d = decoders[key] { dec = d } else {
                    dec = AudioDecoder(url: url, rate: rate, channels: channels)
                    decoders[key] = dec
                }
                let offset = Int(((outStart - t) * Double(rate)).rounded())
                let n = min(Int((length * Double(rate)).rounded()), frames - offset)
                guard n > 0, offset >= 0 else { continue }
                let samples = dec.read(at: srcStart, frames: n)
                // Volume per 64-frame block (ramps are smooth at that scale).
                var i = 0
                while i < n {
                    let block = min(64, n - i)
                    let at = CMTime(seconds: outStart + Double(i) / Double(rate), preferredTimescale: 48000)
                    let v = mix?.volume(track: track.trackID, at: at) ?? 1
                    for f in i..<(i + block) {
                        for c in 0..<channels { out[(offset + f) * channels + c] += samples[f * channels + c] * v }
                    }
                    i += block
                }
            }
        }
        return out
    }
}

// MARK: Reader

open class AVAssetReaderOutput: NSObject, @unchecked Sendable {
    open var mediaType: AVMediaType { .video }
    open var alwaysCopiesSampleData = true
    open var supportsRandomAccess = false
    weak var reader: AVAssetReader?
    var started = false
    var done = false

    open func copyNextSampleBuffer() -> CMSampleBuffer? { nil }
    open func reset(forReadingTimeRanges timeRanges: [NSValue]) {}
    open func markConfigurationAsFinal() {}
    func start(_ range: CMTimeRange) {}
    func finish(failed error: Error? = nil) {
        done = true
        reader?.outputFinished(error)
    }
    var range: CMTimeRange { reader?.effectiveRange ?? .zero }
    var cancelled: Bool { reader?.status == .cancelled }
}

open class AVAssetReaderTrackOutput: AVAssetReaderOutput, @unchecked Sendable {
    public let track: AVAssetTrack
    public let outputSettings: [String: Any]?
    private var video: VideoDecoder?
    private var mixer: AudioMixer?
    private var pcm = PCMFormat()
    private var cursor: Double = 0
    open override var mediaType: AVMediaType { track.mediaType }

    public init(track: AVAssetTrack, outputSettings: [String: Any]?) {
        self.track = track
        self.outputSettings = outputSettings
        super.init()
    }

    override func start(_ range: CMTimeRange) {
        cursor = range.start.seconds
        if track.mediaType == .audio {
            let fmt = track._formatDescriptions.first?.audioStreamBasicDescription
            pcm = PCMFormat(settings: outputSettings, defaultRate: fmt.map { $0.mSampleRate > 0 ? $0.mSampleRate : 48000 } ?? 48000,
                            defaultChannels: fmt.map { max(Int($0.mChannelsPerFrame), 1) } ?? 2)
            mixer = AudioMixer(tracks: [track], mix: nil, rate: Int(pcm.rate), channels: pcm.channels)
        } else if let url = track.sourceURL {
            let f = (outputSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
                ?? (outputSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType)
            let fmt = f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? "NV12" : "BGRA"
            let d = VideoDecoder(url: url, format: fmt)
            d.start(at: range.start.seconds)
            video = d
        }
    }

    open override func copyNextSampleBuffer() -> CMSampleBuffer? {
        guard started, !done, !cancelled else { return nil }
        let end = range.end.seconds
        if let mixer {
            guard cursor < end - 1e-9 else { finish(); return nil }
            let frames = min(Int(pcm.rate / 10), Int(((end - cursor) * pcm.rate).rounded(.up)))
            guard frames > 0 else { finish(); return nil }
            let samples = mixer.render(at: cursor, frames: frames)
            let sb = CMSampleBuffer(pcm: pcm.encode(samples), format: pcm.asbd,
                                    presentationTimeStamp: CMTime(seconds: cursor, preferredTimescale: Int32(pcm.rate)))
            cursor += Double(frames) / pcm.rate
            return sb
        }
        if let video {
            guard let f = video.nextFrame(), f.time < end - 1e-6 else {
                finish(failed: video.failure.map { avError(.decodeFailed, $0) })
                return nil
            }
            return CMSampleBuffer(imageBuffer: f.buffer, timing: CMSampleTimingInfo(duration: CMTime(seconds: f.duration, preferredTimescale: 600_000),
                                                                                     presentationTimeStamp: CMTime(seconds: f.time, preferredTimescale: 600_000),
                                                                                     decodeTimeStamp: .invalid))
        }
        // A composition video track: its frames at the track's rate.
        let fps = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 30)
        guard cursor < end - 1e-6 else { finish(); return nil }
        let composer = FrameComposer(asset: track.asset ?? AVAsset(), composition: nil)
        let t = CMTime(seconds: cursor, preferredTimescale: 600)
        cursor += 1 / fps
        guard let pb = composer.sourceFrame(track, at: t) else { return copyNextSampleBuffer() }
        return CMSampleBuffer(imageBuffer: pb, timing: CMSampleTimingInfo(duration: CMTime(seconds: 1 / fps, preferredTimescale: 600),
                                                                           presentationTimeStamp: t, decodeTimeStamp: .invalid))
    }
}

open class AVAssetReaderVideoCompositionOutput: AVAssetReaderOutput, @unchecked Sendable {
    public let videoTracks: [AVAssetTrack]
    public let videoSettings: [String: Any]?
    open var videoComposition: AVVideoComposition?
    open var customVideoCompositor: (any AVVideoCompositing)? { nil }
    private var composer: FrameComposer?
    private var frameIndex: Int64 = 0
    open override var mediaType: AVMediaType { .video }

    public init(videoTracks: [AVAssetTrack], videoSettings: [String: Any]?) {
        self.videoTracks = videoTracks
        self.videoSettings = videoSettings
        super.init()
    }

    override func start(_ range: CMTimeRange) {
        guard let asset = reader?.asset else { return }
        composer = FrameComposer(asset: asset, composition: videoComposition)
        frameIndex = 0
    }

    open override func copyNextSampleBuffer() -> CMSampleBuffer? {
        guard started, !done, !cancelled, let composer else { return nil }
        let step = composer.frameDuration
        let t = range.start + CMTimeMultiply(step, multiplier: Int32(clamping: frameIndex))
        guard t < range.end else { finish(); return nil }
        frameIndex += 1
        guard let pb = composer.frame(at: t) else {
            finish(failed: composer.lastError ?? avError(.decodeFailed, "No frame at \(t.seconds) s."))
            return nil
        }
        return CMSampleBuffer(imageBuffer: pb, timing: CMSampleTimingInfo(duration: step, presentationTimeStamp: t, decodeTimeStamp: .invalid))
    }
}

open class AVAssetReaderAudioMixOutput: AVAssetReaderOutput, @unchecked Sendable {
    public let audioTracks: [AVAssetTrack]
    public let audioSettings: [String: Any]?
    open var audioMix: AVAudioMix?
    open var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm = .spectral
    private var mixer: AudioMixer?
    private var pcm = PCMFormat()
    private var cursor: Double = 0
    open override var mediaType: AVMediaType { .audio }

    public init(audioTracks: [AVAssetTrack], audioSettings: [String: Any]?) {
        self.audioTracks = audioTracks
        self.audioSettings = audioSettings
        super.init()
    }

    override func start(_ range: CMTimeRange) {
        pcm = PCMFormat(settings: audioSettings, defaultRate: 44100, defaultChannels: 2)
        mixer = AudioMixer(tracks: audioTracks, mix: audioMix, rate: Int(pcm.rate), channels: pcm.channels)
        cursor = range.start.seconds
    }

    open override func copyNextSampleBuffer() -> CMSampleBuffer? {
        guard started, !done, !cancelled, let mixer else { return nil }
        let end = range.end.seconds
        let frames = min(Int(pcm.rate / 10), Int(((end - cursor) * pcm.rate).rounded()))
        guard frames > 0 else { finish(); return nil }
        let samples = mixer.render(at: cursor, frames: frames)
        let sb = CMSampleBuffer(pcm: pcm.encode(samples), format: pcm.asbd, presentationTimeStamp: CMTime(value: Int64((cursor * pcm.rate).rounded()), timescale: Int32(pcm.rate)))
        cursor += Double(frames) / pcm.rate
        return sb
    }
}

open class AVAssetReaderSampleReferenceOutput: AVAssetReaderOutput, @unchecked Sendable {
    public let track: AVAssetTrack
    public init(track: AVAssetTrack) { self.track = track; super.init() }
}

open class AVAssetReader: NSObject, @unchecked Sendable {
    public enum Status: Int, Sendable { case unknown = 0, reading, completed, failed, cancelled }
    public let asset: AVAsset
    public private(set) var outputs: [AVAssetReaderOutput] = []
    public private(set) var status: Status = .unknown
    public private(set) var error: Error?
    open var timeRange: CMTimeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)
    private let lock = NSLock()

    public init(asset: AVAsset) throws {
        self.asset = asset
        super.init()
        if !(asset is AVComposition) {
            _ = try asset.loadedTracks()
        }
    }

    var effectiveRange: CMTimeRange {
        let d = asset.duration
        let end = timeRange.duration.isNumeric ? CMTimeMinimum(timeRange.end, d) : d
        return CMTimeRange(start: timeRange.start.isNumeric ? timeRange.start : .zero, end: end)
    }

    open func canAdd(_ output: AVAssetReaderOutput) -> Bool { status == .unknown && output.reader == nil }
    open func add(_ output: AVAssetReaderOutput) {
        guard canAdd(output) else { return }
        output.reader = self
        outputs.append(output)
    }

    open func startReading() -> Bool {
        guard status == .unknown else { return false }
        guard Gst.available else {
            status = .failed
            error = avError(.mediaServicesWereReset, "Media decoding needs GStreamer, which isn't available here.")
            return false
        }
        status = .reading
        let r = effectiveRange
        for o in outputs {
            o.start(r)
            o.started = true
        }
        return true
    }

    open func cancelReading() { lock.lock(); if status == .reading || status == .unknown { status = .cancelled }; lock.unlock() }

    func outputFinished(_ e: Error?) {
        lock.lock(); defer { lock.unlock() }
        guard status == .reading else { return }
        if let e { status = .failed; error = e; return }
        if outputs.allSatisfy(\.done) { status = .completed }
    }
}

// MARK: Image generator

open class AVAssetImageGenerator: NSObject, @unchecked Sendable {
    public let asset: AVAsset
    open var appliesPreferredTrackTransform = false
    open var maximumSize: CGSize = .zero
    open var apertureMode: AVAssetImageGenerator.ApertureMode? = .cleanAperture
    open var videoComposition: AVVideoComposition? { didSet { composer = nil } }
    open var requestedTimeToleranceBefore: CMTime = .positiveInfinity
    open var requestedTimeToleranceAfter: CMTime = .positiveInfinity
    open var dynamicRangePolicy: AVAssetImageGenerator.DynamicRangePolicy = .forceSDR
    private var composer: FrameComposer?
    private let lock = NSLock()

    public struct ApertureMode: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let cleanAperture = ApertureMode(rawValue: "CleanAperture"), productionAperture = ApertureMode(rawValue: "ProductionAperture")
        public static let encodedPixels = ApertureMode(rawValue: "EncodedPixels")
    }
    public struct DynamicRangePolicy: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let forceSDR = DynamicRangePolicy(rawValue: "ForceSDR"), matchSource = DynamicRangePolicy(rawValue: "MatchSource")
    }
    public enum Result: Int, Sendable { case succeeded = 0, failed, cancelled }
    public typealias CompletionHandler = @Sendable (CMTime, CGImage?, CMTime, AVAssetImageGenerator.Result, Error?) -> Void

    public init(asset: AVAsset) {
        self.asset = asset
        super.init()
    }

    /// The picture at `requestedTime` and the time it's actually from.
    open func copyCGImage(at requestedTime: CMTime, actualTime: UnsafeMutablePointer<CMTime>?) throws -> CGImage {
        lock.lock(); defer { lock.unlock() }
        guard Gst.available else { throw avError(.mediaServicesWereReset, "Media decoding needs GStreamer, which isn't available here.") }
        let c = composer ?? FrameComposer(asset: asset, composition: videoComposition)
        composer = c
        var t = requestedTime.isNumeric ? requestedTime : .zero
        // A video composition's timeline runs to its last instruction, which
        // may outlast every track (a span drawn from no source at all).
        var d = asset.duration
        if let end = videoComposition?.instructions.map(\.timeRange.end).max(), end.isNumeric, end > d { d = end }
        if d > .zero, t >= d { t = d - CMTime(value: 1, timescale: 600) }
        guard let pb = c.frame(at: t) else {
            throw c.lastError ?? avError(.noImageAtTime, "There is no picture at \(requestedTime.seconds) s.")
        }
        actualTime?.pointee = t
        var image = CGImage(width: pb.width, height: pb.height, rgba: pb.rgba(), hasAlpha: videoComposition != nil)
        if appliesPreferredTrackTransform, videoComposition == nil, let track = asset.allTracks.first(where: { $0.mediaType == .video }) {
            image = oriented(image, track.preferredTransform)
        }
        if maximumSize.width > 0 || maximumSize.height > 0 {
            let kw = maximumSize.width > 0 ? maximumSize.width / CGFloat(image.width) : .infinity
            let kh = maximumSize.height > 0 ? maximumSize.height / CGFloat(image.height) : .infinity
            let k = min(kw, kh)
            if k < 1 {
                let w = max(Int((CGFloat(image.width) * k).rounded()), 1), h = max(Int((CGFloat(image.height) * k).rounded()), 1)
                if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                    if let s = ctx.makeImage() { image = s }
                }
            }
        }
        return image
    }

    /// The macOS 13+ async form.
    public func image(at time: CMTime) async throws -> (image: CGImage, actualTime: CMTime) {
        try await detached {
            var actual = CMTime.invalid
            let img = try self.copyCGImage(at: time, actualTime: &actual)
            return (img, actual)
        }
    }

    open func generateCGImagesAsynchronously(forTimes requestedTimes: [NSValue], completionHandler handler: @escaping CompletionHandler) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for v in requestedTimes {
                let t = v.timeValue ?? .zero
                var actual = CMTime.invalid
                do {
                    let img = try copyCGImage(at: t, actualTime: &actual)
                    handler(t, img, actual, .succeeded, nil)
                } catch {
                    handler(t, nil, actual, .failed, error)
                }
            }
        }
    }
    open func cancelAllCGImageGeneration() {}
}

/// Rotates/flips `image` by a track's preferred transform.
func oriented(_ image: CGImage, _ t: CGAffineTransform) -> CGImage {
    if t.isIdentity { return image }
    let w = image.width, h = image.height
    let r = CGRect(x: 0, y: 0, width: w, height: h).applying(t)
    let ow = Int(abs(r.width).rounded()), oh = Int(abs(r.height).rounded())
    guard ow > 0, oh > 0 else { return image }
    var out = [UInt8](repeating: 0, count: ow * oh * 4)
    let inv = t.concatenating(CGAffineTransform(translationX: -r.minX, y: -r.minY)).inverted()
    for y in 0..<oh {
        for x in 0..<ow {
            let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inv)
            let sx = Int(p.x), sy = Int(p.y)
            guard sx >= 0, sy >= 0, sx < w, sy < h else { continue }
            let s = (sy * w + sx) * 4, d = (y * ow + x) * 4
            out[d] = image.pixels[s]; out[d + 1] = image.pixels[s + 1]; out[d + 2] = image.pixels[s + 2]; out[d + 3] = image.pixels[s + 3]
        }
    }
    return CGImage(width: ow, height: oh, rgba: out, hasAlpha: image.hasAlpha)
}

// MARK: Writer

open class AVAssetWriterInput: NSObject, @unchecked Sendable {
    public let mediaType: AVMediaType
    public let outputSettings: [String: Any]?
    public let sourceFormatHint: CMFormatDescription?
    open var expectsMediaDataInRealTime = false
    open var transform: CGAffineTransform = .identity
    open var naturalSize: CGSize = .zero
    open var mediaTimeScale: CMTimeScale = 0
    open var preferredVolume: Float = 1
    open var marksOutputTrackAsEnabled = true
    open var performsMultiPassEncodingIfSupported = false
    open var languageCode: String?
    open var metadata: [AVMetadataItem] = []
    weak var writer: AVAssetWriter?
    var name = ""
    var capsSet = false
    private(set) var finished = false
    private var pending: (() -> Void)?
    private let lock = NSLock()

    public init(mediaType: AVMediaType, outputSettings: [String: Any]?, sourceFormatHint: CMFormatDescription?) {
        self.mediaType = mediaType
        self.outputSettings = outputSettings
        self.sourceFormatHint = sourceFormatHint
        super.init()
    }
    public convenience init(mediaType: AVMediaType, outputSettings: [String: Any]?) {
        self.init(mediaType: mediaType, outputSettings: outputSettings, sourceFormatHint: nil)
    }

    open var isReadyForMoreMediaData: Bool {
        lock.lock(); defer { lock.unlock() }
        return !finished && writer?.status == .writing
    }

    open func append(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard isReadyForMoreMediaData, let w = writer else { return false }
        return w.write(sampleBuffer, from: self)
    }

    open func markAsFinished() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        writer?.inputFinished(self)
    }

    /// Calls `block` on `queue` until the input is finished or the writer
    /// stops (appends block while the encoder catches up: that's the pacing).
    open func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            while isReadyForMoreMediaData {
                block()
                if !isReadyForMoreMediaData { break }
                usleep(500)
            }
        }
    }

    open func canAddTrackAssociation(withTrackOf input: AVAssetWriterInput, type: String) -> Bool { false }
    open func addTrackAssociation(withTrackOf input: AVAssetWriterInput, type: String) {}
}

open class AVAssetWriterInputPixelBufferAdaptor: NSObject, @unchecked Sendable {
    public let assetWriterInput: AVAssetWriterInput
    public let sourcePixelBufferAttributes: [String: Any]?
    public init(assetWriterInput input: AVAssetWriterInput, sourcePixelBufferAttributes: [String: Any]?) {
        assetWriterInput = input
        self.sourcePixelBufferAttributes = sourcePixelBufferAttributes
        super.init()
    }
    /// Buffers of the input's size and the source format (BGRA by default), once writing has started.
    open var pixelBufferPool: CVPixelBufferPool? {
        guard assetWriterInput.writer?.status == .writing else { return nil }
        let a = sourcePixelBufferAttributes
        let w = a.flatMap { number($0, kCVPixelBufferWidthKey as String) }.map(Int.init) ?? Int(number(assetWriterInput.outputSettings, AVVideoWidthKey) ?? 0)
        let h = a.flatMap { number($0, kCVPixelBufferHeightKey as String) }.map(Int.init) ?? Int(number(assetWriterInput.outputSettings, AVVideoHeightKey) ?? 0)
        let f = a.flatMap { number($0, kCVPixelBufferPixelFormatTypeKey as String) }.map { OSType($0) } ?? kCVPixelFormatType_32BGRA
        guard w > 0, h > 0 else { return nil }
        return CVPixelBufferPool(width: w, height: h, pixelFormat: f, attributes: a ?? [:])
    }
    open func append(_ pixelBuffer: CVPixelBuffer, withPresentationTime presentationTime: CMTime) -> Bool {
        assetWriterInput.append(CMSampleBuffer(imageBuffer: pixelBuffer, timing: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)))
    }
}

open class AVAssetWriter: NSObject, @unchecked Sendable {
    public enum Status: Int, Sendable { case unknown = 0, writing, completed, failed, cancelled }
    public let outputURL: URL
    public let outputFileType: AVFileType
    public private(set) var inputs: [AVAssetWriterInput] = []
    public private(set) var status: Status = .unknown
    public private(set) var error: Error?
    open var shouldOptimizeForNetworkUse = false
    open var movieTimeScale: CMTimeScale = 0
    open var movieFragmentInterval: CMTime = .invalid
    open var metadata: [AVMetadataItem] = []
    open var directoryForTemporaryFiles: URL?
    open var availableMediaTypes: [AVMediaType] { outputFileType == .m4a || outputFileType == .wav ? [.audio] : [.video, .audio] }
    private var pipeline: GstPipeline?
    private var sessionStart: CMTime = .invalid
    private var sessionEnd: CMTime = .invalid
    private let lock = NSLock()
    private var lastVideoPTS: [ObjectIdentifier: Int64] = [:]

    public init(outputURL: URL, fileType: AVFileType) throws {
        guard outputURL.isFileURL else { throw avError(.invalidOutputURLPathExtension, "Only file URLs can be written.") }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            throw NSError(domain: NSCocoaErrorDomain, code: 516, userInfo: [NSLocalizedDescriptionKey: "The file “\(outputURL.lastPathComponent)” already exists."])
        }
        guard [.mp4, .mov, .m4v, .m4a, .wav].contains(fileType) else {
            throw avError(.formatUnsupported, "Writing \(fileType.rawValue) files isn't supported here (MP4, MOV, M4V, M4A and WAV are).")
        }
        self.outputURL = outputURL
        outputFileType = fileType
        super.init()
    }
    public convenience init(url: URL, fileType: AVFileType) throws { try self.init(outputURL: url, fileType: fileType) }

    open func canAdd(_ input: AVAssetWriterInput) -> Bool {
        status == .unknown && input.writer == nil && availableMediaTypes.contains(input.mediaType)
            && !(outputFileType == .wav && !inputs.isEmpty)
    }
    open func add(_ input: AVAssetWriterInput) {
        guard canAdd(input) else { return }
        input.writer = self
        input.name = "in\(inputs.count)"
        inputs.append(input)
    }
    open func canApply(outputSettings: [String: Any]?, forMediaType mediaType: AVMediaType) -> Bool { availableMediaTypes.contains(mediaType) }

    /// The encoder for an input's settings.
    private func videoBranch(_ i: AVAssetWriterInput, realtime: Bool) throws -> String {
        let s = i.outputSettings
        let codec = setting(s, AVVideoCodecKey, AVVideoCodecType.self) ?? setting(s, AVVideoCodecKey, String.self).map { AVVideoCodecType(rawValue: $0) } ?? .h264
        let props = dict(s, AVVideoCompressionPropertiesKey)
        let w = Int(number(s, AVVideoWidthKey) ?? 1280), h = Int(number(s, AVVideoHeightKey) ?? 720)
        let fps = number(props, AVVideoExpectedSourceFrameRateKey) ?? 30
        let bitrate = number(props, AVVideoAverageBitRateKey) ?? Double(w * h) * fps * 0.1
        let keyint = Int(number(props, AVVideoMaxKeyFrameIntervalKey) ?? (number(props, AVVideoMaxKeyFrameIntervalDurationKey).map { $0 * fps } ?? fps * 2))
        let reorder = props?[AVVideoAllowFrameReorderingKey].flatMap { ($0 as? Bool) ?? ($0 as? NSNumber)?.boolValue } ?? !realtime
        let kbps = max(Int(bitrate / 1000), 100)
        let scale = "videoconvert ! videoscale ! video/x-raw,format=I420,width=\(w),height=\(h),colorimetry=bt709"
        func h264() throws -> String {
            if Gst.has("x264enc") {
                return "\(scale) ! x264enc bitrate=\(kbps) key-int-max=\(max(keyint, 1)) speed-preset=\(realtime ? "ultrafast" : "veryfast")\(realtime ? " tune=zerolatency" : "") bframes=\(reorder ? 2 : 0) ! h264parse"
            }
            if Gst.has("openh264enc") { return "\(scale) ! openh264enc bitrate=\(kbps * 1000) gop-size=\(max(keyint, 1)) ! h264parse" }
            if Gst.has("avenc_h264_omx") { return "\(scale) ! avenc_h264_omx bitrate=\(kbps * 1000) ! h264parse" }
            throw avError(.encoderNotFound, "No H.264 encoder is installed (x264enc or openh264enc: GStreamer's ugly/bad plugins).")
        }
        switch codec {
        case .hevc, .hevcWithAlpha:
            if Gst.has("x265enc") {
                return "\(scale) ! x265enc bitrate=\(kbps) key-int-max=\(max(keyint, 1)) speed-preset=\(realtime ? "ultrafast" : "veryfast")\(realtime ? " tune=zerolatency" : "") ! h265parse"
            }
            return try h264() // No HEVC encoder: H.264 plays everywhere HEVC would.
        case .jpeg:
            guard Gst.has("jpegenc") else { throw avError(.encoderNotFound, "No JPEG encoder is installed.") }
            return "videoconvert ! videoscale ! video/x-raw,width=\(w),height=\(h) ! jpegenc"
        case .proRes422, .proRes422HQ, .proRes422LT, .proRes422Proxy, .proRes4444, .appleProRes4444XQ:
            if Gst.has("avenc_prores_ks") { return "videoconvert ! videoscale ! video/x-raw,format=Y444_10LE,width=\(w),height=\(h) ! avenc_prores_ks" }
            return try h264()
        default:
            return try h264()
        }
    }

    private func audioBranch(_ i: AVAssetWriterInput) throws -> String {
        let s = i.outputSettings
        let format = (s?[AVFormatIDKey] as? NSNumber)?.uint32Value ?? (s?[AVFormatIDKey] as? UInt32) ?? kAudioFormatMPEG4AAC
        let rate = Int(number(s, AVSampleRateKey) ?? 48000), channels = Int(number(s, AVNumberOfChannelsKey) ?? 2)
        let bitrate = Int(number(s, AVEncoderBitRateKey) ?? 128_000)
        let raw = "audioconvert ! audioresample ! audio/x-raw,rate=\(rate),channels=\(channels)"
        if outputFileType == .wav || format == kAudioFormatLinearPCM {
            let pcm = PCMFormat(settings: s, defaultRate: Double(rate), defaultChannels: channels)
            let f = pcm.float ? "F\(pcm.bits)LE" : (pcm.bits == 8 ? "U8" : "S\(pcm.bits)\(pcm.bigEndian ? "BE" : "LE")")
            return "audioconvert ! audioresample ! audio/x-raw,format=\(f),rate=\(rate),channels=\(channels)"
        }
        switch format {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE:
            if Gst.has("avenc_aac") { return "\(raw) ! avenc_aac bitrate=\(bitrate) ! aacparse" }
            if Gst.has("fdkaacenc") { return "\(raw) ! fdkaacenc bitrate=\(bitrate) ! aacparse" }
            if Gst.has("voaacenc") { return "\(raw) ! voaacenc bitrate=\(bitrate) ! aacparse" }
            throw avError(.encoderNotFound, "No AAC encoder is installed (avenc_aac: gstreamer1.0-libav).")
        case kAudioFormatOpus:
            guard Gst.has("opusenc") else { throw avError(.encoderNotFound, "No Opus encoder is installed.") }
            return "\(raw) ! opusenc bitrate=\(bitrate)"
        case kAudioFormatAppleLossless:
            guard Gst.has("avenc_alac") else { throw avError(.encoderNotFound, "No ALAC encoder is installed.") }
            return "\(raw) ! avenc_alac"
        case kAudioFormatFLAC:
            guard Gst.has("flacenc") else { throw avError(.encoderNotFound, "No FLAC encoder is installed.") }
            return "\(raw) ! flacenc ! flacparse"
        default:
            throw avError(.unsupportedOutputSettings, "That audio format can't be written here.")
        }
    }

    open func startWriting() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard status == .unknown else { return false }
        guard Gst.available else {
            fail(avError(.mediaServicesWereReset, "Media encoding needs GStreamer, which isn't available here."))
            return false
        }
        do {
            let realtime = inputs.contains { $0.expectsMediaDataInRealTime }
            var desc = ""
            if outputFileType == .wav {
                guard let a = inputs.first else { throw avError(.unsupportedOutputSettings, "A WAV file needs an audio input.") }
                desc = "appsrc name=\(a.name) format=time block=true max-bytes=2000000 ! queue ! \(try audioBranch(a)) ! wavenc ! filesink name=out"
            } else {
                let mux = outputFileType == .mov ? "qtmux" : "mp4mux"
                desc = "\(mux) name=mux\(outputFileType == .mov ? "" : " faststart=\(shouldOptimizeForNetworkUse)") ! filesink name=out"
                for i in inputs {
                    let branch = i.mediaType == .video ? try videoBranch(i, realtime: realtime) : try audioBranch(i)
                    desc += " appsrc name=\(i.name) format=time block=true max-bytes=\(i.mediaType == .video ? 40_000_000 : 2_000_000) ! queue max-size-time=0 max-size-bytes=0 max-size-buffers=8 ! \(branch) ! queue ! mux."
                }
            }
            let p = try GstPipeline(desc)
            p.set("out", "location", outputURL.path)
            // The pipeline prerolls only once data arrives: start it without waiting.
            p.stateAsync(.playing)
            if p.poll().contains(.error) { throw avError(.unknown, p.lastError ?? "The encoder could not start.") }
            pipeline = p
            status = .writing
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fail(_ e: Error) {
        status = .failed
        error = e
        pipeline = nil
        try? FileManager.default.removeItem(at: outputURL)
    }

    open func startSession(atSourceTime startTime: CMTime) { sessionStart = startTime }
    open func endSession(atSourceTime endTime: CMTime) { sessionEnd = endTime }

    /// Writes a video input's `transform` into its track header's matrix
    /// (qtmux/mp4mux write the identity), as preferredTransform reads it back.
    /// Tracks are matched in order: the nth video tkhd (one with a size) is
    /// the nth video input.
    static func writeTrackMatrices(_ url: URL, _ transforms: [CGAffineTransform]) {
        guard transforms.contains(where: { !$0.isIdentity }),
              let fh = try? FileHandle(forUpdating: url), let data = try? fh.readToEnd() else { return }
        defer { try? fh.close() }
        let b = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        func fixed(_ v: CGFloat, _ bits: Int) -> [UInt8] {
            let x = UInt32(bitPattern: Int32((v * CGFloat(1 << bits)).rounded()))
            return [UInt8(x >> 24), UInt8(x >> 16 & 0xff), UInt8(x >> 8 & 0xff), UInt8(x & 0xff)]
        }
        // Walk moov → trak → tkhd.
        var video = 0
        func walk(_ start: Int, _ end: Int) {
            var i = start
            while i + 8 <= end {
                var size = u32(i)
                let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
                var header = 8
                if size == 1, i + 16 <= end { size = Int(u32(i + 8)) << 32 | u32(i + 12); header = 16 }
                if size == 0 { size = end - i }
                guard size >= header, i + size <= end else { return }
                if type == "moov" || type == "trak" { walk(i + header, i + size) }
                if type == "tkhd", i + header + 84 <= end {
                    let v1 = b[i + header] == 1
                    let matrix = i + header + 4 + (v1 ? 32 : 20) + 16
                    let w = u32(matrix + 36), h = u32(matrix + 40)
                    if w > 0, h > 0 {
                        if video < transforms.count, !transforms[video].isIdentity {
                            let t = transforms[video]
                            let m = fixed(t.a, 16) + fixed(t.b, 16) + fixed(0, 30) + fixed(t.c, 16) + fixed(t.d, 16) + fixed(0, 30)
                                + fixed(t.tx, 16) + fixed(t.ty, 16) + fixed(1, 30)
                            try? fh.seek(toOffset: UInt64(matrix))
                            try? fh.write(contentsOf: Data(m))
                        }
                        video += 1
                    }
                }
                i += size
            }
        }
        walk(0, b.count)
    }

    /// Pushes one sample into its input's appsrc, in the source's own pixel/PCM layout.
    func write(_ sb: CMSampleBuffer, from input: AVAssetWriterInput) -> Bool {
        guard let p = pipeline, status == .writing else { return false }
        let start = sessionStart.isNumeric ? sessionStart : .zero
        let pts = sb.presentationTimeStamp
        guard pts.isNumeric else { return false }
        if sessionEnd.isNumeric, pts >= sessionEnd { return true }
        let rel = Gst.ns(pts - start)
        guard rel >= 0 else { return true } // before the session: dropped, as AVAssetWriter does
        if let pb = sb.imageBuffer as? CVPixelBuffer {
            let (format, bytes) = packed(pb)
            if !input.capsSet {
                let fps = number(dict(input.outputSettings, AVVideoCompressionPropertiesKey), AVVideoExpectedSourceFrameRateKey) ?? 30
                p.set(input.name, "caps", "video/x-raw,format=\(format),width=\(pb.width),height=\(pb.height),framerate=\(Int(fps.rounded()))/1")
                input.capsSet = true
            }
            // Strictly increasing timestamps (an encoder rejects repeats).
            lock.lock()
            let key = ObjectIdentifier(input)
            if let last = lastVideoPTS[key], rel <= last { lock.unlock(); return true }
            lastVideoPTS[key] = rel
            lock.unlock()
            let dur = sb.duration.isNumeric ? Gst.ns(sb.duration) : -1
            let ok = bytes.withUnsafeBytes { p.push(input.name, $0, pts: rel, duration: dur) }
            return ok || checkFailure()
        }
        guard let block = sb.dataBuffer, let asbd = sb.formatDescription?.audioStreamBasicDescription else { return false }
        if !input.capsSet {
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let be = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
            let bits = Int(asbd.mBitsPerChannel)
            let f = isFloat ? "F\(bits)\(be ? "BE" : "LE")" : (bits == 8 ? "U8" : "S\(bits)\(be ? "BE" : "LE")")
            p.set(input.name, "caps", "audio/x-raw,format=\(f),layout=interleaved,rate=\(Int(asbd.mSampleRate)),channels=\(asbd.mChannelsPerFrame)")
            input.capsSet = true
        }
        let frames = asbd.mBytesPerFrame > 0 ? block.dataLength / Int(asbd.mBytesPerFrame) : sb.numSamples
        let dur = Int64(Double(frames) / max(asbd.mSampleRate, 1) * 1e9)
        let ok = p.push(input.name, UnsafeRawBufferPointer(start: block.data, count: block.dataLength), pts: rel, duration: dur)
        return ok || checkFailure()
    }

    private func checkFailure() -> Bool {
        guard let p = pipeline else { return false }
        if p.poll().contains(.error) {
            lock.lock()
            status = .failed
            error = avError(.unknown, p.lastError ?? "Encoding failed.")
            lock.unlock()
        }
        return false
    }

    /// Tight rows in GStreamer's default layout for the buffer's format.
    private func packed(_ pb: CVPixelBuffer) -> (String, Data) {
        let w = pb.width, h = pb.height
        switch pb.pixelFormatType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            let stride = (w + 3) & ~3, ch = (h + 1) / 2
            var d = Data(count: stride * ((h + 1) & ~1) + stride * ch)
            d.withUnsafeMutableBytes { dst in
                let b = dst.baseAddress!
                for y in 0..<h { memcpy(b + y * stride, pb.baseAddress(ofPlane: 0)! + y * pb.bytesPerRow(ofPlane: 0), w) }
                let uv = b + stride * ((h + 1) & ~1)
                for y in 0..<ch { memcpy(uv + y * stride, pb.baseAddress(ofPlane: 1)! + y * pb.bytesPerRow(ofPlane: 1), min(stride, pb.bytesPerRow(ofPlane: 1))) }
            }
            return ("NV12", d)
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA, kCVPixelFormatType_32ARGB:
            let name = pb.pixelFormatType == kCVPixelFormatType_32BGRA ? "BGRA" : (pb.pixelFormatType == kCVPixelFormatType_32RGBA ? "RGBA" : "ARGB")
            if pb.bytesPerRow == w * 4 { return (name, Data(bytes: pb.base, count: w * h * 4)) }
            var d = Data(count: w * h * 4)
            d.withUnsafeMutableBytes { dst in for y in 0..<h { memcpy(dst.baseAddress! + y * w * 4, pb.base + y * pb.bytesPerRow, w * 4) } }
            return (name, d)
        default:
            let rgba = pb.rgba()
            return ("RGBA", rgba.withUnsafeBufferPointer { Data(buffer: $0) })
        }
    }

    func inputFinished(_ input: AVAssetWriterInput) {
        guard let p = pipeline else { return }
        if !input.capsSet {
            // Nothing was appended: give the stream a format so the muxer can close it.
            p.set(input.name, "caps", input.mediaType == .video ? "video/x-raw,format=BGRA,width=16,height=16,framerate=30/1"
                                                                  : "audio/x-raw,format=F32LE,layout=interleaved,rate=48000,channels=2")
            input.capsSet = true
        }
        p.endOfStream(input.name)
    }

    open func finishWriting(completionHandler handler: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            finishNow()
            handler()
        }
    }

    public func finishWriting() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finishWriting { c.resume() }
        }
    }

    private func finishNow() {
        guard status == .writing, let p = pipeline else { return }
        for i in inputs where !i.finished { i.markAsFinished() }
        let ok = p.waitForEOS(timeout: 600)
        p.state(.null)
        lock.lock()
        pipeline = nil
        if ok, status == .writing {
            if outputFileType != .wav {
                Self.writeTrackMatrices(outputURL, inputs.filter { $0.mediaType == .video }.map(\.transform))
            }
            status = .completed
        } else if status == .writing {
            status = .failed
            error = avError(.unknown, p.lastError ?? "The file couldn't be finished.")
        }
        lock.unlock()
        MediaInfo.cache.invalidate(outputURL)
    }

    open func cancelWriting() {
        lock.lock()
        let wasWriting = status == .writing || status == .unknown
        if wasWriting { status = .cancelled }
        let p = pipeline
        pipeline = nil
        lock.unlock()
        p?.state(.null)
        if wasWriting { try? FileManager.default.removeItem(at: outputURL) }
    }
}

// MARK: Export sessions

public let AVAssetExportPresetLowQuality = "AVAssetExportPresetLowQuality"
public let AVAssetExportPresetMediumQuality = "AVAssetExportPresetMediumQuality"
public let AVAssetExportPresetHighestQuality = "AVAssetExportPresetHighestQuality"
public let AVAssetExportPresetHEVCHighestQuality = "AVAssetExportPresetHEVCHighestQuality"
public let AVAssetExportPresetHEVCHighestQualityWithAlpha = "AVAssetExportPresetHEVCHighestQualityWithAlpha"
public let AVAssetExportPreset640x480 = "AVAssetExportPreset640x480"
public let AVAssetExportPreset960x540 = "AVAssetExportPreset960x540"
public let AVAssetExportPreset1280x720 = "AVAssetExportPreset1280x720"
public let AVAssetExportPreset1920x1080 = "AVAssetExportPreset1920x1080"
public let AVAssetExportPreset3840x2160 = "AVAssetExportPreset3840x2160"
public let AVAssetExportPresetHEVC1920x1080 = "AVAssetExportPresetHEVC1920x1080"
public let AVAssetExportPresetHEVC3840x2160 = "AVAssetExportPresetHEVC3840x2160"
public let AVAssetExportPresetAppleM4A = "AVAssetExportPresetAppleM4A"
public let AVAssetExportPresetPassthrough = "AVAssetExportPresetPassthrough"

/// Exports by reading the asset (its composition, audio mix and video
/// composition applied) and encoding it again: MP4/MOV as H.264 or HEVC + AAC, M4A as AAC.
open class AVAssetExportSession: NSObject, @unchecked Sendable {
    public enum Status: Int, Sendable { case unknown = 0, waiting, exporting, completed, failed, cancelled }
    public let asset: AVAsset
    public let presetName: String
    open var outputURL: URL?
    open var outputFileType: AVFileType?
    open var timeRange: CMTimeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)
    open var videoComposition: AVVideoComposition?
    open var audioMix: AVAudioMix?
    open var shouldOptimizeForNetworkUse = false
    open var metadata: [AVMetadataItem]?
    open var fileLengthLimit: Int64 = 0
    open var canPerformMultiplePassesOverSourceMediaData = false
    public private(set) var status: Status = .unknown
    public private(set) var error: Error?
    public private(set) var progress: Float = 0
    private var cancelled = false
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?

    public init?(asset: AVAsset, presetName: String) {
        guard AVAssetExportSession.allExportPresets().contains(presetName) else { return nil }
        self.asset = asset
        self.presetName = presetName
        super.init()
    }

    open class func allExportPresets() -> [String] {
        [AVAssetExportPresetLowQuality, AVAssetExportPresetMediumQuality, AVAssetExportPresetHighestQuality, AVAssetExportPresetHEVCHighestQuality,
         AVAssetExportPresetHEVCHighestQualityWithAlpha, AVAssetExportPreset640x480, AVAssetExportPreset960x540, AVAssetExportPreset1280x720,
         AVAssetExportPreset1920x1080, AVAssetExportPreset3840x2160, AVAssetExportPresetHEVC1920x1080, AVAssetExportPresetHEVC3840x2160,
         AVAssetExportPresetAppleM4A, AVAssetExportPresetPassthrough]
    }
    open class func exportPresets(compatibleWith asset: AVAsset) -> [String] { allExportPresets() }
    open class func determineCompatibility(ofExportPreset presetName: String, with asset: AVAsset, outputFileType: AVFileType?,
                                           completionHandler handler: @escaping @Sendable (Bool) -> Void) {
        handler(allExportPresets().contains(presetName))
    }
    public static func compatibility(ofExportPreset presetName: String, with asset: AVAsset, outputFileType: AVFileType?) async -> Bool {
        allExportPresets().contains(presetName)
    }
    open var supportedFileTypes: [AVFileType] { presetName == AVAssetExportPresetAppleM4A ? [.m4a] : [.mp4, .mov, .m4v] }
    open func determineCompatibleFileTypes(completionHandler handler: @escaping @Sendable ([AVFileType]) -> Void) { handler(supportedFileTypes) }
    open var estimatedOutputFileLength: Int64 { 0 }

    open func cancelExport() {
        cancelled = true
        reader?.cancelReading()
    }

    open func exportAsynchronously(completionHandler handler: @escaping @Sendable () -> Void) {
        status = .waiting
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            run()
            handler()
        }
    }

    /// macOS 15's form.
    public func export(to url: URL, as fileType: AVFileType) async throws {
        outputURL = url
        outputFileType = fileType
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in exportAsynchronously { c.resume() } }
        if status == .cancelled { throw CancellationError() }
        if let error { throw error }
    }

    private func target(_ natural: CGSize) -> (CGSize, AVVideoCodecType, Double) {
        func fit(_ w: CGFloat, _ h: CGFloat) -> CGSize {
            let k = min(1, min(w / max(natural.width, 1), h / max(natural.height, 1)))
            return CGSize(width: (natural.width * k / 2).rounded() * 2, height: (natural.height * k / 2).rounded() * 2)
        }
        switch presetName {
        case AVAssetExportPresetLowQuality: return (fit(640, 360), .h264, 0.05)
        case AVAssetExportPresetMediumQuality: return (fit(960, 540), .h264, 0.08)
        case AVAssetExportPreset640x480: return (fit(640, 480), .h264, 0.1)
        case AVAssetExportPreset960x540: return (fit(960, 540), .h264, 0.1)
        case AVAssetExportPreset1280x720: return (fit(1280, 720), .h264, 0.1)
        case AVAssetExportPreset1920x1080: return (fit(1920, 1080), .h264, 0.1)
        case AVAssetExportPreset3840x2160: return (fit(3840, 2160), .h264, 0.1)
        case AVAssetExportPresetHEVC1920x1080: return (fit(1920, 1080), .hevc, 0.07)
        case AVAssetExportPresetHEVC3840x2160: return (fit(3840, 2160), .hevc, 0.07)
        case AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHEVCHighestQualityWithAlpha: return (fit(.infinity, .infinity), .hevc, 0.1)
        default: return (fit(.infinity, .infinity), .h264, 0.14)
        }
    }

    private func run() {
        guard let url = outputURL else { return fail(avError(.exportFailed, "No output URL was set.")) }
        let type = outputFileType ?? (presetName == AVAssetExportPresetAppleM4A ? .m4a : .mp4)
        status = .exporting
        do {
            let r = try AVAssetReader(asset: asset)
            r.timeRange = timeRange
            reader = r
            let vtracks = asset.allTracks.filter { $0.mediaType == .video }
            let atracks = asset.allTracks.filter { $0.mediaType == .audio }
            let wantVideo = type != .m4a && !vtracks.isEmpty
            let natural = videoComposition?.renderSize ?? FrameComposer(asset: asset, composition: nil).renderSize
            let (size, codec, bpp) = target(natural == .zero ? CGSize(width: 1280, height: 720) : natural)
            var vout: AVAssetReaderVideoCompositionOutput?
            if wantVideo {
                let o = AVAssetReaderVideoCompositionOutput(videoTracks: vtracks, videoSettings: nil)
                o.videoComposition = videoComposition
                r.add(o)
                vout = o
            }
            var aout: AVAssetReaderAudioMixOutput?
            if !atracks.isEmpty {
                let o = AVAssetReaderAudioMixOutput(audioTracks: atracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
                o.audioMix = audioMix
                r.add(o)
                aout = o
            }
            guard vout != nil || aout != nil else { throw avError(.noSourceTrack, "There's nothing to export.") }
            let w = try AVAssetWriter(outputURL: url, fileType: type)
            w.shouldOptimizeForNetworkUse = shouldOptimizeForNetworkUse
            writer = w
            let fps = vout.map { _ in 1 / max(FrameComposer(asset: asset, composition: videoComposition).frameDuration.seconds, 1e-3) } ?? 30
            var vin: AVAssetWriterInput?
            if vout != nil {
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(size.width * size.height) * fps * bpp),
                                                      AVVideoExpectedSourceFrameRateKey: fps] as [String: Any],
                ])
                w.add(i)
                vin = i
            }
            var ain: AVAssetWriterInput?
            if aout != nil {
                let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
                w.add(i)
                ain = i
            }
            guard r.startReading() else { throw r.error ?? avError(.exportFailed, "Couldn't read the asset.") }
            guard w.startWriting() else { throw w.error ?? avError(.exportFailed, "Couldn't start the encoder.") }
            w.startSession(atSourceTime: r.effectiveRange.start)
            let total = max(r.effectiveRange.duration.seconds, 1e-3)
            // Video and audio on their own threads (the muxer interleaves them).
            let group = DispatchGroup()
            if let vin, let vout {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    while !cancelled, let s = vout.copyNextSampleBuffer() {
                        progress = Float(min((s.presentationTimeStamp - r.effectiveRange.start).seconds / total, 0.99))
                        if !vin.append(s) { break }
                    }
                    vin.markAsFinished()
                    group.leave()
                }
            }
            if let ain, let aout {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    while !cancelled, let s = aout.copyNextSampleBuffer() { if !ain.append(s) { break } }
                    ain.markAsFinished()
                    group.leave()
                }
            }
            group.wait()
            if cancelled {
                w.cancelWriting()
                status = .cancelled
                return
            }
            if r.status == .failed { w.cancelWriting(); throw r.error ?? avError(.exportFailed, "Reading failed.") }
            let done = DispatchSemaphore(value: 0)
            w.finishWriting { done.signal() }
            done.wait()
            guard w.status == .completed else { throw w.error ?? avError(.exportFailed, "Writing failed.") }
            progress = 1
            status = .completed
        } catch {
            fail(error)
        }
    }

    private func fail(_ e: Error) {
        status = .failed
        error = e
    }
}
