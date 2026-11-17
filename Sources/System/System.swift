// System: Apple's typed system-call wrappers (Errno, FilePath,
// FileDescriptor, FilePermissions), over the platform's C library.

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct Errno: RawRepresentable, Error, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: CInt
    public init(rawValue: CInt) { self.rawValue = rawValue }
    public init(_ raw: CInt) { rawValue = raw }

    public static var current: Errno {
        get { Errno(rawValue: errno) }
        set { errno = newValue.rawValue }
    }
    public var description: String { String(cString: strerror(rawValue)) }

    public static func ~= (lhs: Errno, rhs: Error) -> Bool { (rhs as? Errno) == lhs }

    public static let notPermitted = Errno(EPERM)
    public static let noSuchFileOrDirectory = Errno(ENOENT)
    public static let noSuchProcess = Errno(ESRCH)
    public static let interrupted = Errno(EINTR)
    public static let ioError = Errno(EIO)
    public static let badFileDescriptor = Errno(EBADF)
    public static let resourceTemporarilyUnavailable = Errno(EAGAIN)
    public static let wouldBlock = Errno(EWOULDBLOCK)
    public static let noMemory = Errno(ENOMEM)
    public static let permissionDenied = Errno(EACCES)
    public static let badAddress = Errno(EFAULT)
    public static let resourceBusy = Errno(EBUSY)
    public static let fileExists = Errno(EEXIST)
    public static let notDirectory = Errno(ENOTDIR)
    public static let isDirectory = Errno(EISDIR)
    public static let invalidArgument = Errno(EINVAL)
    public static let tooManyOpenFiles = Errno(EMFILE)
    public static let noSpace = Errno(ENOSPC)
    public static let readOnlyFileSystem = Errno(EROFS)
    public static let brokenPipe = Errno(EPIPE)
    public static let fileNameTooLong = Errno(ENAMETOOLONG)
    public static let directoryNotEmpty = Errno(ENOTEMPTY)
    public static let notSupported = Errno(ENOTSUP)
    public static let timedOut = Errno(ETIMEDOUT)
    public static let rangeError = Errno(ERANGE)
    /// ENOATTR: Linux reports a missing extended attribute as ENODATA.
    public static let attributeNotFound = Errno(ENODATA)
    public static let noData = Errno(ENODATA)
}

public struct FilePath: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var string: String
    public init() { string = "" }
    public init(_ string: String) { self.string = string }
    public init(stringLiteral value: String) { string = value }
    public init(cString: UnsafePointer<CChar>) { string = String(cString: cString) }
    public var description: String { string }
    public var isEmpty: Bool { string.isEmpty }
    public var isAbsolute: Bool { string.hasPrefix("/") }
    public var lastComponent: Component? { string.split(separator: "/").last.map { Component(String($0)) } }
    public var `extension`: String? {
        guard let last = lastComponent?.string, let dot = last.lastIndex(of: "."), dot != last.startIndex else { return nil }
        return String(last[last.index(after: dot)...])
    }
    public var stem: String? { lastComponent.map { c in self.extension.map { String(c.string.dropLast($0.count + 1)) } ?? c.string } }
    public func appending(_ other: String) -> FilePath { FilePath(string.hasSuffix("/") ? string + other : string + "/" + other) }
    public mutating func append(_ other: String) { self = appending(other) }
    public func removingLastComponent() -> FilePath {
        guard let i = string.lastIndex(of: "/") else { return FilePath("") }
        return FilePath(i == string.startIndex ? "/" : String(string[..<i]))
    }
    public func withCString<R>(_ body: (UnsafePointer<CChar>) throws -> R) rethrows -> R { try string.withCString(body) }
    public func withPlatformString<R>(_ body: (UnsafePointer<CChar>) throws -> R) rethrows -> R { try string.withCString(body) }

    public struct Component: Hashable, Sendable, CustomStringConvertible {
        public let string: String
        init(_ s: String) { string = s }
        public var description: String { string }
    }
}

extension String {
    public init(decoding path: FilePath) { self = path.string }
    public init?(validating path: FilePath) { self = path.string }
}

public struct FilePermissions: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: CModeT
    public init(rawValue: CModeT) { self.rawValue = rawValue }
    public static let ownerRead = Self(rawValue: 0o400), ownerWrite = Self(rawValue: 0o200), ownerExecute = Self(rawValue: 0o100)
    public static let ownerReadWrite = Self(rawValue: 0o600), ownerReadWriteExecute = Self(rawValue: 0o700)
    public static let groupRead = Self(rawValue: 0o40), groupWrite = Self(rawValue: 0o20), groupExecute = Self(rawValue: 0o10)
    public static let otherRead = Self(rawValue: 0o4), otherWrite = Self(rawValue: 0o2), otherExecute = Self(rawValue: 0o1)
}
public typealias CModeT = UInt32

public struct FileDescriptor: RawRepresentable, Hashable, Sendable {
    public let rawValue: CInt
    public init(rawValue: CInt) { self.rawValue = rawValue }
    public static let standardInput = FileDescriptor(rawValue: 0)
    public static let standardOutput = FileDescriptor(rawValue: 1)
    public static let standardError = FileDescriptor(rawValue: 2)

    public struct AccessMode: RawRepresentable, Hashable, Sendable {
        public let rawValue: CInt
        public init(rawValue: CInt) { self.rawValue = rawValue }
        public static let readOnly = AccessMode(rawValue: O_RDONLY), writeOnly = AccessMode(rawValue: O_WRONLY), readWrite = AccessMode(rawValue: O_RDWR)
    }
    public struct OpenOptions: OptionSet, Hashable, Sendable {
        public let rawValue: CInt
        public init(rawValue: CInt) { self.rawValue = rawValue }
        public static let append = Self(rawValue: O_APPEND), create = Self(rawValue: O_CREAT), truncate = Self(rawValue: O_TRUNC)
        public static let exclusiveCreate = Self(rawValue: O_EXCL), closeOnExec = Self(rawValue: O_CLOEXEC), noFollow = Self(rawValue: O_NOFOLLOW)
    }

    public static func open(_ path: FilePath, _ mode: AccessMode, options: OpenOptions = [], permissions: FilePermissions? = nil,
                            retryOnInterrupt: Bool = true) throws -> FileDescriptor {
        let fd = path.withCString { Glibc.open($0, mode.rawValue | options.rawValue, permissions?.rawValue ?? 0o644) }
        guard fd >= 0 else { throw Errno.current }
        return FileDescriptor(rawValue: fd)
    }
    public func close() throws { guard Glibc.close(rawValue) == 0 else { throw Errno.current } }
    public func read(into buffer: UnsafeMutableRawBufferPointer, retryOnInterrupt: Bool = true) throws -> Int {
        let n = Glibc.read(rawValue, buffer.baseAddress, buffer.count)
        guard n >= 0 else { throw Errno.current }
        return n
    }
    public func write(_ buffer: UnsafeRawBufferPointer, retryOnInterrupt: Bool = true) throws -> Int {
        let n = Glibc.write(rawValue, buffer.baseAddress, buffer.count)
        guard n >= 0 else { throw Errno.current }
        return n
    }
    public func closeAfter<R>(_ body: () throws -> R) throws -> R {
        defer { try? close() }
        return try body()
    }
}
