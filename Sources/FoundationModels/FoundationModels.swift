// FoundationModels for Linux and Windows: Apple's on-device language model
// isn't here, so `SystemLanguageModel.default.availability` is
// `.unavailable(.deviceNotEligible)` (what a Mac without Apple Intelligence
// reports), and a session's `respond` throws the framework's own error.
// The guided-generation surface (Generable, Guide, prompts, transcripts)
// exists so code that declares it compiles.

@_exported import Foundation

public final class SystemLanguageModel: @unchecked Sendable {
    public enum Availability: Equatable, Sendable {
        public enum UnavailableReason: Equatable, Sendable { case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady }
        case available
        case unavailable(UnavailableReason)
    }
    public struct UseCase: Equatable, Sendable {
        let raw: String
        public static let general = UseCase(raw: "general"), contentTagging = UseCase(raw: "contentTagging")
    }
    public struct Guardrails: Sendable {
        public static let `default` = Guardrails()
        public static let permissiveContentTransformations = Guardrails()
    }
    public struct Adapter: Sendable {
        public init(fileURL: URL) throws { throw LanguageModelSession.GenerationError.assetsUnavailable(.init(debugDescription: "No on-device model.")) }
        public init(name: String) throws { throw LanguageModelSession.GenerationError.assetsUnavailable(.init(debugDescription: "No on-device model.")) }
    }

    public static let `default` = SystemLanguageModel()
    public let useCase: UseCase
    public init(useCase: UseCase = .general, guardrails: Guardrails = .default) { self.useCase = useCase }
    public convenience init(adapter: Adapter, guardrails: Guardrails = .default) { self.init() }

    public var availability: Availability { .unavailable(.deviceNotEligible) }
    public var isAvailable: Bool { false }
    public var supportedLanguages: Set<Locale.Language> { [] }
    public func supportsLocale(_ locale: Locale = .current) -> Bool { false }
}

public protocol Tool: Sendable {
    associatedtype Arguments: ConvertibleFromGeneratedContent
    associatedtype Output: PromptRepresentable
    var name: String { get }
    var description: String { get }
    func call(arguments: Arguments) async throws -> Output
}

public struct GeneratedContent: Sendable, Equatable, CustomStringConvertible {
    public let jsonString: String
    public init(json: String) throws { jsonString = json }
    public init(_ s: String) { jsonString = "\"\(s)\"" }
    public var description: String { jsonString }
}
public protocol ConvertibleFromGeneratedContent { init(_ content: GeneratedContent) throws }
public protocol ConvertibleToGeneratedContent { var generatedContent: GeneratedContent { get } }
public protocol PromptRepresentable { var promptRepresentation: Prompt { get } }
public protocol InstructionsRepresentable { var instructionsRepresentation: Instructions { get } }
public protocol Generable: ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent {
    static var generationSchema: GenerationSchema { get }
}
public struct GenerationSchema: Sendable {
    public init() {}
}
public struct GenerationGuide<Value>: Sendable {}

extension String: ConvertibleFromGeneratedContent, ConvertibleToGeneratedContent, PromptRepresentable, InstructionsRepresentable {
    public init(_ content: GeneratedContent) throws { self = content.jsonString }
    public var generatedContent: GeneratedContent { GeneratedContent(self) }
    public var promptRepresentation: Prompt { Prompt(self) }
    public var instructionsRepresentation: Instructions { Instructions(self) }
}

public struct Prompt: Sendable, PromptRepresentable {
    public let text: String
    public init(_ text: String) { self.text = text }
    public init(@PromptBuilder _ content: () throws -> Prompt) rethrows { self = try content() }
    public var promptRepresentation: Prompt { self }
}
@resultBuilder public enum PromptBuilder {
    public static func buildBlock(_ parts: PromptRepresentable...) -> Prompt { Prompt(parts.map(\.promptRepresentation.text).joined(separator: "\n")) }
    public static func buildExpression(_ e: PromptRepresentable) -> PromptRepresentable { e }
}
public struct Instructions: Sendable, InstructionsRepresentable {
    public let text: String
    public init(_ text: String) { self.text = text }
    public init(@InstructionsBuilder _ content: () throws -> Instructions) rethrows { self = try content() }
    public var instructionsRepresentation: Instructions { self }
}
@resultBuilder public enum InstructionsBuilder {
    public static func buildBlock(_ parts: InstructionsRepresentable...) -> Instructions {
        Instructions(parts.map(\.instructionsRepresentation.text).joined(separator: "\n"))
    }
    public static func buildExpression(_ e: InstructionsRepresentable) -> InstructionsRepresentable { e }
}

public struct GenerationOptions: Sendable {
    public enum SamplingMode: Sendable {
        case greedy
        case random(top: Int, seed: UInt64? = nil)
        case random(probabilityThreshold: Double, seed: UInt64? = nil)
    }
    public var sampling: SamplingMode?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public init(sampling: SamplingMode? = nil, temperature: Double? = nil, maximumResponseTokens: Int? = nil) {
        self.sampling = sampling; self.temperature = temperature; self.maximumResponseTokens = maximumResponseTokens
    }
}

public struct Transcript: Sendable, Equatable {
    public enum Entry: Sendable, Equatable { case instructions(String), prompt(String), response(String) }
    public var entries: [Entry]
    public init(entries: [Entry] = []) { self.entries = entries }
}

public final class LanguageModelSession: @unchecked Sendable {
    public enum GenerationError: Error, LocalizedError, Sendable {
        public struct Context: Sendable {
            public let debugDescription: String
            public init(debugDescription: String) { self.debugDescription = debugDescription }
        }
        case exceededContextWindowSize(Context), assetsUnavailable(Context), guardrailViolation(Context), unsupportedGuide(Context)
        case unsupportedLanguageOrLocale(Context), decodingFailure(Context), rateLimited(Context), concurrentRequests(Context), refusal(Context)
        public var errorDescription: String? { "Apple Intelligence isn't available on this platform." }
    }
    public struct Response<Content>: Sendable where Content: Sendable {
        public let content: Content
        public let transcriptEntries: ArraySlice<Transcript.Entry>
    }
    public struct ResponseStream<Content: Sendable>: AsyncSequence, Sendable {
        public typealias Element = Content
        public struct AsyncIterator: AsyncIteratorProtocol {
            public mutating func next() async throws -> Content? { throw LanguageModelSession.unavailable }
        }
        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator() }
        public func collect() async throws -> Response<Content> { throw LanguageModelSession.unavailable }
    }

    static let unavailable = GenerationError.assetsUnavailable(.init(debugDescription: "No on-device language model on this platform."))

    public let transcript: Transcript
    public var isResponding: Bool { false }

    public init(model: SystemLanguageModel = .default, tools: [any Tool] = [], instructions: String? = nil) {
        transcript = Transcript(entries: instructions.map { [.instructions($0)] } ?? [])
    }
    public init(model: SystemLanguageModel = .default, tools: [any Tool] = [], instructions: Instructions?) {
        transcript = Transcript(entries: instructions.map { [.instructions($0.text)] } ?? [])
    }
    public init(model: SystemLanguageModel = .default, tools: [any Tool] = [], transcript: Transcript) { self.transcript = transcript }

    public func prewarm(promptPrefix: Prompt? = nil) {}

    public func respond(to prompt: String, options: GenerationOptions = GenerationOptions()) async throws -> Response<String> { throw Self.unavailable }
    public func respond(to prompt: Prompt, options: GenerationOptions = GenerationOptions()) async throws -> Response<String> { throw Self.unavailable }
    public func respond<Content: Generable & Sendable>(to prompt: String, generating type: Content.Type = Content.self, includeSchemaInPrompt: Bool = true,
                                                       options: GenerationOptions = GenerationOptions()) async throws -> Response<Content> { throw Self.unavailable }
    public func respond(to prompt: String, schema: GenerationSchema, includeSchemaInPrompt: Bool = true,
                        options: GenerationOptions = GenerationOptions()) async throws -> Response<GeneratedContent> { throw Self.unavailable }
    public func streamResponse(to prompt: String, options: GenerationOptions = GenerationOptions()) -> ResponseStream<String> { ResponseStream() }
    public func streamResponse(to prompt: Prompt, options: GenerationOptions = GenerationOptions()) -> ResponseStream<String> { ResponseStream() }
}
