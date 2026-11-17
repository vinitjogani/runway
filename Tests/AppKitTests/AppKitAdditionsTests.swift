// AppKit and Foundation API added for unchanged Mac apps: MainActor
// initializers, grid views, tool tip rectangles, accessibility, font
// descriptors, toolbar validation, Apple events, the field editor, text
// finding, pasteboard items, HTML import, bitmap caching, and Foundation's
// UndoManager, NSItemProvider and file system dispatch sources.

import XCTest
import RunwayCore
import RunwayObjC
@testable import AppKit
import CoreText

/// A subclass overriding MainActor initializers, as apps built with
/// `defaultIsolation(MainActor.self)` do.
final class IsolatedSubview: NSView {
    var made = false
    override init(frame: NSRect) { super.init(frame: frame); made = true }
    required init?(coder: NSCoder) { fatalError() }
}
final class IsolatedController: NSViewController {
    override init(nibName: NSNib.Name?, bundle: Bundle?) { super.init(nibName: nibName, bundle: bundle) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = NSView(frame: .zero) }
}
/// A panel with its own initializer and no init(coder:): AppKit's windows
/// aren't decoded, so subclasses needn't provide it.
final class PlainPanel: NSPanel {
    init() { super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.borderless], backing: .buffered, defer: true) }
}

final class TipOwner: NSObject, NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "tip at \(Int(point.x))"
    }
}

final class PressableView: NSView {
    var pressed = false
    override func accessibilityPerformPress() -> Bool { pressed = true; return true }
}

/// Handles `record:` (as the transpiler's dispatch table would) and
/// validates the toolbar item that sends it.
final class ToolbarValidator: NSResponder, NSToolbarItemValidation, SelectorDispatching {
    var allow = false
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { allow }
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .perform(sel, _): return sel.name == "record:"
        case let .responds(sel): return sel.name == "record:"
        default: return false
        }
    }
}

@MainActor
final class AppKitAdditionsTests: XCTestCase {
    override func setUp() async throws {
        Runway.install(HeadlessBackend())
        AppKitRuntime.install()
    }

    func testMainActorInitializerOverrides() {
        let v = IsolatedSubview(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertTrue(v.made)
        XCTAssertEqual(v.frame.width, 10)
        let c = IsolatedController(nibName: nil, bundle: nil)
        XCTAssertNotNil(c.view)
        let p = PlainPanel()
        p.isFloatingPanel = true
        XCTAssertEqual(p.level, .floating)
        XCTAssertNotNil(NSImage().size)
        XCTAssertEqual(NSAttributedString().length, 0)
    }

    func testGridViewLaysOutColumnsAndRows() {
        func box(_ w: CGFloat, _ h: CGFloat) -> NSView { IntrinsicView(NSSize(width: w, height: h)) }
        let a = box(40, 10), b = box(100, 20), c = box(60, 12)
        let grid = NSGridView(views: [[a, b], [c, NSGridCell.emptyContentView]])
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        XCTAssertEqual(grid.numberOfRows, 2)
        XCTAssertEqual(grid.numberOfColumns, 2)
        XCTAssertNil(grid.cell(atColumnIndex: 1, rowIndex: 1).contentView)
        let size = grid.fittingSize
        XCTAssertEqual(size.width, 60 + 8 + 100)
        XCTAssertEqual(size.height, 20 + 5 + 12)
        grid.frame = NSRect(origin: .zero, size: size)
        grid.layout()
        // Column 0 is 60 wide and right-aligned: `a` (40) starts at 20.
        XCTAssertEqual(a.frame.minX, 20)
        XCTAssertEqual(b.frame.minX, 68)
        XCTAssertEqual(c.frame.minY, 25)
    }

    func testToolTipRectanglesAskTheirOwner() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView = v
        let owner = TipOwner()
        let tag = v.addToolTip(NSRect(x: 0, y: 0, width: 100, height: 100), owner: owner, userData: nil)
        v.addToolTip(NSRect(x: 150, y: 0, width: 50, height: 100), owner: "fixed" as NSString, userData: nil)
        XCTAssertEqual(v.toolTip(at: NSPoint(x: 42, y: 10)), .some("tip at 42"))
        XCTAssertEqual(v.toolTip(at: NSPoint(x: 160, y: 10)), .some("fixed"))
        XCTAssertNil(v.toolTip(at: NSPoint(x: 120, y: 10)) as String??)
        v.removeToolTip(tag)
        XCTAssertNil(v.toolTip(at: NSPoint(x: 42, y: 10)) as String??)
    }

    func testAccessibilityAttributesAndActions() {
        let v = PressableView(frame: .zero)
        XCTAssertFalse(v.isAccessibilityElement())
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.button)
        v.setAccessibilityLabel("Open")
        XCTAssertTrue(v.isAccessibilityElement())
        XCTAssertEqual(v.accessibilityRole(), .button)
        XCTAssertEqual(v.accessibilityLabel(), "Open")
        XCTAssertTrue(v.accessibilityPerformPress())
        XCTAssertTrue(v.pressed)
        NSAccessibility.post(element: v, notification: .announcementRequested, userInfo: [.announcement: "Saved"])
        XCTAssertEqual(NSAccessibility.postedNotifications.last?.notification, .announcementRequested)
    }

    func testFontDescriptorDesignsAndBridging() {
        let system = NSFont.systemFont(ofSize: 20, weight: .bold)
        let serif = system.fontDescriptor.withDesign(.serif)
        XCTAssertNotNil(serif)
        let font = NSFont(descriptor: serif!, size: 20)
        XCTAssertEqual(font?.spec.design, .serif)
        XCTAssertEqual(font?.spec.weight, .bold)
        XCTAssertEqual(font?.pointSize, 20)
        let mono = NSFont(descriptor: system.fontDescriptor.withDesign(.monospaced)!, size: 0)
        XCTAssertEqual(mono?.spec.design, .monospaced)
        // Named fonts have no system designs.
        XCTAssertNil(NSFontDescriptor(fontAttributes: [.family: "DejaVu Sans"]).withDesign(.rounded))
        // Toll-free: the same object is a CTFontDescriptor.
        let wanted = NSFontDescriptor(fontAttributes: [.family: "X", .traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.bold.rawValue]])
        let ct: CTFontDescriptor = wanted
        XCTAssertEqual(CTFontDescriptorCopyAttribute(ct, kCTFontFamilyNameAttribute) as? String, "X")
        XCTAssertEqual(NSFont(descriptor: wanted, size: 12)?.spec.weight, .bold)
        let italic = system.fontDescriptor.withSymbolicTraits(.italic)
        XCTAssertEqual(NSFont(descriptor: italic, size: 12)?.spec.italic, true)
        XCTAssertEqual(NSFontManager.shared.convert(system, toHaveTrait: .italicFontMask).spec.italic, true)
    }

    func testToolbarItemsValidateThroughTheirTarget() {
        let item = NSToolbarItem(itemIdentifier: "record")
        let v = ToolbarValidator()
        item.target = v
        item.action = Selector("record:")
        item.validate()
        XCTAssertFalse(item.isEnabled)
        v.allow = true
        item.validate()
        XCTAssertTrue(item.isEnabled)
    }

    func testSplitViewControllerValidatesToggles() {
        let svc = NSSplitViewController()
        let item = NSMenuItem(title: "Toggle Sidebar", action: Selector("toggleSidebar:"), keyEquivalent: "")
        XCTAssertFalse(AppKitRuntime.validateBuiltIn(item, svc))
        svc.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: IsolatedController(nibName: nil, bundle: nil)))
        XCTAssertTrue(AppKitRuntime.validateBuiltIn(item, svc))
        XCTAssertEqual(item.title, "Hide Sidebar")
    }

    func testLaunchEventIsCurrentWhileFinishingLaunching() {
        let e = NSApplication.launchEvent()
        XCTAssertEqual(e.eventClass, AEEventClass(kCoreEventClass))
        XCTAssertEqual(e.eventID, kAEOpenApplication)
        var seen: NSAppleEventDescriptor?
        NSAppleEventManager.shared()._dispatch(e) { seen = NSAppleEventManager.shared().currentAppleEvent }
        XCTAssertTrue(seen === e)
        XCTAssertNil(NSAppleEventManager.shared().currentAppleEvent)
        e.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
        XCTAssertEqual(e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue, keyAELaunchedAsLogInItem)
    }

    func testTextViewSelectionPropertyAndMethod() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.string = "hello world"
        tv.setSelectedRange(NSRange(location: 6, length: 5))
        XCTAssertEqual(tv.selectedRange, NSRange(location: 6, length: 5))
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 6, length: 5))
        XCTAssertFalse(tv.hasMarkedText())
    }

    func testTextFinderFindsNextAndPrevious() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.string = "one two one two"
        NSTextFinder.searchString = "two"
        let next = NSMenuItem()
        next.tag = NSTextFinder.Action.nextMatch.rawValue
        tv.performTextFinderAction(next)
        XCTAssertEqual(tv.selectedRange, NSRange(location: 4, length: 3))
        tv.performTextFinderAction(next)
        XCTAssertEqual(tv.selectedRange, NSRange(location: 12, length: 3))
        tv.performTextFinderAction(next)
        XCTAssertEqual(tv.selectedRange, NSRange(location: 4, length: 3), "wraps around")
        // The find pasteboard isn't the clipboard.
        XCTAssertEqual(NSPasteboard(name: .find).string(forType: .string), "two")
    }

    func testPasteboardItems() {
        let item = NSPasteboardItem()
        let t = NSPasteboard.PasteboardType("com.example.id")
        item.setString("abc", forType: t)
        XCTAssertEqual(item.types, [t])
        XCTAssertEqual(item.string(forType: t), "abc")
        XCTAssertEqual(item.data(forType: t), Data("abc".utf8))
    }

    func testAttributedStringFromHTML() {
        let html = "<html><head><style>p{}</style></head><body><h1>Title</h1><p>Some <b>bold</b> &amp; <a href=\"https://x.org\">link</a></p><ul><li>one</li></ul></body></html>"
        let s = NSAttributedString(html: Data(html.utf8), options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil)
        XCTAssertEqual(s?.string, "Title\nSome bold & link\n• one")
        let ns = s!.string as NSString
        let value = s!.attribute(.link, at: ns.range(of: "link").location, effectiveRange: nil)
        let link = (value as? URL) ?? (value as? NSURL).map { $0 as URL }
        XCTAssertEqual(link?.absoluteString, "https://x.org")
        // Character styles are fonts, beside the plain runs.
        let bold = s!.attribute(.font, at: ns.range(of: "bold").location, effectiveRange: nil) as? NSFont
        let plain = s!.attribute(.font, at: ns.range(of: "Some").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(bold?.spec.weight, .bold)
        XCTAssertEqual(plain?.spec.weight, .regular)
        XCTAssertEqual((s!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24, "h1")
        let code = NSAttributedString(html: Data("<p>a <code>x()</code> <i>b</i></p>".utf8), documentAttributes: nil)!
        XCTAssertEqual((code.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.spec.design, .monospaced)
        XCTAssertEqual((code.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.spec.italic, true)
    }

    /// corelibs' CFAttributedString compares a run's attributes with its
    /// neighbour's (CFEqual) when runs are inserted; for Swift objects with
    /// no CF type that halted. Fonts, colours and paragraph styles side by
    /// side now work, and equal ones coalesce.
    func testAdjacentRunsHoldingDifferentObjects() {
        let m = NSMutableAttributedString(string: "")
        m.append(NSAttributedString(string: "plain ", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.red]))
        m.append(NSAttributedString(string: "bold ", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.blue]))
        let p = NSMutableParagraphStyle()
        p.headIndent = 10
        m.append(NSAttributedString(string: "styled", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .paragraphStyle: p]))
        var fonts: [(NSRange, CGFloat)] = []
        m.enumerateAttribute(.font, in: NSRange(location: 0, length: m.length), options: []) { v, r, _ in
            fonts.append((r, (v as? NSFont)?.spec.weight == .bold ? 1 : 0))
        }
        XCTAssertEqual(fonts.map(\.0), [NSRange(location: 0, length: 6), NSRange(location: 6, length: 11)], "equal fonts are one run")
        XCTAssertEqual(fonts.map(\.1), [0, 1])
        XCTAssertEqual(NSFont.boldSystemFont(ofSize: 13), NSFont.boldSystemFont(ofSize: 13))
        XCTAssertNotEqual(NSColor.red, NSColor.blue)
        let q = NSMutableParagraphStyle()
        q.headIndent = 10
        XCTAssertEqual(p, q)
        XCTAssertEqual(p.hash, q.hash)
    }

    func testCacheDisplayDrawsSubviews() {
        final class Filled: NSView {
            let color: NSColor
            init(_ c: NSColor, _ f: NSRect) { color = c; super.init(frame: f) }
            required init?(coder: NSCoder) { fatalError() }
            override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
        }
        let root = Filled(.white, NSRect(x: 0, y: 0, width: 20, height: 20))
        root.addSubview(Filled(.red, NSRect(x: 0, y: 0, width: 10, height: 10)))
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return XCTFail("no rep") }
        root.cacheDisplay(in: root.bounds, to: rep)
        XCTAssertEqual(rep.pixelsWide, 20)
        let px = rep.bitmapData!
        func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let o = y * rep.bytesPerRow + x * 4
            return (px[o], px[o + 1], px[o + 2])
        }
        // The red subview sits at the bottom left (unflipped): pixel rows run top down.
        XCTAssertEqual(pixel(2, 17).0, 255)
        XCTAssertLessThan(pixel(2, 17).1, 40)
        XCTAssertEqual(pixel(15, 2).1, 255, "white elsewhere")
        XCTAssertNotNil(rep.representation(using: .png, properties: [:]))
    }

    func testUndoManagerSelectorRegistration() {
        let u = UndoManager()
        u.groupsByEvent = false
        let target = ActionTarget()
        u.beginUndoGrouping()
        u.registerUndo(withTarget: target, selector: Selector("doThing:"), object: nil)
        u.endUndoGrouping()
        u.undo()
        XCTAssertEqual(target.performed, ["doThing:"])
    }
}
