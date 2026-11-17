// Compression: Apple's buffer and stream APIs and the Swift filters.
// COMPRESSION_ZLIB is raw DEFLATE (RFC 1951) through zlib, as on Apple
// platforms; COMPRESSION_LZMA is xz through liblzma, loaded at run time
// when the system has it. LZFSE, LZ4 and Brotli are Apple's own formats
// with no implementation here: they fail as unsupported (0 bytes, or
// COMPRESSION_STATUS_ERROR).

@_exported import Foundation
#if canImport(CRunwayZlib)
import CRunwayZlib
#endif

public struct compression_algorithm: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
public let COMPRESSION_LZ4 = compression_algorithm(0x100)
public let COMPRESSION_LZ4_RAW = compression_algorithm(0x101)
public let COMPRESSION_ZLIB = compression_algorithm(0x205)
public let COMPRESSION_LZMA = compression_algorithm(0x306)
public let COMPRESSION_LZFSE = compression_algorithm(0x801)
public let COMPRESSION_BROTLI = compression_algorithm(0xB02)
public let COMPRESSION_LZBITMAP = compression_algorithm(0x702)

public struct compression_stream_operation: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
public let COMPRESSION_STREAM_ENCODE = compression_stream_operation(0)
public let COMPRESSION_STREAM_DECODE = compression_stream_operation(1)

public struct compression_stream_flags: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}
public let COMPRESSION_STREAM_FINALIZE = compression_stream_flags(1)

public struct compression_status: RawRepresentable, Hashable, Sendable {
    public var rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public init(_ rawValue: Int32) { self.rawValue = rawValue }
}
public let COMPRESSION_STATUS_OK = compression_status(0)
public let COMPRESSION_STATUS_ERROR = compression_status(-1)
public let COMPRESSION_STATUS_END = compression_status(1)

// MARK: Codecs

/// One direction of one algorithm, fed and drained in chunks.
protocol Codec: AnyObject {
    /// Consumes input and returns output; `finish` flushes. `done` once the end is reached.
    func process(_ input: UnsafeRawBufferPointer, finish: Bool, into out: inout [UInt8]) throws -> (consumed: Int, done: Bool)
}

enum CodecError: Error { case unsupported, failed }

#if canImport(CRunwayZlib)
final class ZlibCodec: Codec {
    var stream = z_stream()
    let encode: Bool
    var open = false
    init(encode: Bool) throws {
        self.encode = encode
        let r = encode
            ? deflateInit2_(&stream, 5, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard r == Z_OK else { throw CodecError.failed }
        open = true
    }
    deinit { if open { if encode { deflateEnd(&stream) } else { inflateEnd(&stream) } } }

    func process(_ input: UnsafeRawBufferPointer, finish: Bool, into out: inout [UInt8]) throws -> (consumed: Int, done: Bool) {
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var done = false
        repeat {
            let status: Int32 = chunk.withUnsafeMutableBufferPointer { b in
                stream.next_out = b.baseAddress
                stream.avail_out = uInt(b.count)
                return encode ? deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH) : inflate(&stream, Z_NO_FLUSH)
            }
            out += chunk[0..<(chunk.count - Int(stream.avail_out))]
            if status == Z_STREAM_END { done = true; break }
            if status == Z_BUF_ERROR { break }
            guard status == Z_OK else { throw CodecError.failed }
        } while stream.avail_out == 0 || stream.avail_in > 0
        return (input.count - Int(stream.avail_in), done)
    }
}
#endif

/// liblzma's buffer API, loaded at run time (xz streams).
enum LZMA {
    typealias Encode = @convention(c) (UInt32, Int32, UnsafeRawPointer?, UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>?, Int) -> Int32
    typealias Decode = @convention(c) (UnsafeMutablePointer<UInt64>?, UInt32, UnsafeRawPointer?, UnsafePointer<UInt8>?, UnsafeMutablePointer<Int>?, Int,
                                       UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<Int>?, Int) -> Int32
    nonisolated(unsafe) static let handle: UnsafeMutableRawPointer? = {
        #if os(Linux)
        return dlopen("liblzma.so.5", RTLD_NOW) ?? dlopen("liblzma.so", RTLD_NOW)
        #else
        return nil
        #endif
    }()
    static var encode: Encode? {
        #if os(Linux)
        guard let h = handle, let s = dlsym(h, "lzma_easy_buffer_encode") else { return nil }
        return unsafeBitCast(s, to: Encode.self)
        #else
        return nil
        #endif
    }
    static var decode: Decode? {
        #if os(Linux)
        guard let h = handle, let s = dlsym(h, "lzma_stream_buffer_decode") else { return nil }
        return unsafeBitCast(s, to: Decode.self)
        #else
        return nil
        #endif
    }

    static func compress(_ input: [UInt8]) throws -> [UInt8] {
        guard let encode else { throw CodecError.unsupported }
        var out = [UInt8](repeating: 0, count: input.count + input.count / 2 + 1024)
        var pos = 0
        let r = input.withUnsafeBufferPointer { i in
            out.withUnsafeMutableBufferPointer { o in encode(6, 4 /* LZMA_CHECK_CRC64 */, nil, i.baseAddress, i.count, o.baseAddress, &pos, o.count) }
        }
        guard r == 0 else { throw CodecError.failed }
        return Array(out.prefix(pos))
    }

    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        guard let decode else { throw CodecError.unsupported }
        var size = max(input.count * 4, 4096)
        while true {
            var out = [UInt8](repeating: 0, count: size)
            var memlimit = UInt64.max
            var inPos = 0, outPos = 0
            let r = input.withUnsafeBufferPointer { i in
                out.withUnsafeMutableBufferPointer { o in decode(&memlimit, 0, nil, i.baseAddress, &inPos, i.count, o.baseAddress, &outPos, o.count) }
            }
            if r == 0 { return Array(out.prefix(outPos)) }
            if r == 10 /* LZMA_BUF_ERROR */ && size < 1 << 31 { size *= 4; continue }
            throw CodecError.failed
        }
    }
}

/// LZMA here is whole-buffer: input collects until the stream finishes.
final class BufferedCodec: Codec {
    let transform: ([UInt8]) throws -> [UInt8]
    var input: [UInt8] = []
    init(_ transform: @escaping ([UInt8]) throws -> [UInt8]) { self.transform = transform }
    func process(_ chunk: UnsafeRawBufferPointer, finish: Bool, into out: inout [UInt8]) throws -> (consumed: Int, done: Bool) {
        input += chunk
        guard finish else { return (chunk.count, false) }
        out += try transform(input)
        input = []
        return (chunk.count, true)
    }
}

func makeCodec(_ algorithm: compression_algorithm, encode: Bool) throws -> Codec {
    switch algorithm {
    case COMPRESSION_ZLIB:
        #if canImport(CRunwayZlib)
        return try ZlibCodec(encode: encode)
        #else
        throw CodecError.unsupported
        #endif
    case COMPRESSION_LZMA:
        guard encode ? LZMA.encode != nil : LZMA.decode != nil else { throw CodecError.unsupported }
        return BufferedCodec(encode ? LZMA.compress : LZMA.decompress)
    default:
        throw CodecError.unsupported
    }
}

// MARK: Buffer API

public func compression_encode_scratch_buffer_size(_ algorithm: compression_algorithm) -> Int { 0 }
public func compression_decode_scratch_buffer_size(_ algorithm: compression_algorithm) -> Int { 0 }

private func oneShot(_ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int, _ src: UnsafePointer<UInt8>, _ srcSize: Int,
                     _ algorithm: compression_algorithm, encode: Bool) -> Int {
    guard let codec = try? makeCodec(algorithm, encode: encode) else { return 0 }
    var out: [UInt8] = []
    guard (try? codec.process(UnsafeRawBufferPointer(start: src, count: srcSize), finish: true, into: &out)) != nil else { return 0 }
    // Encoding that doesn't fit fails; decoding fills what fits (as Apple's does).
    if encode && out.count > dstSize { return 0 }
    let n = min(out.count, dstSize)
    for i in 0..<n { dst[i] = out[i] }
    return n
}

public func compression_encode_buffer(_ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int, _ src: UnsafePointer<UInt8>, _ srcSize: Int,
                                      _ scratch: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm) -> Int {
    oneShot(dst, dstSize, src, srcSize, algorithm, encode: true)
}

public func compression_decode_buffer(_ dst: UnsafeMutablePointer<UInt8>, _ dstSize: Int, _ src: UnsafePointer<UInt8>, _ srcSize: Int,
                                      _ scratch: UnsafeMutableRawPointer?, _ algorithm: compression_algorithm) -> Int {
    oneShot(dst, dstSize, src, srcSize, algorithm, encode: false)
}

// MARK: Stream API

public struct compression_stream {
    public var dst_ptr: UnsafeMutablePointer<UInt8>
    public var dst_size: Int
    public var src_ptr: UnsafePointer<UInt8>
    public var src_size: Int
    public var state: UnsafeMutableRawPointer?
    public init() {
        dst_ptr = UnsafeMutablePointer(bitPattern: 1)!
        dst_size = 0
        src_ptr = UnsafePointer(bitPattern: 1)!
        src_size = 0
        state = nil
    }
    public init(dst_ptr: UnsafeMutablePointer<UInt8>, dst_size: Int, src_ptr: UnsafePointer<UInt8>, src_size: Int, state: UnsafeMutableRawPointer?) {
        self.dst_ptr = dst_ptr; self.dst_size = dst_size; self.src_ptr = src_ptr; self.src_size = src_size; self.state = state
    }
}

final class StreamState {
    let codec: Codec
    var pending: [UInt8] = []
    var ended = false
    init(_ codec: Codec) { self.codec = codec }
}

public func compression_stream_init(_ stream: UnsafeMutablePointer<compression_stream>, _ operation: compression_stream_operation,
                                    _ algorithm: compression_algorithm) -> compression_status {
    guard let codec = try? makeCodec(algorithm, encode: operation == COMPRESSION_STREAM_ENCODE) else { return COMPRESSION_STATUS_ERROR }
    stream.pointee.state = Unmanaged.passRetained(StreamState(codec)).toOpaque()
    return COMPRESSION_STATUS_OK
}

public func compression_stream_process(_ stream: UnsafeMutablePointer<compression_stream>, _ flags: Int32) -> compression_status {
    guard let raw = stream.pointee.state else { return COMPRESSION_STATUS_ERROR }
    let st = Unmanaged<StreamState>.fromOpaque(raw).takeUnretainedValue()
    let finish = flags & Int32(COMPRESSION_STREAM_FINALIZE.rawValue) != 0
    if !st.ended {
        do {
            let (consumed, done) = try st.codec.process(UnsafeRawBufferPointer(start: stream.pointee.src_ptr, count: stream.pointee.src_size),
                                                        finish: finish, into: &st.pending)
            stream.pointee.src_ptr += consumed
            stream.pointee.src_size -= consumed
            st.ended = done
        } catch {
            return COMPRESSION_STATUS_ERROR
        }
    }
    let n = min(st.pending.count, stream.pointee.dst_size)
    for i in 0..<n { stream.pointee.dst_ptr[i] = st.pending[i] }
    st.pending.removeFirst(n)
    stream.pointee.dst_ptr += n
    stream.pointee.dst_size -= n
    return st.ended && st.pending.isEmpty ? COMPRESSION_STATUS_END : COMPRESSION_STATUS_OK
}

public func compression_stream_process(_ stream: UnsafeMutablePointer<compression_stream>, _ flags: compression_stream_flags) -> compression_status {
    compression_stream_process(stream, Int32(flags.rawValue))
}

public func compression_stream_destroy(_ stream: UnsafeMutablePointer<compression_stream>) -> compression_status {
    if let raw = stream.pointee.state { Unmanaged<StreamState>.fromOpaque(raw).release() }
    stream.pointee.state = nil
    return COMPRESSION_STATUS_OK
}

// MARK: Swift filters

public enum Algorithm: CaseIterable, Sendable {
    case lz4, zlib, lzma, lzfse
    var raw: compression_algorithm {
        switch self {
        case .lz4: COMPRESSION_LZ4
        case .zlib: COMPRESSION_ZLIB
        case .lzma: COMPRESSION_LZMA
        case .lzfse: COMPRESSION_LZFSE
        }
    }
}

public enum FilterOperation: Sendable { case compress, decompress }

public enum FilterError: Error { case invalidState, invalidData, writeToFinalizedFilter, readFromFinalizedFilter }

/// Pushes data through: `write` chunks (nil or empty at the end); the
/// output goes to the closure as it's produced.
public final class OutputFilter {
    let codec: Codec
    let writeFunc: (Data?) throws -> Void
    var finalized = false
    public init(_ operation: FilterOperation, using algorithm: Algorithm, bufferCapacity: Int = 65536,
                writingTo writeFunc: @escaping (Data?) throws -> Void) throws {
        guard let c = try? makeCodec(algorithm.raw, encode: operation == .compress) else { throw FilterError.invalidState }
        codec = c
        self.writeFunc = writeFunc
    }
    public func write<D: DataProtocol>(_ data: D?) throws {
        guard !finalized else { throw FilterError.writeToFinalizedFilter }
        let bytes = data.map { Array($0) } ?? []
        let finish = bytes.isEmpty
        var out: [UInt8] = []
        do {
            _ = try bytes.withUnsafeBytes { try codec.process($0, finish: finish, into: &out) }
        } catch { throw FilterError.invalidData }
        if !out.isEmpty { try writeFunc(Data(out)) }
        if finish { finalized = true; try writeFunc(nil) }
    }
    public func finalize() throws { if !finalized { try write(nil as Data?) } }
}

/// Pulls data through: `readData(ofLength:)` reads from the closure.
public final class InputFilter<D: DataProtocol> {
    let codec: Codec
    let readFunc: (Int) throws -> D?
    var buffer: [UInt8] = []
    var sourceDone = false
    var codecDone = false
    public init(_ operation: FilterOperation, using algorithm: Algorithm, bufferCapacity: Int = 65536,
                readingFrom readFunc: @escaping (Int) throws -> D?) throws {
        guard let c = try? makeCodec(algorithm.raw, encode: operation == .compress) else { throw FilterError.invalidState }
        codec = c
        self.readFunc = readFunc
    }
    public func readData(ofLength count: Int) throws -> Data? {
        while buffer.count < count && !codecDone {
            let chunk = sourceDone ? nil : try readFunc(65536)
            let bytes = chunk.map { Array($0) } ?? []
            if bytes.isEmpty { sourceDone = true }
            do {
                let r = try bytes.withUnsafeBytes { try codec.process($0, finish: sourceDone, into: &buffer) }
                if r.done || sourceDone { codecDone = codecDone || r.done || sourceDone }
            } catch { throw FilterError.invalidData }
        }
        guard !buffer.isEmpty else { return nil }
        let n = min(count, buffer.count)
        defer { buffer.removeFirst(n) }
        return Data(buffer[0..<n])
    }
}
