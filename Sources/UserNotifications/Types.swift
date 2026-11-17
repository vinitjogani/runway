// UserNotifications' value types: options, settings, content, triggers,
// requests, actions, categories, responses, errors.

@_exported import Foundation

public let UNErrorDomain = "UNErrorDomain"
public let UNNotificationDefaultActionIdentifier = "com.apple.UNNotificationDefaultActionIdentifier"
public let UNNotificationDismissActionIdentifier = "com.apple.UNNotificationDismissActionIdentifier"

public struct UNError: CustomNSError, Hashable, Sendable {
    public enum Code: Int, Sendable {
        case notificationsNotAllowed = 1
        case attachmentInvalidURL = 100
        case attachmentUnrecognizedType = 101
        case attachmentInvalidFileSize = 102
        case attachmentNotInDataStore = 103
        case attachmentMoveIntoDataStoreFailed = 104
        case attachmentCorrupt = 105
        case notificationInvalidNoDate = 1400
        case notificationInvalidNoContent = 1401
        case contentProvidingObjectNotAllowed = 1500
        case contentProvidingInvalid = 1501
        case badgeInputInvalid = 1600
    }
    public let code: Code
    public init(_ code: Code) { self.code = code }
    public static var errorDomain: String { UNErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { [:] }
    public static var notificationsNotAllowed: Code { .notificationsNotAllowed }
    public static var attachmentInvalidURL: Code { .attachmentInvalidURL }
    public static var notificationInvalidNoContent: Code { .notificationInvalidNoContent }
    public static var notificationInvalidNoDate: Code { .notificationInvalidNoDate }
}

public func ~= (match: UNError.Code, error: Error) -> Bool { (error as? UNError)?.code == match }

public struct UNAuthorizationOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let badge = UNAuthorizationOptions(rawValue: 1 << 0)
    public static let sound = UNAuthorizationOptions(rawValue: 1 << 1)
    public static let alert = UNAuthorizationOptions(rawValue: 1 << 2)
    public static let carPlay = UNAuthorizationOptions(rawValue: 1 << 3)
    public static let criticalAlert = UNAuthorizationOptions(rawValue: 1 << 4)
    public static let providesAppNotificationSettings = UNAuthorizationOptions(rawValue: 1 << 5)
    public static let provisional = UNAuthorizationOptions(rawValue: 1 << 6)
    public static let announcement = UNAuthorizationOptions(rawValue: 1 << 7)
    public static let timeSensitive = UNAuthorizationOptions(rawValue: 1 << 8)
}

public enum UNAuthorizationStatus: Int, Sendable {
    case notDetermined = 0, denied, authorized, provisional, ephemeral
}

public enum UNNotificationSetting: Int, Sendable {
    case notSupported = 0, disabled, enabled
}

public enum UNAlertStyle: Int, Sendable {
    case none = 0, banner, alert
}

public enum UNShowPreviewsSetting: Int, Sendable {
    case always = 0, whenAuthenticated, never
}

public struct UNNotificationPresentationOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let badge = UNNotificationPresentationOptions(rawValue: 1 << 0)
    public static let sound = UNNotificationPresentationOptions(rawValue: 1 << 1)
    public static let alert = UNNotificationPresentationOptions(rawValue: 1 << 2)
    public static let list = UNNotificationPresentationOptions(rawValue: 1 << 3)
    public static let banner = UNNotificationPresentationOptions(rawValue: 1 << 4)
}

public enum UNNotificationInterruptionLevel: UInt, Sendable {
    case passive = 0, active, timeSensitive, critical
}

open class UNNotificationSettings: NSObject, @unchecked Sendable {
    open internal(set) var authorizationStatus: UNAuthorizationStatus
    open internal(set) var soundSetting: UNNotificationSetting
    open internal(set) var badgeSetting: UNNotificationSetting
    open internal(set) var alertSetting: UNNotificationSetting
    open internal(set) var notificationCenterSetting: UNNotificationSetting
    open internal(set) var lockScreenSetting: UNNotificationSetting
    open internal(set) var carPlaySetting: UNNotificationSetting = .notSupported
    open internal(set) var criticalAlertSetting: UNNotificationSetting = .notSupported
    open internal(set) var announcementSetting: UNNotificationSetting = .notSupported
    open internal(set) var timeSensitiveSetting: UNNotificationSetting = .notSupported
    open internal(set) var scheduledDeliverySetting: UNNotificationSetting = .notSupported
    open internal(set) var directMessagesSetting: UNNotificationSetting = .notSupported
    open internal(set) var alertStyle: UNAlertStyle
    open internal(set) var showPreviewsSetting: UNShowPreviewsSetting = .always
    open internal(set) var providesAppNotificationSettings: Bool = false

    init(status: UNAuthorizationStatus, sound: Bool) {
        authorizationStatus = status
        let on: UNNotificationSetting = status == .authorized || status == .provisional ? .enabled : (status == .notDetermined ? .notSupported : .disabled)
        soundSetting = sound ? on : (on == .enabled ? .disabled : on)
        badgeSetting = .notSupported
        alertSetting = on
        notificationCenterSetting = on
        lockScreenSetting = on
        alertStyle = on == .enabled ? .banner : .none
    }
}

public struct UNNotificationSoundName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

open class UNNotificationSound: NSObject, @unchecked Sendable {
    let name: UNNotificationSoundName?
    let critical: Bool
    init(name: UNNotificationSoundName?, critical: Bool) { self.name = name; self.critical = critical }
    open class var `default`: UNNotificationSound { UNNotificationSound(name: nil, critical: false) }
    open class var defaultCritical: UNNotificationSound { UNNotificationSound(name: nil, critical: true) }
    open class var defaultRingtone: UNNotificationSound { UNNotificationSound(name: nil, critical: false) }
    public convenience init(named name: UNNotificationSoundName) { self.init(name: name, critical: false) }
    open class func soundNamed(_ name: UNNotificationSoundName) -> UNNotificationSound { UNNotificationSound(name: name, critical: false) }
    open class func criticalSoundNamed(_ name: UNNotificationSoundName) -> UNNotificationSound { UNNotificationSound(name: name, critical: true) }
    open class func criticalSoundNamed(_ name: UNNotificationSoundName, withAudioVolume volume: Float) -> UNNotificationSound {
        UNNotificationSound(name: name, critical: true)
    }
    open class func defaultCriticalSound(withAudioVolume volume: Float) -> UNNotificationSound { .defaultCritical }
}

open class UNNotificationAttachment: NSObject, @unchecked Sendable {
    open private(set) var identifier: String
    open private(set) var url: URL
    open private(set) var type: String
    public init(identifier: String, url URL: URL, options: [AnyHashable: Any]? = nil) throws {
        guard URL.isFileURL, FileManager.default.fileExists(atPath: URL.path) else { throw UNError(.attachmentInvalidURL) }
        self.identifier = identifier
        self.url = URL
        let ext = URL.pathExtension.lowercased()
        type = ["png": "public.png", "jpg": "public.jpeg", "jpeg": "public.jpeg", "gif": "com.compuserve.gif"][ext] ?? "public.data"
    }
}

open class UNNotificationContent: NSObject, NSCopying, NSMutableCopying, @unchecked Sendable {
    open internal(set) var title: String = ""
    open internal(set) var subtitle: String = ""
    open internal(set) var body: String = ""
    open internal(set) var badge: NSNumber?
    open internal(set) var sound: UNNotificationSound?
    open internal(set) var launchImageName: String = ""
    open internal(set) var userInfo: [AnyHashable: Any] = [:]
    open internal(set) var attachments: [UNNotificationAttachment] = []
    open internal(set) var categoryIdentifier: String = ""
    open internal(set) var threadIdentifier: String = ""
    open internal(set) var targetContentIdentifier: String?
    open internal(set) var summaryArgument: String = ""
    open internal(set) var summaryArgumentCount: Int = 0
    open internal(set) var interruptionLevel: UNNotificationInterruptionLevel = .active
    open internal(set) var relevanceScore: Double = 0
    open internal(set) var filterCriteria: String?

    public override init() { super.init() }

    func copyFields(to c: UNNotificationContent) {
        c.title = title; c.subtitle = subtitle; c.body = body; c.badge = badge; c.sound = sound
        c.launchImageName = launchImageName; c.userInfo = userInfo; c.attachments = attachments
        c.categoryIdentifier = categoryIdentifier; c.threadIdentifier = threadIdentifier
        c.targetContentIdentifier = targetContentIdentifier; c.summaryArgument = summaryArgument
        c.summaryArgumentCount = summaryArgumentCount; c.interruptionLevel = interruptionLevel
        c.relevanceScore = relevanceScore; c.filterCriteria = filterCriteria
    }
    open func copy(with zone: NSZone? = nil) -> Any { let c = UNNotificationContent(); copyFields(to: c); return c }
    open func mutableCopy(with zone: NSZone? = nil) -> Any { let c = UNMutableNotificationContent(); copyFields(to: c); return c }
}

open class UNMutableNotificationContent: UNNotificationContent, @unchecked Sendable {
    open override var title: String { get { super.title } set { super.title = newValue } }
    open override var subtitle: String { get { super.subtitle } set { super.subtitle = newValue } }
    open override var body: String { get { super.body } set { super.body = newValue } }
    open override var badge: NSNumber? { get { super.badge } set { super.badge = newValue } }
    open override var sound: UNNotificationSound? { get { super.sound } set { super.sound = newValue } }
    open override var launchImageName: String { get { super.launchImageName } set { super.launchImageName = newValue } }
    open override var userInfo: [AnyHashable: Any] { get { super.userInfo } set { super.userInfo = newValue } }
    open override var attachments: [UNNotificationAttachment] { get { super.attachments } set { super.attachments = newValue } }
    open override var categoryIdentifier: String { get { super.categoryIdentifier } set { super.categoryIdentifier = newValue } }
    open override var threadIdentifier: String { get { super.threadIdentifier } set { super.threadIdentifier = newValue } }
    open override var targetContentIdentifier: String? { get { super.targetContentIdentifier } set { super.targetContentIdentifier = newValue } }
    open override var summaryArgument: String { get { super.summaryArgument } set { super.summaryArgument = newValue } }
    open override var summaryArgumentCount: Int { get { super.summaryArgumentCount } set { super.summaryArgumentCount = newValue } }
    open override var interruptionLevel: UNNotificationInterruptionLevel { get { super.interruptionLevel } set { super.interruptionLevel = newValue } }
    open override var relevanceScore: Double { get { super.relevanceScore } set { super.relevanceScore = newValue } }
    open override var filterCriteria: String? { get { super.filterCriteria } set { super.filterCriteria = newValue } }
}

// MARK: Triggers

open class UNNotificationTrigger: NSObject, @unchecked Sendable {
    open private(set) var repeats: Bool
    init(repeats: Bool) { self.repeats = repeats }
    /// The next time this trigger fires after `date` (nil: never again).
    func next(after date: Date) -> Date? { nil }
}

open class UNPushNotificationTrigger: UNNotificationTrigger, @unchecked Sendable {}

open class UNTimeIntervalNotificationTrigger: UNNotificationTrigger, @unchecked Sendable {
    open private(set) var timeInterval: TimeInterval
    let created = Date()
    public init(timeInterval: TimeInterval, repeats: Bool) {
        precondition(timeInterval > 0, "time interval must be greater than 0")
        precondition(!repeats || timeInterval >= 60, "time interval must be at least 60 if repeating")
        self.timeInterval = timeInterval
        super.init(repeats: repeats)
    }
    open func nextTriggerDate() -> Date? { next(after: Date()) }
    override func next(after date: Date) -> Date? {
        let first = created.addingTimeInterval(timeInterval)
        if date < first { return first }
        guard repeats else { return nil }
        let n = ((date.timeIntervalSince(first)) / timeInterval).rounded(.down) + 1
        return first.addingTimeInterval(n * timeInterval)
    }
}

open class UNCalendarNotificationTrigger: UNNotificationTrigger, @unchecked Sendable {
    open private(set) var dateComponents: DateComponents
    public init(dateMatching dateComponents: DateComponents, repeats: Bool) {
        self.dateComponents = dateComponents
        super.init(repeats: repeats)
    }
    open func nextTriggerDate() -> Date? { next(after: Date()) }
    override func next(after date: Date) -> Date? {
        let cal = dateComponents.calendar ?? Calendar.current
        var comps = dateComponents
        comps.calendar = nil
        comps.timeZone = nil
        if let d = cal.date(from: dateComponents), comps.year != nil { return d > date ? d : nil }
        return cal.nextDate(after: date, matching: comps, matchingPolicy: .nextTime)
    }
}

// MARK: Requests, notifications, responses

open class UNNotificationRequest: NSObject, @unchecked Sendable {
    open private(set) var identifier: String
    open private(set) var content: UNNotificationContent
    open private(set) var trigger: UNNotificationTrigger?
    public init(identifier: String, content: UNNotificationContent, trigger: UNNotificationTrigger?) {
        self.identifier = identifier
        self.content = content.copy() as! UNNotificationContent
        self.trigger = trigger
    }
}

open class UNNotification: NSObject, @unchecked Sendable {
    open private(set) var date: Date
    open private(set) var request: UNNotificationRequest
    init(date: Date, request: UNNotificationRequest) { self.date = date; self.request = request }
}

open class UNNotificationResponse: NSObject, @unchecked Sendable {
    open private(set) var notification: UNNotification
    open private(set) var actionIdentifier: String
    open private(set) var targetScene: AnyObject?
    init(notification: UNNotification, actionIdentifier: String) { self.notification = notification; self.actionIdentifier = actionIdentifier }
}

open class UNTextInputNotificationResponse: UNNotificationResponse, @unchecked Sendable {
    open private(set) var userText: String
    init(notification: UNNotification, actionIdentifier: String, userText: String) {
        self.userText = userText
        super.init(notification: notification, actionIdentifier: actionIdentifier)
    }
}

// MARK: Actions and categories

public struct UNNotificationActionOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let authenticationRequired = UNNotificationActionOptions(rawValue: 1 << 0)
    public static let destructive = UNNotificationActionOptions(rawValue: 1 << 1)
    public static let foreground = UNNotificationActionOptions(rawValue: 1 << 2)
}

open class UNNotificationActionIcon: NSObject, @unchecked Sendable {
    let name: String
    init(name: String) { self.name = name }
    public convenience init(templateImageName: String) { self.init(name: templateImageName) }
    public convenience init(systemImageName: String) { self.init(name: systemImageName) }
}

open class UNNotificationAction: NSObject, @unchecked Sendable {
    open private(set) var identifier: String
    open private(set) var title: String
    open private(set) var options: UNNotificationActionOptions
    open private(set) var icon: UNNotificationActionIcon?
    public init(identifier: String, title: String, options: UNNotificationActionOptions = []) {
        self.identifier = identifier; self.title = title; self.options = options
    }
    public init(identifier: String, title: String, options: UNNotificationActionOptions = [], icon: UNNotificationActionIcon?) {
        self.identifier = identifier; self.title = title; self.options = options; self.icon = icon
    }
}

open class UNTextInputNotificationAction: UNNotificationAction, @unchecked Sendable {
    open private(set) var textInputButtonTitle: String = ""
    open private(set) var textInputPlaceholder: String = ""
    public init(identifier: String, title: String, options: UNNotificationActionOptions = [], textInputButtonTitle: String, textInputPlaceholder: String) {
        self.textInputButtonTitle = textInputButtonTitle
        self.textInputPlaceholder = textInputPlaceholder
        super.init(identifier: identifier, title: title, options: options)
    }
    public init(identifier: String, title: String, options: UNNotificationActionOptions = [], icon: UNNotificationActionIcon?,
                textInputButtonTitle: String, textInputPlaceholder: String) {
        self.textInputButtonTitle = textInputButtonTitle
        self.textInputPlaceholder = textInputPlaceholder
        super.init(identifier: identifier, title: title, options: options, icon: icon)
    }
}

public struct UNNotificationCategoryOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let customDismissAction = UNNotificationCategoryOptions(rawValue: 1 << 0)
    public static let allowInCarPlay = UNNotificationCategoryOptions(rawValue: 1 << 1)
    public static let hiddenPreviewsShowTitle = UNNotificationCategoryOptions(rawValue: 1 << 2)
    public static let hiddenPreviewsShowSubtitle = UNNotificationCategoryOptions(rawValue: 1 << 3)
    public static let allowAnnouncement = UNNotificationCategoryOptions(rawValue: 1 << 4)
}

open class UNNotificationCategory: NSObject, @unchecked Sendable {
    open private(set) var identifier: String
    open private(set) var actions: [UNNotificationAction]
    open private(set) var intentIdentifiers: [String]
    open private(set) var options: UNNotificationCategoryOptions
    open private(set) var hiddenPreviewsBodyPlaceholder: String = ""
    open private(set) var categorySummaryFormat: String = ""

    public init(identifier: String, actions: [UNNotificationAction], intentIdentifiers: [String], options: UNNotificationCategoryOptions = []) {
        self.identifier = identifier; self.actions = actions; self.intentIdentifiers = intentIdentifiers; self.options = options
    }
    public convenience init(identifier: String, actions: [UNNotificationAction], intentIdentifiers: [String],
                            hiddenPreviewsBodyPlaceholder: String, options: UNNotificationCategoryOptions = []) {
        self.init(identifier: identifier, actions: actions, intentIdentifiers: intentIdentifiers, options: options)
        self.hiddenPreviewsBodyPlaceholder = hiddenPreviewsBodyPlaceholder
    }
    public convenience init(identifier: String, actions: [UNNotificationAction], intentIdentifiers: [String],
                            hiddenPreviewsBodyPlaceholder: String?, categorySummaryFormat: String?, options: UNNotificationCategoryOptions = []) {
        self.init(identifier: identifier, actions: actions, intentIdentifiers: intentIdentifiers, options: options)
        self.hiddenPreviewsBodyPlaceholder = hiddenPreviewsBodyPlaceholder ?? ""
        self.categorySummaryFormat = categorySummaryFormat ?? ""
    }
    open override var hash: Int { identifier.hashValue }
    open override func isEqual(_ object: Any?) -> Bool { (object as? UNNotificationCategory)?.identifier == identifier }
}
