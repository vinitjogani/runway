// More Keychain names apps pass (accepted; the store keys items by class,
// service and account), the remaining common error codes, and code
// signing (SecStaticCode / SecCode): nothing is signed here, so checks
// report the code as unsigned.

import Foundation
import RunwayFoundation

public let errSecUnimplemented: OSStatus = -4
public let errSecAllocate: OSStatus = -108
public let errSecUserCanceled: OSStatus = -128
public let errSecBadReq: OSStatus = -909
public let errSecNotAvailable: OSStatus = -25291
public let errSecAuthFailed: OSStatus = -25293
public let errSecNoSuchKeychain: OSStatus = -25294
public let errSecInteractionNotAllowed: OSStatus = -25308
public let errSecDecode: OSStatus = -26275
public let errSecMissingEntitlement: OSStatus = -34018
public let errSecCSUnsigned: OSStatus = -67062
public let errSecCSSignatureFailed: OSStatus = -67061
public let errSecCSReqFailed: OSStatus = -67050

public let kSecAttrAccessGroup: CFString = "agrp"
public let kSecAttrCreationDate: CFString = "cdat"
public let kSecAttrModificationDate: CFString = "mdat"
public let kSecAttrDescription: CFString = "desc"
public let kSecAttrComment: CFString = "icmt"
public let kSecAttrGeneric: CFString = "gena"
public let kSecAttrIsInvisible: CFString = "invi"
public let kSecAttrProtocol: CFString = "ptcl"
public let kSecAttrPort: CFString = "port"
public let kSecAttrPath: CFString = "path"
public let kSecAttrAuthenticationType: CFString = "atyp"
public let kSecAttrSecurityDomain: CFString = "sdmn"
public let kSecAttrAccessibleWhenUnlockedThisDeviceOnly: CFString = "aku"
public let kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: CFString = "cku"
public let kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly: CFString = "akpu"
public let kSecAttrSynchronizableAny: CFString = "syna"
public let kSecAttrAccessControl: CFString = "accc"
public let kSecUseAuthenticationUI: CFString = "u_AuthUI"
public let kSecUseAuthenticationContext: CFString = "u_AuthCtx"
public let kSecUseOperationPrompt: CFString = "u_OpPrompt"
public let kSecReturnRef: CFString = "r_Ref"
public let kSecReturnPersistentRef: CFString = "r_PersistentRef"
public let kSecValueRef: CFString = "v_Ref"
public let kSecValuePersistentRef: CFString = "v_PersistentRef"
public let kSecMatchCaseInsensitive: CFString = "m_CaseInsensitive"
public let kSecClassKey: CFString = "keys"
public let kSecClassCertificate: CFString = "cert"
public let kSecClassIdentity: CFString = "idnt"
public let kSecAttrProtocolHTTPS: CFString = "htps"
public let kSecAttrProtocolHTTP: CFString = "http"

// MARK: Code signing

public struct SecCSFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}
public let kSecCSDefaultFlags: UInt32 = 0
public let kSecCSCheckAllArchitectures: UInt32 = 1
public let kSecCSStrictValidate: UInt32 = 16
public let kSecCSSigningInformation: UInt32 = 2
public let kSecCSCheckNestedCode: UInt32 = 8
public let kSecCSDoNotValidateResources: UInt32 = 4
public let kSecCSDoNotValidateExecutable: UInt32 = 2
public let kSecCSRequirementInformation: UInt32 = 4
public let kSecCodeInfoIdentifier: CFString = "identifier"
public let kSecCodeInfoTeamIdentifier: CFString = "teamid"
public let kSecCodeInfoCertificates: CFString = "certificates"
public let kSecCodeInfoEntitlementsDict: CFString = "entitlements-dict"
public let kSecGuestAttributePid: CFString = "pid"
public let kSecGuestAttributeAudit: CFString = "audit"

public final class SecStaticCode: @unchecked Sendable { let url: URL; init(url: URL) { self.url = url } }
public final class SecCode: @unchecked Sendable { let pid: Int32; init(pid: Int32) { self.pid = pid } }
/// A certificate (DER bytes). Code here isn't signed, so none come from code signing.
public final class SecCertificate: Equatable, @unchecked Sendable {
    public static func == (a: SecCertificate, b: SecCertificate) -> Bool { a.der == b.der }
    let der: Data
    init(der: Data) { self.der = der }
}
public func SecCertificateCreateWithData(_ allocator: CFAllocator?, _ data: CFData) -> SecCertificate? { SecCertificate(der: data as Data) }
public func SecCertificateCopyData(_ certificate: SecCertificate) -> CFData { certificate.der as NSData }
public func SecCertificateCopySubjectSummary(_ certificate: SecCertificate) -> CFString? { nil }
public func SecCertificateCopyCommonName(_ certificate: SecCertificate, _ commonName: UnsafeMutablePointer<CFString?>) -> OSStatus { errSecUnimplemented }

public final class SecRequirement: @unchecked Sendable { let text: String; init(text: String) { self.text = text } }

public func SecStaticCodeCreateWithPath(_ path: CFURL, _ flags: SecCSFlags, _ staticCode: UnsafeMutablePointer<SecStaticCode?>) -> OSStatus {
    staticCode.pointee = SecStaticCode(url: path as URL)
    return errSecSuccess
}
public func SecCodeCopySelf(_ flags: SecCSFlags, _ code: UnsafeMutablePointer<SecCode?>) -> OSStatus {
    code.pointee = SecCode(pid: ProcessInfo.processInfo.processIdentifier)
    return errSecSuccess
}
public func SecCodeCopyGuestWithAttributes(_ host: SecCode?, _ attributes: CFDictionary?, _ flags: SecCSFlags,
                                           _ guest: UnsafeMutablePointer<SecCode?>) -> OSStatus {
    guest.pointee = SecCode(pid: (attributes?[kSecGuestAttributePid as String] as? Int32) ?? 0)
    return errSecSuccess
}
public func SecCodeCopyStaticCode(_ code: SecCode, _ flags: SecCSFlags, _ staticCode: UnsafeMutablePointer<SecStaticCode?>) -> OSStatus {
    let exe = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(code.pid)/exe")) ?? CommandLine.arguments[0]
    staticCode.pointee = SecStaticCode(url: URL(fileURLWithPath: exe))
    return errSecSuccess
}
public func SecRequirementCreateWithString(_ text: CFString, _ flags: SecCSFlags, _ requirement: UnsafeMutablePointer<SecRequirement?>) -> OSStatus {
    requirement.pointee = SecRequirement(text: text as String)
    return errSecSuccess
}
/// Nothing is code-signed on Linux: validity checks fail as unsigned.
public func SecStaticCodeCheckValidity(_ code: SecStaticCode, _ flags: SecCSFlags, _ requirement: SecRequirement?) -> OSStatus { errSecCSUnsigned }
public func SecStaticCodeCheckValidityWithErrors(_ code: SecStaticCode, _ flags: SecCSFlags, _ requirement: SecRequirement?,
                                                 _ errors: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> OSStatus { errSecCSUnsigned }
public func SecCodeCheckValidity(_ code: SecCode, _ flags: SecCSFlags, _ requirement: SecRequirement?) -> OSStatus { errSecCSUnsigned }
public func SecCodeCheckValidityWithErrors(_ code: SecCode, _ flags: SecCSFlags, _ requirement: SecRequirement?,
                                           _ errors: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> OSStatus { errSecCSUnsigned }
public func SecCodeCopySigningInformation(_ code: SecStaticCode, _ flags: SecCSFlags, _ information: UnsafeMutablePointer<CFDictionary?>) -> OSStatus {
    information.pointee = [kSecCodeInfoIdentifier as String: code.url.deletingPathExtension().lastPathComponent] as NSDictionary
    return errSecSuccess
}

// MARK: Random

public struct SecRandom: @unchecked Sendable {}
public let kSecRandomDefault: SecRandom? = nil
public func SecRandomCopyBytes(_ rnd: SecRandom?, _ count: Int, _ bytes: UnsafeMutableRawPointer) -> Int32 {
    var g = SystemRandomNumberGenerator()
    for i in 0..<count { bytes.storeBytes(of: UInt8.random(in: 0...255, using: &g), toByteOffset: i, as: UInt8.self) }
    return errSecSuccess
}


// MARK: Authorization Services

// Privilege elevation through Authorization Services (the padlock dialog)
// has no counterpart here: an authorization can be created (apps hold one
// around their privileged work) but grants no rights, and obtaining rights
// is denied, as when the user cancels the dialog.

public final class AuthorizationOpaqueRef: @unchecked Sendable {}
public typealias AuthorizationRef = OpaquePointer

public struct AuthorizationFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let interactionAllowed = AuthorizationFlags(rawValue: 1 << 0)
    public static let extendRights = AuthorizationFlags(rawValue: 1 << 1)
    public static let partialRights = AuthorizationFlags(rawValue: 1 << 2)
    public static let destroyRights = AuthorizationFlags(rawValue: 1 << 3)
    public static let preAuthorize = AuthorizationFlags(rawValue: 1 << 4)
}

public struct AuthorizationItem {
    public var name: UnsafePointer<CChar>
    public var valueLength: Int
    public var value: UnsafeMutableRawPointer?
    public var flags: UInt32
    public init(name: UnsafePointer<CChar>, valueLength: Int, value: UnsafeMutableRawPointer?, flags: UInt32) {
        self.name = name; self.valueLength = valueLength; self.value = value; self.flags = flags
    }
}
public struct AuthorizationItemSet {
    public var count: UInt32
    public var items: UnsafeMutablePointer<AuthorizationItem>?
    public init(count: UInt32, items: UnsafeMutablePointer<AuthorizationItem>?) { self.count = count; self.items = items }
    public init() { count = 0; items = nil }
}
public typealias AuthorizationRights = AuthorizationItemSet
public typealias AuthorizationEnvironment = AuthorizationItemSet
public struct AuthorizationExternalForm {
    public var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    public init() {}
}

public let errAuthorizationSuccess: OSStatus = 0
public let errAuthorizationInvalidSet: OSStatus = -60001
public let errAuthorizationInvalidRef: OSStatus = -60002
public let errAuthorizationDenied: OSStatus = -60005
public let errAuthorizationCanceled: OSStatus = -60006
public let errAuthorizationInteractionNotAllowed: OSStatus = -60007
public let errAuthorizationToolExecuteFailure: OSStatus = -60031
public let kAuthorizationRightExecute = "system.privilege.admin"
public let kAuthorizationEmptyEnvironment: UnsafePointer<AuthorizationEnvironment>? = nil
public let kSMRightBlessPrivilegedHelper = "com.apple.ServiceManagement.blesshelper"
public let kSMRightModifySystemDaemons = "com.apple.ServiceManagement.daemons.modify"

@discardableResult
public func AuthorizationCreate(_ rights: UnsafePointer<AuthorizationRights>?, _ environment: UnsafePointer<AuthorizationEnvironment>?,
                                _ flags: AuthorizationFlags, _ authorization: UnsafeMutablePointer<AuthorizationRef?>?) -> OSStatus {
    // An empty authorization is always granted; any right is denied.
    if let rights, rights.pointee.count > 0 { return errAuthorizationDenied }
    authorization?.pointee = OpaquePointer(UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8))
    return errAuthorizationSuccess
}

@discardableResult
public func AuthorizationFree(_ authorization: AuthorizationRef, _ flags: AuthorizationFlags) -> OSStatus {
    UnsafeMutableRawPointer(authorization).deallocate()
    return errAuthorizationSuccess
}

@discardableResult
public func AuthorizationCopyRights(_ authorization: AuthorizationRef, _ rights: UnsafePointer<AuthorizationRights>, _ environment: UnsafePointer<AuthorizationEnvironment>?,
                                    _ flags: AuthorizationFlags, _ authorizedRights: UnsafeMutablePointer<UnsafeMutablePointer<AuthorizationRights>?>?) -> OSStatus {
    rights.pointee.count == 0 ? errAuthorizationSuccess : errAuthorizationDenied
}

@discardableResult
public func AuthorizationMakeExternalForm(_ authorization: AuthorizationRef, _ extForm: UnsafeMutablePointer<AuthorizationExternalForm>) -> OSStatus {
    extForm.pointee = AuthorizationExternalForm()
    return errAuthorizationSuccess
}

@discardableResult
public func AuthorizationCreateFromExternalForm(_ extForm: UnsafePointer<AuthorizationExternalForm>, _ authorization: UnsafeMutablePointer<AuthorizationRef?>) -> OSStatus {
    AuthorizationCreate(nil, nil, [], authorization)
}

@discardableResult
public func AuthorizationFreeItemSet(_ set: UnsafeMutablePointer<AuthorizationItemSet>) -> OSStatus { errAuthorizationSuccess }
