// simd: Apple's vector and matrix library over the standard library's SIMD
// types. Vectors are SIMD2/3/4 (as on Apple platforms); matrices are
// column-major structs with the usual products, transpose and inverse.

public typealias simd_float2 = SIMD2<Float>
public typealias simd_float3 = SIMD3<Float>
public typealias simd_float4 = SIMD4<Float>
public typealias simd_double2 = SIMD2<Double>
public typealias simd_double3 = SIMD3<Double>
public typealias simd_double4 = SIMD4<Double>
public typealias simd_int2 = SIMD2<Int32>
public typealias simd_int3 = SIMD3<Int32>
public typealias simd_int4 = SIMD4<Int32>
public typealias simd_uint2 = SIMD2<UInt32>
public typealias simd_uint3 = SIMD3<UInt32>
public typealias simd_uint4 = SIMD4<UInt32>

// MARK: Functions

public func simd_dot<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { (a * b).sum() }
public func dot<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { (a * b).sum() }
public func simd_length<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_dot(v, v).squareRoot() }
public func length<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length(v) }
public func simd_length_squared<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_dot(v, v) }
public func simd_distance<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length(a - b) }
public func distance<V: SIMD>(_ a: V, _ b: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length(a - b) }
public func simd_normalize<V: SIMD>(_ v: V) -> V where V.Scalar: FloatingPoint { v / V(repeating: simd_length(v)) }
public func normalize<V: SIMD>(_ v: V) -> V where V.Scalar: FloatingPoint { simd_normalize(v) }
public func simd_mix<V: SIMD>(_ x: V, _ y: V, _ t: V) -> V where V.Scalar: FloatingPoint { x + t * (y - x) }
public func mix<V: SIMD>(_ x: V, _ y: V, t: V) -> V where V.Scalar: FloatingPoint { simd_mix(x, y, t) }
public func simd_mix<T: FloatingPoint>(_ x: T, _ y: T, _ t: T) -> T { x + t * (y - x) }
public func simd_clamp<V: SIMD>(_ x: V, _ lo: V, _ hi: V) -> V where V.Scalar: Comparable { x.clamped(lowerBound: lo, upperBound: hi) }
public func simd_clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T { min(max(x, lo), hi) }
public func clamp<V: SIMD>(_ x: V, min lo: V, max hi: V) -> V where V.Scalar: Comparable { x.clamped(lowerBound: lo, upperBound: hi) }
public func simd_min<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable { pointwiseMin(a, b) }
public func simd_max<V: SIMD>(_ a: V, _ b: V) -> V where V.Scalar: Comparable { pointwiseMax(a, b) }
public func simd_abs<V: SIMD>(_ v: V) -> V where V.Scalar: FloatingPoint { pointwiseMax(v, -v) }
public func simd_reduce_add<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: FloatingPoint { v.sum() }
public func simd_reduce_max<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: Comparable { v.max() }
public func simd_reduce_min<V: SIMD>(_ v: V) -> V.Scalar where V.Scalar: Comparable { v.min() }
public func simd_step<V: SIMD>(_ edge: V, _ x: V) -> V where V.Scalar: FloatingPoint {
    var r = V()
    for i in r.indices { r[i] = x[i] < edge[i] ? 0 : 1 }
    return r
}
public func simd_smoothstep<V: SIMD>(_ e0: V, _ e1: V, _ x: V) -> V where V.Scalar: FloatingPoint {
    var r = V()
    for i in r.indices {
        let t = min(max((x[i] - e0[i]) / (e1[i] - e0[i]), 0), 1)
        r[i] = t * t * (3 - 2 * t)
    }
    return r
}
public func simd_smoothstep<T: FloatingPoint>(_ e0: T, _ e1: T, _ x: T) -> T {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}
public func simd_cross<T: FloatingPoint>(_ a: SIMD3<T>, _ b: SIMD3<T>) -> SIMD3<T> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
public func cross<T: FloatingPoint>(_ a: SIMD3<T>, _ b: SIMD3<T>) -> SIMD3<T> { simd_cross(a, b) }
public func simd_make_float3(_ x: Float, _ y: Float, _ z: Float) -> simd_float3 { SIMD3(x, y, z) }
public func simd_make_double3(_ x: Double, _ y: Double, _ z: Double) -> simd_double3 { SIMD3(x, y, z) }
public func simd_precise_cbrt(_ x: Double) -> Double { x < 0 ? -pow3root(-x) : pow3root(x) }
private func pow3root(_ x: Double) -> Double {
    guard x != 0 else { return 0 }
    var y = x > 1 ? x / 3 : x
    for _ in 0..<60 { y = (2 * y + x / (y * y)) / 3 }
    return y
}

// MARK: Matrices

/// An N×N column-major matrix over SIMD columns.
public protocol _SquareMatrix: Equatable {
    associatedtype Column: SIMD where Column.Scalar: FloatingPoint
    var columns: [Column] { get set }
    init(columns: [Column])
}

extension _SquareMatrix {
    public typealias Scalar = Column.Scalar
    static var n: Int { Column.scalarCount }
    public init() { self.init(columns: (0..<Column.scalarCount).map { _ in Column() }) }
    public init(diagonal d: Column) {
        var cols = (0..<Column.scalarCount).map { _ in Column() }
        for i in 0..<Column.scalarCount { cols[i][i] = d[i] }
        self.init(columns: cols)
    }
    public init(_ scalar: Scalar) { self.init(diagonal: Column(repeating: scalar)) }
    public init(rows: [Column]) {
        var cols = (0..<Column.scalarCount).map { _ in Column() }
        for r in 0..<Column.scalarCount { for c in 0..<Column.scalarCount { cols[c][r] = rows[r][c] } }
        self.init(columns: cols)
    }
    public init(_ columns: [Column]) { self.init(columns: columns) }
    public subscript(column: Int) -> Column {
        get { columns[column] }
        set { columns[column] = newValue }
    }
    public subscript(column: Int, row: Int) -> Scalar {
        get { columns[column][row] }
        set { columns[column][row] = newValue }
    }
    public var transpose: Self {
        var cols = columns
        for r in 0..<Self.n { for c in 0..<Self.n { cols[c][r] = columns[r][c] } }
        return Self(columns: cols)
    }
    public var inverse: Self {
        // Gauss–Jordan on rows.
        let n = Self.n
        var a = (0..<n).map { r in (0..<n).map { c in columns[c][r] } }
        var inv = (0..<n).map { r in (0..<n).map { c in r == c ? Scalar(1) : Scalar(0) } }
        for col in 0..<n {
            var pivot = col
            for r in col..<n where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            a.swapAt(col, pivot); inv.swapAt(col, pivot)
            let p = a[col][col]
            guard p != 0 else { return self }
            for c in 0..<n { a[col][c] /= p; inv[col][c] /= p }
            for r in 0..<n where r != col {
                let f = a[r][col]
                for c in 0..<n { a[r][c] -= f * a[col][c]; inv[r][c] -= f * inv[col][c] }
            }
        }
        var cols = (0..<n).map { _ in Column() }
        for r in 0..<n { for c in 0..<n { cols[c][r] = inv[r][c] } }
        return Self(columns: cols)
    }
    public var determinant: Scalar {
        let n = Self.n
        var a = (0..<n).map { r in (0..<n).map { c in columns[c][r] } }
        var det = Scalar(1)
        for col in 0..<n {
            var pivot = col
            for r in col..<n where abs(a[r][col]) > abs(a[pivot][col]) { pivot = r }
            if pivot != col { a.swapAt(col, pivot); det = -det }
            let p = a[col][col]
            if p == 0 { return 0 }
            det *= p
            for r in (col + 1)..<n {
                let f = a[r][col] / p
                for c in col..<n { a[r][c] -= f * a[col][c] }
            }
        }
        return det
    }

    public static func * (m: Self, v: Column) -> Column {
        var r = Column()
        for c in 0..<n { r += m.columns[c] * Column(repeating: v[c]) }
        return r
    }
    public static func * (v: Column, m: Self) -> Column { m.transpose * v }
    public static func * (a: Self, b: Self) -> Self { Self(columns: b.columns.map { a * $0 }) }
    public static func * (a: Self, s: Scalar) -> Self { Self(columns: a.columns.map { $0 * Column(repeating: s) }) }
    public static func + (a: Self, b: Self) -> Self { Self(columns: zip(a.columns, b.columns).map { $0 + $1 }) }
    public static func - (a: Self, b: Self) -> Self { Self(columns: zip(a.columns, b.columns).map { $0 - $1 }) }
}

public struct simd_double2x2: _SquareMatrix { public var columns: [SIMD2<Double>]; public init(columns: [SIMD2<Double>]) { self.columns = columns } }
public struct simd_double3x3: _SquareMatrix { public var columns: [SIMD3<Double>]; public init(columns: [SIMD3<Double>]) { self.columns = columns } }
public struct simd_double4x4: _SquareMatrix { public var columns: [SIMD4<Double>]; public init(columns: [SIMD4<Double>]) { self.columns = columns } }
public struct simd_float2x2: _SquareMatrix { public var columns: [SIMD2<Float>]; public init(columns: [SIMD2<Float>]) { self.columns = columns } }
public struct simd_float3x3: _SquareMatrix { public var columns: [SIMD3<Float>]; public init(columns: [SIMD3<Float>]) { self.columns = columns } }
public struct simd_float4x4: _SquareMatrix { public var columns: [SIMD4<Float>]; public init(columns: [SIMD4<Float>]) { self.columns = columns } }

public typealias double2x2 = simd_double2x2
public typealias double3x3 = simd_double3x3
public typealias double4x4 = simd_double4x4
public typealias float2x2 = simd_float2x2
public typealias float3x3 = simd_float3x3
public typealias float4x4 = simd_float4x4

public func simd_mul<M: _SquareMatrix>(_ m: M, _ v: M.Column) -> M.Column { m * v }
public func simd_mul<M: _SquareMatrix>(_ a: M, _ b: M) -> M { a * b }
public func simd_inverse<M: _SquareMatrix>(_ m: M) -> M { m.inverse }
public func simd_transpose<M: _SquareMatrix>(_ m: M) -> M { m.transpose }
public func simd_determinant<M: _SquareMatrix>(_ m: M) -> M.Column.Scalar { m.determinant }
public func matrix_multiply<M: _SquareMatrix>(_ a: M, _ b: M) -> M { a * b }
public func matrix_multiply<M: _SquareMatrix>(_ m: M, _ v: M.Column) -> M.Column { m * v }
public let matrix_identity_float4x4 = simd_float4x4(1)
public let matrix_identity_double4x4 = simd_double4x4(1)
public let matrix_identity_float3x3 = simd_float3x3(1)
public let matrix_identity_double3x3 = simd_double3x3(1)
