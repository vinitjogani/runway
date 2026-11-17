// CommonCrypto: digests (CC_MD5/SHA1/SHA256/SHA384/SHA512, one-shot and
// incremental), HMAC, AES (CCCrypt and CCCryptor, ECB/CBC with PKCS#7
// padding) and PBKDF2, implemented in Swift over Runway's CryptoKit.

@_exported import Foundation
import CryptoKit

public typealias CC_LONG = UInt32
public typealias CCCryptorStatus = Int32
public typealias CCOperation = UInt32
public typealias CCAlgorithm = UInt32
public typealias CCOptions = UInt32
public typealias CCHmacAlgorithm = UInt32
public typealias CCPBKDFAlgorithm = UInt32
public typealias CCPseudoRandomAlgorithm = UInt32

public let CC_MD5_DIGEST_LENGTH: Int32 = 16
public let CC_SHA1_DIGEST_LENGTH: Int32 = 20
public let CC_SHA224_DIGEST_LENGTH: Int32 = 28
public let CC_SHA256_DIGEST_LENGTH: Int32 = 32
public let CC_SHA384_DIGEST_LENGTH: Int32 = 48
public let CC_SHA512_DIGEST_LENGTH: Int32 = 64
public let CC_MD5_BLOCK_BYTES: Int32 = 64
public let CC_SHA1_BLOCK_BYTES: Int32 = 64
public let CC_SHA256_BLOCK_BYTES: Int32 = 64
public let CC_SHA512_BLOCK_BYTES: Int32 = 128

public let kCCSuccess: CCCryptorStatus = 0
public let kCCParamError: CCCryptorStatus = -4300
public let kCCBufferTooSmall: CCCryptorStatus = -4301
public let kCCMemoryFailure: CCCryptorStatus = -4302
public let kCCAlignmentError: CCCryptorStatus = -4303
public let kCCDecodeError: CCCryptorStatus = -4304
public let kCCUnimplemented: CCCryptorStatus = -4305
public let kCCKeySizeError: CCCryptorStatus = -4310

public let kCCEncrypt: CCOperation = 0
public let kCCDecrypt: CCOperation = 1
public let kCCAlgorithmAES: CCAlgorithm = 0
public let kCCAlgorithmAES128: CCAlgorithm = 0
public let kCCAlgorithmDES: CCAlgorithm = 1
public let kCCAlgorithm3DES: CCAlgorithm = 2
public let kCCOptionPKCS7Padding: CCOptions = 1
public let kCCOptionECBMode: CCOptions = 2
public let kCCKeySizeAES128 = 16
public let kCCKeySizeAES192 = 24
public let kCCKeySizeAES256 = 32
public let kCCBlockSizeAES128 = 16

public let kCCHmacAlgSHA1: CCHmacAlgorithm = 0
public let kCCHmacAlgMD5: CCHmacAlgorithm = 1
public let kCCHmacAlgSHA256: CCHmacAlgorithm = 2
public let kCCHmacAlgSHA384: CCHmacAlgorithm = 3
public let kCCHmacAlgSHA512: CCHmacAlgorithm = 4
public let kCCHmacAlgSHA224: CCHmacAlgorithm = 5

public let kCCPBKDF2: CCPBKDFAlgorithm = 2
public let kCCPRFHmacAlgSHA1: CCPseudoRandomAlgorithm = 1
public let kCCPRFHmacAlgSHA224: CCPseudoRandomAlgorithm = 2
public let kCCPRFHmacAlgSHA256: CCPseudoRandomAlgorithm = 3
public let kCCPRFHmacAlgSHA384: CCPseudoRandomAlgorithm = 4
public let kCCPRFHmacAlgSHA512: CCPseudoRandomAlgorithm = 5

// MARK: Digests

private func bytes(_ data: UnsafeRawPointer?, _ len: CC_LONG) -> UnsafeRawBufferPointer {
    UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : Int(len))
}

@discardableResult
private func write<D: Digest>(_ d: D, _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>? {
    guard let md else { return nil }
    for (i, b) in d.bytes.enumerated() { md[i] = b }
    return md
}

private func oneShot<H: HashFunction>(_ h: H.Type, _ data: UnsafeRawPointer?, _ len: CC_LONG, _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>? {
    var hasher = H()
    hasher.update(bufferPointer: bytes(data, len))
    return write(hasher.finalize(), md)
}

@discardableResult public func CC_MD5(_ data: UnsafeRawPointer?, _ len: CC_LONG, _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>? { oneShot(Insecure.MD5.self, data, len, md) }
@discardableResult public func CC_SHA1(_ data: UnsafeRawPointer?, _ len: CC_LONG, _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>? { oneShot(Insecure.SHA1.self, data, len, md) }
@discardableResult public func CC_SHA256(_ data: UnsafeRawPointer?, _ len: CC_LONG, _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>? { oneShot(SHA256.self, data, len, md) }
@discardableResult public func CC_SHA384(_ data: UnsafeRawPointer?, _ len: CC_LONG, _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>? { oneShot(SHA384.self, data, len, md) }
@discardableResult public func CC_SHA512(_ data: UnsafeRawPointer?, _ len: CC_LONG, _ md: UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>? { oneShot(SHA512.self, data, len, md) }

/// An incremental digest context (a box around the hasher).
public struct CC_HashContext<H: HashFunction> {
    var hasher: H? = nil
    public init() {}
}
public typealias CC_MD5_CTX = CC_HashContext<Insecure.MD5>
public typealias CC_SHA1_CTX = CC_HashContext<Insecure.SHA1>
public typealias CC_SHA256_CTX = CC_HashContext<SHA256>
public typealias CC_SHA512_CTX = CC_HashContext<SHA512>

@discardableResult public func CC_MD5_Init(_ c: UnsafeMutablePointer<CC_MD5_CTX>!) -> Int32 { c.pointee.hasher = .init(); return 1 }
@discardableResult public func CC_MD5_Update(_ c: UnsafeMutablePointer<CC_MD5_CTX>!, _ data: UnsafeRawPointer?, _ len: CC_LONG) -> Int32 { c.pointee.hasher?.update(bufferPointer: bytes(data, len)); return 1 }
@discardableResult public func CC_MD5_Final(_ md: UnsafeMutablePointer<UInt8>?, _ c: UnsafeMutablePointer<CC_MD5_CTX>!) -> Int32 { if let h = c.pointee.hasher { write(h.finalize(), md) }; return 1 }
@discardableResult public func CC_SHA1_Init(_ c: UnsafeMutablePointer<CC_SHA1_CTX>!) -> Int32 { c.pointee.hasher = .init(); return 1 }
@discardableResult public func CC_SHA1_Update(_ c: UnsafeMutablePointer<CC_SHA1_CTX>!, _ data: UnsafeRawPointer?, _ len: CC_LONG) -> Int32 { c.pointee.hasher?.update(bufferPointer: bytes(data, len)); return 1 }
@discardableResult public func CC_SHA1_Final(_ md: UnsafeMutablePointer<UInt8>?, _ c: UnsafeMutablePointer<CC_SHA1_CTX>!) -> Int32 { if let h = c.pointee.hasher { write(h.finalize(), md) }; return 1 }
@discardableResult public func CC_SHA256_Init(_ c: UnsafeMutablePointer<CC_SHA256_CTX>!) -> Int32 { c.pointee.hasher = .init(); return 1 }
@discardableResult public func CC_SHA256_Update(_ c: UnsafeMutablePointer<CC_SHA256_CTX>!, _ data: UnsafeRawPointer?, _ len: CC_LONG) -> Int32 { c.pointee.hasher?.update(bufferPointer: bytes(data, len)); return 1 }
@discardableResult public func CC_SHA256_Final(_ md: UnsafeMutablePointer<UInt8>?, _ c: UnsafeMutablePointer<CC_SHA256_CTX>!) -> Int32 { if let h = c.pointee.hasher { write(h.finalize(), md) }; return 1 }
@discardableResult public func CC_SHA512_Init(_ c: UnsafeMutablePointer<CC_SHA512_CTX>!) -> Int32 { c.pointee.hasher = .init(); return 1 }
@discardableResult public func CC_SHA512_Update(_ c: UnsafeMutablePointer<CC_SHA512_CTX>!, _ data: UnsafeRawPointer?, _ len: CC_LONG) -> Int32 { c.pointee.hasher?.update(bufferPointer: bytes(data, len)); return 1 }
@discardableResult public func CC_SHA512_Final(_ md: UnsafeMutablePointer<UInt8>?, _ c: UnsafeMutablePointer<CC_SHA512_CTX>!) -> Int32 { if let h = c.pointee.hasher { write(h.finalize(), md) }; return 1 }

// MARK: HMAC

private func hmac(_ alg: CCHmacAlgorithm, key: [UInt8], data: [UInt8]) -> [UInt8] {
    let k = SymmetricKey(data: key)
    switch alg {
    case kCCHmacAlgSHA1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
    case kCCHmacAlgMD5: return Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: k))
    case kCCHmacAlgSHA384: return Array(HMAC<SHA384>.authenticationCode(for: data, using: k))
    case kCCHmacAlgSHA512: return Array(HMAC<SHA512>.authenticationCode(for: data, using: k))
    default: return Array(HMAC<SHA256>.authenticationCode(for: data, using: k))
    }
}

public func CCHmac(_ algorithm: CCHmacAlgorithm, _ key: UnsafeRawPointer?, _ keyLength: Int, _ data: UnsafeRawPointer?, _ dataLength: Int,
                   _ macOut: UnsafeMutableRawPointer?) {
    let k = Array(UnsafeRawBufferPointer(start: key, count: key == nil ? 0 : keyLength))
    let d = Array(UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : dataLength))
    let mac = hmac(algorithm, key: k, data: d)
    guard let macOut else { return }
    mac.withUnsafeBytes { macOut.copyMemory(from: $0.baseAddress!, byteCount: mac.count) }
}

public struct CCHmacContext {
    var algorithm: CCHmacAlgorithm = 0
    var key: [UInt8] = []
    var data: [UInt8] = []
    public init() {}
}

public func CCHmacInit(_ ctx: UnsafeMutablePointer<CCHmacContext>!, _ algorithm: CCHmacAlgorithm, _ key: UnsafeRawPointer?, _ keyLength: Int) {
    ctx.pointee = CCHmacContext()
    ctx.pointee.algorithm = algorithm
    ctx.pointee.key = Array(UnsafeRawBufferPointer(start: key, count: key == nil ? 0 : keyLength))
}
public func CCHmacUpdate(_ ctx: UnsafeMutablePointer<CCHmacContext>!, _ data: UnsafeRawPointer?, _ dataLength: Int) {
    ctx.pointee.data += UnsafeRawBufferPointer(start: data, count: data == nil ? 0 : dataLength)
}
public func CCHmacFinal(_ ctx: UnsafeMutablePointer<CCHmacContext>!, _ macOut: UnsafeMutableRawPointer?) {
    let mac = hmac(ctx.pointee.algorithm, key: ctx.pointee.key, data: ctx.pointee.data)
    guard let macOut else { return }
    mac.withUnsafeBytes { macOut.copyMemory(from: $0.baseAddress!, byteCount: mac.count) }
}

// MARK: PBKDF2

public func CCKeyDerivationPBKDF(_ algorithm: CCPBKDFAlgorithm, _ password: UnsafePointer<CChar>!, _ passwordLen: Int,
                                 _ salt: UnsafePointer<UInt8>!, _ saltLen: Int, _ prf: CCPseudoRandomAlgorithm, _ rounds: UInt32,
                                 _ derivedKey: UnsafeMutablePointer<UInt8>!, _ derivedKeyLen: Int) -> Int32 {
    guard algorithm == kCCPBKDF2, let derivedKey else { return kCCParamError }
    let pw = Array(UnsafeRawBufferPointer(start: password, count: password == nil ? 0 : passwordLen))
    let s = Array(UnsafeBufferPointer(start: salt, count: salt == nil ? 0 : saltLen))
    let alg: CCHmacAlgorithm = switch prf {
    case kCCPRFHmacAlgSHA1: kCCHmacAlgSHA1
    case kCCPRFHmacAlgSHA384: kCCHmacAlgSHA384
    case kCCPRFHmacAlgSHA512: kCCHmacAlgSHA512
    default: kCCHmacAlgSHA256
    }
    var out: [UInt8] = []
    var blockIndex: UInt32 = 1
    while out.count < derivedKeyLen {
        var u = hmac(alg, key: pw, data: s + [UInt8(blockIndex >> 24), UInt8(blockIndex >> 16 & 0xff), UInt8(blockIndex >> 8 & 0xff), UInt8(blockIndex & 0xff)])
        var t = u
        if rounds > 1 {
            for _ in 1..<rounds {
                u = hmac(alg, key: pw, data: u)
                for i in 0..<t.count { t[i] ^= u[i] }
            }
        }
        out += t
        blockIndex += 1
    }
    for i in 0..<derivedKeyLen { derivedKey[i] = out[i] }
    return kCCSuccess
}

// MARK: AES

/// AES (FIPS-197) block cipher with 128/192/256-bit keys.
struct AESBlock {
    static let sbox: [UInt8] = {
        var s = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1, q: UInt8 = 1
        repeat {
            p = p ^ (p << 1) ^ (p & 0x80 != 0 ? 0x1b : 0)
            q ^= q << 1; q ^= q << 2; q ^= q << 4
            if q & 0x80 != 0 { q ^= 0x09 }
            let x = q ^ (q << 1 | q >> 7) ^ (q << 2 | q >> 6) ^ (q << 3 | q >> 5) ^ (q << 4 | q >> 4)
            s[Int(p)] = x ^ 0x63
        } while p != 1
        s[0] = 0x63
        return s
    }()
    static let inverse: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for (i, v) in sbox.enumerated() { inv[Int(v)] = UInt8(i) }
        return inv
    }()

    let roundKeys: [[UInt8]]
    let rounds: Int

    init?(key: [UInt8]) {
        guard [16, 24, 32].contains(key.count) else { return nil }
        let nk = key.count / 4
        rounds = nk + 6
        var w: [[UInt8]] = stride(from: 0, to: key.count, by: 4).map { Array(key[$0..<$0 + 4]) }
        var rcon: UInt8 = 1
        for i in nk..<(4 * (rounds + 1)) {
            var t = w[i - 1]
            if i % nk == 0 {
                t = [t[1], t[2], t[3], t[0]].map { Self.sbox[Int($0)] }
                t[0] ^= rcon
                rcon = Self.xtime(rcon)
            } else if nk > 6 && i % nk == 4 {
                t = t.map { Self.sbox[Int($0)] }
            }
            w.append(zip(w[i - nk], t).map { $0 ^ $1 })
        }
        roundKeys = (0...rounds).map { r in Array(w[4 * r..<4 * r + 4].joined()) }
    }

    static func xtime(_ x: UInt8) -> UInt8 { (x << 1) ^ (x & 0x80 != 0 ? 0x1b : 0) }
    static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, r: UInt8 = 0
        while b != 0 { if b & 1 != 0 { r ^= a }; a = xtime(a); b >>= 1 }
        return r
    }

    func encrypt(_ input: [UInt8]) -> [UInt8] {
        var s = zip(input, roundKeys[0]).map { $0 ^ $1 }
        for r in 1...rounds {
            s = s.map { Self.sbox[Int($0)] }
            s = [s[0], s[5], s[10], s[15], s[4], s[9], s[14], s[3], s[8], s[13], s[2], s[7], s[12], s[1], s[6], s[11]]
            if r != rounds {
                var m = s
                for c in 0..<4 {
                    let a = Array(s[4 * c..<4 * c + 4])
                    m[4 * c] = Self.mul(a[0], 2) ^ Self.mul(a[1], 3) ^ a[2] ^ a[3]
                    m[4 * c + 1] = a[0] ^ Self.mul(a[1], 2) ^ Self.mul(a[2], 3) ^ a[3]
                    m[4 * c + 2] = a[0] ^ a[1] ^ Self.mul(a[2], 2) ^ Self.mul(a[3], 3)
                    m[4 * c + 3] = Self.mul(a[0], 3) ^ a[1] ^ a[2] ^ Self.mul(a[3], 2)
                }
                s = m
            }
            s = zip(s, roundKeys[r]).map { $0 ^ $1 }
        }
        return s
    }

    func decrypt(_ input: [UInt8]) -> [UInt8] {
        var s = zip(input, roundKeys[rounds]).map { $0 ^ $1 }
        for r in stride(from: rounds - 1, through: 0, by: -1) {
            s = [s[0], s[13], s[10], s[7], s[4], s[1], s[14], s[11], s[8], s[5], s[2], s[15], s[12], s[9], s[6], s[3]]
            s = s.map { Self.inverse[Int($0)] }
            s = zip(s, roundKeys[r]).map { $0 ^ $1 }
            if r != 0 {
                var m = s
                for c in 0..<4 {
                    let a = Array(s[4 * c..<4 * c + 4])
                    m[4 * c] = Self.mul(a[0], 14) ^ Self.mul(a[1], 11) ^ Self.mul(a[2], 13) ^ Self.mul(a[3], 9)
                    m[4 * c + 1] = Self.mul(a[0], 9) ^ Self.mul(a[1], 14) ^ Self.mul(a[2], 11) ^ Self.mul(a[3], 13)
                    m[4 * c + 2] = Self.mul(a[0], 13) ^ Self.mul(a[1], 9) ^ Self.mul(a[2], 14) ^ Self.mul(a[3], 11)
                    m[4 * c + 3] = Self.mul(a[0], 11) ^ Self.mul(a[1], 13) ^ Self.mul(a[2], 9) ^ Self.mul(a[3], 14)
                }
                s = m
            }
        }
        return s
    }
}

/// A streaming AES cryptor (CBC or ECB, optional PKCS#7 padding).
public final class _CCCryptorState {
    let op: CCOperation
    let cipher: AESBlock
    let ecb: Bool
    let padding: Bool
    var iv: [UInt8]
    var pending: [UInt8] = []

    init(op: CCOperation, cipher: AESBlock, ecb: Bool, padding: Bool, iv: [UInt8]) {
        self.op = op; self.cipher = cipher; self.ecb = ecb; self.padding = padding; self.iv = iv
    }

    func process(_ block: [UInt8]) -> [UInt8] {
        if op == kCCEncrypt {
            let x = ecb ? block : zip(block, iv).map { $0 ^ $1 }
            let c = cipher.encrypt(x)
            iv = c
            return c
        }
        let p = cipher.decrypt(block)
        let out = ecb ? p : zip(p, iv).map { $0 ^ $1 }
        iv = block
        return out
    }

    func update(_ input: [UInt8]) -> [UInt8] {
        pending += input
        var out: [UInt8] = []
        // Decrypting with padding keeps the last whole block for final().
        let keepLast = op == kCCDecrypt && padding
        while keepLast ? pending.count > 16 : pending.count >= 16 {
            out += process(Array(pending.prefix(16)))
            pending.removeFirst(16)
        }
        return out
    }

    func final() -> ([UInt8], CCCryptorStatus) {
        if op == kCCEncrypt {
            if padding {
                let n = 16 - pending.count % 16
                let block = pending + [UInt8](repeating: UInt8(n), count: n)
                pending = []
                var out: [UInt8] = []
                var i = 0
                while i < block.count { out += process(Array(block[i..<i + 16])); i += 16 }
                return (out, kCCSuccess)
            }
            return pending.isEmpty ? ([], kCCSuccess) : ([], kCCAlignmentError)
        }
        guard pending.count % 16 == 0 else { return ([], kCCAlignmentError) }
        var out: [UInt8] = []
        var i = 0
        while i < pending.count { out += process(Array(pending[i..<i + 16])); i += 16 }
        pending = []
        if padding {
            guard let n = out.last, n >= 1, n <= 16, out.count >= Int(n), out.suffix(Int(n)).allSatisfy({ $0 == n }) else { return ([], kCCDecodeError) }
            out.removeLast(Int(n))
        }
        return (out, kCCSuccess)
    }
}

public typealias CCCryptorRef = _CCCryptorState

public func CCCryptorCreate(_ op: CCOperation, _ alg: CCAlgorithm, _ options: CCOptions, _ key: UnsafeRawPointer!, _ keyLength: Int,
                            _ iv: UnsafeRawPointer!, _ cryptorRef: UnsafeMutablePointer<CCCryptorRef?>!) -> CCCryptorStatus {
    guard alg == kCCAlgorithmAES else { return kCCUnimplemented }
    guard let key, let cipher = AESBlock(key: Array(UnsafeRawBufferPointer(start: key, count: keyLength))) else { return kCCKeySizeError }
    let ivBytes = iv.map { Array(UnsafeRawBufferPointer(start: $0, count: 16)) } ?? [UInt8](repeating: 0, count: 16)
    cryptorRef?.pointee = _CCCryptorState(op: op, cipher: cipher, ecb: options & kCCOptionECBMode != 0,
                                          padding: options & kCCOptionPKCS7Padding != 0, iv: ivBytes)
    return kCCSuccess
}

public func CCCryptorUpdate(_ cryptor: CCCryptorRef!, _ dataIn: UnsafeRawPointer!, _ dataInLength: Int, _ dataOut: UnsafeMutableRawPointer!,
                            _ dataOutAvailable: Int, _ dataOutMoved: UnsafeMutablePointer<Int>!) -> CCCryptorStatus {
    guard let cryptor else { return kCCParamError }
    let out = cryptor.update(Array(UnsafeRawBufferPointer(start: dataIn, count: dataIn == nil ? 0 : dataInLength)))
    guard out.count <= dataOutAvailable else { return kCCBufferTooSmall }
    if !out.isEmpty { out.withUnsafeBytes { dataOut.copyMemory(from: $0.baseAddress!, byteCount: out.count) } }
    dataOutMoved?.pointee = out.count
    return kCCSuccess
}

public func CCCryptorFinal(_ cryptor: CCCryptorRef!, _ dataOut: UnsafeMutableRawPointer!, _ dataOutAvailable: Int,
                           _ dataOutMoved: UnsafeMutablePointer<Int>!) -> CCCryptorStatus {
    guard let cryptor else { return kCCParamError }
    let (out, status) = cryptor.final()
    guard status == kCCSuccess else { return status }
    guard out.count <= dataOutAvailable else { return kCCBufferTooSmall }
    if !out.isEmpty { out.withUnsafeBytes { dataOut.copyMemory(from: $0.baseAddress!, byteCount: out.count) } }
    dataOutMoved?.pointee = out.count
    return kCCSuccess
}

@discardableResult public func CCCryptorRelease(_ cryptor: CCCryptorRef!) -> CCCryptorStatus { kCCSuccess }

public func CCCryptorGetOutputLength(_ cryptor: CCCryptorRef!, _ inputLength: Int, _ final: Bool) -> Int {
    (inputLength + (cryptor?.pending.count ?? 0) + 16) / 16 * 16
}

public func CCCrypt(_ op: CCOperation, _ alg: CCAlgorithm, _ options: CCOptions, _ key: UnsafeRawPointer!, _ keyLength: Int,
                    _ iv: UnsafeRawPointer!, _ dataIn: UnsafeRawPointer!, _ dataInLength: Int, _ dataOut: UnsafeMutableRawPointer!,
                    _ dataOutAvailable: Int, _ dataOutMoved: UnsafeMutablePointer<Int>!) -> CCCryptorStatus {
    var ref: CCCryptorRef?
    let created = CCCryptorCreate(op, alg, options, key, keyLength, iv, &ref)
    guard created == kCCSuccess, let ref else { return created }
    let input = Array(UnsafeRawBufferPointer(start: dataIn, count: dataIn == nil ? 0 : dataInLength))
    let first = ref.update(input)
    let (last, status) = ref.final()
    guard status == kCCSuccess else { return status }
    let out = first + last
    dataOutMoved?.pointee = out.count
    guard out.count <= dataOutAvailable else { return kCCBufferTooSmall }
    if !out.isEmpty { out.withUnsafeBytes { dataOut.copyMemory(from: $0.baseAddress!, byteCount: out.count) } }
    return kCCSuccess
}

// MARK: Random

public typealias CCRNGStatus = CCCryptorStatus
public func CCRandomGenerateBytes(_ bytes: UnsafeMutableRawPointer!, _ count: Int) -> CCRNGStatus {
    var g = SystemRandomNumberGenerator()
    for i in 0..<count { bytes.storeBytes(of: UInt8.random(in: 0...255, using: &g), toByteOffset: i, as: UInt8.self) }
    return kCCSuccess
}
