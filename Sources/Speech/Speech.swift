// Speech for Linux and Windows: there is no on-device speech recogniser,
// so authorization is `.restricted` (the answer for a device where speech
// recognition can't be used), recognisers report themselves unavailable,
// and SpeechAnalyzer's modules say they aren't available. Apps already
// handle all of these on Macs without the feature.

@_exported import AVFoundation
@_exported import CoreMedia
@_exported import Foundation

public enum SFSpeechRecognizerAuthorizationStatus: Int, Sendable { case notDetermined = 0, denied, restricted, authorized }
public enum SFSpeechRecognitionTaskHint: Int, Sendable { case unspecified = 0, dictation, search, confirmation }
public enum SFSpeechRecognitionTaskState: Int, Sendable { case starting = 0, running, finishing, canceling, completed }

public let SFSpeechErrorDomain = "SFSpeechErrorDomain"

public protocol SFSpeechRecognizerDelegate: AnyObject {
    func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool)
}
extension SFSpeechRecognizerDelegate {
    public func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {}
}

public final class SFSpeechRecognizer: @unchecked Sendable {
    public let locale: Locale
    public var isAvailable: Bool { false }
    public var supportsOnDeviceRecognition = false
    public weak var delegate: SFSpeechRecognizerDelegate?
    public var defaultTaskHint: SFSpeechRecognitionTaskHint = .unspecified
    public var queue: OperationQueue = .main

    public convenience init?() { self.init(locale: .current) }
    public init?(locale: Locale) {
        self.locale = locale
    }
    public class func supportedLocales() -> Set<Locale> { [] }
    public class func authorizationStatus() -> SFSpeechRecognizerAuthorizationStatus { .restricted }
    public class func requestAuthorization(_ handler: @escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) { handler(.restricted) }

    private func unavailable() -> NSError {
        NSError(domain: SFSpeechErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn't available on this platform."])
    }
    public func recognitionTask(with request: SFSpeechRecognitionRequest, resultHandler: @escaping (SFSpeechRecognitionResult?, Error?) -> Void) -> SFSpeechRecognitionTask {
        let t = SFSpeechRecognitionTask()
        resultHandler(nil, unavailable())
        return t
    }
    public func recognitionTask(with request: SFSpeechRecognitionRequest, delegate: SFSpeechRecognitionTaskDelegate) -> SFSpeechRecognitionTask {
        let t = SFSpeechRecognitionTask()
        delegate.speechRecognitionTask(t, didFinishSuccessfully: false)
        return t
    }
}

public class SFSpeechRecognitionRequest: NSObject, @unchecked Sendable {
    public var taskHint: SFSpeechRecognitionTaskHint = .unspecified
    public var shouldReportPartialResults = true
    public var contextualStrings: [String] = []
    public var requiresOnDeviceRecognition = false
    public var addsPunctuation = false
    public var interactionIdentifier: String?
}
public final class SFSpeechURLRecognitionRequest: SFSpeechRecognitionRequest, @unchecked Sendable {
    public let url: URL
    public init(url URL: URL) { url = URL; super.init() }
}
public final class SFSpeechAudioBufferRecognitionRequest: SFSpeechRecognitionRequest, @unchecked Sendable {
    public override init() { super.init() }
    public func append(_ audioPCMBuffer: AVAudioPCMBuffer) {}
    public func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {}
    public func endAudio() {}
}

public final class SFSpeechRecognitionTask: NSObject, @unchecked Sendable {
    public private(set) var state: SFSpeechRecognitionTaskState = .completed
    public var isFinishing: Bool { false }
    public private(set) var isCancelled = false
    public var error: Error? { nil }
    public func finish() {}
    public func cancel() { isCancelled = true }
}
public protocol SFSpeechRecognitionTaskDelegate: AnyObject {
    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool)
}

public final class SFSpeechRecognitionResult: NSObject, @unchecked Sendable {
    public let bestTranscription: SFTranscription
    public let transcriptions: [SFTranscription]
    public let isFinal: Bool
    init(_ t: SFTranscription, final: Bool) { bestTranscription = t; transcriptions = [t]; isFinal = final; super.init() }
}
public final class SFTranscription: NSObject, @unchecked Sendable {
    public let formattedString: String
    public let segments: [SFTranscriptionSegment]
    init(_ s: String, _ segs: [SFTranscriptionSegment]) { formattedString = s; segments = segs; super.init() }
}
public final class SFTranscriptionSegment: NSObject, @unchecked Sendable {
    public let substring: String
    public let substringRange: NSRange
    public let timestamp: TimeInterval
    public let duration: TimeInterval
    public let confidence: Float
    public let alternativeSubstrings: [String]
    init(_ s: String, at t: TimeInterval, for d: TimeInterval) {
        substring = s; substringRange = NSRange(location: 0, length: s.utf16.count); timestamp = t; duration = d; confidence = 0; alternativeSubstrings = []
        super.init()
    }
}

// MARK: SpeechAnalyzer (macOS 26)

public protocol SpeechModule: AnyObject, Sendable {}
public protocol LocaleDependentSpeechModule: SpeechModule {}

public final class SpeechTranscriber: LocaleDependentSpeechModule, @unchecked Sendable {
    public struct TranscriptionOption: Hashable, Sendable {
        let raw: String
        public static let etiquetteReplacements = TranscriptionOption(raw: "etiquette")
    }
    public struct ReportingOption: Hashable, Sendable {
        let raw: String
        public static let volatileResults = ReportingOption(raw: "volatile"), alternativeTranscriptions = ReportingOption(raw: "alternatives")
        public static let fastResults = ReportingOption(raw: "fast")
    }
    public struct ResultAttributeOption: Hashable, Sendable {
        let raw: String
        public static let audioTimeRange = ResultAttributeOption(raw: "audioTimeRange"), transcriptionConfidence = ResultAttributeOption(raw: "confidence")
    }
    public enum Preset: Sendable { case transcription, transcriptionWithAlternatives, timeIndexedTranscriptionWithAlternatives, progressiveLiveTranscription, offlineTranscription }

    public struct Result: Sendable {
        public let text: AttributedString
        public let range: CMTimeRange
        public let resultsFinalizationTime: CMTime
        public let isFinal: Bool
    }

    public let locale: Locale
    /// Results never come: there's no recogniser (the stream ends at once).
    public let results: AsyncThrowingStream<Result, Error>

    public init(locale: Locale, transcriptionOptions: Set<TranscriptionOption>, reportingOptions: Set<ReportingOption>, attributeOptions: Set<ResultAttributeOption>) {
        self.locale = locale
        results = AsyncThrowingStream { $0.finish() }
    }
    public convenience init(locale: Locale, preset: Preset) { self.init(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: []) }

    public static var isAvailable: Bool { false }
    public static var supportedLocales: [Locale] { get async { [] } }
    public static var installedLocales: [Locale] { get async { [] } }
    public static func supportedLocale(equivalentTo locale: Locale) async -> Locale? { nil }
}

public final class DictationTranscriber: LocaleDependentSpeechModule, @unchecked Sendable {
    public static var isAvailable: Bool { false }
    public static func supportedLocale(equivalentTo locale: Locale) async -> Locale? { nil }
}

public struct SpeechAnalyzerError: Error, LocalizedError, Sendable {
    public var errorDescription: String? { "On-device speech analysis isn't available on this platform." }
}

public final class SpeechAnalyzer: @unchecked Sendable {
    public let modules: [any SpeechModule]
    public init(modules: [any SpeechModule]) { self.modules = modules }
    public func analyzeSequence(from file: AVAudioFile) async throws -> CMTime? { throw SpeechAnalyzerError() }
    public func analyzeSequence<S: AsyncSequence>(_ input: S) async throws -> CMTime? { throw SpeechAnalyzerError() }
    public func start<S: AsyncSequence>(inputSequence: S) async throws { throw SpeechAnalyzerError() }
    public func finalizeAndFinish(through: CMTime) async throws {}
    public func finalizeAndFinishThroughEndOfInput() async throws {}
    public func cancelAndFinishNow() async {}
    public func finalize(through: CMTime?) async throws {}
    public static func bestAvailableAudioFormat(compatibleWith modules: [any SpeechModule]) async -> AVAudioFormat? { nil }
}

public final class AssetInstallationRequest: @unchecked Sendable {
    public let progress = Progress(totalUnitCount: 1)
    public func downloadAndInstall() async throws { throw SpeechAnalyzerError() }
}
public enum AssetInventory {
    public enum Status: Int, Sendable, Comparable {
        case unsupported = 0, supported, downloading, installed
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }
    public static func assetInstallationRequest(supporting modules: [any SpeechModule]) async throws -> AssetInstallationRequest? { nil }
    public static func status(forModules modules: [any SpeechModule]) async -> Status { .unsupported }
    public static func reserve(locale: Locale) async throws -> Bool { false }
}

extension AttributeScopes {
    public struct SpeechAttributes: AttributeScope {
        public let audioTimeRange: AudioTimeRangeAttribute
        public let transcriptionConfidence: ConfidenceAttribute
        public let foundation: FoundationAttributes
    }
    public var speech: SpeechAttributes.Type { SpeechAttributes.self }
}
public enum AudioTimeRangeAttribute: CodableAttributedStringKey {
    public typealias Value = CMTimeRange
    public static let name = "audioTimeRange"
}
public enum ConfidenceAttribute: CodableAttributedStringKey {
    public typealias Value = Double
    public static let name = "transcriptionConfidence"
}
extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SpeechAttributes, T>) -> T { self[T.self] }
}
