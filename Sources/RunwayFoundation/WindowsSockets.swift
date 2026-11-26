// Darwin's BSD socket API on Winsock, for Mac code that talks over sockets
// (Unix-domain sockets included: Windows 10 1803+ supports AF_UNIX).
//
// Mac code holds sockets as Int32 descriptors and uses them with read,
// write, close and shutdown like files. Each socket here is a C runtime
// descriptor over its Winsock handle (_open_osfhandle), non-overlapped, so
// the runtime's read, write and close work on it unchanged; the socket calls
// find the handle again with _get_osfhandle.

#if os(Windows)
import ucrt
import Foundation
import WinSDK

public typealias socklen_t = Int32
public typealias sa_family_t = UInt16

public let AF_UNSPEC: Int32 = 0
public let AF_UNIX: Int32 = 1
public let AF_INET: Int32 = 2
public let AF_INET6: Int32 = 23
public let SOCK_STREAM: Int32 = 1
public let SOCK_DGRAM: Int32 = 2
public let SOL_SOCKET: Int32 = 0xFFFF
public let SO_REUSEADDR: Int32 = 0x0004
public let SO_KEEPALIVE: Int32 = 0x0008
public let SO_SNDTIMEO: Int32 = 0x1005
public let SO_RCVTIMEO: Int32 = 0x1006
/// Darwin's option that keeps a write to a closed peer from raising SIGPIPE;
/// Windows has no SIGPIPE, so it is accepted and does nothing.
public let SO_NOSIGPIPE: Int32 = 0x1022
public let SHUT_RD: Int32 = 0
public let SHUT_WR: Int32 = 1
public let SHUT_RDWR: Int32 = 2
public let MSG_NOSIGNAL: Int32 = 0

/// Darwin's generic socket address.
public struct sockaddr {
    public var sa_len: UInt8 = 0
    public var sa_family: sa_family_t = 0
    public var sa_data: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    public init() {}
}

/// A Unix-domain socket address: a path of up to 107 bytes.
public struct sockaddr_un {
    public var sun_family: sa_family_t = 0
    public var sun_path: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    public init() {}
}

/// Darwin's time value (seconds and microseconds), as socket timeouts take.
public struct timeval {
    public var tv_sec: Int
    public var tv_usec: Int32
    public init() { tv_sec = 0; tv_usec = 0 }
    public init(tv_sec: Int, tv_usec: Int32) { self.tv_sec = tv_sec; self.tv_usec = tv_usec }
}

/// Winsock, started once.
private enum Winsock {
    static let started: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()
    /// The socket behind a descriptor.
    static func handle(_ fd: Int32) -> SOCKET? {
        let h = _get_osfhandle(fd)
        return h == -1 ? nil : SOCKET(UInt(bitPattern: h))
    }
}

private func setErrno(_ code: Int32) { _set_errno(code) }

/// A socket as a C runtime descriptor (so read, write and close work on it
/// as on a Mac). Non-overlapped, so the runtime's file reads and writes can
/// use it.
@discardableResult
public func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 {
    _ = Winsock.started
    let s = WSASocketW(domain, type, proto, nil, 0, 0)
    guard s != INVALID_SOCKET else { setErrno(EIO); return -1 }
    let fd = _open_osfhandle(Int(bitPattern: UInt(s)), 0)
    if fd < 0 { closesocket(s); setErrno(EMFILE) }
    return fd
}

@discardableResult
public func setsockopt(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: UnsafeRawPointer?, _ length: socklen_t) -> Int32 {
    guard let s = Winsock.handle(fd) else { setErrno(EBADF); return -1 }
    if level == SOL_SOCKET && name == SO_NOSIGPIPE { return 0 }
    if level == SOL_SOCKET && (name == SO_RCVTIMEO || name == SO_SNDTIMEO), let value {
        // Winsock takes the timeout as milliseconds in a DWORD.
        let t = value.load(as: timeval.self)
        var ms = DWORD(max(0, t.tv_sec * 1000 + Int(t.tv_usec) / 1000))
        return withUnsafeBytes(of: &ms) { WinSDK.setsockopt(s, level, name, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)) }
    }
    return WinSDK.setsockopt(s, level, name, value?.assumingMemoryBound(to: CChar.self), length)
}

/// Translates a Darwin-shaped address (a leading length byte, then the
/// family) to Winsock's (the family first).
private func withWinsockAddress<R>(_ address: UnsafePointer<sockaddr>?, _ length: socklen_t,
                                   _ body: (UnsafePointer<WinSDK.sockaddr>?, Int32) -> R) -> R {
    guard let address else { return body(nil, 0) }
    var bytes = [UInt8](UnsafeRawBufferPointer(start: UnsafeRawPointer(address), count: Int(length)))
    if address.pointee.sa_family == sa_family_t(AF_UNIX) {
        // sockaddr_un here has no length byte: already Winsock's layout.
    } else if bytes.count >= 2 {
        let family = UInt16(bytes[1])
        bytes[0] = UInt8(family & 0xFF); bytes[1] = UInt8(family >> 8)
    }
    return bytes.withUnsafeBytes { body($0.baseAddress?.assumingMemoryBound(to: WinSDK.sockaddr.self), length) }
}

public func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    guard let s = Winsock.handle(fd) else { setErrno(EBADF); return -1 }
    let r = withWinsockAddress(address, length) { WinSDK.connect(s, $0, $1) }
    if r != 0 { setErrno(ECONNREFUSED) }
    return r == 0 ? 0 : -1
}

public func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
    guard let s = Winsock.handle(fd) else { setErrno(EBADF); return -1 }
    return withWinsockAddress(address, length) { WinSDK.bind(s, $0, $1) } == 0 ? 0 : -1
}

public func listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
    guard let s = Winsock.handle(fd) else { setErrno(EBADF); return -1 }
    return WinSDK.listen(s, backlog) == 0 ? 0 : -1
}

public func accept(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 {
    guard let s = Winsock.handle(fd) else { setErrno(EBADF); return -1 }
    let c = WinSDK.accept(s, nil, nil)
    guard c != INVALID_SOCKET else { setErrno(EIO); return -1 }
    return _open_osfhandle(Int(bitPattern: UInt(c)), 0)
}

public func send(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ length: Int, _ flags: Int32) -> Int {
    guard let s = Winsock.handle(fd) else { setErrno(EBADF); return -1 }
    let n = WinSDK.send(s, buffer?.assumingMemoryBound(to: CChar.self), Int32(clamping: length), flags)
    if n < 0 { setErrno(EPIPE) }
    return Int(n)
}

public func recv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ length: Int, _ flags: Int32) -> Int {
    guard let s = Winsock.handle(fd) else { setErrno(EBADF); return -1 }
    let n = WinSDK.recv(s, buffer?.assumingMemoryBound(to: CChar.self), Int32(clamping: length), flags)
    if n < 0 { setErrno(EAGAIN) }
    return Int(n)
}

@discardableResult
public func shutdown(_ fd: Int32, _ how: Int32) -> Int32 {
    guard let s = Winsock.handle(fd) else { setErrno(EBADF); return -1 }
    return WinSDK.shutdown(s, how) == 0 ? 0 : -1
}

/// Darwin's read and write: byte counts and results are Int (the C
/// runtime's take and return 32-bit counts).
public func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ length: Int) -> Int {
    Int(_read(fd, buffer, UInt32(clamping: length)))
}
public func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ length: Int) -> Int {
    Int(_write(fd, buffer, UInt32(clamping: length)))
}

/// fcntl: the descriptor flags Mac code sets (F_SETNOSIGPIPE, close-on-exec,
/// non-blocking) have no Windows counterpart for C runtime descriptors and
/// are accepted; F_GETFL reports a plain descriptor.
public let F_GETFD: Int32 = 1
public let F_SETFD: Int32 = 2
public let F_GETFL: Int32 = 3
public let F_SETFL: Int32 = 4
public let FD_CLOEXEC: Int32 = 1
public let O_NONBLOCK: Int32 = 0x0004
@discardableResult
public func fcntl(_ fd: Int32, _ command: Int32, _ argument: Int32 = 0) -> Int32 {
    if command == F_SETFL, let s = Winsock.handle(fd) {
        var nonBlocking: UInt32 = (argument & O_NONBLOCK) != 0 ? 1 : 0
        return ioctlsocket(s, Int32(bitPattern: 0x8004667E), &nonBlocking) == 0 ? 0 : -1   // FIONBIO
    }
    return 0
}
#endif

#if os(Windows)
extension FileHandle {
    /// A C runtime descriptor for the handle (Foundation offers none on
    /// Windows): over a duplicate of the handle, made once per handle, so
    /// Mac code that passes a pipe's descriptor to fcntl or write works.
    public var fileDescriptor: Int32 {
        let raw = Int(bitPattern: _handle)
        DescriptorCache.lock.lock(); defer { DescriptorCache.lock.unlock() }
        if let fd = DescriptorCache.fds[raw] { return fd }
        var dup: HANDLE?
        guard DuplicateHandle(GetCurrentProcess(), _handle, GetCurrentProcess(), &dup, 0, false, DWORD(DUPLICATE_SAME_ACCESS)),
              let dup else { return -1 }
        let fd = _open_osfhandle(Int(bitPattern: dup), 0)
        DescriptorCache.fds[raw] = fd
        return fd
    }
}

private enum DescriptorCache {
    static let lock = NSLock()
    nonisolated(unsafe) static var fds: [Int: Int32] = [:]
}
#endif
