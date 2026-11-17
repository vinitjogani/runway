// Swift Charts: marks collected by a result builder and drawn with
// SwiftUI's Canvas. Bars, lines, areas, points, rules, rectangles and
// sectors (pie and donut) over numeric, date or categorical (string)
// values; automatic domains (or chartXScale/chartYScale), the default
// palette by series, foreground styles, and the chart modifiers apps use.
// Axes, legends and annotations aren't drawn yet.

@_exported import SwiftUI
import Foundation

// MARK: Values

public protocol Plottable {
    var _plotValue: _PlotValue { get }
}

public enum _PlotValue: Hashable {
    case number(Double)
    case category(String)
    var number: Double? { if case .number(let d) = self { return d }; return nil }
}

extension Int: Plottable { public var _plotValue: _PlotValue { .number(Double(self)) } }
extension Double: Plottable { public var _plotValue: _PlotValue { .number(self) } }
extension Float: Plottable { public var _plotValue: _PlotValue { .number(Double(self)) } }
extension CGFloat: Plottable { public var _plotValue: _PlotValue { .number(Double(self)) } }
extension Int64: Plottable { public var _plotValue: _PlotValue { .number(Double(self)) } }
extension UInt64: Plottable { public var _plotValue: _PlotValue { .number(Double(self)) } }
extension Date: Plottable { public var _plotValue: _PlotValue { .number(timeIntervalSinceReferenceDate) } }
extension String: Plottable { public var _plotValue: _PlotValue { .category(self) } }

public struct PlottableValue<Value: Plottable> {
    let label: String
    let value: Value
    public static func value(_ label: LocalizedStringKey, _ value: Value) -> PlottableValue { PlottableValue(label: "\(label)", value: value) }
    @_disfavoredOverload
    public static func value<S: StringProtocol>(_ label: S, _ value: Value) -> PlottableValue { PlottableValue(label: String(label), value: value) }
    public static func value(_ label: Text, _ value: Value) -> PlottableValue { PlottableValue(label: "", value: value) }
}

extension PlottableValue where Value == Date {
    public static func value(_ label: LocalizedStringKey, _ value: Date, unit: Calendar.Component) -> PlottableValue {
        PlottableValue(label: "\(label)", value: value)
    }
}

public enum MarkDimension: Sendable, Equatable {
    case automatic, inset(CGFloat), ratio(CGFloat), fixed(CGFloat)
}

// MARK: Marks

/// One drawable mark, as the chart lays it out.
public struct _Mark {
    enum Kind { case bar, line, area, point, rule, rectangle, sector }
    var kind: Kind
    public var x: _PlotValue?
    public var y: _PlotValue?
    var x2: _PlotValue?
    var y2: _PlotValue?
    public var angle: Double?
    var innerRadius: MarkDimension = .automatic
    var outerRadius: MarkDimension = .automatic
    var angularInset: CGFloat = 0
    var series: String?
    var style: AnyShapeStyle?
    var lineWidth: CGFloat = 2
    var opacity: Double = 1
    var width: MarkDimension = .automatic
}

public protocol ChartContent {
    var _marks: [_Mark] { get }
}

@resultBuilder
public enum ChartContentBuilder {
    public static func buildExpression<C: ChartContent>(_ c: C) -> C { c }
    public static func buildBlock() -> _ChartGroup { _ChartGroup(marks: []) }
    public static func buildBlock<each C: ChartContent>(_ c: repeat each C) -> _ChartGroup {
        var all: [_Mark] = []
        for x in repeat each c { all += x._marks }
        return _ChartGroup(marks: all)
    }
    public static func buildOptional(_ c: _ChartGroup?) -> _ChartGroup { c ?? _ChartGroup(marks: []) }
    public static func buildEither(first: _ChartGroup) -> _ChartGroup { first }
    public static func buildEither(second: _ChartGroup) -> _ChartGroup { second }
    public static func buildArray<C: ChartContent>(_ c: [C]) -> _ChartGroup { _ChartGroup(marks: c.flatMap(\._marks)) }
    public static func buildLimitedAvailability<C: ChartContent>(_ c: C) -> _ChartGroup { _ChartGroup(marks: c._marks) }
}

public struct _ChartGroup: ChartContent { public let _marks: [_Mark]; init(marks: [_Mark]) { _marks = marks } }

extension ForEach: ChartContent where Content: ChartContent {
    public var _marks: [_Mark] { data.flatMap { content($0)._marks } }
}

extension ForEach where Content: ChartContent {
    public init(_ data: Data, @ChartContentBuilder content: @escaping (Data.Element) -> Content) where Data.Element: Identifiable, ID == Data.Element.ID {
        self.init(_runwayData: data, id: { $0.id }, content: content)
    }
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ChartContentBuilder content: @escaping (Data.Element) -> Content) {
        self.init(_runwayData: data, id: { $0[keyPath: id] }, content: content)
    }
}

/// A mark with modifiers applied.
public struct _ModifiedMark: ChartContent {
    public var _marks: [_Mark]
}

extension ChartContent {
    private func map(_ f: (inout _Mark) -> Void) -> _ModifiedMark { _ModifiedMark(_marks: _marks.map { var m = $0; f(&m); return m }) }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> _ModifiedMark { map { $0.style = AnyShapeStyle(style) } }
    public func foregroundStyle<V: Plottable>(by value: PlottableValue<V>) -> _ModifiedMark {
        map { if case .category(let s) = value.value._plotValue { $0.series = s } else { $0.series = value.label } }
    }
    public func position<V: Plottable>(by value: PlottableValue<V>, axis: Axis? = nil, span: MarkDimension = .automatic) -> _ModifiedMark {
        foregroundStyle(by: value)
    }
    public func symbol<V: Plottable>(by value: PlottableValue<V>) -> _ModifiedMark { map { _ in } }
    public func symbol<S>(_ symbol: S) -> _ModifiedMark { map { _ in } }
    public func symbolSize(_ size: CGFloat) -> _ModifiedMark { map { _ in } }
    public func lineStyle(_ style: StrokeStyle) -> _ModifiedMark { map { $0.lineWidth = style.lineWidth } }
    public func interpolationMethod(_ method: InterpolationMethod) -> _ModifiedMark { map { _ in } }
    public func opacity(_ opacity: Double) -> _ModifiedMark { map { $0.opacity = opacity } }
    public func cornerRadius(_ radius: CGFloat, style: RoundedCornerStyle = .continuous) -> _ModifiedMark { map { _ in } }
    public func annotation<C: View>(position: AnnotationPosition = .automatic, alignment: Alignment = .center, spacing: CGFloat? = nil,
                                    @ViewBuilder content: () -> C) -> _ModifiedMark { map { _ in } }
    public func accessibilityLabel(_ label: Text) -> _ModifiedMark { map { _ in } }
    public func accessibilityValue(_ value: Text) -> _ModifiedMark { map { _ in } }
    public func accessibilityHidden(_ hidden: Bool) -> _ModifiedMark { map { _ in } }
    public func zIndex(_ value: Double) -> _ModifiedMark { map { _ in } }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> _ModifiedMark { map { _ in } }
    public func alignsMarkStylesWithPlotArea(_ aligns: Bool = true) -> _ModifiedMark { map { _ in } }
}

public enum AnnotationPosition: Sendable { case automatic, overlay, top, bottom, leading, trailing, topLeading, topTrailing, bottomLeading, bottomTrailing }

public struct InterpolationMethod: Sendable {
    public static let linear = Self(), monotone = Self(), catmullRom = Self(), cardinal = Self(), stepStart = Self(), stepCenter = Self(), stepEnd = Self()
}

private func mark(_ kind: _Mark.Kind, x: _PlotValue? = nil, y: _PlotValue? = nil, x2: _PlotValue? = nil, y2: _PlotValue? = nil) -> _Mark {
    _Mark(kind: kind, x: x, y: y, x2: x2, y2: y2)
}

public struct BarMark: ChartContent {
    public let _marks: [_Mark]
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, width: MarkDimension = .automatic, height: MarkDimension = .automatic, stacking: MarkStackingMethod = .standard) {
        var m = mark(.bar, x: x.value._plotValue, y: y.value._plotValue)
        m.width = width
        _marks = [m]
    }
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, yStart: PlottableValue<Y>, yEnd: PlottableValue<Y>, width: MarkDimension = .automatic) {
        _marks = [mark(.bar, x: x.value._plotValue, y: yEnd.value._plotValue, y2: yStart.value._plotValue)]
    }
    public init<X: Plottable, Y: Plottable>(xStart: PlottableValue<X>, xEnd: PlottableValue<X>, y: PlottableValue<Y>, height: MarkDimension = .automatic) {
        _marks = [mark(.rectangle, x: xStart.value._plotValue, y: y.value._plotValue, x2: xEnd.value._plotValue)]
    }
}

public struct MarkStackingMethod: Sendable { public static let standard = Self(), normalized = Self(), center = Self(), unstacked = Self() }

public struct LineMark: ChartContent {
    public let _marks: [_Mark]
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>) { _marks = [mark(.line, x: x.value._plotValue, y: y.value._plotValue)] }
    public init<X: Plottable, Y: Plottable, S: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, series: PlottableValue<S>) {
        var m = mark(.line, x: x.value._plotValue, y: y.value._plotValue)
        if case .category(let s) = series.value._plotValue { m.series = s }
        _marks = [m]
    }
}

public struct AreaMark: ChartContent {
    public let _marks: [_Mark]
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, stacking: MarkStackingMethod = .standard) {
        _marks = [mark(.area, x: x.value._plotValue, y: y.value._plotValue)]
    }
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, yStart: PlottableValue<Y>, yEnd: PlottableValue<Y>) {
        _marks = [mark(.area, x: x.value._plotValue, y: yEnd.value._plotValue, y2: yStart.value._plotValue)]
    }
}

public struct PointMark: ChartContent {
    public let _marks: [_Mark]
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>) { _marks = [mark(.point, x: x.value._plotValue, y: y.value._plotValue)] }
}

public struct RuleMark: ChartContent {
    public let _marks: [_Mark]
    public init<Y: Plottable>(y: PlottableValue<Y>) { _marks = [mark(.rule, y: y.value._plotValue)] }
    public init<X: Plottable>(x: PlottableValue<X>) { _marks = [mark(.rule, x: x.value._plotValue)] }
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, yStart: PlottableValue<Y>, yEnd: PlottableValue<Y>) {
        _marks = [mark(.rule, x: x.value._plotValue, y: yEnd.value._plotValue, y2: yStart.value._plotValue)]
    }
    public init<X: Plottable, Y: Plottable>(xStart: PlottableValue<X>, xEnd: PlottableValue<X>, y: PlottableValue<Y>) {
        _marks = [mark(.rule, x: xStart.value._plotValue, y: y.value._plotValue, x2: xEnd.value._plotValue)]
    }
}

public struct RectangleMark: ChartContent {
    public let _marks: [_Mark]
    public init<X: Plottable, Y: Plottable>(xStart: PlottableValue<X>, xEnd: PlottableValue<X>, yStart: PlottableValue<Y>, yEnd: PlottableValue<Y>) {
        _marks = [mark(.rectangle, x: xStart.value._plotValue, y: yStart.value._plotValue, x2: xEnd.value._plotValue, y2: yEnd.value._plotValue)]
    }
    public init<X: Plottable, Y: Plottable>(x: PlottableValue<X>, y: PlottableValue<Y>, width: MarkDimension = .automatic, height: MarkDimension = .automatic) {
        _marks = [mark(.point, x: x.value._plotValue, y: y.value._plotValue)]
    }
}

public struct SectorMark: ChartContent {
    public let _marks: [_Mark]
    public init<V: Plottable>(angle: PlottableValue<V>, innerRadius: MarkDimension = .automatic, outerRadius: MarkDimension = .automatic,
                              angularInset: CGFloat = 0) {
        var m = mark(.sector)
        m.angle = angle.value._plotValue.number ?? 0
        m.innerRadius = innerRadius
        m.outerRadius = outerRadius
        m.angularInset = angularInset
        m.series = angle.label
        _marks = [m]
    }
}

// MARK: The chart

public struct ChartProxy {
    public let plotFrame: Anchor<CGRect>?
    public let plotSize: CGSize
    public var plotAreaSize: CGSize { plotSize }
    public func value<P: Plottable>(atX x: CGFloat, as: P.Type = P.self) -> P? { nil }
    public func value<P: Plottable>(atY y: CGFloat, as: P.Type = P.self) -> P? { nil }
    public func position<P: Plottable>(forX x: P) -> CGFloat? { nil }
    public func position<P: Plottable>(forY y: P) -> CGFloat? { nil }
}

struct ChartOptions {
    var xDomain: ClosedRange<Double>?
    var yDomain: ClosedRange<Double>?
}

struct ChartXDomainKey: EnvironmentKey { static var defaultValue: ClosedRange<Double>? { nil } }
struct ChartYDomainKey: EnvironmentKey { static var defaultValue: ClosedRange<Double>? { nil } }
struct ChartBackgroundKey: EnvironmentKey { static var defaultValue: ((ChartProxy) -> AnyView)? { nil } }
struct ChartOverlayKey: EnvironmentKey { static var defaultValue: ((ChartProxy) -> AnyView)? { nil } }

extension EnvironmentValues {
    var _chartXDomain: ClosedRange<Double>? { get { self[ChartXDomainKey.self] } set { self[ChartXDomainKey.self] = newValue } }
    var _chartYDomain: ClosedRange<Double>? { get { self[ChartYDomainKey.self] } set { self[ChartYDomainKey.self] = newValue } }
    var _chartBackground: ((ChartProxy) -> AnyView)? { get { self[ChartBackgroundKey.self] } set { self[ChartBackgroundKey.self] = newValue } }
    var _chartOverlay: ((ChartProxy) -> AnyView)? { get { self[ChartOverlayKey.self] } set { self[ChartOverlayKey.self] = newValue } }
}

public struct Chart<Content: ChartContent>: View {
    let content: Content
    @Environment(\._chartXDomain) var xDomain
    @Environment(\._chartYDomain) var yDomain
    @Environment(\._chartBackground) var background
    @Environment(\._chartOverlay) var overlay

    public init(@ChartContentBuilder content: () -> Content) { self.content = content() }
    public init<Data: RandomAccessCollection, C: ChartContent>(_ data: Data, @ChartContentBuilder content: @escaping (Data.Element) -> C)
        where Content == _ChartGroup, Data.Element: Identifiable {
        self.content = _ChartGroup(marks: data.flatMap { content($0)._marks })
    }

    public var body: some View {
        let marks = content._marks
        let options = ChartOptions(xDomain: xDomain, yDomain: yDomain)
        let background = self.background, overlay = self.overlay
        return GeometryReader { geo in
            let proxy = ChartProxy(plotFrame: Anchor<CGRect>.Source.rect(CGRect(origin: .zero, size: geo.size))._anchor, plotSize: geo.size)
            ZStack {
                if let background { background(proxy) }
                Canvas { ctx, size in ChartRenderer(marks: marks, options: options, size: size).draw(&ctx) }
                if let overlay { overlay(proxy) }
            }
            .environment(\._chartBackground, nil)
            .environment(\._chartOverlay, nil)
        }
    }
}

extension View {
    public func chartLegend(_ visibility: Visibility) -> some View { self }
    public func chartLegend(position: AnnotationPosition = .automatic, alignment: Alignment? = nil, spacing: CGFloat? = nil) -> some View { self }
    public func chartXAxis(_ visibility: Visibility) -> some View { self }
    public func chartYAxis(_ visibility: Visibility) -> some View { self }
    public func chartXAxis<C>(@AxisContentBuilder content: () -> C) -> some View { self }
    public func chartYAxis<C>(@AxisContentBuilder content: () -> C) -> some View { self }
    public func chartXAxisLabel(_ label: String, position: AnnotationPosition = .automatic) -> some View { self }
    public func chartYAxisLabel(_ label: String, position: AnnotationPosition = .automatic) -> some View { self }
    public func chartPlotStyle<C: View>(content: @escaping (_ChartPlotContent) -> C) -> some View { self }
    public func chartForegroundStyleScale<S>(_ mapping: S) -> some View { self }
    public func chartYScale<V: Plottable>(domain: ClosedRange<V>) -> some View {
        let a = domain.lowerBound._plotValue.number ?? 0, b = domain.upperBound._plotValue.number ?? 1
        return environment(\._chartYDomain, a...max(b, a + 1e-9))
    }
    public func chartXScale<V: Plottable>(domain: ClosedRange<V>) -> some View {
        let a = domain.lowerBound._plotValue.number ?? 0, b = domain.upperBound._plotValue.number ?? 1
        return environment(\._chartXDomain, a...max(b, a + 1e-9))
    }
    public func chartYScale(range: ClosedRange<CGFloat>) -> some View { self }
    public func chartXScale(range: ClosedRange<CGFloat>) -> some View { self }
    public func chartBackground<V: View>(alignment: Alignment = .center, @ViewBuilder content: @escaping (ChartProxy) -> V) -> some View {
        environment(\._chartBackground, { AnyView(content($0)) })
    }
    public func chartOverlay<V: View>(alignment: Alignment = .center, @ViewBuilder content: @escaping (ChartProxy) -> V) -> some View {
        environment(\._chartOverlay, { AnyView(content($0)) })
    }
    public func chartScrollableAxes(_ axes: Axis.Set) -> some View { self }
    public func chartXVisibleDomain<V>(length: V) -> some View { self }
    public func chartXSelection<V>(value: Binding<V?>) -> some View { self }
    public func chartAngleSelection<V>(value: Binding<V?>) -> some View { self }
}

public struct _ChartPlotContent: View {
    public var body: some View { EmptyView() }
    public func background<S: ShapeStyle>(_ s: S) -> _ChartPlotContent { self }
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil) -> _ChartPlotContent { self }
}

// Axes (accepted; not drawn yet).
@resultBuilder public enum AxisContentBuilder {
    public static func buildBlock(_ c: Any...) -> [Any] { c }
    public static func buildExpression(_ c: Any) -> Any { c }
}
public struct AxisMarks {
    public init(values: Any = 0, @AxisContentBuilder content: (AxisValue) -> [Any] = { _ in [] }) {}
    public init(position: AnnotationPosition, values: Any = 0, @AxisContentBuilder content: (AxisValue) -> [Any] = { _ in [] }) {}
    public init(preset: Any? = nil, position: AnnotationPosition = .automatic, values: Any = 0) {}
}
public struct AxisValue { public var index: Int = 0; public var count: Int = 0; public func `as`<T>(_ t: T.Type) -> T? { nil } }
public struct AxisGridLine { public init(centered: Bool? = nil, stroke: StrokeStyle? = nil) {} }
public struct AxisTick { public init(centered: Bool? = nil, length: CGFloat? = nil, stroke: StrokeStyle? = nil) {} }
public struct AxisValueLabel { public init() {}; public init(_ s: String) {}; public init<C: View>(@ViewBuilder content: () -> C) {} }

// MARK: Rendering

struct ChartRenderer {
    let marks: [_Mark]
    let options: ChartOptions
    let size: CGSize

    static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .yellow, .brown, .indigo]

    func color(_ m: _Mark, _ seriesIndex: [String: Int]) -> GraphicsContext.Shading {
        if let s = m.style { return .style(s) }
        let i = m.series.flatMap { seriesIndex[$0] } ?? 0
        return .color(Self.palette[i % Self.palette.count].opacity(m.opacity))
    }

    func categories(_ values: [_PlotValue?]) -> [String] {
        var seen: [String] = []
        for case .category(let s)? in values where !seen.contains(s) { seen.append(s) }
        return seen
    }

    @MainActor func draw(_ ctx: inout GraphicsContext) {
        var seriesIndex: [String: Int] = [:]
        for m in marks { if let s = m.series, seriesIndex[s] == nil { seriesIndex[s] = seriesIndex.count } }

        let sectors = marks.filter { $0.kind == .sector }
        if !sectors.isEmpty { drawSectors(sectors, &ctx, seriesIndex); return }

        let xCats = categories(marks.flatMap { [$0.x, $0.x2] })
        let yCats = categories(marks.flatMap { [$0.y, $0.y2] })
        let xs = marks.flatMap { [$0.x?.number, $0.x2?.number] }.compactMap { $0 }
        let ys = marks.flatMap { [$0.y?.number, $0.y2?.number] }.compactMap { $0 }
        let hasBars = marks.contains { $0.kind == .bar || $0.kind == .area }
        let xDomain = options.xDomain ?? (xs.min() ?? 0)...max(xs.max() ?? 1, (xs.min() ?? 0) + 1e-9)
        let yLow = hasBars ? min(0, ys.min() ?? 0) : (ys.min() ?? 0)
        let yDomain = options.yDomain ?? yLow...max(ys.max() ?? 1, yLow + 1e-9)
        let w = size.width, h = size.height

        func px(_ v: _PlotValue?) -> CGFloat? {
            switch v {
            case .category(let s)?:
                guard let i = xCats.firstIndex(of: s) else { return nil }
                return (CGFloat(i) + 0.5) * w / CGFloat(max(xCats.count, 1))
            case .number(let d)?:
                return CGFloat((d - xDomain.lowerBound) / (xDomain.upperBound - xDomain.lowerBound)) * w
            case nil: return nil
            }
        }
        func py(_ v: _PlotValue?) -> CGFloat? {
            switch v {
            case .category(let s)?:
                guard let i = yCats.firstIndex(of: s) else { return nil }
                return (CGFloat(i) + 0.5) * h / CGFloat(max(yCats.count, 1))
            case .number(let d)?:
                return h - CGFloat((d - yDomain.lowerBound) / (yDomain.upperBound - yDomain.lowerBound)) * h
            case nil: return nil
            }
        }
        let zeroY = py(.number(max(yDomain.lowerBound, min(0, yDomain.upperBound)))) ?? h
        let band = xCats.isEmpty ? max(4, w / CGFloat(max(marks.filter { $0.kind == .bar }.count, 1)) * 0.8) : w / CGFloat(xCats.count) * 0.7

        // Lines and areas connect marks of the same series, in x order.
        var groups: [String: [_Mark]] = [:]
        for m in marks where m.kind == .line || m.kind == .area { groups[m.series ?? "", default: []].append(m) }
        for (_, ms) in groups.sorted(by: { $0.key < $1.key }) {
            let pts = ms.compactMap { m -> (CGPoint, _Mark)? in
                guard let x = px(m.x), let y = py(m.y) else { return nil }
                return (CGPoint(x: x, y: y), m)
            }.sorted { $0.0.x < $1.0.x }
            guard let first = pts.first else { continue }
            if first.1.kind == .area {
                var p = Path()
                p.move(to: CGPoint(x: first.0.x, y: zeroY))
                for (pt, _) in pts { p.addLine(to: pt) }
                p.addLine(to: CGPoint(x: pts.last!.0.x, y: zeroY))
                p.closeSubpath()
                ctx.fill(p, with: color(first.1, seriesIndex))
            } else {
                var p = Path()
                p.move(to: first.0)
                for (pt, _) in pts.dropFirst() { p.addLine(to: pt) }
                ctx.stroke(p, with: color(first.1, seriesIndex), lineWidth: first.1.lineWidth)
            }
        }

        for m in marks {
            switch m.kind {
            case .bar:
                guard let x = px(m.x), let y = py(m.y) else { continue }
                let base = m.y2.flatMap(py) ?? zeroY
                var bw = band
                if case .fixed(let f) = m.width { bw = f }
                if case .ratio(let r) = m.width { bw = band / 0.7 * r }
                ctx.fill(Path(CGRect(x: x - bw / 2, y: min(y, base), width: bw, height: abs(base - y))), with: color(m, seriesIndex))
            case .rectangle:
                guard let x1 = px(m.x) else { continue }
                let x2 = px(m.x2) ?? x1 + 4
                let y1 = py(m.y) ?? 0, y2 = m.y2.flatMap(py) ?? (m.y == nil ? h : y1 + 4)
                ctx.fill(Path(CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: max(abs(y2 - y1), 1))), with: color(m, seriesIndex))
            case .point:
                guard let x = px(m.x), let y = py(m.y) else { continue }
                ctx.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: color(m, seriesIndex))
            case .rule:
                var p = Path()
                if let y = py(m.y), m.x == nil || m.x2 != nil {
                    p.move(to: CGPoint(x: px(m.x) ?? 0, y: y))
                    p.addLine(to: CGPoint(x: px(m.x2) ?? w, y: y))
                } else if let x = px(m.x) {
                    p.move(to: CGPoint(x: x, y: m.y2.flatMap(py) ?? 0))
                    p.addLine(to: CGPoint(x: x, y: py(m.y) ?? h))
                }
                ctx.stroke(p, with: color(m, seriesIndex), lineWidth: 1)
            default: break
            }
        }
    }

    @MainActor func drawSectors(_ sectors: [_Mark], _ ctx: inout GraphicsContext, _ seriesIndex: [String: Int]) {
        let total = sectors.reduce(0) { $0 + max($1.angle ?? 0, 0) }
        guard total > 0 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2
        var start = -Double.pi / 2
        for m in sectors {
            let sweep = max(m.angle ?? 0, 0) / total * 2 * .pi
            var outer = radius
            if case .ratio(let r) = m.outerRadius { outer = radius * r }
            if case .fixed(let f) = m.outerRadius { outer = f }
            if case .inset(let i) = m.outerRadius { outer = radius - i }
            var inner: CGFloat = 0
            if case .ratio(let r) = m.innerRadius { inner = outer * r }
            if case .fixed(let f) = m.innerRadius { inner = f }
            if case .inset(let i) = m.innerRadius { inner = outer - i }
            var p = Path()
            let steps = max(2, Int(sweep / (2 * .pi) * 96))
            for s in 0...steps {
                let a = start + sweep * Double(s) / Double(steps)
                let pt = CGPoint(x: center.x + outer * CGFloat(cos(a)), y: center.y + outer * CGFloat(sin(a)))
                if s == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            for s in (0...steps).reversed() {
                let a = start + sweep * Double(s) / Double(steps)
                p.addLine(to: CGPoint(x: center.x + inner * CGFloat(cos(a)), y: center.y + inner * CGFloat(sin(a))))
            }
            p.closeSubpath()
            ctx.fill(p, with: color(m, seriesIndex))
            start += sweep
        }
    }
}
