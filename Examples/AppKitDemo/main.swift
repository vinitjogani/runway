// An AppKit-first app, as written for the Mac: an NSWindowController that
// builds its window in code, custom-drawn NSViews (gradients, Bézier paths,
// strings, images), Auto Layout with anchors and the visual format
// language, a main menu with key equivalents, validation and a checkmark,
// mouse tracking (hover, drag to draw, scroll), a context menu, cursors.
//
// Selectors dispatch through RunwayObjC: on the Mac these classes would
// use @objc methods and #selector; here (as the transpiler generates) each
// class answers its selectors in `_runwayHandle`.

import AppKit
import RunwayObjC

// MARK: A custom-drawn canvas

final class SketchView: NSView, SelectorDispatching {
    var strokes: [[NSPoint]] = []
    var hover: NSPoint?
    var showsGrid = true { didSet { needsDisplay = true } }
    var accent = NSColor.systemBlue

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A sample stroke so the drawing shows something from the start.
        strokes = [(0..<40).map { i in
            let t = CGFloat(i) / 39
            return NSPoint(x: 60 + t * 420, y: 120 + sin(t * .pi * 2) * 60)
        }]
        hover = NSPoint(x: 380, y: 260)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        // Background: a vertical gradient in the view's appearance.
        let base = NSColor.textBackgroundColor
        NSGradient(starting: base, ending: base.blended(withFraction: 0.18, of: .systemBlue) ?? base)?.draw(in: bounds, angle: 90)

        if showsGrid {
            NSColor.labelColor.withAlphaComponent(0.07).setStroke()
            let grid = NSBezierPath()
            var x: CGFloat = 0
            while x < bounds.width { grid.move(to: NSPoint(x: x, y: 0)); grid.line(to: NSPoint(x: x, y: bounds.height)); x += 20 }
            var y: CGFloat = 0
            while y < bounds.height { grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: bounds.width, y: y)); y += 20 }
            grid.lineWidth = 1
            grid.stroke()
        }

        // A rounded card with a shadow, drawn through Core Graphics directly.
        if let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -3), blur: 6, color: NSColor(white: 0, alpha: 0.25).cgColor)
            cg.setFillColor(NSColor.controlBackgroundColor.blended(withFraction: 0.06, of: .labelColor)!.cgColor)
            cg.addPath(CGPath(roundedRect: CGRect(x: 30, y: bounds.height - 110, width: 260, height: 80), cornerWidth: 12, cornerHeight: 12, transform: nil))
            cg.fillPath()
            cg.restoreGState()
        }
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.labelColor]
        ("Runway AppKit" as NSString).draw(at: NSPoint(x: 46, y: bounds.height - 62), withAttributes: title)
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
        "draw(_:) → CGContext → Cairo".draw(at: NSPoint(x: 46, y: bounds.height - 90), withAttributes: body)

        // Shapes: an oval, a star (even-odd), an arc.
        accent.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width - 170, y: bounds.height - 130, width: 120, height: 90)).fill()
        let star = NSBezierPath()
        let c = NSPoint(x: bounds.width - 110, y: 110)
        for i in 0..<5 {
            let a = CGFloat(i) * 4 * .pi / 5 + .pi / 2
            let p = NSPoint(x: c.x + cos(a) * 60, y: c.y + sin(a) * 60)
            if i == 0 { star.move(to: p) } else { star.line(to: p) }
        }
        star.close()
        star.windingRule = .evenOdd
        NSColor.systemOrange.setFill()
        star.fill()
        NSColor.systemOrange.shadow(withLevel: 0.3)?.setStroke()
        star.lineWidth = 2
        star.lineJoinStyle = .round
        star.stroke()

        // The strokes drawn with the mouse.
        NSColor.systemPink.setStroke()
        for s in strokes where s.count > 1 {
            let p = NSBezierPath()
            p.lineWidth = 3
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: s[0])
            for q in s.dropFirst() { p.line(to: q) }
            p.stroke()
        }

        // Hover crosshair from mouseMoved.
        if let h = hover {
            NSColor.systemGreen.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: h.x - 10, y: h.y - 10, width: 20, height: 20))
            ring.lineWidth = 2
            ring.stroke()
            let label = String(format: "%.0f, %.0f", h.x, h.y)
            label.draw(at: NSPoint(x: h.x + 14, y: h.y - 6), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor])
        }

        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func scrollWheel(with event: NSEvent) {
        accent = NSColor(hue: CGFloat.random(in: 0...1), saturation: 0.7, brightness: 0.9, alpha: 1)
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 { _ = strokes.popLast(); needsDisplay = true } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu(title: "Canvas")
        m.addItem(withTitle: "Clear Drawing", action: Selector("clear:"), keyEquivalent: "")
        m.addItem(.separator())
        let grid = m.addItem(withTitle: "Show Grid", action: Selector("toggleGrid:"), keyEquivalent: "")
        grid.state = showsGrid ? .on : .off
        return m
    }

    func clear(_ sender: Any?) { strokes = []; needsDisplay = true }
    func toggleGrid(_ sender: Any?) { showsGrid.toggle() }

    // What the transpiler generates for the @objc methods above.
    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .perform(sel, args):
            switch sel.name {
            case "clear:": clear(args.first ?? nil); return true
            case "toggleGrid:": toggleGrid(args.first ?? nil); return true
            case "validateMenuItem:":
                if let item = args.first as? NSMenuItem {
                    if item.action == Selector("toggleGrid:") { item.state = showsGrid ? .on : .off }
                    m.result = item.action != Selector("clear:") || !strokes.isEmpty
                }
                return true
            default: return false
            }
        case let .responds(sel): return ["clear:", "toggleGrid:", "validateMenuItem:"].contains(sel.name)
        default: return false
        }
    }
}

// MARK: A sidebar of swatches (plain NSViews laid out with Auto Layout)

final class SwatchView: NSView {
    let color: NSColor
    let name: String
    init(_ color: NSColor, _ name: String) {
        self.color = color
        self.name = name
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: 7, width: 20, height: 20), xRadius: 5, yRadius: 5).fill()
        name.draw(at: NSPoint(x: 36, y: 9), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
    }
}

final class SidebarView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        "COLORS".draw(at: NSPoint(x: 16, y: 14), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

// MARK: The window controller

final class MainWindowController: NSWindowController {
    let sketch = SketchView(frame: .zero)

    convenience init() { self.init(window: nil) }

    override func loadWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "AppKit Demo"
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 600, height: 400)
        window = w
    }

    override func windowDidLoad() {
        guard let content = window?.contentView else { return }
        let sidebar = SidebarView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sketch.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        content.addSubview(sketch)

        let swatches = [(NSColor.systemRed, "Red"), (.systemOrange, "Orange"), (.systemGreen, "Green"), (.systemBlue, "Blue"), (.systemPurple, "Purple")]
            .map { SwatchView($0.0, $0.1) }
        var previous: NSLayoutYAxisAnchor = sidebar.topAnchor
        for (i, s) in swatches.enumerated() {
            sidebar.addSubview(s)
            NSLayoutConstraint.activate([
                s.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
                s.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
                s.topAnchor.constraint(equalTo: previous, constant: i == 0 ? 34 : 2),
            ])
            previous = s.bottomAnchor
        }

        let views: [String: Any] = ["sidebar": sidebar, "sketch": sketch]
        NSLayoutConstraint.activate(
            NSLayoutConstraint.constraints(withVisualFormat: "H:|[sidebar(180)]-20-[sketch]-20-|", options: [], metrics: nil, views: views) +
            NSLayoutConstraint.constraints(withVisualFormat: "V:|[sidebar]|", options: [], metrics: nil, views: views) + [
                sketch.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                sketch.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                sketch.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            ])
        window?.initialFirstResponder = sketch
    }
}

// MARK: The app

final class AppDelegate: NSObject, NSApplicationDelegate, SelectorDispatching {
    var controllers: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        newWindow(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func newWindow(_ sender: Any?) {
        let wc = MainWindowController()
        controllers.append(wc)
        wc.showWindow(sender)
    }

    func makeMainMenu() -> NSMenu {
        let main = NSMenu(title: "Main")
        let app = NSMenu(title: "AppKit Demo")
        app.addItem(withTitle: "About AppKit Demo", action: Selector("orderFrontStandardAboutPanel:"), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit AppKit Demo", action: Selector("terminate:"), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = app

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Window", action: Selector("newWindow:"), keyEquivalent: "n")
        file.addItem(withTitle: "Close", action: Selector("performClose:"), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Clear Drawing", action: Selector("clear:"), keyEquivalent: "k")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Show Grid", action: Selector("toggleGrid:"), keyEquivalent: "g")
        let dark = view.addItem(withTitle: "Dark Appearance", action: nil, keyEquivalent: "D")
        dark.handler = { item in
            NSApp.appearance = NSApp.appearance?.isDark == true ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
            item.state = NSApp.appearance?.isDark == true ? .on : .off
        }
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = view

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: Selector("performMiniaturize:"), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: Selector("performZoom:"), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window
        return main
    }

    func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
        switch m.kind {
        case let .perform(sel, args) where sel.name == "newWindow:": newWindow(args.first ?? nil); return true
        case let .responds(sel): return sel.name == "newWindow:"
        default: return false
        }
    }
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    _ = delegate
}
