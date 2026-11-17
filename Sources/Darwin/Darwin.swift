// Darwin for Linux and Windows: the platform's C library under Apple's
// module name, so `import Darwin` (POSIX calls, math, errno…) resolves.
#if canImport(Glibc)
@_exported import Glibc
#elseif canImport(Musl)
@_exported import Musl
#elseif os(Windows)
@_exported import ucrt
@_exported import WinSDK
#endif
@_exported import Foundation
