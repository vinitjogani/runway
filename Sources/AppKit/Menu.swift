// NSMenu and NSMenuItem: key equivalents, validation (autoenabling via
// the responder chain, `validateMenuItem(_:)`), target/action through
// RunwayObjC, the main menu as each window's native menu bar, and
// context menus.

import Foundation
import RunwayCore
import RunwayObjC

@preconcurrency @MainActor public protocol NSMenuDelegate: AnyObject {
    func menuNeedsUpdate(_ menu: NSMenu)
    func numberOfItems(in menu: NSMenu) -> Int
    func menu(_ menu: NSMenu, update item: NSMenuItem, at index: Int, shouldCancel: Bool) -> Bool
    func menuWillOpen(_ menu: NSMenu)
    func menuDidClose(_ menu: NSMenu)
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?)
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: UnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool
}

extension NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {}
    public func numberOfItems(in menu: NSMenu) -> Int { -1 }
    public func menu(_ menu: NSMenu, update item: NSMenuItem, at index: Int, shouldCancel: Bool) -> Bool { true }
    public func menuWillOpen(_ menu: NSMenu) {}
    public func menuDidClose(_ menu: NSMenu) {}
    public func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {}
    public func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: UnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool { false }
}

@preconcurrency @MainActor
open class NSMenu: NSObject {
    open var title: String { didSet { MenuBar.structureChanged() } }
    open var items: [NSMenuItem] = [] {
        didSet {
            for i in oldValue where i.menu === self { i.menu = nil }
            for i in items { i.menu = self }
            MenuBar.structureChanged()
        }
    }
    open weak var delegate: NSMenuDelegate?
    nonisolated(unsafe) public weak var supermenu: NSMenu?
    open var autoenablesItems = true
    open var font: NSFont?
    open var minimumWidth: CGFloat = 0
    open var showsStateColumn = true
    open var allowsContextMenuPlugIns = false
    open var identifier: NSUserInterfaceItemIdentifier?
    open var userInterfaceLayoutDirection: NSUserInterfaceLayoutDirection = .leftToRight
    open private(set) var highlightedItem: NSMenuItem?
    open var size: NSSize { NSSize(width: max(minimumWidth, 200), height: CGFloat(items.count) * 22) }
    open var menuBarHeight: CGFloat { 24 }
    open var selectedItems: [NSMenuItem] { items.filter { $0.state == .on } }

    public init(title: String) { self.title = title; super.init() }
    public convenience override init() { self.init(title: "") }
    public required init(coder: NSCoder) { title = ""; super.init() }
    open func awakeFromNib() {}

    open func addItem(_ item: NSMenuItem) { insertItem(item, at: items.count) }
    @discardableResult open func addItem(withTitle title: String, action: Selector?, keyEquivalent: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        addItem(i)
        return i
    }
    open func insertItem(_ item: NSMenuItem, at index: Int) {
        if let m = item.menu, m !== self { m.removeItem(item) }
        items.insert(item, at: max(0, min(index, items.count)))
    }
    @discardableResult open func insertItem(withTitle title: String, action: Selector?, keyEquivalent: String, at index: Int) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        insertItem(i, at: index)
        return i
    }
    open func removeItem(_ item: NSMenuItem) { items.removeAll { $0 === item } }
    open func removeItem(at index: Int) { items.remove(at: index) }
    open func removeAllItems() { items.removeAll() }
    open func itemChanged(_ item: NSMenuItem) { MenuBar.structureChanged() }
    open var numberOfItems: Int { items.count }
    open func item(withTitle t: String) -> NSMenuItem? { items.first { $0.title == t } }
    open func item(withTag tag: Int) -> NSMenuItem? { items.first { $0.tag == tag } }
    open func item(at i: Int) -> NSMenuItem? { items.indices.contains(i) ? items[i] : nil }
    open func index(of item: NSMenuItem) -> Int { items.firstIndex { $0 === item } ?? -1 }
    open func indexOfItem(withTitle t: String) -> Int { items.firstIndex { $0.title == t } ?? -1 }
    open func indexOfItem(withTag tag: Int) -> Int { items.firstIndex { $0.tag == tag } ?? -1 }
    open func indexOfItem(withSubmenu m: NSMenu?) -> Int { items.firstIndex { $0.submenu === m } ?? -1 }
    open func indexOfItem(withRepresentedObject o: Any?) -> Int {
        items.firstIndex { ($0.representedObject as AnyObject?) === (o as AnyObject?) } ?? -1
    }
    open func indexOfItem(withTarget t: Any?, andAction a: Selector?) -> Int {
        items.firstIndex { $0.target === (t as AnyObject?) && $0.action == a } ?? -1
    }
    open func setSubmenu(_ m: NSMenu?, for item: NSMenuItem) { item.submenu = m }
    open func submenuAction(_ sender: Any?) {}
    open func cancelTracking() {}
    open func cancelTrackingWithoutAnimation() {}
    open func performActionForItem(at index: Int) { item(at: index)?.perform() }

    /// Validates every item (autoenabling): asks each item's target, or the
    /// responder chain's first taker of its action.
    open func update() {
        delegate?.menuNeedsUpdate(self)
        if let d = delegate {
            let n = d.numberOfItems(in: self)
            if n >= 0 {
                while items.count < n { addItem(NSMenuItem(title: "", action: nil, keyEquivalent: "")) }
                while items.count > n { removeItem(at: items.count - 1) }
                for (i, item) in items.enumerated() where !d.menu(self, update: item, at: i, shouldCancel: false) { break }
            }
        }
        guard autoenablesItems else { return }
        for item in items { item.validate() }
    }

    /// Runs the item whose key equivalent matches `event` (⌘ is Ctrl here).
    open func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        for item in items where !item.isHidden {
            if let sub = item.submenu {
                if sub.performKeyEquivalent(with: event) { return true }
                continue
            }
            guard item.matches(chars, flags) else { continue }
            if let s = supermenu ?? Optional(self) { s.delegate?.menuNeedsUpdate(self) }
            if autoenablesItems { item.validate() }
            guard item.isEnabled else { return false }
            item.perform()
            return true
        }
        return false
    }

    /// For backends that report KeyPress only.
    func performKeyEquivalent(_ key: KeyPress) -> Bool {
        var f: NSEvent.ModifierFlags = []
        if key.command { f.insert(.command) }
        if key.shift { f.insert(.shift) }
        if key.option { f.insert(.option) }
        let e = NSEvent(type: .keyDown, location: .zero, modifierFlags: f, timestamp: 0, window: NSApp.keyWindow,
                        characters: key.key, charactersIgnoringModifiers: key.key.count == 1 ? key.key : "")
        return performKeyEquivalent(with: e)
    }

    /// Shows the menu at `location` in `view` (or the screen) and returns
    /// once it closes; true when an item was chosen.
    @discardableResult
    open func popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        let window = view?.window ?? NSApp.keyWindow
        guard let window, let native = window.nativeWindow, let vs = Runway.backend as? ViewSystemBackend else { return false }
        let inWindow = view?.convert(location, to: nil) ?? location
        let point = CGPoint(x: inWindow.x, y: window.contentLayoutRect.height - inWindow.y)
        delegate?.menuWillOpen(self)
        let model = MenuModel(self, includeSelf: false)
        var chosen = false
        vs.popUpMenu(model.nodes, in: native, at: point, callbacks: MenuCallbacks(activate: { id in
            chosen = true
            model.items[id]?.perform()
        }, validate: { model.validate() }))
        // The menu took the button's release.
        NSEvent.pressedMouseButtons = 0
        delegate?.menuDidClose(self)
        return chosen
    }

    /// A context menu for `event` over `view`.
    public static func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        menu.popUp(positioning: nil, at: view.convert(event.locationInWindow, from: nil), in: view)
    }
    public static func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView, with font: NSFont?) {
        popUpContextMenu(menu, with: event, for: view)
    }
    public static func setMenuBarVisible(_ visible: Bool) {}
    public static func menuBarVisible() -> Bool { true }
}

/// Menu items can be made and configured on any thread (AppKit's aren't
/// main-actor bound); the menus that show them are.
open class NSMenuItem: NSObject, NSValidatedUserInterfaceItem, NSUserInterfaceItemIdentification, @unchecked Sendable {
    open var title: String { didSet { if title != oldValue { MenuBar.structureChanged() } } }
    open var attributedTitle: NSAttributedString?
    open var action: Selector?
    open weak var target: AnyObject?
    open var keyEquivalent: String { didSet { if keyEquivalent != oldValue { MenuBar.structureChanged() } } }
    open var keyEquivalentModifierMask: NSEvent.ModifierFlags = .command { didSet { MenuBar.structureChanged() } }
    open var submenu: NSMenu? {
        didSet {
            oldValue?.supermenu = nil
            submenu?.supermenu = menu
            MenuBar.structureChanged()
        }
    }
    open internal(set) weak var menu: NSMenu? { didSet { submenu?.supermenu = menu } }
    open var parent: NSMenuItem? { onMainThread { menu?.supermenu?.items.first { $0.submenu === menu } } }
    open var hasSubmenu: Bool { submenu != nil }
    open var isEnabled = true { didSet { if isEnabled != oldValue { MenuBar.stateChanged() } } }
    open var isHidden = false { didSet { if isHidden != oldValue { MenuBar.structureChanged() } } }
    open var isHiddenOrHasHiddenAncestor: Bool { isHidden || (parent?.isHiddenOrHasHiddenAncestor ?? false) }
    open var state: NSControl.StateValue = .off { didSet { if state != oldValue { MenuBar.stateChanged(); KVO.didChange(self, "state", old: oldValue, new: state) } } }
    open var tag = 0
    open var representedObject: Any?
    open var image: NSImage?
    /// A second line under the title (macOS 14).
    open var subtitle: String? { didSet { if subtitle != oldValue { MenuBar.structureChanged() } } }
    open var onStateImage: NSImage?
    open var offStateImage: NSImage?
    open var mixedStateImage: NSImage?
    open var toolTip: String?
    open var indentationLevel = 0
    open var isAlternate = false
    open var isHighlighted: Bool { false }
    open var allowsKeyEquivalentWhenHidden = false
    open var allowsAutomaticKeyEquivalentLocalization = true
    open var view: NSView?
    open var identifier: NSUserInterfaceItemIdentifier?
    open var userKeyEquivalent: String { keyEquivalent }
    open private(set) var isSeparatorItem = false
    open var badge: AnyObject?
    /// Runway: a closure to run instead of (or before resolving) the action.
    open var handler: ((NSMenuItem) -> Void)?
    let id: Int
    private static var nextID = 1

    public init(title: String, action: Selector?, keyEquivalent: String) {
        self.title = title
        self.action = action
        self.keyEquivalent = keyEquivalent
        id = NSMenuItem.nextID
        NSMenuItem.nextID += 1
        super.init()
    }
    public convenience override init() { self.init(title: "", action: nil, keyEquivalent: "") }
    public required init(coder: NSCoder) {
        title = ""; keyEquivalent = ""; id = NSMenuItem.nextID; NSMenuItem.nextID += 1
        super.init()
    }
    open func awakeFromNib() {}
    public static func separator() -> NSMenuItem {
        let i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        i.isSeparatorItem = true
        return i
    }
    public static func sectionHeader(title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }
    public static var usesUserKeyEquivalents: Bool { false }

    /// The object the action goes to: the target, or the responder chain's
    /// first object that handles the action.
    @MainActor var resolvedTarget: AnyObject? {
        guard let a = action else { return nil }
        return RunwayObjC.target(forAction: a, to: target, from: self)
    }

    /// Autoenabling: enabled when something handles the action and its
    /// validation agrees (items with handlers or submenus are enabled).
    @MainActor func validate() {
        if isSeparatorItem { return }
        if submenu != nil { submenu?.update(); return }
        if handler != nil { return }
        guard let t = resolvedTarget else { isEnabled = false; return }
        isEnabled = Validation.validate(self, with: t)
    }

    /// Sends the action (or runs the handler).
    @MainActor func perform() {
        if let h = handler { h(self); return }
        guard let a = action else { return }
        NSApp.sendAction(a, to: target, from: self)
    }

    func matches(_ chars: String, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard !keyEquivalent.isEmpty, !isSeparatorItem else { return false }
        let ke = keyEquivalent
        let isLetter = ke.count == 1 && ke.lowercased() != ke.uppercased()
        var want = keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
        if isLetter, ke != ke.lowercased() { want.insert(.shift) }
        var have = flags
        if !isLetter { have.remove(.shift); want.remove(.shift) }
        guard want == have else { return false }
        return ke.lowercased() == chars.lowercased() || (ke == "\r" && chars == "\u{3}")
    }

    /// The accelerator for GTK menus ("<Control><Shift>n"), for display.
    var accelerator: String? {
        guard !keyEquivalent.isEmpty, let c = keyEquivalent.unicodeScalars.first else { return nil }
        var m = keyEquivalentModifierMask
        let isLetter = keyEquivalent.lowercased() != keyEquivalent.uppercased()
        if isLetter, keyEquivalent != keyEquivalent.lowercased() { m.insert(.shift) }
        var s = ""
        if m.contains(.command) { s += "<Control>" }
        if m.contains(.shift) { s += "<Shift>" }
        if m.contains(.option) { s += "<Alt>" }
        if m.contains(.control) { s += "<Super>" }
        let names: [Int: String] = [NSUpArrowFunctionKey: "Up", NSDownArrowFunctionKey: "Down", NSLeftArrowFunctionKey: "Left", NSRightArrowFunctionKey: "Right",
                                    NSDeleteFunctionKey: "Delete", 0x7f: "BackSpace", 0x08: "BackSpace", 0x0d: "Return", 0x03: "KP_Enter", 0x09: "Tab", 0x1b: "Escape",
                                    0x20: "space", NSHomeFunctionKey: "Home", NSEndFunctionKey: "End", NSPageUpFunctionKey: "Page_Up", NSPageDownFunctionKey: "Page_Down"]
        if let n = names[Int(c.value)] { return s + n }
        if (NSF1FunctionKey...NSF12FunctionKey).contains(Int(c.value)) { return s + "F\(Int(c.value) - NSF1FunctionKey + 1)" }
        // A literal key: the GTK side maps it to its keysym name.
        return s + String(keyEquivalent.lowercased())
    }
}

// MARK: Menus as native menus

/// A menu tree flattened to backend nodes, with each node's item by id.
@MainActor final class MenuModel {
    var nodes: [MenuNode] = []
    var items: [Int: NSMenuItem] = [:]
    private var menus: [NSMenu] = []

    weak var root: NSMenu?
    init(_ menu: NSMenu, includeSelf: Bool) {
        root = menu
        menu.update()
        nodes = build(menu)
    }

    private func build(_ menu: NSMenu) -> [MenuNode] {
        menus.append(menu)
        var out: [MenuNode] = []
        for item in menu.items where !item.isHidden && !item.isAlternate {
            if item.isSeparatorItem { out.append(MenuNode(id: item.id, kind: .separator, title: "")); continue }
            items[item.id] = item
            if let sub = item.submenu {
                let title = sub.title.isEmpty ? item.title : sub.title
                out.append(MenuNode(id: item.id, kind: .submenu, title: title, enabled: item.isEnabled, children: build(sub)))
            } else {
                out.append(MenuNode(id: item.id, kind: .item, title: item.title, enabled: item.isEnabled, checked: item.state != .off,
                                    accelerator: item.accelerator))
            }
        }
        return out
    }

    /// Fresh enabled/checked state for every item (menus about to open).
    func validate() -> [MenuItemState] {
        for m in menus { m.update() }
        return items.values.map { MenuItemState(id: $0.id, enabled: $0.isEnabled, checked: $0.state != .off) }
    }
}

/// The main menu shown as each window's menu bar (GTK has no global menu
/// bar): rebuilt when the menu tree changes, validated when it opens.
@MainActor enum MenuBar {
    private static var model: MenuModel?
    private static var rebuildScheduled = false
    private static var windows: [WeakWindow] = []
    private struct WeakWindow { weak var window: NSWindow? }

    static func mainMenuChanged() { rebuild() }

    /// The menu tree changed (from any thread: menu items aren't tied to
    /// the main actor, as AppKit's aren't); the bar is rebuilt on the main one.
    nonisolated static func structureChanged() {
        if Thread.isMainThread { MainActor.assumeIsolated { scheduleRebuild() } } else { DispatchQueue.main.async { scheduleRebuild() } }
    }
    /// Set while the bar's model is built: menus brought up to date then
    /// (menuNeedsUpdate(_:) refilling them) are in the model being built.
    private static var building = false
    private static func scheduleRebuild() {
        guard !building, !rebuildScheduled, NSApp.mainMenu != nil || model != nil else { return }
        rebuildScheduled = true
        Runway.backend.schedule { rebuild() }
    }
    nonisolated static func stateChanged() {}

    private static func callbacks() -> MenuCallbacks {
        MenuCallbacks(activate: { id in
            model?.items[id]?.perform()
            ViewSystem.flush()
        }, validate: { model?.validate() ?? [] })
    }

    /// The bar's top-level entries; the first (the app menu) is titled with
    /// the app's name, as the Mac shows it.
    private static func barNodes(_ m: MenuModel) -> [MenuNode] {
        var nodes = m.nodes
        if var first = nodes.first, first.kind == .submenu {
            if first.title.isEmpty || first.title == "Apple" {
                first.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
            }
            nodes[0] = first
        }
        return nodes
    }

    static func rebuild() {
        rebuildScheduled = false
        guard let main = NSApp.mainMenu else {
            model = nil
            for w in windows.compactMap(\.window) { if let n = w.nativeWindow { (Runway.backend as? ViewSystemBackend)?.setMenuBar(nil, in: n, callbacks: callbacks()) } }
            return
        }
        building = true
        let m = MenuModel(main, includeSelf: false)
        building = false
        model = m
        windows.removeAll { $0.window == nil }
        for w in windows.compactMap(\.window) { install(m, on: w) }
    }

    private static func install(_ m: MenuModel, on w: NSWindow) {
        guard let n = w.nativeWindow, let vs = Runway.backend as? ViewSystemBackend else { return }
        vs.setMenuBar(barNodes(m), in: n, callbacks: callbacks())
    }

    /// Gives a newly shown titled window the menu bar.
    static func install(on w: NSWindow) {
        guard w.styleMask.contains(.titled), !w.isSheet, !w.isModal, NSApp.mainMenu != nil else { return }
        if !windows.contains(where: { $0.window === w }) { windows.append(WeakWindow(window: w)) }
        if let main = NSApp.mainMenu, model == nil || model?.root !== main {
            building = true
            model = MenuModel(main, includeSelf: false)
            building = false
        }
        if let m = model { install(m, on: w) }
    }

    /// Re-validates the main menu (after focus changes) so key equivalents
    /// and the bar see current state.
    static func validateAll() {
        guard let m = model else { return }
        _ = m.validate()
    }
}


// MARK: Menu notifications

extension NSMenu {
    public static let willSendActionNotification = Notification.Name("NSMenuWillSendActionNotification")
    public static let didSendActionNotification = Notification.Name("NSMenuDidSendActionNotification")
    public static let didAddItemNotification = Notification.Name("NSMenuDidAddItemNotification")
    public static let didRemoveItemNotification = Notification.Name("NSMenuDidRemoveItemNotification")
    public static let didChangeItemNotification = Notification.Name("NSMenuDidChangeItemNotification")
    public static let didBeginTrackingNotification = Notification.Name("NSMenuDidBeginTrackingNotification")
    public static let didEndTrackingNotification = Notification.Name("NSMenuDidEndTrackingNotification")
}
