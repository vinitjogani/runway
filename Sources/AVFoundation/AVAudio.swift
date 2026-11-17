// AVFAudio's buffer and file types: AVAudioFormat, AVAudioPCMBuffer and
// AVAudioFile (reading any GStreamer-decodable file as Float32; writing
// linear PCM to WAV directly, compressed formats through AVAssetWriter).

import CoreMedia
import Foundation

public typealias AVAudioFrameCount = UInt32
public typealias AVAudioFramePosition = Int64
public typealias AVAudioChannelCount = UInt32
public typealias AVAudioPacketCount = UInt32

public enum AVAudioCommonFormat: UInt, Sendable { case otherFormat = 0, pcmFormatFloat32, pcmFormatFloat64, pcmFormatInt16, pcmFormatInt32 }

open class AVAudioFormat: NSObject, @unchecked Sendable {
    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    public let commonFormat: AVAudioCommonFormat
    public let isInterleaved: Bool
    private let asbd: UnsafeMutablePointer<AudioStreamBasicDescription>

    public init?(commonFormat format: AVAudioCommonFormat, sampleRate: Double, channels: AVAudioChannelCount, interleaved: Bool) {
        guard sampleRate > 0, channels > 0, format != .otherFormat else { return nil }
        self.sampleRate = sampleRate
        channelCount = channels
        commonFormat = format
        isInterleaved = interleaved
        let bits = switch format { case .pcmFormatFloat64: 64; case .pcmFormatInt16: 16; default: 32 }
        asbd = .allocate(capacity: 1)
        asbd.initialize(to: .pcm(rate: sampleRate, channels: Int(channels), bits: bits,
                                 float: format == .pcmFormatFloat32 || format == .pcmFormatFloat64, nonInterleaved: !interleaved))
        super.init()
    }
    public convenience init?(standardFormatWithSampleRate sampleRate: Double, channels: AVAudioChannelCount) {
        self.init(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)
    }
    public convenience init?(settings: [String: Any]) {
        let pcm = PCMFormat(settings: settings, defaultRate: 44100, defaultChannels: 2)
        let f: AVAudioCommonFormat = pcm.float ? (pcm.bits == 64 ? .pcmFormatFloat64 : .pcmFormatFloat32) : (pcm.bits == 16 ? .pcmFormatInt16 : .pcmFormatInt32)
        let nonInterleaved = settings[AVLinearPCMIsNonInterleaved].flatMap { ($0 as? Bool) ?? ($0 as? NSNumber)?.boolValue } ?? false
        self.init(commonFormat: f, sampleRate: pcm.rate, channels: AVAudioChannelCount(pcm.channels), interleaved: !nonInterleaved)
    }
    public convenience init(streamDescription asbd: UnsafePointer<AudioStreamBasicDescription>) {
        let d = asbd.pointee
        let f: AVAudioCommonFormat = d.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? (d.mBitsPerChannel == 64 ? .pcmFormatFloat64 : .pcmFormatFloat32)
            : (d.mBitsPerChannel == 16 ? .pcmFormatInt16 : .pcmFormatInt32)
        self.init(commonFormat: f, sampleRate: max(d.mSampleRate, 1), channels: max(d.mChannelsPerFrame, 1),
                  interleaved: d.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)!
    }
    deinit { asbd.deallocate() }

    open var streamDescription: UnsafePointer<AudioStreamBasicDescription> { UnsafePointer(asbd) }
    open var isStandard: Bool { commonFormat == .pcmFormatFloat32 && !isInterleaved }
    open var formatDescription: CMAudioFormatDescription { CMFormatDescription(mediaType: kCMMediaType_Audio, subType: kAudioFormatLinearPCM, audio: asbd.pointee) }
    open var settings: [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: Int(channelCount),
         AVLinearPCMBitDepthKey: Int(asbd.pointee.mBitsPerChannel), AVLinearPCMIsFloatKey: commonFormat == .pcmFormatFloat32 || commonFormat == .pcmFormatFloat64,
         AVLinearPCMIsNonInterleaved: !isInterleaved, AVLinearPCMIsBigEndianKey: false]
    }
    var bytesPerSample: Int { Int(asbd.pointee.mBitsPerChannel) / 8 }
}

open class AVAudioBuffer: NSObject, @unchecked Sendable {
    public let format: AVAudioFormat
    init(format: AVAudioFormat) { self.format = format; super.init() }
}

/// PCM in memory: one block per channel (or one interleaved block).
open class AVAudioPCMBuffer: AVAudioBuffer, @unchecked Sendable {
    public let frameCapacity: AVAudioFrameCount
    open var frameLength: AVAudioFrameCount = 0 { didSet { frameLength = min(frameLength, frameCapacity) } }
    private let storage: UnsafeMutableRawPointer
    private let channelPointers: UnsafeMutablePointer<UnsafeMutableRawPointer>
    public var pcmFormat: AVAudioFormat { format }

    public init?(pcmFormat format: AVAudioFormat, frameCapacity: AVAudioFrameCount) {
        self.frameCapacity = frameCapacity
        let ch = Int(format.channelCount), bps = format.bytesPerSample
        let total = max(Int(frameCapacity) * ch * bps, 1)
        storage = .allocate(byteCount: total, alignment: 16)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: total)
        let blocks = format.isInterleaved ? 1 : ch
        channelPointers = .allocate(capacity: max(blocks, 1))
        for i in 0..<blocks { channelPointers[i] = storage + i * Int(frameCapacity) * bps }
        super.init(format: format)
    }
    deinit {
        storage.deallocate()
        channelPointers.deallocate()
    }
    open var stride: Int { format.isInterleaved ? Int(format.channelCount) : 1 }
    open var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? {
        guard format.commonFormat == .pcmFormatFloat32 else { return nil }
        return UnsafeRawPointer(channelPointers).assumingMemoryBound(to: UnsafeMutablePointer<Float>.self)
    }
    open var int16ChannelData: UnsafePointer<UnsafeMutablePointer<Int16>>? {
        guard format.commonFormat == .pcmFormatInt16 else { return nil }
        return UnsafeRawPointer(channelPointers).assumingMemoryBound(to: UnsafeMutablePointer<Int16>.self)
    }
    open var int32ChannelData: UnsafePointer<UnsafeMutablePointer<Int32>>? {
        guard format.commonFormat == .pcmFormatInt32 else { return nil }
        return UnsafeRawPointer(channelPointers).assumingMemoryBound(to: UnsafeMutablePointer<Int32>.self)
    }

    /// Sample `i` of channel `c` as Float.
    func sample(_ c: Int, _ i: Int) -> Float {
        let ch = Int(format.channelCount)
        let idx = format.isInterleaved ? i * ch + c : i
        let base = channelPointers[format.isInterleaved ? 0 : c]
        switch format.commonFormat {
        case .pcmFormatFloat32: return base.assumingMemoryBound(to: Float.self)[idx]
        case .pcmFormatFloat64: return Float(base.assumingMemoryBound(to: Double.self)[idx])
        case .pcmFormatInt16: return Float(base.assumingMemoryBound(to: Int16.self)[idx]) / 32768
        default: return Float(base.assumingMemoryBound(to: Int32.self)[idx]) / 2_147_483_648
        }
    }
    func setSample(_ c: Int, _ i: Int, _ v: Float) {
        let ch = Int(format.channelCount)
        let idx = format.isInterleaved ? i * ch + c : i
        let base = channelPointers[format.isInterleaved ? 0 : c]
        let x = max(-1, min(1, v))
        switch format.commonFormat {
        case .pcmFormatFloat32: base.assumingMemoryBound(to: Float.self)[idx] = v
        case .pcmFormatFloat64: base.assumingMemoryBound(to: Double.self)[idx] = Double(v)
        case .pcmFormatInt16: base.assumingMemoryBound(to: Int16.self)[idx] = Int16((x * 32767).rounded())
        default: base.assumingMemoryBound(to: Int32.self)[idx] = Int32((Double(x) * 2_147_483_647).rounded())
        }
    }
}

/// A sound file: read through GStreamer as Float32, or written (WAV directly, else via AVAssetWriter).
open class AVAudioFile: NSObject, @unchecked Sendable {
    public let url: URL
    public let fileFormat: AVAudioFormat
    public let processingFormat: AVAudioFormat
    open var framePosition: AVAudioFramePosition = 0
    public private(set) var length: AVAudioFramePosition
    private var decoder: AudioDecoder?
    private var wav: FileHandle?
    private var wavFormat: PCMFormat?
    private var dataBytes = 0
    private var assetWriter: (AVAssetWriter, AVAssetWriterInput)?

    public init(forReading fileURL: URL) throws {
        let info = try MediaInfo.read(fileURL).get()
        guard info.audioCount > 0 else { throw NSError(domain: NSOSStatusErrorDomain, code: 1_954_115_647, userInfo: [NSLocalizedDescriptionKey: "The file has no sound."]) }
        url = fileURL
        let rate = Double(info.rate > 0 ? info.rate : 44100), ch = AVAudioChannelCount(max(info.channels, 1))
        fileFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: ch)!
        processingFormat = fileFormat
        length = AVAudioFramePosition((info.duration * rate).rounded())
        decoder = AudioDecoder(url: fileURL, rate: Int(rate), channels: Int(ch))
        super.init()
    }
    public convenience init(forReading fileURL: URL, commonFormat format: AVAudioCommonFormat, interleaved: Bool) throws { try self.init(forReading: fileURL) }

    public init(forWriting fileURL: URL, settings: [String: Any], commonFormat format: AVAudioCommonFormat, interleaved: Bool) throws {
        url = fileURL
        let pcm = PCMFormat(settings: settings, defaultRate: 44100, defaultChannels: 2)
        fileFormat = AVAudioFormat(settings: settings) ?? AVAudioFormat(standardFormatWithSampleRate: pcm.rate, channels: AVAudioChannelCount(pcm.channels))!
        processingFormat = AVAudioFormat(commonFormat: format, sampleRate: pcm.rate, channels: AVAudioChannelCount(pcm.channels), interleaved: interleaved)!
        length = 0
        super.init()
        let id = (settings[AVFormatIDKey] as? NSNumber)?.uint32Value ?? (settings[AVFormatIDKey] as? UInt32) ?? kAudioFormatLinearPCM
        try? FileManager.default.removeItem(at: fileURL)
        if id == kAudioFormatLinearPCM, ["wav", "wave", ""].contains(fileURL.pathExtension.lowercased()) || fileURL.pathExtension.lowercased() == "caf" || fileURL.pathExtension.lowercased() == "aif" {
            var f = pcm
            if !f.float, f.bits == 32 { f.bits = 32 }
            FileManager.default.createFile(atPath: fileURL.path, contents: Self.wavHeader(f, dataBytes: 0))
            wav = try FileHandle(forWritingTo: fileURL)
            wav?.seekToEndOfFile()
            wavFormat = f
        } else {
            let type: AVFileType = fileURL.pathExtension.lowercased() == "wav" ? .wav : .m4a
            let w = try AVAssetWriter(outputURL: fileURL, fileType: type)
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            w.add(i)
            guard w.startWriting() else { throw w.error ?? avError(.unknown, "Couldn't write \(fileURL.lastPathComponent).") }
            w.startSession(atSourceTime: .zero)
            assetWriter = (w, i)
        }
    }
    public convenience init(forWriting fileURL: URL, settings: [String: Any]) throws {
        try self.init(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    deinit { close() }

    static func wavHeader(_ f: PCMFormat, dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(truncatingIfNeeded: v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let block = f.channels * f.bits / 8
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(f.float ? 3 : 1); u16(f.channels); u32(Int(f.rate)); u32(Int(f.rate) * block); u16(block); u16(f.bits)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }

    open func read(into buffer: AVAudioPCMBuffer) throws { try read(into: buffer, frameCount: buffer.frameCapacity) }
    open func read(into buffer: AVAudioPCMBuffer, frameCount frames: AVAudioFrameCount) throws {
        guard let decoder else { throw avError(.operationNotAllowed, "The file is open for writing.") }
        let n = Int(min(frames, buffer.frameCapacity, AVAudioFrameCount(max(length - framePosition, 0))))
        let ch = Int(processingFormat.channelCount)
        let samples = decoder.read(at: Double(framePosition) / processingFormat.sampleRate, frames: n)
        for i in 0..<n { for c in 0..<min(ch, Int(buffer.format.channelCount)) { buffer.setSample(c, i, samples[i * ch + c]) } }
        buffer.frameLength = AVAudioFrameCount(n)
        framePosition += AVAudioFramePosition(n)
    }

    open func write(from buffer: AVAudioPCMBuffer) throws {
        let n = Int(buffer.frameLength), ch = Int(buffer.format.channelCount)
        var interleaved = [Float](repeating: 0, count: n * ch)
        for i in 0..<n { for c in 0..<ch { interleaved[i * ch + c] = buffer.sample(c, i) } }
        if let wav, let f = wavFormat {
            var out = [Float](repeating: 0, count: n * f.channels)
            for i in 0..<n { for c in 0..<f.channels { out[i * f.channels + c] = interleaved[i * ch + min(c, ch - 1)] } }
            let bytes = f.encode(out)
            wav.write(bytes)
            dataBytes += bytes.count
        } else if let (_, input) = assetWriter {
            let f = PCMFormat(rate: buffer.format.sampleRate, channels: ch)
            let sb = CMSampleBuffer(pcm: f.encode(interleaved), format: f.asbd,
                                    presentationTimeStamp: CMTime(value: length, timescale: Int32(buffer.format.sampleRate)))
            _ = input.append(sb)
        }
        length += AVAudioFramePosition(n)
        framePosition = length
    }

    open func close() {
        if let wav, let f = wavFormat {
            wav.seek(toFileOffset: 0)
            wav.write(Self.wavHeader(f, dataBytes: dataBytes))
            try? wav.close()
            self.wav = nil
            MediaInfo.cache.invalidate(url)
        }
        if let (w, i) = assetWriter {
            assetWriter = nil
            i.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            w.finishWriting { done.signal() }
            done.wait()
        }
    }
    open var isOpen: Bool { decoder != nil || wav != nil || assetWriter != nil }
}
