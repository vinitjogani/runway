// Text Input Sources and UCKeyTranslate, as shortcut recorders use them to
// name keys. The current keyboard layout is reported as U.S. (its id,
// name and "layout data"), and UCKeyTranslate maps key codes through the US
// ANSI layout, so shortcuts display as they would on a US Mac keyboard.

import Foundation

public final class TISInputSource: @unchecked Sendable {
    let properties: [String: AnyObject]
    init(_ p: [String: AnyObject]) { properties = p }
}


public let kTISPropertyInputSourceCategory: CFString! = "TISPropertyInputSourceCategory"
public let kTISPropertyInputSourceType: CFString! = "TISPropertyInputSourceType"
public let kTISPropertyInputSourceIsASCIICapable: CFString! = "TISPropertyInputSourceIsASCIICapable"
public let kTISPropertyInputSourceIsEnableCapable: CFString! = "TISPropertyInputSourceIsEnableCapable"
public let kTISPropertyInputSourceIsSelectCapable: CFString! = "TISPropertyInputSourceIsSelectCapable"
public let kTISPropertyInputSourceIsEnabled: CFString! = "TISPropertyInputSourceIsEnabled"
public let kTISPropertyInputSourceIsSelected: CFString! = "TISPropertyInputSourceIsSelected"
public let kTISPropertyInputSourceID: CFString! = "TISPropertyInputSourceID"
public let kTISPropertyBundleID: CFString! = "TISPropertyBundleID"
public let kTISPropertyInputModeID: CFString! = "TISPropertyInputModeID"
public let kTISPropertyLocalizedName: CFString! = "TISPropertyLocalizedName"
public let kTISPropertyInputSourceLanguages: CFString! = "TISPropertyInputSourceLanguages"
public let kTISPropertyUnicodeKeyLayoutData: CFString! = "TISPropertyUnicodeKeyLayoutData"
public let kTISPropertyIconRef: CFString! = "TISPropertyIconRef"
public let kTISPropertyIconImageURL: CFString! = "TISPropertyIconImageURL"
public let kTISCategoryKeyboardInputSource: CFString! = "TISCategoryKeyboardInputSource"
public let kTISTypeKeyboardLayout: CFString! = "TISTypeKeyboardLayout"
public let kTISTypeKeyboardInputMode: CFString! = "TISTypeKeyboardInputMode"
public let kTISNotifySelectedKeyboardInputSourceChanged: CFString! = "TISNotifySelectedKeyboardInputSourceChanged"
public let kTISNotifyEnabledKeyboardInputSourcesChanged: CFString! = "TISNotifyEnabledKeyboardInputSourcesChanged"

private let usLayoutData: NSData = {
    var header = UCKeyboardLayout()
    return NSData(bytes: &header, length: MemoryLayout<UCKeyboardLayout>.size)
}()

private let usSource = TISInputSource([
    kTISPropertyInputSourceID as String: "com.apple.keylayout.US" as NSString,
    kTISPropertyLocalizedName as String: "U.S." as NSString,
    kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource,
    kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout,
    kTISPropertyInputSourceIsASCIICapable as String: NSNumber(value: true),
    kTISPropertyInputSourceIsEnabled as String: NSNumber(value: true),
    kTISPropertyInputSourceIsSelected as String: NSNumber(value: true),
    kTISPropertyInputSourceLanguages as String: ["en"] as NSArray,
    kTISPropertyUnicodeKeyLayoutData as String: usLayoutData,
])

public func TISCopyCurrentKeyboardInputSource() -> Unmanaged<TISInputSource>! { .passRetained(usSource) }
public func TISCopyCurrentKeyboardLayoutInputSource() -> Unmanaged<TISInputSource>! { .passRetained(usSource) }
public func TISCopyCurrentASCIICapableKeyboardInputSource() -> Unmanaged<TISInputSource>! { .passRetained(usSource) }
public func TISCopyCurrentASCIICapableKeyboardLayoutInputSource() -> Unmanaged<TISInputSource>! { .passRetained(usSource) }
public func TISCopyInputSourceForLanguage(_ language: CFString!) -> Unmanaged<TISInputSource>! { .passRetained(usSource) }
public func TISCreateInputSourceList(_ properties: CFDictionary!, _ includeAllInstalled: Bool) -> Unmanaged<CFArray>! {
    .passRetained([usSource] as NSArray)
}
public func TISSelectInputSource(_ inputSource: TISInputSource!) -> OSStatus { noErr }
public func TISEnableInputSource(_ inputSource: TISInputSource!) -> OSStatus { noErr }
public func TISDisableInputSource(_ inputSource: TISInputSource!) -> OSStatus { paramErr }
public func TISGetInputSourceTypeID() -> CFTypeID { 0x5449 }

/// The property as Core Foundation hands it back: an unretained object pointer.
public func TISGetInputSourceProperty(_ inputSource: TISInputSource!, _ propertyKey: CFString!) -> UnsafeMutableRawPointer! {
    guard let inputSource, let propertyKey, let v = inputSource.properties[propertyKey as String] else { return nil }
    return Unmanaged.passUnretained(v).toOpaque()
}

public func LMGetKbdType() -> UInt8 { 40 }   // ANSI
public func LMGetKbdLast() -> UInt8 { 40 }
public func KBGetLayoutType(_ iKeyboardType: Int16) -> UInt32 { 0 }

