// Instantiating an Interface Builder object graph, as Cocoa's nib loading
// does:
//
//  1. every object is created: views, controllers and cells decode through
//     `init?(coder:)` with an `IBCoder` (so an app's custom classes run
//     their own `init(coder:)`, and the IB properties are in place by the
//     time `super.init(coder:)` returns, as on the Mac); windows through
//     `init(contentRect:styleMask:backing:defer:)`; custom objects
//     through `init()`;
//  2. Auto Layout constraints are installed;
//  3. connections are made: outlets and outlet collections by key-value
//     coding (the transpiler's generated tables for the app's `@IBOutlet`s,
//     IBKVC.swift for AppKit's own outlets), actions as target/action
//     (First Responder: a nil target), bindings;
//  4. user-defined runtime attributes are set (KVC);
//  5. `awakeFromNib` goes to every object, then the File's Owner.
//
// Classes named by `customClass`/`customModule` are found through
// RunwayObjC's ClassRegistry (the app's generated table, else the Swift
// runtime's metadata).

import Foundation
import RunwayCore

// MARK: The coder

/// The coder a decoded object's `init?(coder:)` receives: its element in the
/// document and the loader. Keyed decoding answers from the element's
/// attributes.
final class IBCoder: NSCoder, @unchecked Sendable {
    let element: IBElement
    unowned let loader: IBLoader
    /// Framework `init?(coder:)` nesting: properties decode when the
    /// outermost AppKit initializer finishes.
    var depth = 0
    var decoded = false

    init(_ element: IBElement, _ loader: IBLoader) {
        self.element = element
        self.loader = loader
        super.init()
    }

    override var allowsKeyedCoding: Bool { true }
    override func containsValue(forKey key: String) -> Bool {
        element.attributes[key] != nil || element.children.contains { $0.attributes["key"] == key }
    }
    override func decodeObject(forKey key: String) -> Any? {
        if let a = element.attributes[key] { return a }
        guard let c = element.children.first(where: { $0.attributes["key"] == key }) else { return nil }
        if c.name == "string" { return MainActor.assumeIsolated { IBValue.string(c) } }
        return MainActor.assumeIsolated { loader.object(for: c) }
    }
    override func decodeBool(forKey key: String) -> Bool { element.bool(key) ?? false }
    override func decodeInteger(forKey key: String) -> Int { element.int(key) ?? 0 }
    override func decodeInt32(forKey key: String) -> Int32 { Int32(truncatingIfNeeded: element.int(key) ?? 0) }
    override func decodeInt64(forKey key: String) -> Int64 { Int64(element.int(key) ?? 0) }
    override func decodeDouble(forKey key: String) -> Double { element.double(key) ?? 0 }
    override func decodeFloat(forKey key: String) -> Float { Float(element.double(key) ?? 0) }
}

/// The hooks AppKit's `init?(coder:)` implementations call.
enum IBDecoding {
    static func enter(_ coder: NSCoder) { (coder as? IBCoder)?.depth += 1 }

    /// The `<rect key="frame">` of the element being decoded.
    static func frame(_ coder: NSCoder) -> CGRect {
        guard let c = coder as? IBCoder else { return .zero }
        return MainActor.assumeIsolated { IBValue.rect(c.element.child(key: "frame", "rect")) ?? .zero }
    }

    /// Decodes the element's properties when the outermost AppKit
    /// initializer in the chain finishes (an app subclass's initializer then
    /// runs the rest of its body, seeing them set).
    static func leave(_ object: AnyObject, _ coder: NSCoder) {
        guard let c = coder as? IBCoder else { return }
        c.depth -= 1
        guard c.depth == 0, !c.decoded else { return }
        c.decoded = true
        MainActor.assumeIsolated { c.loader.decode(object, c.element) }
    }
}

/// First Responder: actions sent to it go up the responder chain.
final class IBFirstResponder: NSObject, @unchecked Sendable {
    static let shared = IBFirstResponder()
}

// MARK: The loader

@preconcurrency @MainActor
public final class IBLoader {
    public let document: IBDocument
    let bundle: Bundle
    weak var storyboard: NSStoryboard?
    /// The File's Owner (also what scene placeholders for the controller resolve to).
    var owner: AnyObject?
    /// Objects by id, including placeholders.
    var objects: [String: AnyObject] = [:]
    /// Ids that stand for objects outside this load (a storyboard scene's
    /// controller, a prototype cell's table), resolved through `outside`.
    var outside: ((String) -> AnyObject?)?
    /// Every object made, in order (for awakeFromNib).
    var made: [AnyObject] = []
    private var pendingConnections: [(IBElement, AnyObject)] = []
    /// Every connection list met, for a storyboard view's later load.
    private(set) var allConnections: [(IBElement, AnyObject)] = []
    /// Connections made (by id), across a scene's loads.
    var doneConnections: Set<String> = []
    private var pendingConstraints: [(IBElement, NSView)] = []
    private var pendingAttributes: [(IBElement, AnyObject)] = []
    /// Work after connections (selections, table reloads, windows to show).
    var afterConnecting: [() -> Void] = []
    /// Element subtrees not to instantiate (a storyboard view controller's
    /// view, which loads with the view).
    var skip: Set<String> = []
    /// Diagnostics: classes that couldn't be found.
    public internal(set) var missingClasses: [String] = []
    /// Whether the main menu / NSApp placeholders apply (main nib or storyboard).
    var isMainInterface = false
    /// Windows marked "Visible At Launch".
    var windowsToShow: [NSWindow] = []
    var constraintCount = 0
    var connectionCount = 0

    public init(document: IBDocument, bundle: Bundle?, owner: AnyObject?) {
        self.document = document
        self.bundle = bundle ?? .main
        self.owner = owner
    }

    var resources: IBElement? { document.root.child("resources") }

    // MARK: Top level

    /// Instantiates a xib's `<objects>`; the result is its top-level objects
    /// (placeholders excluded).
    public func instantiateXib() -> [AnyObject] {
        guard let list = document.objects else { return [] }
        let top = instantiate(list.children)
        finish()
        return top
    }

    /// Creates the objects (not the placeholders) among `elements`.
    func instantiate(_ elements: [IBElement]) -> [AnyObject] {
        var top: [AnyObject] = []
        list: for e in elements {
            e.consumed = true
            if placeholder(e) { continue list }
            if let o = object(for: e) { top.append(o) }
        }
        return top
    }

    /// Registers File's Owner, First Responder and Application placeholders;
    /// true if `e` is one.
    func placeholder(_ e: IBElement) -> Bool {
        guard let id = e.id else { return false }
        let ident = e["placeholderIdentifier"]
        let member = e["sceneMemberID"]
        if id == "-2" || ident == "IBFilesOwner" {
            objects[id] = owner ?? NSApplication.shared
            _ = e["userLabel"]; _ = e["customClass"]; _ = e["customModule"]; _ = e["customModuleProvider"]
            if let c = e.child("connections") { queueConnections(c, objects[id]!) }
            return true
        }
        if id == "-1" || ident == "IBFirstResponder" || member == "firstResponder" {
            objects[id] = IBFirstResponder.shared
            _ = e["userLabel"]; _ = e["customClass"]
            return true
        }
        if id == "-3" || ident == "NSApplication" || e.name == "application" {
            objects[id] = NSApplication.shared
            _ = e["userLabel"]; _ = e["customClass"]; _ = e["customModule"]; _ = e["customModuleProvider"]
            if e.name == "application" { decodeApplication(e) }
            else if let c = e.child("connections") { queueConnections(c, NSApplication.shared) }
            return true
        }
        if e.name == "placeholder" {
            // Other external objects: storyboard-provided or unknown.
            objects[id] = ident.flatMap { externalObjects[$0] } ?? owner ?? NSNull()
            return true
        }
        return false
    }

    /// `NSNib.instantiate`'s external name table (`NSNibExternalObjects`).
    var externalObjects: [String: AnyObject] = [:]

    // MARK: Making objects

    /// The object for an element: made once per load.
    func object(for e: IBElement) -> AnyObject? {
        if let id = e.id, let o = objects[id] { return o }
        if let ref = e["reference"] { return resolve(ref) }
        if let id = e.id, skip.contains(id) { return nil }
        e.consumed = true
        let o = make(e)
        if let o, let id = e.id, objects[id] == nil { register(o, e, id: id) }
        return o
    }

    /// The object a connection or attribute names by id.
    func resolve(_ id: String) -> AnyObject? {
        if let o = objects[id] { return o }
        if let o = outside?(id) { return o }
        // Not made yet (a forward reference): make it now.
        if let e = document.elements[id], !isSkipped(id) {
            if e.name == "constraint" { return nil }
            return object(for: e)
        }
        return nil
    }

    private func register(_ o: AnyObject, _ e: IBElement, id: String) {
        objects[id] = o
        if !made.contains(where: { $0 === o }) { made.append(o) }
    }

    /// Default AppKit classes by element name.
    static let viewClasses: [String: NSView.Type] = [
        "view": NSView.self, "customView": NSView.self, "containerView": NSView.self,
        "button": NSButton.self, "textField": NSTextField.self, "secureTextField": NSSecureTextField.self,
        "searchField": NSSearchField.self, "comboBox": NSComboBox.self, "tokenField": NSTokenField.self,
        "popUpButton": NSPopUpButton.self, "segmentedControl": NSSegmentedControl.self, "slider": NSSlider.self,
        "stepper": NSStepper.self, "progressIndicator": NSProgressIndicator.self, "levelIndicator": NSLevelIndicator.self,
        "colorWell": NSColorWell.self, "datePicker": NSDatePicker.self, "imageView": NSImageView.self, "box": NSBox.self,
        "scrollView": NSScrollView.self, "clipView": NSClipView.self, "tableView": NSTableView.self,
        "outlineView": NSOutlineView.self, "tableHeaderView": NSTableHeaderView.self, "tableCellView": NSTableCellView.self,
        "tableRowView": NSTableRowView.self, "textView": NSTextView.self, "stackView": NSStackView.self,
        "splitView": NSSplitView.self, "tabView": NSTabView.self, "visualEffectView": NSVisualEffectView.self,
        "collectionView": NSCollectionView.self, "gridView": NSGridView.self, "switch": NSSwitch.self,
        "scroller": NSScroller.self,
    ]

    /// The class `e` names (`customClass`), when it's a `base`; else `fallback`.
    func classFor<T>(_ e: IBElement, _ base: T.Type, fallback: T.Type) -> T.Type {
        guard let name = e["customClass"] else { return fallback }
        let module = e["customModule"]
        _ = e["customModuleProvider"]
        if let c = ClassRegistry.lookup(name, module: module) ?? ClassRegistry.lookup(name, module: "AppKit") {
            if let t = c as? T.Type { return t }
            report("\(name) isn't a \(base)")
            return fallback
        }
        let full = (module.map { $0 + "." } ?? "") + name
        if !missingClasses.contains(full) { missingClasses.append(full) }
        report("unknown class \(full) (\(e.name) \(e.id ?? "")); using \(fallback)")
        return fallback
    }

    func report(_ message: String) {
        guard IBLoader.logging else { return }
        FileHandle.standardError.write(Data("runway: Interface Builder (\(document.name)): \(message)\n".utf8))
    }
    nonisolated(unsafe) static var logging = ProcessInfo.processInfo.environment["RUNWAY_IB_QUIET"] == nil

    private func make(_ e: IBElement) -> AnyObject? {
        if let base = Self.viewClasses[e.name] {
            let cls = classFor(e, NSView.self, fallback: base)
            return cls.init(coder: IBCoder(e, self))
        }
        switch e.name {
        case "window", "panel": return makeWindow(e)
        case "menu": return makeMenu(e)
        case "menuItem": return makeMenuItem(e)
        case "customObject", "userDefaultsController", "objectController", "arrayController", "dictionaryController", "treeController":
            return makeCustomObject(e)
        case "viewController", "splitViewController", "tabViewController", "pagecontroller", "collectionViewItem":
            let fallback: NSViewController.Type = switch e.name {
            case "splitViewController": NSSplitViewController.self
            case "tabViewController": NSTabViewController.self
            case "collectionViewItem": NSCollectionViewItem.self
            default: NSViewController.self
            }
            let cls = classFor(e, NSViewController.self, fallback: fallback)
            return cls.init(coder: IBCoder(e, self))
        case "windowController":
            let cls = classFor(e, NSWindowController.self, fallback: NSWindowController.self)
            return cls.init(coder: IBCoder(e, self))
        case "constraint":
            return nil  // installed with their view
        case "tableColumn":
            return makeTableColumn(e)
        case "popover":
            let cls = classFor(e, NSPopover.self, fallback: NSPopover.self)
            return cls.init(coder: IBCoder(e, self))
        case "toolbar":
            return makeToolbar(e)
        case "toolbarItem":
            return makeToolbarItem(e)
        case "layoutGuide", "viewLayoutGuide":
            return nil  // resolved by constraints
        case "wkWebView", "pathControl", "matrix", "ruler", "openGLView", "sceneView", "avPlayerView", "mtkView", "pdfView",
             "browser", "ibPlaceholderView", "levelIndicatorCell", "shareButton", "tokenFieldCell", "colorPicker":
            report("no \(e.name) in Runway's AppKit: a plain view stands in for it")
            return NSView(coder: IBCoder(e, self))
        default:
            report("unsupported element <\(e.name)>")
            return nil
        }
    }

    // MARK: Decoding (from init?(coder:))

    /// Called once an object's outermost AppKit `init?(coder:)` finishes.
    func decode(_ object: AnyObject, _ e: IBElement) {
        if let id = e.id { register(object, e, id: id) }
        collectConnections(object, e)
        if let v = object as? NSView { decodeView(v, e) }
        else if let vc = object as? NSViewController { decodeViewController(vc, e) }
        else if let wc = object as? NSWindowController { decodeWindowController(wc, e) }
        else if let p = object as? NSPopover { decodePopover(p, e) }
    }

    /// Connections and runtime attributes of `e`, made later.
    func collectConnections(_ object: AnyObject, _ e: IBElement) {
        if let c = e.child("connections") { queueConnections(c, object) }
        if let a = e.child("userDefinedRuntimeAttributes") { pendingAttributes.append((a, object)) }
        _ = e["userLabel"]; _ = e["sceneMemberID"]; _ = e["colorLabel"]; _ = e["misplaced"]; _ = e["ambiguous"]
        _ = e["placeholderIntrinsicWidth"]; _ = e["placeholderIntrinsicHeight"]; _ = e["customModuleProvider"]
        _ = e["key"]; _ = e["id"]
    }

    func queueConnections(_ list: IBElement, _ source: AnyObject) {
        pendingConnections.append((list, source))
        if !allConnections.contains(where: { $0.0 === list }) { allConnections.append((list, source)) }
    }

    /// Whether `id` is inside a subtree this load leaves out.
    func isSkipped(_ id: String) -> Bool {
        guard !skip.isEmpty else { return false }
        var e = document.elements[id]
        while let x = e {
            if let i = x.attributes["id"], skip.contains(i) { return true }
            e = x.parent
        }
        return false
    }

    func addConstraints(_ list: IBElement, to view: NSView) {
        for c in list.children("constraint") { pendingConstraints.append((c, view)) }
    }

    // MARK: Finishing

    /// Installs constraints, makes connections, sets runtime attributes and
    /// sends awakeFromNib.
    func finish(awakeOwner: Bool = true) {
        installConstraints()
        let conns = pendingConnections
        pendingConnections = []
        for (list, source) in conns { connect(list, source) }
        // Connections made while connecting (forward references) too.
        while !pendingConnections.isEmpty {
            let more = pendingConnections
            pendingConnections = []
            installConstraints()
            for (list, source) in more { connect(list, source) }
        }
        let attrs = pendingAttributes
        pendingAttributes = []
        for (a, o) in attrs { IBKVC.applyRuntimeAttributes(a, to: o, loader: self) }
        let after = afterConnecting
        afterConnecting = []
        for f in after { f() }
        let objs = made
        for o in objs { awake(o) }
        if awakeOwner, let owner, !(owner is NSApplication), !objs.contains(where: { $0 === owner }) { awake(owner) }
    }

    func awake(_ o: AnyObject) {
        if let r = o as? NSResponder { r.awakeFromNib() }
        else if let m = o as? NSMenu { m.awakeFromNib() }
        else if let m = o as? NSMenuItem { m.awakeFromNib() }
        else if RunwayObjC.responds(o, to: Selector("awakeFromNib")) { RunwayObjC.perform(o, Selector("awakeFromNib")) }
    }

    /// Whether `o` was made from a subtree this load leaves out.
    func isSkipped(_ o: AnyObject) -> Bool {
        guard !skip.isEmpty else { return false }
        return objects.contains { $0.value === o && isSkipped($0.key) }
    }

    private func installConstraints() {
        let cs = pendingConstraints
        pendingConstraints = []
        for (e, view) in cs {
            guard let c = makeConstraint(e, in: view) else { continue }
            view.addConstraint(c)
            constraintCount += 1
            if let id = e.id { objects[id] = c; made.append(c) }
        }
    }

    /// A `<constraint>`: items default to the view holding it; layout
    /// guides (`safeArea`, `layoutMargins`) map to the view's guides.
    func makeConstraint(_ e: IBElement, in view: NSView) -> NSLayoutConstraint? {
        func item(_ id: String?) -> AnyObject? {
            guard let id else { return view }
            if let g = document.elements[id], g.name == "viewLayoutGuide" || g.name == "layoutGuide" {
                g.consumed = true
                let owner = (g.parent.flatMap { $0.id.flatMap { objects[$0] } } as? NSView) ?? view
                switch g["key"] {
                case "safeArea": return owner.safeAreaLayoutGuide
                case "layoutMargins": return owner.layoutMarginsGuide
                default:
                    let guide = NSLayoutGuide()
                    owner.addLayoutGuide(guide)
                    objects[id] = guide
                    return guide
                }
            }
            return resolve(id)
        }
        e.consumed = true
        guard let a1 = IBValue.layoutAttribute(e["firstAttribute"]) else { report("constraint attribute \(e.attributes["firstAttribute"] ?? "?")"); return nil }
        guard let first = item(e["firstItem"]) else { return nil }
        let secondID = e["secondItem"]
        let a2 = IBValue.layoutAttribute(e["secondAttribute"]) ?? (secondID == nil ? .notAnAttribute : a1)
        var second: AnyObject? = nil
        if secondID != nil || a2 != .notAnAttribute {
            second = item(secondID)
            if second == nil { return nil }
        }
        if a2 == .notAnAttribute { second = nil }
        let relation: NSLayoutConstraint.Relation = switch e["relation"] {
        case "greaterThanOrEqual": .greaterThanOrEqual
        case "lessThanOrEqual": .lessThanOrEqual
        default: .equal
        }
        var multiplier: CGFloat = 1
        if let m = e["multiplier"] {
            let parts = m.split(separator: ":")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { multiplier = CGFloat(a / b) }
            else if let v = Double(m) { multiplier = CGFloat(v) }
        }
        let c = NSLayoutConstraint(item: first, attribute: a1, relatedBy: relation, toItem: second, attribute: a2,
                                   multiplier: multiplier, constant: CGFloat(e.double("constant") ?? 0))
        if let p = IBValue.priority(e["priority"]) { c.priority = p }
        c.identifier = e["identifier"]
        _ = e["symbolic"]; _ = e["id"]; _ = e["placeholder"]
        if let active = e.bool("active"), !active { return nil }
        return c
    }

    // MARK: Connections

    private func connect(_ list: IBElement, _ source: AnyObject) {
        list.consumed = true
        var collections: [String: [AnyObject]] = [:]
        var collectionOrder: [String] = []
        for c in list.children {
            c.consumed = true
            if let id = c.attributes["id"], doneConnections.contains(id) { continue }
            // Leave connections into a subtree not loaded yet (a storyboard
            // controller's view) for when it loads.
            if let d = c.attributes["destination"] ?? c.attributes["target"], isSkipped(d) { continue }
            if isSkipped(source) { continue }
            if let id = c.attributes["id"] { doneConnections.insert(id) }
            switch c.name {
            case "outlet":
                guard let property = c["property"], let destID = c["destination"] else { continue }
                guard let dest = resolve(destID) else { report("outlet \(property): no object \(destID)"); continue }
                IBKVC.setOutlet(property, of: source, to: dest is IBFirstResponder ? nil : dest, loader: self)
                connectionCount += 1
            case "outletCollection":
                guard let property = c["property"], let destID = c["destination"], let dest = resolve(destID) else { continue }
                _ = c["collectionClass"]
                if collections[property] == nil { collectionOrder.append(property) }
                collections[property, default: []].append(dest)
                connectionCount += 1
            case "action":
                guard let sel = c["selector"] else { continue }
                let target = c["target"].flatMap { resolve($0) }
                IBKVC.setAction(Selector(sel), target: target is IBFirstResponder ? nil : target, of: source, trigger: c["trigger"])
                connectionCount += 1
            case "binding":
                IBBindings.bind(c, source: source, loader: self)
                connectionCount += 1
            case "segue":
                IBSegues.connect(c, source: source, loader: self)
                connectionCount += 1
            default:
                report("unsupported connection <\(c.name)>")
            }
            _ = c["id"]
        }
        for p in collectionOrder { IBKVC.setOutlet(p, of: source, to: collections[p]!, loader: self) }
    }
}
