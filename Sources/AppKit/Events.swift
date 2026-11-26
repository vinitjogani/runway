// NSEvent, NSTrackingArea, NSCursor and the drag-and-drop types, and the
// mapping from the backend's raw input to AppKit events (Mac key codes and
// function-key characters included, so `event.keyCode == 53` still means
// Escape).

import Foundation
import RunwayCore

// MARK: NSEvent

/// Events aren't tied to the main actor (AppKit's NSEvent isn't): they're
/// made on the main thread and can be read anywhere.
open class NSEvent: NSObject, @unchecked Sendable {
    public enum EventType: UInt, Sendable {
        case leftMouseDown = 1, leftMouseUp = 2, rightMouseDown = 3, rightMouseUp = 4, mouseMoved = 5, leftMouseDragged = 6
        case rightMouseDragged = 7, mouseEntered = 8, mouseExited = 9, keyDown = 10, keyUp = 11, flagsChanged = 12
        case appKitDefined = 13, systemDefined = 14, applicationDefined = 15, periodic = 16, cursorUpdate = 17
        case scrollWheel = 22, tabletPoint = 23, tabletProximity = 24, otherMouseDown = 25, otherMouseUp = 26, otherMouseDragged = 27
        case gesture = 29, magnify = 30, swipe = 31, rotate = 18, beginGesture = 19, endGesture = 20, smartMagnify = 32
        case quickLook = 33, pressure = 34, directTouch = 37, changeMode = 38
    }

    public struct EventTypeMask: OptionSet, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public init(type: EventType) { rawValue = 1 << type.rawValue }
        public static let leftMouseDown = EventTypeMask(type: .leftMouseDown), leftMouseUp = EventTypeMask(type: .leftMouseUp)
        public static let rightMouseDown = EventTypeMask(type: .rightMouseDown), rightMouseUp = EventTypeMask(type: .rightMouseUp)
        public static let mouseMoved = EventTypeMask(type: .mouseMoved), leftMouseDragged = EventTypeMask(type: .leftMouseDragged)
        public static let rightMouseDragged = EventTypeMask(type: .rightMouseDragged)
        public static let mouseEntered = EventTypeMask(type: .mouseEntered), mouseExited = EventTypeMask(type: .mouseExited)
        public static let keyDown = EventTypeMask(type: .keyDown), keyUp = EventTypeMask(type: .keyUp), flagsChanged = EventTypeMask(type: .flagsChanged)
        public static let cursorUpdate = EventTypeMask(type: .cursorUpdate), scrollWheel = EventTypeMask(type: .scrollWheel)
        public static let otherMouseDown = EventTypeMask(type: .otherMouseDown), otherMouseUp = EventTypeMask(type: .otherMouseUp)
        public static let otherMouseDragged = EventTypeMask(type: .otherMouseDragged)
        public static let magnify = EventTypeMask(type: .magnify), swipe = EventTypeMask(type: .swipe), rotate = EventTypeMask(type: .rotate)
        public static let gesture = EventTypeMask(type: .gesture), appKitDefined = EventTypeMask(type: .appKitDefined)
        public static let applicationDefined = EventTypeMask(type: .applicationDefined), periodic = EventTypeMask(type: .periodic)
        public static let any = EventTypeMask(rawValue: .max)
    }

    public struct ModifierFlags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let capsLock = ModifierFlags(rawValue: 1 << 16)
        public static let shift = ModifierFlags(rawValue: 1 << 17)
        public static let control = ModifierFlags(rawValue: 1 << 18)
        public static let option = ModifierFlags(rawValue: 1 << 19)
        public static let command = ModifierFlags(rawValue: 1 << 20)
        public static let numericPad = ModifierFlags(rawValue: 1 << 21)
        public static let help = ModifierFlags(rawValue: 1 << 22)
        public static let function = ModifierFlags(rawValue: 1 << 23)
        public static let deviceIndependentFlagsMask = ModifierFlags(rawValue: 0xffff0000)
    }

    public struct Phase: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let began = Phase(rawValue: 1), stationary = Phase(rawValue: 2), changed = Phase(rawValue: 4)
        public static let ended = Phase(rawValue: 8), cancelled = Phase(rawValue: 16), mayBegin = Phase(rawValue: 32)
    }

    public struct SpecialKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let upArrow = SpecialKey(rawValue: NSUpArrowFunctionKey), downArrow = SpecialKey(rawValue: NSDownArrowFunctionKey)
        public static let leftArrow = SpecialKey(rawValue: NSLeftArrowFunctionKey), rightArrow = SpecialKey(rawValue: NSRightArrowFunctionKey)
        public static let home = SpecialKey(rawValue: NSHomeFunctionKey), end = SpecialKey(rawValue: NSEndFunctionKey)
        public static let pageUp = SpecialKey(rawValue: NSPageUpFunctionKey), pageDown = SpecialKey(rawValue: NSPageDownFunctionKey)
        public static let deleteForward = SpecialKey(rawValue: NSDeleteFunctionKey), delete = SpecialKey(rawValue: 0x7f)
        public static let backspace = SpecialKey(rawValue: 0x08), tab = SpecialKey(rawValue: 0x09), backTab = SpecialKey(rawValue: 0x19)
        public static let carriageReturn = SpecialKey(rawValue: 0x0d), enter = SpecialKey(rawValue: 0x03), newline = SpecialKey(rawValue: 0x0a)
        public static let f1 = SpecialKey(rawValue: NSF1FunctionKey), f2 = SpecialKey(rawValue: NSF1FunctionKey + 1), f3 = SpecialKey(rawValue: NSF1FunctionKey + 2)
        public static let f4 = SpecialKey(rawValue: NSF1FunctionKey + 3), f5 = SpecialKey(rawValue: NSF1FunctionKey + 4), f6 = SpecialKey(rawValue: NSF1FunctionKey + 5)
        public static let f7 = SpecialKey(rawValue: NSF1FunctionKey + 6), f8 = SpecialKey(rawValue: NSF1FunctionKey + 7), f9 = SpecialKey(rawValue: NSF1FunctionKey + 8)
        public static let f10 = SpecialKey(rawValue: NSF1FunctionKey + 9), f11 = SpecialKey(rawValue: NSF1FunctionKey + 10), f12 = SpecialKey(rawValue: NSF1FunctionKey + 11)
        public static let help = SpecialKey(rawValue: 0xF746), insert = SpecialKey(rawValue: 0xF727)
    }

    public let type: EventType
    public let modifierFlags: ModifierFlags
    public let timestamp: TimeInterval
    open private(set) weak var window: NSWindow?
    open var windowNumber: Int { window?.windowNumber ?? 0 }
    public let locationInWindow: NSPoint
    public let clickCount: Int
    public let buttonNumber: Int
    public let eventNumber: Int
    open var pressure: Float { type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0 }
    // Keys.
    public let characters: String?
    public let charactersIgnoringModifiers: String?
    public let isARepeat: Bool
    public let keyCode: UInt16
    /// The characters the key types with `modifiers` instead of the ones
    /// held (a US layout's Shift for symbols).
    open func characters(byApplyingModifiers modifiers: ModifierFlags) -> String? {
        guard let base = charactersIgnoringModifiers else { return nil }
        let lowered = base.lowercased()
        guard modifiers.contains(.shift) else {
            // Undo Shift on a symbol.
            if let i = Self.shifted.firstIndex(where: { String($0.value) == base }) { return String(Self.shifted[i].key) }
            return lowered
        }
        if let c = lowered.first, let up = Self.shifted[c] { return String(up) }
        return base.uppercased()
    }
    static let shifted: [Character: Character] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]
    open var specialKey: SpecialKey? {
        guard let c = charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let v = Int(c.value)
        if (0xF700...0xF8FF).contains(v) || [0x7f, 0x08, 0x09, 0x19, 0x0d, 0x03, 0x0a].contains(v) { return SpecialKey(rawValue: v) }
        return nil
    }
    // Scrolling.
    public let scrollingDeltaX: CGFloat
    public let scrollingDeltaY: CGFloat
    public let hasPreciseScrollingDeltas: Bool
    open var deltaX: CGFloat { _deltaX }
    open var deltaY: CGFloat { _deltaY }
    open var deltaZ: CGFloat { 0 }
    let _deltaX: CGFloat, _deltaY: CGFloat
    open var phase: Phase = []
    open var momentumPhase: Phase = []
    open var isDirectionInvertedFromDevice: Bool { false }
    // Tracking.
    open internal(set) weak var trackingArea: NSTrackingArea?
    open var userData: UnsafeMutableRawPointer? { onMainThread { trackingArea?.userInfoPointer } }
    public struct EventSubtype: RawRepresentable, Hashable, Sendable {
        public var rawValue: Int16
        public init(rawValue: Int16) { self.rawValue = rawValue }
        public static let windowExposed = EventSubtype(rawValue: 0), applicationActivated = EventSubtype(rawValue: 1)
        public static let applicationDeactivated = EventSubtype(rawValue: 2), windowMoved = EventSubtype(rawValue: 4)
        public static let screenChanged = EventSubtype(rawValue: 8), powerOff = EventSubtype(rawValue: 1)
        public static let mouseEvent = EventSubtype(rawValue: 0), tabletPoint = EventSubtype(rawValue: 1)
        public static let tabletProximity = EventSubtype(rawValue: 2), touch = EventSubtype(rawValue: 3)
    }
    open internal(set) var subtype: EventSubtype = .windowExposed
    open internal(set) var data1: Int = 0, data2: Int = 0
    open var magnification: CGFloat = 0
    open var rotation: Float = 0
    open var stage: Int { 1 }
    var _cgEvent: CGEvent?
    open var cgEvent: CGEvent? { _cgEvent }

    public init(type: EventType, location: NSPoint, modifierFlags: ModifierFlags, timestamp: TimeInterval, window: NSWindow?, clickCount: Int = 0,
         buttonNumber: Int = 0, characters: String? = nil, charactersIgnoringModifiers: String? = nil, isARepeat: Bool = false, keyCode: UInt16 = 0,
         scrollingDelta: CGSize = .zero, precise: Bool = false, delta: CGSize = .zero, eventNumber: Int = 0) {
        self.type = type
        locationInWindow = location
        self.modifierFlags = modifierFlags
        self.timestamp = timestamp
        self.window = window
        self.clickCount = clickCount
        self.buttonNumber = buttonNumber
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.isARepeat = isARepeat
        self.keyCode = keyCode
        scrollingDeltaX = scrollingDelta.width
        scrollingDeltaY = scrollingDelta.height
        hasPreciseScrollingDeltas = precise
        _deltaX = delta.width
        _deltaY = delta.height
        self.eventNumber = eventNumber
        super.init()
    }

    public static func mouseEvent(with type: EventType, location: NSPoint, modifierFlags flags: ModifierFlags, timestamp: TimeInterval,
                                  windowNumber: Int, context: Any?, eventNumber: Int, clickCount: Int, pressure: Float) -> NSEvent? {
        NSEvent(type: type, location: location, modifierFlags: flags, timestamp: timestamp, window: onMainThread { NSApp.window(withWindowNumber: windowNumber) },
                clickCount: clickCount, buttonNumber: type == .rightMouseDown || type == .rightMouseUp ? 1 : 0, eventNumber: eventNumber)
    }
    public static func keyEvent(with type: EventType, location: NSPoint, modifierFlags flags: ModifierFlags, timestamp: TimeInterval,
                                windowNumber: Int, context: Any?, characters keys: String, charactersIgnoringModifiers ukeys: String,
                                isARepeat flag: Bool, keyCode code: UInt16) -> NSEvent? {
        NSEvent(type: type, location: location, modifierFlags: flags, timestamp: timestamp, window: onMainThread { NSApp.window(withWindowNumber: windowNumber) },
                characters: keys, charactersIgnoringModifiers: ukeys, isARepeat: flag, keyCode: code)
    }
    public static func otherEvent(with type: EventType, location: NSPoint, modifierFlags flags: ModifierFlags, timestamp: TimeInterval,
                                  windowNumber: Int, context: Any?, subtype: Int16, data1: Int, data2: Int) -> NSEvent? {
        let e = NSEvent(type: type, location: location, modifierFlags: flags, timestamp: timestamp, window: onMainThread { NSApp.window(withWindowNumber: windowNumber) })
        e.subtype = EventSubtype(rawValue: subtype)
        e.data1 = data1
        e.data2 = data2
        return e
    }

    /// The modifier keys held now.
    nonisolated(unsafe) public static var modifierFlags: ModifierFlags = []
    /// The mouse buttons held now (bit 0 left, bit 1 right…).
    nonisolated(unsafe) public static var pressedMouseButtons: Int = 0
    /// The pointer in screen coordinates (y-up), as last seen.
    nonisolated(unsafe) public static var mouseLocation: NSPoint = .zero
    public static var doubleClickInterval: TimeInterval { 0.4 }
    public static var keyRepeatDelay: TimeInterval { 0.5 }
    public static var keyRepeatInterval: TimeInterval { 0.033 }
    public static var isMouseCoalescingEnabled = true
    public static var isSwipeTrackingFromScrollEventsEnabled: Bool { false }

    /// Monitors see (and may replace or swallow) events before dispatch.
    public static func addLocalMonitorForEvents(matching mask: EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        onMainThread { () -> Any? in EventMonitors.add(mask, handler) }
    }
    /// Events for other apps aren't visible here; the monitor never fires.
    public static func addGlobalMonitorForEvents(matching mask: EventTypeMask, handler: @escaping (NSEvent) -> Void) -> Any? { NSObject() }
    public static func removeMonitor(_ monitor: Any) { onMainThread { EventMonitors.remove(monitor) } }
    public static func startPeriodicEvents(afterDelay delay: TimeInterval, withPeriod period: TimeInterval) {}
    public static func stopPeriodicEvents() {}

    open override var description: String {
        "NSEvent: type=\(type) loc=\(locationInWindow) flags=\(modifierFlags.rawValue) chars=\(characters ?? "")"
    }
}

public let NSUpArrowFunctionKey = 0xF700, NSDownArrowFunctionKey = 0xF701, NSLeftArrowFunctionKey = 0xF702, NSRightArrowFunctionKey = 0xF703
public let NSF1FunctionKey = 0xF704, NSF2FunctionKey = 0xF705, NSF3FunctionKey = 0xF706, NSF4FunctionKey = 0xF707, NSF5FunctionKey = 0xF708
public let NSF6FunctionKey = 0xF709, NSF7FunctionKey = 0xF70A, NSF8FunctionKey = 0xF70B, NSF9FunctionKey = 0xF70C, NSF10FunctionKey = 0xF70D
public let NSF11FunctionKey = 0xF70E, NSF12FunctionKey = 0xF70F, NSInsertFunctionKey = 0xF727, NSDeleteFunctionKey = 0xF728
public let NSHomeFunctionKey = 0xF729, NSBeginFunctionKey = 0xF72A, NSEndFunctionKey = 0xF72B, NSPageUpFunctionKey = 0xF72C, NSPageDownFunctionKey = 0xF72D
public let NSHelpFunctionKey = 0xF746, NSClearLineFunctionKey = 0xF739
public let NSEnterCharacter = 0x03, NSBackspaceCharacter = 0x08, NSTabCharacter = 0x09, NSNewlineCharacter = 0x0a
public let NSCarriageReturnCharacter = 0x0d, NSBackTabCharacter = 0x19, NSDeleteCharacter = 0x7f

@MainActor enum EventMonitors {
    final class Monitor: NSObject {
        let mask: NSEvent.EventTypeMask
        let handler: (NSEvent) -> NSEvent?
        init(_ m: NSEvent.EventTypeMask, _ h: @escaping (NSEvent) -> NSEvent?) { mask = m; handler = h }
    }
    static var monitors: [Monitor] = []
    static func add(_ mask: NSEvent.EventTypeMask, _ h: @escaping (NSEvent) -> NSEvent?) -> Any {
        let m = Monitor(mask, h)
        monitors.append(m)
        return m
    }
    static func remove(_ m: Any) { monitors.removeAll { $0 === (m as AnyObject) } }
    /// An event the monitors saw before native widgets did; sendEvent
    /// passes it through without running them again.
    static var alreadyFiltered: NSEvent?
    /// Whether any monitor takes this kind of pointer event.
    static func watches(_ kind: RawEvent.Kind) -> Bool {
        let mask: NSEvent.EventTypeMask = switch kind {
        case .mouseDown: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        case .mouseUp: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        case .mouseMoved: [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        default: []
        }
        return monitors.contains { !$0.mask.intersection(mask).isEmpty }
    }
    static func filter(_ e: NSEvent) -> NSEvent? {
        if let f = alreadyFiltered, f === e { alreadyFiltered = nil; return e }
        alreadyFiltered = nil
        var cur: NSEvent? = e
        for m in monitors where m.mask.contains(NSEvent.EventTypeMask(type: e.type)) {
            guard let c = cur else { return nil }
            cur = m.handler(c)
        }
        return cur
    }
}

@MainActor enum KeyDispatch {
    /// Set when a keyDown reaches the end of the responder chain.
    static var unhandled = false
}

// MARK: Raw input → NSEvent

@MainActor enum EventTranslation {
    static func flags(_ m: RawModifiers) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.shift) { f.insert(.shift) }
        // Ctrl does what ⌘ does on the Mac; Super stands in for ⌃.
        if m.contains(.control) { f.insert(.command) }
        if m.contains(.alt) { f.insert(.option) }
        if m.contains(.super) { f.insert(.control) }
        if m.contains(.capsLock) { f.insert(.capsLock) }
        return f
    }

    /// Characters for a key: Mac function-key code points for special keys.
    static func characters(_ e: RawEvent) -> (String, String) {
        let special: [String: Int] = [
            "Up": NSUpArrowFunctionKey, "Down": NSDownArrowFunctionKey, "Left": NSLeftArrowFunctionKey, "Right": NSRightArrowFunctionKey,
            "KP_Up": NSUpArrowFunctionKey, "KP_Down": NSDownArrowFunctionKey, "KP_Left": NSLeftArrowFunctionKey, "KP_Right": NSRightArrowFunctionKey,
            "Home": NSHomeFunctionKey, "End": NSEndFunctionKey, "Page_Up": NSPageUpFunctionKey, "Page_Down": NSPageDownFunctionKey,
            "Delete": NSDeleteFunctionKey, "KP_Delete": NSDeleteFunctionKey, "Insert": NSInsertFunctionKey, "Help": NSHelpFunctionKey,
            "BackSpace": 0x7f, "Return": 0x0d, "KP_Enter": 0x03, "Tab": 0x09, "ISO_Left_Tab": 0x19, "Escape": 0x1b,
        ]
        if let v = special[e.keyName] { let s = String(Character(Unicode.Scalar(UInt32(v))!)); return (s, s) }
        if e.keyName.hasPrefix("F"), let n = Int(e.keyName.dropFirst()), (1...35).contains(n) {
            let s = String(Character(Unicode.Scalar(UInt32(NSF1FunctionKey + n - 1))!))
            return (s, s)
        }
        return (e.characters, e.charactersIgnoringModifiers)
    }

    /// Mac virtual key codes (kVK_…) for X11 key names.
    static let keyCodes: [String: UInt16] = {
        var m: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26, "minus": 27, "8": 28,
            "0": 29, "bracketright": 30, "o": 31, "u": 32, "bracketleft": 33, "i": 34, "p": 35, "Return": 36, "l": 37, "j": 38,
            "apostrophe": 39, "k": 40, "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47,
            "Tab": 48, "ISO_Left_Tab": 48, "space": 49, "grave": 50, "BackSpace": 51, "Escape": 53, "Control_L": 55, "Control_R": 54,
            "Shift_L": 56, "Caps_Lock": 57, "Alt_L": 58, "Super_L": 59, "Shift_R": 60, "Alt_R": 61, "Super_R": 62,
            "KP_Decimal": 65, "KP_Multiply": 67, "KP_Add": 69, "KP_Divide": 75, "KP_Enter": 76, "KP_Subtract": 78, "KP_Equal": 81,
            "KP_0": 82, "KP_1": 83, "KP_2": 84, "KP_3": 85, "KP_4": 86, "KP_5": 87, "KP_6": 88, "KP_7": 89, "KP_8": 91, "KP_9": 92,
            "F5": 96, "F6": 97, "F7": 98, "F3": 99, "F8": 100, "F9": 101, "F11": 103, "F13": 105, "F14": 107, "F10": 109, "F12": 111,
            "F15": 113, "Help": 114, "Insert": 114, "Home": 115, "Page_Up": 116, "Delete": 117, "F4": 118, "End": 119, "F2": 120,
            "Page_Down": 121, "F1": 122, "Left": 123, "Right": 124, "Down": 125, "Up": 126,
        ]
        for c in "abcdefghijklmnopqrstuvwxyz" { if let v = m[String(c)] { m[String(c).uppercased()] = v } }
        return m
    }()
}

// MARK: Tracking areas

@preconcurrency @MainActor
open class NSTrackingArea: NSObject {
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let mouseEnteredAndExited = Options(rawValue: 0x01)
        public static let mouseMoved = Options(rawValue: 0x02)
        public static let cursorUpdate = Options(rawValue: 0x04)
        public static let activeWhenFirstResponder = Options(rawValue: 0x10)
        public static let activeInKeyWindow = Options(rawValue: 0x20)
        public static let activeInActiveApp = Options(rawValue: 0x40)
        public static let activeAlways = Options(rawValue: 0x80)
        public static let assumeInside = Options(rawValue: 0x100)
        public static let inVisibleRect = Options(rawValue: 0x200)
        public static let enabledDuringMouseDrag = Options(rawValue: 0x400)
    }
    public let rect: NSRect
    public let options: Options
    open private(set) weak var owner: AnyObject?
    public let userInfo: [AnyHashable: Any]?
    weak var view: NSView?
    var inside = false
    var userInfoPointer: UnsafeMutableRawPointer? { nil }

    public init(rect: NSRect, options: Options, owner: Any?, userInfo: [AnyHashable: Any]? = nil) {
        self.rect = rect
        self.options = options
        self.owner = owner.map { $0 as AnyObject }
        self.userInfo = userInfo
        inside = options.contains(.assumeInside)
        super.init()
    }

    /// The area in its view's coordinates, now.
    var effectiveRect: NSRect { options.contains(.inVisibleRect) ? (view?.visibleRect ?? rect) : rect }
}

// MARK: Cursors

@preconcurrency @MainActor
open class NSCursor: NSObject {
    let spec: CursorSpec
    /// The hot spot, in points from the image's top-left.
    open var hotSpot: NSPoint { look.hot }
    /// The cursor's image: a system cursor's is the platform theme's art
    /// (CursorTheme), at 2× in a 24-point image; empty without a theme.
    open var image: NSImage { look.image }
    private var custom: (image: NSImage, hot: NSPoint)?
    private lazy var look: (image: NSImage, hot: NSPoint) = {
        if let custom { return custom }
        guard case let .named(name) = spec, let art = CursorTheme.art(name) else {
            return (NSImage(size: NSSize(width: 16, height: 16)), NSPoint(x: 8, y: 8))
        }
        let image = NSImage(width: art.width, height: art.height, rgba: art.rgba)
        let k = CGFloat(CursorTheme.pointSize) / CGFloat(max(art.nominal, 1))
        image.size = NSSize(width: CGFloat(art.width) * k, height: CGFloat(art.height) * k)
        return (image, NSPoint(x: CGFloat(art.hot.x) * k, y: CGFloat(art.hot.y) * k))
    }()
    init(_ name: String) { spec = .named(name); super.init() }
    public init(image: NSImage, hotSpot: NSPoint) {
        if case let .pixels(w, h, px) = image.source { spec = .image(width: w, height: h, rgba: px, hotSpot: hotSpot) } else { spec = .named("default") }
        custom = (image, hotSpot)
        super.init()
    }

    public static let arrow = NSCursor("default")
    public static let iBeam = NSCursor("text")
    public static let iBeamCursorForVerticalLayout = NSCursor("vertical-text")
    public static let pointingHand = NSCursor("pointer")
    public static let openHand = NSCursor("grab")
    public static let closedHand = NSCursor("grabbing")
    public static let crosshair = NSCursor("crosshair")
    public static let resizeLeft = NSCursor("w-resize")
    public static let resizeRight = NSCursor("e-resize")
    public static let resizeLeftRight = NSCursor("ew-resize")
    public static let resizeUp = NSCursor("n-resize")
    public static let resizeDown = NSCursor("s-resize")
    public static let resizeUpDown = NSCursor("ns-resize")
    public static let operationNotAllowed = NSCursor("not-allowed")
    public static let dragLink = NSCursor("alias")
    public static let dragCopy = NSCursor("copy")
    public static let contextualMenu = NSCursor("context-menu")
    public static let disappearingItem = NSCursor("default")
    public static let zoomIn = NSCursor("zoom-in")
    public static let zoomOut = NSCursor("zoom-out")
    public static let columnResize = NSCursor("col-resize")
    public static let rowResize = NSCursor("row-resize")

    // Frame resizing (macOS 15): an edge or corner, inward, outward or both.
    public enum FrameResizePosition: Int, Sendable { case top, left, bottom, right, topLeft, topRight, bottomLeft, bottomRight }
    public struct FrameResizeDirections: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let inward = FrameResizeDirections(rawValue: 1), outward = FrameResizeDirections(rawValue: 2)
        public static let all: FrameResizeDirections = [.inward, .outward]
    }
    public static func frameResize(position: FrameResizePosition, directions: FrameResizeDirections) -> NSCursor {
        let name: String = switch position {
        case .top, .bottom: directions == .all ? "ns-resize" : (position == .top) == directions.contains(.outward) ? "n-resize" : "s-resize"
        case .left, .right: directions == .all ? "ew-resize" : (position == .left) == directions.contains(.outward) ? "w-resize" : "e-resize"
        case .topLeft, .bottomRight:
            directions == .all ? "nwse-resize" : (position == .topLeft) == directions.contains(.outward) ? "nw-resize" : "se-resize"
        case .topRight, .bottomLeft:
            directions == .all ? "nesw-resize" : (position == .topRight) == directions.contains(.outward) ? "ne-resize" : "sw-resize"
        }
        return frameCursors[name] ?? { let c = NSCursor(name); frameCursors[name] = c; return c }()
    }
    private static var frameCursors: [String: NSCursor] = [:]
    public static func columnResize(directions: FrameResizeDirections) -> NSCursor {
        directions == .all ? columnResize : directions.contains(.inward) ? resizeLeft : resizeRight
    }
    public static func rowResize(directions: FrameResizeDirections) -> NSCursor {
        directions == .all ? rowResize : directions.contains(.inward) ? resizeUp : resizeDown
    }

    static var stack: [NSCursor] = []
    static var _current: NSCursor = .arrow
    static var hidden = false
    public static var current: NSCursor { _current }
    public static var currentSystem: NSCursor? { _current }

    /// Makes this the pointer's shape over the window under the mouse.
    open func set() {
        NSCursor._current = self
        guard !NSCursor.hidden else { return }
        NSCursor.apply(spec)
    }
    open func push() { NSCursor.stack.append(NSCursor._current); set() }
    open func pop() { NSCursor.pop() }
    public static func pop() { (stack.popLast() ?? .arrow).set() }
    public static func hide() { hidden = true; apply(.hidden) }
    public static func unhide() { hidden = false; apply(_current.spec) }
    public static func setHiddenUntilMouseMoves(_ flag: Bool) { if flag { hide(); hideUntilMove = true } }
    static var hideUntilMove = false
    open func setOnMouseEntered(_ flag: Bool) {}
    open func setOnMouseExited(_ flag: Bool) {}
    open func mouseEntered(with event: NSEvent) {}
    open func mouseExited(with event: NSEvent) {}

    static func apply(_ spec: CursorSpec) {
        guard let vs = Runway.backend as? ViewSystemBackend, let w = NSWindow.underMouse ?? NSApp.keyWindow, let n = w.nativeWindow else { return }
        vs.setCursor(spec, in: n)
    }
}

// MARK: Drag and drop

public struct NSDragOperation: OptionSet, Sendable, Hashable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let copy = NSDragOperation(rawValue: 1)
    public static let link = NSDragOperation(rawValue: 2)
    public static let generic = NSDragOperation(rawValue: 4)
    public static let `private` = NSDragOperation(rawValue: 8)
    public static let move = NSDragOperation(rawValue: 16)
    public static let delete = NSDragOperation(rawValue: 32)
    public static let every = NSDragOperation(rawValue: .max)
    public static let all_Obsolete = NSDragOperation(rawValue: 15)
}

public enum NSDraggingFormation: Int, Sendable { case `default`, none, pile, list, stack }
public enum NSDraggingContext: Int, Sendable { case outsideApplication, withinApplication }
public struct NSDraggingItemEnumerationOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let concurrent = NSDraggingItemEnumerationOptions(rawValue: 1)
    public static let clearNonenumeratedImages = NSDraggingItemEnumerationOptions(rawValue: 1 << 16)
}

/// What a drop target learns about a drag.
@preconcurrency @MainActor public protocol NSDraggingInfo: AnyObject {
    var draggingDestinationWindow: NSWindow? { get }
    var draggingSourceOperationMask: NSDragOperation { get }
    /// In the destination window's coordinates.
    var draggingLocation: NSPoint { get }
    var draggedImageLocation: NSPoint { get }
    var draggedImage: NSImage? { get }
    var draggingPasteboard: NSPasteboard { get }
    var draggingSource: Any? { get }
    var draggingSequenceNumber: Int { get }
    var draggingFormation: NSDraggingFormation { get set }
    var animatesToDestination: Bool { get set }
    var numberOfValidItemsForDrop: Int { get set }
    var springLoadingHighlight: Int { get }
    func slideDraggedImage(to screenPoint: NSPoint)
    func resetSpringLoading()
}

@preconcurrency @MainActor public protocol NSDraggingDestination: AnyObject {}
@preconcurrency @MainActor public protocol NSDraggingSource: AnyObject {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation
}

@preconcurrency @MainActor open class NSDraggingSession: NSObject {
    open var draggingFormation: NSDraggingFormation = .default
    open var animatesToStartingPositionsOnCancelOrFail = true
    open var draggingLeaderIndex = 0
    open var draggingPasteboard: NSPasteboard { NSPasteboard(name: .drag) }
    open var draggingSequenceNumber: Int { 0 }
    open var draggingLocation: NSPoint { .zero }
}

@preconcurrency @MainActor open class NSDraggingItem: NSObject {
    public let item: Any
    open var draggingFrame: NSRect = .zero
    public init(pasteboardWriter: NSPasteboardWriting) { item = pasteboardWriter; super.init() }
    open func setDraggingFrame(_ frame: NSRect, contents: Any?) { draggingFrame = frame }
}

/// A drag in progress over one of the app's windows (files and text from
/// other apps; GTK's drop target supplies them).
@MainActor final class RunwayDraggingInfo: NSObject, NSDraggingInfo {
    weak var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = [.copy, .link, .generic, .move]
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    let draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

    init(window: NSWindow, location: NSPoint, files: [URL], strings: [String], sequence: Int) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggingPasteboard = NSPasteboard.dragPasteboard(files: files, strings: strings)
        draggingSequenceNumber = sequence
        numberOfValidItemsForDrop = files.count + strings.count
        super.init()
    }
}
