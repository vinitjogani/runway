// The kernel side of FSEvents: inotify on Linux, ReadDirectoryChangesW on
// Windows. A watcher thread blocks until there are events (or it's told
// to stop through a pipe / CancelIoEx), translates them to FSEvents flags,
// and hands batches to its stream.

import Foundation
#if os(Linux)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

final class FSWatcher: @unchecked Sendable {
    let roots: [String]
    let watchRoot: Bool
    let sink: ([FSStream.Event]) -> Void
    private var thread: Thread?

    init(roots: [String], watchRoot: Bool, sink: @escaping ([FSStream.Event]) -> Void) {
        self.roots = roots
        self.watchRoot = watchRoot
        self.sink = sink
    }

    static let created = UInt32(kFSEventStreamEventFlagItemCreated)
    static let removed = UInt32(kFSEventStreamEventFlagItemRemoved)
    static let renamed = UInt32(kFSEventStreamEventFlagItemRenamed)
    static let modified = UInt32(kFSEventStreamEventFlagItemModified)
    static let metaMod = UInt32(kFSEventStreamEventFlagItemInodeMetaMod)
    static let isFile = UInt32(kFSEventStreamEventFlagItemIsFile)
    static let isDir = UInt32(kFSEventStreamEventFlagItemIsDir)
    static let isSymlink = UInt32(kFSEventStreamEventFlagItemIsSymlink)
    static let rootChanged = UInt32(kFSEventStreamEventFlagRootChanged)
    static let mustScan = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
    static let kernelDropped = UInt32(kFSEventStreamEventFlagKernelDropped)

    /// Kind flags and inode for an existing path.
    static func describe(_ path: String) -> (UInt32, UInt64) {
        #if os(Windows)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return (0, 0) }
        return (isDirectory.boolValue ? isDir : isFile, 0)
        #else
        var st = stat()
        guard lstat(path, &st) == 0 else { return (0, 0) }
        let fmt = st.st_mode & S_IFMT
        let kind: UInt32 = fmt == S_IFDIR ? isDir : fmt == S_IFLNK ? isSymlink : isFile
        return (kind, UInt64(st.st_ino))
        #endif
    }

    #if os(Linux)
    private var fd: Int32 = -1
    private var wake: [Int32] = [-1, -1]
    private var dirs: [Int32: String] = [:]
    private var rootWatches: Set<Int32> = []
    private let mask: UInt32 = UInt32(IN_CREATE | IN_DELETE | IN_MODIFY | IN_CLOSE_WRITE | IN_MOVED_FROM | IN_MOVED_TO | IN_ATTRIB
        | IN_DELETE_SELF | IN_MOVE_SELF) | UInt32(IN_EXCL_UNLINK)

    func start() -> Bool {
        fd = inotify_init1(Int32(IN_CLOEXEC | IN_NONBLOCK))
        guard fd >= 0 else { return false }
        guard pipe(&wake) == 0 else { close(fd); return false }
        var any = false
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { any = addTree(root, root: true) || any } else { any = add(root, root: true) || any }
        }
        guard any else { close(fd); close(wake[0]); close(wake[1]); return false }
        let t = Thread { [self] in run() }
        t.name = "runway.fsevents"
        thread = t
        t.start()
        return true
    }

    @discardableResult
    private func add(_ path: String, root: Bool = false) -> Bool {
        let wd = inotify_add_watch(fd, path, mask)
        guard wd >= 0 else { return false }
        dirs[wd] = path
        if root { rootWatches.insert(wd) }
        return true
    }

    /// Watches `dir` and every directory below it; returns false if `dir` can't be watched.
    @discardableResult
    private func addTree(_ dir: String, root: Bool = false, reportInto events: UnsafeMutablePointer<[FSStream.Event]>? = nil) -> Bool {
        guard add(dir, root: root) else { return false }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return true }
        for name in names {
            let p = dir + "/" + name
            let (kind, inode) = FSWatcher.describe(p)
            // Items that appeared inside a new directory before its watch existed.
            events?.pointee.append(.init(path: p, flags: FSWatcher.created | kind, inode: inode))
            if kind == FSWatcher.isDir { addTree(p, reportInto: events) }
        }
        return true
    }

    func stop() {
        guard wake[1] >= 0 else { return }
        var b: UInt8 = 1
        _ = write(wake[1], &b, 1)
    }

    private func run() {
        let bufSize = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer {
            buf.deallocate()
            close(fd); close(wake[0]); close(wake[1])
            wake = [-1, -1]
        }
        var pendingMoves: [UInt32: (String, UInt32)] = [:]
        while true {
            var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0), pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0)]
            let r = poll(&fds, 2, -1)
            if r < 0 { if errno == EINTR { continue }; return }
            if fds[1].revents != 0 { return }
            var events: [FSStream.Event] = []
            while true {
                let n = read(fd, buf, bufSize)
                if n <= 0 { break }
                var off = 0
                while off < n {
                    let ev = buf.advanced(by: off).assumingMemoryBound(to: inotify_event.self).pointee
                    let nameLen = Int(ev.len)
                    var name = ""
                    if nameLen > 0 {
                        name = String(cString: buf.advanced(by: off + MemoryLayout<inotify_event>.size).assumingMemoryBound(to: CChar.self))
                    }
                    off += MemoryLayout<inotify_event>.size + nameLen
                    handle(ev, name: name, into: &events, moves: &pendingMoves)
                }
            }
            // A move whose other half never arrived left the watched tree.
            for (_, (path, kind)) in pendingMoves { events.append(.init(path: path, flags: FSWatcher.renamed | kind, inode: 0)) }
            pendingMoves.removeAll()
            if !events.isEmpty { sink(events) }
        }
    }

    private func handle(_ ev: inotify_event, name: String, into events: inout [FSStream.Event], moves: inout [UInt32: (String, UInt32)]) {
        let m = ev.mask
        if m & UInt32(IN_Q_OVERFLOW) != 0 {
            for r in roots { events.append(.init(path: r, flags: FSWatcher.mustScan | FSWatcher.kernelDropped, inode: 0)) }
            return
        }
        guard let base = dirs[ev.wd] else { return }
        if m & UInt32(IN_IGNORED) != 0 { dirs[ev.wd] = nil; return }
        if m & UInt32(IN_DELETE_SELF | IN_MOVE_SELF) != 0 {
            if rootWatches.contains(ev.wd), watchRoot { events.append(.init(path: base, flags: FSWatcher.rootChanged, inode: 0)) }
            return
        }
        let path = name.isEmpty ? base : base + "/" + name
        let dirFlag = m & UInt32(IN_ISDIR) != 0 ? FSWatcher.isDir : FSWatcher.isFile
        if m & UInt32(IN_CREATE) != 0 {
            let (kind, inode) = FSWatcher.describe(path)
            events.append(.init(path: path, flags: FSWatcher.created | (kind == 0 ? dirFlag : kind), inode: inode))
            if kind == FSWatcher.isDir {
                var found: [FSStream.Event] = []
                addTree(path, reportInto: &found)
                events += found
            }
        }
        if m & UInt32(IN_DELETE) != 0 { events.append(.init(path: path, flags: FSWatcher.removed | dirFlag, inode: 0)) }
        if m & UInt32(IN_MODIFY | IN_CLOSE_WRITE) != 0 {
            events.append(.init(path: path, flags: FSWatcher.modified | dirFlag, inode: FSWatcher.describe(path).1))
        }
        if m & UInt32(IN_ATTRIB) != 0 { events.append(.init(path: path, flags: FSWatcher.metaMod | dirFlag, inode: FSWatcher.describe(path).1)) }
        if m & UInt32(IN_MOVED_FROM) != 0 {
            moves[ev.cookie] = (path, dirFlag)
        }
        if m & UInt32(IN_MOVED_TO) != 0 {
            // FSEvents reports both ends of a rename with ItemRenamed.
            if let (from, kind) = moves.removeValue(forKey: ev.cookie) {
                events.append(.init(path: from, flags: FSWatcher.renamed | kind, inode: 0))
                for (wd, p) in dirs where p == from || p.hasPrefix(from + "/") { dirs[wd] = path + p.dropFirst(from.count) }
            }
            let (kind, inode) = FSWatcher.describe(path)
            events.append(.init(path: path, flags: FSWatcher.renamed | (kind == 0 ? dirFlag : kind), inode: inode))
            if kind == FSWatcher.isDir, !dirs.values.contains(path) { addTree(path) }
        }
    }

    #elseif os(Windows)
    private var handles: [HANDLE] = []
    private let lock = NSLock()
    private var stopping = false

    func start() -> Bool {
        var threads: [Thread] = []
        for root in roots {
            let h = root.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(FILE_LIST_DIRECTORY), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                            DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
            }
            guard let h, h != INVALID_HANDLE_VALUE else { continue }
            handles.append(h)
            let t = Thread { [self] in run(h, root: root) }
            t.name = "runway.fsevents"
            threads.append(t)
        }
        guard !handles.isEmpty else { return false }
        threads.forEach { $0.start() }
        return true
    }

    func stop() {
        lock.lock(); stopping = true; let hs = handles; lock.unlock()
        for h in hs { CancelIoEx(h, nil) }
    }

    private func run(_ h: HANDLE, root: String) {
        defer { CloseHandle(h) }
        let size = 64 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        let filter = DWORD(FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_ATTRIBUTES
            | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_CREATION)
        while true {
            var returned: DWORD = 0
            let ok = ReadDirectoryChangesW(h, buf, DWORD(size), true, filter, &returned, nil, nil)
            lock.lock(); let done = stopping; lock.unlock()
            if done { return }
            guard ok else { return }
            if returned == 0 {
                sink([.init(path: root, flags: FSWatcher.mustScan | FSWatcher.kernelDropped, inode: 0)])
                continue
            }
            var events: [FSStream.Event] = []
            var off = 0
            while true {
                let info = buf.advanced(by: off).assumingMemoryBound(to: FILE_NOTIFY_INFORMATION.self)
                let chars = Int(info.pointee.FileNameLength) / 2
                let namePtr = buf.advanced(by: off + MemoryLayout<FILE_NOTIFY_INFORMATION>.offset(of: \.FileName)!).assumingMemoryBound(to: UInt16.self)
                let name = String(decoding: UnsafeBufferPointer(start: namePtr, count: chars), as: UTF16.self)
                let path = root + "\\" + name
                let (kind, _) = FSWatcher.describe(path)
                let flags: UInt32
                switch Int32(info.pointee.Action) {
                case FILE_ACTION_ADDED: flags = FSWatcher.created
                case FILE_ACTION_REMOVED: flags = FSWatcher.removed
                case FILE_ACTION_MODIFIED: flags = FSWatcher.modified
                default: flags = FSWatcher.renamed
                }
                events.append(.init(path: path, flags: flags | (kind == 0 ? FSWatcher.isFile : kind), inode: 0))
                if info.pointee.NextEntryOffset == 0 { break }
                off += Int(info.pointee.NextEntryOffset)
            }
            sink(events)
        }
    }
    #else
    func start() -> Bool { false }
    func stop() {}
    #endif
}
