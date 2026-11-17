// NSTabView (a segmented control over a rounded panel, as the Mac draws
// tabs) and NSTabViewController (segmented tabs, or a Settings-style
// toolbar of icons and labels).

import Foundation
import CoreGraphics
import RunwayCore

@preconcurrency @MainActor public protocol NSTabViewDelegate: AnyObject {
    func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool
    func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?)
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?)
    func tabViewDidChangeNumberOfTabViewItems(_ tabView: NSTabView)
}
extension NSTabViewDelegate {
    public func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool { true }
    public func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {}
    public func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {}
    public func tabViewDidChangeNumberOfTabViewItems(_ tabView: NSTabView) {}
}

@preconcurrency @MainActor
open class NSTabViewItem: NSObject {
    public enum State: UInt, Sendable { case selectedTab = 0, backgroundTab, pressedTab }
    open var identifier: Any?
    open var label = "" { didSet { tabView?.updateTabs() } }
    open var toolTip: String?
    open var image: NSImage? { didSet { tabView?.updateTabs() } }
    open var color: NSColor = .controlColor
    open var initialFirstResponder: NSView?
    open var viewController: NSViewController? { didSet { if let vc = viewController { view = vc.view } } }
    open var view: NSView? { didSet { if tabView?.selectedTabViewItem === self { tabView?.showSelected() } } }
    open internal(set) weak var tabView: NSTabView?
    open var tabState: State { tabView?.selectedTabViewItem === self ? .selectedTab : .backgroundTab }
    public init(identifier: Any?) { self.identifier = identifier; super.init() }
    public convenience init(viewController: NSViewController) {
        self.init(identifier: nil)
        self.viewController = viewController
        view = viewController.view
        label = viewController.title ?? ""
    }
    open func sizeOfLabel(_ shouldTruncate: Bool) -> CGSize {
        let l = LabelWidget()
        l.set(label)
        return l.size()
    }
}

@preconcurrency @MainActor
open class NSTabView: NSView {
    open override var isFlipped: Bool { true }
    public enum TabType: UInt, Sendable { case topTabsBezelBorder = 0, leftTabsBezelBorder, bottomTabsBezelBorder, rightTabsBezelBorder, noTabsBezelBorder, noTabsLineBorder, noTabsNoBorder }
    public enum TabPosition: UInt, Sendable { case none = 0, top, left, bottom, right }
    public enum TabViewBorderType: UInt, Sendable { case none = 0, line, bezel }

    open weak var delegate: NSTabViewDelegate?
    open private(set) var tabViewItems: [NSTabViewItem] = []
    open private(set) var selectedTabViewItem: NSTabViewItem?
    open var tabViewType: TabType = .topTabsBezelBorder { didSet { updateTabs() } }
    open var tabPosition: TabPosition {
        get { [.topTabsBezelBorder: .top, .bottomTabsBezelBorder: .bottom, .leftTabsBezelBorder: .left, .rightTabsBezelBorder: .right][tabViewType] ?? .none }
        set { tabViewType = newValue == .bottom ? .bottomTabsBezelBorder : newValue == .none ? .noTabsBezelBorder : .topTabsBezelBorder }
    }
    open var tabViewBorderType: TabViewBorderType = .bezel { didSet { updateTabs() } }
    open var drawsBackground = true
    open var allowsTruncatedLabels = true
    open var font: NSFont = .systemFont(ofSize: 13)
    open var controlSize: NSControl.ControlSize = .regular
    open var minimumSize: CGSize { CGSize(width: 50, height: 50) }
    open var numberOfTabViewItems: Int { tabViewItems.count }
    private let tabs = NSSegmentedControl(frame: .zero)
    private let backdrop = DrawnLayer()
    private var shownView: NSView?

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain {
            tabs.trackingMode = .selectOne
            tabs.handler = { [weak self] c in self?.selectTabViewItem(at: (c as! NSSegmentedControl).selectedSegment) }
            addSubview(tabs)
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        onMain {
            tabs.trackingMode = .selectOne
            tabs.handler = { [weak self] c in self?.selectTabViewItem(at: (c as! NSSegmentedControl).selectedSegment) }
            addSubview(tabs)
        }
        IBDecoding.leave(self, coder)
    }

    open func addTabViewItem(_ item: NSTabViewItem) { insertTabViewItem(item, at: tabViewItems.count) }
    open func insertTabViewItem(_ item: NSTabViewItem, at i: Int) {
        item.tabView = self
        tabViewItems.insert(item, at: min(i, tabViewItems.count))
        updateTabs()
        if selectedTabViewItem == nil { selectTabViewItem(item) }
        delegate?.tabViewDidChangeNumberOfTabViewItems(self)
    }
    open func removeTabViewItem(_ item: NSTabViewItem) {
        let wasSelected = selectedTabViewItem === item
        tabViewItems.removeAll { $0 === item }
        item.tabView = nil
        if wasSelected { selectedTabViewItem = nil; selectTabViewItem(tabViewItems.first) }
        updateTabs()
        delegate?.tabViewDidChangeNumberOfTabViewItems(self)
    }
    open func indexOfTabViewItem(_ item: NSTabViewItem) -> Int { tabViewItems.firstIndex { $0 === item } ?? NSNotFound }
    open func indexOfTabViewItem(withIdentifier id: Any) -> Int {
        tabViewItems.firstIndex { ($0.identifier as? AnyHashable) == (id as? AnyHashable) } ?? NSNotFound
    }
    open func tabViewItem(at i: Int) -> NSTabViewItem { tabViewItems[i] }

    open func selectTabViewItem(_ item: NSTabViewItem?) {
        guard item !== selectedTabViewItem else { return }
        guard delegate?.tabView(self, shouldSelect: item) ?? true else { updateTabs(); return }
        delegate?.tabView(self, willSelect: item)
        selectedTabViewItem = item
        showSelected()
        updateTabs()
        delegate?.tabView(self, didSelect: item)
    }
    open func selectTabViewItem(at i: Int) { if tabViewItems.indices.contains(i) { selectTabViewItem(tabViewItems[i]) } }
    open func selectTabViewItem(withIdentifier id: Any) { let i = indexOfTabViewItem(withIdentifier: id); if i != NSNotFound { selectTabViewItem(at: i) } }
    open func selectFirstTabViewItem(_ sender: Any?) { selectTabViewItem(at: 0) }
    open func selectLastTabViewItem(_ sender: Any?) { selectTabViewItem(at: tabViewItems.count - 1) }
    open func selectNextTabViewItem(_ sender: Any?) { if let s = selectedTabViewItem { selectTabViewItem(at: indexOfTabViewItem(s) + 1) } }
    open func selectPreviousTabViewItem(_ sender: Any?) { if let s = selectedTabViewItem { selectTabViewItem(at: indexOfTabViewItem(s) - 1) } }
    open func takeSelectedTabViewItemFromSender(_ sender: Any?) {}

    var showsTabs: Bool { tabViewType == .topTabsBezelBorder || tabViewType == .bottomTabsBezelBorder || tabViewType == .leftTabsBezelBorder || tabViewType == .rightTabsBezelBorder }

    func updateTabs() {
        tabs.isHidden = !showsTabs
        tabs.segmentCount = tabViewItems.count
        for (i, item) in tabViewItems.enumerated() { tabs.setLabel(item.label, forSegment: i) }
        if let s = selectedTabViewItem { tabs.selectedSegment = indexOfTabViewItem(s) }
        layoutTabs()
    }

    func showSelected() {
        if let v = shownView, v !== selectedTabViewItem?.view { v.removeFromSuperview() }
        shownView = selectedTabViewItem?.view
        if let v = shownView, v.superview !== self { addSubview(v) }
        layoutTabs()
    }

    /// The area item views fill.
    open var contentRect: CGRect {
        let b = boxRect
        switch tabViewType {
        case .noTabsNoBorder: return bounds
        case .noTabsLineBorder: return b.insetBy(dx: 1, dy: 1)
        default: return CGRect(x: b.minX + 7, y: b.minY + (showsTabs && tabViewType != .bottomTabsBezelBorder ? 16 : 7), width: max(0, b.width - 14), height: max(0, b.height - (showsTabs ? 23 : 14)))
        }
    }

    private var boxRect: CGRect {
        guard showsTabs else { return bounds }
        let h = tabs.intrinsicContentSize.height
        return tabViewType == .bottomTabsBezelBorder ? CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - h / 2)
                                                     : CGRect(x: 0, y: h / 2, width: bounds.width, height: bounds.height - h / 2)
    }

    private func layoutTabs() {
        let size = tabs.intrinsicContentSize
        let y = tabViewType == .bottomTabsBezelBorder ? bounds.height - size.height : 0
        let f = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
        if tabs.frame != f { tabs.frame = f }
        if let v = shownView, v.frame != contentRect { v.frame = contentRect }
        var cmds: [DrawCommand] = []
        if tabViewType != .noTabsNoBorder {
            let dark = NSAppearance.current.isDark
            let r = boxRect.insetBy(dx: 0.5, dy: 0.5)
            cmds.append(.fill(.roundedRect(r, radius: 6), .color(RGBA(0, 0, 0, dark ? 0.1 : 0.035))))
            cmds.append(.stroke(.roundedRect(r, radius: 6), .color(RGBA(0, 0, 0, dark ? 0.25 : 0.1)), lineWidth: 1, dash: []))
        }
        backdrop.draw(cmds)
        layoutSubviews()
    }

    override func place() {
        placementDirty = false
        // The panel, then the content, with the tabs on top of the panel's edge.
        let content = subviews.filter { $0 !== tabs && !$0.isHidden }.map { ($0.widget, $0.frame) }
        let top = tabs.isHidden ? [] : [(tabs.widget, tabs.frame)]
        Runway.backend.setChildren(widget, [(backdrop.widget, bounds)] + content + top, contentSize: frame.size)
    }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutTabs() }
}

// MARK: Tab view controller

@preconcurrency @MainActor
open class NSTabViewController: NSViewController, NSTabViewDelegate {
    public enum TabStyle: Int, Sendable { case segmentedControlOnTop = 0, segmentedControlOnBottom, toolbar, unspecified }
    public struct TransitionOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let crossfade = TransitionOptions(rawValue: 1)
        public static let allowUserInteraction = TransitionOptions(rawValue: 0x1000)
        public static let slideLeft = TransitionOptions(rawValue: 0x10)
        public static let slideRight = TransitionOptions(rawValue: 0x20)
        public static let slideForward = TransitionOptions(rawValue: 0x140)
        public static let slideBackward = TransitionOptions(rawValue: 0x180)
    }
    open var tabStyle: TabStyle = .segmentedControlOnTop { didSet { if isViewLoaded { restyle() } } }
    open var tabView = NSTabView(frame: .zero)
    open var transitionOptions: TransitionOptions = [.crossfade, .slideForward]
    open var canPropagateSelectedChildViewControllerTitle = true
    open private(set) var tabViewItems: [NSTabViewItem] = []
    private var toolbarRow: NSStackView?
    private var toolbarButtons: [NSButton] = []
    private var container: NSView?
    open private(set) var childControllers: [NSViewController] = []

    open var selectedTabViewItemIndex: Int {
        get { tabView.selectedTabViewItem.map { tabView.indexOfTabViewItem($0) } ?? -1 }
        set { tabView.selectTabViewItem(at: newValue) }
    }

    open override func loadView() {
        AppKitControls.install()
        let root = NSView(frame: CGRect(origin: .zero, size: preferredContentSize == .zero ? CGSize(width: 500, height: 360) : preferredContentSize))
        container = root
        tabView.delegate = self
        root.addSubview(tabView)
        view = root
        restyle()
    }

    open func addTabViewItem(_ item: NSTabViewItem) { insertTabViewItem(item, at: tabViewItems.count) }
    open func insertTabViewItem(_ item: NSTabViewItem, at i: Int) {
        tabViewItems.insert(item, at: min(i, tabViewItems.count))
        if let vc = item.viewController, !childControllers.contains(where: { $0 === vc }) { childControllers.append(vc) }
        tabView.insertTabViewItem(item, at: i)
        if isViewLoaded { restyle() }
    }
    open func removeTabViewItem(_ item: NSTabViewItem) {
        tabViewItems.removeAll { $0 === item }
        tabView.removeTabViewItem(item)
        if isViewLoaded { restyle() }
    }
    open func tabViewItem(for vc: NSViewController) -> NSTabViewItem? { tabViewItems.first { $0.viewController === vc } }
    /// Adds a child controller as a tab, as AppKit's addChild does.
    open override func addChild(_ vc: NSViewController) { addTabViewItem(NSTabViewItem(viewController: vc)) }

    private func restyle() {
        guard let root = container else { return }
        tabView.tabViewType = tabStyle == .toolbar || tabStyle == .unspecified ? .noTabsNoBorder : tabStyle == .segmentedControlOnBottom ? .bottomTabsBezelBorder : .topTabsBezelBorder
        toolbarRow?.removeFromSuperview()
        toolbarRow = nil
        if tabStyle == .toolbar {
            // A Settings window's row: an icon over a label per tab.
            toolbarButtons = tabViewItems.enumerated().map { i, item in
                let b = NSButton(title: item.label, image: item.image ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)!, target: nil, action: nil)
                b.imagePosition = .imageAbove
                b.bezelStyle = .texturedRounded
                b.setButtonType(.pushOnPushOff)
                b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
                b.handler = { [weak self] _ in self?.selectedTabViewItemIndex = i }
                return b
            }
            let row = NSStackView(views: toolbarButtons)
            row.spacing = 2
            root.addSubview(row)
            toolbarRow = row
            syncToolbar()
        }
        layoutRoot()
    }

    private func syncToolbar() {
        for (i, b) in toolbarButtons.enumerated() { b.state = i == selectedTabViewItemIndex ? .on : .off }
    }

    private func layoutRoot() {
        guard let root = container else { return }
        var top: CGFloat = 0
        if let row = toolbarRow {
            let s = row.fittingSize
            row.frame = CGRect(x: ((root.bounds.width - s.width) / 2).rounded(), y: 6, width: s.width, height: s.height)
            row.layout()
            top = s.height + 12
        } else if tabStyle != .unspecified {
            top = 8
        }
        let inset: CGFloat = tabStyle == .toolbar || tabStyle == .unspecified ? 0 : 12
        tabView.frame = CGRect(x: inset, y: top, width: max(0, root.bounds.width - inset * 2), height: max(0, root.bounds.height - top - inset))
        tabView.autoresizingMask = [.width, .height]
    }

    open override func viewDidLoad() { super.viewDidLoad() }

    // NSTabViewDelegate
    open func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool { true }
    open func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {}
    open func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        syncToolbar()
        if canPropagateSelectedChildViewControllerTitle, let t = tabViewItem?.viewController?.title ?? tabViewItem?.label {
            title = t
            view.hostWindow?.title = t
        }
    }
}
