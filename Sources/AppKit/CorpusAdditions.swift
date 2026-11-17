// AppKit API the corpus apps use that the slice lacked: image and font
// names, workspace notifications and launching apps, screen-change
// notifications, pasteboard items, gesture recognizers (clicks work; the
// others are accepted and stay idle), sharing services (copy, mail via
// xdg-open) and haptics (none on a PC).

import Foundation
import CoreGraphics
import RunwayCore
import RunwayFoundation
import UniformTypeIdentifiers

// MARK: Names

extension NSImage {
    public struct Name: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public static let actionTemplate = Name("NSActionTemplate")
        public static let addTemplate = Name("NSAddTemplate")
        public static let removeTemplate = Name("NSRemoveTemplate")
        public static let refreshTemplate = Name("NSRefreshTemplate")
        public static let stopProgressTemplate = Name("NSStopProgressTemplate")
        public static let goLeftTemplate = Name("NSGoLeftTemplate")
        public static let goRightTemplate = Name("NSGoRightTemplate")
        public static let menuOnStateTemplate = Name("NSMenuOnStateTemplate")
        public static let menuMixedStateTemplate = Name("NSMenuMixedStateTemplate")
        public static let shareTemplate = Name("NSShareTemplate")
        public static let applicationIcon = Name("NSApplicationIcon")
        public static let caution = Name("NSCaution")
        public static let folder = Name("NSFolder")
        public static let trashEmpty = Name("NSTrashEmpty")
        public static let trashFull = Name("NSTrashFull")
        public static let network = Name("NSNetwork")
        public static let advanced = Name("NSAdvanced")
        public static let preferencesGeneral = Name("NSPreferencesGeneral")
        public static let userAccounts = Name("NSUserAccounts")
        public static let statusAvailable = Name("NSStatusAvailable")
        public static let statusPartiallyAvailable = Name("NSStatusPartiallyAvailable")
        public static let statusUnavailable = Name("NSStatusUnavailable")
        public static let statusNone = Name("NSStatusNone")
        public static let touchBarAddTemplate = Name("NSTouchBarAddTemplate")
    }

    /// An image by name: the app's resources (as `NSImage(named: String)`).
    public convenience init?(named name: Name) { self.init(named: name.rawValue) }
}

extension NSFont {
    public static func menuFont(ofSize size: CGFloat) -> NSFont { systemFont(ofSize: size == 0 ? 14 : size) }
    public static func menuBarFont(ofSize size: CGFloat) -> NSFont { systemFont(ofSize: size == 0 ? 13 : size) }
    public static func messageFont(ofSize size: CGFloat) -> NSFont { systemFont(ofSize: size == 0 ? 13 : size) }
    public static func paletteFont(ofSize size: CGFloat) -> NSFont { systemFont(ofSize: size == 0 ? 11 : size) }
    public static func titleBarFont(ofSize size: CGFloat) -> NSFont { boldSystemFont(ofSize: size == 0 ? 13 : size) }
    public static func toolTipsFont(ofSize size: CGFloat) -> NSFont { systemFont(ofSize: size == 0 ? 11 : size) }
    public static func controlContentFont(ofSize size: CGFloat) -> NSFont { systemFont(ofSize: size == 0 ? 13 : size) }
    public static func userFont(ofSize size: CGFloat) -> NSFont? { systemFont(ofSize: size == 0 ? 12 : size) }
    public static func userFixedPitchFont(ofSize size: CGFloat) -> NSFont? { monospacedSystemFont(ofSize: size == 0 ? 11 : size, weight: .regular) }
    public static var labelFontSize: CGFloat { 10 }
}

// MARK: Function keys F13–F35 (F1–F12 are in Events.swift)

public let NSF13FunctionKey = 0xF710, NSF14FunctionKey = 0xF711, NSF15FunctionKey = 0xF712, NSF16FunctionKey = 0xF713, NSF17FunctionKey = 0xF714, NSF18FunctionKey = 0xF715, NSF19FunctionKey = 0xF716, NSF20FunctionKey = 0xF717, NSF21FunctionKey = 0xF718, NSF22FunctionKey = 0xF719, NSF23FunctionKey = 0xF71A, NSF24FunctionKey = 0xF71B, NSF25FunctionKey = 0xF71C, NSF26FunctionKey = 0xF71D, NSF27FunctionKey = 0xF71E, NSF28FunctionKey = 0xF71F, NSF29FunctionKey = 0xF720, NSF30FunctionKey = 0xF721, NSF31FunctionKey = 0xF722, NSF32FunctionKey = 0xF723, NSF33FunctionKey = 0xF724, NSF34FunctionKey = 0xF725, NSF35FunctionKey = 0xF726

// MARK: Application and workspace notifications

extension NSApplication {
    public static let didChangeScreenParametersNotification = Notification.Name("NSApplicationDidChangeScreenParametersNotification")
    public static let willFinishLaunchingNotification = Notification.Name("NSApplicationWillFinishLaunchingNotification")
    public static let willBecomeActiveNotification = Notification.Name("NSApplicationWillBecomeActiveNotification")
    public static let willResignActiveNotification = Notification.Name("NSApplicationWillResignActiveNotification")
    public static let didHideNotification = Notification.Name("NSApplicationDidHideNotification")
    public static let didUnhideNotification = Notification.Name("NSApplicationDidUnhideNotification")
    public static let willHideNotification = Notification.Name("NSApplicationWillHideNotification")
    public static let willUnhideNotification = Notification.Name("NSApplicationWillUnhideNotification")
    public static let didUpdateNotification = Notification.Name("NSApplicationDidUpdateNotification")
    public static let willUpdateNotification = Notification.Name("NSApplicationWillUpdateNotification")
    public static let didChangeOcclusionStateNotification = Notification.Name("NSApplicationDidChangeOcclusionStateNotification")
    public static let protectedDataDidBecomeAvailableNotification = Notification.Name("NSApplicationProtectedDataDidBecomeAvailableNotification")
}

extension NSWorkspace {
    public static let didActivateApplicationNotification = Notification.Name("NSWorkspaceDidActivateApplicationNotification")
    public static let didDeactivateApplicationNotification = Notification.Name("NSWorkspaceDidDeactivateApplicationNotification")
    public static let didLaunchApplicationNotification = Notification.Name("NSWorkspaceDidLaunchApplicationNotification")
    public static let willLaunchApplicationNotification = Notification.Name("NSWorkspaceWillLaunchApplicationNotification")
    public static let didTerminateApplicationNotification = Notification.Name("NSWorkspaceDidTerminateApplicationNotification")
    public static let didHideApplicationNotification = Notification.Name("NSWorkspaceDidHideApplicationNotification")
    public static let didUnhideApplicationNotification = Notification.Name("NSWorkspaceDidUnhideApplicationNotification")
    public static let activeSpaceDidChangeNotification = Notification.Name("NSWorkspaceActiveSpaceDidChangeNotification")
    public static let sessionDidBecomeActiveNotification = Notification.Name("NSWorkspaceSessionDidBecomeActiveNotification")
    public static let sessionDidResignActiveNotification = Notification.Name("NSWorkspaceSessionDidResignActiveNotification")
    public static let screensDidSleepNotification = Notification.Name("NSWorkspaceScreensDidSleepNotification")
    public static let screensDidWakeNotification = Notification.Name("NSWorkspaceScreensDidWakeNotification")
    public static let willPowerOffNotification = Notification.Name("NSWorkspaceWillPowerOffNotification")
    public static let didMountNotification = Notification.Name("NSWorkspaceDidMountNotification")
    public static let didUnmountNotification = Notification.Name("NSWorkspaceDidUnmountNotification")
    public static let willUnmountNotification = Notification.Name("NSWorkspaceDidWillUnmountNotification")
    public static let didRenameVolumeNotification = Notification.Name("NSWorkspaceDidRenameVolumeNotification")
    public static let didChangeFileLabelsNotification = Notification.Name("NSWorkspaceDidChangeFileLabelsNotification")
    public static let accessibilityDisplayOptionsDidChangeNotification = Notification.Name("NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification")
    public static let applicationUserInfoKey = "NSWorkspaceApplicationKey"
    public static let volumeURLUserInfoKey = "NSWorkspaceVolumeURLKey"
    public static let volumeLocalizedNameUserInfoKey = "NSDevicePath"

    /// Launches an app: an executable, or a `.desktop` file, with the URLs as arguments.
    public func openApplication(at applicationURL: URL, configuration: OpenConfiguration,
                                completionHandler: ((NSRunningApplication?, Error?) -> Void)? = nil) {
        launch(applicationURL, arguments: configuration.arguments, completionHandler: completionHandler)
    }

    public func open(_ urls: [URL], withApplicationAt applicationURL: URL, configuration: OpenConfiguration,
                     completionHandler: ((NSRunningApplication?, Error?) -> Void)? = nil) {
        launch(applicationURL, arguments: configuration.arguments + urls.map { $0.isFileURL ? $0.path : $0.absoluteString },
               completionHandler: completionHandler)
    }

    private func launch(_ app: URL, arguments: [String], completionHandler: ((NSRunningApplication?, Error?) -> Void)?) {
        let p = Process()
        if app.pathExtension == "desktop" {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["gtk-launch", app.deletingPathExtension().lastPathComponent] + arguments
        } else {
            p.executableURL = app
            p.arguments = arguments
        }
        do {
            try p.run()
            completionHandler?(NSRunningApplication(processIdentifier: p.processIdentifier), nil)
        } catch {
            completionHandler?(nil, error)
        }
    }

    @discardableResult
    public func launchApplication(_ appName: String) -> Bool {
        guard let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":")
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent(appName) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return false }
        launch(path, arguments: [], completionHandler: nil)
        return true
    }

    public func urlsForApplications(toOpen url: URL) -> [URL] { urlForApplication(toOpen: url).map { [$0] } ?? [] }
    public func urlsForApplications(withBundleIdentifier id: String) -> [URL] { urlForApplication(withBundleIdentifier: id).map { [$0] } ?? [] }
    public func fullPath(forApplication appName: String) -> String? { nil }
    public func absolutePathForApplication(withBundleIdentifier id: String) -> String? { nil }
    public func isFilePackage(atPath fullPath: String) -> Bool { false }
    public func hideOtherApplications() {}
    public func setIcon(_ image: NSImage?, forFile fullPath: String, options: Int = 0) -> Bool { false }
    public func type(ofFile absoluteFilePath: String) throws -> String {
        UTType(filenameExtension: (absoluteFilePath as NSString).pathExtension)?.identifier ?? UTType.data.identifier
    }
    public func localizedDescription(forType typeName: String) -> String? { UTType(typeName)?.localizedDescription }
    public func requestAuthorization(to type: Int, completionHandler: @escaping (Any?, Error?) -> Void) {
        completionHandler(nil, CocoaError(.featureUnsupported))
    }
}

extension NSWorkspace.OpenConfiguration {
    private static var argumentsByConfig: [ObjectIdentifier: [String]] = [:]
    private static let lock = NSLock()
    /// Arguments passed to the launched app.
    public var arguments: [String] {
        get { Self.lock.withLock { Self.argumentsByConfig[ObjectIdentifier(self)] ?? [] } }
        set { Self.lock.withLock { Self.argumentsByConfig[ObjectIdentifier(self)] = newValue } }
    }
    public var addsToRecentItems: Bool { get { true } set {} }
    public var hides: Bool { get { false } set {} }
    public var hidesOthers: Bool { get { false } set {} }
    public var createsNewApplicationInstance: Bool { get { false } set {} }
    public var allowsRunningApplicationSubstitution: Bool { get { true } set {} }
    public var environment: [String: String] { get { [:] } set {} }
    public var requiresUniversalLinks: Bool { get { false } set {} }
    public var isForPrinting: Bool { get { false } set {} }
}

// MARK: Pasteboard items

extension NSPasteboard {
    /// The pasteboard's contents as one item per type group (one item here:
    /// the clipboard holds a single item on Linux and Windows).
    public var pasteboardItems: [NSPasteboardItem]? {
        guard let types, !types.isEmpty else { return [] }
        let item = NSPasteboardItem()
        for t in types {
            if let s = string(forType: t) { item.setString(s, forType: t) } else if let d = data(forType: t) { item.setData(d, forType: t) }
        }
        return [item]
    }
    @discardableResult public func addTypes(_ newTypes: [PasteboardType], owner newOwner: Any?) -> Int { changeCount }
    @discardableResult public func setPropertyList(_ plist: Any, forType dataType: PasteboardType) -> Bool {
        if let s = plist as? String { return setString(s, forType: dataType) }
        guard let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return false }
        return setData(d, forType: dataType)
    }
}

extension NSPasteboard.PasteboardType {
    public static let color = Self("com.apple.cocoa.pasteboard.color")
    public static let font = Self("com.apple.cocoa.pasteboard.character-formatting")
    public static let ruler = Self("com.apple.cocoa.pasteboard.paragraph-formatting")
    public static let sound = Self("com.apple.cocoa.pasteboard.sound")
    public static let tabularText = Self("public.utf8-tab-separated-values-text")
    public static let multipleTextSelection = Self("com.apple.cocoa.pasteboard.multiple-text-selection")
    public static let findPanelSearchOptions = Self("com.apple.cocoa.pasteboard.find-panel-search-options")
    public static let textFinderOptions = Self("com.apple.cocoa.pasteboard.find-panel-search-options")
    public static let rtfd = Self("com.apple.flat-rtfd")
    public static let fileContents = Self("com.apple.pasteboard.fileContents")
    public static let URLName = Self("public.url-name")
    public static let filenames = Self("NSFilenamesPboardType")
}

// MARK: Gesture recognizers

public protocol NSGestureRecognizerDelegate: AnyObject {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: Any) -> Bool
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool
}

extension NSGestureRecognizerDelegate {
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool { true }
    public func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer) -> Bool { false }
    public func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool { true }
    public func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldReceive touch: Any) -> Bool { true }
    public func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool { false }
}

@preconcurrency @MainActor
open class NSGestureRecognizer: NSObject {
    public enum State: Int, Sendable { case possible, began, changed, ended, cancelled, failed
        public static let recognized = State.ended
    }
    open weak var target: AnyObject?
    open var action: Selector?
    open weak var delegate: NSGestureRecognizerDelegate?
    open var isEnabled = true
    open internal(set) var state: State = .possible
    open internal(set) weak var view: NSView?
    open var delaysPrimaryMouseButtonEvents = false
    open var delaysSecondaryMouseButtonEvents = false
    open var delaysOtherMouseButtonEvents = false
    open var delaysKeyEvents = false
    open var allowedTouchTypes: Int = 0
    var lastLocation: NSPoint = .zero

    public init(target: AnyObject?, action: Selector?) {
        self.target = target
        self.action = action
        super.init()
    }
    public override convenience init() { self.init(target: nil, action: nil) }

    open func location(in view: NSView?) -> NSPoint {
        guard let own = self.view else { return lastLocation }
        return view?.convert(lastLocation, from: own) ?? own.convert(lastLocation, to: nil)
    }
    open func reset() {}
    open func canPrevent(_ other: NSGestureRecognizer) -> Bool { true }
    open func canBePrevented(by other: NSGestureRecognizer) -> Bool { true }
    open func shouldRequireFailure(of other: NSGestureRecognizer) -> Bool { false }
    open func shouldBeRequiredToFail(by other: NSGestureRecognizer) -> Bool { false }

    /// Runs the action (target/action as an NSControl's does).
    func fire() {
        guard let action else { return }
        _ = NSApp.sendAction(action, to: target, from: self)
    }

    /// Whether this recognizer takes `event` on its view; returns true if it fired.
    func handleMouseUp(_ event: NSEvent, in view: NSView) -> Bool { false }
}

open class NSClickGestureRecognizer: NSGestureRecognizer {
    open var buttonMask: Int = 1
    open var numberOfClicksRequired = 1
    open var numberOfTouchesRequired = 1

    override func handleMouseUp(_ event: NSEvent, in view: NSView) -> Bool {
        let button = event.type == .leftMouseUp ? 0 : event.type == .rightMouseUp ? 1 : 2
        guard buttonMask & (1 << button) != 0, event.clickCount == numberOfClicksRequired else { return false }
        guard delegate?.gestureRecognizerShouldBegin(self) ?? true else { return false }
        lastLocation = view.convert(event.locationInWindow, from: nil)
        state = .ended
        fire()
        state = .possible
        reset()
        return true
    }
}

open class NSPanGestureRecognizer: NSGestureRecognizer {
    open var buttonMask: Int = 1
    open var numberOfTouchesRequired = 1
    open func translation(in view: NSView?) -> NSPoint { .zero }
    open func setTranslation(_ translation: NSPoint, in view: NSView?) {}
    open func velocity(in view: NSView?) -> NSPoint { .zero }
}

open class NSPressGestureRecognizer: NSGestureRecognizer {
    open var buttonMask: Int = 1
    open var minimumPressDuration: TimeInterval = 0.5
    open var allowableMovement: CGFloat = 10
    open var numberOfTouchesRequired = 1
}

open class NSMagnificationGestureRecognizer: NSGestureRecognizer {
    open var magnification: CGFloat = 0
}

open class NSRotationGestureRecognizer: NSGestureRecognizer {
    open var rotation: CGFloat = 0
    open var rotationInDegrees: CGFloat { get { rotation * 180 / .pi } set { rotation = newValue * .pi / 180 } }
}

@MainActor enum GestureRecognizers {
    struct Entry { weak var view: NSView?; var recognizers: [NSGestureRecognizer] }
    static var byView: [ObjectIdentifier: Entry] = [:]

    static func of(_ view: NSView) -> [NSGestureRecognizer] {
        guard let e = byView[ObjectIdentifier(view)], e.view === view else { return [] }
        return e.recognizers
    }
    static func set(_ list: [NSGestureRecognizer], on view: NSView) {
        byView = byView.filter { $0.value.view != nil }
        byView[ObjectIdentifier(view)] = Entry(view: view, recognizers: list)
        for r in list { r.view = view }
    }

    /// Called as a mouse button comes up over `view`: the nearest enabled
    /// click recognizer on it or its superviews runs its action.
    static func mouseUp(_ event: NSEvent, over view: NSView) {
        guard !byView.isEmpty else { return }
        var v: NSView? = view
        while let cur = v {
            for r in of(cur) where r.isEnabled && r.handleMouseUp(event, in: cur) { return }
            v = cur.superview
        }
    }
}

extension NSView {
    public var gestureRecognizers: [NSGestureRecognizer] {
        get { GestureRecognizers.of(self) }
        set { GestureRecognizers.set(newValue, on: self) }
    }
    public func addGestureRecognizer(_ gestureRecognizer: NSGestureRecognizer) {
        GestureRecognizers.set(GestureRecognizers.of(self) + [gestureRecognizer], on: self)
    }
    public func removeGestureRecognizer(_ gestureRecognizer: NSGestureRecognizer) {
        GestureRecognizers.set(GestureRecognizers.of(self).filter { $0 !== gestureRecognizer }, on: self)
        gestureRecognizer.view = nil
    }
}

// MARK: Sharing

public protocol NSSharingServiceDelegate: AnyObject {
    func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any])
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error)
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any])
}
extension NSSharingServiceDelegate {
    public func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {}
    public func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {}
    public func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {}
}

/// Sharing on Linux: "Copy" (to the clipboard) and e-mail (a mailto: link
/// through the default mail client); the Mac's other services don't exist.
@preconcurrency @MainActor
open class NSSharingService: NSObject {
    public struct Name: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let composeEmail = Name("com.apple.share.Mail.compose")
        public static let composeMessage = Name("com.apple.share.Messages.compose")
        public static let sendViaAirDrop = Name("com.apple.share.AirDrop.send")
        public static let addToSafariReadingList = Name("com.apple.share.System.add-to-safari-reading-list")
        public static let addToIPhoto = Name("com.apple.share.System.add-to-iphoto")
        public static let addToAperture = Name("com.apple.share.System.add-to-aperture")
        public static let useAsDesktopPicture = Name("com.apple.share.System.set-desktop-image")
        public static let cloudSharing = Name("com.apple.share.CloudSharing")
        public static let copyToPasteboard = Name("com.apple.share.Copy")
    }
    public let name: Name
    open var title: String
    open var image: NSImage
    open var alternateImage: NSImage?
    open weak var delegate: NSSharingServiceDelegate?
    open var recipients: [String]?
    open var subject: String?
    open var menuItemTitle: String
    open var accountName: String?
    open var messageBody: String?
    open var permanentLink: URL?
    open var attachmentFileURLs: [URL]?

    public init?(named serviceName: Name) {
        guard [Name.composeEmail, .copyToPasteboard].contains(serviceName) else { return nil }
        name = serviceName
        title = serviceName == .composeEmail ? "Mail" : "Copy"
        menuItemTitle = title
        image = NSImage(systemSymbolName: serviceName == .composeEmail ? "envelope" : "doc.on.doc", accessibilityDescription: title)!
        super.init()
    }
    public init(title: String, image: NSImage, alternateImage: NSImage?, handler: @escaping () -> Void) {
        name = Name("custom")
        self.title = title
        menuItemTitle = title
        self.image = image
        self.alternateImage = alternateImage
        self.handler = handler
        super.init()
    }
    var handler: (() -> Void)?

    open class func sharingServices(forItems items: [Any]) -> [NSSharingService] {
        [NSSharingService(named: .copyToPasteboard), NSSharingService(named: .composeEmail)].compactMap { $0 }
    }

    open func canPerform(withItems items: [Any]?) -> Bool { true }

    open func perform(withItems items: [Any]) {
        delegate?.sharingService(self, willShareItems: items)
        if let handler { handler(); delegate?.sharingService(self, didShareItems: items); return }
        let text = items.map { item -> String in
            if let u = item as? URL { return u.isFileURL ? u.path : u.absoluteString }
            if let a = item as? NSAttributedString { return a.string }
            return "\(item)"
        }.joined(separator: "\n")
        switch name {
        case .copyToPasteboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .composeEmail:
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = (recipients ?? []).joined(separator: ",")
            c.queryItems = [URLQueryItem(name: "subject", value: subject ?? ""), URLQueryItem(name: "body", value: text)]
            if let u = c.url { NSWorkspace.shared.open(u) }
        default:
            delegate?.sharingService(self, didFailToShareItems: items, error: CocoaError(.featureUnsupported))
            return
        }
        delegate?.sharingService(self, didShareItems: items)
    }
}

public protocol NSSharingServicePickerDelegate: AnyObject {
    func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService]
    func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate?
    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?)
}
extension NSSharingServicePickerDelegate {
    public func sharingServicePicker(_ picker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices proposed: [NSSharingService]) -> [NSSharingService] { proposed }
    public func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { nil }
    public func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {}
}

/// The share menu: the available services as a pop-up menu.
@preconcurrency @MainActor
open class NSSharingServicePicker: NSObject {
    let items: [Any]
    open weak var delegate: NSSharingServicePickerDelegate?
    public init(items: [Any]) { self.items = items; super.init() }

    open var standardShareMenuItem: NSMenuItem {
        let item = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        item.submenu = menu()
        return item
    }

    func services() -> [NSSharingService] {
        let proposed = NSSharingService.sharingServices(forItems: items)
        return delegate?.sharingServicePicker(self, sharingServicesForItems: items, proposedSharingServices: proposed) ?? proposed
    }

    func menu() -> NSMenu {
        let menu = NSMenu(title: "Share")
        for s in services() {
            let item = NSMenuItem(title: s.menuItemTitle, action: nil, keyEquivalent: "")
            item.representedObject = s
            item.handler = { [weak self] in self?.choose($0) }
            menu.addItem(item)
        }
        return menu
    }

    func choose(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? NSSharingService else { return }
        if let d = delegate?.sharingServicePicker(self, delegateFor: s) { s.delegate = d }
        delegate?.sharingServicePicker(self, didChoose: s)
        s.perform(withItems: items)
    }

    open func show(relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge) {
        menu().popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY), in: view)
    }
    open func close() {}
}

// MARK: Haptics

public protocol NSHapticFeedbackPerformer: AnyObject {
    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern, performanceTime: NSHapticFeedbackManager.PerformanceTime)
}

/// No Force Touch trackpads off the Mac: feedback is accepted and dropped.
public final class NSHapticFeedbackManager: NSObject, @unchecked Sendable {
    public enum FeedbackPattern: Int, Sendable { case generic, alignment, levelChange }
    public enum PerformanceTime: UInt, Sendable { case `default`, now, drawCompleted }
    final class Performer: NSObject, NSHapticFeedbackPerformer {
        func perform(_ pattern: FeedbackPattern, performanceTime: PerformanceTime) {}
    }
    public static var defaultPerformer: NSHapticFeedbackPerformer { Performer() }
}

// MARK: Accessibility attributes and actions

extension NSAccessibility {
    public struct Attribute: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let role = Attribute("AXRole")
        public static let subrole = Attribute("AXSubrole")
        public static let roleDescription = Attribute("AXRoleDescription")
        public static let title = Attribute("AXTitle")
        public static let value = Attribute("AXValue")
        public static let valueDescription = Attribute("AXValueDescription")
        public static let description = Attribute("AXDescription")
        public static let help = Attribute("AXHelp")
        public static let identifier = Attribute("AXIdentifier")
        public static let children = Attribute("AXChildren")
        public static let parent = Attribute("AXParent")
        public static let windows = Attribute("AXWindows")
        public static let mainWindow = Attribute("AXMainWindow")
        public static let focusedWindow = Attribute("AXFocusedWindow")
        public static let focusedUIElement = Attribute("AXFocusedUIElement")
        public static let position = Attribute("AXPosition")
        public static let size = Attribute("AXSize")
        public static let frame = Attribute("AXFrame")
        public static let minimized = Attribute("AXMinimized")
        public static let main = Attribute("AXMain")
        public static let focused = Attribute("AXFocused")
        public static let enabled = Attribute("AXEnabled")
        public static let hidden = Attribute("AXHidden")
        public static let modal = Attribute("AXModal")
        public static let closeButton = Attribute("AXCloseButton")
        public static let zoomButton = Attribute("AXZoomButton")
        public static let minimizeButton = Attribute("AXMinimizeButton")
        public static let fullScreenButton = Attribute("AXFullScreenButton")
        public static let menuBar = Attribute("AXMenuBar")
        public static let extrasMenuBar = Attribute("AXExtrasMenuBar")
        public static let selectedText = Attribute("AXSelectedText")
        public static let selectedTextRange = Attribute("AXSelectedTextRange")
        public static let numberOfCharacters = Attribute("AXNumberOfCharacters")
        public static let visibleCharacterRange = Attribute("AXVisibleCharacterRange")
        public static let selectedChildren = Attribute("AXSelectedChildren")
        public static let visibleChildren = Attribute("AXVisibleChildren")
        public static let contents = Attribute("AXContents")
        public static let document = Attribute("AXDocument")
        public static let url = Attribute("AXURL")
        public static let topLevelUIElement = Attribute("AXTopLevelUIElement")
        public static let window = Attribute("AXWindow")
        public static let rows = Attribute("AXRows")
        public static let columns = Attribute("AXColumns")
        public static let selectedRows = Attribute("AXSelectedRows")
        public static let isApplicationRunning = Attribute("AXIsApplicationRunning")
        public static let frontmost = Attribute("AXFrontmost")
        public static let minimumSize = Attribute("AXMinimumSize")
        public static let maximumSize = Attribute("AXMaximumSize")
        public static let label = Attribute("AXLabel")
        public static let placeholderValue = Attribute("AXPlaceholderValue")
        public static let menuItemCmdChar = Attribute("AXMenuItemCmdChar")
        public static let menuItemCmdModifiers = Attribute("AXMenuItemCmdModifiers")
        public static let menuItemCmdVirtualKey = Attribute("AXMenuItemCmdVirtualKey")
        public static let menuItemMarkChar = Attribute("AXMenuItemMarkChar")
        public static let menuItemPrimaryUIElement = Attribute("AXMenuItemPrimaryUIElement")
        public static let defaultButton = Attribute("AXDefaultButton")
        public static let cancelButton = Attribute("AXCancelButton")
        public static let toolbarButton = Attribute("AXToolbarButton")
        public static let proxy = Attribute("AXProxy")
        public static let growArea = Attribute("AXGrowArea")
        public static let sharedFocusElements = Attribute("AXSharedFocusElements")
        public static let focusedApplication = Attribute("AXFocusedApplication")
        public static let orientation = Attribute("AXOrientation")
        public static let index = Attribute("AXIndex")
        public static let expanded = Attribute("AXExpanded")
        public static let selected = Attribute("AXSelected")
    }
    public struct Action: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let press = Action("AXPress")
        public static let increment = Action("AXIncrement")
        public static let decrement = Action("AXDecrement")
        public static let confirm = Action("AXConfirm")
        public static let cancel = Action("AXCancel")
        public static let raise = Action("AXRaise")
        public static let showMenu = Action("AXShowMenu")
        public static let pick = Action("AXPick")
        public static let showAlternateUI = Action("AXShowAlternateUI")
        public static let showDefaultUI = Action("AXShowDefaultUI")
        public static let delete = Action("AXDelete")
    }
    public struct ParameterizedAttribute: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public static let stringForRange = ParameterizedAttribute("AXStringForRange")
        public static let boundsForRange = ParameterizedAttribute("AXBoundsForRange")
        public static let lineForIndex = ParameterizedAttribute("AXLineForIndex")
        public static let rangeForLine = ParameterizedAttribute("AXRangeForLine")
    }
}

extension NSApplication {
    public typealias ActivationOptions = NSRunningApplication.ActivationOptions
}

extension NSColor {
    public static let selectedControlColor = NSColor.selectedContentBackgroundColor
    public static let selectedControlTextColor = NSColor.textColor
    public static let alternateSelectedControlTextColor = NSColor.white
    public static let selectedMenuItemTextColor = NSColor.white
    public static let scrubberTexturedBackground = NSColor.windowBackgroundColor
    public static let windowFrameTextColor = NSColor.textColor
    public static let knobColor = NSColor.controlColor
    public static let selectedKnobColor = NSColor.controlAccentColor
    public static let scrollBarColor = NSColor.controlColor
    public static let highlightColor = NSColor.white
}

extension NSControl {
    /// Draws the control highlighted (pressed) or not.
    public func highlight(_ flag: Bool) {
        isHighlighted = flag
        needsDisplay = true
    }
}

extension NSEvent.SpecialKey {
    public static let f13 = NSEvent.SpecialKey(rawValue: NSF13FunctionKey)
    public static let f14 = NSEvent.SpecialKey(rawValue: NSF14FunctionKey)
    public static let f15 = NSEvent.SpecialKey(rawValue: NSF15FunctionKey)
    public static let f16 = NSEvent.SpecialKey(rawValue: NSF16FunctionKey)
    public static let f17 = NSEvent.SpecialKey(rawValue: NSF17FunctionKey)
    public static let f18 = NSEvent.SpecialKey(rawValue: NSF18FunctionKey)
    public static let f19 = NSEvent.SpecialKey(rawValue: NSF19FunctionKey)
    public static let f20 = NSEvent.SpecialKey(rawValue: NSF20FunctionKey)
    public static let f21 = NSEvent.SpecialKey(rawValue: NSF21FunctionKey)
    public static let f22 = NSEvent.SpecialKey(rawValue: NSF22FunctionKey)
    public static let f23 = NSEvent.SpecialKey(rawValue: NSF23FunctionKey)
    public static let f24 = NSEvent.SpecialKey(rawValue: NSF24FunctionKey)
    public static let f25 = NSEvent.SpecialKey(rawValue: NSF25FunctionKey)
    public static let f26 = NSEvent.SpecialKey(rawValue: NSF26FunctionKey)
    public static let f27 = NSEvent.SpecialKey(rawValue: NSF27FunctionKey)
    public static let f28 = NSEvent.SpecialKey(rawValue: NSF28FunctionKey)
    public static let f29 = NSEvent.SpecialKey(rawValue: NSF29FunctionKey)
    public static let f30 = NSEvent.SpecialKey(rawValue: NSF30FunctionKey)
    public static let f31 = NSEvent.SpecialKey(rawValue: NSF31FunctionKey)
    public static let f32 = NSEvent.SpecialKey(rawValue: NSF32FunctionKey)
    public static let f33 = NSEvent.SpecialKey(rawValue: NSF33FunctionKey)
    public static let f34 = NSEvent.SpecialKey(rawValue: NSF34FunctionKey)
    public static let f35 = NSEvent.SpecialKey(rawValue: NSF35FunctionKey)
}

/// The child index an outline view drop proposes when dropping onto an item.
public let NSOutlineViewDropOnItemIndex: Int = -1


// MARK: Asset catalog colours

extension NSColor {
    /// A colour set of the app's asset catalogs, following light and dark.
    public convenience init?(named name: NSColor.Name, bundle: Bundle? = nil) {
        guard let c = RunwayAssets.color(named: name) else { return nil }
        let light = RGBA(c.light.red, c.light.green, c.light.blue, c.light.alpha), dark = RGBA(c.dark.red, c.dark.green, c.dark.blue, c.dark.alpha)
        if light == dark { self.init(rgba: light) }
        else { self.init(name: name) { ap in NSColor(rgba: ap.isDark ? dark : light) } }
    }
}


// MARK: More image API

extension NSImage {
    public static let applicationIconName = NSImage.Name("NSApplicationIcon")
    public static let cautionName = NSImage.Name("NSCaution")
    public static let infoName = NSImage.Name("NSInfo")
    public static let folderName = NSImage.Name("NSFolder")
    public static let userName = NSImage.Name("NSUser")
    public static let actionTemplateName = NSImage.Name("NSActionTemplate")
    public static let addTemplateName = NSImage.Name("NSAddTemplate")
    public static let removeTemplateName = NSImage.Name("NSRemoveTemplate")
    public static let refreshTemplateName = NSImage.Name("NSRefreshTemplate")
    public static let stopProgressTemplateName = NSImage.Name("NSStopProgressTemplate")
    public static let shareTemplateName = NSImage.Name("NSShareTemplate")
    public static let lockLockedTemplateName = NSImage.Name("NSLockLockedTemplate")
    public static let lockUnlockedTemplateName = NSImage.Name("NSLockUnlockedTemplate")
    public static let goLeftTemplateName = NSImage.Name("NSGoLeftTemplate")
    public static let goRightTemplateName = NSImage.Name("NSGoRightTemplate")
    public static let statusAvailableName = NSImage.Name("NSStatusAvailable")
    public static let statusUnavailableName = NSImage.Name("NSStatusUnavailable")
    public static let statusPartiallyAvailableName = NSImage.Name("NSStatusPartiallyAvailable")
    public static let statusNoneName = NSImage.Name("NSStatusNone")
    public static let preferencesGeneralName = NSImage.Name("NSPreferencesGeneral")
    public static let advancedName = NSImage.Name("NSAdvanced")
    public static let networkName = NSImage.Name("NSNetwork")
    public static let computerName = NSImage.Name("NSComputer")
    public static let quickLookTemplateName = NSImage.Name("NSQuickLookTemplate")
    public static let revealFreestandingTemplateName = NSImage.Name("NSRevealFreestandingTemplate")
    public static let followLinkFreestandingTemplateName = NSImage.Name("NSFollowLinkFreestandingTemplate")
    public static let invalidDataFreestandingTemplateName = NSImage.Name("NSInvalidDataFreestandingTemplate")
    public static let multipleDocumentsName = NSImage.Name("NSMultipleDocuments")
    public static let trashEmptyName = NSImage.Name("NSTrashEmpty")
    public static let trashFullName = NSImage.Name("NSTrashFull")
    public static let bonjourName = NSImage.Name("NSBonjour")
    public static let colorPanelName = NSImage.Name("NSColorPanel")
    public static let listViewTemplateName = NSImage.Name("NSListViewTemplate")
    public static let iconViewTemplateName = NSImage.Name("NSIconViewTemplate")
    public static let columnViewTemplateName = NSImage.Name("NSColumnViewTemplate")
    public static let menuOnStateTemplateName = NSImage.Name("NSMenuOnStateTemplate")
    public static let menuMixedStateTemplateName = NSImage.Name("NSMenuMixedStateTemplate")
    public static let userAccountsName = NSImage.Name("NSUserAccounts")
    public static let everyoneName = NSImage.Name("NSEveryone")
    public static let userGroupName = NSImage.Name("NSUserGroup")
    public static let touchBarAddTemplateName = NSImage.Name("NSTouchBarAddTemplate")
    public static let touchBarIconViewTemplateName = NSImage.Name("NSTouchBarIconViewTemplate")
    public static let touchBarListViewTemplateName = NSImage.Name("NSTouchBarListViewTemplate")
    public static let touchBarComposeTemplateName = NSImage.Name("NSTouchBarComposeTemplate")
    public static let touchBarDeleteTemplateName = NSImage.Name("NSTouchBarDeleteTemplate")
    public static let touchBarSearchTemplateName = NSImage.Name("NSTouchBarSearchTemplate")
    public static let smartBadgeTemplateName = NSImage.Name("NSSmartBadgeTemplate")
    public static let bookmarksTemplateName = NSImage.Name("NSBookmarksTemplate")
    public static let homeTemplateName = NSImage.Name("NSHomeTemplate")
    public static let leftFacingTriangleTemplateName = NSImage.Name("NSLeftFacingTriangleTemplate")
    public static let rightFacingTriangleTemplateName = NSImage.Name("NSRightFacingTriangleTemplate")

    /// `#imageLiteral(resourceName:)` and `NSImage(imageLiteralResourceName:)`:
    /// the named image, or an empty one when the app has none by that name.
    public convenience init(imageLiteralResourceName name: String) {
        if let found = RunwayAssets.resolveImage(named: name, scale: 2), FileManager.default.fileExists(atPath: found.path) {
            self.init(contentsOf: URL(fileURLWithPath: found.path))!
            isTemplate = found.template
            if found.scale > 1 { size = CGSize(width: size.width / CGFloat(found.scale), height: size.height / CGFloat(found.scale)) }
        } else {
            self.init(size: .zero)
        }
    }

    public enum ResizingMode: Int, Sendable { case tile = 0, stretch }
    /// Nine-part resizing: kept for code that sets them (images are drawn stretched).
    public var capInsets: NSEdgeInsets {
        get { NSImage._capInsets[ObjectIdentifier(self)] ?? NSEdgeInsets() }
        set { NSImage._capInsets[ObjectIdentifier(self)] = newValue }
    }
    public var resizingMode: ResizingMode {
        get { NSImage._resizingModes[ObjectIdentifier(self)] ?? .stretch }
        set { NSImage._resizingModes[ObjectIdentifier(self)] = newValue }
    }
    nonisolated(unsafe) private static var _capInsets: [ObjectIdentifier: NSEdgeInsets] = [:]
    nonisolated(unsafe) private static var _resizingModes: [ObjectIdentifier: ResizingMode] = [:]
}

extension NSValue {
    public convenience init(caTransform3D t: CATransform3D) {
        var copy = t
        self.init(bytes: &copy, objCType: "{CATransform3D=dddddddddddddddd}")
    }
    public var caTransform3DValue: CATransform3D {
        var t = CATransform3DIdentity
        getValue(&t)
        return t
    }
}


// MARK: Display links (macOS 14)

extension NSScreen {
    /// A display link calling `selector` on `target` each frame.
    public func displayLink(target: Any, selector: Selector) -> CADisplayLink {
        let object = target as AnyObject
        return CADisplayLink(_runwayHandler: { [weak object] link in
            guard let object else { return }
            _ = RunwayObjC.perform(object, selector, [link])
        })
    }
}
extension NSWindow {
    public func displayLink(target: Any, selector: Selector) -> CADisplayLink { (screen ?? NSScreen.screens[0]).displayLink(target: target, selector: selector) }
}
extension NSView {
    public func displayLink(target: Any, selector: Selector) -> CADisplayLink { NSScreen.screens[0].displayLink(target: target, selector: selector) }
}

// MARK: Events from Core Graphics events

extension NSEvent {
    /// The AppKit event for a Core Graphics event (event taps hand these out).
    public convenience init?(cgEvent: CGEvent) {
        let type: NSEvent.EventType
        switch cgEvent.type {
        case .keyDown: type = .keyDown
        case .keyUp: type = .keyUp
        case .flagsChanged: type = .flagsChanged
        case .leftMouseDown: type = .leftMouseDown
        case .leftMouseUp: type = .leftMouseUp
        case .rightMouseDown: type = .rightMouseDown
        case .rightMouseUp: type = .rightMouseUp
        case .mouseMoved: type = .mouseMoved
        case .leftMouseDragged: type = .leftMouseDragged
        case .rightMouseDragged: type = .rightMouseDragged
        case .scrollWheel: type = .scrollWheel
        case .otherMouseDown: type = .otherMouseDown
        case .otherMouseUp: type = .otherMouseUp
        case .otherMouseDragged: type = .otherMouseDragged
        default: type = .systemDefined
        }
        self.init(type: type, location: cgEvent.location, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(cgEvent.flags.rawValue)),
                  timestamp: TimeInterval(cgEvent.timestamp) / 1e9, window: nil,
                  buttonNumber: Int(cgEvent.getIntegerValueField(.mouseEventButtonNumber)),
                  keyCode: UInt16(truncatingIfNeeded: cgEvent.getIntegerValueField(.keyboardEventKeycode)),
                  scrollingDelta: CGSize(width: CGFloat(cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2)), height: CGFloat(cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1))))
        _cgEvent = cgEvent
    }
}


extension NSWindow {
    /// Whether the user is resizing the window now (resizes aren't tracked live here).
    public var inLiveResize: Bool { false }
}


// MARK: NSAffineTransform in the current graphics context

extension NSAffineTransform {
    private var cgTransform: CGAffineTransform {
        let t = transformStruct
        return CGAffineTransform(a: t.m11, b: t.m12, c: t.m21, d: t.m22, tx: t.tX, ty: t.tY)
    }
    /// Appends the transform to the current context's.
    public func concat() { NSGraphicsContext.current?.cgContext.concatenate(cgTransform) }
    /// Replaces the current context's transform.
    public func set() {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.concatenate(c.ctm.inverted())
        c.concatenate(cgTransform)
    }
}


extension NSWindow {
    /// The window's colour space (everything is sRGB here; setting it is accepted).
    public var colorSpace: NSColorSpace? {
        get { .sRGB }
        set {}
    }
}

public enum NSAccessibilityPriorityLevel: Int, Sendable { case low = 10, medium = 50, high = 90 }


// MARK: Menu item images (macOS 26), bindings options, image caches

extension NSMenuItem {
    public enum ImageVisibility: Int, Sendable { case automatic = 0, visible, hidden }
    /// Whether the item shows its image (images are always shown here).
    public var preferredImageVisibility: ImageVisibility {
        get { .automatic }
        set {}
    }
}

public struct NSBindingOption: RawRepresentable, Hashable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let allowsEditingMultipleValuesSelection = NSBindingOption("NSAllowsEditingMultipleValuesSelection")
    public static let allowsNullArgument = NSBindingOption("NSAllowsNullArgument")
    public static let alwaysPresentsApplicationModalAlerts = NSBindingOption("NSAlwaysPresentsApplicationModalAlerts")
    public static let conditionallySetsEditable = NSBindingOption("NSConditionallySetsEditable")
    public static let conditionallySetsEnabled = NSBindingOption("NSConditionallySetsEnabled")
    public static let conditionallySetsHidden = NSBindingOption("NSConditionallySetsHidden")
    public static let continuouslyUpdatesValue = NSBindingOption("NSContinuouslyUpdatesValue")
    public static let createsSortDescriptor = NSBindingOption("NSCreatesSortDescriptor")
    public static let deletesObjectsOnRemove = NSBindingOption("NSDeletesObjectsOnRemove")
    public static let displayName = NSBindingOption("NSDisplayName")
    public static let displayPattern = NSBindingOption("NSDisplayPattern")
    public static let contentPlacementTag = NSBindingOption("NSContentPlacementTag")
    public static let handlesContentAsCompoundValue = NSBindingOption("NSHandlesContentAsCompoundValue")
    public static let insertsNullPlaceholder = NSBindingOption("NSInsertsNullPlaceholder")
    public static let invokesSeparatelyWithArrayObjects = NSBindingOption("NSInvokesSeparatelyWithArrayObjects")
    public static let multipleValuesPlaceholder = NSBindingOption("NSMultipleValuesPlaceholder")
    public static let noSelectionPlaceholder = NSBindingOption("NSNoSelectionPlaceholder")
    public static let notApplicablePlaceholder = NSBindingOption("NSNotApplicablePlaceholder")
    public static let nullPlaceholder = NSBindingOption("NSNullPlaceholder")
    public static let raisesForNotApplicableKeys = NSBindingOption("NSRaisesForNotApplicableKeys")
    public static let predicateFormat = NSBindingOption("NSPredicateFormat")
    public static let selectorName = NSBindingOption("NSSelectorName")
    public static let selectsAllWhenSettingContent = NSBindingOption("NSSelectsAllWhenSettingContent")
    public static let validatesImmediately = NSBindingOption("NSValidatesImmediately")
    public static let valueTransformerName = NSBindingOption("NSValueTransformerName")
    public static let valueTransformer = NSBindingOption("NSValueTransformer")
}

extension NSImage {
    /// Drops cached representations (images here are decoded on demand).
    public func recache() {}
}
