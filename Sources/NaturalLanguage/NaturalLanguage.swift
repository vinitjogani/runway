// NaturalLanguage for Linux and Windows: tokenizers and language detection
// in Swift, and word embeddings from fastText/GloVe `.vec` files when the
// app or user provides them (RUNWAY_WORD_VECTORS=/dir with en.vec, fr.vec…;
// or ~/.local/share/runway/vectors). Without vectors, wordEmbedding(for:)
// returns nil, as macOS does for a language it has none for, and apps fall
// back the way they already do there.

import Foundation

public struct NLLanguage: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static let english = NLLanguage("en"), french = NLLanguage("fr"), german = NLLanguage("de"), italian = NLLanguage("it")
    public static let spanish = NLLanguage("es"), portuguese = NLLanguage("pt"), dutch = NLLanguage("nl"), swedish = NLLanguage("sv")
    public static let danish = NLLanguage("da"), norwegian = NLLanguage("nb"), finnish = NLLanguage("fi"), polish = NLLanguage("pl")
    public static let russian = NLLanguage("ru"), turkish = NLLanguage("tr"), japanese = NLLanguage("ja"), simplifiedChinese = NLLanguage("zh-Hans")
    public static let traditionalChinese = NLLanguage("zh-Hant"), korean = NLLanguage("ko"), arabic = NLLanguage("ar"), hebrew = NLLanguage("he")
    public static let greek = NLLanguage("el"), hindi = NLLanguage("hi"), thai = NLLanguage("th"), ukrainian = NLLanguage("uk")
    public static let czech = NLLanguage("cs"), undetermined = NLLanguage("und")
}

/// Detects languages from function-word frequencies and scripts.
public final class NLLanguageRecognizer: @unchecked Sendable {
    public var languageConstraints: [NLLanguage] = []
    public var languageHints: [NLLanguage: Double] = [:]
    private var scores: [NLLanguage: Double] = [:]
    public init() {}

    static let words: [NLLanguage: Set<String>] = [
        .english: ["the", "and", "of", "to", "is", "in", "that", "it", "with", "for", "this", "was", "are", "you", "not", "be", "on", "have", "what", "which"],
        .french: ["le", "la", "les", "et", "des", "est", "une", "un", "du", "que", "dans", "pour", "pas", "qui", "sur", "au", "avec", "ce", "il", "je"],
        .german: ["der", "die", "das", "und", "ist", "nicht", "ein", "eine", "zu", "den", "mit", "von", "sich", "auf", "für", "ich", "es", "dem", "im", "auch"],
        .italian: ["il", "di", "che", "la", "e", "un", "per", "non", "una", "sono", "del", "della", "con", "gli", "le", "è", "si", "da", "nel", "come"],
        .spanish: ["el", "la", "de", "que", "y", "en", "los", "las", "un", "por", "con", "una", "para", "es", "no", "del", "se", "al", "lo", "como"],
        .portuguese: ["o", "a", "de", "que", "e", "do", "da", "em", "um", "para", "com", "não", "uma", "os", "no", "se", "na", "por", "mais", "as"],
        .dutch: ["de", "het", "een", "en", "van", "is", "dat", "op", "te", "in", "zijn", "met", "voor", "niet", "aan", "er", "ook", "maar", "als", "bij"],
    ]

    public func processString(_ string: String) {
        let tokens = string.lowercased().split { !$0.isLetter }.map(String.init)
        var s: [NLLanguage: Double] = [:]
        for (lang, set) in Self.words { s[lang] = Double(tokens.filter { set.contains($0) }.count) }
        // Scripts decide outright.
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30ff: s[.japanese, default: 0] += 3
            case 0x4e00...0x9fff: s[.simplifiedChinese, default: 0] += 2
            case 0xac00...0xd7af: s[.korean, default: 0] += 3
            case 0x0400...0x04ff: s[.russian, default: 0] += 1
            case 0x0600...0x06ff: s[.arabic, default: 0] += 1
            case 0x0590...0x05ff: s[.hebrew, default: 0] += 1
            case 0x0370...0x03ff: s[.greek, default: 0] += 1
            case 0x0900...0x097f: s[.hindi, default: 0] += 1
            case 0x0e00...0x0e7f: s[.thai, default: 0] += 1
            default: break
            }
        }
        for (l, h) in languageHints { s[l, default: 0] += h }
        if !languageConstraints.isEmpty { s = s.filter { languageConstraints.contains($0.key) } }
        scores = s
    }

    public var dominantLanguage: NLLanguage? {
        guard let best = scores.max(by: { $0.value < $1.value }), best.value > 0 else {
            return languageConstraints.isEmpty || languageConstraints.contains(.english) ? .english : languageConstraints.first
        }
        return best.key
    }

    public func languageHypotheses(withMaximum n: Int) -> [NLLanguage: Double] {
        let total = max(1, scores.values.reduce(0, +))
        return Dictionary(uniqueKeysWithValues: scores.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value / total) })
    }

    public func reset() { scores = [:] }

    public static func dominantLanguage(for string: String) -> NLLanguage? {
        let r = NLLanguageRecognizer()
        r.processString(string)
        return r.dominantLanguage
    }
}

public enum NLTokenUnit: Int, Sendable { case word, sentence, paragraph, document }

public final class NLTokenizer: @unchecked Sendable {
    public let unit: NLTokenUnit
    public var string: String?
    public init(unit: NLTokenUnit) { self.unit = unit }
    public func setLanguage(_ language: NLLanguage) {}

    public func tokens(for range: Range<String.Index>) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        enumerateTokens(in: range) { r, _ in out.append(r); return true }
        return out
    }

    public struct Attributes: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let numeric = Attributes(rawValue: 1), symbolic = Attributes(rawValue: 2), emoji = Attributes(rawValue: 4)
    }

    public func enumerateTokens(in range: Range<String.Index>, using block: (Range<String.Index>, Attributes) -> Bool) {
        guard let s = string else { return }
        if unit == .document { _ = block(range, []); return }
        for (r, attrs) in Self.segments(s, range, unit) where !block(r, attrs) { return }
    }

    /// Words (letters, digits, inner apostrophes), sentences (ending in
    /// . ! ? or a line break) and paragraphs (separated by line breaks).
    static func segments(_ s: String, _ range: Range<String.Index>, _ unit: NLTokenUnit) -> [(Range<String.Index>, Attributes)] {
        var out: [(Range<String.Index>, Attributes)] = []
        var i = range.lowerBound
        switch unit {
        case .word:
            while i < range.upperBound {
                let c = s[i]
                if c.isLetter || c.isNumber {
                    var j = s.index(after: i)
                    while j < range.upperBound {
                        let d = s[j]
                        if d.isLetter || d.isNumber { j = s.index(after: j); continue }
                        if d == "'" || d == "’", s.index(after: j) < range.upperBound, s[s.index(after: j)].isLetter { j = s.index(after: j); continue }
                        break
                    }
                    let numeric = s[i..<j].allSatisfy(\.isNumber)
                    out.append((i..<j, numeric ? .numeric : []))
                    i = j
                } else {
                    if c.unicodeScalars.first?.properties.isEmojiPresentation == true { out.append((i..<s.index(after: i), .emoji)) }
                    i = s.index(after: i)
                }
            }
        case .sentence, .paragraph, .document:
            var start = i
            while i < range.upperBound {
                let c = s[i]
                let next = s.index(after: i)
                let ends = c.isNewline || (unit == .sentence && ".!?".contains(c) && (next == range.upperBound || s[next].isWhitespace))
                if ends {
                    let end = c.isNewline ? i : next
                    if s[start..<end].contains(where: { !$0.isWhitespace }) { out.append((start..<end, [])) }
                    start = next
                }
                i = next
            }
            if start < range.upperBound, s[start..<range.upperBound].contains(where: { !$0.isWhitespace }) { out.append((start..<range.upperBound, [])) }
        }
        return out
    }

    public func tokenRange(at index: String.Index) -> Range<String.Index> {
        guard let s = string else { return index..<index }
        return tokens(for: s.startIndex..<s.endIndex).first { $0.contains(index) } ?? index..<index
    }
}

public enum NLDistanceType: Int, Sendable { case cosine }
public typealias NLDistance = Double

/// Word vectors, loaded from a `.vec` text file (`word v1 v2 …` per line).
public final class NLEmbedding: @unchecked Sendable {
    public let dimension: Int
    public let revision: Int
    public let language: NLLanguage?
    public var vocabularySize: Int { vectors.count }
    private let vectors: [String: [Float]]

    init(language: NLLanguage, vectors: [String: [Float]], dimension: Int) {
        self.language = language; self.vectors = vectors; self.dimension = dimension; revision = 1
    }

    nonisolated(unsafe) private static var loaded: [NLLanguage: NLEmbedding?] = [:]
    private static let lock = NSLock()

    static var directories: [URL] {
        var out: [URL] = []
        if let d = ProcessInfo.processInfo.environment["RUNWAY_WORD_VECTORS"] { out.append(URL(fileURLWithPath: d)) }
        out.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/runway/vectors"))
        return out
    }

    public static func wordEmbedding(for language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let e = loaded[language] { return e }
        var result: NLEmbedding?
        for dir in directories {
            let file = dir.appendingPathComponent("\(language.rawValue).vec")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var vectors: [String: [Float]] = [:]
            var dim = 0
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count == 2, vectors.isEmpty { continue }   // fastText header
                guard parts.count > 2 else { continue }
                let v = parts.dropFirst().compactMap { Float($0) }
                if dim == 0 { dim = v.count }
                if v.count == dim { vectors[String(parts[0])] = v }
            }
            if dim > 0 { result = NLEmbedding(language: language, vectors: vectors, dimension: dim); break }
        }
        loaded[language] = result
        return result
    }

    public static func wordEmbedding(for language: NLLanguage, revision: Int) -> NLEmbedding? { wordEmbedding(for: language) }
    public static func sentenceEmbedding(for language: NLLanguage) -> NLEmbedding? { nil }
    public static func currentRevision(for language: NLLanguage) -> Int { 1 }

    public func vector(for word: String) -> [Double]? { vectors[word].map { $0.map(Double.init) } }
    public func contains(_ word: String) -> Bool { vectors[word] != nil }

    public func distance(between a: String, and b: String, distanceType: NLDistanceType = .cosine) -> NLDistance {
        guard let x = vectors[a], let y = vectors[b] else { return 2 }
        var dot: Float = 0, nx: Float = 0, ny: Float = 0
        for i in 0..<min(x.count, y.count) { dot += x[i] * y[i]; nx += x[i] * x[i]; ny += y[i] * y[i] }
        return Double(1 - dot / max(1e-9, nx.squareRoot() * ny.squareRoot()))
    }

    public func neighbors(for word: String, maximumCount: Int, distanceType: NLDistanceType = .cosine) -> [(String, NLDistance)] {
        vectors.keys.filter { $0 != word }.map { ($0, distance(between: word, and: $0)) }.sorted { $0.1 < $1.1 }.prefix(maximumCount).map { $0 }
    }
}
