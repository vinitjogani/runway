// `AttributedString(markdown:)` and the presentation intents it sets, which
// Foundation provides only on Apple platforms.
//
// Inline Markdown as CommonMark reads it: emphasis (`*`/`_`), strong
// emphasis (`**`/`__`), code spans, strikethrough (`~~`), links
// (`[text](url "title")`), autolinks (`<https://…>`), backslash escapes and
// hard line breaks. With `.full` syntax, block markers (headings, list
// bullets, quotes) are dropped and paragraphs are separated by a blank
// line, as Foundation does when it flattens blocks into one string.

import Foundation

/// How a run of Markdown is presented inline.
public struct InlinePresentationIntent: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let emphasized = Self(rawValue: 1 << 0)
    public static let stronglyEmphasized = Self(rawValue: 1 << 1)
    public static let code = Self(rawValue: 1 << 2)
    public static let strikethrough = Self(rawValue: 1 << 5)
    public static let softBreak = Self(rawValue: 1 << 6)
    public static let lineBreak = Self(rawValue: 1 << 7)
    public static let inlineHTML = Self(rawValue: 1 << 8)
    public static let blockHTML = Self(rawValue: 1 << 9)
}

extension AttributeScopes {
    /// Foundation's Markdown attributes missing from this platform's Foundation.
    public struct RunwayMarkdownAttributes: AttributeScope {
        public let inlinePresentationIntent: InlinePresentationIntentAttribute
        public let foundation: AttributeScopes.FoundationAttributes

        public enum InlinePresentationIntentAttribute: CodableAttributedStringKey {
            public typealias Value = InlinePresentationIntent
            public static let name = "NSInlinePresentationIntent"
        }
    }
    public var runwayMarkdown: RunwayMarkdownAttributes.Type { RunwayMarkdownAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.RunwayMarkdownAttributes, T>) -> T {
        self[T.self]
    }
}

extension AttributedString {
    public struct MarkdownParsingOptions: Hashable, Sendable {
        public enum InterpretedSyntax: Hashable, Sendable { case full, inlineOnly, inlineOnlyPreservingWhitespace }
        public enum FailurePolicy: Hashable, Sendable { case throwError, returnPartiallyParsedIfPossible }
        public var allowsExtendedAttributes: Bool
        public var interpretedSyntax: InterpretedSyntax
        public var failurePolicy: FailurePolicy
        public var languageCode: String?
        public var appliesSourcePositionAttributes: Bool = false
        public init(allowsExtendedAttributes: Bool = false, interpretedSyntax: InterpretedSyntax = .full,
                    failurePolicy: FailurePolicy = .throwError, languageCode: String? = nil) {
            self.allowsExtendedAttributes = allowsExtendedAttributes
            self.interpretedSyntax = interpretedSyntax
            self.failurePolicy = failurePolicy
            self.languageCode = languageCode
        }
    }

    public init(markdown: String, options: MarkdownParsingOptions = MarkdownParsingOptions(), baseURL: URL? = nil) throws {
        self = MarkdownInline.parse(markdown, options: options, baseURL: baseURL)
    }

    public init(markdown: Data, options: MarkdownParsingOptions = MarkdownParsingOptions(), baseURL: URL? = nil) throws {
        try self.init(markdown: String(decoding: markdown, as: UTF8.self), options: options, baseURL: baseURL)
    }

    public init(markdown: String, including scope: Any.Type, options: MarkdownParsingOptions = MarkdownParsingOptions(), baseURL: URL? = nil) throws {
        try self.init(markdown: markdown, options: options, baseURL: baseURL)
    }
}

enum MarkdownInline {
    static func parse(_ source: String, options: AttributedString.MarkdownParsingOptions, baseURL: URL?) -> AttributedString {
        switch options.interpretedSyntax {
        case .inlineOnlyPreservingWhitespace:
            return inline(source, baseURL: baseURL)
        case .inlineOnly:
            return inline(collapse(source), baseURL: baseURL)
        case .full:
            var out = AttributedString()
            for (i, block) in blocks(source).enumerated() {
                if i > 0 { out += AttributedString("\n\n") }
                out += inline(block, baseURL: baseURL)
            }
            return out
        }
    }

    /// Runs of whitespace (newlines included) as one space.
    static func collapse(_ s: String) -> String {
        var out = ""
        var space = false
        for c in s {
            if c.isWhitespace { space = true; continue }
            if space, !out.isEmpty { out.append(" ") }
            space = false
            out.append(c)
        }
        return out
    }

    /// Paragraphs, with block markers removed and soft breaks as spaces.
    static func blocks(_ s: String) -> [String] {
        var paragraphs: [String] = []
        var current: [String] = []
        var fence = false
        func flush() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: fence ? "\n" : " ")) }
            current = []
        }
        for raw in s.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if fence { flush(); fence = false } else { flush(); fence = true }
                continue
            }
            if fence { current.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.first == "#" {
                flush()
                line = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                paragraphs.append(line)
                continue
            }
            if line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let f = line.first, "-*+".contains(f), line.dropFirst().first == " " {
                flush()
                line = String(line.dropFirst(2))
            } else if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot > line.startIndex,
                      line[line.startIndex..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].first == " " {
                flush()
            }
            current.append(line)
        }
        flush()
        return paragraphs
    }

    private struct Delim {
        let char: Character
        var count: Int
        let index: Int   // position in `pieces`
        let canOpen: Bool
        let canClose: Bool
    }

    private enum Piece {
        case text(String, InlinePresentationIntent, URL?)
        case delim(Character, Int)
    }

    /// Inline Markdown into an attributed string.
    static func inline(_ s: String, baseURL: URL?) -> AttributedString {
        let chars = Array(s)
        var pieces: [Piece] = []
        var text = ""
        func flushText() {
            if !text.isEmpty { pieces.append(.text(text, [], nil)); text = "" }
        }
        var delims: [Delim] = []
        var i = 0
        func isPunct(_ c: Character?) -> Bool { c.map { $0.isPunctuation || $0.isSymbol } ?? false }
        func isSpace(_ c: Character?) -> Bool { c.map { $0.isWhitespace } ?? true }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "\n" { flushText(); pieces.append(.text("\n", .lineBreak, nil)); i += 2; continue }
                if n.isPunctuation || n.isSymbol { text.append(n); i += 2; continue }
            }
            if c == "`" {
                var run = 0
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                // The matching closing run.
                var j = i + run
                var found: Int?
                while j < chars.count {
                    if chars[j] == "`" {
                        var r = 0
                        while j + r < chars.count, chars[j + r] == "`" { r += 1 }
                        if r == run { found = j; break }
                        j += r
                    } else { j += 1 }
                }
                if let end = found {
                    var code = String(chars[(i + run)..<end]).replacingOccurrences(of: "\n", with: " ")
                    if code.count > 2, code.first == " ", code.last == " ", code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    flushText()
                    pieces.append(.text(code, .code, nil))
                    i = end + run
                    continue
                }
                text.append(contentsOf: String(repeating: "`", count: run))
                i += run
                continue
            }
            if c == "<", let close = chars[(i + 1)...].firstIndex(of: ">") {
                let inner = String(chars[(i + 1)..<close])
                if inner.contains(":") || inner.contains("@"), !inner.contains(" "), let url = URL(string: inner.contains(":") ? inner : "mailto:" + inner) {
                    flushText()
                    pieces.append(.text(inner, [], url))
                    i = close + 1
                    continue
                }
            }
            if c == "[", let (label, url, end) = link(chars, from: i, baseURL: baseURL) {
                flushText()
                let inner = inline(label, baseURL: baseURL)
                for run in inner.runs {
                    let str = String(inner[run.range].characters)
                    pieces.append(.text(str, run[AttributeScopes.RunwayMarkdownAttributes.InlinePresentationIntentAttribute.self] ?? [], url))
                }
                i = end
                continue
            }
            if c == "*" || c == "_" || c == "~" {
                var run = 0
                while i + run < chars.count, chars[i + run] == c { run += 1 }
                if c == "~", run != 2 { text.append(contentsOf: String(repeating: "~", count: run)); i += run; continue }
                let before: Character? = i > 0 ? chars[i - 1] : nil
                let after: Character? = i + run < chars.count ? chars[i + run] : nil
                let leftFlanking = !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before))
                let rightFlanking = !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after))
                var canOpen = leftFlanking, canClose = rightFlanking
                if c == "_" {
                    canOpen = leftFlanking && (!rightFlanking || isPunct(before))
                    canClose = rightFlanking && (!leftFlanking || isPunct(after))
                }
                flushText()
                delims.append(Delim(char: c, count: run, index: pieces.count, canOpen: canOpen, canClose: canClose))
                pieces.append(.delim(c, run))
                i += run
                continue
            }
            if c == "\n" {
                // Two trailing spaces make a hard break; otherwise soft.
                if text.hasSuffix("  ") {
                    text = String(text.dropLast(2))
                    flushText()
                    pieces.append(.text("\n", .lineBreak, nil))
                } else {
                    text.append("\n")
                }
                i += 1
                continue
            }
            text.append(c)
            i += 1
        }
        flushText()

        // Match delimiters (CommonMark's process-emphasis, simplified).
        var intents = [InlinePresentationIntent](repeating: [], count: pieces.count)
        var remaining = pieces.map { p -> Int in if case let .delim(_, n) = p { return n }; return 0 }
        var openers: [Delim] = []
        for d in delims {
            var closer = d
            if closer.canClose {
                var k = openers.count - 1
                while k >= 0, remaining[closer.index] > 0 {
                    let o = openers[k]
                    guard o.char == closer.char, remaining[o.index] > 0 else { k -= 1; continue }
                    // The rule of three for runs that can both open and close.
                    if (o.canClose || closer.canOpen), (remaining[o.index] + remaining[closer.index]) % 3 == 0,
                       remaining[o.index] % 3 != 0 || remaining[closer.index] % 3 != 0, o.char != "~" { k -= 1; continue }
                    let use: Int
                    let intent: InlinePresentationIntent
                    if o.char == "~" { use = 2; intent = .strikethrough }
                    else if remaining[o.index] >= 2 && remaining[closer.index] >= 2 { use = 2; intent = .stronglyEmphasized }
                    else { use = 1; intent = .emphasized }
                    remaining[o.index] -= use
                    remaining[closer.index] -= use
                    for p in (o.index + 1)..<closer.index { intents[p].formUnion(intent) }
                    // Openers between are no longer usable.
                    openers.removeSubrange((k + 1)...)
                    if remaining[o.index] == 0 { openers.remove(at: k) }
                    k = openers.count - 1
                }
                closer = d
            }
            if remaining[d.index] > 0, d.canOpen { openers.append(d) }
        }

        var out = AttributedString()
        for (n, p) in pieces.enumerated() {
            switch p {
            case let .text(s, own, url):
                var a = AttributedString(s)
                let intent = own.union(intents[n])
                if !intent.isEmpty { a[AttributeScopes.RunwayMarkdownAttributes.InlinePresentationIntentAttribute.self] = intent }
                if let url { a.link = url }
                out += a
            case let .delim(c, _):
                if remaining[n] > 0 {
                    var a = AttributedString(String(repeating: c, count: remaining[n]))
                    if !intents[n].isEmpty { a[AttributeScopes.RunwayMarkdownAttributes.InlinePresentationIntentAttribute.self] = intents[n] }
                    out += a
                }
            }
        }
        return out
    }

    /// `[label](destination "title")` starting at `start`: the label, the
    /// URL and the index after the link.
    static func link(_ chars: [Character], from start: Int, baseURL: URL?) -> (String, URL, Int)? {
        var depth = 0
        var j = start
        var labelEnd: Int?
        while j < chars.count {
            let c = chars[j]
            if c == "\\" { j += 2; continue }
            if c == "[" { depth += 1 }
            if c == "]" { depth -= 1; if depth == 0 { labelEnd = j; break } }
            j += 1
        }
        guard let le = labelEnd, le + 1 < chars.count, chars[le + 1] == "(" else { return nil }
        var k = le + 2
        var parens = 0
        var dest = ""
        while k < chars.count, chars[k] == " " { k += 1 }
        if k < chars.count, chars[k] == "<" {
            k += 1
            while k < chars.count, chars[k] != ">" { dest.append(chars[k]); k += 1 }
            k += 1
        } else {
            while k < chars.count {
                let c = chars[k]
                if c == "(" { parens += 1 }
                if c == ")" { if parens == 0 { break }; parens -= 1 }
                if c == " " { break }
                dest.append(c)
                k += 1
            }
        }
        // An optional title, then ")".
        while k < chars.count, chars[k] == " " { k += 1 }
        if k < chars.count, chars[k] == "\"" || chars[k] == "'" {
            let q = chars[k]
            k += 1
            while k < chars.count, chars[k] != q { k += 1 }
            k += 1
            while k < chars.count, chars[k] == " " { k += 1 }
        }
        guard k < chars.count, chars[k] == ")" else { return nil }
        guard let url = URL(string: dest, relativeTo: baseURL) ?? URL(string: dest.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "") else { return nil }
        return (String(chars[(start + 1)..<le]), url.absoluteURL, k + 1)
    }
}
