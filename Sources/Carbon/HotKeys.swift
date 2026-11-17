// Carbon Event Manager's global hot keys: RegisterEventHotKey and
// InstallEventHandler, as the HotKey / KeyboardShortcuts / MASShortcut /
// Magnet libraries use them. On Linux the key is grabbed on the X root
// window (XGrabKey, on a private Display connection whose thread sleeps in
// poll(2)); presses and releases reach the installed handlers on the main
// queue as kEventHotKeyPressed / kEventHotKeyReleased events carrying the
// EventHotKeyID. Without an X server (a pure Wayland session),
// RegisterEventHotKey returns eventHotKeyInvalidErr, the error apps already
// report for a shortcut that can't be registered. On Windows the key is a
// RegisterHotKey on a message-loop thread.

@_exported import CoreServices
@_exported import ApplicationServices
import Foundation
#if os(Linux)
import Glibc
import RunwayX11
#elseif os(Windows)
import WinSDK
#endif

public typealias OSType = UInt32
public typealias FourCharCode = UInt32
public typealias EventTargetRef = OpaquePointer
public typealias EventHandlerRef = OpaquePointer
public typealias EventHandlerCallRef = OpaquePointer
public typealias EventRef = OpaquePointer
public typealias EventHotKeyRef = OpaquePointer
public typealias EventParamName = OSType
public typealias EventParamType = OSType
public typealias EventHandlerUPP = @convention(c) (EventHandlerCallRef?, EventRef?, UnsafeMutableRawPointer?) -> OSStatus
public typealias EventHandlerProcPtr = EventHandlerUPP

public struct EventHotKeyID: Sendable, Equatable {
    public var signature: OSType
    public var id: UInt32
    public init() { signature = 0; id = 0 }
    public init(signature: OSType, id: UInt32) { self.signature = signature; self.id = id }
}

public struct EventTypeSpec: Sendable {
    public var eventClass: OSType
    public var eventKind: UInt32
    public init() { eventClass = 0; eventKind = 0 }
    public init(eventClass: OSType, eventKind: UInt32) { self.eventClass = eventClass; self.eventKind = eventKind }
}

private func fourCC(_ s: String) -> Int { s.utf8.reduce(0) { $0 << 8 | Int($1) } }

public var kEventClassKeyboard: Int { fourCC("keyb") }
public var kEventClassApplication: Int { fourCC("appl") }
public var kEventClassMouse: Int { fourCC("mous") }
public var kEventClassCommand: Int { fourCC("cmds") }
public var kEventHotKeyPressed: Int { 5 }
public var kEventHotKeyReleased: Int { 6 }
public var kEventRawKeyDown: Int { 1 }
public var kEventRawKeyRepeat: Int { 2 }
public var kEventRawKeyUp: Int { 3 }
public var kEventRawKeyModifiersChanged: Int { 4 }
public var kEventAppActivated: Int { 1 }
public var kEventAppDeactivated: Int { 2 }
public var kEventAppQuit: Int { 3 }
public var kEventAppLaunched: Int { 5 }
public var kEventAppTerminated: Int { 6 }
public var kEventAppFrontSwitched: Int { 7 }
public var kEventParamDirectObject: Int { fourCC("----") }
public var kEventParamKeyCode: Int { fourCC("kcod") }
public var kEventParamKeyModifiers: Int { fourCC("kmod") }
public var typeEventHotKeyID: Int { fourCC("hkid") }
// Apple Event descriptor types are `DescType` (UInt32) in Swift.
public var typeUInt32: OSType { OSType(fourCC("magn")) }
public var typeSInt32: OSType { OSType(fourCC("long")) }
public var typeUnicodeText: OSType { OSType(fourCC("utxt")) }
public var kEventHotKeyNoOptions: Int { 0 }
public var kEventHotKeyExclusive: Int { 1 }

public let eventNotHandledErr: OSStatus = -9874
public let eventHotKeyExistsErr: OSStatus = -9878
public let eventHotKeyInvalidErr: OSStatus = -9879
public let eventInternalErr: OSStatus = -9868
public let eventParameterNotFoundErr: OSStatus = -9870

// MARK: Events and targets

final class CarbonEvent {
    let eventClass: OSType
    let kind: UInt32
    let hotKeyID: EventHotKeyID
    init(eventClass: OSType, kind: UInt32, hotKeyID: EventHotKeyID) { self.eventClass = eventClass; self.kind = kind; self.hotKeyID = hotKeyID }
    var ref: EventRef { OpaquePointer(Unmanaged.passUnretained(self).toOpaque()) }
    static func from(_ r: EventRef) -> CarbonEvent { Unmanaged<CarbonEvent>.fromOpaque(UnsafeRawPointer(r)).takeUnretainedValue() }
}

final class EventTarget { let name: String; init(_ n: String) { name = n } }
private let applicationTarget = EventTarget("application")
private let dispatcherTarget = EventTarget("dispatcher")

public func GetApplicationEventTarget() -> EventTargetRef! { OpaquePointer(Unmanaged.passUnretained(applicationTarget).toOpaque()) }
public func GetEventDispatcherTarget() -> EventTargetRef! { OpaquePointer(Unmanaged.passUnretained(dispatcherTarget).toOpaque()) }
public func GetEventMonitorTarget() -> EventTargetRef! { GetEventDispatcherTarget() }

final class InstalledHandler {
    let handler: EventHandlerUPP
    var types: [EventTypeSpec]
    let userData: UnsafeMutableRawPointer?
    init(_ h: EventHandlerUPP, _ t: [EventTypeSpec], _ u: UnsafeMutableRawPointer?) { handler = h; types = t; userData = u }
}

enum Registry {
    static let lock = NSLock()
    nonisolated(unsafe) static var handlers: [InstalledHandler] = []
    nonisolated(unsafe) static var hotKeys: [HotKey] = []

    /// Calls each handler for the event's class and kind (most recently
    /// installed first, until one handles it), on the main queue.
    static func dispatch(_ event: CarbonEvent) {
        DispatchQueue.main.async {
            lock.lock()
            let hs = handlers.reversed().filter { h in h.types.contains { $0.eventClass == event.eventClass && $0.eventKind == event.kind } }
            lock.unlock()
            withExtendedLifetime(event) {
                for h in hs where h.handler(nil, event.ref, h.userData) != eventNotHandledErr { break }
            }
        }
    }
}

public func InstallEventHandler(_ inTarget: EventTargetRef!, _ inHandler: EventHandlerUPP!, _ inNumTypes: Int,
                                _ inList: UnsafePointer<EventTypeSpec>!, _ inUserData: UnsafeMutableRawPointer!,
                                _ outRef: UnsafeMutablePointer<EventHandlerRef?>!) -> OSStatus {
    guard let inHandler else { return paramErr }
    let types = inList.map { Array(UnsafeBufferPointer(start: $0, count: inNumTypes)) } ?? []
    let h = InstalledHandler(inHandler, types, inUserData)
    Registry.lock.lock(); Registry.handlers.append(h); Registry.lock.unlock()
    outRef?.pointee = OpaquePointer(Unmanaged.passRetained(h).toOpaque())
    return noErr
}

public func InstallApplicationEventHandler(_ handler: EventHandlerUPP!, _ numTypes: Int, _ list: UnsafePointer<EventTypeSpec>!,
                                           _ userData: UnsafeMutableRawPointer!, _ outHandlerRef: UnsafeMutablePointer<EventHandlerRef?>!) -> OSStatus {
    InstallEventHandler(GetApplicationEventTarget(), handler, numTypes, list, userData, outHandlerRef)
}

public func RemoveEventHandler(_ inHandlerRef: EventHandlerRef!) -> OSStatus {
    guard let inHandlerRef else { return paramErr }
    let h = Unmanaged<InstalledHandler>.fromOpaque(UnsafeRawPointer(inHandlerRef))
    let obj = h.takeUnretainedValue()
    Registry.lock.lock(); Registry.handlers.removeAll { $0 === obj }; Registry.lock.unlock()
    h.release()
    return noErr
}

/// Adds event types an installed handler receives.
@discardableResult
public func AddEventTypesToHandler(_ inHandlerRef: EventHandlerRef!, _ inNumTypes: Int, _ inList: UnsafePointer<EventTypeSpec>!) -> OSStatus {
    guard let inHandlerRef, let inList else { return paramErr }
    let h = Unmanaged<InstalledHandler>.fromOpaque(UnsafeRawPointer(inHandlerRef)).takeUnretainedValue()
    let add = Array(UnsafeBufferPointer(start: inList, count: inNumTypes))
    Registry.lock.lock()
    for t in add where !h.types.contains(where: { $0.eventClass == t.eventClass && $0.eventKind == t.eventKind }) { h.types.append(t) }
    Registry.lock.unlock()
    return noErr
}

@discardableResult
public func RemoveEventTypesFromHandler(_ inHandlerRef: EventHandlerRef!, _ inNumTypes: Int, _ inList: UnsafePointer<EventTypeSpec>!) -> OSStatus {
    guard let inHandlerRef, let inList else { return paramErr }
    let h = Unmanaged<InstalledHandler>.fromOpaque(UnsafeRawPointer(inHandlerRef)).takeUnretainedValue()
    let remove = Array(UnsafeBufferPointer(start: inList, count: inNumTypes))
    Registry.lock.lock()
    h.types.removeAll { t in remove.contains { $0.eventClass == t.eventClass && $0.eventKind == t.eventKind } }
    Registry.lock.unlock()
    return noErr
}

public func CallNextEventHandler(_ inCallRef: EventHandlerCallRef!, _ inEvent: EventRef!) -> OSStatus { eventNotHandledErr }
public func GetEventClass(_ inEvent: EventRef!) -> OSType { inEvent.map { CarbonEvent.from($0).eventClass } ?? 0 }
public func GetEventKind(_ inEvent: EventRef!) -> UInt32 { inEvent.map { CarbonEvent.from($0).kind } ?? 0 }

public func GetEventParameter(_ inEvent: EventRef!, _ inName: EventParamName, _ inDesiredType: EventParamType,
                              _ outActualType: UnsafeMutablePointer<EventParamType>!, _ inBufferSize: Int,
                              _ outActualSize: UnsafeMutablePointer<Int>!, _ outData: UnsafeMutableRawPointer!) -> OSStatus {
    guard let inEvent else { return paramErr }
    let e = CarbonEvent.from(inEvent)
    // The key code and modifiers of the hot key an event is for.
    if inName == OSType(kEventParamKeyCode) || inName == OSType(kEventParamKeyModifiers), inDesiredType == typeUInt32 {
        Registry.lock.lock()
        let key = Registry.hotKeys.first { $0.id == e.hotKeyID }
        Registry.lock.unlock()
        guard let key, let outData, inBufferSize >= MemoryLayout<UInt32>.size else { return eventParameterNotFoundErr }
        outData.assumingMemoryBound(to: UInt32.self).pointee = inName == OSType(kEventParamKeyCode) ? key.code : key.modifiers
        outActualType?.pointee = typeUInt32
        outActualSize?.pointee = MemoryLayout<UInt32>.size
        return noErr
    }
    guard inName == OSType(kEventParamDirectObject), inDesiredType == OSType(typeEventHotKeyID) else { return eventParameterNotFoundErr }
    let size = MemoryLayout<EventHotKeyID>.size
    outActualType?.pointee = OSType(typeEventHotKeyID)
    outActualSize?.pointee = size
    if let outData, inBufferSize >= size { outData.assumingMemoryBound(to: EventHotKeyID.self).pointee = e.hotKeyID }
    return noErr
}

// MARK: Hot keys

final class HotKey {
    let code: UInt32
    let modifiers: UInt32
    let id: EventHotKeyID
    init(code: UInt32, modifiers: UInt32, id: EventHotKeyID) { self.code = code; self.modifiers = modifiers; self.id = id }
}

public func RegisterEventHotKey(_ inHotKeyCode: UInt32, _ inHotKeyModifiers: UInt32, _ inHotKeyID: EventHotKeyID,
                                _ inTarget: EventTargetRef!, _ inOptions: OptionBits,
                                _ outRef: UnsafeMutablePointer<EventHotKeyRef?>!) -> OSStatus {
    Registry.lock.lock()
    if Registry.hotKeys.contains(where: { $0.code == inHotKeyCode && $0.modifiers == inHotKeyModifiers }) {
        Registry.lock.unlock()
        return eventHotKeyExistsErr
    }
    Registry.lock.unlock()
    let key = HotKey(code: inHotKeyCode, modifiers: inHotKeyModifiers, id: inHotKeyID)
    if !_runwayHotKeysWithoutGrab {
        guard let grabber = HotKeyGrabber.shared, grabber.grab(key) else { return eventHotKeyInvalidErr }
    }
    Registry.lock.lock(); Registry.hotKeys.append(key); Registry.lock.unlock()
    outRef?.pointee = OpaquePointer(Unmanaged.passRetained(key).toOpaque())
    return noErr
}

public func UnregisterEventHotKey(_ inHotKey: EventHotKeyRef!) -> OSStatus {
    guard let inHotKey else { return paramErr }
    let u = Unmanaged<HotKey>.fromOpaque(UnsafeRawPointer(inHotKey))
    let key = u.takeUnretainedValue()
    Registry.lock.lock(); Registry.hotKeys.removeAll { $0 === key }; Registry.lock.unlock()
    HotKeyGrabber.shared?.ungrab(key)
    u.release()
    return noErr
}

/// Test hook: register hot keys without grabbing them from the system.
nonisolated(unsafe) public var _runwayHotKeysWithoutGrab = false

/// Test hook: deliver a hot key as if the system had (pressed: true / false).
public func _runwaySimulateHotKey(keyCode: UInt32, modifiers: UInt32, pressed: Bool = true) {
    Registry.lock.lock()
    let key = Registry.hotKeys.first { $0.code == keyCode && $0.modifiers == modifiers }
    Registry.lock.unlock()
    guard let key else { return }
    Registry.dispatch(CarbonEvent(eventClass: OSType(kEventClassKeyboard), kind: UInt32(pressed ? kEventHotKeyPressed : kEventHotKeyReleased), hotKeyID: key.id))
}

/// Symbolic (system) hot keys: none are reported.
public func CopySymbolicHotKeys(_ outHotKeyArray: UnsafeMutablePointer<Unmanaged<CFArray>?>!) -> OSStatus {
    outHotKeyArray?.pointee = Unmanaged.passRetained(NSArray())
    return noErr
}
public let kHISymbolicHotKeyCode = "kHISymbolicHotKeyCode"
public let kHISymbolicHotKeyModifiers = "kHISymbolicHotKeyModifiers"
public let kHISymbolicHotKeyEnabled = "kHISymbolicHotKeyEnabled"

public func PushSymbolicHotKeyMode(_ inOptions: OptionBits) -> UnsafeMutableRawPointer! { UnsafeMutableRawPointer(bitPattern: 1) }
public func PopSymbolicHotKeyMode(_ inToken: UnsafeMutableRawPointer!) {}

// MARK: Grabbing

final class HotKeyGrabber: @unchecked Sendable {
    #if os(Linux)
    static let shared: HotKeyGrabber? = X11.shared.flatMap { HotKeyGrabber($0) }

    let x: X11
    let dpy: X11.Display
    let root: X11.Window
    var wake: [Int32] = [-1, -1]
    let lock = NSLock()
    var ops: [() -> Void] = []
    var grabbed: [(keycode: UInt8, mods: UInt32, key: HotKey)] = []

    init?(_ x: X11) {
        guard let d = x.XOpenDisplay(nil) else { return nil }
        self.x = x
        dpy = d
        root = x.XDefaultRootWindow(d)
        guard pipe(&wake) == 0 else { return nil }
        let t = Thread { [self] in run() }
        t.name = "runway.hotkeys"
        t.start()
    }

    static func xMods(_ carbon: UInt32) -> UInt32 {
        var m: UInt32 = 0
        if carbon & UInt32(shiftKey) != 0 { m |= 1 }        // ShiftMask
        if carbon & UInt32(controlKey) != 0 { m |= 4 }      // ControlMask
        if carbon & UInt32(optionKey) != 0 { m |= 8 }       // Mod1Mask (Alt)
        if carbon & UInt32(cmdKey) != 0 { m |= 64 }         // Mod4Mask (Super)
        return m
    }
    /// CapsLock (Lock) and NumLock (Mod2) mustn't stop a match.
    static let ignored: [UInt32] = [0, 2, 16, 18]

    private func perform(_ op: @escaping () -> Void) {
        lock.lock(); ops.append(op); lock.unlock()
        var b: UInt8 = 1
        _ = write(wake[1], &b, 1)
    }

    func grab(_ key: HotKey) -> Bool {
        guard let sym = Layout.keysym(Int(key.code)) else { return false }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        perform { [self] in
            let code = x.XKeysymToKeycode(dpy, sym)
            if code != 0 {
                let mods = HotKeyGrabber.xMods(key.modifiers)
                for extra in HotKeyGrabber.ignored { _ = x.XGrabKey(dpy, Int32(code), mods | extra, root, 0, 1, 1) }
                _ = x.XSync(dpy, 0)
                grabbed.append((code, mods, key))
                ok = true
            }
            done.signal()
        }
        done.wait()
        return ok
    }

    func ungrab(_ key: HotKey) {
        perform { [self] in
            for g in grabbed where g.key === key {
                for extra in HotKeyGrabber.ignored { _ = x.XUngrabKey(dpy, Int32(g.keycode), g.mods | extra, root) }
            }
            grabbed.removeAll { $0.key === key }
            _ = x.XFlush(dpy)
        }
    }

    private func run() {
        let event = UnsafeMutableRawPointer.allocate(byteCount: 192, alignment: 8)
        defer { event.deallocate() }
        let xfd = x.XConnectionNumber(dpy)
        while true {
            lock.lock(); let pending = ops; ops.removeAll(); lock.unlock()
            pending.forEach { $0() }
            while x.XPending(dpy) > 0 {
                _ = x.XNextEvent(dpy, event)
                let type = event.load(as: Int32.self)
                guard type == 2 || type == 3 else { continue }   // KeyPress, KeyRelease
                let state = event.load(fromByteOffset: 80, as: UInt32.self) & ~UInt32(2 | 16)
                let keycode = event.load(fromByteOffset: 84, as: UInt32.self)
                for g in grabbed where UInt32(g.keycode) == keycode && g.mods == state & 0x4D {
                    Registry.dispatch(CarbonEvent(eventClass: OSType(kEventClassKeyboard),
                                                  kind: UInt32(type == 2 ? kEventHotKeyPressed : kEventHotKeyReleased), hotKeyID: g.key.id))
                }
            }
            var fds = [pollfd(fd: xfd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 2, -1) < 0, errno != EINTR { return }
            if fds[1].revents != 0 { var b = [UInt8](repeating: 0, count: 64); _ = read(wake[0], &b, 64) }
        }
    }

    #elseif os(Windows)
    static let shared: HotKeyGrabber? = HotKeyGrabber()
    var threadId: DWORD = 0
    let lock = NSLock()
    var ops: [() -> Void] = []
    var ids: [Int32: HotKey] = [:]
    var nextId: Int32 = 1

    init?() {
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [self] in
            var msg = MSG()
            PeekMessageW(&msg, nil, 0, 0, UINT(PM_NOREMOVE))   // creates the queue
            threadId = GetCurrentThreadId()
            ready.signal()
            while GetMessageW(&msg, nil, 0, 0) {
                if msg.message == UINT(WM_APP) {
                    lock.lock(); let p = ops; ops.removeAll(); lock.unlock()
                    p.forEach { $0() }
                } else if msg.message == UINT(WM_HOTKEY) {
                    lock.lock(); let k = ids[Int32(msg.wParam)]; lock.unlock()
                    if let k { Registry.dispatch(CarbonEvent(eventClass: OSType(kEventClassKeyboard), kind: UInt32(kEventHotKeyPressed), hotKeyID: k.id)) }
                }
            }
        }
        t.start()
        ready.wait()
    }

    private func perform(_ op: @escaping () -> Void) {
        lock.lock(); ops.append(op); lock.unlock()
        PostThreadMessageW(threadId, UINT(WM_APP), 0, 0)
    }

    func grab(_ key: HotKey) -> Bool {
        guard let vk = Layout.windowsVK(Int(key.code)) else { return false }
        var mods: UINT = UINT(MOD_NOREPEAT)
        if key.modifiers & UInt32(shiftKey) != 0 { mods |= UINT(MOD_SHIFT) }
        if key.modifiers & UInt32(controlKey) != 0 { mods |= UINT(MOD_CONTROL) }
        if key.modifiers & UInt32(optionKey) != 0 { mods |= UINT(MOD_ALT) }
        if key.modifiers & UInt32(cmdKey) != 0 { mods |= UINT(MOD_WIN) }
        let done = DispatchSemaphore(value: 0)
        var ok = false
        perform { [self] in
            let id = nextId; nextId += 1
            ok = RegisterHotKey(nil, id, mods, UINT(vk))
            if ok { lock.lock(); ids[id] = key; lock.unlock() }
            done.signal()
        }
        done.wait()
        return ok
    }

    func ungrab(_ key: HotKey) {
        perform { [self] in
            lock.lock(); let mine = ids.filter { $0.value === key }.map(\.key); mine.forEach { ids[$0] = nil }; lock.unlock()
            mine.forEach { _ = UnregisterHotKey(nil, $0) }
        }
    }
    #else
    static let shared: HotKeyGrabber? = nil
    func grab(_ key: HotKey) -> Bool { false }
    func ungrab(_ key: HotKey) {}
    #endif
}
