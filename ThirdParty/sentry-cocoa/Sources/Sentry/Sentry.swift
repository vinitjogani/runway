// The Sentry SDK's entry points apps call, doing nothing: crash and error
// reporting isn't available here, so `SentrySDK.isEnabled` stays false.

import Foundation

public enum SentryLevel: UInt {
    case none, debug, info, warning, error, fatal
}

open class Options: NSObject {
    public var dsn: String?
    public var debug = false
    public var environment = "production"
    public var releaseName: String?
    public var dist: String?
    public var enabled = true
    public var sampleRate: NSNumber? = 1
    public var tracesSampleRate: NSNumber?
    public var profilesSampleRate: NSNumber?
    public var enableSwizzling = true
    public var enableAppHangTracking = true
    public var appHangTimeoutInterval: TimeInterval = 2
    public var enableAutoSessionTracking = true
    public var enableCrashHandler = true
    public var enableNetworkTracking = true
    public var enableFileIOTracing = true
    public var enableUncaughtNSExceptionReporting = false
    public var attachStacktrace = true
    public var swiftAsyncStacktraces = false
    public var sendDefaultPii = false
    public var maxBreadcrumbs: UInt = 100
    public var beforeSend: ((Event) -> Event?)?
    public var beforeBreadcrumb: ((Breadcrumb) -> Breadcrumb?)?
    public override init() { super.init() }
}

open class Event: NSObject {
    public var message: SentryMessage?
    public var level: SentryLevel = .error
    public var tags: [String: String]?
    public var extra: [String: Any]?
    public override init() { super.init() }
}

open class SentryMessage: NSObject {
    public let formatted: String
    public init(formatted: String) { self.formatted = formatted; super.init() }
}

open class Breadcrumb: NSObject {
    public var level: SentryLevel = .info
    public var category: String
    public var message: String?
    public var type: String?
    public var data: [String: Any]?
    public init(level: SentryLevel = .info, category: String = "default") {
        self.level = level
        self.category = category
        super.init()
    }
}

open class SentryId: NSObject {
    public static let empty = SentryId()
    public var sentryIdString: String { "00000000000000000000000000000000" }
}

open class Scope: NSObject {
    public func setTag(value: String, key: String) {}
    public func removeTag(key: String) {}
    public func setExtra(value: Any?, key: String) {}
    public func setContext(value: [String: Any], key: String) {}
    public func setLevel(_ level: SentryLevel) {}
    public func setUser(_ user: User?) {}
    public func addBreadcrumb(_ crumb: Breadcrumb) {}
    public func clear() {}
}

open class User: NSObject {
    public var userId: String?
    public var email: String?
    public var username: String?
    public init(userId: String) { self.userId = userId; super.init() }
    public override init() { super.init() }
}

public enum SentrySDK {
    /// False: nothing is reported on this platform.
    public static var isEnabled: Bool { false }
    public static func start(configureOptions: @escaping (Options) -> Void) { configureOptions(Options()) }
    public static func start(options: Options) {}
    @discardableResult public static func capture(error: Error) -> SentryId { .empty }
    @discardableResult public static func capture(error: Error, block: (Scope) -> Void) -> SentryId { .empty }
    @discardableResult public static func capture(message: String) -> SentryId { .empty }
    @discardableResult public static func capture(message: String, block: (Scope) -> Void) -> SentryId { .empty }
    @discardableResult public static func capture(event: Event) -> SentryId { .empty }
    public static func addBreadcrumb(_ crumb: Breadcrumb) {}
    public static func configureScope(_ callback: @escaping (Scope) -> Void) {}
    public static func setUser(_ user: User?) {}
    public static func crash() {}
    public static func flush(timeout: TimeInterval) {}
    public static func close() {}
}
