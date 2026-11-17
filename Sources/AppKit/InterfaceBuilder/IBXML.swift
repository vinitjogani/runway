// Interface Builder documents (.xib, .storyboard) are XML. This is a small,
// dependency-free reader for them: elements, attributes, character data,
// comments, CDATA and the predefined/numeric entities. Xcode writes no DTDs,
// namespaces or processing instructions beyond the XML declaration.

import Foundation

/// One element of an Interface Builder document.
public final class IBElement: CustomStringConvertible {
    public let name: String
    public internal(set) var attributes: [String: String]
    public internal(set) var children: [IBElement] = []
    public internal(set) var text = ""
    public internal(set) weak var parent: IBElement?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// Attributes and children the loader read (for reports of what
    /// isn't supported).
    var used: Set<String> = []
    var consumed = false

    public subscript(_ attribute: String) -> String? { used.insert(attribute); return attributes[attribute] }

    public var id: String? { attributes["id"] }
    /// The `key` attribute: which property of the parent this element sets.
    public var key: String? { attributes["key"] }

    public func child(_ name: String) -> IBElement? { mark(children.first { $0.name == name }) }
    public func children(_ name: String) -> [IBElement] { children.filter { $0.name == name }.map { $0.consumed = true; return $0 } }
    /// The child with `key="..."`, optionally of a given element name.
    public func child(key: String, _ name: String? = nil) -> IBElement? {
        mark(children.first { $0.attributes["key"] == key && (name == nil || $0.name == name) })
    }
    private func mark(_ e: IBElement?) -> IBElement? { e?.consumed = true; return e }

    /// Marks this element and everything under it as handled (Xcode state
    /// with no runtime effect here).
    func ignoreSubtree() {
        consumed = true
        used.formUnion(attributes.keys)
        for c in children { c.ignoreSubtree() }
    }

    public func bool(_ attribute: String) -> Bool? {
        guard let v = self[attribute] else { return nil }
        return v == "YES" || v == "true" || v == "1"
    }
    public func double(_ attribute: String) -> Double? { self[attribute].flatMap(Double.init) }
    public func int(_ attribute: String) -> Int? {
        guard let v = self[attribute] else { return nil }
        return Int(v) ?? Double(v).map { Int($0) }
    }

    /// Every element below this one, depth first, in document order.
    public func descendants() -> [IBElement] {
        var out: [IBElement] = []
        func walk(_ e: IBElement) { for c in e.children { out.append(c); walk(c) } }
        walk(self)
        return out
    }

    public var description: String {
        "<\(name)" + attributes.sorted { $0.key < $1.key }.map { " \($0.key)=\"\($0.value)\"" }.joined() + ">"
    }
}

public struct IBXMLError: Error, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "XML error at byte \(offset): \(message)" }
}

/// Parses an XML document into its root element.
public enum IBXMLParser {
    public static func parse(_ data: Data) throws -> IBElement {
        try data.withUnsafeBytes { raw in
            var p = Reader(bytes: raw.bindMemory(to: UInt8.self))
            return try p.document()
        }
    }

    public static func parse(_ string: String) throws -> IBElement { try parse(Data(string.utf8)) }

    private struct Reader {
        let bytes: UnsafeBufferPointer<UInt8>
        var i = 0
        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
            // Skip a UTF-8 byte order mark.
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { i = 3 }
        }

        func error(_ m: String) -> IBXMLError { IBXMLError(message: m, offset: i) }
        var atEnd: Bool { i >= bytes.count }
        func peek(_ s: String) -> Bool {
            var j = i
            for b in s.utf8 { if j >= bytes.count || bytes[j] != b { return false }; j += 1 }
            return true
        }
        mutating func skip(until s: String) throws {
            while !atEnd, !peek(s) { i += 1 }
            if atEnd { throw error("unterminated \(s)") }
            i += s.utf8.count
        }
        mutating func skipSpace() { while !atEnd, isSpace(bytes[i]) { i += 1 } }
        func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
        func isNameByte(_ b: UInt8) -> Bool {
            !(isSpace(b) || b == UInt8(ascii: "=") || b == UInt8(ascii: ">") || b == UInt8(ascii: "/") || b == UInt8(ascii: "<")
              || b == UInt8(ascii: "\"") || b == UInt8(ascii: "'"))
        }
        mutating func name() throws -> String {
            let start = i
            while !atEnd, isNameByte(bytes[i]) { i += 1 }
            if start == i { throw error("expected a name") }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
        }

        /// Skips the prolog (declaration, comments, doctype) and reads the root.
        mutating func document() throws -> IBElement {
            while true {
                skipSpace()
                if atEnd { throw error("no root element") }
                if peek("<?") { try skip(until: "?>") }
                else if peek("<!--") { try skip(until: "-->") }
                else if peek("<!") { try skip(until: ">") }
                else if peek("<") { return try element(parent: nil) }
                else { throw error("unexpected text before the root element") }
            }
        }

        mutating func element(parent: IBElement?) throws -> IBElement {
            // Iterative over depth so very deep documents don't overflow the stack.
            var stack: [IBElement] = []
            repeat {
                if peek("</") {
                    i += 2
                    let n = try name()
                    skipSpace()
                    guard !atEnd, bytes[i] == UInt8(ascii: ">") else { throw error("expected > closing </\(n)") }
                    i += 1
                    guard let top = stack.popLast(), top.name == n else { throw error("mismatched </\(n)>") }
                    if stack.isEmpty { return top }
                } else if peek("<!--") {
                    try skip(until: "-->")
                } else if peek("<![CDATA[") {
                    i += 9
                    let start = i
                    try skip(until: "]]>")
                    stack.last?.text += String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<(i - 3)]), as: UTF8.self)
                } else if peek("<?") {
                    try skip(until: "?>")
                } else if peek("<") {
                    i += 1
                    let n = try name()
                    var attrs: [String: String] = [:]
                    var selfClosing = false
                    while true {
                        skipSpace()
                        if atEnd { throw error("unterminated <\(n)") }
                        if bytes[i] == UInt8(ascii: "/") {
                            i += 1
                            guard !atEnd, bytes[i] == UInt8(ascii: ">") else { throw error("expected />") }
                            i += 1; selfClosing = true; break
                        }
                        if bytes[i] == UInt8(ascii: ">") { i += 1; break }
                        let a = try name()
                        skipSpace()
                        guard !atEnd, bytes[i] == UInt8(ascii: "=") else { throw error("expected = after \(a)") }
                        i += 1
                        skipSpace()
                        guard !atEnd, bytes[i] == UInt8(ascii: "\"") || bytes[i] == UInt8(ascii: "'") else { throw error("expected a quoted value") }
                        let q = bytes[i]
                        i += 1
                        let start = i
                        while !atEnd, bytes[i] != q { i += 1 }
                        if atEnd { throw error("unterminated attribute value") }
                        attrs[a] = decodeEntities(UnsafeBufferPointer(rebasing: bytes[start..<i]))
                        i += 1
                    }
                    let e = IBElement(name: n, attributes: attrs)
                    if let p = stack.last { e.parent = p; p.children.append(e) } else { e.parent = parent }
                    if selfClosing {
                        if stack.isEmpty { return e }
                    } else {
                        stack.append(e)
                    }
                } else {
                    let start = i
                    while !atEnd, bytes[i] != UInt8(ascii: "<") { i += 1 }
                    if let top = stack.last {
                        top.text += decodeEntities(UnsafeBufferPointer(rebasing: bytes[start..<i]))
                    }
                }
            } while !atEnd
            throw error("unexpected end of document")
        }

        func decodeEntities(_ b: UnsafeBufferPointer<UInt8>) -> String {
            guard b.contains(UInt8(ascii: "&")) else { return String(decoding: b, as: UTF8.self) }
            var out: [UInt8] = []
            out.reserveCapacity(b.count)
            var j = 0
            while j < b.count {
                let c = b[j]
                if c == UInt8(ascii: "&"), let semi = b[j...].firstIndex(of: UInt8(ascii: ";")), semi - j <= 10 {
                    let ent = String(decoding: UnsafeBufferPointer(rebasing: b[(j + 1)..<semi]), as: UTF8.self)
                    var scalar: UnicodeScalar?
                    switch ent {
                    case "lt": scalar = "<"
                    case "gt": scalar = ">"
                    case "amp": scalar = "&"
                    case "quot": scalar = "\""
                    case "apos": scalar = "'"
                    default:
                        if ent.hasPrefix("#x") || ent.hasPrefix("#X") { scalar = UInt32(ent.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init) }
                        else if ent.hasPrefix("#") { scalar = UInt32(ent.dropFirst()).flatMap(UnicodeScalar.init) }
                    }
                    if let s = scalar {
                        out += Array(String(Character(s)).utf8)
                        j = semi + 1
                        continue
                    }
                }
                out.append(c)
                j += 1
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}
