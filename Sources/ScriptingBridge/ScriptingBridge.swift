// ScriptingBridge: Apple events to scriptable apps through generated
// proxies. No app on Linux answers Apple events, so applications can't be
// found: SBApplication's initializers return nil.

@_exported import Foundation
import RunwayFoundation

open class SBObject: NSObject, @unchecked Sendable {
    public override init() {}
    public init(properties: [String: Any]) {}
    public init(data: Any) {}
    open func get() -> Any? { nil }
    open var lastError: Error? { nil }
    open func property(withCode code: UInt32) -> SBObject { SBObject() }
    open func elementArray(withCode code: UInt32) -> SBElementArray { SBElementArray() }
    open func setTo(_ value: Any?) {}
}

open class SBElementArray: NSMutableArray, @unchecked Sendable {
    open func get() -> [Any]? { [] }
    open func object(withName name: String) -> Any { SBObject() }
    open func object(withID identifier: Any) -> Any { SBObject() }
    open func object(atLocation location: Any) -> Any { SBObject() }
    open func array(byApplying selector: Any) -> [Any] { [] }
    open func array(byApplying selector: Any, with argument: Any) -> [Any] { [] }
    open func arrayByApplying(_ selector: Any) -> [Any] { [] }
}

public protocol SBApplicationDelegate: AnyObject {
    func eventDidFail(_ event: UnsafePointer<NSAppleEventDescriptor>, withError error: Error) -> Any?
}

open class SBApplication: SBObject, @unchecked Sendable {
    public init?(bundleIdentifier ident: String) { return nil }
    public init?(url: URL) { return nil }
    public init?(processIdentifier pid: Int32) { return nil }
    open class func application(bundleIdentifier ident: String) -> Self? { nil }
    open class func application(url: URL) -> Self? { nil }
    open class func application(processIdentifier pid: Int32) -> Self? { nil }
    open var isRunning: Bool { false }
    open func activate() {}
    open weak var delegate: SBApplicationDelegate?
    open var launchFlags: Int = 0
    open var sendMode: Int = 0
    open var timeout: Int = 0
    open func `class`(forScriptingClass className: String) -> AnyClass? { nil }
}
