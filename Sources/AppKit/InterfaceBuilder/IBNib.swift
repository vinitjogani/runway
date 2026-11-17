// NSNib, Bundle.loadNibNamed, nib-backed view and window controllers, and
// app launch from Info.plist's NSMainNibFile / NSMainStoryboardFile.

import Foundation
import RunwayCore

// MARK: NSNib

/// A loaded Interface Builder document (a .xib; storyboards use
/// NSStoryboard), instantiable any number of times.
@preconcurrency @MainActor
open class NSNib: NSObject {
    public typealias Name = String

    let document: IBDocument?
    let bundle: Bundle?
    /// A view-based table's prototype cell view (a nib of one view).
    private let prototype: IBElement?
    private weak var prototypeLoader: IBLoader?
    private var prototypeContext: [String: AnyObject] = [:]

    /// `NSNib(nibNamed:bundle:)`: nil when the bundle has no such document.
    public init?(nibNamed name: NSNib.Name, bundle: Bundle?) {
        guard let d = try? IBDocument.named(name, bundle: bundle, kind: .xib) else { return nil }
        document = d
        self.bundle = bundle
        prototype = nil
        super.init()
    }

    /// From a document's contents (`.xib` XML).
    public init(nibData: Data, bundle: Bundle?) {
        document = try? IBDocument(data: nibData)
        self.bundle = bundle
        prototype = nil
        super.init()
    }

    init(prototype: IBElement, loader: IBLoader) {
        document = loader.document
        bundle = loader.bundle
        self.prototype = prototype
        prototypeLoader = loader
        prototypeContext = loader.objects
        super.init()
    }

    /// Instantiates the document's objects with `owner` as File's Owner; the
    /// top-level objects come back in `topLevelObjects`.
    @discardableResult
    open func instantiate(withOwner owner: Any?, topLevelObjects: UnsafeMutablePointer<NSArray?>?) -> Bool {
        guard let objs = instantiate(owner: owner) else { return false }
        topLevelObjects?.pointee = objs as NSArray
        return true
    }

    /// The Swift spelling: the top-level objects, or nil on failure.
    open func instantiate(owner: Any?) -> [Any]? {
        guard let document else { return nil }
        let ownerObject = owner.map { $0 as AnyObject }
        if let prototype {
            // A prototype cell: ids outside it resolve to the table's
            // nib objects (its controller, the File's Owner → owner).
            let loader = IBLoader(document: document, bundle: bundle, owner: ownerObject)
            let context = prototypeContext
            let ownerID = prototypeLoader?.owner
            loader.outside = { id in
                if id == "-2" { return ownerObject ?? ownerID }
                return context[id]
            }
            guard let v = loader.object(for: prototype) else { return nil }
            loader.finish(awakeOwner: false)
            if IBCheck.collecting { IBCheck.storyboardLoaders.append(loader) }
            return [v]
        }
        let loader = IBLoader(document: document, bundle: bundle, owner: ownerObject)
        let top = loader.instantiateXib()
        for o in top { IBRetained.keep(o) }
        for w in loader.windowsToShow { w.makeKeyAndOrderFront(nil) }
        return top
    }
}

extension Bundle {
    /// `loadNibNamed(_:owner:topLevelObjects:)`.
    @MainActor @discardableResult
    public func loadNibNamed(_ nibName: NSNib.Name, owner: Any?, topLevelObjects: UnsafeMutablePointer<NSArray?>?) -> Bool {
        guard let nib = NSNib(nibNamed: nibName, bundle: self) else {
            FileHandle.standardError.write(Data("runway: no nib named \(nibName)\n".utf8))
            return false
        }
        return nib.instantiate(withOwner: owner, topLevelObjects: topLevelObjects)
    }

    /// The Objective-C era's `loadNibNamed:owner:` (returns success).
    @MainActor @discardableResult
    public static func loadNibNamed(_ nibName: NSNib.Name, owner: Any?) -> Bool {
        Bundle.main.loadNibNamed(nibName, owner: owner, topLevelObjects: nil)
    }
}

// MARK: View-based table cells

/// `register(_:forIdentifier:)` nibs and IB prototype cell views, from which
/// `makeView(withIdentifier:owner:)` makes cells.
@MainActor enum IBTableCellNibs {
    private static var nibs: [ObjectIdentifier: [NSUserInterfaceItemIdentifier: NSNib]] = [:]

    static func register(_ nib: NSNib?, _ table: NSTableView, _ id: NSUserInterfaceItemIdentifier, prototype: Bool = false) {
        let key = ObjectIdentifier(table)
        if prototype, nibs[key]?[id] != nil { return }   // the app's registration wins
        nibs[key, default: [:]][id] = nib
    }

    static func registered(_ table: NSTableView) -> [NSUserInterfaceItemIdentifier: NSNib]? { nibs[ObjectIdentifier(table)] }

    static func make(_ table: NSTableView, _ id: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        guard let nib = nibs[ObjectIdentifier(table)]?[id] else { return nil }
        let objs = nib.instantiate(owner: owner) ?? []
        guard let v = objs.lazy.compactMap({ $0 as? NSView }).first else { return nil }
        if v.identifier == nil { v.identifier = id }
        return v
    }
}

// MARK: Controllers backed by documents

@MainActor enum IBLoading {
    /// NSViewController.loadView: its storyboard scene's view, or the nib
    /// named `nibName` (or like the class), with the controller as File's Owner.
    static func loadView(of vc: NSViewController) -> Bool {
        if let state = IBStoryboardState.state(of: vc) { return state.loadView(vc) }
        let bundle = vc.nibBundle ?? Bundle.main
        let names: [String]
        if let n = vc.nibName { names = [n] } else {
            let cls = String(describing: type(of: vc))
            names = [cls] + (cls.hasSuffix("Controller") ? [String(cls.dropLast("Controller".count))] : [])
        }
        for n in names where IBDocument.exists(n, bundle: bundle, kind: .xib) {
            guard let nib = NSNib(nibNamed: n, bundle: bundle) else { continue }
            _ = nib.instantiate(owner: vc)
            return vc.isViewLoaded
        }
        return false
    }

    /// NSWindowController.loadWindow: its storyboard scene's window, or the
    /// nib `windowNibName` with `owner` (else the controller) as File's Owner.
    static func loadWindow(of wc: NSWindowController) {
        if let state = IBStoryboardState.state(of: wc) { state.loadWindow(wc); return }
        guard let name = wc.windowNibName else { return }
        guard let nib = NSNib(nibNamed: name, bundle: Bundle.main) else {
            FileHandle.standardError.write(Data("runway: no window nib named \(name)\n".utf8))
            return
        }
        _ = nib.instantiate(owner: wc.owner ?? wc)
    }
}

// MARK: Launch

extension NSApplication {
    /// What NSApplicationMain arranges for launch: the main storyboard's or
    /// nib's objects before `applicationWillFinishLaunching`, the storyboard's
    /// initial controller after it.
    struct LaunchHooks {
        var loadMainInterface: (() -> Void)?
        var showInitialController: (() -> Void)?
    }
    static var launchHooks = LaunchHooks()
}

@MainActor enum IBLaunch {
    /// Reads Info.plist's NSMainStoryboardFile / NSMainNibFile.
    static func prepare() {
        let info = Bundle.main.infoDictionary ?? [:]
        if let name = info["NSMainStoryboardFile"] as? String, !name.isEmpty {
            NSApplication.launchHooks.loadMainInterface = {
                guard let sb = try? NSStoryboard.load(name, bundle: .main) else {
                    FileHandle.standardError.write(Data("runway: no storyboard named \(name)\n".utf8))
                    return
                }
                NSStoryboard._main = sb
                sb.instantiateApplicationScene()
            }
            NSApplication.launchHooks.showInitialController = {
                guard let sb = NSStoryboard._main, let c = sb.instantiateInitialController() else { return }
                IBRetained.keep(c as AnyObject)
                if let wc = c as? NSWindowController { wc.showWindow(nil) }
                else if let vc = c as? NSViewController {
                    let w = NSWindow(contentViewController: vc)
                    IBRetained.keep(w)
                    w.makeKeyAndOrderFront(nil)
                }
            }
        } else if let name = info["NSMainNibFile"] as? String, !name.isEmpty {
            NSApplication.launchHooks.loadMainInterface = {
                guard let d = try? IBDocument.named(name, bundle: .main, kind: .xib) else {
                    FileHandle.standardError.write(Data("runway: no nib named \(name)\n".utf8))
                    return
                }
                let loader = IBLoader(document: d, bundle: .main, owner: NSApplication.shared)
                loader.isMainInterface = true
                for o in loader.instantiateXib() { IBRetained.keep(o) }
                for w in loader.windowsToShow { w.makeKeyAndOrderFront(nil) }
            }
        }
    }
}

extension NSApplicationDelegate {
    /// `@main` on an app delegate (and `@NSApplicationMain`): as on the Mac,
    /// NSApplicationMain, which makes the delegate from the main nib or
    /// storyboard. The delegate's module is where Interface Builder's
    /// `customModuleProvider="target"` classes are looked up.
    @preconcurrency @MainActor public static func main() {
        let full = String(reflecting: Self.self)
        if let module = full.split(separator: ".").first { ClassRegistry.addModule(String(module)) }
        ClassRegistry.register(Self.self as! AnyClass)
        let info = Bundle.main.infoDictionary ?? [:]
        if info["NSMainStoryboardFile"] == nil && info["NSMainNibFile"] == nil, NSApplication.shared.delegate == nil,
           let make = ClassRegistry.factory(for: Self.self as! AnyClass), let d = make() as? NSApplicationDelegate {
            // No main interface to make it (Cocoa would leave the app
            // without a delegate): made here when the class table can.
            IBRetained.keep(d)
            NSApplication.shared.delegate = d
        }
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

// MARK: NSUserDefaultsController

/// The shared user-defaults controller bindings in nibs go through
/// (`values.<key>`).
@preconcurrency @MainActor
public final class NSUserDefaultsController: NSObject {
    public static let shared = NSUserDefaultsController()
    public let defaults: UserDefaults
    public var appliesImmediately = true
    public var initialValues: [String: Any]?
    public init(defaults: UserDefaults? = nil, initialValues: [String: Any]? = nil) {
        self.defaults = defaults ?? .standard
        self.initialValues = initialValues
        super.init()
    }
    public override convenience init() { self.init(defaults: nil, initialValues: nil) }
    public func revertToInitialValues(_ sender: Any?) {
        for (k, v) in initialValues ?? [:] { defaults.set(v, forKey: k) }
    }
}
