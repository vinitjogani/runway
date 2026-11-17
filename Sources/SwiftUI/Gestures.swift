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
}

extension Gesture {
    public func _runwayTap() -> (count: Int, action: () -> Void)? { nil }
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
    public init<T: Gesture>(_ gesture: T) where T.Value == Value {
        tap = { gesture._runwayTap() }
    }
    public func _runwayTap() -> (count: Int, action: () -> Void)? { tap() }
}

// MARK: Gesture modifiers

public struct _ChangedGesture<Content: Gesture>: _PrimitiveGesture {
    public typealias Value = Content.Value
    let content: Content
    let action: (Content.Value) -> Void
    public func _runwayTap() -> (count: Int, action: () -> Void)? { content._runwayTap() }
}

public struct _EndedGesture<Content: Gesture>: _PrimitiveGesture {
    public typealias Value = Content.Value
    let content: Content
    let action: (Content.Value) -> Void
    public func _runwayTap() -> (count: Int, action: () -> Void)? {
        let action = self.action
        if let t = content as? TapGesture { return (t.count, { action(() as! Content.Value) }) }
        if let t = content as? SpatialTapGesture {
            return (t.count, { action(SpatialTapGesture.Value(location: .zero) as! Content.Value) })
        }
        return content._runwayTap()
    }
}

public struct _MapGesture<Content: Gesture, Value>: _PrimitiveGesture {
    let content: Content
    let transform: (Content.Value) -> Value
    public func _runwayTap() -> (count: Int, action: () -> Void)? { content._runwayTap() }
}

public struct GestureStateGesture<Base: Gesture, State>: _PrimitiveGesture {
    public typealias Value = Base.Value
    public var base: Base
    public var state: GestureState<State>
    let update: (Base.Value, inout State, inout Transaction) -> Void
    public func _runwayTap() -> (count: Int, action: () -> Void)? { base._runwayTap() }
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
}

public struct _ModifiersGesture<Content: Gesture>: _PrimitiveGesture {
    public typealias Value = Content.Value
    let content: Content
    public func _runwayTap() -> (count: Int, action: () -> Void)? { content._runwayTap() }
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
public struct GestureState<Value>: DynamicProperty {
    let initial: Value
    let reset: ((Value, inout Transaction) -> Void)?
    public init(wrappedValue: Value) { initial = wrappedValue; reset = nil }
    public init(initialValue: Value) { self.init(wrappedValue: initialValue) }
    public init(wrappedValue: Value, resetTransaction: Transaction) { initial = wrappedValue; reset = nil }
    public init(wrappedValue: Value, reset: @escaping (Value, inout Transaction) -> Void) { initial = wrappedValue; self.reset = reset }
    /// Gesture state is the initial value whenever no gesture is active,
    /// which (with no pointer tracking yet) is always.
    public var wrappedValue: Value { initial }
    public var projectedValue: GestureState<Value> { self }
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
        if let tap = gesture._runwayTap() {
            return ctx.resolve(content.onTapGesture(count: tap.count, perform: tap.action), "g")
        }
        return ctx.resolve(content, "g")
    }
}

extension View {
    public func gesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View { GestureView(content: self, gesture: gesture) }
    public func simultaneousGesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View { GestureView(content: self, gesture: gesture) }
    public func highPriorityGesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View { GestureView(content: self, gesture: gesture) }
    public func gesture<G: Gesture>(_ gesture: G, isEnabled: Bool) -> some View { GestureView(content: self, gesture: gesture) }
}
