// Interface Builder documents in Runway's AppKit, on the headless backend:
// the XML reader, a xib (window, controls and their cell properties,
// constraints, File's Owner outlets and outlet collections, actions,
// runtime attributes, bindings, menus), a storyboard (initial controller,
// lazy view and window loading, relationship / embed / modal segues,
// split and tab view controllers, view-based table prototypes,
// awakeFromNib order), the class registry and its generator, and the
// transpiler's awakeFromNib handling.
//
// The test classes carry dispatch tables written as the transpiler
// generates them for `@IBOutlet` / `@IBAction` members.

import XCTest
import RunwayCore
import RunwayObjC
import RunwayTranspiler
@testable import AppKit

// MARK: Test classes

final class PrefsOwner: NSObject, SelectorDispatching {
    var window: NSWindow?
    var nameField: NSTextField?
    var saveButton: NSButton?
    var helper: PrefsHelper?
    var widthConstraint: NSLayoutConstraint?
    var checkboxes: [NSButton] = []
    var fired: [String] = []
    var awoke = 0

    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .setValue(k, v):
            switch k {
            case "window": window = RunwayObjC.arg([v], 0)
            case "nameField": nameField = RunwayObjC.arg([v], 0)
            case "saveButton": saveButton = RunwayObjC.arg([v], 0)
            case "helper": helper = RunwayObjC.arg([v], 0)
            case "widthConstraint": widthConstraint = RunwayObjC.arg([v], 0)
            case "checkboxes": checkboxes = RunwayObjC.arg([v], 0)
            default: return false
            }
            return true
        case let .perform(s, _):
            switch s.name {
            case "save:", "copyName:": fired.append(s.name)
            case "awakeFromNib": awoke += 1
            default: return false
            }
            return true
        case let .responds(s): return ["save:", "copyName:", "awakeFromNib"].contains(s.name)
        case .value: return false
        }
    }
}

final class PrefsHelper: NSObject, SelectorDispatching {
    weak var owner: PrefsOwner?
    var helped = 0
    static var awakeOrder: [String] = []
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .setValue("owner", v): owner = RunwayObjC.arg([v], 0); return true
        case .perform("help:", _): helped += 1; return true
        case .perform("awakeFromNib", _): Self.awakeOrder.append("helper(owner set: \(owner != nil))"); return true
        case .responds(let s): return s.name == "help:" || s.name == "awakeFromNib"
        default: return false
        }
    }
}

final class PrefsSwatch: NSView, @preconcurrency SelectorDispatching {
    var label = ""
    var radius: CGFloat = 0
    var initRan = false
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        // IB's properties are set by the time super.init(coder:) returns.
        initRan = frame.width == 60
    }
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .setValue("label", v): label = RunwayObjC.arg([v], 0); return true
        case let .setValue("radius", v): radius = RunwayObjC.arg([v], 0); return true
        default: return false
        }
    }
}

final class FlowWindowController: NSWindowController, NSWindowDelegate {
    var loaded = false
    override func windowDidLoad() { loaded = true }
}

final class FlowViewController: NSViewController, @preconcurrency SelectorDispatching, NSTableViewDataSource, NSTableViewDelegate {
    var label: NSTextField?
    var table: NSTableView?
    var helper: FlowHelper?
    var events: [String] = []
    var prepared: [String] = []

    override func awakeFromNib() { events.append("awakeFromNib(viewLoaded: \(isViewLoaded))") }
    override func viewDidLoad() { events.append("viewDidLoad(label: \(label?.stringValue ?? "nil"))") }
    override func prepare(for segue: NSStoryboardSegue, sender: Any?) {
        prepared.append("\(segue.identifier ?? "-"):\(type(of: segue.destinationController))")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 3 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let v = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("NameCell"), owner: self) as? NSTableCellView
        v?.textField?.stringValue = "Row \(row)"
        return v
    }

    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .setValue(k, v):
            switch k {
            case "label": label = RunwayObjC.arg([v], 0)
            case "table": table = RunwayObjC.arg([v], 0)
            case "helper": helper = RunwayObjC.arg([v], 0)
            default: return false
            }
            return true
        default: return false
        }
    }
}

final class FlowHelper: NSObject, SelectorDispatching {
    weak var controller: FlowViewController?
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        if case let .setValue("controller", v) = m.kind { controller = RunwayObjC.arg([v], 0); return true }
        return false
    }
}

final class FlowCellView: NSTableCellView, @preconcurrency SelectorDispatching {
    weak var controller: FlowViewController?
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        if case let .setValue("controller", v) = m.kind { controller = RunwayObjC.arg([v], 0); return true }
        return false
    }
}

final class MenuAppDelegate: NSObject, NSApplicationDelegate, SelectorDispatching {
    var window: NSWindow?
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        if case let .setValue("window", v) = m.kind { window = RunwayObjC.arg([v], 0); return true }
        return false
    }
}

final class NibViewController: NSViewController, @preconcurrency SelectorDispatching {
    var button: NSButton?
    var added = 0
    var didLoad = false
    override func viewDidLoad() { didLoad = button != nil }
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .setValue("button", v): button = RunwayObjC.arg([v], 0); return true
        case .perform("add:", _): added += 1; return true
        case .responds("add:"): return true
        default: return false
        }
    }
}

// MARK: Tests

@MainActor
final class InterfaceBuilderTests: XCTestCase {
    override func setUp() async throws {
        Runway.install(HeadlessBackend())
        AppKitRuntime.install()
        IBLoader.logging = false
        ClassRegistry.addModule("InterfaceBuilderTests")
        // What the generated class table provides (`init()` isn't callable
        // through an NSObject metatype).
        ClassRegistry.registerFactory(PrefsHelper.self) { PrefsHelper() }
        ClassRegistry.registerFactory(FlowHelper.self) { FlowHelper() }
        ClassRegistry.registerFactory(MenuAppDelegate.self) { MenuAppDelegate() }
    }

    func fixture(_ name: String) throws -> URL {
        let u = try XCTUnwrap(Bundle.module.resourceURL).appendingPathComponent("Fixtures/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: u.path), u.path)
        return u
    }

    // MARK: XML

    func testXMLReader() throws {
        let root = try IBXMLParser.parse("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- comment -->
        <document a="x &amp; y &lt;z&gt; &#x41;&#66;"><child key="k">text &quot;q&quot;<![CDATA[<raw>]]></child><empty/></document>
        """)
        XCTAssertEqual(root.name, "document")
        XCTAssertEqual(root["a"], "x & y <z> AB")
        XCTAssertEqual(root.child(key: "k")?.text, "text \"q\"<raw>")
        XCTAssertEqual(root.children.count, 2)
        XCTAssertTrue(root.children[1].parent === root)
        XCTAssertThrowsError(try IBXMLParser.parse("<a><b></a>"))
        let s = try IBXMLParser.parse(#"<string key="keyEquivalent" base64-UTF8="YES">DQ</string>"#)
        XCTAssertEqual(IBValue.string(s), "\r")
    }

    func testStringsFile() {
        let pairs = IBDocument.parseStrings("""
        /* Class = "NSMenuItem"; title = "Quit"; ObjectID = "4sb"; */
        "4sb.title" = "Beenden";
        // line comment
        "x.y" = "a \\"b\\"\\n";
        """)
        XCTAssertEqual(pairs.map(\.0), ["4sb.title", "x.y"])
        XCTAssertEqual(pairs[1].1, "a \"b\"\n")
    }

    // MARK: A xib

    func testXibObjectsPropertiesAndConnections() throws {
        let doc = try IBDocument(contentsOf: fixture("Prefs.xib"))
        let owner = PrefsOwner()
        PrefsHelper.awakeOrder = []
        let loader = IBLoader(document: doc, bundle: nil, owner: owner)
        let top = loader.instantiateXib()

        // Top-level objects: the helper, the defaults controller, the window, the menu.
        XCTAssertEqual(top.count, 4)
        XCTAssertTrue(top.contains { $0 is PrefsHelper })
        XCTAssertTrue(top.contains { $0 is NSUserDefaultsController })
        let menu = try XCTUnwrap(top.compactMap { $0 as? NSMenu }.first)

        // Outlets on the File's Owner (generated KVC tables).
        let w = try XCTUnwrap(owner.window)
        XCTAssertEqual(w.title, "Preferences & Settings")
        XCTAssertEqual(w.styleMask, [.titled, .closable])
        XCTAssertEqual(w.contentView?.frame.size, CGSize(width: 400, height: 220))
        XCTAssertEqual(w.minSize, CGSize(width: 300, height: 200))
        XCTAssertFalse(w.isReleasedWhenClosed)
        XCTAssertFalse(w.isVisible, "visibleAtLaunch=NO")
        XCTAssertTrue(w.initialFirstResponder === owner.nameField)
        XCTAssertTrue(owner.helper === top.first { $0 is PrefsHelper })
        XCTAssertTrue(owner.helper?.owner === owner, "a top-level object's outlet to the File's Owner")
        XCTAssertEqual(owner.checkboxes.map(\.title), ["First", "Second"], "outlet collection, in document order")
        XCTAssertEqual(owner.widthConstraint?.identifier, "nameWidth")
        XCTAssertEqual(owner.widthConstraint?.constant, 200)

        // Text fields: an editable bezeled field, a label.
        let field = try XCTUnwrap(owner.nameField)
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(field.isBezeled)
        XCTAssertEqual(field.placeholderString, "Your name")
        XCTAssertFalse(field.translatesAutoresizingMaskIntoConstraints)
        let label = try XCTUnwrap(w.contentView?.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "<Label>" })
        XCTAssertFalse(label.isEditable)
        XCTAssertFalse(label.isBezeled)
        XCTAssertEqual(label.alignment, .right)
        XCTAssertEqual(label.font?.pointSize, 11)
        XCTAssertEqual(label.textColor?.rgba(dark: false), RGBA(0.5, 0.25, 1, 1))

        // Buttons: a checkbox (state on), a radio, a push button with Return.
        let views = w.contentView!.subviews
        let first = owner.checkboxes[0], second = owner.checkboxes[1]
        XCTAssertEqual(first.buttonType, .switch)
        XCTAssertEqual(second.buttonType, .radio)
        XCTAssertEqual(second.action, Selector("toggled:"))
        XCTAssertNil(second.target, "First Responder: nil-targeted")
        let save = try XCTUnwrap(owner.saveButton)
        XCTAssertEqual(save.title, "Save")
        XCTAssertEqual(save.bezelStyle, .rounded)
        XCTAssertEqual(save.keyEquivalent, "\r")
        XCTAssertTrue(save.target === owner)
        save.performClick(nil)
        XCTAssertEqual(owner.fired, ["save:"])
        let help = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.bezelStyle == .helpButton })
        XCTAssertEqual(help.toolTip, "Help!")
        help.performClick(nil)
        XCTAssertEqual(owner.helper?.helped, 1, "action to a top-level custom object")

        // Pop-up, segmented control, slider.
        let pop = try XCTUnwrap(views.compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(pop.itemTitles, ["One", "Two", "", "Three"])
        XCTAssertTrue(pop.itemArray[2].isSeparatorItem)
        XCTAssertEqual(pop.titleOfSelectedItem, "Two")
        XCTAssertEqual(pop.selectedTag(), 2)
        let seg = try XCTUnwrap(views.compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(seg.segmentCount, 3)
        XCTAssertEqual(seg.label(forSegment: 1), "B")
        XCTAssertEqual(seg.selectedSegment, 1)
        XCTAssertNotNil(seg.image(forSegment: 2), "SF Symbol image")
        XCTAssertEqual(seg.tag(forSegment: 2), 2)
        let slider = try XCTUnwrap(views.compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(slider.minValue, 10)
        XCTAssertEqual(slider.maxValue, 20)
        XCTAssertEqual(slider.doubleValue, 15)
        XCTAssertEqual(slider.numberOfTickMarks, 3)
        XCTAssertEqual(slider.tickMarkPosition, .above)

        // A custom view: its own init(coder:) ran with IB's frame, runtime attributes set.
        let swatch = try XCTUnwrap(views.compactMap { $0 as? PrefsSwatch }.first)
        XCTAssertTrue(swatch.initRan)
        XCTAssertEqual(swatch.label, "swatch")
        XCTAssertEqual(swatch.radius, 6.5)
        XCTAssertEqual(swatch.layer?.masksToBounds, true)

        // Constraints: installed on the content view, margins and ratios.
        XCTAssertEqual(loader.constraintCount, 11)
        let ratio = try XCTUnwrap(w.contentView?.constraints.first { $0.firstItem === swatch && $0.secondItem === swatch })
        XCTAssertEqual(ratio.multiplier, 1.2, accuracy: 0.0001)
        let low = try XCTUnwrap(w.contentView?.constraints.first { $0.firstItem === swatch && $0.firstAttribute == .width && $0.secondItem == nil })
        XCTAssertEqual(low.priority.rawValue, 750)
        w.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(field.frame.width, 200)
        XCTAssertEqual(field.frame.minX, 20)

        // Menus: key equivalents and modifiers, hidden/disabled items, an action to the owner.
        XCTAssertEqual(menu.title, "Context")
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items[0].keyEquivalent, "c")
        XCTAssertEqual(menu.items[0].keyEquivalentModifierMask, [.command, .option])
        XCTAssertTrue(menu.items[1].isHidden)
        XCTAssertFalse(menu.items[1].isEnabled)
        NSApp.sendAction(menu.items[0].action!, to: menu.items[0].target, from: menu.items[0])
        XCTAssertEqual(owner.fired, ["save:", "copyName:"])

        // awakeFromNib: every object, then the File's Owner; outlets already set.
        XCTAssertEqual(PrefsHelper.awakeOrder, ["helper(owner set: true)"])
        XCTAssertEqual(owner.awoke, 1)
    }

    func testBindingToUserDefaults() throws {
        UserDefaults.standard.set(false, forKey: "IBTestsFirst")
        let doc = try IBDocument(contentsOf: fixture("Prefs.xib"))
        let owner = PrefsOwner()
        _ = IBLoader(document: doc, bundle: nil, owner: owner).instantiateXib()
        let first = owner.checkboxes[0]
        XCTAssertEqual(first.state, .off, "the bound default wins over IB's state")
        first.performClick(nil)
        XCTAssertEqual(first.state, .on)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "IBTestsFirst"), true, "edits flow back")
        UserDefaults.standard.removeObject(forKey: "IBTestsFirst")
    }

    func testNSNibAPI() throws {
        let data = try Data(contentsOf: fixture("Prefs.xib"))
        let nib = NSNib(nibData: data, bundle: nil)
        let owner = PrefsOwner()
        var top: NSArray?
        XCTAssertTrue(nib.instantiate(withOwner: owner, topLevelObjects: &top))
        XCTAssertEqual(top?.count, 4)
        XCTAssertNotNil(owner.window)
        // Twice: a fresh set of objects.
        let owner2 = PrefsOwner()
        _ = nib.instantiate(owner: owner2)
        XCTAssertNotNil(owner2.window)
        XCTAssertFalse(owner.window === owner2.window)
        XCTAssertNil(NSNib(nibNamed: "NoSuchNib", bundle: .main))
    }

    func testMainNibAtLaunch() throws {
        // What NSApplicationMain does with Info.plist's NSMainNibFile.
        let doc = try IBDocument(contentsOf: fixture("MainMenu.xib"))
        let loader = IBLoader(document: doc, bundle: nil, owner: NSApplication.shared)
        loader.isMainInterface = true
        _ = loader.instantiateXib()
        XCTAssertEqual(NSApp.mainMenu?.items.map(\.title), ["App", "Window"])
        XCTAssertEqual(NSApp.windowsMenu?.title, "Window")
        let quit = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu?.items.first)
        XCTAssertEqual(quit.action, Selector("terminate:"))
        XCTAssertNil(quit.target)
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        let delegate = try XCTUnwrap(NSApp.delegate as? MenuAppDelegate, "the File's Owner (NSApp) delegate outlet")
        XCTAssertEqual(delegate.window?.title, "Main")
        XCTAssertEqual(loader.windowsToShow.map(\.title), ["Main"], "Visible At Launch")
        NSApp.mainMenu = nil
    }

    func testViewControllerLoadsNibNamedLikeItsClass() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ib-nib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixture("NibViewController.xib"), to: dir.appendingPathComponent("NibViewController.xib"))
        let bundle = try XCTUnwrap(Bundle(path: dir.path))
        let vc = NibViewController(nibName: nil, bundle: bundle)
        XCTAssertEqual(vc.view.frame.size, CGSize(width: 240, height: 120))
        XCTAssertTrue(vc.didLoad, "outlets are set before viewDidLoad")
        let b = try XCTUnwrap(vc.button)
        XCTAssertEqual(b.imagePosition, .imageOnly)
        XCTAssertNotNil(b.image, "NSAddTemplate")
        XCTAssertFalse(b.isBordered)
        XCTAssertEqual(b.autoresizingMask, [.maxXMargin, .minYMargin])
        b.performClick(nil)
        XCTAssertEqual(vc.added, 1)
        // Bundle.loadNibNamed with an explicit owner.
        let other = NibViewController(nibName: "Missing", bundle: bundle)
        XCTAssertTrue(bundle.loadNibNamed("NibViewController", owner: other, topLevelObjects: nil))
        XCTAssertNotNil(other.button)
    }

    // MARK: A storyboard

    func storyboard() throws -> NSStoryboard {
        NSStoryboard(document: try IBDocument(contentsOf: fixture("Flow.storyboard")), bundle: .main)
    }

    func testInitialControllerLoadsLazily() throws {
        let sb = try storyboard()
        let wc = try XCTUnwrap(sb.instantiateInitialController() as? FlowWindowController)
        XCTAssertFalse(wc.isWindowLoaded, "the window loads on first use")
        XCTAssertTrue(wc.storyboard === sb)
        let w = try XCTUnwrap(wc.window)
        XCTAssertTrue(wc.loaded)
        XCTAssertEqual(w.title, "Flow")
        XCTAssertTrue(w.delegate === wc)
        let vc = try XCTUnwrap(w.contentViewController as? FlowViewController)
        // The scene's controller awakes when instantiated, again as its view loads (Cocoa does too).
        XCTAssertEqual(vc.events, ["awakeFromNib(viewLoaded: false)", "awakeFromNib(viewLoaded: true)", "viewDidLoad(label: Hello)"])
        XCTAssertTrue(vc.helper?.controller === vc, "a scene object, connected to its controller")
        XCTAssertTrue(vc.table?.dataSource === vc)
        XCTAssertTrue(vc.table?.delegate === vc)
        XCTAssertEqual(vc.table?.tableColumns.map(\.identifier.rawValue), ["NameColumn"])
        XCTAssertEqual(vc.table?.tableColumns.first?.title, "Name")

        // View-based table: cells from the prototype, each a fresh copy wired to the owner.
        let table = try XCTUnwrap(vc.table)
        let c1 = try XCTUnwrap(table.makeView(withIdentifier: NSUserInterfaceItemIdentifier("NameCell"), owner: vc) as? FlowCellView)
        let c2 = try XCTUnwrap(table.makeView(withIdentifier: NSUserInterfaceItemIdentifier("NameCell"), owner: vc) as? FlowCellView)
        XCTAssertFalse(c1 === c2)
        XCTAssertNotNil(c1.textField)
        XCTAssertTrue(c1.textField !== c2.textField)
        XCTAssertTrue(c1.controller === vc)
        XCTAssertEqual(c1.identifier?.rawValue, "NameCell")

        // Embed segue: the container hosts the child controller's view.
        XCTAssertEqual(vc.children.map { $0.title ?? "" }, ["Embedded"])
        XCTAssertTrue(vc.children.first?.view.superview?.superview === vc.view)
    }

    func testSegues() throws {
        let sb = try storyboard()
        let wc = try XCTUnwrap(sb.instantiateInitialController() as? NSWindowController)
        let vc = try XCTUnwrap(wc.window?.contentViewController as? FlowViewController)
        // A control-triggered segue: its target performs it.
        let next = try XCTUnwrap(vc.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Next" })
        XCTAssertEqual(next.action, Selector("perform:"))
        // The embed segue already went through prepare(for:sender:) as the view loaded.
        XCTAssertEqual(vc.prepared, ["-:NSViewController"])
        next.performClick(nil)
        XCTAssertEqual(vc.prepared, ["-:NSViewController", "next:FlowViewController"])
        XCTAssertEqual(vc.presentedViewControllers?.first?.title, "Second")
        // performSegue(withIdentifier:) for the controller's own segue.
        vc.performSegue(withIdentifier: "sheet", sender: nil)
        XCTAssertEqual(vc.prepared, ["-:NSViewController", "next:FlowViewController", "sheet:FlowViewController"])
    }

    func testSplitAndTabControllers() throws {
        let sb = try storyboard()
        let split = try XCTUnwrap(sb.instantiateController(withIdentifier: "Split") as? NSSplitViewController)
        XCTAssertEqual(split.splitViewItems.count, 2)
        XCTAssertEqual(split.splitViewItems[0].behavior, .sidebar)
        XCTAssertTrue(split.splitViewItems[0].canCollapse)
        XCTAssertEqual(split.splitViewItems[0].holdingPriority.rawValue, 260)
        XCTAssertEqual(split.splitViewItems.map { $0.viewController.title ?? "" }, ["Second", "Embedded"])
        XCTAssertTrue(split.splitView.isVertical)
        XCTAssertEqual(split.splitView.dividerStyle, .thin)

        let tabs = try XCTUnwrap(sb.instantiateController(withIdentifier: "Tabs") as? NSTabViewController)
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "Advanced"])
        XCTAssertEqual(tabs.tabViewItems.first?.identifier as? String, "general")
        XCTAssertNotNil(tabs.tabViewItems.first?.image)
        _ = tabs.view
        XCTAssertEqual(tabs.selectedTabViewItemIndex, 1)
    }

    // MARK: Classes by name

    func testClassLookup() {
        XCTAssertTrue(ClassRegistry.lookup("PrefsSwatch", module: "InterfaceBuilderTests") == PrefsSwatch.self)
        XCTAssertTrue(ClassRegistry.lookup("InterfaceBuilderTests.FlowCellView") == FlowCellView.self)
        XCTAssertTrue(ClassRegistry.lookup("NSPanel", module: "AppKit") == NSPanel.self)
        XCTAssertNil(ClassRegistry.lookup("NoSuchClass", module: "InterfaceBuilderTests"))
        ClassRegistry.register(PrefsHelper.self, name: "LegacyHelper")
        XCTAssertTrue(ClassRegistry.lookup("LegacyHelper") == PrefsHelper.self, "an @objc(Name) registration")
        XCTAssertNotNil(ClassRegistry.factory(for: PrefsHelper.self)?())
    }

    func testRegistryGenerator() throws {
        let text = try XCTUnwrap(RunwayTranspiler.classRegistrySource(module: "App", files: [("/x/A.swift", """
        import Cocoa
        @main class AppDelegate: NSObject, NSApplicationDelegate {}
        @objc(LegacyThing) final class Thing: NSObject { init(x: Int) { super.init() } }
        class Base: NSObject { override init() { super.init() } }
        class Derived: Base {}
        class Panel: NSPanel {}
        class Win: NSWindow { init() { super.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: false) } }
        class Generic<T>: NSObject {}
        private class Hidden: NSObject {}
        enum Outer { class Inner: NSView {} }
        struct S { func f() { class Local {} } }
        """)]))
        XCTAssertTrue(text.contains(#"c.append(("App.AppDelegate", AppDelegate.self))"#))
        XCTAssertTrue(text.contains(#"c.append(("LegacyThing", Thing.self))"#), text)
        XCTAssertTrue(text.contains(#"c.append(("App.Outer.Inner", Outer.Inner.self))"#))
        XCTAssertFalse(text.contains("Generic"))
        XCTAssertFalse(text.contains("Hidden"))
        XCTAssertFalse(text.contains("Local"))
        XCTAssertTrue(text.contains("f.append((AppDelegate.self, { AppDelegate() }))"))
        XCTAssertTrue(text.contains("f.append((Derived.self, { Derived() }))"), "inherits init() from a package class")
        XCTAssertFalse(text.contains("{ Thing() }"), "no init() when it declares other designated initializers")
        XCTAssertTrue(text.contains("w.append((Panel.self,"), "a panel inherits NSWindow's initializer")
        XCTAssertFalse(text.contains("w.append((Win.self,"))
        XCTAssertNil(RunwayTranspiler.classRegistrySource(module: "App", files: [("/x/B.swift", "struct S {}")]))
    }

    func testTranspilerDropsNSObjectAwakeFromNibOverride() {
        let src = """
        import Cocoa
        class Controller: NSObject {
            @IBOutlet weak var label: NSTextField!
            override func awakeFromNib() {
                super.awakeFromNib()
                label.stringValue = "x"
            }
        }
        class Panel: NSView {
            override func awakeFromNib() { super.awakeFromNib() }
        }
        """
        let out = RunwayTranspiler.transform(source: src, fileName: "/tmp/AwakeTest.swift", index: PackageIndex(files: [("/tmp/AwakeTest.swift", src)]))
        XCTAssertTrue(out.contains("    func awakeFromNib() {"), out)
        XCTAssertTrue(out.contains("RunwayObjC.nsObjectHook()"), out)
        XCTAssertTrue(out.contains("override func awakeFromNib() { super.awakeFromNib() }"), "NSView's stays an override")
        XCTAssertTrue(out.contains(#"case "awakeFromNib""#), "reachable by selector for nib loading")
        XCTAssertTrue(out.contains(#"case "label""#), "the outlet is KVC-settable")
    }

    // MARK: Corpus-style check

    func testCheckReportsUnreadAttributes() throws {
        let r = IBCheck.check(try fixture("Prefs.xib"))
        XCTAssertNil(r.error)
        XCTAssertGreaterThan(r.objects, 20)
        XCTAssertEqual(r.constraints, 11)
        XCTAssertTrue(r.customClasses.isEmpty || r.customClasses.allSatisfy { !$0.contains("Swatch") })
        let s = IBCheck.check(try fixture("Flow.storyboard"))
        XCTAssertNil(s.error)
        XCTAssertEqual(s.unsupportedElements, [:], "\(s.unsupportedElements)")
    }
}
