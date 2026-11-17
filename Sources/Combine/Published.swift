// ObservableObject, ObservableObjectPublisher and @Published, as Combine
// defines them. SwiftUI re-exports these; its @ObservedObject/@StateObject
// subscribe to `objectWillChange` like any other publisher.

import Foundation

public protocol ObservableObject: AnyObject {
    associatedtype ObjectWillChangePublisher: Publisher = ObservableObjectPublisher
        where ObjectWillChangePublisher.Failure == Never
    var objectWillChange: ObjectWillChangePublisher { get }
}

/// The publisher an ObservableObject's @Published properties fire, before
/// each change.
public final class ObservableObjectPublisher: Publisher, @unchecked Sendable {
    public typealias Output = Void
    public typealias Failure = Never
    let subject = PassthroughSubject<Void, Never>()
    public init() {}
    public func send() { subject.send(()) }
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Void, S.Failure == Never {
        subject.receive(subscriber: subscriber)
    }
}

extension ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    /// The synthesized publisher: shared by all of the object's @Published
    /// properties (installed into them on first use). A class with no
    /// @Published properties gets a fresh, never-firing publisher, as on Apple
    /// platforms; declare `let objectWillChange = ObservableObjectPublisher()`
    /// to send manually.
    public var objectWillChange: ObservableObjectPublisher {
        var boxes: [_PublishedBoxBase] = []
        var mirror: Mirror? = Mirror(reflecting: self)
        while let m = mirror {
            for child in m.children {
                if let p = child.value as? _PublishedProperty { boxes.append(p._publishedBox) }
            }
            mirror = m.superclassMirror
        }
        guard !boxes.isEmpty else { return ObservableObjectPublisher() }
        _publishedInstallLock.lock()
        defer { _publishedInstallLock.unlock() }
        if let existing = boxes.lazy.compactMap({ $0.objectWillChange }).first {
            for b in boxes where b.objectWillChange == nil { b.objectWillChange = existing }
            return existing
        }
        let p = ObservableObjectPublisher()
        for b in boxes { b.objectWillChange = p }
        return p
    }
}

private let _publishedInstallLock = NSLock()

protocol _PublishedProperty {
    var _publishedBox: _PublishedBoxBase { get }
}

class _PublishedBoxBase: @unchecked Sendable {
    var objectWillChange: ObservableObjectPublisher?
}

final class _PublishedBox<Value>: _PublishedBoxBase, @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    private var _subject: CurrentValueSubject<Value, Never>?
    var assignment: AnyCancellable?

    init(_ v: Value) { _value = v }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    var subject: CurrentValueSubject<Value, Never> {
        lock.lock(); defer { lock.unlock() }
        if let s = _subject { return s }
        let s = CurrentValueSubject<Value, Never>(_value)
        _subject = s
        return s
    }

    /// willSet semantics: objectWillChange, then `$property` subscribers
    /// see the new value, then it's stored.
    func set(_ v: Value) {
        objectWillChange?.send()
        lock.lock()
        let s = _subject
        lock.unlock()
        s?.send(v)
        lock.lock()
        _value = v
        lock.unlock()
    }
}

@propertyWrapper
public struct Published<Value> {
    let box: _PublishedBox<Value>

    public init(wrappedValue: Value) { box = _PublishedBox(wrappedValue) }
    public init(initialValue: Value) { box = _PublishedBox(initialValue) }

    /// `$property`: emits the current value, then every new value (before
    /// it is stored).
    public struct Publisher: Combine.Publisher {
        public typealias Output = Value
        public typealias Failure = Never
        let box: _PublishedBox<Value>
        public func receive<S: Subscriber>(subscriber: S) where S.Input == Value, S.Failure == Never {
            box.subject.receive(subscriber: subscriber)
        }
    }

    public var projectedValue: Publisher {
        get { Publisher(box: box) }
        set {}
    }

    @available(*, unavailable, message: "@Published is only available on properties of classes")
    public var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    public static subscript<EnclosingSelf: AnyObject>(
        _enclosingInstance object: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Published<Value>>
    ) -> Value {
        get { object[keyPath: storageKeyPath].box.value }
        set {
            let box = object[keyPath: storageKeyPath].box
            if box.objectWillChange == nil, let observable = object as? any ObservableObject {
                // The object's own publisher: the synthesized one, or one it
                // declares (`let objectWillChange = ObservableObjectPublisher()`).
                if let p = _objectWillChange(of: observable) as? ObservableObjectPublisher { box.objectWillChange = p }
            }
            box.set(newValue)
        }
    }
}

private func _objectWillChange<O: ObservableObject>(of o: O) -> Any { o.objectWillChange }

extension Published: _PublishedProperty {
    var _publishedBox: _PublishedBoxBase { box }
}

extension Published: @unchecked Sendable where Value: Sendable {}

extension Publisher where Failure == Never {
    /// Republishes every value to a @Published property, for as long as
    /// that property's object lives.
    public func assign(to published: inout Published<Output>.Publisher) {
        let box = published.box
        let sub = _ClosureSubscriber<Output, Never>({ [weak box] v in box?.set(v); return .none }, { _ in })
        box.assignment = AnyCancellable(sub)
        subscribe(sub)
    }
}
