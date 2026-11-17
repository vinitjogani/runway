// The old-style (OpenStep/NeXTSTEP) property list format project.pbxproj is
// written in: `{ key = value; }` dictionaries, `( a, b, )` arrays, quoted and
// bare strings, `<hex>` data, `//` and `/* */` comments. Parsed by hand
// (Foundation's parser differs between platforms and reports no positions).

import Foundation

public indirect enum PlistValue: Equatable, CustomStringConvertible, Sendable {
    case string(String)
    case array([PlistValue])
    case dict([String: PlistValue])
    case data(Data)

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var array: [PlistValue]? { if case .array(let a) = self { return a }; return nil }
    public var dict: [String: PlistValue]? { if case .dict(let d) = self { return d }; return nil }
    public subscript(key: String) -> PlistValue? { dict?[key] }
    /// Strings of an array (or a lone string as a one-element list).
    public var strings: [String] {
        switch self {
        case .string(let s): return [s]
        case .array(let a): return a.compactMap(\.string)
        default: return []
        }
    }

    /// Foundation property-list objects (String, [Any], [String: Any], Data).
    public var foundation: Any {
        switch self {
        case .string(let s): return s
        case .array(let a): return a.map(\.foundation)
        case .dict(let d): return d.mapValues(\.foundation)
        case .data(let d): return d
        }
    }

    public var description: String {
        switch self {
        case .string(let s): return lit(s)
        case .array(let a): return "(" + a.map(\.description).joined(separator: ", ") + ")"
        case .dict(let d): return "{" + d.keys.sorted().map { "\($0) = \(d[$0]!.description);" }.joined(separator: " ") + "}"
        case .data(let d): return "<" + d.map { String(format: "%02x", $0) }.joined() + ">"
        }
    }
}

public struct PlistParseError: Error, CustomStringConvertible {
    public var message: String
    public var line: Int
    public var description: String { "line \(line): \(message)" }
}

public enum OpenStepPlist {
    public static func parse(_ text: String) throws -> PlistValue {
        var p = Parser(Array(text.utf8))
        p.skipTrivia()
        let v = try p.value()
        p.skipTrivia()
        if p.i < p.b.count { throw p.error("unexpected content after the root value") }
        return v
    }

    public static func parse(contentsOf url: URL) throws -> PlistValue {
        try parse(String(decoding: try Data(contentsOf: url), as: UTF8.self))
    }

    struct Parser {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        func error(_ m: String) -> PlistParseError {
            PlistParseError(message: m, line: b[..<min(i, b.count)].reduce(1) { $0 + ($1 == 0x0A ? 1 : 0) })
        }

        mutating func skipTrivia() {
            while i < b.count {
                let c = b[i]
                if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C { i += 1; continue }
                if c == 0xEF, i + 2 < b.count, b[i + 1] == 0xBB, b[i + 2] == 0xBF { i += 3; continue }  // BOM
                if c == ch("/"), i + 1 < b.count {
                    if b[i + 1] == ch("/") {
                        while i < b.count, b[i] != 0x0A { i += 1 }
                        continue
                    }
                    if b[i + 1] == ch("*") {
                        i += 2
                        while i + 1 < b.count, !(b[i] == ch("*") && b[i + 1] == ch("/")) { i += 1 }
                        i = min(i + 2, b.count)
                        continue
                    }
                }
                break
            }
        }

        /// Characters of an unquoted string. Xcode writes paths, identifiers,
        /// numbers and `$(VAR)`-free settings bare.
        static func isBare(_ c: UInt8) -> Bool {
            switch c {
            case ch("a")...ch("z"), ch("A")...ch("Z"), ch("0")...ch("9"): return true
            case ch("_"), ch("$"), ch("+"), ch("/"), ch(":"), ch("."), ch("-"), ch("@"), ch("~"), ch("!"), ch("%"),
                 ch("&"), ch("*"), ch("?"), ch("["), ch("]"), ch("^"), ch("|"), ch("\\"):
                return true
            default: return c >= 0x80
            }
        }

        mutating func value() throws -> PlistValue {
            skipTrivia()
            guard i < b.count else { throw error("unexpected end of input") }
            switch b[i] {
            case ch("{"):
                i += 1
                var d: [String: PlistValue] = [:]
                while true {
                    skipTrivia()
                    guard i < b.count else { throw error("unterminated dictionary") }
                    if b[i] == ch("}") { i += 1; break }
                    guard case .string(let key) = try value() else { throw error("dictionary key must be a string") }
                    skipTrivia()
                    guard i < b.count, b[i] == ch("=") else { throw error("expected '=' after key \(key)") }
                    i += 1
                    d[key] = try value()
                    skipTrivia()
                    guard i < b.count else { throw error("unterminated dictionary") }
                    if b[i] == ch(";") { i += 1 } else if b[i] != ch("}") { throw error("expected ';' after the value of \(key)") }
                }
                return .dict(d)
            case ch("("):
                i += 1
                var a: [PlistValue] = []
                while true {
                    skipTrivia()
                    guard i < b.count else { throw error("unterminated array") }
                    if b[i] == ch(")") { i += 1; break }
                    a.append(try value())
                    skipTrivia()
                    guard i < b.count else { throw error("unterminated array") }
                    if b[i] == ch(",") { i += 1 } else if b[i] != ch(")") { throw error("expected ',' in array") }
                }
                return .array(a)
            case ch("\""), ch("'"):
                return .string(try quoted())
            case ch("<"):
                i += 1
                var bytes: [UInt8] = [], nibble: UInt8?
                while i < b.count, b[i] != ch(">") {
                    let c = b[i]
                    i += 1
                    guard let v = hexDigit(c) else { continue }
                    if let n = nibble { bytes.append(n << 4 | v); nibble = nil } else { nibble = v }
                }
                guard i < b.count else { throw error("unterminated data") }
                i += 1
                return .data(Data(bytes))
            default:
                let start = i
                while i < b.count, Parser.isBare(b[i]) { i += 1 }
                guard i > start else { throw error("unexpected character '\(Character(UnicodeScalar(b[i])))'") }
                return .string(String(decoding: b[start..<i], as: UTF8.self))
            }
        }

        mutating func quoted() throws -> String {
            let q = b[i]
            i += 1
            var out: [UInt8] = []
            while i < b.count, b[i] != q {
                guard b[i] == ch("\\"), i + 1 < b.count else {
                    out.append(b[i])
                    i += 1
                    continue
                }
                i += 1
                let c = b[i]
                i += 1
                switch c {
                case ch("n"): out.append(0x0A)
                case ch("t"): out.append(0x09)
                case ch("r"): out.append(0x0D)
                case ch("a"): out.append(0x07)
                case ch("b"): out.append(0x08)
                case ch("f"): out.append(0x0C)
                case ch("v"): out.append(0x0B)
                case ch("U"), ch("u"):
                    var v = readHex4()
                    // A UTF-16 surrogate pair: \UD83D\UDE00.
                    if (0xD800..<0xDC00).contains(v), i + 1 < b.count, b[i] == ch("\\"), b[i + 1] == ch("U") || b[i + 1] == ch("u") {
                        let save = i
                        i += 2
                        let lo = readHex4()
                        if (0xDC00..<0xE000).contains(lo) { v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00) } else { i = save }
                    }
                    out += Array(String(UnicodeScalar(v).map(Character.init) ?? "\u{FFFD}").utf8)
                case ch("0")...ch("7"):
                    var v = UInt32(c - ch("0")), n = 1
                    while n < 3, i < b.count, (ch("0")...ch("7")).contains(b[i]) { v = v * 8 + UInt32(b[i] - ch("0")); i += 1; n += 1 }
                    out.append(UInt8(truncatingIfNeeded: v))
                default: out.append(c)  // \" \\ \' and anything else: the character itself
                }
            }
            guard i < b.count else { throw error("unterminated string") }
            i += 1
            return String(decoding: out, as: UTF8.self)
        }

        mutating func readHex4() -> UInt32 {
            var v: UInt32 = 0, n = 0
            while n < 4, i < b.count, let d = hexDigit(b[i]) { v = v << 4 | UInt32(d); i += 1; n += 1 }
            return v
        }

        func hexDigit(_ c: UInt8) -> UInt8? {
            switch c {
            case ch("0")...ch("9"): return c - ch("0")
            case ch("a")...ch("f"): return c - ch("a") + 10
            case ch("A")...ch("F"): return c - ch("A") + 10
            default: return nil
            }
        }
    }
}

@inline(__always) private func ch(_ s: Unicode.Scalar) -> UInt8 { UInt8(ascii: s) }
