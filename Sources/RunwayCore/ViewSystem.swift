// What AppKit's view system needs from a backend beyond SwiftUI's widget
// contract: raw input for a window (AppKit hit-tests and dispatches it
// itself), cursors, drag and drop, a native menu bar and context menus,
// screen geometry, text metrics for string drawing, and focus.
//
// NSView drawing needs nothing new: a view's `draw(_:)` is recorded into a
// CGDisplayList shown by a `.canvas` widget (`DrawCommand.displayList`).
//
// Backends adopt `ViewSystemBackend` alongside `Backend`; AppKit checks
// `Runway.backend as? ViewSystemBackend` and degrades without it.

import CoreGraphics
import Foundation

/// Modifier keys as the platform reports them. AppKit maps Ctrl to ⌘
/// (so Mac shortcuts work as Ctrl shortcuts), Alt to ⌥, Super to ⌃.
public struct RawModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shift = RawModifiers(rawValue: 1)
    public static let control = RawModifiers(rawValue: 2)
    public static let alt = RawModifiers(rawValue: 4)
    public static let `super` = RawModifiers(rawValue: 8)
    public static let capsLock = RawModifiers(rawValue: 16)
}

/// One input event for a window, in its content area's top-left
/// coordinates (points).
public struct RawEvent: Sendable {
    public enum Kind: Sendable { case mouseDown, mouseUp, mouseMoved, scroll, mouseEntered, mouseExited, keyDown, keyUp, flagsChanged }
    public var kind: Kind
    /// 0 left, 1 right, 2 middle, 3+ others.
    public var button: Int = 0
    public var location: CGPoint = .zero
    public var modifiers: RawModifiers = []
    /// Seconds, monotonic.
    public var timestamp: TimeInterval = 0
    /// Scroll deltas: positive y scrolls content down (wheel toward the user
    /// gives negative y, as on the Mac).
    public var scrollDelta: CGSize = .zero
    /// Pixel-precise deltas (touchpads) rather than wheel lines.
    public var preciseScrolling = false
    /// Platform key code and name ("a", "Return", "Left"…: X11 keysym names).
    public var keyCode: UInt32 = 0
    public var keyName: String = ""
    /// The text the key produces, and without modifiers.
    public var characters: String = ""
    public var charactersIgnoringModifiers: String = ""
    public var isRepeat = false
    public init(kind: Kind) { self.kind = kind }
}

/// A drag over a window: files and/or text.
public struct RawDragEvent: Sendable {
    public enum Kind: Sendable { case entered, updated, exited, perform }
    public var kind: Kind
    public var location: CGPoint
    public var fileURLs: [URL]
    public var strings: [String]
    public init(kind: Kind, location: CGPoint, fileURLs: [URL] = [], strings: [String] = []) {
        self.kind = kind; self.location = location; self.fileURLs = fileURLs; self.strings = strings
    }
}

/// What a drop target accepts (AppKit's NSDragOperation bits).
public struct RawDragOperation: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let copy = RawDragOperation(rawValue: 1)
    public static let link = RawDragOperation(rawValue: 2)
    public static let move = RawDragOperation(rawValue: 16)
}

/// A pointer shape: a named one (CSS cursor names) or an image.
public enum CursorSpec: Hashable, Sendable {
    case named(String)
    case image(width: Int, height: Int, rgba: [UInt8], hotSpot: CGPoint)
    case hidden
}

/// A menu for the menu bar or a context menu. `id`s are the AppKit
/// layer's; the backend reports activations and asks for fresh state by id.
public struct MenuNode: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case item, separator, submenu }
    public var id: Int
    public var kind: Kind
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    /// GTK accelerator syntax ("<Control>n", "<Control><Shift>z"), for display.
    public var accelerator: String?
    public var children: [MenuNode]
    public init(id: Int, kind: Kind = .item, title: String, enabled: Bool = true, checked: Bool = false, accelerator: String? = nil, children: [MenuNode] = []) {
        self.id = id; self.kind = kind; self.title = title; self.enabled = enabled; self.checked = checked; self.accelerator = accelerator; self.children = children
    }
}

public struct MenuItemState: Hashable, Sendable {
    public var id: Int
    public var enabled: Bool
    public var checked: Bool
    public init(id: Int, enabled: Bool, checked: Bool) { self.id = id; self.enabled = enabled; self.checked = checked }
}

/// How a menu reports back.
@MainActor public struct MenuCallbacks {
    /// An item was chosen.
    public var activate: (Int) -> Void
    /// The menu is about to open: return current enabled/checked states.
    public var validate: () -> [MenuItemState]
    public init(activate: @escaping (Int) -> Void, validate: @escaping () -> [MenuItemState]) {
        self.activate = activate; self.validate = validate
    }
}

/// A display, in top-left desktop coordinates (points).
public struct ScreenSpec: Hashable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var scale: CGFloat
    public var name: String
    public init(frame: CGRect, visibleFrame: CGRect, scale: CGFloat, name: String) {
        self.frame = frame; self.visibleFrame = visibleFrame; self.scale = scale; self.name = name
    }
}

@MainActor public protocol ViewSystemBackend: AnyObject {
    /// Delivers the window's input; return true when handled (the backend
    /// then stops native propagation). Key events arrive before native
    /// widgets see them (`keyDown` with `nativeFocus == false`).
    func setEventHandler(_ window: NativeWindow, _ handler: ((RawEvent) -> Bool)?)
    /// Key and main status changes (`true`: became active).
    func setActivationHandler(_ window: NativeWindow, _ handler: ((Bool) -> Void)?)
    /// Drag and drop over the window; return the operation accepted.
    func setDropHandler(_ window: NativeWindow, _ handler: ((RawDragEvent) -> RawDragOperation)?)
    func setCursor(_ cursor: CursorSpec, in window: NativeWindow)
    /// A menu bar along the window's top (nil removes it).
    func setMenuBar(_ menu: [MenuNode]?, in window: NativeWindow, callbacks: MenuCallbacks)
    /// Shows a context menu at `point` (content coordinates) and returns
    /// once it closes.
    func popUpMenu(_ menu: [MenuNode], in window: NativeWindow, at point: CGPoint, callbacks: MenuCallbacks)
    func screens() -> [ScreenSpec]
    /// The size text takes when drawn (`CGDisplayOp.text`).
    func measureText(_ layout: CGTextLayout) -> CGSize
    /// Moves native keyboard focus to `widget` (nil: to no widget, so key
    /// events reach the window's own handler).
    func setKeyboardFocus(_ widget: NativeWidget?, in window: NativeWindow)
    func setDecorated(_ decorated: Bool, window: NativeWindow)
    /// nil follows the system.
    func setPreferredColorScheme(_ scheme: ColorSchemeValue?)
    /// Raises the window and gives it focus.
    func activate(_ window: NativeWindow)
}

// MARK: Headless

/// The headless backend records what AppKit asks for, and tests inject
/// input through `send(_:to:)`.
@MainActor public final class HeadlessViewSystem {
    public var eventHandlers: [ObjectIdentifier: (RawEvent) -> Bool] = [:]
    public var activationHandlers: [ObjectIdentifier: (Bool) -> Void] = [:]
    public var dropHandlers: [ObjectIdentifier: (RawDragEvent) -> RawDragOperation] = [:]
    public var cursors: [ObjectIdentifier: CursorSpec] = [:]
    public var menuBars: [ObjectIdentifier: [MenuNode]] = [:]
    public var menuCallbacks: [ObjectIdentifier: MenuCallbacks] = [:]
    /// The last context menu shown; `popUpChoice` picks an id to activate.
    public var lastPopUp: [MenuNode]?
    public var popUpChoice: Int?
    public var screenSpecs = [ScreenSpec(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 32, width: 1440, height: 868), scale: 2, name: "Headless Display")]
    public var focused: [ObjectIdentifier: NativeWidget?] = [:]
    public var preferredScheme: ColorSchemeValue?
    init() {}
}

extension HeadlessBackend: ViewSystemBackend {
    private static var systems: [ObjectIdentifier: HeadlessViewSystem] = [:]
    /// What AppKit set up on this backend.
    public var viewSystem: HeadlessViewSystem {
        if let s = Self.systems[ObjectIdentifier(self)] { return s }
        let s = HeadlessViewSystem()
        Self.systems[ObjectIdentifier(self)] = s
        return s
    }

    /// Simulates input to a window; returns whether it was handled.
    @discardableResult public func send(_ event: RawEvent, to window: NativeWindow) -> Bool {
        viewSystem.eventHandlers[ObjectIdentifier(window)]?(event) ?? false
    }

    public func setEventHandler(_ window: NativeWindow, _ handler: ((RawEvent) -> Bool)?) { viewSystem.eventHandlers[ObjectIdentifier(window)] = handler }
    public func setActivationHandler(_ window: NativeWindow, _ handler: ((Bool) -> Void)?) { viewSystem.activationHandlers[ObjectIdentifier(window)] = handler }
    public func setDropHandler(_ window: NativeWindow, _ handler: ((RawDragEvent) -> RawDragOperation)?) { viewSystem.dropHandlers[ObjectIdentifier(window)] = handler }
    public func setCursor(_ cursor: CursorSpec, in window: NativeWindow) { viewSystem.cursors[ObjectIdentifier(window)] = cursor }
    public func setMenuBar(_ menu: [MenuNode]?, in window: NativeWindow, callbacks: MenuCallbacks) {
        viewSystem.menuBars[ObjectIdentifier(window)] = menu
        viewSystem.menuCallbacks[ObjectIdentifier(window)] = callbacks
    }
    public func popUpMenu(_ menu: [MenuNode], in window: NativeWindow, at point: CGPoint, callbacks: MenuCallbacks) {
        _ = callbacks.validate()
        viewSystem.lastPopUp = menu
        if let id = viewSystem.popUpChoice { callbacks.activate(id) }
    }
    public func screens() -> [ScreenSpec] { viewSystem.screenSpecs }
    public func measureText(_ layout: CGTextLayout) -> CGSize {
        let runs = layout.runs.map { r in
            TextRun(string: r.string, font: FontSpec(size: r.size), color: nil)
        }
        let limit = layout.lineBreak == .wordWrap || layout.lineBreak == .charWrap ? (layout.maximumLines > 0 ? layout.maximumLines : nil) : 1
        let s = Self.measureText(StyledText(runs: runs, lineLimit: limit), width: layout.width)
        return CGSize(width: s.width, height: s.height + max(0, CGFloat(s.height / Self.lineHeight(runs.map(\.font.size).max() ?? 13)) - 1) * layout.lineSpacing)
    }
    public func setKeyboardFocus(_ widget: NativeWidget?, in window: NativeWindow) { viewSystem.focused[ObjectIdentifier(window)] = widget }
    public func setDecorated(_ decorated: Bool, window: NativeWindow) {}
    public func setPreferredColorScheme(_ scheme: ColorSchemeValue?) {
        viewSystem.preferredScheme = scheme
        if let scheme { colorScheme = scheme }
    }
    public func activate(_ window: NativeWindow) { viewSystem.activationHandlers[ObjectIdentifier(window)]?(true) }
}
