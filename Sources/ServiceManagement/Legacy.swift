// Legacy login items and privileged helpers.

import Foundation
import RunwayFoundation

/// A login-item helper (Contents/Library/LoginItems) starts the main app at
/// login on the Mac; here the main app's own autostart entry does that.
@discardableResult
public func SMLoginItemSetEnabled(_ identifier: CFString, _ enabled: Bool) -> Bool {
    do {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        return true
    } catch {
        return false
    }
}

public let kSMDomainSystemLaunchd: CFString = "kSMDomainSystemLaunchd"
public let kSMDomainUserLaunchd: CFString = "kSMDomainUserLaunchd"
public let kSMErrorDomainFramework: CFString = "kSMErrorDomainFramework"
public let kSMRightBlessPrivilegedHelper: CFString = "com.apple.ServiceManagement.blesshelper"
public let kSMRightModifySystemDaemons: CFString = "com.apple.ServiceManagement.daemons.modify"

/// Privileged helpers are launchd jobs: there is no launchd to bless one into.
public func SMJobBless(_ domain: CFString?, _ executableLabel: CFString, _ auth: Any?, _ outError: UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool {
    let e = NSError(domain: kSMErrorDomainFramework as String, code: 2, userInfo: [NSLocalizedDescriptionKey: "Privileged helpers are not supported on this platform"])
    outError?.pointee = Unmanaged.passRetained(e)
    return false
}
public func SMJobRemove(_ domain: CFString?, _ jobLabel: CFString, _ auth: Any?, _ wait: Bool, _ outError: UnsafeMutablePointer<Unmanaged<NSError>?>?) -> Bool { false }
public func SMJobCopyDictionary(_ domain: CFString?, _ jobLabel: CFString) -> Unmanaged<NSDictionary>? { nil }
public func SMCopyAllJobDictionaries(_ domain: CFString?) -> Unmanaged<NSArray>? { Unmanaged.passRetained(NSArray()) }
