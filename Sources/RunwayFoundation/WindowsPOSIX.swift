// POSIX names Mac code uses through Darwin that the Windows CRT lacks or
// spells differently: process and user ids, and the calls that return them.
// Windows has no POSIX users; the ids are those of a single local user.

#if os(Windows)
import Foundation
import WinSDK

public typealias pid_t = Int32
public typealias uid_t = UInt32
public typealias gid_t = UInt32

public func getpid() -> pid_t { pid_t(GetCurrentProcessId()) }
public func getuid() -> uid_t { 501 }
public func geteuid() -> uid_t { 501 }
public func getgid() -> gid_t { 20 }
public func getegid() -> gid_t { 20 }

/// Sleeps at least `microseconds` (Windows sleeps in milliseconds).
@discardableResult public func usleep(_ microseconds: UInt32) -> Int32 {
    Sleep(DWORD((UInt64(microseconds) + 999) / 1000))
    return 0
}
#endif
