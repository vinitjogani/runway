// FSEvents for Linux and Windows. A stream watches its paths recursively
// with inotify (Linux: a watch per directory, added as directories appear)
// or ReadDirectoryChangesW (Windows: one recursive handle per root), on a
// thread of its own that sleeps until the kernel has events, coalesces them
// for the stream's latency (leading edge with NoDefer, trailing otherwise,
// as FSEvents does), and delivers on the stream's dispatch queue or run
// loop. Directory-level streams report each changed directory (with a
// trailing slash, flags none); kFSEventStreamCreateFlagFileEvents streams
// report each item with ItemCreated/Removed/Renamed/Modified/… and
// ItemIsFile/ItemIsDir. Event ids count up from the first stream in the
// process; there's no history, so `sinceWhen` other than now starts now.

@_exported import RunwayCF
@_exported import Security
import Foundation
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

public typealias FSEventStreamRef = OpaquePointer
public typealias ConstFSEventStreamRef = OpaquePointer
public typealias FSEventStreamEventId = UInt64
public typealias FSEventStreamCreateFlags = UInt32
public typealias FSEventStreamEventFlags = UInt32

public typealias FSEventStreamCallback = @convention(c) (
    ConstFSEventStreamRef, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer,
    UnsafePointer<FSEventStreamEventFlags>, UnsafePointer<FSEventStreamEventId>) -> Void

public struct FSEventStreamContext {
    public var version: CFIndex
    public var info: UnsafeMutableRawPointer?
    public var retain: CFAllocatorRetainCallBack?
    public var release: CFAllocatorReleaseCallBack?
    public var copyDescription: CFAllocatorCopyDescriptionCallBack?
    public init() { version = 0 }
    public init(version: CFIndex, info: UnsafeMutableRawPointer?, retain: CFAllocatorRetainCallBack?,
                release: CFAllocatorReleaseCallBack?, copyDescription: CFAllocatorCopyDescriptionCallBack?) {
        self.version = version; self.info = info; self.retain = retain; self.release = release; self.copyDescription = copyDescription
    }
}

public var kFSEventStreamCreateFlagNone: Int { 0x00000000 }
public var kFSEventStreamCreateFlagUseCFTypes: Int { 0x00000001 }
public var kFSEventStreamCreateFlagNoDefer: Int { 0x00000002 }
public var kFSEventStreamCreateFlagWatchRoot: Int { 0x00000004 }
public var kFSEventStreamCreateFlagIgnoreSelf: Int { 0x00000008 }
public var kFSEventStreamCreateFlagFileEvents: Int { 0x00000010 }
public var kFSEventStreamCreateFlagMarkSelf: Int { 0x00000020 }
public var kFSEventStreamCreateFlagUseExtendedData: Int { 0x00000040 }
public var kFSEventStreamCreateFlagFullHistory: Int { 0x00000080 }
public var kFSEventStreamCreateWithDocID: Int { 0x00000100 }

public var kFSEventStreamEventFlagNone: Int { 0x00000000 }
public var kFSEventStreamEventFlagMustScanSubDirs: Int { 0x00000001 }
public var kFSEventStreamEventFlagUserDropped: Int { 0x00000002 }
public var kFSEventStreamEventFlagKernelDropped: Int { 0x00000004 }
public var kFSEventStreamEventFlagEventIdsWrapped: Int { 0x00000008 }
public var kFSEventStreamEventFlagHistoryDone: Int { 0x00000010 }
public var kFSEventStreamEventFlagRootChanged: Int { 0x00000020 }
public var kFSEventStreamEventFlagMount: Int { 0x00000040 }
public var kFSEventStreamEventFlagUnmount: Int { 0x00000080 }
public var kFSEventStreamEventFlagItemCreated: Int { 0x00000100 }
public var kFSEventStreamEventFlagItemRemoved: Int { 0x00000200 }
public var kFSEventStreamEventFlagItemInodeMetaMod: Int { 0x00000400 }
public var kFSEventStreamEventFlagItemRenamed: Int { 0x00000800 }
public var kFSEventStreamEventFlagItemModified: Int { 0x00001000 }
public var kFSEventStreamEventFlagItemFinderInfoMod: Int { 0x00002000 }
public var kFSEventStreamEventFlagItemChangeOwner: Int { 0x00004000 }
public var kFSEventStreamEventFlagItemXattrMod: Int { 0x00008000 }
public var kFSEventStreamEventFlagItemIsFile: Int { 0x00010000 }
public var kFSEventStreamEventFlagItemIsDir: Int { 0x00020000 }
public var kFSEventStreamEventFlagItemIsSymlink: Int { 0x00040000 }
public var kFSEventStreamEventFlagOwnEvent: Int { 0x00080000 }
public var kFSEventStreamEventFlagItemIsHardlink: Int { 0x00100000 }
public var kFSEventStreamEventFlagItemIsLastHardlink: Int { 0x00200000 }
public var kFSEventStreamEventFlagItemCloned: Int { 0x00400000 }

public var kFSEventStreamEventIdSinceNow: UInt64 { 0xFFFFFFFFFFFFFFFF }
public let kFSEventStreamEventExtendedDataPathKey = "path"
public let kFSEventStreamEventExtendedFileIDKey = "fileID"
public let kFSEventStreamEventExtendedDocIDKey = "docID"

// MARK: The stream

final class FSStream: @unchecked Sendable {
    struct Event { var path: String; var flags: UInt32; var inode: UInt64 }

    let callback: FSEventStreamCallback
    var context: FSEventStreamContext
    let roots: [String]
    let latency: Double
    let flags: Int
    let lock = NSLock()
    var queue: DispatchQueue?
    var runLoop: CFRunLoop?
    var pending: [Event] = []
    var started = false
    var invalidated = false
    var watcher: FSWatcher?
    var flushScheduled = false
    var lastDelivery = Date.distantPast
    var refCount = 1

    static let idLock = NSLock()
    nonisolated(unsafe) static var lastId: UInt64 = 0
    static func nextId() -> UInt64 { idLock.lock(); defer { idLock.unlock() }; lastId += 1; return lastId }
    static func currentId() -> UInt64 { idLock.lock(); defer { idLock.unlock() }; return lastId }

    init(callback: FSEventStreamCallback, context: FSEventStreamContext?, roots: [String], latency: Double, flags: Int) {
        self.callback = callback
        var ctx = context ?? FSEventStreamContext()
        if let r = ctx.retain, let info = ctx.info { ctx.info = UnsafeMutableRawPointer(mutating: r(info)) }
        self.context = ctx
        self.roots = roots
        self.latency = max(0, latency)
        self.flags = flags
    }

    var ref: FSEventStreamRef { OpaquePointer(Unmanaged.passUnretained(self).toOpaque()) }
    static func from(_ ref: FSEventStreamRef) -> FSStream { Unmanaged<FSStream>.fromOpaque(UnsafeRawPointer(ref)).takeUnretainedValue() }

    var fileEvents: Bool { flags & kFSEventStreamCreateFlagFileEvents != 0 }

    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !started, !invalidated, queue != nil || runLoop != nil else { return started }
        let w = FSWatcher(roots: roots, watchRoot: flags & kFSEventStreamCreateFlagWatchRoot != 0) { [weak self] events in
            self?.enqueue(events)
        }
        guard w.start() else { return false }
        watcher = w
        started = true
        return true
    }

    func stop() {
        lock.lock()
        let w = watcher
        watcher = nil
        started = false
        pending.removeAll()
        lock.unlock()
        w?.stop()
    }

    func invalidate() {
        stop()
        lock.lock()
        guard !invalidated else { lock.unlock(); return }
        invalidated = true
        let ctx = context
        lock.unlock()
        if let rel = ctx.release, let info = ctx.info { rel(info) }
    }

    /// Raw events from the watcher thread.
    func enqueue(_ events: [Event]) {
        lock.lock()
        guard started else { lock.unlock(); return }
        for e in events {
            var e = e
            if !fileEvents {
                // Directory-level: the directory that changed, with a trailing slash.
                let isRootChange = e.flags & UInt32(kFSEventStreamEventFlagRootChanged) != 0
                let dirFlags = e.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagRootChanged)
                var dir = isRootChange || e.flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 ? e.path : (e.path as NSString).deletingLastPathComponent
                if !isRootChange, e.flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0, e.flags & UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod) != 0 {
                    dir = e.path
                }
                if !dir.hasSuffix("/") { dir += "/" }
                e = Event(path: dir, flags: dirFlags, inode: 0)
            }
            if let i = pending.firstIndex(where: { $0.path == e.path }) { pending[i].flags |= e.flags } else { pending.append(e) }
        }
        let noDefer = flags & kFSEventStreamCreateFlagNoDefer != 0
        let sinceLast = Date().timeIntervalSince(lastDelivery)
        let delay: Double = noDefer && sinceLast >= latency ? 0 : (noDefer ? latency - sinceLast : latency)
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        if schedule { scheduleFlush(after: delay) }
    }

    private func scheduleFlush(after delay: Double) {
        if let q = queue {
            q.asyncAfter(deadline: .now() + delay) { [weak self] in self?.flush() }
        } else if let rl = runLoop {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in rl.perform { self?.flush() } }
        }
    }

    /// Delivers coalesced events (on the stream's queue or run loop).
    func flush() {
        lock.lock()
        flushScheduled = false
        guard started, !pending.isEmpty else { lock.unlock(); return }
        let events = pending
        pending.removeAll()
        lastDelivery = Date()
        let info = context.info
        lock.unlock()

        let ids = events.map { _ in FSStream.nextId() }
        let eventFlags = events.map(\.flags)
        let useCF = flags & kFSEventStreamCreateFlagUseCFTypes != 0
        let extended = flags & kFSEventStreamCreateFlagUseExtendedData != 0
        eventFlags.withUnsafeBufferPointer { fp in
            ids.withUnsafeBufferPointer { ip in
                if useCF || extended {
                    let array: NSArray = extended
                        ? events.map { [kFSEventStreamEventExtendedDataPathKey: $0.path as NSString,
                                        kFSEventStreamEventExtendedFileIDKey: NSNumber(value: $0.inode)] as NSDictionary } as NSArray
                        : events.map { $0.path as NSString } as NSArray
                    withExtendedLifetime(array) {
                        callback(ref, info, events.count, Unmanaged.passUnretained(array).toOpaque(), fp.baseAddress!, ip.baseAddress!)
                    }
                } else {
                    var cstrs: [UnsafeMutablePointer<CChar>?] = events.map { strdup($0.path) }
                    defer { cstrs.forEach { free($0) } }
                    cstrs.withUnsafeMutableBufferPointer { cp in
                        callback(ref, info, events.count, UnsafeMutableRawPointer(cp.baseAddress!), fp.baseAddress!, ip.baseAddress!)
                    }
                }
            }
        }
    }
}

// MARK: API

public func FSEventStreamCreate(_ allocator: CFAllocator?, _ callback: FSEventStreamCallback,
                                _ context: UnsafeMutablePointer<FSEventStreamContext>?, _ pathsToWatch: CFArray,
                                _ sinceWhen: FSEventStreamEventId, _ latency: CFTimeInterval,
                                _ flags: FSEventStreamCreateFlags) -> FSEventStreamRef? {
    let paths = pathsToWatch.compactMap { p -> String? in
        if let s = p as? String { return s }
        if let s = p as? NSString { return s as String }
        if let u = p as? URL { return u.path }
        return nil
    }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    guard !paths.isEmpty else { return nil }
    let s = FSStream(callback: callback, context: context?.pointee, roots: paths, latency: latency, flags: Int(flags))
    return OpaquePointer(Unmanaged.passRetained(s).toOpaque())
}

public func FSEventStreamCreateRelativeToDevice(_ allocator: CFAllocator?, _ callback: FSEventStreamCallback,
                                                _ context: UnsafeMutablePointer<FSEventStreamContext>?, _ deviceToWatch: Int32,
                                                _ pathsToWatchRelativeToDevice: CFArray, _ sinceWhen: FSEventStreamEventId,
                                                _ latency: CFTimeInterval, _ flags: FSEventStreamCreateFlags) -> FSEventStreamRef? {
    FSEventStreamCreate(allocator, callback, context, pathsToWatchRelativeToDevice, sinceWhen, latency, flags)
}

public func FSEventStreamSetDispatchQueue(_ streamRef: FSEventStreamRef, _ q: DispatchQueue?) {
    let s = FSStream.from(streamRef)
    s.lock.lock(); s.queue = q; s.lock.unlock()
}

public func FSEventStreamScheduleWithRunLoop(_ streamRef: FSEventStreamRef, _ runLoop: CFRunLoop, _ runLoopMode: CFRunLoopMode) {
    let s = FSStream.from(streamRef)
    s.lock.lock(); s.runLoop = runLoop; s.lock.unlock()
}

public func FSEventStreamUnscheduleFromRunLoop(_ streamRef: FSEventStreamRef, _ runLoop: CFRunLoop, _ runLoopMode: CFRunLoopMode) {
    let s = FSStream.from(streamRef)
    s.lock.lock(); s.runLoop = nil; s.lock.unlock()
}

/// False if the stream isn't scheduled or a path can't be watched.
public func FSEventStreamStart(_ streamRef: FSEventStreamRef) -> Bool { FSStream.from(streamRef).start() }
public func FSEventStreamStop(_ streamRef: FSEventStreamRef) { FSStream.from(streamRef).stop() }
public func FSEventStreamInvalidate(_ streamRef: FSEventStreamRef) { FSStream.from(streamRef).invalidate() }

public func FSEventStreamRetain(_ streamRef: FSEventStreamRef) {
    _ = Unmanaged<FSStream>.fromOpaque(UnsafeRawPointer(streamRef)).retain()
}

public func FSEventStreamRelease(_ streamRef: FSEventStreamRef) {
    let s = FSStream.from(streamRef)
    s.invalidate()
    Unmanaged<FSStream>.fromOpaque(UnsafeRawPointer(streamRef)).release()
}

public func FSEventStreamFlushAsync(_ streamRef: FSEventStreamRef) -> FSEventStreamEventId {
    let s = FSStream.from(streamRef)
    if let q = s.queue { q.async { s.flush() } } else { s.runLoop?.perform { s.flush() } }
    return FSStream.currentId()
}

public func FSEventStreamFlushSync(_ streamRef: FSEventStreamRef) {
    let s = FSStream.from(streamRef)
    if let q = s.queue { q.sync { s.flush() } } else { s.flush() }
}

public func FSEventStreamGetLatestEventId(_ streamRef: ConstFSEventStreamRef) -> FSEventStreamEventId { FSStream.currentId() }
public func FSEventsGetCurrentEventId() -> FSEventStreamEventId { FSStream.currentId() }
public func FSEventStreamGetDeviceBeingWatched(_ streamRef: ConstFSEventStreamRef) -> Int32 { 0 }
public func FSEventStreamCopyPathsBeingWatched(_ streamRef: ConstFSEventStreamRef) -> CFArray {
    FSStream.from(streamRef).roots.map { $0 as NSString } as NSArray
}
public func FSEventStreamSetExclusionPaths(_ streamRef: FSEventStreamRef, _ pathsToExclude: CFArray) -> Bool { true }
public func FSEventStreamShow(_ streamRef: ConstFSEventStreamRef) {
    print("FSEventStream \(FSStream.from(streamRef).roots)")
}
public func FSEventsCopyUUIDForDevice(_ dev: Int32) -> Unmanaged<CFUUID>? { nil }
public func FSEventsGetLastEventIdForDeviceBeforeTime(_ dev: Int32, _ time: CFAbsoluteTime) -> FSEventStreamEventId { 0 }
public func FSEventsPurgeEventsForDeviceUpToEventId(_ dev: Int32, _ eventId: FSEventStreamEventId) -> Bool { false }
