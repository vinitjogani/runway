// Canvas and GraphicsContext: immediate-mode drawing recorded as the same
// draw commands shapes use (paths filled and stroked with resolved paints,
// text, images), replayed by the backend's canvas widget.

import Foundation
import RunwayCore

public struct GraphicsContext {
    final class Recorder {
        var commands: [DrawCommand] = []
    }
    let recorder: Recorder
    let env: EnvironmentValues
    public var transform: CGAffineTransform = .identity
    public var opacity: Double = 1
    public var blendMode: BlendMode = .normal
    public var environment: EnvironmentValues { env }

    init(env: EnvironmentValues) { recorder = Recorder(); self.env = env }

    public struct Shading {
        let paint: @MainActor (EnvironmentValues) -> Paint
        var paintForPath: (@MainActor (EnvironmentValues, CGRect) -> Paint)?
        public static func color(_ color: Color) -> Shading { Shading { color.resolvePaint($0, role: .fill) } }
        public static func color(red: Double, green: Double, blue: Double, opacity: Double = 1) -> Shading {
            .color(Color(red: red, green: green, blue: blue, opacity: opacity))
        }
        public static func style<S: ShapeStyle>(_ style: S) -> Shading { Shading { AnyShapeStyle(style).resolvePaint($0, role: .fill) } }
        public static var foreground: Shading { Shading { $0._foreground?.resolvePaint($0, role: .foreground) ?? Color.primary.resolvePaint($0, role: .fill) } }
        public static func linearGradient(_ gradient: Gradient, startPoint: CGPoint, endPoint: CGPoint, options: GradientOptions = []) -> Shading {
            Shading { env in AnyShapeStyle(LinearGradient(gradient: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)).resolvePaint(env, role: .fill) }
        }
        public static func conicGradient(_ gradient: Gradient, center: CGPoint, angle: Angle = .zero, options: GradientOptions = []) -> Shading {
            var shading = Shading.color(gradient.stops.first?.color ?? .clear)
            let stops = gradient.stops.sorted { $0.location < $1.location }
            shading.paintForPath = { env, bounds in
                guard let first = stops.first, let last = stops.last else { return .color(.clear) }
                // The desktop drawing backends do not have a conic paint.
                // Sample at the centre of each path to preserve the angular
                // colouring of small repeated marks in a Canvas.
                let turns = (atan2(bounds.midY - center.y, bounds.midX - center.x) - angle.radians) / (2 * .pi)
                let fraction = turns - floor(turns)
                if fraction <= first.location { return .color(first.color.resolve(env)) }
                guard let upper = stops.firstIndex(where: { $0.location > fraction }) else { return .color(last.color.resolve(env)) }
                let a = stops[upper - 1], b = stops[upper]
                let mix = (fraction - a.location) / (b.location - a.location)
                let from = a.color.resolve(env), to = b.color.resolve(env)
                func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * mix }
                return .color(RGBA(lerp(from.r, to.r), lerp(from.g, to.g), lerp(from.b, to.b), lerp(from.a, to.a)))
            }
            return shading
        }
    }

    public struct GradientOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let `repeat` = GradientOptions(rawValue: 1)
        public static let mirror = GradientOptions(rawValue: 2)
        public static let linearColor = GradientOptions(rawValue: 4)
    }

    public struct BlendMode: Equatable, Sendable {
        let raw: Int
        public static let normal = BlendMode(raw: 0), multiply = BlendMode(raw: 1), screen = BlendMode(raw: 2),
                          overlay = BlendMode(raw: 3), clear = BlendMode(raw: 4), copy = BlendMode(raw: 5),
                          sourceAtop = BlendMode(raw: 6), destinationOut = BlendMode(raw: 7), plusLighter = BlendMode(raw: 8)
    }

    public struct ResolvedText {
        let styled: StyledText
        let size: CGSize
        public func measure(in size: CGSize) -> CGSize { CGSize(width: min(self.size.width, size.width), height: self.size.height) }
        public var shading: Shading = .foreground
    }

    public struct ResolvedImage {
        let source: ImageSource
        public var size: CGSize
        public var baseline: CGFloat { size.height }
        public var shading: Shading?
    }

    public struct ResolvedSymbol {
        public var size: CGSize { .zero }
    }

    // MARK: Transforms

    public mutating func translateBy(x: CGFloat, y: CGFloat) { transform = CGAffineTransform(translationX: x, y: y).concatenating(transform) }
    public mutating func scaleBy(x: CGFloat, y: CGFloat) { transform = CGAffineTransform(scaleX: x, y: y).concatenating(transform) }
    public mutating func rotate(by angle: Angle) { transform = CGAffineTransform(rotationAngle: angle.radians).concatenating(transform) }
    public mutating func concatenate(_ m: CGAffineTransform) { transform = m.concatenating(transform) }
    public mutating func clip(to path: Path, style: FillStyle = FillStyle(), options: ClipOptions = []) {}
    public mutating func clipToLayer(opacity: Double = 1, options: ClipOptions = [], content: (inout GraphicsContext) throws -> Void) rethrows {}
    public mutating func addFilter(_ filter: Filter, options: FilterOptions = []) {}

    public struct ClipOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let inverse = ClipOptions(rawValue: 1)
    }
    public struct Filter: Sendable {
        public static func shadow(color: Color = .black, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) -> Filter { Filter() }
        public static func blur(radius: CGFloat) -> Filter { Filter() }
        public static func opacity(_ amount: Double) -> Filter { Filter() }
    }
    public struct FilterOptions: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
    }

    public func drawLayer(content: (inout GraphicsContext) throws -> Void) rethrows {
        var c = self
        try content(&c)
    }

    // MARK: Drawing

    private func mapped(_ path: Path) -> ShapePath {
        path.applying(transform).shapePath
    }

    @preconcurrency @MainActor public func fill(_ path: Path, with shading: Shading, style: FillStyle = FillStyle()) {
        recorder.commands.append(.fill(mapped(path), paint(shading, path)))
    }

    @preconcurrency @MainActor public func stroke(_ path: Path, with shading: Shading, style: StrokeStyle) {
        recorder.commands.append(.stroke(mapped(path), paint(shading, path), style: style.drawingStyle))
    }

    @MainActor private func paint(_ shading: Shading, _ path: Path) -> Paint {
        let paint = shading.paintForPath?(env, path.boundingRect) ?? shading.paint(env)
        return paint.multiplyingAlpha(opacity)
    }

    @preconcurrency @MainActor public func stroke(_ path: Path, with shading: Shading, lineWidth: CGFloat = 1) {
        stroke(path, with: shading, style: StrokeStyle(lineWidth: lineWidth))
    }

    @preconcurrency @MainActor public func resolve(_ text: Text) -> ResolvedText {
        let styled = text.styled(env)
        let chars = styled.runs.reduce(0) { $0 + $1.string.count }
        let font = styled.runs.first?.font.size ?? 13
        return ResolvedText(styled: styled, size: CGSize(width: ceil(CGFloat(chars) * font * 0.58), height: ceil(font * 1.25)))
    }

    @preconcurrency @MainActor public func resolve(_ image: Image) -> ResolvedImage {
        ResolvedImage(source: image.imageSource, size: CGSize(width: 16, height: 16))
    }

    @preconcurrency @MainActor public func draw(_ text: ResolvedText, at point: CGPoint, anchor: UnitPoint = .center) {
        let p = point.applying(transform)
        let origin = CGPoint(x: p.x - text.size.width * anchor.x, y: p.y - text.size.height * anchor.y)
        recorder.commands.append(.text(text.styled, CGRect(origin: origin, size: text.size)))
    }
    @preconcurrency @MainActor public func draw(_ text: ResolvedText, in rect: CGRect) {
        recorder.commands.append(.text(text.styled, rect.applying(transform)))
    }
    @preconcurrency @MainActor public func draw(_ text: Text, at point: CGPoint, anchor: UnitPoint = .center) { draw(resolve(text), at: point, anchor: anchor) }
    @preconcurrency @MainActor public func draw(_ text: Text, in rect: CGRect) { draw(resolve(text), in: rect) }

    @preconcurrency @MainActor public func draw(_ image: ResolvedImage, in rect: CGRect, style: FillStyle = FillStyle()) {
        recorder.commands.append(.image(image.source, rect.applying(transform)))
    }
    @preconcurrency @MainActor public func draw(_ image: ResolvedImage, at point: CGPoint, anchor: UnitPoint = .center) {
        let p = point.applying(transform)
        draw(image, in: CGRect(x: p.x - image.size.width * anchor.x, y: p.y - image.size.height * anchor.y, width: image.size.width, height: image.size.height))
    }
    @preconcurrency @MainActor public func draw(_ image: Image, in rect: CGRect, style: FillStyle = FillStyle()) { draw(resolve(image), in: rect, style: style) }
    @preconcurrency @MainActor public func draw(_ image: Image, at point: CGPoint, anchor: UnitPoint = .center) { draw(resolve(image), at: point, anchor: anchor) }
    public func resolveSymbol<ID: Hashable>(id: ID) -> ResolvedSymbol? { nil }
    public func draw(_ symbol: ResolvedSymbol, at point: CGPoint, anchor: UnitPoint = .center) {}
}

public struct Canvas<Symbols: View>: View, PrimitiveView {
    public typealias Body = Never
    let renderer: (inout GraphicsContext, CGSize) -> Void
    let opaque: Bool

    public init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear, rendersAsynchronously: Bool = false,
                renderer: @escaping (inout GraphicsContext, CGSize) -> Void) where Symbols == EmptyView {
        self.renderer = renderer
        self.opaque = opaque
    }
    public init(opaque: Bool = false, colorMode: ColorRenderingMode = .nonLinear, rendersAsynchronously: Bool = false,
                renderer: @escaping (inout GraphicsContext, CGSize) -> Void, @ViewBuilder symbols: () -> Symbols) {
        self.renderer = renderer
        self.opaque = opaque
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let env = ctx.env
        let renderer = self.renderer
        var p = WidgetProps()
        p.tooltip = env._help
        return [ShapeNode(widget: ctx.widget(.canvas), backend: ctx.host.backend, props: p, events: WidgetEvents()) { rect in
            var g = GraphicsContext(env: env)
            g.opacity = env._opacity
            renderer(&g, rect.size)
            return g.recorder.commands
        }]
    }
}

public enum ColorRenderingMode: Sendable { case nonLinear, linear, extendedLinear }
