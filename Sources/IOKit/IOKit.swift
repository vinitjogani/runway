// IOKit for Linux and Windows. The I/O Registry holds one service, the
// platform expert (IOPlatformUUID from /etc/machine-id, serial number and
// model from DMI), so the common "machine identifier" lookup works; other
// matches find nothing, as on a Mac without that hardware. HID devices
// aren't reachable (IOHIDCheckAccess answers denied). Power sources come
// from /sys/class/power_supply, with change notifications from UPower over
// D-Bus; power assertions inhibit idle sleep / the screen saver through
// logind and org.freedesktop.ScreenSaver (PowerSetRequest on Windows).

@_exported import RunwayCF
import Foundation
import RunwayDBus
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public typealias IOReturn = kern_return_t
public typealias io_object_t = mach_port_t
public typealias io_iterator_t = io_object_t
public typealias io_service_t = io_object_t
public typealias io_registry_entry_t = io_object_t
public typealias io_connect_t = io_object_t
public typealias io_name_t = (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                              CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                              CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                              CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                              CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                              CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                              CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                              CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
public typealias IOOptionBits = UInt32
public typealias IOByteCount32 = UInt32
public typealias IOByteCount64 = UInt64
public typealias IOByteCount = UInt
public typealias IOFixed = Int32
public typealias IOVersion = UInt32
public typealias IOCacheMode = UInt32
public typealias IOPhysicalAddress = UInt
public typealias IOVirtualAddress = UInt
public typealias IOPhysicalLength = UInt
public typealias IOItemCount = UInt32
public typealias IOPMAssertionID = UInt32
public typealias IOPMAssertionLevel = UInt32

public let kIOReturnSuccess: IOReturn = 0
public let kIOReturnError = IOReturn(bitPattern: 0xE00002BC)
public let kIOReturnNoMemory = IOReturn(bitPattern: 0xE00002BD)
public let kIOReturnNoResources = IOReturn(bitPattern: 0xE00002BE)
public let kIOReturnNoDevice = IOReturn(bitPattern: 0xE00002C0)
public let kIOReturnNotPrivileged = IOReturn(bitPattern: 0xE00002C1)
public let kIOReturnBadArgument = IOReturn(bitPattern: 0xE00002C2)
public let kIOReturnUnsupported = IOReturn(bitPattern: 0xE00002C7)
public let kIOReturnTimeout = IOReturn(bitPattern: 0xE00002D6)
public let kIOReturnNotPermitted = IOReturn(bitPattern: 0xE00002E2)
public let kIOReturnNotFound = IOReturn(bitPattern: 0xE00002F0)
public let kIOReturnNotOpen = IOReturn(bitPattern: 0xE00002CD)

public let kIOMainPortDefault: mach_port_t = 0
public let kIOMasterPortDefault: mach_port_t = 0
public let IO_OBJECT_NULL: io_object_t = 0
public let kIOServicePlane = "IOService"
public let kIODeviceTreePlane = "IODeviceTree"
public var kIORegistryIterateRecursively: Int { 1 }
public var kIORegistryIterateParents: Int { 2 }

public let kIOPlatformUUIDKey = "IOPlatformUUID"
public let kIOPlatformSerialNumberKey = "IOPlatformSerialNumber"
public let kIOPlatformExpertDeviceClass = "IOPlatformExpertDevice"
public let kIOProviderClassKey = "IOProviderClass"
public let kIONameMatchKey = "IONameMatch"
public let kIOBSDNameKey = "BSD Name"

// MARK: Registry

enum Registry {
    final class Entry {
        let className: String
        let name: String
        let properties: [String: AnyObject]
        init(_ c: String, _ n: String, _ p: [String: AnyObject]) { className = c; name = n; properties = p }
    }
    final class Iterator { var items: [io_object_t]; init(_ i: [io_object_t]) { items = i } }

    static let lock = NSLock()
    nonisolated(unsafe) static var objects: [io_object_t: AnyObject] = [:]
    nonisolated(unsafe) static var refs: [io_object_t: Int] = [:]
    nonisolated(unsafe) static var next: io_object_t = 0x1000

    static func add(_ o: AnyObject) -> io_object_t {
        lock.lock(); defer { lock.unlock() }
        next += 1
        objects[next] = o
        refs[next] = 1
        return next
    }
    static func get(_ h: io_object_t) -> AnyObject? { lock.lock(); defer { lock.unlock() }; return objects[h] }

    static func read(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static let platformExpert: Entry = {
        var p: [String: AnyObject] = [:]
        #if os(Linux)
        if let id = read("/etc/machine-id") ?? read("/var/lib/dbus/machine-id"), id.count == 32 {
            let c = Array(id.uppercased())
            let uuid = "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))"
            p[kIOPlatformUUIDKey] = uuid as NSString
        }
        if let s = read("/sys/class/dmi/id/product_serial") { p[kIOPlatformSerialNumberKey] = s as NSString }
        if let m = read("/sys/class/dmi/id/product_name") { p["model"] = Data(m.utf8) as NSData }
        if let v = read("/sys/class/dmi/id/sys_vendor") { p["manufacturer"] = Data(v.utf8) as NSData }
        #endif
        return Entry(kIOPlatformExpertDeviceClass, "IOPlatformExpertDevice", p)
    }()

    static func matches(_ matching: NSDictionary?) -> [Entry] {
        guard let m = matching else { return [] }
        let cls = (m[kIOProviderClassKey] as? String) ?? (m[kIOProviderClassKey] as? NSString).map { $0 as String }
        let name = (m[kIONameMatchKey] as? String) ?? (m["IONameMatched"] as? String)
        if cls == kIOPlatformExpertDeviceClass || name == "IOPlatformExpertDevice" { return [platformExpert] }
        return []
    }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

public func IOServiceMatching(_ name: UnsafePointer<CChar>!) -> CFMutableDictionary! {
    NSMutableDictionary(dictionary: [kIOProviderClassKey: String(cString: name)])
}
public func IOServiceNameMatching(_ name: UnsafePointer<CChar>!) -> CFMutableDictionary! {
    NSMutableDictionary(dictionary: [kIONameMatchKey: String(cString: name)])
}
public func IOBSDNameMatching(_ mainPort: mach_port_t, _ options: UInt32, _ bsdName: UnsafePointer<CChar>!) -> CFMutableDictionary! {
    NSMutableDictionary(dictionary: [kIOBSDNameKey: String(cString: bsdName)])
}

public func IOServiceGetMatchingService(_ mainPort: mach_port_t, _ matching: CFDictionary!) -> io_service_t {
    Registry.matches(matching).first.map(Registry.add) ?? 0
}

public func IOServiceGetMatchingServices(_ mainPort: mach_port_t, _ matching: CFDictionary!, _ existing: UnsafeMutablePointer<io_iterator_t>!) -> kern_return_t {
    let items = Registry.matches(matching).map(Registry.add)
    existing?.pointee = Registry.add(Registry.Iterator(items))
    return KERN_SUCCESS
}

public func IOIteratorNext(_ iterator: io_iterator_t) -> io_object_t {
    guard let it = Registry.get(iterator) as? Registry.Iterator, !it.items.isEmpty else { return 0 }
    return it.items.removeFirst()
}
public func IOIteratorIsValid(_ iterator: io_iterator_t) -> Bool { Registry.get(iterator) is Registry.Iterator }
public func IOIteratorReset(_ iterator: io_iterator_t) {}

public func IOObjectRetain(_ object: io_object_t) -> kern_return_t {
    Registry.lock.lock(); defer { Registry.lock.unlock() }
    guard Registry.objects[object] != nil else { return KERN_INVALID_ARGUMENT }
    Registry.refs[object, default: 0] += 1
    return KERN_SUCCESS
}
public func IOObjectRelease(_ object: io_object_t) -> kern_return_t {
    Registry.lock.lock(); defer { Registry.lock.unlock() }
    guard Registry.objects[object] != nil else { return KERN_INVALID_ARGUMENT }
    Registry.refs[object, default: 1] -= 1
    if Registry.refs[object]! <= 0 { Registry.objects[object] = nil; Registry.refs[object] = nil }
    return KERN_SUCCESS
}
public func IOObjectConformsTo(_ object: io_object_t, _ className: UnsafePointer<CChar>!) -> boolean_t {
    (Registry.get(object) as? Registry.Entry)?.className == String(cString: className) ? 1 : 0
}
public typealias boolean_t = Int32
public func IOObjectGetClass(_ object: io_object_t, _ className: UnsafeMutablePointer<CChar>!) -> kern_return_t {
    guard let e = Registry.get(object) as? Registry.Entry else { return KERN_INVALID_ARGUMENT }
    _ = e.className.withCString { strncpy(className, $0, 127) }
    return KERN_SUCCESS
}

public func IORegistryEntryCreateCFProperty(_ entry: io_registry_entry_t, _ key: CFString!, _ allocator: CFAllocator!,
                                            _ options: IOOptionBits) -> Unmanaged<CFTypeRef>! {
    guard let e = Registry.get(entry) as? Registry.Entry, let v = e.properties[key as String] else { return nil }
    return .passRetained(v)
}
public func IORegistryEntrySearchCFProperty(_ entry: io_registry_entry_t, _ plane: UnsafePointer<CChar>!, _ key: CFString!,
                                            _ allocator: CFAllocator!, _ options: IOOptionBits) -> CFTypeRef! {
    (Registry.get(entry) as? Registry.Entry)?.properties[key as String]
}
public func IORegistryEntryCreateCFProperties(_ entry: io_registry_entry_t, _ properties: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>!,
                                              _ allocator: CFAllocator!, _ options: IOOptionBits) -> kern_return_t {
    guard let e = Registry.get(entry) as? Registry.Entry else { return KERN_INVALID_ARGUMENT }
    properties?.pointee = .passRetained(NSMutableDictionary(dictionary: e.properties))
    return KERN_SUCCESS
}
public func IORegistryEntryGetName(_ entry: io_registry_entry_t, _ name: UnsafeMutablePointer<CChar>!) -> kern_return_t {
    guard let e = Registry.get(entry) as? Registry.Entry else { return KERN_INVALID_ARGUMENT }
    _ = e.name.withCString { strncpy(name, $0, 127) }
    return KERN_SUCCESS
}
public func IORegistryEntryGetRegistryEntryID(_ entry: io_registry_entry_t, _ entryID: UnsafeMutablePointer<UInt64>!) -> kern_return_t {
    guard Registry.get(entry) is Registry.Entry else { return KERN_INVALID_ARGUMENT }
    entryID?.pointee = UInt64(entry)
    return KERN_SUCCESS
}
public func IORegistryEntryGetParentEntry(_ entry: io_registry_entry_t, _ plane: UnsafePointer<CChar>!, _ parent: UnsafeMutablePointer<io_registry_entry_t>!) -> kern_return_t { KERN_NOT_FOUND }
public func IORegistryEntryGetChildIterator(_ entry: io_registry_entry_t, _ plane: UnsafePointer<CChar>!, _ iterator: UnsafeMutablePointer<io_iterator_t>!) -> kern_return_t {
    iterator?.pointee = Registry.add(Registry.Iterator([]))
    return KERN_SUCCESS
}
public func IORegistryEntryFromPath(_ mainPort: mach_port_t, _ path: UnsafePointer<CChar>!) -> io_registry_entry_t {
    String(cString: path).hasSuffix(":/") ? Registry.add(Registry.platformExpert) : 0
}
public func IORegistryGetRootEntry(_ mainPort: mach_port_t) -> io_registry_entry_t { Registry.add(Registry.platformExpert) }
public func IOServiceOpen(_ service: io_service_t, _ owningTask: mach_port_t, _ type: UInt32, _ connect: UnsafeMutablePointer<io_connect_t>!) -> kern_return_t { kIOReturnNotPermitted }
public func IOServiceClose(_ connect: io_connect_t) -> kern_return_t { kIOReturnSuccess }
public func IOConnectCallStructMethod(_ connection: mach_port_t, _ selector: UInt32, _ input: UnsafeRawPointer!, _ inputSize: Int,
                                      _ output: UnsafeMutableRawPointer!, _ outputSize: UnsafeMutablePointer<Int>!) -> kern_return_t { kIOReturnNotPermitted }

// MARK: HID

public final class IOHIDManager: @unchecked Sendable {}
public final class IOHIDDevice: @unchecked Sendable {}
public final class IOHIDElement: @unchecked Sendable {}
public final class IOHIDValue: @unchecked Sendable {}

public enum IOHIDReportType: UInt32, Sendable { case input = 0, output, feature, count }
public var kIOHIDReportTypeInput: IOHIDReportType { .input }
public var kIOHIDReportTypeOutput: IOHIDReportType { .output }
public var kIOHIDReportTypeFeature: IOHIDReportType { .feature }
public enum IOHIDRequestType: UInt32, Sendable { case postEvent = 0, listenEvent }
public var kIOHIDRequestTypePostEvent: IOHIDRequestType { .postEvent }
public var kIOHIDRequestTypeListenEvent: IOHIDRequestType { .listenEvent }
public enum IOHIDAccessType: UInt32, Sendable { case granted = 0, denied, unknown }
public var kIOHIDAccessTypeGranted: IOHIDAccessType { .granted }
public var kIOHIDAccessTypeDenied: IOHIDAccessType { .denied }
public var kIOHIDAccessTypeUnknown: IOHIDAccessType { .unknown }
public var kIOHIDOptionsTypeNone: Int { 0 }
public var kIOHIDOptionsTypeSeizeDevice: Int { 1 }
public let kIOHIDVendorIDKey = "VendorID"
public let kIOHIDProductIDKey = "ProductID"
public let kIOHIDProductKey = "Product"
public let kIOHIDManufacturerKey = "Manufacturer"
public let kIOHIDSerialNumberKey = "SerialNumber"
public let kIOHIDTransportKey = "Transport"
public let kIOHIDPrimaryUsagePageKey = "PrimaryUsagePage"
public let kIOHIDPrimaryUsageKey = "PrimaryUsage"
public let kIOHIDDeviceUsagePageKey = "DeviceUsagePage"
public let kIOHIDDeviceUsageKey = "DeviceUsage"
public let kIOHIDLocationIDKey = "LocationID"

public typealias IOHIDDeviceCallback = (UnsafeMutableRawPointer?, IOReturn, UnsafeMutableRawPointer?, IOHIDDevice) -> Void
public typealias IOHIDValueCallback = (UnsafeMutableRawPointer?, IOReturn, UnsafeMutableRawPointer?, IOHIDValue) -> Void

public func IOHIDCheckAccess(_ requestType: IOHIDRequestType) -> IOHIDAccessType { .denied }
public func IOHIDRequestAccess(_ requestType: IOHIDRequestType) -> Bool { false }
public func IOHIDManagerCreate(_ allocator: CFAllocator!, _ options: IOOptionBits) -> IOHIDManager { IOHIDManager() }
public func IOHIDManagerSetDeviceMatching(_ manager: IOHIDManager, _ matching: CFDictionary?) {}
public func IOHIDManagerSetDeviceMatchingMultiple(_ manager: IOHIDManager, _ multiple: CFArray?) {}
public func IOHIDManagerOpen(_ manager: IOHIDManager, _ options: IOOptionBits) -> IOReturn { kIOReturnNotPermitted }
public func IOHIDManagerClose(_ manager: IOHIDManager, _ options: IOOptionBits) -> IOReturn { kIOReturnSuccess }
public func IOHIDManagerCopyDevices(_ manager: IOHIDManager) -> CFSet? { nil }
public func IOHIDManagerScheduleWithRunLoop(_ manager: IOHIDManager, _ runLoop: CFRunLoop, _ runLoopMode: CFString) {}
public func IOHIDManagerUnscheduleFromRunLoop(_ manager: IOHIDManager, _ runLoop: CFRunLoop, _ runLoopMode: CFString) {}
public func IOHIDManagerSetDispatchQueue(_ manager: IOHIDManager, _ queue: DispatchQueue) {}
public func IOHIDManagerActivate(_ manager: IOHIDManager) {}
public func IOHIDManagerCancel(_ manager: IOHIDManager) {}
public func IOHIDManagerRegisterDeviceMatchingCallback(_ manager: IOHIDManager, _ callback: IOHIDDeviceCallback?, _ context: UnsafeMutableRawPointer?) {}
public func IOHIDManagerRegisterDeviceRemovalCallback(_ manager: IOHIDManager, _ callback: IOHIDDeviceCallback?, _ context: UnsafeMutableRawPointer?) {}
public func IOHIDManagerRegisterInputValueCallback(_ manager: IOHIDManager, _ callback: IOHIDValueCallback?, _ context: UnsafeMutableRawPointer?) {}
public func IOHIDDeviceGetProperty(_ device: IOHIDDevice, _ key: CFString) -> CFTypeRef? { nil }
public func IOHIDDeviceOpen(_ device: IOHIDDevice, _ options: IOOptionBits) -> IOReturn { kIOReturnNotPermitted }
public func IOHIDDeviceClose(_ device: IOHIDDevice, _ options: IOOptionBits) -> IOReturn { kIOReturnSuccess }
public func IOHIDDeviceSetReport(_ device: IOHIDDevice, _ reportType: IOHIDReportType, _ reportID: CFIndex, _ report: UnsafePointer<UInt8>, _ reportLength: CFIndex) -> IOReturn { kIOReturnNotPermitted }
public func IOHIDDeviceGetReport(_ device: IOHIDDevice, _ reportType: IOHIDReportType, _ reportID: CFIndex, _ report: UnsafeMutablePointer<UInt8>,
                                 _ pReportLength: UnsafeMutablePointer<CFIndex>) -> IOReturn { kIOReturnNotPermitted }


// MARK: Special keys (IOKit/hidsystem/ev_keymap.h)

public let NX_KEYTYPE_SOUND_UP: Int32 = 0
public let NX_KEYTYPE_SOUND_DOWN: Int32 = 1
public let NX_KEYTYPE_BRIGHTNESS_UP: Int32 = 2
public let NX_KEYTYPE_BRIGHTNESS_DOWN: Int32 = 3
public let NX_KEYTYPE_CAPS_LOCK: Int32 = 4
public let NX_KEYTYPE_HELP: Int32 = 5
public let NX_POWER_KEY: Int32 = 6
public let NX_KEYTYPE_MUTE: Int32 = 7
public let NX_UP_ARROW_KEY: Int32 = 8
public let NX_DOWN_ARROW_KEY: Int32 = 9
public let NX_KEYTYPE_NUM_LOCK: Int32 = 10
public let NX_KEYTYPE_CONTRAST_UP: Int32 = 11
public let NX_KEYTYPE_CONTRAST_DOWN: Int32 = 12
public let NX_KEYTYPE_LAUNCH_PANEL: Int32 = 13
public let NX_KEYTYPE_EJECT: Int32 = 14
public let NX_KEYTYPE_VIDMIRROR: Int32 = 15
public let NX_KEYTYPE_PLAY: Int32 = 16
public let NX_KEYTYPE_NEXT: Int32 = 17
public let NX_KEYTYPE_PREVIOUS: Int32 = 18
public let NX_KEYTYPE_FAST: Int32 = 19
public let NX_KEYTYPE_REWIND: Int32 = 20
public let NX_KEYTYPE_ILLUMINATION_UP: Int32 = 21
public let NX_KEYTYPE_ILLUMINATION_DOWN: Int32 = 22
public let NX_KEYTYPE_ILLUMINATION_TOGGLE: Int32 = 23
public let NX_SUBTYPE_AUX_CONTROL_BUTTONS: Int16 = 8
public let NX_KEYDOWN: Int32 = 10
public let NX_KEYUP: Int32 = 11
public let NX_SYSDEFINED: Int32 = 14


// MARK: Displays (IOKit/graphics)

public let kIODisplayMatchingInfo: UInt32 = 0x0000_0100
public let kIODisplayOnlyPreferredName: UInt32 = 0x0000_0200
public let kIODisplayNoProductName: UInt32 = 0x0000_0400
public let kDisplayVendorID = "DisplayVendorID"
public let kDisplayProductID = "DisplayProductID"
public let kDisplaySerialNumber = "DisplaySerialNumber"
public let kDisplaySerialString = "DisplaySerialString"
public let kDisplayProductName = "DisplayProductName"
public let kDisplayWeekOfManufacture = "DisplayWeekManufacture"
public let kDisplayYearOfManufacture = "DisplayYearManufacture"
public let kDisplayHorizontalImageSize = "DisplayHorizontalImageSize"
public let kDisplayVerticalImageSize = "DisplayVerticalImageSize"
public let kIODisplayEDIDKey = "IODisplayEDID"
public let kIODisplayLocationKey = "IODisplayLocation"
public let kIODisplayConnectFlagsKey = "IODisplayConnectFlags"
public let kIODisplayPrefsKey = "IODisplayPrefsKey"
public let kIODisplayBrightnessKey = "brightness"
public let kIODisplayContrastKey = "contrast"
public let kIODisplayParametersKey = "IODisplayParameters"
public let kIOFBDependentIDKey = "IOFBDependentID"
public let kIOFBDependentIndexKey = "IOFBDependentIndex"

/// A display service's description. Display services aren't in the
/// registry here (IOServiceMatching("IODisplayConnect") finds none), so
/// this answers an empty dictionary for any object.
public func IODisplayCreateInfoDictionary(_ framebuffer: io_service_t, _ options: IOOptionBits) -> Unmanaged<CFDictionary>! {
    Unmanaged.passRetained(NSDictionary())
}

@discardableResult
public func IODisplayGetFloatParameter(_ service: io_service_t, _ options: IOOptionBits, _ parameterName: CFString!, _ value: UnsafeMutablePointer<Float>!) -> kern_return_t { -536870212 }
@discardableResult
public func IODisplaySetFloatParameter(_ service: io_service_t, _ options: IOOptionBits, _ parameterName: CFString!, _ value: Float) -> kern_return_t { -536870212 }


// MARK: I²C (IOKit/i2c): DDC over a framebuffer's bus

public struct IOI2CRequest {
    public var sendTransactionType: IOOptionBits = 0
    public var replyTransactionType: IOOptionBits = 0
    public var sendAddress: UInt32 = 0
    public var replyAddress: UInt32 = 0
    public var sendSubAddress: UInt8 = 0
    public var replySubAddress: UInt8 = 0
    public var __reservedA: (UInt8, UInt8) = (0, 0)
    public var minReplyDelay: UInt64 = 0
    public var result: IOReturn = 0
    public var commFlags: IOOptionBits = 0
    public var __padA: UInt32 = 0
    public var sendBytes: UInt32 = 0
    public var __reservedB: (UInt32, UInt32) = (0, 0)
    public var __padB: UInt32 = 0
    public var replyBytes: UInt32 = 0
    public var completion: UnsafeMutableRawPointer?
    public var sendBuffer: vm_address_t = 0
    public var replyBuffer: vm_address_t = 0
    public init() {}
}
public typealias vm_address_t = UInt
public typealias vm_size_t = UInt
public typealias IOI2CConnectRef = OpaquePointer

public let kIOI2CNoTransactionType: Int = 0
public let kIOI2CSimpleTransactionType: Int = 1
public let kIOI2CDDCciReplyTransactionType: Int = 2
public let kIOI2CCombinedTransactionType: Int = 3
public let kIOI2CDisplayPortNativeTransactionType: Int = 4
public let kIOI2CUseSubAddressCommFlag: Int = 0x0000_0002
public let kIOI2CInterfaceIDKey = "IOI2CInterfaceID"
public let kIOI2CBusTypeKey = "IOI2CBusType"
public let kIOI2CTransactionTypesKey = "IOI2CTransactionTypes"
public let kIOI2CSupportedCommFlagsKey = "IOI2CSupportedCommFlags"

/// Framebuffers expose no I²C buses here (DDC goes through ddcutil or the
/// kernel's i2c-dev on Linux, which this doesn't reach): every call fails.
public func IOFBGetI2CInterfaceCount(_ framebuffer: io_service_t, _ count: UnsafeMutablePointer<IOItemCount>!) -> IOReturn {
    count?.pointee = 0
    return kIOReturnSuccess
}
public func IOFBCopyI2CInterfaceForBus(_ framebuffer: io_service_t, _ bus: IOOptionBits, _ interface: UnsafeMutablePointer<io_service_t>!) -> IOReturn { kIOReturnError }
public func IOI2CInterfaceOpen(_ interface: io_service_t, _ options: IOOptionBits, _ connect: UnsafeMutablePointer<IOI2CConnectRef?>!) -> IOReturn { kIOReturnError }
public func IOI2CInterfaceClose(_ connect: IOI2CConnectRef!, _ options: IOOptionBits) -> IOReturn { kIOReturnSuccess }
public func IOI2CSendRequest(_ connect: IOI2CConnectRef!, _ options: IOOptionBits, _ request: UnsafeMutablePointer<IOI2CRequest>!) -> IOReturn { kIOReturnError }
