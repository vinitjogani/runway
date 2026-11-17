// CloudKit for Linux and Windows: there's no iCloud account, so
// accountStatus is .noAccount and every database request and operation
// completes with CKError(.notAuthenticated), the error apps already handle
// for a signed-out Mac. Records, IDs, zones, queries and references are
// real values.

@_exported import Foundation

public let CKErrorDomain = "CKErrorDomain"
public let CKPartialErrorsByItemIDKey = "CKPartialErrors"
public let CKErrorRetryAfterKey = "CKRetryAfter"
public let CKRecordChangedErrorServerRecordKey = "ServerRecord"
public let CKRecordChangedErrorClientRecordKey = "ClientRecord"
public let CKRecordChangedErrorAncestorRecordKey = "AncestorRecord"
public let CKCurrentUserDefaultName = "__defaultOwner__"
public let CKOwnerDefaultName = "__defaultOwner__"
public let CKRecordZoneDefaultName = "_defaultZone"

public enum CKAccountStatus: Int, Sendable { case couldNotDetermine = 0, available, restricted, noAccount, temporarilyUnavailable }
public enum CKDatabaseScope: Int, Sendable { case `public` = 1, `private`, shared }

public extension Notification.Name {
    static let CKAccountChanged = Notification.Name("CKAccountChangedNotification")
}

public struct CKError: CustomNSError, Hashable, Error, Sendable {
    public enum Code: Int, Sendable {
        case internalError = 1, partialFailure, networkUnavailable, networkFailure, badContainer, serviceUnavailable
        case requestRateLimited, missingEntitlement, notAuthenticated, permissionFailure, unknownItem, invalidArguments
        case resultsTruncated, serverRecordChanged, serverRejectedRequest, assetFileNotFound, assetFileModified
        case incompatibleVersion, constraintViolation, operationCancelled, changeTokenExpired, batchRequestFailed
        case zoneBusy, badDatabase, quotaExceeded, zoneNotFound, limitExceeded, userDeletedZone, tooManyParticipants
        case alreadyShared, referenceViolation, managedAccountRestricted, participantMayNeedVerification
        case serverResponseLost, assetNotAvailable, accountTemporarilyUnavailable
    }
    public let code: Code
    public let errorUserInfo: [String: Any]
    public init(_ code: Code, userInfo: [String: Any] = [:]) { self.code = code; errorUserInfo = userInfo }
    public static var errorDomain: String { CKErrorDomain }
    public var errorCode: Int { code.rawValue }
    public static func == (a: CKError, b: CKError) -> Bool { a.code == b.code }
    public func hash(into h: inout Hasher) { h.combine(code) }
    public var partialErrorsByItemID: [AnyHashable: Error]? { errorUserInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] }
    public var retryAfterSeconds: Double? { errorUserInfo[CKErrorRetryAfterKey] as? Double }
    public var serverRecord: CKRecord? { errorUserInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord }
    public var clientRecord: CKRecord? { errorUserInfo[CKRecordChangedErrorClientRecordKey] as? CKRecord }
    public var ancestorRecord: CKRecord? { errorUserInfo[CKRecordChangedErrorAncestorRecordKey] as? CKRecord }
    public static var notAuthenticated: Code { .notAuthenticated }
    public static var networkFailure: Code { .networkFailure }
    public static var networkUnavailable: Code { .networkUnavailable }
    public static var partialFailure: Code { .partialFailure }
    public static var unknownItem: Code { .unknownItem }
    public static var zoneNotFound: Code { .zoneNotFound }
    public static var serverRecordChanged: Code { .serverRecordChanged }
    public static var changeTokenExpired: Code { .changeTokenExpired }
    public static var userDeletedZone: Code { .userDeletedZone }
    public static var requestRateLimited: Code { .requestRateLimited }
    public static var serviceUnavailable: Code { .serviceUnavailable }
    public static var zoneBusy: Code { .zoneBusy }
    public static var operationCancelled: Code { .operationCancelled }
}

public func ~= (code: CKError.Code, error: Error) -> Bool { (error as? CKError)?.code == code }

let notSignedIn = CKError(.notAuthenticated)

public protocol CKRecordValueProtocol {}
public typealias CKRecordValue = CKRecordValueProtocol
extension String: CKRecordValueProtocol {}
extension NSString: CKRecordValueProtocol {}
extension Int: CKRecordValueProtocol {}
extension Int64: CKRecordValueProtocol {}
extension Double: CKRecordValueProtocol {}
extension Bool: CKRecordValueProtocol {}
extension Date: CKRecordValueProtocol {}
extension Data: CKRecordValueProtocol {}
extension NSNumber: CKRecordValueProtocol {}
extension Array: CKRecordValueProtocol where Element: CKRecordValueProtocol {}

open class CKServerChangeToken: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }
    override init() {}
    public required init?(coder: NSCoder) {}
    public func encode(with coder: NSCoder) {}
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

open class CKRecordZone: NSObject, @unchecked Sendable {
    public final class ID: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
        public let zoneName: String
        public let ownerName: String
        public init(zoneName: String = CKRecordZoneDefaultName, ownerName: String = CKCurrentUserDefaultName) {
            self.zoneName = zoneName; self.ownerName = ownerName
        }
        public static let `default` = ID()
        public static var supportsSecureCoding: Bool { true }
        public init?(coder: NSCoder) {
            zoneName = coder.decodeObject(forKey: "zoneName") as? String ?? CKRecordZoneDefaultName
            ownerName = coder.decodeObject(forKey: "ownerName") as? String ?? CKCurrentUserDefaultName
        }
        public func encode(with coder: NSCoder) { coder.encode(zoneName, forKey: "zoneName"); coder.encode(ownerName, forKey: "ownerName") }
        public func copy(with zone: NSZone? = nil) -> Any { self }
        public override func isEqual(_ object: Any?) -> Bool { (object as? ID).map { $0.zoneName == zoneName && $0.ownerName == ownerName } ?? false }
        public override var hash: Int { zoneName.hashValue ^ ownerName.hashValue }
    }
    public let zoneID: ID
    public init(zoneName: String) { zoneID = ID(zoneName: zoneName) }
    public init(zoneID: ID) { self.zoneID = zoneID }
    public class func `default`() -> CKRecordZone { CKRecordZone(zoneID: .default) }
}

open class CKRecord: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    public typealias RecordType = String
    public typealias FieldKey = String

    public final class ID: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
        public let recordName: String
        public let zoneID: CKRecordZone.ID
        public init(recordName: String = UUID().uuidString, zoneID: CKRecordZone.ID = .default) { self.recordName = recordName; self.zoneID = zoneID }
        public static var supportsSecureCoding: Bool { true }
        public init?(coder: NSCoder) {
            recordName = coder.decodeObject(forKey: "recordName") as? String ?? ""
            zoneID = coder.decodeObject(forKey: "zoneID") as? CKRecordZone.ID ?? .default
        }
        public func encode(with coder: NSCoder) { coder.encode(recordName, forKey: "recordName"); coder.encode(zoneID, forKey: "zoneID") }
        public func copy(with zone: NSZone? = nil) -> Any { self }
        public override func isEqual(_ object: Any?) -> Bool { (object as? ID).map { $0.recordName == recordName && $0.zoneID == zoneID } ?? false }
        public override var hash: Int { recordName.hashValue }
    }

    public final class Reference: NSObject, NSSecureCoding, NSCopying, CKRecordValueProtocol, @unchecked Sendable {
        public enum Action: UInt, Sendable { case none = 0, deleteSelf = 1 }
        public let recordID: ID
        public let action: Action
        public init(recordID: ID, action: Action) { self.recordID = recordID; self.action = action }
        public convenience init(record: CKRecord, action: Action) { self.init(recordID: record.recordID, action: action) }
        public static var supportsSecureCoding: Bool { true }
        public init?(coder: NSCoder) { recordID = coder.decodeObject(forKey: "recordID") as? ID ?? ID(); action = .none }
        public func encode(with coder: NSCoder) { coder.encode(recordID, forKey: "recordID") }
        public func copy(with zone: NSZone? = nil) -> Any { self }
    }

    public let recordType: RecordType
    public let recordID: ID
    open var creationDate: Date? { nil }
    open var modificationDate: Date? { nil }
    open var recordChangeTag: String? { nil }
    open var parent: Reference?
    private var values: [String: CKRecordValueProtocol] = [:]

    public init(recordType: RecordType) { self.recordType = recordType; recordID = ID() }
    public init(recordType: RecordType, recordID: ID) { self.recordType = recordType; self.recordID = recordID }
    public init(recordType: RecordType, zoneID: CKRecordZone.ID) { self.recordType = recordType; recordID = ID(zoneID: zoneID) }

    open subscript(key: FieldKey) -> CKRecordValueProtocol? {
        get { values[key] }
        set { values[key] = newValue }
    }
    open func object(forKey key: FieldKey) -> CKRecordValueProtocol? { values[key] }
    open func setObject(_ object: CKRecordValueProtocol?, forKey key: FieldKey) { values[key] = object }
    open func allKeys() -> [FieldKey] { Array(values.keys) }
    open func changedKeys() -> [FieldKey] { Array(values.keys) }
    open var encryptedValues: CKRecordKeyValueSetting { CKRecordKeyValueSetting(self) }

    public static var supportsSecureCoding: Bool { true }
    public required init?(coder: NSCoder) {
        recordType = coder.decodeObject(forKey: "recordType") as? String ?? ""
        recordID = coder.decodeObject(forKey: "recordID") as? ID ?? ID()
    }
    public func encode(with coder: NSCoder) { coder.encode(recordType, forKey: "recordType"); coder.encode(recordID, forKey: "recordID") }
    open func encodeSystemFields(with coder: NSCoder) { encode(with: coder) }
    public func copy(with zone: NSZone? = nil) -> Any {
        let r = CKRecord(recordType: recordType, recordID: recordID)
        r.values = values
        return r
    }
}

public struct CKRecordKeyValueSetting {
    let record: CKRecord
    init(_ r: CKRecord) { record = r }
    public subscript(key: String) -> CKRecordValueProtocol? {
        get { record[key] }
        nonmutating set { record[key] = newValue }
    }
}

open class CKAsset: NSObject, CKRecordValueProtocol, @unchecked Sendable {
    public let fileURL: URL?
    public init(fileURL: URL) { self.fileURL = fileURL }
}

open class CKQuery: NSObject, @unchecked Sendable {
    public let recordType: CKRecord.RecordType
    public let predicate: NSPredicate
    open var sortDescriptors: [NSSortDescriptor]?
    public init(recordType: CKRecord.RecordType, predicate: NSPredicate) { self.recordType = recordType; self.predicate = predicate }
}

open class CKSubscription: NSObject, @unchecked Sendable {
    public typealias ID = String
    public final class NotificationInfo: NSObject, @unchecked Sendable {
        public var shouldSendContentAvailable = false
        public var shouldBadge = false
        public var alertBody: String?
        public var soundName: String?
        public var desiredKeys: [CKRecord.FieldKey]?
        public override init() {}
    }
    public let subscriptionID: ID
    open var notificationInfo: NotificationInfo?
    init(id: ID) { subscriptionID = id }
}
open class CKRecordZoneSubscription: CKSubscription, @unchecked Sendable {
    public let zoneID: CKRecordZone.ID
    open var recordType: CKRecord.RecordType?
    public init(zoneID: CKRecordZone.ID) { self.zoneID = zoneID; super.init(id: UUID().uuidString) }
    public init(zoneID: CKRecordZone.ID, subscriptionID: CKSubscription.ID) { self.zoneID = zoneID; super.init(id: subscriptionID) }
}
open class CKQuerySubscription: CKSubscription, @unchecked Sendable {
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let firesOnRecordCreation = Options(rawValue: 1)
        public static let firesOnRecordUpdate = Options(rawValue: 2)
        public static let firesOnRecordDeletion = Options(rawValue: 4)
        public static let firesOnce = Options(rawValue: 8)
    }
    public init(recordType: CKRecord.RecordType, predicate: NSPredicate, subscriptionID: CKSubscription.ID, options: Options = []) { super.init(id: subscriptionID) }
}
open class CKDatabaseSubscription: CKSubscription, @unchecked Sendable {
    public init(subscriptionID: CKSubscription.ID) { super.init(id: subscriptionID) }
}

open class CKNotification: NSObject, @unchecked Sendable {
    public init?(fromRemoteNotificationDictionary info: [AnyHashable: Any]) { nil }
}
open class CKRecordZoneNotification: CKNotification, @unchecked Sendable {
    open var recordZoneID: CKRecordZone.ID? { nil }
}

// MARK: Containers and databases

open class CKContainer: NSObject, @unchecked Sendable {
    public let containerIdentifier: String?
    private static let shared = CKContainer(identifier: Bundle.main.bundleIdentifier.map { "iCloud." + $0 } ?? "iCloud")
    public init(identifier containerIdentifier: String) { self.containerIdentifier = containerIdentifier }
    open class func `default`() -> CKContainer { shared }

    open var privateCloudDatabase: CKDatabase { CKDatabase(.private) }
    open var publicCloudDatabase: CKDatabase { CKDatabase(.public) }
    open var sharedCloudDatabase: CKDatabase { CKDatabase(.shared) }
    open func database(with scope: CKDatabaseScope) -> CKDatabase { CKDatabase(scope) }

    open func accountStatus(completionHandler: @escaping @Sendable (CKAccountStatus, Error?) -> Void) {
        DispatchQueue.global().async { completionHandler(.noAccount, nil) }
    }
    open func accountStatus() async throws -> CKAccountStatus { .noAccount }
    open func fetchUserRecordID(completionHandler: @escaping @Sendable (CKRecord.ID?, Error?) -> Void) {
        DispatchQueue.global().async { completionHandler(nil, notSignedIn) }
    }
    open func userRecordID() async throws -> CKRecord.ID { throw notSignedIn }
    open func add(_ operation: CKOperation) { operation.fail(notSignedIn) }
}

open class CKDatabase: NSObject, @unchecked Sendable {
    public typealias Scope = CKDatabaseScope
    public let databaseScope: CKDatabaseScope
    init(_ s: CKDatabaseScope) { databaseScope = s }

    private func later<T>(_ f: @escaping @Sendable (T?, Error?) -> Void) { DispatchQueue.global().async { f(nil, notSignedIn) } }

    open func add(_ operation: CKDatabaseOperation) { operation.fail(notSignedIn) }
    open func fetch(withRecordID recordID: CKRecord.ID, completionHandler: @escaping @Sendable (CKRecord?, Error?) -> Void) { later(completionHandler) }
    open func save(_ record: CKRecord, completionHandler: @escaping @Sendable (CKRecord?, Error?) -> Void) { later(completionHandler) }
    open func delete(withRecordID recordID: CKRecord.ID, completionHandler: @escaping @Sendable (CKRecord.ID?, Error?) -> Void) { later(completionHandler) }
    open func perform(_ query: CKQuery, inZoneWith zoneID: CKRecordZone.ID?, completionHandler: @escaping @Sendable ([CKRecord]?, Error?) -> Void) { later(completionHandler) }
    open func fetchAllRecordZones(completionHandler: @escaping @Sendable ([CKRecordZone]?, Error?) -> Void) { later(completionHandler) }
    open func save(_ zone: CKRecordZone, completionHandler: @escaping @Sendable (CKRecordZone?, Error?) -> Void) { later(completionHandler) }
    open func delete(withRecordZoneID zoneID: CKRecordZone.ID, completionHandler: @escaping @Sendable (CKRecordZone.ID?, Error?) -> Void) { later(completionHandler) }
    open func save(_ subscription: CKSubscription, completionHandler: @escaping @Sendable (CKSubscription?, Error?) -> Void) { later(completionHandler) }
    open func fetchAllSubscriptions(completionHandler: @escaping @Sendable ([CKSubscription]?, Error?) -> Void) { later(completionHandler) }
    open func delete(withSubscriptionID subscriptionID: CKSubscription.ID, completionHandler: @escaping @Sendable (String?, Error?) -> Void) { later(completionHandler) }

    open func record(for recordID: CKRecord.ID) async throws -> CKRecord { throw notSignedIn }
    open func save(_ record: CKRecord) async throws -> CKRecord { throw notSignedIn }
    open func deleteRecord(withID recordID: CKRecord.ID) async throws -> CKRecord.ID { throw notSignedIn }
    open func records(matching query: CKQuery, inZoneWith zoneID: CKRecordZone.ID? = nil, desiredKeys: [CKRecord.FieldKey]? = nil,
                      resultsLimit: Int = 0) async throws -> (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?) {
        throw notSignedIn
    }
    open func modifyRecords(saving recordsToSave: [CKRecord], deleting recordIDsToDelete: [CKRecord.ID]) async throws
        -> (saveResults: [CKRecord.ID: Result<CKRecord, Error>], deleteResults: [CKRecord.ID: Result<Void, Error>]) { throw notSignedIn }
    open func allRecordZones() async throws -> [CKRecordZone] { throw notSignedIn }
    open func save(_ zone: CKRecordZone) async throws -> CKRecordZone { throw notSignedIn }
    open func allSubscriptions() async throws -> [CKSubscription] { throw notSignedIn }
    open func save(_ subscription: CKSubscription) async throws -> CKSubscription { throw notSignedIn }
}

// MARK: Operations

open class CKOperation: Operation, @unchecked Sendable {
    public final class Configuration: NSObject, @unchecked Sendable {
        public var container: CKContainer?
        public var qualityOfService: QualityOfService = .default
        public var allowsCellularAccess = true
        public var isLongLived = false
        public var timeoutIntervalForRequest: TimeInterval = 60
        public var timeoutIntervalForResource: TimeInterval = 604800
    }
    open var configuration: Configuration! = Configuration()
    open var operationID: String { "" }
    open var longLivedOperationWasPersistedBlock: (() -> Void)?
    func fail(_ e: Error) { DispatchQueue.global().async { self.finishWith(e) } }
    func finishWith(_ e: Error) {}
    open override func main() { finishWith(notSignedIn) }
}

open class CKDatabaseOperation: CKOperation, @unchecked Sendable {
    open var database: CKDatabase?
}

open class CKModifyRecordsOperation: CKDatabaseOperation, @unchecked Sendable {
    public enum RecordSavePolicy: Int, Sendable { case ifServerRecordUnchanged = 0, changedKeys = 1, allKeys = 2 }
    open var recordsToSave: [CKRecord]?
    open var recordIDsToDelete: [CKRecord.ID]?
    open var savePolicy: RecordSavePolicy = .ifServerRecordUnchanged
    open var isAtomic = true
    open var perRecordSaveBlock: ((CKRecord.ID, Result<CKRecord, Error>) -> Void)?
    open var perRecordDeleteBlock: ((CKRecord.ID, Result<Void, Error>) -> Void)?
    open var modifyRecordsResultBlock: ((Result<Void, Error>) -> Void)?
    open var modifyRecordsCompletionBlock: (([CKRecord]?, [CKRecord.ID]?, Error?) -> Void)?
    public override init() {}
    public init(recordsToSave: [CKRecord]?, recordIDsToDelete: [CKRecord.ID]?) { self.recordsToSave = recordsToSave; self.recordIDsToDelete = recordIDsToDelete }
    override func finishWith(_ e: Error) { modifyRecordsResultBlock?(.failure(e)); modifyRecordsCompletionBlock?(nil, nil, e) }
}

open class CKFetchRecordsOperation: CKDatabaseOperation, @unchecked Sendable {
    open var recordIDs: [CKRecord.ID]?
    open var desiredKeys: [CKRecord.FieldKey]?
    open var perRecordResultBlock: ((CKRecord.ID, Result<CKRecord, Error>) -> Void)?
    open var fetchRecordsResultBlock: ((Result<Void, Error>) -> Void)?
    public override init() {}
    public init(recordIDs: [CKRecord.ID]) { self.recordIDs = recordIDs }
    override func finishWith(_ e: Error) { fetchRecordsResultBlock?(.failure(e)) }
}

open class CKQueryOperation: CKDatabaseOperation, @unchecked Sendable {
    public final class Cursor: NSObject, NSSecureCoding, @unchecked Sendable {
        public static var supportsSecureCoding: Bool { true }
        public init?(coder: NSCoder) {}
        public func encode(with coder: NSCoder) {}
    }
    public static let maximumResults = 0
    open var query: CKQuery?
    open var cursor: Cursor?
    open var zoneID: CKRecordZone.ID?
    open var resultsLimit = 0
    open var desiredKeys: [CKRecord.FieldKey]?
    open var recordMatchedBlock: ((CKRecord.ID, Result<CKRecord, Error>) -> Void)?
    open var recordFetchedBlock: ((CKRecord) -> Void)?
    open var queryResultBlock: ((Result<Cursor?, Error>) -> Void)?
    open var queryCompletionBlock: ((Cursor?, Error?) -> Void)?
    public override init() {}
    public init(query: CKQuery) { self.query = query }
    public init(cursor: Cursor) { self.cursor = cursor }
    override func finishWith(_ e: Error) { queryResultBlock?(.failure(e)); queryCompletionBlock?(nil, e) }
}

open class CKFetchRecordZoneChangesOperation: CKDatabaseOperation, @unchecked Sendable {
    public final class ZoneConfiguration: NSObject, @unchecked Sendable {
        public var previousServerChangeToken: CKServerChangeToken?
        public var resultsLimit = 0
        public var desiredKeys: [CKRecord.FieldKey]?
        public override init() {}
        public init(previousServerChangeToken: CKServerChangeToken?, resultsLimit: Int, desiredKeys: [CKRecord.FieldKey]?) {
            self.previousServerChangeToken = previousServerChangeToken; self.resultsLimit = resultsLimit; self.desiredKeys = desiredKeys
        }
    }
    open var recordZoneIDs: [CKRecordZone.ID]?
    open var configurationsByRecordZoneID: [CKRecordZone.ID: ZoneConfiguration]?
    open var fetchAllChanges = true
    open var recordWasChangedBlock: ((CKRecord.ID, Result<CKRecord, Error>) -> Void)?
    open var recordWithIDWasDeletedBlock: ((CKRecord.ID, CKRecord.RecordType) -> Void)?
    open var recordZoneChangeTokensUpdatedBlock: ((CKRecordZone.ID, CKServerChangeToken?, Data?) -> Void)?
    open var recordZoneFetchResultBlock: ((CKRecordZone.ID, Result<(serverChangeToken: CKServerChangeToken, clientChangeTokenData: Data?, moreComing: Bool), Error>) -> Void)?
    open var fetchRecordZoneChangesResultBlock: ((Result<Void, Error>) -> Void)?
    public override init() {}
    public init(recordZoneIDs: [CKRecordZone.ID], configurationsByRecordZoneID: [CKRecordZone.ID: ZoneConfiguration]? = nil) {
        self.recordZoneIDs = recordZoneIDs; self.configurationsByRecordZoneID = configurationsByRecordZoneID
    }
    override func finishWith(_ e: Error) {
        for z in recordZoneIDs ?? [] { recordZoneFetchResultBlock?(z, .failure(e)) }
        fetchRecordZoneChangesResultBlock?(.failure(e))
    }
}

open class CKFetchDatabaseChangesOperation: CKDatabaseOperation, @unchecked Sendable {
    open var previousServerChangeToken: CKServerChangeToken?
    open var recordZoneWithIDChangedBlock: ((CKRecordZone.ID) -> Void)?
    open var recordZoneWithIDWasDeletedBlock: ((CKRecordZone.ID) -> Void)?
    open var fetchDatabaseChangesResultBlock: ((Result<(serverChangeToken: CKServerChangeToken, moreComing: Bool), Error>) -> Void)?
    public init(previousServerChangeToken: CKServerChangeToken?) { self.previousServerChangeToken = previousServerChangeToken }
    override func finishWith(_ e: Error) { fetchDatabaseChangesResultBlock?(.failure(e)) }
}

open class CKModifyRecordZonesOperation: CKDatabaseOperation, @unchecked Sendable {
    open var modifyRecordZonesResultBlock: ((Result<Void, Error>) -> Void)?
    public init(recordZonesToSave: [CKRecordZone]?, recordZoneIDsToDelete: [CKRecordZone.ID]?) {}
    override func finishWith(_ e: Error) { modifyRecordZonesResultBlock?(.failure(e)) }
}

open class CKModifySubscriptionsOperation: CKDatabaseOperation, @unchecked Sendable {
    open var modifySubscriptionsResultBlock: ((Result<Void, Error>) -> Void)?
    public init(subscriptionsToSave: [CKSubscription]?, subscriptionIDsToDelete: [CKSubscription.ID]?) {}
    override func finishWith(_ e: Error) { modifySubscriptionsResultBlock?(.failure(e)) }
}
