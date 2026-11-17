// NSPopover on the toolkit's popover (GtkPopover): its content view
// controller's view in a bubble pointing at a rect of a view, closed by a
// click outside (transient) or by the app.

import Foundation
import CoreGraphics
import RunwayCore

@preconcurrency @MainActor public protocol NSPopoverDelegate: AnyObject {
    func popoverShouldShow(_ popover: NSPopover) -> Bool
    func popoverShouldClose(_ popover: NSPopover) -> Bool
    func popoverWillShow(_ notification: Notification)
    func popoverDidShow(_ notification: Notification)
    func popoverWillClose(_ notification: Notification)
    func popoverDidClose(_ notification: Notification)
    func popoverShouldDetach(_ popover: NSPopover) -> Bool
    func detachableWindow(for popover: NSPopover) -> NSWindow?
}
extension NSPopoverDelegate {
    public func popoverShouldShow(_ popover: NSPopover) -> Bool { true }
    public func popoverShouldClose(_ popover: NSPopover) -> Bool { true }
    public func popoverWillShow(_ notification: Notification) {}
    public func popoverDidShow(_ notification: Notification) {}
    public func popoverWillClose(_ notification: Notification) {}
    public func popoverDidClose(_ notification: Notification) {}
    public func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }
    public func detachableWindow(for popover: NSPopover) -> NSWindow? { nil }
}

@preconcurrency @MainActor
open class NSPopover: NSResponder {
    public enum Behavior: Int, Sendable { case applicationDefined = 0, transient, semitransient }
    public static let willShowNotification = Notification.Name("NSPopoverWillShowNotification")
    public static let didShowNotification = Notification.Name("NSPopoverDidShowNotification")
    public static let willCloseNotification = Notification.Name("NSPopoverWillCloseNotification")
    public static let didCloseNotification = Notification.Name("NSPopoverDidCloseNotification")
    public static let closeReasonKey = "NSPopoverCloseReasonKey"
    public static let closeReasonStandard = "NSPopoverCloseReasonStandard"
    public static let closeReasonDetachToWindow = "NSPopoverCloseReasonDetachToWindow"

    open weak var delegate: NSPopoverDelegate?
    open var contentViewController: NSViewController?
    open var behavior: Behavior = .applicationDefined
    open var animates = true
    open var appearance: NSAppearance?
    open var effectiveAppearance: NSAppearance { appearance ?? .current }
    open var hasFullSizeContent = false
    open private(set) var isShown = false
    open var isDetached: Bool { false }
    open var positioningRect: CGRect = .zero
    open var contentSize: CGSize = .zero {
        didSet { if isShown, let h = handle { Runway.appKit?.setPopoverSize(h, contentSize); layoutContent() } }
    }
    private var handle: AnyObject?
    private var root: NSView?

    public override init() {
        super.init()
        MainActor.assumeIsolated { AppKitControls.install() }
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        MainActor.assumeIsolated { AppKitControls.install() }
        IBDecoding.leave(self, coder)
    }

    /// Shows the popover pointing at `rect` in `view`.
    open func show(relativeTo rect: CGRect, of view: NSView, preferredEdge edge: NSRectEdge) {
        guard !isShown, let vc = contentViewController, let ak = Runway.appKit else { return }
        guard delegate?.popoverShouldShow(self) ?? true else { return }
        let content = vc.view
        var size = contentSize
        if size == .zero { size = vc.preferredContentSize }
        if size == .zero { size = content.frame.size }
        if size == .zero { size = content.fittingSize }
        contentSize = size
        let r = rect == .zero ? view.bounds : rect
        positioningRect = r
        let host = NSView(frame: CGRect(origin: .zero, size: size))
        host.addSubview(content)
        root = host
        layoutContent()
        post(Self.willShowNotification) { $0?.popoverWillShow($1) }
        vc.viewWillAppear()
        // Unflipped AppKit coordinates name the bottom edge minY; Runway's
        // views are flipped, so the edges are named as they look.
        let e: PopoverEdge = switch edge {
        case .minY: .bottom
        case .maxY: .top
        case .minX: .leading
        case .maxX: .trailing
        }
        isShown = true
        handle = ak.showPopover(host.widget, size: size, anchor: view.widget, rect: r, edge: e, transient: behavior != .applicationDefined) { [weak self] in
            self?.didClose()
        }
        vc.viewDidAppear()
        post(Self.didShowNotification) { $0?.popoverDidShow($1) }
    }

    private func layoutContent() {
        guard let root, let content = contentViewController?.view else { return }
        root.frame = CGRect(origin: .zero, size: contentSize)
        content.frame = root.bounds
        RunwayLayoutTree(content)
    }

    open func performClose(_ sender: Any?) {
        guard isShown, delegate?.popoverShouldClose(self) ?? true else { return }
        close()
    }

    open func close() {
        guard isShown, let h = handle else { return }
        Runway.appKit?.closePopover(h)
        didClose()
    }

    private func didClose() {
        guard isShown else { return }
        isShown = false
        handle = nil
        post(Self.willCloseNotification) { $0?.popoverWillClose($1) }
        contentViewController?.viewWillDisappear()
        contentViewController?.view.removeFromSuperview()
        root = nil
        contentViewController?.viewDidDisappear()
        post(Self.didCloseNotification) { $0?.popoverDidClose($1) }
    }

    private func post(_ name: Notification.Name, _ call: (NSPopoverDelegate?, Notification) -> Void) {
        let n = Notification(name: name, object: self, userInfo: [Self.closeReasonKey: Self.closeReasonStandard])
        call(delegate, n)
        NotificationCenter.default.post(n)
    }
}
