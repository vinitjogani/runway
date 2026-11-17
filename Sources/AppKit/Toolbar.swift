// NSToolbar as the Mac's unified titlebar: the window's title and toolbar
// items share one band under the titlebar row (WindowChrome.swift), items
// made by the delegate, flexible spaces, the sidebar and inspector tracking
// separators lining items up with the split view's dividers, item groups,
// menu items and search items.

import Foundation
import CoreGraphics
import RunwayCore
import RunwayObjC

@preconcurrency @MainActor public protocol NSToolbarDelegate: AnyObject {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem?
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier]
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier]
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier]
    func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier>
    func toolbarWillAddItem(_ notification: Notification)
    func toolbarDidRemoveItem(_ notification: Notification)
}
extension NSToolbarDelegate {
    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [] }
    public func toolbarImmovableItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> { [] }
    public func toolbarWillAddItem(_ notification: Notification) {}
    public func toolbarDidRemoveItem(_ notification: Notification) {}
}

@preconcurrency @MainActor
open class NSToolbar: NSObject {
    public typealias Identifier = String
    public enum DisplayMode: UInt, Sendable { case `default` = 0, iconAndLabel, iconOnly, labelOnly }
    public enum SizeMode: UInt, Sendable { case `default` = 0, regular, small }
    public static let willAddItemNotification = Notification.Name("NSToolbarWillAddItemNotification")
    public static let didRemoveItemNotification = Notification.Name("NSToolbarDidRemoveItemNotification")

    public let identifier: Identifier
    open weak var delegate: NSToolbarDelegate? { didSet { reload() } }
    open var displayMode: DisplayMode = .default { didSet { strip?.relayout() } }
    open var sizeMode: SizeMode = .default
    open var isVisible = true { didSet { window?.toolbarDidChange(from: nil) } }
    open var allowsUserCustomization = false
    open var allowsExtensionItems = false
    open var autosavesConfiguration = false
    open var showsBaselineSeparator = true
    open var centeredItemIdentifier: NSToolbarItem.Identifier? { didSet { strip?.relayout() } }
    open var centeredItemIdentifiers: Set<NSToolbarItem.Identifier> = [] { didSet { strip?.relayout() } }
    open var selectedItemIdentifier: NSToolbarItem.Identifier? { didSet { strip?.relayout() } }
    open private(set) var items: [NSToolbarItem] = []
    open var visibleItems: [NSToolbarItem]? { items.filter { $0.isVisible } }
    open var customizationPaletteIsRunning: Bool { false }
    weak var window: NSWindow?
    var strip: ToolbarStrip?

    public init(identifier: Identifier) { self.identifier = identifier; super.init() }
    public override convenience init() { self.init(identifier: "") }

    /// Asks the delegate for its default items.
    func reload() {
        for i in items { i.toolbar = nil }
        items = (delegate?.toolbarDefaultItemIdentifiers(self) ?? []).compactMap { makeItem($0) }
        strip?.rebuild()
    }

    private func makeItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        let item: NSToolbarItem?
        switch id {
        case .flexibleSpace, .space, .separator, .sidebarTrackingSeparator, .inspectorTrackingSeparator:
            item = delegate?.toolbar(self, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true) ?? NSToolbarItem(itemIdentifier: id)
        case .toggleSidebar:
            item = delegate?.toolbar(self, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true) ?? {
                let t = NSToolbarItem(itemIdentifier: id)
                t.label = "Sidebar"
                t.toolTip = "Hide or show the sidebar"
                t.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Sidebar")
                t.action = Selector("toggleSidebar:")
                return t
            }()
        case .toggleInspector:
            item = delegate?.toolbar(self, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true) ?? {
                let t = NSToolbarItem(itemIdentifier: id)
                t.label = "Inspector"
                t.toolTip = "Hide or show the inspector"
                t.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Inspector")
                t.action = Selector("toggleInspector:")
                return t
            }()
        default:
            item = delegate?.toolbar(self, itemForItemIdentifier: id, willBeInsertedIntoToolbar: true)
        }
        item?.toolbar = self
        if let item {
            let n = Notification(name: Self.willAddItemNotification, object: self, userInfo: ["item": item])
            delegate?.toolbarWillAddItem(n)
            NotificationCenter.default.post(n)
        }
        return item
    }

    open func insertItem(withItemIdentifier id: NSToolbarItem.Identifier, at i: Int) {
        guard let item = makeItem(id) else { return }
        items.insert(item, at: min(max(0, i), items.count))
        strip?.rebuild()
    }
    open func removeItem(at i: Int) {
        guard items.indices.contains(i) else { return }
        let item = items.remove(at: i)
        item.toolbar = nil
        let n = Notification(name: Self.didRemoveItemNotification, object: self, userInfo: ["item": item])
        delegate?.toolbarDidRemoveItem(n)
        NotificationCenter.default.post(n)
        strip?.rebuild()
    }
    open func removeItem(identifier: NSToolbarItem.Identifier) {
        if let i = items.firstIndex(where: { $0.itemIdentifier == identifier }) { removeItem(at: i) }
    }
    open func validateVisibleItems() { for i in items { i.validate() } }
    open func runCustomizationPalette(_ sender: Any?) {}
    open func setConfigurationFrom(_ d: [String: Any]) {}
    open var configuration: [String: Any] { [:] }
}

@preconcurrency @MainActor
open class NSToolbarItem: NSObject, NSValidatedUserInterfaceItem {
    public struct Identifier: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public var description: String { rawValue }
    }
    public struct VisibilityPriority: RawRepresentable, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let standard = VisibilityPriority(rawValue: 0), low = VisibilityPriority(rawValue: -1000)
        public static let high = VisibilityPriority(rawValue: 1000), user = VisibilityPriority(rawValue: 2000)
    }
    public let itemIdentifier: Identifier
    open internal(set) weak var toolbar: NSToolbar?
    open var label = "" { didSet { changed() } }
    open var paletteLabel = ""
    open var possibleLabels: Set<String> = []
    open var title = "" { didSet { changed() } }
    open var toolTip: String? { didSet { changed() } }
    open var image: NSImage? { didSet { changed() } }
    open var view: NSView? { didSet { changed() } }
    open weak var target: AnyObject?
    open var action: Selector?
    /// Runway: run when the item is clicked (see NSControl.handler).
    open var handler: ((NSToolbarItem) -> Void)?
    open var isEnabled = true { didSet { changed() } }
    open var isBordered = false { didSet { changed() } }
    open var isNavigational = false
    open var isHidden = false { didSet { changed() } }
    open var isVisible: Bool { !isHidden }
    open var tag = 0
    open var autovalidates = true
    open var visibilityPriority: VisibilityPriority = .standard
    open var menuFormRepresentation: NSMenuItem?
    open var minSize: CGSize = .zero
    open var maxSize: CGSize = .zero
    /// How the item is drawn (macOS 26): plain, or prominent (tinted).
    public enum Style: Int, Sendable { case plain = 0, prominent = 1 }
    open var style: Style = .plain { didSet { if style != oldValue { changed() } } }
    open var backgroundTintColor: NSColor?
    open var allowsDuplicatesInToolbar: Bool { false }

    public init(itemIdentifier: Identifier) { self.itemIdentifier = itemIdentifier; super.init() }

    func changed() { toolbar?.strip?.itemChanged(self) }

    /// Enables the item by what its action's target says: the target (or
    /// the first responder that handles the action) is asked through
    /// `validateToolbarItem(_:)` (NSToolbarItemValidation), then
    /// `validateUserInterfaceItem(_:)`; an action no one handles disables
    /// the item. Items with a view, a handler or no action are left alone.
    open func validate() {
        guard autovalidates, view == nil, handler == nil, let a = action,
              itemIdentifier != .toggleSidebar, a.name != "toggleSidebar:",
              itemIdentifier != .toggleInspector, a.name != "toggleInspector:" else { return }
        let enabled: Bool
        if let t = NSApp.target(forAction: a, to: target, from: self) {
            enabled = ToolbarValidation.validate(self, with: t as AnyObject)
        } else {
            enabled = false
        }
        if enabled != isEnabled { isEnabled = enabled }
    }

    /// The click: handler, the standard sidebar toggle, then the action.
    func perform(sender: Any?) {
        guard isEnabled else { return }
        if let h = handler { h(self); return }
        if itemIdentifier == .toggleSidebar || action == Selector("toggleSidebar:") {
            (toolbar?.window?.contentViewController as? NSSplitViewController)?.toggleSidebar(self)
            return
        }
        if itemIdentifier == .toggleInspector, action == Selector("toggleInspector:"),
           NSApp.target(forAction: Selector("toggleInspector:"), to: target, from: self) == nil {
            (toolbar?.window?.contentViewController as? NSSplitViewController)?.toggleInspector(self)
            return
        }
        guard let a = action else { return }
        _ = NSApp.sendAction(a, to: target, from: self)
    }
}

extension NSToolbarItem.Identifier {
    public static let flexibleSpace = NSToolbarItem.Identifier("NSToolbarFlexibleSpaceItem")
    public static let space = NSToolbarItem.Identifier("NSToolbarSpaceItem")
    public static let separator = NSToolbarItem.Identifier("NSToolbarSeparatorItem")
    public static let sidebarTrackingSeparator = NSToolbarItem.Identifier("NSToolbarSidebarTrackingSeparatorItemIdentifier")
    public static let inspectorTrackingSeparator = NSToolbarItem.Identifier("NSToolbarInspectorTrackingSeparatorItemIdentifier")
    public static let toggleSidebar = NSToolbarItem.Identifier("NSToolbarToggleSidebarItem")
    public static let toggleInspector = NSToolbarItem.Identifier("NSToolbarToggleInspectorItem")
    public static let showColors = NSToolbarItem.Identifier("NSToolbarShowColorsItem")
    public static let showFonts = NSToolbarItem.Identifier("NSToolbarShowFontsItem")
    public static let print = NSToolbarItem.Identifier("NSToolbarPrintItem")
    public static let cloudSharing = NSToolbarItem.Identifier("NSToolbarCloudSharingItem")
    public static let writingTools = NSToolbarItem.Identifier("NSToolbarWritingToolsItem")
}

@preconcurrency @MainActor
open class NSToolbarItemGroup: NSToolbarItem {
    public enum SelectionMode: Int, Sendable { case selectOne = 0, selectAny, momentary }
    public enum ControlRepresentation: Int, Sendable { case automatic = 0, expanded, collapsed }
    open var subitems: [NSToolbarItem] = [] { didSet { changed() } }
    open var selectionMode: SelectionMode = .momentary { didSet { changed() } }
    open var controlRepresentation: ControlRepresentation = .automatic
    open var selectedIndex: Int = -1 { didSet { changed() } }
    private var selected: Set<Int> = []

    public convenience init(itemIdentifier: Identifier, titles: [String], selectionMode: SelectionMode, labels: [String]?, target: AnyObject?, action: Selector?) {
        self.init(itemIdentifier: itemIdentifier)
        self.selectionMode = selectionMode
        subitems = titles.enumerated().map { i, t in
            let s = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("\(itemIdentifier.rawValue).\(i)"))
            s.title = t
            s.label = labels?[safe: i] ?? t
            return s
        }
        self.target = target
        self.action = action
    }
    public convenience init(itemIdentifier: Identifier, images: [NSImage], selectionMode: SelectionMode, labels: [String]?, target: AnyObject?, action: Selector?) {
        self.init(itemIdentifier: itemIdentifier)
        self.selectionMode = selectionMode
        subitems = images.enumerated().map { i, img in
            let s = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier("\(itemIdentifier.rawValue).\(i)"))
            s.image = img
            s.label = labels?[safe: i] ?? ""
            return s
        }
        self.target = target
        self.action = action
    }
    open func setSelected(_ on: Bool, at i: Int) {
        if on { selected.insert(i) } else { selected.remove(i) }
        if selectionMode == .selectOne { selectedIndex = on ? i : -1 } else { changed() }
    }
    open func isSelected(at i: Int) -> Bool { selectionMode == .selectOne ? selectedIndex == i : selected.contains(i) }
}

@preconcurrency @MainActor
open class NSMenuToolbarItem: NSToolbarItem {
    open var menu = NSMenu(title: "") { didSet { changed() } }
    open var showsIndicator = true { didSet { changed() } }
}

@preconcurrency @MainActor
open class NSSearchToolbarItem: NSToolbarItem {
    open var searchField = NSSearchField(frame: CGRect(x: 0, y: 0, width: 180, height: 22)) { didSet { changed() } }
    open var preferredWidthForSearchField: CGFloat = 180 { didSet { changed() } }
    open var resignsFirstResponderWithCancel = true
    open func beginSearchInteraction() { searchField._runwayFocus() }
    open func endSearchInteraction() {}
}

@preconcurrency @MainActor
open class NSTrackingSeparatorToolbarItem: NSToolbarItem {
    open weak var splitView: NSSplitView?
    open var dividerIndex = 0
    public convenience init(identifier: Identifier, splitView: NSSplitView, dividerIndex: Int) {
        self.init(itemIdentifier: identifier)
        self.splitView = splitView
        self.dividerIndex = dividerIndex
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: The strip

/// The toolbar's band: the window's title and the items, below the
/// backend's titlebar row (see WindowChrome.swift).
@MainActor final class ToolbarStrip: NSView {
    override var isFlipped: Bool { true }
    weak var toolbar: NSToolbar?
    weak var hostWindowRef: NSWindow?
    private var itemViews: [ObjectIdentifier: NSView] = [:]
    private var labels: [ObjectIdentifier: NSTextField] = [:]
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private var observer: NSObjectProtocol?
    static let height: CGFloat = 46
    /// Over full-size content the band has no material of its own (the
    /// content shows through, as under macOS 26's toolbar) and clicks on
    /// its empty parts reach the content; above content it's the titlebar.
    var floatsOverContent = false {
        didSet {
            Runway.appKit?.setPassesThrough(widget, floatsOverContent)
            needsDisplay = true
        }
    }

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain {
            titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            titleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = .secondaryLabelColor
            subtitleLabel.lineBreakMode = .byTruncatingTail
            addSubview(titleLabel)
            addSubview(subtitleLabel)
            observer = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }

    /// The titlebar's material and its hairline, unless the band floats.
    override func draw(_ dirtyRect: NSRect) {
        guard !floatsOverContent else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    /// The band itself isn't a target: items are, and the rest is the
    /// titlebar (or, floating, the content under it).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === titleLabel || hit === subtitleLabel || labels.values.contains(where: { $0 === hit }) ? self : hit
    }

    /// Makes each item's view: its own, or a toolbar button.
    func rebuild() {
        for v in itemViews.values { v.removeFromSuperview() }
        itemViews.removeAll()
        for l in labels.values { l.removeFromSuperview() }
        labels.removeAll()
        for item in toolbar?.items ?? [] { makeView(item) }
        relayout()
    }

    private var showsLabels: Bool { toolbar?.displayMode == .iconAndLabel || toolbar?.displayMode == .labelOnly }

    private func makeView(_ item: NSToolbarItem) {
        let id = ObjectIdentifier(item)
        let v: NSView?
        switch item {
        case let g as NSToolbarItemGroup:
            let seg = NSSegmentedControl(frame: .zero)
            seg.segmentStyle = .texturedRounded
            seg.trackingMode = g.selectionMode == .selectOne ? .selectOne : g.selectionMode == .selectAny ? .selectAny : .momentary
            seg.segmentCount = g.subitems.count
            for (i, s) in g.subitems.enumerated() {
                if let img = s.image { seg.setImage(img, forSegment: i) } else { seg.setLabel(s.title.isEmpty ? s.label : s.title, forSegment: i) }
                seg.setSelected(g.isSelected(at: i), forSegment: i)
                seg.setToolTip(s.toolTip ?? s.label, forSegment: i)
            }
            seg.handler = { [weak g] c in
                guard let g, let seg = c as? NSSegmentedControl else { return }
                let i = seg.selectedSegment
                if g.selectionMode == .selectOne { g.selectedIndex = i }
                if g.subitems.indices.contains(i), g.subitems[i].action != nil || g.subitems[i].handler != nil { g.subitems[i].perform(sender: g) }
                else { g.perform(sender: g) }
            }
            seg.sizeToFit()
            v = seg
        case let s as NSSearchToolbarItem:
            s.searchField.frame.size = CGSize(width: s.preferredWidthForSearchField, height: 22)
            v = s.searchField
        case let m as NSMenuToolbarItem:
            let b = toolbarButton(item)
            b.handler = { [weak m, weak b] _ in
                guard let m, let b else { return }
                Runway.appKit?.popUpMenu(m.menu.specs(), in: b.widget, at: CGPoint(x: 0, y: b.bounds.height + 4))
            }
            v = b
        default:
            switch item.itemIdentifier {
            case .flexibleSpace, .space, .sidebarTrackingSeparator, .inspectorTrackingSeparator, .separator: v = nil
            default: v = item.view ?? toolbarButton(item)
            }
        }
        if let v {
            itemViews[id] = v
            addSubview(v)
        }
        if showsLabels, v != nil, !item.label.isEmpty {
            let l = NSTextField(labelWithString: item.label)
            l.font = .systemFont(ofSize: 10)
            l.textColor = .secondaryLabelColor
            l.alignment = .center
            labels[id] = l
            addSubview(l)
        }
    }

    private func toolbarButton(_ item: NSToolbarItem) -> NSButton {
        let b: NSButton
        if let img = item.image, toolbar?.displayMode != .labelOnly {
            b = NSButton(image: img, target: nil, action: nil)
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            if !item.title.isEmpty { b.title = item.title; b.imagePosition = .imageLeading }
        } else {
            b = NSButton(title: item.title.isEmpty ? item.label : item.title, target: nil, action: nil)
        }
        b.bezelStyle = .texturedRounded
        b.isBordered = item.isBordered
        b.toolTip = item.toolTip ?? item.label
        b.isEnabled = item.isEnabled
        b.handler = { [weak item] c in item?.perform(sender: c) }
        if toolbar?.selectedItemIdentifier == item.itemIdentifier { b.setButtonType(.pushOnPushOff); b.state = .on }
        b.sizeToFit()
        b.frame.size = CGSize(width: max(32, b.frame.width), height: 28)
        return b
    }

    func itemChanged(_ item: NSToolbarItem) {
        if let v = itemViews[ObjectIdentifier(item)] { v.removeFromSuperview(); itemViews[ObjectIdentifier(item)] = nil }
        labels[ObjectIdentifier(item)]?.removeFromSuperview()
        labels[ObjectIdentifier(item)] = nil
        if toolbar?.items.contains(where: { $0 === item }) == true { makeView(item) }
        relayout()
    }

    // MARK: Layout

    /// The split view a tracking separator follows: its own, or the
    /// window's split view controller's.
    private func trackedSplitView(_ sep: NSToolbarItem) -> NSSplitView? {
        if let s = (sep as? NSTrackingSeparatorToolbarItem)?.splitView { return s }
        return (hostWindowRef?.contentViewController as? NSSplitViewController)?.splitView
    }

    /// The sidebar's trailing edge in the band (nil while it's collapsed).
    private func sidebarEdge(_ sep: NSToolbarItem) -> CGFloat? {
        guard let s = trackedSplitView(sep), s.window === hostWindowRef, s.arrangedSubviews.count > 1 else { return nil }
        let index = (sep as? NSTrackingSeparatorToolbarItem)?.dividerIndex ?? 0
        guard s.arrangedSubviews.indices.contains(index), !s.isSubviewCollapsed(s.arrangedSubviews[index]) else { return nil }
        let x = s.convert(CGPoint(x: s.position(ofDividerAt: index), y: 0), to: nil).x
        return x > 0 ? x : nil
    }

    /// The inspector's leading edge in the band (nil while it's collapsed).
    private func inspectorEdge(_ sep: NSToolbarItem) -> CGFloat? {
        guard let s = trackedSplitView(sep), s.window === hostWindowRef, s.arrangedSubviews.count > 1 else { return nil }
        let last = s.arrangedSubviews.count - 1
        let index = (sep as? NSTrackingSeparatorToolbarItem).map { $0.splitView != nil ? $0.dividerIndex : last - 1 } ?? last - 1
        guard s.arrangedSubviews.indices.contains(index + 1), !s.isSubviewCollapsed(s.arrangedSubviews[index + 1]) else { return nil }
        let x = s.convert(CGPoint(x: s.position(ofDividerAt: index) + s.dividerThickness, y: 0), to: nil).x
        return x < bounds.width ? x : nil
    }

    func relayout() {
        guard let toolbar else { return }
        let w = bounds.width, h = bounds.height
        if let win = hostWindowRef {
            titleLabel.stringValue = win.titleVisibility == .visible ? win.title : ""
            subtitleLabel.stringValue = win.titleVisibility == .visible ? win.subtitle : ""
        }
        titleLabel.isHidden = titleLabel.stringValue.isEmpty
        subtitleLabel.isHidden = subtitleLabel.stringValue.isEmpty
        // Split the items at the tracking separators: over the sidebar,
        // over the content (with the title), over the inspector.
        var items = toolbar.items.filter { !$0.isHidden }
        var lead: [NSToolbarItem] = [], trail: [NSToolbarItem] = []
        var leadEdge: CGFloat?, trailEdge: CGFloat?
        if let i = items.firstIndex(where: { $0.itemIdentifier == .sidebarTrackingSeparator }) {
            leadEdge = sidebarEdge(items[i])
            if leadEdge != nil { lead = Array(items[..<i]) }
            items = leadEdge != nil ? Array(items[(i + 1)...]) : items.filter { $0 !== items[i] }
        }
        if let i = items.firstIndex(where: { $0.itemIdentifier == .inspectorTrackingSeparator }) {
            trailEdge = inspectorEdge(items[i])
            if trailEdge != nil { trail = Array(items[(i + 1)...]) }
            items = trailEdge != nil ? Array(items[..<i]) : items.filter { $0 !== items[i] }
        }

        func width(_ item: NSToolbarItem) -> CGFloat {
            switch item.itemIdentifier {
            case .flexibleSpace: return 0
            case .space: return 8
            case .separator: return 9
            default:
                guard let v = itemViews[ObjectIdentifier(item)] else { return 0 }
                let lw = labels[ObjectIdentifier(item)].map { $0.intrinsicContentSize.width } ?? 0
                return max(v.frame.width, lw)
            }
        }
        func place(_ list: [NSToolbarItem], from x0: CGFloat, to x1: CGFloat, title: Bool) {
            var x = x0
            if title, !titleLabel.isHidden {
                let ts = titleLabel.intrinsicContentSize
                let ss = subtitleLabel.isHidden ? .zero : subtitleLabel.intrinsicContentSize
                let fixed = list.map(width).reduce(0, +) + CGFloat(list.count) * 6
                let tw = max(0, min(max(ts.width, ss.width), x1 - x - fixed - 16))
                let total = ts.height + ss.height
                titleLabel.frame = CGRect(x: x, y: ((h - total) / 2).rounded(), width: min(ts.width, tw), height: ts.height)
                subtitleLabel.frame = CGRect(x: x, y: titleLabel.frame.maxY, width: min(ss.width, tw), height: ss.height)
                x += tw + 16
            }
            let fixed = list.map(width).reduce(0, +) + CGFloat(max(0, list.count - 1)) * 6
            let flex = list.filter { $0.itemIdentifier == .flexibleSpace }
            let leftover = max(0, x1 - x - fixed)
            // With no flexible space, items sit at the trailing edge, as on the Mac.
            if flex.isEmpty { x += leftover }
            for item in list {
                var iw = width(item)
                if item.itemIdentifier == .flexibleSpace { iw = leftover / CGFloat(flex.count) }
                if let v = itemViews[ObjectIdentifier(item)] {
                    let label = labels[ObjectIdentifier(item)]
                    let lh: CGFloat = label == nil ? 0 : 13
                    let vh = v.frame.height > 0 ? min(v.frame.height, h - lh) : 28
                    let top = ((h - vh - lh) / 2).rounded()
                    v.frame = CGRect(x: (x + (iw - v.frame.width) / 2).rounded(), y: top, width: v.frame.width, height: vh)
                    label?.frame = CGRect(x: x, y: top + vh, width: iw, height: lh)
                }
                x += iw + 6
            }
        }
        let mainStart = (leadEdge ?? 0) + (leadEdge == nil ? 14 : 12)
        let mainEnd = (trailEdge ?? w) - (trailEdge == nil ? 10 : 8)
        if let e = leadEdge { place(lead, from: 8, to: e - 8, title: false) }
        place(items, from: mainStart, to: mainEnd, title: true)
        if let e = trailEdge { place(trail, from: e + 8, to: w - 10, title: false) }
        layoutSubviews()
    }

    override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); relayout() }
}

// MARK: Window hooks

/// Installs a window's toolbar once it's on screen.
@MainActor private final class ToolbarInstaller {
    static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]
}

extension NSWindow {
    /// The window's toolbar, shown in its titlebar.
    public var toolbar: NSToolbar? {
        get { _runwayToolbar as? NSToolbar }
        set {
            let old = toolbar
            _runwayToolbar = newValue
            toolbarDidChange(from: old)
        }
    }


    /// The toolbar changed: the band's height counts at once (for the
    /// content's safe area); its items are made once the window is shown.
    func toolbarDidChange(from old: NSToolbar?) {
        if let old, old !== toolbar { old.strip = nil; old.window = nil }
        if let t = toolbar { t.window = self }
        if nativeWindow == nil {
            chromeDidChange()
            let id = ObjectIdentifier(self)
            guard ToolbarInstaller.observers[id] == nil else { return }
            ToolbarInstaller.observers[id] = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: self, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    if let o = ToolbarInstaller.observers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(o) }
                    self?.installToolbarStrip()
                }
            }
            return
        }
        installToolbarStrip()
    }

    private func installToolbarStrip() {
        if let t = toolbar, t.isVisible {
            let strip = t.strip ?? ToolbarStrip(frame: CGRect(x: 0, y: 0, width: frame.width, height: toolbarBandHeight))
            strip.toolbar = t
            strip.hostWindowRef = self
            t.strip = strip
            if t.items.isEmpty { t.reload() } else { strip.rebuild() }
        }
        chromeDidChange()
    }
}

/// Toolbar item validation (`validateToolbarItem(_:)`), asked of an item's
/// target before it's shown and after each event.
@preconcurrency @MainActor public protocol NSToolbarItemValidation: AnyObject {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool
}

enum ToolbarValidation {
    @MainActor static func validate(_ item: NSToolbarItem, with target: AnyObject) -> Bool {
        if let v = target as? NSToolbarItemValidation { return v.validateToolbarItem(item) }
        if RunwayObjC.responds(target, to: Selector("validateToolbarItem:")) {
            return (RunwayObjC.perform(target, Selector("validateToolbarItem:"), [item]) as? Bool) ?? true
        }
        if let v = target as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
        if RunwayObjC.responds(target, to: Selector("validateUserInterfaceItem:")) {
            return (RunwayObjC.perform(target, Selector("validateUserInterfaceItem:"), [item]) as? Bool) ?? true
        }
        return true
    }
}
