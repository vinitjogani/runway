// Sparkle 2's public API (and Sparkle 1's SUUpdater), with no updater
// behind it: on Linux and Windows apps update through the system's package
// manager, so every check reports that updating isn't available.

import Foundation

/// Errors Sparkle reports, in its domain.
public let SUSparkleErrorDomain = "SUSparkleErrorDomain"

@objc public enum SUError: Int, Error {
    case noUpdateError = 1001
    case installationCanceledError = 4007
    case runningFromDiskImageError = 3002
    case invalidFeedURLError = 4
    case incorrectFeedError = 1002
}

/// The reason an updater can't run here.
let unavailableError = NSError(domain: SUSparkleErrorDomain, code: 4, userInfo: [
    NSLocalizedDescriptionKey: "Software updates aren't available on this platform.",
])

@objc public enum SPUUpdateCheck: Int {
    case updates, updatesInBackground, updateInformation
}

@objc public enum SPUUserUpdateChoice: Int {
    case skip, install, dismiss
}

@objc public enum SPUUserUpdateStage: Int {
    case notDownloaded, downloaded, installing
}

@objc public enum SUUpdatePermissionResponseChoice: Int { case no, yes }

/// An item of an appcast feed.
@objc open class SUAppcastItem: NSObject {
    @objc public let versionString: String
    @objc public let displayVersionString: String
    @objc public let title: String?
    @objc public let fileURL: URL?
    @objc public let infoURL: URL?
    @objc public let releaseNotesURL: URL?
    @objc public let itemDescription: String?
    @objc public let date: Date?
    @objc public let dateString: String?
    @objc public let channel: String?
    @objc public let minimumSystemVersion: String?
    @objc public let isCriticalUpdate: Bool
    @objc public let isMajorUpgrade: Bool
    @objc public let isInformationOnlyUpdate: Bool
    @objc public let propertiesDictionary: [String: Any]

    @objc public init(dictionary: [String: Any]) {
        versionString = dictionary["sparkle:version"] as? String ?? ""
        displayVersionString = dictionary["sparkle:shortVersionString"] as? String ?? versionString
        title = dictionary["title"] as? String
        fileURL = nil
        infoURL = nil
        releaseNotesURL = nil
        itemDescription = dictionary["description"] as? String
        date = nil
        dateString = dictionary["pubDate"] as? String
        channel = dictionary["sparkle:channel"] as? String
        minimumSystemVersion = nil
        isCriticalUpdate = false
        isMajorUpgrade = false
        isInformationOnlyUpdate = false
        propertiesDictionary = dictionary
        super.init()
    }

    @objc public static func empty() -> SUAppcastItem { SUAppcastItem(dictionary: [:]) }
}

@objc open class SUAppcast: NSObject {
    @objc public let items: [SUAppcastItem] = []
}

@objc open class SPUUserUpdateState: NSObject {
    @objc public let stage: SPUUserUpdateStage = .notDownloaded
    @objc public let userInitiated: Bool = false
}

@objc open class SUUpdatePermissionResponse: NSObject {
    @objc public let automaticUpdateChecks: Bool
    @objc public let sendSystemProfile: Bool
    @objc public init(automaticUpdateChecks: Bool, sendSystemProfile: Bool) {
        self.automaticUpdateChecks = automaticUpdateChecks
        self.sendSystemProfile = sendSystemProfile
        super.init()
    }
}

@objc open class SPUUpdatePermissionRequest: NSObject {
    @objc public let systemProfile: [[String: String]] = []
}

/// Compares version strings (Sparkle's `SUStandardVersionComparator`).
@objc public protocol SUVersionComparison {
    func compareVersion(_ versionA: String, toVersion versionB: String) -> ComparisonResult
}

@objc open class SUStandardVersionComparator: NSObject, SUVersionComparison {
    @objc public static let `default` = SUStandardVersionComparator()
    @objc public static func defaultComparator() -> SUStandardVersionComparator { .default }

    @objc open func compareVersion(_ versionA: String, toVersion versionB: String) -> ComparisonResult {
        versionA.compare(versionB, options: .numeric)
    }
}

// MARK: Delegates

/// What an updater asks its delegate. Every method is optional.
@objc public protocol SPUUpdaterDelegate: NSObjectProtocol {}

extension SPUUpdaterDelegate {
    public func feedURLString(for updater: SPUUpdater) -> String? { nil }
    public func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] { [] }
    public func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
    public func versionComparator(for updater: SPUUpdater) -> SUVersionComparison? { nil }
    public func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {}
    public func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {}
    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {}
    public func updaterDidNotFindUpdate(_ updater: SPUUpdater) {}
    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {}
    public func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {}
    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {}
    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {}
    public func updaterWillRelaunchApplication(_ updater: SPUUpdater) {}
    public func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }
}

/// What the standard user interface asks its delegate. Every method is optional.
@objc public protocol SPUStandardUserDriverDelegate: NSObjectProtocol {}

extension SPUStandardUserDriverDelegate {
    public var supportsGentleScheduledUpdateReminders: Bool { false }
    public func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { true }
    public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {}
    public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {}
    public func standardUserDriverWillFinishUpdateSession() {}
    public func standardUserDriverWillShowModalAlert() {}
    public func standardUserDriverDidShowModalAlert() {}
}

/// How an updater talks to the user.
@objc public protocol SPUUserDriver: NSObjectProtocol {}

@objc open class SPUStandardUserDriver: NSObject, SPUUserDriver {
    @objc public weak var delegate: SPUStandardUserDriverDelegate?
    @objc public init(hostBundle: Bundle, delegate: SPUStandardUserDriverDelegate?) {
        self.delegate = delegate
        super.init()
    }
    @objc open func dismissUpdateInstallation() {}
}

// MARK: The updater

/// Sparkle's updater. It never finds or installs an update here:
/// `canCheckForUpdates` stays false and `start()` reports why.
@objc open class SPUUpdater: NSObject {
    @objc public let hostBundle: Bundle
    @objc public let userDriver: SPUUserDriver
    @objc public weak var delegate: SPUUpdaterDelegate?

    @objc public init(hostBundle: Bundle, applicationBundle: Bundle, userDriver: SPUUserDriver, delegate: SPUUpdaterDelegate?) {
        self.hostBundle = hostBundle
        self.userDriver = userDriver
        self.delegate = delegate
        super.init()
    }

    /// Starts the updater. Throws, as Sparkle does for a misconfigured
    /// app: updating isn't available on this platform.
    @objc open func start() throws { throw unavailableError }

    /// Sparkle's Objective-C name for `start()`.
    @objc open func startUpdater() throws { try start() }

    @objc open func checkForUpdates() {}
    @objc open func checkForUpdatesInBackground() {}
    @objc open func checkForUpdateInformation() {}
    @objc open func resetUpdateCycle() {}
    @objc open func resetUpdateCycleAfterShortDelay() {}

    /// False: there is no update to look for.
    @objc open dynamic private(set) var canCheckForUpdates: Bool = false
    @objc open dynamic private(set) var sessionInProgress: Bool = false
    @objc open dynamic var automaticallyChecksForUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks") }
        set { UserDefaults.standard.set(newValue, forKey: "SUEnableAutomaticChecks") }
    }
    @objc open dynamic var automaticallyDownloadsUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: "SUAutomaticallyUpdate") }
        set { UserDefaults.standard.set(newValue, forKey: "SUAutomaticallyUpdate") }
    }
    @objc open dynamic var allowsAutomaticUpdates: Bool { false }
    @objc open dynamic var updateCheckInterval: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: "SUScheduledCheckInterval")
            return v > 0 ? v : 86400
        }
        set { UserDefaults.standard.set(newValue, forKey: "SUScheduledCheckInterval") }
    }
    @objc open dynamic private(set) var lastUpdateCheckDate: Date?
    @objc open dynamic var sendsSystemProfile: Bool = false
    @objc open var feedURL: URL? {
        if let s = UserDefaults.standard.string(forKey: "SUFeedURL") ?? hostBundle.object(forInfoDictionaryKey: "SUFeedURL") as? String {
            return URL(string: s)
        }
        return nil
    }
    @objc open var userAgentString: String = "Sparkle"
    @objc open var httpHeaders: [String: String]?
    @objc open var systemProfileArray: [[String: String]] { [] }

    @objc open func setFeedURL(_ feedURL: URL?) {
        if let feedURL { UserDefaults.standard.set(feedURL.absoluteString, forKey: "SUFeedURL") }
        else { UserDefaults.standard.removeObject(forKey: "SUFeedURL") }
    }

    @discardableResult
    @objc open func clearFeedURLFromUserDefaults() -> URL? {
        let old = UserDefaults.standard.string(forKey: "SUFeedURL").flatMap(URL.init(string:))
        UserDefaults.standard.removeObject(forKey: "SUFeedURL")
        return old
    }
}

/// The controller apps put in their nib or create in code. `updater`
/// never checks; the "Check for Updates…" action does nothing.
@objc open class SPUStandardUpdaterController: NSObject {
    @objc public private(set) var updater: SPUUpdater
    @objc public private(set) var userDriver: SPUStandardUserDriver
    @objc public weak var updaterDelegate: SPUUpdaterDelegate?
    @objc public weak var userDriverDelegate: SPUStandardUserDriverDelegate?

    @objc public init(startingUpdater: Bool, updaterDelegate: SPUUpdaterDelegate?, userDriverDelegate: SPUStandardUserDriverDelegate?) {
        self.updaterDelegate = updaterDelegate
        self.userDriverDelegate = userDriverDelegate
        userDriver = SPUStandardUserDriver(hostBundle: .main, delegate: userDriverDelegate)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: updaterDelegate)
        super.init()
        if startingUpdater { startUpdater() }
    }

    /// Sparkle's convenience initializer (`startingUpdater: true`).
    @objc public convenience init(updaterDelegate: SPUUpdaterDelegate?, userDriverDelegate: SPUStandardUserDriverDelegate?) {
        self.init(startingUpdater: true, updaterDelegate: updaterDelegate, userDriverDelegate: userDriverDelegate)
    }

    @objc public override convenience init() {
        self.init(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }

    /// Starts the updater; failing to (always, here) is not an error the app sees.
    @objc open func startUpdater() { try? updater.start() }

    @objc open func checkForUpdates(_ sender: Any?) { updater.checkForUpdates() }
}

// MARK: Sparkle 1

/// Sparkle 1's updater singleton.
@objc open class SUUpdater: NSObject {
    private static let sharedUpdater = SUUpdater()
    @objc public static func shared() -> SUUpdater { sharedUpdater }
    @objc public convenience init(for bundle: Bundle) { self.init() }

    @objc public weak var delegate: AnyObject?
    @objc open var automaticallyChecksForUpdates: Bool = false
    @objc open var automaticallyDownloadsUpdates: Bool = false
    @objc open var updateCheckInterval: TimeInterval = 86400
    @objc open var feedURL: URL?
    @objc open var sendsSystemProfile: Bool = false
    @objc open var lastUpdateCheckDate: Date? { nil }
    @objc open var updateInProgress: Bool { false }

    @objc open func checkForUpdates(_ sender: Any?) {}
    @objc open func checkForUpdatesInBackground() {}
    @objc open func checkForUpdateInformation() {}
    @objc open func validateMenuItem(_ item: AnyObject) -> Bool { false }
}
