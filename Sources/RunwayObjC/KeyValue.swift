// Key-value coding and observing.
//
// KVC goes through the generated tables (`.value` / `.setValue` messages for
// a class's `@objc` properties). KVO: the transpiler gives each
// `@objc dynamic` stored property `willSet`/`didSet` observers that call
// `KVO.willChange` / `KVO.didChange`, and rewrites `observe(\.a.b, ...)` to
// pass the key path's name ("a.b"), so the registry here can match changes to
// observers by key without the Objective-C runtime's key path strings.

import Foundation

// MARK: Types (Foundation's, which corelibs lacks)

public struct NSKeyValueObservingOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let new = NSKeyValueObservingOptions(rawValue: 0x01)
    public static let old = NSKeyValueObservingOptions(rawValue: 0x02)
    public static let initial = NSKeyValueObservingOptions(rawValue: 0x04)
    public static let prior = NSKeyValueObservingOptions(rawValue: 0x08)
}

public enum NSKeyValueChange: UInt, Sendable {
    case setting = 1, insertion = 2, removal = 3, replacement = 4
}

public struct NSKeyValueChangeKey: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let kindKey = NSKeyValueChangeKey("kind")
    public static let newKey = NSKeyValueChangeKey("new")
    public static let oldKey = NSKeyValueChangeKey("old")
    public static let indexesKey = NSKeyValueChangeKey("indexes")
    public static let notificationIsPriorKey = NSKeyValueChangeKey("notificationIsPrior")
}

public struct NSKeyValueObservedChange<Value> {
    public typealias Kind = NSKeyValueChange
    public let kind: Kind
    public let newValue: Value?
    public let oldValue: Value?
    public let indexes: IndexSet?
    public let isPrior: Bool
}

/// The token `observe(_:options:changeHandler:)` returns; observing stops
/// when it's invalidated or deallocated.
public final class NSKeyValueObservation: NSObject, @unchecked Sendable {
    private var token: KVO.Token?
    init(_ token: KVO.Token) { self.token = token }
    public func invalidate() { token?.cancel(); token = nil }
    deinit { token?.cancel() }
}

/// `observeValue(forKeyPath:of:change:context:)`, for observers registered
/// with `addObserver(_:forKeyPath:options:context:)`. The transpiler adds the
/// conformance to classes that implement it.
public protocol KeyValueObserving: AnyObject {
    func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?)
}

// MARK: The registry

public enum KVO {
    struct Event { var old: Any?; var new: Any?; var isPrior: Bool }

    /// A registration; cancelling it stops delivery.
    final class Token: @unchecked Sendable {
        private let onCancel: () -> Void
        private var done = false
        init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        func cancel() { if !done { done = true; onCancel() } }
    }

    fileprivate final class Observer {
        let id: Int
        let key: String          // a property name, or "*" for every change
        let prior: Bool
        let deliver: (Event) -> Void
        init(id: Int, key: String, prior: Bool, deliver: @escaping (Event) -> Void) {
            self.id = id; self.key = key; self.prior = prior; self.deliver = deliver
        }
    }

    fileprivate final class Entry {
        weak var object: AnyObject?
        var observers: [Observer] = []
        init(_ object: AnyObject) { self.object = object }
    }

    fileprivate final class Store: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var entries: [ObjectIdentifier: Entry] = [:]
        var nextID = 0
        var pendingOld: [PendingKey: [Any?]] = [:]
    }
    fileprivate struct PendingKey: Hashable { let object: ObjectIdentifier; let key: String }
    fileprivate static let store = Store()

    private static func observers(of object: AnyObject, key: String, priorOnly: Bool = false) -> [Observer] {
        store.lock.lock(); defer { store.lock.unlock() }
        guard let e = store.entries[ObjectIdentifier(object)] else { return [] }
        guard e.object === object else { store.entries[ObjectIdentifier(object)] = nil; return [] }
        return e.observers.filter { ($0.key == key || $0.key == "*") && (!priorOnly || $0.prior) }
    }

    /// Registers `deliver` for changes to `key` (one component) of `object`.
    static func register(_ object: AnyObject, key: String, prior: Bool, _ deliver: @escaping (Event) -> Void) -> Token {
        store.lock.lock()
        store.nextID += 1
        let id = store.nextID
        let oid = ObjectIdentifier(object)
        let entry: Entry
        if let e = store.entries[oid], e.object === object { entry = e } else { entry = Entry(object); store.entries[oid] = entry }
        entry.observers.append(Observer(id: id, key: key, prior: prior, deliver: deliver))
        store.lock.unlock()
        return Token { [weak entry] in
            store.lock.lock(); defer { store.lock.unlock() }
            guard let entry else { return }
            entry.observers.removeAll { $0.id == id }
            if entry.observers.isEmpty, store.entries[oid] === entry { store.entries[oid] = nil }
        }
    }

    /// Observes a key path ("a.b.c"): re-subscribes the rest of the path on
    /// each new intermediate value.
    static func subscribe(_ object: AnyObject, path: [Substring], prior: Bool, _ deliver: @escaping (Event) -> Void) -> Token {
        guard let first = path.first else { return Token {} }
        let key = String(first)
        if path.count == 1 { return register(object, key: key, prior: prior, deliver) }
        let rest = Array(path.dropFirst())
        let restPath = rest.joined(separator: ".")
        final class Chain: @unchecked Sendable { var child: Token? }
        let chain = Chain()
        func attach(_ value: Any?) {
            chain.child?.cancel(); chain.child = nil
            if let o = flatten(value as Any).flatMap({ type(of: $0) is AnyClass ? $0 as AnyObject : nil }) {
                chain.child = subscribe(o, path: rest, prior: prior, deliver)
            }
        }
        attach(valueForKey(object, key))
        let head = register(object, key: key, prior: prior) { ev in
            let old = ev.old.flatMap { valueForKeyPath($0 as AnyObject, restPath) }
            if ev.isPrior {
                deliver(Event(old: old, new: nil, isPrior: true))
                return
            }
            attach(ev.new)
            let new = ev.new.flatMap { valueForKeyPath($0 as AnyObject, restPath) }
            deliver(Event(old: old, new: new, isPrior: false))
        }
        return Token { head.cancel(); chain.child?.cancel() }
    }

    // MARK: Notifying (generated property observers call these)

    /// Before a change (the `.prior` notifications).
    public static func willChange(_ object: AnyObject, _ key: String) {
        let obs = observers(of: object, key: key, priorOnly: true)
        if obs.isEmpty { return }
        let old = valueForKey(object, key)
        for o in obs { o.deliver(Event(old: old, new: nil, isPrior: true)) }
    }

    /// After a change, with the old and new values.
    public static func didChange<V>(_ object: AnyObject, _ key: String, old: V, new: V) {
        let obs = observers(of: object, key: key)
        if obs.isEmpty { return }
        let ev = Event(old: flatten(old), new: flatten(new), isPrior: false)
        for o in obs { o.deliver(ev) }
    }

    /// `willChangeValue(forKey:)`: remembers the value for `didChangeValue`.
    static func manualWillChange(_ object: AnyObject, _ key: String) {
        let k = PendingKey(object: ObjectIdentifier(object), key: key)
        let hasObservers = !observers(of: object, key: key).isEmpty
        let old = hasObservers ? valueForKey(object, key) : nil
        store.lock.lock(); store.pendingOld[k, default: []].append(old); store.lock.unlock()
        willChange(object, key)
    }

    static func manualDidChange(_ object: AnyObject, _ key: String) {
        let k = PendingKey(object: ObjectIdentifier(object), key: key)
        store.lock.lock()
        let old = store.pendingOld[k]?.popLast() ?? nil
        if store.pendingOld[k]?.isEmpty == true { store.pendingOld[k] = nil }
        store.lock.unlock()
        let obs = observers(of: object, key: key)
        if obs.isEmpty { return }
        let ev = Event(old: old, new: valueForKey(object, key), isPrior: false)
        for o in obs { o.deliver(ev) }
    }

    /// What `super.observeValue(forKeyPath:of:change:context:)` becomes when
    /// the superclass is NSObject: Foundation's raises; this ignores it.
    public static func unhandledObservation(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {}

    // MARK: KVC

    static func valueForKey(_ object: AnyObject, _ key: String) -> Any? {
        var m = Message(.value(key))
        if handle(object, &m) { return m.result }
        if let d = object as? NSDictionary { return d.object(forKey: key) }
        return nil
    }

    static func valueForKeyPath(_ object: AnyObject, _ path: String) -> Any? {
        var current: Any? = object
        for k in path.split(separator: ".") {
            guard let c = current.flatMap({ flatten($0) }), type(of: c) is AnyClass else { return nil }
            current = valueForKey(c as AnyObject, String(k))
        }
        return current
    }

    static func change(_ ev: Event, _ options: NSKeyValueObservingOptions) -> [NSKeyValueChangeKey: Any] {
        var c: [NSKeyValueChangeKey: Any] = [.kindKey: NSKeyValueChange.setting.rawValue]
        if ev.isPrior { c[.notificationIsPriorKey] = true }
        if options.contains(.old) { c[.oldKey] = ev.old ?? NSNull() }
        if options.contains(.new), !ev.isPrior { c[.newKey] = ev.new ?? NSNull() }
        return c
    }

    // addObserver(_:forKeyPath:options:context:) registrations.
    fileprivate final class Classic: @unchecked Sendable {
        let lock = NSLock()
        struct Reg { let object: ObjectIdentifier; weak var observer: AnyObject?; let observerID: ObjectIdentifier; let keyPath: String; let context: UnsafeMutableRawPointer?; let token: Token }
        var regs: [Reg] = []
    }
    fileprivate static let classic = Classic()
}

final class LastValue<V>: @unchecked Sendable { var value: V?; init(_ v: V?) { value = v } }

func cast<T>(_ v: Any?) -> T? {
    if let t = v as? T { return t }
    return (v as Any) as? T
}

// MARK: The NSObject API

/// Foundation's protocol for `observe(_:options:changeHandler:)`'s `Self`.
public protocol _KeyValueCodingAndObserving {}
extension NSObject: _KeyValueCodingAndObserving {}

extension _KeyValueCodingAndObserving where Self: NSObject {
    /// `observe(\.a.b, options:changeHandler:)`. The transpiler passes the key
    /// path's name as `_runwayKey`.
    public func observe<Value>(_ keyPath: KeyPath<Self, Value>, _runwayKey key: String,
                               options: NSKeyValueObservingOptions = [],
                               changeHandler: @escaping (Self, NSKeyValueObservedChange<Value>) -> Void) -> NSKeyValueObservation {
        _observe(keyPath, path: key.split(separator: "."), options: options, changeHandler)
    }

    /// Without the key path's name (a key path held in a variable), any
    /// observable change of the object is reported.
    public func observe<Value>(_ keyPath: KeyPath<Self, Value>,
                               options: NSKeyValueObservingOptions = [],
                               changeHandler: @escaping (Self, NSKeyValueObservedChange<Value>) -> Void) -> NSKeyValueObservation {
        _observe(keyPath, path: ["*"], options: options, changeHandler)
    }

    private func _observe<Value>(_ keyPath: KeyPath<Self, Value>, path: [Substring], options: NSKeyValueObservingOptions,
                                 _ handler: @escaping (Self, NSKeyValueObservedChange<Value>) -> Void) -> NSKeyValueObservation {
        let last = LastValue<Value>(self[keyPath: keyPath])
        let token = KVO.subscribe(self, path: path, prior: options.contains(.prior)) { [weak self] ev in
            guard let self else { return }
            if ev.isPrior {
                handler(self, NSKeyValueObservedChange(kind: .setting, newValue: nil,
                                                       oldValue: options.contains(.old) ? last.value : nil, indexes: nil, isPrior: true))
                return
            }
            let new = self[keyPath: keyPath]
            let old: Value? = ev.old.flatMap { cast($0) } ?? last.value
            last.value = new
            handler(self, NSKeyValueObservedChange(kind: .setting, newValue: options.contains(.new) ? new : nil,
                                                   oldValue: options.contains(.old) ? old : nil, indexes: nil, isPrior: false))
        }
        if options.contains(.initial) {
            handler(self, NSKeyValueObservedChange(kind: .setting, newValue: options.contains(.new) ? self[keyPath: keyPath] : nil,
                                                   oldValue: nil, indexes: nil, isPrior: false))
        }
        return NSKeyValueObservation(token)
    }
}

extension NSObject {
    // KVC

    /// `valueForKey:` over the class's `@objc` properties (nil, with a log
    /// line, for an unknown key, where the Mac raises).
    public func value(forKey key: String) -> Any? {
        var m = Message(.value(key))
        if handle(self, &m) { return m.result }
        return value(forUndefinedKey: key)
    }

    public func value(forUndefinedKey key: String) -> Any? {
        FileHandle.standardError.write(Data("runway: \(type(of: self)) is not key value coding-compliant for the key \(key)\n".utf8))
        return nil
    }

    /// `setValue:forKey:`; notifies observers like the Mac does.
    public func setValue(_ value: Any?, forKey key: String) {
        let old = KVO.valueForKey(self, key)
        var m = Message(.setValue(key, value))
        guard handle(self, &m) else {
            FileHandle.standardError.write(Data("runway: \(type(of: self)) is not key value coding-compliant for the key \(key)\n".utf8))
            return
        }
        if !m.notifies { KVO.didChange(self, key, old: old, new: KVO.valueForKey(self, key)) }
    }

    public func value(forKeyPath keyPath: String) -> Any? { KVO.valueForKeyPath(self, keyPath) }

    public func setValue(_ value: Any?, forKeyPath keyPath: String) {
        var parts = keyPath.split(separator: ".").map(String.init)
        guard let last = parts.popLast() else { return }
        let target = parts.isEmpty ? self : KVO.valueForKeyPath(self, parts.joined(separator: "."))
        (target.flatMap { flatten($0) } as? NSObject)?.setValue(value, forKey: last)
    }

    public func setValuesForKeys(_ keyedValues: [String: Any]) {
        for (k, v) in keyedValues { setValue(v, forKey: k) }
    }

    public func dictionaryWithValues(forKeys keys: [String]) -> [String: Any] {
        var d: [String: Any] = [:]
        for k in keys { d[k] = value(forKey: k) ?? NSNull() }
        return d
    }

    // Manual KVO notifications

    public func willChangeValue(forKey key: String) { KVO.manualWillChange(self, key) }
    public func didChangeValue(forKey key: String) { KVO.manualDidChange(self, key) }

    // addObserver/removeObserver

    /// `addObserver:forKeyPath:options:context:`. The observer isn't
    /// retained; it gets `observeValue(forKeyPath:of:change:context:)`.
    public func addObserver(_ observer: NSObject, forKeyPath keyPath: String, options: NSKeyValueObservingOptions = [], context: UnsafeMutableRawPointer?) {
        weak var weakObserver = observer
        weak var weakSelf = self
        let token = KVO.subscribe(self, path: keyPath.split(separator: "."), prior: options.contains(.prior)) { ev in
            guard let o = weakObserver as? KeyValueObserving, let s = weakSelf else { return }
            o.observeValue(forKeyPath: keyPath, of: s, change: KVO.change(ev, options), context: context)
        }
        KVO.classic.lock.lock()
        KVO.classic.regs.append(.init(object: ObjectIdentifier(self), observer: observer, observerID: ObjectIdentifier(observer),
                                      keyPath: keyPath, context: context, token: token))
        KVO.classic.lock.unlock()
        if options.contains(.initial), let o = observer as? KeyValueObserving {
            var c: [NSKeyValueChangeKey: Any] = [.kindKey: NSKeyValueChange.setting.rawValue]
            if options.contains(.new) { c[.newKey] = value(forKeyPath: keyPath) ?? NSNull() }
            o.observeValue(forKeyPath: keyPath, of: self, change: c, context: context)
        }
    }

    public func removeObserver(_ observer: NSObject, forKeyPath keyPath: String) {
        removeKVO(observer, keyPath) { _ in true }
    }

    public func removeObserver(_ observer: NSObject, forKeyPath keyPath: String, context: UnsafeMutableRawPointer?) {
        removeKVO(observer, keyPath) { $0 == context }
    }

    private func removeKVO(_ observer: NSObject, _ keyPath: String, _ context: (UnsafeMutableRawPointer?) -> Bool) {
        let me = ObjectIdentifier(self), them = ObjectIdentifier(observer)
        KVO.classic.lock.lock()
        // Removes the most recent matching registration, as Foundation does.
        guard let i = KVO.classic.regs.lastIndex(where: { $0.object == me && $0.observerID == them && $0.keyPath == keyPath && context($0.context) }) else {
            KVO.classic.lock.unlock(); return
        }
        let r = KVO.classic.regs.remove(at: i)
        KVO.classic.lock.unlock()
        r.token.cancel()
    }
}
