// Foundation's async byte and line sequences (`FileHandle.bytes`,
// `URL.lines`, `.lines` / `.characters` / `.unicodeScalars` on any byte
// sequence), which Foundation provides only on Apple platforms.
//
// A file handle is read on a background thread in chunks as data arrives
// (a pipe delivers as soon as the writer flushes), so lines from a child
// process stream as they're written. Lines split as Foundation's do: on
// \n, \r, \r\n, NEL, LS and PS, without the terminator.

import Foundation
import Dispatch
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

extension FileHandle {
    /// The handle's bytes as they become available, until end of file.
    public var bytes: AsyncBytes { AsyncBytes(handle: self) }

    public struct AsyncBytes: AsyncSequence, Sendable {
        public typealias Element = UInt8
        let handle: FileHandle

        public struct AsyncIterator: AsyncIteratorProtocol {
            var buffer = Data()
            var index = 0
            var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator
            init(_ stream: AsyncThrowingStream<Data, Error>) { iterator = stream.makeAsyncIterator() }
            public mutating func next() async throws -> UInt8? {
                while index >= buffer.count {
                    guard let chunk = try await iterator.next() else { return nil }
                    buffer = chunk
                    index = 0
                }
                defer { index += 1 }
                return buffer[buffer.startIndex + index]
            }
        }

        public func makeAsyncIterator() -> AsyncIterator {
            let handle = self.handle
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                let thread = Thread {
                    #if os(Windows)
                    while true {
                        let d = handle.availableData
                        if d.isEmpty { break }
                        continuation.yield(d)
                    }
                    continuation.finish()
                    #else
                    let fd = handle.fileDescriptor
                    var buf = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let n = buf.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
                        if n > 0 {
                            continuation.yield(Data(buf[0..<n]))
                        } else if n == 0 {
                            break
                        } else if errno == EINTR {
                            continue
                        } else if errno == EAGAIN {
                            usleep(5_000)
                        } else {
                            continuation.finish(throwing: CocoaError(.fileReadUnknown))
                            return
                        }
                    }
                    continuation.finish()
                    #endif
                }
                thread.name = "FileHandle.AsyncBytes"
                thread.start()
            }
            return AsyncIterator(stream)
        }
    }
}

extension URL {
    /// The resource's lines (a file read as it's read; other URLs fetched).
    public var lines: AsyncLineSequence<AsyncBytesOfURL> { resourceBytes.lines }

    public var resourceBytes: AsyncBytesOfURL { AsyncBytesOfURL(url: self) }

    public struct AsyncBytesOfURL: AsyncSequence, Sendable {
        public typealias Element = UInt8
        let url: URL
        public struct AsyncIterator: AsyncIteratorProtocol {
            let url: URL
            var file: FileHandle.AsyncBytes.AsyncIterator?
            var data: Data?
            var index = 0
            public mutating func next() async throws -> UInt8? {
                if url.isFileURL {
                    if file == nil { file = try FileHandle(forReadingFrom: url).bytes.makeAsyncIterator() }
                    return try await file!.next()
                }
                if data == nil { data = try await URLSession.shared.data(from: url).0 }
                guard let d = data, index < d.count else { return nil }
                defer { index += 1 }
                return d[d.startIndex + index]
            }
        }
        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(url: url) }
    }
}

/// The lines of an async sequence of UTF-8 bytes.
public struct AsyncLineSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = String
    let base: Base

    public struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Base.AsyncIterator
        var pending: UInt8?
        var done = false

        public mutating func next() async throws -> String? {
            guard !done else { return nil }
            var line: [UInt8] = []
            while true {
                let b: UInt8?
                if let p = pending { b = p; pending = nil } else { b = try await bytes.next() }
                guard let byte = b else {
                    done = true
                    return line.isEmpty ? nil : String(decoding: line, as: UTF8.self)
                }
                switch byte {
                case 0x0A:
                    return String(decoding: line, as: UTF8.self)
                case 0x0D:
                    // \r\n is one break.
                    if let n = try await bytes.next(), n != 0x0A { pending = n }
                    return String(decoding: line, as: UTF8.self)
                default:
                    line.append(byte)
                    // NEL (C2 85), LS (E2 80 A8), PS (E2 80 A9).
                    if line.count >= 2, line[line.count - 2] == 0xC2, line[line.count - 1] == 0x85 {
                        line.removeLast(2)
                        return String(decoding: line, as: UTF8.self)
                    }
                    if line.count >= 3, line[line.count - 3] == 0xE2, line[line.count - 2] == 0x80,
                       line[line.count - 1] == 0xA8 || line[line.count - 1] == 0xA9 {
                        line.removeLast(3)
                        return String(decoding: line, as: UTF8.self)
                    }
                }
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(bytes: base.makeAsyncIterator()) }
}

extension AsyncLineSequence: Sendable where Base: Sendable {}

/// The Unicode scalars of an async sequence of UTF-8 bytes.
public struct AsyncUnicodeScalarSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = Unicode.Scalar
    let base: Base
    public struct AsyncIterator: AsyncIteratorProtocol {
        var bytes: Base.AsyncIterator
        public mutating func next() async throws -> Unicode.Scalar? {
            guard let first = try await bytes.next() else { return nil }
            var units = [first]
            let count = first < 0x80 ? 1 : first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : first >= 0xC0 ? 2 : 1
            while units.count < count, let b = try await bytes.next() { units.append(b) }
            return String(decoding: units, as: UTF8.self).unicodeScalars.first ?? "\u{FFFD}"
        }
    }
    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(bytes: base.makeAsyncIterator()) }
}

/// The characters of an async sequence of UTF-8 bytes.
public struct AsyncCharacterSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    public typealias Element = Character
    let base: Base
    public struct AsyncIterator: AsyncIteratorProtocol {
        var scalars: AsyncUnicodeScalarSequence<Base>.AsyncIterator
        var pending: Unicode.Scalar?
        public mutating func next() async throws -> Character? {
            var s = String.UnicodeScalarView()
            if let p = pending { s.append(p); pending = nil } else if let f = try await scalars.next() { s.append(f) } else { return nil }
            // Combining marks and joiners extend the character.
            while let n = try await scalars.next() {
                var probe = s
                probe.append(n)
                if String(probe).count == 1 { s = probe } else { pending = n; break }
            }
            return Character(String(s))
        }
    }
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(scalars: AsyncUnicodeScalarSequence(base: base).makeAsyncIterator())
    }
}

extension AsyncSequence where Element == UInt8 {
    public var lines: AsyncLineSequence<Self> { AsyncLineSequence(base: self) }
    public var unicodeScalars: AsyncUnicodeScalarSequence<Self> { AsyncUnicodeScalarSequence(base: self) }
    public var characters: AsyncCharacterSequence<Self> { AsyncCharacterSequence(base: self) }
}
