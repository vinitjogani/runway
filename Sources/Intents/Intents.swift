// Intents (SiriKit): the classes intent definitions build on and intent
// handlers use. There is no Siri or Shortcuts on Linux: authorization is
// denied, donations go nowhere, and nothing sends the app an intent.

@_exported import Foundation
import RunwayFoundation

open class INIntent: NSObject, @unchecked Sendable {
    open var identifier: String? = UUID().uuidString
    open var intentDescription: String?
    open var suggestedInvocationPhrase: String?
    public override init() {}
}

public enum INIntentResponseCode: Int, Sendable { case unspecified, ready, continueInApp, inProgress, success, failure, failureRequiringAppLaunch }

open class INIntentResponse: NSObject, @unchecked Sendable {
    open var userActivity: NSUserActivity?
    public override init() {}
}

public enum INInteractionDirection: Int, Sendable { case unspecified, outgoing, incoming }
public enum INIntentHandlingStatus: Int, Sendable { case unspecified, ready, inProgress, success, failure, deferredToApplication, userConfirmationRequired }

open class INInteraction: NSObject, @unchecked Sendable {
    public let intent: INIntent
    public let intentResponse: INIntentResponse?
    open var identifier: String?
    open var groupIdentifier: String?
    open var direction: INInteractionDirection = .unspecified
    open var intentHandlingStatus: INIntentHandlingStatus { .unspecified }
    open var dateInterval: DateInterval?
    public init(intent: INIntent, response: INIntentResponse?) { self.intent = intent; self.intentResponse = response }
    open func donate(completion: ((Error?) -> Void)? = nil) { completion?(nil) }
    open class func deleteAll(completion: ((Error?) -> Void)? = nil) { completion?(nil) }
    open class func delete(with identifiers: [String], completion: ((Error?) -> Void)? = nil) { completion?(nil) }
    open class func delete(with groupIdentifier: String, completion: ((Error?) -> Void)? = nil) { completion?(nil) }
}

open class INObject: NSObject, @unchecked Sendable {
    public let identifier: String?
    public let displayString: String
    open var pronunciationHint: String?
    open var subtitleString: String?
    public init(identifier: String?, display displayString: String, pronunciationHint: String? = nil) {
        self.identifier = identifier
        self.displayString = displayString
        self.pronunciationHint = pronunciationHint
    }
    public init(identifier: String?, display displayString: String, subtitle: String?, image: Any?) {
        self.identifier = identifier
        self.displayString = displayString
        subtitleString = subtitle
    }
}

open class INObjectSection<ObjectType>: NSObject, @unchecked Sendable {
    public let title: String?
    public let items: [ObjectType]
    public init(title: String?, items: [ObjectType]) { self.title = title; self.items = items }
}

open class INObjectCollection<ObjectType>: NSObject, @unchecked Sendable {
    public let sections: [INObjectSection<ObjectType>]
    public var allItems: [ObjectType] { sections.flatMap(\.items) }
    open var usesIndexedCollation = false
    public init(sections: [INObjectSection<ObjectType>]) { self.sections = sections }
    public init(items: [ObjectType]) { sections = [INObjectSection(title: nil, items: items)] }
}

open class INIntentResolutionResult: NSObject, @unchecked Sendable {
    public class func needsValue() -> Self { Self.init() }
    public class func notRequired() -> Self { Self.init() }
    public class func unsupported() -> Self { Self.init() }
    public required override init() {}
}

open class INStringResolutionResult: INIntentResolutionResult, @unchecked Sendable {
    public class func success(with resolvedString: String) -> INStringResolutionResult { INStringResolutionResult() }
    public class func disambiguation(with stringsToDisambiguate: [String]) -> INStringResolutionResult { INStringResolutionResult() }
    public class func confirmationRequired(with stringToConfirm: String?) -> INStringResolutionResult { INStringResolutionResult() }
}

open class INTimeIntervalResolutionResult: INIntentResolutionResult, @unchecked Sendable {
    public class func success(with resolvedTimeInterval: TimeInterval) -> INTimeIntervalResolutionResult { INTimeIntervalResolutionResult() }
    public class func confirmationRequired(with timeIntervalToConfirm: TimeInterval) -> INTimeIntervalResolutionResult { INTimeIntervalResolutionResult() }
}

open class INBooleanResolutionResult: INIntentResolutionResult, @unchecked Sendable {
    public class func success(with resolvedValue: Bool) -> INBooleanResolutionResult { INBooleanResolutionResult() }
    public class func confirmationRequired(with valueToConfirm: NSNumber?) -> INBooleanResolutionResult { INBooleanResolutionResult() }
}

open class INIntegerResolutionResult: INIntentResolutionResult, @unchecked Sendable {
    public class func success(with resolvedValue: Int) -> INIntegerResolutionResult { INIntegerResolutionResult() }
    public class func confirmationRequired(with valueToConfirm: NSNumber?) -> INIntegerResolutionResult { INIntegerResolutionResult() }
}

open class INObjectResolutionResult: INIntentResolutionResult, @unchecked Sendable {
    public class func success(with resolvedObject: INObject) -> INObjectResolutionResult { INObjectResolutionResult() }
    public class func disambiguation(with objectsToDisambiguate: [INObject]) -> INObjectResolutionResult { INObjectResolutionResult() }
}

public enum INSiriAuthorizationStatus: Int, Sendable { case notDetermined, restricted, denied, authorized }

open class INPreferences: NSObject, @unchecked Sendable {
    open class func siriAuthorizationStatus() -> INSiriAuthorizationStatus { .denied }
    open class func requestSiriAuthorization(_ handler: @escaping (INSiriAuthorizationStatus) -> Void) { handler(.denied) }
    open class func siriLanguageCode() -> String { Locale.current.identifier }
}

open class INShortcut: NSObject, @unchecked Sendable {
    public let intent: INIntent?
    public let userActivity: NSUserActivity?
    public init?(intent: INIntent) { self.intent = intent; userActivity = nil }
    public init(userActivity: NSUserActivity) { intent = nil; self.userActivity = userActivity }
}

open class INVoiceShortcut: NSObject, @unchecked Sendable {
    public let identifier = UUID()
    public let invocationPhrase: String = ""
    public let shortcut: INShortcut
    init(shortcut: INShortcut) { self.shortcut = shortcut }
}

open class INVoiceShortcutCenter: NSObject, @unchecked Sendable {
    public static let shared = INVoiceShortcutCenter()
    open func getAllVoiceShortcuts(completion: @escaping ([INVoiceShortcut]?, Error?) -> Void) { completion([], nil) }
    open func setShortcutSuggestions(_ suggestions: [INShortcut]) {}
}

open class INRelevantShortcut: NSObject, @unchecked Sendable {
    public let shortcut: INShortcut
    public init(shortcut: INShortcut) { self.shortcut = shortcut }
}

open class INRelevantShortcutStore: NSObject, @unchecked Sendable {
    public static let `default` = INRelevantShortcutStore()
    open func setRelevantShortcuts(_ shortcuts: [INRelevantShortcut], completionHandler: ((Error?) -> Void)? = nil) { completionHandler?(nil) }
}

open class INExtension: NSObject, INIntentHandlerProviding, @unchecked Sendable {
    public override init() {}
    open func handler(for intent: INIntent) -> Any? { nil }
}

public protocol INIntentHandlerProviding: AnyObject {
    func handler(for intent: INIntent) -> Any?
}

extension NSUserActivity {
    /// The intent an activity carries (none here).
    public var interaction: INInteraction? { nil }
    public var suggestedInvocationPhrase: String? { get { nil } set {} }
}
