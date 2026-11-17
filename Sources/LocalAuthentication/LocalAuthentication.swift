// LocalAuthentication for Linux and Windows: no biometric hardware is
// reachable, so canEvaluatePolicy answers false with .biometryNotAvailable
// (biometric policies) or .passcodeNotSet (device-owner policies, as on a
// Mac with no password to verify against), and evaluatePolicy fails the
// same way. Apps fall back to their unauthenticated path or hide the lock.

@_exported import Foundation

public let LAErrorDomain = "com.apple.LocalAuthentication"

public enum LAPolicy: Int, Sendable {
    case deviceOwnerAuthenticationWithBiometrics = 1
    case deviceOwnerAuthentication = 2
    case deviceOwnerAuthenticationWithWatch = 3
    case deviceOwnerAuthenticationWithBiometricsOrWatch = 4
    case deviceOwnerAuthenticationWithWristDetection = 5
    case deviceOwnerAuthenticationWithCompanion = 6
    case deviceOwnerAuthenticationWithBiometricsOrCompanion = 7
}

public enum LABiometryType: Int, Sendable {
    case none = 0, touchID = 1, faceID = 2, opticID = 4
    @available(*, deprecated, renamed: "none") public static var LABiometryNone: LABiometryType { .none }
}

public enum LACredentialType: Int, Sendable { case applicationPassword = 0, smartCardPIN = -3 }
public enum LAAccessControlOperation: Int, Sendable { case createItem, useItem, createKey, useKeySign, useKeyDecrypt, useKeyKeyExchange }

public struct LAError: CustomNSError, Hashable, Error, Sendable {
    public enum Code: Int, Sendable {
        case authenticationFailed = -1
        case userCancel = -2
        case userFallback = -3
        case systemCancel = -4
        case passcodeNotSet = -5
        case biometryNotAvailable = -6
        case biometryNotEnrolled = -7
        case biometryLockout = -8
        case appCancel = -9
        case invalidContext = -10
        case companionNotAvailable = -11
        case biometryNotPaired = -12
        case biometryDisconnected = -13
        case invalidDimensions = -14
        case notInteractive = -1004
        public static var touchIDNotAvailable: Code { .biometryNotAvailable }
        public static var touchIDNotEnrolled: Code { .biometryNotEnrolled }
        public static var touchIDLockout: Code { .biometryLockout }
        public static var watchNotAvailable: Code { .companionNotAvailable }
    }
    public let code: Code
    public init(_ code: Code) { self.code = code }
    public init(_ code: Code, userInfo: [String: Any] = [:]) { self.code = code }
    public static var errorDomain: String { LAErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: localizedDescription] }
    public var localizedDescription: String {
        switch code {
        case .biometryNotAvailable: return "Biometry is not available on this device."
        case .passcodeNotSet: return "No password is set to authenticate with."
        default: return "Authentication failed."
        }
    }
    public static var authenticationFailed: Code { .authenticationFailed }
    public static var userCancel: Code { .userCancel }
    public static var userFallback: Code { .userFallback }
    public static var systemCancel: Code { .systemCancel }
    public static var passcodeNotSet: Code { .passcodeNotSet }
    public static var biometryNotAvailable: Code { .biometryNotAvailable }
    public static var biometryNotEnrolled: Code { .biometryNotEnrolled }
    public static var biometryLockout: Code { .biometryLockout }
    public static var appCancel: Code { .appCancel }
    public static var invalidContext: Code { .invalidContext }
    public static var notInteractive: Code { .notInteractive }
}

public func ~= (code: LAError.Code, error: Error) -> Bool { (error as? LAError)?.code == code }

open class LAContext: NSObject, @unchecked Sendable {
    open var localizedReason: String = ""
    open var localizedFallbackTitle: String?
    open var localizedCancelTitle: String?
    open var touchIDAuthenticationAllowableReuseDuration: TimeInterval = 0
    open var interactionNotAllowed = false
    open var biometryType: LABiometryType { .none }
    open var evaluatedPolicyDomainState: Data? { nil }
    open var domainState: LADomainState { LADomainState() }

    public override init() { super.init() }

    private func reason(_ policy: LAPolicy) -> LAError {
        policy == .deviceOwnerAuthentication ? LAError(.passcodeNotSet) : LAError(.biometryNotAvailable)
    }

    open func canEvaluatePolicy(_ policy: LAPolicy, error: UnsafeMutablePointer<NSError?>?) -> Bool {
        error?.pointee = reason(policy) as NSError
        return false
    }

    open func evaluatePolicy(_ policy: LAPolicy, localizedReason: String, reply: @escaping @Sendable (Bool, Error?) -> Void) {
        let e = reason(policy)
        DispatchQueue.global().async { reply(false, e) }
    }

    open func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool { throw reason(policy) }

    open func evaluateAccessControl(_ accessControl: AnyObject, operation: LAAccessControlOperation, localizedReason: String,
                                    reply: @escaping @Sendable (Bool, Error?) -> Void) {
        DispatchQueue.global().async { reply(false, LAError(.biometryNotAvailable)) }
    }

    open func setCredential(_ credential: Data?, type: LACredentialType) -> Bool { false }
    open func isCredentialSet(_ type: LACredentialType) -> Bool { false }
    open func invalidate() {}
}

public final class LADomainState: NSObject, @unchecked Sendable {
    public final class Biometry: NSObject, @unchecked Sendable {
        public var biometryType: LABiometryType { .none }
        public var stateHash: Data? { nil }
    }
    public var biometry: Biometry { Biometry() }
    public var stateHash: Data? { nil }
}
