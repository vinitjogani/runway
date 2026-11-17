// Vector drawing as data. A CGContext sends every drawing operation to
// its target as a `CGDisplayOp`; a recording context keeps them as a
// `CGDisplayList`, which backends replay natively (Cairo on Linux), and a
// bitmap context rasterizes them in software. Each op carries the state it
// needs (transform, colour, alpha, blend mode), so a list replays without
// the context that made it.

import Foundation

public enum CGBlendMode: Int32, Sendable, Hashable {
    case normal, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight
    case difference, exclusion, hue, saturation, color, luminosity
    case clear, copy, sourceIn, sourceOut, sourceAtop, destinationOver, destinationIn, destinationOut, destinationAtop
    case xor, plusDarker, plusLighter
}

public struct CGGradientDrawingOptions: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let drawsBeforeStartLocation = CGGradientDrawingOptions(rawValue: 1)
    public static let drawsAfterEndLocation = CGGradientDrawingOptions(rawValue: 2)
}

/// A gradient: colours at locations in 0…1.
public final class CGGradient: Hashable, @unchecked Sendable {
    /// RGBA per stop.
    public let colors: [[CGFloat]]
    public let locations: [CGFloat]
    /// Made in a linear colour space: colours mix in linear light (bitmap
    /// contexts honour it; native targets may mix sRGB-encoded values).
    public private(set) var interpolatesInLinearLight = false

    public init?(colorsSpace space: CGColorSpace?, colors: [CGColor], locations: [CGFloat]?) {
        guard !colors.isEmpty else { return nil }
        self.colors = colors.map(\.rgba)
        self.locations = locations ?? Self.even(colors.count)
        interpolatesInLinearLight = space?.isLinear ?? false
    }
    /// Core Graphics' own signature: the colours as a CFArray of CGColors.
    public convenience init?(colorsSpace space: CGColorSpace?, colors: CFArray, locations: UnsafePointer<CGFloat>?) {
        let cs = (colors as [AnyObject]).compactMap { $0 as? CGColor }
        self.init(colorsSpace: space, colors: cs, locations: locations.map { l in (0..<cs.count).map { l[$0] } })
    }
    public convenience init?(colorsSpace space: CGColorSpace?, colors: CFArray, locations: [CGFloat]?) {
        let cs = (colors as [AnyObject]).compactMap { $0 as? CGColor }
        self.init(colorsSpace: space, colors: cs, locations: locations)
    }
    public init?(colorSpace space: CGColorSpace, colorComponents: UnsafePointer<CGFloat>, locations: UnsafePointer<CGFloat>?, count: Int) {
        guard count > 0 else { return nil }
        let n = space.numberOfComponents + 1
        var cs: [[CGFloat]] = []
        for i in 0..<count {
            let base = colorComponents + i * n
            cs.append(n == 2 ? [base[0], base[0], base[0], base[1]] : [base[0], base[1], base[2], base[3]])
        }
        colors = cs
        self.locations = locations.map { l in (0..<count).map { l[$0] } } ?? Self.even(count)
        interpolatesInLinearLight = space.isLinear
    }
    /// Runway: RGBA stops directly.
    public init(stops: [(color: [CGFloat], location: CGFloat)]) {
        colors = stops.map(\.color)
        locations = stops.map(\.location)
    }
    static func even(_ n: Int) -> [CGFloat] { n == 1 ? [0] : (0..<n).map { CGFloat($0) / CGFloat(n - 1) } }

    public static func == (l: CGGradient, r: CGGradient) -> Bool { l === r || (l.colors == r.colors && l.locations == r.locations) }
    public func hash(into h: inout Hasher) { h.combine(colors); h.combine(locations) }

    /// The colour at `t`, mixed in linear light when `linear` (returned linear, then).
    public func color(at t: CGFloat, linear: Bool) -> [CGFloat] {
        guard linear else { return color(at: t) }
        guard let first = locations.first, let last = locations.last else { return [0, 0, 0, 0] }
        func lin(_ c: [CGFloat]) -> [CGFloat] { c.prefix(3).map(Transfer.linear) + [c[3]] }
        if t <= first { return lin(colors[0]) }
        if t >= last { return lin(colors[colors.count - 1]) }
        for i in 1..<locations.count where t <= locations[i] {
            let a = locations[i - 1], b = locations[i]
            let f = b > a ? (t - a) / (b - a) : 1
            let ca = lin(colors[i - 1]), cb = lin(colors[i])
            return (0..<4).map { ca[$0] + (cb[$0] - ca[$0]) * f }
        }
        return lin(colors[colors.count - 1])
    }

    /// The colour at `t` (0…1), linearly interpolated.
    public func color(at t: CGFloat) -> [CGFloat] {
        guard let first = locations.first, let last = locations.last else { return [0, 0, 0, 0] }
        if t <= first { return colors[0] }
        if t >= last { return colors[colors.count - 1] }
        for i in 1..<locations.count where t <= locations[i] {
            let a = locations[i - 1], b = locations[i]
            let f = b > a ? (t - a) / (b - a) : 1
            return (0..<4).map { colors[i - 1][$0] + (colors[i][$0] - colors[i - 1][$0]) * f }
        }
        return colors[colors.count - 1]
    }
}

/// How a stroke is drawn.
public struct CGStrokeStyle: Hashable, Sendable {
    public var lineWidth: CGFloat = 1
    public var lineCap: CGLineCap = .butt
    public var lineJoin: CGLineJoin = .miter
    public var miterLimit: CGFloat = 10
    public var dashPhase: CGFloat = 0
    public var dashLengths: [CGFloat] = []
    public init() {}
}

/// A shadow cast by what's drawn (backends may approximate the blur).
public struct CGShadowSpec: Hashable, Sendable {
    public var offset: CGSize
    public var blur: CGFloat
    public var color: [CGFloat]
    public init(offset: CGSize, blur: CGFloat, color: [CGFloat]) { self.offset = offset; self.blur = blur; self.color = color }
}

/// The graphics state an op is drawn with.
public struct CGDrawState: Hashable, Sendable {
    /// User space to the target's device space.
    public var ctm: CGAffineTransform = .identity
    public var alpha: CGFloat = 1
    public var blendMode: CGBlendMode = .normal
    public var antialias = true
    public var shadow: CGShadowSpec?
    public init() {}
}

/// A run of text with its attributes, for text ops. Fonts are described,
/// not loaded: the backend resolves the family (nil: the system UI font).
public struct CGTextRun: Hashable, Sendable {
    public var string: String
    public var family: String?
    public var size: CGFloat
    /// 100…900, CSS-style.
    public var weight: Int
    public var italic: Bool
    public var monospaced: Bool
    public var color: [CGFloat]
    public var backgroundColor: [CGFloat]?
    public var underline: Bool
    public var strikethrough: Bool
    public var kern: CGFloat
    public var baselineOffset: CGFloat
    public init(string: String, family: String? = nil, size: CGFloat = 13, weight: Int = 400, italic: Bool = false, monospaced: Bool = false,
                color: [CGFloat] = [0, 0, 0, 1], backgroundColor: [CGFloat]? = nil, underline: Bool = false, strikethrough: Bool = false,
                kern: CGFloat = 0, baselineOffset: CGFloat = 0) {
        self.string = string; self.family = family; self.size = size; self.weight = weight; self.italic = italic; self.monospaced = monospaced
        self.color = color; self.backgroundColor = backgroundColor; self.underline = underline; self.strikethrough = strikethrough
        self.kern = kern; self.baselineOffset = baselineOffset
    }
}

/// Text to lay out: runs, a wrap width, alignment and line breaking.
public struct CGTextLayout: Hashable, Sendable {
    public enum Alignment: Int, Hashable, Sendable { case left, center, right, justified, natural }
    public enum LineBreak: Int, Hashable, Sendable { case wordWrap, charWrap, clip, truncateHead, truncateTail, truncateMiddle }
    public var runs: [CGTextRun]
    /// Wrap (or truncate) to this width; nil: one line per paragraph, unbounded.
    public var width: CGFloat?
    /// Clip to this height (nil: unbounded).
    public var height: CGFloat?
    public var alignment: Alignment = .natural
    public var lineBreak: LineBreak = .wordWrap
    public var lineSpacing: CGFloat = 0
    public var maximumLines: Int = 0
    public init(runs: [CGTextRun], width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .natural, lineBreak: LineBreak = .wordWrap) {
        self.runs = runs; self.width = width; self.height = height; self.alignment = alignment; self.lineBreak = lineBreak
    }
    public var string: String { runs.map(\.string).joined() }
}

/// One drawing operation.
public enum CGDisplayOp: Hashable, Sendable {
    /// Push and pop the clip (other state travels with each op).
    case save
    case restore
    /// Intersects the clip with `path` (user space, drawn through `ctm`).
    case clip(CGPath, CGPathFillRule, ctm: CGAffineTransform)
    case fill(CGPath, CGPathFillRule, color: [CGFloat], CGDrawState)
    case stroke(CGPath, CGStrokeStyle, color: [CGFloat], CGDrawState)
    /// Makes `rect` transparent.
    case clear(CGRect, ctm: CGAffineTransform)
    /// Draws `image` in `rect` as Core Graphics does: the image's top row at
    /// the rect's maxY, so it's upright in a y-up space.
    case image(CGImage, CGRect, CGInterpolationQuality, CGDrawState)
    /// Fills the clip with a gradient.
    case linearGradient(CGGradient, start: CGPoint, end: CGPoint, CGGradientDrawingOptions, CGDrawState)
    case radialGradient(CGGradient, startCenter: CGPoint, startRadius: CGFloat, endCenter: CGPoint, endRadius: CGFloat, CGGradientDrawingOptions, CGDrawState)
    /// Text with its layout box's top-left at `origin` (user space). With
    /// `flipped` the user space is y-down and lines run toward +y; without,
    /// they run toward -y. Glyphs are always upright.
    case text(CGTextLayout, origin: CGPoint, flipped: Bool, CGDrawState)
}

/// Recorded drawing: what a recording CGContext produced.
public struct CGDisplayList: Hashable, Sendable {
    public var ops: [CGDisplayOp]
    public init(_ ops: [CGDisplayOp] = []) { self.ops = ops }
    public var isEmpty: Bool { ops.isEmpty }
}

/// Where a CGContext sends its ops: a recorder, a bitmap, or a native
/// surface a backend provides (Cairo on Linux).
public protocol CGRenderTarget: AnyObject {
    func execute(_ op: CGDisplayOp)
}

extension CGImage: Hashable {
    public static func == (l: CGImage, r: CGImage) -> Bool { l === r }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}

extension CGColor: Hashable {
    public func hash(into h: inout Hasher) { h.combine(components ?? []) }
    /// RGBA, expanding gray.
    public var rgba: [CGFloat] {
        let c = components ?? [0, 0, 0, 1]
        switch c.count {
        case 1: return [c[0], c[0], c[0], 1]
        case 2: return [c[0], c[0], c[0], c[1]]
        case 3: return [c[0], c[1], c[2], 1]
        default: return [c[0], c[1], c[2], c[3]]
        }
    }
}
