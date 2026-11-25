// The View protocol, view builders and the structural views (tuples,
// conditionals, optionals, ForEach, Group, AnyView, EmptyView).
//
// How a view becomes widgets: the host walks the view tree from the root.
// A primitive view (Text, Button, VStack, a modifier…) resolves itself into
// layout nodes; any other view is a *scope*: its dynamic properties
// (@State, @Environment, @Bindable…) are linked to storage kept by its
// *structural path* (its position in the tree, as SwiftUI's identity), then
// its body is resolved in turn. Widgets are cached by path too, so a
// re-render updates the same native widgets and focus, selection and
// scroll position survive. Re-renders are incremental (see Graph.swift):
// a scope whose input didn't change isn't resolved again, and a state
// change runs only the body that owns the state.

import Foundation
import RunwayCore

@MainActor @preconcurrency
public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor @preconcurrency var body: Self.Body { get }
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError("Never has no body") }
}

/// A view Runway resolves itself, with no body.
@MainActor protocol PrimitiveView {
    func resolve(in ctx: ResolveContext) -> [LayoutNode]
}

extension PrimitiveView {
    @preconcurrency @MainActor public var body: Never { fatalError("\(Self.self) is a primitive view") }
}

// MARK: Builders

@resultBuilder
public enum ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<repeat each Content> {
        TupleView(repeat each content)
    }
    public static func buildExpression<Content: View>(_ content: Content) -> Content { content }
    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }
    public static func buildOptional<Content: View>(_ content: Content?) -> Content? { content }
    public static func buildEither<T: View, F: View>(first: T) -> _ConditionalContent<T, F> { .init(storage: .trueContent(first)) }
    public static func buildEither<T: View, F: View>(second: F) -> _ConditionalContent<T, F> { .init(storage: .falseContent(second)) }
    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
}

public struct TupleView<each Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let content: (repeat each Content)
    public init(_ content: repeat each Content) { self.content = (repeat each content) }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        var out: [LayoutNode] = []
        var i = 0
        for child in repeat each content {
            out += ctx.resolve(child, "\(i)")
            i += 1
        }
        return out
    }
}

public struct _ConditionalContent<TrueContent: View, FalseContent: View>: View, PrimitiveView {
    public typealias Body = Never
    enum Storage { case trueContent(TrueContent), falseContent(FalseContent) }
    let storage: Storage
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        switch storage {
        case let .trueContent(v): return ctx.resolve(v, "T")
        case let .falseContent(v): return ctx.resolve(v, "F")
        }
    }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { fatalError() }
}

extension Optional: PrimitiveView where Wrapped: View {
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        switch self {
        case let .some(v): return ctx.resolve(v, "some")
        case .none: return []
        }
    }
}

public struct EmptyView: View, PrimitiveView {
    public typealias Body = Never
    public init() {}
    func resolve(in ctx: ResolveContext) -> [LayoutNode] { [] }
}

/// A transparent container: its modifiers apply to each child.
public struct Group<Content>: PrimitiveView {
    let content: Content
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        if let v = content as? any View { return ctx.resolveAny(v, "g") }
        return []
    }
}

extension Group: View where Content: View {
    public typealias Body = Never
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
}

/// A type-erased view. Changing the wrapped type resets its state, as in SwiftUI.
public struct AnyView: View, PrimitiveView {
    public typealias Body = Never
    let view: any View
    public init<V: View>(_ view: V) { self.view = view }
    public init<V: View>(erasing view: V) { self.view = view }
    public init?(_fromValue value: Any) {
        guard let v = value as? any View else { return nil }
        view = v
    }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] { ctx.resolveAny(view, "any") }
}

// MARK: ForEach

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content>: PrimitiveView {
    public let data: Data
    let id: (Data.Element) -> ID
    public let content: (Data.Element) -> Content
    /// For other frameworks' content builders (Charts' ForEach of marks).
    public init(_runwayData data: Data, id: @escaping (Data.Element) -> ID, content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.id = id
        self.content = content
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        var out: [LayoutNode] = []
        var seen: [String: Int] = [:]
        for element in data {
            var key = String(describing: id(element))
            // Duplicate ids keep their own state, as best we can.
            if let n = seen[key] { seen[key] = n + 1; key += "~\(n + 1)" } else { seen[key] = 0 }
            if let v = content(element) as? any View { out += ctx.resolveAny(v, "id=" + key) }
        }
        return out
    }
}

extension ForEach: View where Content: View {
    public typealias Body = Never
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.id = { $0[keyPath: id] }
        self.content = content
    }
}

extension ForEach where Content: View, Data.Element: Identifiable, ID == Data.Element.ID {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.id = { $0.id }
        self.content = content
    }
}

extension ForEach where Content: View, Data == Range<Int>, ID == Int {
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.data = data
        self.id = { $0 }
        self.content = content
    }
}

extension ForEach where Content: View, Data == ClosedRange<Int>, ID == Int {
    public init(_ data: ClosedRange<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.data = data
        self.id = { $0 }
        self.content = content
    }
}

extension ForEach where Content: View {
    /// `ForEach($items) { $item in … }`
    public init<C: MutableCollection & RandomAccessCollection>(_ data: Binding<C>, @ViewBuilder content: @escaping (Binding<C.Element>) -> Content)
    where C.Element: Identifiable, C.Index: Hashable, Data == [Binding<C.Element>], ID == C.Element.ID {
        self.data = data.wrappedValue.indices.map { i in data[i] }
        self.id = { $0.wrappedValue.id }
        self.content = content
    }
}

extension Binding where Value: MutableCollection {
    subscript(_ i: Value.Index) -> Binding<Value.Element> {
        Binding<Value.Element>(get: { self.wrappedValue[i] }, set: { self.wrappedValue[i] = $0 })
    }
}

// MARK: Identity

/// `.id(_:)`: a new identity resets the view's state.
struct IDView<Content: View, ID: Hashable>: View, PrimitiveView {
    typealias Body = Never
    let content: Content
    let id: ID
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let nodes = ctx.resolve(content, "#id=\(id)")
        guard !ctx.dryRun else { return nodes }
        let key = AnyHashable(id)
        // Where it's placed, so ScrollViewProxy can scroll to it.
        return nodes.map { IDMarkerNode($0, id: key) }
    }
}

extension View {
    public func id<ID: Hashable>(_ id: ID) -> some View { IDView(content: self, id: id) }
}


// MARK: Dynamic view content

/// Views made from a collection (ForEach and wrappers around it).
public protocol DynamicViewContent: View {
    associatedtype Data: Collection
    var data: Data { get }
}

extension ForEach: DynamicViewContent where Content: View {}

extension DynamicViewContent {
    /// Editing a list by dragging and deleting rows needs list editing
    /// support, which the list here doesn't have: the actions are kept
    /// for the API but never called.
    public func onMove(perform action: ((IndexSet, Int) -> Void)?) -> some DynamicViewContent { self }
    public func onDelete(perform action: ((IndexSet) -> Void)?) -> some DynamicViewContent { self }
    public func onInsert(of supportedContentTypes: [UTType], perform action: @escaping (Int, [NSItemProvider]) -> Void) -> some DynamicViewContent { self }
}
