// Message dispatch without an Objective-C runtime.
//
// The transpiler gives every class with selector-reachable members (its
// `@objc` methods and properties, `@IBAction`s, methods named by a
// `#selector` or a selector string anywhere in the package, implementations
// of `@objc optional` requirements) a generated, statically typed handler:
//
//     class Doc: NSObject, @preconcurrency RunwayObjC.SelectorDispatching {
//         ...
//         func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool {
//             _runwayPart_Doc(&m, RunwayObjC.Part0.self) || ... }   // or super._runwayHandle(&m)
//     }
//     extension Doc {  // one per file that adds reachable members to Doc
//         func _runwayPart_Doc(_ m: inout RunwayObjC.Message, _: RunwayObjC.Part0.Type) -> Bool {
//             switch m.kind { case .perform(let s, let a): switch s.name {
//                 case "save:": m.result = RunwayObjC.box(self.save(RunwayObjC.arg(a, 0))); return true ...
//
// The functions below (perform, responds, sendAction, KVC) go through it.

import Foundation

// MARK: The message

/// One dynamic message to an object: a selector send, a "do you respond"
/// query, or a key-value coding access.
public struct Message {
    public enum Kind {
        case perform(Selector, [Any?])
        case responds(Selector)
        case value(String)
        case setValue(String, Any?)
    }
    public var kind: Kind
    /// What the handler returned (perform, value).
    public var result: Any?
    /// setValue: the property notifies key-value observers itself (it was
    /// `dynamic`), so KVC needn't.
    public var notifies = false
    public init(_ kind: Kind) { self.kind = kind }
}

/// A class with a generated dispatch table.
public protocol SelectorDispatching: AnyObject {
    /// Handles `m` if this object (or a superclass's table) knows it.
    func _runwayHandle(_ m: inout Message) -> Bool
}

extension SelectorDispatching {
    /// Sends `sel` with one argument; nil if not handled or it returns nothing.
    public func _runwayPerform(_ sel: Selector, with arg: Any?) -> Any? {
        var m = Message(.perform(sel, [arg]))
        return _runwayHandle(&m) ? m.result : nil
    }
    public func _runwayPerform(_ sel: Selector, arguments: [Any?]) -> Any? {
        var m = Message(.perform(sel, arguments))
        return _runwayHandle(&m) ? m.result : nil
    }
    public func _runwayResponds(to sel: Selector) -> Bool {
        var m = Message(.responds(sel))
        return _runwayHandle(&m)
    }
}

/// The same, for `@objc` members added in extensions to classes the package
/// doesn't declare (`extension NSWindow { @objc func toggle(_:) }`).
/// Framework modules must not adopt it themselves; they register handlers
/// with `registerSelector(_:for:_:)` instead.
public protocol ExternalSelectorDispatching: AnyObject {
    func _runwayHandleExternal(_ m: inout Message) -> Bool
}

/// Tags distinguishing the per-file parts of one class's dispatch table.
public protocol PartTag {}
public enum Part0: PartTag {}
public enum Part1: PartTag {}
public enum Part2: PartTag {}
public enum Part3: PartTag {}
public enum Part4: PartTag {}
public enum Part5: PartTag {}
public enum Part6: PartTag {}
public enum Part7: PartTag {}
public enum Part8: PartTag {}
public enum Part9: PartTag {}
public enum Part10: PartTag {}
public enum Part11: PartTag {}
public enum Part12: PartTag {}
public enum Part13: PartTag {}
public enum Part14: PartTag {}
public enum Part15: PartTag {}
public enum Part16: PartTag {}
public enum Part17: PartTag {}
public enum Part18: PartTag {}
public enum Part19: PartTag {}
public enum Part20: PartTag {}
public enum Part21: PartTag {}
public enum Part22: PartTag {}
public enum Part23: PartTag {}
public enum Part24: PartTag {}
public enum Part25: PartTag {}
public enum Part26: PartTag {}
public enum Part27: PartTag {}
public enum Part28: PartTag {}
public enum Part29: PartTag {}
public enum Part30: PartTag {}
public enum Part31: PartTag {}

// MARK: Registered handlers (framework classes)

public typealias SelectorHandler = (_ receiver: AnyObject, _ arguments: [Any?]) -> Any?

private final class Registry: @unchecked Sendable {
    let lock = NSLock()
    var handlers: [ObjectIdentifier: [String: SelectorHandler]] = [:]
}
private let registry = Registry()

/// Lets a framework class (which the transpiler never sees) answer a
/// selector: `registerSelector("terminate:", for: NSApplication.self) { app, args in ... }`.
/// Subclasses inherit it.
public func registerSelector(_ sel: Selector, for type: AnyClass, _ handler: @escaping SelectorHandler) {
    registry.lock.lock(); defer { registry.lock.unlock() }
    registry.handlers[ObjectIdentifier(type), default: [:]][sel.name] = handler
}

private func registeredHandler(_ sel: Selector, for object: AnyObject) -> SelectorHandler? {
    registry.lock.lock(); defer { registry.lock.unlock() }
    if registry.handlers.isEmpty { return nil }
    var t: AnyClass? = type(of: object)
    while let c = t {
        if let h = registry.handlers[ObjectIdentifier(c)]?[sel.name] { return h }
        t = _getSuperclass(c)
    }
    return nil
}

// MARK: Sending messages

/// Delivers `m` to `object`: its generated table, then extension tables,
/// then registered framework handlers.
public func handle(_ object: AnyObject, _ m: inout Message) -> Bool {
    if let d = object as? SelectorDispatching, d._runwayHandle(&m) { return true }
    if let d = object as? ExternalSelectorDispatching, d._runwayHandleExternal(&m) { return true }
    switch m.kind {
    case .perform(let sel, let args):
        if let h = registeredHandler(sel, for: object) { m.result = h(object, args); return true }
    case .responds(let sel):
        if registeredHandler(sel, for: object) != nil { return true }
    case .value, .setValue: break
    }
    return false
}

/// `[object performSelector:sel ...]`. Logs (rather than crashing, as the
/// Mac would) when nothing handles it.
@discardableResult
public func perform(_ object: AnyObject, _ sel: Selector, _ arguments: [Any?] = []) -> Any? {
    var m = Message(.perform(sel, arguments))
    if handle(object, &m) { return m.result }
    unrecognizedSelector(sel, object)
    return nil
}

/// `[object respondsToSelector:sel]`.
public func responds(_ object: AnyObject, to sel: Selector) -> Bool {
    if let o = object as? RespondsOverriding { return o.responds(to: sel) }
    var m = Message(.responds(sel))
    return handle(object, &m)
}

/// A class that overrides `responds(to:)` (the transpiler adopts this for
/// it): `respondsToSelector:` asks the override.
public protocol RespondsOverriding: AnyObject {
    func responds(to aSelector: Selector!) -> Bool
}

/// What `super.responds(to:)` becomes inside such an override: the answer
/// of the dispatch tables.
public func superResponds(_ object: AnyObject, to sel: Selector?) -> Bool {
    guard let sel else { return false }
    var m = Message(.responds(sel))
    return handle(object, &m)
}

public func unrecognizedSelector(_ sel: Selector, _ object: AnyObject) {
    FileHandle.standardError.write(Data("runway: unrecognized selector \(sel.name) sent to \(type(of: object))\n".utf8))
}

/// Hooks the UI layer fills in.
public enum ObjCRuntime {
    /// The responder chain for nil-targeted actions, first responder first
    /// (AppKit: key window's first responder … window, its delegate,
    /// NSApp, NSApp's delegate).
    nonisolated(unsafe) public static var responderChain: ((_ sender: Any?) -> [AnyObject])?
}

/// `NSApp.sendAction(_:to:from:)`: sends `action` with `sender` to `target`,
/// or to the first object in the responder chain that responds to it.
/// AppKit's `sendAction`, `NSControl` and `NSMenuItem` call this.
@discardableResult
public func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
    guard let receiver = RunwayObjC.target(forAction: action, to: target, from: sender) else { return false }
    var m = Message(.perform(action, [sender]))
    return handle(receiver, &m)
}

/// `NSApp.target(forAction:to:from:)`.
public func target(forAction action: Selector, to target: Any?, from sender: Any?) -> AnyObject? {
    if let t = target.map({ $0 as AnyObject }) {
        return responds(t, to: action) ? t : nil
    }
    for r in ObjCRuntime.responderChain?(sender) ?? [] where responds(r, to: action) { return r }
    return nil
}

/// `x?.optionalRequirement?(...)`: x when it implements the `@objc optional`
/// requirement `sel`, nil when it doesn't.
public func ifResponds<T>(_ x: T?, _ sel: Selector) -> T? {
    guard let x else { return nil }
    let o = x as AnyObject
    return responds(o, to: sel) ? x : nil
}

/// What `super.validateMenuItem(_:)` (and `validateToolbarItem`,
/// `validateUserInterfaceItem`) becomes when the superclass is a framework
/// class: enabled, as NSObject's default.
public func defaultValidation(_ item: Any?) -> Bool { true }

// MARK: Helpers the generated tables use

/// Argument `i` of a send, converted to the parameter's type (inferred).
public func arg<T>(_ args: [Any?], _ i: Int) -> T {
    let v: Any? = i < args.count ? args[i] : nil
    if let t = v as? T { return t }
    if let t = (v as Any) as? T { return t }
    // Key-value coding unboxes numbers into scalar properties (an NSNumber
    // for a CGFloat, Int or Bool), as the Objective-C runtime does.
    if let t: T = unboxNumber(v) { return t }
    // An optional parameter (an outlet, an optional argument) given another
    // type: nil, with a note, rather than a crash (a nib connection to an
    // object that isn't what the property declares).
    if v != nil, let none = (Optional<Any>.none as Any) as? T {
        unrecognizedArgument(v, T.self)
        return none
    }
    fatalError("runway: selector argument \(i) is \(v.map { "\(type(of: $0))" } ?? "nil"), not \(T.self)")
}

/// A number (NSNumber or a Swift numeric) as a scalar type `T` (or `T?`).
func unboxNumber<T>(_ v: Any?) -> T? {
    guard let v = v.flatMap({ flatten($0) }) else { return nil }
    let d: Double
    switch v {
    case let n as NSNumber: d = n.doubleValue
    case let x as Double: d = x
    case let x as Float: d = Double(x)
    case let x as CGFloat: d = Double(x)
    case let x as Int: d = Double(x)
    case let x as Bool: d = x ? 1 : 0
    default: return nil
    }
    let candidates: [Any] = [CGFloat(d), d, Float(d), Int(exactly: d.rounded(.towardZero)) ?? 0, d != 0,
                             Int32(clamping: Int(d)), Int64(d), UInt(clamping: Int(d)), Int16(clamping: Int(d)), UInt8(clamping: Int(d))]
    for c in candidates {
        if let t = c as? T { return t }
        if let t = Optional(c) as? T { return t }
    }
    return nil
}

/// A method's return value as a send result (nothing for Void, unwrapped
/// optionals).
public func box<T>(_ v: T) -> Any? {
    if T.self == Void.self { return nil }
    return flatten(v)
}

func flatten(_ v: Any) -> Any? {
    let m = Mirror(reflecting: v)
    if m.displayStyle == .optional {
        guard let inner = m.children.first?.value else { return nil }
        return flatten(inner)
    }
    return v
}

/// Same-object check across `Any?` (perform's `with:` arguments).
func identity(_ x: Any?) -> ObjectIdentifier? {
    guard let x = flatten(x as Any) else { return nil }
    if type(of: x) is AnyClass { return ObjectIdentifier(x as AnyObject) }
    return nil
}

/// What `super.awakeFromNib()` becomes in a class rooted in NSObject
/// (NSObject's implementation does nothing).
public func nsObjectHook() {}

func unrecognizedArgument(_ v: Any?, _ t: Any.Type) {
    FileHandle.standardError.write(Data("runway: argument \(v.map { "\(type(of: $0))" } ?? "nil") isn't a \(t); passing nil\n".utf8))
}
