// The view graph: a host per window renders its root view into native
// widgets, keeps state and widgets by structural path, tracks Observation
// reads so changes to @Observable models re-render, and runs lifecycle
// effects (onAppear, onChange, task) after each commit.
//
// Rendering is incremental. Every view with a body (a custom View) is a
// *scope*: it remembers the input it was resolved with (its value and
// environment), the layout nodes it produced, and the state, widgets and
// effects it owns. Then:
//
// - A @State (or ObservableObject) change dirties only its own scope. If the
//   scope's output still has the same shape, its body alone runs again and
//   the result is spliced into the existing tree (its parent's body does not
//   run, as in SwiftUI).
// - Otherwise the tree is resolved from the root, but any scope whose input
//   is unchanged (compared field by field: == for Equatable fields, bitwise
//   otherwise, @State and friends ignored) and that holds nothing dirty is
//   reused as is: its body does not run and its layout nodes, with their
//   measurements, are kept.
// - A window resize lays out again without running any body.
// - Each native container's children are only re-sent to the toolkit when
//   they or their frames changed.
//
// Observation reads are tracked per scope; Swift's tracking merges a nested
// scope's reads into its ancestors', so a model change re-runs the path from
// the root to the scopes that read it (siblings with equal input are
// reused).

@_spi(Reflection) import Swift
import Foundation
import CoreGraphics
import Observation
import RunwayCore

/// Passed down while resolving: the host, the environment and the path.
@preconcurrency @MainActor public struct ResolveContext {
    let host: ViewHost
    var env: EnvironmentValues
    var path: String
    /// Resolving only to read structure (Picker options, menu items): no
    /// widgets are made.
    var dryRun = false
    /// The innermost scope (custom view) being resolved.
    var scope: Scope?

    func child(_ component: String) -> ResolveContext {
        var c = self
        c.path = path + "/" + component
        return c
    }

    func with(_ transform: (inout EnvironmentValues) -> Void) -> ResolveContext {
        var c = self
        transform(&c.env)
        return c
    }

    func resolve<V: View>(_ view: V, _ component: String) -> [LayoutNode] {
        host.resolve(view, in: child(component))
    }

    func resolveAny(_ view: any View, _ component: String) -> [LayoutNode] {
        func open<V: View>(_ v: V) -> [LayoutNode] { resolve(v, component) }
        return open(view)
    }

    /// The widget for this path, reused across renders. `nil` in a dry run.
    func widget(_ kind: WidgetKind, _ suffix: String = "w") -> NativeWidget? {
        dryRun ? nil : host.widget(path + "#" + suffix, kind)
    }
}

/// Storage a dynamic property links to, kept per path across renders.
final class StateBox<Value>: @unchecked Sendable {
    var value: Value
    weak var host: ViewHost?
    /// The scope whose body reads it (re-run when it changes).
    weak var scope: Scope?
    init(_ value: Value, host: ViewHost) { self.value = value; self.host = host }
    @MainActor func set(_ v: Value) {
        value = v
        host?.invalidate(scope: scope)
    }
}

/// Implemented by @State, @Environment, @Bindable…: linked before a body runs.
@MainActor protocol DynamicPropertyLink {
    func link(_ ctx: ResolveContext, key: String)
    func linkForProbe(_ env: EnvironmentValues)
}

extension DynamicPropertyLink {
    func linkForProbe(_ env: EnvironmentValues) {}
}

/// SwiftUI's DynamicProperty: custom ones may hold @State and friends.
public protocol DynamicProperty {
    mutating func update()
}
extension DynamicProperty { public mutating func update() {} }

// MARK: Scopes

/// A custom view's place in the graph: what it was resolved from, what it
/// produced, and what it owns.
@preconcurrency @MainActor public final class Scope {
    let path: String
    weak var parent: Scope?
    /// The render generation that last saw it in the tree.
    var generation = 0
    /// Its last input; `nil` until first resolved.
    var input: ScopeInput?
    /// What its parent's layout holds: stable proxies to its current nodes.
    var proxies: [ScopeNode] = []
    /// Its own state changed: the body must run again.
    var dirty = true
    /// Something below it is dirty: it can't be reused wholesale.
    var containsDirty = false
    /// Must always run again: it reads the container size (GeometryReader)
    /// or registers window-level actions (shortcuts, default/cancel
    /// buttons, title), which are collected afresh on each full resolve.
    var volatile = false
    /// Bumped when something below changes size without this body running,
    /// so the layout nodes it owns measure again.
    var layoutEpoch = 0
    /// Keys of host storage (state, widgets, effects) it touched directly.
    var ownKeys: [StorageKey] = []
    /// The scopes resolved within it, in order.
    var children: [Scope] = []

    init(path: String) { self.path = path }
}

struct StorageKey {
    enum Kind: UInt8 { case state, widget, appear, task, value, presentation, interaction }
    let kind: Kind
    let key: String
}

/// A scope's input: the view value and the context it was resolved in.
@MainActor class ScopeInput {
    var ctx: ResolveContext
    init(ctx: ResolveContext) { self.ctx = ctx }
    func same(as other: ScopeInput) -> Bool { false }
    func link(_ host: ViewHost, _ ctx: ResolveContext) {}
    func resolveBody(_ host: ViewHost, _ ctx: ResolveContext) -> [LayoutNode] { [] }
}

final class TypedScopeInput<V: View>: ScopeInput {
    let view: V
    init(_ view: V, ctx: ResolveContext) { self.view = view; super.init(ctx: ctx) }
    override func same(as other: ScopeInput) -> Bool {
        guard let o = other as? TypedScopeInput<V> else { return false }
        return FieldLayout.equal(view, o.view)
    }
    override func link(_ host: ViewHost, _ ctx: ResolveContext) { host.linkTyped(view, ctx) }
    override func resolveBody(_ host: ViewHost, _ ctx: ResolveContext) -> [LayoutNode] {
        host.resolve(view.body, in: ctx.child("body"))
    }
}

/// Stands in a parent's layout for one node a scope produced, so the scope
/// can be resolved again on its own and its new node swapped in.
final class ScopeNode: LayoutNode {
    private(set) var target: LayoutNode
    init(_ target: LayoutNode) {
        self.target = target
        super.init()
        adopt()
    }
    func retarget(_ node: LayoutNode) {
        guard node !== target else { return }
        target = node
        adopt()
        clearSizeCache()
    }
    private func adopt() {
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
    override func place(_ rect: CGRect, _ sink: PlacementSink) { target.place(rect, sink) }
    override var debugName: String { target.debugName }
}

/// Readers of @AppStorage keys, so a write re-runs every body that reads it.
@MainActor enum AppStorageReaders {
    final class Ref { weak var scope: Scope?; weak var host: ViewHost?; init(_ s: Scope?, _ h: ViewHost?) { scope = s; host = h } }
    static var readers: [String: [Ref]] = [:]
    static func add(_ key: String, scope: Scope?, host: ViewHost) {
        var list = readers[key, default: []].filter { $0.host != nil }
        if !list.contains(where: { $0.scope === scope && $0.host === host }) { list.append(Ref(scope, host)) }
        readers[key] = list
    }
    static func changed(_ key: String) {
        for r in readers[key] ?? [] { r.host?.invalidate(scope: r.scope) }
    }
}

// MARK: The host

@preconcurrency @MainActor public final class ViewHost {
    public let backend: Backend
    public let container: NativeWidget
    var root: (ResolveContext) -> [LayoutNode]
    public var baseEnvironment: EnvironmentValues
    public private(set) var size: CGSize = .zero
    weak var window: NativeWindow?
    /// The NSHostingView showing this host, if any: NSViewRepresentable
    /// views join its view hierarchy.
    weak var hostingView: NSView?
    /// Called when the ideal size changes (windows sized to content).
    var onIdealSizeChange: ((CGSize) -> Void)?
    var onTitleChange: ((String) -> Void)?

    private var states: [String: AnyObject] = [:]
    private var visitedStates: Set<String> = []
    private var widgets: [String: (WidgetKind, NativeWidget)] = [:]
    private var usedWidgets: Set<String> = []
    private(set) var scheduled = false
    private var rendering = false
    private(set) var renderCount = 0
    /// How many renders ran bodies from the root, spliced scopes, or only
    /// laid out again (tests and metrics).
    private(set) var fullResolves = 0
    private(set) var splices = 0
    private(set) var bodiesRun = 0

    // Incremental state.
    private var rootDirty = true
    private var dirtyScopes: [Scope] = []
    private var scopes: [String: Scope] = [:]
    private let rootScope = Scope(path: "")
    private var generation = 0
    /// The scope whose body is being resolved (state, widgets and effects
    /// touched now belong to it).
    private var currentScope: Scope?
    /// GeometryReader resolves its content during layout: a size change
    /// must run bodies again.
    var readsGeometry = false
    private var pendingGC: GC = .none
    private enum GC { case none, full, partial(keys: [StorageKey], scopes: [Scope]) }
    /// Per native container: the children last sent to the toolkit.
    private var committed: [ObjectIdentifier: CommitRecord] = [:]
    private var commitGeneration = 0

    // Lifecycle.
    struct Appearance { var onDisappear: [() -> Void] = [] }
    private var appeared: [String: Appearance] = [:]
    private var visitedAppear: Set<String> = []
    private var effects: [() -> Void] = []
    private var tasks: [String: (id: AnyHashable?, task: Task<Void, Never>)] = [:]
    private var visitedTasks: Set<String> = []
    private var lastValues: [String: Any] = [:]
    /// Window-level actions bodies register; any change marks the scope
    /// being resolved as volatile (see Scope.volatile).
    private var effectStamp = 0
    var shortcuts: [(RunwayCore.KeyPress, () -> Void)] = [] { didSet { effectStamp += 1 } }
    var defaultAction: (() -> Void)? { didSet { effectStamp += 1 } }
    var cancelAction: (() -> Void)? { didSet { effectStamp += 1 } }
    var presentations: [String: Presentation] = [:]
    private var visitedPresentations: Set<String> = []
    /// Focus targets and key handlers registered by modifiers, by path
    /// (see Interaction.swift); kept alive like state.
    var interactions: [String: AnyObject] = [:]
    var visitedInteractions: Set<String> = []
    /// The path of the view holding keyboard focus in this host, if any.
    var keyFocusPath: String?
    var focusSyncScheduled = false
    var focusSyncRequested = false
    /// Where views with an `.id` were last placed: their scroll view and
    /// frame in its document.
    var idFrames: [AnyHashable: (scroll: ObjectIdentifier, frame: CGRect)] = [:]
    var scrollViews: [ObjectIdentifier: ScrollRecord] = [:]
    var lastDispatchedKey: (key: RunwayCore.KeyPress, path: String, handled: Bool)?
    var title: String? { didSet { effectStamp += 1 } }
    public private(set) var lastRoot: LayoutNode?

    public init<V: View>(_ view: V, backend: Backend? = nil, container: NativeWidget? = nil, environment: EnvironmentValues = EnvironmentValues()) {
        MainThread.record()
        let backend = backend ?? Runway.backend
        self.backend = backend
        self.container = container ?? backend.makeWidget(.container)
        (backend as? AppKitBackend)?.setPassesThrough(self.container, true)
        self.baseEnvironment = environment
        self.root = { ctx in ctx.resolve(view, "root") }
    }

    public func setRoot<V: View>(_ view: V) {
        root = { ctx in ctx.resolve(view, "root") }
        invalidate()
    }

    public func setSize(_ s: CGSize) {
        guard s != size else { return }
        size = s
        // Only layout depends on the size, unless a GeometryReader reads it.
        if readsGeometry { rootDirty = true }
        scheduleRender()
    }

    /// Everything may have changed: resolve from the root (reusing what
    /// provably didn't).
    public func invalidate() {
        rootDirty = true
        scheduleRender()
    }

    /// `scope`'s own state changed.
    func invalidate(scope: Scope?) {
        guard let scope, scope !== rootScope else { invalidate(); return }
        if !scope.dirty {
            scope.dirty = true
            dirtyScopes.append(scope)
            var p = scope.parent
            while let q = p, !q.containsDirty { q.containsDirty = true; p = q.parent }
        }
        scheduleRender()
    }

    private func scheduleRender() {
        guard !scheduled else { return }
        scheduled = true
        backend.schedule { [weak self] in self?.renderIfNeeded() }
    }

    public func renderIfNeeded() { if scheduled { render() } }

    // MARK: Resolving

    func resolve<V: View>(_ view: V, in ctx: ResolveContext) -> [LayoutNode] {
        if let p = view as? PrimitiveView { return p.resolve(in: ctx) }
        if let r = view as? any NSViewRepresentable { return r.resolveRepresentable(in: ctx) }
        if let r = view as? any NSViewControllerRepresentable { return r.resolveControllerRepresentable(in: ctx) }
        var ctx = ctx
        ctx.path += ":" + typeKey(V.self)
        if ctx.dryRun {
            linkTyped(view, ctx)
            return resolve(view.body, in: ctx.child("body"))
        }
        return resolveScope(view, ctx)
    }

    private func resolveScope<V: View>(_ view: V, _ ctx: ResolveContext) -> [LayoutNode] {
        let scope: Scope
        if let s = scopes[ctx.path] { scope = s } else { scope = Scope(path: ctx.path); scopes[ctx.path] = scope }
        let parent = ctx.scope ?? rootScope
        scope.parent = parent
        if lateDepth == 0 { parent.children.append(scope) }
        if !scope.dirty, !scope.containsDirty, !scope.volatile, let old = scope.input,
           old.ctx.env.memoEquals(ctx.env), let typed = old as? TypedScopeInput<V>, FieldLayout.equal(typed.view, view) {
            // Same input, nothing inside changed: keep it as it is.
            old.ctx = ctx
            markAlive(scope)
            return scope.proxies
        }
        scope.generation = generation
        let nodes = runBody(scope, TypedScopeInput(view, ctx: ctx))
        return wrap(scope, nodes)
    }

    /// Runs a scope's body: links its dynamic properties, resolves the
    /// body with its reads tracked, and records what it touched.
    private func runBody(_ scope: Scope, _ input: ScopeInput) -> [LayoutNode] {
        bodiesRun += 1
        scope.input = input
        scope.dirty = false
        scope.containsDirty = false
        scope.volatile = false
        scope.ownKeys.removeAll(keepingCapacity: true)
        scope.children.removeAll(keepingCapacity: true)
        var ctx = input.ctx
        ctx.scope = scope
        let outer = currentScope
        let outerBuilding = LayoutNode.buildingScope
        currentScope = scope
        LayoutNode.buildingScope = scope
        let stamp = effectStamp
        input.link(self, ctx)
        let nodes = withObservationTracking {
            input.resolveBody(self, ctx)
        } onChange: { [weak self, weak scope] in
            let ref = UncheckedScopeRef(host: self, scope: scope)
            if Thread.isMainThread {
                MainActor.assumeIsolated { ref.invalidate() }
            } else {
                Task { @MainActor in ref.invalidate() }
            }
        }
        if effectStamp != stamp { scope.volatile = true }
        currentScope = outer
        LayoutNode.buildingScope = outerBuilding
        return nodes
    }

    private func wrap(_ scope: Scope, _ nodes: [LayoutNode]) -> [LayoutNode] {
        if scope.proxies.count == nodes.count {
            for (p, n) in zip(scope.proxies, nodes) { p.retarget(n) }
        } else {
            scope.proxies = nodes.map { ScopeNode($0) }
        }
        return scope.proxies
    }

    /// A reused scope and everything in it stay alive this render.
    private func markAlive(_ scope: Scope) {
        scope.generation = generation
        for k in scope.ownKeys { visit(k) }
        for c in scope.children { markAlive(c) }
    }

    private func visit(_ k: StorageKey) {
        switch k.kind {
        case .state, .value: visitedStates.insert(k.key)
        case .widget: usedWidgets.insert(k.key)
        case .appear: visitedAppear.insert(k.key)
        case .task: visitedTasks.insert(k.key)
        case .presentation: visitedPresentations.insert(k.key)
        case .interaction: visitedInteractions.insert(k.key)
        }
    }

    func record(_ kind: StorageKey.Kind, _ key: String) {
        currentScope?.ownKeys.append(StorageKey(kind: kind, key: key))
    }

    /// Resolves content outside the normal walk: GeometryReader's, built at
    /// layout time for the size it gets. What it touches is kept alive by
    /// being touched (layout runs before garbage collection) rather than
    /// recorded on a scope, which would grow on every layout.
    private var lateDepth = 0
    func resolveLate(_ body: () -> [LayoutNode]) -> [LayoutNode] {
        let outer = currentScope, outerBuilding = LayoutNode.buildingScope
        currentScope = nil
        LayoutNode.buildingScope = nil
        lateDepth += 1
        defer { currentScope = outer; LayoutNode.buildingScope = outerBuilding; lateDepth -= 1 }
        return body()
    }

    private var typeKeys: [ObjectIdentifier: String] = [:]
    private func typeKey(_ t: Any.Type) -> String {
        if let k = typeKeys[ObjectIdentifier(t)] { return k }
        var name = String(describing: t)
        if let lt = name.firstIndex(of: "<") { name = String(name[..<lt]) }
        typeKeys[ObjectIdentifier(t)] = name
        return name
    }

    /// Links @State and friends found in `value` (and in custom
    /// DynamicProperty structs it holds) to this path's storage.
    func link(_ value: Any, _ ctx: ResolveContext) {
        func open<T>(_ v: T) { linkTyped(v, ctx) }
        _openExistential(value, do: open)
    }

    func linkTyped<T>(_ value: T, _ ctx: ResolveContext) {
        let layout = FieldLayout.of(T.self)
        guard layout.isStruct else { linkMirror(value, ctx); return }
        guard !layout.links.isEmpty else { return }
        withUnsafeBytes(of: value) { raw in
            let base = raw.baseAddress!
            for l in layout.links {
                let v = l.load(base + l.offset)
                if let d = v as? DynamicPropertyLink {
                    linkProperty(d, ctx, label: l.label)
                } else {
                    link(v, ctx.child(l.label))
                }
            }
        }
    }

    private func linkMirror(_ value: Any, _ ctx: ResolveContext) {
        for (i, child) in Mirror(reflecting: value).children.enumerated() {
            if let d = child.value as? DynamicPropertyLink {
                linkProperty(d, ctx, label: child.label ?? "\(i)")
            } else if child.value is DynamicProperty {
                link(child.value, ctx.child(child.label ?? "\(i)"))
            }
        }
    }

    private func linkProperty(_ property: DynamicPropertyLink, _ ctx: ResolveContext, label: String) {
        if ctx.dryRun {
            // Labels and menu items can read the environment when inspected.
            // The probe does not own persistent state or object subscriptions.
            property.linkForProbe(ctx.env)
        } else {
            property.link(ctx, key: ctx.path + "$" + label)
        }
    }

    func stateBox<Value>(_ key: String, initial: () -> Value) -> StateBox<Value> {
        visitedStates.insert(key)
        record(.state, key)
        if let b = states[key] as? StateBox<Value> {
            if let s = currentScope { b.scope = s }
            return b
        }
        let b = StateBox(initial(), host: self)
        b.scope = currentScope
        states[key] = b
        return b
    }

    /// The scope being resolved (AppStorage registers it as a reader).
    var resolvingScope: Scope? { currentScope }

    func widget(_ key: String, _ kind: WidgetKind) -> NativeWidget {
        usedWidgets.insert(key)
        record(.widget, key)
        if let (k, w) = widgets[key] {
            if k == kind { return w }
            destroy(w)
        }
        let w = backend.makeWidget(kind)
        // SwiftUI's containers take no hits themselves, only their content.
        if kind == .container { (backend as? AppKitBackend)?.setPassesThrough(w, true) }
        widgets[key] = (kind, w)
        WidgetKinds.set(w, kind)
        return w
    }

    /// A widget the caller makes itself (an event container), kept by key
    /// like `widget(_:_:)`.
    func customWidget(_ key: String, fresh: Bool, make: () -> NativeWidget) -> NativeWidget {
        usedWidgets.insert(key)
        record(.widget, key)
        if let (_, w) = widgets[key], !fresh { return w }
        if let (_, w) = widgets[key] { destroy(w) }
        let w = make()
        widgets[key] = (.container, w)
        WidgetKinds.set(w, .container)
        return w
    }

    private func destroy(_ w: NativeWidget) {
        WidgetKinds.set(w, nil)
        committed[ObjectIdentifier(w)] = nil
        backend.destroy(w)
    }

    // MARK: Lifecycle

    func appear(_ key: String, onAppear: (() -> Void)?, onDisappear: (() -> Void)?) {
        visitedAppear.insert(key)
        record(.appear, key)
        if appeared[key] == nil {
            appeared[key] = Appearance()
            if let a = onAppear { effects.append(a) }
        }
        if let d = onDisappear { appeared[key]?.onDisappear = [d] }
    }

    func task(_ key: String, id: AnyHashable?, priority: TaskPriority, _ action: @escaping @MainActor @Sendable () async -> Void) {
        visitedTasks.insert(key)
        record(.task, key)
        if let existing = tasks[key], existing.id == id { return }
        tasks[key]?.task.cancel()
        // Start after the commit, like onAppear.
        let slot = key
        tasks[key] = (id, Task { @MainActor in })
        effects.append { [weak self] in
            guard let self else { return }
            self.tasks[slot] = (id, Task(priority: priority) { @MainActor in await action() })
        }
    }

    func change<V: Equatable>(_ key: String, value: V, initial: Bool, _ action: @escaping (V, V) -> Void) {
        visitedStates.insert(key)
        record(.value, key)
        if let old = lastValues[key] as? V {
            if old != value {
                lastValues[key] = value
                effects.append { action(old, value) }
            }
        } else {
            lastValues[key] = value
            if initial { effects.append { action(value, value) } }
        }
    }

    func present(_ key: String, _ p: Presentation) {
        visitedPresentations.insert(key)
        record(.presentation, key)
        if let existing = presentations[key] {
            existing.update(p)
        } else {
            presentations[key] = p
            effects.append { [weak self] in self?.presentations[key]?.open(parent: self?.window) }
        }
    }

    // MARK: Rendering

    public func render() {
        guard !rendering else { scheduleRender(); return }
        rendering = true
        scheduled = false
        renderCount += 1
        let metricsStart = RunwayMetrics.enabled ? RunwayMetrics.monoMillis() : 0
        let oldTitle = title

        if rootDirty || lastRoot == nil {
            resolveFromRoot()
        } else if !dirtyScopes.isEmpty, !spliceDirtyScopes() {
            resolveFromRoot()
        }
        let tResolved = RunwayMetrics.enabled ? RunwayMetrics.monoMillis() : 0
        guard let rootNode = lastRoot else { rendering = false; return }

        // Lay out in the container's size, centred as SwiftUI does.
        let proposal = ProposedSize(width: size.width, height: size.height)
        let fitted = rootNode.size(proposal)
        let tMeasured = RunwayMetrics.enabled ? RunwayMetrics.monoMillis() : 0
        let origin = CGPoint(x: max(0, ((size.width - fitted.width) / 2).rounded()), y: max(0, ((size.height - fitted.height) / 2).rounded()))
        commitGeneration += 1
        let sink = PlacementSink(container: container, backend: backend, host: self)
        rootNode.place(CGRect(origin: origin, size: fitted), sink)
        sink.commit(contentSize: size)
        let tPlaced = RunwayMetrics.enabled ? RunwayMetrics.monoMillis() : 0

        collectGarbage()
        rendering = false
        if RunwayMetrics.enabled { reportRender(since: metricsStart, phases: [tResolved - metricsStart, tMeasured - tResolved, tPlaced - tMeasured]) }

        if title != oldTitle, let t = title { onTitleChange?(t) }
        onIdealSizeChange?(idealSize(rootNode))

        let run = effects
        effects.removeAll()
        for e in run { e() }
        syncFocus()
    }

    private func beginPass() {
        generation += 1
        visitedStates.removeAll(keepingCapacity: true)
        usedWidgets.removeAll(keepingCapacity: true)
        visitedAppear.removeAll(keepingCapacity: true)
        visitedTasks.removeAll(keepingCapacity: true)
        visitedPresentations.removeAll(keepingCapacity: true)
        visitedInteractions.removeAll(keepingCapacity: true)
    }

    /// Resolves the whole tree, reusing scopes whose input didn't change.
    private func resolveFromRoot() {
        fullResolves += 1
        beginPass()
        shortcuts.removeAll()
        defaultAction = nil
        cancelAction = nil
        readsGeometry = false
        rootDirty = false
        dirtyScopes.removeAll()

        var env = baseEnvironment
        env.colorScheme = backend.colorScheme == .dark ? .dark : .light
        env._host = self
        rootScope.ownKeys.removeAll(keepingCapacity: true)
        rootScope.children.removeAll(keepingCapacity: true)
        rootScope.generation = generation
        rootScope.dirty = false
        rootScope.containsDirty = false
        let ctx = ResolveContext(host: self, env: env, path: "", scope: rootScope)
        currentScope = rootScope
        LayoutNode.buildingScope = rootScope

        // Reads outside any scope (a primitive root reading a model) and,
        // merged in by Observation, every scope's reads re-resolve the root.
        let nodes = withObservationTracking {
            root(ctx)
        } onChange: { [weak self] in
            let host = UncheckedBox(self)
            if Thread.isMainThread {
                MainActor.assumeIsolated { host.value?.invalidate() }
            } else {
                Task { @MainActor in host.value?.invalidate() }
            }
        }
        currentScope = nil
        lastRoot = nodes.count == 1 ? nodes[0] : StackNode(axis: .vertical, alignment: .center, spacing: nil, children: nodes)
        LayoutNode.buildingScope = nil
        pendingGC = .full
    }

    /// Runs just the bodies of dirty scopes and splices their output into
    /// the tree. False when that can't be done (a scope's output changed
    /// shape, or it registers window-level actions): resolve from the root.
    private func spliceDirtyScopes() -> Bool {
        let dirty = dirtyScopes
        dirtyScopes.removeAll()
        // The outermost dirty scopes still in the tree.
        let tops = dirty.filter { s in
            guard s.dirty, scopes[s.path] === s, s.input != nil else { return false }
            var p = s.parent
            while let q = p { if q.dirty { return false }; p = q.parent }
            return true
        }
        guard !tops.isEmpty else { return dirty.allSatisfy { !$0.dirty || scopes[$0.path] !== $0 } }
        beginPass()
        var oldKeys: [StorageKey] = []
        var oldScopes: [Scope] = []
        for d in tops {
            guard !d.volatile, let input = d.input else { return false }
            collect(d, keys: &oldKeys, scopes: &oldScopes)
            d.generation = generation
            let stamp = effectStamp
            let nodes = runBody(d, input)
            guard nodes.count == d.proxies.count, effectStamp == stamp, !d.volatile else { return false }
            for (p, n) in zip(d.proxies, nodes) { p.retarget(n) }
            // Its size may have changed: everything above it measures again.
            var a = d.parent
            while let s = a { s.layoutEpoch += 1; a = s.parent }
            splices += 1
        }
        pendingGC = .partial(keys: oldKeys, scopes: oldScopes)
        return true
    }

    private func collect(_ s: Scope, keys: inout [StorageKey], scopes list: inout [Scope]) {
        keys += s.ownKeys
        for c in s.children { list.append(c); collect(c, keys: &keys, scopes: &list) }
    }

    /// Releases what the last resolve no longer reached.
    private func collectGarbage() {
        switch pendingGC {
        case .none:
            return
        case .full:
            for (key, (_, w)) in widgets where !usedWidgets.contains(key) {
                destroy(w)
                widgets[key] = nil
            }
            for key in states.keys where !visitedStates.contains(key) { states[key] = nil }
            for key in lastValues.keys where !visitedStates.contains(key) { lastValues[key] = nil }
            for (key, a) in appeared where !visitedAppear.contains(key) {
                appeared[key] = nil
                effects += a.onDisappear
            }
            for (key, t) in tasks where !visitedTasks.contains(key) {
                t.task.cancel()
                tasks[key] = nil
            }
            for (key, p) in presentations where !visitedPresentations.contains(key) {
                presentations[key] = nil
                p.dismissWindow()
            }
            for key in interactions.keys where !visitedInteractions.contains(key) { interactions[key] = nil }
            for (key, s) in scopes where s.generation != generation { scopes[key] = nil }
            for (key, r) in committed where r.generation != commitGeneration { committed[key] = nil }
        case let .partial(keys, oldScopes):
            for k in keys {
                switch k.kind {
                case .widget:
                    if !usedWidgets.contains(k.key), let (_, w) = widgets[k.key] { destroy(w); widgets[k.key] = nil }
                case .state:
                    if !visitedStates.contains(k.key) { states[k.key] = nil }
                case .value:
                    if !visitedStates.contains(k.key) { lastValues[k.key] = nil }
                case .appear:
                    if !visitedAppear.contains(k.key), let a = appeared[k.key] { appeared[k.key] = nil; effects += a.onDisappear }
                case .task:
                    if !visitedTasks.contains(k.key), let t = tasks[k.key] { t.task.cancel(); tasks[k.key] = nil }
                case .presentation:
                    if !visitedPresentations.contains(k.key), let p = presentations[k.key] { presentations[k.key] = nil; p.dismissWindow() }
                case .interaction:
                    if !visitedInteractions.contains(k.key) { interactions[k.key] = nil }
                }
            }
            for s in oldScopes where s.generation != generation && scopes[s.path] === s { scopes[s.path] = nil }
        }
        pendingGC = .none
    }

    // MARK: Committing

    final class CommitRecord {
        let container: NativeWidget
        var children: [(NativeWidget, CGRect)]
        var contentSize: CGSize
        var generation: Int
        init(container: NativeWidget, children: [(NativeWidget, CGRect)], contentSize: CGSize, generation: Int) {
            self.container = container; self.children = children; self.contentSize = contentSize; self.generation = generation
        }
    }

    /// Sends a container's children to the toolkit unless they and their
    /// frames are what it already has.
    func commit(_ container: NativeWidget, _ children: [(NativeWidget, CGRect)], contentSize: CGSize) {
        let id = ObjectIdentifier(container)
        if let r = committed[id], r.container === container {
            r.generation = commitGeneration
            if r.contentSize == contentSize, r.children.count == children.count,
               zip(r.children, children).allSatisfy({ $0.0 === $1.0 && $0.1 == $1.1 }) {
                return
            }
            r.children = children
            r.contentSize = contentSize
        } else {
            committed[id] = CommitRecord(container: container, children: children, contentSize: contentSize, generation: commitGeneration)
        }
        backend.setChildren(container, children, contentSize: contentSize)
    }

    private static var firstFrameReported = false
    private func reportRender(since start: Double, phases: [Double]) {
        defer { LayoutNode.sizeCalls = 0; LayoutNode.sizeMisses = 0; LayoutNode.measures = 0 }
        let ms = RunwayMetrics.monoMillis() - start
        let f = { (v: Double) in String(format: "%.3f", v) }
        RunwayMetrics.log("render", [("n", renderCount), ("ms", f(ms)), ("resolve", f(phases[0])), ("measure", f(phases[1])), ("place", f(phases[2])),
                                     ("bodies", bodiesRun), ("full", fullResolves), ("splices", splices),
                                     ("sizes", LayoutNode.sizeCalls), ("misses", LayoutNode.sizeMisses), ("measures", LayoutNode.measures),
                                     ("widgets", widgets.count), ("states", states.count), ("scopes", scopes.count)])
        // The first window's first frame: once GTK has had a turn to lay
        // out and paint what this render committed.
        if window != nil, !Self.firstFrameReported {
            Self.firstFrameReported = true
            backend.schedule { RunwayMetrics.log("first-frame", [("wall", String(format: "%.1f", RunwayMetrics.wallMillis()))]) }
        }
    }

    /// The root's ideal size (what a window sized to content uses).
    /// Resolves the tree if needed, but doesn't place it.
    public func idealSize() -> CGSize {
        if lastRoot == nil || rootDirty { resolveFromRoot() }
        return lastRoot.map(idealSize) ?? .zero
    }

    private func idealSize(_ node: LayoutNode) -> CGSize {
        node.size(.unspecified)
    }

    /// Handles a key press: shortcuts first, then Return and Escape.
    public func handleKey(_ key: RunwayCore.KeyPress) -> Bool {
        // The focused view and the views around it see a key first.
        if let path = keyFocusPath, dispatchKey(key, from: path) { return true }
        for (k, action) in shortcuts where k == key { action(); return true }
        if key.key == "return", !key.command, let a = defaultAction { a(); return true }
        if key.key == "escape", let a = cancelAction { a(); return true }
        return false
    }

    /// Cancels tasks, closes presentations and releases the native widgets
    /// (the window is going away).
    public func tearDown() {
        for (_, t) in tasks { t.task.cancel() }
        tasks.removeAll()
        for (_, a) in appeared { a.onDisappear.forEach { $0() } }
        appeared.removeAll()
        for (_, p) in presentations { p.dismissWindow() }
        presentations.removeAll()
        for (_, (_, w)) in widgets { destroy(w) }
        widgets.removeAll()
        committed.removeAll()
        scopes.removeAll()
        states.removeAll()
        lastRoot = nil
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    weak var object: AnyObject?
    init(_ v: T?) { object = v as AnyObject? }
    var value: T? { object as? T }
}

/// A scope to invalidate from Observation's (Sendable) change callback.
struct UncheckedScopeRef: @unchecked Sendable {
    weak var host: ViewHost?
    weak var scope: Scope?
    @MainActor func invalidate() {
        guard let host else { return }
        if let scope { host.invalidate(scope: scope) } else { host.invalidate() }
    }
}

/// Collects the placements for one native container and commits them.
@MainActor final class PlacementSink {
    let container: NativeWidget
    let backend: Backend
    weak var host: ViewHost?
    var offset: CGPoint = .zero
    var drawingTransform: CGAffineTransform = .identity
    /// The enclosing scroll view's document, and this container's origin in it.
    weak var scrollDocument: NativeWidget?
    var documentOrigin: CGPoint = .zero
    /// This container's origin in the host's root container (as currently
    /// scrolled).
    var hostOrigin: CGPoint = .zero
    var items: [(NativeWidget, CGRect)] = []
    init(container: NativeWidget, backend: Backend, host: ViewHost? = nil) { self.container = container; self.backend = backend; self.host = host }

    func add(_ widget: NativeWidget, _ frame: CGRect) {
        items.append((widget, frame.offsetBy(dx: -offset.x, dy: -offset.y).integralRounded))
    }

    /// A sink for a nested native container whose origin is `frame.origin`.
    func nested(_ container: NativeWidget, origin: CGPoint) -> PlacementSink {
        let s = PlacementSink(container: container, backend: backend, host: host)
        s.offset = origin
        s.scrollDocument = scrollDocument
        s.documentOrigin = documentOrigin
        s.hostOrigin = hostOrigin
        return s
    }

    func commit(contentSize: CGSize) {
        if let host { host.commit(container, items, contentSize: contentSize) } else { backend.setChildren(container, items, contentSize: contentSize) }
    }
}

extension CGRect {
    var integralRounded: CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: max(0, width.rounded()), height: max(0, height.rounded()))
    }
}

// MARK: Field layouts

/// How a dynamic property compares when deciding whether a view's input
/// changed. State and environment-like properties hold no input of their
/// own (their values live in the graph and invalidate it themselves).
protocol MemoComparable {
    static func memoEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool
}

/// A type's stored fields, worked out once from the runtime's metadata:
/// where its dynamic properties are (to link them without Mirror), and how
/// to compare two values of it.
@MainActor final class FieldLayout {
    enum Compare {
        case ignore
        case never
        case equatable((UnsafeRawPointer, UnsafeRawPointer) -> Bool)
        case bytes(Int)
        case fields(FieldLayout)
        case custom((UnsafeRawPointer, UnsafeRawPointer) -> Bool)
    }
    struct Field { let offset: Int; let compare: Compare }
    struct Link { let offset: Int; let label: String; let load: (UnsafeRawPointer) -> Any }

    /// Reflected as a struct (its fields are known).
    private(set) var isStruct = false
    private(set) var fields: [Field] = []
    private(set) var links: [Link] = []
    /// How the type as a whole compares (never equal while being worked out).
    private(set) var compare: Compare = .never

    private static var cache: [ObjectIdentifier: FieldLayout] = [:]

    static func of<T>(_ type: T.Type) -> FieldLayout { of(any: type, depth: 0) }

    static func of(any type: Any.Type, depth: Int) -> FieldLayout {
        if let l = cache[ObjectIdentifier(type)] { return l }
        let l = FieldLayout()
        cache[ObjectIdentifier(type)] = l
        l.build(type, depth: depth)
        return l
    }

    private static func size(_ type: Any.Type) -> Int {
        func size<T>(_: T.Type) -> Int { MemoryLayout<T>.size }
        return _openExistential(type, do: size)
    }

    private func build(_ type: Any.Type, depth: Int) {
        // Fields first: dynamic properties to link, and a fallback compare.
        var collected: [Field] = []
        var linked: [Link] = []
        let isClass = type is AnyClass
        var reflected = !isClass && _forEachField(of: type, options: [.ignoreUnknown]) { name, offset, fieldType, kind in
            if fieldType is DynamicPropertyLink.Type || fieldType is DynamicProperty.Type {
                linked.append(Link(offset: offset, label: String(cString: name), load: Self.loader(fieldType)))
            }
            let c: Compare
            if let m = fieldType as? MemoComparable.Type {
                c = .custom(m.memoEqual)
            } else if kind == .class || kind == .foreignClass || kind == .objcClassWrapper {
                c = .bytes(Self.size(fieldType))      // identity
            } else if let eq = fieldType as? any Equatable.Type {
                c = .equatable(Self.equality(eq))
            } else if kind == .struct, depth < 4 {
                c = FieldLayout.of(any: fieldType, depth: depth + 1).compare
            } else {
                c = .bytes(Self.size(fieldType))      // closures, enums, existentials: bitwise
            }
            collected.append(Field(offset: offset, compare: c))
            return true
        }
        // Enums (Optional among them) reflect as having no fields, which
        // would make all their values equal; a struct with no fields has
        // no size.
        if reflected, collected.isEmpty, Self.size(type) > 0 { reflected = false }
        if reflected {
            isStruct = true
            fields = collected
            links = linked
        }
        if let m = type as? MemoComparable.Type {
            compare = .custom(m.memoEqual)
        } else if isClass {
            compare = .bytes(Self.size(type))
        } else if let eq = type as? any Equatable.Type {
            compare = .equatable(Self.equality(eq))
        } else if reflected {
            compare = collected.isEmpty ? .ignore : .fields(self)
        } else {
            compare = .bytes(Self.size(type))
        }
    }

    private static func equality<E: Equatable>(_: E.Type) -> (UnsafeRawPointer, UnsafeRawPointer) -> Bool {
        { a, b in a.assumingMemoryBound(to: E.self).pointee == b.assumingMemoryBound(to: E.self).pointee }
    }

    private static func loader(_ type: Any.Type) -> (UnsafeRawPointer) -> Any {
        func make<T>(_: T.Type) -> (UnsafeRawPointer) -> Any { { $0.assumingMemoryBound(to: T.self).pointee } }
        return _openExistential(type, do: make)
    }

    func equal(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool {
        for f in fields where !Self.compare(f.compare, a + f.offset, b + f.offset) { return false }
        return true
    }

    static func compare(_ c: Compare, _ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool {
        switch c {
        case .ignore: return true
        case .never: return false
        case let .equatable(f), let .custom(f): return f(a, b)
        case let .bytes(n): return n == 0 || memcmp(a, b, n) == 0
        case let .fields(l): return l.equal(a, b)
        }
    }

    /// Whether two values of a type are the same input to a view.
    static func equal<T>(_ a: T, _ b: T) -> Bool {
        let c = of(T.self).compare
        return withUnsafeBytes(of: a) { pa in
            withUnsafeBytes(of: b) { pb in
                guard let x = pa.baseAddress, let y = pb.baseAddress else { return true }
                return compare(c, x, y)
            }
        }
    }

    /// The same for two values only known as `Any` (environment values).
    static func equalAny(_ a: Any, _ b: Any) -> Bool {
        func open<A>(_ a: A) -> Bool {
            guard let b = b as? A else { return false }
            return equal(a, b)
        }
        return _openExistential(a, do: open)
    }
}
