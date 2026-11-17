// The GStreamer side of AVFoundation on Linux: pipelines (CRunwayGst),
// discovery with a per-file cache, and sequential decoders that turn a file
// into frames or PCM at the times a reader, generator or player asks for.
// On other platforms the same calls fail and the AVFoundation types report
// it through their own error paths.

import CRunwayGst
import CoreMedia
import CoreVideo
import Foundation

package enum Gst {
    package static let available: Bool = rg_init() != 0

    package static func has(_ element: String) -> Bool { rg_has_element(element) != 0 }

    /// The first installed element of `names`.
    package static func first(_ names: [String]) -> String? { names.first { has($0) } }

    package static func uri(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.absoluteString : url.absoluteString
    }

    package static func ns(_ t: CMTime) -> Int64 {
        guard t.isNumeric else { return t.isPositiveInfinity ? Int64.max : 0 }
        return t.convertScale(1_000_000_000, method: .default).value
    }
    package static func ns(_ seconds: Double) -> Int64 { Int64((seconds * 1e9).rounded()) }
    package static func time(_ ns: Int64) -> CMTime { ns < 0 ? .invalid : CMTime(value: ns, timescale: 1_000_000_000) }
}

/// A failure from the media engine, as an NSError in AVFoundation's domain.
package func avError(_ code: AVError.Code, _ message: String) -> NSError {
    NSError(domain: AVFoundationErrorDomain, code: code.rawValue, userInfo: [
        NSLocalizedDescriptionKey: message,
        NSLocalizedFailureReasonErrorKey: message,
    ])
}

/// What a file holds, read once with GstDiscoverer.
struct MediaInfo: Sendable {
    var duration: Double
    var videoCount: Int
    var audioCount: Int
    var width: Int
    var height: Int
    var fps: Double
    var rotation: Int
    var flipped: Bool
    var channels: Int
    var rate: Int
    var videoCodec: String
    var audioCodec: String
    var container: String
    var videoBitrate: Double
    var audioBitrate: Double

    static let cache = MediaInfoCache()

    static func read(_ url: URL) -> Result<MediaInfo, NSError> {
        if let hit = cache.get(url) { return hit }
        let r = probe(url)
        cache.set(url, r)
        return r
    }

    private static func probe(_ url: URL) -> Result<MediaInfo, NSError> {
        guard Gst.available else { return .failure(avError(.mediaServicesWereReset, "Media decoding needs GStreamer, which isn't available here.")) }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) {
            return .failure(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                                    userInfo: [NSLocalizedDescriptionKey: "The file “\(url.lastPathComponent)” couldn’t be opened because there is no such file."]))
        }
        var d = RGDiscovery()
        var err = [CChar](repeating: 0, count: 512)
        let ok = rg_discover(Gst.uri(url), 15_000_000_000, &d, &err, Int32(err.count))
        guard ok != 0 else {
            return .failure(avError(.fileFormatNotRecognized, "Cannot open: \(String(cString: err))"))
        }
        func str<T>(_ t: T) -> String { withUnsafeBytes(of: t) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } }
        return .success(MediaInfo(
            duration: d.duration_ns >= 0 ? Double(d.duration_ns) / 1e9 : 0, videoCount: Int(d.video_count), audioCount: Int(d.audio_count),
            width: Int(d.width), height: Int(d.height), fps: d.fps_d > 0 ? Double(d.fps_n) / Double(d.fps_d) : 0,
            rotation: Int(d.rotation), flipped: d.flipped != 0, channels: Int(d.channels), rate: Int(d.rate),
            videoCodec: str(d.video_codec), audioCodec: str(d.audio_codec), container: str(d.container),
            videoBitrate: Double(d.video_bitrate), audioBitrate: Double(d.audio_bitrate)))
    }
}

/// Discovery results by file (and its modification date), at most 64.
final class MediaInfoCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (Date?, Result<MediaInfo, NSError>)] = [:]
    private func stamp(_ url: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }
    func get(_ url: URL) -> Result<MediaInfo, NSError>? {
        lock.lock(); defer { lock.unlock() }
        guard let (d, r) = entries[url.absoluteString], !url.isFileURL || d == stamp(url) else { return nil }
        return r
    }
    func set(_ url: URL, _ r: Result<MediaInfo, NSError>) {
        let d = url.isFileURL ? stamp(url) : nil
        lock.lock(); defer { lock.unlock() }
        if entries.count >= 64 { entries.removeAll() }
        entries[url.absoluteString] = (d, r)
    }
    func invalidate(_ url: URL) { lock.lock(); entries[url.absoluteString] = nil; lock.unlock() }
}

// MARK: Pipelines

/// One GStreamer pipeline; freed (set to NULL) with the object.
package final class GstPipeline: @unchecked Sendable {
    package let raw: OpaquePointer
    package private(set) var lastError: String?

    package init(_ description: String) throws {
        var err = [CChar](repeating: 0, count: 512)
        guard let p = rg_pipeline_new(description, &err, Int32(err.count)) else {
            throw avError(.mediaServicesWereReset, String(cString: err))
        }
        raw = p
    }
    deinit { rg_pipeline_free(raw) }

    package func set(_ element: String?, _ property: String, _ value: String) { _ = rg_pipeline_set_string(raw, element, property, value) }
    package func set(_ element: String?, _ property: String, int value: Int64) { _ = rg_pipeline_set_int(raw, element, property, value) }
    package func set(_ element: String?, _ property: String, double value: Double) { _ = rg_pipeline_set_double(raw, element, property, value) }
    package func set(_ element: String?, _ property: String, bool value: Bool) { _ = rg_pipeline_set_bool(raw, element, property, value ? 1 : 0) }
    @discardableResult
    package func setBin(_ element: String?, _ property: String, _ description: String) -> Bool {
        var err = [CChar](repeating: 0, count: 512)
        let ok = rg_pipeline_set_bin(raw, element, property, description, &err, Int32(err.count)) != 0
        if !ok { lastError = String(cString: err) }
        return ok
    }

    package enum State: Int32 { case null = 1, ready, paused, playing }

    @discardableResult
    package func state(_ s: State, timeout: Double = 15) -> Bool {
        var err = [CChar](repeating: 0, count: 512)
        let ok = rg_pipeline_set_state(raw, s.rawValue, Int64(timeout * 1e9), &err, Int32(err.count)) != 0
        if !ok { lastError = String(cString: err) }
        return ok
    }
    package func stateAsync(_ s: State) { rg_pipeline_set_state_async(raw, s.rawValue) }
    package var currentState: State { State(rawValue: rg_pipeline_get_state(raw)) ?? .null }

    @discardableResult
    package func seek(_ seconds: Double, accurate: Bool = true, rate: Double = 1) -> Bool {
        rg_pipeline_seek(raw, Gst.ns(max(seconds, 0)), rate, Int32(accurate ? RG_SEEK_ACCURATE : RG_SEEK_KEY | RG_SEEK_SNAP_BEFORE)) != 0
    }
    package var position: Double? { let p = rg_pipeline_position(raw); return p >= 0 ? Double(p) / 1e9 : nil }
    package var duration: Double? { let d = rg_pipeline_duration(raw); return d >= 0 ? Double(d) / 1e9 : nil }

    package enum Pull { case sample(RGFrame), eos, timeout, error }

    package func pull(_ sink: String, timeout: Double = 10, preroll: Bool = false) -> Pull {
        var f = RGFrame()
        switch rg_pipeline_pull(raw, sink, timeout < 0 ? -1 : Int64(timeout * 1e9), preroll ? 1 : 0, &f) {
        case Int32(RG_PULL_SAMPLE): return .sample(f)
        case Int32(RG_PULL_EOS): return .eos
        case Int32(RG_PULL_TIMEOUT): return .timeout
        default:
            _ = poll()
            return .error
        }
    }

    @discardableResult
    package func push(_ src: String, _ bytes: UnsafeRawBufferPointer, pts: Int64, duration: Int64) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return rg_pipeline_push(raw, src, base, bytes.count, pts, duration) != 0
    }
    @discardableResult
    package func endOfStream(_ src: String) -> Bool { rg_pipeline_end_of_stream(raw, src) != 0 }

    package struct Bus: OptionSet { package let rawValue: Int32; package init(rawValue: Int32) { self.rawValue = rawValue }; package static let eos = Bus(rawValue: 1), error = Bus(rawValue: 2), state = Bus(rawValue: 4) }

    package func poll() -> Bus {
        var err = [CChar](repeating: 0, count: 512)
        let f = Bus(rawValue: rg_pipeline_poll(raw, &err, Int32(err.count)))
        if f.contains(.error) { lastError = String(cString: err) }
        return f
    }

    package func waitForEOS(timeout: Double) -> Bool {
        var err = [CChar](repeating: 0, count: 512)
        let ok = rg_pipeline_wait_eos(raw, timeout < 0 ? -1 : Int64(timeout * 1e9), &err, Int32(err.count)) != 0
        if !ok { lastError = String(cString: err) }
        return ok
    }
}

extension RGFrame {
    package var formatName: String { withUnsafeBytes(of: format) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } }
    package var seconds: Double { Double(pts) / 1e9 }
    package var durationSeconds: Double? { duration >= 0 ? Double(duration) / 1e9 : nil }
    package var planeOffsets: [Int] { withUnsafeBytes(of: plane_offset) { Array($0.bindMemory(to: Int32.self)).map(Int.init) } }
    package var planeStrides: [Int] { withUnsafeBytes(of: plane_stride) { Array($0.bindMemory(to: Int32.self)).map(Int.init) } }
}

/// Copies a pulled video frame into a new pixel buffer (BGRA, NV12 or I420).
package func pixelBuffer(from f: RGFrame) -> CVPixelBuffer? {
    let fmt = f.formatName
    let pf: OSType = switch fmt {
    case "NV12": kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    case "I420": kCVPixelFormatType_420YpCbCr8Planar
    case "RGBA": kCVPixelFormatType_32RGBA
    case "ARGB": kCVPixelFormatType_32ARGB
    default: kCVPixelFormatType_32BGRA
    }
    guard let data = f.data, let pb = CVPixelBuffer(width: Int(f.width), height: Int(f.height), pixelFormat: pf) else { return nil }
    let offsets = f.planeOffsets, strides = f.planeStrides
    let planes = max(Int(f.planes), 1)
    for p in 0..<planes {
        guard let dst = pb.baseAddress(ofPlane: p) else { continue }
        let rowBytes = min(strides[p], pb.bytesPerRow(ofPlane: p))
        let rows = pb.height(ofPlane: p)
        for y in 0..<rows {
            let s = offsets[p] + y * strides[p]
            guard s + rowBytes <= f.size else { break }
            (dst + y * pb.bytesPerRow(ofPlane: p)).copyMemory(from: data + s, byteCount: rowBytes)
        }
    }
    return pb
}

// MARK: Sequential decoders

/// Frames of one file's first video stream, decoded in order and found by
/// time: forward steps pull, a step back or a jump seeks. Holds two frames.
final class VideoDecoder: @unchecked Sendable {
    let url: URL
    private var pipeline: GstPipeline?
    private var current: (pts: Double, end: Double, buffer: CVPixelBuffer)?
    private var pending: (pts: Double, end: Double, buffer: CVPixelBuffer)?
    private var eos = false
    private(set) var failure: String?
    private let lock = NSLock()
    let format: String

    init(url: URL, format: String = "BGRA") {
        self.url = url
        self.format = format
    }

    private func open() -> GstPipeline? {
        if let pipeline { return pipeline }
        guard failure == nil else { return nil }
        do {
            let p = try GstPipeline("uridecodebin name=src caps=video/x-raw ! videoconvert ! video/x-raw,format=\(format) ! appsink name=sink sync=false max-buffers=2 enable-last-sample=false")
            p.set("src", "uri", Gst.uri(url))
            guard p.state(.paused) else { failure = p.lastError ?? "Cannot decode"; return nil }
            p.state(.playing)
            pipeline = p
            return p
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    private func next(_ p: GstPipeline) -> (pts: Double, end: Double, buffer: CVPixelBuffer)? {
        if let n = pending { pending = nil; return n }
        guard !eos else { return nil }
        switch p.pull("sink", timeout: 20) {
        case .sample(var f):
            defer { rg_frame_release(&f) }
            guard let pb = pixelBuffer(from: f) else { return nil }
            let pts = f.pts >= 0 ? f.seconds : (current?.end ?? 0)
            return (pts, pts + (f.durationSeconds ?? 1.0 / 30), pb)
        case .eos, .timeout:
            eos = true
            return nil
        case .error:
            failure = p.lastError ?? "decoding failed"
            eos = true
            return nil
        }
    }

    /// The frame showing at `t` seconds (the last one past the end).
    func frame(at t: Double) -> (buffer: CVPixelBuffer, time: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let p = open() else { return nil }
        let eps = 1e-4
        if let c = current, t >= c.pts - eps, t < c.end - eps { return (c.buffer, c.pts) }
        if let c = current, t >= c.end - eps, eos { return (c.buffer, c.pts) }
        let behind = current.map { t < $0.pts - eps } ?? (t > 0.5)
        let farAhead = current.map { t > $0.end + 2 } ?? false
        if behind || farAhead {
            pending = nil
            eos = false
            current = nil
            p.seek(t, accurate: true)
        }
        while true {
            guard let f = next(p) else { return current.map { ($0.buffer, $0.pts) } }
            if let c = current, f.pts > t + eps {
                // Overshot: the earlier frame is the one on screen at t.
                pending = f
                return (c.buffer, c.pts)
            }
            current = f
            if f.end > t + eps { return (f.buffer, f.pts) }
        }
    }

    /// The next decoded frame in order (readers), from wherever the decoder is.
    func nextFrame() -> (buffer: CVPixelBuffer, time: Double, duration: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let p = open(), let f = next(p) else { return nil }
        current = f
        return (f.buffer, f.pts, f.end - f.pts)
    }

    func start(at t: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let p = open() else { return }
        if t > 0.001 {
            pending = nil; current = nil; eos = false
            p.seek(t, accurate: true)
        }
    }
}

/// One file's first audio stream as interleaved Float32 at a fixed rate and
/// channel count, read by time (sequential reads continue, others seek).
final class AudioDecoder: @unchecked Sendable {
    let url: URL
    let rate: Int
    let channels: Int
    private var pipeline: GstPipeline?
    private var buffer: [Float] = []
    /// Time of buffer[0].
    private var bufferStart: Double = 0
    private var eos = false
    private(set) var failure: String?
    private let lock = NSLock()

    init(url: URL, rate: Int, channels: Int) {
        self.url = url
        self.rate = rate
        self.channels = channels
    }

    private func open() -> GstPipeline? {
        if let pipeline { return pipeline }
        guard failure == nil else { return nil }
        do {
            let p = try GstPipeline("uridecodebin name=src caps=audio/x-raw ! audioconvert ! audioresample ! audio/x-raw,format=F32LE,layout=interleaved,rate=\(rate),channels=\(channels) ! appsink name=sink sync=false max-buffers=8 enable-last-sample=false")
            p.set("src", "uri", Gst.uri(url))
            guard p.state(.paused) else { failure = p.lastError ?? "Cannot decode"; return nil }
            p.state(.playing)
            pipeline = p
            return p
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }

    private func pullMore(_ p: GstPipeline) -> Bool {
        guard !eos else { return false }
        switch p.pull("sink", timeout: 20) {
        case .sample(var f):
            defer { rg_frame_release(&f) }
            guard let data = f.data else { return true }
            let n = Int(f.size) / 4
            let start = f.pts >= 0 ? f.seconds : bufferStart + Double(buffer.count / channels) / Double(rate)
            if buffer.isEmpty { bufferStart = start }
            // Fill a gap in the stream with silence; drop an overlap.
            let expected = bufferStart + Double(buffer.count / channels) / Double(rate)
            let gap = Int(((start - expected) * Double(rate)).rounded())
            if gap > 0, gap < rate * 10 { buffer.append(contentsOf: repeatElement(0, count: gap * channels)) }
            let skip = gap < 0 ? min(-gap * channels, n) : 0
            data.withMemoryRebound(to: Float.self, capacity: n) { fp in
                buffer.append(contentsOf: UnsafeBufferPointer(start: fp + skip, count: n - skip))
            }
            return true
        case .eos, .timeout:
            eos = true
            return false
        case .error:
            failure = p.lastError ?? "decoding failed"
            eos = true
            return false
        }
    }

    /// `frames` frames from `t` seconds (silence where there's no sound).
    func read(at t: Double, frames: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        var out = [Float](repeating: 0, count: frames * channels)
        guard frames > 0, let p = open() else { return out }
        let tolerance = 2.0 / Double(rate)
        let bufferEnd = bufferStart + Double(buffer.count / channels) / Double(rate)
        if t < bufferStart - tolerance || t > bufferEnd + 1.0 {
            buffer.removeAll()
            eos = false
            bufferStart = t
            if !p.seek(t, accurate: true) { return out }
        }
        let wantEnd = t + Double(frames) / Double(rate)
        while bufferStart + Double(buffer.count / channels) / Double(rate) < wantEnd - tolerance / 2, pullMore(p) {}
        let offset = Int(((t - bufferStart) * Double(rate)).rounded())
        for i in 0..<frames {
            let src = offset + i
            guard src >= 0 else { continue }
            guard src * channels + channels <= buffer.count else { break }
            for c in 0..<channels { out[i * channels + c] = buffer[src * channels + c] }
        }
        // Keep only what a following read can still use.
        let consumed = max(0, min(offset + frames, buffer.count / channels))
        if consumed > 0 {
            buffer.removeFirst(consumed * channels)
            bufferStart += Double(consumed) / Double(rate)
        }
        return out
    }

    /// The next decoded chunk in order (readers), with its start time.
    func nextChunk() -> (samples: [Float], time: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let p = open() else { return nil }
        if buffer.isEmpty, !pullMore(p) { return nil }
        let out = buffer, start = bufferStart
        bufferStart += Double(buffer.count / channels) / Double(rate)
        buffer.removeAll(keepingCapacity: true)
        return (out, start)
    }
}
