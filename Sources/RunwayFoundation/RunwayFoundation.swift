// What Apple's Foundation has and swift-corelibs-foundation lacks, for
// code that only `import Foundation`: Runway's build tool adds this module
// to every target it stages, so the extensions resolve unchanged.
//
//   NSData.compressed/decompressed(using:)   zlib (raw DEFLATE, as Apple's .zlib)
//   FileManager.trashItem(at:resultingItemURL:)  the freedesktop Trash
//   CFData, CFString, CFDictionary…          the toll-free bridged names

// Re-exported so `RunwayFoundation.write(…)` (what `Darwin.write(…)`
// becomes) finds the C library through Foundation, and the Darwin-shaped
// overloads declared here beside it.
@_exported import Foundation
#if os(Linux)
import CRunwayZlib
// DistributedNotificationCenter: Foundation has it on the Mac, corelibs doesn't.
@_exported import RunwayDistributedNotifications
// On the Mac, Foundation brings Combine (ObservableObject, publishers).
@_exported import Combine
#endif

// MARK: Core Foundation names

public typealias CFData = NSData
public typealias CFMutableData = NSMutableData
public typealias CFString = NSString
public typealias CFDictionary = NSDictionary
public typealias CFMutableDictionary = NSMutableDictionary
public typealias CFArray = NSArray
public typealias CFNumber = NSNumber
public typealias CFURL = NSURL
public typealias CFTypeRef = AnyObject
public typealias CFIndex = Int
public typealias CFTimeInterval = Double
public typealias OSStatus = Int32
public let noErr: OSStatus = 0

public typealias CFTypeID = UInt
public typealias CFBoolean = NSNumber

/// Core Foundation type identity, as far as Foundation objects need it:
/// booleans (corelibs' __NSCFBoolean), numbers, strings, data, collections.
public func CFGetTypeID(_ cf: AnyObject?) -> CFTypeID {
    guard let cf else { return 0 }
    switch cf {
    case is NSNumber: return String(describing: type(of: cf)) == "__NSCFBoolean" ? CFBooleanGetTypeID() : CFNumberGetTypeID()
    case is NSString: return CFStringGetTypeID()
    case is NSData: return CFDataGetTypeID()
    case is NSArray: return CFArrayGetTypeID()
    case is NSDictionary: return CFDictionaryGetTypeID()
    default: return UInt(bitPattern: ObjectIdentifier(type(of: cf)).hashValue)
    }
}
public func CFBooleanGetTypeID() -> CFTypeID { 21 }
public func CFNumberGetTypeID() -> CFTypeID { 22 }
public func CFStringGetTypeID() -> CFTypeID { 7 }
public func CFDataGetTypeID() -> CFTypeID { 20 }
public func CFArrayGetTypeID() -> CFTypeID { 19 }
public func CFDictionaryGetTypeID() -> CFTypeID { 18 }
public func CFBooleanGetValue(_ b: NSNumber) -> Bool { b.boolValue }
/// Whether a number holds a float or double.
public func CFNumberIsFloatType(_ n: NSNumber) -> Bool {
    let t = String(cString: n.objCType)
    return t == "d" || t == "f"
}

// MARK: Compression

extension NSData {
    public enum CompressionAlgorithm: Int, Sendable {
        case lzfse, lz4, lzma, zlib
    }

    public enum CompressionError: Error { case unsupported, failed }

    /// `.zlib` is raw DEFLATE (RFC 1951), as on Apple platforms.
    public func compressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        guard algorithm == .zlib else { throw CompressionError.unsupported }
        return NSData(data: try Deflate.compress(Data(referencing: self)))
    }

    public func decompressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        guard algorithm == .zlib else { throw CompressionError.unsupported }
        return NSData(data: try Deflate.decompress(Data(referencing: self)))
    }
}

public enum Deflate {
    #if os(Linux)
    public static func compress(_ input: Data, level: Int32 = 6) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw NSData.CompressionError.failed
        }
        defer { deflateEnd(&stream) }
        var out = Data(count: Int(deflateBound(&stream, uLong(input.count))) + 64)
        let produced: Int = try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            try out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(dst.count)
                guard deflate(&stream, Z_FINISH) == Z_STREAM_END else { throw NSData.CompressionError.failed }
                return Int(stream.total_out)
            }
        }
        return out.prefix(produced)
    }

    public static func decompress(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw NSData.CompressionError.failed }
        defer { inflateEnd(&stream) }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(src.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(buf.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let n = chunk.count - Int(stream.avail_out)
                out.append(contentsOf: chunk[0..<n])
                if status == Z_STREAM_END { break }
                guard status == Z_OK, n > 0 || stream.avail_in > 0 else { throw NSData.CompressionError.failed }
            }
        }
        return out
    }
    #else
    /// Without zlib: stored (uncompressed) DEFLATE blocks, which every
    /// inflater reads.
    public static func compress(_ input: Data, level: Int32 = 6) throws -> Data {
        var out = Data()
        var i = 0
        repeat {
            let n = min(65535, input.count - i)
            let final: UInt8 = i + n >= input.count ? 1 : 0
            out.append(final)
            out.append(UInt8(n & 0xff)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xff)); out.append(UInt8((~n >> 8) & 0xff))
            out.append(input.subdata(in: input.startIndex + i..<input.startIndex + i + n))
            i += n
        } while i < input.count
        return out
    }

    public static func decompress(_ input: Data) throws -> Data {
        var inflater = Inflater(Array(input))
        return try inflater.run()
    }
    #endif
}

/// A small RFC 1951 inflater (for platforms without zlib).
struct Inflater {
    let input: [UInt8]
    var pos = 0, bit = 0
    var out: [UInt8] = []
    init(_ input: [UInt8]) { self.input = input }

    mutating func bits(_ n: Int) throws -> Int {
        var v = 0
        for i in 0..<n {
            guard pos < input.count else { throw NSData.CompressionError.failed }
            v |= Int((input[pos] >> bit) & 1) << i
            bit += 1
            if bit == 8 { bit = 0; pos += 1 }
        }
        return v
    }

    struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int] = []
        init(_ lengths: [Int]) {
            for l in lengths { counts[l] += 1 }
            counts[0] = 0
            var offs = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offs[i] = offs[i - 1] + counts[i - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (s, l) in lengths.enumerated() where l != 0 { symbols[offs[l]] = s; offs[l] += 1 }
        }
    }

    mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1..<16 {
            code |= try bits(1)
            let count = h.counts[len]
            if code - count < first { return h.symbols[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw NSData.CompressionError.failed
    }

    static let lbase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lext = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let dbase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let dext = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    mutating func codes(_ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try decode(lit)
            if sym < 256 { out.append(UInt8(sym)); continue }
            if sym == 256 { return }
            let li = sym - 257
            guard li < 29 else { throw NSData.CompressionError.failed }
            let len = Self.lbase[li] + (try bits(Self.lext[li]))
            let di = try decode(dist)
            guard di < 30 else { throw NSData.CompressionError.failed }
            let d = Self.dbase[di] + (try bits(Self.dext[di]))
            guard d <= out.count else { throw NSData.CompressionError.failed }
            for _ in 0..<len { out.append(out[out.count - d]) }
        }
    }

    mutating func run() throws -> Data {
        var final = 0
        repeat {
            final = try bits(1)
            switch try bits(2) {
            case 0:
                if bit != 0 { bit = 0; pos += 1 }
                guard pos + 4 <= input.count else { throw NSData.CompressionError.failed }
                let n = Int(input[pos]) | Int(input[pos + 1]) << 8
                pos += 4
                guard pos + n <= input.count else { throw NSData.CompressionError.failed }
                out += input[pos..<pos + n]
                pos += n
            case 1:
                var l = [Int](repeating: 8, count: 288)
                for i in 144..<256 { l[i] = 9 }
                for i in 256..<280 { l[i] = 7 }
                try codes(Huffman(l), Huffman([Int](repeating: 5, count: 30)))
            case 2:
                let hlit = try bits(5) + 257, hdist = try bits(5) + 1, hclen = try bits(4) + 4
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var cl = [Int](repeating: 0, count: 19)
                for i in 0..<hclen { cl[order[i]] = try bits(3) }
                let ch = Huffman(cl)
                var lens: [Int] = []
                while lens.count < hlit + hdist {
                    let sym = try decode(ch)
                    switch sym {
                    case 0..<16: lens.append(sym)
                    case 16:
                        guard let prev = lens.last else { throw NSData.CompressionError.failed }
                        lens += Array(repeating: prev, count: 3 + (try bits(2)))
                    case 17: lens += Array(repeating: 0, count: 3 + (try bits(3)))
                    default: lens += Array(repeating: 0, count: 11 + (try bits(7)))
                    }
                }
                try codes(Huffman(Array(lens[0..<hlit])), Huffman(Array(lens[hlit..<hlit + hdist])))
            default:
                throw NSData.CompressionError.failed
            }
        } while final == 0
        return Data(out)
    }
}

// MARK: Trash

extension FileManager {
    /// Moves an item to the trash: the freedesktop Trash on Linux
    /// ($XDG_DATA_HOME/Trash, with its .trashinfo).
    public func trashItem(at url: URL, resultingItemURL outResultingURL: UnsafeMutablePointer<NSURL?>?) throws {
        let env = ProcessInfo.processInfo.environment
        let dataHome = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        let trash = dataHome.appendingPathComponent("Trash")
        let files = trash.appendingPathComponent("files"), info = trash.appendingPathComponent("info")
        try createDirectory(at: files, withIntermediateDirectories: true)
        try createDirectory(at: info, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var name = url.lastPathComponent
        var n = 1
        while fileExists(atPath: files.appendingPathComponent(name).path) || fileExists(atPath: info.appendingPathComponent(name + ".trashinfo").path) {
            n += 1
            name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let path = url.standardizedFileURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let entry = "[Trash Info]\nPath=\(path)\nDeletionDate=\(f.string(from: Date()))\n"
        try entry.write(to: info.appendingPathComponent(name + ".trashinfo"), atomically: true, encoding: .utf8)
        let dest = files.appendingPathComponent(name)
        try moveItem(at: url, to: dest)
        outResultingURL?.pointee = dest as NSURL
    }
}
