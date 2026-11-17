// Dispatch's vnode sources (`DispatchSource.makeFileSystemObjectSource`),
// which corelibs libdispatch builds only where kqueue exists. On Linux the
// same events come from inotify: the descriptor's file is found through
// /proc/self/fd and watched, and the inotify descriptor is read by an
// ordinary dispatch read source on the target queue, so delivery is event
// driven, as with kqueue.
//
// Events, as kqueue reports them:
//   .write   a file's contents changed; a directory's entries changed
//   .extend  a file grew
//   .attrib  metadata changed
//   .link    the link count changed (a subdirectory added or removed)
//   .rename  the file was moved or renamed
//   .delete  the file was unlinked
//   .revoke  its file system was unmounted

import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#endif

/// A dispatch source that watches one file or directory for changes.
public protocol DispatchSourceFileSystemObject: DispatchSourceProtocol {
    /// The descriptor being watched.
    var handle: Int32 { get }
    /// The events seen since the handler last ran.
    var data: DispatchSource.FileSystemEvent { get }
    /// The events the source watches for.
    var mask: DispatchSource.FileSystemEvent { get }

    // Dispatch's own DispatchSourceProtocol extension implements these
    // for its DispatchSource class only; file system sources answer them.
    func _setEventHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?)
    func _setCancelHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?)
    func _setRegistrationHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?)
    func _activate()
    var _handle: Int32 { get }
    var _events: (data: DispatchSource.FileSystemEvent, mask: DispatchSource.FileSystemEvent) { get }
}

extension DispatchSourceFileSystemObject {
    public func setEventHandler(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], handler: DispatchSourceHandler?) {
        _setEventHandler(qos: qos, flags: flags, handler: handler)
    }
    public func setEventHandler(handler: DispatchWorkItem) {
        _setEventHandler(qos: .unspecified, flags: [], handler: { handler.perform() })
    }
    public func setCancelHandler(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], handler: DispatchSourceHandler?) {
        _setCancelHandler(qos: qos, flags: flags, handler: handler)
    }
    public func setCancelHandler(handler: DispatchWorkItem) {
        _setCancelHandler(qos: .unspecified, flags: [], handler: { handler.perform() })
    }
    public func setRegistrationHandler(qos: DispatchQoS = .unspecified, flags: DispatchWorkItemFlags = [], handler: DispatchSourceHandler?) {
        _setRegistrationHandler(qos: qos, flags: flags, handler: handler)
    }
    public func setRegistrationHandler(handler: DispatchWorkItem) {
        _setRegistrationHandler(qos: .unspecified, flags: [], handler: { handler.perform() })
    }
    public func activate() { _activate() }
    public var handle: Int32 { _handle }
    public var data: DispatchSource.FileSystemEvent { _events.data }
    public var mask: DispatchSource.FileSystemEvent { _events.mask }
}

extension DispatchSource {
    /// A source that reports `eventMask` events on the file or directory
    /// open as `fileDescriptor`, on `queue` (the default global queue when
    /// nil). Like every dispatch source it starts inactive: call
    /// `resume()` or `activate()`.
    public class func makeFileSystemObjectSource(fileDescriptor: Int32, eventMask: DispatchSource.FileSystemEvent,
                                                 queue: DispatchQueue? = nil) -> DispatchSourceFileSystemObject {
        FileSystemObjectSource(fd: fileDescriptor, mask: eventMask, queue: queue ?? .global())
    }
}

final class FileSystemObjectSource: DispatchSourceFileSystemObject, @unchecked Sendable {
    private let fd: Int32
    private let eventMask: DispatchSource.FileSystemEvent
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var eventHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private var registrationHandler: (() -> Void)?
    private var pending: DispatchSource.FileSystemEvent = []
    private var delivered: DispatchSource.FileSystemEvent = []
    /// Dispatch sources start inactive, with one suspension.
    private var suspendCount = 1
    private var activated = false
    private var cancelled = false
    private var notifyFD: Int32 = -1
    private var reader: DispatchSourceRead?
    private var lastSize: Int64 = 0
    private var lastLinks: UInt64 = 0

    init(fd: Int32, mask: DispatchSource.FileSystemEvent, queue: DispatchQueue) {
        self.fd = fd
        eventMask = mask
        self.queue = queue
    }

    var _handle: Int32 { fd }
    var _events: (data: DispatchSource.FileSystemEvent, mask: DispatchSource.FileSystemEvent) { (lock.withLock { delivered }, eventMask) }

    // DispatchSourceProtocol
    var handle: UInt { UInt(bitPattern: Int(fd)) }
    var mask: UInt { eventMask.rawValue }
    var data: UInt { lock.withLock { delivered.rawValue } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    func setEventHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?) {
        _setEventHandler(qos: qos, flags: flags, handler: handler)
    }
    func setEventHandler(handler: DispatchWorkItem) { _setEventHandler(qos: .unspecified, flags: [], handler: { handler.perform() }) }
    func setCancelHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?) {
        _setCancelHandler(qos: qos, flags: flags, handler: handler)
    }
    func setCancelHandler(handler: DispatchWorkItem) { _setCancelHandler(qos: .unspecified, flags: [], handler: { handler.perform() }) }
    func setRegistrationHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?) {
        _setRegistrationHandler(qos: qos, flags: flags, handler: handler)
    }
    func setRegistrationHandler(handler: DispatchWorkItem) {
        _setRegistrationHandler(qos: .unspecified, flags: [], handler: { handler.perform() })
    }

    /// Handlers are kept as Swift closures: off Apple platforms the runtime
    /// can't build generic metadata over `@convention(block)` types (an
    /// optional block in a generic context crashes), so they're never used
    /// as generic arguments here.
    static func swiftClosure(_ handler: DispatchSourceHandler?) -> (() -> Void)? {
        switch handler {
        case let h?: return { h() }
        case nil: return nil
        }
    }

    func _setEventHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?) {
        let f = Self.swiftClosure(handler)
        lock.lock(); eventHandler = f; lock.unlock()
    }
    func _setCancelHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?) {
        let f = Self.swiftClosure(handler)
        lock.lock(); cancelHandler = f; lock.unlock()
    }
    func _setRegistrationHandler(qos: DispatchQoS, flags: DispatchWorkItemFlags, handler: DispatchSourceHandler?) {
        let f = Self.swiftClosure(handler)
        lock.lock(); registrationHandler = f; lock.unlock()
    }

    func _activate() {
        let start: Bool = lock.withLock {
            guard !activated, !cancelled else { return false }
            activated = true
            suspendCount -= 1
            return true
        }
        if start { register() }
    }

    func resume() {
        let (start, unpause): (Bool, Bool) = lock.withLock {
            guard !cancelled else { return (false, false) }
            if !activated {
                activated = true
                suspendCount -= 1
                return (true, false)
            }
            guard suspendCount > 0 else { return (false, false) }
            suspendCount -= 1
            return (false, suspendCount == 0)
        }
        if start { register() }
        if unpause { reader?.resume() }
    }

    func suspend() {
        let pause: Bool = lock.withLock {
            guard activated, !cancelled else { suspendCount += 1; return false }
            suspendCount += 1
            return suspendCount == 1
        }
        if pause { reader?.suspend() }
    }

    func cancel() {
        let (first, r, suspended): (Bool, DispatchSourceRead?, Bool) = lock.withLock {
            guard !cancelled else { return (false, nil, false) }
            cancelled = true
            return (true, reader, activated && suspendCount > 0)
        }
        guard first else { return }
        if let r {
            // A suspended read source must be resumed for its cancel handler to run.
            if suspended { r.resume() }
            r.cancel()
        } else {
            finishCancel()
        }
    }

    private func finishCancel() {
        let h: (() -> Void)? = lock.withLock {
            let h = cancelHandler
            eventHandler = nil
            cancelHandler = nil
            registrationHandler = nil
            if notifyFD >= 0 { close(notifyFD); notifyFD = -1 }
            reader = nil
            return h
        }
        if let h { queue.async(execute: h) }
    }

    // MARK: Watching

    private func register() {
        #if os(Linux)
        var st = stat()
        if fstat(fd, &st) == 0 { lastSize = Int64(st.st_size); lastLinks = UInt64(st.st_nlink) }
        let nfd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        if nfd >= 0, let path = Self.path(of: fd) {
            let watch = UInt32(IN_MODIFY | IN_ATTRIB | IN_MOVE_SELF | IN_DELETE_SELF | IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO)
            if inotify_add_watch(nfd, path, watch) >= 0 {
                let r = DispatchSource.makeReadSource(fileDescriptor: nfd, queue: queue)
                r.setEventHandler { [weak self] in self?.drain() }
                r.setCancelHandler { [weak self] in self?.finishCancel() }
                lock.withLock {
                    notifyFD = nfd
                    reader = r
                }
                r.resume()
            } else {
                close(nfd)
            }
        } else if nfd >= 0 {
            close(nfd)
        }
        #endif
        if let h = lock.withLock({ registrationHandler }) { queue.async(execute: h) }
    }

    /// The path the descriptor was opened with, as the kernel knows it now.
    static func path(of fd: Int32) -> String? {
        #if os(Linux)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink("/proc/self/fd/\(fd)", &buf, buf.count - 1)
        guard n > 0 else { return nil }
        buf[n] = 0
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    #if os(Linux)
    /// Reads every queued inotify event and reports them as one batch.
    private func drain() {
        let nfd = lock.withLock { notifyFD }
        guard nfd >= 0 else { return }
        var seen: DispatchSource.FileSystemEvent = []
        let size = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<inotify_event>.alignment)
        defer { buf.deallocate() }
        while true {
            let n = read(nfd, buf, size)
            guard n > 0 else { break }
            var off = 0
            while off + MemoryLayout<inotify_event>.size <= n {
                let ev = buf.advanced(by: off).assumingMemoryBound(to: inotify_event.self).pointee
                seen.formUnion(events(for: ev.mask))
                off += MemoryLayout<inotify_event>.size + Int(ev.len)
            }
        }
        // Size and link count say whether the file grew or was unlinked.
        var st = stat()
        if fstat(fd, &st) == 0 {
            let size = Int64(st.st_size), links = UInt64(st.st_nlink)
            let isDir = (st.st_mode & S_IFMT) == S_IFDIR
            if !isDir, size > lastSize { seen.insert(.extend) }
            if links != lastLinks {
                seen.insert(.link)
                if links == 0 { seen.insert(.delete) }
            }
            lastSize = size
            lastLinks = links
        }
        let fire = seen.intersection(eventMask)
        guard !fire.isEmpty else { return }
        let h: (() -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            pending.formUnion(fire)
            delivered = pending
            pending = []
            return eventHandler
        }
        h?()
    }

    private func events(for m: UInt32) -> DispatchSource.FileSystemEvent {
        var e: DispatchSource.FileSystemEvent = []
        let has = { (bit: Int32) in m & UInt32(bitPattern: bit) != 0 }
        // A directory's entries changing is a write to the directory.
        if has(Int32(IN_MODIFY)) || has(Int32(IN_CREATE)) || has(Int32(IN_DELETE)) || has(Int32(IN_MOVED_FROM)) || has(Int32(IN_MOVED_TO)) {
            e.insert(.write)
        }
        if (has(Int32(IN_CREATE)) || has(Int32(IN_DELETE)) || has(Int32(IN_MOVED_FROM)) || has(Int32(IN_MOVED_TO))) && has(Int32(IN_ISDIR)) {
            e.insert(.link)
        }
        if has(Int32(IN_ATTRIB)) { e.insert(.attrib) }
        if has(Int32(IN_MOVE_SELF)) { e.insert(.rename) }
        if has(Int32(IN_DELETE_SELF)) { e.insert(.delete) }
        if has(Int32(IN_UNMOUNT)) { e.insert(.revoke) }
        return e
    }
    #endif
}
