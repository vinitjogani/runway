// Firebase's app, analytics and crash-reporting entry points, inert:
// nothing is configured or sent on this platform.

import Foundation

open class FirebaseOptions: NSObject {
    public var googleAppID: String
    public var gcmSenderID: String
    public var apiKey: String?
    public var bundleID: String
    public var projectID: String?
    public var storageBucket: String?

    public init(googleAppID: String, gcmSenderID: String) {
        self.googleAppID = googleAppID
        self.gcmSenderID = gcmSenderID
        bundleID = Bundle.main.bundleIdentifier ?? ""
        super.init()
    }

    /// Reads GoogleService-Info.plist, as Firebase does.
    public convenience init?(contentsOfFile path: String) {
        guard let d = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
        self.init(googleAppID: d["GOOGLE_APP_ID"] as? String ?? "", gcmSenderID: d["GCM_SENDER_ID"] as? String ?? "")
        apiKey = d["API_KEY"] as? String
        projectID = d["PROJECT_ID"] as? String
        storageBucket = d["STORAGE_BUCKET"] as? String
    }

    public static func defaultOptions() -> FirebaseOptions? {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist").flatMap(FirebaseOptions.init(contentsOfFile:))
    }
}

open class FirebaseApp: NSObject {
    nonisolated(unsafe) private static var apps: [String: FirebaseApp] = [:]
    public let name: String
    public let options: FirebaseOptions

    init(name: String, options: FirebaseOptions) {
        self.name = name
        self.options = options
        super.init()
    }

    public static func configure() {
        if let o = FirebaseOptions.defaultOptions() { configure(options: o) }
    }
    public static func configure(options: FirebaseOptions) { configure(name: "__FIRAPP_DEFAULT", options: options) }
    public static func configure(name: String, options: FirebaseOptions) { apps[name] = FirebaseApp(name: name, options: options) }
    public static func app() -> FirebaseApp? { apps["__FIRAPP_DEFAULT"] }
    public static func app(name: String) -> FirebaseApp? { apps[name] }
    public static var allApps: [String: FirebaseApp]? { apps.isEmpty ? nil : apps }
    public func delete(_ completion: @escaping (Bool) -> Void) {
        FirebaseApp.apps[name] = nil
        completion(true)
    }
    public var isDataCollectionDefaultEnabled = false
}

public enum AnalyticsEventSelectContent {}
public let AnalyticsParameterItemID = "item_id"
public let AnalyticsParameterContentType = "content_type"
public let AnalyticsEventScreenView = "screen_view"
public let AnalyticsParameterScreenName = "screen_name"
public let AnalyticsParameterScreenClass = "screen_class"

/// Google Analytics: events are dropped.
open class Analytics: NSObject {
    public static func logEvent(_ name: String, parameters: [String: Any]?) {}
    public static func setUserID(_ userID: String?) {}
    public static func setUserProperty(_ value: String?, forName name: String) {}
    public static func setAnalyticsCollectionEnabled(_ enabled: Bool) {}
    public static func setDefaultEventParameters(_ parameters: [String: Any]?) {}
    public static func resetAnalyticsData() {}
    public static func appInstanceID() -> String? { nil }
}

/// Crashlytics: nothing is recorded.
open class Crashlytics: NSObject {
    private static let shared = Crashlytics()
    public static func crashlytics() -> Crashlytics { shared }
    public func record(error: Error) {}
    public func record(error: Error, userInfo: [String: Any]?) {}
    public func log(_ msg: String) {}
    public func setCustomValue(_ value: Any?, forKey key: String) {}
    public func setCustomKeysAndValues(_ keysAndValues: [AnyHashable: Any]) {}
    public func setUserID(_ userID: String?) {}
    public func setCrashlyticsCollectionEnabled(_ enabled: Bool) {}
    public func isCrashlyticsCollectionEnabled() -> Bool { false }
    public func didCrashDuringPreviousExecution() -> Bool { false }
    public func checkForUnsentReports(completion: @escaping (Bool) -> Void) { completion(false) }
    public func sendUnsentReports() {}
    public func deleteUnsentReports() {}
}
