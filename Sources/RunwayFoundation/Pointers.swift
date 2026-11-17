// Standard library and Foundation names that exist only with Objective-C
// interop on Apple platforms.

import Foundation

/// A mutable pointer that, on Apple platforms, autoreleases what's stored
/// through it: Objective-C out-parameters (`NSError **`, the `NSString **`
/// of a Services method). Without Objective-C there's no autorelease pool,
/// so values are stored with ordinary (strong, `UnsafeMutablePointer`)
/// semantics.
@frozen
public struct AutoreleasingUnsafeMutablePointer<Pointee>: Hashable, @unchecked Sendable {
    public let _rawValue: UnsafeMutableRawPointer

    public init(_ from: UnsafeMutablePointer<Pointee>) { _rawValue = UnsafeMutableRawPointer(from) }
    public init?(_ from: UnsafeMutablePointer<Pointee>?) {
        guard let from else { return nil }
        self.init(from)
    }
    public init<U>(_ from: UnsafeMutablePointer<U>) { _rawValue = UnsafeMutableRawPointer(from) }
    public init?<U>(_ from: UnsafeMutablePointer<U>?) {
        guard let from else { return nil }
        self.init(from)
    }
    public init<U>(_ from: UnsafePointer<U>) { _rawValue = UnsafeMutableRawPointer(mutating: from) }
    public init?<U>(_ from: UnsafePointer<U>?) {
        guard let from else { return nil }
        self.init(from)
    }

    private var typed: UnsafeMutablePointer<Pointee> { _rawValue.assumingMemoryBound(to: Pointee.self) }

    /// The value the pointer points to.
    public var pointee: Pointee {
        get { typed.pointee }
        nonmutating set { typed.pointee = newValue }
    }
    public subscript(i: Int) -> Pointee {
        get { typed[i] }
        nonmutating set { typed[i] = newValue }
    }
}

extension UnsafeMutableRawPointer {
    public init<T>(_ other: AutoreleasingUnsafeMutablePointer<T>) { self = other._rawValue }
    public init?<T>(_ other: AutoreleasingUnsafeMutablePointer<T>?) {
        guard let other else { return nil }
        self = other._rawValue
    }
}
extension UnsafeRawPointer {
    public init<T>(_ other: AutoreleasingUnsafeMutablePointer<T>) { self.init(other._rawValue) }
    public init?<T>(_ other: AutoreleasingUnsafeMutablePointer<T>?) {
        guard let other else { return nil }
        self.init(other._rawValue)
    }
}

/// Opens a file for event notifications only (Darwin's `O_EVTONLY`): a
/// read-only descriptor kept just to watch the file or directory with
/// `DispatchSource.makeFileSystemObjectSource`.
public let O_EVTONLY: Int32 = O_RDONLY

// MARK: Attributed strings

extension NSAttributedString {
    /// An empty attributed string: `NSAttributedString()`. (corelibs'
    /// NSAttributedString doesn't inherit NSObject's `init()`, and an
    /// extension can't redeclare it, so the empty initializer takes an
    /// argument with a default.)
    public convenience init(_ empty: Void = ()) { self.init(string: "") }
}

// MARK: Paths

extension NSString {
    /// The path with the home directory written as `~`.
    public var abbreviatingWithTildeInPath: String {
        let s = self as String
        let home = NSHomeDirectory()
        guard !home.isEmpty, home != "/" else { return s }
        if s == home { return "~" }
        if s.hasPrefix(home + "/") { return "~" + s.dropFirst(home.count) }
        return s
    }
}
