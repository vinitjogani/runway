// AppIntents: actions an app offers to Shortcuts, Spotlight and Siri. There
// is no Shortcuts on Linux, so nothing discovers or runs the intents, but
// they compile with Apple's declarations, keep their parameters and can be
// run from the app itself (`try await intent.perform()`).

@_exported import Foundation
@_exported import UniformTypeIdentifiers
import RunwayFoundation

// MARK: Intents

public protocol AppIntent: Sendable {
    associatedtype PerformResult: IntentResult
    associatedtype SummaryContent: ParameterSummary
    static var title: LocalizedStringResource { get }
    static var description: IntentDescription? { get }
    static var openAppWhenRun: Bool { get }
    static var isDiscoverable: Bool { get }
    static var authenticationPolicy: IntentAuthenticationPolicy { get }
    @ParameterSummaryBuilder<Self> static var parameterSummary: SummaryContent { get }
    init()
    func perform() async throws -> PerformResult
}

extension AppIntent {
    public static var description: IntentDescription? { nil }
    public static var openAppWhenRun: Bool { false }
    public static var isDiscoverable: Bool { true }
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
    public static var parameterSummary: _EmptyParameterSummary<Self> { _EmptyParameterSummary() }

    /// Shortcuts would ask the user; here there is no one to ask, so it
    /// goes ahead (as with confirmation turned off).
    public func requestConfirmation(confirmationActionName: ConfirmationActionName = .go, showPrompt: Bool = true) async throws {}
    public func requestConfirmation<R: IntentResult>(result: R, confirmationActionName: ConfirmationActionName = .go, showPrompt: Bool = true) async throws {}
    public func requestConfirmation<T>(for value: T, dialog: IntentDialog? = nil) async throws -> T { value }
    public func requestValue<T>(_ dialog: IntentDialog? = nil) async throws -> T { throw AppIntentError.Unrecoverable.unknown }
}

public protocol CustomIntentMigratedAppIntent: AppIntent {
    static var intentClassName: String { get }
}
public protocol OpenIntent: AppIntent {}
public protocol ForegroundContinuableIntent: AppIntent {}
public protocol AudioPlaybackIntent: AppIntent {}
public protocol ProgressReportingIntent: AppIntent {}
public protocol SystemIntent: AppIntent {}

public enum IntentAuthenticationPolicy: Sendable { case alwaysAllowed, requiresAuthentication, requiresLocalDeviceAuthentication }

public struct ConfirmationActionName: Sendable {
    public static let go = Self(), add = Self(), `continue` = Self(), order = Self(), post = Self(), request = Self(),
                      run = Self(), search = Self(), send = Self(), set = Self(), start = Self(), toggle = Self()
}

public enum AppIntentError: Error {
    case restartPerform
    public enum Unrecoverable: Error { case unknown, featureCurrentlyUnavailable, entityNotFound }
    public enum UserActionRequired: Error { case confirmation, deviceUnlock, signin }
}

public struct IntentDescription: Sendable, ExpressibleByStringLiteral {
    public var descriptionText: LocalizedStringResource
    public var categoryName: LocalizedStringResource?
    public var searchKeywords: [LocalizedStringResource]
    public var resultValueName: LocalizedStringResource?
    public init(_ descriptionText: LocalizedStringResource, categoryName: LocalizedStringResource? = nil,
                searchKeywords: [LocalizedStringResource] = [], resultValueName: LocalizedStringResource? = nil) {
        self.descriptionText = descriptionText
        self.categoryName = categoryName
        self.searchKeywords = searchKeywords
        self.resultValueName = resultValueName
    }
    public init(stringLiteral value: String) { self.init(LocalizedStringResource(value)) }
}

public struct IntentDialog: Sendable, ExpressibleByStringInterpolation {
    public var full: LocalizedStringResource
    public init(_ full: LocalizedStringResource) { self.full = full }
    public init(full: LocalizedStringResource, supporting: LocalizedStringResource) { self.full = full }
    public init(stringLiteral value: String) { full = LocalizedStringResource(value) }
    public init(stringInterpolation: LocalizedStringResource.StringInterpolation) { full = LocalizedStringResource(stringInterpolation: stringInterpolation) }
}

// MARK: Results

public protocol IntentResult: Sendable {}
public protocol ReturnsValue<Value>: IntentResult {
    associatedtype Value
}
public protocol ProvidesDialog: IntentResult {}
public protocol ShowsSnippetView: IntentResult {}
public protocol OpensIntent: IntentResult {}

/// The one result type: an optional value and dialog.
public struct _IntentResult<Value>: IntentResult, ReturnsValue, ProvidesDialog, ShowsSnippetView, OpensIntent, @unchecked Sendable {
    public let value: Value?
    public let dialog: IntentDialog?
    public init() { value = nil; dialog = nil }
    init(value: Value?, dialog: IntentDialog?) { self.value = value; self.dialog = dialog }
}

extension IntentResult where Self == _IntentResult<Never> {
    public static func result() -> _IntentResult<Never> { _IntentResult() }
    public static func result(dialog: IntentDialog) -> _IntentResult<Never> { _IntentResult(value: nil, dialog: dialog) }
    public static func result<V>(value: V) -> _IntentResult<V> { _IntentResult(value: value, dialog: nil) }
    public static func result<V>(value: V, dialog: IntentDialog) -> _IntentResult<V> { _IntentResult(value: value, dialog: dialog) }
    public static func result<I: AppIntent>(opensIntent: I) -> _IntentResult<Never> { _IntentResult() }
    public static func result<V, I: AppIntent>(value: V, opensIntent: I) -> _IntentResult<V> { _IntentResult(value: value, dialog: nil) }
}

// MARK: Parameters

public enum IntentParameterControlStyle: Sendable { case field, slider, stepper }

public protocol DynamicOptionsProvider: Sendable {
    associatedtype Result
    init()
    func results() async throws -> Result
}
extension DynamicOptionsProvider { public init() { fatalError("\(Self.self) needs an init()") } }

/// A parameter of an intent: `@Parameter(title:…) var x: T`; `$x` is the
/// parameter itself (what parameter summaries refer to).
@propertyWrapper
public final class IntentParameter<Value>: @unchecked Sendable {
    public var title: LocalizedStringResource?
    public var description: LocalizedStringResource?
    var value: Value?
    var defaultValue: Value?

    public init(title: LocalizedStringResource? = nil, description: LocalizedStringResource? = nil, default defaultValue: Value? = nil,
                requestValueDialog: IntentDialog? = nil, inputOptions: Any? = nil, controlStyle: IntentParameterControlStyle? = nil,
                inclusiveRange: (Value, Value)? = nil, supportedContentTypes: [UTType]? = nil,
                optionsProvider: (any DynamicOptionsProvider)? = nil, requestDisambiguationDialog: IntentDialog? = nil,
                kind: Any? = nil, resolvesValueOnMain: Bool = false) {
        self.title = title
        self.description = description
        self.defaultValue = defaultValue
    }

    public var wrappedValue: Value {
        get {
            if let value { return value }
            if let defaultValue { return defaultValue }
            if let nilType = Value.self as? any ExpressibleByNilLiteral.Type, let v = nilType.init(nilLiteral: ()) as? Value { return v }
            fatalError("@Parameter \(title.map { "\($0)" } ?? "") has no value")
        }
        set { value = newValue }
    }
    public var projectedValue: IntentParameter<Value> { self }
}

public typealias Parameter = IntentParameter

/// A property of an entity: `@Property(title:) var x: T`.
@propertyWrapper
public final class EntityProperty<Value>: @unchecked Sendable {
    public var title: LocalizedStringResource?
    var value: Value?
    public init(title: LocalizedStringResource? = nil) { self.title = title }
    public init(wrappedValue: Value, title: LocalizedStringResource? = nil) { self.title = title; value = wrappedValue }
    public var wrappedValue: Value {
        get {
            if let value { return value }
            if let nilType = Value.self as? any ExpressibleByNilLiteral.Type, let v = nilType.init(nilLiteral: ()) as? Value { return v }
            fatalError("@Property \(title.map { "\($0)" } ?? "") has no value")
        }
        set { value = newValue }
    }
    public var projectedValue: EntityProperty<Value> { self }
}

public typealias Property = EntityProperty

public struct IntentFile: Sendable, Hashable {
    public var data: Data
    public var filename: String
    public var type: UTType?
    public var fileURL: URL?
    public init(data: Data, filename: String, type: UTType? = nil) { self.data = data; self.filename = filename; self.type = type }
    public init(fileURL: URL, filename: String? = nil, type: UTType? = nil) {
        self.fileURL = fileURL
        self.data = (try? Data(contentsOf: fileURL)) ?? Data()
        self.filename = filename ?? fileURL.lastPathComponent
        self.type = type
    }
    public var removedOnCompletion: Bool { false }
}

// MARK: Parameter summaries

public protocol ParameterSummary: Sendable {}

/// A summary bound to the intent its key paths start from.
public protocol _IntentParameterSummary<Intent>: ParameterSummary {
    associatedtype Intent: AppIntent
}

public struct _EmptyParameterSummary<Intent: AppIntent>: _IntentParameterSummary {
    public init() {}
}

@resultBuilder
public enum ParameterSummaryBuilder<Intent: AppIntent> {
    public static func buildExpression<S: _IntentParameterSummary>(_ s: S) -> S where S.Intent == Intent { s }
    public static func buildBlock<S: _IntentParameterSummary>(_ s: S) -> S where S.Intent == Intent { s }
    public static func buildEither<T: _IntentParameterSummary>(first: T) -> _EitherSummary<Intent> where T.Intent == Intent { _EitherSummary() }
    public static func buildEither<F: _IntentParameterSummary>(second: F) -> _EitherSummary<Intent> where F.Intent == Intent { _EitherSummary() }
}

public struct _EitherSummary<Intent: AppIntent>: _IntentParameterSummary {}

/// "Convert \(\.$video) to GIF": text with the parameters it shows.
public struct ParameterSummaryString<Intent: AppIntent>: Sendable, ExpressibleByStringInterpolation {
    public var text: String
    public init(stringLiteral value: String) { text = value }
    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ s: String) { text += s }
        public mutating func appendInterpolation<T>(_ kp: KeyPath<Intent, IntentParameter<T>>) { text += "${parameter}" }
        public mutating func appendInterpolation(_ s: String) { text += s }
    }
    public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
}

@resultBuilder
public enum ParameterSummaryParametersBuilder<Intent: AppIntent> {
    public static func buildExpression<T>(_ kp: KeyPath<Intent, IntentParameter<T>>) -> [PartialKeyPath<Intent>] { [kp] }
    public static func buildBlock(_ parts: [PartialKeyPath<Intent>]...) -> [PartialKeyPath<Intent>] { parts.flatMap { $0 } }
}

public struct Summary<Intent: AppIntent>: _IntentParameterSummary {
    public let text: String?
    public init(_ summary: ParameterSummaryString<Intent>) { text = summary.text }
    public init(_ summary: ParameterSummaryString<Intent>,
                @ParameterSummaryParametersBuilder<Intent> _ parameters: () -> [PartialKeyPath<Intent>]) { text = summary.text }
    public init(@ParameterSummaryParametersBuilder<Intent> _ parameters: () -> [PartialKeyPath<Intent>]) { text = nil }
}

public enum ParameterSummaryComparison: Sendable { case equalTo, notEqualTo, greaterThan, lessThan, hasAnyValue, hasNoValue, oneOf, noneOf }

public struct When<Intent: AppIntent>: _IntentParameterSummary {
    public init<V, T: _IntentParameterSummary, F: _IntentParameterSummary>(
        _ parameter: KeyPath<Intent, IntentParameter<V>>, _ comparison: ParameterSummaryComparison, _ value: V,
        @ParameterSummaryBuilder<Intent> _ then: () -> T, @ParameterSummaryBuilder<Intent> otherwise: () -> F
    ) where T.Intent == Intent, F.Intent == Intent {}
    public init<V, T: _IntentParameterSummary>(
        _ parameter: KeyPath<Intent, IntentParameter<V>>, _ comparison: ParameterSummaryComparison, _ value: V,
        @ParameterSummaryBuilder<Intent> _ then: () -> T
    ) where T.Intent == Intent {}
    public init<V, T: _IntentParameterSummary, F: _IntentParameterSummary>(
        _ parameter: KeyPath<Intent, IntentParameter<V>>, _ comparison: ParameterSummaryComparison,
        @ParameterSummaryBuilder<Intent> _ then: () -> T, @ParameterSummaryBuilder<Intent> otherwise: () -> F
    ) where T.Intent == Intent, F.Intent == Intent {}
}

public struct Switch<Intent: AppIntent, Value>: _IntentParameterSummary {
    public init(_ parameter: KeyPath<Intent, IntentParameter<Value>>, @ParameterSummaryCaseBuilder<Intent, Value> _ cases: () -> [_SummaryCase<Intent, Value>]) {}
}

public struct _SummaryCase<Intent: AppIntent, Value> {}

public struct Case<Intent: AppIntent, Value> {
    public init<S: _IntentParameterSummary>(_ value: Value, @ParameterSummaryBuilder<Intent> _ summary: () -> S) where S.Intent == Intent {}
}

public struct DefaultCase<Intent: AppIntent, Value> {
    public init<S: _IntentParameterSummary>(@ParameterSummaryBuilder<Intent> _ summary: () -> S) where S.Intent == Intent {}
}

@resultBuilder
public enum ParameterSummaryCaseBuilder<Intent: AppIntent, Value> {
    public static func buildExpression(_ c: Case<Intent, Value>) -> [_SummaryCase<Intent, Value>] { [_SummaryCase()] }
    public static func buildExpression(_ c: DefaultCase<Intent, Value>) -> [_SummaryCase<Intent, Value>] { [_SummaryCase()] }
    public static func buildBlock(_ parts: [_SummaryCase<Intent, Value>]...) -> [_SummaryCase<Intent, Value>] { parts.flatMap { $0 } }
}

// MARK: Entities and enums

public struct DisplayRepresentation: Sendable, ExpressibleByStringInterpolation {
    public var title: LocalizedStringResource
    public var subtitle: LocalizedStringResource?
    public var image: Image?
    public init(title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil, image: Image? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.image = image
    }
    public init(stringLiteral value: String) { title = LocalizedStringResource(value) }
    public init(stringInterpolation: LocalizedStringResource.StringInterpolation) { title = LocalizedStringResource(stringInterpolation: stringInterpolation) }

    public struct Image: Sendable {
        public init(systemName: String, tintColor: Any? = nil, symbolConfiguration: Any? = nil) {}
        public init(named: String, isTemplate: Bool = false) {}
        public init(url: URL, isTemplate: Bool = false) {}
        public init(data: Data, isTemplate: Bool = false) {}
    }
}

public struct TypeDisplayRepresentation: Sendable, ExpressibleByStringInterpolation {
    public var name: LocalizedStringResource
    public var numericFormat: LocalizedStringResource?
    public init(name: LocalizedStringResource, numericFormat: LocalizedStringResource? = nil) { self.name = name; self.numericFormat = numericFormat }
    public init(stringLiteral value: String) { name = LocalizedStringResource(value) }
    public init(stringInterpolation: LocalizedStringResource.StringInterpolation) { name = LocalizedStringResource(stringInterpolation: stringInterpolation) }
}

public protocol TypeDisplayRepresentable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { get }
}

public protocol DisplayRepresentable {
    var displayRepresentation: DisplayRepresentation { get }
}

public protocol AppValue: Sendable {}

public protocol AppEntity: TypeDisplayRepresentable, DisplayRepresentable, Identifiable, Sendable {
    associatedtype DefaultQuery: EntityQuery
    static var defaultQuery: DefaultQuery { get }
}

public protocol TransientAppEntity: AppEntity where ID == UUID, DefaultQuery == _TransientQuery<Self> {
    init()
}

extension TransientAppEntity {
    public var id: UUID { UUID() }
    public static var defaultQuery: _TransientQuery<Self> { _TransientQuery() }
}

public protocol EntityQuery: Sendable {
    associatedtype Entity: AppEntity
    init()
    func entities(for identifiers: [Entity.ID]) async throws -> [Entity]
    func suggestedEntities() async throws -> [Entity]
}

extension EntityQuery {
    public func suggestedEntities() async throws -> [Entity] { [] }
}

public protocol EntityStringQuery: EntityQuery {
    func entities(matching string: String) async throws -> [Entity]
}

public protocol EnumerableEntityQuery: EntityQuery {
    func allEntities() async throws -> [Entity]
}

public struct _TransientQuery<E: AppEntity>: EntityQuery {
    public typealias Entity = E
    public init() {}
    public func entities(for identifiers: [E.ID]) async throws -> [E] { [] }
}

public protocol AppEnum: TypeDisplayRepresentable, RawRepresentable, CaseIterable, Hashable, Sendable where RawValue: Sendable {
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { get }
}

// MARK: Shortcuts

public protocol AppShortcutsProvider {
    @AppShortcutsBuilder static var appShortcuts: [AppShortcut] { get }
    static var shortcutTileColor: ShortcutTileColor { get }
}

extension AppShortcutsProvider {
    public static var shortcutTileColor: ShortcutTileColor { .navy }
    public static func updateAppShortcutParameters() {}
}

public enum ShortcutTileColor: Sendable { case red, tangerine, orange, yellow, lime, grayGreen, teal, lightBlue, blue, navy, purple, lightPurple, pink, grayBlue, grayBrown, grayGreen2 }

@resultBuilder
public enum AppShortcutsBuilder {
    public static func buildExpression(_ s: AppShortcut) -> [AppShortcut] { [s] }
    public static func buildBlock(_ parts: [AppShortcut]...) -> [AppShortcut] { parts.flatMap { $0 } }
    public static func buildOptional(_ s: [AppShortcut]?) -> [AppShortcut] { s ?? [] }
}

public struct AppShortcutPhrase<Intent: AppIntent>: ExpressibleByStringInterpolation, Sendable {
    public init(stringLiteral value: String) {}
    public struct StringInterpolation: StringInterpolationProtocol {
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ s: String) {}
        public mutating func appendInterpolation(_ token: AppShortcutPhraseToken) {}
        public mutating func appendInterpolation<T>(_ kp: KeyPath<Intent, IntentParameter<T>>) {}
    }
    public init(stringInterpolation: StringInterpolation) {}
}

public enum AppShortcutPhraseToken: Sendable { case applicationName }

public struct AppShortcut: Sendable {
    public init<I: AppIntent>(intent: I, phrases: [AppShortcutPhrase<I>], shortTitle: LocalizedStringResource, systemImageName: String) {}
    public init<I: AppIntent>(intent: I, phrases: [AppShortcutPhrase<I>]) {}
}

// MARK: Dependencies

@propertyWrapper
public struct AppDependency<Value>: @unchecked Sendable {
    public init() {}
    public init(key: String) {}
    public var wrappedValue: Value { AppDependencyManager.shared.resolve() }
}

public final class AppDependencyManager: @unchecked Sendable {
    public static let shared = AppDependencyManager()
    private var values: [ObjectIdentifier: () -> Any] = [:]
    private let lock = NSLock()
    public func add<D>(key: String? = nil, dependency: @escaping @Sendable () -> D) {
        lock.withLock { values[ObjectIdentifier(D.self)] = dependency }
    }
    func resolve<D>() -> D {
        guard let make = lock.withLock({ values[ObjectIdentifier(D.self)] }), let d = make() as? D else {
            fatalError("AppDependency \(D.self) was never added to AppDependencyManager")
        }
        return d
    }
}
