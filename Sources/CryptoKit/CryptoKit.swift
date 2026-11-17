// CryptoKit's hashing and HMAC for Linux and Windows, in Swift. (For
// encryption and signatures, swift-crypto's `Crypto` module is the
// cross-platform route; this covers what apps use for digests.)

import Foundation

public protocol Digest: Sequence, Hashable, Sendable, CustomStringConvertible where Element == UInt8 {
    var bytes: [UInt8] { get }
}

extension Digest {
    public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
    public var description: String { "\(Self.self): " + bytes.map { String(format: "%02x", $0) }.joined() }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try bytes.withUnsafeBytes(body) }
}

public protocol HashFunction {
    associatedtype DigestType: Digest
    static var byteCount: Int { get }
    static var blockByteCount: Int { get }
    init()
    mutating func update(bufferPointer: UnsafeRawBufferPointer)
    func finalize() -> DigestType
}

extension HashFunction {
    public static func hash<D: DataProtocol>(data: D) -> DigestType {
        var h = Self()
        h.update(data: data)
        return h.finalize()
    }
    public mutating func update<D: DataProtocol>(data: D) {
        let bytes = Array(data)
        bytes.withUnsafeBytes { update(bufferPointer: $0) }
    }
}

public struct SHA256Digest: Digest { public let bytes: [UInt8] }
public struct SHA384Digest: Digest { public let bytes: [UInt8] }
public struct SHA512Digest: Digest { public let bytes: [UInt8] }
public struct SHA1Digest: Digest { public let bytes: [UInt8] }

public struct SHA256: HashFunction {
    public static let byteCount = 32
    public static let blockByteCount = 64
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var buffer: [UInt8] = []
    var length: UInt64 = 0
    public init() {}

    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    mutating func block(_ b: ArraySlice<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        let base = b.startIndex
        for i in 0..<16 { w[i] = UInt32(b[base + 4 * i]) << 24 | UInt32(b[base + 4 * i + 1]) << 16 | UInt32(b[base + 4 * i + 2]) << 8 | UInt32(b[base + 4 * i + 3]) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { x >> n | x << (32 - n) }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, bb, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & bb) ^ (a & c) ^ (bb & c)
            let t2 = s0 &+ maj
            (hh, g, f, e, d, c, bb, a) = (g, f, e, d &+ t1, c, bb, a, t1 &+ t2)
        }
        h[0] &+= a; h[1] &+= bb; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    public mutating func update(bufferPointer: UnsafeRawBufferPointer) {
        buffer += bufferPointer
        length += UInt64(bufferPointer.count)
        var i = 0
        while buffer.count - i >= 64 { block(buffer[i..<i + 64]); i += 64 }
        buffer.removeFirst(i)
    }

    public func finalize() -> SHA256Digest {
        var copy = self
        var tail = copy.buffer + [0x80]
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length * 8
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
        var i = 0
        while i < tail.count { copy.block(tail[i..<i + 64]); i += 64 }
        return SHA256Digest(bytes: copy.h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32($0))) } })
    }
}

public struct SymmetricKey: Sendable {
    let bytes: [UInt8]
    public init<D: ContiguousBytes>(data: D) { bytes = data.withUnsafeBytes { Array($0) } }
    public init(size: SymmetricKeySize) {
        var g = SystemRandomNumberGenerator()
        bytes = (0..<size.bitCount / 8).map { _ in UInt8.random(in: 0...255, using: &g) }
    }
    public var bitCount: Int { bytes.count * 8 }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try bytes.withUnsafeBytes(body) }
}

public struct SymmetricKeySize: Sendable {
    public let bitCount: Int
    public init(bitCount: Int) { self.bitCount = bitCount }
    public static let bits128 = SymmetricKeySize(bitCount: 128), bits192 = SymmetricKeySize(bitCount: 192), bits256 = SymmetricKeySize(bitCount: 256)
}

public struct HashedAuthenticationCode<H: HashFunction>: Hashable, Sendable, Sequence {
    public let bytes: [UInt8]
    public func makeIterator() -> IndexingIterator<[UInt8]> { bytes.makeIterator() }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R { try bytes.withUnsafeBytes(body) }
}

public struct HMAC<H: HashFunction> {
    public static func authenticationCode<D: DataProtocol>(for data: D, using key: SymmetricKey) -> HashedAuthenticationCode<H> {
        var k = key.bytes
        if k.count > H.blockByteCount { k = Array(H.hash(data: k)) }
        k += [UInt8](repeating: 0, count: H.blockByteCount - k.count)
        var inner = H()
        inner.update(data: k.map { $0 ^ 0x36 })
        inner.update(data: data)
        var outer = H()
        outer.update(data: k.map { $0 ^ 0x5c })
        outer.update(data: Array(inner.finalize()))
        return HashedAuthenticationCode(bytes: Array(outer.finalize()))
    }
    public static func isValidAuthenticationCode<D: DataProtocol>(_ code: HashedAuthenticationCode<H>, authenticating data: D, using key: SymmetricKey) -> Bool {
        authenticationCode(for: data, using: key).bytes == code.bytes
    }
}

public enum Insecure {
    public struct SHA1: HashFunction {
        public static let byteCount = 20
        public static let blockByteCount = 64
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var buffer: [UInt8] = []
        var length: UInt64 = 0
        public init() {}
        mutating func block(_ b: ArraySlice<UInt8>) {
            var w = [UInt32](repeating: 0, count: 80)
            let base = b.startIndex
            for i in 0..<16 { w[i] = UInt32(b[base + 4 * i]) << 24 | UInt32(b[base + 4 * i + 1]) << 16 | UInt32(b[base + 4 * i + 2]) << 8 | UInt32(b[base + 4 * i + 3]) }
            func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var (a, bb, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32) = i < 20 ? ((bb & c) | (~bb & d), 0x5A827999) : i < 40 ? (bb ^ c ^ d, 0x6ED9EBA1) : i < 60 ? ((bb & c) | (bb & d) | (c & d), 0x8F1BBCDC) : (bb ^ c ^ d, 0xCA62C1D6)
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, bb, a) = (d, c, rotl(bb, 30), a, t)
            }
            h[0] &+= a; h[1] &+= bb; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        public mutating func update(bufferPointer: UnsafeRawBufferPointer) {
            buffer += bufferPointer
            length += UInt64(bufferPointer.count)
            var i = 0
            while buffer.count - i >= 64 { block(buffer[i..<i + 64]); i += 64 }
            buffer.removeFirst(i)
        }
        public func finalize() -> SHA1Digest {
            var copy = self
            var tail = copy.buffer + [0x80]
            while tail.count % 64 != 56 { tail.append(0) }
            let bits = length * 8
            for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
            var i = 0
            while i < tail.count { copy.block(tail[i..<i + 64]); i += 64 }
            return SHA1Digest(bytes: copy.h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32($0))) } })
        }
    }
}
