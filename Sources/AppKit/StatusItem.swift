// NSStatusBar and NSStatusItem: a menu-bar extra as the desktop's tray
// item (StatusNotifierItem over D-Bus, with its menu as a
// com.canonical.dbusmenu, on Linux). The item's button image and title
// become the tray icon and title; its menu is the tray menu, rebuilt each
// time it opens so `menuNeedsUpdate`-style changes show. Without a tray
// (a desktop with no StatusNotifierItem host) the items show in a small
// window of their own, the app's "menu bar" (StatusItemStrip): a menu-bar
// app stays reachable, and its menus and actions work from there.

import Foundation
import CoreGraphics
import RunwayCore

@preconcurrency @MainActor
open class NSStatusBar: NSObject {
    public static let system = NSStatusBar()
    open class var systemStatusBar: NSStatusBar { system }
    open private(set) var items: [NSStatusItem] = []
    open var thickness: CGFloat { 24 }
    open var isVertical: Bool { false }

    public override init() { super.init() }

    open func statusItem(withLength length: CGFloat) -> NSStatusItem {
        let i = NSStatusItem(statusBar: self, length: length)
        items.append(i)
        return i
    }
    open func removeStatusItem(_ item: NSStatusItem) {
        item.removeNative()
        items.removeAll { $0 === item }
    }
}

public let NSVariableStatusItemLength: CGFloat = -1
public let NSSquareStatusItemLength: CGFloat = -2

@preconcurrency @MainActor
open class NSStatusItem: NSObject {
    public static let variableLength: CGFloat = -1
    public static let squareLength: CGFloat = -2
    public struct Behavior: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let removalAllowed = Behavior(rawValue: 1 << 1)
        public static let terminationOnRemoval = Behavior(rawValue: 1 << 2)
    }

    open private(set) weak var statusBar: NSStatusBar?
    open var length: CGFloat
    open var menu: NSMenu? { didSet { sync() } }
    open var isVisible = true { didSet { sync() } }
    open var behavior: Behavior = []
    open var autosaveName: String?
    open private(set) var button: NSStatusBarButton?
    /// The native tray item; nil when the desktop has no tray.
    private var native: AnyObject?
    private var made = false

    init(statusBar: NSStatusBar, length: CGFloat) {
        self.statusBar = statusBar
        self.length = length
        super.init()
        let b = NSStatusBarButton(frame: CGRect(x: 0, y: 0, width: 24, height: 22))
        b.isBordered = false
        b.statusItem = self
        button = b
        // Made on the next turn, once the app has set the image and menu.
        Runway.backend.schedule { [weak self] in self?.sync() }
    }

    // Older API, kept for apps that still use it.
    open var title: String? { get { button?.title } set { button?.title = newValue ?? "" } }
    open var image: NSImage? { get { button?.image } set { button?.image = newValue } }
    open var toolTip: String? { get { button?.toolTip } set { button?.toolTip = newValue; sync() } }
    open var isEnabled: Bool { get { button?.isEnabled ?? true } set { button?.isEnabled = newValue } }
    open var highlightMode = false
    open weak var target: AnyObject? { get { button?.target } set { button?.target = newValue } }
    open var action: Selector? { get { button?.action } set { button?.action = newValue } }
    open func popUpMenu(_ menu: NSMenu) { menu.update() }

    /// What the tray shows.
    var spec: StatusItemSpec {
        var s = StatusItemSpec()
        s.title = button?.title ?? ""
        if let img = button?.image, case let .symbol(name) = img.imageSource { s.symbol = name }
        s.tooltip = button?.toolTip
        s.visible = isVisible
        return s
    }

    /// The tray's menu, from `menu`, asking its delegate to update first.
    var menuSpecs: [MenuItemSpec] {
        guard let m = menu else { return [] }
        (m.delegate as? NSMenuDelegate)?.menuNeedsUpdate(m)
        (m.delegate as? NSMenuDelegate)?.menuWillOpen(m)
        return m.specs()
    }

    /// Clicking the tray icon: the button's action (items without a menu).
    func activated() {
        if menu != nil { return }
        button?.performClick(nil)
    }

    func sync() {
        guard let ak = Runway.appKit else { return }
        if !made {
            made = true
            native = ak.makeStatusItem(spec, menu: { [weak self] in self?.menuSpecs ?? [] }, activate: { [weak self] in self?.activated() })
        } else if let n = native {
            ak.updateStatusItem(n, spec)
        }
        if native == nil { StatusItemStrip.shared.setNeedsUpdate() }
    }

    func removeNative() {
        if let n = native { Runway.appKit?.removeStatusItem(n) }
        native = nil
        isVisible = false
        StatusItemStrip.shared.setNeedsUpdate()
    }

    /// A click on the item where it is shown without a tray: its menu, else its action.
    func clicked(in view: NSView) {
        if let menu {
            (menu.delegate as? NSMenuDelegate)?.menuNeedsUpdate(menu)
            _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: view)
        } else {
            button?.performClick(nil)
        }
    }

    /// Runway: whether the desktop shows the item (it has a tray).
    open var isShownInTray: Bool { native != nil }
}

/// The status item's button; changes to it update the tray item.
@preconcurrency @MainActor
open class NSStatusBarButton: NSButton {
    weak var statusItem: NSStatusItem?
    open var appearsDisabled = false
    open override func controlValueChanged() { controlStateChanged() }
    open override func controlStateChanged() {
        super.controlStateChanged()
        statusItem?.sync()
    }
}


// MARK: Status items without a tray

/// The app's status items in a window of their own, for desktops with no
/// tray to put them in: one button per visible item (its image and title,
/// or the item's own button when the app draws into it), left to right.
@MainActor final class StatusItemStrip {
    static let shared = StatusItemStrip()
    private var window: NSPanel?
    private var scheduled = false
    private var proxies: [ObjectIdentifier: NSButton] = [:]

    func setNeedsUpdate() {
        guard !scheduled else { return }
        scheduled = true
        Runway.backend.schedule { [weak self] in
            self?.scheduled = false
            self?.update()
        }
    }

    private func update() {
        let items = NSStatusBar.system.items.filter { $0.isVisible && !$0.isShownInTray }
        guard !items.isEmpty else {
            window?.orderOut(nil)
            return
        }
        let height: CGFloat = 28, padding: CGFloat = 8
        let content = window?.contentView ?? NSView(frame: .zero)
        for v in content.subviews { v.removeFromSuperview() }
        var x = padding
        var live = Set<ObjectIdentifier>()
        for item in items {
            let view = self.view(for: item)
            live.insert(ObjectIdentifier(item))
            var size = view.intrinsicContentSize
            if size.width <= 0 { size.width = max(view.frame.width, 24) }
            if item.length > 0 { size.width = item.length }
            let w = max(size.width, 24)
            view.frame = CGRect(x: x, y: 0, width: w, height: height)
            content.addSubview(view)
            x += w + 4
        }
        proxies = proxies.filter { live.contains($0.key) }
        let width = max(x - 4 + padding, 120)
        if window == nil {
            let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? ProcessInfo.processInfo.processName
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            content.frame = CGRect(x: 0, y: 0, width: width, height: height)
            p.contentView = content
            window = p
        }
        window?.setContentSize(CGSize(width: width, height: height))
        window?.orderFront(nil)
        // RUNWAY_STATUS_ITEM_CLICK=n: click the nth item shortly after it
        // appears (screenshots and checks of menu-bar apps, whose windows
        // open from their status item).
        if !clickedForEnvironment, let n = ProcessInfo.processInfo.environment["RUNWAY_STATUS_ITEM_CLICK"].flatMap(Int.init), items.indices.contains(n) {
            clickedForEnvironment = true
            let item = items[n]
            let view = self.view(for: item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { item.clicked(in: view) } }
        }
    }
    private var clickedForEnvironment = false

    /// What stands for an item: its own button when the app put views in
    /// it, else a plain button with its image and title.
    private func view(for item: NSStatusItem) -> NSView {
        if let b = item.button, !b.subviews.isEmpty { return b }
        let key = ObjectIdentifier(item)
        let proxy = proxies[key] ?? {
            let b = NSButton(frame: .zero)
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.handler = { [weak item] sender in
                guard let item, let view = sender as? NSView else { return }
                item.clicked(in: view)
            }
            proxies[key] = b
            return b
        }()
        let title = item.button?.title ?? ""
        proxy.image = item.button?.image
        proxy.title = title.isEmpty && proxy.image == nil ? ((Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "●") : title
        if let attributed = item.button?.attributedTitle, attributed.length > 0 { proxy.attributedTitle = attributed }
        proxy.toolTip = item.button?.toolTip
        proxy.isEnabled = item.button?.isEnabled ?? true
        return proxy
    }
}
