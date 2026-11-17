// SHA-384, SHA-512 and Insecure.MD5, in Swift like the others.

import Foundation

/// SHA-512's compression (SHA-384 is it with other initial values, truncated).
struct SHA512Core {
    var h: [UInt64]
    var buffer: [UInt8] = []
    var length: UInt64 = 0

    static let k: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538, 0x59f111f1b605d019,
        0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3,
        0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65, 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
        0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b, 0xa2bfe8a14cf10364, 0xa81a664bbc423001,
        0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb,
        0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c, 0xd186b8c721c0c207,
        0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a,
        0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]

    mutating func block(_ b: ArraySlice<UInt8>) {
        var w = [UInt64](repeating: 0, count: 80)
        let base = b.startIndex
        for i in 0..<16 {
            var v: UInt64 = 0
            for j in 0..<8 { v = v << 8 | UInt64(b[base + 8 * i + j]) }
            w[i] = v
        }
        func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { x >> n | x << (64 - n) }
        for i in 16..<80 {
            let s0 = rotr(w[i - 15], 1) ^ rotr(w[i - 15], 8) ^ (w[i - 15] >> 7)
            let s1 = rotr(w[i - 2], 19) ^ rotr(w[i - 2], 61) ^ (w[i - 2] >> 6)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, bb, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
        for i in 0..<80 {
            let s1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
            let maj = (a & bb) ^ (a & c) ^ (bb & c)
            let t2 = s0 &+ maj
            (hh, g, f, e, d, c, bb, a) = (g, f, e, d &+ t1, c, bb, a, t1 &+ t2)
        }
        h[0] &+= a; h[1] &+= bb; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }

    mutating func update(_ p: UnsafeRawBufferPointer) {
        buffer += p
        length += UInt64(p.count)
        var i = 0
        while buffer.count - i >= 128 { block(buffer[i..<i + 128]); i += 128 }
        buffer.removeFirst(i)
    }

    func finalize(words: Int) -> [UInt8] {
        var copy = self
        var tail = copy.buffer + [0x80]
        while tail.count % 128 != 112 { tail.append(0) }
        tail += [UInt8](repeating: 0, count: 8)
        let bits = length * 8
        for i in (0..<8).reversed() { tail.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
        var i = 0
        while i < tail.count { copy.block(tail[i..<i + 128]); i += 128 }
        return copy.h.prefix(words).flatMap { v in (0..<8).map { UInt8(truncatingIfNeeded: v >> (56 - 8 * UInt64($0))) } }
    }
}

public struct SHA512: HashFunction {
    public static let byteCount = 64
    public static let blockByteCount = 128
    var core = SHA512Core(h: [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                              0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179])
    public init() {}
    public mutating func update(bufferPointer: UnsafeRawBufferPointer) { core.update(bufferPointer) }
    public func finalize() -> SHA512Digest { SHA512Digest(bytes: core.finalize(words: 8)) }
}

public struct SHA384: HashFunction {
    public static let byteCount = 48
    public static let blockByteCount = 128
    var core = SHA512Core(h: [0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
                              0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4])
    public init() {}
    public mutating func update(bufferPointer: UnsafeRawBufferPointer) { core.update(bufferPointer) }
    public func finalize() -> SHA384Digest { SHA384Digest(bytes: core.finalize(words: 6)) }
}

public struct MD5Digest: Digest { public let bytes: [UInt8] }

extension Insecure {
    public struct MD5: HashFunction {
        public static let byteCount = 16
        public static let blockByteCount = 64
        var h: [UInt32] = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
        var buffer: [UInt8] = []
        var length: UInt64 = 0
        public init() {}

        static let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
        static let k: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }

        mutating func block(_ b: ArraySlice<UInt8>) {
            let base = b.startIndex
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                m[i] = UInt32(b[base + 4 * i]) | UInt32(b[base + 4 * i + 1]) << 8 | UInt32(b[base + 4 * i + 2]) << 16 | UInt32(b[base + 4 * i + 3]) << 24
            }
            var (a, bb, c, d) = (h[0], h[1], h[2], h[3])
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16: f = (bb & c) | (~bb & d); g = i
                case 16..<32: f = (d & bb) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = bb ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (bb | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ Self.k[i] &+ m[g]
                a = d; d = c; c = bb
                bb = bb &+ (f << Self.s[i] | f >> (32 - Self.s[i]))
            }
            h[0] &+= a; h[1] &+= bb; h[2] &+= c; h[3] &+= d
        }

        public mutating func update(bufferPointer: UnsafeRawBufferPointer) {
            buffer += bufferPointer
            length += UInt64(bufferPointer.count)
            var i = 0
            while buffer.count - i >= 64 { block(buffer[i..<i + 64]); i += 64 }
            buffer.removeFirst(i)
        }

        public func finalize() -> MD5Digest {
            var copy = self
            var tail = copy.buffer + [0x80]
            while tail.count % 64 != 56 { tail.append(0) }
            let bits = length * 8
            for i in 0..<8 { tail.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(i)))) }
            var i = 0
            while i < tail.count { copy.block(tail[i..<i + 64]); i += 64 }
            return MD5Digest(bytes: copy.h.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } })
        }
    }
}
