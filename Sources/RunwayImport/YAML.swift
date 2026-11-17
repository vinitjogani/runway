// The YAML subset XcodeGen specs are written in: block mappings and
// sequences by indentation, plain and quoted scalars, flow `[a, b]` and
// `{k: v}` collections, `#` comments, `|`/`>` block scalars. Values come
// back as String, [Any] and [String: Any] (mapping order isn't kept).

import Foundation

public enum YAML {
    public static func parse(_ text: String) throws -> Any {
        var lines: [(indent: Int, text: String)] = []
        let raw = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < raw.count {
            let line = raw[i]
            i += 1
            if line.trimmingCharacters(in: .whitespaces) == "---" || line.hasPrefix("%") { continue }
            let stripped = stripComment(line)
            if stripped.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indent = stripped.prefix { $0 == " " }.count
            var content = String(stripped.dropFirst(indent))
            // Block scalars: gather the more-indented lines verbatim.
            if content.hasSuffix(": |") || content.hasSuffix(": >") || content.hasSuffix(": |-") || content.hasSuffix(": >-") {
                let folded = content.contains(": >")
                content = String(content[..<content.range(of: ": ", options: .backwards)!.lowerBound]) + ": "
                var block: [String] = []
                var blockIndent: Int?
                while i < raw.count {
                    let l = raw[i]
                    let ind = l.prefix { $0 == " " }.count
                    if !l.trimmingCharacters(in: .whitespaces).isEmpty && ind <= indent { break }
                    if blockIndent == nil, !l.trimmingCharacters(in: .whitespaces).isEmpty { blockIndent = ind }
                    block.append(String(l.dropFirst(min(ind, blockIndent ?? ind))))
                    i += 1
                }
                content += quote(block.joined(separator: folded ? " " : "\n"))
            }
            lines.append((indent, content))
        }
        var p = 0
        guard !lines.isEmpty else { return [String: Any]() }
        return try block(&lines, &p, indent: lines[0].indent)
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func stripComment(_ line: String) -> String {
        var inS = false, inD = false
        var prev: Character = " "
        for (n, c) in line.enumerated() {
            if c == "'" && !inD { inS.toggle() } else if c == "\"" && !inS && prev != "\\" { inD.toggle() }
            if c == "#" && !inS && !inD && (prev == " " || prev == "\t" || n == 0) { return String(line.prefix(n)) }
            prev = c
        }
        return line
    }

    static func block(_ lines: inout [(indent: Int, text: String)], _ p: inout Int, indent: Int) throws -> Any {
        guard p < lines.count else { return "" }
        if lines[p].text == "-" || lines[p].text.hasPrefix("- ") {
            var seq: [Any] = []
            while p < lines.count, lines[p].indent == indent, lines[p].text == "-" || lines[p].text.hasPrefix("- ") {
                let rest = lines[p].text == "-" ? "" : String(lines[p].text.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    p += 1
                    seq.append(p < lines.count && lines[p].indent > indent ? try block(&lines, &p, indent: lines[p].indent) : "")
                } else if mappingKey(rest) != nil && !rest.hasPrefix("{") && !rest.hasPrefix("[") && !rest.hasPrefix("\"") && !rest.hasPrefix("'") {
                    // "- key: value" starts a mapping indented past the dash.
                    lines[p] = (indent + 2, rest)
                    seq.append(try block(&lines, &p, indent: indent + 2))
                } else {
                    p += 1
                    seq.append(scalarOrFlow(rest))
                }
            }
            return seq
        }
        var map: [String: Any] = [:]
        while p < lines.count, lines[p].indent == indent, !(lines[p].text == "-" || lines[p].text.hasPrefix("- ")) {
            guard let (key, rest) = mappingKey(lines[p].text) else {
                throw ImportError("YAML: expected 'key: value' in “\(lines[p].text)”")
            }
            p += 1
            if rest.isEmpty {
                if p < lines.count, lines[p].indent > indent || (lines[p].indent == indent && lines[p].text.hasPrefix("-")) {
                    map[key] = try block(&lines, &p, indent: lines[p].indent)
                } else {
                    map[key] = ""
                }
            } else {
                map[key] = scalarOrFlow(rest)
            }
        }
        return map
    }

    /// `key: rest` (the key may be quoted); nil when the line isn't a mapping entry.
    static func mappingKey(_ s: String) -> (String, String)? {
        if s.hasPrefix("\"") || s.hasPrefix("'") {
            let q = s.first!
            guard let end = s.dropFirst().firstIndex(of: q) else { return nil }
            let after = s[s.index(after: end)...]
            guard after.hasPrefix(":") else { return nil }
            return (String(s[s.index(after: s.startIndex)..<end]), after.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        var depth = 0
        let chars = Array(s)
        for (i, c) in chars.enumerated() {
            if c == "[" || c == "{" { depth += 1 } else if c == "]" || c == "}" { depth -= 1 }
            if c == ":", depth == 0, i + 1 == chars.count || chars[i + 1] == " " {
                return (String(chars[..<i]).trimmingCharacters(in: .whitespaces), String(chars[(i + 1)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func scalarOrFlow(_ s: String) -> Any {
        var chars = Array(s)
        var i = 0
        return flow(&chars, &i, top: true)
    }

    static func flow(_ c: inout [Character], _ i: inout Int, top: Bool) -> Any {
        while i < c.count, c[i] == " " { i += 1 }
        guard i < c.count else { return "" }
        if c[i] == "[" {
            i += 1
            var out: [Any] = []
            while i < c.count {
                while i < c.count, c[i] == " " || c[i] == "," { i += 1 }
                if i < c.count, c[i] == "]" { i += 1; break }
                out.append(flow(&c, &i, top: false))
            }
            return out
        }
        if c[i] == "{" {
            i += 1
            var out: [String: Any] = [:]
            while i < c.count {
                while i < c.count, c[i] == " " || c[i] == "," { i += 1 }
                if i < c.count, c[i] == "}" { i += 1; break }
                let k = flowScalar(&c, &i, stops: [":", ",", "}"])
                if i < c.count, c[i] == ":" { i += 1; out[k] = flow(&c, &i, top: false) } else { out[k] = "" }
            }
            return out
        }
        return top ? unquote(String(c[i...]).trimmingCharacters(in: .whitespaces)) : flowScalar(&c, &i, stops: [",", "]", "}"])
    }

    static func flowScalar(_ c: inout [Character], _ i: inout Int, stops: Set<Character>) -> String {
        while i < c.count, c[i] == " " { i += 1 }
        if i < c.count, c[i] == "\"" || c[i] == "'" {
            let q = c[i]
            let start = i
            i += 1
            while i < c.count, c[i] != q { if c[i] == "\\" && q == "\"" { i += 1 }; i += 1 }
            i = min(i + 1, c.count)
            return unquote(String(c[start..<i]))
        }
        let start = i
        while i < c.count, !stops.contains(c[i]) { i += 1 }
        return String(c[start..<i]).trimmingCharacters(in: .whitespaces)
    }

    static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") { return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'") }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            var out = "", esc = false
            for ch in s.dropFirst().dropLast() {
                if esc {
                    switch ch { case "n": out.append("\n"); case "t": out.append("\t"); default: out.append(ch) }
                    esc = false
                } else if ch == "\\" { esc = true } else { out.append(ch) }
            }
            return out
        }
        return s
    }
}
