// Storyboards: scenes instantiated on demand, controllers whose view or
// window loads lazily from their scene (as Cocoa compiles each into its
// own nib), and segues — relationship (window content, split and tab
// items), embed (container views), show, sheet, modal, popover — triggered
// by controls or `performSegue(withIdentifier:sender:)`, with
// `shouldPerformSegue` and `prepare(for:sender:)`. Bindings (basic
// `NSUserDefaultsController` and KVC value bindings) are here too.

import Foundation
import RunwayCore

// MARK: NSStoryboard

@preconcurrency @MainActor
open class NSStoryboard: NSObject {
    public typealias Name = String
    public typealias SceneIdentifier = String
    public typealias ControllerCreator = (NSCoder) -> Any?

    public let name: NSStoryboard.Name
    let document: IBDocument?
    let bundle: Bundle
    nonisolated(unsafe) static var _main: NSStoryboard?
    private static var cache: [String: NSStoryboard] = [:]

    /// The app's main storyboard (Info.plist's NSMainStoryboardFile).
    open class var main: NSStoryboard? { _main }

    /// `NSStoryboard(name:bundle:)`. A missing storyboard logs and then
    /// instantiates nothing (Cocoa raises).
    public init(name: NSStoryboard.Name, bundle: Bundle?) {
        self.name = name
        self.bundle = bundle ?? .main
        do { document = try IBDocument.named(name, bundle: bundle, kind: .storyboard) } catch {
            FileHandle.standardError.write(Data("runway: \(error)\n".utf8))
            document = nil
        }
        super.init()
    }

    init(document: IBDocument, bundle: Bundle) {
        name = document.name
        self.document = document
        self.bundle = bundle
        super.init()
    }

    static func load(_ name: String, bundle: Bundle) throws -> NSStoryboard {
        if let s = cache[name] { return s }
        let s = NSStoryboard(document: try IBDocument.named(name, bundle: bundle, kind: .storyboard), bundle: bundle)
        cache[name] = s
        return s
    }

    /// The controller the storyboard's entry point names.
    open func instantiateInitialController() -> Any? {
        guard let document, let id = document.initialViewControllerID, let e = document.elements[id] else { return nil }
        return instantiate(e)
    }

    open func instantiateInitialController<Controller>(creator: ((NSCoder) -> Controller?)? = nil) -> Controller? {
        guard let document, let id = document.initialViewControllerID, let e = document.elements[id] else { return nil }
        return instantiate(e, creator: creator.map { c in { coder in c(coder) } }) as? Controller
    }

    /// The controller with Storyboard ID `identifier` (nil when there's none;
    /// Cocoa raises).
    open func instantiateController(withIdentifier identifier: NSStoryboard.SceneIdentifier) -> Any {
        guard let document, let e = document.element(storyboardIdentifier: identifier), let c = instantiate(e) else {
            FileHandle.standardError.write(Data("runway: storyboard \(name) has no controller with identifier \(identifier)\n".utf8))
            return NSViewController()
        }
        return c
    }

    open func instantiateController<Controller>(identifier: NSStoryboard.SceneIdentifier, creator: ((NSCoder) -> Controller?)? = nil) -> Controller {
        guard let document, let e = document.element(storyboardIdentifier: identifier),
              let c = instantiate(e, creator: creator.map { c in { coder in c(coder) } }) as? Controller else {
            fatalError("runway: storyboard \(name) has no \(Controller.self) with identifier \(identifier)")
        }
        return c
    }

    /// The Application scene: NSApp's main menu, its delegate and the
    /// scene's other objects.
    func instantiateApplicationScene() {
        guard let document else { return }
        for scene in document.scenes {
            guard let objects = scene.child("objects"), objects.children.contains(where: { $0.name == "application" }) else { continue }
            let loader = IBLoader(document: document, bundle: bundle, owner: NSApplication.shared)
            loader.storyboard = self
            loader.isMainInterface = true
            for o in loader.instantiate(objects.children) { IBRetained.keep(o) }
            loader.finish(awakeOwner: false)
            if IBCheck.collecting { IBCheck.storyboardLoaders.append(loader) }
        }
    }

    /// A controller (or a storyboard reference to one) from its scene.
    func instantiate(_ e: IBElement, creator: ((NSCoder) -> Any?)? = nil) -> AnyObject? {
        guard let document else { return nil }
        if e.name == "controllerPlaceholder" {
            let other = e["storyboardName"].flatMap { try? NSStoryboard.load($0, bundle: bundle) } ?? self
            if let ident = e["referencedIdentifier"] { return other.instantiateController(withIdentifier: ident) as AnyObject }
            return other.instantiateInitialController() as AnyObject?
        }
        guard let scene = document.scene(containing: e.id ?? ""), let objects = scene.child("objects") else { return nil }
        let loader = IBLoader(document: document, bundle: bundle, owner: nil)
        loader.storyboard = self
        // The controller's view or window loads with it later.
        for c in objects.children {
            for k in ["view", "window"] { if let v = c.child(key: k), let id = v.id { loader.skip.insert(id) } }
        }
        var controller: AnyObject?
        if let creator, let id = e.id {
            let coder = IBCoder(e, loader)
            if let made = creator(coder) as AnyObject? {
                if !coder.decoded { loader.decode(made, e) }
                loader.objects[id] = made
                controller = made
            }
        }
        if controller == nil { controller = loader.object(for: e) }
        guard let controller else { return nil }
        loader.owner = controller
        for o in objects.children where o !== e { _ = loader.placeholder(o) ? nil : loader.object(for: o) }
        loader.finish(awakeOwner: false)
        IBStoryboardState.state(of: controller)?.sceneLoader = loader
        return controller
    }
}

extension NSViewController {
    /// The storyboard the controller came from.
    public var storyboard: NSStoryboard? { IBStoryboardState.state(of: self)?.storyboard }
}
extension NSWindowController {
    public var storyboard: NSStoryboard? { IBStoryboardState.state(of: self)?.storyboard }
}

// MARK: Segues

@preconcurrency @MainActor
open class NSStoryboardSegue: NSObject {
    public typealias Identifier = String
    public let identifier: NSStoryboardSegue.Identifier?
    public let sourceController: Any
    public let destinationController: Any
    var kind = "show"
    var element: IBElement?
    weak var sender: AnyObject?
    var performHandler: (() -> Void)?

    public init(identifier: NSStoryboardSegue.Identifier, source sourceController: Any, destination destinationController: Any) {
        self.identifier = identifier.isEmpty ? nil : identifier
        self.sourceController = sourceController
        self.destinationController = destinationController
        super.init()
    }

    public convenience init(identifier: NSStoryboardSegue.Identifier, source: Any, destination: Any, performHandler: @escaping () -> Void) {
        self.init(identifier: identifier, source: source, destination: destination)
        self.performHandler = performHandler
    }

    /// Presents the destination as the segue's kind says.
    open func perform() {
        if let h = performHandler { h(); return }
        let src = sourceController, dst = destinationController
        let srcVC = src as? NSViewController ?? (src as? NSWindowController)?.contentViewController
        switch kind {
        case "sheet":
            if let d = dst as? NSViewController, let s = srcVC { s.presentAsSheet(d) }
            else if let d = dst as? NSWindowController, let w = d.window, let host = srcVC?.view.window ?? (src as? NSWindowController)?.window { host.beginSheet(w) }
        case "modal":
            if let d = dst as? NSViewController, let s = srcVC { s.presentAsModalWindow(d) }
            else if let d = dst as? NSWindowController { d.showWindow(sender) }
        case "popover":
            if let d = dst as? NSViewController, let s = srcVC {
                let anchor = element?["popoverAnchorView"].flatMap { IBSegues.lookup($0, near: s) } as? NSView ?? (sender as? NSView) ?? s.view
                let edges: [String: NSRectEdge] = ["minX": .minX, "minY": .minY, "maxX": .maxX, "maxY": .maxY]
                let edge = element?["preferredEdge"].flatMap { edges[$0] } ?? .maxY
                let behavior: Int = element?["popoverBehavior"] == "t" ? 1 : element?["popoverBehavior"] == "s" ? 2 : 0
                s.present(d, asPopoverRelativeTo: anchor.bounds, of: anchor, preferredEdge: edge, behavior: behavior)
            }
        default:  // show
            if let d = dst as? NSWindowController { d.showWindow(sender) }
            else if let d = dst as? NSViewController {
                if let s = srcVC, s.view.window != nil, element?["kind"] == "show" {
                    let w = NSWindow(contentViewController: d)
                    IBRetained.keep(w)
                    w.makeKeyAndOrderFront(sender)
                } else {
                    let w = NSWindow(contentViewController: d)
                    IBRetained.keep(w)
                    w.makeKeyAndOrderFront(sender)
                }
            }
        }
    }
}

/// Performs a control's segue (its target, with action `perform:`).
@MainActor final class IBSeguePerformer: NSObject {
    let element: IBElement
    weak var loader: IBLoader?
    weak var source: AnyObject?
    let storyboard: NSStoryboard?
    static var performers: [ObjectIdentifier: IBSeguePerformer] = [:]
    static var registered = false

    init(_ element: IBElement, source: AnyObject?, loader: IBLoader) {
        self.element = element
        self.loader = loader
        self.source = source
        storyboard = loader.storyboard
        super.init()
        if !Self.registered {
            Self.registered = true
            RunwayObjC.registerSelector(Selector("perform:"), for: IBSeguePerformer.self) { p, args in
                MainActor.assumeIsolated { (p as? IBSeguePerformer)?.fire(args.first ?? nil) }
                return nil
            }
        }
    }

    func fire(_ sender: Any?) {
        guard let source else { return }
        IBSegues.perform(element: element, from: source, sender: sender, storyboard: storyboard)
    }
}

/// Per-controller storyboard state: its scene, lazily loaded view/window,
/// and segues by identifier.
@MainActor final class IBStoryboardState {
    weak var controller: AnyObject?
    weak var storyboard: NSStoryboard?
    let element: IBElement
    var sceneLoader: IBLoader?
    var segues: [String: IBElement] = [:]
    var relationships: [IBElement] = []

    private static var states: [ObjectIdentifier: IBStoryboardState] = [:]
    static var splitItems: [ObjectIdentifier: [IBElement]] = [:]
    static var tabItems: [ObjectIdentifier: [IBElement]] = [:]

    init(controller: AnyObject, element: IBElement, storyboard: NSStoryboard?) {
        self.controller = controller
        self.element = element
        self.storyboard = storyboard
    }

    static func state(of c: AnyObject) -> IBStoryboardState? {
        guard let s = states[ObjectIdentifier(c)] else { return nil }
        if s.controller !== c { states[ObjectIdentifier(c)] = nil; return nil }
        return s
    }

    /// Called as a view or window controller decodes.
    static func attach(_ c: AnyObject, element e: IBElement, loader: IBLoader) {
        if loader.storyboard == nil {
            // A controller in a xib: its view comes with the nib.
            if let vc = c as? NSViewController, let ve = e.child(key: "view") {
                loader.afterConnecting.append { [weak vc, weak loader] in
                    if let vc, let v = loader?.object(for: ve) as? NSView, !vc.isViewLoaded { vc.view = v }
                }
            }
            if let wc = c as? NSWindowController, let we = e.child(key: "window"), let w = loader.object(for: we) as? NSWindow { wc.window = w }
            return
        }
        let s = IBStoryboardState(controller: c, element: e, storyboard: loader.storyboard)
        states[ObjectIdentifier(c)] = s
        _ = e.child(key: "view"); _ = e.child(key: "window")
    }

    // MARK: Lazy loading

    func loadView(_ vc: NSViewController) -> Bool {
        guard let ve = element.child(key: "view"), let scene = sceneLoader else {
            // A split/tab controller builds its own view.
            return false
        }
        let loader = IBLoader(document: scene.document, bundle: scene.bundle, owner: vc)
        loader.storyboard = storyboard
        loader.objects = scene.objects
        loader.doneConnections = scene.doneConnections
        guard let v = loader.object(for: ve) as? NSView else { return false }
        vc.view = v
        loader.requeueConnections(of: scene)
        loader.finish()
        scene.doneConnections.formUnion(loader.doneConnections)
        if IBCheck.collecting { IBCheck.storyboardLoaders.append(loader) }
        return true
    }

    func loadWindow(_ wc: NSWindowController) {
        guard let we = element.child(key: "window"), let scene = sceneLoader else { return }
        let loader = IBLoader(document: scene.document, bundle: scene.bundle, owner: wc)
        loader.storyboard = storyboard
        loader.objects = scene.objects
        loader.doneConnections = scene.doneConnections
        guard let w = loader.object(for: we) as? NSWindow else { return }
        wc.window = w
        loader.requeueConnections(of: scene)
        loader.finish()
        scene.doneConnections.formUnion(loader.doneConnections)
        if IBCheck.collecting { IBCheck.storyboardLoaders.append(loader) }
        // The window's content controller (a relationship segue).
        for r in relationships where r["relationship"] == "window.shadowedContentViewController" {
            if let d = r["destination"].flatMap({ storyboard?.document?.elements[$0] }), let vc = storyboard?.instantiate(d) as? NSViewController {
                let size = vc.view.frame.size
                w.contentViewController = vc
                if size.width > 0, size.height > 0 { w.setContentSize(size) }
            }
        }
    }
}

extension IBLoader {
    /// Re-queues a scene's connections not yet made (they involve the view
    /// or window loading now).
    func requeueConnections(of scene: IBLoader) {
        for (list, source) in scene.allConnections { queueConnections(list, source) }
    }
}

@MainActor enum IBSegues {
    /// Hooks a `<segue>` connection up: relationships and embeds now (or as
    /// the controller's view loads), triggered segues to their trigger.
    static func connect(_ s: IBElement, source: AnyObject, loader: IBLoader) {
        let kind = s["kind"] ?? "show"
        _ = s["destination"]; _ = s["id"]; _ = s["identifier"]; _ = s["relationship"]
        _ = s["popoverAnchorView"]; _ = s["popoverBehavior"]; _ = s["preferredEdge"]; _ = s["customClass"]
        guard let storyboard = loader.storyboard, let destID = s["destination"], let dest = storyboard.document?.elements[destID] else { return }
        switch kind {
        case "relationship":
            switch s["relationship"] {
            case "window.shadowedContentViewController":
                IBStoryboardState.state(of: source)?.relationships.append(s)
            case "splitItems":
                guard let svc = source as? NSSplitViewController, let vc = storyboard.instantiate(dest) as? NSViewController else { return }
                let index = svc.splitViewItems.count
                let props = IBStoryboardState.splitItems[ObjectIdentifier(svc)] ?? []
                let p = index < props.count ? props[index] : nil
                let item: NSSplitViewItem
                switch p?["behavior"] {
                case "sidebar": item = NSSplitViewItem(sidebarWithViewController: vc)
                case "contentList": item = NSSplitViewItem(contentListWithViewController: vc)
                case "inspector": item = NSSplitViewItem(inspectorWithViewController: vc)
                default: item = NSSplitViewItem(viewController: vc)
                }
                if let p {
                    if let h = IBValue.priority(p["holdingPriority"]) { item.holdingPriority = h }
                    if let c = p.bool("canCollapse") { item.canCollapse = c }
                    if let c = p.bool("collapsed") { item.isCollapsed = c }
                    if let m = p.double("minimumThickness") { item.minimumThickness = CGFloat(m) }
                    if let m = p.double("maximumThickness") { item.maximumThickness = CGFloat(m) }
                    if let id = p.id { loader.objects[id] = item }
                    p.consumed = true
                }
                svc.addSplitViewItem(item)
            case "tabItems":
                guard let tvc = source as? NSTabViewController, let vc = storyboard.instantiate(dest) as? NSViewController else { return }
                let index = tvc.tabViewItems.count
                let props = IBStoryboardState.tabItems[ObjectIdentifier(tvc)] ?? []
                let item = NSTabViewItem(viewController: vc)
                if index < props.count {
                    let p = props[index]
                    if let l = loader.localized(p, "label") ?? p["label"] { item.label = l }
                    if let i = p["identifier"] { item.identifier = i }
                    _ = p.child(key: "label", "nil"); _ = p.child(key: "view", "nil")
                    if let img = loader.image(p) { item.image = img }
                    if let id = p.id { loader.objects[id] = item }
                    p.consumed = true
                }
                if item.label.isEmpty { item.label = vc.title ?? "" }
                tvc.addTabViewItem(item)
            default:
                loader.report("unsupported relationship segue \(s.attributes["relationship"] ?? "")")
            }
        case "embed":
            guard let container = source as? NSView else { return }
            loader.afterConnecting.append { [weak container] in
                guard let container else { return }
                let parent = loader.owner as? NSViewController
                guard let vc = storyboard.instantiate(dest) as? NSViewController else { return }
                let segue = NSStoryboardSegue(identifier: s.attributes["identifier"] ?? "", source: parent as Any, destination: vc)
                segue.kind = "embed"
                parent?.prepare(for: segue, sender: nil)
                parent?.addChild(vc)
                let v = vc.view
                v.frame = container.bounds
                v.autoresizingMask = [.width, .height]
                v.translatesAutoresizingMaskIntoConstraints = true
                container.addSubview(v)
            }
        default:
            // Triggered by a control, menu item or toolbar item, or by
            // performSegue(withIdentifier:) on the controller.
            if source is NSViewController || source is NSWindowController {
                if let id = s["identifier"] { IBStoryboardState.state(of: source)?.segues[id] = s }
                return
            }
            let controller = loader.owner
            let performer = IBSeguePerformer(s, source: controller, loader: loader)
            IBSeguePerformer.performers[ObjectIdentifier(source)] = performer
            IBKVC.setAction(Selector("perform:"), target: performer, of: source)
            if let id = s["identifier"], let c = controller { IBStoryboardState.state(of: c)?.segues[id] = s }
        }
    }

    /// `performSegue(withIdentifier:sender:)`.
    static func perform(_ identifier: String, from source: AnyObject, sender: Any?) {
        guard let state = IBStoryboardState.state(of: source), let s = state.segues[identifier] else {
            FileHandle.standardError.write(Data("runway: \(type(of: source)) has no segue with identifier \(identifier)\n".utf8))
            return
        }
        perform(element: s, from: source, sender: sender, storyboard: state.storyboard)
    }

    static func perform(element s: IBElement, from source: AnyObject, sender: Any?, storyboard: NSStoryboard?) {
        let identifier = s.attributes["identifier"] ?? ""
        if !identifier.isEmpty {
            if let vc = source as? NSViewController, !vc.shouldPerformSegue(withIdentifier: identifier, sender: sender) { return }
            if let wc = source as? NSWindowController, !wc.shouldPerformSegue(withIdentifier: identifier, sender: sender) { return }
        }
        guard let storyboard, let destID = s.attributes["destination"], let dest = storyboard.document?.elements[destID],
              let destination = storyboard.instantiate(dest) else { return }
        let segue = NSStoryboardSegue(identifier: identifier, source: source, destination: destination)
        segue.kind = s.attributes["kind"] ?? "show"
        segue.element = s
        segue.sender = sender.map { $0 as AnyObject }
        if let vc = source as? NSViewController { vc.prepare(for: segue, sender: sender) }
        if let wc = source as? NSWindowController { wc.prepare(for: segue, sender: sender) }
        IBRetained.keep(destination)
        segue.perform()
    }

    /// An object of the source controller's scene by id (popover anchors).
    static func lookup(_ id: String, near vc: NSViewController) -> AnyObject? {
        IBStoryboardState.state(of: vc)?.sceneLoader?.objects[id]
    }
}

// MARK: Bindings

/// Cocoa bindings, the common case: a control's value, enabled or hidden
/// state bound to `NSUserDefaultsController`'s `values.<key>` or to a KVC
/// key path of another object. Values flow in at load and when user
/// defaults change; a control's edits flow back when it sends its action.
@MainActor enum IBBindings {
    @MainActor final class Proxy: NSObject {
        let write: (Any?) -> Void
        weak var originalTarget: AnyObject?
        let originalAction: Selector?
        static var registered = false
        static var proxies: [ObjectIdentifier: [Proxy]] = [:]
        init(write: @escaping (Any?) -> Void, target: AnyObject?, action: Selector?) {
            self.write = write
            originalTarget = target
            originalAction = action
            super.init()
            if !Self.registered {
                Self.registered = true
                RunwayObjC.registerSelector(Selector("_runwayBindingChanged:"), for: Proxy.self) { p, args in
                    MainActor.assumeIsolated { (p as? Proxy)?.changed(args.first ?? nil) }
                    return nil
                }
            }
        }
        func changed(_ sender: Any?) {
            write(sender)
            if let a = originalAction { NSApplication.shared.sendAction(a, to: originalTarget, from: sender) }
        }
    }

    static func bind(_ b: IBElement, source: AnyObject, loader: IBLoader) {
        guard let name = b["name"], let keyPath = b["keyPath"], let destID = b["destination"] else { return }
        _ = b["id"]
        var transformer = b.child(key: "options")?.children.first { $0.attributes["key"] == "NSValueTransformerName" }.flatMap { IBValue.string($0) }
        if let opts = b.child(key: "options") { opts.consumed = true; for o in opts.children { o.consumed = true; for a in o.attributes.keys { _ = o[a] } } }
        _ = b["previousBinding"]
        if transformer == nil { transformer = nil }
        loader.afterConnecting.append { [weak loader] in
            guard let loader, let dest = loader.resolve(destID) else { return }
            let read: () -> Any? = {
                if dest is NSUserDefaultsController, keyPath.hasPrefix("values.") {
                    let key = String(keyPath.dropFirst(7))
                    return (dest as! NSUserDefaultsController).defaults.object(forKey: key)
                }
                return (dest as? NSObject)?.value(forKeyPath: keyPath)
            }
            let write: (Any?) -> Void = { v in
                let v = transform(v, transformer, reverse: true)
                if dest is NSUserDefaultsController, keyPath.hasPrefix("values.") {
                    (dest as! NSUserDefaultsController).defaults.set(v, forKey: String(keyPath.dropFirst(7)))
                } else {
                    (dest as? NSObject)?.setValue(v, forKeyPath: keyPath)
                }
            }
            let apply = { [weak source] in
                guard let source else { return }
                apply(name, transform(read(), transformer, reverse: false), to: source)
            }
            apply()
            if dest is NSUserDefaultsController {
                let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { apply() }
                }
                IBRetained.keep(token as AnyObject)
            }
            // Edits flow back when the control acts.
            if ["value", "selectedIndex", "selectedTag", "selectedValue", "selectedObject"].contains(name), let c = source as? NSControl {
                let proxy = Proxy(write: { [weak c] _ in
                    guard let c else { return }
                    write(value(name, of: c))
                }, target: c.target, action: c.action)
                Proxy.proxies[ObjectIdentifier(c), default: []].append(proxy)
                c.target = proxy
                c.action = Selector("_runwayBindingChanged:")
            }
        }
    }

    static func transform(_ v: Any?, _ name: String?, reverse: Bool) -> Any? {
        switch name {
        case "NSNegateBoolean": return !(IBKVC.bool(v) ?? false)
        case "NSIsNil": return v == nil || v is NSNull
        case "NSIsNotNil": return !(v == nil || v is NSNull)
        default: return v
        }
    }

    static func apply(_ binding: String, _ v: Any?, to o: AnyObject) {
        switch (binding, o) {
        case ("value", let b as NSButton) where !(o is NSPopUpButton): b.state = (IBKVC.bool(v) ?? false) ? .on : .off
        case ("value", let s as NSSwitch): s.state = (IBKVC.bool(v) ?? false) ? .on : .off
        case ("value", let c as NSControl):
            if let s = v as? String { c.stringValue = s }
            else if let n = IBKVC.number(v) { if c is NSTextField { c.stringValue = "\(v!)" } else { c.doubleValue = n } }
            else if v == nil, c is NSTextField { c.stringValue = "" }
        case ("enabled", let c as NSControl): c.isEnabled = IBKVC.bool(v) ?? true
        case ("hidden", let view as NSView): view.isHidden = IBKVC.bool(v) ?? false
        case ("selectedIndex", let p as NSPopUpButton): if let n = IBKVC.number(v) { p.selectItem(at: Int(n)) }
        case ("selectedTag", let p as NSPopUpButton): if let n = IBKVC.number(v) { p.selectItem(withTag: Int(n)) }
        case ("selectedValue", let p as NSPopUpButton): if let s = v as? String { p.selectItem(withTitle: s) }
        case ("selectedIndex", let s as NSSegmentedControl): if let n = IBKVC.number(v) { s.selectedSegment = Int(n) }
        case ("title", let b as NSButton): if let s = v as? String { b.title = s }
        case ("toolTip", let view as NSView): view.toolTip = v as? String
        case ("editable", let t as NSTextField): t.isEditable = IBKVC.bool(v) ?? true
        default: break
        }
    }

    static func value(_ binding: String, of c: NSControl) -> Any? {
        switch (binding, c) {
        case ("value", let b as NSButton) where !(c is NSPopUpButton): return b.state == .on
        case ("value", let s as NSSwitch): return s.state == .on
        case ("value", let t as NSTextField): return t.stringValue
        case ("value", _): return c.doubleValue
        case ("selectedIndex", let p as NSPopUpButton): return p.indexOfSelectedItem
        case ("selectedTag", let p as NSPopUpButton): return p.selectedTag
        case ("selectedValue", let p as NSPopUpButton): return p.titleOfSelectedItem
        case ("selectedIndex", let s as NSSegmentedControl): return s.selectedSegment
        default: return nil
        }
    }
}
