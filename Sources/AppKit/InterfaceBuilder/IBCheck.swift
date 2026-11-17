// Loading a document without its app, to see what Runway makes of it:
// objects, classes, constraints and connections made, the app classes it
// names (not present without the app's code), and the elements and
// attributes the loader didn't read (unsupported). Used by the corpus
// harness (Tools/ib-check) and available to `runway check`.

import Foundation
import RunwayCore

public struct IBCheckResult: Sendable {
    public var file: String
    public var kind: String
    public var elements = 0
    public var objects = 0
    public var views = 0
    public var constraints = 0
    public var connections = 0
    public var scenes = 0
    /// AppKit classes instantiated, with counts.
    public var classes: [String: Int] = [:]
    /// customClass names the loader looked up (app classes: absent here).
    public var customClasses: [String] = []
    /// Elements never read, as "parent > element" with counts.
    public var unsupportedElements: [String: Int] = [:]
    /// Attributes never read, as "element.attribute" with counts.
    public var unsupportedAttributes: [String: Int] = [:]
    public var error: String?
}

@preconcurrency @MainActor
public enum IBCheck {
    /// Elements that carry no runtime state (Xcode's own bookkeeping).
    static let ignoredElements: Set<String> = [
        "dependencies", "deployment", "plugIn", "capability", "point", "canvasLocation", "designable",
        "resources", "image", "namedColor", "systemColor", "accessibility", "inferredMetricsTieBreakers",
        "simulatedMetricsContainer", "attributedString", "fragment", "paragraphStyle", "inset",
    ]
    static let ignoredAttributes: Set<String> = [
        "id", "key", "userLabel", "sceneMemberID", "customModuleProvider", "misplaced", "ambiguous", "colorLabel",
        "placeholderIntrinsicWidth", "placeholderIntrinsicHeight", "fixedFrame", "verifyAmbiguity", "contentType",
        "allowsCharacterPickerTouchBarItem", "textCompletion", "usesSingleLineMode", "colorSpace", "customColorSpace",
        "catalog", "translatesAutoresizingMaskIntoConstraints", "headerView", "sceneID", "symbolic", "useAutolayout",
        "toolsVersion", "version", "type", "targetRuntime", "propertyAccessControl", "initialViewController",
        "customObjectInstantitationMethod", "focusRingType", "baseWritingDirection", "systemMenu", "usesAppearanceFont",
        "wantsLayer", "symbolScale", "sortKey", "allowsImageEditing", "preservesSelection",
    ]

    public static func check(_ url: URL) -> IBCheckResult {
        var r = IBCheckResult(file: url.path, kind: url.pathExtension)
        if !(Runway.isInstalled) { Runway.install(HeadlessBackend()) }
        AppKitRuntime.install()
        let previous = IBLoader.logging
        IBLoader.logging = false
        collecting = true
        defer { IBLoader.logging = previous; collecting = false }
        let doc: IBDocument
        do { doc = try IBDocument(contentsOf: url) } catch {
            r.error = "\(error)"
            return r
        }
        r.elements = doc.root.descendants().count
        var loaders: [IBLoader] = []
        let probe = NSObject()
        if doc.kind == .xib {
            let l = IBLoader(document: doc, bundle: Bundle(url: url.deletingLastPathComponent()), owner: probe)
            _ = l.instantiateXib()
            loaders.append(l)
            loaders += storyboardLoaders
            storyboardLoaders = []
        } else {
            let sb = NSStoryboard(document: doc, bundle: Bundle(url: url.deletingLastPathComponent()) ?? .main)
            sb.instantiateApplicationScene()
            r.scenes = doc.scenes.count
            for scene in doc.scenes {
                guard let objects = scene.child("objects") else { continue }
                for o in objects.children where ["viewController", "windowController", "splitViewController", "tabViewController",
                                                 "pagecontroller", "collectionViewItem"].contains(o.name) {
                    guard let c = sb.instantiate(o) else { continue }
                    if let vc = c as? NSViewController { _ = vc.view }
                    if let wc = c as? NSWindowController { _ = wc.window }
                    if let s = IBStoryboardState.state(of: c)?.sceneLoader { loaders.append(s) }
                }
            }
            loaders += IBCheck.storyboardLoaders
            IBCheck.storyboardLoaders = []
        }
        // View-based tables' prototype cells: one of each.
        var tables: [NSTableView] = []
        for l in loaders { for o in l.objects.values { if let t = o as? NSTableView, !tables.contains(where: { $0 === t }) { tables.append(t) } } }
        for t in tables { for id in (IBTableCellNibs.registered(t) ?? [:]).keys { _ = IBTableCellNibs.make(t, id, owner: nil) } }
        loaders += storyboardLoaders
        storyboardLoaders = []
        var seen = Set<ObjectIdentifier>()
        for l in loaders {
            for o in l.objects.values where seen.insert(ObjectIdentifier(o)).inserted && !(o is NSNull) && o !== probe
                && !(o is IBFirstResponder) && !(o is NSApplication) {
                r.objects += 1
                if o is NSView { r.views += 1 }
                r.classes[String(describing: type(of: o)), default: 0] += 1
            }
            r.constraints += l.constraintCount
            r.connections += l.connectionCount
            for m in l.missingClasses where !r.customClasses.contains(m) { r.customClasses.append(m) }
        }
        // What wasn't read.
        func walk(_ e: IBElement, parentRead: Bool) {
            for c in e.children {
                let read = c.consumed || c.attributes["id"].flatMap { id in loaders.contains { $0.objects[id] != nil } } == true
                if !read {
                    if parentRead, !ignoredElements.contains(c.name), c.attributes["key"].map({ !ignoredElements.contains($0) }) ?? true {
                        let k = e.name + " > " + c.name + (c.attributes["key"].map { "[key=\($0)]" } ?? "")
                        r.unsupportedElements[k, default: 0] += 1
                    }
                    continue
                }
                for a in c.attributes.keys where !c.used.contains(a) && !ignoredAttributes.contains(a) {
                    r.unsupportedAttributes[c.name + "." + a, default: 0] += 1
                }
                walk(c, parentRead: true)
            }
        }
        if doc.kind == .xib {
            if let objs = doc.objects { objs.consumed = true; walk(objs, parentRead: true) }
        } else {
            for s in doc.scenes { if let objs = s.child("objects") { walk(objs, parentRead: true) } }
        }
        return r
    }

    /// Shows a document without its app: its windows (xib), its initial
    /// controller (storyboard), else its first view or controller in a window.
    public static func show(_ url: URL) {
        IBLoader.logging = false
        guard let doc = try? IBDocument(contentsOf: url) else { return }
        var windows: [NSWindow] = []
        func wrap(_ v: NSView, _ title: String) {
            let w = NSWindow(contentRect: CGRect(origin: .zero, size: v.frame.size == .zero ? CGSize(width: 480, height: 320) : v.frame.size),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = title
            w.contentView = v
            windows.append(w)
        }
        let bundle = Bundle(url: url.deletingLastPathComponent())
        if doc.kind == .xib {
            let top = IBLoader(document: doc, bundle: bundle, owner: NSObject()).instantiateXib()
            for case let w as NSWindow in top { windows.append(w) }
            if windows.isEmpty {
                if let v = top.lazy.compactMap({ $0 as? NSView }).first { wrap(v, doc.name) }
                else if let vc = top.lazy.compactMap({ $0 as? NSViewController }).first { wrap(vc.view, doc.name) }
            }
        } else {
            let sb = NSStoryboard(document: doc, bundle: bundle ?? .main)
            sb.instantiateApplicationScene()
            var c = sb.instantiateInitialController() as AnyObject?
            if c == nil {
                for s in doc.scenes {
                    if let e = s.child("objects")?.children.first(where: { $0.name.hasSuffix("Controller") || $0.name == "viewController" }) {
                        c = sb.instantiate(e)
                        if c != nil { break }
                    }
                }
            }
            if let wc = c as? NSWindowController, let w = wc.window { IBRetained.keep(wc); windows.append(w) }
            else if let vc = c as? NSViewController { IBRetained.keep(vc); let w = NSWindow(contentViewController: vc); w.title = vc.title ?? doc.name; windows.append(w) }
        }
        for w in windows { IBRetained.keep(w); w.makeKeyAndOrderFront(nil) }
    }

    /// Loaders of views/windows loaded during a check (storyboards).
    static var storyboardLoaders: [IBLoader] = []
    static var collecting = false
}
