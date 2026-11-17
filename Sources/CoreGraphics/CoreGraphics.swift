// CoreGraphics for Linux and Windows. Geometry (CGFloat, CGPoint, CGSize,
// CGRect) already comes from swift-corelibs-foundation; this module adds
// what app code reaches for beyond it:
//
//   CoreGraphics.swift  CGAffineTransform
//   CGColor.swift       colours and colour spaces (sRGB, linear, gray…)
//   CGPath.swift        paths, gradients
//   CGContext.swift     bitmap contexts: a software rasterizer (anti-aliased
//                       fills and strokes, transforms, clipping, shadows,
//                       transparency layers, images, gradients) over
//                       RGBA/BGRA/ARGB 8-bit, alpha-only, gray, half and full
//                       float pixels; CGImage
//   CGDisplay.swift     display and window ids, display modes, events and
//                       screen-capture access, PDF documents (none here)

@_exported import Foundation
@_exported import RunwayFoundation

// MARK: Affine transforms

public struct CGAffineTransform: Equatable, Sendable {
    public var a, b, c, d, tx, ty: CGFloat
    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        (self.a, self.b, self.c, self.d, self.tx, self.ty) = (a, b, c, d, tx, ty)
    }
    public init(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat, _ tx: CGFloat, _ ty: CGFloat) {
        self.init(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
    public init() { self = .identity }
    public static let identity = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    public init(translationX x: CGFloat, y: CGFloat) { self.init(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y) }
    public init(scaleX sx: CGFloat, y sy: CGFloat) { self.init(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0) }
    public init(rotationAngle angle: CGFloat) {
        let (s, c) = (CGFloat(sin(Double(angle))), CGFloat(cos(Double(angle))))
        self.init(a: c, b: s, c: -s, d: c, tx: 0, ty: 0)
    }
    public var isIdentity: Bool { self == .identity }
    /// `self` then `t`.
    public func concatenating(_ t: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: a * t.a + b * t.c, b: a * t.b + b * t.d,
                          c: c * t.a + d * t.c, d: c * t.b + d * t.d,
                          tx: tx * t.a + ty * t.c + t.tx, ty: tx * t.b + ty * t.d + t.ty)
    }
    public func translatedBy(x: CGFloat, y: CGFloat) -> CGAffineTransform { CGAffineTransform(translationX: x, y: y).concatenating(self) }
    public func scaledBy(x: CGFloat, y: CGFloat) -> CGAffineTransform { CGAffineTransform(scaleX: x, y: y).concatenating(self) }
    public func rotated(by angle: CGFloat) -> CGAffineTransform { CGAffineTransform(rotationAngle: angle).concatenating(self) }
    public func inverted() -> CGAffineTransform {
        let det = a * d - b * c
        guard det != 0 else { return self }
        return CGAffineTransform(a: d / det, b: -b / det, c: -c / det, d: a / det,
                                 tx: (c * ty - d * tx) / det, ty: (b * tx - a * ty) / det)
    }
}

extension CGPoint {
    public func applying(_ t: CGAffineTransform) -> CGPoint {
        CGPoint(x: t.a * x + t.c * y + t.tx, y: t.b * x + t.d * y + t.ty)
    }
}

extension CGSize {
    public func applying(_ t: CGAffineTransform) -> CGSize {
        CGSize(width: t.a * width + t.c * height, height: t.b * width + t.d * height)
    }
}

extension CGRect {
    public func applying(_ t: CGAffineTransform) -> CGRect {
        if t.isIdentity { return self }
        let pts = [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)].map { $0.applying(t) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}


// MARK: CGVector

/// Core Graphics' vector (not in swift-corelibs-foundation).
public struct CGVector: Hashable, Sendable, Codable {
    public var dx: CGFloat
    public var dy: CGFloat
    public init() { dx = 0; dy = 0 }
    public init(dx: CGFloat, dy: CGFloat) { self.dx = dx; self.dy = dy }
    public init(dx: Double, dy: Double) { self.dx = CGFloat(dx); self.dy = CGFloat(dy) }
    public init(dx: Int, dy: Int) { self.dx = CGFloat(dx); self.dy = CGFloat(dy) }
    public static var zero: CGVector { CGVector(dx: 0, dy: 0) }
}
