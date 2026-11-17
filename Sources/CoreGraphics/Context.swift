// CGContext: Core Graphics' drawing API over a pluggable target.
//
//   CGContext(data:width:height:…)       a bitmap (any layout Bitmap.swift's
//                                         rasterizer handles), rasterized in
//                                         software (origin bottom-left, as CG)
//   CGContext(recordingSize:)             records a CGDisplayList
//   CGContext(target:size:baseTransform:) a native surface (Cairo…)
//
// The context keeps Core Graphics' graphics state (CTM, colours, line
// style, alpha, blend mode, shadow, clip via save/restore) and the current
// path; each drawing call becomes one CGDisplayOp carrying that state.
// Paths are kept in user space and drawn with the CTM current when they're
// painted (Core Graphics transforms points as they're added; the two only
// differ if the CTM changes while a path is being built).

import Foundation

public final class CGContext {
    // Bitmap geometry (zero for recording and native targets).
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let data: UnsafeMutableRawPointer?
    private let owned: Bool
    public let alphaInfo: CGImageAlphaInfo
    public let bitsPerComponent: Int
    public let bitsPerPixel: Int
    public let bitmapInfo: CGBitmapInfo
    public let colorSpace: CGColorSpace?

    private var target: CGRenderTarget?
    private let recorder: Recorder?
    private var raster: SurfaceRaster?
    /// Transparency layers open on a non-bitmap target (drawn directly).
    private var groupDepth = 0

    struct GState {
        var ctm: CGAffineTransform
        var fill: [CGFloat] = [0, 0, 0, 1]
        var stroke: [CGFloat] = [0, 0, 0, 1]
        var style = CGStrokeStyle()
        var alpha: CGFloat = 1
        var blend: CGBlendMode = .normal
        var antialias = true
        var shadow: CGShadowSpec?
        var interpolation: CGInterpolationQuality = .default
        var textMatrix: CGAffineTransform = .identity
        var textPosition: CGPoint = .zero
        var fontSize: CGFloat = 12
        var clipBounds: CGRect = .infinite
    }
    private var gstate: GState
    private var stack: [GState] = []
    private let cur = CGMutablePath()
    /// The transform from the context's user space at creation to device space.
    public let baseTransform: CGAffineTransform

    // MARK: Creating

    /// A bitmap context; `data` nil allocates (and frees) the buffer.
    public init?(data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int,
                 space: CGColorSpace, bitmapInfo: UInt32) {
        guard width > 0, height > 0,
              let layout = PixelLayout(bitsPerComponent: bitsPerComponent, components: space.numberOfComponents, info: bitmapInfo) else { return nil }
        let minRow = width * layout.bytesPerPixel
        guard bytesPerRow == 0 || bytesPerRow >= minRow else { return nil }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow >= minRow ? bytesPerRow : (minRow + 15) / 16 * 16
        self.bitsPerComponent = bitsPerComponent
        bitsPerPixel = layout.bytesPerPixel * 8
        self.bitmapInfo = CGBitmapInfo(rawValue: bitmapInfo)
        colorSpace = space
        alphaInfo = CGImageAlphaInfo(rawValue: bitmapInfo & CGBitmapInfo.alphaInfoMask.rawValue) ?? .premultipliedLast
        if let data {
            self.data = data
            owned = false
        } else {
            let p = UnsafeMutableRawPointer.allocate(byteCount: self.bytesPerRow * height, alignment: 16)
            p.initializeMemory(as: UInt8.self, repeating: 0, count: self.bytesPerRow * height)
            self.data = p
            owned = true
        }
        // Device space is top-left, y-down; CG user space is bottom-left.
        baseTransform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        gstate = GState(ctm: .identity)
        recorder = nil
        let r = SurfaceRaster(surface: Surface(base: self.data!, width: width, height: height, rowBytes: self.bytesPerRow, layout: layout), linear: space.isLinear)
        raster = r
        target = r
    }
    public convenience init?(data: UnsafeMutableRawPointer?, width: Int, height: Int, bitsPerComponent: Int, bytesPerRow: Int,
                             space: CGColorSpace, bitmapInfo: CGBitmapInfo) {
        self.init(data: data, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: space,
                  bitmapInfo: bitmapInfo.rawValue)
    }

    /// A context that records its drawing (`displayList`). `baseTransform`
    /// maps its initial user space to the list's device space.
    public init(recordingSize size: CGSize, baseTransform: CGAffineTransform = .identity) {
        width = Int(size.width); height = Int(size.height); bytesPerRow = 0
        data = nil; owned = false; alphaInfo = .premultipliedLast
        bitsPerComponent = 8; bitsPerPixel = 32; bitmapInfo = []; colorSpace = CGColorSpace()
        self.baseTransform = baseTransform
        gstate = GState(ctm: baseTransform)
        gstate.clipBounds = CGRect(origin: .zero, size: size)
        let r = Recorder()
        recorder = r
        target = r
    }

    /// A context drawing into a native target.
    public init(target: CGRenderTarget, size: CGSize, baseTransform: CGAffineTransform = .identity) {
        width = Int(size.width); height = Int(size.height); bytesPerRow = 0
        data = nil; owned = false; alphaInfo = .premultipliedLast
        bitsPerComponent = 8; bitsPerPixel = 32; bitmapInfo = []; colorSpace = CGColorSpace()
        self.baseTransform = baseTransform
        gstate = GState(ctm: baseTransform)
        gstate.clipBounds = CGRect(origin: .zero, size: size)
        recorder = nil
        self.target = target
    }

    deinit { if owned { data?.deallocate() } }

    final class Recorder: CGRenderTarget {
        var ops: [CGDisplayOp] = []
        func execute(_ op: CGDisplayOp) { ops.append(op) }
    }

    /// What a recording context has drawn so far.
    public var displayList: CGDisplayList { CGDisplayList(recorder?.ops ?? []) }
    public var isRecording: Bool { recorder != nil }

    private func emit(_ op: CGDisplayOp) { target?.execute(op) }

    private var drawState: CGDrawState {
        var s = CGDrawState()
        s.ctm = gstate.ctm
        s.alpha = gstate.alpha
        s.blendMode = gstate.blend
        s.antialias = gstate.antialias
        s.shadow = gstate.shadow
        return s
    }

    // MARK: Graphics state

    public func saveGState() {
        stack.append(gstate)
        emit(.save)
    }
    public func restoreGState() {
        guard let g = stack.popLast() else { return }
        gstate = g
        emit(.restore)
    }

    /// User space to device space (excluding nothing: the full CTM).
    public var ctm: CGAffineTransform { gstate.ctm }
    public var userSpaceToDeviceSpaceTransform: CGAffineTransform { gstate.ctm }
    public func convertToDeviceSpace(_ p: CGPoint) -> CGPoint { p.applying(gstate.ctm) }
    public func convertToUserSpace(_ p: CGPoint) -> CGPoint { p.applying(gstate.ctm.inverted()) }
    public func convertToDeviceSpace(_ r: CGRect) -> CGRect { r.applying(gstate.ctm) }
    public func convertToUserSpace(_ r: CGRect) -> CGRect { r.applying(gstate.ctm.inverted()) }

    public func concatenate(_ t: CGAffineTransform) { gstate.ctm = t.concatenating(gstate.ctm) }
    public func translateBy(x: CGFloat, y: CGFloat) { concatenate(CGAffineTransform(translationX: x, y: y)) }
    public func scaleBy(x: CGFloat, y: CGFloat) { concatenate(CGAffineTransform(scaleX: x, y: y)) }
    public func rotate(by angle: CGFloat) { concatenate(CGAffineTransform(rotationAngle: angle)) }

    public func setFillColor(_ color: CGColor) { gstate.fill = color.rgba }
    public func setStrokeColor(_ color: CGColor) { gstate.stroke = color.rgba }
    public func setFillColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { gstate.fill = [red, green, blue, alpha] }
    public func setStrokeColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) { gstate.stroke = [red, green, blue, alpha] }
    public func setFillColor(gray: CGFloat, alpha: CGFloat) { gstate.fill = [gray, gray, gray, alpha] }
    public func setStrokeColor(gray: CGFloat, alpha: CGFloat) { gstate.stroke = [gray, gray, gray, alpha] }
    /// The current fill and stroke colours (RGBA).
    public var fillColorComponents: [CGFloat] { gstate.fill }
    public var strokeColorComponents: [CGFloat] { gstate.stroke }

    public func setLineWidth(_ w: CGFloat) { gstate.style.lineWidth = w }
    public func setLineCap(_ c: CGLineCap) { gstate.style.lineCap = c }
    public func setLineJoin(_ j: CGLineJoin) { gstate.style.lineJoin = j }
    public func setMiterLimit(_ m: CGFloat) { gstate.style.miterLimit = m }
    public func setLineDash(phase: CGFloat, lengths: [CGFloat]) { gstate.style.dashPhase = phase; gstate.style.dashLengths = lengths }
    public var strokeStyle: CGStrokeStyle { get { gstate.style } set { gstate.style = newValue } }
    public func setAlpha(_ a: CGFloat) { gstate.alpha = max(0, min(1, a)) }
    public var alpha: CGFloat { gstate.alpha }
    public func setBlendMode(_ m: CGBlendMode) { gstate.blend = m }
    public var blendMode: CGBlendMode { gstate.blend }
    public func setShouldAntialias(_ on: Bool) { gstate.antialias = on }
    public func setAllowsAntialiasing(_ on: Bool) {}
    public func setShouldSmoothFonts(_ on: Bool) {}
    public func setAllowsFontSmoothing(_ on: Bool) {}
    public func setFlatness(_ f: CGFloat) {}
    public func setRenderingIntent(_ i: Int32) {}
    public var interpolationQuality: CGInterpolationQuality {
        get { gstate.interpolation }
        set { gstate.interpolation = newValue }
    }
    public func setShadow(offset: CGSize, blur: CGFloat, color: CGColor?) {
        gstate.shadow = color.map { CGShadowSpec(offset: offset, blur: blur, color: $0.rgba) }
    }
    public func setShadow(offset: CGSize, blur: CGFloat) {
        gstate.shadow = CGShadowSpec(offset: offset, blur: blur, color: [0, 0, 0, 1.0 / 3])
    }
    public var textMatrix: CGAffineTransform { get { gstate.textMatrix } set { gstate.textMatrix = newValue } }
    public var textPosition: CGPoint { get { gstate.textPosition } set { gstate.textPosition = newValue } }
    public func setFontSize(_ s: CGFloat) { gstate.fontSize = s }

    // MARK: The current path

    public func beginPath() { cur.removeAll() }
    public func move(to p: CGPoint) { cur.move(to: p) }
    public func addLine(to p: CGPoint) { cur.addLine(to: p) }
    public func addLines(between points: [CGPoint]) { cur.addLines(between: points) }
    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint) { cur.addCurve(to: end, control1: control1, control2: control2) }
    public func addQuadCurve(to end: CGPoint, control: CGPoint) { cur.addQuadCurve(to: end, control: control) }
    public func addRect(_ r: CGRect) { cur.addRect(r) }
    public func addRects(_ rs: [CGRect]) { cur.addRects(rs) }
    public func addEllipse(in r: CGRect) { cur.addEllipse(in: r) }
    public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {
        cur.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: clockwise)
    }
    public func addArc(tangent1End: CGPoint, tangent2End: CGPoint, radius: CGFloat) {
        cur.addArc(tangent1End: tangent1End, tangent2End: tangent2End, radius: radius)
    }
    public func addRelativeArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, delta: CGFloat) {
        cur.addRelativeArc(center: center, radius: radius, startAngle: startAngle, delta: delta)
    }
    public func addPath(_ p: CGPath) { cur.addPath(p) }
    public func closePath() { cur.closeSubpath() }
    public var isPathEmpty: Bool { cur.isEmpty }
    public var currentPointOfPath: CGPoint { cur.currentPoint }
    public var boundingBoxOfPath: CGRect { cur.isEmpty ? .null : cur.boundingBoxOfPath }
    public var path: CGPath? { cur.isEmpty ? nil : cur.copy() }
    public func pathContains(_ point: CGPoint, mode: CGPathDrawingMode) -> Bool {
        cur.contains(point, using: mode == .eoFill || mode == .eoFillStroke ? .evenOdd : .winding)
    }
    /// Replaces the path with the outline of its stroke (approximated by
    /// the stroke's own geometry: the path is kept, stroked when filled).
    public func replacePathWithStrokedPath() {}

    private func takePath() -> CGPath {
        let p = CGPath(ops: cur.ops)
        cur.removeAll()
        return p
    }

    // MARK: Painting

    public func fillPath(using rule: CGPathFillRule = .winding) {
        guard !cur.isEmpty else { return }
        emit(.fill(takePath(), rule, color: gstate.fill, drawState))
    }
    public func eoFillPath() { fillPath(using: .evenOdd) }
    public func strokePath() {
        guard !cur.isEmpty else { return }
        emit(.stroke(takePath(), gstate.style, color: gstate.stroke, drawState))
    }
    public func drawPath(using mode: CGPathDrawingMode) {
        guard !cur.isEmpty else { return }
        let p = takePath()
        switch mode {
        case .fill: emit(.fill(p, .winding, color: gstate.fill, drawState))
        case .eoFill: emit(.fill(p, .evenOdd, color: gstate.fill, drawState))
        case .stroke: emit(.stroke(p, gstate.style, color: gstate.stroke, drawState))
        case .fillStroke:
            emit(.fill(p, .winding, color: gstate.fill, drawState))
            emit(.stroke(p, gstate.style, color: gstate.stroke, drawState))
        case .eoFillStroke:
            emit(.fill(p, .evenOdd, color: gstate.fill, drawState))
            emit(.stroke(p, gstate.style, color: gstate.stroke, drawState))
        }
    }
    public func fill(_ rect: CGRect) {
        let p = CGMutablePath(); p.addRect(rect)
        emit(.fill(p, .winding, color: gstate.fill, drawState))
    }
    public func fill(_ rects: [CGRect]) {
        let p = CGMutablePath(); p.addRects(rects)
        emit(.fill(p, .winding, color: gstate.fill, drawState))
    }
    public func fillEllipse(in rect: CGRect) {
        let p = CGMutablePath(); p.addEllipse(in: rect)
        emit(.fill(p, .winding, color: gstate.fill, drawState))
    }
    public func stroke(_ rect: CGRect) {
        let p = CGMutablePath(); p.addRect(rect)
        emit(.stroke(p, gstate.style, color: gstate.stroke, drawState))
    }
    public func stroke(_ rect: CGRect, width: CGFloat) {
        var s = gstate.style; s.lineWidth = width
        let p = CGMutablePath(); p.addRect(rect)
        emit(.stroke(p, s, color: gstate.stroke, drawState))
    }
    public func strokeEllipse(in rect: CGRect) {
        let p = CGMutablePath(); p.addEllipse(in: rect)
        emit(.stroke(p, gstate.style, color: gstate.stroke, drawState))
    }
    public func strokeLineSegments(between points: [CGPoint]) {
        let p = CGMutablePath()
        var i = 0
        while i + 1 < points.count { p.move(to: points[i]); p.addLine(to: points[i + 1]); i += 2 }
        emit(.stroke(p, gstate.style, color: gstate.stroke, drawState))
    }
    public func clear(_ rect: CGRect) { emit(.clear(rect, ctm: gstate.ctm)) }

    // MARK: Clipping

    public func clip(using rule: CGPathFillRule = .winding) {
        let p = takePath()
        gstate.clipBounds = gstate.clipBounds.intersection(p.boundingBox.applying(gstate.ctm))
        emit(.clip(p, rule, ctm: gstate.ctm))
    }
    public func eoClip() { clip(using: .evenOdd) }
    public func clip(to rect: CGRect) {
        let p = CGMutablePath(); p.addRect(rect)
        gstate.clipBounds = gstate.clipBounds.intersection(rect.applying(gstate.ctm))
        emit(.clip(p, .winding, ctm: gstate.ctm))
    }
    public func clip(to rects: [CGRect]) {
        let p = CGMutablePath(); p.addRects(rects)
        gstate.clipBounds = gstate.clipBounds.intersection(p.boundingBox.applying(gstate.ctm))
        emit(.clip(p, .winding, ctm: gstate.ctm))
    }
    /// The clip's bounds in user space.
    public var boundingBoxOfClipPath: CGRect {
        let b = gstate.clipBounds
        return b.isInfinite ? b : b.applying(gstate.ctm.inverted())
    }

    // MARK: Images and gradients

    public func draw(_ image: CGImage, in rect: CGRect, byTiling: Bool = false) {
        guard !byTiling else {
            let clipB = boundingBoxOfClipPath
            guard rect.width > 0, rect.height > 0, !clipB.isInfinite else {
                emit(.image(image, rect, gstate.interpolation, drawState)); return
            }
            var y = rect.minY + ((clipB.minY - rect.minY) / rect.height).rounded(.down) * rect.height
            while y < clipB.maxY {
                var x = rect.minX + ((clipB.minX - rect.minX) / rect.width).rounded(.down) * rect.width
                while x < clipB.maxX {
                    emit(.image(image, CGRect(x: x, y: y, width: rect.width, height: rect.height), gstate.interpolation, drawState))
                    x += rect.width
                }
                y += rect.height
            }
            return
        }
        emit(.image(image, rect, gstate.interpolation, drawState))
    }

    public func drawLinearGradient(_ g: CGGradient, start: CGPoint, end: CGPoint, options: CGGradientDrawingOptions) {
        emit(.linearGradient(g, start: start, end: end, options, drawState))
    }
    public func drawRadialGradient(_ g: CGGradient, startCenter: CGPoint, startRadius: CGFloat, endCenter: CGPoint, endRadius: CGFloat, options: CGGradientDrawingOptions) {
        emit(.radialGradient(g, startCenter: startCenter, startRadius: startRadius, endCenter: endCenter, endRadius: endRadius, options, drawState))
    }

    /// Runway: text, laid out and drawn by the target (AppKit's string
    /// drawing uses this). See `CGDisplayOp.text`.
    public func drawText(_ layout: CGTextLayout, at origin: CGPoint, flipped: Bool) {
        emit(.text(layout, origin: origin, flipped: flipped, drawState))
    }

    /// Replays a display list through this context's current state (its
    /// CTM is prepended to each op's).
    public func draw(_ list: CGDisplayList) {
        let t = gstate.ctm
        for op in list.ops { emit(op.prepending(t)) }
    }

    // MARK: Transparency layers

    /// Draws into an offscreen layer until `endTransparencyLayer`, which then
    /// paints it with this state's shadow, alpha and blend mode (bitmap
    /// contexts; other targets draw straight through).
    public func beginTransparencyLayer(auxiliaryInfo: CFDictionary?) {
        stack.append(gstate)
        if let raster { raster.beginGroup(drawState) } else { groupDepth += 1 }
        gstate.shadow = nil
        gstate.alpha = 1
        gstate.blend = .normal
    }
    public func beginTransparencyLayer(in rect: CGRect, auxiliaryInfo: CFDictionary?) { beginTransparencyLayer(auxiliaryInfo: auxiliaryInfo) }
    public func endTransparencyLayer() {
        guard let g = stack.popLast() else { return }
        let ctm = gstate.ctm
        gstate = g
        gstate.ctm = ctm
        if let raster { raster.endGroup() } else { groupDepth = max(groupDepth - 1, 0) }
    }

    public func setTextDrawingMode(_ m: CGTextDrawingMode) {}
    public func setCharacterSpacing(_ s: CGFloat) {}
    public func setShouldSubpixelPositionFonts(_ v: Bool) {}
    public func setAllowsFontSubpixelPositioning(_ v: Bool) {}
    public func setFillColorSpace(_ space: CGColorSpace) {}
    public func setStrokeColorSpace(_ space: CGColorSpace) {}
    public func drawPDFPage(_ page: CGPDFPage) {}
    public func clip(to rect: CGRect, mask: CGImage) { clip(to: rect) }
    public func resetClip() {}

    // MARK: Output

    public func flush() {}
    public func synchronize() {}

    public func makeImage() -> CGImage? { raster?.makeImage() }
}

extension CGDisplayOp {
    /// The op with `t` applied after its own transform (moving it into an
    /// outer device space).
    public func prepending(_ t: CGAffineTransform) -> CGDisplayOp {
        if t.isIdentity { return self }
        func st(_ s: CGDrawState) -> CGDrawState { var s = s; s.ctm = s.ctm.concatenating(t); return s }
        switch self {
        case .save, .restore: return self
        case let .clip(p, r, ctm): return .clip(p, r, ctm: ctm.concatenating(t))
        case let .fill(p, r, c, s): return .fill(p, r, color: c, st(s))
        case let .stroke(p, style, c, s): return .stroke(p, style, color: c, st(s))
        case let .clear(r, ctm): return .clear(r, ctm: ctm.concatenating(t))
        case let .image(i, r, q, s): return .image(i, r, q, st(s))
        case let .linearGradient(g, a, b, o, s): return .linearGradient(g, start: a, end: b, o, st(s))
        case let .radialGradient(g, c0, r0, c1, r1, o, s): return .radialGradient(g, startCenter: c0, startRadius: r0, endCenter: c1, endRadius: r1, o, st(s))
        case let .text(l, o, f, s): return .text(l, origin: o, flipped: f, st(s))
        }
    }
}
