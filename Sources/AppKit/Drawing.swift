// Drawing as AppKit does it: NSGraphicsContext (over a CGContext),
// NSBezierPath, colours setting the fill and stroke, NSRectFill and
// friends, NSGradient, NSShadow, images and strings drawn into the current
// context, and the text attributes string drawing reads.

import Foundation
import RunwayCore

// MARK: NSGraphicsContext

@preconcurrency @MainActor
open class NSGraphicsContext: NSObject {
    /// The context drawing goes to: set while a view's `draw(_:)` runs.
    public static var current: NSGraphicsContext? {
        get { stack.last ?? _current }
        set { _current = newValue }
    }
    nonisolated(unsafe) private static var _current: NSGraphicsContext?
    nonisolated(unsafe) private static var stack: [NSGraphicsContext] = []

    public let cgContext: CGContext
    public let isFlipped: Bool
    open var imageInterpolation: NSImageInterpolation = .default {
        didSet { cgContext.interpolationQuality = CGInterpolationQuality(rawValue: Int32(imageInterpolation.rawValue)) ?? .default }
    }
    open var shouldAntialias = true { didSet { cgContext.setShouldAntialias(shouldAntialias) } }
    open var compositingOperation: NSCompositingOperation = .sourceOver {
        didSet { cgContext.setBlendMode(compositingOperation.blendMode) }
    }
    open var patternPhase: NSPoint = .zero
    open var colorRenderingIntent: Int = 0
    open var isDrawingToScreen: Bool { !cgContext.isRecording || true }
    open var attributes: [NSGraphicsContext.AttributeKey: Any]? { nil }
    public struct AttributeKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
    }

    public init(cgContext: CGContext, flipped: Bool) {
        self.cgContext = cgContext
        isFlipped = flipped
        super.init()
    }
    public convenience init(window: NSWindow) {
        self.init(cgContext: CGContext(recordingSize: window.frame.size), flipped: false)
    }
    /// The deprecated `graphicsPort` (the CGContext).
    open var graphicsPort: UnsafeMutableRawPointer { Unmanaged.passUnretained(cgContext).toOpaque() }

    open func saveGraphicsState() { cgContext.saveGState() }
    open func restoreGraphicsState() { cgContext.restoreGState() }
    public static func saveGraphicsState() {
        if let c = current { stack.append(c); c.saveGraphicsState() }
    }
    public static func restoreGraphicsState() {
        if let c = stack.popLast() { c.restoreGraphicsState() } else { current?.restoreGraphicsState() }
    }
    open func flushGraphics() {}
    public static func currentContextDrawingToScreen() -> Bool { true }
    /// Runs `body` with this as the current context.
    open func perform(_ body: () -> Void) {
        let old = Self.current
        Self.current = self
        body()
        Self.current = old
    }
}

public enum NSImageInterpolation: UInt, Sendable { case `default`, none, low, medium, high }

public enum NSCompositingOperation: UInt, Sendable {
    case clear, copy, sourceOver, sourceIn, sourceOut, sourceAtop, destinationOver, destinationIn, destinationOut, destinationAtop
    case xor, plusDarker, plusLighter, multiply, screen, overlay, darken, lighten, colorDodge, colorBurn, softLight, hardLight
    case difference, exclusion, hue, saturation, color, luminosity
    var blendMode: CGBlendMode {
        switch self {
        case .clear: .clear
        case .copy: .copy
        case .sourceOver: .normal
        case .sourceIn: .sourceIn
        case .sourceOut: .sourceOut
        case .sourceAtop: .sourceAtop
        case .destinationOver: .destinationOver
        case .destinationIn: .destinationIn
        case .destinationOut: .destinationOut
        case .destinationAtop: .destinationAtop
        case .xor: .xor
        case .plusDarker: .plusDarker
        case .plusLighter: .plusLighter
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .darken: .darken
        case .lighten: .lighten
        case .colorDodge: .colorDodge
        case .colorBurn: .colorBurn
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        }
    }
}

// MARK: Colours as drawing state

extension NSColor {
    @MainActor private var cg: CGColor { cgColor }
    /// Sets the fill and stroke colour of the current context.
    @preconcurrency @MainActor public func set() {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        let col = cgColor
        c.setFillColor(col)
        c.setStrokeColor(col)
    }
    @preconcurrency @MainActor public func setFill() { NSGraphicsContext.current?.cgContext.setFillColor(cgColor) }
    @preconcurrency @MainActor public func setStroke() { NSGraphicsContext.current?.cgContext.setStrokeColor(cgColor) }
    /// Fills `rect` with this colour (`NSColor.red.setFill(); rect.fill()` in one).
    @preconcurrency @MainActor public func drawSwatch(in rect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.saveGState(); setFill(); c.fill(rect); c.restoreGState()
    }
}

@preconcurrency @MainActor public func NSRectFill(_ rect: NSRect) { NSGraphicsContext.current?.cgContext.fill(rect) }
@preconcurrency @MainActor public func NSRectFillList(_ rects: UnsafePointer<NSRect>, _ count: Int) {
    NSGraphicsContext.current?.cgContext.fill((0..<count).map { rects[$0] })
}
@preconcurrency @MainActor public func NSRectFillUsingOperation(_ rect: NSRect, _ op: NSCompositingOperation) {
    guard let c = NSGraphicsContext.current?.cgContext else { return }
    c.saveGState(); c.setBlendMode(op.blendMode); c.fill(rect); c.restoreGState()
}
@preconcurrency @MainActor public func NSFrameRect(_ rect: NSRect) { NSFrameRectWithWidth(rect, 1) }
@preconcurrency @MainActor public func NSFrameRectWithWidth(_ rect: NSRect, _ width: CGFloat) {
    guard let c = NSGraphicsContext.current?.cgContext else { return }
    // Inside the rect, as AppKit frames: four edges in the fill colour.
    c.fill([CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: width),
            CGRect(x: rect.minX, y: rect.maxY - width, width: rect.width, height: width),
            CGRect(x: rect.minX, y: rect.minY + width, width: width, height: max(0, rect.height - 2 * width)),
            CGRect(x: rect.maxX - width, y: rect.minY + width, width: width, height: max(0, rect.height - 2 * width))])
}
@preconcurrency @MainActor public func NSEraseRect(_ rect: NSRect) {
    guard let c = NSGraphicsContext.current?.cgContext else { return }
    c.saveGState(); c.setFillColor(gray: 1, alpha: 1); c.fill(rect); c.restoreGState()
}
@preconcurrency @MainActor public func NSRectClip(_ rect: NSRect) { NSGraphicsContext.current?.cgContext.clip(to: rect) }

extension NSRect {
    /// `rect.fill()`: fills with the current fill colour.
    @preconcurrency @MainActor public func fill() { NSRectFill(self) }
    @preconcurrency @MainActor public func fill(using op: NSCompositingOperation) { NSRectFillUsingOperation(self, op) }
    @preconcurrency @MainActor public func frame(withWidth width: CGFloat = 1, using op: NSCompositingOperation = .sourceOver) { NSFrameRectWithWidth(self, width) }
    @preconcurrency @MainActor public func clip() { NSRectClip(self) }
}

// MARK: NSBezierPath

@preconcurrency @MainActor
open class NSBezierPath: NSObject {
    public enum LineCapStyle: UInt, Sendable { case butt, round, square }
    public enum LineJoinStyle: UInt, Sendable { case miter, round, bevel }
    public enum WindingRule: UInt, Sendable { case nonZero, evenOdd }
    public enum ElementType: UInt, Sendable { case moveTo, lineTo, cubicCurveTo, closePath, quadraticCurveTo }

    public let path = CGMutablePath()
    open var lineWidth: CGFloat = NSBezierPath.defaultLineWidth
    open var lineCapStyle: LineCapStyle = NSBezierPath.defaultLineCapStyle
    open var lineJoinStyle: LineJoinStyle = NSBezierPath.defaultLineJoinStyle
    open var miterLimit: CGFloat = NSBezierPath.defaultMiterLimit
    open var windingRule: WindingRule = NSBezierPath.defaultWindingRule
    open var flatness: CGFloat = 0.6
    private var dash: [CGFloat] = []
    private var dashPhase: CGFloat = 0

    nonisolated(unsafe) public static var defaultLineWidth: CGFloat = 1
    nonisolated(unsafe) public static var defaultLineCapStyle: LineCapStyle = .butt
    nonisolated(unsafe) public static var defaultLineJoinStyle: LineJoinStyle = .miter
    nonisolated(unsafe) public static var defaultMiterLimit: CGFloat = 10
    nonisolated(unsafe) public static var defaultWindingRule: WindingRule = .nonZero
    nonisolated(unsafe) public static var defaultFlatness: CGFloat = 0.6

    public override init() { super.init() }
    public convenience init(rect: NSRect) { self.init(); appendRect(rect) }
    public convenience init(ovalIn rect: NSRect) { self.init(); appendOval(in: rect) }
    public convenience init(roundedRect rect: NSRect, xRadius: CGFloat, yRadius: CGFloat) {
        self.init(); appendRoundedRect(rect, xRadius: xRadius, yRadius: yRadius)
    }
    public convenience init(cgPath: CGPath) { self.init(); path.addPath(cgPath) }
    open var cgPath: CGPath { path.copy()! }

    open func move(to p: NSPoint) { path.move(to: p) }
    open func line(to p: NSPoint) { path.addLine(to: p) }
    open func curve(to p: NSPoint, controlPoint1 c1: NSPoint, controlPoint2 c2: NSPoint) { path.addCurve(to: p, control1: c1, control2: c2) }
    open func curve(to p: NSPoint, controlPoint c: NSPoint) { path.addQuadCurve(to: p, control: c) }
    open func close() { path.closeSubpath() }
    open func relativeMove(to d: NSPoint) { let c = currentPoint; move(to: NSPoint(x: c.x + d.x, y: c.y + d.y)) }
    open func relativeLine(to d: NSPoint) { let c = currentPoint; line(to: NSPoint(x: c.x + d.x, y: c.y + d.y)) }
    open func relativeCurve(to d: NSPoint, controlPoint1 c1: NSPoint, controlPoint2 c2: NSPoint) {
        let c = currentPoint
        curve(to: NSPoint(x: c.x + d.x, y: c.y + d.y), controlPoint1: NSPoint(x: c.x + c1.x, y: c.y + c1.y), controlPoint2: NSPoint(x: c.x + c2.x, y: c.y + c2.y))
    }
    open func removeAllPoints() { path.removeAll() }
    open func appendRect(_ r: NSRect) { path.addRect(r) }
    open func appendRects(_ rects: UnsafePointer<NSRect>, count: Int) { for i in 0..<count { path.addRect(rects[i]) } }
    open func appendOval(in r: NSRect) { path.addEllipse(in: r) }
    open func appendRoundedRect(_ r: NSRect, xRadius: CGFloat, yRadius: CGFloat) { path.addRoundedRect(in: r, cornerWidth: xRadius, cornerHeight: yRadius) }
    /// Angles in degrees, counter-clockwise unless `clockwise`, as AppKit.
    open func appendArc(withCenter c: NSPoint, radius r: CGFloat, startAngle a0: CGFloat, endAngle a1: CGFloat, clockwise: Bool = false) {
        path.addArc(center: c, radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: clockwise)
    }
    open func appendArc(from p1: NSPoint, to p2: NSPoint, radius r: CGFloat) { path.addArc(tangent1End: p1, tangent2End: p2, radius: r) }
    open func append(_ other: NSBezierPath) { path.addPath(other.path) }
    open func appendPoints(_ points: UnsafeMutablePointer<NSPoint>, count: Int) {
        for i in 0..<count { if i == 0 && path.isEmpty { move(to: points[i]) } else { line(to: points[i]) } }
    }
    open func addClip() { applyTo { $0.addPath(path); $0.clip(using: windingRule == .evenOdd ? .evenOdd : .winding) } }
    open func setClip() { addClip() }
    open func setLineDash(_ pattern: UnsafePointer<CGFloat>?, count: Int, phase: CGFloat) {
        dash = pattern.map { p in (0..<count).map { p[$0] } } ?? []
        dashPhase = phase
    }
    open func getLineDash(_ pattern: UnsafeMutablePointer<CGFloat>?, count: UnsafeMutablePointer<Int>?, phase: UnsafeMutablePointer<CGFloat>?) {
        count?.pointee = dash.count
        phase?.pointee = dashPhase
        if let pattern { for (i, d) in dash.enumerated() { pattern[i] = d } }
    }

    private func applyTo(_ f: (CGContext) -> Void) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        f(c)
    }
    open func fill() {
        applyTo { c in
            c.addPath(path)
            c.fillPath(using: windingRule == .evenOdd ? .evenOdd : .winding)
        }
    }
    open func stroke() {
        applyTo { c in
            let old = c.strokeStyle
            var s = old
            s.lineWidth = lineWidth
            s.lineCap = CGLineCap(rawValue: Int32(lineCapStyle.rawValue)) ?? .butt
            s.lineJoin = CGLineJoin(rawValue: Int32(lineJoinStyle.rawValue)) ?? .miter
            s.miterLimit = miterLimit
            s.dashLengths = dash
            s.dashPhase = dashPhase
            c.strokeStyle = s
            c.addPath(path)
            c.strokePath()
            c.strokeStyle = old
        }
    }

    open var bounds: NSRect { path.isEmpty ? .zero : path.boundingBoxOfPath }
    open var controlPointBounds: NSRect { path.isEmpty ? .zero : path.boundingBox }
    open var isEmpty: Bool { path.isEmpty }
    open var currentPoint: NSPoint { path.currentPoint }
    open func contains(_ p: NSPoint) -> Bool { path.contains(p, using: windingRule == .evenOdd ? .evenOdd : .winding) }
    open var elementCount: Int { path.ops.count }
    open func element(at index: Int) -> ElementType {
        switch path.ops[index] {
        case .move: .moveTo
        case .line: .lineTo
        case .quad: .quadraticCurveTo
        case .cubic: .cubicCurveTo
        case .close: .closePath
        }
    }
    open func element(at index: Int, associatedPoints points: UnsafeMutablePointer<NSPoint>?) -> ElementType {
        if let points {
            switch path.ops[index] {
            case let .move(p), let .line(p): points[0] = p
            case let .quad(c, p): points[0] = c; points[1] = p
            case let .cubic(a, b, p): points[0] = a; points[1] = b; points[2] = p
            case .close: break
            }
        }
        return element(at: index)
    }
    open func transform(using t: AffineTransform) {
        let cg = CGAffineTransform(a: t.m11, b: t.m12, c: t.m21, d: t.m22, tx: t.tX, ty: t.tY)
        path.transform(by: cg)
    }
    open override nonisolated func copy() -> Any { MainActor.assumeIsolated { duplicate() } }
    private func duplicate() -> NSBezierPath {
        let p = NSBezierPath()
        p.path.addPath(path)
        p.lineWidth = lineWidth; p.lineCapStyle = lineCapStyle; p.lineJoinStyle = lineJoinStyle
        p.miterLimit = miterLimit; p.windingRule = windingRule; p.dash = dash; p.dashPhase = dashPhase
        return p
    }
    open var reversed: NSBezierPath {
        let p = NSBezierPath()
        for poly in path.flattened() {
            let pts = poly.points.reversed()
            guard let f = pts.first else { continue }
            p.move(to: f)
            for q in pts.dropFirst() { p.line(to: q) }
            if poly.closed { p.close() }
        }
        return p
    }
    open var flattened: NSBezierPath {
        let p = NSBezierPath()
        for poly in path.flattened() {
            guard let f = poly.points.first else { continue }
            p.move(to: f)
            for q in poly.points.dropFirst() { p.line(to: q) }
            if poly.closed { p.close() }
        }
        return p
    }

    public static func fill(_ rect: NSRect) { NSRectFill(rect) }
    public static func stroke(_ rect: NSRect) { NSBezierPath(rect: rect).stroke() }
    public static func strokeLine(from a: NSPoint, to b: NSPoint) {
        let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.stroke()
    }
    public static func clip(_ rect: NSRect) { NSRectClip(rect) }
}

extension CGPathOp {
    func applying(_ t: CGAffineTransform) -> CGPathOp {
        switch self {
        case let .move(p): .move(p.applying(t))
        case let .line(p): .line(p.applying(t))
        case let .quad(c, p): .quad(c.applying(t), p.applying(t))
        case let .cubic(a, b, p): .cubic(a.applying(t), b.applying(t), p.applying(t))
        case .close: .close
        }
    }
}

extension AffineTransform {
    /// Applies the transform to the current context (`NSAffineTransform.concat()`).
    @preconcurrency @MainActor public func concat() {
        NSGraphicsContext.current?.cgContext.concatenate(CGAffineTransform(a: m11, b: m12, c: m21, d: m22, tx: tX, ty: tY))
    }
    @preconcurrency @MainActor public func set() { concat() }
}

// MARK: NSGradient

@preconcurrency @MainActor
open class NSGradient: NSObject {
    let gradient: CGGradient
    public let numberOfColorStops: Int
    public convenience init?(starting a: NSColor, ending b: NSColor) { self.init(colors: [a, b]) }
    public convenience init?(colors: [NSColor]) {
        guard !colors.isEmpty else { return nil }
        let locs = colors.count == 1 ? [CGFloat(0)] : (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
        self.init(colors: colors, atLocations: locs, colorSpace: .sRGB)
    }
    public init?(colors: [NSColor], atLocations locations: UnsafePointer<CGFloat>?, colorSpace: NSColorSpace) {
        guard !colors.isEmpty else { return nil }
        let locs = locations.map { l in (0..<colors.count).map { l[$0] } } ?? (0..<colors.count).map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        gradient = CGGradient(stops: zip(colors, locs).map { (color: $0.0.cgColor.rgba, location: $0.1) })
        numberOfColorStops = colors.count
        super.init()
    }
    public convenience init?(colors: [NSColor], atLocations locations: [CGFloat], colorSpace: NSColorSpace) {
        let locs = locations
        self.init(colors: colors, atLocations: locs.withUnsafeBufferPointer { $0.baseAddress }, colorSpace: colorSpace)
    }
    public convenience init?(colorsAndLocations pairs: (NSColor, CGFloat)...) {
        self.init(colors: pairs.map(\.0), atLocations: pairs.map(\.1), colorSpace: .sRGB)
    }
    public struct DrawingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let drawsBeforeStartingLocation = DrawingOptions(rawValue: 1)
        public static let drawsAfterEndingLocation = DrawingOptions(rawValue: 2)
    }
    private func cgOptions(_ o: DrawingOptions) -> CGGradientDrawingOptions {
        var r: CGGradientDrawingOptions = []
        if o.contains(.drawsBeforeStartingLocation) { r.insert(.drawsBeforeStartLocation) }
        if o.contains(.drawsAfterEndingLocation) { r.insert(.drawsAfterEndLocation) }
        return r
    }
    open func draw(from start: NSPoint, to end: NSPoint, options: DrawingOptions) {
        NSGraphicsContext.current?.cgContext.drawLinearGradient(gradient, start: start, end: end, options: cgOptions(options))
    }
    /// Fills `rect` along `angle` degrees (0: left to right, 90: bottom to top).
    open func draw(in rect: NSRect, angle: CGFloat) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.saveGState()
        c.clip(to: rect)
        drawLinear(in: rect, angle: angle, c)
        c.restoreGState()
    }
    open func draw(in path: NSBezierPath, angle: CGFloat) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.saveGState()
        c.addPath(path.path)
        c.clip(using: path.windingRule == .evenOdd ? .evenOdd : .winding)
        drawLinear(in: path.bounds, angle: angle, c)
        c.restoreGState()
    }
    private func drawLinear(in rect: NSRect, angle: CGFloat, _ c: CGContext) {
        let a = angle * .pi / 180
        let dx = cos(a), dy = sin(a)
        // Endpoints so the gradient spans the rect's projection on the axis.
        let half = (abs(dx) * rect.width + abs(dy) * rect.height) / 2
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        c.drawLinearGradient(gradient, start: CGPoint(x: mid.x - dx * half, y: mid.y - dy * half),
                             end: CGPoint(x: mid.x + dx * half, y: mid.y + dy * half), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    open func draw(fromCenter c0: NSPoint, radius r0: CGFloat, toCenter c1: NSPoint, radius r1: CGFloat, options: DrawingOptions) {
        NSGraphicsContext.current?.cgContext.drawRadialGradient(gradient, startCenter: c0, startRadius: r0, endCenter: c1, endRadius: r1, options: cgOptions(options))
    }
    open func draw(in rect: NSRect, relativeCenterPosition p: NSPoint) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        let center = CGPoint(x: rect.midX + p.x * rect.width / 2, y: rect.midY + p.y * rect.height / 2)
        let r = ((rect.width / 2 * (1 + abs(p.x))) * (rect.width / 2 * (1 + abs(p.x))) + (rect.height / 2 * (1 + abs(p.y))) * (rect.height / 2 * (1 + abs(p.y)))).squareRoot()
        c.saveGState(); c.clip(to: rect)
        c.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [.drawsAfterEndLocation])
        c.restoreGState()
    }
    open func draw(in path: NSBezierPath, relativeCenterPosition p: NSPoint) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.saveGState(); c.addPath(path.path); c.clip()
        draw(in: path.bounds, relativeCenterPosition: p)
        c.restoreGState()
    }
    open func interpolatedColor(atLocation l: CGFloat) -> NSColor {
        let c = gradient.color(at: l)
        return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
    }
    open func getColor(_ color: UnsafeMutablePointer<NSColor>?, location: UnsafeMutablePointer<CGFloat>?, at index: Int) {
        let c = gradient.colors[index]
        color?.pointee = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        location?.pointee = gradient.locations[index]
    }
}

// MARK: NSShadow

open class NSShadow: NSObject, @unchecked Sendable {
    open var shadowOffset: NSSize = .zero
    open var shadowBlurRadius: CGFloat = 0
    open var shadowColor: NSColor? = NSColor.black.withAlphaComponent(1.0 / 3)
    public override init() { super.init() }
    /// Makes this the current context's shadow.
    @preconcurrency @MainActor open func set() {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.setShadow(offset: shadowOffset, blur: shadowBlurRadius, color: shadowColor?.cgColor)
    }
}

// MARK: Text attributes

extension NSAttributedString.Key {
    public static let font = NSAttributedString.Key("NSFont")
    public static let foregroundColor = NSAttributedString.Key("NSColor")
    public static let backgroundColor = NSAttributedString.Key("NSBackgroundColor")
    public static let paragraphStyle = NSAttributedString.Key("NSParagraphStyle")
    public static let underlineStyle = NSAttributedString.Key("NSUnderline")
    public static let underlineColor = NSAttributedString.Key("NSUnderlineColor")
    public static let strikethroughStyle = NSAttributedString.Key("NSStrikethrough")
    public static let strikethroughColor = NSAttributedString.Key("NSStrikethroughColor")
    public static let kern = NSAttributedString.Key("NSKern")
    public static let tracking = NSAttributedString.Key("NSTracking")
    public static let ligature = NSAttributedString.Key("NSLigature")
    public static let baselineOffset = NSAttributedString.Key("NSBaselineOffset")
    public static let shadow = NSAttributedString.Key("NSShadow")
    public static let link = NSAttributedString.Key("NSLink")
    public static let attachment = NSAttributedString.Key("NSAttachment")
    public static let obliqueness = NSAttributedString.Key("NSObliqueness")
    public static let expansion = NSAttributedString.Key("NSExpansion")
    public static let strokeColor = NSAttributedString.Key("NSStrokeColor")
    public static let strokeWidth = NSAttributedString.Key("NSStrokeWidth")
    public static let superscript = NSAttributedString.Key("NSSuperScript")
    public static let cursor = NSAttributedString.Key("NSCursor")
    public static let toolTip = NSAttributedString.Key("NSToolTip")
    public static let markedClauseSegment = NSAttributedString.Key("NSMarkedClauseSegment")
    public static let spellingState = NSAttributedString.Key("NSSpellingState")
    public static let textEffect = NSAttributedString.Key("NSTextEffect")
    public static let verticalGlyphForm = NSAttributedString.Key("CTVerticalForms")
    public static let writingDirection = NSAttributedString.Key("NSWritingDirection")
}

public enum NSTextAlignment: Int, Sendable { case left = 0, right = 1, center = 2, justified = 3, natural = 4 }
public enum NSLineBreakMode: UInt, Sendable { case byWordWrapping = 0, byCharWrapping, byClipping, byTruncatingHead, byTruncatingTail, byTruncatingMiddle }
public enum NSWritingDirection: Int, Sendable { case natural = -1, leftToRight = 0, rightToLeft = 1 }

public struct NSUnderlineStyle: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let single = NSUnderlineStyle(rawValue: 1)
    public static let thick = NSUnderlineStyle(rawValue: 2)
    public static let double = NSUnderlineStyle(rawValue: 9)
    public static let patternDot = NSUnderlineStyle(rawValue: 0x100)
    public static let patternDash = NSUnderlineStyle(rawValue: 0x200)
    public static let byWord = NSUnderlineStyle(rawValue: 0x8000)
}

open class NSParagraphStyle: NSObject, NSCopying, NSMutableCopying, @unchecked Sendable {
    public static let `default` = NSParagraphStyle()
    open internal(set) var alignment: NSTextAlignment = .natural
    open internal(set) var lineBreakMode: NSLineBreakMode = .byWordWrapping
    open internal(set) var lineSpacing: CGFloat = 0
    open internal(set) var paragraphSpacing: CGFloat = 0
    open internal(set) var paragraphSpacingBefore: CGFloat = 0
    open internal(set) var headIndent: CGFloat = 0
    open internal(set) var tailIndent: CGFloat = 0
    open internal(set) var firstLineHeadIndent: CGFloat = 0
    open internal(set) var minimumLineHeight: CGFloat = 0
    open internal(set) var maximumLineHeight: CGFloat = 0
    open internal(set) var lineHeightMultiple: CGFloat = 0
    open internal(set) var baseWritingDirection: NSWritingDirection = .natural
    open internal(set) var hyphenationFactor: Float = 0
    open internal(set) var allowsDefaultTighteningForTruncation = false
    open internal(set) var defaultTabInterval: CGFloat = 0
    open internal(set) var tabStops: [NSTextTab] = []
    public override init() { super.init() }
    public static func defaultWritingDirection(forLanguage: String?) -> NSWritingDirection { .leftToRight }
    func copyValues(to p: NSParagraphStyle) {
        p.alignment = alignment; p.lineBreakMode = lineBreakMode; p.lineSpacing = lineSpacing; p.paragraphSpacing = paragraphSpacing
        p.paragraphSpacingBefore = paragraphSpacingBefore; p.headIndent = headIndent; p.tailIndent = tailIndent
        p.firstLineHeadIndent = firstLineHeadIndent; p.minimumLineHeight = minimumLineHeight; p.maximumLineHeight = maximumLineHeight
        p.lineHeightMultiple = lineHeightMultiple; p.baseWritingDirection = baseWritingDirection
        p.hyphenationFactor = hyphenationFactor; p.defaultTabInterval = defaultTabInterval; p.tabStops = tabStops
        p.allowsDefaultTighteningForTruncation = allowsDefaultTighteningForTruncation
    }
    /// The values that make two styles equal.
    private var values: [Double] {
        [Double(alignment.rawValue), Double(lineBreakMode.rawValue), lineSpacing, paragraphSpacing, paragraphSpacingBefore, headIndent, tailIndent,
         firstLineHeadIndent, minimumLineHeight, maximumLineHeight, lineHeightMultiple, Double(baseWritingDirection.rawValue),
         Double(hyphenationFactor), defaultTabInterval].map { Double($0) }
    }
    open override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? NSParagraphStyle else { return false }
        return o === self || (o.values == values && o.tabStops.map(\.location) == tabStops.map(\.location))
    }
    open override var hash: Int { values.hashValue }
    open func copy(with zone: NSZone? = nil) -> Any { let p = NSParagraphStyle(); copyValues(to: p); return p }
    open func mutableCopy(with zone: NSZone? = nil) -> Any { let p = NSMutableParagraphStyle(); copyValues(to: p); return p }
}

open class NSMutableParagraphStyle: NSParagraphStyle, @unchecked Sendable {
    open override var alignment: NSTextAlignment { get { super.alignment } set { super.alignment = newValue } }
    open override var lineBreakMode: NSLineBreakMode { get { super.lineBreakMode } set { super.lineBreakMode = newValue } }
    open override var lineSpacing: CGFloat { get { super.lineSpacing } set { super.lineSpacing = newValue } }
    open override var paragraphSpacing: CGFloat { get { super.paragraphSpacing } set { super.paragraphSpacing = newValue } }
    open override var paragraphSpacingBefore: CGFloat { get { super.paragraphSpacingBefore } set { super.paragraphSpacingBefore = newValue } }
    open override var headIndent: CGFloat { get { super.headIndent } set { super.headIndent = newValue } }
    open override var tailIndent: CGFloat { get { super.tailIndent } set { super.tailIndent = newValue } }
    open override var firstLineHeadIndent: CGFloat { get { super.firstLineHeadIndent } set { super.firstLineHeadIndent = newValue } }
    open override var minimumLineHeight: CGFloat { get { super.minimumLineHeight } set { super.minimumLineHeight = newValue } }
    open override var maximumLineHeight: CGFloat { get { super.maximumLineHeight } set { super.maximumLineHeight = newValue } }
    open override var lineHeightMultiple: CGFloat { get { super.lineHeightMultiple } set { super.lineHeightMultiple = newValue } }
    open override var baseWritingDirection: NSWritingDirection { get { super.baseWritingDirection } set { super.baseWritingDirection = newValue } }
    open override var hyphenationFactor: Float { get { super.hyphenationFactor } set { super.hyphenationFactor = newValue } }
    open override var allowsDefaultTighteningForTruncation: Bool { get { super.allowsDefaultTighteningForTruncation } set { super.allowsDefaultTighteningForTruncation = newValue } }
    open override var defaultTabInterval: CGFloat { get { super.defaultTabInterval } set { super.defaultTabInterval = newValue } }
    open override var tabStops: [NSTextTab] { get { super.tabStops } set { super.tabStops = newValue } }
    open func addTabStop(_ tab: NSTextTab) { tabStops.append(tab); tabStops.sort { $0.location < $1.location } }
    open func removeTabStop(_ tab: NSTextTab) { tabStops.removeAll { $0 === tab } }
    open func setParagraphStyle(_ p: NSParagraphStyle) { p.copyValues(to: self) }
}

extension NSString {
    public struct DrawingOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let usesLineFragmentOrigin = DrawingOptions(rawValue: 1)
        public static let usesFontLeading = DrawingOptions(rawValue: 2)
        public static let usesDeviceMetrics = DrawingOptions(rawValue: 8)
        public static let truncatesLastVisibleLine = DrawingOptions(rawValue: 32)
    }
}

// MARK: String drawing

@MainActor enum TextDrawing {
    static func runs(_ string: String, _ attrs: [NSAttributedString.Key: Any]?) -> CGTextRun {
        let font = (attrs?[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let color = (attrs?[.foregroundColor] as? NSColor) ?? NSColor.textColor
        let spec = font.spec
        var r = CGTextRun(string: string, family: spec.family, size: spec.size, weight: spec.weight.rawValue, italic: spec.italic,
                          monospaced: spec.design == .monospaced, color: color.cgColor.rgba)
        if let bg = attrs?[.backgroundColor] as? NSColor { r.backgroundColor = bg.cgColor.rgba }
        if let u = attrs?[.underlineStyle] { r.underline = ((u as? Int) ?? (u as? NSUnderlineStyle)?.rawValue ?? (u as? NSNumber)?.intValue ?? 0) != 0 }
        if let s = attrs?[.strikethroughStyle] { r.strikethrough = ((s as? Int) ?? (s as? NSUnderlineStyle)?.rawValue ?? (s as? NSNumber)?.intValue ?? 0) != 0 }
        if let k = attrs?[.kern] { r.kern = (k as? CGFloat) ?? CGFloat((k as? Double) ?? (k as? NSNumber)?.doubleValue ?? 0) }
        if let b = attrs?[.baselineOffset] { r.baselineOffset = (b as? CGFloat) ?? CGFloat((b as? Double) ?? (b as? NSNumber)?.doubleValue ?? 0) }
        return r
    }

    static func layout(_ runs: [CGTextRun], paragraph: NSParagraphStyle?, width: CGFloat?, height: CGFloat?) -> CGTextLayout {
        var l = CGTextLayout(runs: runs, width: width, height: height)
        if let p = paragraph {
            l.alignment = CGTextLayout.Alignment(rawValue: p.alignment.rawValue == 1 ? 2 : p.alignment.rawValue == 2 ? 1 : p.alignment.rawValue) ?? .natural
            l.lineBreak = CGTextLayout.LineBreak(rawValue: Int(p.lineBreakMode.rawValue)) ?? .wordWrap
            l.lineSpacing = p.lineSpacing
        }
        return l
    }

    static func layout(_ s: NSAttributedString, width: CGFloat?, height: CGFloat?) -> CGTextLayout {
        var runs: [CGTextRun] = []
        var para: NSParagraphStyle?
        let ns = s.string as NSString
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length), options: []) { attrs, range, _ in
            runs.append(Self.runs(ns.substring(with: range), attrs))
            if para == nil { para = attrs[.paragraphStyle] as? NSParagraphStyle }
        }
        return layout(runs, paragraph: para, width: width, height: height)
    }

    static func measure(_ l: CGTextLayout) -> CGSize {
        if let vs = Runway.backend as? ViewSystemBackend { return vs.measureText(l) }
        return HeadlessBackend().measureText(l)
    }

    /// Draws at `point`: the text's top-left in a flipped context, its
    /// bottom-left otherwise (AppKit's `draw(at:)`).
    static func draw(_ l: CGTextLayout, at point: NSPoint) {
        guard let gc = NSGraphicsContext.current else { return }
        let size = measure(l)
        let origin = gc.isFlipped ? point : CGPoint(x: point.x, y: point.y + size.height)
        gc.cgContext.drawText(l, at: origin, flipped: gc.isFlipped)
    }
    /// Draws in `rect`, wrapping to its width and clipped to its height.
    static func draw(_ l: CGTextLayout, in rect: NSRect) {
        guard let gc = NSGraphicsContext.current else { return }
        var l = l
        l.width = rect.width
        l.height = rect.height
        let origin = gc.isFlipped ? rect.origin : CGPoint(x: rect.minX, y: rect.maxY)
        gc.cgContext.drawText(l, at: origin, flipped: gc.isFlipped)
    }
}

extension NSString {
    /// The text's size drawn with `attrs` (measured on the main thread;
    /// callable from any, as AppKit's string measuring is).
    public func size(withAttributes attrs: [NSAttributedString.Key: Any]? = nil) -> NSSize {
        let s = self as String
        let a = UncheckedAttributes(attrs)
        return onMainThread {
            TextDrawing.measure(TextDrawing.layout([TextDrawing.runs(s, a.value)], paragraph: a.value?[.paragraphStyle] as? NSParagraphStyle, width: nil, height: nil))
        }
    }
    @preconcurrency @MainActor public func draw(at point: NSPoint, withAttributes attrs: [NSAttributedString.Key: Any]? = nil) {
        TextDrawing.draw(TextDrawing.layout([TextDrawing.runs(self as String, attrs)], paragraph: attrs?[.paragraphStyle] as? NSParagraphStyle, width: nil, height: nil), at: point)
    }
    @preconcurrency @MainActor public func draw(in rect: NSRect, withAttributes attrs: [NSAttributedString.Key: Any]? = nil) {
        TextDrawing.draw(TextDrawing.layout([TextDrawing.runs(self as String, attrs)], paragraph: attrs?[.paragraphStyle] as? NSParagraphStyle, width: rect.width, height: rect.height), in: rect)
    }
    @preconcurrency @MainActor public func draw(with rect: NSRect, options: NSString.DrawingOptions = [], attributes: [NSAttributedString.Key: Any]? = nil, context: NSStringDrawingContext? = nil) {
        draw(in: rect, withAttributes: attributes)
    }
    public func boundingRect(with size: NSSize, options: NSString.DrawingOptions = [], attributes: [NSAttributedString.Key: Any]? = nil, context: NSStringDrawingContext? = nil) -> NSRect {
        let w: CGFloat? = options.contains(.usesLineFragmentOrigin) && size.width > 0 && size.width < 1e7 ? size.width : nil
        let str = self as String
        let a = UncheckedAttributes(attributes)
        let s = onMainThread {
            TextDrawing.measure(TextDrawing.layout([TextDrawing.runs(str, a.value)], paragraph: a.value?[.paragraphStyle] as? NSParagraphStyle, width: w, height: nil))
        }
        return CGRect(origin: .zero, size: s)
    }
}

extension StringProtocol {
    public func size(withAttributes attrs: [NSAttributedString.Key: Any]? = nil) -> NSSize { (String(self) as NSString).size(withAttributes: attrs) }
    @preconcurrency @MainActor public func draw(at point: NSPoint, withAttributes attrs: [NSAttributedString.Key: Any]? = nil) { (String(self) as NSString).draw(at: point, withAttributes: attrs) }
    @preconcurrency @MainActor public func draw(in rect: NSRect, withAttributes attrs: [NSAttributedString.Key: Any]? = nil) { (String(self) as NSString).draw(in: rect, withAttributes: attrs) }
    @preconcurrency @MainActor public func draw(with rect: NSRect, options: NSString.DrawingOptions = [], attributes: [NSAttributedString.Key: Any]? = nil, context: NSStringDrawingContext? = nil) {
        (String(self) as NSString).draw(in: rect, withAttributes: attributes)
    }
    public func boundingRect(with size: NSSize, options: NSString.DrawingOptions = [], attributes: [NSAttributedString.Key: Any]? = nil, context: NSStringDrawingContext? = nil) -> NSRect {
        (String(self) as NSString).boundingRect(with: size, options: options, attributes: attributes, context: context)
    }
}

extension NSAttributedString {
    @preconcurrency @MainActor public func size() -> NSSize { TextDrawing.measure(TextDrawing.layout(self, width: nil, height: nil)) }
    @preconcurrency @MainActor public func draw(at point: NSPoint) { TextDrawing.draw(TextDrawing.layout(self, width: nil, height: nil), at: point) }
    @preconcurrency @MainActor public func draw(in rect: NSRect) { TextDrawing.draw(TextDrawing.layout(self, width: rect.width, height: rect.height), in: rect) }
    @preconcurrency @MainActor public func draw(with rect: NSRect, options: NSString.DrawingOptions = [], context: NSStringDrawingContext? = nil) { draw(in: rect) }
    @preconcurrency @MainActor public func boundingRect(with size: NSSize, options: NSString.DrawingOptions = [], context: NSStringDrawingContext? = nil) -> NSRect {
        let w: CGFloat? = options.contains(.usesLineFragmentOrigin) && size.width > 0 && size.width < 1e7 ? size.width : nil
        return CGRect(origin: .zero, size: TextDrawing.measure(TextDrawing.layout(self, width: w, height: nil)))
    }
}

open class NSStringDrawingContext: NSObject {
    open var minimumScaleFactor: CGFloat = 0
    open private(set) var actualScaleFactor: CGFloat = 1
    open private(set) var totalBounds: NSRect = .zero
    public override init() { super.init() }
}

// MARK: Images

extension NSImage {
    /// The image's pixels, decoded once (files through ImageIO-free loaders
    /// aren't available here: pixels and CGImage-backed images draw).
    @MainActor var drawableCGImage: CGImage? { decoded }

    /// Draws the image in `rect` of the current context, upright in flipped
    /// and unflipped views alike.
    @preconcurrency @MainActor public func draw(in rect: NSRect) {
        draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    @preconcurrency @MainActor public func draw(in rect: NSRect, from src: NSRect, operation op: NSCompositingOperation, fraction: CGFloat) {
        draw(in: rect, from: src, operation: op, fraction: fraction, respectFlipped: false, hints: nil)
    }
    @preconcurrency @MainActor public func draw(in rect: NSRect, from src: NSRect, operation op: NSCompositingOperation, fraction: CGFloat, respectFlipped: Bool, hints: [NSImageRep.HintKey: Any]?) {
        guard let gc = NSGraphicsContext.current, var img = drawableCGImage else {
            if case let .symbol(name) = source { drawSymbolPlaceholder(name, in: rect) }
            return
        }
        if src != .zero, src.width > 0, src.height > 0 {
            // `from` is in image points, bottom-left origin.
            let sx = CGFloat(img.width) / max(size.width, 1), sy = CGFloat(img.height) / max(size.height, 1)
            let crop = CGRect(x: src.minX * sx, y: CGFloat(img.height) - src.maxY * sy, width: src.width * sx, height: src.height * sy)
            if let c = img.cropping(to: crop) { img = c }
        }
        let c = gc.cgContext
        c.saveGState()
        c.setAlpha(fraction)
        c.setBlendMode(op.blendMode)
        if gc.isFlipped && respectFlipped {
            c.translateBy(x: 0, y: rect.minY + rect.maxY)
            c.scaleBy(x: 1, y: -1)
        }
        c.draw(img, in: rect)
        c.restoreGState()
    }
    @preconcurrency @MainActor public func draw(at point: NSPoint, from src: NSRect, operation op: NSCompositingOperation, fraction: CGFloat) {
        let s = src == .zero ? size : src.size
        draw(in: CGRect(origin: point, size: s), from: src, operation: op, fraction: fraction)
    }
    @preconcurrency @MainActor public func draw(in rect: NSRect, from src: NSRect, operation op: NSCompositingOperation, fraction: CGFloat, respectFlipped: Bool) {
        draw(in: rect, from: src, operation: op, fraction: fraction, respectFlipped: respectFlipped, hints: nil)
    }
    @MainActor private func drawSymbolPlaceholder(_ name: String, in rect: NSRect) {}

    /// An image drawn by a handler (`NSImage(size:flipped:drawingHandler:)`),
    /// rasterized in software at its size.
    public convenience init(size: NSSize, flipped: Bool, drawingHandler: @escaping (NSRect) -> Bool) {
        let w = max(1, Int(size.width.rounded(.up))), h = max(1, Int(size.height.rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            self.init(size: size); return
        }
        if flipped { ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) }
        MainActor.assumeIsolated {
            let gc = NSGraphicsContext(cgContext: ctx, flipped: flipped)
            gc.perform { _ = drawingHandler(CGRect(origin: .zero, size: size)) }
        }
        if let img = ctx.makeImage() { self.init(cgImage: img, size: size) } else { self.init(size: size) }
    }
}

open class NSImageRep: NSObject {
    public override init() { super.init() }
    public struct HintKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let interpolation = HintKey(rawValue: "NSImageHintInterpolation")
        public static let ctm = HintKey(rawValue: "NSImageHintCTM")
    }
}

/// Attribute dictionaries carried to the main thread for measuring.
struct UncheckedAttributes: @unchecked Sendable {
    let value: [NSAttributedString.Key: Any]?
    init(_ v: [NSAttributedString.Key: Any]?) { value = v }
}
