// Core Foundation: allocators, run loops and their sources, absolute time,
// CFError. On the Mac, Foundation re-exports Core Foundation, so these are
// here in RunwayFoundation, which every staged file imports (RunwayCF, which
// the system frameworks re-export, is this module). Run loops map to
// Foundation's: work scheduled on the main run loop goes through the main
// dispatch queue, which RunLoop.main and Runway's UI backends drain.

import Foundation

public final class CFAllocator: @unchecked Sendable {
    init() {}
}

/// Every allocator argument is accepted and ignored (Swift manages memory).
public let kCFAllocatorDefault: CFAllocator? = nil
public let kCFAllocatorSystemDefault: CFAllocator? = nil
public let kCFAllocatorMalloc: CFAllocator? = nil
public let kCFAllocatorNull: CFAllocator? = nil

public typealias CFAllocatorRetainCallBack = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
public typealias CFAllocatorReleaseCallBack = @convention(c) (UnsafeRawPointer?) -> Void
/// (Returns an unretained CFString pointer; Swift can't spell Unmanaged in a C signature here.)
public typealias CFAllocatorCopyDescriptionCallBack = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?

public typealias CFError = NSError
public typealias CFSet = NSSet
public typealias CFPropertyList = CFTypeRef
public typealias UniChar = UInt16
public typealias CFMutableSet = NSMutableSet
public typealias CFUUID = NSUUID
public typealias CFStringEncoding = UInt32
public typealias CFMutableString = NSMutableString
public typealias CFDate = NSDate
public typealias CFHashCode = UInt

public struct CFRange: Equatable, Sendable {
    public var location: CFIndex
    public var length: CFIndex
    public init(location: CFIndex, length: CFIndex) { self.location = location; self.length = length }
    public init() { self.init(location: 0, length: 0) }
}
public func CFRangeMake(_ loc: CFIndex, _ len: CFIndex) -> CFRange { CFRange(location: loc, length: len) }
public typealias CFMutableArray = NSMutableArray
public typealias CFAbsoluteTime = Double
public typealias CFOptionFlags = UInt
public typealias Boolean = UInt8

public func CFAbsoluteTimeGetCurrent() -> CFAbsoluteTime { Date().timeIntervalSinceReferenceDate }

// MARK: Run loops

public struct CFRunLoopMode: RawRepresentable, Hashable, @unchecked Sendable {
    public let rawValue: CFString
    public init(rawValue: CFString) { self.rawValue = rawValue }
    public init(_ rawValue: CFString) { self.rawValue = rawValue }
    public static let defaultMode = CFRunLoopMode(rawValue: "kCFRunLoopDefaultMode" as NSString)
    public static let commonModes = CFRunLoopMode(rawValue: "kCFRunLoopCommonModes" as NSString)
    public static func == (a: CFRunLoopMode, b: CFRunLoopMode) -> Bool { (a.rawValue as String) == (b.rawValue as String) }
    public func hash(into h: inout Hasher) { h.combine(rawValue as String) }
}

public let kCFRunLoopDefaultMode: CFRunLoopMode = .defaultMode
public let kCFRunLoopCommonModes: CFRunLoopMode = .commonModes

/// A run loop: the main one, or a thread's Foundation RunLoop.
public final class CFRunLoop: @unchecked Sendable, Hashable {
    public let runLoop: RunLoop
    let isMain: Bool
    init(_ r: RunLoop, isMain: Bool) { runLoop = r; self.isMain = isMain }

    static let main = CFRunLoop(.main, isMain: true)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byThread: [ObjectIdentifier: CFRunLoop] = [:]

    static var current: CFRunLoop {
        if Thread.isMainThread { return main }
        let r = RunLoop.current
        lock.lock(); defer { lock.unlock() }
        if let l = byThread[ObjectIdentifier(r)] { return l }
        let l = CFRunLoop(r, isMain: false)
        byThread[ObjectIdentifier(r)] = l
        return l
    }

    /// Runs `work` on this run loop's thread, soon.
    public func perform(_ work: @escaping () -> Void) {
        if isMain { DispatchQueue.main.async(execute: work); return }
        let t = Timer(timeInterval: 0, repeats: false) { _ in work() }
        runLoop.add(t, forMode: .default)
    }

    public static func == (a: CFRunLoop, b: CFRunLoop) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

public func CFRunLoopGetMain() -> CFRunLoop! { CFRunLoop.main }
public func CFRunLoopGetCurrent() -> CFRunLoop! { CFRunLoop.current }
public func CFRunLoopRun() {
    let l = CFRunLoop.current
    l.stopped = false
    while !l.stopped, l.runLoop.run(mode: .default, before: .distantFuture) {}
}
public func CFRunLoopStop(_ rl: CFRunLoop!) {
    rl.stopped = true
    rl.perform {}
}
public func CFRunLoopWakeUp(_ rl: CFRunLoop!) { rl.perform {} }
public func CFRunLoopPerformBlock(_ rl: CFRunLoop!, _ mode: CFTypeRef!, _ block: (() -> Void)!) { rl.perform(block) }

extension CFRunLoop {
    private static var stopKey = 0
    var stopped: Bool {
        get { CFRunLoop.lock.lock(); defer { CFRunLoop.lock.unlock() }; return CFRunLoop.stops.contains(ObjectIdentifier(self)) }
        set {
            CFRunLoop.lock.lock(); defer { CFRunLoop.lock.unlock() }
            if newValue { CFRunLoop.stops.insert(ObjectIdentifier(self)) } else { CFRunLoop.stops.remove(ObjectIdentifier(self)) }
        }
    }
    nonisolated(unsafe) static var stops: Set<ObjectIdentifier> = []
}

/// A source added to a run loop: frameworks attach their event delivery to
/// it; adding it to a run loop routes the deliveries there.
public final class CFRunLoopSource: @unchecked Sendable {
    private let lock = NSLock()
    private var loops: [CFRunLoop] = []
    private var valid = true
    /// Called when first added to a run loop / removed from the last one.
    public var onSchedule: ((CFRunLoop) -> Void)?
    public var onInvalidate: (() -> Void)?
    public init() {}

    func add(_ rl: CFRunLoop) {
        lock.lock()
        let first = loops.isEmpty
        if !loops.contains(rl) { loops.append(rl) }
        lock.unlock()
        if first { onSchedule?(rl) }
    }
    func remove(_ rl: CFRunLoop) { lock.lock(); loops.removeAll { $0 == rl }; lock.unlock() }

    /// Delivers `work` on the run loop this source is scheduled on (if any).
    public func signal(_ work: @escaping () -> Void) {
        lock.lock()
        let rl = valid ? loops.first : nil
        lock.unlock()
        rl?.perform(work)
    }

    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }

    public func invalidate() {
        lock.lock()
        guard valid else { lock.unlock(); return }
        valid = false
        loops.removeAll()
        let h = onInvalidate
        lock.unlock()
        h?()
    }
}

public func CFRunLoopAddSource(_ rl: CFRunLoop!, _ source: CFRunLoopSource!, _ mode: CFRunLoopMode!) { source?.add(rl) }
public func CFRunLoopRemoveSource(_ rl: CFRunLoop!, _ source: CFRunLoopSource!, _ mode: CFRunLoopMode!) { source?.remove(rl) }
public func CFRunLoopContainsSource(_ rl: CFRunLoop!, _ source: CFRunLoopSource!, _ mode: CFRunLoopMode!) -> Bool { source?.isValid ?? false }
public func CFRunLoopSourceInvalidate(_ source: CFRunLoopSource!) { source?.invalidate() }
public func CFRunLoopSourceIsValid(_ source: CFRunLoopSource!) -> Bool { source?.isValid ?? false }

// MARK: Mach ports (event taps hand these out)

public final class CFMachPort: @unchecked Sendable {
    public let source = CFRunLoopSource()
    public init() {}
}
public func CFMachPortCreateRunLoopSource(_ allocator: CFAllocator?, _ port: CFMachPort!, _ order: CFIndex) -> CFRunLoopSource! { port?.source }
public func CFMachPortInvalidate(_ port: CFMachPort!) { port?.source.invalidate() }
public func CFMachPortIsValid(_ port: CFMachPort!) -> Bool { port?.source.isValid ?? false }
