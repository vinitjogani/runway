// NSClassFromString for Swift classes, without an Objective-C runtime.
//
// Interface Builder documents name an app's classes as strings
// (`customClass="PreferencesViewController" customModule="MyApp"`). Lookups
// go, in order, through:
//
//  1. classes registered at run time (`ClassRegistry.register`);
//  2. each module's generated table: the build tool can add one file per
//     staged module (`RunwayTranspiler.classRegistrySource`) declaring
//
//         enum _RunwayClassRegistry: RunwayObjC.ClassRegistryProviding {
//             static var classes: [(String, AnyClass)] { [("MyApp.Prefs", Prefs.self), ("CustomName", Renamed.self)] }
//         }
//
//     which is found by its mangled name, so nothing has to call it;
//  3. the Swift runtime's own metadata, by the class's mangled name
//     (`_typeByName`), for top-level and nested classes of the module.
//
// The modules searched are the one named, any registered with
// `ClassRegistry.addModule`, and the main executable's.

import Foundation

/// A module's generated class table (see above).
public protocol ClassRegistryProviding {
    /// (name, class): names are "Module.Class" and, for `@objc(Name)`
    /// classes, the Objective-C name.
    static var classes: [(String, AnyClass)] { get }
    /// `init()` for classes that have one (Swift can't call an initializer
    /// through a metatype unless it's `required`, and NSObject's isn't):
    /// what nib loading uses for custom objects.
    static var factories: [(AnyClass, @MainActor @Sendable () -> AnyObject?)] { get }
    /// `init(contentRect:styleMask:backing:defer:)` for window subclasses
    /// (the style mask's raw value).
    static var windowFactories: [(AnyClass, @MainActor @Sendable (CGRect, UInt) -> AnyObject)] { get }
}

extension ClassRegistryProviding {
    public static var factories: [(AnyClass, @MainActor @Sendable () -> AnyObject?)] { [] }
    public static var windowFactories: [(AnyClass, @MainActor @Sendable (CGRect, UInt) -> AnyObject)] { [] }
}

public enum ClassRegistry {
    private final class State: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var classes: [String: AnyClass] = [:]
        var modules: [String] = []
        var loadedTables: Set<String> = []
        var cache: [String: AnyClass?] = [:]
        var factories: [ObjectIdentifier: @MainActor @Sendable () -> AnyObject?] = [:]
        var windowFactories: [ObjectIdentifier: @MainActor @Sendable (CGRect, UInt) -> AnyObject] = [:]
    }
    private static let state = State()

    /// Registers `cls` under `name` ("Module.Class", or an Objective-C name).
    public static func register(_ cls: AnyClass, name: String) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.classes[name] = cls
        state.cache = [:]
    }

    /// Registers `cls` under its qualified Swift name (and its bare name).
    public static func register(_ cls: AnyClass) {
        let full = String(reflecting: cls)
        register(cls, name: full)
        if let module = full.split(separator: ".").first { addModule(String(module)) }
    }

    /// Registers how to make a `cls` with `init()`.
    public static func registerFactory(_ cls: AnyClass, _ make: @escaping @MainActor @Sendable () -> AnyObject?) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.factories[ObjectIdentifier(cls)] = make
    }

    /// `init()` for `cls`, when its module's table (or the app) registered one.
    public static func factory(for cls: AnyClass) -> (@MainActor @Sendable () -> AnyObject?)? {
        for m in modules { loadTable(m) }
        if let module = String(reflecting: cls).split(separator: ".").first { loadTable(String(module)) }
        state.lock.lock(); defer { state.lock.unlock() }
        return state.factories[ObjectIdentifier(cls)]
    }

    /// `init(contentRect:styleMask:backing:defer:)` for a window class.
    public static func windowFactory(for cls: AnyClass) -> (@MainActor @Sendable (CGRect, UInt) -> AnyObject)? {
        for m in modules { loadTable(m) }
        if let module = String(reflecting: cls).split(separator: ".").first { loadTable(String(module)) }
        state.lock.lock(); defer { state.lock.unlock() }
        return state.windowFactories[ObjectIdentifier(cls)]
    }

    /// Adds a module to search for classes named without one.
    public static func addModule(_ module: String) {
        guard !module.isEmpty else { return }
        state.lock.lock(); defer { state.lock.unlock() }
        if !state.modules.contains(module) { state.modules.append(module); state.cache = [:] }
    }

    /// Modules searched by default: registered ones, then the executable's.
    public static var modules: [String] {
        state.lock.lock(); defer { state.lock.unlock() }
        var out = state.modules
        for m in mainModuleCandidates where !out.contains(m) { out.append(m) }
        return out
    }

    /// The executable's module, as SwiftPM names it (its c99 name).
    static var mainModuleCandidates: [String] {
        var names: [String] = []
        if let exe = Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String { names.append(exe) }
        if let path = Bundle.main.executablePath ?? CommandLine.arguments.first {
            names.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        if let n = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String { names.append(n) }
        var out: [String] = []
        for n in names {
            let c = c99Name(n)
            if !c.isEmpty, !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// SwiftPM's module name for a target or product name.
    public static func c99Name(_ s: String) -> String {
        var out = String(s.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if let f = out.first, f.isNumber { out = "_" + out }
        return out
    }

    /// The class IB (or `NSClassFromString`) means by `name` in `module`
    /// (nil: the registered modules and the executable's).
    public static func lookup(_ name: String, module: String? = nil) -> AnyClass? {
        let key = (module ?? "") + "|" + name
        state.lock.lock()
        if let hit = state.cache[key] { state.lock.unlock(); return hit }
        state.lock.unlock()
        let found = resolve(name, module: module)
        state.lock.lock(); state.cache[key] = found; state.lock.unlock()
        return found
    }

    private static func resolve(_ name: String, module: String?) -> AnyClass? {
        // "Module.Class" names carry their module.
        var name = name, module = module
        let parts = name.split(separator: ".").map(String.init)
        if parts.count > 1, module == nil || module == parts[0] { module = parts[0]; name = parts.dropFirst().joined(separator: ".") }
        var mods: [String] = []
        if let m = module { mods.append(m) }
        for m in modules where !mods.contains(m) { mods.append(m) }
        for m in mods { loadTable(m) }

        state.lock.lock()
        let table = state.classes
        state.lock.unlock()
        for m in mods { if let c = table[m + "." + name] { return c } }
        if let c = table[name] { return c }
        for m in mods { if let c = typeByName(module: m, path: name) { return c } }
        return nil
    }

    private static func loadTable(_ module: String) {
        state.lock.lock()
        let done = !state.loadedTables.insert(module).inserted
        state.lock.unlock()
        if done { return }
        guard let t = _typeByName(mangle(module) + mangle("_RunwayClassRegistry") + "O") as? ClassRegistryProviding.Type else { return }
        let classes = t.classes
        let factories = t.factories, windowFactories = t.windowFactories
        state.lock.lock()
        for (n, c) in classes where state.classes[n] == nil { state.classes[n] = c }
        for (c, f) in factories where state.factories[ObjectIdentifier(c)] == nil { state.factories[ObjectIdentifier(c)] = f }
        for (c, f) in windowFactories { state.windowFactories[ObjectIdentifier(c)] = f }
        state.cache = [:]
        state.lock.unlock()
    }

    /// Finds `Outer.Inner` in `module` through the runtime's metadata: the
    /// class mangled as `<module><Outer><kind>…<Inner>C`, trying each kind
    /// (class, struct, enum) for the enclosing types.
    static func typeByName(module: String, path: String) -> AnyClass? {
        let comps = path.split(separator: ".").map(String.init)
        guard !comps.isEmpty, comps.allSatisfy({ $0.unicodeScalars.allSatisfy(\.isASCII) && !$0.isEmpty }) else { return nil }
        var prefixes = [mangle(module)]
        for c in comps.dropLast() {
            prefixes = prefixes.flatMap { p in ["C", "V", "O"].map { p + mangle(c) + $0 } }
            if prefixes.count > 27 { return nil }
        }
        for p in prefixes {
            if let t = _typeByName(p + mangle(comps.last!) + "C"), let c = t as? AnyClass { return c }
        }
        return nil
    }

    private static func mangle(_ identifier: String) -> String { "\(identifier.utf8.count)\(identifier)" }
}
