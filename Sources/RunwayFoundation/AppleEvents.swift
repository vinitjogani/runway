// NSAppleEventDescriptor and NSAppleEventManager (Foundation's): Apple
// events as data. There's no Apple Event transport off the Mac, but an app
// still receives the events of its own life: AppKit makes the launch's
// "open application" event current while it finishes launching, with
// `keyAEPropData` set to `keyAELaunchedAsLogInItem` when the app was started
// at login (the autostart entry SMAppService writes passes
// `--launched-at-login`).

import Foundation

public typealias FourCharCode = UInt32
public typealias OSType = FourCharCode
public typealias DescType = FourCharCode
public typealias AEKeyword = FourCharCode
public typealias AEEventClass = FourCharCode
public typealias AEEventID = FourCharCode
public typealias AEReturnID = Int16
public typealias AETransactionID = Int32

/// A four-character code from its ASCII string ('oapp').
public func runwayFourCharCode(_ s: String) -> FourCharCode {
    s.utf8.prefix(4).reduce(0) { ($0 << 8) | FourCharCode($1) }
}

open class NSAppleEventDescriptor: NSObject, @unchecked Sendable {
    public private(set) var descriptorType: DescType
    public private(set) var eventClass: AEEventClass = 0
    public private(set) var eventID: AEEventID = 0
    public private(set) var returnID: AEReturnID = 0
    public private(set) var transactionID: AETransactionID = 0
    private var value: Any?
    private var params: [AEKeyword: NSAppleEventDescriptor] = [:]
    private var attributes: [AEKeyword: NSAppleEventDescriptor] = [:]
    private var items: [NSAppleEventDescriptor] = []

    static let typeEvent = runwayFourCharCode("aevt"), typeEnum = runwayFourCharCode("enum"), typeText = runwayFourCharCode("utxt")
    static let typeInt = runwayFourCharCode("long"), typeBool = runwayFourCharCode("bool"), typeList = runwayFourCharCode("list")
    static let typeNull = runwayFourCharCode("null"), typeURL = runwayFourCharCode("url "), typeType = runwayFourCharCode("type")

    init(type: DescType, value: Any?) {
        descriptorType = type
        self.value = value
        super.init()
    }
    public override convenience init() { self.init(type: NSAppleEventDescriptor.typeNull, value: nil) }
    public static func null() -> NSAppleEventDescriptor { NSAppleEventDescriptor() }
    public static func list() -> NSAppleEventDescriptor { NSAppleEventDescriptor(listDescriptor: ()) }
    public static func record() -> NSAppleEventDescriptor { NSAppleEventDescriptor(type: runwayFourCharCode("reco"), value: nil) }
    public static func currentProcess() -> NSAppleEventDescriptor { NSAppleEventDescriptor(type: runwayFourCharCode("psn "), value: nil) }
    convenience init(listDescriptor: Void) { self.init(type: NSAppleEventDescriptor.typeList, value: nil) }

    public convenience init(enumCode: OSType) { self.init(type: NSAppleEventDescriptor.typeEnum, value: enumCode) }
    public convenience init(typeCode: OSType) { self.init(type: NSAppleEventDescriptor.typeType, value: typeCode) }
    public convenience init(string: String) { self.init(type: NSAppleEventDescriptor.typeText, value: string) }
    public convenience init(int32: Int32) { self.init(type: NSAppleEventDescriptor.typeInt, value: int32) }
    public convenience init(boolean: Bool) { self.init(type: NSAppleEventDescriptor.typeBool, value: boolean) }
    public convenience init(fileURL: URL) { self.init(type: NSAppleEventDescriptor.typeURL, value: fileURL) }
    public convenience init(eventClass: AEEventClass, eventID: AEEventID, targetDescriptor: NSAppleEventDescriptor?,
                            returnID: AEReturnID, transactionID: AETransactionID) {
        self.init(type: NSAppleEventDescriptor.typeEvent, value: nil)
        self.eventClass = eventClass
        self.eventID = eventID
        self.returnID = returnID
        self.transactionID = transactionID
    }
    public static func appleEvent(withEventClass eventClass: AEEventClass, eventID: AEEventID, targetDescriptor: NSAppleEventDescriptor?,
                                  returnID: AEReturnID, transactionID: AETransactionID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID, targetDescriptor: targetDescriptor, returnID: returnID, transactionID: transactionID)
    }

    public var enumCodeValue: OSType { value as? OSType ?? 0 }
    public var typeCodeValue: OSType { value as? OSType ?? 0 }
    public var stringValue: String? {
        switch value {
        case let s as String: s
        case let u as URL: u.absoluteString
        case let i as Int32: String(i)
        default: nil
        }
    }
    public var int32Value: Int32 { (value as? Int32) ?? (value as? Bool).map { $0 ? 1 : 0 } ?? Int32(stringValue ?? "") ?? 0 }
    public var booleanValue: Bool { (value as? Bool) ?? ((value as? Int32).map { $0 != 0 } ?? false) }
    public var fileURLValue: URL? { value as? URL ?? stringValue.flatMap { URL(string: $0) } }
    public var data: Data { stringValue.map { Data($0.utf8) } ?? Data() }
    public var isRecordDescriptor: Bool { descriptorType == runwayFourCharCode("reco") }
    public var numberOfItems: Int { items.count }

    public func paramDescriptor(forKeyword keyword: AEKeyword) -> NSAppleEventDescriptor? { params[keyword] }
    public func setParam(_ descriptor: NSAppleEventDescriptor, forKeyword keyword: AEKeyword) { params[keyword] = descriptor }
    public func removeParamDescriptor(withKeyword keyword: AEKeyword) { params[keyword] = nil }
    public func attributeDescriptor(forKeyword keyword: AEKeyword) -> NSAppleEventDescriptor? { attributes[keyword] }
    public func setAttribute(_ descriptor: NSAppleEventDescriptor, forKeyword keyword: AEKeyword) { attributes[keyword] = descriptor }
    /// List items, 1-based as in AppleScript.
    public func atIndex(_ index: Int) -> NSAppleEventDescriptor? { items.indices.contains(index - 1) ? items[index - 1] : nil }
    public func insert(_ descriptor: NSAppleEventDescriptor, at index: Int) {
        if index <= 0 || index > items.count { items.append(descriptor) } else { items.insert(descriptor, at: index - 1) }
    }
    public func descriptor(forKeyword keyword: AEKeyword) -> NSAppleEventDescriptor? { params[keyword] }
    public func setDescriptor(_ descriptor: NSAppleEventDescriptor, forKeyword keyword: AEKeyword) { params[keyword] = descriptor }
}

open class NSAppleEventManager: NSObject, @unchecked Sendable {
    private static let instance = NSAppleEventManager()
    public static func shared() -> NSAppleEventManager { instance }

    private let lock = NSLock()
    private var current: NSAppleEventDescriptor?
    private var currentReplyEvent: NSAppleEventDescriptor?
    /// Handlers by (class, id): AppKit registers selector handlers through this.
    private var handlers: [UInt64: (NSAppleEventDescriptor, NSAppleEventDescriptor) -> Void] = [:]

    /// The event being handled, if any.
    open var currentAppleEvent: NSAppleEventDescriptor? { lock.withLock { current } }
    open var currentReplyAppleEvent: NSAppleEventDescriptor? { lock.withLock { currentReplyEvent } }

    private func key(_ c: AEEventClass, _ i: AEEventID) -> UInt64 { UInt64(c) << 32 | UInt64(i) }
    public func _setEventHandler(forEventClass c: AEEventClass, andEventID i: AEEventID,
                                 _ handler: @escaping (NSAppleEventDescriptor, NSAppleEventDescriptor) -> Void) {
        lock.withLock { handlers[key(c, i)] = handler }
    }
    open func removeEventHandler(forEventClass eventClass: AEEventClass, andEventID eventID: AEEventID) {
        lock.withLock { handlers[key(eventClass, eventID)] = nil }
    }

    /// Makes `event` current while `body` runs and the event's registered
    /// handler (if any) handles it: the app's own events (launch, reopen,
    /// open documents) are delivered this way.
    public func _dispatch(_ event: NSAppleEventDescriptor, during body: () -> Void = {}) {
        let reply = NSAppleEventDescriptor()
        let (prevEvent, prevReply, handler) = lock.withLock { () -> (NSAppleEventDescriptor?, NSAppleEventDescriptor?, ((NSAppleEventDescriptor, NSAppleEventDescriptor) -> Void)?) in
            let p = (current, currentReplyEvent, handlers[key(event.eventClass, event.eventID)])
            current = event
            currentReplyEvent = reply
            return p
        }
        handler?(event, reply)
        body()
        lock.withLock {
            current = prevEvent
            currentReplyEvent = prevReply
        }
    }
}
