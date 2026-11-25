// NSWindow (frame in screen coordinates, content view, first responder,
// event dispatch, tracking areas, cursor rects, drops, sheets, frame
// autosave), NSWindowController and NSScreen.

import Foundation
import RunwayCore

@preconcurrency @MainActor public protocol NSWindowDelegate: AnyObject {
    @MainActor func windowShouldClose(_ sender: NSWindow) -> Bool
    @MainActor func windowWillClose(_ notification: Notification)
    @MainActor func windowDidResize(_ notification: Notification)
    @MainActor func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize
    @MainActor func windowDidMove(_ notification: Notification)
    @MainActor func windowDidBecomeKey(_ notification: Notification)
    @MainActor func windowDidResignKey(_ notification: Notification)
    @MainActor func windowDidBecomeMain(_ notification: Notification)
    @MainActor func windowDidResignMain(_ notification: Notification)
    @MainActor func windowWillStartLiveResize(_ notification: Notification)
    @MainActor func windowDidEndLiveResize(_ notification: Notification)
    @MainActor func windowDidChangeScreen(_ notification: Notification)
    @MainActor func windowDidChangeBackingProperties(_ notification: Notification)
    @MainActor func windowDidChangeOcclusionState(_ notification: Notification)
    @MainActor func windowWillEnterFullScreen(_ notification: Notification)
    @MainActor func windowDidEnterFullScreen(_ notification: Notification)
    @MainActor func windowWillExitFullScreen(_ notification: Notification)
    @MainActor func windowDidExitFullScreen(_ notification: Notification)
    @MainActor func windowDidMiniaturize(_ notification: Notification)
    @MainActor func windowDidDeminiaturize(_ notification: Notification)
    @MainActor func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager?
    @MainActor func windowWillBeginSheet(_ notification: Notification)
    @MainActor func windowDidEndSheet(_ notification: Notification)
}

extension NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool { true }
    public func windowWillClose(_ notification: Notification) {}
    public func windowDidResize(_ notification: Notification) {}
    public func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize { frameSize }
    public func windowDidMove(_ notification: Notification) {}
    public func windowDidBecomeKey(_ notification: Notification) {}
    public func windowDidResignKey(_ notification: Notification) {}
    public func windowDidBecomeMain(_ notification: Notification) {}
    public func windowDidResignMain(_ notification: Notification) {}
    public func windowWillStartLiveResize(_ notification: Notification) {}
    public func windowDidEndLiveResize(_ notification: Notification) {}
    public func windowDidChangeScreen(_ notification: Notification) {}
    public func windowDidChangeBackingProperties(_ notification: Notification) {}
    public func windowDidChangeOcclusionState(_ notification: Notification) {}
    public func windowWillEnterFullScreen(_ notification: Notification) {}
    public func windowDidEnterFullScreen(_ notification: Notification) {}
    public func windowWillExitFullScreen(_ notification: Notification) {}
    public func windowDidExitFullScreen(_ notification: Notification) {}
    public func windowDidMiniaturize(_ notification: Notification) {}
    public func windowDidDeminiaturize(_ notification: Notification) {}
    public func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { nil }
    public func windowWillBeginSheet(_ notification: Notification) {}
    public func windowDidEndSheet(_ notification: Notification) {}
}

@preconcurrency @MainActor
open class NSWindow: NSResponder, NSAppearanceCustomization, NSUserInterfaceItemIdentification {
    public struct StyleMask: OptionSet, Sendable, Hashable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let borderless = StyleMask([])
        public static let titled = StyleMask(rawValue: 1)
        public static let closable = StyleMask(rawValue: 2)
        public static let miniaturizable = StyleMask(rawValue: 4)
        public static let resizable = StyleMask(rawValue: 8)
        public static let utilityWindow = StyleMask(rawValue: 1 << 4)
        public static let docModalWindow = StyleMask(rawValue: 1 << 6)
        public static let nonactivatingPanel = StyleMask(rawValue: 1 << 7)
        public static let unifiedTitleAndToolbar = StyleMask(rawValue: 1 << 12)
        public static let hudWindow = StyleMask(rawValue: 1 << 13)
        public static let fullScreen = StyleMask(rawValue: 1 << 14)
        public static let fullSizeContentView = StyleMask(rawValue: 1 << 15)
    }
    public enum BackingStoreType: UInt, Sendable { case retained, nonretained, buffered }
    public enum TitleVisibility: Int, Sendable { case visible, hidden }
    public enum ToolbarStyle: Int, Sendable { case automatic, expanded, preference, unified, unifiedCompact }
    public enum OrderingMode: Int, Sendable { case below = -1, out = 0, above = 1 }
    public enum TabbingMode: Int, Sendable { case automatic, preferred, disallowed }
    public enum TitlebarSeparatorStyle: Int, Sendable { case automatic, none, line, shadow }
    public enum AnimationBehavior: Int, Sendable { case `default` = 0, none = 2, documentWindow, utilityWindow, alertPanel }
    public enum ButtonType: UInt, Sendable { case closeButton, miniaturizeButton, zoomButton, toolbarButton, documentIconButton, documentVersionsButton }
    public enum SelectionDirection: UInt, Sendable { case directSelection, selectingNext, selectingPrevious }
    public struct CollectionBehavior: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let canJoinAllSpaces = CollectionBehavior(rawValue: 1)
        public static let moveToActiveSpace = CollectionBehavior(rawValue: 2)
        public static let managed = CollectionBehavior(rawValue: 4)
        public static let transient = CollectionBehavior(rawValue: 8)
        public static let stationary = CollectionBehavior(rawValue: 16)
        public static let participatesInCycle = CollectionBehavior(rawValue: 32)
        public static let ignoresCycle = CollectionBehavior(rawValue: 64)
        public static let fullScreenPrimary = CollectionBehavior(rawValue: 128)
        public static let fullScreenAuxiliary = CollectionBehavior(rawValue: 256)
        public static let fullScreenNone = CollectionBehavior(rawValue: 512)
        public static let primary = CollectionBehavior(rawValue: 1 << 16)
        public static let auxiliary = CollectionBehavior(rawValue: 1 << 17)
        public static let canJoinAllApplications = CollectionBehavior(rawValue: 1 << 18)
    }
    public struct Level: RawRepresentable, Hashable, Comparable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public init(_ rawValue: Int) { self.rawValue = rawValue }
        public static let normal = Level(0), floating = Level(3), submenu = Level(3), tornOffMenu = Level(3), modalPanel = Level(8)
        public static let mainMenu = Level(24), statusBar = Level(25), popUpMenu = Level(101), screenSaver = Level(1000)
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    public struct OcclusionState: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let visible = OcclusionState(rawValue: 1 << 1)
    }
    public typealias FrameAutosaveName = String
    public typealias PersistableFrameDescriptor = String

    public static let willCloseNotification = Notification.Name("NSWindowWillCloseNotification")
    public static let didResizeNotification = Notification.Name("NSWindowDidResizeNotification")
    public static let didMoveNotification = Notification.Name("NSWindowDidMoveNotification")
    public static let didBecomeKeyNotification = Notification.Name("NSWindowDidBecomeKeyNotification")
    public static let didResignKeyNotification = Notification.Name("NSWindowDidResignKeyNotification")
    public static let didBecomeMainNotification = Notification.Name("NSWindowDidBecomeMainNotification")
    public static let didResignMainNotification = Notification.Name("NSWindowDidResignMainNotification")
    public static let willStartLiveResizeNotification = Notification.Name("NSWindowWillStartLiveResizeNotification")
    public static let didEndLiveResizeNotification = Notification.Name("NSWindowDidEndLiveResizeNotification")
    public static let didChangeScreenNotification = Notification.Name("NSWindowDidChangeScreenNotification")
    public static let didChangeOcclusionStateNotification = Notification.Name("NSWindowDidChangeOcclusionStateNotification")
    public static let didEnterFullScreenNotification = Notification.Name("NSWindowDidEnterFullScreenNotification")
    public static let didExitFullScreenNotification = Notification.Name("NSWindowDidExitFullScreenNotification")
    public static let didMiniaturizeNotification = Notification.Name("NSWindowDidMiniaturizeNotification")
    public static let didUpdateNotification = Notification.Name("NSWindowDidUpdateNotification")

    open weak var delegate: NSWindowDelegate?
    open weak var windowController: NSWindowController? { didSet { nextResponder = windowController } }
    open var styleMask: StyleMask {
        didSet {
            native?.setResizable(styleMask.contains(.resizable))
            if (oldValue == .borderless) != (styleMask == .borderless), let n = native { viewSystem?.setDecorated(styleMask != .borderless, window: n) }
            if oldValue.contains(.fullSizeContentView) != styleMask.contains(.fullSizeContentView) || oldValue.contains(.titled) != styleMask.contains(.titled) {
                chromeDidChange()
            }
        }
    }
    open var isReleasedWhenClosed = true
    open var titleVisibility: TitleVisibility = .visible { didSet { if titleVisibility != oldValue { chromeDidChange() } } }
    open var titlebarAppearsTransparent = false { didSet { if titlebarAppearsTransparent != oldValue { chromeDidChange() } } }
    open var titlebarSeparatorStyle: TitlebarSeparatorStyle = .automatic
    open var toolbarStyle: ToolbarStyle = .automatic { didSet { if toolbarStyle != oldValue { chromeDidChange() } } }
    open var collectionBehavior: CollectionBehavior = []
    open var level: Level = .normal
    open var isMovableByWindowBackground = false
    open var isMovable = true
    open var backgroundColor: NSColor! = .windowBackgroundColor
    open var hasShadow = true
    open var isOpaque = true
    open var alphaValue: CGFloat = 1
    open var tabbingMode: TabbingMode = .automatic
    public static var allowsAutomaticWindowTabbing = false
    open var tabbingIdentifier: String = ""
    open var animationBehavior: AnimationBehavior = .default
    open var identifier: NSUserInterfaceItemIdentifier?
    open var isRestorable = false
    open var restorationClass: AnyClass?
    open var isDocumentEdited = false
    open var representedURL: URL?
    open var representedFilename: String = ""
    open var acceptsMouseMovedEvents = false
    open var ignoresMouseEvents = false
    open var hidesOnDeactivate = false
    open var canHide = true
    open var isExcludedFromWindowsMenu = false
    open var preventsApplicationTerminationWhenModal = true
    open var worksWhenModal: Bool { false }
    open var displaysWhenScreenProfileChanges = false
    open var showsResizeIndicator = true
    open var showsToolbarButton = true
    open var allowsToolTipsWhenApplicationIsInactive = false
    open var autorecalculatesKeyViewLoop = false
    open var initialFirstResponder: NSView?
    open var defaultButtonCell: AnyObject?
    open var contentAspectRatio: NSSize = .zero
    open var aspectRatio: NSSize = .zero
    open var resizeIncrements: NSSize = NSSize(width: 1, height: 1)
    open var contentResizeIncrements: NSSize = NSSize(width: 1, height: 1)
    open var isModal = false
    /// The window this one is a child of (`addChildWindow(_:ordered:)`).
    open weak var parent: NSWindow?
    open var parentWindow: NSWindow? {
        get { parent }
        set { parent = newValue }
    }
    open private(set) var childWindows: [NSWindow]? = nil
    open private(set) var isVisible = false
    open private(set) var isKeyWindow = false
    open private(set) var isMainWindow = false
    open var isMiniaturized: Bool { false }
    open var isZoomed: Bool { false }
    open var isOnActiveSpace: Bool { true }
    open var occlusionState: OcclusionState { isVisible ? .visible : [] }
    open var isSheet: Bool { sheetParent != nil }
    open private(set) weak var sheetParent: NSWindow?
    open var attachedSheet: NSWindow? { sheets.first }
    open private(set) var sheets: [NSWindow] = []
    private var sheetHandlers: [ObjectIdentifier: (NSApplication.ModalResponse) -> Void] = [:]
    /// Runway: storage for the standard controls' toolbar (NSToolbar lives
    /// with the controls; `NSWindow.toolbar` is declared there).
    open var _runwayToolbar: AnyObject?
    open var appearance: NSAppearance? { didSet { appearanceDidChange() } }
    open var effectiveAppearance: NSAppearance { appearance ?? NSApplication.shared.effectiveAppearance }
    open var appearanceSource: AnyObject?
    open var minFullScreenContentSize: NSSize = .zero
    open var maxFullScreenContentSize: NSSize = .zero
    open var subtitle: String = ""

    private static var nextNumber = 1
    public let windowNumber: Int

    private var _frame: CGRect
    var native: NativeWindow?
    /// Runway: the backend window (nil until first shown).
    open var nativeWindow: NativeWindow? { native }
    var viewSystem: ViewSystemBackend? { Runway.backend as? ViewSystemBackend }

    open var title: String = "" { didSet { native?.title = title; toolbar?.strip?.relayout(); KVO.didChange(self, "title", old: oldValue, new: title) } }
    open var miniwindowTitle: String { title }
    open func setTitleWithRepresentedFilename(_ filename: String) { title = (filename as NSString).lastPathComponent; representedFilename = filename }

    // MARK: Geometry

    /// The title bar's height in frame math (as on the Mac).
    static let titlebarHeight: CGFloat = 28
    open class func frameRect(forContentRect r: NSRect, styleMask: StyleMask) -> NSRect {
        guard styleMask.contains(.titled), !styleMask.contains(.fullSizeContentView) else { return r }
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + titlebarHeight)
    }
    open class func contentRect(forFrameRect r: NSRect, styleMask: StyleMask) -> NSRect {
        guard styleMask.contains(.titled), !styleMask.contains(.fullSizeContentView) else { return r }
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: max(0, r.height - titlebarHeight))
    }
    /// A toolbar band above content that isn't full-size is part of the frame.
    open func frameRect(forContentRect r: NSRect) -> NSRect {
        let f = Self.frameRect(forContentRect: r, styleMask: styleMask)
        return CGRect(x: f.minX, y: f.minY, width: f.width, height: f.height + chromeAbove)
    }
    open func contentRect(forFrameRect r: NSRect) -> NSRect {
        let c = Self.contentRect(forFrameRect: r, styleMask: styleMask)
        return CGRect(x: c.minX, y: c.minY, width: c.width, height: max(0, c.height - chromeAbove))
    }

    /// The window's frame in screen coordinates (y-up, title bar included).
    open var frame: NSRect { _frame }
    var contentSize: CGSize { contentRect(forFrameRect: _frame).size }
    /// The content area the titlebar doesn't cover (full-size content runs
    /// under the toolbar band).
    open var contentLayoutRect: NSRect {
        let s = contentSize
        return CGRect(x: 0, y: 0, width: s.width, height: max(0, s.height - titlebarInset))
    }
    open var contentLayoutGuide: AnyObject? { contentView?.safeAreaLayoutGuide }
    open var minSize: NSSize = .zero { didSet { applyMinSize() } }
    open var maxSize: NSSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    open var contentMinSize: NSSize {
        get { contentRect(forFrameRect: CGRect(origin: .zero, size: minSize)).size }
        set { minSize = frameRect(forContentRect: CGRect(origin: .zero, size: newValue)).size }
    }
    open var contentMaxSize: NSSize {
        get { contentRect(forFrameRect: CGRect(origin: .zero, size: maxSize)).size }
        set { maxSize = frameRect(forContentRect: CGRect(origin: .zero, size: newValue)).size }
    }
    private var constraintMinSize: CGSize = .zero
    private func applyMinSize() {
        let m = contentMinSize
        native?.setMinimumSize(CGSize(width: max(m.width, constraintMinSize.width), height: max(m.height, constraintMinSize.height) + chromeAbove))
    }

    open var screen: NSScreen? { NSScreen.main }
    open var deepestScreen: NSScreen? { NSScreen.main }
    open var backingScaleFactor: CGFloat { screen?.backingScaleFactor ?? 1 }

    // MARK: Creating

    public init(contentRect: NSRect, styleMask style: StyleMask, backing: BackingStoreType, defer flag: Bool) {
        styleMask = style
        _frame = Self.frameRect(forContentRect: contentRect, styleMask: style)
        windowNumber = NSWindow.nextNumber
        NSWindow.nextNumber += 1
        super.init()
        AppKitRuntime.install()
        contentView = NSView(frame: CGRect(origin: .zero, size: contentRect.size))
        contentViewChanged(from: nil)   // observers don't run in init
    }
    public convenience init(contentRect: NSRect, styleMask style: StyleMask, backing: BackingStoreType, defer flag: Bool, screen: NSScreen?) {
        self.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
    }
    public convenience init(contentViewController vc: NSViewController) {
        self.init(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        // Set in an initializer, the property's didSet doesn't run: install the content here.
        contentViewController = vc
        contentViewControllerChanged(from: nil)
    }
    /// Windows aren't decoded (AppKit marks `initWithCoder:` unavailable), so
    /// subclasses with their own initializers needn't provide it.
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }

    // MARK: Content

    open var contentView: NSView? {
        didSet { contentViewChanged(from: oldValue) }
    }
    private func contentViewChanged(from oldValue: NSView?) {
        do {
            guard oldValue !== contentView else { return }
            if let old = oldValue {
                if isVisible { old.viewWillMove(toWindow: nil) }
                old.setWindowRecursively(nil)
                if isVisible { old.viewDidMoveToWindowRecursively() }
            }
            if let v = contentView {
                v.removeFromSuperview()
                v.frame = CGRect(origin: .zero, size: contentSize)
                v.autoresizingMask = [.width, .height]
                v.viewWillMove(toWindow: self)
                v.setWindowRecursively(self)
                v.viewDidMoveToWindowRecursively()
                v.appearanceMayHaveChanged()
            }
            if let fr = firstResponder as? NSView, fr.window !== self { firstResponder = self }
            attachContent()
            trackingDirty = true
            cursorRectsDirty = true
        }
    }

    open var contentViewController: NSViewController? {
        didSet { contentViewControllerChanged(from: oldValue) }
    }
    private func contentViewControllerChanged(from oldValue: NSViewController?) {
        do {
            guard let vc = contentViewController, oldValue !== vc || contentView !== vc.view else { return }
            let v = vc.view
            if let s = vc.contentSizeForWindow, s.width > 0, s.height > 0 { setContentSize(s) } else if v.frame.width > 0, v.frame.height > 0 { setContentSize(v.frame.size) }
            contentView = v
            if title.isEmpty, let t = vc.title { title = t }
        }
    }

    /// Puts the content view (below a toolbar band unless it's full-size)
    /// and the toolbar band (over the content) in the native window.
    func attachContent() {
        guard let native else { return }
        placeToolbarStrip()
        let cs = contentSize
        var children: [(NativeWidget, CGRect)] = []
        if let v = contentView { children.append((v.widget, CGRect(x: 0, y: chromeAbove, width: cs.width, height: cs.height))) }
        if let strip = shownToolbarStrip {
            children.append((strip.widget, CGRect(x: 0, y: 0, width: cs.width, height: toolbarBandHeight)))
        }
        Runway.backend.setChildren(native.content, children, contentSize: canvasSize)
    }

    // MARK: The native window

    private func ensureNative() -> NativeWindow {
        if let n = native { return n }
        let parent = (sheetParent ?? parentWindow)?.native
        let titled = styleMask.contains(.titled) && !isSheet
        let n = Runway.backend.makeWindow(WindowOptions(title: title, size: canvasSize, resizable: styleMask.contains(.resizable), modal: isModal || isSheet,
                                                        titlebar: titled ? .standard : .none), parent: parent)
        native = n
        n.onResize = { [weak self] s in self?.nativeResized(s) }
        n.onCloseRequest = { [weak self] in
            guard let self else { return true }
            if self.delegate?.windowShouldClose(self) == false { return false }
            return true
        }
        n.onClosed = { [weak self] in self?.didClose() }
        if let vs = viewSystem {
            n.onKey = { [weak self] key in
                // Hosted SwiftUI's shortcuts, when the view system handles the rest.
                guard let self, let h = self.contentView as? KeyHandling else { return false }
                return h.handleKey(key)
            }
            vs.setEventHandler(n) { [weak self] e in self?.handleRaw(e) ?? false }
            vs.setActivationHandler(n) { [weak self] active in
                guard let self else { return }
                if active { self.becomeKey() } else { self.resignKey() }
            }
            if styleMask == .borderless { vs.setDecorated(false, window: n) }
        } else {
            n.onKey = { [weak self] key in self?.handleKey(key) ?? false }
        }
        applyMinSize()
        attachContent()
        updateTitlebarTitle()
        dropTargetsChanged()
        return n
    }

    private func nativeResized(_ canvas: CGSize) {
        let old = contentSize
        let s = CGSize(width: canvas.width, height: max(0, canvas.height - chromeAbove))
        guard s != old else { return }
        let f = frameRect(forContentRect: CGRect(origin: _frame.origin, size: s))
        let oldFrame = _frame
        _frame = CGRect(x: _frame.minX, y: _frame.maxY - f.height, width: f.width, height: f.height)
        KVO.didChange(self, "frame", old: oldFrame, new: _frame)
        contentView?.frame = CGRect(origin: .zero, size: s)
        attachContent()
        layoutIfNeeded()
        saveFrameIfAutosaving()
        post(Self.didResizeNotification) { $0.windowDidResize($1) }
    }

    private func post(_ name: Notification.Name, _ call: (NSWindowDelegate, Notification) -> Void) {
        let n = Notification(name: name, object: self)
        if let d = delegate { call(d, n) }
        NotificationCenter.default.post(n)
    }

    // MARK: Showing and closing

    open func makeKeyAndOrderFront(_ sender: Any?) {
        orderFront(sender)
        makeKey()
    }
    open func orderFront(_ sender: Any?) {
        let wasVisible = isVisible
        windowController?.loadIfNeeded()
        let n = ensureNative()
        if !wasVisible {
            contentView.map { $0.viewDidMoveToWindowRecursively() }
            fitToConstraints()
            if let ifr = initialFirstResponder, firstResponder === self { _ = makeFirstResponder(ifr) }
        }
        isVisible = true
        NSApp.register(self)
        NSApp.moveToFront(self)
        if !wasVisible {
            contentViewController?.viewWillAppearRecursively()
            MenuBar.install(on: self)
        }
        // A window that can't become key (a non-activating panel) doesn't take the focus.
        if canBecomeKey { n.show() } else { n.showWithoutActivating() }
        ViewSystem.flush()
        if !wasVisible { contentViewController?.viewDidAppearRecursively() }
    }
    open func orderFrontRegardless() { orderFront(nil) }
    open func orderBack(_ sender: Any?) { orderFront(sender) }
    open func makeKey() {
        guard isVisible else { return }
        if let n = native { viewSystem?.activate(n) }
        becomeKey()
    }
    open func makeMain() { becomeMain() }
    open func order(_ place: OrderingMode, relativeTo other: Int) { if place == .out { orderOut(nil) } else { orderFront(nil) } }
    open func orderOut(_ sender: Any?) {
        guard isVisible else { return }
        close()
    }
    open var canBecomeKey: Bool { styleMask.contains(.titled) || styleMask == .borderless && false || isSheet || styleMask.contains(.titled) }
    open var canBecomeMain: Bool { styleMask.contains(.titled) && !isSheet }

    open func becomeKey() {
        guard !isKeyWindow else { return }
        if let k = NSApp._keyWindow, k !== self { k.resignKey() }
        isKeyWindow = true
        KVO.didChange(self, "keyWindow", old: false, new: true)
        KVO.didChange(self, "isKeyWindow", old: false, new: true)
        NSApp._keyWindow = self
        NSApp.moveToFront(self)
        if canBecomeMain { becomeMain() }
        post(Self.didBecomeKeyNotification) { $0.windowDidBecomeKey($1) }
        MenuBar.validateAll()
        trackingDirty = true
    }
    open func resignKey() {
        guard isKeyWindow else { return }
        isKeyWindow = false
        KVO.didChange(self, "keyWindow", old: true, new: false)
        KVO.didChange(self, "isKeyWindow", old: true, new: false)
        if NSApp._keyWindow === self { NSApp._keyWindow = nil }
        post(Self.didResignKeyNotification) { $0.windowDidResignKey($1) }
    }
    open func becomeMain() {
        guard !isMainWindow else { return }
        for w in NSApp.windows where w !== self && w.isMainWindow { w.resignMain() }
        isMainWindow = true
        post(Self.didBecomeMainNotification) { $0.windowDidBecomeMain($1) }
    }
    open func resignMain() {
        guard isMainWindow else { return }
        isMainWindow = false
        post(Self.didResignMainNotification) { $0.windowDidResignMain($1) }
    }

    open func performClose(_ sender: Any?) {
        guard styleMask.contains(.closable) || true else { NSBeep(); return }
        if let d = delegate, !d.windowShouldClose(self) { return }
        if let wc = windowController, let doc = wc.document as? NSObject, RunwayObjC.responds(doc, to: Selector("canCloseDocument")) {}
        close()
    }
    open func close() {
        guard isVisible else { return }
        if let n = native { n.close() } else { didClose() }
    }
    private func didClose() {
        guard isVisible else { return }
        contentViewController?.viewWillDisappearRecursively()
        post(Self.willCloseNotification) { $0.windowWillClose($1) }
        isVisible = false
        resignKey()
        resignMain()
        native = nil
        contentViewController?.viewDidDisappearRecursively()
        for s in sheets { s.close() }
        if let p = sheetParent { p.sheetEnded(self, .cancel) }
        NSApp.unregister(self)
    }
    open func performMiniaturize(_ sender: Any?) { miniaturize(sender) }
    open func miniaturize(_ sender: Any?) {}
    open func deminiaturize(_ sender: Any?) {}
    open func performZoom(_ sender: Any?) { zoom(sender) }
    open func zoom(_ sender: Any?) {
        guard let s = screen?.visibleFrame else { return }
        setFrame(s, display: true)
    }
    open func toggleFullScreen(_ sender: Any?) {
        if styleMask.contains(.fullScreen) { styleMask.remove(.fullScreen) } else { styleMask.insert(.fullScreen) }
    }
    open func toggleToolbarShown(_ sender: Any?) {}
    open func runToolbarCustomizationPalette(_ sender: Any?) {}
    open func center() {
        guard let s = screen?.visibleFrame else { return }
        // AppKit centres horizontally and a little above the middle.
        let x = s.midX - _frame.width / 2
        let y = s.minY + (s.height - _frame.height) * 2 / 3
        _frame.origin = CGPoint(x: x.rounded(), y: y.rounded())
        native?.center()
    }
    open func cascadeTopLeft(from p: NSPoint) -> NSPoint {
        if p == .zero { return CGPoint(x: _frame.minX, y: _frame.maxY) }
        setFrameTopLeftPoint(p)
        return CGPoint(x: p.x + 20, y: p.y - 20)
    }

    open func setFrame(_ r: NSRect, display: Bool) {
        var r = r
        r.size.width = min(max(r.width, minSize.width), maxSize.width)
        r.size.height = min(max(r.height, minSize.height), maxSize.height)
        let resized = r.size != _frame.size
        let moved = r.origin != _frame.origin
        let oldFrame = _frame
        _frame = r
        if oldFrame != r { KVO.didChange(self, "frame", old: oldFrame, new: r) }
        if resized {
            let cs = contentSize
            native?.setContentSize(canvasSize)
            contentView?.frame = CGRect(origin: .zero, size: cs)
            attachContent()
            layoutIfNeeded()
            post(Self.didResizeNotification) { $0.windowDidResize($1) }
        }
        if moved { post(Self.didMoveNotification) { $0.windowDidMove($1) } }
        saveFrameIfAutosaving()
    }
    open func setFrame(_ r: NSRect, display: Bool, animate: Bool) { setFrame(r, display: display) }
    open func setContentSize(_ s: NSSize) {
        let f = frameRect(forContentRect: CGRect(origin: .zero, size: s))
        setFrame(CGRect(x: _frame.minX, y: _frame.maxY - f.height, width: f.width, height: f.height), display: true)
    }
    open func setFrameOrigin(_ p: NSPoint) { setFrame(CGRect(origin: p, size: _frame.size), display: true) }
    open func setFrameTopLeftPoint(_ p: NSPoint) { setFrameOrigin(CGPoint(x: p.x, y: p.y - _frame.height)) }
    open func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
    open func animationResizeTime(_ r: NSRect) -> TimeInterval { 0.2 }

    /// Grows the window to what its content's required constraints need,
    /// and keeps that as the minimum, as AppKit does for Auto Layout content.
    func fitToConstraints() {
        guard let v = contentView, v.subtreeUsesConstraints() else { return }
        let fit = v.fittingSize
        constraintMinSize = fit
        applyMinSize()
        let cs = contentSize
        if fit.width > cs.width || fit.height > cs.height {
            setContentSize(CGSize(width: max(fit.width, cs.width), height: max(fit.height, cs.height)))
        }
    }

    // MARK: Frame autosave

    open private(set) var frameAutosaveName: FrameAutosaveName = ""
    @discardableResult open func setFrameAutosaveName(_ name: FrameAutosaveName) -> Bool {
        frameAutosaveName = name
        guard !name.isEmpty else { return true }
        if !setFrameUsingName(name) { saveFrame(usingName: name) }
        return true
    }
    open var frameDescriptor: PersistableFrameDescriptor {
        let s = screen?.visibleFrame ?? .zero
        return "\(Int(_frame.minX)) \(Int(_frame.minY)) \(Int(_frame.width)) \(Int(_frame.height)) \(Int(s.minX)) \(Int(s.minY)) \(Int(s.width)) \(Int(s.height)) "
    }
    open func saveFrame(usingName name: FrameAutosaveName) {
        let d = frameDescriptor
        guard UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") != d else { return }
        UserDefaults.standard.set(d, forKey: "NSWindow Frame \(name)")
        Self.scheduleDefaultsSync()
    }

    /// Foundation off Apple platforms writes defaults to disk only when
    /// asked: a moved or resized window's frame is written shortly after
    /// (once for a burst of changes), so it's there at the next launch.
    private static var defaultsSyncScheduled = false
    private static func scheduleDefaultsSync() {
        guard !defaultsSyncScheduled else { return }
        defaultsSyncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                defaultsSyncScheduled = false
                UserDefaults.standard.synchronize()
            }
        }
    }
    @discardableResult open func setFrameUsingName(_ name: FrameAutosaveName) -> Bool { setFrameUsingName(name, force: false) }
    @discardableResult open func setFrameUsingName(_ name: FrameAutosaveName, force: Bool) -> Bool {
        guard let d = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") else { return false }
        setFrame(from: d)
        return true
    }
    open func setFrame(from descriptor: PersistableFrameDescriptor) {
        let n = descriptor.split(separator: " ").compactMap { Double($0) }
        guard n.count >= 4, n[2] > 0, n[3] > 0 else { return }
        let saving = frameAutosaveName
        frameAutosaveName = ""
        setFrame(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), display: true)
        frameAutosaveName = saving
    }
    public static func removeFrame(usingName name: FrameAutosaveName) { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
    private func saveFrameIfAutosaving() { if !frameAutosaveName.isEmpty { saveFrame(usingName: frameAutosaveName) } }

    // MARK: Sheets and children

    open func beginSheet(_ sheet: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        sheet.sheetParent = self
        sheet.isModal = true
        sheets.append(sheet)
        if let handler { sheetHandlers[ObjectIdentifier(sheet)] = handler }
        post(Notification.Name("NSWindowWillBeginSheetNotification")) { $0.windowWillBeginSheet($1) }
        sheet.makeKeyAndOrderFront(nil)
    }
    open func beginCriticalSheet(_ sheet: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        beginSheet(sheet, completionHandler: handler)
    }
    open func endSheet(_ sheet: NSWindow) { endSheet(sheet, returnCode: .stop) }
    open func endSheet(_ sheet: NSWindow, returnCode: NSApplication.ModalResponse) {
        sheetEnded(sheet, returnCode)
        sheet.close()
    }
    fileprivate func sheetEnded(_ sheet: NSWindow, _ code: NSApplication.ModalResponse) {
        guard sheets.contains(where: { $0 === sheet }) else { return }
        sheets.removeAll { $0 === sheet }
        sheet.sheetParent = nil
        if let h = sheetHandlers.removeValue(forKey: ObjectIdentifier(sheet)) { h(code) }
        post(Notification.Name("NSWindowDidEndSheetNotification")) { $0.windowDidEndSheet($1) }
    }
    open func addChildWindow(_ child: NSWindow, ordered place: OrderingMode) {
        child.parent = self
        childWindows = (childWindows ?? []) + [child]
    }
    open func removeChildWindow(_ child: NSWindow) {
        childWindows?.removeAll { $0 === child }
        if child.parent === self { child.parent = nil }
    }

    /// Moves the window with the pointer, as dragging its title bar does,
    /// from a mouse-down event.
    open func performDrag(with event: NSEvent) {
        guard let n = native else { return }
        let p = event.locationInWindow
        Runway.appKit?.beginWindowMove(n, button: event.buttonNumber, at: CGPoint(x: p.x, y: frame.height - p.y), timestamp: event.timestamp)
    }

    // MARK: Responders

    open private(set) var firstResponder: NSResponder?
    @discardableResult
    open func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let target = responder ?? self
        if firstResponder === target {
            // Already first responder, but the toolkit's focus may have left
            // its widget (removed and shown again): put it back.
            if let v = target as? NSView, v.usesNativeKeyboardFocus, let n = native, let vs = viewSystem { vs.setKeyboardFocus(v.widget, in: n) }
            return true
        }
        if let cur = firstResponder, cur !== self, !cur.resignFirstResponder() { return false }
        if let r = responder, r !== self {
            guard r.acceptsFirstResponder || r is NSWindow else { firstResponder = self; return false }
            firstResponder = r
            if !r.becomeFirstResponder() { firstResponder = self; return false }
        } else {
            firstResponder = self
        }
        if let n = native, let vs = viewSystem {
            if let v = firstResponder as? NSView, v.usesNativeKeyboardFocus { vs.setKeyboardFocus(v.widget, in: n) } else { vs.setKeyboardFocus(nil, in: n) }
        }
        MenuBar.validateAll()
        return true
    }
    open override var acceptsFirstResponder: Bool { true }
    open func selectNextKeyView(_ sender: Any?) {
        guard let cur = firstResponder as? NSView ?? initialFirstResponder, let next = cur.nextValidKeyView ?? keyViewLoop(after: cur) else { return }
        makeFirstResponder(next)
    }
    open func selectPreviousKeyView(_ sender: Any?) {
        guard let cur = firstResponder as? NSView, let prev = cur.previousValidKeyView ?? keyViewLoop(before: cur) else { return }
        makeFirstResponder(prev)
    }
    open func selectKeyView(following v: NSView) { if let n = v.nextValidKeyView ?? keyViewLoop(after: v) { makeFirstResponder(n) } }
    open func selectKeyView(preceding v: NSView) { if let p = v.previousValidKeyView ?? keyViewLoop(before: v) { makeFirstResponder(p) } }
    open func recalculateKeyViewLoop() {}
    /// Views that can become key, in reading order (the automatic loop).
    private func keyViews() -> [NSView] {
        var out: [NSView] = []
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            if v.canBecomeKeyView { out.append(v) }
            let ordered = v.subviews.sorted {
                let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
                return a.maxY != b.maxY ? a.maxY > b.maxY : a.minX < b.minX
            }
            ordered.forEach(walk)
        }
        contentView.map(walk)
        return out
    }
    private func keyViewLoop(after v: NSView) -> NSView? {
        let views = keyViews()
        guard !views.isEmpty else { return nil }
        let i = views.firstIndex { $0 === v } ?? -1
        return views[(i + 1) % views.count]
    }
    private func keyViewLoop(before v: NSView) -> NSView? {
        let views = keyViews()
        guard !views.isEmpty else { return nil }
        let i = views.firstIndex { $0 === v } ?? 0
        return views[(i - 1 + views.count) % views.count]
    }

    open override var undoManager: UndoManager? {
        delegate?.windowWillReturnUndoManager(self) ?? sharedUndoManager
    }
    private lazy var sharedUndoManager = UndoManager()

    // MARK: Display and layout

    open var viewsNeedDisplay: Bool { get { false } set { if newValue { contentView?.needsDisplay = true } } }
    open func display() { contentView?.display() }
    open func displayIfNeeded() { ViewSystem.flush() }
    open func layoutIfNeeded() { contentView?.layoutSubtreeIfNeeded(); ViewSystem.flush() }
    open func update() {
        if let t = toolbar, t.isVisible { t.validateVisibleItems() }
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }
    open func disableScreenUpdatesUntilFlush() {}
    open func flush() {}
    open func invalidateShadow() {}
    open func disableFlushing() {}
    open func enableFlushing() {}
    open var allowsConcurrentViewDrawing = true
    open func updateConstraintsIfNeeded() { contentView?.updateConstraintsForSubtreeIfNeeded() }
    open func visualizeConstraints(_ c: [NSLayoutConstraint]?) {}
    open func anchorAttribute(for o: NSLayoutConstraint.Orientation) -> NSLayoutConstraint.Attribute { o == .horizontal ? .left : .top }

    func appearanceDidChange() {
        contentView?.appearanceMayHaveChanged()
        for s in sheets { s.appearanceDidChange() }
    }

    // MARK: Coordinates

    open func convertPoint(toScreen p: NSPoint) -> NSPoint { CGPoint(x: _frame.minX + p.x, y: _frame.minY + p.y) }
    open func convertPoint(fromScreen p: NSPoint) -> NSPoint { CGPoint(x: p.x - _frame.minX, y: p.y - _frame.minY) }
    open func convertToScreen(_ r: NSRect) -> NSRect { r.offsetBy(dx: _frame.minX, dy: _frame.minY) }
    open func convertFromScreen(_ r: NSRect) -> NSRect { r.offsetBy(dx: -_frame.minX, dy: -_frame.minY) }
    open func convertPoint(toBacking p: NSPoint) -> NSPoint { p }
    open func convertPoint(fromBacking p: NSPoint) -> NSPoint { p }
    open var mouseLocationOutsideOfEventStream: NSPoint { lastMouseLocation }
    var lastMouseLocation: NSPoint = .zero

    // MARK: Events

    /// The window the pointer was last over.
    static weak var underMouse: NSWindow?
    private weak var mouseDownView: NSView?
    private var lastClick: (time: TimeInterval, location: CGPoint, button: Int, count: Int)?
    private var eventCounter = 0

    /// Raw backend input → NSEvent → NSApp.sendEvent. Returns whether the
    /// event was used (so native widgets don't also act on it).
    private var pressOnNativeControl = false

    func handleRaw(_ raw: RawEvent) -> Bool {
        let flags = EventTranslation.flags(raw.modifiers)
        NSEvent.modifierFlags = flags
        let loc = CGPoint(x: raw.location.x, y: canvasSize.height - raw.location.y)
        eventCounter += 1
        if raw.kind != .keyDown && raw.kind != .keyUp && raw.kind != .flagsChanged {
            lastMouseLocation = loc
            NSEvent.mouseLocation = convertPoint(toScreen: loc)
            NSWindow.underMouse = self
            if NSCursor.hideUntilMove, raw.kind == .mouseMoved { NSCursor.hideUntilMove = false; NSCursor.unhide() }
        }
        guard !ignoresMouseEvents || raw.kind == .keyDown || raw.kind == .keyUp || raw.kind == .flagsChanged else { return false }
        defer { ViewSystem.flush() }
        switch raw.kind {
        case .mouseDown:
            // A SwiftUI control took this press natively: it isn't a drag
            // of the window from its title bar.
            pressOnNativeControl = raw.onNativeControl
            defer { pressOnNativeControl = false }
            NSEvent.pressedMouseButtons |= 1 << raw.button
            var count = 1
            if let l = lastClick, l.button == raw.button, raw.timestamp - l.time < NSEvent.doubleClickInterval,
               abs(l.location.x - loc.x) < 5, abs(l.location.y - loc.y) < 5 { count = l.count + 1 }
            lastClick = (raw.timestamp, loc, raw.button, count)
            let type: NSEvent.EventType = raw.button == 0 ? .leftMouseDown : raw.button == 1 ? .rightMouseDown : .otherMouseDown
            dispatch(NSEvent(type: type, location: loc, modifierFlags: flags, timestamp: raw.timestamp, window: self, clickCount: count, buttonNumber: raw.button, eventNumber: eventCounter))
            return true
        case .mouseUp:
            NSEvent.pressedMouseButtons &= ~(1 << raw.button)
            let type: NSEvent.EventType = raw.button == 0 ? .leftMouseUp : raw.button == 1 ? .rightMouseUp : .otherMouseUp
            dispatch(NSEvent(type: type, location: loc, modifierFlags: flags, timestamp: raw.timestamp, window: self, clickCount: lastClick?.count ?? 1, buttonNumber: raw.button, eventNumber: eventCounter))
            return true
        case .mouseMoved:
            let buttons = NSEvent.pressedMouseButtons
            if buttons != 0 {
                let b = buttons & 1 != 0 ? 0 : buttons & 2 != 0 ? 1 : 2
                let type: NSEvent.EventType = b == 0 ? .leftMouseDragged : b == 1 ? .rightMouseDragged : .otherMouseDragged
                dispatch(NSEvent(type: type, location: loc, modifierFlags: flags, timestamp: raw.timestamp, window: self, buttonNumber: b, eventNumber: eventCounter))
            } else {
                dispatch(NSEvent(type: .mouseMoved, location: loc, modifierFlags: flags, timestamp: raw.timestamp, window: self, eventNumber: eventCounter))
            }
            updateTracking(loc, flags: flags, time: raw.timestamp, dragging: buttons != 0)
            updateCursorRects(loc)
            if buttons == 0 { updateToolTipRects(loc) }
            return false
        case .mouseEntered:
            updateTracking(loc, flags: flags, time: raw.timestamp, dragging: false)
            return false
        case .mouseExited:
            exitAllTracking(flags: flags, time: raw.timestamp)
            return false
        case .scroll:
            let k: CGFloat = raw.preciseScrolling ? 1 : 10
            dispatch(NSEvent(type: .scrollWheel, location: loc, modifierFlags: flags, timestamp: raw.timestamp, window: self,
                             scrollingDelta: CGSize(width: raw.scrollDelta.width * k, height: raw.scrollDelta.height * k),
                             precise: raw.preciseScrolling, delta: raw.scrollDelta, eventNumber: eventCounter))
            return true
        case .keyDown, .keyUp, .flagsChanged:
            let (chars, plain) = EventTranslation.characters(raw)
            let code = EventTranslation.keyCodes[raw.keyName] ?? UInt16(truncatingIfNeeded: raw.keyCode)
            let type: NSEvent.EventType = raw.kind == .keyDown ? .keyDown : raw.kind == .keyUp ? .keyUp : .flagsChanged
            let e = NSEvent(type: type, location: lastMouseLocation, modifierFlags: flags, timestamp: raw.timestamp, window: self,
                            characters: type == .flagsChanged ? nil : chars, charactersIgnoringModifiers: type == .flagsChanged ? nil : plain,
                            isARepeat: raw.isRepeat, keyCode: code, eventNumber: eventCounter)
            if type == .keyDown, let h = (firstResponderChainKeyHandler() ?? contentView as? KeyHandling) {
                if h.handleKey(KeyPress(key: legacyKeyName(raw), command: flags.contains(.command), shift: flags.contains(.shift), option: flags.contains(.option))) { return true }
            }
            KeyDispatch.unhandled = false
            // A SwiftUI text field or editor isn't a responder AppKit knows:
            // the toolkit says when native text input has focus.
            let nativeFocus = ((firstResponder as? NSView)?.usesNativeKeyboardFocus ?? false) || raw.nativeTextFocus
            if nativeFocus, type == .keyDown, let tv = firstResponder as? NSTextView, tv.takesKeyEvents,
               flags.contains(.command) || KeyBindings.selector(for: e) != nil {
                // A text view takes its commands as events (keyDown(with:) →
                // interpretKeyEvents → doCommand(by:)), as on the Mac; typed
                // text goes through the toolkit's input method.
                dispatch(e)
                return !KeyDispatch.unhandled
            }
            if nativeFocus, type != .flagsChanged {
                // Native text input keeps its keys; key equivalents still apply.
                if type == .keyDown, flags.contains(.command) || e.specialKey.map({ (0xF704...0xF70F).contains($0.rawValue) }) == true {
                    if keyEquivalent(e) { return true }
                }
                return false
            }
            dispatch(e)
            return !KeyDispatch.unhandled
        }
    }

    private func legacyKeyName(_ raw: RawEvent) -> String {
        switch raw.keyName {
        case "Return", "KP_Enter": return "return"
        case "Escape": return "escape"
        case "BackSpace": return "backspace"
        case "space": return "space"
        case "Tab", "ISO_Left_Tab": return "tab"
        default: return raw.charactersIgnoringModifiers.isEmpty ? raw.keyName.lowercased() : raw.charactersIgnoringModifiers.lowercased()
        }
    }

    private func firstResponderChainKeyHandler() -> KeyHandling? {
        var r: NSResponder? = firstResponder
        var n = 0
        while let cur = r, n < 256 { if let h = cur as? KeyHandling { return h }; r = cur.nextResponder; n += 1 }
        return nil
    }

    private func dispatch(_ e: NSEvent) {
        NSApp.setCurrentEvent(e)
        NSApp.sendEvent(e)
        NSApp.setCurrentEvent(nil)
        switch e.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown, .keyUp, .flagsChanged: setNeedsUpdate()
        default: break
        }
    }

    /// `update()` once the current event is done, as AppKit updates its
    /// windows after each event (the toolbar revalidates its items then).
    private var updateScheduled = false
    func setNeedsUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Runway.backend.schedule { [weak self] in
            guard let self else { return }
            updateScheduled = false
            update()
        }
    }

    /// Key equivalents: the view hierarchy, then the main menu.
    func keyEquivalent(_ e: NSEvent) -> Bool {
        if performKeyEquivalent(with: e) { return true }
        if let m = NSApp.mainMenu, m.performKeyEquivalent(with: e) { return true }
        return false
    }

    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        contentView?.performKeyEquivalent(with: event) ?? false
    }

    /// Dispatches an event to the right view: mouse events to the view
    /// under the pointer (drags and ups to the one that got the down), keys
    /// to the first responder after key equivalents.
    open func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if event.type == .leftMouseDown, !pressOnNativeControl, titlebarMouseDown(event) { return }
            guard let hit = toolbarHit(event.locationInWindow) ?? contentView?.hitTest(event.locationInWindow) else { return }
            mouseDownView = hit
            if event.type == .leftMouseDown, hit !== firstResponder, hit.acceptsFirstResponder {
                makeFirstResponder(hit)
            }
            if !isKeyWindow { makeKey() }
            switch event.type {
            case .leftMouseDown: hit.mouseDown(with: event)
            case .rightMouseDown: hit.rightMouseDown(with: event)
            default: hit.otherMouseDown(with: event)
            }
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let v = mouseDownView ?? contentView?.hitTest(event.locationInWindow) else { return }
            switch event.type {
            case .leftMouseDragged: v.mouseDragged(with: event)
            case .rightMouseDragged: v.rightMouseDragged(with: event)
            default: v.otherMouseDragged(with: event)
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard let v = mouseDownView ?? contentView?.hitTest(event.locationInWindow) else { return }
            if NSEvent.pressedMouseButtons == 0 { mouseDownView = nil }
            GestureRecognizers.mouseUp(event, over: contentView?.hitTest(event.locationInWindow) ?? v)
            switch event.type {
            case .leftMouseUp: v.mouseUp(with: event)
            case .rightMouseUp: v.rightMouseUp(with: event)
            default: v.otherMouseUp(with: event)
            }
        case .mouseMoved:
            if acceptsMouseMovedEvents { (firstResponder ?? self).mouseMoved(with: event) }
        case .scrollWheel:
            contentView?.hitTest(event.locationInWindow)?.scrollWheel(with: event)
        case .keyDown:
            if event.modifierFlags.contains(.command) || event.specialKey.map({ (0xF704...0xF70F).contains($0.rawValue) }) == true || event.charactersIgnoringModifiers == "\u{1b}" {
                if keyEquivalent(event) { return }
            }
            (firstResponder ?? self).keyDown(with: event)
        case .keyUp:
            (firstResponder ?? self).keyUp(with: event)
        case .flagsChanged:
            (firstResponder ?? self).flagsChanged(with: event)
        case .mouseEntered, .mouseExited, .cursorUpdate:
            break
        default:
            break
        }
    }

    // The window ends the responder chain for keys: Escape cancels, Tab moves.
    open override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\t": selectNextKeyView(nil)
        case "\u{19}": selectPreviousKeyView(nil)
        case "\u{1b}":
            if !RunwayObjC.sendAction(Selector("cancelOperation:"), to: nil, from: self) { KeyDispatch.unhandled = true }
        default: super.keyDown(with: event)
        }
    }
    open override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    // MARK: Tracking areas

    var trackingDirty = true
    private var trackingCache: [NSTrackingArea] = []

    private func allTrackingAreas() -> [NSTrackingArea] {
        if trackingDirty {
            trackingDirty = false
            trackingCache = []
            func walk(_ v: NSView) {
                guard !v.isHidden else { return }
                trackingCache += v.trackingAreas
                v.treeChildren.forEach(walk)
            }
            contentView.map(walk)
        }
        return trackingCache
    }

    private func active(_ a: NSTrackingArea) -> Bool {
        let o = a.options
        if o.contains(.activeAlways) || o.contains(.activeInActiveApp) { return true }
        // Key status can lag on some window systems (no window manager,
        // after a popover): with no other key window, count as key.
        if o.contains(.activeInKeyWindow) { return isKeyWindow || NSApp._keyWindow == nil || NSApp._keyWindow === self }
        if o.contains(.activeWhenFirstResponder) { return a.view != nil && firstResponder === a.view }
        return false
    }

    private func updateTracking(_ loc: CGPoint, flags: NSEvent.ModifierFlags, time: TimeInterval, dragging: Bool) {
        var entered: [NSTrackingArea] = [], exited: [NSTrackingArea] = [], moved: [NSTrackingArea] = []
        for a in allTrackingAreas() {
            guard let v = a.view, v.window === self else { continue }
            let r = v.convert(a.effectiveRect, to: nil)
            let inside = r.contains(loc) && active(a) && (!dragging || a.options.contains(.enabledDuringMouseDrag) || a.inside)
            if inside != a.inside {
                a.inside = inside
                if inside { entered.append(a) } else { exited.append(a) }
            } else if inside, a.options.contains(.mouseMoved), !dragging {
                moved.append(a)
            }
        }
        func send(_ a: NSTrackingArea, _ type: NSEvent.EventType) {
            guard let owner = a.owner as? NSResponder else { return }
            let e = NSEvent(type: type, location: loc, modifierFlags: flags, timestamp: time, window: self)
            e.trackingArea = a
            switch type {
            case .mouseEntered: owner.mouseEntered(with: e)
            case .mouseExited: owner.mouseExited(with: e)
            case .cursorUpdate: owner.cursorUpdate(with: e)
            default: owner.mouseMoved(with: e)
            }
        }
        for a in exited where a.options.contains(.mouseEnteredAndExited) { send(a, .mouseExited) }
        for a in entered {
            if a.options.contains(.mouseEnteredAndExited) { send(a, .mouseEntered) }
            if a.options.contains(.cursorUpdate) { send(a, .cursorUpdate) }
        }
        if !exited.isEmpty, entered.isEmpty, exited.contains(where: { $0.options.contains(.cursorUpdate) }),
           !allTrackingAreas().contains(where: { $0.inside && $0.options.contains(.cursorUpdate) }) {
            NSCursor.arrow.set()
        }
        for a in moved { send(a, .mouseMoved) }
    }

    private func exitAllTracking(flags: NSEvent.ModifierFlags, time: TimeInterval) {
        for a in allTrackingAreas() where a.inside {
            a.inside = false
            if a.options.contains(.mouseEnteredAndExited), let owner = a.owner as? NSResponder {
                let e = NSEvent(type: .mouseExited, location: lastMouseLocation, modifierFlags: flags, timestamp: time, window: self)
                e.trackingArea = a
                owner.mouseExited(with: e)
            }
        }
    }

    // MARK: Cursor rects

    private var cursorRectsDirty = true
    private var cursorRectList: [(CGRect, NSCursor)] = []
    private var cursorFromRects = false
    open private(set) var areCursorRectsEnabled = true
    open func invalidateCursorRects(for view: NSView) { cursorRectsDirty = true }
    open func resetCursorRects() { cursorRectsDirty = true }
    open func discardCursorRects() { cursorRectList = [] }
    open func disableCursorRects() { areCursorRectsEnabled = false }
    open func enableCursorRects() { areCursorRectsEnabled = true }

    /// The view under the pointer whose tool tip rectangles answer for it.
    private weak var toolTipView: NSView?
    private func updateToolTipRects(_ loc: CGPoint) {
        var v = contentView?.hitTest(loc)
        var found: (NSView, String?)?
        while let cur = v {
            if !cur.toolTipRects.isEmpty, let t = cur.toolTip(at: cur.convert(loc, from: nil)) { found = (cur, t); break }
            v = cur.superview
        }
        if let old = toolTipView, old !== found?.0 { old.activeToolTip = nil }
        toolTipView = found?.0
        found?.0.activeToolTip = found?.1
    }

    private func updateCursorRects(_ loc: CGPoint) {
        guard areCursorRectsEnabled else { return }
        if cursorRectsDirty {
            cursorRectsDirty = false
            cursorRectList = []
            func walk(_ v: NSView) {
                guard !v.isHidden else { return }
                v.discardCursorRects()
                v.resetCursorRects()
                for (r, c) in v.cursorRects { cursorRectList.append((v.convert(r, to: nil).intersection(v.convert(v.visibleRect, to: nil)), c)) }
                v.treeChildren.forEach(walk)
            }
            contentView.map(walk)
        }
        guard !cursorRectList.isEmpty else { return }
        if let hit = cursorRectList.last(where: { $0.0.contains(loc) }) {
            if NSCursor.current !== hit.1 || !cursorFromRects { hit.1.set() }
            cursorFromRects = true
        } else if cursorFromRects {
            cursorFromRects = false
            NSCursor.arrow.set()
        }
    }

    // MARK: Drops

    private var dragSequence = 0
    private weak var dragTarget: NSView?
    private var dragInfo: RunwayDraggingInfo?

    func dropTargetsChanged() {
        guard let n = native, let vs = viewSystem else { return }
        vs.setDropHandler(n) { [weak self] e in self?.handleDrag(e) ?? [] }
    }

    private func dropTarget(at loc: CGPoint, types: [NSPasteboard.PasteboardType]) -> NSView? {
        var v = contentView?.hitTest(loc)
        while let cur = v {
            if cur.registeredDraggedTypes.contains(where: { types.contains($0) || ($0.rawValue == "NSFilenamesPboardType" && types.contains(.fileURL)) }) { return cur }
            v = cur.superview
        }
        return nil
    }

    private func handleDrag(_ e: RawDragEvent) -> RawDragOperation {
        let loc = CGPoint(x: e.location.x, y: canvasSize.height - e.location.y)
        var types: [NSPasteboard.PasteboardType] = []
        if !e.fileURLs.isEmpty { types += [.fileURL, .URL] }
        if !e.strings.isEmpty { types += [.string] }
        defer { ViewSystem.flush() }
        func op(_ o: NSDragOperation) -> RawDragOperation {
            if o.contains(.copy) || o.contains(.generic) { return .copy }
            if o.contains(.move) { return .move }
            if o.contains(.link) { return .link }
            return []
        }
        switch e.kind {
        case .entered, .updated:
            if e.kind == .entered { dragSequence += 1 }
            let info = dragInfo ?? RunwayDraggingInfo(window: self, location: loc, files: e.fileURLs, strings: e.strings, sequence: dragSequence)
            info.draggingLocation = loc
            dragInfo = info
            let target = dropTarget(at: loc, types: types)
            if target !== dragTarget {
                dragTarget?.draggingExited(info)
                dragTarget = target
                return op(target?.draggingEntered(info) ?? [])
            }
            return op(target?.draggingUpdated(info) ?? [])
        case .exited:
            dragTarget?.draggingExited(dragInfo)
            dragTarget = nil
            dragInfo = nil
            return []
        case .perform:
            let info = RunwayDraggingInfo(window: self, location: loc, files: e.fileURLs, strings: e.strings, sequence: dragSequence)
            let target = dragTarget ?? dropTarget(at: loc, types: types)
            dragTarget = nil
            dragInfo = nil
            guard let target else { return [] }
            if target.prepareForDragOperation(info), target.performDragOperation(info) {
                target.concludeDragOperation(info)
                target.draggingEnded(info)
                return .copy
            }
            target.draggingEnded(info)
            return []
        }
    }

    // MARK: Without a view-system backend

    /// Key presses from a backend that only reports KeyPress: hosted
    /// SwiftUI first, then the main menu's key equivalents.
    open func handleKey(_ key: KeyPress) -> Bool {
        if let h = contentView as? KeyHandling, h.handleKey(key) { return true }
        if key.command, let menu = NSApp.mainMenu, menu.performKeyEquivalent(key) { return true }
        if key.key == "w", key.command, styleMask.contains(.closable) { performClose(nil); return true }
        return false
    }

    /// The titlebar's buttons are the backend's. While they float over the
    /// content (in the toolbar band) each is a button at their frame, so
    /// apps can measure against them; otherwise a button that isn't in a
    /// view tree stands for each, so code can still configure and hide it.
    open func standardWindowButton(_ b: ButtonType) -> NSButton? {
        if let placed = windowButtonView(b) as? NSButton { return placed }
        if let existing = _standardButtons[b.rawValue] { return existing }
        let button = NSButton()
        _standardButtons[b.rawValue] = button
        return button
    }
    private var _standardButtons: [UInt: NSButton] = [:]
    /// Holds the buttons standardWindowButton(_:) returns in the band.
    var windowButtonHost: NSView?
    open func addTitlebarAccessoryViewController(_ vc: NSViewController) {}
    open func removeTitlebarAccessoryViewController(at index: Int) {}
    open func trackEvents(matching mask: NSEvent.EventTypeMask, timeout: TimeInterval, mode: RunLoop.Mode, handler: (NSEvent?, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    open func nextEvent(matching mask: NSEvent.EventTypeMask) -> NSEvent? { nil }
    open func nextEvent(matching mask: NSEvent.EventTypeMask, until date: Date?, inMode mode: RunLoop.Mode, dequeue: Bool) -> NSEvent? { nil }
    open func postEvent(_ event: NSEvent, atStart: Bool) { sendEvent(event) }
    open func makeFirstResponderIfPossible(_ r: NSResponder) { makeFirstResponder(r) }
}

/// A window for auxiliary content: palettes, inspectors, pop-up panels.
@preconcurrency @MainActor
open class NSPanel: NSWindow {
    /// Floats above ordinary windows (the floating level).
    open var isFloatingPanel = false { didSet { level = isFloatingPanel ? .floating : .normal } }
    /// Becomes key only when a view that needs keyboard input is clicked.
    open var becomesKeyOnlyIfNeeded = false
}

// MARK: NSWindowController

@preconcurrency @MainActor
open class NSWindowController: NSResponder {
    private var _window: NSWindow?
    open var windowNibName: String?
    open weak var owner: AnyObject?
    open var shouldCascadeWindows = true
    open var shouldCloseDocument = false
    open var windowFrameAutosaveName: NSWindow.FrameAutosaveName = "" {
        didSet { if isWindowLoaded, !windowFrameAutosaveName.isEmpty { _window?.setFrameAutosaveName(windowFrameAutosaveName) } }
    }
    /// The NSDocument (or any document object) the window shows.
    open weak var document: AnyObject? {
        didSet { if let d = document as? NSObject, let name = d.value(forKey: "displayName") as? String { synchronizeWindowTitleWithDocumentName(name) } }
    }

    public init(window: NSWindow?) {
        super.init()
        _window = window
        AppKitRuntime.install()
        window?.windowController = self
    }
    public convenience init(windowNibName: String) { self.init(window: nil); self.windowNibName = windowNibName }
    public convenience init(windowNibName: String, owner: Any) { self.init(windowNibName: windowNibName); self.owner = owner as AnyObject }
    public convenience override init() { self.init(window: nil) }
    /// Storyboards decode window controllers through this (InterfaceBuilder/).
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        AppKitRuntime.install()
        IBDecoding.leave(self, coder)
    }

    /// The window, loaded on first use (`loadWindow()` then `windowDidLoad()`).
    open var window: NSWindow? {
        get { loadIfNeeded(); return _window }
        set {
            _window?.windowController = nil
            _window = newValue
            newValue?.windowController = self
        }
    }
    open var isWindowLoaded: Bool { _window != nil }
    private var loading = false

    func loadIfNeeded() {
        guard _window == nil, !loading else { return }
        loading = true
        defer { loading = false }
        windowWillLoad()
        loadWindow()
        _window?.windowController = self
        if !windowFrameAutosaveName.isEmpty { _window?.setFrameAutosaveName(windowFrameAutosaveName) }
        windowDidLoad()
    }

    /// Loads the window from the controller's storyboard scene or its nib
    /// (`windowNibName`), as Cocoa does; subclasses override to make it in code.
    open func loadWindow() { IBLoading.loadWindow(of: self) }
    open func prepare(for segue: NSStoryboardSegue, sender: Any?) {}
    open func shouldPerformSegue(withIdentifier identifier: NSStoryboardSegue.Identifier, sender: Any?) -> Bool { true }
    open func performSegue(withIdentifier identifier: NSStoryboardSegue.Identifier, sender: Any?) {
        IBSegues.perform(identifier, from: self, sender: sender)
    }
    open func windowWillLoad() {}
    open func windowDidLoad() {}

    open func showWindow(_ sender: Any?) {
        guard let w = window else { return }
        if !w.isVisible, shouldCascadeWindows, let prev = NSApp.windows.last(where: { $0 !== w && $0.isVisible }) {
            _ = w.cascadeTopLeft(from: CGPoint(x: prev.frame.minX + 20, y: prev.frame.maxY - 20))
        }
        w.makeKeyAndOrderFront(sender)
    }
    open func close() { _window?.close() }
    open func dismissController(_ sender: Any?) { close() }

    open var contentViewController: NSViewController? {
        get { window?.contentViewController }
        set { window?.contentViewController = newValue }
    }
    open func windowTitle(forDocumentDisplayName displayName: String) -> String { displayName }
    open func synchronizeWindowTitleWithDocumentName() {}
    func synchronizeWindowTitleWithDocumentName(_ name: String) { window?.title = windowTitle(forDocumentDisplayName: name) }
    open func setDocumentEdited(_ dirty: Bool) { window?.isDocumentEdited = dirty }

    open override var nextResponder: NSResponder? {
        get { super.nextResponder }
        set { super.nextResponder = newValue }
    }
}

// MARK: NSScreen

@preconcurrency @MainActor
public final class NSScreen: NSObject {
    let spec: ScreenSpec
    /// The primary display's height (screen coordinates flip around it).
    private let primaryHeight: CGFloat
    init(_ spec: ScreenSpec, primaryHeight: CGFloat) {
        self.spec = spec
        self.primaryHeight = primaryHeight
        super.init()
    }

    /// The displays, from the backend's monitors (the first is the primary).
    public static var screens: [NSScreen] {
        let specs = (Runway.backend as? ViewSystemBackend)?.screens() ?? []
        let list = specs.isEmpty ? [ScreenSpec(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), scale: 1, name: "Display")] : specs
        let ph = list[0].frame.height
        return list.map { NSScreen($0, primaryHeight: ph) }
    }
    /// The screen with the key window (the primary one here).
    public static var main: NSScreen? { screens.first }
    public static var deepest: NSScreen? { main }
    public static var screensHaveSeparateSpaces: Bool { false }

    private func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height) }
    /// In AppKit's screen coordinates: y-up, origin at the primary's bottom-left.
    public var frame: NSRect { flip(spec.frame) }
    public var visibleFrame: NSRect { flip(spec.visibleFrame) }
    public var backingScaleFactor: CGFloat { spec.scale }
    public var localizedName: String { spec.name }
    public var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
    public var auxiliaryTopLeftArea: NSRect? { nil }
    public var auxiliaryTopRightArea: NSRect? { nil }
    public var maximumFramesPerSecond: Int { 60 }
    public var depth: Int { 24 }
    public var colorSpace: NSColorSpace? { .sRGB }
    public typealias DeviceDescriptionKey = NSDeviceDescriptionKey
    public var deviceDescription: [DeviceDescriptionKey: Any] {
        [.size: frame.size, .isScreen: "YES", DeviceDescriptionKey("NSScreenNumber"): NSNumber(value: (NSScreen.screens.firstIndex { $0.spec == spec } ?? 0) + 1)]
    }
    public func convertRectToBacking(_ r: NSRect) -> NSRect { r.applying(CGAffineTransform(scaleX: spec.scale, y: spec.scale)) }
    public func convertRectFromBacking(_ r: NSRect) -> NSRect { r.applying(CGAffineTransform(scaleX: 1 / spec.scale, y: 1 / spec.scale)) }
    public static func == (a: NSScreen, b: NSScreen) -> Bool { a.spec == b.spec }
    public override func isEqual(_ object: Any?) -> Bool { (object as? NSScreen)?.spec == spec }
}

/// Keys of a screen's (or printer's) device description.
public struct NSDeviceDescriptionKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let resolution = NSDeviceDescriptionKey("NSDeviceResolution")
    public static let colorSpaceName = NSDeviceDescriptionKey("NSDeviceColorSpaceName")
    public static let bitsPerSample = NSDeviceDescriptionKey("NSDeviceBitsPerSample")
    public static let isScreen = NSDeviceDescriptionKey("NSDeviceIsScreen")
    public static let isPrinter = NSDeviceDescriptionKey("NSDeviceIsPrinter")
    public static let size = NSDeviceDescriptionKey("NSDeviceSize")
}
