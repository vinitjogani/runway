// Gestures: the Gesture protocol, the standard gestures and their
// modifiers, @GestureState. A tap gesture (TapGesture / SpatialTapGesture
// ending in an action) attached with .gesture works like onTapGesture;
// continuous gestures (drag, magnify, rotate, long press) compile and are
// accepted, but the backends don't deliver pointer tracking to SwiftUI yet.

import Foundation
import RunwayCore

@MainActor @preconcurrency
public protocol Gesture<Value> {
    associatedtype Value
    associatedtype Body: Gesture
    var body: Self.Body { get }
    /// Runway: the action to run on a tap, when this gesture is a tap that
    /// ends in one.
    func _runwayTap() -> (count: Int, action: () -> Void)?
    func _runwaySpatialTap() -> _RunwaySpatialTap?
    /// Runway: the drag this gesture tracks, with its callbacks.
    func _runwayDrag() -> _RunwayDrag?
}

/// A drag gesture's distance and callbacks (onChanged, updating, onEnded).
public struct _RunwayDrag {
    var minimumDistance: CGFloat
    var changed: [(DragGesture.Value) -> Void] = []
    var ended: [(DragGesture.Value) -> Void] = []
    var reset: [() -> Void] = []
}

public typealias _RunwaySpatialTap = (count: Int, coordinateSpace: CoordinateSpace, action: (CGPoint) -> Void)

extension Gesture {
    public func _runwayTap() -> (count: Int, action: () -> Void)? { nil }
    public func _runwaySpatialTap() -> _RunwaySpatialTap? { nil }
    public func _runwayDrag() -> _RunwayDrag? { nil }
}

extension Never: Gesture {
    public typealias Value = Never
}

/// A gesture Runway handles itself (no body).
public protocol _PrimitiveGesture: Gesture where Body == Never {}
extension _PrimitiveGesture {
    public var body: Never { fatalError("\(Self.self) is a primitive gesture") }
}

public struct GestureMask: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let none = GestureMask([])
    public static let gesture = GestureMask(rawValue: 1)
    public static let subviews = GestureMask(rawValue: 2)
    public static let all = GestureMask(rawValue: 3)
}

// MARK: Standard gestures

public struct TapGesture: _PrimitiveGesture {
    public typealias Value = Void
    public var count: Int
    public init(count: Int = 1) { self.count = count }
}

public struct SpatialTapGesture: _PrimitiveGesture {
    public struct Value: Equatable, Sendable {
        public var location: CGPoint
    }
    public var count: Int
    public var coordinateSpace: CoordinateSpace
    public init(count: Int = 1, coordinateSpace: CoordinateSpace = .local) { self.count = count; self.coordinateSpace = coordinateSpace }
}

public struct LongPressGesture: _PrimitiveGesture {
    public typealias Value = Bool
    public var minimumDuration: Double
    public var maximumDistance: CGFloat
    public init(minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10) {
        self.minimumDuration = minimumDuration
        self.maximumDistance = maximumDistance
    }
}

public struct DragGesture: _PrimitiveGesture {
    public struct Value: Equatable, Sendable {
        public var time: Date
        public var location: CGPoint
        public var startLocation: CGPoint
        public var translation: CGSize { CGSize(width: location.x - startLocation.x, height: location.y - startLocation.y) }
        public var velocity: CGSize
        public var predictedEndLocation: CGPoint
        public var predictedEndTranslation: CGSize {
            CGSize(width: predictedEndLocation.x - startLocation.x, height: predictedEndLocation.y - startLocation.y)
        }
        public init(time: Date = Date(), location: CGPoint, startLocation: CGPoint, velocity: CGSize = .zero, predictedEndLocation: CGPoint? = nil) {
            self.time = time
            self.location = location
            self.startLocation = startLocation
            self.velocity = velocity
            self.predictedEndLocation = predictedEndLocation ?? location
        }
    }
    public var minimumDistance: CGFloat
    public var coordinateSpace: CoordinateSpace
    public init(minimumDistance: CGFloat = 10, coordinateSpace: CoordinateSpace = .local) {
        self.minimumDistance = minimumDistance
        self.coordinateSpace = coordinateSpace
    }
    public func _runwayDrag() -> _RunwayDrag? { _RunwayDrag(minimumDistance: minimumDistance) }
}

public struct MagnifyGesture: _PrimitiveGesture {
    public struct Value: Equatable, Sendable {
        public var time: Date
        public var magnification: CGFloat
        public var velocity: CGFloat
        public var startAnchor: UnitPoint
        public var startLocation: CGPoint
    }
    public var minimumScaleDelta: CGFloat
    public init(minimumScaleDelta: CGFloat = 0.01) { self.minimumScaleDelta = minimumScaleDelta }
}

public struct MagnificationGesture: _PrimitiveGesture {
    public typealias Value = CGFloat
    public var minimumScaleDelta: CGFloat
    public init(minimumScaleDelta: CGFloat = 0.01) { self.minimumScaleDelta = minimumScaleDelta }
}

public struct RotateGesture: _PrimitiveGesture {
    public struct Value: Equatable, Sendable {
        public var time: Date
        public var rotation: Angle
        public var velocity: Angle
        public var startAnchor: UnitPoint
        public var startLocation: CGPoint
    }
    public var minimumAngleDelta: Angle
    public init(minimumAngleDelta: Angle = .degrees(1)) { self.minimumAngleDelta = minimumAngleDelta }
}

public struct RotationGesture: _PrimitiveGesture {
    public typealias Value = Angle
    public var minimumAngleDelta: Angle
    public init(minimumAngleDelta: Angle = .degrees(1)) { self.minimumAngleDelta = minimumAngleDelta }
}

public struct AnyGesture<Value>: _PrimitiveGesture {
    let tap: () -> (count: Int, action: () -> Void)?
    let spatialTap: () -> _RunwaySpatialTap?
    let drag: () -> _RunwayDrag?
    public init<T: Gesture>(_ gesture: T) where T.Value == Value {
        tap = { gesture._runwayTap() }
        spatialTap = { gesture._runwaySpatialTap() }
        drag = { gesture._runwayDrag() }
    }
    public func _runwayTap() -> (count: Int, action: () -> Void)? { tap() }
    public func _runwaySpatialTap() -> _RunwaySpatialTap? { spatialTap() }
    public func _runwayDrag() -> _RunwayDrag? { drag() }
}

// MARK: Gesture modifiers

public struct _ChangedGesture<Content: Gesture>: _PrimitiveGesture {
    public typealias Value = Content.Value
    let content: Content
    let action: (Content.Value) -> Void
    public func _runwayTap() -> (count: Int, action: () -> Void)? { content._runwayTap() }
    public func _runwaySpatialTap() -> _RunwaySpatialTap? { content._runwaySpatialTap() }
    public func _runwayDrag() -> _RunwayDrag? {
        guard var d = content._runwayDrag() else { return nil }
        let action = self.action
        d.changed.append { v in if let value = v as? Content.Value { action(value) } }
        return d
    }
}

public struct _EndedGesture<Content: Gesture>: _PrimitiveGesture {
    public typealias Value = Content.Value
    let content: Content
    let action: (Content.Value) -> Void
    public func _runwayTap() -> (count: Int, action: () -> Void)? {
        let action = self.action
        if let t = content as? TapGesture { return (t.count, { action(() as! Content.Value) }) }
        return content._runwayTap()
    }
    public func _runwaySpatialTap() -> _RunwaySpatialTap? {
        if let t = content as? SpatialTapGesture {
            return (t.count, t.coordinateSpace, { location in action(SpatialTapGesture.Value(location: location) as! Content.Value) })
        }
        return content._runwaySpatialTap()
    }
    public func _runwayDrag() -> _RunwayDrag? {
        guard var d = content._runwayDrag() else { return nil }
        let action = self.action
        d.ended.append { v in if let value = v as? Content.Value { action(value) } }
        return d
    }
}

public struct _MapGesture<Content: Gesture, Value>: _PrimitiveGesture {
    let content: Content
    let transform: (Content.Value) -> Value
    public func _runwayTap() -> (count: Int, action: () -> Void)? { content._runwayTap() }
    public func _runwaySpatialTap() -> _RunwaySpatialTap? { content._runwaySpatialTap() }
}

public struct GestureStateGesture<Base: Gesture, State>: _PrimitiveGesture {
    public typealias Value = Base.Value
    public var base: Base
    public var state: GestureState<State>
    let update: (Base.Value, inout State, inout Transaction) -> Void
    public func _runwayTap() -> (count: Int, action: () -> Void)? { base._runwayTap() }
    public func _runwaySpatialTap() -> _RunwaySpatialTap? { base._runwaySpatialTap() }
    public func _runwayDrag() -> _RunwayDrag? {
        guard var d = base._runwayDrag() else { return nil }
        let state = self.state, update = self.update
        d.changed.append { v in
            guard let value = v as? Base.Value else { return }
            var current = state.wrappedValue
            var t = Transaction()
            update(value, &current, &t)
            state.set(current)
        }
        d.reset.append { state.set(state.initial) }
        return d
    }
}

public struct SequenceGesture<First: Gesture, Second: Gesture>: _PrimitiveGesture {
    public enum Value {
        case first(First.Value)
        case second(First.Value, Second.Value?)
    }
    public var first: First
    public var second: Second
    public init(_ first: First, _ second: Second) { self.first = first; self.second = second }
}

public struct SimultaneousGesture<First: Gesture, Second: Gesture>: _PrimitiveGesture {
    public struct Value {
        public var first: First.Value?
        public var second: Second.Value?
    }
    public var first: First
    public var second: Second
    public init(_ first: First, _ second: Second) { self.first = first; self.second = second }
    public func _runwayTap() -> (count: Int, action: () -> Void)? { first._runwayTap() ?? second._runwayTap() }
    public func _runwaySpatialTap() -> _RunwaySpatialTap? {
        first._runwaySpatialTap() ?? (first._runwayTap() == nil ? second._runwaySpatialTap() : nil)
    }
    public func _runwayDrag() -> _RunwayDrag? { first._runwayDrag() ?? second._runwayDrag() }
}

public struct ExclusiveGesture<First: Gesture, Second: Gesture>: _PrimitiveGesture {
    public enum Value {
        case first(First.Value)
        case second(Second.Value)
    }
    public var first: First
    public var second: Second
    public init(_ first: First, _ second: Second) { self.first = first; self.second = second }
    public func _runwayTap() -> (count: Int, action: () -> Void)? {
        // The higher count wins on the Mac (double-click before click):
        // take the first that resolves.
        first._runwayTap() ?? second._runwayTap()
    }
    public func _runwaySpatialTap() -> _RunwaySpatialTap? {
        first._runwaySpatialTap() ?? (first._runwayTap() == nil ? second._runwaySpatialTap() : nil)
    }
    public func _runwayDrag() -> _RunwayDrag? { first._runwayDrag() ?? second._runwayDrag() }
}

public struct _ModifiersGesture<Content: Gesture>: _PrimitiveGesture {
    public typealias Value = Content.Value
    let content: Content
    public func _runwayTap() -> (count: Int, action: () -> Void)? { content._runwayTap() }
    public func _runwaySpatialTap() -> _RunwaySpatialTap? { content._runwaySpatialTap() }
    public func _runwayDrag() -> _RunwayDrag? { content._runwayDrag() }
}

extension Gesture {
    public func onChanged(_ action: @escaping (Value) -> Void) -> _ChangedGesture<Self> { _ChangedGesture(content: self, action: action) }
    public func onEnded(_ action: @escaping (Value) -> Void) -> _EndedGesture<Self> { _EndedGesture(content: self, action: action) }
    public func map<T>(_ body: @escaping (Value) -> T) -> _MapGesture<Self, T> { _MapGesture(content: self, transform: body) }
    public func updating<State>(_ state: GestureState<State>, body: @escaping (Value, inout State, inout Transaction) -> Void) -> GestureStateGesture<Self, State> {
        GestureStateGesture(base: self, state: state, update: body)
    }
    public func sequenced<Other: Gesture>(before other: Other) -> SequenceGesture<Self, Other> { SequenceGesture(self, other) }
    public func simultaneously<Other: Gesture>(with other: Other) -> SimultaneousGesture<Self, Other> { SimultaneousGesture(self, other) }
    public func exclusively<Other: Gesture>(before other: Other) -> ExclusiveGesture<Self, Other> { ExclusiveGesture(self, other) }
    public func modifiers(_ modifiers: EventModifiers) -> _ModifiersGesture<Self> { _ModifiersGesture(content: self) }
}

// MARK: GestureState

@propertyWrapper
public struct GestureState<Value>: DynamicProperty, DynamicPropertyLink {
    final class Link: @unchecked Sendable { var box: StateBox<Value>? }
    let initial: Value
    let reset: ((Value, inout Transaction) -> Void)?
    let link = Link()
    public init(wrappedValue: Value) { initial = wrappedValue; reset = nil }
    public init(initialValue: Value) { self.init(wrappedValue: initialValue) }
    public init(wrappedValue: Value, resetTransaction: Transaction) { initial = wrappedValue; reset = nil }
    public init(wrappedValue: Value, reset: @escaping (Value, inout Transaction) -> Void) { initial = wrappedValue; self.reset = reset }
    /// The value a gesture's `updating` set while it's active; the initial
    /// value otherwise.
    public var wrappedValue: Value { link.box?.value ?? initial }
    public var projectedValue: GestureState<Value> { self }

    func link(_ ctx: ResolveContext, key: String) {
        let initial = self.initial
        link.box = ctx.host.stateBox(key) { initial }
    }
    func set(_ v: Value) {
        guard let box = link.box else { return }
        MainActor.assumeIsolated { box.set(v) }
    }
}

extension GestureState where Value: ExpressibleByNilLiteral {
    public init(resetTransaction: Transaction = Transaction()) { self.init(wrappedValue: nil) }
}

// MARK: Attaching gestures

struct GestureView<Content: View, G: Gesture>: View, PrimitiveView {
    typealias Body = Never
    let content: Content
    let gesture: G
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        if let drag = gesture._runwayDrag() {
            // A tap combined with it still taps.
            if let tap = gesture._runwayTap() {
                return ctx.resolve(content.onTapGesture(count: tap.count, perform: tap.action).dragTracking(drag), "g")
            }
            return ctx.resolve(content.dragTracking(drag), "g")
        }
        if let tap = gesture._runwaySpatialTap() {
            return ctx.resolve(content.onTapGesture(count: tap.count, coordinateSpace: tap.coordinateSpace, perform: tap.action), "g")
        }
        if let tap = gesture._runwayTap() {
            return ctx.resolve(content.onTapGesture(count: tap.count, perform: tap.action), "g")
        }
        return ctx.resolve(content, "g")
    }
}

/// Where a drag is, between its press and its release.
@MainActor final class DragTracker {
    var start: CGPoint?
    var active = false
    var last: (CGPoint, Date)?
    var velocity = CGSize.zero
}

extension View {
    /// Tracks the pointer from a press as a DragGesture: onChanged (and
    /// updating) once it has moved its minimum distance, onEnded on release.
    func dragTracking(_ drag: _RunwayDrag) -> some View {
        pointerArea("drag") { h, ctx in
            let tracker = (ctx.host.interactions["drag:" + ctx.path] as? DragTracker) ?? DragTracker()
            ctx.host.interactions["drag:" + ctx.path] = tracker
            ctx.host.visitedInteractions.insert("drag:" + ctx.path)
            ctx.host.record(.interaction, "drag:" + ctx.path)
            h.pointer = { e in
                @MainActor func value(_ p: CGPoint) -> DragGesture.Value {
                    let start = tracker.start ?? p
                    let predicted = CGPoint(x: p.x + tracker.velocity.width * 0.25, y: p.y + tracker.velocity.height * 0.25)
                    return DragGesture.Value(time: Date(), location: p, startLocation: start, velocity: tracker.velocity, predictedEndLocation: predicted)
                }
                switch e.kind {
                case .down where e.button == 0:
                    tracker.start = e.location
                    tracker.last = (e.location, Date())
                    tracker.velocity = .zero
                    tracker.active = drag.minimumDistance <= 0
                    if tracker.active { drag.changed.forEach { $0(value(e.location)) } }
                    return tracker.active
                case .dragged:
                    guard let start = tracker.start else { return false }
                    if let (p, t) = tracker.last {
                        let dt = max(0.001, Date().timeIntervalSince(t))
                        tracker.velocity = CGSize(width: (e.location.x - p.x) / dt, height: (e.location.y - p.y) / dt)
                    }
                    tracker.last = (e.location, Date())
                    if !tracker.active, hypot(e.location.x - start.x, e.location.y - start.y) >= drag.minimumDistance { tracker.active = true }
                    if tracker.active { drag.changed.forEach { $0(value(e.location)) } }
                    return tracker.active
                case .up:
                    defer { tracker.start = nil; tracker.active = false; tracker.last = nil }
                    guard tracker.start != nil else { return false }
                    if tracker.active { drag.ended.forEach { $0(value(e.location)) } }
                    drag.reset.forEach { $0() }
                    return tracker.active
                default:
                    return false
                }
            }
        }
    }
}

extension View {
    public func gesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View { GestureView(content: self, gesture: gesture) }
    public func simultaneousGesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View { GestureView(content: self, gesture: gesture) }
    public func highPriorityGesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View { GestureView(content: self, gesture: gesture) }
    public func gesture<G: Gesture>(_ gesture: G, isEnabled: Bool) -> some View { GestureView(content: self, gesture: gesture) }
}
