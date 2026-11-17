// Text, fonts and LocalizedStringKey.

import Foundation
import RunwayCore

public struct LocalizedStringKey: Hashable, Sendable, ExpressibleByStringInterpolation {
    let string: String
    public init(_ value: String) { string = value }
    public init(stringLiteral value: String) { string = value }
    public init(stringInterpolation: StringInterpolation) { string = stringInterpolation.output }

    public struct StringInterpolation: StringInterpolationProtocol {
        var output = ""
        public init(literalCapacity: Int, interpolationCount: Int) { output.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { output += literal }
        public mutating func appendInterpolation<T>(_ value: T) { output += String(describing: value) }
        public mutating func appendInterpolation(_ value: String) { output += value }
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, specifier: String) {
            output += String(format: specifier, Double(value))
        }
        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, specifier: String) {
            output += String(format: specifier, Int(value))
        }
        public mutating func appendInterpolation(_ text: Text) { output += text.plainText }
        public mutating func appendInterpolation<F: FormatStyle>(_ value: F.FormatInput, format: F) where F.FormatOutput == String {
            output += format.format(value)
        }
        public mutating func appendInterpolation(_ date: Date, style: Text.DateStyle) {
            let f = DateFormatter()
            f.dateStyle = style == .date ? .medium : .none
            f.timeStyle = style == .time ? .short : .none
            output += f.string(from: date)
        }
    }
}

public struct Font: Hashable, Sendable {
    var spec: FontSpec
    init(_ spec: FontSpec) { self.spec = spec }

    public enum Weight: Hashable, Sendable {
        case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
        var value: FontWeightValue {
            switch self {
            case .ultraLight: .ultraLight
            case .thin: .thin
            case .light: .light
            case .regular: .regular
            case .medium: .medium
            case .semibold: .semibold
            case .bold: .bold
            case .heavy: .heavy
            case .black: .black
            }
        }
    }
    public enum Design: Hashable, Sendable {
        case `default`, serif, rounded, monospaced
        var value: FontDesignValue {
            switch self {
            case .default: .default
            case .serif: .serif
            case .rounded: .rounded
            case .monospaced: .monospaced
            }
        }
    }
    public enum TextStyle: Hashable, Sendable, CaseIterable {
        case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2
    }
    public struct Width: Hashable, Sendable {
        public static let compressed = Width(), condensed = Width(), standard = Width(), expanded = Width()
    }
    public enum Leading: Hashable, Sendable { case standard, tight, loose }

    /// macOS's text style metrics, so Mac layouts keep their proportions.
    static func style(_ s: TextStyle) -> FontSpec {
        switch s {
        case .largeTitle: FontSpec(size: 26)
        case .title: FontSpec(size: 22)
        case .title2: FontSpec(size: 17)
        case .title3: FontSpec(size: 15)
        case .headline: FontSpec(size: 13, weight: .bold)
        case .subheadline: FontSpec(size: 11)
        case .body: FontSpec(size: 13)
        case .callout: FontSpec(size: 12)
        case .footnote: FontSpec(size: 10)
        case .caption: FontSpec(size: 10)
        case .caption2: FontSpec(size: 10)
        }
    }

    public static let largeTitle = Font(style(.largeTitle))
    public static let title = Font(style(.title))
    public static let title2 = Font(style(.title2))
    public static let title3 = Font(style(.title3))
    public static let headline = Font(style(.headline))
    public static let subheadline = Font(style(.subheadline))
    public static let body = Font(style(.body))
    public static let callout = Font(style(.callout))
    public static let footnote = Font(style(.footnote))
    public static let caption = Font(style(.caption))
    public static let caption2 = Font(style(.caption2))

    public static func system(size: CGFloat, weight: Weight? = nil, design: Design? = nil) -> Font {
        Font(FontSpec(size: size, weight: weight?.value ?? .regular, design: design?.value ?? .default))
    }
    public static func system(_ style: TextStyle, design: Design? = nil, weight: Weight? = nil) -> Font {
        var s = Self.style(style)
        if let d = design { s.design = d.value }
        if let w = weight { s.weight = w.value }
        return Font(s)
    }
    public static func custom(_ name: String, size: CGFloat) -> Font { Font(FontSpec(size: size, family: name)) }
    public static func custom(_ name: String, size: CGFloat, relativeTo: TextStyle) -> Font { custom(name, size: size) }
    public static func custom(_ name: String, fixedSize: CGFloat) -> Font { custom(name, size: fixedSize) }

    public func weight(_ w: Weight) -> Font { var f = self; f.spec.weight = w.value; return f }
    public func bold() -> Font { weight(.bold) }
    public func italic() -> Font { var f = self; f.spec.italic = true; return f }
    public func monospacedDigit() -> Font { var f = self; f.spec.monospacedDigit = true; return f }
    public func monospaced() -> Font { var f = self; f.spec.design = .monospaced; return f }
    func design(_ d: Design) -> Font { var f = self; f.spec.design = d.value; return f }
    public func smallCaps() -> Font { self }
    public func width(_ w: Width) -> Font { self }
    public func leading(_ l: Leading) -> Font { self }
}

public struct Text: View, PrimitiveView, Equatable {
    public typealias Body = Never

    struct Segment: Equatable {
        var string: String
        var font: Font?
        var color: Color?
        var weight: Font.Weight?
        var italic = false
        var monoDigit = false
        var underline = false
        var strikethrough = false
    }
    var segments: [Segment]

    public init(_ key: LocalizedStringKey, tableName: String? = nil, bundle: Bundle? = nil, comment: StaticString? = nil) {
        segments = Text.markdown(Text.localized(key.string, table: tableName, bundle: bundle))
    }
    /// The key's translation from the bundle's strings tables (the key itself when there is none).
    static func localized(_ key: String, table: String?, bundle: Bundle?) -> String {
        guard !key.isEmpty, key.utf8.count < 400 else { return key }
        let cacheKey = (table ?? "") + "\u{0}" + key + "\u{0}" + (bundle?.bundlePath ?? "")
        localizationLock.lock()
        defer { localizationLock.unlock() }
        if let hit = localizationCache[cacheKey] { return hit }
        let value = (bundle ?? .main).localizedString(forKey: key, value: key, table: table)
        if localizationCache.count > 4000 { localizationCache.removeAll() }
        localizationCache[cacheKey] = value
        return value
    }
    private static let localizationLock = NSLock()
    nonisolated(unsafe) private static var localizationCache: [String: String] = [:]
    @_disfavoredOverload public init<S: StringProtocol>(_ content: S) { segments = [Segment(string: String(content))] }
    public init(verbatim content: String) { segments = [Segment(string: content)] }
    public init(_ attributed: AttributedString) { segments = [Segment(string: String(attributed.characters))] }
    public init<F: FormatStyle>(_ input: F.FormatInput, format: F) where F.FormatOutput == String { segments = [Segment(string: format.format(input))] }
    public init(_ date: Date, style: DateStyle) {
        var interp = LocalizedStringKey.StringInterpolation(literalCapacity: 0, interpolationCount: 1)
        interp.appendInterpolation(date, style: style)
        segments = [Segment(string: interp.output)]
    }
    public init(_ range: ClosedRange<Date>) { segments = [Segment(string: "\(range.lowerBound) – \(range.upperBound)")] }
    init(segments: [Segment]) { self.segments = segments }

    public enum DateStyle: Sendable { case time, date, relative, offset, timer }
    public enum TruncationMode: Hashable, Sendable { case head, middle, tail }
    public enum Case: Sendable { case uppercase, lowercase }

    var plainText: String { segments.map(\.string).joined() }

    /// `**bold**`, `*italic*` and `` `code` `` in literals, as SwiftUI renders them.
    static func markdown(_ s: String) -> [Segment] {
        guard s.contains("*") || s.contains("`") else { return [Segment(string: s)] }
        var out: [Segment] = []
        var current = ""
        var bold = false, italic = false, code = false
        var chars = Array(s)[...]
        func flush() {
            guard !current.isEmpty else { return }
            out.append(Segment(string: current, font: code ? .body.monospaced() : nil, weight: bold ? .bold : nil, italic: italic))
            current = ""
        }
        while let c = chars.first {
            chars = chars.dropFirst()
            if c == "`" { flush(); code.toggle(); continue }
            if c == "*", !code {
                if chars.first == "*" { chars = chars.dropFirst(); flush(); bold.toggle(); continue }
                flush(); italic.toggle(); continue
            }
            current.append(c)
        }
        flush()
        return out
    }

    private func map(_ f: (inout Segment) -> Void) -> Text {
        Text(segments: segments.map { var s = $0; f(&s); return s })
    }
    public func font(_ font: Font?) -> Text { map { if $0.font == nil { $0.font = font } } }
    public func foregroundColor(_ color: Color?) -> Text { map { if $0.color == nil { $0.color = color } } }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> Text {
        guard let c = style as? Color else { return self }
        return foregroundColor(c)
    }
    public func fontWeight(_ w: Font.Weight?) -> Text { map { $0.weight = w } }
    public func bold() -> Text { fontWeight(.bold) }
    public func bold(_ active: Bool) -> Text { active ? bold() : self }
    public func italic() -> Text { map { $0.italic = true } }
    public func italic(_ active: Bool) -> Text { active ? italic() : self }
    public func monospacedDigit() -> Text { map { $0.monoDigit = true } }
    public func monospaced(_ active: Bool = true) -> Text { active ? map { $0.font = ($0.font ?? .body).monospaced() } : self }
    public func underline(_ active: Bool = true, color: Color? = nil) -> Text { map { $0.underline = active } }
    public func strikethrough(_ active: Bool = true, color: Color? = nil) -> Text { map { $0.strikethrough = active } }
    public func kerning(_ k: CGFloat) -> Text { self }
    public func tracking(_ t: CGFloat) -> Text { self }
    public func baselineOffset(_ o: CGFloat) -> Text { self }
    public func textCase(_ c: Case?) -> Text {
        guard let c else { return self }
        return map { $0.string = c == .uppercase ? $0.string.uppercased() : $0.string.lowercased() }
    }

    public static func + (a: Text, b: Text) -> Text { Text(segments: a.segments + b.segments) }

    /// The text's runs with the environment applied.
    func styled(_ env: EnvironmentValues) -> StyledText {
        let base = (env.font ?? .body).spec
        let fg = env._foreground?.resolvePaint(env, role: .foreground).averageColor ?? Color.primary.resolve(env)
        let runs = segments.map { s -> TextRun in
            var f = s.font?.spec ?? base
            if let w = s.weight ?? env._fontWeight { f.weight = w.value }
            if s.italic || env._italic { f.italic = true }
            if s.monoDigit || env._monospacedDigit { f.monospacedDigit = true }
            let color = (s.color?.resolve(env) ?? fg).multiplyingAlpha(env.isEnabled ? 1 : 0.5)
            return TextRun(string: s.string, font: f, color: color, underline: s.underline, strikethrough: s.strikethrough)
        }
        let align: TextAlignmentValue = switch env.multilineTextAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        let trunc: TruncationValue = switch env.truncationMode {
        case .head: .head
        case .middle: .middle
        case .tail: .tail
        }
        return StyledText(runs: runs, alignment: align, lineLimit: env.lineLimit, truncation: trunc)
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let w = ctx.widget(.text)
        if let w {
            var p = WidgetProps()
            p.text = styled(ctx.env)
            p.tooltip = ctx.env._help
            p.opacity = ctx.env._opacity
            ctx.host.backend.update(w, props: p, events: WidgetEvents())
        }
        return [WidgetNode(w, backend: ctx.host.backend, text: plainText)]
    }
}

extension Text {
    public init(_ image: Image) { segments = [Segment(string: "")] }
}


// MARK: SwiftUI's AttributedString attributes

extension Text {
    /// The line of an underline or strikethrough.
    public struct LineStyle: Hashable, Sendable {
        public struct Pattern: Hashable, Sendable {
            let name: String
            public static let solid = Pattern(name: "solid"), dot = Pattern(name: "dot"), dash = Pattern(name: "dash")
            public static let dashDot = Pattern(name: "dashDot"), dashDotDot = Pattern(name: "dashDotDot")
        }
        public var pattern: Pattern
        public var color: Color?
        public init(pattern: Pattern = .solid, color: Color? = nil) { self.pattern = pattern; self.color = color }
        public static let single = LineStyle()
        public init?(nsUnderlineStyle: NSUnderlineStyle) { self.init() }
    }
}

extension AttributeScopes {
    /// `attributedString.font`, `.foregroundColor`…: the attributes Text reads.
    public struct SwiftUIAttributes: AttributeScope {
        public let font: FontAttribute
        public let foregroundColor: ForegroundColorAttribute
        public let backgroundColor: BackgroundColorAttribute
        public let strikethroughStyle: StrikethroughStyleAttribute
        public let underlineStyle: UnderlineStyleAttribute
        public let kern: KernAttribute
        public let tracking: TrackingAttribute
        public let baselineOffset: BaselineOffsetAttribute
        public let foundation: AttributeScopes.FoundationAttributes

        public enum FontAttribute: AttributedStringKey { public typealias Value = Font; public static let name = "SwiftUI.Font" }
        public enum ForegroundColorAttribute: AttributedStringKey { public typealias Value = Color; public static let name = "SwiftUI.ForegroundColor" }
        public enum BackgroundColorAttribute: AttributedStringKey { public typealias Value = Color; public static let name = "SwiftUI.BackgroundColor" }
        public enum StrikethroughStyleAttribute: AttributedStringKey { public typealias Value = Text.LineStyle; public static let name = "SwiftUI.StrikethroughStyle" }
        public enum UnderlineStyleAttribute: AttributedStringKey { public typealias Value = Text.LineStyle; public static let name = "SwiftUI.UnderlineStyle" }
        public enum KernAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "SwiftUI.Kern" }
        public enum TrackingAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "SwiftUI.Tracking" }
        public enum BaselineOffsetAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "SwiftUI.BaselineOffset" }
    }
    public var swiftUI: SwiftUIAttributes.Type { SwiftUIAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SwiftUIAttributes, T>) -> T { self[T.self] }
}
