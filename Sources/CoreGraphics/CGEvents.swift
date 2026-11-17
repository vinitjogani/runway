// Quartz Event Services and the window list (CoreGraphics names, also
// reached through ApplicationServices, Carbon or AppKit). Events can be
// made and inspected; posting them to other apps and tapping the system's
// event stream need privileges Runway doesn't take (on a Mac, the
// Accessibility / Input Monitoring grants), so the preflight checks answer
// false, CGEvent.tapCreate returns nil and post() is dropped. The window
// list is real under X11 (_NET_CLIENT_LIST: id, owner pid and name, title,
// bounds), and empty elsewhere.

import Foundation
import RunwayFoundation
import RunwayCF
#if os(Linux)
import Glibc
import RunwayX11
#endif

public typealias CGKeyCode = UInt16
public typealias CGCharCode = UInt16
public typealias CGEventTimestamp = UInt64
public typealias CGEventMask = UInt64
public typealias CGEventTapProxy = OpaquePointer

public enum CGEventType: UInt32, Sendable {
    case null = 0
    case leftMouseDown = 1, leftMouseUp = 2, rightMouseDown = 3, rightMouseUp = 4, mouseMoved = 5
    case leftMouseDragged = 6, rightMouseDragged = 7
    case keyDown = 10, keyUp = 11, flagsChanged = 12
    case scrollWheel = 22, tabletPointer = 23, tabletProximity = 24
    case otherMouseDown = 25, otherMouseUp = 26, otherMouseDragged = 27
    case tapDisabledByTimeout = 0xFFFFFFFE
    case tapDisabledByUserInput = 0xFFFFFFFF
}

public struct CGEventFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let maskAlphaShift = CGEventFlags(rawValue: 0x00010000)
    public static let maskShift = CGEventFlags(rawValue: 0x00020000)
    public static let maskControl = CGEventFlags(rawValue: 0x00040000)
    public static let maskAlternate = CGEventFlags(rawValue: 0x00080000)
    public static let maskCommand = CGEventFlags(rawValue: 0x00100000)
    public static let maskNumericPad = CGEventFlags(rawValue: 0x00200000)
    public static let maskHelp = CGEventFlags(rawValue: 0x00400000)
    public static let maskSecondaryFn = CGEventFlags(rawValue: 0x00800000)
    public static let maskNonCoalesced = CGEventFlags(rawValue: 0x00000100)
}

public enum CGEventField: UInt32, Sendable {
    case mouseEventNumber = 0, mouseEventClickState = 1, mouseEventPressure = 2, mouseEventButtonNumber = 3
    case mouseEventDeltaX = 4, mouseEventDeltaY = 5, mouseEventInstantMouser = 6, mouseEventSubtype = 7
    case keyboardEventAutorepeat = 8, keyboardEventKeycode = 9, keyboardEventKeyboardType = 10
    case scrollWheelEventDeltaAxis1 = 11, scrollWheelEventDeltaAxis2 = 12, scrollWheelEventDeltaAxis3 = 13
    case scrollWheelEventInstantMouser = 14
    case eventTargetProcessSerialNumber = 39, eventTargetUnixProcessID = 41, eventSourceUnixProcessID = 40
    case eventSourceUserData = 42, eventSourceUserID = 43, eventSourceGroupID = 44, eventSourceStateID = 45
    case scrollWheelEventIsContinuous = 88, mouseEventWindowUnderMousePointer = 91
    case mouseEventWindowUnderMousePointerThatCanHandleThisEvent = 92
    case scrollWheelEventFixedPtDeltaAxis1 = 93, scrollWheelEventFixedPtDeltaAxis2 = 94, scrollWheelEventFixedPtDeltaAxis3 = 95
    case scrollWheelEventPointDeltaAxis1 = 96, scrollWheelEventPointDeltaAxis2 = 97, scrollWheelEventPointDeltaAxis3 = 98
    case scrollWheelEventScrollPhase = 99, scrollWheelEventScrollCount = 100, scrollWheelEventMomentumPhase = 123
    case eventUnacceleratedPointerMovementX = 170, eventUnacceleratedPointerMovementY = 171
}

public enum CGEventTapLocation: UInt32, Sendable { case cghidEventTap = 0, cgSessionEventTap, cgAnnotatedSessionEventTap }
public enum CGEventTapPlacement: UInt32, Sendable { case headInsertEventTap = 0, tailAppendEventTap }
public enum CGEventTapOptions: UInt32, Sendable { case defaultTap = 0, listenOnly = 1 }
public enum CGEventSourceStateID: Int32, Sendable { case privateState = -1, combinedSessionState = 0, hidSystemState = 1 }
public enum CGMouseButton: UInt32, Sendable { case left = 0, right = 1, center = 2 }
public enum CGScrollEventUnit: UInt32, Sendable { case pixel = 0, line = 1 }

public typealias CGEventTapCallBack = (CGEventTapProxy, CGEventType, CGEvent, UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>?

public final class CGEventSource: @unchecked Sendable {
    public let sourceStateID: CGEventSourceStateID
    public var userData: Int64 = 0
    public var localEventsSuppressionInterval: CFTimeInterval = 0.25
    public var pixelsPerLine: Double = 10
    public var keyboardType: UInt32 = 40
    public init?(stateID: CGEventSourceStateID) { sourceStateID = stateID }
    public static func keyState(_ stateID: CGEventSourceStateID, key: CGKeyCode) -> Bool { false }
    public static func buttonState(_ stateID: CGEventSourceStateID, button: CGMouseButton) -> Bool {
        ((CGEventServices.pressedButtons?() ?? 0) >> Int(button.rawValue)) & 1 == 1
    }
    public static func flagsState(_ stateID: CGEventSourceStateID) -> CGEventFlags { [] }
    public static func secondsSinceLastEventType(_ stateID: CGEventSourceStateID, eventType: CGEventType) -> CFTimeInterval { 0 }
    public static func counterForEventType(_ stateID: CGEventSourceStateID, eventType: CGEventType) -> UInt32 { 0 }
    public func setLocalEventsFilterDuringSuppressionState(_ filter: CGEventFilterMask, state: CGEventSuppressionState) {}
}

public struct CGEventFilterMask: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let permitLocalMouseEvents = CGEventFilterMask(rawValue: 1)
    public static let permitLocalKeyboardEvents = CGEventFilterMask(rawValue: 2)
    public static let permitSystemDefinedEvents = CGEventFilterMask(rawValue: 4)
}
public enum CGEventSuppressionState: UInt32, Sendable { case eventSuppressionStateSuppressionInterval = 0, eventSuppressionStateRemoteMouseDrag }

public final class CGEvent: @unchecked Sendable {
    public var type: CGEventType
    public var flags: CGEventFlags = []
    public var location: CGPoint = .zero
    public var timestamp: CGEventTimestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1e9)
    var ints: [UInt32: Int64] = [:]
    var doubles: [UInt32: Double] = [:]
    var unicode: [UniChar] = []

    /// The current state: the pointer's location when the platform reports it.
    public init?(source: CGEventSource?) {
        type = .null
        location = CGEventServices.pointerLocation?() ?? .zero
    }
    public init?(keyboardEventSource source: CGEventSource?, virtualKey: CGKeyCode, keyDown: Bool) {
        type = keyDown ? .keyDown : .keyUp
        ints[CGEventField.keyboardEventKeycode.rawValue] = Int64(virtualKey)
    }
    public init?(mouseEventSource source: CGEventSource?, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) {
        type = mouseType
        location = mouseCursorPosition
        ints[CGEventField.mouseEventButtonNumber.rawValue] = Int64(mouseButton.rawValue)
    }
    public init?(scrollWheelEvent2Source source: CGEventSource?, units: CGScrollEventUnit, wheelCount: UInt32, wheel1: Int32, wheel2: Int32, wheel3: Int32) {
        type = .scrollWheel
        ints[CGEventField.scrollWheelEventDeltaAxis1.rawValue] = Int64(wheel1)
        ints[CGEventField.scrollWheelEventDeltaAxis2.rawValue] = Int64(wheel2)
        ints[CGEventField.scrollWheelEventDeltaAxis3.rawValue] = Int64(wheel3)
    }
    private init(copying e: CGEvent) {
        type = e.type; flags = e.flags; location = e.location; timestamp = e.timestamp
        ints = e.ints; doubles = e.doubles; unicode = e.unicode
    }

    public func copy() -> CGEvent? { CGEvent(copying: self) }
    public func getIntegerValueField(_ field: CGEventField) -> Int64 { ints[field.rawValue] ?? 0 }
    public func setIntegerValueField(_ field: CGEventField, value: Int64) { ints[field.rawValue] = value }
    public func getDoubleValueField(_ field: CGEventField) -> Double { doubles[field.rawValue] ?? Double(ints[field.rawValue] ?? 0) }
    public func setDoubleValueField(_ field: CGEventField, value: Double) { doubles[field.rawValue] = value }
    public func keyboardSetUnicodeString(stringLength: Int, unicodeString: UnsafePointer<UniChar>?) {
        unicode = unicodeString.map { Array(UnsafeBufferPointer(start: $0, count: stringLength)) } ?? []
    }
    public func keyboardGetUnicodeString(maxStringLength: Int, actualStringLength: UnsafeMutablePointer<Int>?, unicodeString: UnsafeMutablePointer<UniChar>?) {
        let n = Swift.min(maxStringLength, unicode.count)
        if let unicodeString { for i in 0..<n { unicodeString[i] = unicode[i] } }
        actualStringLength?.pointee = n
    }
    public func setSource(_ source: CGEventSource?) {}

    /// Posting to other apps needs a privilege Runway doesn't take: dropped.
    public func post(tap: CGEventTapLocation) {}
    public func postToPid(_ pid: pid_t) {}
    public func postToPSN(processSerialNumber: UnsafeMutableRawPointer?) {}

    /// System-wide event taps aren't available: nil, as on a Mac without
    /// Input Monitoring / Accessibility access.
    public static func tapCreate(tap: CGEventTapLocation, place: CGEventTapPlacement, options: CGEventTapOptions,
                                 eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?) -> CFMachPort? { nil }
    public static func tapCreateForPid(pid: pid_t, place: CGEventTapPlacement, options: CGEventTapOptions,
                                       eventsOfInterest: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?) -> CFMachPort? { nil }
    public static func tapEnable(tap: CFMachPort, enable: Bool) {}
    public static func tapIsEnabled(tap: CFMachPort) -> Bool { false }
    public static func tapPostEvent(_ proxy: CGEventTapProxy?, event: CGEvent?) {}
}


public func CGEventMaskBit(_ type: CGEventType) -> CGEventMask { 1 << CGEventMask(type.rawValue) }

public func CGPreflightListenEventAccess() -> Bool { false }
public func CGRequestListenEventAccess() -> Bool { false }
public func CGPreflightPostEventAccess() -> Bool { false }
public func CGRequestPostEventAccess() -> Bool { false }

public func CGWarpMouseCursorPosition(_ newCursorPosition: CGPoint) -> CGError { .cannotComplete }
public func CGAssociateMouseAndMouseCursorPosition(_ connected: Bool) -> CGError { .success }
public func CGAssociateMouseAndMouseCursorPosition(_ connected: Int32) -> CGError { .success }
public func CGEventSourceButtonState(_ state: CGEventSourceStateID, _ button: CGMouseButton) -> Bool {
    CGEventSource.buttonState(state, button: button)
}
public func CGDisplayHideCursor(_ display: CGDirectDisplayID) -> CGError { .success }
public func CGDisplayShowCursor(_ display: CGDirectDisplayID) -> CGError { .success }

public enum CGError: Int32, Error, Sendable {
    case success = 0, failure = 1000, illegalArgument = 1001, invalidConnection = 1002, invalidContext = 1003
    case cannotComplete = 1004, notImplemented = 1006, rangeCheck = 1007, typeCheck = 1008, invalidOperation = 1010
    case noneAvailable = 1011
}

// MARK: Window list

public struct CGWindowListOption: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let optionAll = CGWindowListOption([])
    public static let optionOnScreenOnly = CGWindowListOption(rawValue: 1 << 0)
    public static let optionOnScreenAboveWindow = CGWindowListOption(rawValue: 1 << 1)
    public static let optionOnScreenBelowWindow = CGWindowListOption(rawValue: 1 << 2)
    public static let optionIncludingWindow = CGWindowListOption(rawValue: 1 << 3)
    public static let excludeDesktopElements = CGWindowListOption(rawValue: 1 << 4)
}

public let kCGWindowNumber: CFString = "kCGWindowNumber"
public let kCGWindowStoreType: CFString = "kCGWindowStoreType"
public let kCGWindowLayer: CFString = "kCGWindowLayer"
public let kCGWindowBounds: CFString = "kCGWindowBounds"
public let kCGWindowSharingState: CFString = "kCGWindowSharingState"
public let kCGWindowAlpha: CFString = "kCGWindowAlpha"
public let kCGWindowOwnerPID: CFString = "kCGWindowOwnerPID"
public let kCGWindowMemoryUsage: CFString = "kCGWindowMemoryUsage"
public let kCGWindowOwnerName: CFString = "kCGWindowOwnerName"
public let kCGWindowName: CFString = "kCGWindowName"
public let kCGWindowIsOnscreen: CFString = "kCGWindowIsOnscreen"
public let kCGWindowBackingLocationVideoMemory: CFString = "kCGWindowBackingLocationVideoMemory"

/// One X11 top-level window, as the window list reports it.
struct WindowInfo { var id: UInt32; var pid: Int32; var owner: String; var title: String; var bounds: CGRect }

func x11Windows() -> [WindowInfo] {
    #if os(Linux)
    guard let x = X11.shared, let dpy = x.XOpenDisplay(nil) else { return [] }
    defer { _ = x.XCloseDisplay(dpy) }
    let root = x.XDefaultRootWindow(dpy)
    // _NET_CLIENT_LIST_STACKING is bottom to top; the window list is front to back.
    let ids = (x.property(dpy, root, "_NET_CLIENT_LIST_STACKING") ?? x.property(dpy, root, "_NET_CLIENT_LIST"))?.items.reversed() ?? []
    return ids.map { w in
        let pid = Int32(truncatingIfNeeded: x.property(dpy, w, "_NET_WM_PID")?.items.first ?? 0)
        let title = (x.property(dpy, w, "_NET_WM_NAME")?.bytes).map { String(decoding: $0, as: UTF8.self) }
            ?? (x.property(dpy, w, "WM_NAME")?.bytes).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var owner = ""
        if pid > 0, let comm = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) { owner = comm.trimmingCharacters(in: .whitespacesAndNewlines) }
        if owner.isEmpty, let cls = x.property(dpy, w, "WM_CLASS")?.bytes {
            owner = cls.split(separator: 0).last.map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        var rootRet: UInt = 0, child: UInt = 0
        var gx: Int32 = 0, gy: Int32 = 0, ax: Int32 = 0, ay: Int32 = 0
        var gw: UInt32 = 0, gh: UInt32 = 0, border: UInt32 = 0, depth: UInt32 = 0
        _ = x.XGetGeometry(dpy, w, &rootRet, &gx, &gy, &gw, &gh, &border, &depth)
        _ = x.XTranslateCoordinates(dpy, w, root, 0, 0, &ax, &ay, &child)
        return WindowInfo(id: UInt32(truncatingIfNeeded: w), pid: pid, owner: owner, title: title,
                          bounds: CGRect(x: CGFloat(ax), y: CGFloat(ay), width: CGFloat(gw), height: CGFloat(gh)))
    }
    #else
    return []
    #endif
}

public func CGWindowListCopyWindowInfo(_ option: CGWindowListOption, _ relativeToWindow: CGWindowID) -> CFArray? {
    var windows = x11Windows()
    if option.contains(.optionIncludingWindow) && !option.contains(.optionOnScreenAboveWindow) && !option.contains(.optionOnScreenBelowWindow) {
        windows = windows.filter { $0.id == relativeToWindow }
    } else if let i = windows.firstIndex(where: { $0.id == relativeToWindow }) {
        let incl = option.contains(.optionIncludingWindow)
        if option.contains(.optionOnScreenAboveWindow) { windows = Array(windows[..<(incl ? i + 1 : i)]) }
        else if option.contains(.optionOnScreenBelowWindow) { windows = Array(windows[(incl ? i : i + 1)...]) }
    }
    let dicts: [NSDictionary] = windows.map { w in
        [kCGWindowNumber as String: NSNumber(value: w.id),
         kCGWindowOwnerPID as String: NSNumber(value: w.pid),
         kCGWindowOwnerName as String: w.owner as NSString,
         kCGWindowName as String: w.title as NSString,
         kCGWindowLayer as String: NSNumber(value: 0),
         kCGWindowAlpha as String: NSNumber(value: 1.0),
         kCGWindowIsOnscreen as String: NSNumber(value: true),
         kCGWindowSharingState as String: NSNumber(value: 1),
         kCGWindowStoreType as String: NSNumber(value: 1),
         kCGWindowMemoryUsage as String: NSNumber(value: 0),
         kCGWindowBounds as String: ["X": NSNumber(value: Double(w.bounds.minX)), "Y": NSNumber(value: Double(w.bounds.minY)),
                                     "Width": NSNumber(value: Double(w.bounds.width)), "Height": NSNumber(value: Double(w.bounds.height))] as NSDictionary,
        ] as NSDictionary
    }
    return dicts as NSArray
}

public func CGWindowListCreate(_ option: CGWindowListOption, _ relativeToWindow: CGWindowID) -> CFArray? {
    (CGWindowListCopyWindowInfo(option, relativeToWindow) as? [NSDictionary])?.compactMap { $0[kCGWindowNumber as String] } as NSArray?
}

public func CGWindowListCreateDescriptionFromArray(_ windowArray: CFArray?) -> CFArray? {
    let ids = Set((windowArray as? [NSNumber])?.map(\.uint32Value) ?? [])
    return (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [NSDictionary])?
        .filter { ids.contains(($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0) } as NSArray?
}

extension CGRect {
    /// A rect from a kCGWindowBounds-style dictionary (X, Y, Width, Height).
    public init?(dictionaryRepresentation dict: CFDictionary) {
        func v(_ k: String) -> CGFloat? { ((dict as NSDictionary)[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
        guard let x = v("X"), let y = v("Y"), let w = v("Width"), let h = v("Height") else { return nil }
        self.init(x: x, y: y, width: w, height: h)
    }
    public var dictionaryRepresentation: CFDictionary {
        ["X": NSNumber(value: Double(minX)), "Y": NSNumber(value: Double(minY)),
         "Width": NSNumber(value: Double(width)), "Height": NSNumber(value: Double(height))] as NSDictionary
    }
}
