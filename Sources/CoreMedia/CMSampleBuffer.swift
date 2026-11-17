// CoreMedia buffers and clocks: CMSampleBuffer (an image buffer or a block
// of PCM/compressed bytes with timing), CMFormatDescription, CMBlockBuffer,
// the host clock and the audio format types (CoreAudioTypes) media code
// reads through Core Media.

import Foundation

public typealias CMItemCount = Int
public typealias CMItemIndex = Int
public typealias CMPersistentTrackID = Int32
public let kCMPersistentTrackID_Invalid: CMPersistentTrackID = 0

// MARK: Audio types (CoreAudioTypes)

public typealias AudioFormatID = UInt32
public typealias AudioFormatFlags = UInt32
public typealias AudioChannelLayoutTag = UInt32
public let kAudioFormatLinearPCM = AudioFormatID(fourCC: "lpcm")
public let kAudioFormatMPEG4AAC = AudioFormatID(fourCC: "aac ")
public let kAudioFormatMPEG4AAC_HE = AudioFormatID(fourCC: "aach")
public let kAudioFormatAppleLossless = AudioFormatID(fourCC: "alac")
public let kAudioFormatOpus = AudioFormatID(fourCC: "opus")
public let kAudioFormatFLAC = AudioFormatID(fourCC: "flac")
public let kAudioFormatMPEGLayer3 = AudioFormatID(fourCC: ".mp3")
public let kAudioFormatULaw = AudioFormatID(fourCC: "ulaw")
public let kAudioFormatALaw = AudioFormatID(fourCC: "alaw")
public let kAudioFormatAC3 = AudioFormatID(fourCC: "ac-3")
public let kAudioFormatFlagIsFloat: AudioFormatFlags = 1 << 0
public let kAudioFormatFlagIsBigEndian: AudioFormatFlags = 1 << 1
public let kAudioFormatFlagIsSignedInteger: AudioFormatFlags = 1 << 2
public let kAudioFormatFlagIsPacked: AudioFormatFlags = 1 << 3
public let kAudioFormatFlagIsNonInterleaved: AudioFormatFlags = 1 << 5
public let kLinearPCMFormatFlagIsFloat = kAudioFormatFlagIsFloat
public let kLinearPCMFormatFlagIsSignedInteger = kAudioFormatFlagIsSignedInteger
public let kLinearPCMFormatFlagIsPacked = kAudioFormatFlagIsPacked
public let kLinearPCMFormatFlagIsNonInterleaved = kAudioFormatFlagIsNonInterleaved
public let kAudioFormatFlagsNativeFloatPacked: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
public let kAudioChannelLayoutTag_Mono: AudioChannelLayoutTag = (100 << 16) | 1
public let kAudioChannelLayoutTag_Stereo: AudioChannelLayoutTag = (101 << 16) | 2

public struct AudioStreamBasicDescription: Sendable, Equatable {
    public var mSampleRate: Float64
    public var mFormatID: AudioFormatID
    public var mFormatFlags: AudioFormatFlags
    public var mBytesPerPacket: UInt32
    public var mFramesPerPacket: UInt32
    public var mBytesPerFrame: UInt32
    public var mChannelsPerFrame: UInt32
    public var mBitsPerChannel: UInt32
    public var mReserved: UInt32
    public init() { self.init(mSampleRate: 0, mFormatID: 0, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 0, mBitsPerChannel: 0, mReserved: 0) }
    public init(mSampleRate: Float64, mFormatID: AudioFormatID, mFormatFlags: AudioFormatFlags, mBytesPerPacket: UInt32, mFramesPerPacket: UInt32,
                mBytesPerFrame: UInt32, mChannelsPerFrame: UInt32, mBitsPerChannel: UInt32, mReserved: UInt32) {
        self.mSampleRate = mSampleRate; self.mFormatID = mFormatID; self.mFormatFlags = mFormatFlags; self.mBytesPerPacket = mBytesPerPacket
        self.mFramesPerPacket = mFramesPerPacket; self.mBytesPerFrame = mBytesPerFrame; self.mChannelsPerFrame = mChannelsPerFrame
        self.mBitsPerChannel = mBitsPerChannel; self.mReserved = mReserved
    }
    /// Interleaved linear PCM.
    public static func pcm(rate: Double, channels: Int, bits: Int, float: Bool, bigEndian: Bool = false, nonInterleaved: Bool = false) -> Self {
        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked | (float ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
        if bigEndian { flags |= kAudioFormatFlagIsBigEndian }
        if nonInterleaved { flags |= kAudioFormatFlagIsNonInterleaved }
        let frame = UInt32(bits / 8 * (nonInterleaved ? 1 : channels))
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: frame,
                                           mFramesPerPacket: 1, mBytesPerFrame: frame, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bits), mReserved: 0)
    }
}

// MARK: Format descriptions

public typealias CMMediaType = FourCharCode
public let kCMMediaType_Video = CMMediaType(fourCC: "vide")
public let kCMMediaType_Audio = CMMediaType(fourCC: "soun")
public let kCMMediaType_Muxed = CMMediaType(fourCC: "muxx")
public let kCMMediaType_Text = CMMediaType(fourCC: "text")
public let kCMMediaType_Subtitle = CMMediaType(fourCC: "sbtl")
public let kCMMediaType_Metadata = CMMediaType(fourCC: "meta")
public typealias CMVideoCodecType = FourCharCode
public let kCMVideoCodecType_H264 = CMVideoCodecType(fourCC: "avc1")
public let kCMVideoCodecType_HEVC = CMVideoCodecType(fourCC: "hvc1")
public let kCMVideoCodecType_AppleProRes422 = CMVideoCodecType(fourCC: "apcn")
public let kCMVideoCodecType_JPEG = CMVideoCodecType(fourCC: "jpeg")
public let kCMVideoCodecType_VP9 = CMVideoCodecType(fourCC: "vp09")
public let kCMVideoCodecType_AV1 = CMVideoCodecType(fourCC: "av01")

public struct CMVideoDimensions: Sendable, Equatable {
    public var width: Int32
    public var height: Int32
    public init(width: Int32, height: Int32) { self.width = width; self.height = height }
    public init() { self.init(width: 0, height: 0) }
}

public final class CMFormatDescription: @unchecked Sendable, Equatable {
    public let mediaType: CMMediaType
    public let mediaSubType: FourCharCode
    public let dimensions: CMVideoDimensions
    private let asbdStorage: UnsafeMutablePointer<AudioStreamBasicDescription>?
    public let extensions: [String: Any]

    public init(mediaType: CMMediaType, subType: FourCharCode, dimensions: CMVideoDimensions = .init(),
                audio: AudioStreamBasicDescription? = nil, extensions: [String: Any] = [:]) {
        self.mediaType = mediaType
        mediaSubType = subType
        self.dimensions = dimensions
        self.extensions = extensions
        if let audio {
            asbdStorage = .allocate(capacity: 1)
            asbdStorage!.initialize(to: audio)
        } else {
            asbdStorage = nil
        }
    }
    deinit { asbdStorage?.deallocate() }

    public var audioStreamBasicDescription: AudioStreamBasicDescription? { asbdStorage?.pointee }
    var asbdPointer: UnsafePointer<AudioStreamBasicDescription>? { asbdStorage.map { UnsafePointer($0) } }

    public enum MediaType: Sendable { case video, audio, other }
    public var presentationDimensions: CGSize { CGSize(width: Int(dimensions.width), height: Int(dimensions.height)) }

    public static func == (a: CMFormatDescription, b: CMFormatDescription) -> Bool {
        a.mediaType == b.mediaType && a.mediaSubType == b.mediaSubType && a.dimensions == b.dimensions
            && a.audioStreamBasicDescription == b.audioStreamBasicDescription
    }
}
public typealias CMVideoFormatDescription = CMFormatDescription
public typealias CMAudioFormatDescription = CMFormatDescription

public func CMFormatDescriptionGetMediaType(_ d: CMFormatDescription) -> CMMediaType { d.mediaType }
public func CMFormatDescriptionGetMediaSubType(_ d: CMFormatDescription) -> FourCharCode { d.mediaSubType }
public func CMFormatDescriptionGetExtensions(_ d: CMFormatDescription) -> CFDictionary? { d.extensions as NSDictionary }
public func CMVideoFormatDescriptionGetDimensions(_ d: CMFormatDescription) -> CMVideoDimensions { d.dimensions }
public func CMVideoFormatDescriptionGetPresentationDimensions(_ d: CMFormatDescription, usePixelAspectRatio: Bool, useCleanAperture: Bool) -> CGSize {
    d.presentationDimensions
}
public func CMAudioFormatDescriptionGetStreamBasicDescription(_ d: CMFormatDescription) -> UnsafePointer<AudioStreamBasicDescription>? { d.asbdPointer }

@discardableResult
public func CMVideoFormatDescriptionCreate(allocator: AnyObject?, codecType: CMVideoCodecType, width: Int32, height: Int32, extensions: CFDictionary?,
                                           formatDescriptionOut: UnsafeMutablePointer<CMFormatDescription?>) -> OSStatus {
    formatDescriptionOut.pointee = CMFormatDescription(mediaType: kCMMediaType_Video, subType: codecType, dimensions: .init(width: width, height: height),
                                                       extensions: (extensions as? [String: Any]) ?? [:])
    return noErr
}
@discardableResult
public func CMVideoFormatDescriptionCreateForImageBuffer(allocator: AnyObject?, imageBuffer: CVImageBuffer,
                                                         formatDescriptionOut: UnsafeMutablePointer<CMFormatDescription?>) -> OSStatus {
    guard let pb = imageBuffer as? CVPixelBuffer else { return -12710 }
    formatDescriptionOut.pointee = CMFormatDescription(mediaType: kCMMediaType_Video, subType: pb.pixelFormatType,
                                                       dimensions: .init(width: Int32(pb.width), height: Int32(pb.height)))
    return noErr
}
@discardableResult
public func CMAudioFormatDescriptionCreate(allocator: AnyObject?, asbd: UnsafePointer<AudioStreamBasicDescription>, layoutSize: Int, layout: UnsafeRawPointer?,
                                           magicCookieSize: Int, magicCookie: UnsafeRawPointer?, extensions: CFDictionary?,
                                           formatDescriptionOut: UnsafeMutablePointer<CMFormatDescription?>) -> OSStatus {
    formatDescriptionOut.pointee = CMFormatDescription(mediaType: kCMMediaType_Audio, subType: asbd.pointee.mFormatID, audio: asbd.pointee)
    return noErr
}

// MARK: Block buffers

/// Contiguous bytes (one allocation, owned).
public final class CMBlockBuffer: @unchecked Sendable {
    public let data: UnsafeMutableRawPointer
    public let dataLength: Int
    public init(length: Int) {
        dataLength = length
        data = .allocate(byteCount: max(length, 1), alignment: 16)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: max(length, 1))
    }
    public convenience init(copying bytes: UnsafeRawBufferPointer) {
        self.init(length: bytes.count)
        if let b = bytes.baseAddress, bytes.count > 0 { data.copyMemory(from: b, byteCount: bytes.count) }
    }
    public convenience init(data d: Data) { self.init(length: d.count); d.withUnsafeBytes { if let b = $0.baseAddress, d.count > 0 { data.copyMemory(from: b, byteCount: d.count) } } }
    deinit { data.deallocate() }
    public var bytes: Data { Data(bytes: data, count: dataLength) }
}

public let kCMBlockBufferNoErr: OSStatus = 0
public let kCMBlockBufferBadOffsetParameterErr: OSStatus = -12703
public let kCMBlockBufferBadLengthParameterErr: OSStatus = -12704

public func CMBlockBufferGetDataLength(_ b: CMBlockBuffer) -> Int { b.dataLength }
@discardableResult
public func CMBlockBufferGetDataPointer(_ b: CMBlockBuffer, atOffset offset: Int, lengthAtOffsetOut: UnsafeMutablePointer<Int>?,
                                        totalLengthOut: UnsafeMutablePointer<Int>?, dataPointerOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OSStatus {
    guard offset >= 0, offset <= b.dataLength else { return kCMBlockBufferBadOffsetParameterErr }
    lengthAtOffsetOut?.pointee = b.dataLength - offset
    totalLengthOut?.pointee = b.dataLength
    dataPointerOut?.pointee = (b.data + offset).assumingMemoryBound(to: CChar.self)
    return noErr
}
@discardableResult
public func CMBlockBufferCopyDataBytes(_ b: CMBlockBuffer, atOffset offset: Int, dataLength: Int, destination: UnsafeMutableRawPointer) -> OSStatus {
    guard offset >= 0, dataLength >= 0, offset + dataLength <= b.dataLength else { return kCMBlockBufferBadLengthParameterErr }
    destination.copyMemory(from: b.data + offset, byteCount: dataLength)
    return noErr
}
public func CMBlockBufferIsRangeContiguous(_ b: CMBlockBuffer, atOffset: Int, length: Int) -> Bool { true }
@discardableResult
public func CMBlockBufferCreateWithMemoryBlock(allocator: AnyObject?, memoryBlock: UnsafeMutableRawPointer?, blockLength: Int, blockAllocator: AnyObject?,
                                               customBlockSource: UnsafeRawPointer?, offsetToData: Int, dataLength: Int, flags: UInt32,
                                               blockBufferOut: UnsafeMutablePointer<CMBlockBuffer?>) -> OSStatus {
    let b = CMBlockBuffer(length: dataLength)
    if let m = memoryBlock { b.data.copyMemory(from: m + offsetToData, byteCount: dataLength) }
    blockBufferOut.pointee = b
    return noErr
}
@discardableResult
public func CMBlockBufferReplaceDataBytes(with source: UnsafeRawPointer, blockBuffer: CMBlockBuffer, offsetIntoDestination: Int, dataLength: Int) -> OSStatus {
    guard offsetIntoDestination + dataLength <= blockBuffer.dataLength else { return kCMBlockBufferBadLengthParameterErr }
    (blockBuffer.data + offsetIntoDestination).copyMemory(from: source, byteCount: dataLength)
    return noErr
}

// MARK: Sample buffers

public struct CMSampleTimingInfo: Sendable, Equatable {
    public var duration: CMTime
    public var presentationTimeStamp: CMTime
    public var decodeTimeStamp: CMTime
    public init() { self.init(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid) }
    public init(duration: CMTime, presentationTimeStamp: CMTime, decodeTimeStamp: CMTime) {
        self.duration = duration
        self.presentationTimeStamp = presentationTimeStamp
        self.decodeTimeStamp = decodeTimeStamp
    }
    public static let invalid = CMSampleTimingInfo()
}

/// One video frame (an image buffer) or a run of audio frames (a block of
/// PCM described by its format), with timing and attachments.
public final class CMSampleBuffer: @unchecked Sendable {
    public let formatDescription: CMFormatDescription?
    public let imageBuffer: CVImageBuffer?
    public let dataBuffer: CMBlockBuffer?
    public let numSamples: Int
    public private(set) var timing: [CMSampleTimingInfo]
    public var dataIsReady: Bool
    private var sampleAttachments: NSArray?
    private let lock = NSLock()

    public init(imageBuffer: CVImageBuffer, formatDescription: CMFormatDescription? = nil, timing: CMSampleTimingInfo) {
        self.imageBuffer = imageBuffer
        if let f = formatDescription {
            self.formatDescription = f
        } else {
            var f: CMFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: imageBuffer, formatDescriptionOut: &f)
            self.formatDescription = f
        }
        dataBuffer = nil
        numSamples = 1
        self.timing = [timing]
        dataIsReady = true
    }

    public init(dataBuffer: CMBlockBuffer?, formatDescription: CMFormatDescription?, numSamples: Int, timing: [CMSampleTimingInfo]) {
        self.dataBuffer = dataBuffer
        self.formatDescription = formatDescription
        imageBuffer = nil
        self.numSamples = numSamples
        self.timing = timing
        dataIsReady = true
    }

    /// Interleaved PCM frames from `bytes`, starting at `pts`.
    public convenience init(pcm bytes: Data, format: AudioStreamBasicDescription, presentationTimeStamp pts: CMTime) {
        let frames = format.mBytesPerFrame > 0 ? bytes.count / Int(format.mBytesPerFrame) : 0
        let rate = Int32(max(format.mSampleRate, 1))
        self.init(dataBuffer: CMBlockBuffer(data: bytes), formatDescription: CMFormatDescription(mediaType: kCMMediaType_Audio, subType: kAudioFormatLinearPCM, audio: format),
                  numSamples: frames, timing: [CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate), presentationTimeStamp: pts, decodeTimeStamp: .invalid)])
    }

    func copy(timing t: [CMSampleTimingInfo]) -> CMSampleBuffer {
        let s: CMSampleBuffer
        if let image = imageBuffer {
            s = CMSampleBuffer(imageBuffer: image, formatDescription: formatDescription, timing: t.first ?? .invalid)
        } else {
            s = CMSampleBuffer(dataBuffer: dataBuffer, formatDescription: formatDescription, numSamples: numSamples, timing: t)
        }
        s.sampleAttachments = sampleAttachments
        return s
    }

    public var presentationTimeStamp: CMTime { timing.first?.presentationTimeStamp ?? .invalid }
    public var outputPresentationTimeStamp: CMTime { presentationTimeStamp }
    public var decodeTimeStamp: CMTime { timing.first?.decodeTimeStamp ?? .invalid }
    /// The whole buffer's duration (all of its audio frames).
    public var duration: CMTime {
        guard let first = timing.first, first.duration.isValid else { return .invalid }
        if timing.count == 1, numSamples > 1 { return CMTimeMultiply(first.duration, multiplier: Int32(clamping: numSamples)) }
        return timing.dropFirst().reduce(first.duration) { $0 + $1.duration }
    }
    public var outputDuration: CMTime { duration }
    public var isValid: Bool { true }
    public var totalSampleSize: Int { dataBuffer?.dataLength ?? 0 }

    /// Per-sample attachment dictionaries (ScreenCaptureKit's frame info…).
    public func setSampleAttachments(_ a: [[AnyHashable: Any]]) { lock.lock(); sampleAttachments = a as NSArray; lock.unlock() }
    func attachments(create: Bool) -> NSArray? {
        lock.lock(); defer { lock.unlock() }
        if sampleAttachments == nil, create { sampleAttachments = (0..<max(numSamples, 1)).map { _ in NSMutableDictionary() } as NSArray }
        return sampleAttachments
    }
}

public func CMSampleBufferGetPresentationTimeStamp(_ sb: CMSampleBuffer) -> CMTime { sb.presentationTimeStamp }
public func CMSampleBufferGetOutputPresentationTimeStamp(_ sb: CMSampleBuffer) -> CMTime { sb.presentationTimeStamp }
public func CMSampleBufferGetDecodeTimeStamp(_ sb: CMSampleBuffer) -> CMTime { sb.decodeTimeStamp }
public func CMSampleBufferGetDuration(_ sb: CMSampleBuffer) -> CMTime { sb.duration }
public func CMSampleBufferGetOutputDuration(_ sb: CMSampleBuffer) -> CMTime { sb.duration }
public func CMSampleBufferGetFormatDescription(_ sb: CMSampleBuffer) -> CMFormatDescription? { sb.formatDescription }
public func CMSampleBufferGetImageBuffer(_ sb: CMSampleBuffer) -> CVImageBuffer? { sb.imageBuffer }
public func CMSampleBufferGetDataBuffer(_ sb: CMSampleBuffer) -> CMBlockBuffer? { sb.dataBuffer }
public func CMSampleBufferGetNumSamples(_ sb: CMSampleBuffer) -> CMItemCount { sb.numSamples }
public func CMSampleBufferGetTotalSampleSize(_ sb: CMSampleBuffer) -> Int { sb.totalSampleSize }
public func CMSampleBufferDataIsReady(_ sb: CMSampleBuffer) -> Bool { sb.dataIsReady }
public func CMSampleBufferIsValid(_ sb: CMSampleBuffer) -> Bool { true }
public func CMSampleBufferGetSampleAttachmentsArray(_ sb: CMSampleBuffer, createIfNecessary: Bool) -> CFArray? { sb.attachments(create: createIfNecessary) }

@discardableResult
public func CMSampleBufferGetSampleTimingInfoArray(_ sb: CMSampleBuffer, entryCount: CMItemCount, arrayToFill: UnsafeMutablePointer<CMSampleTimingInfo>?,
                                                   entriesNeededOut: UnsafeMutablePointer<CMItemCount>?) -> OSStatus {
    entriesNeededOut?.pointee = sb.timing.count
    if let arrayToFill {
        guard entryCount >= sb.timing.count else { return -12737 } // kCMSampleBufferError_ArrayTooSmall
        for (i, t) in sb.timing.enumerated() { arrayToFill[i] = t }
    }
    return noErr
}
@discardableResult
public func CMSampleBufferGetSampleTimingInfo(_ sb: CMSampleBuffer, at index: CMItemIndex, timingInfoOut: UnsafeMutablePointer<CMSampleTimingInfo>) -> OSStatus {
    guard index >= 0, index < max(sb.numSamples, 1) else { return -12733 }
    var t = sb.timing.first ?? .invalid
    if sb.timing.count > index { t = sb.timing[index] } else if index > 0, t.duration.isNumeric {
        t.presentationTimeStamp = t.presentationTimeStamp + CMTimeMultiply(t.duration, multiplier: Int32(index))
    }
    timingInfoOut.pointee = t
    return noErr
}
@discardableResult
public func CMSampleBufferCreateCopyWithNewTiming(allocator: AnyObject?, sampleBuffer: CMSampleBuffer, sampleTimingEntryCount: CMItemCount,
                                                  sampleTimingArray: UnsafePointer<CMSampleTimingInfo>?, sampleBufferOut: UnsafeMutablePointer<CMSampleBuffer?>) -> OSStatus {
    let t = sampleTimingArray.map { Array(UnsafeBufferPointer(start: $0, count: sampleTimingEntryCount)) } ?? []
    sampleBufferOut.pointee = sampleBuffer.copy(timing: t)
    return noErr
}
@discardableResult
public func CMSampleBufferCreateReadyWithImageBuffer(allocator: AnyObject?, imageBuffer: CVImageBuffer, formatDescription: CMFormatDescription,
                                                     sampleTiming: UnsafePointer<CMSampleTimingInfo>, sampleBufferOut: UnsafeMutablePointer<CMSampleBuffer?>) -> OSStatus {
    sampleBufferOut.pointee = CMSampleBuffer(imageBuffer: imageBuffer, formatDescription: formatDescription, timing: sampleTiming.pointee)
    return noErr
}
@discardableResult
public func CMSampleBufferCreateForImageBuffer(allocator: AnyObject?, imageBuffer: CVImageBuffer, dataReady: Bool, makeDataReadyCallback: AnyObject?,
                                               refcon: UnsafeMutableRawPointer?, formatDescription: CMFormatDescription,
                                               sampleTiming: UnsafePointer<CMSampleTimingInfo>, sampleBufferOut: UnsafeMutablePointer<CMSampleBuffer?>) -> OSStatus {
    let s = CMSampleBuffer(imageBuffer: imageBuffer, formatDescription: formatDescription, timing: sampleTiming.pointee)
    s.dataIsReady = dataReady
    sampleBufferOut.pointee = s
    return noErr
}
@discardableResult
public func CMSampleBufferCreate(allocator: AnyObject?, dataBuffer: CMBlockBuffer?, dataReady: Bool, makeDataReadyCallback: AnyObject?,
                                 refcon: UnsafeMutableRawPointer?, formatDescription: CMFormatDescription?, sampleCount: CMItemCount,
                                 sampleTimingEntryCount: CMItemCount, sampleTimingArray: UnsafePointer<CMSampleTimingInfo>?,
                                 sampleSizeEntryCount: CMItemCount, sampleSizeArray: UnsafePointer<Int>?,
                                 sampleBufferOut: UnsafeMutablePointer<CMSampleBuffer?>) -> OSStatus {
    let t = sampleTimingArray.map { Array(UnsafeBufferPointer(start: $0, count: sampleTimingEntryCount)) } ?? []
    let s = CMSampleBuffer(dataBuffer: dataBuffer, formatDescription: formatDescription, numSamples: sampleCount, timing: t)
    s.dataIsReady = dataReady
    sampleBufferOut.pointee = s
    return noErr
}

// MARK: Clocks

/// The host clock: monotonic nanoseconds since boot.
public final class CMClock: @unchecked Sendable {
    public let name: String
    let offset: CMTime
    init(name: String, offset: CMTime = .zero) { self.name = name; self.offset = offset }
    public static let hostTimeClock = CMClock(name: "host")
    public var time: CMTime { CMTime(value: Int64(DispatchTime.now().uptimeNanoseconds), timescale: 1_000_000_000) + offset }
    public func convert(_ t: CMTime, to other: CMClock) -> CMTime { t - offset + other.offset }
}
public typealias CMClockOrTimebase = AnyObject

public func CMClockGetHostTimeClock() -> CMClock { .hostTimeClock }
public func CMClockGetTime(_ clock: CMClock) -> CMTime { clock.time }
public func CMClockMakeHostTimeFromSystemUnits(_ units: UInt64) -> CMTime { CMTime(value: Int64(units), timescale: 1_000_000_000) }
public func CMClockConvertHostTimeToSystemUnits(_ t: CMTime) -> UInt64 { UInt64(max(t.convertScale(1_000_000_000, method: .default).value, 0)) }

/// A clock or timebase's time converted to another's.
public func CMSyncConvertTime(_ time: CMTime, from fromClockOrTimebase: AnyObject, to toClockOrTimebase: AnyObject) -> CMTime {
    func offset(_ o: AnyObject) -> CMTime {
        if let c = o as? CMClock { return c.offset }
        if let tb = o as? CMTimebase { return tb.offsetFromSource }
        return .zero
    }
    return time - offset(fromClockOrTimebase) + offset(toClockOrTimebase)
}
public func CMSyncGetTime(_ clockOrTimebase: AnyObject) -> CMTime {
    if let c = clockOrTimebase as? CMClock { return c.time }
    if let tb = clockOrTimebase as? CMTimebase { return tb.time }
    return .invalid
}

/// A timebase over a source clock: time = (source − anchor) × rate + start.
public final class CMTimebase: @unchecked Sendable {
    public let source: CMClock
    private let lock = NSLock()
    private var anchor: CMTime
    private var startTime: CMTime = .zero
    private var rateValue: Double = 0
    public init(sourceClock: CMClock) {
        source = sourceClock
        anchor = sourceClock.time
    }
    public var time: CMTime {
        lock.lock(); defer { lock.unlock() }
        return startTime + CMTimeMultiplyByFloat64(source.time - anchor, multiplier: rateValue)
    }
    public var rate: Double {
        get { lock.lock(); defer { lock.unlock() }; return rateValue }
        set { let t = time; lock.lock(); startTime = t; anchor = source.time; rateValue = newValue; lock.unlock() }
    }
    public func setTime(_ t: CMTime) { lock.lock(); startTime = t; anchor = source.time; lock.unlock() }
    var offsetFromSource: CMTime { time - source.time }
}
@discardableResult
public func CMTimebaseCreateWithSourceClock(allocator: AnyObject?, sourceClock: CMClock, timebaseOut: UnsafeMutablePointer<CMTimebase?>) -> OSStatus {
    timebaseOut.pointee = CMTimebase(sourceClock: sourceClock)
    return noErr
}
public func CMTimebaseGetTime(_ tb: CMTimebase) -> CMTime { tb.time }
@discardableResult public func CMTimebaseSetTime(_ tb: CMTimebase, time: CMTime) -> OSStatus { tb.setTime(time); return noErr }
@discardableResult public func CMTimebaseSetRate(_ tb: CMTimebase, rate: Double) -> OSStatus { tb.rate = rate; return noErr }
public func CMTimebaseGetRate(_ tb: CMTimebase) -> Double { tb.rate }
