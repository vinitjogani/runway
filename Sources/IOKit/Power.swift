// IOKit power: power sources (IOPS…) and power-management assertions.

import Foundation
import RunwayDBus
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public let kIOPSNameKey = "Name"
public let kIOPSTypeKey = "Type"
public let kIOPSTransportTypeKey = "Transport Type"
public let kIOPSPowerSourceStateKey = "Power Source State"
public let kIOPSCurrentCapacityKey = "Current Capacity"
public let kIOPSMaxCapacityKey = "Max Capacity"
public let kIOPSDesignCapacityKey = "DesignCapacity"
public let kIOPSIsPresentKey = "Is Present"
public let kIOPSIsChargingKey = "Is Charging"
public let kIOPSIsChargedKey = "Is Charged"
public let kIOPSIsFinishingChargeKey = "Is Finishing Charge"
public let kIOPSTimeToEmptyKey = "Time to Empty"
public let kIOPSTimeToFullChargeKey = "Time to Full Charge"
public let kIOPSVoltageKey = "Voltage"
public let kIOPSCurrentKey = "Current"
public let kIOPSPowerSourceIDKey = "Power Source ID"
public let kIOPSBatteryHealthKey = "BatteryHealth"
public let kIOPSHardwareSerialNumberKey = "Hardware Serial Number"
public let kIOPSInternalBatteryType = "InternalBattery"
public let kIOPSUPSType = "UPS"
public let kIOPSInternalType = "Internal"
public let kIOPSUSBTransportType = "USB"
public let kIOPSACPowerValue = "AC Power"
public let kIOPSBatteryPowerValue = "Battery Power"
public let kIOPSOffLineValue = "Off Line"
public let kIOPSGoodValue = "Good"
public let kIOPSFairValue = "Fair"
public let kIOPSPoorValue = "Poor"
public let kIOPSNotificationKey = "com.apple.system.powersources"
public let kIOPSTimeRemainingUnknown: CFTimeInterval = -1.0
public let kIOPSTimeRemainingUnlimited: CFTimeInterval = -2.0

public enum IOPSLowBatteryWarningLevel: UInt32, Sendable { case none = 1, early = 2, final = 3 }
public var kIOPSLowBatteryWarningNone: IOPSLowBatteryWarningLevel { .none }

enum PowerSources {
    struct Snapshot { var sources: [[String: AnyObject]]; var onAC: Bool }

    static func read(_ dir: String, _ name: String) -> String? {
        (try? String(contentsOfFile: dir + "/" + name, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func snapshot() -> Snapshot {
        #if os(Linux)
        let base = "/sys/class/power_supply"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base))?.sorted() ?? []
        var sources: [[String: AnyObject]] = []
        var mains = false, sawMains = false
        for n in names {
            let d = base + "/" + n
            let type = read(d, "type") ?? ""
            if type == "Mains" || type == "USB" { sawMains = true; if read(d, "online") == "1" { mains = true } }
            guard type == "Battery", read(d, "scope") != "Device" else { continue }
            let capacity = Int(read(d, "capacity") ?? "") ?? {
                let now = Double(read(d, "energy_now") ?? read(d, "charge_now") ?? "") ?? 0
                let full = Double(read(d, "energy_full") ?? read(d, "charge_full") ?? "") ?? 0
                return full > 0 ? Int((now / full * 100).rounded()) : 0
            }()
            let status = read(d, "status") ?? "Unknown"
            var s: [String: AnyObject] = [
                kIOPSNameKey: (read(d, "model_name") ?? n) as NSString,
                kIOPSTypeKey: kIOPSInternalBatteryType as NSString,
                kIOPSTransportTypeKey: kIOPSInternalType as NSString,
                kIOPSIsPresentKey: NSNumber(value: read(d, "present") != "0"),
                kIOPSCurrentCapacityKey: NSNumber(value: capacity),
                kIOPSMaxCapacityKey: NSNumber(value: 100),
                kIOPSIsChargingKey: NSNumber(value: status == "Charging"),
                kIOPSIsChargedKey: NSNumber(value: status == "Full" || capacity >= 100),
                kIOPSPowerSourceIDKey: NSNumber(value: sources.count + 1),
                kIOPSBatteryHealthKey: kIOPSGoodValue as NSString,
            ]
            // Minutes, from power draw (µW) and remaining energy (µWh).
            let power = Double(read(d, "power_now") ?? "") ?? 0
            let energy = Double(read(d, "energy_now") ?? "") ?? 0
            let full = Double(read(d, "energy_full") ?? "") ?? 0
            s[kIOPSTimeToEmptyKey] = NSNumber(value: status == "Discharging" && power > 0 ? Int(energy / power * 60) : -1)
            s[kIOPSTimeToFullChargeKey] = NSNumber(value: status == "Charging" && power > 0 ? Int((full - energy) / power * 60) : -1)
            if let v = Double(read(d, "voltage_now") ?? "") { s[kIOPSVoltageKey] = NSNumber(value: Int(v / 1000)) }
            if let serial = read(d, "serial_number"), !serial.isEmpty { s[kIOPSHardwareSerialNumberKey] = serial as NSString }
            sources.append(s)
        }
        let onAC = sawMains ? mains : !sources.contains { ($0[kIOPSIsChargingKey] as? NSNumber)?.boolValue == false && ($0[kIOPSIsChargedKey] as? NSNumber)?.boolValue == false }
        for i in sources.indices { sources[i][kIOPSPowerSourceStateKey] = (onAC ? kIOPSACPowerValue : kIOPSBatteryPowerValue) as NSString }
        return Snapshot(sources: sources, onAC: onAC)
        #elseif os(Windows)
        var st = SYSTEM_POWER_STATUS()
        guard GetSystemPowerStatus(&st) else { return Snapshot(sources: [], onAC: true) }
        let onAC = st.ACLineStatus == 1
        guard st.BatteryFlag != 128, st.BatteryLifePercent != 255 else { return Snapshot(sources: [], onAC: onAC) }
        let s: [String: AnyObject] = [
            kIOPSNameKey: "InternalBattery-0" as NSString, kIOPSTypeKey: kIOPSInternalBatteryType as NSString,
            kIOPSTransportTypeKey: kIOPSInternalType as NSString, kIOPSIsPresentKey: NSNumber(value: true),
            kIOPSCurrentCapacityKey: NSNumber(value: Int(st.BatteryLifePercent)), kIOPSMaxCapacityKey: NSNumber(value: 100),
            kIOPSIsChargingKey: NSNumber(value: st.BatteryFlag & 8 != 0), kIOPSIsChargedKey: NSNumber(value: st.BatteryLifePercent >= 100),
            kIOPSPowerSourceStateKey: (onAC ? kIOPSACPowerValue : kIOPSBatteryPowerValue) as NSString,
            kIOPSTimeToEmptyKey: NSNumber(value: st.BatteryLifeTime == 0xFFFFFFFF ? -1 : Int(st.BatteryLifeTime / 60)),
        ]
        return Snapshot(sources: [s], onAC: onAC)
        #else
        return Snapshot(sources: [], onAC: true)
        #endif
    }
}

final class PowerSourcesBlob: @unchecked Sendable { let snapshot: PowerSources.Snapshot; init(_ s: PowerSources.Snapshot) { snapshot = s } }

public func IOPSCopyPowerSourcesInfo() -> Unmanaged<CFTypeRef>! { .passRetained(PowerSourcesBlob(PowerSources.snapshot())) }

public func IOPSCopyPowerSourcesList(_ blob: CFTypeRef!) -> Unmanaged<CFArray>! {
    guard let b = blob as? PowerSourcesBlob else { return .passRetained(NSArray()) }
    return .passRetained((0..<b.snapshot.sources.count).map { NSNumber(value: $0) } as NSArray)
}

public func IOPSGetPowerSourceDescription(_ blob: CFTypeRef!, _ ps: CFTypeRef!) -> Unmanaged<CFDictionary>! {
    guard let b = blob as? PowerSourcesBlob, let i = (ps as? NSNumber)?.intValue, i < b.snapshot.sources.count else { return nil }
    return .passUnretained(b.snapshot.sources[i] as NSDictionary)
}

public func IOPSGetProvidingPowerSourceType(_ snapshot: CFTypeRef!) -> Unmanaged<CFString>! {
    let onAC = (snapshot as? PowerSourcesBlob)?.snapshot.onAC ?? PowerSources.snapshot().onAC
    return .passRetained((onAC ? kIOPSACPowerValue : kIOPSBatteryPowerValue) as NSString)
}

public func IOPSCopyExternalPowerAdapterDetails() -> Unmanaged<CFDictionary>! {
    PowerSources.snapshot().onAC ? .passRetained([kIOPSNameKey: "AC Power"] as NSDictionary) : nil
}

public func IOPSGetTimeRemainingEstimate() -> CFTimeInterval {
    let s = PowerSources.snapshot()
    if s.onAC { return kIOPSTimeRemainingUnlimited }
    guard let m = (s.sources.first?[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue, m >= 0 else { return kIOPSTimeRemainingUnknown }
    return CFTimeInterval(m * 60)
}

public func IOPSGetBatteryWarningLevel() -> IOPSLowBatteryWarningLevel {
    let s = PowerSources.snapshot()
    guard !s.onAC, let c = (s.sources.first?[kIOPSCurrentCapacityKey] as? NSNumber)?.intValue else { return .none }
    return c <= 5 ? .final : (c <= 10 ? .early : .none)
}

public typealias IOPowerSourceCallbackType = @convention(c) (UnsafeMutableRawPointer?) -> Void

/// A run loop source that fires on power changes (UPower's
/// PropertiesChanged on the system bus).
public func IOPSNotificationCreateRunLoopSource(_ callback: IOPowerSourceCallbackType!, _ context: UnsafeMutableRawPointer!) -> Unmanaged<CFRunLoopSource>! {
    let source = CFRunLoopSource()
    #if os(Linux)
    if let bus = DBusConnection.system, let callback {
        nonisolated(unsafe) let ctx = context
        let id = bus.subscribe(sender: "org.freedesktop.UPower", interface: "org.freedesktop.DBus.Properties", member: "PropertiesChanged") { [weak source] _ in
            source?.signal { callback(ctx) }
        }
        source.onInvalidate = { bus.unsubscribe(id) }
    }
    #endif
    return .passRetained(source)
}

public func IOPSCreateLimitedPowerNotification(_ callback: IOPowerSourceCallbackType!, _ context: UnsafeMutableRawPointer!) -> Unmanaged<CFRunLoopSource>! {
    IOPSNotificationCreateRunLoopSource(callback, context)
}

// MARK: Assertions

public let kIOPMAssertionTypeNoIdleSleep = "NoIdleSleepAssertion"
public let kIOPMAssertionTypeNoDisplaySleep = "NoDisplaySleepAssertion"
public let kIOPMAssertionTypePreventUserIdleSystemSleep = "PreventUserIdleSystemSleep"
public let kIOPMAssertionTypePreventUserIdleDisplaySleep = "PreventUserIdleDisplaySleep"
public let kIOPMAssertionTypePreventSystemSleep = "PreventSystemSleep"
public let kIOPMAssertionTypeUserIsActive = "UserIsActive"
public let kIOPMAssertPreventUserIdleSystemSleep = "PreventUserIdleSystemSleep"
public let kIOPMAssertPreventUserIdleDisplaySleep = "PreventUserIdleDisplaySleep"
public var kIOPMAssertionLevelOff: Int { 0 }
public var kIOPMAssertionLevelOn: Int { 255 }
public let kIOPMNullAssertionID: IOPMAssertionID = 0

public enum IOPMUserActiveType: UInt32, Sendable { case local = 0, remote = 1 }
public var kIOPMUserActiveLocal: IOPMUserActiveType { .local }

enum Assertions {
    final class Held {
        #if os(Linux)
        var fd: Int32 = -1
        var cookie: UInt32?
        #elseif os(Windows)
        var request: HANDLE?
        #endif
    }
    static let lock = NSLock()
    nonisolated(unsafe) static var held: [IOPMAssertionID: Held] = [:]
    nonisolated(unsafe) static var next: IOPMAssertionID = 0

    static func create(type: String, name: String, details: String?) -> IOPMAssertionID? {
        let display = type == kIOPMAssertionTypeNoDisplaySleep || type == kIOPMAssertionTypePreventUserIdleDisplaySleep
        let h = Held()
        let app = ProcessInfo.processInfo.processName
        let why = details.map { "\(name): \($0)" } ?? name
        var any = false
        #if os(Linux)
        if let sys = DBusConnection.system {
            let what = type == kIOPMAssertionTypePreventSystemSleep ? "sleep:idle" : "idle"
            if let (_, fds) = try? sys.callReturningFDs("org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
                                                       "Inhibit", [.string(what), .string(app), .string(why), .string("block")]), let fd = fds.first {
                h.fd = fd
                any = true
            }
        }
        if display, let session = DBusConnection.session,
           let r = try? session.call("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver",
                                     "Inhibit", [.string(app), .string(why)]), let c = r.first?.int {
            h.cookie = UInt32(c)
            any = true
        }
        #elseif os(Windows)
        var ctx = REASON_CONTEXT()
        ctx.Version = ULONG(POWER_REQUEST_CONTEXT_VERSION)
        ctx.Flags = DWORD(POWER_REQUEST_CONTEXT_SIMPLE_STRING)
        let wide = Array(why.utf16) + [0]
        let req: HANDLE? = wide.withUnsafeBufferPointer { buf in
            ctx.Reason.SimpleReasonString = UnsafeMutablePointer(mutating: buf.baseAddress)
            return PowerCreateRequest(&ctx)
        }
        if let req, req != INVALID_HANDLE_VALUE {
            _ = PowerSetRequest(req, PowerRequestSystemRequired)
            if display { _ = PowerSetRequest(req, PowerRequestDisplayRequired) }
            h.request = req
            any = true
        }
        #endif
        guard any else { return nil }
        lock.lock(); defer { lock.unlock() }
        next += 1
        held[next] = h
        return next
    }

    static func release(_ id: IOPMAssertionID) -> Bool {
        lock.lock()
        let h = held.removeValue(forKey: id)
        lock.unlock()
        guard let h else { return false }
        #if os(Linux)
        if h.fd >= 0 { close(h.fd) }
        if let c = h.cookie {
            _ = try? DBusConnection.session?.call("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver", "UnInhibit", [.uint32(c)])
        }
        #elseif os(Windows)
        if let r = h.request { CloseHandle(r) }
        #endif
        return true
    }
}

public func IOPMAssertionCreateWithName(_ assertionType: CFString!, _ assertionLevel: IOPMAssertionLevel, _ assertionName: CFString!,
                                        _ assertionID: UnsafeMutablePointer<IOPMAssertionID>!) -> IOReturn {
    guard assertionLevel != 0 else { assertionID?.pointee = 0; return kIOReturnSuccess }
    guard let id = Assertions.create(type: assertionType as String, name: assertionName as String, details: nil) else { return kIOReturnUnsupported }
    assertionID?.pointee = id
    return kIOReturnSuccess
}

public func IOPMAssertionCreateWithDescription(_ assertionType: CFString!, _ name: CFString!, _ details: CFString!, _ humanReadableReason: CFString!,
                                               _ localizationBundlePath: CFString!, _ timeout: CFTimeInterval, _ timeoutAction: CFString!,
                                               _ assertionID: UnsafeMutablePointer<IOPMAssertionID>!) -> IOReturn {
    guard let id = Assertions.create(type: assertionType as String, name: name as String, details: details.map { $0 as String }) else { return kIOReturnUnsupported }
    assertionID?.pointee = id
    if timeout > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { _ = Assertions.release(id) } }
    return kIOReturnSuccess
}

public func IOPMAssertionCreate(_ assertionType: CFString!, _ assertionLevel: IOPMAssertionLevel,
                                _ assertionID: UnsafeMutablePointer<IOPMAssertionID>!) -> IOReturn {
    IOPMAssertionCreateWithName(assertionType, assertionLevel, "Runway" as NSString, assertionID)
}

public func IOPMAssertionRelease(_ assertionID: IOPMAssertionID) -> IOReturn {
    Assertions.release(assertionID) ? kIOReturnSuccess : kIOReturnNotFound
}

public func IOPMAssertionDeclareUserActivity(_ assertionName: CFString!, _ userType: IOPMUserActiveType,
                                             _ assertionID: UnsafeMutablePointer<IOPMAssertionID>!) -> IOReturn {
    #if os(Linux)
    _ = try? DBusConnection.session?.call("org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver", "SimulateUserActivity")
    #endif
    assertionID?.pointee = 0
    return kIOReturnSuccess
}
