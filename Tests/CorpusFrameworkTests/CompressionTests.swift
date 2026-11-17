import XCTest
import Compression

final class CompressionTests: XCTestCase {
    let sample = Array(String(repeating: "Runway compresses like a Mac. ", count: 200).utf8)

    func roundTrip(_ algorithm: compression_algorithm) throws {
        var packed = [UInt8](repeating: 0, count: sample.count + 1024)
        let n = compression_encode_buffer(&packed, packed.count, sample, sample.count, nil, algorithm)
        XCTAssertGreaterThan(n, 0)
        XCTAssertLessThan(n, sample.count)
        var unpacked = [UInt8](repeating: 0, count: sample.count)
        let m = compression_decode_buffer(&unpacked, unpacked.count, packed, n, nil, algorithm)
        XCTAssertEqual(m, sample.count)
        XCTAssertEqual(unpacked, sample)
    }

    func testZlibBuffer() throws { try roundTrip(COMPRESSION_ZLIB) }

    func testLZMABufferWhenAvailable() throws {
        guard LZMAProbe.available else { throw XCTSkip("liblzma not installed") }
        try roundTrip(COMPRESSION_LZMA)
    }

    func testUnsupportedAlgorithmsFail() {
        var out = [UInt8](repeating: 0, count: 100)
        XCTAssertEqual(compression_encode_buffer(&out, out.count, sample, sample.count, nil, COMPRESSION_LZFSE), 0)
    }

    func testStream() throws {
        var packed: [UInt8] = []
        for (op, input) in [(COMPRESSION_STREAM_ENCODE, sample)] {
            var stream = compression_stream()
            XCTAssertEqual(compression_stream_init(&stream, op, COMPRESSION_ZLIB), COMPRESSION_STATUS_OK)
            var dst = [UInt8](repeating: 0, count: 256)
            input.withUnsafeBufferPointer { src in
                stream.src_ptr = src.baseAddress!
                stream.src_size = src.count
                var status = COMPRESSION_STATUS_OK
                repeat {
                    dst.withUnsafeMutableBufferPointer { d in
                        stream.dst_ptr = d.baseAddress!
                        stream.dst_size = d.count
                        status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                        packed += d[0..<(d.count - stream.dst_size)]
                    }
                } while status == COMPRESSION_STATUS_OK
                XCTAssertEqual(status, COMPRESSION_STATUS_END)
            }
            _ = compression_stream_destroy(&stream)
        }
        var out = [UInt8](repeating: 0, count: sample.count)
        XCTAssertEqual(compression_decode_buffer(&out, out.count, packed, packed.count, nil, COMPRESSION_ZLIB), sample.count)
        XCTAssertEqual(out, sample)
    }

    func testFilters() throws {
        var packed = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { if let d = $0 { packed.append(d) } }
        try filter.write(Data(sample.prefix(1000)))
        try filter.write(Data(sample.dropFirst(1000)))
        try filter.finalize()
        var index = 0
        let input = try InputFilter(.decompress, using: .zlib) { (n: Int) -> Data? in
            let chunk = packed.subdata(in: index..<min(index + n, packed.count))
            index += chunk.count
            return chunk
        }
        var out = Data()
        while let d = try input.readData(ofLength: 777) { out.append(d) }
        XCTAssertEqual(Array(out), sample)
    }
}

enum LZMAProbe {
    static var available: Bool {
        var out = [UInt8](repeating: 0, count: 100)
        let src: [UInt8] = [1, 2, 3]
        return compression_encode_buffer(&out, out.count, src, 3, nil, COMPRESSION_LZMA) > 0
    }
}
