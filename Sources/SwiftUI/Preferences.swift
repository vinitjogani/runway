// Preferences (values that flow up the tree: PreferenceKey, .preference,
// onPreferenceChange, overlay/backgroundPreferenceValue, anchors), Xcode
// previews (compile-only) and NSApplicationDelegateAdaptor.

import Foundation
import RunwayCore
import AppKit

// MARK: Preferences

public protocol PreferenceKey {
    associatedtype Value
    static var defaultValue: Value { get }
    static func reduce(value: inout Value, nextValue: () -> Value)
}

extension PreferenceKey where Value: ExpressibleByNilLiteral {
    public static var defaultValue: Value { nil }
}

/// Where `.preference` writers below a reader put their values: the host
/// keeps them per reader and writer path, so a subtree reused without
/// running its bodies again keeps contributing what it last wrote.
struct PreferenceSinks {
    var byKey: [ObjectIdentifier: [String]] = [:]
}

struct PreferenceSinksKey: EnvironmentKey { static var defaultValue: PreferenceSinks { PreferenceSinks() } }

extension EnvironmentValues {
    var _preferenceSinks: PreferenceSinks {
        get { self[PreferenceSinksKey.self] }
        set { self[PreferenceSinksKey.self] = newValue }
    }
}

@MainActor final class PreferenceStore {
    static var stores: [ObjectIdentifier: PreferenceStore] = [:]
    static func of(_ host: ViewHost) -> PreferenceStore {
        if let s = stores[ObjectIdentifier(host)] { return s }
        let s = PreferenceStore()
        stores[ObjectIdentifier(host)] = s
        return s
    }
    /// sink path → writer path → value
    var values: [String: [String: Any]] = [:]

    func reduce<K: PreferenceKey>(_ key: K.Type, sink: String) -> K.Value {
        var v = K.defaultValue
        guard let writers = values[sink] else { return v }
        var first = true
        for path in writers.keys.sorted() {
            guard let next = writers[path] as? K.Value else { continue }
            if first { v = next; first = false } else { K.reduce(value: &v) { next } }
        }
        return v
    }
}

/// Resolves its content with a sink for `K` in the environment, then hands
/// the reduced value to `after`.
struct PreferenceReader<K: PreferenceKey, Content: View>: View, PrimitiveView {
    typealias Body = Never
    let content: Content
    let name: String
    let after: @MainActor ([LayoutNode], K.Value, ResolveContext) -> [LayoutNode]
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let c = ctx.child(name)
        let sink = c.path
        let store = PreferenceStore.of(ctx.host)
        store.values[sink] = store.values[sink] ?? [:]
        let inner = c.with { $0._preferenceSinks.byKey[ObjectIdentifier(K.self), default: []].append(sink) }
        let ns = inner.resolve(content, "c")
        return after(ns, store.reduce(K.self, sink: sink), c)
    }
}

extension View {
    public func preference<K: PreferenceKey>(key: K.Type = K.self, value: K.Value) -> some View {
        nodes("pref") { ns, ctx in
            if !ctx.dryRun, let sinks = ctx.env._preferenceSinks.byKey[ObjectIdentifier(K.self)] {
                let store = PreferenceStore.of(ctx.host)
                for s in sinks { store.values[s, default: [:]][ctx.path] = value }
            }
            return ns
        }
    }

    public func transformPreference<K: PreferenceKey>(_ key: K.Type = K.self, _ callback: @escaping (inout K.Value) -> Void) -> some View {
        nodes("tpref") { ns, ctx in
            if !ctx.dryRun, let sinks = ctx.env._preferenceSinks.byKey[ObjectIdentifier(K.self)] {
                let store = PreferenceStore.of(ctx.host)
                for s in sinks {
                    var v = store.reduce(K.self, sink: s)
                    callback(&v)
                    store.values[s, default: [:]][ctx.path] = v
                }
            }
            return ns
        }
    }

    public func onPreferenceChange<K: PreferenceKey>(_ key: K.Type = K.self, perform action: @escaping (K.Value) -> Void) -> some View where K.Value: Equatable {
        PreferenceReader<K, Self>(content: self, name: "onpref") { ns, value, ctx in
            if !ctx.dryRun { ctx.host.change(ctx.path + "$pref", value: value, initial: true) { _, new in action(new) } }
            return ns
        }
    }

    public func overlayPreferenceValue<K: PreferenceKey, V: View>(_ key: K.Type, alignment: Alignment = .center,
                                                                  @ViewBuilder _ transform: @escaping (K.Value) -> V) -> some View {
        PreferenceReader<K, Self>(content: self, name: "ovpref") { ns, value, ctx in
            let extra = ctx.resolve(transform(value), "layer")
            guard !ns.isEmpty else { return [] }
            let primary: LayoutNode = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            return [LayerNode(primary: primary, secondary: extra, alignment: alignment, behind: false)]
        }
    }

    public func backgroundPreferenceValue<K: PreferenceKey, V: View>(_ key: K.Type, alignment: Alignment = .center,
                                                                     @ViewBuilder _ transform: @escaping (K.Value) -> V) -> some View {
        PreferenceReader<K, Self>(content: self, name: "bgpref") { ns, value, ctx in
            let extra = ctx.resolve(transform(value), "layer")
            guard !ns.isEmpty else { return [] }
            let primary: LayoutNode = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            return [LayerNode(primary: primary, secondary: extra, alignment: alignment, behind: true)]
        }
    }

    public func anchorPreference<A, K: PreferenceKey>(key: K.Type = K.self, value: Anchor<A>.Source,
                                                      transform: @escaping (Anchor<A>) -> K.Value) -> some View {
        preference(key: K.self, value: transform(Anchor<A>(source: value)))
    }

    public func transformAnchorPreference<A, K: PreferenceKey>(key: K.Type = K.self, value: Anchor<A>.Source,
                                                               transform: @escaping (inout K.Value, Anchor<A>) -> Void) -> some View {
        transformPreference(K.self) { v in transform(&v, Anchor<A>(source: value)) }
    }
}

/// An anchor resolves through a GeometryProxy to a value in its space.
/// Runway doesn't track where the anchored view landed, so anchors resolve
/// to the value they were made from in the reader's space.
public struct Anchor<Value> {
    let source: Source
    public struct Source {
        let value: Any
        init(_ value: Any) { self.value = value }
        /// Runway: the anchor for this source (Charts' proxy uses it).
        public var _anchor: Anchor<Value> { Anchor(source: self) }
    }
}

extension Anchor.Source where Value == CGRect {
    public static var bounds: Anchor<CGRect>.Source { .init(CGRect.zero) }
    public static func rect(_ r: CGRect) -> Anchor<CGRect>.Source { .init(r) }
}

extension Anchor.Source where Value == CGPoint {
    public static var center: Anchor<CGPoint>.Source { .init(CGPoint.zero) }
    public static var top: Anchor<CGPoint>.Source { .init(CGPoint.zero) }
    public static var bottom: Anchor<CGPoint>.Source { .init(CGPoint.zero) }
    public static var leading: Anchor<CGPoint>.Source { .init(CGPoint.zero) }
    public static var trailing: Anchor<CGPoint>.Source { .init(CGPoint.zero) }
    public static var topLeading: Anchor<CGPoint>.Source { .init(CGPoint.zero) }
    public static var bottomTrailing: Anchor<CGPoint>.Source { .init(CGPoint.zero) }
    public static func point(_ p: CGPoint) -> Anchor<CGPoint>.Source { .init(p) }
    public static func unitPoint(_ p: UnitPoint) -> Anchor<CGPoint>.Source { .init(CGPoint(x: p.x, y: p.y)) }
}

extension Anchor: Equatable where Value: Equatable {
    public static func == (a: Anchor, b: Anchor) -> Bool { (a.source.value as? Value) == (b.source.value as? Value) }
}

extension GeometryProxy {
    public subscript<T>(anchor: Anchor<T>) -> T {
        if let r = anchor.source.value as? CGRect, r == .zero, T.self == CGRect.self { return CGRect(origin: .zero, size: size) as! T }
        return anchor.source.value as! T
    }
}

// MARK: Xcode previews (compile-only)

@MainActor @preconcurrency
public protocol PreviewProvider {
    associatedtype Previews: View
    @ViewBuilder @MainActor @preconcurrency static var previews: Previews { get }
    static var platform: PreviewPlatform? { get }
}

extension PreviewProvider {
    public static var platform: PreviewPlatform? { nil }
}

public enum PreviewPlatform: Sendable { case iOS, macOS, tvOS, watchOS, visionOS }

public enum PreviewLayout: Sendable {
    case device, sizeThatFits
    case fixed(width: CGFloat, height: CGFloat)
}

public struct PreviewDevice: RawRepresentable, ExpressibleByStringLiteral, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct PreviewContext {}

extension View {
    public func previewDisplayName(_ name: String?) -> some View { self }
    public func previewLayout(_ value: PreviewLayout) -> some View { self }
    public func previewDevice(_ value: PreviewDevice?) -> some View { self }
    public func previewInterfaceOrientation(_ value: Any) -> some View { self }
    public func previewContext(_ value: Any) -> some View { self }
}

// MARK: NSApplicationDelegateAdaptor

/// Creates the app delegate when the App is created and makes it
/// `NSApp.delegate`; App.main then calls its launch methods.
@MainActor @preconcurrency @propertyWrapper
public struct NSApplicationDelegateAdaptor<DelegateType: NSObject & NSApplicationDelegate>: DynamicProperty {
    let delegate: DelegateType

    /// What `runway` stages `@NSApplicationDelegateAdaptor(T.self)` as: the
    /// delegate's `init()` isn't `required`, so it comes as a factory.
    public init(_ delegateType: DelegateType.Type = DelegateType.self, _ make: @MainActor () -> DelegateType) {
        if let existing = _AppDelegateBox.delegates[ObjectIdentifier(delegateType)] as? DelegateType {
            delegate = existing
        } else {
            delegate = make()
            _AppDelegateBox.delegates[ObjectIdentifier(delegateType)] = delegate
        }
        NSApplication.shared.delegate = delegate
    }

    public init(_ delegateType: DelegateType.Type = DelegateType.self) {
        guard let existing = _AppDelegateBox.delegates[ObjectIdentifier(delegateType)] as? DelegateType else {
            fatalError("NSApplicationDelegateAdaptor(\(delegateType)): build the app with `runway`, which gives the adaptor a factory")
        }
        delegate = existing
    }

    public var wrappedValue: DelegateType { delegate }
}

extension NSApplicationDelegateAdaptor where DelegateType: ObservableObject {
    public var projectedValue: ObservedObject<DelegateType> { ObservedObject(wrappedValue: delegate) }
}

@MainActor enum _AppDelegateBox {
    static var delegates: [ObjectIdentifier: AnyObject] = [:]
}
