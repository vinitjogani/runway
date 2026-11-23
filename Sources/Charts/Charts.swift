// Swift Charts: marks collected by a result builder and drawn with
// SwiftUI's Canvas. Bars, lines, areas, points, rules, rectangles and
// sectors (pie and donut) over numeric, date or categorical (string)
// values; automatic domains (or chartXScale/chartYScale), the default
// palette by series, foreground styles, and configured chart axes.

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

    func converted<T>(to type: T.Type) -> T? {
        if case .category(let value) = self { return value as? T }
        guard let number, number.isFinite else { return nil }
        switch type {
        case is Date.Type: return Date(timeIntervalSinceReferenceDate: number) as? T
        case is Double.Type: return number as? T
        case is CGFloat.Type: return CGFloat(number) as? T
        case is Float.Type: return Float(number) as? T
        case is Int.Type: return Int(exactly: number.rounded()) as? T
        case is Int64.Type: return Int64(exactly: number.rounded()) as? T
        case is UInt64.Type: return UInt64(exactly: number.rounded()) as? T
        default: return nil
        }
    }
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
    enum Kind: Hashable { case bar, line, area, point, rule, rectangle, sector }
    var kind: Kind
    public var x: _PlotValue?
    public var y: _PlotValue?
    var x2: _PlotValue?
    var y2: _PlotValue?
    public var angle: Double?
    var innerRadius: MarkDimension = .automatic
    var outerRadius: MarkDimension = .automatic
    var angularInset: CGFloat = 0
    var series: _PlotValue?
    var style: AnyShapeStyle?
    var stroke: StrokeStyle?
    var opacity: Double = 1
    var width: MarkDimension = .automatic
    var cornerRadius: CGFloat = 0
    var symbolArea: CGFloat?
    var interpolation: InterpolationMethod = .linear
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
        map { $0.series = value.value._plotValue }
    }
    public func position<V: Plottable>(by value: PlottableValue<V>, axis: Axis? = nil, span: MarkDimension = .automatic) -> _ModifiedMark {
        foregroundStyle(by: value)
    }
    public func symbol<V: Plottable>(by value: PlottableValue<V>) -> _ModifiedMark { map { _ in } }
    public func symbol<S>(_ symbol: S) -> _ModifiedMark { map { _ in } }
    public func symbolSize(_ size: CGFloat) -> _ModifiedMark { map { $0.symbolArea = max(0, size) } }
    public func lineStyle(_ style: StrokeStyle) -> _ModifiedMark { map { $0.stroke = style } }
    public func interpolationMethod(_ method: InterpolationMethod) -> _ModifiedMark { map { $0.interpolation = method } }
    public func opacity(_ opacity: Double) -> _ModifiedMark { map { $0.opacity = opacity } }
    public func cornerRadius(_ radius: CGFloat, style: RoundedCornerStyle = .continuous) -> _ModifiedMark { map { $0.cornerRadius = max(0, radius) } }
    public func annotation<C: View>(position: AnnotationPosition = .automatic, alignment: Alignment = .center, spacing: CGFloat? = nil,
                                    @ViewBuilder content: () -> C) -> _ModifiedMark { map { _ in } }
    public func accessibilityLabel(_ label: Text) -> _ModifiedMark { map { _ in } }
    public func accessibilityValue(_ value: Text) -> _ModifiedMark { map { _ in } }
    public func accessibilityLabel<S: StringProtocol>(_ label: S) -> _ModifiedMark { accessibilityLabel(Text(label)) }
    public func accessibilityValue<S: StringProtocol>(_ value: S) -> _ModifiedMark { accessibilityValue(Text(value)) }
    public func accessibilityHidden(_ hidden: Bool) -> _ModifiedMark { map { _ in } }
    public func zIndex(_ value: Double) -> _ModifiedMark { map { _ in } }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> _ModifiedMark { map { _ in } }
    public func alignsMarkStylesWithPlotArea(_ aligns: Bool = true) -> _ModifiedMark { map { _ in } }
}

public enum AnnotationPosition: Equatable, Sendable { case automatic, overlay, top, bottom, leading, trailing, topLeading, topTrailing, bottomLeading, bottomTrailing }

public struct InterpolationMethod: Sendable {
    let usesMonotoneCurve: Bool
    private init(usesMonotoneCurve: Bool = false) { self.usesMonotoneCurve = usesMonotoneCurve }
    public static let linear = Self(), monotone = Self(usesMonotoneCurve: true)
    public static let catmullRom = Self(), cardinal = Self(), stepStart = Self(), stepCenter = Self(), stepEnd = Self()
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
        m.series = series.value._plotValue
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
    public init<X: Plottable, Y: Plottable, S: Plottable>(x: PlottableValue<X>, yStart: PlottableValue<Y>, yEnd: PlottableValue<Y>, series: PlottableValue<S>) {
        var m = mark(.area, x: x.value._plotValue, y: yEnd.value._plotValue, y2: yStart.value._plotValue)
        m.series = series.value._plotValue
        _marks = [m]
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
        m.series = .category(angle.label)
        _marks = [m]
    }
}

// MARK: The chart

public struct ChartProxy {
    public let plotFrame: Anchor<CGRect>?
    public let plotSize: CGSize
    let xScale: ChartScale
    let yScale: ChartScale
    let xSelection: ChartXSelection?
    public var plotAreaSize: CGSize { plotSize }
    public func value<P: Plottable>(atX x: CGFloat, as type: P.Type = P.self) -> P? {
        xScale.value(at: x, extent: plotSize.width, as: type)
    }
    public func value<P: Plottable>(atY y: CGFloat, as type: P.Type = P.self) -> P? {
        yScale.value(at: y, extent: plotSize.height, as: type)
    }
    public func position<P: Plottable>(forX x: P) -> CGFloat? { xScale.position(x._plotValue, extent: plotSize.width) }
    public func position<P: Plottable>(forY y: P) -> CGFloat? { yScale.position(y._plotValue, extent: plotSize.height) }
    @MainActor public func selectXValue(at x: CGFloat) { xSelection?(self, x) }
}

typealias ChartXSelection = @MainActor (ChartProxy, CGFloat) -> Void
typealias ChartGesture = @MainActor (ChartProxy, AnyView) -> AnyView

struct ChartOptions {
    var xDomain: ClosedRange<Double>?
    var yDomain: ClosedRange<Double>?
    var yIncludesZero: Bool?

    func scales(for marks: [_Mark]) -> (x: ChartScale, y: ChartScale) {
        let xs = marks.flatMap { [$0.x, $0.x2] }.compactMap { $0 }
        let ys = marks.flatMap { [$0.y, $0.y2] }.compactMap { $0 }
        let xNumbers = xs.compactMap(\.number).filter(\.isFinite)
        let yNumbers = ys.compactMap(\.number).filter(\.isFinite)
        let xLow = xNumbers.min() ?? 0
        let hasBars = marks.contains { $0.kind == .bar || $0.kind == .area }
        let yMin = yNumbers.min() ?? 0
        let yLow = (yIncludesZero ?? hasBars) ? min(0, yMin) : yMin
        let yMax = yNumbers.max() ?? 1
        let yHigh = yIncludesZero == true ? max(0, yMax) : yMax
        return (
            ChartScale(domain: xDomain ?? xLow...max(xNumbers.max() ?? 1, xLow.nextUp), values: xs),
            ChartScale(domain: yDomain ?? yLow...max(yHigh, yLow.nextUp), values: ys, reversed: true)
        )
    }
}

struct ChartScale {
    let domain: ClosedRange<Double>
    let categories: [String]
    let reversed: Bool

    init(domain: ClosedRange<Double>, values: [_PlotValue], reversed: Bool = false) {
        self.domain = domain
        var seen = Set<String>()
        self.categories = values.compactMap { value in
            guard case .category(let text) = value, seen.insert(text).inserted else { return nil }
            return text
        }
        self.reversed = reversed
    }

    func position(_ value: _PlotValue?, extent: CGFloat) -> CGFloat? {
        switch value {
        case .category(let text)?:
            guard let index = categories.firstIndex(of: text) else { return nil }
            return (CGFloat(index) + 0.5) * extent / CGFloat(categories.count)
        case .number(let number)? where number.isFinite:
            let unit = CGFloat((number - domain.lowerBound) / (domain.upperBound - domain.lowerBound))
            return (reversed ? 1 - unit : unit) * extent
        default: return nil
        }
    }

    func value<P: Plottable>(at position: CGFloat, extent: CGFloat, as type: P.Type) -> P? {
        guard extent > 0, position.isFinite, position >= 0, position <= extent else { return nil }
        let fraction = position / extent
        if type == String.self, !categories.isEmpty {
            let index = min(Int(fraction * CGFloat(categories.count)), categories.count - 1)
            return categories[index] as? P
        }
        let unit = Double(reversed ? 1 - fraction : fraction)
        let number = domain.lowerBound + unit * (domain.upperBound - domain.lowerBound)
        return _PlotValue.number(number).converted(to: type)
    }
}

struct ChartXDomainKey: EnvironmentKey { static var defaultValue: ClosedRange<Double>? { nil } }
struct ChartYDomainKey: EnvironmentKey { static var defaultValue: ClosedRange<Double>? { nil } }
struct ChartYIncludesZeroKey: EnvironmentKey { static var defaultValue: Bool? { nil } }
struct ChartBackgroundKey: EnvironmentKey { static var defaultValue: ((ChartProxy) -> AnyView)? { nil } }
struct ChartOverlayKey: EnvironmentKey { static var defaultValue: ((ChartProxy) -> AnyView)? { nil } }
struct ChartXSelectionKey: EnvironmentKey { static var defaultValue: ChartXSelection? { nil } }
struct ChartGestureKey: EnvironmentKey { static var defaultValue: ChartGesture? { nil } }
struct ChartXAxisKey: EnvironmentKey { static var defaultValue: [AxisMarks] { [] } }
struct ChartYAxisKey: EnvironmentKey { static var defaultValue: [AxisMarks] { [] } }
struct ChartPlotStyleKey: EnvironmentKey { static var defaultValue: ((_ChartPlotContent) -> AnyView)? { nil } }

extension EnvironmentValues {
    var _chartXDomain: ClosedRange<Double>? { get { self[ChartXDomainKey.self] } set { self[ChartXDomainKey.self] = newValue } }
    var _chartYDomain: ClosedRange<Double>? { get { self[ChartYDomainKey.self] } set { self[ChartYDomainKey.self] = newValue } }
    var _chartYIncludesZero: Bool? { get { self[ChartYIncludesZeroKey.self] } set { self[ChartYIncludesZeroKey.self] = newValue } }
    var _chartBackground: ((ChartProxy) -> AnyView)? { get { self[ChartBackgroundKey.self] } set { self[ChartBackgroundKey.self] = newValue } }
    var _chartOverlay: ((ChartProxy) -> AnyView)? { get { self[ChartOverlayKey.self] } set { self[ChartOverlayKey.self] = newValue } }
    var _chartXSelection: ChartXSelection? { get { self[ChartXSelectionKey.self] } set { self[ChartXSelectionKey.self] = newValue } }
    var _chartGesture: ChartGesture? { get { self[ChartGestureKey.self] } set { self[ChartGestureKey.self] = newValue } }
    var _chartXAxis: [AxisMarks] { get { self[ChartXAxisKey.self] } set { self[ChartXAxisKey.self] = newValue } }
    var _chartYAxis: [AxisMarks] { get { self[ChartYAxisKey.self] } set { self[ChartYAxisKey.self] = newValue } }
    var _chartPlotStyle: ((_ChartPlotContent) -> AnyView)? { get { self[ChartPlotStyleKey.self] } set { self[ChartPlotStyleKey.self] = newValue } }
}

public struct Chart<Content: ChartContent>: View {
    let content: Content
    @Environment(\._chartXDomain) var xDomain
    @Environment(\._chartYDomain) var yDomain
    @Environment(\._chartYIncludesZero) var yIncludesZero
    @Environment(\._chartBackground) var background
    @Environment(\._chartOverlay) var overlay
    @Environment(\._chartXSelection) var xSelection
    @Environment(\._chartGesture) var gesture
    @Environment(\._chartXAxis) var xAxis
    @Environment(\._chartYAxis) var yAxis
    @Environment(\._chartPlotStyle) var plotStyle
    @Environment(\.calendar) var calendar

    public init(@ChartContentBuilder content: () -> Content) { self.content = content() }
    public init<Data: RandomAccessCollection, C: ChartContent>(_ data: Data, @ChartContentBuilder content: @escaping (Data.Element) -> C)
        where Content == _ChartGroup, Data.Element: Identifiable {
        self.init(data, id: \.id, content: content)
    }
    public init<Data: RandomAccessCollection, ID: Hashable, C: ChartContent>(_ data: Data, id: KeyPath<Data.Element, ID>,
                                                                           @ChartContentBuilder content: @escaping (Data.Element) -> C)
        where Content == _ChartGroup {
        self.content = _ChartGroup(marks: data.flatMap { content($0)._marks })
    }

    public var body: some View {
        let marks = content._marks
        let options = ChartOptions(xDomain: xDomain, yDomain: yDomain, yIncludesZero: yIncludesZero)
        let scales = options.scales(for: marks)
        return GeometryReader { geo in
            let axes = ChartAxes(x: xAxis, y: yAxis, scales: scales, calendar: calendar, size: geo.size)
            let rect = axes.plot
            let frame = Anchor<CGRect>.Source.rect(rect)._anchor
            let proxy = ChartProxy(plotFrame: frame, plotSize: rect.size, xScale: scales.x, yScale: scales.y, xSelection: xSelection)
            let labels = axes.labels(chartSize: geo.size)
            let canvas = AnyView(Canvas { ctx, size in
                ChartRenderer(marks: marks, xScale: scales.x, yScale: scales.y, size: size).draw(&ctx)
            })
            let plot = plotStyle?(_ChartPlotContent(plot: canvas)) ?? canvas
            ZStack(alignment: .topLeading) {
                if let background { background(proxy) }
                if axes.hasGrid { Canvas { ctx, _ in axes.draw(in: &ctx, grid: true) } }
                plotWithSelection(plot, proxy: proxy)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                if let overlay { overlay(proxy) }
                if axes.hasTicks { Canvas { ctx, _ in axes.draw(in: &ctx, grid: false) } }
                if !labels.isEmpty {
                    ChartAxisLabelLayout(size: geo.size, labels: labels) {
                        ForEach(labels.indices, id: \.self) { labels[$0].view }
                    }
                }
            }
            .environment(\._chartBackground, nil)
            .environment(\._chartOverlay, nil)
            .environment(\._chartXSelection, nil)
            .environment(\._chartGesture, nil)
            .environment(\._chartXAxis, [])
            .environment(\._chartYAxis, [])
            .environment(\._chartPlotStyle, nil)
        }
    }

    @ViewBuilder private func plotWithSelection(_ plot: AnyView, proxy: ChartProxy) -> some View {
        if let gesture { gesture(proxy, plot) }
        else if xSelection != nil { plot.onTapGesture { (location: CGPoint) in proxy.selectXValue(at: location.x) } }
        else { plot }
    }
}

extension View {
    public func chartLegend(_ visibility: Visibility) -> some View { self }
    public func chartLegend(position: AnnotationPosition = .automatic, alignment: Alignment? = nil, spacing: CGFloat? = nil) -> some View { self }
    public func chartXAxis(_ visibility: Visibility) -> some View {
        environment(\._chartXAxis, visibility == .hidden ? [] : [AxisMarks()])
    }
    public func chartYAxis(_ visibility: Visibility) -> some View {
        environment(\._chartYAxis, visibility == .hidden ? [] : [AxisMarks()])
    }
    public func chartXAxis(@AxisContentBuilder content: () -> [Any]) -> some View {
        environment(\._chartXAxis, content().compactMap { $0 as? AxisMarks })
    }
    public func chartYAxis(@AxisContentBuilder content: () -> [Any]) -> some View {
        environment(\._chartYAxis, content().compactMap { $0 as? AxisMarks })
    }
    public func chartXAxisLabel(_ label: String, position: AnnotationPosition = .automatic) -> some View { self }
    public func chartYAxisLabel(_ label: String, position: AnnotationPosition = .automatic) -> some View { self }
    public func chartPlotStyle<C: View>(content: @escaping (_ChartPlotContent) -> C) -> some View {
        environment(\._chartPlotStyle, { AnyView(content($0)) })
    }
    public func chartForegroundStyleScale<S>(_ mapping: S) -> some View { self }
    public func chartYScale<V: Plottable>(domain: ClosedRange<V>) -> some View {
        let a = domain.lowerBound._plotValue.number ?? 0, b = domain.upperBound._plotValue.number ?? 1
        return environment(\._chartYDomain, a...max(b, a.nextUp))
    }
    public func chartYScale(domain: AutomaticScaleDomain) -> some View {
        environment(\._chartYIncludesZero, domain.includesZero)
    }
    public func chartXScale<V: Plottable>(domain: ClosedRange<V>) -> some View {
        let a = domain.lowerBound._plotValue.number ?? 0, b = domain.upperBound._plotValue.number ?? 1
        return environment(\._chartXDomain, a...max(b, a.nextUp))
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
    public func chartXSelection<V: Plottable>(value: Binding<V?>) -> some View {
        environment(\._chartXSelection, { proxy, position in value.wrappedValue = proxy.value(atX: position) })
    }
    public func chartGesture<G: Gesture>(_ gesture: @escaping (ChartProxy) -> G) -> some View {
        environment(\._chartGesture, { proxy, chart in AnyView(chart.gesture(gesture(proxy))) })
    }
    public func chartAngleSelection<V>(value: Binding<V?>) -> some View { self }
}

public struct AutomaticScaleDomain: Sendable {
    let includesZero: Bool?
    public static func automatic(includesZero: Bool? = nil) -> Self { Self(includesZero: includesZero) }
}

public struct _ChartPlotContent: View {
    let plot: AnyView
    public var body: some View { plot }
    public func background<S: ShapeStyle>(_ style: S) -> _ChartPlotContent {
        _ChartPlotContent(plot: AnyView(plot.background(style)))
    }
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil) -> _ChartPlotContent {
        _ChartPlotContent(plot: AnyView(plot.frame(width: width, height: height)))
    }
}

// MARK: Rendering

struct ChartRenderer {
    let marks: [_Mark]
    let xScale: ChartScale
    let yScale: ChartScale
    let size: CGSize

    static let palette: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .pink, .yellow, .brown, .indigo]

    func color(_ m: _Mark, _ seriesIndex: [_PlotValue: Int]) -> GraphicsContext.Shading {
        if let s = m.style { return .style(s) }
        let i = m.series.flatMap { seriesIndex[$0] } ?? 0
        return .color(Self.palette[i % Self.palette.count].opacity(m.opacity))
    }

    @MainActor func draw(_ ctx: inout GraphicsContext) {
        var seriesIndex: [_PlotValue: Int] = [:]
        for m in marks { if let s = m.series, seriesIndex[s] == nil { seriesIndex[s] = seriesIndex.count } }

        let sectors = marks.filter { $0.kind == .sector }
        if !sectors.isEmpty { drawSectors(sectors, &ctx, seriesIndex); return }

        let xCats = xScale.categories
        let yDomain = yScale.domain
        let w = size.width, h = size.height

        func px(_ value: _PlotValue?) -> CGFloat? { xScale.position(value, extent: w) }
        func py(_ value: _PlotValue?) -> CGFloat? { yScale.position(value, extent: h) }
        let zeroY = py(.number(max(yDomain.lowerBound, min(0, yDomain.upperBound)))) ?? h
        let band = xCats.isEmpty ? max(4, w / CGFloat(max(marks.filter { $0.kind == .bar }.count, 1)) * 0.8) : w / CGFloat(xCats.count) * 0.7

        // Group like marks by series, then draw them at their first position in the input.
        let groups = Dictionary(grouping: marks.filter { $0.kind == .line || $0.kind == .area }, by: SeriesKey.init)
        var drawn = Set<SeriesKey>()
        for m in marks {
            switch m.kind {
            case .area, .line:
                let key = SeriesKey(m)
                guard drawn.insert(key).inserted, let series = groups[key] else { continue }
                let points = series.compactMap { point -> (top: CGPoint, base: CGPoint)? in
                    guard let x = px(point.x), let y = py(point.y) else { return nil }
                    return (CGPoint(x: x, y: y), CGPoint(x: x, y: py(point.y2) ?? zeroY))
                }.sorted { $0.top.x < $1.top.x }
                guard let first = points.first else { continue }
                var path = Path()
                path.move(to: first.top)
                append(points.map(\.top), to: &path, interpolation: m.interpolation)
                if m.kind == .area {
                    let baseline = points.reversed().map(\.base)
                    path.addLine(to: baseline[0])
                    append(baseline, to: &path, interpolation: m.interpolation)
                    path.closeSubpath()
                    ctx.fill(path, with: color(m, seriesIndex))
                } else {
                    ctx.stroke(path, with: color(m, seriesIndex), style: m.stroke ?? StrokeStyle(lineWidth: 2))
                }
            case .bar:
                guard let x = px(m.x), let y = py(m.y) else { continue }
                let base = m.y2.flatMap(py) ?? zeroY
                var bw = band
                if case .fixed(let f) = m.width { bw = f }
                if case .ratio(let r) = m.width { bw = band / 0.7 * r }
                let rect = CGRect(x: x - bw / 2, y: min(y, base), width: bw, height: abs(base - y))
                ctx.fill(barPath(rect, radius: m.cornerRadius), with: color(m, seriesIndex))
            case .rectangle:
                guard let x1 = px(m.x) else { continue }
                let x2 = px(m.x2) ?? x1 + 4
                let y1 = py(m.y) ?? 0, y2 = m.y2.flatMap(py) ?? (m.y == nil ? h : y1 + 4)
                let rect = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: max(abs(y2 - y1), 1))
                ctx.fill(barPath(rect, radius: m.cornerRadius), with: color(m, seriesIndex))
            case .point:
                guard let x = px(m.x), let y = py(m.y) else { continue }
                let radius = m.symbolArea.map { sqrt($0 / .pi) } ?? 4
                ctx.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                         with: color(m, seriesIndex))
            case .rule:
                var p = Path()
                if let y = py(m.y), m.x == nil || m.x2 != nil {
                    p.move(to: CGPoint(x: px(m.x) ?? 0, y: y))
                    p.addLine(to: CGPoint(x: px(m.x2) ?? w, y: y))
                } else if let x = px(m.x) {
                    p.move(to: CGPoint(x: x, y: m.y2.flatMap(py) ?? 0))
                    p.addLine(to: CGPoint(x: x, y: py(m.y) ?? h))
                }
                ctx.stroke(p, with: color(m, seriesIndex), style: m.stroke ?? StrokeStyle(lineWidth: 1))
            case .sector: break
            }
        }
    }

    private func barPath(_ rect: CGRect, radius: CGFloat) -> Path {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        return radius > 0 ? Path(roundedRect: rect, cornerRadius: radius) : Path(rect)
    }

    /// The shape-preserving cubic uses a zero tangent at local extrema. In
    /// between, the weighted harmonic mean accounts for uneven x spacing.
    private func append(_ points: [CGPoint], to path: inout Path, interpolation: InterpolationMethod) {
        let segments = Array(zip(points, points.dropFirst()))
        guard interpolation.usesMonotoneCurve, points.count >= 3,
              segments.allSatisfy({ $0.0.x != $0.1.x }) else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return
        }

        let spans = segments.map { abs($0.1.x - $0.0.x) }
        let slopes = segments.map { ($0.1.y - $0.0.y) / ($0.1.x - $0.0.x) }
        var tangents = [slopes[0]]
        for i in 1..<(points.count - 1) {
            let a = slopes[i - 1], b = slopes[i]
            if a == 0 || b == 0 || a.sign != b.sign {
                tangents.append(0)
            } else {
                let wa = 2 * spans[i] + spans[i - 1]
                let wb = 2 * spans[i - 1] + spans[i]
                tangents.append((wa + wb) / (wa / a + wb / b))
            }
        }
        tangents.append(slopes[slopes.count - 1])

        for (i, segment) in segments.enumerated() {
            let (a, b) = segment
            let dx = (b.x - a.x) / 3
            let first = CGPoint(x: a.x + dx, y: a.y + tangents[i] * dx)
            let second = CGPoint(x: b.x - dx, y: b.y - tangents[i + 1] * dx)
            path.addCurve(to: b, control1: first, control2: second)
        }
    }

    @MainActor func drawSectors(_ sectors: [_Mark], _ ctx: inout GraphicsContext, _ seriesIndex: [_PlotValue: Int]) {
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

private struct SeriesKey: Hashable {
    let kind: _Mark.Kind
    let series: _PlotValue?
    init(_ mark: _Mark) { kind = mark.kind; series = mark.series }
}
