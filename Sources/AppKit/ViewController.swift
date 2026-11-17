// NSViewController: the view's lifecycle (load, appear, layout,
// disappear), child view controllers, presentation (sheets, modal
// windows, popovers through a hook the standard controls fill in), and its
// place in the responder chain between its view and the view's superview.

import Foundation
import RunwayCore
import RunwayPlatform

@preconcurrency @MainActor
open class NSViewController: NSResponder, NSUserInterfaceItemIdentification {
    private var _view: NSView?
    open var title: String?
    open var preferredContentSize: NSSize = .zero
    open var identifier: NSUserInterfaceItemIdentifier?
    open var representedObject: Any?
    open private(set) var nibName: NSNib.Name?
    open private(set) var nibBundle: Bundle?
    open var children: [NSViewController] = [] { didSet { for c in children where c.parent !== self { c.parent = self } } }
    open private(set) weak var parent: NSViewController?
    open private(set) var presentedViewControllers: [NSViewController]?
    open private(set) weak var presentingViewController: NSViewController?
    private var presentationWindow: NSWindow?
    private var appeared = false

    public init(nibName: NSNib.Name?, bundle: Bundle?) {
        super.init()
        self.nibName = nibName
        nibBundle = bundle
        RunwayPlatform.installDefaultBackend()
        AppKitRuntime.install()
    }
    public override convenience init() { self.init(nibName: nil, bundle: nil) }
    /// Storyboards decode view controllers through this (InterfaceBuilder/).
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        RunwayPlatform.installDefaultBackend()
        AppKitRuntime.install()
        IBDecoding.leave(self, coder)
    }

    /// The view, loaded on first access (`loadView()` then `viewDidLoad()`).
    open var view: NSView {
        get {
            if _view == nil { loadViewIfNeeded() }
            return _view!
        }
        set { setView(newValue) }
    }
    private func setView(_ v: NSView) {
        _view?._viewController = nil
        _view = v
        v._viewController = self
    }
    open var viewIfLoaded: NSView? { _view }
    open var isViewLoaded: Bool { _view != nil }
    open func loadViewIfNeeded() {
        guard _view == nil else { return }
        loadView()
        if _view == nil { setView(NSView()) }
        viewDidLoad()
    }
    /// Loads the view from the controller's storyboard scene or its nib
    /// (`nibName`, else one named like the class), as Cocoa does; with
    /// neither, an empty view. Override to build yours.
    open func loadView() {
        if IBLoading.loadView(of: self) { return }
        setView(NSView())
    }
    open func viewDidLoad() {}
    open func viewWillAppear() {}
    open func viewDidAppear() {}
    open func viewWillDisappear() {}
    open func viewDidDisappear() {}
    open func viewWillLayout() {}
    open func viewDidLayout() {}
    open func updateViewConstraints() { view._needsUpdateConstraints = false; view.updateConstraints() }
    open func viewWillTransition(to newSize: NSSize) {}
    open func preferredContentSizeDidChange(for vc: NSViewController) {}
    open func commitEditing() -> Bool { true }
    open func discardEditing() {}

    /// Sized-to-content controllers (hosting controllers) override this.
    open var contentSizeForWindow: CGSize? { preferredContentSize == .zero ? nil : preferredContentSize }

    // The responder chain: view → controller → the view's superview.
    open override var nextResponder: NSResponder? {
        get {
            if let n = super.nextResponder { return n }
            guard let v = _view else { return nil }
            return v.nextResponderSkippingController
        }
        set { super.nextResponder = newValue }
    }

    // MARK: Appearing

    func viewMovedToWindow(_ w: NSWindow?) {
        if w != nil, w!.isVisible, !appeared { viewWillAppearRecursively(); viewDidAppearRecursively() }
        if w == nil, appeared { viewWillDisappearRecursively(); viewDidDisappearRecursively() }
    }
    func viewWillAppearRecursively() {
        guard !appeared else { return }
        viewWillAppear()
        for c in children where c.isViewLoaded && c.view.window != nil { c.viewWillAppearRecursively() }
    }
    func viewDidAppearRecursively() {
        guard !appeared else { return }
        appeared = true
        viewDidAppear()
        for c in children where c.isViewLoaded && c.view.window != nil { c.viewDidAppearRecursively() }
    }
    func viewWillDisappearRecursively() {
        guard appeared else { return }
        viewWillDisappear()
        for c in children { c.viewWillDisappearRecursively() }
    }
    func viewDidDisappearRecursively() {
        guard appeared else { return }
        appeared = false
        viewDidDisappear()
        for c in children { c.viewDidDisappearRecursively() }
    }

    // MARK: Children

    open func addChild(_ c: NSViewController) { insertChild(c, at: children.count) }
    open func insertChild(_ c: NSViewController, at index: Int) {
        c.removeFromParent()
        children.insert(c, at: min(index, children.count))
        c.parent = self
    }
    open func removeChild(at index: Int) {
        let c = children.remove(at: index)
        c.parent = nil
    }
    open func removeFromParent() {
        guard let p = parent, let i = p.children.firstIndex(where: { $0 === self }) else { return }
        p.removeChild(at: i)
    }
    open func setChildren(_ cs: [NSViewController]) {
        for c in children { c.parent = nil }
        children = []
        for c in cs { addChild(c) }
    }
    open func transition(from a: NSViewController, to b: NSViewController, options: TransitionOptions = [], completionHandler: (() -> Void)? = nil) {
        if let s = a.view.superview {
            b.view.frame = a.view.frame
            s.replaceSubview(a.view, with: b.view)
        }
        completionHandler?()
    }
    public struct TransitionOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let crossfade = TransitionOptions(rawValue: 1)
        public static let slideUp = TransitionOptions(rawValue: 16), slideDown = TransitionOptions(rawValue: 32)
        public static let slideLeft = TransitionOptions(rawValue: 64), slideRight = TransitionOptions(rawValue: 128)
        public static let slideForward = TransitionOptions(rawValue: 320), slideBackward = TransitionOptions(rawValue: 384)
        public static let allowUserInteraction = TransitionOptions(rawValue: 0x1000)
    }

    // MARK: Presenting

    /// Popovers are the standard controls' (NSPopover); they install this.
    public static var _runwayPopoverPresenter: ((_ vc: NSViewController, _ rect: NSRect, _ view: NSView, _ edge: NSRectEdge, _ behavior: Int) -> Void)?

    private func presentInWindow(_ vc: NSViewController, sheet: Bool) {
        presentedViewControllers = (presentedViewControllers ?? []) + [vc]
        vc.presentingViewController = self
        let w = NSWindow(contentViewController: vc)
        w.styleMask = sheet ? [.titled, .docModalWindow] : [.titled, .closable]
        vc.presentationWindow = w
        if sheet, let host = view.window { host.beginSheet(w) } else {
            w.isModal = true
            w.parentWindow = view.window
            w.center()
            w.makeKeyAndOrderFront(nil)
        }
    }
    // MARK: Storyboard segues (InterfaceBuilder/IBStoryboard.swift)

    open func prepare(for segue: NSStoryboardSegue, sender: Any?) {}
    open func shouldPerformSegue(withIdentifier identifier: NSStoryboardSegue.Identifier, sender: Any?) -> Bool { true }
    open func performSegue(withIdentifier identifier: NSStoryboardSegue.Identifier, sender: Any?) {
        IBSegues.perform(identifier, from: self, sender: sender)
    }

    open func presentAsSheet(_ vc: NSViewController) { presentInWindow(vc, sheet: true) }
    open func presentAsModalWindow(_ vc: NSViewController) { presentInWindow(vc, sheet: false) }
    open func present(_ vc: NSViewController, asPopoverRelativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge, behavior: Int) {
        if let p = Self._runwayPopoverPresenter {
            presentedViewControllers = (presentedViewControllers ?? []) + [vc]
            vc.presentingViewController = self
            p(vc, rect, view, preferredEdge, behavior)
        } else {
            presentAsSheet(vc)
        }
    }
    open func present(_ vc: NSViewController, animator: NSViewControllerPresentationAnimator) {
        presentedViewControllers = (presentedViewControllers ?? []) + [vc]
        vc.presentingViewController = self
        animator.animatePresentation(of: vc, from: self)
    }
    open func dismiss(_ vc: NSViewController) {
        presentedViewControllers?.removeAll { $0 === vc }
        vc.presentingViewController = nil
        if let w = vc.presentationWindow {
            vc.presentationWindow = nil
            if let p = w.sheetParent { p.endSheet(w) } else { w.close() }
        }
    }
    /// Dismisses this controller if it was presented, else closes its window.
    open func dismiss(_ sender: Any?) {
        if let p = presentingViewController { p.dismiss(self) } else { view.window?.close() }
    }
}

@preconcurrency @MainActor public protocol NSViewControllerPresentationAnimator: AnyObject {
    func animatePresentation(of vc: NSViewController, from fromViewController: NSViewController)
    func animateDismissal(of vc: NSViewController, from fromViewController: NSViewController)
}


