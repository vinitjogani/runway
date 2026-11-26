// Context and pop-up menus drawn the Mac's way, the same on every platform
// the drawn backend runs on: a rounded panel with a checkmark column, the
// item's SF Symbol, its title, its shortcut aligned trailing, chevrons for
// submenus, an accent highlight that follows the pointer and the arrow
// keys, and submenus opening beside their row. Native menus (GTK hides
// icons beside titles; Win32's take no SF Symbols) can't show all of that.
//
// RUNWAY_NATIVE_MENUS=1 uses the toolkit's menus instead.

#if os(Windows) || os(Linux)
import Foundation
import RunwayCore
import CoreGraphics
import CRunwayDrawn

@MainActor final class DrawnMenu {
    static var native: Bool { ProcessInfo.processInfo.environment["RUNWAY_NATIVE_MENUS"] != nil }

    // Metrics after the Mac's menus.
    private static let font: CGFloat = 13
    private static let rowHeight: CGFloat = 22
    private static let separatorHeight: CGFloat = 11
    private static let inset: CGFloat = 5          // panel to highlight
    private static let padding: CGFloat = 9        // highlight to content
    private static let radius: CGFloat = 7

    let items: [MenuItemSpec]
    let window: DrawnWindow
    private let canvas: DrawnWidget
    private let surface: DrawnWidget
    private weak var parentMenu: DrawnMenu?
    private var child: DrawnMenu?
    private var childRow: Int?
    private var rows: [CGRect] = []
    private var highlighted: Int? { didSet { if highlighted != oldValue { redraw() } } }
    private let done: UnsafeMutablePointer<Int32>
    private var root: DrawnMenu { parentMenu?.root ?? self }
    private var chosen: MenuItemSpec?
    private var closed = false
    private let checkColumn: Bool
    private let iconColumn: Bool
    private let size: CGSize

    /// Shows `items` at `point` in `owner` and returns the chosen item
    /// (once every menu has closed), or nil.
    static func run(_ items: [MenuItemSpec], in owner: DrawnWindow, at point: CGPoint) -> MenuItemSpec? {
        guard !items.isEmpty else { return nil }
        let done = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        done.pointee = 0
        defer { done.deallocate() }
        let menu = DrawnMenu(items, owner: owner, at: point, parent: nil, done: done)
        if DrawnBackend.debugInput { FileHandle.standardError.write("menu open \(items.count) items at \(point)\n".data(using: .utf8)!) }
        rw_run_modal(done)
        if DrawnBackend.debugInput { FileHandle.standardError.write("menu closed chosen=\(menu.chosen?.title ?? "-")\n".data(using: .utf8)!) }
        let choice = menu.chosen
        menu.closeAll()
        return choice
    }

    private init(_ items: [MenuItemSpec], owner: DrawnWindow, at point: CGPoint, parent: DrawnMenu?, done: UnsafeMutablePointer<Int32>) {
        self.items = items
        self.parentMenu = parent
        self.done = done
        checkColumn = items.contains { $0.checked }
        iconColumn = items.contains { $0.symbol != nil }
        // Sizes: the widest title plus shortcut, the rows' heights.
        var widest: CGFloat = 0
        var y = Self.inset
        var frames: [CGRect] = []
        let leading = Self.leadingWidth(check: checkColumn, icon: iconColumn)
        for item in items {
            if item.isSeparator {
                frames.append(CGRect(x: Self.inset, y: y, width: 0, height: Self.separatorHeight))
                y += Self.separatorHeight
                continue
            }
            var w = leading + TextMetrics.size(item.title, size: Self.font).width + Self.padding
            if let s = item.shortcut { w += 28 + TextMetrics.size(s.displayText, size: Self.font).width }
            if !item.children.isEmpty { w += 22 }
            widest = max(widest, w)
            frames.append(CGRect(x: Self.inset, y: y, width: 0, height: Self.rowHeight))
            y += Self.rowHeight
        }
        let width = max(160, ceil(widest + 2 * Self.inset))
        rows = frames.map { CGRect(x: $0.minX, y: $0.minY, width: width - 2 * Self.inset, height: $0.height) }
        size = CGSize(width: width, height: ceil(y + Self.inset))

        let backend = owner.backend
        window = DrawnWindow(WindowOptions(title: "", size: size, resizable: false, modal: false), parent: owner, backend: backend, popup: true)
        backend.windows.append(window)
        surface = backend.makeEventContainer(focusable: true, pointer: { _ in false }, key: { _ in false }) as! DrawnWidget
        canvas = backend.makeWidget(.canvas) as! DrawnWidget
        backend.setChildren(surface, [(canvas, CGRect(origin: .zero, size: size))], contentSize: size)
        backend.setChildren(window.root, [(surface, CGRect(origin: .zero, size: size))], contentSize: size)
        surface.pointerHandler = { [weak self] e in self?.pointer(e) ?? false }
        surface.keyHandler = { [weak self] k in self?.key(k) ?? false }
        window.onKey = { [weak self] k in self?.key(k) ?? false }
        // Not transient: a submenu taking the focus mustn't close its parent.
        // The chain closes when none of its windows is active any more.
        window.popover = PopoverState(transient: false, anchor: owner.root, rect: .zero, edge: .bottom) { [weak self] in self?.windowClosed() }
        window.activationHandler = { [weak self] active in if !active { self?.root.checkActive() } }
        redraw()
        if let n = window.native {
            rw_popup_place(n, Double(point.x), Double(point.y), Double(size.width), Double(size.height))
            rw_window_show(n)
            if DrawnBackend.debugInput, let o = owner.native {
                var x = 0.0, y = 0.0
                rw_window_offset_in(n, o, &x, &y)
                FileHandle.standardError.write("menu placed at \(x),\(y) in owner (asked \(point))\n".data(using: .utf8)!)
            }
            window.setFocusedContainer(surface)
        }
    }

    private static func leadingWidth(check: Bool, icon: Bool) -> CGFloat {
        padding + (check ? 16 : 0) + (icon ? 22 : 0)
    }

    // MARK: Drawing

    private func redraw() {
        let theme = window.backend.theme
        var cmds: [DrawCommand] = []
        let panel = CGRect(origin: .zero, size: size)
        cmds.append(.fill(.roundedRect(panel, radius: Self.radius), .color(theme.popoverBackground)))
        let leading = Self.leadingWidth(check: checkColumn, icon: iconColumn)
        for (i, item) in items.enumerated() {
            let r = rows[i]
            if item.isSeparator {
                let y = r.midY.rounded() + 0.5
                cmds.append(.fill(.rect(CGRect(x: r.minX + Self.padding, y: y - 0.5, width: r.width - 2 * Self.padding, height: 1)),
                                  .color(theme.separator)))
                continue
            }
            let hot = highlighted == i && item.enabled
            if hot { cmds.append(.fill(.roundedRect(r, radius: 4), .color(theme.accent))) }
            let ink: RGBA = !item.enabled ? theme.secondaryLabel.withAlpha(0.45)
                : hot ? RGBA(1, 1, 1, 1) : item.destructive ? theme.destructive : theme.label
            var x = r.minX + Self.padding
            if checkColumn {
                if item.checked {
                    let c = CGPoint(x: x + 5, y: r.midY)
                    let check: [PathElement] = [.move(CGPoint(x: c.x - 4, y: c.y)), .line(CGPoint(x: c.x - 1, y: c.y + 3)), .line(CGPoint(x: c.x + 4, y: c.y - 4))]
                    var style = CGStrokeStyle()
                    style.lineWidth = 1.6
                    style.lineCap = .round
                    style.lineJoin = .round
                    cmds.append(.stroke(.path(check), .color(ink), style: style))
                }
                x += 16
            }
            if iconColumn {
                if let name = item.symbol { cmds += Self.symbol(name, in: CGRect(x: x, y: r.midY - 8, width: 16, height: 16), ink) }
                x += 22
            }
            _ = leading
            let titleRect = CGRect(x: x, y: r.minY, width: r.maxX - x - Self.padding, height: r.height)
            cmds.append(.text(Self.line(item.title, ink, .leading), Self.centred(titleRect, item.title)))
            if let s = item.shortcut {
                let shortcutInk = hot ? RGBA(1, 1, 1, 0.85) : theme.secondaryLabel
                let t = s.displayText
                let w = TextMetrics.size(t, size: Self.font).width
                let sr = CGRect(x: r.maxX - Self.padding - w - (item.children.isEmpty ? 0 : 16), y: r.minY, width: w + 1, height: r.height)
                cmds.append(.text(Self.line(t, shortcutInk, .trailing), Self.centred(sr, t)))
            }
            if !item.children.isEmpty {
                let cx = r.maxX - Self.padding - 3, cy = r.midY
                let chevron: [PathElement] = [.move(CGPoint(x: cx - 3, y: cy - 4.5)), .line(CGPoint(x: cx + 1.5, y: cy)), .line(CGPoint(x: cx - 3, y: cy + 4.5))]
                var style = CGStrokeStyle()
                style.lineWidth = 1.5
                style.lineCap = .round
                style.lineJoin = .round
                cmds.append(.stroke(.path(chevron), .color(ink), style: style))
            }
        }
        var p = WidgetProps()
        p.drawing = cmds
        window.backend.update(canvas, props: p, events: WidgetEvents())
    }

    private static func line(_ s: String, _ c: RGBA, _ a: TextAlignmentValue) -> StyledText {
        StyledText(runs: [TextRun(string: s, font: FontSpec(size: font), color: c)], alignment: a, lineLimit: 1)
    }

    /// A text rect centred vertically on its row.
    private static func centred(_ r: CGRect, _ s: String) -> CGRect {
        let h = TextMetrics.size(s.isEmpty ? " " : s, size: font).height
        return CGRect(x: r.minX, y: (r.midY - h / 2).rounded(), width: r.width, height: h)
    }

    /// An SF Symbol as fills and strokes in `r`, in one colour.
    private static func symbol(_ name: String, in r: CGRect, _ ink: RGBA) -> [DrawCommand] {
        guard let shapes = SymbolPaths.shapes(name) else { return [] }
        let k = r.width / 24
        let t = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: r.minX, ty: r.minY)
        var out: [DrawCommand] = []
        for s in shapes where !s.knockout {
            let els: [PathElement] = s.elements.map {
                switch $0 {
                case let .move(p): .move(p.applying(t))
                case let .line(p): .line(p.applying(t))
                case let .quad(p, c): .quad(p.applying(t), control: c.applying(t))
                case let .curve(p, a, b): .curve(p.applying(t), control1: a.applying(t), control2: b.applying(t))
                case .close: .close
                }
            }
            if s.fill { out.append(.fill(.path(els), .color(ink))) }
            if s.stroke {
                var style = CGStrokeStyle()
                style.lineWidth = max(1, s.strokeWidth * k)
                style.lineCap = .round
                style.lineJoin = .round
                out.append(.stroke(.path(els), .color(ink), style: style))
            }
        }
        return out
    }

    // MARK: Input

    private func row(at p: CGPoint) -> Int? {
        rows.firstIndex { $0.contains(p) }.flatMap { items[$0].isSeparator ? nil : $0 }
    }

    private func pointer(_ e: PointerEvent) -> Bool {
        switch e.kind {
        case .moved, .entered, .dragged:
            let r = row(at: e.location)
            if r != highlighted {
                highlighted = r
                openSubmenu(r)
            }
        case .exited:
            if child == nil { highlighted = nil }
        case .up:
            if let r = row(at: e.location) { activate(r) }
        default:
            break
        }
        return true
    }

    private func key(_ k: KeyPress) -> Bool {
        let enabled = items.indices.filter { !items[$0].isSeparator && items[$0].enabled }
        switch k.key {
        case "down":
            let next = enabled.first { $0 > (highlighted ?? -1) } ?? enabled.first
            highlighted = next
        case "up":
            let prev = enabled.last { $0 < (highlighted ?? items.count) } ?? enabled.last
            highlighted = prev
        case "right":
            if let h = highlighted, !items[h].children.isEmpty {
                openSubmenu(h)
                child?.highlighted = child?.items.indices.first { !(child?.items[$0].isSeparator ?? true) }
                if let c = child, let n = c.window.native { rw_window_activate(n); c.window.setFocusedContainer(c.surface) }
            }
        case "left", "escape":
            if let p = parentMenu {
                p.closeChild()
                if let n = p.window.native { rw_window_activate(n) }
            } else {
                root.finish(nil)
            }
        case "return", "space":
            if let h = highlighted { activate(h) }
        default:
            // Typing a title's first letter moves to it.
            if k.key.count == 1, let i = enabled.first(where: { $0 > (highlighted ?? -1) && items[$0].title.lowercased().hasPrefix(k.key) })
                ?? enabled.first(where: { items[$0].title.lowercased().hasPrefix(k.key) }) {
                highlighted = i
            }
        }
        return true
    }

    private func activate(_ i: Int) {
        let item = items[i]
        guard item.enabled, !item.isSeparator else { return }
        if !item.children.isEmpty { openSubmenu(i); return }
        root.finish(item)
    }

    private func openSubmenu(_ i: Int?) {
        guard i != childRow else { return }
        closeChild()
        guard let i, items[i].enabled, !items[i].children.isEmpty else { return }
        childRow = i
        let r = rows[i]
        child = DrawnMenu(items[i].children, owner: window, at: CGPoint(x: r.maxX + Self.inset - 2, y: r.minY - Self.inset),
                          parent: self, done: done)
        // Keep typing and the highlight with this menu until the pointer moves in.
        if let n = window.native { rw_window_activate(n) }
    }

    private func closeChild() {
        child?.closeAll()
        child = nil
        childRow = nil
    }

    // MARK: Closing

    private func finish(_ item: MenuItemSpec?) {
        chosen = item
        closeAll()
        done.pointee = 1
    }

    /// Whether any menu of the chain still has the focus (else it closes,
    /// as menus do when the user clicks elsewhere).
    private func checkActive() {
        window.backend.after(0.05) { [weak self] in
            guard let self, !self.closed else { return }
            var m: DrawnMenu? = self
            while let cur = m {
                if let n = cur.window.native, rw_window_is_active(n) != 0 { return }
                m = cur.child
            }
            self.finish(nil)
        }
    }

    private func windowClosed() {
        guard !closed else { return }
        closed = true
        if parentMenu == nil, done.pointee == 0 { done.pointee = 1 }
    }

    func closeAll() {
        child?.closeAll()
        child = nil
        guard !closed else { return }
        closed = true
        window.popover = nil
        window.close()
        if parentMenu == nil { done.pointee = 1 }
    }
}
#endif
