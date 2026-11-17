// Vision for Linux and Windows: there are no on-device vision models, so
// every request fails through Vision's own error path —
// `VNImageRequestHandler.perform` throws VNError.unsupportedRequest and each
// request's completion handler gets the same error with no results — which
// is how apps already see a request a device can't run.

@_exported import CoreGraphics
@_exported import CoreImage
@_exported import CoreVideo
@_exported import Foundation

public let VNErrorDomain = "com.apple.Vision"

public struct VNError: CustomNSError, Hashable, Sendable {
    public enum Code: Int, Sendable {
        case tuplesNotFound = 0, requestCancelled, invalidFormat, operationFailed, outOfBoundsError, invalidOption, ioError
        case missingOption, notImplemented, internalError, outOfMemory, unknownError, invalidOperation, invalidImage, invalidArgument
        case invalidModel, unsupportedRevision, dataUnavailable, timeStampNotFound, unsupportedRequest, timeout, unsupportedComputeStage, unsupportedComputeDevice
    }
    public let code: Code
    public init(_ code: Code) { self.code = code }
    public static var errorDomain: String { VNErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: "Vision requests aren't supported on this platform."] }
}

public typealias VNRequestCompletionHandler = (VNRequest, Error?) -> Void

public struct VNImageOption: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let properties = Self(rawValue: "VNImageOptionProperties"), ciContext = Self(rawValue: "VNImageOptionCIContext")
}

open class VNRequest: NSObject, @unchecked Sendable {
    public let completionHandler: VNRequestCompletionHandler?

    open var preferBackgroundProcessing = false
    open var usesCPUOnly = false
    open var revision = 1
    public init(completionHandler: VNRequestCompletionHandler? = nil) {
        self.completionHandler = completionHandler
        super.init()
    }
    public override convenience init() { self.init(completionHandler: nil) }
    open func cancel() {}
}
/// `results`, typed per request class as on Apple platforms (class members
/// in each request; this protocol extension for the base).
public protocol VNRequestResultsAccess {}
extension VNRequest: VNRequestResultsAccess {}
extension VNRequestResultsAccess where Self: VNRequest {
    public var results: [VNObservation]? { nil }
}

open class VNImageBasedRequest: VNRequest, @unchecked Sendable {
    open var regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
}

open class VNObservation: NSObject, @unchecked Sendable {
    public let uuid = UUID()
    public let confidence: Float = 0
}
open class VNDetectedObjectObservation: VNObservation, @unchecked Sendable { public let boundingBox: CGRect = .zero }
open class VNRectangleObservation: VNDetectedObjectObservation, @unchecked Sendable {}
open class VNFaceObservation: VNDetectedObjectObservation, @unchecked Sendable {}
open class VNRecognizedObjectObservation: VNDetectedObjectObservation, @unchecked Sendable {}
open class VNTextObservation: VNRectangleObservation, @unchecked Sendable {}
open class VNRecognizedTextObservation: VNRectangleObservation, @unchecked Sendable {
    open func topCandidates(_ maxCandidateCount: Int) -> [VNRecognizedText] { [] }
}
public final class VNRecognizedText: NSObject, @unchecked Sendable {
    public let string = ""
    public let confidence: Float = 0
}
open class VNClassificationObservation: VNObservation, @unchecked Sendable { public let identifier = "" }
open class VNBarcodeObservation: VNRectangleObservation, @unchecked Sendable { public let payloadStringValue: String? = nil }
open class VNPixelBufferObservation: VNObservation, @unchecked Sendable {}
open class VNFeaturePrintObservation: VNObservation, @unchecked Sendable {
    open func computeDistance(_ distance: UnsafeMutablePointer<Float>, to featurePrint: VNFeaturePrintObservation) throws { throw VNError(.unsupportedRequest) }
}

public enum VNRequestTextRecognitionLevel: Int, Sendable { case accurate = 0, fast }

open class VNRecognizeTextRequest: VNImageBasedRequest, @unchecked Sendable {
    open var recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    open var recognitionLanguages: [String] = ["en-US"]
    open var usesLanguageCorrection = true
    open var customWords: [String] = []
    open var minimumTextHeight: Float = 0
    open var automaticallyDetectsLanguage = false
    public var results: [VNRecognizedTextObservation]? { nil }
    open func supportedRecognitionLanguages() throws -> [String] { [] }
}
open class VNDetectFaceRectanglesRequest: VNImageBasedRequest, @unchecked Sendable { public var results: [VNFaceObservation]? { nil } }
open class VNDetectFaceLandmarksRequest: VNImageBasedRequest, @unchecked Sendable { public var results: [VNFaceObservation]? { nil } }
open class VNDetectRectanglesRequest: VNImageBasedRequest, @unchecked Sendable { public var results: [VNRectangleObservation]? { nil } }
open class VNDetectBarcodesRequest: VNImageBasedRequest, @unchecked Sendable { public var results: [VNBarcodeObservation]? { nil } }
open class VNDetectTextRectanglesRequest: VNImageBasedRequest, @unchecked Sendable { public var results: [VNTextObservation]? { nil } }
open class VNClassifyImageRequest: VNImageBasedRequest, @unchecked Sendable { public var results: [VNClassificationObservation]? { nil } }
open class VNGenerateImageFeaturePrintRequest: VNImageBasedRequest, @unchecked Sendable { public var results: [VNFeaturePrintObservation]? { nil } }
open class VNGeneratePersonSegmentationRequest: VNImageBasedRequest, @unchecked Sendable {
    public enum QualityLevel: Int, Sendable { case accurate = 0, balanced, fast }
    open var qualityLevel: QualityLevel = .accurate
    public var results: [VNPixelBufferObservation]? { nil }
}
open class VNGenerateForegroundInstanceMaskRequest: VNImageBasedRequest, @unchecked Sendable {}
open class VNDetectHumanRectanglesRequest: VNImageBasedRequest, @unchecked Sendable {}
open class VNGenerateAttentionBasedSaliencyImageRequest: VNImageBasedRequest, @unchecked Sendable {}

public final class VNImageRequestHandler: NSObject, @unchecked Sendable {
    public init(cgImage: CGImage, options: [VNImageOption: Any] = [:]) { super.init() }
    public init(cgImage: CGImage, orientation: CGImagePropertyOrientation, options: [VNImageOption: Any] = [:]) { super.init() }
    public init(ciImage: CIImage, options: [VNImageOption: Any] = [:]) { super.init() }
    public init(ciImage: CIImage, orientation: CGImagePropertyOrientation, options: [VNImageOption: Any] = [:]) { super.init() }
    public init(cvPixelBuffer: CVPixelBuffer, options: [VNImageOption: Any] = [:]) { super.init() }
    public init(cvPixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, options: [VNImageOption: Any] = [:]) { super.init() }
    public init(url: URL, options: [VNImageOption: Any] = [:]) { super.init() }
    public init(data: Data, options: [VNImageOption: Any] = [:]) { super.init() }

    /// Every request fails: no vision models on this platform.
    public func perform(_ requests: [VNRequest]) throws {
        let e = VNError(.unsupportedRequest)
        for r in requests { r.completionHandler?(r, e) }
        if !requests.isEmpty { throw e }
    }
}

public final class VNSequenceRequestHandler: NSObject, @unchecked Sendable {
    public override init() { super.init() }
    public func perform(_ requests: [VNRequest], on image: CGImage) throws { try VNImageRequestHandler(cgImage: image).perform(requests) }
    public func perform(_ requests: [VNRequest], on pixelBuffer: CVPixelBuffer) throws { try VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform(requests) }
    public func perform(_ requests: [VNRequest], on image: CIImage) throws { try VNImageRequestHandler(ciImage: image).perform(requests) }
}

public func VNImageRectForNormalizedRect(_ r: CGRect, _ w: Int, _ h: Int) -> CGRect {
    CGRect(x: r.minX * CGFloat(w), y: r.minY * CGFloat(h), width: r.width * CGFloat(w), height: r.height * CGFloat(h))
}
public func VNNormalizedRectForImageRect(_ r: CGRect, _ w: Int, _ h: Int) -> CGRect {
    CGRect(x: r.minX / CGFloat(w), y: r.minY / CGFloat(h), width: r.width / CGFloat(w), height: r.height / CGFloat(h))
}
