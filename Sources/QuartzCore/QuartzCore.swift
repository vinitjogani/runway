// QuartzCore (Core Animation) for Linux and Windows: a CALayer tree with
// geometry, appearance (background, corners, border, shadow, opacity),
// contents as a CGImage, sublayers, CATransaction, and animations that are
// recorded but not interpolated (the model value is what's drawn).
//
// Hosting: a view backend draws a layer tree with `render(in:)` (software,
// into a CGContext) or walks it itself. Any change to a layer calls the
// root layer's `onInvalidate`, which a layer-backed NSView sets to mark
// itself for redraw; see `CALayer.onInvalidate`.

@_exported import CoreGraphics
@_exported import Foundation
@_exported import RunwayFoundation
import Metal


/// Seconds on the host clock, as Core Animation counts time.
public func CACurrentMediaTime() -> CFTimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

// MARK: Transforms

public struct CATransform3D: Equatable, Sendable {
    public var m11: CGFloat, m12: CGFloat, m13: CGFloat, m14: CGFloat
    public var m21: CGFloat, m22: CGFloat, m23: CGFloat, m24: CGFloat
    public var m31: CGFloat, m32: CGFloat, m33: CGFloat, m34: CGFloat
    public var m41: CGFloat, m42: CGFloat, m43: CGFloat, m44: CGFloat
    public init(m11: CGFloat, m12: CGFloat, m13: CGFloat, m14: CGFloat, m21: CGFloat, m22: CGFloat, m23: CGFloat, m24: CGFloat,
                m31: CGFloat, m32: CGFloat, m33: CGFloat, m34: CGFloat, m41: CGFloat, m42: CGFloat, m43: CGFloat, m44: CGFloat) {
        (self.m11, self.m12, self.m13, self.m14) = (m11, m12, m13, m14)
        (self.m21, self.m22, self.m23, self.m24) = (m21, m22, m23, m24)
        (self.m31, self.m32, self.m33, self.m34) = (m31, m32, m33, m34)
        (self.m41, self.m42, self.m43, self.m44) = (m41, m42, m43, m44)
    }
    public init() { self = CATransform3DIdentity }
}

public let CATransform3DIdentity = CATransform3D(m11: 1, m12: 0, m13: 0, m14: 0, m21: 0, m22: 1, m23: 0, m24: 0,
                                                 m31: 0, m32: 0, m33: 1, m34: 0, m41: 0, m42: 0, m43: 0, m44: 1)
public func CATransform3DIsIdentity(_ t: CATransform3D) -> Bool { t == CATransform3DIdentity }
public func CATransform3DEqualToTransform(_ a: CATransform3D, _ b: CATransform3D) -> Bool { a == b }
public func CATransform3DMakeTranslation(_ tx: CGFloat, _ ty: CGFloat, _ tz: CGFloat) -> CATransform3D {
    var t = CATransform3DIdentity; t.m41 = tx; t.m42 = ty; t.m43 = tz; return t
}
public func CATransform3DMakeScale(_ sx: CGFloat, _ sy: CGFloat, _ sz: CGFloat) -> CATransform3D {
    var t = CATransform3DIdentity; t.m11 = sx; t.m22 = sy; t.m33 = sz; return t
}
public func CATransform3DMakeRotation(_ angle: CGFloat, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CATransform3D {
    let len = (x * x + y * y + z * z).squareRoot()
    guard len > 0 else { return CATransform3DIdentity }
    let (x, y, z) = (x / len, y / len, z / len)
    let c = CGFloat(cos(Double(angle))), s = CGFloat(sin(Double(angle))), k = 1 - c
    return CATransform3D(m11: c + x * x * k, m12: x * y * k + z * s, m13: x * z * k - y * s, m14: 0,
                         m21: x * y * k - z * s, m22: c + y * y * k, m23: y * z * k + x * s, m24: 0,
                         m31: x * z * k + y * s, m32: y * z * k - x * s, m33: c + z * z * k, m34: 0,
                         m41: 0, m42: 0, m43: 0, m44: 1)
}
public func CATransform3DConcat(_ a: CATransform3D, _ b: CATransform3D) -> CATransform3D {
    func row(_ r: (CGFloat, CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        (r.0 * b.m11 + r.1 * b.m21 + r.2 * b.m31 + r.3 * b.m41, r.0 * b.m12 + r.1 * b.m22 + r.2 * b.m32 + r.3 * b.m42,
         r.0 * b.m13 + r.1 * b.m23 + r.2 * b.m33 + r.3 * b.m43, r.0 * b.m14 + r.1 * b.m24 + r.2 * b.m34 + r.3 * b.m44)
    }
    let r1 = row((a.m11, a.m12, a.m13, a.m14)), r2 = row((a.m21, a.m22, a.m23, a.m24))
    let r3 = row((a.m31, a.m32, a.m33, a.m34)), r4 = row((a.m41, a.m42, a.m43, a.m44))
    return CATransform3D(m11: r1.0, m12: r1.1, m13: r1.2, m14: r1.3, m21: r2.0, m22: r2.1, m23: r2.2, m24: r2.3,
                         m31: r3.0, m32: r3.1, m33: r3.2, m34: r3.3, m41: r4.0, m42: r4.1, m43: r4.2, m44: r4.3)
}
public func CATransform3DTranslate(_ t: CATransform3D, _ tx: CGFloat, _ ty: CGFloat, _ tz: CGFloat) -> CATransform3D {
    CATransform3DConcat(CATransform3DMakeTranslation(tx, ty, tz), t)
}
public func CATransform3DScale(_ t: CATransform3D, _ sx: CGFloat, _ sy: CGFloat, _ sz: CGFloat) -> CATransform3D {
    CATransform3DConcat(CATransform3DMakeScale(sx, sy, sz), t)
}
public func CATransform3DRotate(_ t: CATransform3D, _ angle: CGFloat, _ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> CATransform3D {
    CATransform3DConcat(CATransform3DMakeRotation(angle, x, y, z), t)
}
public func CATransform3DMakeAffineTransform(_ m: CGAffineTransform) -> CATransform3D {
    CATransform3D(m11: m.a, m12: m.b, m13: 0, m14: 0, m21: m.c, m22: m.d, m23: 0, m24: 0, m31: 0, m32: 0, m33: 1, m34: 0, m41: m.tx, m42: m.ty, m43: 0, m44: 1)
}
public func CATransform3DIsAffine(_ t: CATransform3D) -> Bool {
    t.m13 == 0 && t.m14 == 0 && t.m23 == 0 && t.m24 == 0 && t.m31 == 0 && t.m32 == 0 && t.m33 == 1 && t.m34 == 0 && t.m43 == 0 && t.m44 == 1
}
public func CATransform3DGetAffineTransform(_ t: CATransform3D) -> CGAffineTransform {
    CGAffineTransform(a: t.m11, b: t.m12, c: t.m21, d: t.m22, tx: t.m41, ty: t.m42)
}
public func CATransform3DInvert(_ t: CATransform3D) -> CATransform3D {
    guard CATransform3DIsAffine(t) else { return t }
    return CATransform3DMakeAffineTransform(CATransform3DGetAffineTransform(t).inverted())
}

// MARK: Names

public struct CALayerContentsGravity: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let center = Self(rawValue: "center"), top = Self(rawValue: "top"), bottom = Self(rawValue: "bottom")
    public static let left = Self(rawValue: "left"), right = Self(rawValue: "right"), topLeft = Self(rawValue: "topLeft")
    public static let topRight = Self(rawValue: "topRight"), bottomLeft = Self(rawValue: "bottomLeft"), bottomRight = Self(rawValue: "bottomRight")
    public static let resize = Self(rawValue: "resize"), resizeAspect = Self(rawValue: "resizeAspect"), resizeAspectFill = Self(rawValue: "resizeAspectFill")
}
public struct CALayerContentsFilter: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let nearest = Self(rawValue: "nearest"), linear = Self(rawValue: "linear"), trilinear = Self(rawValue: "trilinear")
}
public struct CALayerContentsFormat: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let RGBA8Uint = Self(rawValue: "RGBA8"), RGBA16Float = Self(rawValue: "RGBAh"), gray8Uint = Self(rawValue: "Gray8")
}
public struct CALayerCornerCurve: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let circular = Self(rawValue: "circular"), continuous = Self(rawValue: "continuous")
}
public struct CAAutoresizingMask: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let layerMinXMargin = Self(rawValue: 1), layerWidthSizable = Self(rawValue: 2), layerMaxXMargin = Self(rawValue: 4)
    public static let layerMinYMargin = Self(rawValue: 8), layerHeightSizable = Self(rawValue: 16), layerMaxYMargin = Self(rawValue: 32)
}
public struct CACornerMask: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let layerMinXMinYCorner = Self(rawValue: 1), layerMaxXMinYCorner = Self(rawValue: 2)
    public static let layerMinXMaxYCorner = Self(rawValue: 4), layerMaxXMaxYCorner = Self(rawValue: 8)
}
public struct CAEdgeAntialiasingMask: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let layerLeftEdge = Self(rawValue: 1), layerRightEdge = Self(rawValue: 2), layerBottomEdge = Self(rawValue: 4), layerTopEdge = Self(rawValue: 8)
}

// MARK: Actions and delegates

public protocol CAAction {
    func run(forKey event: String, object anObject: Any, arguments dict: [AnyHashable: Any]?)
}

extension NSNull: CAAction {
    public func run(forKey event: String, object anObject: Any, arguments dict: [AnyHashable: Any]?) {}
}

public protocol CALayerDelegate: AnyObject {
    func display(_ layer: CALayer)
    func draw(_ layer: CALayer, in ctx: CGContext)
    func layerWillDraw(_ layer: CALayer)
    func layoutSublayers(of layer: CALayer)
    func action(for layer: CALayer, forKey event: String) -> CAAction?
}
extension CALayerDelegate {
    public func display(_ layer: CALayer) {}
    public func draw(_ layer: CALayer, in ctx: CGContext) {}
    public func layerWillDraw(_ layer: CALayer) {}
    public func layoutSublayers(of layer: CALayer) {}
    public func action(for layer: CALayer, forKey event: String) -> CAAction? { nil }
}

// MARK: Layers

open class CALayer: NSObject, @unchecked Sendable {
    // Geometry. `frame` is derived from bounds, position and anchorPoint as in Core Animation.
    open var bounds: CGRect = .zero { didSet { boundsChanged(from: oldValue) } }
    open var position: CGPoint = .zero { didSet { invalidate() } }
    open var anchorPoint = CGPoint(x: 0.5, y: 0.5) { didSet { invalidate() } }
    open var zPosition: CGFloat = 0 { didSet { invalidate() } }
    open var anchorPointZ: CGFloat = 0
    open var transform: CATransform3D = CATransform3DIdentity { didSet { invalidate() } }
    open var sublayerTransform: CATransform3D = CATransform3DIdentity { didSet { invalidate() } }
    open var isGeometryFlipped = false { didSet { invalidate() } }
    open var autoresizingMask: CAAutoresizingMask = []
    open var needsDisplayOnBoundsChange = false
    open var contentsAreFlipped: Bool { isGeometryFlipped }

    open var frame: CGRect {
        get {
            CGRect(x: position.x - bounds.width * anchorPoint.x, y: position.y - bounds.height * anchorPoint.y,
                   width: bounds.width, height: bounds.height)
        }
        set {
            bounds = CGRect(origin: bounds.origin, size: newValue.size)
            position = CGPoint(x: newValue.minX + newValue.width * anchorPoint.x, y: newValue.minY + newValue.height * anchorPoint.y)
        }
    }

    // Appearance.
    open var backgroundColor: CGColor? { didSet { invalidate() } }
    open var cornerRadius: CGFloat = 0 { didSet { invalidate() } }
    open var cornerCurve: CALayerCornerCurve = .circular { didSet { invalidate() } }
    open var maskedCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    open var borderWidth: CGFloat = 0 { didSet { invalidate() } }
    open var borderColor: CGColor? = CGColor.black { didSet { invalidate() } }
    open var opacity: Float = 1 { didSet { hostObserver?("opacity"); invalidate() } }
    open var isHidden = false { didSet { invalidate() } }
    open var isOpaque = false
    open var masksToBounds = false { didSet { hostObserver?("masksToBounds"); invalidate() } }
    open var isDoubleSided = true
    open var allowsEdgeAntialiasing = false
    open var allowsGroupOpacity = true
    open var edgeAntialiasingMask: CAEdgeAntialiasingMask = [.layerLeftEdge, .layerRightEdge, .layerBottomEdge, .layerTopEdge]
    open var shadowColor: CGColor? = CGColor.black { didSet { invalidate() } }
    open var shadowOpacity: Float = 0 { didSet { invalidate() } }
    open var shadowOffset = CGSize(width: 0, height: -3) { didSet { invalidate() } }
    open var shadowRadius: CGFloat = 3 { didSet { invalidate() } }
    open var shouldRasterize = false
    open var rasterizationScale: CGFloat = 1
    open var drawsAsynchronously = false
    open var compositingFilter: Any?
    open var filters: [Any]?
    open var backgroundFilters: [Any]?
    open var minificationFilter: CALayerContentsFilter = .linear
    open var magnificationFilter: CALayerContentsFilter = .linear
    open var name: String?
    open var style: [AnyHashable: Any]?
    open var actions: [String: CAAction]?

    // Contents: a CGImage (or anything a backend understands).
    open var contents: Any? { didSet { invalidate() } }
    open var contentsGravity: CALayerContentsGravity = .resize { didSet { invalidate() } }
    open var contentsScale: CGFloat = 1
    open var contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    open var contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
    open var contentsFormat: CALayerContentsFormat = .RGBA8Uint

    // Tree.
    open private(set) weak var superlayer: CALayer?
    private var _sublayers: [CALayer] = []
    open var sublayers: [CALayer]? {
        get { _sublayers.isEmpty ? nil : _sublayers }
        set {
            for l in _sublayers { l.superlayer = nil }
            _sublayers = []
            for l in newValue ?? [] { addSublayer(l) }
            invalidate()
        }
    }
    open var mask: CALayer? { didSet { invalidate() } }
    open weak var delegate: CALayerDelegate?

    /// Set by the host (a layer-backed view) on its root layer: called when
    /// anything in the tree changes, so the host can redraw.
    open var onInvalidate: (() -> Void)?
    /// Set by a view backed by this layer: told "opacity" and
    /// "masksToBounds" (which views keep themselves) and "display" for any
    /// other change in the layer or its sublayers.
    open var hostObserver: ((String) -> Void)?

    private var animationsByKey: [String: CAAnimation] = [:]
    private var needsDisplayFlag = false
    private var needsLayoutFlag = false
    private var values: [String: Any] = [:]

    public override init() { super.init() }
    public init(layer: Any) {
        super.init()
        if let l = layer as? CALayer {
            bounds = l.bounds; position = l.position; anchorPoint = l.anchorPoint; backgroundColor = l.backgroundColor
            cornerRadius = l.cornerRadius; borderWidth = l.borderWidth; borderColor = l.borderColor; opacity = l.opacity
            contents = l.contents; contentsGravity = l.contentsGravity; isHidden = l.isHidden; masksToBounds = l.masksToBounds
        }
    }
    /// `+layer`: a new layer of the receiving class. (Without `required`
    /// initializers a metatype can't be constructed; subclasses are made
    /// through the class registry the build tool generates.)
    open class func layer() -> Self {
        if self == CALayer.self { return unsafeDowncast(CALayer(), to: self) }
        if let made = CALayer._subclassFactory?(self) as? Self { return made }
        fatalError("\(self).layer(): the class isn't in the class registry; use \(self)() instead")
    }
    /// How `layer()` makes a subclass: AppKit points this at the class registry.
    nonisolated(unsafe) public static var _subclassFactory: ((AnyClass) -> AnyObject?)?

    /// Marks the tree for a redraw (the host decides when).
    open func invalidate() {
        var top: CALayer = self
        hostObserver?("display")
        while let s = top.superlayer {
            top = s
            s.hostObserver?("display")
        }
        top.onInvalidate?()
    }

    // MARK: Drawing for hosting views

    /// The layer's outline: its bounds, rounded by `cornerRadius`.
    open func roundedPath(_ r: CGRect) -> CGPath {
        let p = CGMutablePath()
        if cornerRadius > 0 { p.addRoundedRect(in: r, cornerWidth: cornerRadius, cornerHeight: cornerRadius) } else { p.addRect(r) }
        return p
    }

    /// Background colour and image contents into `bounds` (then clips to the
    /// rounded outline when masking), for a view drawing its backing layer.
    open func drawBackground(in ctx: CGContext, bounds: CGRect, flipped: Bool) {
        guard !isHidden else { return }
        if let bg = backgroundColor, (bg.components?.last ?? 1) > 0 {
            ctx.setFillColor(bg)
            ctx.addPath(roundedPath(bounds))
            ctx.fillPath()
        }
        if let img = contentsImage {
            if flipped {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: bounds.maxY + bounds.minY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: contentsRect(for: img, in: bounds))
                ctx.restoreGState()
            } else {
                ctx.draw(img, in: contentsRect(for: img, in: bounds))
            }
        }
        if cornerRadius > 0, masksToBounds {
            ctx.addPath(roundedPath(bounds))
            ctx.clip()
        }
    }

    /// The border, inside `bounds`.
    open func drawBorder(in ctx: CGContext, bounds: CGRect, flipped: Bool) {
        guard !isHidden, borderWidth > 0, let c = borderColor else { return }
        ctx.setStrokeColor(c)
        ctx.setLineWidth(borderWidth)
        ctx.addPath(roundedPath(bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)))
        ctx.strokePath()
    }

    private func boundsChanged(from old: CGRect) {
        if old.size != bounds.size {
            for s in _sublayers { s.resize(fromSuperSize: old.size, to: bounds.size) }
            if needsDisplayOnBoundsChange { setNeedsDisplay() }
            setNeedsLayout()
        }
        invalidate()
    }

    /// Autoresizing, as Core Animation applies it to sublayers.
    private func resize(fromSuperSize old: CGSize, to new: CGSize) {
        guard !autoresizingMask.isEmpty else { return }
        var f = frame
        let dw = new.width - old.width, dh = new.height - old.height
        func distribute(_ d: CGFloat, _ minM: Bool, _ size: Bool, _ maxM: Bool) -> (CGFloat, CGFloat) {
            let parts = CGFloat([minM, size, maxM].filter { $0 }.count)
            guard parts > 0 else { return (0, 0) }
            let each = d / parts
            return (minM ? each : 0, size ? each : 0)
        }
        let (mx, sx) = distribute(dw, autoresizingMask.contains(.layerMinXMargin), autoresizingMask.contains(.layerWidthSizable), autoresizingMask.contains(.layerMaxXMargin))
        let (my, sy) = distribute(dh, autoresizingMask.contains(.layerMinYMargin), autoresizingMask.contains(.layerHeightSizable), autoresizingMask.contains(.layerMaxYMargin))
        f.origin.x += mx; f.size.width += sx
        f.origin.y += my; f.size.height += sy
        frame = f
    }

    open func addSublayer(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        layer.superlayer = self
        _sublayers.append(layer)
        invalidate()
    }
    open func insertSublayer(_ layer: CALayer, at idx: UInt32) {
        layer.removeFromSuperlayer()
        layer.superlayer = self
        _sublayers.insert(layer, at: min(Int(idx), _sublayers.count))
        invalidate()
    }
    open func insertSublayer(_ layer: CALayer, below sibling: CALayer?) {
        guard let s = sibling, let i = _sublayers.firstIndex(where: { $0 === s }) else { return insertSublayer(layer, at: 0) }
        insertSublayer(layer, at: UInt32(i))
    }
    open func insertSublayer(_ layer: CALayer, above sibling: CALayer?) {
        guard let s = sibling, let i = _sublayers.firstIndex(where: { $0 === s }) else { return addSublayer(layer) }
        insertSublayer(layer, at: UInt32(i + 1))
    }
    open func replaceSublayer(_ oldLayer: CALayer, with newLayer: CALayer) {
        guard let i = _sublayers.firstIndex(where: { $0 === oldLayer }) else { return }
        oldLayer.removeFromSuperlayer()
        insertSublayer(newLayer, at: UInt32(i))
    }
    open func removeFromSuperlayer() {
        guard let s = superlayer else { return }
        s._sublayers.removeAll { $0 === self }
        superlayer = nil
        s.invalidate()
    }

    // Display and layout.
    open func setNeedsDisplay() { needsDisplayFlag = true; invalidate() }
    open func setNeedsDisplay(_ r: CGRect) { setNeedsDisplay() }
    open var needsDisplay: Bool { needsDisplayFlag }
    open func displayIfNeeded() { if needsDisplayFlag { display() } }
    open func display() {
        needsDisplayFlag = false
        if let d = delegate { d.display(self) }
    }
    open func draw(in ctx: CGContext) { delegate?.draw(self, in: ctx) }
    open func setNeedsLayout() { needsLayoutFlag = true }
    open func needsLayout() -> Bool { needsLayoutFlag }
    open func layoutIfNeeded() { if needsLayoutFlag { layoutSublayers() } }
    open func layoutSublayers() { needsLayoutFlag = false; delegate?.layoutSublayers(of: self) }
    open func preferredFrameSize() -> CGSize { bounds.size }

    open func affineTransform() -> CGAffineTransform { CATransform3DGetAffineTransform(transform) }
    open func setAffineTransform(_ m: CGAffineTransform) { transform = CATransform3DMakeAffineTransform(m) }

    // Coordinates (translation only; transforms aren't applied).
    private var originInRoot: CGPoint {
        var p = CGPoint(x: frame.minX - bounds.minX, y: frame.minY - bounds.minY)
        var l = superlayer
        while let s = l { p.x += s.frame.minX - s.bounds.minX; p.y += s.frame.minY - s.bounds.minY; l = s.superlayer }
        return p
    }
    open func convert(_ p: CGPoint, from l: CALayer?) -> CGPoint {
        let a = l?.originInRoot ?? .zero, b = originInRoot
        return CGPoint(x: p.x + a.x - b.x, y: p.y + a.y - b.y)
    }
    open func convert(_ p: CGPoint, to l: CALayer?) -> CGPoint { (l ?? CALayer()).convert(p, from: self) }
    open func convert(_ r: CGRect, from l: CALayer?) -> CGRect { CGRect(origin: convert(r.origin, from: l), size: r.size) }
    open func convert(_ r: CGRect, to l: CALayer?) -> CGRect { CGRect(origin: convert(r.origin, to: l), size: r.size) }
    open func contains(_ p: CGPoint) -> Bool { bounds.contains(p) }
    open func hitTest(_ p: CGPoint) -> CALayer? {
        guard !isHidden, frame.contains(p) else { return nil }
        let local = CGPoint(x: p.x - frame.minX + bounds.minX, y: p.y - frame.minY + bounds.minY)
        for s in _sublayers.reversed() { if let h = s.hitTest(local) { return h } }
        return self
    }

    // Animations: kept (and reported by `animation(forKey:)`), not interpolated.
    open func add(_ anim: CAAnimation, forKey key: String?) {
        animationsByKey[key ?? UUID().uuidString] = anim
        anim.delegate?.animationDidStart(anim)
        if anim.isRemovedOnCompletion {
            animationsByKey = animationsByKey.filter { $0.value !== anim }
            anim.delegate?.animationDidStop(anim, finished: true)
        }
    }
    open func animation(forKey key: String) -> CAAnimation? { animationsByKey[key] }
    open func removeAnimation(forKey key: String) { animationsByKey[key] = nil }
    open func removeAllAnimations() { animationsByKey.removeAll() }
    open func animationKeys() -> [String]? { animationsByKey.isEmpty ? nil : Array(animationsByKey.keys) }
    open func presentation() -> Self? { self }
    open func model() -> Self { self }
    open func action(forKey event: String) -> CAAction? { actions?[event] ?? delegate?.action(for: self, forKey: event) }
    open class func defaultAction(forKey event: String) -> CAAction? { nil }
    open class func defaultValue(forKey key: String) -> Any? { nil }
    open class func needsDisplay(forKey key: String) -> Bool { false }

    open func setValue(_ value: Any?, forKey key: String) { values[key] = value; invalidate() }
    open func value(forKey key: String) -> Any? { values[key] }

    // MARK: Software rendering

    /// Draws the tree into `ctx` (Core Graphics space: bottom-left origin):
    /// background, contents, sublayers, border, each at its frame.
    open func render(in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        drawLayer(in: ctx, flipped: false, alpha: 1)
        ctx.restoreGState()
    }

    /// Draws the sublayers (each with its own sublayers) into `ctx`, which is
    /// in this layer's coordinate space: how a layer-backed view shows the
    /// layers added to its backing layer. `flipped`: the space runs top-down
    /// on screen (a flipped view), so images are drawn upright in it.
    open func renderSublayers(in ctx: CGContext, flipped: Bool, alpha: CGFloat = 1) {
        guard !isHidden else { return }
        let children = sortedSublayers
        guard !children.isEmpty else { return }
        ctx.saveGState()
        // A flipped layer's sublayers lay out top-down.
        var flip = flipped
        if isGeometryFlipped {
            ctx.translateBy(x: 0, y: bounds.maxY + bounds.minY)
            ctx.scaleBy(x: 1, y: -1)
            flip.toggle()
        }
        if !CATransform3DIsIdentity(sublayerTransform) {
            ctx.translateBy(x: bounds.midX, y: bounds.midY)
            ctx.concatenate(CATransform3DGetAffineTransform(sublayerTransform))
            ctx.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        for s in children { s.renderInSuperlayer(ctx, flipped: flip, alpha: alpha) }
        ctx.restoreGState()
    }

    /// Whether anything would be drawn by `renderSublayers`.
    open var hasVisibleSublayers: Bool { !isHidden && _sublayers.contains { !$0.isHidden && $0.opacity > 0 } }

    /// Back to front: by zPosition, then in order.
    private var sortedSublayers: [CALayer] {
        guard _sublayers.contains(where: { $0.zPosition != 0 }) else { return _sublayers }
        return _sublayers.enumerated().sorted { ($0.element.zPosition, $0.offset) < ($1.element.zPosition, $1.offset) }.map(\.element)
    }

    /// Draws this layer at its place in its superlayer's space (the space `ctx` is in).
    private func renderInSuperlayer(_ ctx: CGContext, flipped: Bool, alpha: CGFloat) {
        guard !isHidden, opacity > 0 else { return }
        ctx.saveGState()
        // position, then the transform about the anchor point, then the bounds origin.
        ctx.translateBy(x: position.x, y: position.y)
        if !CATransform3DIsIdentity(transform) { ctx.concatenate(CATransform3DGetAffineTransform(transform)) }
        ctx.translateBy(x: -bounds.width * anchorPoint.x - bounds.minX, y: -bounds.height * anchorPoint.y - bounds.minY)
        drawLayer(in: ctx, flipped: flipped, alpha: alpha)
        ctx.restoreGState()
    }

    /// This layer and its sublayers, in its own bounds space.
    private func drawLayer(in ctx: CGContext, flipped: Bool, alpha: CGFloat) {
        guard !isHidden, opacity > 0 else { return }
        let a = alpha * CGFloat(opacity)
        let rect = bounds
        let outline = roundedPath(rect)
        ctx.setAlpha(a)
        // The shadow follows the layer's outline.
        if shadowOpacity > 0, let sc = shadowColor, let c = sc.copy(alpha: sc.alpha * CGFloat(shadowOpacity)),
           backgroundColor != nil || contentsImage != nil {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: shadowOffset.width, height: flipped ? -shadowOffset.height : shadowOffset.height),
                          blur: shadowRadius * 2, color: c)
            ctx.setFillColor(backgroundColor ?? CGColor.black)
            ctx.addPath(outline)
            ctx.fillPath()
            ctx.restoreGState()
        }
        if let bg = backgroundColor, bg.alpha > 0 {
            ctx.setFillColor(bg)
            ctx.addPath(outline)
            ctx.fillPath()
        }
        ctx.saveGState()
        if masksToBounds {
            ctx.addPath(outline)
            ctx.clip()
        }
        if let image = contentsImage {
            let r = contentsRect(for: image, in: rect)
            if flipped {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: r.maxY + r.minY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: r)
                ctx.restoreGState()
            } else {
                ctx.draw(image, in: r)
            }
        }
        displayIfNeeded()
        drawOwnContent(in: ctx)
        draw(in: ctx)
        renderSublayers(in: ctx, flipped: flipped, alpha: a)
        ctx.restoreGState()
        ctx.setAlpha(a)
        if borderWidth > 0, let c = borderColor, c.alpha > 0 {
            ctx.setStrokeColor(c)
            ctx.setLineWidth(borderWidth)
            ctx.addPath(roundedPath(rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2)))
            ctx.strokePath()
        }
    }

    /// What a layer class draws by itself (a shape, a gradient), in its bounds space.
    open func drawOwnContent(in ctx: CGContext) {}

    /// The contents as an image, if they are one.
    open var contentsImage: CGImage? { contents as? CGImage }

    /// Where contents of `image` go inside `r` for the gravity.
    open func contentsRect(for image: CGImage, in r: CGRect) -> CGRect {
        let iw = CGFloat(image.width) / max(contentsScale, 1), ih = CGFloat(image.height) / max(contentsScale, 1)
        guard iw > 0, ih > 0 else { return r }
        switch contentsGravity {
        case .resize: return r
        case .resizeAspect, .resizeAspectFill:
            let k = contentsGravity == .resizeAspect ? min(r.width / iw, r.height / ih) : max(r.width / iw, r.height / ih)
            let w = iw * k, h = ih * k
            return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
        case .center: return CGRect(x: r.midX - iw / 2, y: r.midY - ih / 2, width: iw, height: ih)
        case .bottomLeft: return CGRect(x: r.minX, y: r.minY, width: iw, height: ih)
        case .bottomRight: return CGRect(x: r.maxX - iw, y: r.minY, width: iw, height: ih)
        case .topLeft: return CGRect(x: r.minX, y: r.maxY - ih, width: iw, height: ih)
        case .topRight: return CGRect(x: r.maxX - iw, y: r.maxY - ih, width: iw, height: ih)
        case .top: return CGRect(x: r.midX - iw / 2, y: r.maxY - ih, width: iw, height: ih)
        case .bottom: return CGRect(x: r.midX - iw / 2, y: r.minY, width: iw, height: ih)
        case .left: return CGRect(x: r.minX, y: r.midY - ih / 2, width: iw, height: ih)
        case .right: return CGRect(x: r.maxX - iw, y: r.midY - ih / 2, width: iw, height: ih)
        default: return r
        }
    }
}

open class CAShapeLayer: CALayer, @unchecked Sendable {
    open var path: CGPath? { didSet { invalidate() } }
    open var fillColor: CGColor? = CGColor.black { didSet { invalidate() } }
    open var strokeColor: CGColor? { didSet { invalidate() } }
    open var lineWidth: CGFloat = 1 { didSet { invalidate() } }
    open var lineDashPattern: [NSNumber]?
    open var lineDashPhase: CGFloat = 0
    open var strokeStart: CGFloat = 0
    open var strokeEnd: CGFloat = 1
    open var miterLimit: CGFloat = 10
    open var lineCap: CAShapeLayerLineCap = .butt
    open var lineJoin: CAShapeLayerLineJoin = .miter
    open var fillRule: CAShapeLayerFillRule = .nonZero

    open override func drawOwnContent(in ctx: CGContext) {
        guard let path, !path.isEmpty else { return }
        if let f = fillColor, f.alpha > 0 {
            ctx.setFillColor(f)
            ctx.addPath(path)
            ctx.fillPath(using: fillRule == .evenOdd ? .evenOdd : .winding)
        }
        if let st = strokeColor, st.alpha > 0, lineWidth > 0 {
            ctx.setStrokeColor(st)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(lineCap == .round ? .round : lineCap == .square ? .square : .butt)
            ctx.setLineJoin(lineJoin == .round ? .round : lineJoin == .bevel ? .bevel : .miter)
            ctx.setMiterLimit(miterLimit)
            if let d = lineDashPattern, !d.isEmpty { ctx.setLineDash(phase: lineDashPhase, lengths: d.map { CGFloat($0.doubleValue) }) }
            ctx.addPath(path)
            ctx.strokePath()
        }
    }
}
public struct CAShapeLayerLineCap: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let butt = Self(rawValue: "butt"), round = Self(rawValue: "round"), square = Self(rawValue: "square")
}
public struct CAShapeLayerLineJoin: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let miter = Self(rawValue: "miter"), round = Self(rawValue: "round"), bevel = Self(rawValue: "bevel")
}
public struct CAShapeLayerFillRule: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let nonZero = Self(rawValue: "non-zero"), evenOdd = Self(rawValue: "even-odd")
}

open class CAGradientLayer: CALayer, @unchecked Sendable {
    open var colors: [Any]? { didSet { invalidate() } }
    open var locations: [NSNumber]? { didSet { invalidate() } }
    open var startPoint = CGPoint(x: 0.5, y: 0) { didSet { invalidate() } }
    open var endPoint = CGPoint(x: 0.5, y: 1) { didSet { invalidate() } }
    open var type: CAGradientLayerType = .axial

    open override func drawOwnContent(in ctx: CGContext) {
        let cs = (colors ?? []).compactMap { $0 as? CGColor }
        guard !cs.isEmpty, bounds.width > 0, bounds.height > 0,
              let g = CGGradient(colorsSpace: nil, colors: cs.count == 1 ? [cs[0], cs[0]] : cs,
                                 locations: locations?.map { CGFloat($0.doubleValue) })
        else { return }
        let r = bounds
        func at(_ p: CGPoint) -> CGPoint { CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height) }
        ctx.saveGState()
        ctx.addPath(roundedPath(r))
        ctx.clip()
        if type == .radial {
            let c = at(startPoint), e = at(endPoint)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                                   endRadius: hypot(e.x - c.x, e.y - c.y), options: [.drawsAfterEndLocation])
        } else {
            ctx.drawLinearGradient(g, start: at(startPoint), end: at(endPoint), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }
}
public struct CAGradientLayerType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let axial = Self(rawValue: "axial"), radial = Self(rawValue: "radial"), conic = Self(rawValue: "conic")
}

open class CATextLayer: CALayer, @unchecked Sendable {
    open var string: Any? { didSet { invalidate() } }
    open var font: AnyObject?
    open var fontSize: CGFloat = 36 { didSet { invalidate() } }
    open var foregroundColor: CGColor? = CGColor.white { didSet { invalidate() } }
    open var isWrapped = false
    open var truncationMode: CATextLayerTruncationMode = .none
    open var alignmentMode: CATextLayerAlignmentMode = .natural
}
public struct CATextLayerTruncationMode: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let none = Self(rawValue: "none"), start = Self(rawValue: "start"), end = Self(rawValue: "end"), middle = Self(rawValue: "middle")
}
public struct CATextLayerAlignmentMode: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let natural = Self(rawValue: "natural"), left = Self(rawValue: "left"), right = Self(rawValue: "right")
    public static let center = Self(rawValue: "center"), justified = Self(rawValue: "justified")
}

open class CAReplicatorLayer: CALayer, @unchecked Sendable {
    open var instanceCount = 1
    open var instanceDelay: CFTimeInterval = 0
    open var instanceTransform = CATransform3DIdentity
}
open class CAScrollLayer: CALayer, @unchecked Sendable {
    open func scroll(to p: CGPoint) { bounds.origin = p }
    open func scroll(_ r: CGRect) { bounds.origin = r.origin }
}
open class CATransformLayer: CALayer, @unchecked Sendable {}

/// A Metal-backed layer: there is no Metal device here, so it never has drawables.
open class CAMetalLayer: CALayer, @unchecked Sendable {
    open var device: (any MTLDevice)?
    open var preferredDevice: (any MTLDevice)? { nil }
    open var pixelFormat: MTLPixelFormat = .bgra8Unorm
    open var framebufferOnly = true
    open var drawableSize: CGSize = .zero
    open var maximumDrawableCount = 3
    open var presentsWithTransaction = false
    open var displaySyncEnabled = true
    open var allowsNextDrawableTimeout = true
    open var wantsExtendedDynamicRangeContent = false
    open var colorspace: CGColorSpace?
    open func nextDrawable() -> (any CAMetalDrawable)? { nil }
}
public protocol CAMetalDrawable: MTLDrawable {
    var texture: any MTLTexture { get }
    var layer: CAMetalLayer { get }
}

// MARK: Transactions

/// Groups layer changes; completion blocks run when the outermost commit
/// does (changes themselves apply immediately: there's no render server).
open class CATransaction: NSObject {
    private struct Frame {
        var disableActions = false
        var duration: CFTimeInterval = 0.25
        var timing: CAMediaTimingFunction?
        var completion: (() -> Void)?
        var values: [String: Any] = [:]
    }
    nonisolated(unsafe) private static var stack: [Frame] = []
    private static let mutex = NSRecursiveLock()

    open class func begin() { mutex.lock(); stack.append(Frame()); mutex.unlock() }
    open class func commit() {
        mutex.lock()
        let f = stack.popLast()
        mutex.unlock()
        f?.completion?()
    }
    open class func flush() {}
    open class func lock() { mutex.lock() }
    open class func unlock() { mutex.unlock() }
    private static func update(_ body: (inout Frame) -> Void) {
        mutex.lock(); defer { mutex.unlock() }
        if stack.isEmpty { stack.append(Frame()) ; body(&stack[0]); stack.removeAll(); return }
        body(&stack[stack.count - 1])
    }
    private static func read<T>(_ body: (Frame) -> T) -> T {
        mutex.lock(); defer { mutex.unlock() }
        return body(stack.last ?? Frame())
    }
    open class func animationDuration() -> CFTimeInterval { read { $0.duration } }
    open class func setAnimationDuration(_ d: CFTimeInterval) { update { $0.duration = d } }
    open class func animationTimingFunction() -> CAMediaTimingFunction? { read { $0.timing } }
    open class func setAnimationTimingFunction(_ f: CAMediaTimingFunction?) { update { $0.timing = f } }
    open class func disableActions() -> Bool { read { $0.disableActions } }
    open class func setDisableActions(_ flag: Bool) { update { $0.disableActions = flag } }
    open class func completionBlock() -> (() -> Void)? { read { $0.completion } }
    /// Outside a transaction the block runs right away.
    open class func setCompletionBlock(_ block: (() -> Void)?) {
        mutex.lock()
        let open = !stack.isEmpty
        if open { stack[stack.count - 1].completion = block }
        mutex.unlock()
        if !open { block?() }
    }
    open class func value(forKey key: String) -> Any? { read { $0.values[key] } }
    open class func setValue(_ anObject: Any?, forKey key: String) { update { $0.values[key] = anObject } }
}

// MARK: Animations

public struct CAMediaTimingFunctionName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let linear = Self(rawValue: "linear"), easeIn = Self(rawValue: "easeIn"), easeOut = Self(rawValue: "easeOut")
    public static let easeInEaseOut = Self(rawValue: "easeInEaseOut"), `default` = Self(rawValue: "default")
}
public struct CAMediaTimingFillMode: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let forwards = Self(rawValue: "forwards"), backwards = Self(rawValue: "backwards"), both = Self(rawValue: "both"), removed = Self(rawValue: "removed")
}
public struct CAAnimationCalculationMode: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let linear = Self(rawValue: "linear"), discrete = Self(rawValue: "discrete"), paced = Self(rawValue: "paced")
    public static let cubic = Self(rawValue: "cubic"), cubicPaced = Self(rawValue: "cubicPaced")
}
public struct CATransitionType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fade = Self(rawValue: "fade"), moveIn = Self(rawValue: "moveIn"), push = Self(rawValue: "push"), reveal = Self(rawValue: "reveal")
}
public struct CATransitionSubtype: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fromRight = Self(rawValue: "fromRight"), fromLeft = Self(rawValue: "fromLeft"), fromTop = Self(rawValue: "fromTop"), fromBottom = Self(rawValue: "fromBottom")
}

open class CAMediaTimingFunction: NSObject, @unchecked Sendable {
    public let controlPoints: (Float, Float, Float, Float)
    public init(name: CAMediaTimingFunctionName) {
        controlPoints = switch name {
        case .linear: (0, 0, 1, 1)
        case .easeIn: (0.42, 0, 1, 1)
        case .easeOut: (0, 0, 0.58, 1)
        case .easeInEaseOut: (0.42, 0, 0.58, 1)
        default: (0.25, 0.1, 0.25, 1)
        }
        super.init()
    }
    public init(controlPoints c1x: Float, _ c1y: Float, _ c2x: Float, _ c2y: Float) {
        controlPoints = (c1x, c1y, c2x, c2y)
        super.init()
    }
    open func getControlPoint(at idx: Int, values ptr: UnsafeMutablePointer<Float>) {
        let (a, b, c, d) = controlPoints
        switch idx {
        case 1: ptr[0] = a; ptr[1] = b
        case 2: ptr[0] = c; ptr[1] = d
        case 3: ptr[0] = 1; ptr[1] = 1
        default: ptr[0] = 0; ptr[1] = 0
        }
    }
}

public protocol CAAnimationDelegate: AnyObject {
    func animationDidStart(_ anim: CAAnimation)
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool)
}
extension CAAnimationDelegate {
    public func animationDidStart(_ anim: CAAnimation) {}
    public func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {}
}

open class CAAnimation: NSObject, CAAction, @unchecked Sendable {
    open var duration: CFTimeInterval = 0
    open var beginTime: CFTimeInterval = 0
    open var timeOffset: CFTimeInterval = 0
    open var speed: Float = 1
    open var repeatCount: Float = 0
    open var repeatDuration: CFTimeInterval = 0
    open var autoreverses = false
    open var fillMode: CAMediaTimingFillMode = .removed
    open var timingFunction: CAMediaTimingFunction?
    open var isRemovedOnCompletion = true
    open var delegate: CAAnimationDelegate?
    public required override init() { super.init() }
    open class func animation() -> Self { self.init() }
    open func run(forKey event: String, object anObject: Any, arguments dict: [AnyHashable: Any]?) {
        (anObject as? CALayer)?.add(self, forKey: event)
    }
}
open class CAPropertyAnimation: CAAnimation, @unchecked Sendable {
    open var keyPath: String?
    open var isAdditive = false
    open var isCumulative = false
    public convenience init(keyPath path: String?) { self.init(); keyPath = path }
}
open class CABasicAnimation: CAPropertyAnimation, @unchecked Sendable {
    open var fromValue: Any?
    open var toValue: Any?
    open var byValue: Any?
}
open class CASpringAnimation: CABasicAnimation, @unchecked Sendable {
    open var mass: CGFloat = 1
    open var stiffness: CGFloat = 100
    open var damping: CGFloat = 10
    open var initialVelocity: CGFloat = 0
    open var settlingDuration: CFTimeInterval { duration }
}
open class CAKeyframeAnimation: CAPropertyAnimation, @unchecked Sendable {
    open var values: [Any]?
    open var keyTimes: [NSNumber]?
    open var timingFunctions: [CAMediaTimingFunction]?
    open var calculationMode: CAAnimationCalculationMode = .linear
}
open class CAAnimationGroup: CAAnimation, @unchecked Sendable {
    open var animations: [CAAnimation]?
}
open class CATransition: CAAnimation, @unchecked Sendable {
    open var type: CATransitionType = .fade
    open var subtype: CATransitionSubtype?
    open var startProgress: Float = 0
    open var endProgress: Float = 1
}

/// Core Animation's value function names for transform animations.
public struct CAValueFunctionName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let rotateZ = Self(rawValue: "rotateZ"), scale = Self(rawValue: "scale"), translate = Self(rawValue: "translate")
}


// MARK: Display links

public struct CAFrameRateRange: Equatable, Sendable {
    public var minimum: Float, maximum: Float, preferred: Float
    public init() { minimum = 0; maximum = 0; preferred = 0 }
    public init(minimum: Float, maximum: Float, preferred: Float? = nil) { self.minimum = minimum; self.maximum = maximum; self.preferred = preferred ?? 0 }
    public static let `default` = CAFrameRateRange()
}

/// A timer in step with the display: here a 60 Hz timer on the run loop
/// it's added to (toolkits don't expose their frame clock per screen).
open class CADisplayLink: NSObject, @unchecked Sendable {
    private let handler: (CADisplayLink) -> Void
    private var timer: Timer?
    private var loops: [(RunLoop, RunLoop.Mode)] = []
    public private(set) var timestamp: CFTimeInterval = CACurrentMediaTime()
    public private(set) var targetTimestamp: CFTimeInterval = CACurrentMediaTime() + 1.0 / 60
    public var duration: CFTimeInterval { 1.0 / Double(framesPerSecond) }
    public var preferredFramesPerSecond: Int = 0 { didSet { reschedule() } }
    public var preferredFrameRateRange = CAFrameRateRange.default { didSet { reschedule() } }
    public var isPaused = false { didSet { reschedule() } }

    /// Runway: frameworks make display links around a callback.
    public init(_runwayHandler handler: @escaping (CADisplayLink) -> Void) {
        self.handler = handler
        super.init()
    }

    private var framesPerSecond: Int {
        if preferredFramesPerSecond > 0 { return min(preferredFramesPerSecond, 120) }
        if preferredFrameRateRange.preferred > 0 { return Int(min(preferredFrameRateRange.preferred, 120)) }
        return 60
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard !isPaused, !loops.isEmpty else { return }
        let interval = duration
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.timestamp = CACurrentMediaTime()
            self.targetTimestamp = self.timestamp + interval
            self.handler(self)
        }
        timer = t
        for (loop, mode) in loops { loop.add(t, forMode: mode) }
    }

    open func add(to runloop: RunLoop, forMode mode: RunLoop.Mode) {
        loops.append((runloop, mode))
        reschedule()
    }
    open func remove(from runloop: RunLoop, forMode mode: RunLoop.Mode) {
        loops.removeAll { $0.0 === runloop && $0.1 == mode }
        reschedule()
    }
    open func invalidate() {
        loops = []
        timer?.invalidate()
        timer = nil
    }
}


// MARK: Dynamic range

extension CALayer {
    public struct DynamicRange: RawRepresentable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let automatic = DynamicRange(rawValue: "automatic")
        public static let standard = DynamicRange(rawValue: "standard")
        public static let constrainedHigh = DynamicRange(rawValue: "constrainedHigh")
        public static let high = DynamicRange(rawValue: "high")
    }
    /// HDR isn't rendered: every layer is standard range, whatever is asked for.
    public var preferredDynamicRange: DynamicRange {
        get { (value(forKey: "preferredDynamicRange") as? DynamicRange) ?? .automatic }
        set { setValue(newValue, forKey: "preferredDynamicRange") }
    }
}
