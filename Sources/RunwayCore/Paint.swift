// Resolved colours, fonts and drawing: what SwiftUI's Color, Font and
// Shape become once the environment (light/dark, hierarchy) is applied.

import CoreGraphics

public struct RGBA: Hashable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(Double(hex >> 16 & 0xff) / 255, Double(hex >> 8 & 0xff) / 255, Double(hex & 0xff) / 255, alpha)
    }
    public func withAlpha(_ a: Double) -> RGBA { RGBA(r, g, b, a) }
    public func multiplyingAlpha(_ f: Double) -> RGBA { RGBA(r, g, b, a * f) }
    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public static let clear = RGBA(0, 0, 0, 0)
    /// "#rrggbbaa" for CSS and logs.
    public var hexString: String {
        func c(_ v: Double) -> String { let i = Int((max(0, min(1, v)) * 255).rounded()); return (i < 16 ? "0" : "") + String(i, radix: 16) }
        return "#" + c(r) + c(g) + c(b) + c(a)
    }
}

/// A fill: a colour or a linear gradient in unit coordinates of the shape.
public enum Paint: Hashable, Sendable {
    case color(RGBA)
    case linearGradient(stops: [GradientStop], start: CGPoint, end: CGPoint)
    case radialGradient(stops: [GradientStop], center: CGPoint, startRadius: CGFloat, endRadius: CGFloat)

    public var averageColor: RGBA {
        switch self {
        case let .color(c): return c
        case let .linearGradient(stops, _, _), let .radialGradient(stops, _, _, _):
            guard !stops.isEmpty else { return .clear }
            let n = Double(stops.count)
            return RGBA(stops.map(\.color.r).reduce(0, +) / n, stops.map(\.color.g).reduce(0, +) / n,
                        stops.map(\.color.b).reduce(0, +) / n, stops.map(\.color.a).reduce(0, +) / n)
        }
    }
    public func multiplyingAlpha(_ f: Double) -> Paint {
        switch self {
        case let .color(c): return .color(c.multiplyingAlpha(f))
        case let .linearGradient(s, a, b): return .linearGradient(stops: s.map { GradientStop(color: $0.color.multiplyingAlpha(f), location: $0.location) }, start: a, end: b)
        case let .radialGradient(s, c, r0, r1): return .radialGradient(stops: s.map { GradientStop(color: $0.color.multiplyingAlpha(f), location: $0.location) }, center: c, startRadius: r0, endRadius: r1)
        }
    }
}

public struct GradientStop: Hashable, Sendable {
    public var color: RGBA
    public var location: Double
    public init(color: RGBA, location: Double) { self.color = color; self.location = location }
}

public enum FontWeightValue: Int, Hashable, Sendable, Comparable {
    case ultraLight = 100, thin = 200, light = 300, regular = 400, medium = 500, semibold = 600, bold = 700, heavy = 800, black = 900
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum FontDesignValue: Hashable, Sendable { case `default`, serif, rounded, monospaced }

/// A concrete font: SwiftUI's text styles resolve to macOS's point sizes so
/// layouts written for the Mac keep their proportions.
public struct FontSpec: Hashable, Sendable {
    public var size: CGFloat
    public var weight: FontWeightValue
    public var design: FontDesignValue
    public var italic: Bool
    public var monospacedDigit: Bool
    public var family: String?
    public init(size: CGFloat = 13, weight: FontWeightValue = .regular, design: FontDesignValue = .default, italic: Bool = false, monospacedDigit: Bool = false, family: String? = nil) {
        self.size = size; self.weight = weight; self.design = design; self.italic = italic; self.monospacedDigit = monospacedDigit; self.family = family
    }
    public static let body = FontSpec()
}

/// One step of drawing in a canvas widget, in the widget's coordinates.
public enum DrawCommand: Hashable, Sendable {
    case fill(ShapePath, Paint)
    case stroke(ShapePath, Paint, lineWidth: CGFloat, dash: [CGFloat])
    case image(ImageSource, CGRect)
    case text(StyledText, CGRect)
    /// Core Graphics drawing recorded by a CGContext (AppKit views'
    /// `draw(_:)`), in the widget's top-left coordinates.
    case displayList(CGDisplayList)
}

/// The geometry shapes reduce to.
public indirect enum ShapePath: Hashable, Sendable {
    case rect(CGRect)
    case roundedRect(CGRect, radius: CGFloat)
    case ellipse(CGRect)
    case path([PathElement])
    /// A shape inset for `strokeBorder`.
    case inset(ShapePath, CGFloat)

    public var bounds: CGRect {
        switch self {
        case let .rect(r), let .roundedRect(r, _), let .ellipse(r): return r
        case let .inset(s, d): return s.bounds.insetBy(dx: d, dy: d)
        case let .path(els):
            var pts: [CGPoint] = []
            for e in els {
                switch e {
                case let .move(p), let .line(p): pts.append(p)
                case let .quad(p, c): pts += [p, c]
                case let .curve(p, c1, c2): pts += [p, c1, c2]
                case .close: break
                }
            }
            guard let f = pts.first else { return .zero }
            return pts.reduce(CGRect(origin: f, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
    }
}

extension ShapePath {
    public func insetBy(_ d: CGFloat) -> ShapePath {
        switch self {
        case let .rect(r): .rect(r.insetBy(dx: d, dy: d))
        case let .roundedRect(r, rad): .roundedRect(r.insetBy(dx: d, dy: d), radius: max(0, rad - d))
        case let .ellipse(r): .ellipse(r.insetBy(dx: d, dy: d))
        default: .inset(self, d)
        }
    }
}

public enum PathElement: Hashable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(CGPoint, control: CGPoint)
    case curve(CGPoint, control1: CGPoint, control2: CGPoint)
    case close
}

extension CGPoint: @retroactive Hashable {
    public func hash(into h: inout Hasher) { h.combine(x); h.combine(y) }
}
extension CGSize: @retroactive Hashable {
    public func hash(into h: inout Hasher) { h.combine(width); h.combine(height) }
}
extension CGRect: @retroactive Hashable {
    public func hash(into h: inout Hasher) { h.combine(origin); h.combine(size) }
}

/// The running backend. `RunwayPlatform` installs the platform's at start;
/// tests install the headless one.
@MainActor public enum Runway {
    private static var installed: Backend?
    public static var defaultBackendFactory: (@MainActor () -> Backend)?
    public static var backend: Backend {
        if let b = installed { return b }
        let b = defaultBackendFactory?() ?? HeadlessBackend()
        installed = b
        return b
    }
    public static func install(_ backend: Backend) { installed = backend }
    public static var isInstalled: Bool { installed != nil }
}
