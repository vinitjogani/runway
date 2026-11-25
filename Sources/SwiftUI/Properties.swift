// @State, @Binding, @Environment, @Bindable, @AppStorage, @FocusState,
// @StateObject/@ObservedObject: linked to per-path storage by the host.

import Foundation
import Observation
import RunwayCore

// MARK: State

@propertyWrapper
public struct State<Value>: DynamicPropertyLink, DynamicProperty {
    final class Link: @unchecked Sendable {
        var initial: Value
        var box: StateBox<Value>?
        init(_ v: Value) { initial = v }
    }
    let _link: Link

    public init(wrappedValue value: Value) { _link = Link(value) }
    public init(initialValue value: Value) { _link = Link(value) }

    public var wrappedValue: Value {
        get { _link.box?.value ?? _link.initial }
        nonmutating set {
            if let b = _link.box { MainActor.assumeIsolated { b.set(newValue) } } else { _link.initial = newValue }
        }
    }

    public var projectedValue: Binding<Value> {
        let link = _link
        return Binding(get: { link.box?.read() ?? link.initial },
                       set: { v in if let b = link.box { MainActor.assumeIsolated { b.set(v) } } else { link.initial = v } })
    }

    func link(_ ctx: ResolveContext, key: String) {
        let initial = _link.initial
        _link.box = ctx.host.stateBox(key) { initial }
    }
}

extension State where Value: ExpressibleByNilLiteral {
    public init() { _link = Link(nil) }
}

extension State: @unchecked Sendable {}

// MARK: Binding

@propertyWrapper @dynamicMemberLookup
public struct Binding<Value>: @unchecked Sendable {
    let getter: () -> Value
    let setter: (Value) -> Void
    public var transaction = Transaction()

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        getter = get
        setter = set
    }
    public init(get: @escaping () -> Value, set: @escaping (Value, Transaction) -> Void) {
        getter = get
        setter = { set($0, Transaction()) }
    }
    public init(projectedValue: Binding<Value>) { self = projectedValue }

    public static func constant(_ value: Value) -> Binding<Value> { Binding(get: { value }, set: { _ in }) }

    public var wrappedValue: Value {
        get { getter() }
        nonmutating set { setter(newValue) }
    }
    public var projectedValue: Binding<Value> { self }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        Binding<T>(get: { self.wrappedValue[keyPath: keyPath] }, set: { self.wrappedValue[keyPath: keyPath] = $0 })
    }

    public func animation(_ animation: Animation? = .default) -> Binding<Value> { self }
    public func transaction(_ transaction: Transaction) -> Binding<Value> { self }
}

extension Binding {
    /// Unwraps a binding to an optional, `nil` while it holds `nil`.
    public init?(_ base: Binding<Value?>) {
        guard let v = base.wrappedValue else { return nil }
        var last = v
        self.init(get: { base.wrappedValue ?? last }, set: { last = $0; base.wrappedValue = $0 })
    }
    public init<V>(_ base: Binding<V>) where Value == V? {
        self.init(get: { base.wrappedValue }, set: { if let v = $0 { base.wrappedValue = v } })
    }
}

extension Binding: Identifiable where Value: Identifiable {
    public var id: Value.ID { wrappedValue.id }
}

public struct Transaction: Sendable {
    public var animation: Animation?
    public var disablesAnimations = false
    public init() {}
    public init(animation: Animation?) { self.animation = animation }
}

// MARK: Environment

@propertyWrapper
public struct Environment<Value>: DynamicPropertyLink, DynamicProperty {
    final class Link: @unchecked Sendable { var env: EnvironmentValues? }
    let read: (EnvironmentValues) -> Value
    let _link = Link()

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) { read = { $0[keyPath: keyPath] } }

    public var wrappedValue: Value {
        MainActor.assumeIsolated { read(_link.env ?? EnvironmentValues()) }
    }

    func link(_ ctx: ResolveContext, key: String) { linkForProbe(ctx.env) }
    func linkForProbe(_ env: EnvironmentValues) { _link.env = env }
}

extension Environment where Value: AnyObject & Observable {
    /// `@Environment(Model.self) var model`
    public init(_ type: Value.Type) {
        read = { env in
            guard let v = env.objects[ObjectIdentifier(type)] as? Value else {
                fatalError("No \(Value.self) in the environment: add .environment(model) above this view")
            }
            return v
        }
    }
}

extension Environment: @unchecked Sendable {}

// MARK: Bindable

@propertyWrapper @dynamicMemberLookup
public struct Bindable<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(_ wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(projectedValue: Bindable<Value>) { self = projectedValue }
    public var projectedValue: Bindable<Value> { self }
}

extension Bindable where Value: AnyObject {
    public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, T>) -> Binding<T> {
        let object = wrappedValue
        return Binding(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
    }
}

extension Bindable: @unchecked Sendable {}

// MARK: AppStorage

@propertyWrapper
public struct AppStorage<Value>: DynamicPropertyLink, DynamicProperty {
    final class Link: @unchecked Sendable { weak var host: ViewHost? }
    let key: String
    let defaultValue: Value
    let store: UserDefaults
    let decode: (Any) -> Value?
    let encode: (Value) -> Any?
    let _link = Link()

    public var wrappedValue: Value {
        get { store.object(forKey: key).flatMap(decode) ?? defaultValue }
        nonmutating set {
            if let v = encode(newValue) { store.set(v, forKey: key) } else { store.removeObject(forKey: key) }
            let key = self.key
            MainActor.assumeIsolated { AppStorageReaders.changed(key) }
        }
    }
    public var projectedValue: Binding<Value> {
        let s = self
        return Binding(get: { s.wrappedValue }, set: { s.wrappedValue = $0 })
    }
    func link(_ ctx: ResolveContext, key: String) {
        _link.host = ctx.host
        AppStorageReaders.add(self.key, scope: ctx.scope, host: ctx.host)
    }
}

extension AppStorage {
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Bool {
        self.init(key: key, defaultValue: wrappedValue, store: store ?? .standard, decode: { $0 as? Bool }, encode: { $0 })
    }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Int {
        self.init(key: key, defaultValue: wrappedValue, store: store ?? .standard, decode: { $0 as? Int }, encode: { $0 })
    }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Double {
        self.init(key: key, defaultValue: wrappedValue, store: store ?? .standard, decode: { $0 as? Double }, encode: { $0 })
    }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == String {
        self.init(key: key, defaultValue: wrappedValue, store: store ?? .standard, decode: { $0 as? String }, encode: { $0 })
    }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value == Data {
        self.init(key: key, defaultValue: wrappedValue, store: store ?? .standard, decode: { $0 as? Data }, encode: { $0 })
    }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value: RawRepresentable, Value.RawValue == String {
        self.init(key: key, defaultValue: wrappedValue, store: store ?? .standard, decode: { ($0 as? String).flatMap(Value.init(rawValue:)) }, encode: { $0.rawValue })
    }
    public init(wrappedValue: Value, _ key: String, store: UserDefaults? = nil) where Value: RawRepresentable, Value.RawValue == Int {
        self.init(key: key, defaultValue: wrappedValue, store: store ?? .standard, decode: { ($0 as? Int).flatMap(Value.init(rawValue:)) }, encode: { $0.rawValue })
    }
    public init(_ key: String, store: UserDefaults? = nil) where Value == String? {
        self.init(key: key, defaultValue: nil, store: store ?? .standard, decode: { $0 as? String }, encode: { $0 })
    }
}

extension AppStorage: @unchecked Sendable {}

// MARK: Focus (see Interaction.swift for how focus reaches native widgets)

@propertyWrapper
public struct FocusState<Value: Hashable>: DynamicPropertyLink, DynamicProperty {
    /// Storage kept by path; writes re-render the owning scope and move
    /// keyboard focus to the view bound to the new value.
    final class Box: @unchecked Sendable {
        var value: Value
        let unfocused: Value
        weak var state: StateBox<Value>?
        init(_ v: Value) { value = v; unfocused = v }
        var current: Value { state?.read() ?? value }
        @MainActor func set(_ v: Value) {
            if let state {
                guard state.value != v else { return }
                state.set(v)
                state.host?.scheduleFocusSync()
            } else {
                value = v
            }
        }
    }
    let box: Box
    public init() where Value == Bool { box = Box(false) }
    public init<T: Hashable>() where Value == T? { box = Box(nil) }
    public var wrappedValue: Value {
        get { box.current }
        nonmutating set { MainActor.assumeIsolated { box.set(newValue) } }
    }
    public var projectedValue: Binding { Binding(box: box) }

    func link(_ ctx: ResolveContext, key: String) {
        let initial = box.value
        let state = ctx.host.stateBox(key) { initial }
        box.state = state
    }

    @propertyWrapper public struct Binding {
        let box: Box
        public var wrappedValue: Value {
            get { box.current }
            nonmutating set { MainActor.assumeIsolated { box.set(newValue) } }
        }
        public var projectedValue: Binding { self }
    }
}

// MARK: ObservableObject: Combine's (re-exported), observed per host and key.

@_exported import Combine

nonisolated(unsafe) private var objectSubscriptions: [String: AnyCancellable] = [:]

/// Re-renders `host` when `object` will change (one subscription per host
/// and property path, replaced on each resolve).
func observe<O: ObservableObject>(_ object: O, host: ViewHost, scope: Scope?, key: String) {
    // Re-runs only the view holding the object (see Graph.swift).
    let ref = UncheckedScopeRef(host: host, scope: scope)
    objectSubscriptions["\(ObjectIdentifier(host).hashValue)/\(key)"] = object.objectWillChange.sink { _ in
        Task { @MainActor in ref.invalidate() }
    }
}

@propertyWrapper @dynamicMemberLookup
public struct ObservedObject<ObjectType: ObservableObject>: DynamicPropertyLink, DynamicProperty {
    public var wrappedValue: ObjectType
    let id = UUID()
    public init(wrappedValue: ObjectType) { self.wrappedValue = wrappedValue }
    public init(initialValue: ObjectType) { self.wrappedValue = initialValue }
    public var projectedValue: ObservedObject<ObjectType> { self }
    public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, T>) -> Binding<T> {
        let o = wrappedValue
        return Binding(get: { o[keyPath: keyPath] }, set: { o[keyPath: keyPath] = $0 })
    }
    func link(_ ctx: ResolveContext, key: String) {
        observe(wrappedValue, host: ctx.host, scope: ctx.scope, key: key)
    }
}

@propertyWrapper @dynamicMemberLookup
public struct StateObject<ObjectType: ObservableObject>: DynamicPropertyLink, DynamicProperty {
    final class Link: @unchecked Sendable {
        let make: () -> ObjectType
        var box: StateBox<ObjectType>?
        init(_ make: @escaping () -> ObjectType) { self.make = make }
    }
    let _link: Link
    public init(wrappedValue: @autoclosure @escaping () -> ObjectType) { _link = Link(wrappedValue) }
    public var wrappedValue: ObjectType { _link.box?.value ?? _link.make() }
    public var projectedValue: ObservedObject<ObjectType> { ObservedObject(wrappedValue: wrappedValue) }
    public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, T>) -> Binding<T> {
        let o = wrappedValue
        return Binding(get: { o[keyPath: keyPath] }, set: { o[keyPath: keyPath] = $0 })
    }
    func link(_ ctx: ResolveContext, key: String) {
        let make = _link.make
        let box = ctx.host.stateBox(key) { make() }
        _link.box = box
        observe(box.value, host: ctx.host, scope: ctx.scope, key: key)
    }
}

extension View {
    public func environmentObject<T: ObservableObject>(_ object: T) -> some View {
        environment { $0.objects[ObjectIdentifier(T.self)] = object }
    }
}

@propertyWrapper
public struct EnvironmentObject<ObjectType: ObservableObject>: DynamicPropertyLink, DynamicProperty {
    final class Link: @unchecked Sendable { var object: ObjectType? }
    let _link = Link()
    public init() {}
    /// `$object.property`: bindings to the object's properties.
    @dynamicMemberLookup public struct Wrapper {
        let object: ObjectType
        public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<ObjectType, T>) -> Binding<T> {
            let o = object
            return Binding(get: { o[keyPath: keyPath] }, set: { o[keyPath: keyPath] = $0 })
        }
    }
    public var projectedValue: Wrapper { Wrapper(object: wrappedValue) }
    public var wrappedValue: ObjectType {
        guard let o = _link.object else { fatalError("No \(ObjectType.self) environment object") }
        return o
    }
    func link(_ ctx: ResolveContext, key: String) {
        linkForProbe(ctx.env)
        if let o = _link.object {
            observe(o, host: ctx.host, scope: ctx.scope, key: key)
        }
    }
    func linkForProbe(_ env: EnvironmentValues) {
        _link.object = env.objects[ObjectIdentifier(ObjectType.self)] as? ObjectType
    }
}

// MARK: Comparing view inputs

// A view's input is unchanged when its stored properties are. Properties
// whose value lives in the graph (state, environment, storage) aren't part
// of that input: they invalidate the view themselves when they change.
extension State: MemoComparable { static func memoEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool { true } }
extension Environment: MemoComparable { static func memoEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool { true } }
extension StateObject: MemoComparable { static func memoEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool { true } }
extension EnvironmentObject: MemoComparable { static func memoEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool { true } }
extension FocusState: MemoComparable { static func memoEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool { true } }
extension FocusState.Binding: MemoComparable { static func memoEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool { true } }
extension AppStorage: MemoComparable {
    static func memoEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool {
        a.assumingMemoryBound(to: Self.self).pointee.key == b.assumingMemoryBound(to: Self.self).pointee.key
    }
}
extension ObservedObject: MemoComparable {
    /// The same object (its changes invalidate the view on their own).
    static func memoEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool {
        a.assumingMemoryBound(to: Self.self).pointee.wrappedValue === b.assumingMemoryBound(to: Self.self).pointee.wrappedValue
    }
}
