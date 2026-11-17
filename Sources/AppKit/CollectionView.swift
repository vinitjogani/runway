// NSCollectionView with a flow layout: items (NSCollectionViewItem view
// controllers, registered by class and reused) in rows that wrap, made
// only for the part in view; click, ⌘-click and ⇧-click selection.

import Foundation
import CoreGraphics
import RunwayCore

extension IndexPath {
    public init(item: Int, section: Int) { self.init(indexes: [section, item]) }
    public var item: Int { count > 1 ? self[1] : 0 }
    public var section: Int { count > 0 ? self[0] : 0 }
}

@preconcurrency @MainActor public protocol NSCollectionViewDataSource: AnyObject {
    func numberOfSections(in collectionView: NSCollectionView) -> Int
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem
}
extension NSCollectionViewDataSource {
    public func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }
}

@preconcurrency @MainActor public protocol NSCollectionViewDelegate: AnyObject {
    func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath>
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>)
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>)
}
extension NSCollectionViewDelegate {
    public func collectionView(_ collectionView: NSCollectionView, shouldSelectItemsAt indexPaths: Set<IndexPath>) -> Set<IndexPath> { indexPaths }
    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {}
    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {}
}

@preconcurrency @MainActor public protocol NSCollectionViewDelegateFlowLayout: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize
}

@preconcurrency @MainActor
open class NSCollectionViewItem: NSViewController {
    open var imageView: NSImageView?
    open var textField: NSTextField?
    open internal(set) weak var collectionView: NSCollectionView?
    open var isSelected = false { didSet { if isSelected != oldValue { selectionChanged() } } }
    open var highlightState = 0
    public required override init(nibName: String?, bundle: Bundle?) { super.init(nibName: nibName, bundle: bundle) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    open override func loadView() { view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100)) }

    /// AppKit leaves selection drawing to the item; Runway gives it the
    /// Mac's rounded highlight unless the item draws its own.
    open func selectionChanged() {
        (view as? CollectionItemBackground)?.selected = isSelected
        textField?.backgroundStyle = isSelected ? .emphasized : .normal
    }
}

/// A plain item view with the selection highlight (items whose `view`
/// is made by Runway).
@MainActor final class CollectionItemBackground: NSView {
    override var isFlipped: Bool { true }
    var selected = false { didSet { redraw() } }
    private let backdrop = DrawnLayer()
    private func redraw() {
        backdrop.draw(selected ? [.fill(.roundedRect(bounds.insetBy(dx: 1, dy: 1), radius: 8), .color(NSColor.selectedContentBackgroundColor.rgbaValue.withAlpha(0.25)))] : [])
        layoutSubviews()
    }
    override func place() {
        placementDirty = false; placeChildren(below: [(backdrop.widget, bounds)]) }
    override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); redraw() }
}

@preconcurrency @MainActor open class NSCollectionViewLayout: NSObject {
    weak var collectionView: NSCollectionView?
    open func invalidateLayout() { collectionView?.relayout() }
}

@preconcurrency @MainActor
open class NSCollectionViewFlowLayout: NSCollectionViewLayout {
    public enum ScrollDirection: Int, Sendable { case vertical = 0, horizontal }
    open var itemSize = CGSize(width: 50, height: 50) { didSet { invalidateLayout() } }
    open var estimatedItemSize: CGSize = .zero
    open var minimumInteritemSpacing: CGFloat = 10 { didSet { invalidateLayout() } }
    open var minimumLineSpacing: CGFloat = 10 { didSet { invalidateLayout() } }
    open var sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) { didSet { invalidateLayout() } }
    open var headerReferenceSize: CGSize = .zero
    open var footerReferenceSize: CGSize = .zero
    open var scrollDirection: ScrollDirection = .vertical
    open var sectionHeadersPinToVisibleBounds = false
}

@preconcurrency @MainActor open class NSCollectionViewGridLayout: NSCollectionViewFlowLayout {
    open var maximumNumberOfColumns = 0
    open var maximumNumberOfRows = 0
    open var minimumItemSize: CGSize { get { itemSize } set { itemSize = newValue } }
    open var maximumItemSize: CGSize = .zero
    open var margins: NSEdgeInsets { get { sectionInset } set { sectionInset = newValue } }
}

@preconcurrency @MainActor
open class NSCollectionView: NSView, VisibleRectObserving {
    open override var isFlipped: Bool { true }
    // AppKit's event dispatch (when the backend reports raw input).
    open override func mouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.mouseDown(with: e) } }
    open override func mouseDragged(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .dragged)) }
    open override func mouseUp(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .up)) }
    open override func mouseMoved(with e: NSEvent) { _ = pointer(PointerEvent(e, in: self, kind: .moved)) }
    open override func rightMouseDown(with e: NSEvent) { if !pointer(PointerEvent(e, in: self, kind: .down)) { super.rightMouseDown(with: e) } }

    open weak var dataSource: NSCollectionViewDataSource? { didSet { reloadData() } }
    open weak var delegate: NSCollectionViewDelegate?
    open var collectionViewLayout: NSCollectionViewLayout? = NSCollectionViewFlowLayout() {
        didSet { collectionViewLayout?.collectionView = self; reloadData() }
    }
    open var isSelectable = false
    open var allowsMultipleSelection = false
    open var allowsEmptySelection = true
    open var backgroundColors: [NSColor] = [.controlBackgroundColor] { didSet { relayout() } }
    open private(set) var selectionIndexPaths: Set<IndexPath> = []
    private var registered: [NSUserInterfaceItemIdentifier: NSCollectionViewItem.Type] = [:]
    private var pool: [NSUserInterfaceItemIdentifier: [NSCollectionViewItem]] = [:]
    private var visible: [IndexPath: NSCollectionViewItem] = [:]
    private var itemIdentifiers: [ObjectIdentifier: NSUserInterfaceItemIdentifier] = [:]
    private var frames: [(IndexPath, CGRect)] = []
    private var events: NativeWidget!
    private let background = DrawnLayer()
    private var anchor: IndexPath?

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        onMain {
            collectionViewLayout?.collectionView = self
            events = makeEventWidget(focusable: true, pointer: { [weak self] e in self?.pointer(e) ?? false })
        }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        onMain {
            collectionViewLayout?.collectionView = self
            events = makeEventWidget(focusable: true, pointer: { [weak self] e in self?.pointer(e) ?? false })
        }
        IBDecoding.leave(self, coder)
    }

    open func register(_ itemClass: AnyClass?, forItemWithIdentifier id: NSUserInterfaceItemIdentifier) {
        registered[id] = itemClass as? NSCollectionViewItem.Type
    }
    open func register(_ nib: Any?, forItemWithIdentifier id: NSUserInterfaceItemIdentifier) {}

    /// A reused item, or a new one of the registered class.
    open func makeItem(withIdentifier id: NSUserInterfaceItemIdentifier, for indexPath: IndexPath) -> NSCollectionViewItem {
        let item: NSCollectionViewItem
        if var p = pool[id], let i = p.popLast() { pool[id] = p; item = i }
        else {
            let cls = registered[id] ?? NSCollectionViewItem.self
            item = cls.init(nibName: nil, bundle: nil)
        }
        itemIdentifiers[ObjectIdentifier(item)] = id
        item.collectionView = self
        return item
    }

    open var numberOfSections: Int { dataSource?.numberOfSections(in: self) ?? 0 }
    open func numberOfItems(inSection s: Int) -> Int { dataSource?.collectionView(self, numberOfItemsInSection: s) ?? 0 }
    open func item(at indexPath: IndexPath) -> NSCollectionViewItem? { visible[indexPath] }
    open func item(at index: Int) -> NSCollectionViewItem? { visible[IndexPath(item: index, section: 0)] }
    open var visibleItems: [NSCollectionViewItem] { Array(visible.values) }
    open func indexPathsForVisibleItems() -> Set<IndexPath> { Set(visible.keys) }
    open func indexPath(for item: NSCollectionViewItem) -> IndexPath? { visible.first { $0.value === item }?.key }
    open func frameForItem(at indexPath: IndexPath) -> CGRect { frames.first { $0.0 == indexPath }?.1 ?? .zero }
    open func indexPathForItem(at p: CGPoint) -> IndexPath? { frames.first { $0.1.contains(p) }?.0 }

    open func reloadData() {
        guard events != nil else { return }
        for (_, i) in visible { recycle(i) }
        visible.removeAll()
        relayout()
    }
    open func reloadItems(at paths: Set<IndexPath>) { for p in paths { if let i = visible.removeValue(forKey: p) { recycle(i) } }; updateVisible() }
    open func insertItems(at paths: Set<IndexPath>) { reloadData() }
    open func deleteItems(at paths: Set<IndexPath>) { selectionIndexPaths.subtract(paths); reloadData() }
    open func reloadSections(_ s: IndexSet) { reloadData() }
    open func performBatchUpdates(_ updates: (() -> Void)?, completionHandler: ((Bool) -> Void)? = nil) {
        updates?(); reloadData(); completionHandler?(true)
    }
    open func scrollToItems(at paths: Set<IndexPath>, scrollPosition: Int) {
        if let f = paths.compactMap({ frameForItem(at: $0) }).first { scrollToVisible(f) }
    }

    private func recycle(_ item: NSCollectionViewItem) {
        item.view.removeFromSuperview()
        item.isSelected = false
        let id = itemIdentifiers[ObjectIdentifier(item)] ?? NSUserInterfaceItemIdentifier("")
        if (pool[id]?.count ?? 0) < 64 { pool[id, default: []].append(item) }
    }

    /// Computes every item's frame (rows that wrap) and sizes the view.
    func relayout() {
        guard events != nil else { return }
        let flow = collectionViewLayout as? NSCollectionViewFlowLayout ?? NSCollectionViewFlowLayout()
        let width = (superview as? NSClipView)?.frame.width ?? bounds.width
        var out: [(IndexPath, CGRect)] = []
        var y: CGFloat = 0
        for s in 0..<numberOfSections {
            y += flow.sectionInset.top + flow.headerReferenceSize.height
            var x = flow.sectionInset.left
            var rowH: CGFloat = 0
            for i in 0..<numberOfItems(inSection: s) {
                let p = IndexPath(item: i, section: s)
                let size = (delegate as? NSCollectionViewDelegateFlowLayout)?.collectionView(self, layout: flow, sizeForItemAt: p) ?? flow.itemSize
                if x > flow.sectionInset.left, x + size.width > width - flow.sectionInset.right {
                    x = flow.sectionInset.left
                    y += rowH + flow.minimumLineSpacing
                    rowH = 0
                }
                out.append((p, CGRect(x: x, y: y, width: size.width, height: size.height)))
                x += size.width + flow.minimumInteritemSpacing
                rowH = max(rowH, size.height)
            }
            y += rowH + flow.sectionInset.bottom + flow.footerReferenceSize.height
        }
        frames = out
        let h = max(y, (superview as? NSClipView)?.frame.height ?? 0)
        let size = CGSize(width: width, height: h.rounded(.up))
        if frame.size != size { setFrameSize(size) }
        updateVisible()
    }

    private func updateVisible() {
        guard let ds = dataSource else { return }
        let vis = visibleRect.insetBy(dx: 0, dy: -200)
        let want = Set(frames.filter { $0.1.intersects(vis) }.map(\.0))
        for (p, i) in visible where !want.contains(p) { recycle(i); visible[p] = nil }
        for (p, f) in frames where want.contains(p) {
            let item = visible[p] ?? {
                let i = ds.collectionView(self, itemForRepresentedObjectAt: p)
                visible[p] = i
                addSubview(i.view)
                return i
            }()
            if item.view.frame != f { item.view.frame = f }
            item.isSelected = selectionIndexPaths.contains(p)
        }
        background.draw([.fill(.rect(CGRect(origin: .zero, size: visibleRect.size)), .color((backgroundColors.first ?? .clear).rgbaValue))])
        layoutSubviews()
    }

    func visibleRectDidChange() {
        if let clip = superview as? NSClipView, abs(clip.frame.width - frame.width) > 0.5 { relayout() } else { updateVisible() }
    }

    // MARK: Selection

    open func selectItems(at paths: Set<IndexPath>, scrollPosition: Int) {
        let new = allowsMultipleSelection ? selectionIndexPaths.union(paths) : Set(paths.prefix(1))
        setSelection(new)
    }
    open func deselectItems(at paths: Set<IndexPath>) { setSelection(selectionIndexPaths.subtracting(paths)) }
    open override func selectAll(_ sender: Any?) { if allowsMultipleSelection { setSelection(Set(frames.map(\.0))) } }
    open func deselectAll(_ sender: Any?) { setSelection([]) }
    open var selectionIndexes: IndexSet {
        get { IndexSet(selectionIndexPaths.filter { $0.section == 0 }.map(\.item)) }
        set { setSelection(Set(newValue.map { IndexPath(item: $0, section: 0) })) }
    }

    private func setSelection(_ s: Set<IndexPath>) {
        let old = selectionIndexPaths
        guard s != old else { return }
        selectionIndexPaths = s
        for (p, i) in visible { i.isSelected = s.contains(p) }
        let removed = old.subtracting(s), added = s.subtracting(old)
        if !removed.isEmpty { delegate?.collectionView(self, didDeselectItemsAt: removed) }
        if !added.isEmpty { delegate?.collectionView(self, didSelectItemsAt: added) }
    }

    private func pointer(_ e: PointerEvent) -> Bool {
        guard e.kind == .down, isSelectable else { return false }
        Runway.appKit?.focus(events)
        guard let p = indexPathForItem(at: e.location) else {
            if allowsEmptySelection, e.modifiers.isEmpty { setSelection([]) }
            return true
        }
        var proposed: Set<IndexPath>
        if e.modifiers.contains(.command), allowsMultipleSelection {
            proposed = selectionIndexPaths
            if proposed.contains(p) { proposed.remove(p) } else { proposed.insert(p) }
        } else if e.modifiers.contains(.shift), allowsMultipleSelection, let a = anchor,
                  let ai = frames.firstIndex(where: { $0.0 == a }), let pi = frames.firstIndex(where: { $0.0 == p }) {
            proposed = Set(frames[min(ai, pi)...max(ai, pi)].map(\.0))
        } else {
            proposed = [p]
            anchor = p
        }
        let added = proposed.subtracting(selectionIndexPaths)
        let allowed = delegate?.collectionView(self, shouldSelectItemsAt: added) ?? added
        setSelection(proposed.subtracting(added.subtracting(allowed)))
        return true
    }

    override func place() {
        placementDirty = false
        guard let events else { return }
        let vis = visibleRect
        Runway.backend.setChildren(events, [(background.widget, vis)] + subviews.filter { !$0.isHidden }.map { ($0.widget, $0.frame) }, contentSize: frame.size)
        Runway.backend.setChildren(widget, [(events, bounds)], contentSize: frame.size)
    }
    open override func frameSizeChanged(from old: CGSize) { super.frameSizeChanged(from: old); layoutSubviews() }
}
