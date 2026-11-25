// View modifiers: layout (padding, frame, fixedSize, overlay, background…),
// lifecycle (onAppear, onChange, task), gestures, and the many that only
// matter to Apple's renderer (accessibility, animation, glass), accepted
// so code compiles unchanged.

import Foundation
import RunwayCore

// MARK: ViewModifier

public protocol ViewModifier {
    associatedtype Body: View
    typealias Content = _ViewModifier_Content<Self>
    @ViewBuilder @MainActor func body(content: Content) -> Body
}

public struct _ViewModifier_Content<Modifier: ViewModifier>: View, PrimitiveView {
    public typealias Body = Never
    let resolveContent: @MainActor (ResolveContext) -> [LayoutNode]
    func resolve(in ctx: ResolveContext) -> [LayoutNode] { resolveContent(ctx) }
}

public struct ModifiedContent<Content, Modifier>: PrimitiveView {
    public var content: Content
    public var modifier: Modifier
    public init(content: Content, modifier: Modifier) { self.content = content; self.modifier = modifier }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        guard let view = content as? any View else { return [] }
        if let m = modifier as? any ViewModifier { return resolveModifier(m, view, ctx) }
        return ctx.resolveAny(view, "c")
    }
    private func resolveModifier<M: ViewModifier>(_ m: M, _ view: any View, _ ctx: ResolveContext) -> [LayoutNode] {
        var c = ctx
        c.path += ":" + String(describing: M.self)
        c.host.link(m, c)
        let inner = _ViewModifier_Content<M>(resolveContent: { cc in cc.resolveAny(view, "content") })
        return c.resolve(m.body(content: inner), "mod")
    }
}

extension ModifiedContent: View where Content: View, Modifier: ViewModifier {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

extension View {
    public func modifier<M: ViewModifier>(_ modifier: M) -> ModifiedContent<Self, M> { ModifiedContent(content: self, modifier: modifier) }
}

public struct EmptyModifier: ViewModifier {
    public static let identity = EmptyModifier()
    public init() {}
    public func body(content: Content) -> some View { content }
}

/// A modifier resolved by a closure over the content's nodes.
struct NodeModifier<Content: View>: View, PrimitiveView {
    typealias Body = Never
    let content: Content
    let name: String
    let transform: @MainActor ([LayoutNode], ResolveContext) -> [LayoutNode]
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let c = ctx.child(name)
        return transform(c.resolve(content, "c"), c)
    }
}

extension View {
    func nodes(_ name: String, _ transform: @escaping @MainActor ([LayoutNode], ResolveContext) -> [LayoutNode]) -> some View {
        NodeModifier(content: self, name: name, transform: transform)
    }
    func eachNode(_ name: String, _ transform: @escaping @MainActor (LayoutNode, ResolveContext) -> LayoutNode) -> some View {
        nodes(name) { ns, ctx in ns.map { transform($0, ctx) } }
    }
}

// MARK: Layout

extension View {
    public func padding(_ insets: EdgeInsets) -> some View { eachNode("pad") { n, _ in PaddingNode(insets, n) } }
    public func padding(_ length: CGFloat? = nil) -> some View { padding(.all, length) }
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View {
        let l = length ?? 16
        return padding(EdgeInsets(top: edges.contains(.top) ? l : 0, leading: edges.contains(.leading) ? l : 0,
                                  bottom: edges.contains(.bottom) ? l : 0, trailing: edges.contains(.trailing) ? l : 0))
    }

    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        eachNode("frame") { n, _ in
            let f = FrameNode(child: n, alignment: alignment)
            f.width = width
            f.height = height
            return f
        }
    }

    public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil,
                      minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil,
                      alignment: Alignment = .center) -> some View {
        eachNode("frame") { n, _ in
            let f = FrameNode(child: n, alignment: alignment)
            (f.minWidth, f.idealWidth, f.maxWidth) = (minWidth, idealWidth, maxWidth)
            (f.minHeight, f.idealHeight, f.maxHeight) = (minHeight, idealHeight, maxHeight)
            return f
        }
    }

    public func fixedSize() -> some View { fixedSize(horizontal: true, vertical: true) }
    public func fixedSize(horizontal: Bool, vertical: Bool) -> some View {
        eachNode("fixed") { n, _ in FixedSizeNode(n, horizontal: horizontal, vertical: vertical) }
    }

    public func layoutPriority(_ value: Double) -> some View { eachNode("prio") { n, _ in PriorityNode(n, value) } }

    public func aspectRatio(_ ratio: CGFloat? = nil, contentMode: ContentMode) -> some View {
        eachNode("aspect") { n, _ in AspectRatioNode(n, ratio: ratio, mode: contentMode) }
    }
    public func aspectRatio(_ size: CGSize, contentMode: ContentMode) -> some View {
        aspectRatio(size.height > 0 ? size.width / size.height : 1, contentMode: contentMode)
    }
    public func scaledToFit() -> some View { aspectRatio(nil, contentMode: .fit) }
    public func scaledToFill() -> some View { aspectRatio(nil, contentMode: .fill) }

    public func offset(_ offset: CGSize) -> some View { eachNode("offset") { n, _ in OffsetNode(n, offset) } }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View { offset(CGSize(width: x, height: y)) }
    public func position(x: CGFloat = 0, y: CGFloat = 0) -> some View { offset(x: x, y: y) }
    public func position(_ p: CGPoint) -> some View { offset(x: p.x, y: p.y) }

    public func overlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        layered(content(), alignment: alignment, behind: false)
    }
    @_disfavoredOverload public func overlay<V: View>(_ overlay: V, alignment: Alignment = .center) -> some View { layered(overlay, alignment: alignment, behind: false) }
    public func overlay<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges: Edge.Set = .all) -> some View {
        layered(_ShapeView(shape: Rectangle(), style: AnyShapeStyle(style), stroke: nil), alignment: .center, behind: false)
    }
    public func overlay<S: ShapeStyle, T: Shape>(_ style: S, in shape: T) -> some View {
        layered(_ShapeView(shape: shape, style: AnyShapeStyle(style), stroke: nil), alignment: .center, behind: false)
    }
    public func background<V: View>(alignment: Alignment = .center, @ViewBuilder content: () -> V) -> some View {
        layered(content(), alignment: alignment, behind: true)
    }
    @_disfavoredOverload public func background<V: View>(_ background: V, alignment: Alignment = .center) -> some View { layered(background, alignment: alignment, behind: true) }
    public func background<S: ShapeStyle>(_ style: S, ignoresSafeAreaEdges edges: Edge.Set = .all) -> some View {
        layered(_ShapeView(shape: Rectangle(), style: AnyShapeStyle(style), stroke: nil), alignment: .center, behind: true)
    }
    public func background<S: ShapeStyle, T: Shape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle()) -> some View {
        layered(_ShapeView(shape: shape, style: AnyShapeStyle(style), stroke: nil), alignment: .center, behind: true)
    }
    public func background<T: Shape>(in shape: T, fillStyle: FillStyle = FillStyle()) -> some View {
        layered(_ShapeView(shape: shape, style: AnyShapeStyle(BackgroundStyle()), stroke: nil), alignment: .center, behind: true)
    }
    public func border<S: ShapeStyle>(_ content: S, width: CGFloat = 1) -> some View {
        layered(Rectangle().strokeBorder(content, lineWidth: width), alignment: .center, behind: false)
    }

    func layered<V: View>(_ other: V, alignment: Alignment, behind: Bool) -> some View {
        nodes(behind ? "bg" : "ov") { ns, ctx in
            let extra = ctx.with { $0._stackAxis = nil }.resolve(other, "layer")
            guard !ns.isEmpty else { return [] }
            let primary: LayoutNode = ns.count == 1 ? ns[0] : StackNode(axis: ctx.env._stackAxis ?? .vertical, alignment: .center, spacing: nil, children: ns)
            let layer = LayerNode(primary: primary, secondary: extra, alignment: alignment, behind: behind)
            return [navigationBackdrop(layer, background: other, in: ctx)]
        }
    }

    /// Clips to the bounds (a clipping native container).
    public func clipped(antialiased: Bool = false) -> some View {
        nodes("clip") { ns, ctx in
            let w = ctx.widget(.container, "clip")
            var p = WidgetProps()
            p.clips = true
            if let w { ctx.host.backend.update(w, props: p, events: WidgetEvents()) }
            let inner: LayoutNode = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            return [ContainerNode(widget: w, backend: ctx.host.backend, content: inner, sizing: .hug)]
        }
    }
    public func clipShape<S: Shape>(_ shape: S, style: FillStyle = FillStyle()) -> some View { clipped() }
    public func cornerRadius(_ radius: CGFloat, antialiased: Bool = true) -> some View { clipped() }
    public func mask<M: View>(alignment: Alignment = .center, @ViewBuilder _ mask: () -> M) -> some View { self }
    public func mask<M: View>(_ mask: M) -> some View { self }

    public func hidden() -> some View { environment { $0._opacity = 0; $0.isEnabled = false } }
    public func zIndex(_ value: Double) -> some View { self }
    public func ignoresSafeArea(_ regions: SafeAreaRegions = .all, edges: Edge.Set = .all) -> some View { self }
    public func edgesIgnoringSafeArea(_ edges: Edge.Set) -> some View { self }
    public func safeAreaInset<V: View>(edge: VerticalEdge, alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> some View {
        let extra = content()
        return VStack(spacing: spacing ?? 0) {
            if edge == .top { extra }
            self
            if edge == .bottom { extra }
        }
    }
    public func safeAreaPadding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View { padding(edges, length) }
    public func containerRelativeFrame(_ axes: Axis.Set, alignment: Alignment = .center) -> some View {
        frame(maxWidth: axes.contains(.horizontal) ? .infinity : nil, maxHeight: axes.contains(.vertical) ? .infinity : nil, alignment: alignment)
    }
}

public enum VerticalEdge: Hashable, Sendable { case top, bottom }
public enum HorizontalEdge: Hashable, Sendable { case leading, trailing }
public struct SafeAreaRegions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let all = SafeAreaRegions(rawValue: 7)
    public static let container = SafeAreaRegions(rawValue: 1)
    public static let keyboard = SafeAreaRegions(rawValue: 2)
}

// MARK: Lifecycle

extension View {
    public func onAppear(perform action: (() -> Void)? = nil) -> some View {
        nodes("appear") { ns, ctx in
            if !ctx.dryRun { ctx.host.appear(ctx.path, onAppear: action, onDisappear: nil) }
            return ns
        }
    }
    public func onDisappear(perform action: (() -> Void)? = nil) -> some View {
        nodes("disappear") { ns, ctx in
            if !ctx.dryRun { ctx.host.appear(ctx.path, onAppear: nil, onDisappear: action) }
            return ns
        }
    }
    public func task(priority: TaskPriority = .userInitiated, _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        nodes("task") { ns, ctx in
            if !ctx.dryRun { ctx.host.task(ctx.path, id: nil, priority: priority, action) }
            return ns
        }
    }
    public func task<T: Equatable>(id value: T, priority: TaskPriority = .userInitiated, _ action: @escaping @MainActor @Sendable () async -> Void) -> some View {
        nodes("task") { ns, ctx in
            if !ctx.dryRun { ctx.host.task(ctx.path, id: AnyHashable(String(describing: value)), priority: priority, action) }
            return ns
        }
    }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping () -> Void) -> some View {
        nodes("change") { ns, ctx in
            if !ctx.dryRun { ctx.host.change(ctx.path, value: value, initial: initial) { _, _ in action() } }
            return ns
        }
    }
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void) -> some View {
        nodes("change") { ns, ctx in
            if !ctx.dryRun { ctx.host.change(ctx.path, value: value, initial: initial, action) }
            return ns
        }
    }
    @available(*, deprecated)
    public func onChange<V: Equatable>(of value: V, perform action: @escaping (_ newValue: V) -> Void) -> some View {
        nodes("change") { ns, ctx in
            if !ctx.dryRun { ctx.host.change(ctx.path, value: value, initial: false) { _, n in action(n) } }
            return ns
        }
    }

    // MARK: Gestures

    public func onTapGesture(count: Int = 1, perform action: @escaping () -> Void) -> some View {
        tapArea(count: count, action: action)
    }
    /// The preview backends deliver the position in the tapped view's local coordinates.
    public func onTapGesture(count: Int = 1, coordinateSpace: CoordinateSpace = .local, perform action: @escaping (CGPoint) -> Void) -> some View {
        tapArea(count: count, spatialAction: action)
    }
    private func tapArea(count: Int = 1, action: (() -> Void)? = nil, spatialAction: ((CGPoint) -> Void)? = nil) -> some View {
        nodes("tap") { ns, ctx in
            let w = ctx.widget(.tapArea, "tap")
            var events = WidgetEvents()
            events.onTap = action
            events.onTapLocation = spatialAction
            var p = ctx.baseProps()
            p.tapCount = max(1, count)
            if let w { ctx.host.backend.update(w, props: p, events: events) }
            let inner: LayoutNode = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            let node = ContainerNode(widget: w, backend: ctx.host.backend, content: inner, sizing: .hug)
            node.layoutPriority = inner.layoutPriority
            return [node]
        }
    }
    public func onLongPressGesture(minimumDuration: Double = 0.5, perform action: @escaping () -> Void) -> some View { self }
    public func onDrag(_ data: @escaping () -> NSItemProvider) -> some View { self }
    public func onDrag<V: View>(_ data: @escaping () -> NSItemProvider, @ViewBuilder preview: () -> V) -> some View { self }
    public func onOpenURL(perform action: @escaping (URL) -> Void) -> some View { self }
    public func onExitCommand(perform action: (() -> Void)?) -> some View {
        nodes("exit") { ns, ctx in
            if let action, !ctx.dryRun { ctx.host.cancelAction = ctx.host.cancelAction ?? action }
            return ns
        }
    }
    public func onCommand(_ selector: Any, perform action: (() -> Void)?) -> some View { self }
    public func onDeleteCommand(perform action: (() -> Void)?) -> some View { self }
    public func onMoveCommand(perform action: ((MoveCommandDirection) -> Void)?) -> some View { self }
}

public enum HoverPhase: Sendable { case active(CGPoint), ended }
public enum MoveCommandDirection: Sendable { case up, down, left, right }

// MARK: Effects only Apple's renderer draws (accepted, no-ops)

public struct Animation: Hashable, Sendable {
    public static let `default` = Animation()
    public static let linear = Animation(), easeIn = Animation(), easeOut = Animation(), easeInOut = Animation(), spring = Animation(), bouncy = Animation(), smooth = Animation(), snappy = Animation(), interactiveSpring = Animation()
    public static func linear(duration: Double) -> Animation { Animation() }
    public static func easeIn(duration: Double) -> Animation { Animation() }
    public static func easeOut(duration: Double) -> Animation { Animation() }
    public static func easeInOut(duration: Double) -> Animation { Animation() }
    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.8, blendDuration: Double = 0) -> Animation { Animation() }
    public static func spring(duration: Double = 0.5, bounce: Double = 0, blendDuration: Double = 0) -> Animation { Animation() }
    public static func snappy(duration: Double = 0.5, extraBounce: Double = 0) -> Animation { Animation() }
    public static func smooth(duration: Double = 0.5, extraBounce: Double = 0) -> Animation { Animation() }
    public static func bouncy(duration: Double = 0.5, extraBounce: Double = 0) -> Animation { Animation() }
    public func delay(_ d: Double) -> Animation { self }
    public func speed(_ s: Double) -> Animation { self }
    public func repeatForever(autoreverses: Bool = true) -> Animation { self }
    public func repeatCount(_ n: Int, autoreverses: Bool = true) -> Animation { self }
}

/// Runs the body at once: state changes re-render without animation.
@discardableResult
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result { try body() }

/// When an animation counts as complete.
public struct AnimationCompletionCriteria: Hashable, Sendable {
    let name: String
    public static let logicallyComplete = AnimationCompletionCriteria(name: "logicallyComplete")
    public static let removed = AnimationCompletionCriteria(name: "removed")
}

/// Changes apply at once here, so the completion follows on the next turn of the main queue.
public func withAnimation<Result>(_ animation: Animation? = .default, completionCriteria: AnimationCompletionCriteria = .logicallyComplete,
                                  _ body: () throws -> Result, completion: @escaping () -> Void) rethrows -> Result {
    let result = try body()
    DispatchQueue.main.async(execute: completion)
    return result
}
@discardableResult
public func withTransaction<Result>(_ transaction: Transaction, _ body: () throws -> Result) rethrows -> Result { try body() }

public struct AnyTransition: Sendable {
    public static let identity = AnyTransition(), opacity = AnyTransition(), scale = AnyTransition(), slide = AnyTransition()
    public static func move(edge: Edge) -> AnyTransition { AnyTransition() }
    public static func push(from edge: Edge) -> AnyTransition { AnyTransition() }
    public static func offset(x: CGFloat = 0, y: CGFloat = 0) -> AnyTransition { AnyTransition() }
    public static func scale(scale: CGFloat, anchor: UnitPoint = .center) -> AnyTransition { AnyTransition() }
    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition { AnyTransition() }
    public func combined(with other: AnyTransition) -> AnyTransition { self }
    public func animation(_ a: Animation?) -> AnyTransition { self }
}

public struct ContentTransition: Sendable {
    public static let identity = ContentTransition(), opacity = ContentTransition(), interpolate = ContentTransition(), symbolEffect = ContentTransition()
    public static func numericText(countsDown: Bool = false) -> ContentTransition { ContentTransition() }
    public static func numericText(value: Double) -> ContentTransition { ContentTransition() }
    /// A symbol effect (`.replace`…) between a symbol image's states.
    public static func symbolEffect<T: SymbolEffect>(_ effect: T, options: SymbolEffectOptions = .default) -> ContentTransition { ContentTransition() }
}

public struct Glass: Sendable {
    public static let regular = Glass(), clear = Glass(), identity = Glass()
    public func tint(_ c: Color?) -> Glass { self }
    public func interactive(_ on: Bool = true) -> Glass { self }
}

public struct ScrollEdgeEffectStyle: Sendable {
    public static let automatic = ScrollEdgeEffectStyle(), hard = ScrollEdgeEffectStyle(), soft = ScrollEdgeEffectStyle()
}

public struct ScrollBounceBehavior: Sendable {
    public static let automatic = ScrollBounceBehavior(), always = ScrollBounceBehavior(), basedOnSize = ScrollBounceBehavior()
}

public protocol SymbolEffect {}
public struct _SymbolEffect: SymbolEffect, Sendable {
    public var byLayer: _SymbolEffect { self }
    public var wholeSymbol: _SymbolEffect { self }
    public var up: _SymbolEffect { self }
    public var down: _SymbolEffect { self }
    public var reversing: _SymbolEffect { self }
    public var iterative: _SymbolEffect { self }
    public var cumulative: _SymbolEffect { self }
    public var nonReversing: _SymbolEffect { self }
}
extension SymbolEffect where Self == _SymbolEffect {
    public static var pulse: _SymbolEffect { _SymbolEffect() }
    public static var bounce: _SymbolEffect { _SymbolEffect() }
    public static var variableColor: _SymbolEffect { _SymbolEffect() }
    public static var breathe: _SymbolEffect { _SymbolEffect() }
    public static var wiggle: _SymbolEffect { _SymbolEffect() }
    public static var rotate: _SymbolEffect { _SymbolEffect() }
    public static var appear: _SymbolEffect { _SymbolEffect() }
    public static var disappear: _SymbolEffect { _SymbolEffect() }
    public static var scale: _SymbolEffect { _SymbolEffect() }
    public static var replace: _SymbolEffect { _SymbolEffect() }
}

public struct SymbolEffectOptions: Sendable {
    public static let `default` = SymbolEffectOptions(), repeating = SymbolEffectOptions(), nonRepeating = SymbolEffectOptions()
    public static func `repeat`(_ n: Int) -> SymbolEffectOptions { SymbolEffectOptions() }
    public static func speed(_ s: Double) -> SymbolEffectOptions { SymbolEffectOptions() }
    public func speed(_ s: Double) -> SymbolEffectOptions { self }
}

public struct AccessibilityTraits: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let isButton = AccessibilityTraits(rawValue: 1), isHeader = AccessibilityTraits(rawValue: 2), isSelected = AccessibilityTraits(rawValue: 4)
    public static let isModal = AccessibilityTraits(rawValue: 256), isSearchField = AccessibilityTraits(rawValue: 512), isSummaryElement = AccessibilityTraits(rawValue: 1024)
    public static let playsSound = AccessibilityTraits(rawValue: 2048), startsMediaSession = AccessibilityTraits(rawValue: 4096), allowsDirectInteraction = AccessibilityTraits(rawValue: 8192)
    public static let causesPageTurn = AccessibilityTraits(rawValue: 16384), isKeyboardKey = AccessibilityTraits(rawValue: 32768), isTabBar = AccessibilityTraits(rawValue: 65536)
    public static let isLink = AccessibilityTraits(rawValue: 8), isImage = AccessibilityTraits(rawValue: 16), isStaticText = AccessibilityTraits(rawValue: 32)
    public static let updatesFrequently = AccessibilityTraits(rawValue: 64), isToggle = AccessibilityTraits(rawValue: 128)
}

public struct AccessibilityChildBehavior: Sendable {
    public static let ignore = AccessibilityChildBehavior(), combine = AccessibilityChildBehavior(), contain = AccessibilityChildBehavior()
}

public struct AccessibilityActionKind: Sendable {
    public static let `default` = AccessibilityActionKind(), escape = AccessibilityActionKind(), magicTap = AccessibilityActionKind()
    public init(named: Text) {}
    init() {}
}

public enum AccessibilityAdjustmentDirection: Sendable { case increment, decrement }

extension View {
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View { self }
    public func animation(_ animation: Animation?) -> some View { self }
    public func transition(_ t: AnyTransition) -> some View { self }
    public func contentTransition(_ t: ContentTransition) -> some View { self }
    public func symbolEffect<E: SymbolEffect>(_ effect: E, options: SymbolEffectOptions = .default, isActive: Bool = true) -> some View { self }
    public func symbolEffect<E: SymbolEffect, U: Equatable>(_ effect: E, options: SymbolEffectOptions = .default, value: U) -> some View { self }
    public func glassEffect(_ glass: Glass = .regular, in shape: some Shape = Capsule(), isEnabled: Bool = true) -> some View { self }
    public func glassEffectID<ID: Hashable>(_ id: ID, in namespace: Namespace.ID) -> some View { self }
    public func scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set) -> some View { self }
    public func scrollBounceBehavior(_ behavior: ScrollBounceBehavior, axes: Axis.Set = [.vertical]) -> some View { self }
    /// Text editors (and lists) inside draw no background of their own.
    public func scrollContentBackground(_ visibility: Visibility) -> some View { environment { $0._scrollContentBackgroundHidden = visibility == .hidden } }
    /// Scroll views inside hide their scroll bars (still scrolling by wheel and keys).
    public func scrollIndicators(_ visibility: ScrollIndicatorVisibility, axes: Axis.Set = [.vertical, .horizontal]) -> some View {
        environment { env in
            if axes.contains(.vertical) { env._scrollIndicatorsVertical = visibility }
            if axes.contains(.horizontal) { env._scrollIndicatorsHorizontal = visibility }
        }
    }
    public func scrollPosition<ID: Hashable>(id: Binding<ID?>, anchor: UnitPoint? = nil) -> some View { self }
    public func scrollTargetBehavior<T>(_ behavior: T) -> some View { self }
    public func scrollTargetLayout(isEnabled: Bool = true) -> some View { self }

    public func shadow(color: Color = Color(white: 0, opacity: 0.33), radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> some View { self }
    public func blur(radius: CGFloat, opaque: Bool = false) -> some View { self }
    public func brightness(_ amount: Double) -> some View { self }
    public func contrast(_ amount: Double) -> some View { self }
    public func saturation(_ amount: Double) -> some View { self }
    public func grayscale(_ amount: Double) -> some View { self }
    public func colorMultiply(_ color: Color) -> some View { self }
    public func colorInvert() -> some View { self }
    public func blendMode(_ mode: BlendMode) -> some View { self }
    public func compositingGroup() -> some View { self }
    public func drawingGroup(opaque: Bool = false) -> some View { self }
    public func rotationEffect(_ angle: Angle, anchor: UnitPoint = .center) -> some View {
        eachNode("rotation") { node, _ in
            DrawingRotationNode(child: node, rotation: ShapeRotation(angle: angle, anchor: anchor))
        }
    }
    public func rotation3DEffect(_ angle: Angle, axis: (x: CGFloat, y: CGFloat, z: CGFloat), anchor: UnitPoint = .center) -> some View { self }
    public func scaleEffect(_ s: CGFloat, anchor: UnitPoint = .center) -> some View { self }
    public func scaleEffect(_ s: CGSize, anchor: UnitPoint = .center) -> some View { self }
    public func scaleEffect(x: CGFloat = 1, y: CGFloat = 1, anchor: UnitPoint = .center) -> some View { self }
    public func matchedGeometryEffect<ID: Hashable>(id: ID, in namespace: Namespace.ID, isSource: Bool = true) -> some View { self }
    public func accessibilityLabel(_ label: Text) -> some View { self }
    public func accessibilityLabel(_ label: LocalizedStringKey) -> some View { self }
    @_disfavoredOverload public func accessibilityLabel<S: StringProtocol>(_ label: S) -> some View { self }
    public func accessibilityValue(_ value: Text) -> some View { self }
    public func accessibilityValue(_ value: LocalizedStringKey) -> some View { self }
    @_disfavoredOverload public func accessibilityValue<S: StringProtocol>(_ value: S) -> some View { self }
    public func accessibilityHint(_ hint: Text) -> some View { self }
    public func accessibilityHint(_ hint: LocalizedStringKey) -> some View { self }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View { self }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View { self }
    public func accessibilityRemoveTraits(_ traits: AccessibilityTraits) -> some View { self }
    public func accessibilityHidden(_ hidden: Bool) -> some View { self }
    public func accessibilityIdentifier(_ id: String) -> some View { self }
    public func accessibilityAction(_ kind: AccessibilityActionKind = .default, _ handler: @escaping () -> Void) -> some View { self }
    public func accessibilityAction(named name: Text, _ handler: @escaping () -> Void) -> some View { self }
    public func accessibilityAction(named name: LocalizedStringKey, _ handler: @escaping () -> Void) -> some View { self }
    public func accessibilityAdjustableAction(_ handler: @escaping (AccessibilityAdjustmentDirection) -> Void) -> some View { self }
    public func accessibilitySortPriority(_ p: Double) -> some View { self }
    public func textSelection<S: TextSelectability>(_ selectability: S) -> some View { environment { $0._textSelectable = S.allowsSelection } }
    @_disfavoredOverload public func textContentType(_ type: Any?) -> some View { self }
    public func autocorrectionDisabled(_ disabled: Bool = true) -> some View { self }
    public func privacySensitive(_ sensitive: Bool = true) -> some View { self }
    public func redacted(reason: RedactionReasons) -> some View { self }
    public func badge(_ count: Int) -> some View { self }
    public func badge(_ label: Text?) -> some View { self }
    public func listRowInsets(_ insets: EdgeInsets?) -> some View {
        listRowDecoration("listRowInsets", .insets(insets))
    }
    public func listRowBackground<V: View>(_ view: V?) -> some View {
        listRowDecoration("listRowBackground", .background(view.map { AnyView($0) }))
    }
    public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        listRowDecoration("listRowSeparator", .separator(visibility, edges))
    }
    public func listSectionSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View { self }
    public func interactiveDismissDisabled(_ disabled: Bool = true) -> some View { self }
    @_disfavoredOverload public func presentationDetents<S>(_ detents: S) -> some View { self }
    public func presentationSizing<S>(_ sizing: S) -> some View { self }
    public func presentationBackground<S: ShapeStyle>(_ style: S) -> some View { self }
    public func coordinateSpace(name: AnyHashable) -> some View { self }
    public func coordinateSpace<N>(_ name: N) -> some View { self }
    public func defaultFocus<V: Hashable>(_ binding: FocusState<V>.Binding, _ value: V) -> some View { self }
    public func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: Text? = nil) -> some View {
        VStack(spacing: 8) {
            TextField("Search", text: text, prompt: prompt ?? Text("Search")).padding(.horizontal, 8)
            self
        }
    }
    public func searchable(text: Binding<String>, placement: SearchFieldPlacement = .automatic, prompt: LocalizedStringKey) -> some View {
        searchable(text: text, placement: placement, prompt: Text(prompt))
    }
}

extension VerticalEdge {
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let top = Set(rawValue: 1), bottom = Set(rawValue: 2), all = Set(rawValue: 3)
    }
}

public struct SearchFieldPlacement: Sendable {
    public static let automatic = SearchFieldPlacement(), toolbar = SearchFieldPlacement(), sidebar = SearchFieldPlacement()
    public enum NavigationBarDrawerDisplayMode: Sendable { case automatic, always }
    public static func navigationBarDrawer(displayMode: NavigationBarDrawerDisplayMode = .automatic) -> Self { .automatic }
}

public struct RedactionReasons: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let placeholder = RedactionReasons(rawValue: 1), privacy = RedactionReasons(rawValue: 2)
}

public enum BlendMode: Sendable { case normal, multiply, screen, overlay, darken, lighten, plusLighter, plusDarker, difference, sourceAtop, destinationOut }

@propertyWrapper
public struct Namespace: DynamicProperty, Sendable {
    public struct ID: Hashable, Sendable { let raw = UUID() }
    public init() {}
    public var wrappedValue: ID { ID() }
}

public struct ScrollIndicatorVisibility: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case automatic, visible, hidden, never }
    let kind: Kind
    public static let automatic = Self(kind: .automatic), visible = Self(kind: .visible), hidden = Self(kind: .hidden), never = Self(kind: .never)
    var shows: Bool { kind == .automatic || kind == .visible }
}

struct ScrollIndicatorsVKey: EnvironmentKey { static var defaultValue: ScrollIndicatorVisibility { .automatic } }
struct ScrollIndicatorsHKey: EnvironmentKey { static var defaultValue: ScrollIndicatorVisibility { .automatic } }
extension EnvironmentValues {
    var _scrollIndicatorsVertical: ScrollIndicatorVisibility { get { self[ScrollIndicatorsVKey.self] } set { self[ScrollIndicatorsVKey.self] = newValue } }
    var _scrollIndicatorsHorizontal: ScrollIndicatorVisibility { get { self[ScrollIndicatorsHKey.self] } set { self[ScrollIndicatorsHKey.self] = newValue } }
    public var horizontalScrollIndicatorVisibility: ScrollIndicatorVisibility { _scrollIndicatorsHorizontal }
    public var verticalScrollIndicatorVisibility: ScrollIndicatorVisibility { _scrollIndicatorsVertical }
}

struct ScrollContentBackgroundHiddenKey: EnvironmentKey { static var defaultValue: Bool { false } }
extension EnvironmentValues {
    var _scrollContentBackgroundHidden: Bool { get { self[ScrollContentBackgroundHiddenKey.self] } set { self[ScrollContentBackgroundHiddenKey.self] = newValue } }
}
