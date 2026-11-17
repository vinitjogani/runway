// Color, ShapeStyle (hierarchical styles, gradients, materials, tint).
// Colours resolve per environment, so light and dark follow the system.

import Foundation
import RunwayCore

public enum PaintRole { case foreground, fill }

public protocol ShapeStyle: Sendable {
    /// What this style paints with in an environment.
    @MainActor func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint
}

extension ShapeStyle {
    @MainActor func resolvePaint(_ env: EnvironmentValues, role: PaintRole) -> Paint { _paint(env, role: role) }
}

public struct Color: Hashable, Sendable, ShapeStyle {
    enum Storage: Hashable, Sendable {
        case rgba(RGBA)
        case dynamic(light: RGBA, dark: RGBA)
        case label(level: Int)            // primary…quaternary
        case accent
        case provider(id: Int)            // NSColor dynamic providers
    }
    let storage: Storage
    var opacityFactor: Double = 1

    init(_ storage: Storage) { self.storage = storage }

    public enum RGBColorSpace: Sendable { case sRGB, sRGBLinear, displayP3 }

    public init(_ colorSpace: RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1) {
        storage = .rgba(RGBA(red, green, blue, opacity))
    }
    public init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        storage = .rgba(RGBA(red, green, blue, opacity))
    }
    public init(_ colorSpace: RGBColorSpace = .sRGB, white: Double, opacity: Double = 1) {
        storage = .rgba(RGBA(white, white, white, opacity))
    }
    public init(white: Double, opacity: Double = 1) { storage = .rgba(RGBA(white, white, white, opacity)) }
    public init(hue: Double, saturation: Double, brightness: Double, opacity: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let c = brightness * saturation, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = brightness - c
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        storage = .rgba(RGBA(r + m, g + m, b + m, opacity))
    }
    /// A colour set of the app's asset catalogs (light and dark); the
    /// accent colour when there is none by that name.
    public init(_ name: String, bundle: Bundle? = nil) {
        if let c = RunwayAssets.color(named: name) {
            storage = .dynamic(light: RGBA(c.light.red, c.light.green, c.light.blue, c.light.alpha),
                               dark: RGBA(c.dark.red, c.dark.green, c.dark.blue, c.dark.alpha))
        } else { storage = .accent }
    }
    init(rgba: RGBA) { storage = .rgba(rgba) }
    init(light: RGBA, dark: RGBA) { storage = .dynamic(light: light, dark: dark) }

    public func opacity(_ o: Double) -> Color { var c = self; c.opacityFactor *= o; return c }

    @MainActor func resolve(_ env: EnvironmentValues) -> RGBA {
        let base: RGBA
        let dark = env.colorScheme == .dark
        switch storage {
        case let .rgba(c): base = c
        case let .dynamic(l, d): base = dark ? d : l
        case let .label(level):
            let alpha = [0.85, 0.5, 0.25, 0.1, 0.05][min(level, 4)]
            base = dark ? RGBA(1, 1, 1, alpha) : RGBA(0, 0, 0, alpha)
        case .accent:
            if let t = env._tint, t.storage != .accent { base = t.resolve(env) } else { base = dark ? RGBA(hex: 0x0a84ff) : RGBA(hex: 0x007aff) }
        case let .provider(id): base = ColorProviders.resolve(id, dark: dark)
        }
        return base.multiplyingAlpha(opacityFactor)
    }

    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { .color(resolve(env)) }

    // System colours (macOS values, light/dark).
    public static let clear = Color(rgba: .clear)
    public static let black = Color(rgba: .black)
    public static let white = Color(rgba: .white)
    public static let gray = Color(light: RGBA(hex: 0x8e8e93), dark: RGBA(hex: 0x8e8e93))
    public static let red = Color(light: RGBA(hex: 0xff3b30), dark: RGBA(hex: 0xff453a))
    public static let orange = Color(light: RGBA(hex: 0xff9500), dark: RGBA(hex: 0xff9f0a))
    public static let yellow = Color(light: RGBA(hex: 0xffcc00), dark: RGBA(hex: 0xffd60a))
    public static let green = Color(light: RGBA(hex: 0x28cd41), dark: RGBA(hex: 0x32d74b))
    public static let mint = Color(light: RGBA(hex: 0x00c7be), dark: RGBA(hex: 0x66d4cf))
    public static let teal = Color(light: RGBA(hex: 0x59adc4), dark: RGBA(hex: 0x6ac4dc))
    public static let cyan = Color(light: RGBA(hex: 0x55bef0), dark: RGBA(hex: 0x5ac8f5))
    public static let blue = Color(light: RGBA(hex: 0x007aff), dark: RGBA(hex: 0x0a84ff))
    public static let indigo = Color(light: RGBA(hex: 0x5856d6), dark: RGBA(hex: 0x5e5ce6))
    public static let purple = Color(light: RGBA(hex: 0xaf52de), dark: RGBA(hex: 0xbf5af2))
    public static let pink = Color(light: RGBA(hex: 0xff2d55), dark: RGBA(hex: 0xff375f))
    public static let brown = Color(light: RGBA(hex: 0xa2845e), dark: RGBA(hex: 0xac8e68))
    public static let primary = Color(.label(level: 0))
    public static let secondary = Color(.label(level: 1))
    public static let accentColor = Color(.accent)
    /// Window and control backgrounds.
    static let windowBackground = Color(light: RGBA(hex: 0xececec), dark: RGBA(hex: 0x323232))
    static let controlBackground = Color(light: RGBA(hex: 0xffffff), dark: RGBA(hex: 0x1e1e1e))
}

/// Dynamic colours registered by NSColor(name:dynamicProvider:).
@preconcurrency @MainActor public enum ColorProviders {
    nonisolated(unsafe) static var providers: [Int: (Bool) -> RGBA] = [:]
    nonisolated(unsafe) static var next = 0
    public nonisolated static func register(_ f: @escaping (Bool) -> RGBA) -> Int {
        next += 1
        providers[next] = f
        return next
    }
    nonisolated static func resolve(_ id: Int, dark: Bool) -> RGBA { providers[id]?(dark) ?? .black }
    public nonisolated static func color(id: Int) -> Color { Color(.provider(id: id)) }
}

extension ShapeStyle where Self == Color {
    public static var clear: Color { .clear }
    public static var black: Color { Color.black }
    public static var white: Color { Color.white }
    public static var gray: Color { Color.gray }
    public static var red: Color { Color.red }
    public static var orange: Color { Color.orange }
    public static var yellow: Color { Color.yellow }
    public static var green: Color { Color.green }
    public static var mint: Color { Color.mint }
    public static var teal: Color { Color.teal }
    public static var cyan: Color { Color.cyan }
    public static var blue: Color { Color.blue }
    public static var indigo: Color { Color.indigo }
    public static var purple: Color { Color.purple }
    public static var pink: Color { Color.pink }
    public static var brown: Color { Color.brown }
    public static var accentColor: Color { Color.accentColor }
}

/// .primary, .secondary, .tertiary, .quaternary: the label hierarchy.
public struct HierarchicalShapeStyle: ShapeStyle {
    let level: Int
    public static let primary = HierarchicalShapeStyle(level: 0)
    public static let secondary = HierarchicalShapeStyle(level: 1)
    public static let tertiary = HierarchicalShapeStyle(level: 2)
    public static let quaternary = HierarchicalShapeStyle(level: 3)
    public static let quinary = HierarchicalShapeStyle(level: 4)
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint {
        // Relative to the current foreground when one was set.
        if level > 0, let fg = env._foreground, !(fg.base is HierarchicalShapeStyle) {
            let c = fg.resolvePaint(env, role: role).averageColor
            return .color(c.multiplyingAlpha([1, 0.5, 0.3, 0.12, 0.06][level]))
        }
        return .color(Color(.label(level: level)).resolve(env))
    }
}

extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { .primary }
    public static var secondary: HierarchicalShapeStyle { .secondary }
    public static var tertiary: HierarchicalShapeStyle { .tertiary }
    public static var quaternary: HierarchicalShapeStyle { .quaternary }
    public static var quinary: HierarchicalShapeStyle { .quinary }
}

public struct TintShapeStyle: ShapeStyle {
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { .color(Color.accentColor.resolve(env)) }
}
extension ShapeStyle where Self == TintShapeStyle { public static var tint: TintShapeStyle { TintShapeStyle() } }

public struct ForegroundStyle: ShapeStyle {
    public init() {}
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint {
        env._foreground?.resolvePaint(env, role: role) ?? .color(Color.primary.resolve(env))
    }
}
extension ShapeStyle where Self == ForegroundStyle { public static var foreground: ForegroundStyle { ForegroundStyle() } }

public struct SeparatorShapeStyle: ShapeStyle {
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { .color(Color(.label(level: 3)).resolve(env)) }
}
extension ShapeStyle where Self == SeparatorShapeStyle { public static var separator: SeparatorShapeStyle { SeparatorShapeStyle() } }

/// Materials: translucent fills; here, the window's backgrounds.
public struct Material: ShapeStyle {
    let alpha: Double
    public static let ultraThinMaterial = Material(alpha: 0.5)
    public static let thinMaterial = Material(alpha: 0.65)
    public static let regularMaterial = Material(alpha: 0.8)
    public static let thickMaterial = Material(alpha: 0.9)
    public static let ultraThickMaterial = Material(alpha: 0.95)
    public static let bar = Material(alpha: 0.85)
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint {
        .color(Color.windowBackground.resolve(env).multiplyingAlpha(alpha))
    }
}
extension ShapeStyle where Self == Material {
    public static var ultraThinMaterial: Material { .ultraThinMaterial }
    public static var thinMaterial: Material { .thinMaterial }
    public static var regularMaterial: Material { .regularMaterial }
    public static var thickMaterial: Material { .thickMaterial }
    public static var ultraThickMaterial: Material { .ultraThickMaterial }
    public static var bar: Material { .bar }
}

public struct BackgroundStyle: ShapeStyle {
    public init() {}
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { .color(Color.windowBackground.resolve(env)) }
}
extension ShapeStyle where Self == BackgroundStyle { public static var background: BackgroundStyle { BackgroundStyle() } }

public struct AnyShapeStyle: ShapeStyle {
    let base: any ShapeStyle
    public init<S: ShapeStyle>(_ style: S) {
        if let a = style as? AnyShapeStyle { base = a.base } else { base = style }
    }
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { base._paint(env, role: role) }
}

extension ShapeStyle {
    public func opacity(_ o: Double) -> some ShapeStyle { OpacityStyle(base: AnyShapeStyle(self), opacity: o) }
}

struct OpacityStyle: ShapeStyle {
    let base: AnyShapeStyle
    let opacity: Double
    func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint { base._paint(env, role: role).multiplyingAlpha(opacity) }
}

// MARK: Gradients

public struct Gradient: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public var color: Color
        public var location: CGFloat
        public init(color: Color, location: CGFloat) { self.color = color; self.location = location }
    }
    public var stops: [Stop]
    public init(stops: [Stop]) { self.stops = stops }
    public init(colors: [Color]) {
        let n = max(1, colors.count - 1)
        stops = colors.enumerated().map { Stop(color: $1, location: CGFloat($0) / CGFloat(n)) }
    }
    @MainActor func resolved(_ env: EnvironmentValues) -> [GradientStop] {
        stops.map { GradientStop(color: $0.color.resolve(env), location: Double($0.location)) }
    }
}

public struct LinearGradient: ShapeStyle {
    let gradient: Gradient
    let start: UnitPoint, end: UnitPoint
    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) { self.gradient = gradient; start = startPoint; end = endPoint }
    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) { self.init(gradient: Gradient(colors: colors), startPoint: startPoint, endPoint: endPoint) }
    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) { self.init(gradient: Gradient(stops: stops), startPoint: startPoint, endPoint: endPoint) }
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint {
        .linearGradient(stops: gradient.resolved(env), start: start.point, end: end.point)
    }
}

public struct RadialGradient: ShapeStyle {
    let gradient: Gradient
    let center: UnitPoint
    let startRadius: CGFloat, endRadius: CGFloat
    public init(gradient: Gradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.gradient = gradient; self.center = center; self.startRadius = startRadius; self.endRadius = endRadius
    }
    public init(colors: [Color], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.init(gradient: Gradient(colors: colors), center: center, startRadius: startRadius, endRadius: endRadius)
    }
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint {
        .radialGradient(stops: gradient.resolved(env), center: center.point, startRadius: startRadius, endRadius: endRadius)
    }
}

/// Approximated as a sweep from leading to trailing.
public struct AngularGradient: ShapeStyle {
    let gradient: Gradient
    public init(gradient: Gradient, center: UnitPoint, startAngle: Angle = .zero, endAngle: Angle = .zero) { self.gradient = gradient }
    public init(colors: [Color], center: UnitPoint, startAngle: Angle = .zero, endAngle: Angle = .zero) { gradient = Gradient(colors: colors) }
    public init(gradient: Gradient, center: UnitPoint, angle: Angle = .zero) { self.gradient = gradient }
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint {
        .linearGradient(stops: gradient.resolved(env), start: CGPoint(x: 0, y: 0.5), end: CGPoint(x: 1, y: 0.5))
    }
}

extension Color {
    public var gradient: AnyGradient { AnyGradient(Gradient(colors: [self.opacity(0.85), self])) }
}

public struct AnyGradient: ShapeStyle {
    let gradient: Gradient
    init(_ g: Gradient) { gradient = g }
    public func _paint(_ env: EnvironmentValues, role: PaintRole) -> Paint {
        .linearGradient(stops: gradient.resolved(env), start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
    }
}

public struct Angle: Hashable, Sendable, Comparable {
    public var radians: Double
    public var degrees: Double { radians * 180 / .pi }
    public init(radians: Double) { self.radians = radians }
    public init(degrees: Double) { radians = degrees * .pi / 180 }
    public init() { radians = 0 }
    public static func radians(_ r: Double) -> Angle { Angle(radians: r) }
    public static func degrees(_ d: Double) -> Angle { Angle(degrees: d) }
    public static let zero = Angle(radians: 0)
    public static func < (a: Angle, b: Angle) -> Bool { a.radians < b.radians }
}


// MARK: Core Graphics colours

extension Color {
    /// `Color(cgColor:)`: the colour's sRGB components.
    public init(cgColor: CGColor) {
        let c = cgColor.components ?? [0, 0, 0, 1]
        if c.count >= 4 { self.init(.rgba(RGBA(Double(c[0]), Double(c[1]), Double(c[2]), Double(c[3])))) }
        else if c.count == 2 { self.init(.rgba(RGBA(Double(c[0]), Double(c[0]), Double(c[0]), Double(c[1])))) }
        else { self.init(.rgba(RGBA(0, 0, 0, 1))) }
    }
    public init(_ cgColor: CGColor) { self.init(cgColor: cgColor) }

    /// The colour as a CGColor, when it doesn't depend on the environment
    /// (as SwiftUI: nil for dynamic colours such as `.primary`).
    public var cgColor: CGColor? {
        switch storage {
        case let .rgba(c):
            return CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a * opacityFactor))
        default: return nil
        }
    }
}
