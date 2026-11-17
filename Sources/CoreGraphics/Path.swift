// CGPath and CGMutablePath: vector paths as Core Graphics defines them
// (subpaths of lines, quadratic and cubic Béziers; arcs become cubics),
// with bounds, hit testing (winding and even-odd) and transforms.

import Foundation

public enum CGPathElementType: Int32, Sendable {
    case moveToPoint, addLineToPoint, addQuadCurveToPoint, addCurveToPoint, closeSubpath
}

public struct CGPathElement {
    public var type: CGPathElementType
    public var points: UnsafeMutablePointer<CGPoint>
}

public typealias CGPathApplierFunction = (UnsafeMutableRawPointer?, UnsafePointer<CGPathElement>) -> Void

public enum CGPathFillRule: Int, Sendable, Hashable { case winding, evenOdd }
public enum CGPathDrawingMode: Int32, Sendable { case fill, eoFill, stroke, fillStroke, eoFillStroke }
public enum CGLineCap: Int32, Sendable, Hashable { case butt, round, square }
public enum CGLineJoin: Int32, Sendable, Hashable { case miter, round, bevel }

/// One stored path element. Quads are (control, end); cubics (c1, c2, end).
public enum CGPathOp: Hashable, Sendable {
    case move(CGPoint)
    case line(CGPoint)
    case quad(CGPoint, CGPoint)
    case cubic(CGPoint, CGPoint, CGPoint)
    case close

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

extension CGAffineTransform: Hashable {
    public func hash(into h: inout Hasher) { h.combine(a); h.combine(b); h.combine(c); h.combine(d); h.combine(tx); h.combine(ty) }
}

/// An immutable path. `CGMutablePath` builds one.
public class CGPath: Hashable, @unchecked Sendable, CustomStringConvertible {
    public internal(set) var ops: [CGPathOp]

    init(ops: [CGPathOp]) { self.ops = ops }

    public convenience init(rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        let p = CGMutablePath(); p.addRect(rect, transform: transform?.pointee ?? .identity)
        self.init(ops: p.ops)
    }
    public convenience init(ellipseIn rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        let p = CGMutablePath(); p.addEllipse(in: rect, transform: transform?.pointee ?? .identity)
        self.init(ops: p.ops)
    }
    public convenience init(roundedRect rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: UnsafePointer<CGAffineTransform>?) {
        let p = CGMutablePath(); p.addRoundedRect(in: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight, transform: transform?.pointee ?? .identity)
        self.init(ops: p.ops)
    }

    public static func == (l: CGPath, r: CGPath) -> Bool { l === r || l.ops == r.ops }
    public func hash(into h: inout Hasher) { h.combine(ops) }
    public var description: String { "CGPath(\(ops.count) elements)" }

    public var isEmpty: Bool { ops.isEmpty }

    public var currentPoint: CGPoint {
        var start = CGPoint.zero, cur = CGPoint.zero
        for op in ops {
            switch op {
            case let .move(p): start = p; cur = p
            case let .line(p), let .quad(_, p), let .cubic(_, _, p): cur = p
            case .close: cur = start
            }
        }
        return cur
    }

    /// Bounds including control points.
    public var boundingBox: CGRect {
        var r = CGRect.null
        for op in ops {
            switch op {
            case let .move(p), let .line(p): r = r.union(CGRect(origin: p, size: .zero))
            case let .quad(c, p): r = r.union(CGRect(origin: c, size: .zero)).union(CGRect(origin: p, size: .zero))
            case let .cubic(a, b, p):
                r = r.union(CGRect(origin: a, size: .zero)).union(CGRect(origin: b, size: .zero)).union(CGRect(origin: p, size: .zero))
            case .close: break
            }
        }
        return r
    }

    /// Bounds of the curve itself (control points excluded).
    public var boundingBoxOfPath: CGRect {
        var r = CGRect.null
        for poly in flattened(tolerance: 0.05) { for p in poly.points { r = r.union(CGRect(origin: p, size: .zero)) } }
        return r
    }

    public func copy() -> CGPath? { CGPath(ops: ops) }
    public func copy(using transform: UnsafePointer<CGAffineTransform>?) -> CGPath? {
        guard let t = transform?.pointee else { return copy() }
        return CGPath(ops: ops.map { $0.applying(t) })
    }
    public func mutableCopy() -> CGMutablePath? { CGMutablePath(ops: ops) }
    public func mutableCopy(using transform: UnsafePointer<CGAffineTransform>?) -> CGMutablePath? {
        guard let t = transform?.pointee else { return mutableCopy() }
        return CGMutablePath(ops: ops.map { $0.applying(t) })
    }
    public func copy(using transform: CGAffineTransform) -> CGPath { CGPath(ops: ops.map { $0.applying(transform) }) }

    public func isRect(_ rect: UnsafeMutablePointer<CGRect>?) -> Bool {
        guard ops.count >= 4, case let .move(a) = ops[0], case let .line(b) = ops[1], case let .line(c) = ops[2], case let .line(d) = ops[3] else { return false }
        let rest = ops.dropFirst(4)
        guard rest.allSatisfy({ if case .close = $0 { return true }; if case let .line(p) = $0 { return p == a }; return false }) else { return false }
        let axis = (a.y == b.y && b.x == c.x && c.y == d.y && d.x == a.x) || (a.x == b.x && b.y == c.y && c.x == d.x && d.y == a.y)
        guard axis else { return false }
        rect?.pointee = CGRect(x: min(a.x, c.x), y: min(a.y, c.y), width: abs(c.x - a.x), height: abs(c.y - a.y))
        return true
    }

    public func contains(_ point: CGPoint, using rule: CGPathFillRule = .winding, transform: CGAffineTransform = .identity) -> Bool {
        let p = transform.isIdentity ? point : point.applying(transform.inverted())
        var winding = 0
        for poly in flattened(tolerance: 0.1) {
            let pts = poly.points
            guard pts.count > 1 else { continue }
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                if a.y <= p.y {
                    if b.y > p.y, (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) > 0 { winding += 1 }
                } else if b.y <= p.y, (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y) < 0 {
                    winding -= 1
                }
            }
        }
        return rule == .evenOdd ? winding % 2 != 0 : winding != 0
    }

    public func applyWithBlock(_ block: (UnsafePointer<CGPathElement>) -> Void) {
        let pts = UnsafeMutablePointer<CGPoint>.allocate(capacity: 3)
        defer { pts.deallocate() }
        for op in ops {
            var el = CGPathElement(type: .closeSubpath, points: pts)
            switch op {
            case let .move(p): el.type = .moveToPoint; pts[0] = p
            case let .line(p): el.type = .addLineToPoint; pts[0] = p
            case let .quad(c, p): el.type = .addQuadCurveToPoint; pts[0] = c; pts[1] = p
            case let .cubic(a, b, p): el.type = .addCurveToPoint; pts[0] = a; pts[1] = b; pts[2] = p
            case .close: break
            }
            withUnsafePointer(to: &el) { block($0) }
        }
    }

    public func apply(info: UnsafeMutableRawPointer?, function: CGPathApplierFunction) {
        applyWithBlock { function(info, $0) }
    }

    /// A polyline per subpath (curves flattened to within `tolerance`).
    public struct Polyline: Sendable { public var points: [CGPoint]; public var closed: Bool }

    public func flattened(tolerance: CGFloat = 0.25) -> [Polyline] {
        var out: [Polyline] = []
        var cur: [CGPoint] = []
        var start = CGPoint.zero, last = CGPoint.zero
        func flush(closed: Bool) {
            if cur.count > 0 { out.append(Polyline(points: cur, closed: closed)) }
            cur = []
        }
        for op in ops {
            switch op {
            case let .move(p):
                flush(closed: false)
                cur = [p]; start = p; last = p
            case let .line(p):
                if cur.isEmpty { cur = [last] }
                cur.append(p); last = p
            case let .quad(c, p):
                if cur.isEmpty { cur = [last] }
                let n = Self.segments(max(dist(last, c) + dist(c, p), 1), tolerance)
                for i in 1...n {
                    let t = CGFloat(i) / CGFloat(n), u = 1 - t
                    cur.append(CGPoint(x: u * u * last.x + 2 * u * t * c.x + t * t * p.x, y: u * u * last.y + 2 * u * t * c.y + t * t * p.y))
                }
                last = p
            case let .cubic(a, b, p):
                if cur.isEmpty { cur = [last] }
                let n = Self.segments(max(dist(last, a) + dist(a, b) + dist(b, p), 1), tolerance)
                for i in 1...n {
                    let t = CGFloat(i) / CGFloat(n), u = 1 - t
                    let x = u * u * u * last.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * p.x
                    let y = u * u * u * last.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * p.y
                    cur.append(CGPoint(x: x, y: y))
                }
                last = p
            case .close:
                flush(closed: true)
                last = start
            }
        }
        flush(closed: false)
        return out
    }

    static func segments(_ length: CGFloat, _ tolerance: CGFloat) -> Int {
        max(2, min(256, Int((length / max(tolerance * 8, 0.5)).squareRoot() * 2)))
    }
}

@inline(__always) func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

public class CGMutablePath: CGPath, @unchecked Sendable {
    public init() { super.init(ops: []) }
    override init(ops: [CGPathOp]) { super.init(ops: ops) }

    private var subpathStart = CGPoint.zero
    private var hasCurrent: Bool { !ops.isEmpty }

    public func move(to p: CGPoint, transform t: CGAffineTransform = .identity) {
        let q = p.applying(t)
        ops.append(.move(q))
        subpathStart = q
    }
    public func addLine(to p: CGPoint, transform t: CGAffineTransform = .identity) {
        if !hasCurrent { move(to: p, transform: t); return }
        ops.append(.line(p.applying(t)))
    }
    public func addLines(between points: [CGPoint], transform t: CGAffineTransform = .identity) {
        guard let f = points.first else { return }
        move(to: f, transform: t)
        for p in points.dropFirst() { ops.append(.line(p.applying(t))) }
    }
    public func addQuadCurve(to end: CGPoint, control: CGPoint, transform t: CGAffineTransform = .identity) {
        if !hasCurrent { move(to: control, transform: t) }
        ops.append(.quad(control.applying(t), end.applying(t)))
    }
    public func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint, transform t: CGAffineTransform = .identity) {
        if !hasCurrent { move(to: control1, transform: t) }
        ops.append(.cubic(control1.applying(t), control2.applying(t), end.applying(t)))
    }
    public func closeSubpath() {
        guard hasCurrent else { return }
        if case .close? = ops.last { return }
        ops.append(.close)
    }
    public func addRect(_ r: CGRect, transform t: CGAffineTransform = .identity) {
        let r = r.standardized
        move(to: CGPoint(x: r.minX, y: r.minY), transform: t)
        ops.append(.line(CGPoint(x: r.maxX, y: r.minY).applying(t)))
        ops.append(.line(CGPoint(x: r.maxX, y: r.maxY).applying(t)))
        ops.append(.line(CGPoint(x: r.minX, y: r.maxY).applying(t)))
        ops.append(.close)
    }
    public func addRects(_ rects: [CGRect], transform t: CGAffineTransform = .identity) { for r in rects { addRect(r, transform: t) } }

    /// Kappa for quarter-circle cubics.
    static let k: CGFloat = 0.5522847498307936

    public func addEllipse(in r: CGRect, transform t: CGAffineTransform = .identity) {
        let r = r.standardized
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let kx = rx * Self.k, ky = ry * Self.k
        // Counter-clockwise in y-up space, starting at the right, as Core Graphics.
        move(to: CGPoint(x: cx + rx, y: cy), transform: t)
        addCurve(to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + ky), control2: CGPoint(x: cx + kx, y: cy + ry), transform: t)
        addCurve(to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - kx, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + ky), transform: t)
        addCurve(to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - ky), control2: CGPoint(x: cx - kx, y: cy - ry), transform: t)
        addCurve(to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + kx, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - ky), transform: t)
        closeSubpath()
    }

    public func addRoundedRect(in r: CGRect, cornerWidth cw: CGFloat, cornerHeight ch: CGFloat, transform t: CGAffineTransform = .identity) {
        let r = r.standardized
        let rx = max(0, min(cw, r.width / 2)), ry = max(0, min(ch, r.height / 2))
        guard rx > 0, ry > 0 else { addRect(r, transform: t); return }
        let kx = rx * (1 - Self.k), ky = ry * (1 - Self.k)
        move(to: CGPoint(x: r.minX + rx, y: r.minY), transform: t)
        addLine(to: CGPoint(x: r.maxX - rx, y: r.minY), transform: t)
        addCurve(to: CGPoint(x: r.maxX, y: r.minY + ry), control1: CGPoint(x: r.maxX - kx, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + ky), transform: t)
        addLine(to: CGPoint(x: r.maxX, y: r.maxY - ry), transform: t)
        addCurve(to: CGPoint(x: r.maxX - rx, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - ky), control2: CGPoint(x: r.maxX - kx, y: r.maxY), transform: t)
        addLine(to: CGPoint(x: r.minX + rx, y: r.maxY), transform: t)
        addCurve(to: CGPoint(x: r.minX, y: r.maxY - ry), control1: CGPoint(x: r.minX + kx, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - ky), transform: t)
        addLine(to: CGPoint(x: r.minX, y: r.minY + ry), transform: t)
        addCurve(to: CGPoint(x: r.minX + rx, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + ky), control2: CGPoint(x: r.minX + kx, y: r.minY), transform: t)
        closeSubpath()
    }

    /// An arc in the path's own space: angles in radians, counter-clockwise
    /// for increasing angles in a y-up space; `clockwise` sweeps the other way.
    public func addArc(center c: CGPoint, radius r: CGFloat, startAngle a0: CGFloat, endAngle a1: CGFloat, clockwise: Bool, transform t: CGAffineTransform = .identity) {
        var sweep = a1 - a0
        let tau = 2 * CGFloat.pi
        if clockwise {
            if sweep > 0 { sweep = sweep.truncatingRemainder(dividingBy: tau) - tau } else if sweep < -tau { sweep = -tau }
            if sweep == 0, a1 != a0 { sweep = -tau }
        } else {
            if sweep < 0 { sweep = sweep.truncatingRemainder(dividingBy: tau) + tau } else if sweep > tau { sweep = tau }
            if sweep == 0, a1 != a0 { sweep = tau }
        }
        addRelativeArc(center: c, radius: r, startAngle: a0, delta: sweep, transform: t)
    }

    public func addRelativeArc(center c: CGPoint, radius r: CGFloat, startAngle a0: CGFloat, delta: CGFloat, transform t: CGAffineTransform = .identity) {
        let start = CGPoint(x: c.x + r * cos(a0), y: c.y + r * sin(a0))
        if hasCurrent { addLine(to: start, transform: t) } else { move(to: start, transform: t) }
        guard delta != 0, r > 0 else { return }
        let n = max(1, Int((abs(delta) / (CGFloat.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(n)
        let kk = 4 / 3 * tan(step / 4)
        var a = a0
        for _ in 0..<n {
            let b = a + step
            let p0 = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            let p3 = CGPoint(x: c.x + r * cos(b), y: c.y + r * sin(b))
            let p1 = CGPoint(x: p0.x - kk * r * sin(a), y: p0.y + kk * r * cos(a))
            let p2 = CGPoint(x: p3.x + kk * r * sin(b), y: p3.y - kk * r * cos(b))
            ops.append(.cubic(p1.applying(t), p2.applying(t), p3.applying(t)))
            a = b
        }
    }

    /// The arc tangent to the lines current→t1 and t1→t2 (PostScript arct).
    public func addArc(tangent1End p1: CGPoint, tangent2End p2: CGPoint, radius r: CGFloat, transform t: CGAffineTransform = .identity) {
        guard hasCurrent else { move(to: p1, transform: t); return }
        // Work in untransformed space: undo t on the current point.
        let p0 = currentPoint.applying(t.inverted())
        let v1 = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y), v2 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        let l1 = (v1.x * v1.x + v1.y * v1.y).squareRoot(), l2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
        let cross = v1.x * v2.y - v1.y * v2.x
        guard l1 > 0, l2 > 0, abs(cross) > 1e-9, r > 0 else { addLine(to: p1, transform: t); return }
        let cosA = (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)
        let angle = acos(max(-1, min(1, cosA)))
        let d = r / tan(angle / 2)
        let t1 = CGPoint(x: p1.x + v1.x / l1 * d, y: p1.y + v1.y / l1 * d)
        let t2 = CGPoint(x: p1.x + v2.x / l2 * d, y: p1.y + v2.y / l2 * d)
        // Centre: from t1 along the normal toward the inside of the corner.
        let bis = CGPoint(x: v1.x / l1 + v2.x / l2, y: v1.y / l1 + v2.y / l2)
        let bl = (bis.x * bis.x + bis.y * bis.y).squareRoot()
        let h = (d * d + r * r).squareRoot()
        let c = CGPoint(x: p1.x + bis.x / bl * h, y: p1.y + bis.y / bl * h)
        let a0 = atan2(t1.y - c.y, t1.x - c.x), a1 = atan2(t2.y - c.y, t2.x - c.x)
        addLine(to: t1, transform: t)
        addArc(center: c, radius: r, startAngle: a0, endAngle: a1, clockwise: cross > 0, transform: t)
    }

    public func addPath(_ path: CGPath, transform t: CGAffineTransform = .identity) {
        ops += t.isIdentity ? path.ops : path.ops.map { $0.applying(t) }
    }

    public func removeAll() { ops.removeAll(keepingCapacity: true) }
    /// Transforms every point in place.
    public func transform(by t: CGAffineTransform) { ops = ops.map { $0.applying(t) } }
}
