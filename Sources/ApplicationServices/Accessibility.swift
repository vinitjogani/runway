// ApplicationServices for Linux and Windows: the Accessibility client API
// (AXIsProcessTrusted, AXUIElement, AXObserver) answers as on a Mac where
// the user hasn't granted the app Accessibility access: not trusted, the
// prompt is a no-op, and every element call returns .apiDisabled. Apps
// already handle that case (they ask the user to enable access and wait).
// Other processes' UI isn't reachable this way on Linux (AT-SPI is a
// different model) or Windows (UI Automation).

@_exported import RunwayCF
@_exported import CoreGraphics
import Foundation

public let kAXTrustedCheckOptionPrompt: Unmanaged<CFString> = Unmanaged.passRetained("AXTrustedCheckOptionPrompt" as NSString)

public func AXIsProcessTrusted() -> Bool { false }
public func AXIsProcessTrustedWithOptions(_ options: CFDictionary?) -> Bool { false }
public func AXAPIEnabled() -> Bool { false }

public enum AXError: Int32, Error, Sendable {
    case success = 0
    case failure = -25200
    case illegalArgument = -25201
    case invalidUIElement = -25202
    case invalidUIElementObserver = -25203
    case cannotComplete = -25204
    case attributeUnsupported = -25205
    case actionUnsupported = -25206
    case notificationUnsupported = -25207
    case notImplemented = -25208
    case notificationAlreadyRegistered = -25209
    case notificationNotRegistered = -25210
    case apiDisabled = -25211
    case noValue = -25212
    case parameterizedAttributeUnsupported = -25213
    case notEnoughPrecision = -25214
}

public final class AXUIElement: Hashable, @unchecked Sendable {
    let pid: pid_t
    init(pid: pid_t) { self.pid = pid }
    public static func == (a: AXUIElement, b: AXUIElement) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

public final class AXObserver: @unchecked Sendable {
    let source = CFRunLoopSource()
}

public final class AXValue: @unchecked Sendable {
    let type: AXValueType
    let bytes: [UInt8]
    init(type: AXValueType, bytes: [UInt8]) { self.type = type; self.bytes = bytes }
}

public enum AXValueType: UInt32, Sendable {
    case illegal = 0, cgPoint = 1, cgSize = 2, cgRect = 3, cfRange = 4, axError = 5
}

public struct AXUIElementCopyMultipleAttributeOptions: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let stopOnError = AXUIElementCopyMultipleAttributeOptions(rawValue: 1)
}

// Swift closures (Swift classes have no C representation without Objective-C); C function literals still convert.
public typealias AXObserverCallback = (AXObserver, AXUIElement, CFString, UnsafeMutableRawPointer?) -> Void
public typealias AXObserverCallbackWithInfo = (AXObserver, AXUIElement, CFString, CFDictionary, UnsafeMutableRawPointer?) -> Void

public func AXUIElementCreateSystemWide() -> AXUIElement { AXUIElement(pid: 0) }
public func AXUIElementCreateApplication(_ pid: pid_t) -> AXUIElement { AXUIElement(pid: pid) }
public func AXUIElementGetTypeID() -> CFTypeID { 0x4158 }
public func AXUIElementGetPid(_ element: AXUIElement, _ pid: UnsafeMutablePointer<pid_t>) -> AXError { pid.pointee = element.pid; return .success }

public func AXUIElementCopyAttributeNames(_ element: AXUIElement, _ names: UnsafeMutablePointer<CFArray?>) -> AXError { .apiDisabled }
public func AXUIElementCopyAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: UnsafeMutablePointer<CFTypeRef?>) -> AXError { .apiDisabled }
public func AXUIElementCopyAttributeValues(_ element: AXUIElement, _ attribute: CFString, _ index: CFIndex, _ maxValues: CFIndex,
                                           _ values: UnsafeMutablePointer<CFArray?>) -> AXError { .apiDisabled }
public func AXUIElementCopyMultipleAttributeValues(_ element: AXUIElement, _ attributes: CFArray, _ options: AXUIElementCopyMultipleAttributeOptions,
                                                   _ values: UnsafeMutablePointer<CFArray?>) -> AXError { .apiDisabled }
public func AXUIElementGetAttributeValueCount(_ element: AXUIElement, _ attribute: CFString, _ count: UnsafeMutablePointer<CFIndex>) -> AXError { .apiDisabled }
public func AXUIElementIsAttributeSettable(_ element: AXUIElement, _ attribute: CFString, _ settable: UnsafeMutablePointer<DarwinBoolean>) -> AXError { .apiDisabled }
public func AXUIElementSetAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ value: CFTypeRef) -> AXError { .apiDisabled }
public func AXUIElementCopyParameterizedAttributeNames(_ element: AXUIElement, _ names: UnsafeMutablePointer<CFArray?>) -> AXError { .apiDisabled }
public func AXUIElementCopyParameterizedAttributeValue(_ element: AXUIElement, _ attribute: CFString, _ parameter: CFTypeRef,
                                                       _ result: UnsafeMutablePointer<CFTypeRef?>) -> AXError { .apiDisabled }
public func AXUIElementCopyActionNames(_ element: AXUIElement, _ names: UnsafeMutablePointer<CFArray?>) -> AXError { .apiDisabled }
public func AXUIElementCopyActionDescription(_ element: AXUIElement, _ action: CFString, _ description: UnsafeMutablePointer<CFString>) -> AXError { .apiDisabled }
public func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError { .apiDisabled }
public func AXUIElementCopyElementAtPosition(_ application: AXUIElement, _ x: Float, _ y: Float, _ element: UnsafeMutablePointer<AXUIElement?>) -> AXError { .apiDisabled }
public func AXUIElementSetMessagingTimeout(_ element: AXUIElement, _ timeoutInSeconds: Float) -> AXError { .success }
public func AXUIElementPostKeyboardEvent(_ application: AXUIElement, _ keyChar: CGCharCode, _ virtualKey: CGKeyCode, _ keyDown: Bool) -> AXError { .apiDisabled }

public func AXObserverCreate(_ application: pid_t, _ callback: AXObserverCallback, _ outObserver: UnsafeMutablePointer<AXObserver?>) -> AXError {
    outObserver.pointee = AXObserver()
    return .success
}
public func AXObserverCreateWithInfoCallback(_ application: pid_t, _ callback: AXObserverCallbackWithInfo,
                                             _ outObserver: UnsafeMutablePointer<AXObserver?>) -> AXError {
    outObserver.pointee = AXObserver()
    return .success
}
public func AXObserverAddNotification(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) -> AXError { .apiDisabled }
public func AXObserverRemoveNotification(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString) -> AXError { .notificationNotRegistered }
public func AXObserverGetRunLoopSource(_ observer: AXObserver) -> CFRunLoopSource { observer.source }

public func AXValueCreate(_ theType: AXValueType, _ valuePtr: UnsafeRawPointer) -> AXValue? {
    let size: Int
    switch theType {
    case .cgPoint: size = MemoryLayout<CGPoint>.size
    case .cgSize: size = MemoryLayout<CGSize>.size
    case .cgRect: size = MemoryLayout<CGRect>.size
    case .cfRange: size = 2 * MemoryLayout<Int>.size
    case .axError: size = MemoryLayout<Int32>.size
    case .illegal: return nil
    }
    return AXValue(type: theType, bytes: Array(UnsafeRawBufferPointer(start: valuePtr, count: size)))
}
public func AXValueGetType(_ value: AXValue) -> AXValueType { value.type }
public func AXValueGetValue(_ value: AXValue, _ theType: AXValueType, _ valuePtr: UnsafeMutableRawPointer) -> Bool {
    guard value.type == theType else { return false }
    value.bytes.withUnsafeBytes { valuePtr.copyMemory(from: $0.baseAddress!, byteCount: value.bytes.count) }
    return true
}
public func AXValueGetTypeID() -> CFTypeID { 0x4156 }


// Attribute, action and notification names (Apple's are CFSTR macros,
// imported as String).
public let kAXRoleAttribute = "AXRole"
public let kAXSubroleAttribute = "AXSubrole"
public let kAXRoleDescriptionAttribute = "AXRoleDescription"
public let kAXTitleAttribute = "AXTitle"
public let kAXDescriptionAttribute = "AXDescription"
public let kAXValueAttribute = "AXValue"
public let kAXHelpAttribute = "AXHelp"
public let kAXParentAttribute = "AXParent"
public let kAXChildrenAttribute = "AXChildren"
public let kAXWindowsAttribute = "AXWindows"
public let kAXWindowAttribute = "AXWindow"
public let kAXMainWindowAttribute = "AXMainWindow"
public let kAXFocusedWindowAttribute = "AXFocusedWindow"
public let kAXFocusedApplicationAttribute = "AXFocusedApplication"
public let kAXFocusedUIElementAttribute = "AXFocusedUIElement"
public let kAXFocusedAttribute = "AXFocused"
public let kAXPositionAttribute = "AXPosition"
public let kAXSizeAttribute = "AXSize"
public let kAXFrameAttribute = "AXFrame"
public let kAXMinimizedAttribute = "AXMinimized"
public let kAXFullScreenAttribute = "AXFullScreen"
public let kAXMainAttribute = "AXMain"
public let kAXEnabledAttribute = "AXEnabled"
public let kAXSelectedTextAttribute = "AXSelectedText"
public let kAXSelectedTextRangeAttribute = "AXSelectedTextRange"
public let kAXNumberOfCharactersAttribute = "AXNumberOfCharacters"
public let kAXCloseButtonAttribute = "AXCloseButton"
public let kAXZoomButtonAttribute = "AXZoomButton"
public let kAXMinimizeButtonAttribute = "AXMinimizeButton"
public let kAXFullScreenButtonAttribute = "AXFullScreenButton"
public let kAXHiddenAttribute = "AXHidden"
public let kAXFrontmostAttribute = "AXFrontmost"
public let kAXMenuBarAttribute = "AXMenuBar"
public let kAXIdentifierAttribute = "AXIdentifier"
public let kAXURLAttribute = "AXURL"
public let kAXDocumentAttribute = "AXDocument"
public let kAXModalAttribute = "AXModal"
public let kAXEnhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
public let kAXBoundsForRangeParameterizedAttribute = "AXBoundsForRange"
public let kAXStringForRangeParameterizedAttribute = "AXStringForRange"

public let kAXPressAction = "AXPress"
public let kAXRaiseAction = "AXRaise"
public let kAXCancelAction = "AXCancel"
public let kAXConfirmAction = "AXConfirm"
public let kAXShowMenuAction = "AXShowMenu"
public let kAXIncrementAction = "AXIncrement"
public let kAXDecrementAction = "AXDecrement"

public let kAXWindowRole = "AXWindow"
public let kAXApplicationRole = "AXApplication"
public let kAXButtonRole = "AXButton"
public let kAXTextFieldRole = "AXTextField"
public let kAXTextAreaRole = "AXTextArea"
public let kAXStandardWindowSubrole = "AXStandardWindow"
public let kAXDialogSubrole = "AXDialog"
public let kAXFloatingWindowSubrole = "AXFloatingWindow"
public let kAXSystemDialogSubrole = "AXSystemDialog"

public let kAXFocusedWindowChangedNotification = "AXFocusedWindowChanged"
public let kAXMainWindowChangedNotification = "AXMainWindowChanged"
public let kAXFocusedUIElementChangedNotification = "AXFocusedUIElementChanged"
public let kAXWindowCreatedNotification = "AXWindowCreated"
public let kAXWindowMovedNotification = "AXWindowMoved"
public let kAXWindowResizedNotification = "AXWindowResized"
public let kAXWindowMiniaturizedNotification = "AXWindowMiniaturized"
public let kAXWindowDeminiaturizedNotification = "AXWindowDeminiaturized"
public let kAXUIElementDestroyedNotification = "AXUIElementDestroyed"
public let kAXApplicationActivatedNotification = "AXApplicationActivated"
public let kAXApplicationDeactivatedNotification = "AXApplicationDeactivated"
public let kAXApplicationHiddenNotification = "AXApplicationHidden"
public let kAXApplicationShownNotification = "AXApplicationShown"
public let kAXTitleChangedNotification = "AXTitleChanged"
public let kAXValueChangedNotification = "AXValueChanged"
public let kAXSelectedTextChangedNotification = "AXSelectedTextChanged"
public let kAXCreatedNotification = "AXCreated"
public let kAXMovedNotification = "AXMoved"
public let kAXResizedNotification = "AXResized"
public let kAXGroupRole = "AXGroup"
public let kAXStaticTextRole = "AXStaticText"
public let kAXCellRole = "AXCell"
public let kAXComboBoxRole = "AXComboBox"
public let kAXMenuRole = "AXMenu"
public let kAXMenuBarItemRole = "AXMenuBarItem"
public let kAXMenuItemRole = "AXMenuItem"
public let kAXMenuButtonRole = "AXMenuButton"
public let kAXPopUpButtonRole = "AXPopUpButton"
public let kAXRadioButtonRole = "AXRadioButton"
public let kAXCheckBoxRole = "AXCheckBox"
public let kAXSheetRole = "AXSheet"
public let kAXTabGroupRole = "AXTabGroup"
public let kAXScrollAreaRole = "AXScrollArea"
public let kAXImageRole = "AXImage"
public let kAXEditedAttribute = "AXEdited"
public let kAXSelectedChildrenAttribute = "AXSelectedChildren"
public let kAXVisibleChildrenAttribute = "AXVisibleChildren"
public let kAXHorizontalScrollBarAttribute = "AXHorizontalScrollBar"
public let kAXVerticalScrollBarAttribute = "AXVerticalScrollBar"
public typealias AXCopyMultipleAttributeOptions = AXUIElementCopyMultipleAttributeOptions
