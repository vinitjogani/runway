// Foundation classes swift-corelibs-foundation doesn't have: the weak
// collections (NSHashTable, NSMapTable, NSPointerArray), the formatters it
// marks unavailable (DateComponentsFormatter, RelativeDateTimeFormatter,
// ListFormatter), and small API of URL and the geometry types.

import Foundation

// MARK: NSHashTable

private final class WeakBox<T: AnyObject> {
    weak var object: T?
    init(_ object: T) { self.object = object }
}

/// How a pointer collection holds and compares its elements.
open class NSPointerFunctions: NSObject, @unchecked Sendable {
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let strongMemory = Options([])
        public static let opaqueMemory = Options(rawValue: 2)
        public static let mallocMemory = Options(rawValue: 3)
        public static let machVirtualMemory = Options(rawValue: 4)
        public static let weakMemory = Options(rawValue: 5)
        public static let objectPersonality = Options([])
        public static let opaquePersonality = Options(rawValue: 1 << 8)
        public static let objectPointerPersonality = Options(rawValue: 2 << 8)
        public static let cStringPersonality = Options(rawValue: 3 << 8)
        public static let structPersonality = Options(rawValue: 4 << 8)
        public static let integerPersonality = Options(rawValue: 5 << 8)
        public static let copyIn = Options(rawValue: 1 << 16)
    }
    public let options: Options
    public init(options: Options = []) { self.options = options; super.init() }
}

/// A set of objects compared by identity (pointer personality) or
/// equality, held strongly or weakly. Weak members vanish when they die.
public final class NSHashTable<ObjectType: AnyObject>: NSObject, Sequence, @unchecked Sendable {
    private let weak: Bool
    private let byIdentity: Bool
    private var strong: [ObjectType] = []
    private var weakBoxes: [WeakBox<ObjectType>] = []
    private let lock = NSRecursiveLock()

    public init(options: NSPointerFunctions.Options = [], capacity: Int = 0) {
        weak = options.contains(.weakMemory)
        byIdentity = options.contains(.objectPointerPersonality) || !(ObjectType.self is NSObject.Type)
        super.init()
    }
    public convenience override init() { self.init(options: [], capacity: 0) }
    public class func weakObjects() -> NSHashTable<ObjectType> { NSHashTable(options: .weakMemory) }
    public convenience init(pointerFunctions: NSPointerFunctions, capacity: Int) { self.init(options: pointerFunctions.options, capacity: capacity) }

    private func same(_ a: ObjectType, _ b: ObjectType) -> Bool {
        if a === b { return true }
        if byIdentity { return false }
        if let x = a as? NSObject, let y = b as? NSObject { return x.isEqual(y) }
        return false
    }

    public var allObjects: [ObjectType] {
        lock.lock(); defer { lock.unlock() }
        if weak {
            weakBoxes.removeAll { $0.object == nil }
            return weakBoxes.compactMap(\.object)
        }
        return strong
    }
    public var count: Int { allObjects.count }
    public var anyObject: ObjectType? { allObjects.first }
    public var setRepresentation: Set<AnyHashable> { Set(allObjects.map { AnyHashable(ObjectIdentifier($0)) }) }

    public func member(_ object: ObjectType?) -> ObjectType? {
        guard let object else { return nil }
        return allObjects.first { same($0, object) }
    }
    public func contains(_ object: ObjectType?) -> Bool { member(object) != nil }

    public func add(_ object: ObjectType?) {
        guard let object, !contains(object) else { return }
        lock.lock(); defer { lock.unlock() }
        if weak { weakBoxes.append(WeakBox(object)) } else { strong.append(object) }
    }
    public func remove(_ object: ObjectType?) {
        guard let object else { return }
        lock.lock(); defer { lock.unlock() }
        if weak { weakBoxes.removeAll { $0.object == nil || same($0.object!, object) } } else { strong.removeAll { same($0, object) } }
    }
    public func removeAllObjects() {
        lock.lock(); defer { lock.unlock() }
        strong = []
        weakBoxes = []
    }
    public func objectEnumerator() -> NSEnumerator { (allObjects as NSArray).objectEnumerator() }
    public func makeIterator() -> IndexingIterator<[ObjectType]> { allObjects.makeIterator() }

    public func union(_ other: NSHashTable<ObjectType>) { for o in other.allObjects { add(o) } }
    public func minus(_ other: NSHashTable<ObjectType>) { for o in other.allObjects { remove(o) } }
    public func intersect(_ other: NSHashTable<ObjectType>) { for o in allObjects where !other.contains(o) { remove(o) } }
    public func intersects(_ other: NSHashTable<ObjectType>) -> Bool { allObjects.contains { other.contains($0) } }
    public func isSubset(of other: NSHashTable<ObjectType>) -> Bool { allObjects.allSatisfy { other.contains($0) } }
    public func isEqual(to other: NSHashTable<ObjectType>) -> Bool { count == other.count && isSubset(of: other) }
}

// MARK: NSMapTable

/// A dictionary whose keys and values may be held weakly; keys compare by
/// identity unless they're NSObjects of a non-pointer personality.
public final class NSMapTable<KeyType: AnyObject, ObjectType: AnyObject>: NSObject, @unchecked Sendable {
    private struct Entry {
        var strongKey: KeyType?
        weak var weakKey: KeyType?
        var strongValue: ObjectType?
        weak var weakValue: ObjectType?
    }
    private let weakKeys: Bool, weakValues: Bool, byIdentity: Bool
    private var entries: [Entry] = []
    private let lock = NSRecursiveLock()

    public init(keyOptions: NSPointerFunctions.Options = [], valueOptions: NSPointerFunctions.Options = [], capacity: Int = 0) {
        weakKeys = keyOptions.contains(.weakMemory)
        weakValues = valueOptions.contains(.weakMemory)
        byIdentity = keyOptions.contains(.objectPointerPersonality) || !(KeyType.self is NSObject.Type)
        super.init()
    }
    public convenience override init() { self.init(keyOptions: [], valueOptions: [], capacity: 0) }
    public class func strongToStrongObjects() -> NSMapTable<KeyType, ObjectType> { NSMapTable(keyOptions: [], valueOptions: []) }
    public class func weakToStrongObjects() -> NSMapTable<KeyType, ObjectType> { NSMapTable(keyOptions: .weakMemory, valueOptions: []) }
    public class func strongToWeakObjects() -> NSMapTable<KeyType, ObjectType> { NSMapTable(keyOptions: [], valueOptions: .weakMemory) }
    public class func weakToWeakObjects() -> NSMapTable<KeyType, ObjectType> { NSMapTable(keyOptions: .weakMemory, valueOptions: .weakMemory) }

    private func key(_ e: Entry) -> KeyType? { weakKeys ? e.weakKey : e.strongKey }
    private func value(_ e: Entry) -> ObjectType? { weakValues ? e.weakValue : e.strongValue }
    private func same(_ a: KeyType, _ b: KeyType) -> Bool {
        if a === b { return true }
        if byIdentity { return false }
        if let x = a as? NSObject, let y = b as? NSObject { return x.isEqual(y) }
        return false
    }
    private func prune() { entries.removeAll { key($0) == nil || value($0) == nil } }

    public func object(forKey aKey: KeyType?) -> ObjectType? {
        guard let aKey else { return nil }
        lock.lock(); defer { lock.unlock() }
        prune()
        return entries.first { key($0).map { same($0, aKey) } ?? false }.flatMap(value)
    }
    public func setObject(_ anObject: ObjectType?, forKey aKey: KeyType?) {
        guard let aKey else { return }
        lock.lock(); defer { lock.unlock() }
        entries.removeAll { e in key(e).map { same($0, aKey) } ?? true }
        guard let anObject else { return }
        var e = Entry()
        if weakKeys { e.weakKey = aKey } else { e.strongKey = aKey }
        if weakValues { e.weakValue = anObject } else { e.strongValue = anObject }
        entries.append(e)
    }
    public func removeObject(forKey aKey: KeyType?) { setObject(nil, forKey: aKey) }
    /// NSObject's `doesContain(_:)`: whether the object is among the values.
    public func doesContain(_ object: Any) -> Bool {
        lock.lock(); defer { lock.unlock() }
        prune()
        let o = object as AnyObject
        return entries.contains { value($0) === o }
    }
    public func removeAllObjects() { lock.lock(); entries = []; lock.unlock() }
    public var count: Int { lock.lock(); defer { lock.unlock() }; prune(); return entries.count }
    public func keyEnumerator() -> NSEnumerator {
        lock.lock(); defer { lock.unlock() }
        prune()
        return (entries.compactMap(key) as NSArray).objectEnumerator()
    }
    public func objectEnumerator() -> NSEnumerator? {
        lock.lock(); defer { lock.unlock() }
        prune()
        return (entries.compactMap(value) as NSArray).objectEnumerator()
    }
    public func dictionaryRepresentation() -> [AnyHashable: ObjectType] {
        lock.lock(); defer { lock.unlock() }
        prune()
        var out: [AnyHashable: ObjectType] = [:]
        for e in entries {
            guard let k = key(e), let v = value(e) else { continue }
            out[(k as? AnyHashable) ?? AnyHashable(ObjectIdentifier(k))] = v
        }
        return out
    }
}

// MARK: NSPointerArray

/// An array of object references, strong or weak, with nil slots.
public final class NSPointerArray: NSObject, @unchecked Sendable {
    private final class Slot { weak var weakObject: AnyObject?; var strongObject: AnyObject? }
    private let weak: Bool
    private var slots: [Slot] = []

    public init(options: NSPointerFunctions.Options = []) {
        weak = options.contains(.weakMemory)
        super.init()
    }
    public class func weakObjects() -> NSPointerArray { NSPointerArray(options: .weakMemory) }
    public class func strongObjects() -> NSPointerArray { NSPointerArray(options: []) }

    public var count: Int {
        get { slots.count }
        set { while slots.count < newValue { slots.append(Slot()) }; if slots.count > newValue { slots.removeLast(slots.count - newValue) } }
    }
    public var allObjects: [Any] { slots.compactMap { weak ? $0.weakObject : $0.strongObject } }

    private func object(_ s: Slot) -> AnyObject? { weak ? s.weakObject : s.strongObject }
    public func pointer(at index: Int) -> UnsafeMutableRawPointer? {
        object(slots[index]).map { Unmanaged.passUnretained($0).toOpaque() }
    }
    public func addPointer(_ pointer: UnsafeMutableRawPointer?) { insertPointer(pointer, at: slots.count) }
    public func insertPointer(_ pointer: UnsafeMutableRawPointer?, at index: Int) {
        let s = Slot()
        if let pointer {
            let o = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            if weak { s.weakObject = o } else { s.strongObject = o }
        }
        slots.insert(s, at: index)
    }
    public func replacePointer(at index: Int, withPointer pointer: UnsafeMutableRawPointer?) {
        removePointer(at: index)
        insertPointer(pointer, at: index)
    }
    public func removePointer(at index: Int) { slots.remove(at: index) }
    /// Drops the slots whose object is gone.
    public func compact() { slots.removeAll { object($0) == nil } }
}

// MARK: Formatters

/// `DateComponentsFormatter` (unavailable in corelibs): durations as
/// "1:05:09" (positional), "1h 5m" (abbreviated), "1 hour, 5 minutes" (full).
open class DateComponentsFormatter: Formatter, @unchecked Sendable {
    public enum UnitsStyle: Int, Sendable { case positional = 0, abbreviated, short, full, spellOut, brief }
    public struct ZeroFormattingBehavior: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let none = ZeroFormattingBehavior([])
        public static let `default` = ZeroFormattingBehavior(rawValue: 1 << 0)
        public static let dropLeading = ZeroFormattingBehavior(rawValue: 1 << 1)
        public static let dropMiddle = ZeroFormattingBehavior(rawValue: 1 << 2)
        public static let dropTrailing = ZeroFormattingBehavior(rawValue: 1 << 3)
        public static let dropAll: ZeroFormattingBehavior = [.dropLeading, .dropMiddle, .dropTrailing]
        public static let pad = ZeroFormattingBehavior(rawValue: 1 << 16)
    }
    open var unitsStyle: UnitsStyle = .positional
    open var allowedUnits: NSCalendar.Unit = [.hour, .minute, .second]
    open var zeroFormattingBehavior: ZeroFormattingBehavior = .default
    open var calendar: Calendar? = .current
    open var maximumUnitCount = 0
    open var allowsFractionalUnits = false
    open var collapsesLargestUnit = false
    open var includesApproximationPhrase = false
    open var includesTimeRemainingPhrase = false
    open var referenceDate: Date?
    open var formattingContext: Formatter.Context = .unknown

    public override init() { super.init() }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    private static let units: [(NSCalendar.Unit, Double, String, String, String)] = [
        (.year, 31_536_000, "y", "yr", "year"), (.month, 2_592_000, "mo", "mo", "month"), (.weekOfMonth, 604_800, "w", "wk", "week"),
        (.day, 86_400, "d", "day", "day"), (.hour, 3600, "h", "hr", "hour"), (.minute, 60, "m", "min", "minute"), (.second, 1, "s", "sec", "second"),
    ]

    open func string(from ti: TimeInterval) -> String? {
        var remaining = abs(ti.rounded())
        var parts: [(value: Int, unit: (NSCalendar.Unit, Double, String, String, String))] = []
        let used = Self.units.filter { allowedUnits.contains($0.0) }
        for (i, u) in used.enumerated() {
            let v = i == used.count - 1 ? Int((remaining / u.1).rounded()) : Int(remaining / u.1)
            remaining -= Double(v) * u.1
            parts.append((v, u))
        }
        guard !parts.isEmpty else { return nil }
        let sign = ti < 0 ? "-" : ""
        if unitsStyle == .positional {
            var p = parts
            let pad = zeroFormattingBehavior.contains(.pad)
            if !pad { while p.count > (used.contains { $0.0 == .minute } && p.count > 1 ? 2 : 1), p.first?.value == 0 { p.removeFirst() } }
            if maximumUnitCount > 0, p.count > maximumUnitCount { p = Array(p.prefix(maximumUnitCount)) }
            return sign + p.enumerated().map { i, e in i == 0 && !pad ? "\(e.value)" : String(format: "%02d", e.value) }.joined(separator: ":")
        }
        var p = parts.filter { $0.value != 0 }
        if p.isEmpty, let last = parts.last { p = [last] }
        if maximumUnitCount > 0, p.count > maximumUnitCount { p = Array(p.prefix(maximumUnitCount)) }
        let texts = p.map { e -> String in
            switch unitsStyle {
            case .abbreviated: return "\(e.value)\(e.unit.2)"
            case .brief, .short: return "\(e.value) \(e.unit.3)" + (unitsStyle == .short && e.value != 1 && e.unit.3.count > 2 ? "s" : "")
            default: return "\(e.value) \(e.unit.4)" + (e.value == 1 ? "" : "s")
            }
        }
        return sign + texts.joined(separator: unitsStyle == .abbreviated || unitsStyle == .brief ? " " : ", ")
    }
    open func string(from start: Date, to end: Date) -> String? { string(from: end.timeIntervalSince(start)) }
    open func string(from components: DateComponents) -> String? {
        var t = 0.0
        t += Double(components.second ?? 0) + Double(components.minute ?? 0) * 60 + Double(components.hour ?? 0) * 3600
        t += Double(components.day ?? 0) * 86_400 + Double(components.weekOfMonth ?? 0) * 604_800
        t += Double(components.month ?? 0) * 2_592_000 + Double(components.year ?? 0) * 31_536_000
        return string(from: t)
    }
    open override func string(for obj: Any?) -> String? {
        if let t = obj as? TimeInterval { return string(from: t) }
        if let c = obj as? DateComponents { return string(from: c) }
        if let n = obj as? NSNumber { return string(from: n.doubleValue) }
        return nil
    }
    open class func localizedString(from components: DateComponents, unitsStyle: UnitsStyle) -> String? {
        let f = DateComponentsFormatter()
        f.unitsStyle = unitsStyle
        f.allowedUnits = [.year, .month, .day, .hour, .minute, .second]
        return f.string(from: components)
    }
}

/// `RelativeDateTimeFormatter`: "in 5 minutes", "2 hours ago", "yesterday".
open class RelativeDateTimeFormatter: Formatter, @unchecked Sendable {
    public enum DateTimeStyle: Int, Sendable { case numeric = 0, named }
    public enum UnitsStyle: Int, Sendable { case full = 0, spellOut, short, abbreviated }
    open var dateTimeStyle: DateTimeStyle = .numeric
    open var unitsStyle: UnitsStyle = .full
    open var formattingContext: Formatter.Context = .unknown
    open var calendar: Calendar! = .current
    open var locale: Locale! = .current

    public override init() { super.init() }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    open func localizedString(fromTimeInterval timeInterval: TimeInterval) -> String {
        let s = abs(timeInterval)
        let (value, unit): (Int, String)
        switch s {
        case ..<60: (value, unit) = (Int(s), unitsStyle == .full || unitsStyle == .spellOut ? "second" : "sec.")
        case ..<3600: (value, unit) = (Int(s / 60), unitsStyle == .full || unitsStyle == .spellOut ? "minute" : "min.")
        case ..<86_400: (value, unit) = (Int(s / 3600), unitsStyle == .full || unitsStyle == .spellOut ? "hour" : "hr.")
        case ..<604_800: (value, unit) = (Int(s / 86_400), "day")
        case ..<2_592_000: (value, unit) = (Int(s / 604_800), unitsStyle == .full || unitsStyle == .spellOut ? "week" : "wk.")
        case ..<31_536_000: (value, unit) = (Int(s / 2_592_000), unitsStyle == .full || unitsStyle == .spellOut ? "month" : "mo.")
        default: (value, unit) = (Int(s / 31_536_000), unitsStyle == .full || unitsStyle == .spellOut ? "year" : "yr.")
        }
        if dateTimeStyle == .named {
            if value == 0 { return "now" }
            if value == 1, unit == "day" { return timeInterval < 0 ? "yesterday" : "tomorrow" }
        }
        let plural = value == 1 || unit.hasSuffix(".") ? unit : unit + "s"
        return timeInterval < 0 ? "\(value) \(plural) ago" : "in \(value) \(plural)"
    }
    open func localizedString(for date: Date, relativeTo referenceDate: Date) -> String {
        localizedString(fromTimeInterval: date.timeIntervalSince(referenceDate))
    }
    open func localizedString(from dateComponents: DateComponents) -> String {
        var t = 0.0
        t += Double(dateComponents.second ?? 0) + Double(dateComponents.minute ?? 0) * 60 + Double(dateComponents.hour ?? 0) * 3600
        t += Double(dateComponents.day ?? 0) * 86_400 + Double(dateComponents.month ?? 0) * 2_592_000 + Double(dateComponents.year ?? 0) * 31_536_000
        return localizedString(fromTimeInterval: t)
    }
    open override func string(for obj: Any?) -> String? {
        (obj as? Date).map { localizedString(for: $0, relativeTo: Date()) }
    }
}

/// `ListFormatter`: "a, b, and c".
open class ListFormatter: Formatter, @unchecked Sendable {
    open var locale: Locale! = .current
    open var itemFormatter: Formatter?
    public override init() { super.init() }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    open class func localizedString(byJoining strings: [String]) -> String {
        switch strings.count {
        case 0: return ""
        case 1: return strings[0]
        case 2: return strings[0] + " and " + strings[1]
        default: return strings.dropLast().joined(separator: ", ") + ", and " + strings[strings.count - 1]
        }
    }
    open func string(from items: [Any]) -> String? {
        ListFormatter.localizedString(byJoining: items.map { itemFormatter?.string(for: $0) ?? "\($0)" })
    }
    open override func string(for obj: Any?) -> String? { (obj as? [Any]).flatMap(string(from:)) }
}

// MARK: URL

extension URL {
    private static func directory(_ d: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: d, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory())
    }
    public static var documentsDirectory: URL { directory(.documentDirectory) }
    public static var downloadsDirectory: URL { directory(.downloadsDirectory) }
    public static var desktopDirectory: URL { directory(.desktopDirectory) }
    public static var applicationSupportDirectory: URL { directory(.applicationSupportDirectory) }
    public static var cachesDirectory: URL { directory(.cachesDirectory) }
    public static var libraryDirectory: URL { directory(.libraryDirectory) }
    public static var moviesDirectory: URL { directory(.moviesDirectory) }
    public static var musicDirectory: URL { directory(.musicDirectory) }
    public static var picturesDirectory: URL { directory(.picturesDirectory) }
    public static var applicationDirectory: URL { URL(fileURLWithPath: "/usr/share/applications", isDirectory: true) }
    public static var userDirectory: URL { URL(fileURLWithPath: "/home", isDirectory: true) }
    public static var trashDirectory: URL { directory(.trashDirectory) }
}

// MARK: Geometry

extension CGRect {
    public func equalTo(_ rect2: CGRect) -> Bool { self == rect2 }
}
extension CGPoint {
    public func equalTo(_ point2: CGPoint) -> Bool { self == point2 }
}
extension CGSize {
    public func equalTo(_ size2: CGSize) -> Bool { self == size2 }
}


extension CGPoint: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String { "(\(x), \(y))" }
}
extension CGSize: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String { "(\(width), \(height))" }
}
extension CGRect: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String { "(\(origin.x), \(origin.y), \(size.width), \(size.height))" }
}

// MARK: Mach ports on run loops

extension RunLoop {
    /// `CFMachPort` is toll-free bridged to `NSMachPort` on a Mac, so event
    /// taps are added to a run loop this way. Ports here deliver through
    /// their own source, so there is nothing to schedule.
    public func add(_ port: CFMachPort, forMode mode: RunLoop.Mode) {}
    public func remove(_ port: CFMachPort, forMode mode: RunLoop.Mode) {}
}


// MARK: Security-scoped URLs

extension URL {
    /// There is no app sandbox here: every URL is already accessible.
    public func startAccessingSecurityScopedResource() -> Bool { true }
    public func stopAccessingSecurityScopedResource() {}
}
extension NSURL {
    public func startAccessingSecurityScopedResource() -> Bool { true }
    public func stopAccessingSecurityScopedResource() {}
}


// MARK: UserDefaults and CGFloat

extension UserDefaults {
    /// `set(_:forKey:)` for values typed `Any`: on a Mac a CGFloat boxed as
    /// an object is an NSNumber; corelibs leaves it an opaque box that
    /// UserDefaults can't write (it traps). The build tool routes untyped
    /// `set` calls on UserDefaults here, where CGFloats (also inside arrays
    /// and dictionaries) become Doubles first.
    public func _runwaySet(_ value: Any?, forKey defaultName: String) {
        set(UserDefaults._runwayPropertyListValue(value), forKey: defaultName)
    }
    static func _runwayPropertyListValue(_ value: Any?) -> Any? {
        switch value {
        case let f as CGFloat: return Double(f)
        case let a as [Any]: return a.map { _runwayPropertyListValue($0) ?? NSNull() }
        case let d as [String: Any]: return d.mapValues { _runwayPropertyListValue($0) ?? NSNull() }
        default: return value
        }
    }
}
