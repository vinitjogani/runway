// Keyboard focus, key presses, hover, context menus and pointer styles.
//
// Focus follows SwiftUI's model, kept per host:
//
// - `.focused($state, equals: v)` registers a *focus target* at its path.
//   The text field, text editor or focusable view beneath it becomes the
//   target's widget. When that widget gains keyboard focus the state is set
//   to `v`; when it loses it the state goes back to `nil` (or `false`).
// - Setting the state in code moves the toolkit's keyboard focus to the
//   target's widget after the next render (or away, when it's cleared).
// - `.focusable()` makes a view take keyboard focus itself (a focusable
//   event container), so `.onKeyPress` on it, or around it, sees keys.
// - `.onKeyPress` handlers are registered by path. A key press in the view
//   holding focus is offered to the handlers on its path, innermost first,
//   before the control handles it; `.handled` consumes it.
//
// Hover, context menus and pointer styles wrap their content in an event
// container that reports the pointer without taking clicks from controls
// inside.
//
// All of it rides on the backend's AppKit extras (`AppKitBackend`); a
// backend without them shows the views and ignores the events.

import Foundation
import CoreGraphics
import RunwayCore

// MARK: KeyPress

/// A key press, as `.onKeyPress` reports it.
public struct KeyPress: Sendable {
    public struct Phases: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let down = Phases(rawValue: 1)
        public static let `repeat` = Phases(rawValue: 2)
        public static let up = Phases(rawValue: 4)
        public static let all: Phases = [.down, .repeat, .up]
    }
    public enum Result: Sendable { case handled, ignored }

    public let phase: Phases
    public let key: KeyEquivalent
    public let characters: String
    public let modifiers: EventModifiers

    public init(phase: Phases = .down, key: KeyEquivalent, characters: String, modifiers: EventModifiers) {
        self.phase = phase; self.key = key; self.characters = characters; self.modifiers = modifiers
    }

    /// A backend key (Runway's key names) as SwiftUI's.
    init(_ k: RunwayCore.KeyPress) {
        var mods: EventModifiers = []
        if k.command { mods.insert(.command) }
        if k.shift { mods.insert(.shift) }
        if k.option { mods.insert(.option) }
        if k.control { mods.insert(.control) }
        let key: KeyEquivalent
        var chars: String
        switch k.key {
        case "return": key = .return; chars = "\r"
        case "escape": key = .escape; chars = "\u{1b}"
        case "tab": key = .tab; chars = "\t"
        case "space": key = .space; chars = " "
        case "backspace": key = .delete; chars = "\u{8}"
        case "delete": key = .deleteForward; chars = "\u{7f}"
        case "up": key = .upArrow; chars = "\u{F700}"
        case "down": key = .downArrow; chars = "\u{F701}"
        case "left": key = .leftArrow; chars = "\u{F702}"
        case "right": key = .rightArrow; chars = "\u{F703}"
        case "home": key = .home; chars = "\u{F729}"
        case "end": key = .end; chars = "\u{F72B}"
        case "pageup": key = .pageUp; chars = "\u{F72C}"
        case "pagedown": key = .pageDown; chars = "\u{F72D}"
        default:
            if k.key.count == 1, let c = k.key.first {
                chars = k.shift ? String(c).uppercased() : String(c)
                key = KeyEquivalent(Character(chars.lowercased()))
            } else {
                chars = ""
                key = KeyEquivalent(Character("\u{0}"))
            }
        }
        self.init(phase: .down, key: key, characters: chars, modifiers: mods)
    }
}

/// What earlier Runway releases called these.
public typealias KeyPressResult = KeyPress.Result

// MARK: Host registrations

@MainActor final class KeyHandlerEntry {
    var accepts: (KeyPress) -> Bool
    var action: (KeyPress) -> KeyPress.Result
    init(accepts: @escaping (KeyPress) -> Bool, action: @escaping (KeyPress) -> KeyPress.Result) { self.accepts = accepts; self.action = action }
}

@MainActor final class FocusTarget {
    let path: String
    var isFocused: () -> Bool = { false }
    var claim: () -> Void = {}
    var release: () -> Void = {}
    /// The native widget that takes keyboard focus for it, and that
    /// widget's view path (what the host records as holding focus).
    var widget: NativeWidget?
    var widgetPath: String?
    init(path: String) { self.path = path }
}

/// Pointer and key handlers of an event container, replaced each render.
@MainActor final class EventHandlers {
    var pointer: (PointerEvent) -> Bool = { _ in false }
    var key: (RunwayCore.KeyPress) -> Bool = { _ in false }
    var focus: (Bool) -> Void = { _ in }
    var hovering = false
    weak var widget: NativeWidget?
}

struct FocusTargetPathKey: EnvironmentKey { static var defaultValue: String? { nil } }
struct FocusEffectDisabledKey: EnvironmentKey { static var defaultValue: Bool { false } }

extension EnvironmentValues {
    /// The `.focused` target whose widget the next focusable view becomes.
    var _focusTargetPath: String? { get { self[FocusTargetPathKey.self] } set { self[FocusTargetPathKey.self] = newValue } }
    var _focusEffectDisabled: Bool { get { self[FocusEffectDisabledKey.self] } set { self[FocusEffectDisabledKey.self] = newValue } }
}

extension ViewHost {
    func registerKeyHandler(_ path: String, _ entry: KeyHandlerEntry) {
        let key = "key:" + path
        visitedInteractions.insert(key)
        record(.interaction, key)
        interactions[key] = entry
    }

    func focusTarget(_ path: String) -> FocusTarget {
        let key = "focus:" + path
        visitedInteractions.insert(key)
        record(.interaction, key)
        if let t = interactions[key] as? FocusTarget { return t }
        let t = FocusTarget(path: path)
        interactions[key] = t
        return t
    }

    func existingFocusTarget(_ path: String) -> FocusTarget? { interactions["focus:" + path] as? FocusTarget }

    /// An event container kept by key, with handlers the caller fills in.
    func eventWidget(_ key: String, focusable: Bool) -> (NativeWidget, EventHandlers)? {
        guard let appKit = backend as? AppKitBackend else { return nil }
        let hkey = "ev:" + key + (focusable ? "#f" : "")
        visitedInteractions.insert(hkey)
        record(.interaction, hkey)
        let handlers: EventHandlers
        if let h = interactions[hkey] as? EventHandlers { handlers = h } else { handlers = EventHandlers(); interactions[hkey] = handlers }
        let w = customWidget(key + (focusable ? "#f" : ""), fresh: interactions[hkey] !== handlers) {
            let w = appKit.makeEventContainer(focusable: focusable,
                                              pointer: { [weak handlers] e in handlers?.pointer(e) ?? false },
                                              key: { [weak handlers] k in handlers?.key(k) ?? false })
            if focusable { appKit.observeFocus(w) { [weak handlers] gained in handlers?.focus(gained) } }
            return w
        }
        return (w, handlers)
    }

    /// The view paths' handlers for a key pressed while `path` has focus,
    /// innermost first; true when one handled it.
    func dispatchKey(_ k: RunwayCore.KeyPress, from path: String) -> Bool {
        if let last = lastDispatchedKey, last.key == k, last.path == path { return last.handled }
        let press = KeyPress(k)
        var chain: [(String, KeyHandlerEntry)] = []
        for (key, value) in interactions where key.hasPrefix("key:") {
            guard let entry = value as? KeyHandlerEntry else { continue }
            let p = String(key.dropFirst(4))
            if Self.isAncestor(p, of: path) { chain.append((p, entry)) }
        }
        chain.sort { $0.0.count > $1.0.count }
        var handled = false
        for (_, entry) in chain where entry.accepts(press) {
            if entry.action(press) == .handled { handled = true; break }
        }
        // The window's handler and the focused control's both see a key;
        // only the first dispatch of one event runs the handlers.
        lastDispatchedKey = (k, path, handled)
        backend.schedule { [weak self] in self?.lastDispatchedKey = nil }
        return handled
    }

    /// Whether `a` is `b` or a view containing it.
    static func isAncestor(_ a: String, of b: String) -> Bool {
        guard b.hasPrefix(a) else { return false }
        if b.count == a.count { return true }
        let next = b[b.index(b.startIndex, offsetBy: a.count)]
        return next == "/" || next == ":" || next == "#"
    }

    /// A native view at `path` gained or lost keyboard focus.
    func nativeFocusChanged(_ path: String, gained: Bool) {
        let targets = interactions.values.compactMap { $0 as? FocusTarget }.filter { $0.widgetPath == path }
        if gained {
            keyFocusPath = path
            for t in targets where !t.isFocused() { t.claim() }
        } else {
            if keyFocusPath == path { keyFocusPath = nil }
            for t in targets where t.isFocused() { t.release() }
        }
    }

    func scheduleFocusSync() {
        focusSyncRequested = true
        guard !focusSyncScheduled else { return }
        focusSyncScheduled = true
        backend.schedule { [weak self] in
            self?.focusSyncScheduled = false
            self?.syncFocus()
        }
    }

    /// Moves keyboard focus to match focus state set in code.
    func syncFocus(attempt: Int = 0) {
        guard focusSyncRequested, let appKit = backend as? AppKitBackend else { return }
        focusSyncRequested = false
        let targets = interactions.values.compactMap { $0 as? FocusTarget }
        if let want = targets.first(where: { $0.isFocused() && $0.widget != nil && $0.widgetPath != keyFocusPath }), let w = want.widget {
            appKit.focus(w)
            if keyFocusPath != want.widgetPath, attempt < 10 {
                // Not mapped yet (a sheet still opening): try again shortly.
                focusSyncRequested = true
                appKit.after(0.03) { [weak self] in self?.syncFocus(attempt: attempt + 1) }
            }
            return
        }
        if let held = keyFocusPath, let t = targets.first(where: { $0.widgetPath == held }), !t.isFocused(), let w = t.widget {
            appKit.resignFocus(w)
            keyFocusPath = nil
        }
    }
}

extension ResolveContext {
    /// Makes a native control the widget of the enclosing `.focused` target
    /// and reports its focus and keys to the host.
    func adoptFocus(_ w: NativeWidget?, textField: Bool) {
        guard let w, !dryRun, let appKit = host.backend as? AppKitBackend else { return }
        let path = self.path
        if let tp = env._focusTargetPath, let t = host.existingFocusTarget(tp) {
            t.widget = w
            t.widgetPath = path
        }
        let host = self.host
        if textField {
            appKit.observeTextField(w, focus: { [weak host] gained in host?.nativeFocusChanged(path, gained: gained) },
                                    key: { [weak host] k in host?.dispatchKey(k, from: path) ?? false })
        } else {
            appKit.observeFocus(w) { [weak host] gained in host?.nativeFocusChanged(path, gained: gained) }
        }
    }
}

// MARK: Modifiers

extension View {
    public func focused<V: Hashable>(_ binding: FocusState<V>.Binding, equals value: V) -> some View {
        environmentTransform { env, ctx in
            guard !ctx.dryRun else { return }
            let t = ctx.host.focusTarget(ctx.path)
            let box = binding.box
            t.isFocused = { box.current == value }
            t.claim = { MainActor.assumeIsolated { box.set(value) } }
            t.release = { MainActor.assumeIsolated { if box.current == value { box.set(box.unfocused) } } }
            env._focusTargetPath = ctx.path
        }
    }

    public func focused(_ condition: FocusState<Bool>.Binding) -> some View {
        focused(condition, equals: true)
    }

    /// The view takes keyboard focus itself (when clicked, or when a
    /// `.focused` state names it), so key handlers around it see keys.
    public func focusable(_ isFocusable: Bool = true) -> some View {
        nodes("focusable") { ns, ctx in
            guard isFocusable, !ctx.dryRun, let (w, h) = ctx.host.eventWidget(ctx.path, focusable: true) else { return ns }
            let host = ctx.host, path = ctx.path
            if let tp = ctx.env._focusTargetPath, let t = host.existingFocusTarget(tp), t.widget == nil || t.widgetPath == path {
                t.widget = w
                t.widgetPath = path
            }
            h.pointer = { _ in false }
            h.key = { [weak host] k in host?.dispatchKey(k, from: path) ?? false }
            h.focus = { [weak host] gained in host?.nativeFocusChanged(path, gained: gained) }
            host.backend.update(w, props: ctx.baseProps(), events: WidgetEvents())
            let inner: LayoutNode = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            return [ContainerNode(widget: w, backend: host.backend, content: inner, sizing: .hug)]
        }
    }

    public func focusable(_ isFocusable: Bool = true, interactions: FocusInteractions) -> some View { focusable(isFocusable) }

    public func focusEffectDisabled(_ disabled: Bool = true) -> some View { environment { $0._focusEffectDisabled = disabled } }

    // Key presses.

    public func onKeyPress(_ key: KeyEquivalent, action: @escaping () -> KeyPress.Result) -> some View {
        keyHandler(accepts: { $0.key == key && $0.phase != .up }, action: { _ in action() })
    }
    public func onKeyPress(_ key: KeyEquivalent, phases: KeyPress.Phases, action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        keyHandler(accepts: { $0.key == key && phases.contains($0.phase) }, action: action)
    }
    public func onKeyPress(keys: Set<KeyEquivalent>, phases: KeyPress.Phases = [.down, .repeat], action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        keyHandler(accepts: { keys.contains($0.key) && phases.contains($0.phase) }, action: action)
    }
    public func onKeyPress(characters: CharacterSet, phases: KeyPress.Phases = [.down, .repeat], action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        keyHandler(accepts: { press in
            phases.contains(press.phase) && !press.characters.isEmpty && press.characters.unicodeScalars.allSatisfy { characters.contains($0) }
        }, action: action)
    }
    public func onKeyPress(phases: KeyPress.Phases = [.down, .repeat], action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        keyHandler(accepts: { phases.contains($0.phase) }, action: action)
    }

    private func keyHandler(accepts: @escaping (KeyPress) -> Bool, action: @escaping (KeyPress) -> KeyPress.Result) -> some View {
        nodes("onkey") { ns, ctx in
            if !ctx.dryRun { ctx.host.registerKeyHandler(ctx.path, KeyHandlerEntry(accepts: accepts, action: action)) }
            return ns
        }
    }

    // Hover.

    public func onHover(perform action: @escaping (Bool) -> Void) -> some View {
        pointerArea("hover") { h, _ in
            h.pointer = { [weak h] e in
                guard let h else { return false }
                switch e.kind {
                case .moved, .entered:
                    if !h.hovering { h.hovering = true; action(true) }
                case .exited:
                    if h.hovering { h.hovering = false; action(false) }
                default: break
                }
                return false
            }
        }
    }

    public func onContinuousHover(coordinateSpace: CoordinateSpace = .local, perform action: @escaping (HoverPhase) -> Void) -> some View {
        pointerArea("chover") { h, _ in
            h.pointer = { [weak h] e in
                switch e.kind {
                case .moved, .entered, .dragged: h?.hovering = true; action(.active(e.location))
                case .exited: h?.hovering = false; action(.ended)
                default: break
                }
                return false
            }
        }
    }

    // Context menus.

    public func contextMenu<M: View>(@ViewBuilder menuItems: () -> M) -> some View {
        let items = menuItems()
        return pointerArea("ctxmenu") { h, ctx in
            let snapshot = ctx
            h.pointer = { [weak host = ctx.host] e in
                guard e.kind == .down, e.button == 1 || (e.button == 0 && e.modifiers.contains(.control)),
                      let host, let appKit = host.backend as? AppKitBackend, let w = h.widget else { return false }
                let menu = MenuItems.collect(items, snapshot.child("menu"))
                guard !menu.isEmpty else { return false }
                appKit.popUpMenu(menu, in: w, at: e.location)
                return true
            }
        }
    }

    public func contextMenu<M: View, P: View>(@ViewBuilder menuItems: () -> M, @ViewBuilder preview: () -> P) -> some View {
        contextMenu(menuItems: menuItems)
    }


    // Hit testing and pointer style.

    /// Views that don't take hits pass clicks to what's beneath them.
    public func allowsHitTesting(_ enabled: Bool) -> some View {
        nodes("hittest") { ns, ctx in
            guard !enabled, !ctx.dryRun, let appKit = ctx.host.backend as? AppKitBackend, let w = ctx.widget(.container, "nohit") else { return ns }
            appKit.setHitTestable(w, false)
            ctx.host.backend.update(w, props: ctx.baseProps(), events: WidgetEvents())
            let inner: LayoutNode = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            return [ContainerNode(widget: w, backend: ctx.host.backend, content: inner, sizing: .hug)]
        }
    }

    public func pointerStyle(_ style: PointerStyle?) -> some View {
        pointerArea("pointer") { h, ctx in
            if let appKit = ctx.host.backend as? AppKitBackend, let w = h.widget { appKit.setCursor(w, style?.cursor ?? .arrow) }
        }
    }

    /// Wraps the content in an event container that sees the pointer
    /// without taking clicks from what's inside.
    fileprivate func pointerArea(_ name: String, _ configure: @escaping @MainActor (EventHandlers, ResolveContext) -> Void) -> some View {
        nodes(name) { ns, ctx in
            guard !ctx.dryRun, let (w, h) = ctx.host.eventWidget(ctx.path, focusable: false) else { return ns }
            h.widget = w
            configure(h, ctx)
            ctx.host.backend.update(w, props: ctx.baseProps(), events: WidgetEvents())
            let inner: LayoutNode = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            return [ContainerNode(widget: w, backend: ctx.host.backend, content: inner, sizing: .hug)]
        }
    }
}

public struct FocusInteractions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let activate = FocusInteractions(rawValue: 1)
    public static let edit = FocusInteractions(rawValue: 2)
    public static let automatic: FocusInteractions = [.activate, .edit]
}

/// Menu items from a view builder (Menu's and contextMenu's content).
@MainActor enum MenuItems {
    static func collect<V: View>(_ content: V, _ ctx: ResolveContext) -> [MenuItemSpec] {
        var c = ctx.with { $0._inMenu = true }
        c.dryRun = true
        var out: [MenuItemSpec] = []
        func walk(_ n: LayoutNode) {
            if let m = n.menuItem { out.append(m); return }
            if n is DividerMarker { out.append(.separator); return }
            n.children.forEach(walk)
        }
        c.resolve(content, "items").forEach(walk)
        return out
    }
}

/// A modifier that adjusts the environment for its content, with the
/// context it's resolved in (path, host).
struct EnvironmentTransformModifier<Content: View>: View, PrimitiveView {
    typealias Body = Never
    let content: Content
    let transform: @MainActor (inout EnvironmentValues, ResolveContext) -> Void
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        var c = ctx.child("envx")
        transform(&c.env, c)
        return c.resolve(content, "c")
    }
}

extension View {
    func environmentTransform(_ transform: @escaping @MainActor (inout EnvironmentValues, ResolveContext) -> Void) -> some View {
        EnvironmentTransformModifier(content: self, transform: transform)
    }
}

// MARK: Text selection

/// The selection in a text editor (`TextEditor(text:selection:)`).
public struct TextSelection: Hashable, Sendable {
    public enum Indices: Hashable, Sendable {
        case selection(Range<String.Index>)
        case multiSelection(RangeSet<String.Index>)
    }
    public enum Affinity: Hashable, Sendable { case upstream, downstream, automatic }

    public var indices: Indices
    public var affinity: Affinity = .automatic

    public init(range: Range<String.Index>) { indices = .selection(range) }
    public init(insertionPoint: String.Index) { indices = .selection(insertionPoint..<insertionPoint) }
    public init(ranges: RangeSet<String.Index>) { indices = .multiSelection(ranges) }

    public var isInsertion: Bool {
        if case let .selection(r) = indices { return r.isEmpty }
        return false
    }

    /// Unicode scalar offsets, as backends count.
    func scalarRange(in s: String) -> Range<Int> {
        let r: Range<String.Index>
        switch indices {
        case let .selection(x): r = x
        case let .multiSelection(set): r = set.ranges.first ?? s.startIndex..<s.startIndex
        }
        let clamp = { (i: String.Index) in min(max(i, s.startIndex), s.endIndex) }
        let a = s.unicodeScalars.distance(from: s.startIndex, to: clamp(r.lowerBound))
        let z = s.unicodeScalars.distance(from: s.startIndex, to: clamp(r.upperBound))
        return a..<max(a, z)
    }

    init(scalarRange r: Range<Int>, in s: String) {
        let scalars = s.unicodeScalars
        let n = scalars.count
        let a = scalars.index(scalars.startIndex, offsetBy: min(max(0, r.lowerBound), n))
        let z = scalars.index(scalars.startIndex, offsetBy: min(max(0, r.upperBound), n))
        indices = .selection(a..<z)
    }
}

// MARK: Scrolling to views

/// Records where a view with an `.id` lands, in its scroll view's document.
final class IDMarkerNode: LayoutNode {
    let target: LayoutNode
    let id: AnyHashable
    init(_ target: LayoutNode, id: AnyHashable) {
        self.target = target
        self.id = id
        super.init()
        layoutPriority = target.layoutPriority
        tag = target.tag
        tagValue = target.tagValue
    }
    override var textContent: String? { target.textContent }
    override var children: [LayoutNode] { [target] }
    override var menuItem: MenuItemSpec? { target.menuItem }
    override var isSpacer: Bool { target.isSpacer }
    override var isEmptyLayout: Bool { target.isEmptyLayout }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize { target.size(p) }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        if let doc = sink.scrollDocument, let host = sink.host {
            let frame = rect.offsetBy(dx: sink.documentOrigin.x - sink.offset.x, dy: sink.documentOrigin.y - sink.offset.y)
            host.idFrames[id] = (ObjectIdentifier(doc), frame)
        }
        target.place(rect, sink)
    }
    override var debugName: String { target.debugName }
}

@MainActor final class ScrollRecord {
    weak var widget: NativeWidget?
    var anchor: UnitPoint?
    var document: CGSize = .zero
    var viewport: CGSize = .zero
    var placedOnce = false
    /// Was showing its end (for a bottom anchor) before the last change.
    var atEnd = true
}

struct DefaultScrollAnchorKey: EnvironmentKey { static var defaultValue: UnitPoint? { nil } }
extension EnvironmentValues {
    var _defaultScrollAnchor: UnitPoint? { get { self[DefaultScrollAnchorKey.self] } set { self[DefaultScrollAnchorKey.self] = newValue } }
}

extension ViewHost {
    func registerScrollView(_ widget: NativeWidget, anchor: UnitPoint?) {
        let id = ObjectIdentifier(widget)
        let r = scrollViews[id] ?? ScrollRecord()
        r.widget = widget
        r.anchor = anchor
        if let appKit = backend as? AppKitBackend, r.placedOnce {
            let y = appKit.scrollOffset(widget).y
            r.atEnd = y + r.viewport.height >= r.document.height - 4
        }
        scrollViews[id] = r
    }

    /// A scroll view was laid out: keep content anchored to its end.
    func scrollPlaced(_ widget: NativeWidget, document: CGSize, viewport: CGSize) {
        guard let r = scrollViews[ObjectIdentifier(widget)], let appKit = backend as? AppKitBackend else { return }
        let first = !r.placedOnce
        let changed = r.document != document || r.viewport != viewport
        r.document = document
        r.viewport = viewport
        r.placedOnce = true
        guard let anchor = r.anchor, changed, first || (anchor.y >= 0.5 && r.atEnd) else { return }
        let maxY = max(0, document.height - viewport.height)
        appKit.setScrollOffset(widget, CGPoint(x: appKit.scrollOffset(widget).x, y: (maxY * anchor.y).rounded()))
    }

    /// Scrolls the scroll view holding the view with this id so it shows
    /// at `anchor` (or just into view).
    func scrollTo(_ id: AnyHashable, anchor: UnitPoint?) {
        // After the render a state change in the same action causes.
        backend.schedule { [weak self] in
            guard let self else { return }
            if self.scheduled { self.renderIfNeeded() }
            self.performScroll(id, anchor: anchor)
        }
    }

    private func performScroll(_ id: AnyHashable, anchor: UnitPoint?) {
        guard let (scrollID, frame) = idFrames[id], let r = scrollViews[scrollID], let w = r.widget,
              let appKit = backend as? AppKitBackend else { return }
        let viewport = appKit.scrollViewportSize(w)
        let current = appKit.scrollOffset(w)
        var y = current.y
        if let a = anchor {
            y = frame.minY + frame.height * a.y - viewport.height * a.y
        } else if frame.minY < current.y {
            y = frame.minY
        } else if frame.maxY > current.y + viewport.height {
            y = frame.maxY - viewport.height
        }
        let maxY = max(0, r.document.height - viewport.height)
        appKit.setScrollOffset(w, CGPoint(x: current.x, y: min(max(0, y), maxY).rounded()))
    }
}

extension View {
    public func defaultScrollAnchor(_ anchor: UnitPoint?) -> some View { environment { $0._defaultScrollAnchor = anchor } }
    public func defaultScrollAnchor(_ anchor: UnitPoint?, for role: ScrollAnchorRole) -> some View { environment { $0._defaultScrollAnchor = anchor } }
}

public struct ScrollAnchorRole: Hashable, Sendable {
    public static let initialOffset = Self(), sizeChanges = Self(), alignment = Self()
}
