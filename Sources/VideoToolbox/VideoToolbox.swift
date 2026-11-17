// VideoToolbox for Linux and Windows: the compression-property keys apps
// pass to AVAssetWriter (which encodes with GStreamer here), and the
// session APIs, which report that hardware sessions aren't available
// (kVTCouldNotFindVideoEncoderErr) so apps take their AVFoundation path.

@_exported import CoreMedia
@_exported import CoreVideo
@_exported import Foundation

public let kVTCompressionPropertyKey_RealTime: CFString = "RealTime"
public let kVTCompressionPropertyKey_AverageBitRate: CFString = "AverageBitRate"
public let kVTCompressionPropertyKey_DataRateLimits: CFString = "DataRateLimits"
public let kVTCompressionPropertyKey_MaxKeyFrameInterval: CFString = "MaxKeyFrameInterval"
public let kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: CFString = "MaxKeyFrameIntervalDuration"
public let kVTCompressionPropertyKey_AllowFrameReordering: CFString = "AllowFrameReordering"
public let kVTCompressionPropertyKey_ExpectedFrameRate: CFString = "ExpectedFrameRate"
public let kVTCompressionPropertyKey_ProfileLevel: CFString = "ProfileLevel"
public let kVTCompressionPropertyKey_Quality: CFString = "Quality"
public let kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: CFString = "PrioritizeEncodingSpeedOverQuality"
public let kVTCompressionPropertyKey_ColorPrimaries: CFString = "ColorPrimaries"
public let kVTCompressionPropertyKey_TransferFunction: CFString = "TransferFunction"
public let kVTCompressionPropertyKey_YCbCrMatrix: CFString = "YCbCrMatrix"
public let kVTProfileLevel_H264_High_AutoLevel: CFString = "H264_High_AutoLevel"
public let kVTProfileLevel_H264_Main_AutoLevel: CFString = "H264_Main_AutoLevel"
public let kVTProfileLevel_H264_Baseline_AutoLevel: CFString = "H264_Baseline_AutoLevel"
public let kVTProfileLevel_HEVC_Main_AutoLevel: CFString = "HEVC_Main_AutoLevel"
public let kVTProfileLevel_HEVC_Main10_AutoLevel: CFString = "HEVC_Main10_AutoLevel"
public let kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: CFString = "EnableHardwareAcceleratedVideoEncoder"
public let kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: CFString = "RequireHardwareAcceleratedVideoEncoder"
public let kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: CFString = "EnableHardwareAcceleratedVideoDecoder"
public let kVTEncodeFrameOptionKey_ForceKeyFrame: CFString = "ForceKeyFrame"
public let kVTDecompressionPropertyKey_RealTime: CFString = "RealTime"

public let kVTPropertyNotSupportedErr: OSStatus = -12900
public let kVTParameterErr: OSStatus = -12902
public let kVTInvalidSessionErr: OSStatus = -12903
public let kVTAllocationFailedErr: OSStatus = -12904
public let kVTCouldNotFindVideoDecoderErr: OSStatus = -12906
public let kVTCouldNotFindVideoEncoderErr: OSStatus = -12908
public let kVTVideoDecoderBadDataErr: OSStatus = -12909
public let kVTVideoEncoderMalfunctionErr: OSStatus = -12911
public let kVTVideoDecoderUnsupportedDataFormatErr: OSStatus = -12910

public struct VTEncodeInfoFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let asynchronous = Self(rawValue: 1), frameDropped = Self(rawValue: 2)
}
public struct VTDecodeFrameFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let _EnableAsynchronousDecompression = Self(rawValue: 1)
}
public struct VTDecodeInfoFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let asynchronous = Self(rawValue: 1), frameDropped = Self(rawValue: 2)
}

public final class VTCompressionSession: @unchecked Sendable {}
public final class VTDecompressionSession: @unchecked Sendable {}
public final class VTPixelTransferSession: @unchecked Sendable {}

public typealias VTCompressionOutputCallback = (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, OSStatus, VTEncodeInfoFlags, CMSampleBuffer?) -> Void

public func VTCompressionSessionCreate(allocator: AnyObject?, width: Int32, height: Int32, codecType: CMVideoCodecType, encoderSpecification: CFDictionary?,
                                       imageBufferAttributes: CFDictionary?, compressedDataAllocator: AnyObject?, outputCallback: VTCompressionOutputCallback?,
                                       refcon: UnsafeMutableRawPointer?, compressionSessionOut: UnsafeMutablePointer<VTCompressionSession?>) -> OSStatus {
    compressionSessionOut.pointee = nil
    return kVTCouldNotFindVideoEncoderErr
}
public func VTSessionSetProperty(_ session: AnyObject, key: CFString, value: AnyObject?) -> OSStatus { kVTInvalidSessionErr }
public func VTCompressionSessionPrepareToEncodeFrames(_ session: VTCompressionSession) -> OSStatus { kVTInvalidSessionErr }
public func VTCompressionSessionEncodeFrame(_ session: VTCompressionSession, imageBuffer: CVImageBuffer, presentationTimeStamp: CMTime, duration: CMTime,
                                            frameProperties: CFDictionary?, sourceFrameRefcon: UnsafeMutableRawPointer?,
                                            infoFlagsOut: UnsafeMutablePointer<VTEncodeInfoFlags>?) -> OSStatus { kVTInvalidSessionErr }
public func VTCompressionSessionCompleteFrames(_ session: VTCompressionSession, untilPresentationTimeStamp: CMTime) -> OSStatus { kVTInvalidSessionErr }
public func VTCompressionSessionInvalidate(_ session: VTCompressionSession) {}
public func VTDecompressionSessionInvalidate(_ session: VTDecompressionSession) {}
public func VTPixelTransferSessionCreate(allocator: AnyObject?, pixelTransferSessionOut: UnsafeMutablePointer<VTPixelTransferSession?>) -> OSStatus {
    pixelTransferSessionOut.pointee = VTPixelTransferSession()
    return noErr
}
/// Converts between pixel formats and sizes (via RGBA).
public func VTPixelTransferSessionTransferImage(_ session: VTPixelTransferSession, from source: CVPixelBuffer, to destination: CVPixelBuffer) -> OSStatus {
    let rgba = source.rgba()
    if source.width == destination.width, source.height == destination.height {
        destination.write(rgba: rgba, width: source.width, height: source.height)
        return noErr
    }
    var scaled = [UInt8](repeating: 0, count: destination.width * destination.height * 4)
    for y in 0..<destination.height {
        let sy = y * source.height / destination.height
        for x in 0..<destination.width {
            let sx = x * source.width / destination.width
            for c in 0..<4 { scaled[(y * destination.width + x) * 4 + c] = rgba[(sy * source.width + sx) * 4 + c] }
        }
    }
    destination.write(rgba: scaled, width: destination.width, height: destination.height)
    return noErr
}
public func VTIsHardwareDecodeSupported(_ codecType: CMVideoCodecType) -> Bool { false }
public func VTCopyVideoEncoderList(_ options: CFDictionary?, _ listOfVideoEncodersOut: UnsafeMutablePointer<CFArray?>) -> OSStatus {
    listOfVideoEncodersOut.pointee = NSArray()
    return noErr
}
