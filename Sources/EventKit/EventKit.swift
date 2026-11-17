// EventKit for Linux and Windows: calendar and reminder access answer as
// on a Mac where the user denied it (status .denied, requests complete with
// false, queries return nothing, saves throw eventStoreNotAuthorized).

@_exported import Foundation

public let EKErrorDomain = "EKErrorDomain"

public enum EKEntityType: UInt, Sendable { case event = 0, reminder = 1 }
public struct EKEntityMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let event = EKEntityMask(rawValue: 1)
    public static let reminder = EKEntityMask(rawValue: 2)
}
public enum EKAuthorizationStatus: Int, Sendable {
    case notDetermined = 0, restricted, denied, fullAccess, writeOnly
    public static var authorized: EKAuthorizationStatus { .fullAccess }
}
public enum EKSpan: Int, Sendable { case thisEvent = 0, futureEvents }
public enum EKCalendarType: Int, Sendable { case local = 0, calDAV, exchange, subscription, birthday }
public enum EKEventAvailability: Int, Sendable { case notSupported = -1, busy = 0, free, tentative, unavailable }
public enum EKEventStatus: Int, Sendable { case none = 0, confirmed, tentative, canceled }
public enum EKRecurrenceFrequency: Int, Sendable { case daily = 0, weekly, monthly, yearly }

public struct EKError: CustomNSError, Hashable, Error, Sendable {
    public enum Code: Int, Sendable {
        case eventNotMutable = 0, noCalendar, noStartDate, noEndDate, datesInverted, internalFailure, calendarReadOnly
        case durationGreaterThanRecurrence, alarmGreaterThanRecurrence, startDateTooFarInFuture, startDateCollidesWithOtherOccurrence
        case objectBelongsToDifferentStore, invitesCannotBeMoved, invalidSpan, calendarHasNoSource, calendarSourceCannotBeModified
        case calendarIsImmutable, sourceDoesNotAllowCalendarAddDelete, recurringReminderRequiresDueDate, structuredLocationsNotSupported
        case reminderLocationsNotSupported, alarmProximityNotSupported, calendarDoesNotAllowEvents, calendarDoesNotAllowReminders
        case sourceDoesNotAllowReminders, sourceDoesNotAllowEvents, priorityIsInvalid, invalidEntityType, procedureAlarmsNotMutable
        case eventStoreNotAuthorized, osNotSupported, invalidInviteReplyCalendar, notificationsCollectionFlagNotSet
        case sourceMismatch, notificationCollectionMismatch, notificationSavedWithoutCollection, reminderAlarmContainsEmailOrUrl
    }
    public let code: Code
    public init(_ code: Code) { self.code = code }
    public static var errorDomain: String { EKErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { [:] }
}

open class EKObject: NSObject, @unchecked Sendable {
    open var hasChanges: Bool { false }
    open func reset() {}
    open func rollback() {}
    open func refresh() -> Bool { false }
}

open class EKSource: EKObject, @unchecked Sendable {
    open var sourceIdentifier: String { "" }
    open var title: String { "" }
}

open class EKCalendar: EKObject, @unchecked Sendable {
    open var calendarIdentifier: String = UUID().uuidString
    open var title: String = ""
    open var type: EKCalendarType = .local
    open var allowsContentModifications: Bool { false }
    open var isSubscribed: Bool { false }
    open var isImmutable: Bool { true }
    open var cgColor: AnyObject?
    open var source: EKSource?
    public init(for entityType: EKEntityType, eventStore: EKEventStore) {}
}

open class EKAlarm: EKObject, @unchecked Sendable {
    open var relativeOffset: TimeInterval = 0
    open var absoluteDate: Date?
    public init(relativeOffset: TimeInterval) { self.relativeOffset = relativeOffset }
    public init(absoluteDate: Date) { self.absoluteDate = absoluteDate }
}

open class EKRecurrenceRule: EKObject, @unchecked Sendable {
    open var frequency: EKRecurrenceFrequency
    open var interval: Int
    public init(recurrenceWith type: EKRecurrenceFrequency, interval: Int, end: EKRecurrenceEnd?) { frequency = type; self.interval = interval }
}
open class EKRecurrenceEnd: NSObject, @unchecked Sendable {
    public convenience init(end: Date) { self.init() }
    public convenience init(occurrenceCount: Int) { self.init() }
}

open class EKCalendarItem: EKObject, @unchecked Sendable {
    open var calendarItemIdentifier: String = UUID().uuidString
    open var calendarItemExternalIdentifier: String?
    open var calendar: EKCalendar!
    open var title: String! = ""
    open var location: String?
    open var notes: String?
    open var url: URL?
    open var creationDate: Date?
    open var lastModifiedDate: Date?
    open var timeZone: TimeZone?
    open var alarms: [EKAlarm]?
    open var recurrenceRules: [EKRecurrenceRule]?
    open var hasAlarms: Bool { !(alarms ?? []).isEmpty }
    open var hasRecurrenceRules: Bool { !(recurrenceRules ?? []).isEmpty }
    open func addAlarm(_ alarm: EKAlarm) { alarms = (alarms ?? []) + [alarm] }
    open func removeAlarm(_ alarm: EKAlarm) { alarms?.removeAll { $0 === alarm } }
    open func addRecurrenceRule(_ rule: EKRecurrenceRule) { recurrenceRules = (recurrenceRules ?? []) + [rule] }
    open func removeRecurrenceRule(_ rule: EKRecurrenceRule) { recurrenceRules?.removeAll { $0 === rule } }
}

open class EKEvent: EKCalendarItem, @unchecked Sendable {
    open var eventIdentifier: String! { calendarItemIdentifier }
    open var startDate: Date!
    open var endDate: Date!
    open var isAllDay = false
    open var availability: EKEventAvailability = .busy
    open var status: EKEventStatus { .none }
    open var occurrenceDate: Date! { startDate }
    public init(eventStore: EKEventStore) {}
    open func compareStartDate(with other: EKEvent) -> ComparisonResult {
        (startDate ?? .distantPast) < (other.startDate ?? .distantPast) ? .orderedAscending : .orderedDescending
    }
}

open class EKReminder: EKCalendarItem, @unchecked Sendable {
    open var startDateComponents: DateComponents?
    open var dueDateComponents: DateComponents?
    open var isCompleted = false
    open var completionDate: Date?
    open var priority = 0
    public init(eventStore: EKEventStore) {}
}

public extension Notification.Name {
    static let EKEventStoreChanged = Notification.Name("EKEventStoreChangedNotification")
}

open class EKEventStore: NSObject, @unchecked Sendable {
    public typealias EKEventStoreRequestAccessCompletionHandler = @Sendable (Bool, Error?) -> Void

    public override init() { super.init() }
    public init(sources: [EKSource]) { super.init() }

    open class func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus { .denied }

    open func requestAccess(to entityType: EKEntityType, completion: @escaping EKEventStoreRequestAccessCompletionHandler) {
        DispatchQueue.main.async { completion(false, nil) }
    }
    open func requestAccess(to entityType: EKEntityType) async throws -> Bool { false }
    open func requestFullAccessToEvents(completion: @escaping EKEventStoreRequestAccessCompletionHandler) { requestAccess(to: .event, completion: completion) }
    open func requestFullAccessToEvents() async throws -> Bool { false }
    open func requestWriteOnlyAccessToEvents(completion: @escaping EKEventStoreRequestAccessCompletionHandler) { requestAccess(to: .event, completion: completion) }
    open func requestWriteOnlyAccessToEvents() async throws -> Bool { false }
    open func requestFullAccessToReminders(completion: @escaping EKEventStoreRequestAccessCompletionHandler) { requestAccess(to: .reminder, completion: completion) }
    open func requestFullAccessToReminders() async throws -> Bool { false }

    open var eventStoreIdentifier: String { "" }
    open var sources: [EKSource] { [] }
    open var delegateSources: [EKSource] { [] }
    open var defaultCalendarForNewEvents: EKCalendar? { nil }
    open func defaultCalendarForNewReminders() -> EKCalendar? { nil }
    open func calendars(for entityType: EKEntityType) -> [EKCalendar] { [] }
    open func calendar(withIdentifier identifier: String) -> EKCalendar? { nil }
    open func source(withIdentifier identifier: String) -> EKSource? { nil }

    open func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate { NSPredicate(value: false) }
    open func predicateForReminders(in calendars: [EKCalendar]?) -> NSPredicate { NSPredicate(value: false) }
    open func predicateForIncompleteReminders(withDueDateStarting startDate: Date?, ending endDate: Date?, calendars: [EKCalendar]?) -> NSPredicate { NSPredicate(value: false) }
    open func predicateForCompletedReminders(withCompletionDateStarting startDate: Date?, ending endDate: Date?, calendars: [EKCalendar]?) -> NSPredicate { NSPredicate(value: false) }
    open func events(matching predicate: NSPredicate) -> [EKEvent] { [] }
    open func enumerateEvents(matching predicate: NSPredicate, using block: (EKEvent, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    open func fetchReminders(matching predicate: NSPredicate, completion: @escaping @Sendable ([EKReminder]?) -> Void) -> Any {
        DispatchQueue.main.async { completion([]) }
        return NSObject()
    }
    open func cancelFetchRequest(_ fetchIdentifier: Any) {}
    open func event(withIdentifier identifier: String) -> EKEvent? { nil }
    open func calendarItem(withIdentifier identifier: String) -> EKCalendarItem? { nil }

    open func save(_ event: EKEvent, span: EKSpan) throws { throw EKError(.eventStoreNotAuthorized) }
    open func save(_ event: EKEvent, span: EKSpan, commit: Bool) throws { throw EKError(.eventStoreNotAuthorized) }
    open func remove(_ event: EKEvent, span: EKSpan) throws { throw EKError(.eventStoreNotAuthorized) }
    open func remove(_ event: EKEvent, span: EKSpan, commit: Bool) throws { throw EKError(.eventStoreNotAuthorized) }
    open func save(_ reminder: EKReminder, commit: Bool) throws { throw EKError(.eventStoreNotAuthorized) }
    open func remove(_ reminder: EKReminder, commit: Bool) throws { throw EKError(.eventStoreNotAuthorized) }
    open func saveCalendar(_ calendar: EKCalendar, commit: Bool) throws { throw EKError(.eventStoreNotAuthorized) }
    open func removeCalendar(_ calendar: EKCalendar, commit: Bool) throws { throw EKError(.eventStoreNotAuthorized) }
    open func commit() throws {}
    open func reset() {}
    open func refreshSourcesIfNecessary() {}
}
