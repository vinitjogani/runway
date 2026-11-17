// AppKit for Linux and Windows, over the platform's toolkit.
//
//   AppKit.swift          NSApplication and its delegate
//   Responder.swift       NSResponder, the responder chain, target/action
//                         (through RunwayObjC), standard key bindings
//   View.swift            NSView: geometry, flipped coordinates, hierarchy,
//                         display (draw(_:) into a CGDisplayList), hit testing
//   Drawing.swift         NSGraphicsContext, NSBezierPath, string and image
//                         drawing, NSGradient, NSShadow, text attributes
//   Layout*.swift         Auto Layout (a Cassowary solver), autoresizing
//   Events.swift          NSEvent, NSTrackingArea, NSCursor, drag and drop
//   Window.swift          NSWindow, NSWindowController, NSScreen
//   ViewController.swift  NSViewController
//   Menu.swift            NSMenu, NSMenuItem, the menu bar, context menus
//   Control.swift         NSControl, the base of the standard controls
//   Services.swift        colours, appearance, fonts, images, pasteboard,
//                         workspace, sounds, panels, alerts

@_exported import Foundation
@_exported import RunwayFoundation
@_exported import CoreGraphics
@_exported import ApplicationServices
@_exported import IOKit
@_exported import Security
@_exported import CoreServices
@_exported import QuartzCore
@_exported import CoreText
@_exported import CoreImage
@_exported import RunwayObjC
import RunwayCore
import RunwayPlatform
import UniformTypeIdentifiers

// MARK: Application

@preconcurrency @MainActor public protocol NSApplicationDelegate: AnyObject {
    @MainActor func applicationWillFinishLaunching(_ notification: Notification)
    @MainActor func applicationDidFinishLaunching(_ notification: Notification)
    @MainActor func applicationWillTerminate(_ notification: Notification)
    @MainActor func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
    /// Files or folders to open: on Linux, the paths given on the command
    /// line (as a desktop file's `%U` passes them), right after launching.
    @preconcurrency @MainActor func application(_ application: NSApplication, open urls: [URL])
}

extension NSApplicationDelegate {
    public func applicationWillFinishLaunching(_ notification: Notification) {}
    public func applicationDidFinishLaunching(_ notification: Notification) {}
    public func applicationWillTerminate(_ notification: Notification) {}
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { .terminateNow }
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { true }
    public func application(_ application: NSApplication, open urls: [URL]) {}
}

@preconcurrency @MainActor
open class NSApplication: NSResponder {
    public static let shared = NSApplication()
    /// Settable from top-level code (main.swift), as on the Mac.
    nonisolated(unsafe) public weak var delegate: NSApplicationDelegate?
    open var mainMenu: NSMenu? { didSet { MenuBar.mainMenuChanged() } }
    /// The Window menu and Services menu (kept; GTK has no Services).
    open var windowsMenu: NSMenu?
    open var servicesMenu: NSMenu?
    open var helpMenu: NSMenu?
    open private(set) var windows: [NSWindow] = []
    open var isRunning = false
    private var policy: ActivationPolicy = .regular

    public enum ActivationPolicy: Int, Sendable { case regular, accessory, prohibited }
    public enum TerminateReply: UInt, Sendable { case terminateCancel, terminateNow, terminateLater }
    public struct ModalResponse: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let OK = ModalResponse(rawValue: 1)
        public static let cancel = ModalResponse(rawValue: 0)
        public static let stop = ModalResponse(rawValue: -1000)
        public static let abort = ModalResponse(rawValue: -1001)
        public static let `continue` = ModalResponse(rawValue: -1002)
        public static let alertFirstButtonReturn = ModalResponse(rawValue: 1000)
        public static let alertSecondButtonReturn = ModalResponse(rawValue: 1001)
        public static let alertThirdButtonReturn = ModalResponse(rawValue: 1002)
    }

    public static let didFinishLaunchingNotification = Notification.Name("NSApplicationDidFinishLaunchingNotification")
    public static let willTerminateNotification = Notification.Name("NSApplicationWillTerminateNotification")
    public static let didBecomeActiveNotification = Notification.Name("NSApplicationDidBecomeActiveNotification")
    public static let didResignActiveNotification = Notification.Name("NSApplicationDidResignActiveNotification")

    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }
    public override init() {
        super.init()
        RunwayPlatform.installDefaultBackend()
        AppKitRuntime.install()
    }

    /// Runs the main loop (callable from main.swift's top-level code).
    open nonisolated func run() { MainActor.assumeIsolated { runLoop() } }
    private func runLoop() {
        isRunning = true
        Runway.backend.run { [weak self] in
            guard let self else { return }
            let n = Notification(name: Self.didFinishLaunchingNotification, object: self)
            // NSApplicationMain: the main storyboard's or nib's menu and delegate.
            NSApplication.launchHooks.loadMainInterface?()
            self.delegate?.applicationWillFinishLaunching(n)
            // …and the storyboard's initial controller, shown before launching finishes.
            NSApplication.launchHooks.showInitialController?()
            // As on the Mac, launching finishes while the "open application"
            // event is handled, so it's NSAppleEventManager's current event.
            NSAppleEventManager.shared()._dispatch(Self.launchEvent()) {
                self.delegate?.applicationDidFinishLaunching(n)
                NotificationCenter.default.post(n)
            }
            // As the Mac's "open documents" event follows launching.
            let urls = Self.launchURLs(CommandLine.arguments)
            if !urls.isEmpty { self.delegate?.application(self, open: urls) }
        }
    }

    /// The launch's "open application" event, marked as a login item launch
    /// when started from the autostart entry SMAppService writes.
    static func launchEvent() -> NSAppleEventDescriptor {
        let e = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                                  targetDescriptor: nil, returnID: -1, transactionID: 0)
        if CommandLine.arguments.contains("--launched-at-login") {
            e.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData))
        }
        return e
    }

    /// The files and folders named on the command line (existing paths or
    /// `file:` URLs; options starting with "-" are skipped).
    static func launchURLs(_ arguments: [String]) -> [URL] {
        arguments.dropFirst().compactMap { a -> URL? in
            if a.hasPrefix("-") { return nil }
            if a.hasPrefix("file:"), let u = URL(string: a), u.isFileURL { return u }
            guard FileManager.default.fileExists(atPath: a) else { return nil }
            return URL(fileURLWithPath: a).standardizedFileURL
        }
    }

    open func terminate(_ sender: Any?) {
        if delegate?.applicationShouldTerminate(self) == .terminateCancel { return }
        reallyTerminate()
    }

    open func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        if shouldTerminate { reallyTerminate() }
    }

    private func reallyTerminate() {
        let n = Notification(name: Self.willTerminateNotification, object: self)
        delegate?.applicationWillTerminate(n)
        NotificationCenter.default.post(n)
        isRunning = false
        Runway.backend.quit()
    }

    open func stop(_ sender: Any?) { Runway.backend.quit() }
    open nonisolated func activate(ignoringOtherApps flag: Bool) {}
    open nonisolated func activate() {}
    open nonisolated func deactivate() {}
    open func hide(_ sender: Any?) {}
    open func unhide(_ sender: Any?) {}
    @discardableResult open nonisolated func setActivationPolicy(_ p: ActivationPolicy) -> Bool { MainActor.assumeIsolated { policy = p }; return true }
    open func activationPolicy() -> ActivationPolicy { policy }
    open var isActive: Bool { true }
    /// The window receiving key events: the last one made key that's still visible.
    open var keyWindow: NSWindow? {
        if let k = _keyWindow, k.isVisible { return k }
        return windows.last { $0.isVisible && $0.canBecomeKey }
    }
    weak var _keyWindow: NSWindow?
    open var mainWindow: NSWindow? {
        if let k = keyWindow, k.canBecomeMain { return k }
        return windows.last { $0.isVisible && $0.canBecomeMain }
    }
    open var orderedWindows: [NSWindow] { windows.reversed() }
    open func window(withWindowNumber n: Int) -> NSWindow? { windows.first { $0.windowNumber == n } }
    /// The system's appearance, or the app's when set.
    open var effectiveAppearance: NSAppearance { appearance ?? NSAppearance.system }
    open var appearance: NSAppearance? {
        didSet {
            (Runway.backend as? ViewSystemBackend)?.setPreferredColorScheme(appearance.map { $0.isDark ? .dark : .light })
            for w in windows { w.appearanceDidChange() }
            KVO.didChange(self, "appearance", old: oldValue, new: appearance)
            KVO.didChange(self, "effectiveAppearance", old: oldValue ?? NSAppearance.system, new: effectiveAppearance)
        }
    }

    /// Sends `action` to `target`, or along the responder chain when nil
    /// (key window's first responder … window, its delegate and controller,
    /// the main window's chain, NSApp, its delegate). Dispatch goes through
    /// RunwayObjC: generated tables, then AppKit's registered selectors.
    @discardableResult
    open func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        RunwayObjC.sendAction(action, to: target, from: sender)
    }
    open func target(forAction action: Selector) -> Any? { RunwayObjC.target(forAction: action, to: nil, from: nil) }
    open func target(forAction action: Selector, to target: Any?, from sender: Any?) -> Any? {
        RunwayObjC.target(forAction: action, to: target, from: sender)
    }
    open override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        RunwayObjC.sendAction(action, to: nil, from: object)
    }

    /// Delivers an event: local monitors first, then its window.
    open func sendEvent(_ event: NSEvent) {
        guard let e = EventMonitors.filter(event) else { return }
        e.window?.sendEvent(e)
    }
    open private(set) var currentEvent: NSEvent?
    func setCurrentEvent(_ e: NSEvent?) { currentEvent = e }
    open func postEvent(_ event: NSEvent, atStart: Bool) { Runway.backend.schedule { [weak self] in self?.sendEvent(event) } }
    open func nextEvent(matching mask: NSEvent.EventTypeMask, until date: Date?, inMode mode: RunLoop.Mode, dequeue: Bool) -> NSEvent? { nil }
    open func discardEvents(matching mask: NSEvent.EventTypeMask, before event: NSEvent?) {}
    open var isFullKeyboardAccessEnabled: Bool { false }
    open var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection { .leftToRight }
    open func updateWindows() {}
    open func setWindowsNeedUpdate(_ b: Bool) {}
    open func arrangeInFront(_ sender: Any?) { for w in windows where w.isVisible { w.orderFront(sender) } }
    open func miniaturizeAll(_ sender: Any?) {}
    open func hideOtherApplications(_ sender: Any?) {}
    open func unhideAllApplications(_ sender: Any?) {}
    open func runModal(forWindow window: NSWindow) -> ModalResponse { runModal(for: window) }
    open func beginModalSession(for window: NSWindow) -> Int { window.makeKeyAndOrderFront(nil); return 1 }
    open func endModalSession(_ session: Int) {}
    open func abortModal() {}
    open var modalWindow: NSWindow? { windows.last { $0.isVisible && $0.isModal } }
    open func registerServicesMenuSendTypes(_ send: [NSPasteboard.PasteboardType], returnTypes: [NSPasteboard.PasteboardType]) {}
    open func registerForRemoteNotifications() {}
    open func addWindowsItem(_ win: NSWindow, title: String, filename: Bool) {}
    open func changeWindowsItem(_ win: NSWindow, title: String, filename: Bool) {}
    open func removeWindowsItem(_ win: NSWindow) {}
    open func orderFrontCharacterPalette(_ sender: Any?) {}
    open func orderFrontColorPanel(_ sender: Any?) {}
    open func showHelp(_ sender: Any?) {}
    open func toggleTouchBarCustomizationPalette(_ sender: Any?) {}
    /// The object that handles the app's Services (its `NSServices` methods).
    open var servicesProvider: Any?

    public struct AboutPanelOptionKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let credits = AboutPanelOptionKey("Credits")
        public static let applicationName = AboutPanelOptionKey("ApplicationName")
        public static let applicationIcon = AboutPanelOptionKey("ApplicationIcon")
        public static let version = AboutPanelOptionKey("Version")
        public static let applicationVersion = AboutPanelOptionKey("ApplicationVersion")
    }
    open func orderFrontStandardAboutPanel(_ sender: Any?) { orderFrontStandardAboutPanel(options: [:]) }
    /// The About panel: the app's name, version and credits (from the
    /// options, else Info.plist).
    open func orderFrontStandardAboutPanel(options: [AboutPanelOptionKey: Any] = [:]) {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = options[.applicationName] as? String ?? info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            ?? ProcessInfo.processInfo.processName
        let version = options[.applicationVersion] as? String ?? info["CFBundleShortVersionString"] as? String
        let build = options[.version] as? String ?? info["CFBundleVersion"] as? String
        var lines: [String] = []
        if let version { lines.append(build.map { "Version \(version) (\($0))" } ?? "Version \(version)") }
        if let c = options[.credits] as? NSAttributedString { lines.append(c.string) } else if let c = options[.credits] as? String { lines.append(c) }
        if let copyright = info["NSHumanReadableCopyright"] as? String { lines.append(copyright) }
        _ = Runway.backend.services.alert(title: name, message: lines.joined(separator: "\n\n"), buttons: ["OK"], destructive: nil)
    }
    open var applicationIconImage: NSImage?
    open var dockTile: NSDockTile { NSDockTile() }
    open func requestUserAttention(_ type: RequestUserAttentionType) -> Int { 0 }
    public enum RequestUserAttentionType: UInt, Sendable { case criticalRequest = 0, informationalRequest = 10 }
    open func runModal(for window: NSWindow) -> ModalResponse { window.makeKeyAndOrderFront(nil); return .OK }
    open func stopModal() {}
    open func stopModal(withCode code: ModalResponse) {}

    func register(_ w: NSWindow) { if !windows.contains(where: { $0 === w }) { windows.append(w) } }
    func moveToFront(_ w: NSWindow) {
        windows.removeAll { $0 === w }
        windows.append(w)
    }
    func unregister(_ w: NSWindow) {
        windows.removeAll { $0 === w }
        if w === _keyWindow { _keyWindow = nil }
        // Menu-bar (accessory, LSUIElement) apps keep running windowless.
        let agent = policy != .regular || (Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false)
        if !agent, windows.allSatisfy({ !$0.isVisible }), delegate?.applicationShouldTerminateAfterLastWindowClosed(self) ?? true {
            terminate(nil)
        }
    }
}

@preconcurrency @MainActor public var NSApp: NSApplication { NSApplication.shared }

public final class NSDockTile {
    public var badgeLabel: String?
    public var contentView: NSView?
    public func display() {}
}

@preconcurrency @MainActor public func NSBeep() { Runway.backend.services.beep() }


/// Loads Info.plist's `NSMainStoryboardFile` / `NSMainNibFile` as the
/// application launches (InterfaceBuilder/IBNib.swift), then runs.
@preconcurrency @MainActor public func NSApplicationMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    IBLaunch.prepare()
    NSApplication.shared.run()
    return 0
}

public enum NSUserInterfaceLayoutDirection: Int, Sendable { case leftToRight, rightToLeft }

public struct NSUserInterfaceItemIdentifier: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public protocol NSUserInterfaceItemIdentification: AnyObject {
    var identifier: NSUserInterfaceItemIdentifier? { get set }
}

/// Views that take key presses before the window's menus (SwiftUI's
/// hosting view).
@preconcurrency @MainActor public protocol KeyHandling: AnyObject {
    func handleKey(_ key: KeyPress) -> Bool
}
