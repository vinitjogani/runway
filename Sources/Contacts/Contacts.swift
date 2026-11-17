// Contacts for Linux and Windows: access answers as on a Mac where the
// user denied it (status .denied; requests complete with false and
// CNError(.authorizationDenied); fetches throw it). The value types work.

@_exported import Foundation

public let CNErrorDomain = "CNErrorDomain"

public enum CNEntityType: Int, Sendable { case contacts = 0 }
public enum CNAuthorizationStatus: Int, Sendable { case notDetermined = 0, restricted, denied, authorized, limited }
public enum CNContactType: Int, Sendable { case person = 0, organization }
public enum CNContactSortOrder: Int, Sendable { case none = 0, userDefault, givenName, familyName }

public struct CNError: CustomNSError, Hashable, Error, Sendable {
    public enum Code: Int, Sendable {
        case communicationError = 1, dataAccessError = 2, authorizationDenied = 100, noAccessableWritableContainers = 101
        case unauthorizedKeys = 102, featureDisabledByUser = 103, featureNotAvailable = 104, recordDoesNotExist = 200
        case insertedRecordAlreadyExists = 201, containmentCycle = 202, containmentScope = 203, parentRecordDoesNotExist = 204
        case recordIdentifierInvalid = 205, recordNotWritable = 206, parentContainerNotWritable = 207
        case validationMultipleErrors = 300, validationTypeMismatch = 301, validationConfigurationError = 302
        case predicateInvalid = 400, policyViolation = 500, clientIdentifierInvalid = 600, clientIdentifierDoesNotExist = 601
        case vCardMalformed = 700, vCardSummarizationError = 701
    }
    public let code: Code
    public init(_ code: Code) { self.code = code }
    public static var errorDomain: String { CNErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { [:] }
}

public protocol CNKeyDescriptor: NSObjectProtocol, NSSecureCoding, NSCopying {}
extension NSString: CNKeyDescriptor {}

public let CNContactIdentifierKey = "identifier"
public let CNContactGivenNameKey = "givenName"
public let CNContactFamilyNameKey = "familyName"
public let CNContactMiddleNameKey = "middleName"
public let CNContactNicknameKey = "nickname"
public let CNContactOrganizationNameKey = "organizationName"
public let CNContactJobTitleKey = "jobTitle"
public let CNContactEmailAddressesKey = "emailAddresses"
public let CNContactPhoneNumbersKey = "phoneNumbers"
public let CNContactPostalAddressesKey = "postalAddresses"
public let CNContactImageDataKey = "imageData"
public let CNContactThumbnailImageDataKey = "thumbnailImageData"
public let CNContactImageDataAvailableKey = "imageDataAvailable"
public let CNContactBirthdayKey = "birthday"
public let CNContactNoteKey = "note"
public let CNContactUrlAddressesKey = "urlAddresses"
public let CNContactTypeKey = "contactType"
public let CNLabelHome = "_$!<Home>!$_"
public let CNLabelWork = "_$!<Work>!$_"
public let CNLabelOther = "_$!<Other>!$_"
public let CNLabelPhoneNumberMobile = "_$!<Mobile>!$_"
public let CNLabelPhoneNumberMain = "_$!<Main>!$_"

open class CNLabeledValue<ValueType: NSCopying & NSSecureCoding>: NSObject, @unchecked Sendable {
    public let identifier = UUID().uuidString
    public let label: String?
    public let value: ValueType
    public init(label: String?, value: ValueType) { self.label = label; self.value = value }
    open class func localizedString(forLabel label: String) -> String {
        label.replacingOccurrences(of: "_$!<", with: "").replacingOccurrences(of: ">!$_", with: "")
    }
}

open class CNPhoneNumber: NSObject, NSCopying, NSSecureCoding, @unchecked Sendable {
    public let stringValue: String
    public init(stringValue: String) { self.stringValue = stringValue }
    public static var supportsSecureCoding: Bool { true }
    public required init?(coder: NSCoder) { stringValue = coder.decodeObject(forKey: "s") as? String ?? "" }
    public func encode(with coder: NSCoder) { coder.encode(stringValue, forKey: "s") }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

open class CNPostalAddress: NSObject, NSCopying, NSSecureCoding, @unchecked Sendable {
    open var street = "", city = "", state = "", postalCode = "", country = "", isoCountryCode = ""
    public override init() {}
    public static var supportsSecureCoding: Bool { true }
    public required init?(coder: NSCoder) {}
    public func encode(with coder: NSCoder) {}
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

open class CNContact: NSObject, NSCopying, NSMutableCopying, @unchecked Sendable {
    open internal(set) var identifier = UUID().uuidString
    open internal(set) var contactType: CNContactType = .person
    open internal(set) var givenName = ""
    open internal(set) var middleName = ""
    open internal(set) var familyName = ""
    open internal(set) var nickname = ""
    open internal(set) var organizationName = ""
    open internal(set) var jobTitle = ""
    open internal(set) var note = ""
    open internal(set) var birthday: DateComponents?
    open internal(set) var imageData: Data?
    open internal(set) var thumbnailImageData: Data?
    open var imageDataAvailable: Bool { imageData != nil }
    open internal(set) var emailAddresses: [CNLabeledValue<NSString>] = []
    open internal(set) var phoneNumbers: [CNLabeledValue<CNPhoneNumber>] = []
    open internal(set) var postalAddresses: [CNLabeledValue<CNPostalAddress>] = []
    open internal(set) var urlAddresses: [CNLabeledValue<NSString>] = []

    public override init() {}
    open func isKeyAvailable(_ key: String) -> Bool { true }
    open func areKeysAvailable(_ keyDescriptors: [CNKeyDescriptor]) -> Bool { true }
    open func copy(with zone: NSZone? = nil) -> Any { self }
    open func mutableCopy(with zone: NSZone? = nil) -> Any {
        let m = CNMutableContact()
        m.givenName = givenName; m.familyName = familyName; m.middleName = middleName; m.nickname = nickname
        m.organizationName = organizationName; m.jobTitle = jobTitle; m.note = note; m.birthday = birthday
        m.emailAddresses = emailAddresses; m.phoneNumbers = phoneNumbers; m.postalAddresses = postalAddresses
        return m
    }
    open class func predicateForContacts(matchingName name: String) -> NSPredicate { NSPredicate(value: false) }
    open class func predicateForContacts(withIdentifiers identifiers: [String]) -> NSPredicate { NSPredicate(value: false) }
    open class func predicateForContacts(matchingEmailAddress emailAddress: String) -> NSPredicate { NSPredicate(value: false) }
    open class func predicateForContacts(matching phoneNumber: CNPhoneNumber) -> NSPredicate { NSPredicate(value: false) }
}

open class CNMutableContact: CNContact, @unchecked Sendable {
    open override var givenName: String { get { super.givenName } set { super.givenName = newValue } }
    open override var familyName: String { get { super.familyName } set { super.familyName = newValue } }
    open override var middleName: String { get { super.middleName } set { super.middleName = newValue } }
    open override var nickname: String { get { super.nickname } set { super.nickname = newValue } }
    open override var organizationName: String { get { super.organizationName } set { super.organizationName = newValue } }
    open override var jobTitle: String { get { super.jobTitle } set { super.jobTitle = newValue } }
    open override var note: String { get { super.note } set { super.note = newValue } }
    open override var birthday: DateComponents? { get { super.birthday } set { super.birthday = newValue } }
    open override var imageData: Data? { get { super.imageData } set { super.imageData = newValue } }
    open override var emailAddresses: [CNLabeledValue<NSString>] { get { super.emailAddresses } set { super.emailAddresses = newValue } }
    open override var phoneNumbers: [CNLabeledValue<CNPhoneNumber>] { get { super.phoneNumbers } set { super.phoneNumbers = newValue } }
    open override var postalAddresses: [CNLabeledValue<CNPostalAddress>] { get { super.postalAddresses } set { super.postalAddresses = newValue } }
    open override var urlAddresses: [CNLabeledValue<NSString>] { get { super.urlAddresses } set { super.urlAddresses = newValue } }
}

open class CNContactFetchRequest: NSObject, @unchecked Sendable {
    open var keysToFetch: [CNKeyDescriptor]
    open var predicate: NSPredicate?
    open var sortOrder: CNContactSortOrder = .none
    open var unifyResults = true
    public init(keysToFetch: [CNKeyDescriptor]) { self.keysToFetch = keysToFetch }
}

open class CNContainer: NSObject, @unchecked Sendable {
    open var identifier: String { "" }
    open var name: String { "" }
}

open class CNSaveRequest: NSObject, @unchecked Sendable {
    public override init() {}
    open func add(_ contact: CNMutableContact, toContainerWithIdentifier identifier: String?) {}
    open func update(_ contact: CNMutableContact) {}
    open func delete(_ contact: CNMutableContact) {}
}

open class CNContactFormatter: Formatter, @unchecked Sendable {
    public enum Style: Int, Sendable { case fullName = 0, phoneticFullName }
    open var style: Style = .fullName
    open class func string(from contact: CNContact, style: Style) -> String? {
        let parts = [contact.givenName, contact.middleName, contact.familyName].filter { !$0.isEmpty }
        return parts.isEmpty ? (contact.organizationName.isEmpty ? nil : contact.organizationName) : parts.joined(separator: " ")
    }
    open func string(from contact: CNContact) -> String? { CNContactFormatter.string(from: contact, style: style) }
    open class func descriptorForRequiredKeys(for style: Style) -> CNKeyDescriptor {
        "\(CNContactGivenNameKey),\(CNContactFamilyNameKey)" as NSString
    }
}

public extension Notification.Name {
    static let CNContactStoreDidChange = Notification.Name("CNContactStoreDidChangeNotification")
}

open class CNContactStore: NSObject, @unchecked Sendable {
    public override init() { super.init() }
    open class func authorizationStatus(for entityType: CNEntityType) -> CNAuthorizationStatus { .denied }
    open func requestAccess(for entityType: CNEntityType, completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
        DispatchQueue.global().async { completionHandler(false, CNError(.authorizationDenied)) }
    }
    open func requestAccess(for entityType: CNEntityType) async throws -> Bool { throw CNError(.authorizationDenied) }
    open func unifiedContacts(matching predicate: NSPredicate, keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact] { throw CNError(.authorizationDenied) }
    open func unifiedContact(withIdentifier identifier: String, keysToFetch keys: [CNKeyDescriptor]) throws -> CNContact { throw CNError(.authorizationDenied) }
    open func unifiedMeContactWithKeys(toFetch keys: [CNKeyDescriptor]) throws -> CNContact { throw CNError(.authorizationDenied) }
    open func enumerateContacts(with fetchRequest: CNContactFetchRequest, usingBlock block: (CNContact, UnsafeMutablePointer<ObjCBool>) -> Void) throws {
        throw CNError(.authorizationDenied)
    }
    open func containers(matching predicate: NSPredicate?) throws -> [CNContainer] { throw CNError(.authorizationDenied) }
    open func defaultContainerIdentifier() -> String { "" }
    open func execute(_ saveRequest: CNSaveRequest) throws { throw CNError(.authorizationDenied) }
}
