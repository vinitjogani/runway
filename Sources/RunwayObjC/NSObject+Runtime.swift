// NSObject's runtime API (perform, responds, delayed performs, KVC) over the
// generated dispatch tables.

import Foundation

extension NSObjectProtocol {
    /// `respondsToSelector:`.
    public func responds(to aSelector: Selector!) -> Bool {
        guard let aSelector else { return false }
        return RunwayObjC.responds(self as AnyObject, to: aSelector)
    }

    @discardableResult
    public func perform(_ aSelector: Selector!) -> Unmanaged<AnyObject>! {
        unmanaged(RunwayObjC.perform(self as AnyObject, aSelector, []))
    }

    @discardableResult
    public func perform(_ aSelector: Selector!, with object: Any!) -> Unmanaged<AnyObject>! {
        unmanaged(RunwayObjC.perform(self as AnyObject, aSelector, [object as Any?]))
    }

    @discardableResult
    public func perform(_ aSelector: Selector!, with object1: Any!, with object2: Any!) -> Unmanaged<AnyObject>! {
        unmanaged(RunwayObjC.perform(self as AnyObject, aSelector, [object1 as Any?, object2 as Any?]))
    }
}

/// A zero-initialised value of a C-like type (an enum with a zero case, an
/// option set, a struct of scalars), as C gives an uninitialised result
/// slot: what stand-ins for Objective-C code return (see `runway`'s ObjCStandIns).
public func zeroed<T>() -> T {
    withUnsafeTemporaryAllocation(byteCount: max(MemoryLayout<T>.size, 1), alignment: max(MemoryLayout<T>.alignment, 1)) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        return buffer.baseAddress!.assumingMemoryBound(to: T.self).pointee
    }
}

/// Apple returns the result autoreleased; with no autorelease pool, the
/// result is retained once (a small leak) so `takeUnretainedValue()` is safe.
private func unmanaged(_ result: Any?) -> Unmanaged<AnyObject>? {
    guard let r = result, type(of: r) is AnyClass else { return nil }
    return Unmanaged.passRetained(r as AnyObject)
}

// MARK: Delayed and cross-thread performs

private final class PendingPerforms: @unchecked Sendable {
    let lock = NSLock()
    struct Entry { let id: Int; let target: ObjectIdentifier; let sel: Selector; let arg: ObjectIdentifier?; let argValue: String?; let timer: Timer }
    var entries: [Entry] = []
    var next = 0
}
private let pending = PendingPerforms()

extension NSObject {
    /// `performSelector:withObject:afterDelay:`, on the current run loop
    /// (the target and argument are retained until it fires).
    public func perform(_ aSelector: Selector, with anArgument: Any?, afterDelay delay: TimeInterval) {
        perform(aSelector, with: anArgument, afterDelay: delay, inModes: [.default])
    }

    public func perform(_ aSelector: Selector, with anArgument: Any?, afterDelay delay: TimeInterval, inModes modes: [RunLoop.Mode]) {
        pending.lock.lock()
        pending.next += 1
        let id = pending.next
        pending.lock.unlock()
        let target = self
        let timer = Timer(timeInterval: max(delay, 0), repeats: false) { _ in
            pending.lock.lock()
            pending.entries.removeAll { $0.id == id }
            pending.lock.unlock()
            RunwayObjC.perform(target, aSelector, [anArgument])
        }
        pending.lock.lock()
        pending.entries.append(.init(id: id, target: ObjectIdentifier(self), sel: aSelector, arg: identity(anArgument),
                                     argValue: anArgument.map { "\($0)" }, timer: timer))
        pending.lock.unlock()
        for mode in modes { RunLoop.current.add(timer, forMode: mode) }
    }

    /// `cancelPreviousPerformRequestsWithTarget:`.
    public class func cancelPreviousPerformRequests(withTarget aTarget: Any) {
        cancel { $0.target == ObjectIdentifier(aTarget as AnyObject) }
    }

    /// `cancelPreviousPerformRequestsWithTarget:selector:object:` (the
    /// argument matches by identity, or by value for non-objects).
    public class func cancelPreviousPerformRequests(withTarget aTarget: Any, selector aSelector: Selector, object anArgument: Any?) {
        let t = ObjectIdentifier(aTarget as AnyObject), a = identity(anArgument), v = anArgument.map { "\($0)" }
        cancel { $0.target == t && $0.sel == aSelector && (a != nil ? $0.arg == a : $0.argValue == v) }
    }

    private static func cancel(_ match: (PendingPerforms.Entry) -> Bool) {
        pending.lock.lock()
        let hit = pending.entries.filter(match)
        pending.entries.removeAll(where: match)
        pending.lock.unlock()
        for e in hit { e.timer.invalidate() }
    }

    /// `performSelectorOnMainThread:withObject:waitUntilDone:`.
    public func performSelector(onMainThread aSelector: Selector, with arg: Any?, waitUntilDone wait: Bool) {
        nonisolated(unsafe) let target = self, arg = arg
        if Thread.isMainThread {
            if wait { RunwayObjC.perform(target, aSelector, [arg]) }
            else { RunLoop.main.perform { RunwayObjC.perform(target, aSelector, [arg]) } }
        } else if wait {
            DispatchQueue.main.sync { RunwayObjC.perform(target, aSelector, [arg]) }
        } else {
            DispatchQueue.main.async { RunwayObjC.perform(target, aSelector, [arg]) }
        }
    }

    public func performSelector(onMainThread aSelector: Selector, with arg: Any?, waitUntilDone wait: Bool, modes: [String]?) {
        performSelector(onMainThread: aSelector, with: arg, waitUntilDone: wait)
    }

    /// `performSelectorInBackground:withObject:`.
    public func performSelector(inBackground aSelector: Selector, with arg: Any?) {
        nonisolated(unsafe) let target = self, arg = arg
        Thread.detachNewThread { RunwayObjC.perform(target, aSelector, [arg]) }
    }
}


// MARK: Keyed subscripts on untyped values

/// `dictionary["a"]?["b"]` on a typed dictionary: the plain lookup.
public func keyed<V>(_ base: [String: V]?, _ key: String) -> V? { base?[key] }
public func keyed<V>(_ base: [AnyHashable: V]?, _ key: String) -> V? { base?[key] }
public func keyed(_ base: NSDictionary?, _ key: String) -> Any? { base?[key] }

/// The same on an `AnyObject` (Objective-C's `objectForKeyedSubscript:`):
/// the value under `key` when the object is a dictionary.
public func keyed(_ base: AnyObject?, _ key: String) -> Any? {
    guard let base else { return nil }
    if let d = base as? NSDictionary { return d[key] }
    if let d = base as? [String: Any] { return d[key] }
    if let d = base as? [AnyHashable: Any] { return d[key] }
    var m = Message(.value(key))
    return handle(base, &m) ? m.result : nil
}


// MARK: Class names

extension NSObject {
    /// `className`: the class's name, without its module.
    public var className: String { String(describing: type(of: self)) }
    public class func className() -> String { String(describing: self) }
}
