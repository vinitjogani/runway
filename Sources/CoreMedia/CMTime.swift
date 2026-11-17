// CoreMedia time: CMTime, CMTimeRange and CMTimeMapping with Core Media's
// exact rational arithmetic (common timescales, least common multiples,
// overflow to infinity), its ordering of the special values, rounding
// methods, and the C function names alongside the Swift operators.

@_exported import CoreVideo
@_exported import Foundation

public typealias CMTimeValue = Int64
public typealias CMTimeScale = Int32
public typealias CMTimeEpoch = Int64
public let kCMTimeMaxTimescale: CMTimeScale = 0x7fff_ffff

public struct CMTimeFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let valid = CMTimeFlags(rawValue: 1 << 0)
    public static let hasBeenRounded = CMTimeFlags(rawValue: 1 << 1)
    public static let positiveInfinity = CMTimeFlags(rawValue: 1 << 2)
    public static let negativeInfinity = CMTimeFlags(rawValue: 1 << 3)
    public static let indefinite = CMTimeFlags(rawValue: 1 << 4)
    public static let impliedValueFlagsMask: CMTimeFlags = [.positiveInfinity, .negativeInfinity, .indefinite]
}

public enum CMTimeRoundingMethod: UInt32, Sendable {
    case roundHalfAwayFromZero = 1, roundTowardZero = 2, roundAwayFromZero = 3, quickTime = 4
    case roundTowardPositiveInfinity = 5, roundTowardNegativeInfinity = 6
    public static let `default` = CMTimeRoundingMethod.roundHalfAwayFromZero
}

public struct CMTime: Sendable {
    public var value: CMTimeValue
    public var timescale: CMTimeScale
    public var flags: CMTimeFlags
    public var epoch: CMTimeEpoch

    public init(value: CMTimeValue, timescale: CMTimeScale, flags: CMTimeFlags, epoch: CMTimeEpoch) {
        self.value = value
        self.timescale = timescale
        self.flags = flags
        self.epoch = epoch
    }

    /// A numeric time; a timescale ≤ 0 makes it invalid, as Core Media does.
    public init(value: CMTimeValue, timescale: CMTimeScale) {
        self.init(value: value, timescale: timescale, flags: timescale > 0 ? .valid : [], epoch: 0)
    }

    public init(seconds: Double, preferredTimescale: CMTimeScale) {
        self = CMTimeMakeWithSeconds(seconds, preferredTimescale: preferredTimescale)
    }

    public init() { self.init(value: 0, timescale: 0, flags: [], epoch: 0) }

    public static let zero = CMTime(value: 0, timescale: 1)
    public static let invalid = CMTime(value: 0, timescale: 0, flags: [], epoch: 0)
    public static let indefinite = CMTime(value: 0, timescale: 0, flags: [.valid, .indefinite], epoch: 0)
    public static let positiveInfinity = CMTime(value: 0, timescale: 0, flags: [.valid, .positiveInfinity], epoch: 0)
    public static let negativeInfinity = CMTime(value: 0, timescale: 0, flags: [.valid, .negativeInfinity], epoch: 0)

    public var isValid: Bool { flags.contains(.valid) }
    public var isNumeric: Bool { isValid && flags.isDisjoint(with: .impliedValueFlagsMask) }
    public var isIndefinite: Bool { isValid && flags.contains(.indefinite) }
    public var isPositiveInfinity: Bool { isValid && flags.contains(.positiveInfinity) }
    public var isNegativeInfinity: Bool { isValid && flags.contains(.negativeInfinity) }
    public var hasBeenRounded: Bool { isNumeric && flags.contains(.hasBeenRounded) }

    public var seconds: Double { CMTimeGetSeconds(self) }

    public func convertScale(_ newTimescale: Int32, method: CMTimeRoundingMethod) -> CMTime {
        CMTimeConvertScale(self, timescale: newTimescale, method: method)
    }
}

// MARK: Helpers

@inline(__always) func gcd(_ a: Int64, _ b: Int64) -> Int64 {
    var (a, b) = (abs(a), abs(b))
    while b != 0 { (a, b) = (b, a % b) }
    return a
}

/// `n / d` rounded by `method` (d > 0).
func divide(_ n: Int64, _ d: Int64, _ method: CMTimeRoundingMethod) -> (Int64, Bool) {
    let q = n / d, r = n % d
    guard r != 0 else { return (q, false) }
    let away: Int64 = n < 0 ? q - 1 : q + 1
    switch method {
    case .roundTowardZero: return (q, true)
    case .roundAwayFromZero: return (away, true)
    case .roundTowardPositiveInfinity: return (n < 0 ? q : q + 1, true)
    case .roundTowardNegativeInfinity: return (n < 0 ? q - 1 : q, true)
    case .roundHalfAwayFromZero, .quickTime:
        // |r| * 2 >= d without overflow.
        return (abs(r) >= d - abs(r) ? away : q, true)
    }
}

/// `value * newScale / oldScale`, exactly when it fits.
func rescale(_ value: Int64, from old: Int32, to new: Int32, _ method: CMTimeRoundingMethod) -> (Int64, Bool)? {
    if old == new { return (value, false) }
    let (p, overflow) = value.multipliedReportingOverflow(by: Int64(new))
    if !overflow { return divide(p, Int64(old), method) }
    // Reduce first: value * (new/g) / (old/g).
    let g = gcd(Int64(old), Int64(new))
    let (p2, o2) = value.multipliedReportingOverflow(by: Int64(new) / g)
    if !o2 { return divide(p2, Int64(old) / g, method) }
    let d = Double(value) * Double(new) / Double(old)
    guard abs(d) < 9.2e18 else { return nil }
    return (Int64(d.rounded()), true)
}

// MARK: Construction and conversion

public func CMTimeMake(value: Int64, timescale: Int32) -> CMTime { CMTime(value: value, timescale: timescale) }
public func CMTimeMakeWithEpoch(value: Int64, timescale: Int32, epoch: Int64) -> CMTime {
    CMTime(value: value, timescale: timescale, flags: timescale > 0 ? .valid : [], epoch: epoch)
}
public func CMTimeMakeWithSeconds(_ seconds: Float64, preferredTimescale: Int32) -> CMTime {
    if seconds.isNaN || preferredTimescale <= 0 { return .invalid }
    if seconds == .infinity { return .positiveInfinity }
    if seconds == -.infinity { return .negativeInfinity }
    // Like Core Media: a timescale that would overflow is halved until it fits.
    var ts = preferredTimescale
    while ts > 1, abs(seconds * Double(ts)) >= 9.2e18 { ts /= 2 }
    let exact = seconds * Double(ts)
    guard abs(exact) < 9.2e18 else { return seconds > 0 ? .positiveInfinity : .negativeInfinity }
    let v = exact.rounded()
    return CMTime(value: Int64(v), timescale: ts, flags: v == exact ? .valid : [.valid, .hasBeenRounded], epoch: 0)
}

public func CMTimeGetSeconds(_ t: CMTime) -> Float64 {
    if t.isPositiveInfinity { return .infinity }
    if t.isNegativeInfinity { return -.infinity }
    guard t.isNumeric, t.timescale != 0 else { return .nan }
    return Double(t.value) / Double(t.timescale)
}

public func CMTimeConvertScale(_ t: CMTime, timescale: Int32, method: CMTimeRoundingMethod) -> CMTime {
    guard t.isNumeric else { return t }
    guard timescale > 0 else { return .invalid }
    guard let (v, rounded) = rescale(t.value, from: t.timescale, to: timescale, method) else {
        return t.value > 0 ? .positiveInfinity : .negativeInfinity
    }
    var f = t.flags
    if rounded { f.insert(.hasBeenRounded) }
    return CMTime(value: v, timescale: timescale, flags: f, epoch: t.epoch)
}

// MARK: Arithmetic

private func special(_ a: CMTime, _ b: CMTime, subtract: Bool) -> CMTime? {
    if !a.isValid || !b.isValid { return .invalid }
    if a.isIndefinite || b.isIndefinite { return .indefinite }
    let bPos = subtract ? b.isNegativeInfinity : b.isPositiveInfinity
    let bNeg = subtract ? b.isPositiveInfinity : b.isNegativeInfinity
    if (a.isPositiveInfinity && bNeg) || (a.isNegativeInfinity && bPos) { return .invalid }
    if a.isPositiveInfinity || bPos { return .positiveInfinity }
    if a.isNegativeInfinity || bNeg { return .negativeInfinity }
    return nil
}

private func combine(_ a: CMTime, _ b: CMTime, subtract: Bool) -> CMTime {
    if let s = special(a, b, subtract: subtract) { return s }
    let rounded = a.flags.contains(.hasBeenRounded) || b.flags.contains(.hasBeenRounded)
    func make(_ v: Int64, _ ts: Int32, _ r: Bool) -> CMTime {
        CMTime(value: v, timescale: ts, flags: (r || rounded) ? [.valid, .hasBeenRounded] : .valid, epoch: a.epoch)
    }
    func op(_ x: Int64, _ y: Int64) -> (Int64, Bool) { subtract ? x.subtractingReportingOverflow(y) : x.addingReportingOverflow(y) }
    func overflowed(_ x: Int64, _ y: Int64) -> CMTime {
        let d = subtract ? Double(x) - Double(y) : Double(x) + Double(y)
        return d > 0 ? .positiveInfinity : .negativeInfinity
    }
    if a.timescale == b.timescale {
        let (v, o) = op(a.value, b.value)
        return o ? overflowed(a.value, b.value) : make(v, a.timescale, false)
    }
    // The least common multiple of the timescales, when it fits: exact.
    let g = gcd(Int64(a.timescale), Int64(b.timescale))
    let lcm = Int64(a.timescale) / g * Int64(b.timescale)
    if lcm <= Int64(kCMTimeMaxTimescale) {
        let (x, o1) = a.value.multipliedReportingOverflow(by: lcm / Int64(a.timescale))
        let (y, o2) = b.value.multipliedReportingOverflow(by: lcm / Int64(b.timescale))
        if !o1 && !o2 {
            let (v, o) = op(x, y)
            if !o { return make(v, Int32(lcm), false) }
        }
    }
    // Otherwise the larger timescale, rounded.
    let ts = max(a.timescale, b.timescale)
    guard let (x, r1) = rescale(a.value, from: a.timescale, to: ts, .default),
          let (y, r2) = rescale(b.value, from: b.timescale, to: ts, .default) else { return overflowed(a.value, b.value) }
    let (v, o) = op(x, y)
    return o ? overflowed(x, y) : make(v, ts, r1 || r2)
}

public func CMTimeAdd(_ lhs: CMTime, _ rhs: CMTime) -> CMTime { combine(lhs, rhs, subtract: false) }
public func CMTimeSubtract(_ lhs: CMTime, _ rhs: CMTime) -> CMTime { combine(lhs, rhs, subtract: true) }

public func CMTimeMultiply(_ time: CMTime, multiplier: Int32) -> CMTime {
    guard time.isValid else { return .invalid }
    if time.isIndefinite { return .indefinite }
    if time.isPositiveInfinity || time.isNegativeInfinity {
        if multiplier == 0 { return .invalid }
        return (time.isPositiveInfinity) == (multiplier > 0) ? .positiveInfinity : .negativeInfinity
    }
    let (v, o) = time.value.multipliedReportingOverflow(by: Int64(multiplier))
    if o { return (time.value > 0) == (multiplier > 0) ? .positiveInfinity : .negativeInfinity }
    return CMTime(value: v, timescale: time.timescale, flags: time.flags, epoch: time.epoch)
}

public func CMTimeMultiplyByFloat64(_ time: CMTime, multiplier: Float64) -> CMTime {
    guard time.isValid, !multiplier.isNaN else { return .invalid }
    if time.isIndefinite { return .indefinite }
    if time.isPositiveInfinity || time.isNegativeInfinity || multiplier.isInfinite {
        if multiplier == 0 || (time.isNumeric && time.value == 0) { return .invalid }
        let positive = (time.isNegativeInfinity || (time.isNumeric && time.value < 0)) == (multiplier < 0)
        return positive ? .positiveInfinity : .negativeInfinity
    }
    let exact = Double(time.value) * multiplier
    guard abs(exact) < 9.2e18 else { return exact > 0 ? .positiveInfinity : .negativeInfinity }
    let v = exact.rounded()
    var f = time.flags
    if v != exact { f.insert(.hasBeenRounded) }
    return CMTime(value: Int64(v), timescale: time.timescale, flags: f, epoch: time.epoch)
}

public func CMTimeMultiplyByRatio(_ time: CMTime, multiplier: Int32, divisor: Int32) -> CMTime {
    guard time.isValid, divisor != 0 else { return .invalid }
    guard time.isNumeric else { return CMTimeMultiply(time, multiplier: multiplier.signum() * divisor.signum()) }
    let (p, o) = time.value.multipliedReportingOverflow(by: Int64(multiplier))
    let (v, r): (Int64, Bool)
    if o {
        let d = Double(time.value) * Double(multiplier) / Double(divisor)
        guard abs(d) < 9.2e18 else { return d > 0 ? .positiveInfinity : .negativeInfinity }
        (v, r) = (Int64(d.rounded()), true)
    } else {
        let sign: Int64 = divisor < 0 ? -1 : 1
        (v, r) = divide(p * sign, abs(Int64(divisor)), .default)
    }
    var f = time.flags
    if r { f.insert(.hasBeenRounded) }
    return CMTime(value: v, timescale: time.timescale, flags: f, epoch: time.epoch)
}

/// Core Media's order: −∞ < numeric < indefinite < +∞ < invalid.
public func CMTimeCompare(_ a: CMTime, _ b: CMTime) -> Int32 {
    func rank(_ t: CMTime) -> Int {
        if !t.isValid { return 4 }
        if t.isPositiveInfinity { return 3 }
        if t.isIndefinite { return 2 }
        if t.isNegativeInfinity { return 0 }
        return 1
    }
    let (ra, rb) = (rank(a), rank(b))
    if ra != rb { return ra < rb ? -1 : 1 }
    guard ra == 1 else { return 0 }
    if a.epoch != b.epoch { return a.epoch < b.epoch ? -1 : 1 }
    if a.timescale == b.timescale { return a.value == b.value ? 0 : (a.value < b.value ? -1 : 1) }
    // a.value / a.ts vs b.value / b.ts, exactly: cross-multiply in 128 bits.
    let l = a.value.multipliedFullWidth(by: Int64(b.timescale))
    let r = b.value.multipliedFullWidth(by: Int64(a.timescale))
    if l.high != r.high { return l.high < r.high ? -1 : 1 }
    if l.low != r.low { return l.low < r.low ? -1 : 1 }
    return 0
}

public func CMTimeMinimum(_ a: CMTime, _ b: CMTime) -> CMTime {
    if !a.isValid { return b }
    if !b.isValid { return a }
    return CMTimeCompare(a, b) <= 0 ? a : b
}
public func CMTimeMaximum(_ a: CMTime, _ b: CMTime) -> CMTime {
    if !a.isValid { return b }
    if !b.isValid { return a }
    return CMTimeCompare(a, b) >= 0 ? a : b
}
public func CMTimeAbsoluteValue(_ t: CMTime) -> CMTime {
    if t.isNegativeInfinity { return .positiveInfinity }
    guard t.isNumeric, t.value < 0 else { return t }
    var r = t
    r.value = t.value == .min ? .max : -t.value
    return r
}
public func CMTimeShow(_ t: CMTime) { print(t) }
public func CMTimeCopyDescription(allocator: AnyObject?, time: CMTime) -> CFString? { NSString(string: time.description) }

// MARK: Swift conformances and operators

extension CMTime: Comparable, Hashable {
    public static func == (a: CMTime, b: CMTime) -> Bool { CMTimeCompare(a, b) == 0 }
    public static func < (a: CMTime, b: CMTime) -> Bool { CMTimeCompare(a, b) < 0 }
    public func hash(into h: inout Hasher) {
        if isNumeric {
            let g = max(gcd(value, Int64(timescale)), 1)
            h.combine(value / g)
            h.combine(Int64(timescale) / g)
            h.combine(epoch)
        } else {
            h.combine(flags.intersection([.valid, .impliedValueFlagsMask]).rawValue)
        }
    }

    public static func + (a: CMTime, b: CMTime) -> CMTime { CMTimeAdd(a, b) }
    public static func - (a: CMTime, b: CMTime) -> CMTime { CMTimeSubtract(a, b) }
    public static prefix func - (t: CMTime) -> CMTime { CMTimeSubtract(.zero, t) }
    public static func += (a: inout CMTime, b: CMTime) { a = a + b }
    public static func -= (a: inout CMTime, b: CMTime) { a = a - b }
    public static func * (t: CMTime, m: Int32) -> CMTime { CMTimeMultiply(t, multiplier: m) }
    public static func * (m: Int32, t: CMTime) -> CMTime { CMTimeMultiply(t, multiplier: m) }
    public static func * (t: CMTime, m: Float64) -> CMTime { CMTimeMultiplyByFloat64(t, multiplier: m) }
    public static func * (m: Float64, t: CMTime) -> CMTime { CMTimeMultiplyByFloat64(t, multiplier: m) }
    public static func *= (t: inout CMTime, m: Int32) { t = t * m }
    public static func *= (t: inout CMTime, m: Float64) { t = t * m }
}

extension CMTime: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        if !isValid { return "CMTime(invalid)" }
        if isPositiveInfinity { return "CMTime(+infinity)" }
        if isNegativeInfinity { return "CMTime(-infinity)" }
        if isIndefinite { return "CMTime(indefinite)" }
        return "CMTime(value: \(value), timescale: \(timescale), seconds: \(seconds)\(hasBeenRounded ? ", rounded" : ""))"
    }
    public var debugDescription: String { description }
}

extension CMTime: Codable {
    enum CodingKeys: String, CodingKey { case value, timescale, flags, epoch }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(value: try c.decode(Int64.self, forKey: .value), timescale: try c.decode(Int32.self, forKey: .timescale),
                  flags: CMTimeFlags(rawValue: try c.decode(UInt32.self, forKey: .flags)), epoch: try c.decode(Int64.self, forKey: .epoch))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(timescale, forKey: .timescale)
        try c.encode(flags.rawValue, forKey: .flags)
        try c.encode(epoch, forKey: .epoch)
    }
}

// MARK: Ranges

public struct CMTimeRange: Sendable, Hashable, Codable {
    public var start: CMTime
    public var duration: CMTime
    public init(start: CMTime, duration: CMTime) {
        self.start = start
        self.duration = duration
    }
    public init(start: CMTime, end: CMTime) { self.init(start: start, duration: end - start) }
    public init() { self.init(start: .invalid, duration: .invalid) }

    public static let zero = CMTimeRange(start: .zero, duration: .zero)
    public static let invalid = CMTimeRange(start: .invalid, duration: .invalid)

    public var end: CMTime { CMTimeRangeGetEnd(self) }
    public var isValid: Bool { start.isValid && duration.isValid && duration.epoch == 0 && CMTimeCompare(duration, .zero) >= 0 }
    public var isIndefinite: Bool { isValid && (start.isIndefinite || duration.isIndefinite) }
    public var isEmpty: Bool { isValid && CMTimeCompare(duration, .zero) == 0 }

    public func containsTime(_ t: CMTime) -> Bool { CMTimeRangeContainsTime(self, time: t) }
    public func containsTimeRange(_ r: CMTimeRange) -> Bool { CMTimeRangeContainsTimeRange(self, otherRange: r) }
    public func intersection(_ r: CMTimeRange) -> CMTimeRange { CMTimeRangeGetIntersection(self, otherRange: r) }
    public func union(_ r: CMTimeRange) -> CMTimeRange { CMTimeRangeGetUnion(self, otherRange: r) }

    public static func == (a: CMTimeRange, b: CMTimeRange) -> Bool { a.start == b.start && a.duration == b.duration }
}

extension CMTimeRange: CustomStringConvertible {
    public var description: String { isValid ? "CMTimeRange(\(start.seconds)…\(end.seconds))" : "CMTimeRange(invalid)" }
}

public func CMTimeRangeMake(start: CMTime, duration: CMTime) -> CMTimeRange { CMTimeRange(start: start, duration: duration) }
public func CMTimeRangeFromTimeToTime(start: CMTime, end: CMTime) -> CMTimeRange { CMTimeRange(start: start, end: end) }
public func CMTimeRangeGetEnd(_ r: CMTimeRange) -> CMTime {
    guard r.start.isValid, r.duration.isValid else { return .invalid }
    return r.start + r.duration
}
public func CMTimeRangeContainsTime(_ r: CMTimeRange, time t: CMTime) -> Bool {
    guard r.isValid, t.isValid else { return false }
    return CMTimeCompare(t, r.start) >= 0 && CMTimeCompare(t, r.end) < 0
}
public func CMTimeRangeContainsTimeRange(_ r: CMTimeRange, otherRange o: CMTimeRange) -> Bool {
    guard r.isValid, o.isValid else { return false }
    return CMTimeCompare(o.start, r.start) >= 0 && CMTimeCompare(o.end, r.end) <= 0
}
public func CMTimeRangeGetIntersection(_ r: CMTimeRange, otherRange o: CMTimeRange) -> CMTimeRange {
    guard r.isValid, o.isValid else { return .invalid }
    let s = CMTimeMaximum(r.start, o.start), e = CMTimeMinimum(r.end, o.end)
    return CMTimeCompare(s, e) < 0 ? CMTimeRange(start: s, end: e) : .zero
}
public func CMTimeRangeGetUnion(_ r: CMTimeRange, otherRange o: CMTimeRange) -> CMTimeRange {
    guard r.isValid, o.isValid else { return .invalid }
    return CMTimeRange(start: CMTimeMinimum(r.start, o.start), end: CMTimeMaximum(r.end, o.end))
}
public func CMTimeRangeEqual(_ a: CMTimeRange, _ b: CMTimeRange) -> Bool { a == b }
public func CMTimeClampToRange(_ t: CMTime, range r: CMTimeRange) -> CMTime {
    guard r.isValid, t.isValid else { return .invalid }
    if CMTimeCompare(t, r.start) < 0 { return r.start }
    if CMTimeCompare(t, r.end) > 0 { return r.end }
    return t
}
/// Maps `t` linearly from `from` onto `to` (as a scaled edit does).
public func CMTimeMapTimeFromRangeToRange(_ t: CMTime, fromRange from: CMTimeRange, toRange to: CMTimeRange) -> CMTime {
    guard from.isValid, to.isValid, t.isNumeric else { return .invalid }
    if from.duration == .zero { return to.start }
    let offset = t - from.start
    let scaled = CMTimeMultiplyByFloat64(offset, multiplier: to.duration.seconds / from.duration.seconds)
    if from.duration == to.duration { return to.start + offset }
    return to.start + scaled
}
public func CMTimeMapDurationFromRangeToRange(_ d: CMTime, fromRange from: CMTimeRange, toRange to: CMTimeRange) -> CMTime {
    guard from.isValid, to.isValid, d.isNumeric else { return .invalid }
    if from.duration == to.duration { return d }
    guard from.duration != .zero else { return .zero }
    return CMTimeMultiplyByFloat64(d, multiplier: to.duration.seconds / from.duration.seconds)
}
public func CMTimeFoldIntoRange(_ t: CMTime, range r: CMTimeRange) -> CMTime {
    guard r.isValid, t.isNumeric, r.duration.seconds > 0 else { return .invalid }
    let off = (t - r.start).seconds.truncatingRemainder(dividingBy: r.duration.seconds)
    return r.start + CMTime(seconds: off < 0 ? off + r.duration.seconds : off, preferredTimescale: max(t.timescale, r.start.timescale))
}
public func CMTimeRangeShow(_ r: CMTimeRange) { print(r) }

// MARK: Mappings

public struct CMTimeMapping: Sendable, Hashable, Codable {
    public var source: CMTimeRange
    public var target: CMTimeRange
    public init(source: CMTimeRange, target: CMTimeRange) {
        self.source = source
        self.target = target
    }
    public init() { self.init(source: .invalid, target: .invalid) }
    /// An empty edit: nothing plays over `target`.
    public init(target: CMTimeRange) { self.init(source: .invalid, target: target) }
    public var isEmpty: Bool { !source.start.isNumeric }
    public var isValid: Bool { target.isValid && (isEmpty || source.isValid) }
}

public func CMTimeMappingMake(source: CMTimeRange, target: CMTimeRange) -> CMTimeMapping { CMTimeMapping(source: source, target: target) }
public func CMTimeMappingMakeEmpty(target: CMTimeRange) -> CMTimeMapping { CMTimeMapping(target: target) }
