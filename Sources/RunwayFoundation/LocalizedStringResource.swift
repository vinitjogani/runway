// LocalizedStringResource (Foundation on Apple platforms, missing from
// swift-corelibs-foundation): a key looked up in a strings table when it's
// resolved, with interpolation.

import Foundation

public struct LocalizedStringResource: Hashable, Sendable, ExpressibleByStringInterpolation, CustomStringConvertible, Codable {
    public var key: String
    public var defaultValue: String
    public var table: String?
    public var locale: Locale = .current
    public var bundleURL: URL?
    public var comment: String?
    /// Interpolated values, rendered, for the key's format specifiers.
    var arguments: [String] = []

    public init(_ keyAndValue: String, table: String? = nil, locale: Locale = .current, comment: String? = nil) {
        key = keyAndValue
        defaultValue = keyAndValue
        self.table = table
        self.locale = locale
        self.comment = comment
    }
    public init(_ key: StaticString, defaultValue: String, table: String? = nil, locale: Locale = .current, comment: StaticString? = nil) {
        self.key = "\(key)"
        self.defaultValue = defaultValue
        self.table = table
        self.locale = locale
        self.comment = comment.map { "\($0)" }
    }
    public init(stringLiteral value: String) { self.init(value) }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var value = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%"); value += literal }
        mutating func add(_ spec: String, _ rendered: String) { key += spec; value += rendered; arguments.append(rendered) }
        public mutating func appendInterpolation<T>(_ v: T) { add("%@", "\(v)") }
        public mutating func appendInterpolation(_ v: String) { add("%@", v) }
        public mutating func appendInterpolation<I: BinaryInteger>(_ v: I) { add("%lld", String(v)) }
        public mutating func appendInterpolation(_ v: Double) { add("%lf", String(v)) }
        public mutating func appendInterpolation(_ v: Float) { add("%f", String(v)) }
        public mutating func appendInterpolation(_ v: LocalizedStringResource) { add("%@", String(localized: v)) }
    }
    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        defaultValue = stringInterpolation.value
        arguments = stringInterpolation.arguments
    }

    /// The localized string: the key's translation with the interpolated
    /// values put in its format specifiers, or the default value.
    func resolved(bundle: Bundle? = nil) -> String {
        let b = bundle ?? bundleURL.flatMap(Bundle.init(url:)) ?? .main
        let missing = "\u{1}runway-missing\u{1}"
        let found = b.localizedString(forKey: key, value: missing, table: table)
        guard found != missing else { return defaultValue }
        return Self.substitute(found, arguments)
    }

    /// Replaces printf-style specifiers (%@, %lld, %d, %f, positional %1$@...)
    /// with already-rendered arguments.
    static func substitute(_ format: String, _ args: [String]) -> String {
        var out = ""
        var next = 0
        var i = format.startIndex
        while i < format.endIndex {
            let c = format[i]
            guard c == "%" else { out.append(c); i = format.index(after: i); continue }
            var j = format.index(after: i)
            guard j < format.endIndex else { out.append(c); break }
            if format[j] == "%" { out.append("%"); i = format.index(after: j); continue }
            var digits = ""
            var k = j
            while k < format.endIndex, format[k].isNumber { digits.append(format[k]); k = format.index(after: k) }
            var position: Int?
            if k < format.endIndex, format[k] == "$", let n = Int(digits) { position = n - 1; j = format.index(after: k) }
            while j < format.endIndex, "lhqLzjt.0123456789-+ #'".contains(format[j]) { j = format.index(after: j) }
            guard j < format.endIndex else { break }
            let index = position ?? next
            if position == nil { next += 1 }
            out += index < args.count ? args[index] : ""
            i = format.index(after: j)
        }
        return out
    }

    public var description: String { resolved() }

    public static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.defaultValue == b.defaultValue && a.table == b.table }
    public func hash(into h: inout Hasher) { h.combine(key); h.combine(table) }

    enum CodingKeys: String, CodingKey { case key, defaultValue, table }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? key
        table = try c.decodeIfPresent(String.self, forKey: .table)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(defaultValue, forKey: .defaultValue)
        try c.encodeIfPresent(table, forKey: .table)
    }
}

public protocol CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { get }
}

extension String {
    /// Apple's String.LocalizationValue: a key with interpolations.
    public typealias LocalizationValue = LocalizedStringResource


    public init(localized keyAndValue: LocalizationValue, table: String? = nil, bundle: Bundle? = nil, locale: Locale = .current,
                comment: StaticString? = nil) {
        var r = keyAndValue
        r.table = table
        self = r.resolved(bundle: bundle)
    }

    public init(localized key: StaticString, defaultValue: LocalizationValue, table: String? = nil, bundle: Bundle? = nil,
                locale: Locale = .current, comment: StaticString? = nil) {
        var r = defaultValue
        r.key = "\(key)"
        r.table = table
        self = r.resolved(bundle: bundle)
    }
}

extension AttributedString {
    public init(localized keyAndValue: String.LocalizationValue, table: String? = nil, bundle: Bundle? = nil, locale: Locale = .current,
                comment: StaticString? = nil) {
        self.init(String(localized: keyAndValue, table: table, bundle: bundle, locale: locale, comment: comment))
    }
}
