import XCTest
import CommonCrypto
import CryptoKit

final class CommonCryptoTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); out.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        return out
    }

    func testDigests() {
        let abc = Array("abc".utf8)
        var md5 = [UInt8](repeating: 0, count: 16)
        CC_MD5(abc, CC_LONG(abc.count), &md5)
        XCTAssertEqual(hex(md5), "900150983cd24fb0d6963f7d28e17f72")
        var sha256 = [UInt8](repeating: 0, count: 32)
        CC_SHA256(abc, 3, &sha256)
        XCTAssertEqual(hex(sha256), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var sha512 = [UInt8](repeating: 0, count: 64)
        CC_SHA512(abc, 3, &sha512)
        XCTAssertEqual(hex(sha512), "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        XCTAssertEqual(hex(Array(SHA384.hash(data: abc))), "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")

        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)
        CC_SHA256_Update(&ctx, Array("a".utf8), 1)
        CC_SHA256_Update(&ctx, Array("bc".utf8), 2)
        var out = [UInt8](repeating: 0, count: 32)
        CC_SHA256_Final(&out, &ctx)
        XCTAssertEqual(out, sha256)
    }

    func testHMAC() {
        let key = Array("key".utf8), msg = Array("The quick brown fox jumps over the lazy dog".utf8)
        var mac = [UInt8](repeating: 0, count: 32)
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, msg, msg.count, &mac)
        XCTAssertEqual(hex(mac), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
    }

    func testAESKnownAnswer() {
        // FIPS-197 appendix C.1 (AES-128) and C.3 (AES-256), one block, ECB, no padding.
        let pt = bytes("00112233445566778899aabbccddeeff")
        for (key, ct) in [("000102030405060708090a0b0c0d0e0f", "69c4e0d86a7b0430d8cdb78070b4c55a"),
                          ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "8ea2b7ca516745bfeafc49904b496089")] {
            let k = bytes(key)
            var out = [UInt8](repeating: 0, count: 16)
            var moved = 0
            XCTAssertEqual(CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), k, k.count, nil,
                                   pt, 16, &out, 16, &moved), kCCSuccess)
            XCTAssertEqual(hex(out), ct)
            var back = [UInt8](repeating: 0, count: 16)
            XCTAssertEqual(CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), k, k.count, nil,
                                   out, 16, &back, 16, &moved), kCCSuccess)
            XCTAssertEqual(back, pt)
        }
    }

    func testAESCBCPaddingRoundTrip() {
        let key = [UInt8](repeating: 7, count: kCCKeySizeAES256), iv = [UInt8](repeating: 1, count: 16)
        for length in [0, 5, 16, 33] {
            let msg = (0..<length).map { UInt8($0) }
            var ct = [UInt8](repeating: 0, count: length + 16)
            var n = 0
            XCTAssertEqual(CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                                   msg, msg.count, &ct, ct.count, &n), kCCSuccess)
            XCTAssertEqual(n, (length / 16 + 1) * 16)
            var pt = [UInt8](repeating: 0, count: n)
            var m = 0
            XCTAssertEqual(CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                                   ct, n, &pt, pt.count, &m), kCCSuccess)
            XCTAssertEqual(Array(pt.prefix(m)), msg)
        }
    }

    func testPBKDF2() {
        // RFC 6070, test 2 (SHA-1, 2 iterations).
        var dk = [UInt8](repeating: 0, count: 20)
        let salt = Array("salt".utf8)
        XCTAssertEqual(CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), "password", 8, salt, salt.count,
                                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 2, &dk, 20), kCCSuccess)
        XCTAssertEqual(hex(dk), "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
    }
}
