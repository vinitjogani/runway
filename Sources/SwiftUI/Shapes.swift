// Shapes and paths, drawn by the backend's canvas (Cairo on Linux, GDI on
// Windows), and Image.

import Foundation
import CoreGraphics
import RunwayCore

public struct Path: Hashable, Sendable {
    var elements: [PathElement] = []
    var simple: ShapePath?
    public init() {}
    public init(_ rect: CGRect) { simple = .rect(rect); addRect(rect) }
    public init(roundedRect rect: CGRect, cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        simple = .roundedRect(rect, radius: cornerRadius)
    }
    public init(roundedRect rect: CGRect, cornerSize: CGSize, style: RoundedCornerStyle = .continuous) {
        simple = .roundedRect(rect, radius: min(cornerSize.width, cornerSize.height))
    }
    public init(ellipseIn rect: CGRect) { simple = .ellipse(rect) }
    public init(_ path: CGPath) {
        elements = path.ops.map { operation in
            switch operation {
            case .move(let point): .move(point)
            case .line(let point): .line(point)
            case .quad(let control, let point): .quad(point, control: control)
            case .cubic(let first, let second, let point): .curve(point, control1: first, control2: second)
            case .close: .close
            }
        }
    }
    public init(_ build: (inout Path) -> Void) { build(&self) }

    public mutating func move(to p: CGPoint) { simple = nil; elements.append(.move(p)) }
    public mutating func addLine(to p: CGPoint) { simple = nil; elements.append(.line(p)) }
    public mutating func addLines(_ ps: [CGPoint]) {
        guard let f = ps.first else { return }
        move(to: f)
        ps.dropFirst().forEach { addLine(to: $0) }
    }
    public mutating func addQuadCurve(to p: CGPoint, control: CGPoint) { simple = nil; elements.append(.quad(p, control: control)) }
    public mutating func addCurve(to p: CGPoint, control1: CGPoint, control2: CGPoint) { simple = nil; elements.append(.curve(p, control1: control1, control2: control2)) }
    public mutating func closeSubpath() { elements.append(.close) }
    public mutating func addRect(_ r: CGRect) {
        let keep = simple
        addLines([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
        closeSubpath()
        simple = keep
    }
    public mutating func addEllipse(in r: CGRect) {
        let k: CGFloat = 0.5522847498
        let (cx, cy, rx, ry) = (r.midX, r.midY, r.width / 2, r.height / 2)
        move(to: CGPoint(x: cx + rx, y: cy))
        addCurve(to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + k * ry), control2: CGPoint(x: cx + k * rx, y: cy + ry))
        addCurve(to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - k * rx, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + k * ry))
        addCurve(to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - k * ry), control2: CGPoint(x: cx - k * rx, y: cy - ry))
        addCurve(to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + k * rx, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - k * ry))
        closeSubpath()
    }
    public mutating func addRoundedRect(in r: CGRect, cornerSize: CGSize, style: RoundedCornerStyle = .continuous) {
        let rad = min(cornerSize.width, r.width / 2, r.height / 2)
        let k: CGFloat = 0.5522847498 * rad
        move(to: CGPoint(x: r.minX + rad, y: r.minY))
        addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        addCurve(to: CGPoint(x: r.maxX, y: r.minY + rad), control1: CGPoint(x: r.maxX - rad + k, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + rad - k))
        addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        addCurve(to: CGPoint(x: r.maxX - rad, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - rad + k), control2: CGPoint(x: r.maxX - rad + k, y: r.maxY))
        addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        addCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), control1: CGPoint(x: r.minX + rad - k, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - rad + k))
        addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        addCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + rad - k), control2: CGPoint(x: r.minX + rad - k, y: r.minY))
        closeSubpath()
    }
    public mutating func addPath(_ p: Path) { simple = nil; elements += p.shapePath.flattenedElements }
    public mutating func addArc(center: CGPoint, radius: CGFloat, startAngle: Angle, endAngle: Angle, clockwise: Bool) {
        let steps = 24
        let a0 = startAngle.radians, a1 = endAngle.radians
        var sweep = a1 - a0
        if clockwise, sweep > 0 { sweep -= 2 * .pi } else if !clockwise, sweep < 0 { sweep += 2 * .pi }
        for i in 0...steps {
            let a = a0 + sweep * Double(i) / Double(steps)
            let p = CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a)))
            if i == 0, elements.isEmpty { move(to: p) } else { addLine(to: p) }
        }
    }

    var shapePath: ShapePath { simple ?? .path(elements) }
    public var boundingRect: CGRect { shapePath.bounds }
    public var isEmpty: Bool { simple == nil && elements.isEmpty }

    public var cgPath: CGPath { shapePath.cgPath }

    public func applying(_ transform: CGAffineTransform) -> Path {
        transform.isIdentity ? self : Path(cgPath.copy(using: transform))
    }

    public func trimmedPath(from start: CGFloat, to end: CGFloat) -> Path {
        guard start.isFinite, end.isFinite else { return Path() }
        let lower = max(0, start), upper = min(1, end)
        guard lower < upper else { return Path() }
        if lower == 0 && upper == 1 { return self }

        if case let .ellipse(bounds)? = simple, bounds.width == bounds.height, bounds.width > 0 {
            // Circles have constant arc length per turn. Preserve their smooth curve.
            let arc = CGMutablePath()
            arc.addRelativeArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2,
                               startAngle: lower * 2 * .pi, delta: (upper - lower) * 2 * .pi)
            return Path(arc)
        }

        let subpaths = cgPath.flattened(tolerance: 0.1).map { polyline in
            var points = polyline.points
            if polyline.closed, let first = points.first { points.append(first) }
            return zip(points, points.dropFirst()).compactMap(TrimSegment.init)
        }
        let length = subpaths.reduce(CGFloat(0)) { total, segments in
            total + segments.reduce(CGFloat(0)) { $0 + $1.length }
        }
        guard length.isFinite, length > 0 else { return Path() }
        let startDistance = lower * length, endDistance = upper * length

        var distance: CGFloat = 0
        var result = Path()
        for segments in subpaths {
            var beganSubpath = false
            for segment in segments {
                let segmentStart = distance
                distance += segment.length
                if segmentStart >= endDistance { return result }
                if distance <= startDistance { continue }
                if !beganSubpath {
                    result.move(to: segment.point(at: max(0, startDistance - segmentStart)))
                    beganSubpath = true
                }
                result.addLine(to: segment.point(at: min(segment.length, endDistance - segmentStart)))
            }
        }
        return result
    }
}

private struct TrimSegment {
    let start: CGPoint
    let end: CGPoint
    let length: CGFloat

    init?(_ points: (CGPoint, CGPoint)) {
        (start, end) = points
        length = hypot(end.x - start.x, end.y - start.y)
        guard length.isFinite, length > 0 else { return nil }
    }

    func point(at distance: CGFloat) -> CGPoint {
        let fraction = distance / length
        return CGPoint(x: start.x + fraction * (end.x - start.x), y: start.y + fraction * (end.y - start.y))
    }
}

extension ShapePath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        for element in flattenedElements {
            switch element {
            case .move(let point): path.move(to: point)
            case .line(let point): path.addLine(to: point)
            case .quad(let point, let control): path.addQuadCurve(to: point, control: control)
            case .curve(let point, let first, let second): path.addCurve(to: point, control1: first, control2: second)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    var flattenedElements: [PathElement] {
        if case let .path(e) = self { return e }
        var p = Path()
        switch self {
        case let .rect(r): p.addRect(r)
        case let .roundedRect(r, rad): p.addRoundedRect(in: r, cornerSize: CGSize(width: rad, height: rad))
        case let .ellipse(r): p.addEllipse(in: r)
        case let .inset(s, d): return s.insetBy(d).flattenedElements
        case .path: break
        }
        return p.elements
    }
}

extension DrawCommand {
    func applying(_ transform: CGAffineTransform) -> DrawCommand {
        switch self {
        case let .fill(path, paint):
            let transformed = Path(path.cgPath.copy(using: transform)).shapePath
            return .fill(transformed, paint.applying(transform, before: path.bounds, after: transformed.bounds))
        case let .stroke(path, paint, style):
            let transformed = Path(path.cgPath.copy(using: transform)).shapePath
            return .stroke(transformed, paint.applying(transform, before: path.bounds, after: transformed.bounds), style: style)
        case let .image(source, frame): return .image(source, frame.applying(transform))
        case let .text(text, frame): return .text(text, frame.applying(transform))
        case .displayList: return self
        }
    }
}

private extension Paint {
    func applying(_ transform: CGAffineTransform, before: CGRect, after: CGRect) -> Paint {
        func map(_ unit: CGPoint) -> CGPoint {
            let point = CGPoint(x: before.minX + unit.x * before.width, y: before.minY + unit.y * before.height).applying(transform)
            return CGPoint(x: after.width > 0 ? (point.x - after.minX) / after.width : 0,
                           y: after.height > 0 ? (point.y - after.minY) / after.height : 0)
        }
        switch self {
        case .color: return self
        case let .linearGradient(stops, start, end): return .linearGradient(stops: stops, start: map(start), end: map(end))
        case let .radialGradient(stops, center, start, end): return .radialGradient(stops: stops, center: map(center), startRadius: start, endRadius: end)
        }
    }
}

public enum RoundedCornerStyle: Hashable, Sendable { case circular, continuous }

public struct FillStyle: Hashable, Sendable {
    public var isEOFilled: Bool
    public var isAntialiased: Bool
    public init(eoFill: Bool = false, antialiased: Bool = true) { isEOFilled = eoFill; isAntialiased = antialiased }
}

public struct StrokeStyle: Hashable, Sendable {
    public var lineWidth: CGFloat
    public var lineCap: LineCap
    public var lineJoin: LineJoin
    public var miterLimit: CGFloat
    public var dash: [CGFloat]
    public var dashPhase: CGFloat
    public typealias LineCap = CGLineCap
    public typealias LineJoin = CGLineJoin
    public init(lineWidth: CGFloat = 1, lineCap: LineCap = .butt, lineJoin: LineJoin = .miter, miterLimit: CGFloat = 10, dash: [CGFloat] = [], dashPhase: CGFloat = 0) {
        self.lineWidth = lineWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.miterLimit = miterLimit
        self.dash = dash
        self.dashPhase = dashPhase
    }

    var drawingStyle: CGStrokeStyle {
        var style = CGStrokeStyle()
        style.lineWidth = lineWidth
        style.lineCap = lineCap
        style.lineJoin = lineJoin
        style.miterLimit = miterLimit
        style.dashLengths = dash
        style.dashPhase = dashPhase
        return style
    }
}

public protocol Shape: View, Sendable {
    func path(in rect: CGRect) -> Path
}

public protocol InsettableShape: Shape {
    associatedtype InsetShape: InsettableShape
    func inset(by amount: CGFloat) -> InsetShape
}

extension Path: Shape {
    public func path(in rect: CGRect) -> Path { self }
}

extension Shape {
    public var body: some View { _ShapeView(shape: self, style: AnyShapeStyle(ForegroundStyle()), stroke: nil) }
    public func fill<S: ShapeStyle>(_ style: S = ForegroundStyle(), style fillStyle: FillStyle = FillStyle()) -> _ShapeView<Self> {
        _ShapeView(shape: self, style: AnyShapeStyle(style), stroke: nil)
    }
    public func stroke<S: ShapeStyle>(_ style: S, lineWidth: CGFloat = 1) -> _ShapeView<Self> {
        _ShapeView(shape: self, style: AnyShapeStyle(style), stroke: StrokeStyle(lineWidth: lineWidth))
    }
    public func stroke<S: ShapeStyle>(_ content: S, style: StrokeStyle) -> _ShapeView<Self> {
        _ShapeView(shape: self, style: AnyShapeStyle(content), stroke: style)
    }
    public func stroke(lineWidth: CGFloat = 1) -> _ShapeView<Self> { stroke(ForegroundStyle(), lineWidth: lineWidth) }
    public func stroke(style: StrokeStyle) -> _ShapeView<Self> { stroke(ForegroundStyle(), style: style) }
    public func trim(from: CGFloat = 0, to: CGFloat = 1) -> some Shape {
        TrimmedShape(shape: self, from: from, to: to)
    }
    public func rotation(_ angle: Angle, anchor: UnitPoint = .center) -> some Shape {
        RotatedShape(shape: self, angle: angle, anchor: anchor)
    }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> Self { self }
}

private struct TrimmedShape<Base: Shape>: Shape {
    let shape: Base
    let from: CGFloat
    let to: CGFloat
    func path(in rect: CGRect) -> Path { shape.path(in: rect).trimmedPath(from: from, to: to) }
}

struct ShapeRotation: Sendable {
    let angle: Angle
    let anchor: UnitPoint

    func transform(in rect: CGRect) -> CGAffineTransform {
        guard angle.radians.isFinite, angle.radians != 0 else { return .identity }
        let x = rect.minX + anchor.x * rect.width, y = rect.minY + anchor.y * rect.height
        // Keep right-angle rotations on integer boundaries when placing their surfaces.
        func snap(_ value: CGFloat) -> CGFloat { abs(value) < 1e-12 ? 0 : value }
        let sine = snap(sin(angle.radians)), cosine = snap(cos(angle.radians))
        let turn = CGAffineTransform(a: cosine, b: sine, c: -sine, d: cosine, tx: 0, ty: 0)
        return CGAffineTransform(translationX: -x, y: -y)
            .concatenating(turn)
            .concatenating(CGAffineTransform(translationX: x, y: y))
    }
}

private struct RotatedShape<Base: Shape>: Shape {
    let shape: Base
    let angle: Angle
    let anchor: UnitPoint
    func path(in rect: CGRect) -> Path { shape.path(in: rect).applying(ShapeRotation(angle: angle, anchor: anchor).transform(in: rect)) }
}

extension InsettableShape {
    public func strokeBorder<S: ShapeStyle>(_ style: S, lineWidth: CGFloat = 1, antialiased: Bool = true) -> _ShapeView<Self> {
        var v = _ShapeView(shape: self, style: AnyShapeStyle(style), stroke: StrokeStyle(lineWidth: lineWidth))
        v.insetStroke = true
        return v
    }
    public func strokeBorder<S: ShapeStyle>(_ content: S, style: StrokeStyle, antialiased: Bool = true) -> _ShapeView<Self> {
        var v = _ShapeView(shape: self, style: AnyShapeStyle(content), stroke: style)
        v.insetStroke = true
        return v
    }
    public func strokeBorder(lineWidth: CGFloat = 1, antialiased: Bool = true) -> _ShapeView<Self> { strokeBorder(ForegroundStyle(), lineWidth: lineWidth) }
}

public struct _ShapeView<S: Shape>: View, PrimitiveView {
    public typealias Body = Never
    let shape: S
    let style: AnyShapeStyle
    let stroke: StrokeStyle?
    var insetStroke = false
    var extra: [(AnyShapeStyle, StrokeStyle?, Bool)] = []

    /// `.fill(…).stroke(…)` layered, as in SwiftUI 6.
    public func stroke<T: ShapeStyle>(_ style: T, lineWidth: CGFloat = 1) -> _ShapeView<S> {
        var v = self; v.extra.append((AnyShapeStyle(style), StrokeStyle(lineWidth: lineWidth), false)); return v
    }
    public func strokeBorder<T: ShapeStyle>(_ style: T, lineWidth: CGFloat = 1) -> _ShapeView<S> {
        var v = self; v.extra.append((AnyShapeStyle(style), StrokeStyle(lineWidth: lineWidth), true)); return v
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let env = ctx.env
        let layers = [(style, stroke, insetStroke)] + extra
        let paints = layers.map { ($0.0.resolvePaint(env, role: .fill).multiplyingAlpha(env._opacity), $0.1, $0.2) }
        let shape = self.shape
        var p = WidgetProps()
        p.tooltip = env._help
        return [ShapeNode(widget: ctx.widget(.canvas), backend: ctx.host.backend, props: p, events: WidgetEvents()) { rect in
            paints.map { paint, stroke, inset in
                if let stroke {
                    let path = shape.path(in: inset ? rect.insetBy(dx: stroke.lineWidth / 2, dy: stroke.lineWidth / 2) : rect).shapePath
                    return .stroke(path, paint, style: stroke.drawingStyle)
                }
                return .fill(shape.path(in: rect).shapePath, paint)
            }
        }]
    }
}

public struct Rectangle: InsettableShape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(rect) }
    public func inset(by amount: CGFloat) -> Rectangle { self }
}

public struct RoundedRectangle: InsettableShape {
    public var cornerSize: CGSize
    public var style: RoundedCornerStyle
    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) { cornerSize = CGSize(width: cornerRadius, height: cornerRadius); self.style = style }
    public init(cornerSize: CGSize, style: RoundedCornerStyle = .continuous) { self.cornerSize = cornerSize; self.style = style }
    public func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: min(cornerSize.width, rect.width / 2, rect.height / 2)) }
    public func inset(by amount: CGFloat) -> RoundedRectangle { self }
}

public struct UnevenRoundedRectangle: InsettableShape {
    let radius: CGFloat
    public init(topLeadingRadius: CGFloat = 0, bottomLeadingRadius: CGFloat = 0, bottomTrailingRadius: CGFloat = 0, topTrailingRadius: CGFloat = 0, style: RoundedCornerStyle = .continuous) {
        radius = max(topLeadingRadius, bottomLeadingRadius, bottomTrailingRadius, topTrailingRadius)
    }
    public func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: radius) }
    public func inset(by amount: CGFloat) -> UnevenRoundedRectangle { self }
}

public struct Circle: InsettableShape {
    private var insetAmount: CGFloat = 0
    public init() {}
    public func path(in rect: CGRect) -> Path {
        let d = min(rect.width, rect.height) - 2 * insetAmount
        guard d > 0 else { return Path() }
        return Path(ellipseIn: CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d))
    }
    public func inset(by amount: CGFloat) -> Circle {
        var circle = self
        circle.insetAmount += amount
        return circle
    }
}

public struct Ellipse: InsettableShape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(ellipseIn: rect) }
    public func inset(by amount: CGFloat) -> Ellipse { self }
}

public struct Capsule: InsettableShape {
    public init(style: RoundedCornerStyle = .continuous) {}
    public func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2) }
    public func inset(by amount: CGFloat) -> Capsule { self }
}

public struct ContainerRelativeShape: InsettableShape {
    public init() {}
    public func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: 8) }
    public func inset(by amount: CGFloat) -> ContainerRelativeShape { self }
}

public struct AnyShape: Shape {
    let make: @Sendable (CGRect) -> Path
    public init<S: Shape>(_ shape: S) { make = { shape.path(in: $0) } }
    public func path(in rect: CGRect) -> Path { make(rect) }
}

extension Shape where Self == Rectangle { public static var rect: Rectangle { Rectangle() } }
extension Shape where Self == Circle { public static var circle: Circle { Circle() } }
extension Shape where Self == Capsule { public static var capsule: Capsule { Capsule() } }
extension Shape where Self == Ellipse { public static var ellipse: Ellipse { Ellipse() } }
extension Shape where Self == RoundedRectangle {
    public static func rect(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) -> RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: style) }
}

/// Colours are views: they fill the space offered.
extension Color: View, PrimitiveView {
    public typealias Body = Never
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        _ShapeView(shape: Rectangle(), style: AnyShapeStyle(self), stroke: nil).resolve(in: ctx)
    }
}

extension LinearGradient: View, PrimitiveView {
    public typealias Body = Never
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        _ShapeView(shape: Rectangle(), style: AnyShapeStyle(self), stroke: nil).resolve(in: ctx)
    }
}

extension RadialGradient: View, PrimitiveView {
    public typealias Body = Never
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        _ShapeView(shape: Rectangle(), style: AnyShapeStyle(self), stroke: nil).resolve(in: ctx)
    }
}

// MARK: Image

public struct Image: View, PrimitiveView, Equatable {
    public typealias Body = Never
    enum Source: Equatable { case symbol(String), named(String), pixels(Int, Int, [UInt8]), file(String) }
    let source: Source
    var resizable = false
    var renderingTemplate = false
    var variableValue: Double?

    public init(systemName: String) { source = .symbol(systemName) }
    public init(systemName: String, variableValue: Double?) { source = .symbol(systemName); self.variableValue = variableValue }
    /// An image set of the asset catalogs, or an image file of the bundle.
    public init(_ name: String, bundle: Bundle? = nil) {
        if let found = RunwayAssets.resolveImage(named: name, bundle: bundle) {
            source = .file(found.path)
            renderingTemplate = found.template
        } else { source = .named(name) }
    }
    public init(decorative name: String, bundle: Bundle? = nil) { self.init(name, bundle: bundle) }
    /// RGBA8 pixels (what CGImage and NSImage hold here).
    public init(width: Int, height: Int, rgba: [UInt8]) { source = .pixels(width, height, rgba) }
    init(file path: String) { source = .file(path) }

    public enum ResizingMode: Sendable { case tile, stretch }
    public enum TemplateRenderingMode: Sendable { case template, original }
    public enum Interpolation: Sendable { case none, low, medium, high }
    public enum Scale: Sendable { case small, medium, large }
    public enum Orientation: UInt8, Sendable { case up, upMirrored, down, downMirrored, left, leftMirrored, right, rightMirrored }

    public func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: ResizingMode = .stretch) -> Image { var i = self; i.resizable = true; return i }
    public func renderingMode(_ mode: TemplateRenderingMode?) -> Image { var i = self; i.renderingTemplate = mode == .template; return i }
    public func interpolation(_ i: Interpolation) -> Image { self }
    public func antialiased(_ a: Bool) -> Image { self }
    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> Image { self }
    public func symbolVariant(_ v: SymbolVariants) -> Image { self }

    var imageSource: ImageSource {
        switch source {
        case let .symbol(s): .symbol(s)
        case let .named(n): .symbol(n)
        case let .pixels(w, h, px): .pixels(width: w, height: h, rgba: px)
        case let .file(p): .file(p)
        }
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let env = ctx.env
        let w = ctx.widget(.image)
        let backend = ctx.host.backend
        if let w {
            var p = WidgetProps()
            p.image = imageSource
            p.imagePointSize = (env.font ?? .body).resolved(in: env).size
            if case let .symbol(name) = source {
                if env._mobileTabSymbol, name == "person.crop.circle" {
                    p.imageSymbolVariant = "person.crop.circle.fill"
                }
                p.imageTint = (env._foreground?.resolvePaint(env, role: .foreground).averageColor ?? Color.primary.resolve(env))
                    .multiplyingAlpha(env.isEnabled ? 1 : 0.5)
            }
            p.opacity = env._opacity
            p.tooltip = env._help
            backend.update(w, props: p, events: WidgetEvents())
        }
        let node = WidgetNode(w, backend: backend)
        if resizable {
            node.flexibleWidth = true
            node.flexibleHeight = true
        }
        return [node]
    }
}

public struct SymbolRenderingMode: Sendable {
    public static let monochrome = SymbolRenderingMode(), multicolor = SymbolRenderingMode()
    public static let hierarchical = SymbolRenderingMode(), palette = SymbolRenderingMode()
}

public struct SymbolVariants: Sendable {
    public static let none = SymbolVariants(), fill = SymbolVariants(), circle = SymbolVariants(), square = SymbolVariants(), slash = SymbolVariants()
}

extension View {
    public func imageScale(_ scale: Image.Scale) -> some View { self }
    public func symbolRenderingMode(_ mode: SymbolRenderingMode?) -> some View { self }
    public func symbolVariant(_ v: SymbolVariants) -> some View { self }
}
