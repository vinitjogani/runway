import Foundation
import SwiftUI

@resultBuilder public enum AxisContentBuilder {
    public static func buildBlock(_ components: Any...) -> [Any] { components.flatMap { $0 as? [Any] ?? [$0] } }
    public static func buildExpression(_ component: Any) -> Any { component }
    public static func buildEither(first: [Any]) -> [Any] { first }
    public static func buildEither(second: [Any]) -> [Any] { second }
    public static func buildOptional(_ component: [Any]?) -> [Any] { component ?? [] }
    public static func buildArray(_ components: [[Any]]) -> [Any] { components.flatMap { $0 } }
}

public struct AxisMarkValues: Sendable {
    enum Step: Sendable {
        case automatic(Int)
        case calendar(Calendar.Component, Int, Calendar?)
    }

    let step: Step
    public static let automatic = Self(step: .automatic(4))
    public static func automatic(desiredCount: Int?, roundLowerBound: Bool? = nil, roundUpperBound: Bool? = nil) -> Self {
        Self(step: .automatic(desiredCount ?? 4))
    }
    public static func stride(by component: Calendar.Component, count: Int = 1, calendar: Calendar? = nil) -> Self {
        Self(step: .calendar(component, count, calendar))
    }
}

public struct AxisValue {
    public let index: Int
    public let count: Int
    let plotted: _PlotValue
    let original: Any?

    public func `as`<T>(_ type: T.Type) -> T? { original as? T ?? plotted.converted(to: type) }
}

public struct AxisMarks {
    let position: AnnotationPosition
    let makeValues: (ChartScale, Calendar) -> [(_PlotValue, Any?)]
    let makeContent: @MainActor (AxisValue) -> [Any]

    public init(position: AnnotationPosition = .automatic, values: AxisMarkValues = .automatic,
                @AxisContentBuilder content: @escaping @MainActor (AxisValue) -> [Any] = { _ in [AxisGridLine(), AxisTick(), AxisValueLabel()] }) {
        self.position = position
        makeValues = { scale, calendar in values.values(in: scale, calendar: calendar) }
        makeContent = content
    }

    public init<P: Plottable>(position: AnnotationPosition = .automatic, values: [P],
                              @AxisContentBuilder content: @escaping @MainActor (AxisValue) -> [Any] = { _ in [AxisGridLine(), AxisTick(), AxisValueLabel()] }) {
        self.position = position
        makeValues = { _, _ in values.map { ($0._plotValue, $0) } }
        makeContent = content
    }

    public init(preset: Any?, position: AnnotationPosition = .automatic, values: AxisMarkValues = .automatic) {
        self.init(position: position, values: values)
    }
}

public struct AxisGridLine {
    let stroke: StrokeStyle
    var style = AnyShapeStyle(Color.secondary.opacity(0.25))
    public init(centered: Bool? = nil, stroke: StrokeStyle? = nil) {
        self.stroke = stroke ?? StrokeStyle(lineWidth: 0.5)
    }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> Self {
        var line = self
        line.style = AnyShapeStyle(style)
        return line
    }
}

public struct AxisTick {
    let length: CGFloat
    let stroke: StrokeStyle
    var style = AnyShapeStyle(Color.secondary.opacity(0.55))
    public init(centered: Bool? = nil, length: CGFloat? = nil, stroke: StrokeStyle? = nil) {
        self.length = max(0, length ?? 4)
        self.stroke = stroke ?? StrokeStyle(lineWidth: 0.5)
    }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> Self {
        var tick = self
        tick.style = AnyShapeStyle(style)
        return tick
    }
}

public struct AxisValueLabel {
    let anchor: UnitPoint?
    var style: AnyShapeStyle?
    let content: @MainActor (AxisValue) -> AnyView

    public init() {
        anchor = nil
        content = { value in
            switch value.plotted {
            case .number(let number): AnyView(Text(number.formatted(.number.precision(.fractionLength(0...6)))))
            case .category(let text): AnyView(Text(text))
            }
        }
    }
    public init(_ text: String) {
        anchor = nil
        content = { _ in AnyView(Text(text)) }
    }
    public init<F: FormatStyle>(format: F, centered: Bool? = nil, anchor: UnitPoint? = nil) where F.FormatOutput == String {
        self.anchor = anchor
        content = { value in
            guard let input = value.as(F.FormatInput.self) else { return AnyView(EmptyView()) }
            return AnyView(Text(input, format: format))
        }
    }
    @MainActor public init<C: View>(centered: Bool? = nil, anchor: UnitPoint? = nil, @ViewBuilder content: () -> C) {
        self.anchor = anchor
        let view = AnyView(content())
        self.content = { _ in view }
    }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> Self {
        var label = self
        label.style = AnyShapeStyle(style)
        return label
    }
}

private extension AxisMarkValues {
    func values(in scale: ChartScale, calendar: Calendar) -> [(_PlotValue, Any?)] {
        switch step {
        case .automatic(let count):
            if !scale.categories.isEmpty { return scale.categories.map { (.category($0), $0) } }
            return numbers(in: scale.domain, count: count).map { (.number($0), $0) }
        case .calendar(let component, let count, let override):
            return dates(in: scale.domain, by: component, count: count, calendar: override ?? calendar)
                .map { ($0._plotValue, $0) }
        }
    }

    func numbers(in domain: ClosedRange<Double>, count: Int) -> [Double] {
        let ideal = (domain.upperBound - domain.lowerBound) / Double(max(1, min(64, count) - 1))
        let magnitude = pow(10.0, floor(log10(ideal)))
        guard magnitude.isFinite, magnitude > 0 else { return [domain.lowerBound] }
        let scaled = ideal / magnitude
        let step = magnitude * ([1.0, 2, 2.5, 5, 10].min { abs($0 - scaled) < abs($1 - scaled) } ?? 1)
        guard step.isFinite, step > 0 else { return [domain.lowerBound] }
        let first = (domain.lowerBound / step).rounded(.up)
        let last = (domain.upperBound / step).rounded(.down)
        guard last >= first, last - first <= 128 else { return [domain.lowerBound, domain.upperBound] }
        return (0...Int(last - first)).map { (first + Double($0)) * step }
    }

    func dates(in domain: ClosedRange<Double>, by component: Calendar.Component, count: Int, calendar: Calendar) -> [Date] {
        guard count > 0, domain.lowerBound.isFinite, domain.upperBound.isFinite else { return [] }
        let start = Date(timeIntervalSinceReferenceDate: domain.lowerBound)
        let end = Date(timeIntervalSinceReferenceDate: domain.upperBound)
        let unit = component == .hour && count <= 24 ? Calendar.Component.day : component
        var tick = calendar.dateInterval(of: unit, for: start)?.start ?? start
        var result: [Date] = []
        for _ in 0..<256 {
            if tick > end { break }
            if tick >= start { result.append(tick) }
            guard let next = calendar.date(byAdding: component, value: count, to: tick), next > tick else { break }
            tick = next
        }
        return result
    }
}

struct ChartAxes {
    private enum Edge { case top, bottom, leading, trailing }
    private struct Tick {
        let fraction: CGFloat
        let value: AxisValue
        let contents: [Any]
    }
    private struct Axis {
        let edge: Edge
        let ticks: [Tick]
        var isHorizontal: Bool { edge == .top || edge == .bottom }
        var hasLabels: Bool { ticks.contains { $0.contents.contains { $0 is AxisValueLabel } } }
        var tickLength: CGFloat { ticks.flatMap(\.contents).compactMap { ($0 as? AxisTick)?.length }.max() ?? 0 }
    }

    struct Label {
        let view: AnyView
        let position: CGPoint
        let anchor: UnitPoint
        let widthLimit: CGFloat
    }

    private let axes: [Axis]
    let plot: CGRect

    @MainActor init(x: [AxisMarks], y: [AxisMarks], scales: (x: ChartScale, y: ChartScale), calendar: Calendar, size: CGSize) {
        func resolve(_ marks: AxisMarks, _ scale: ChartScale, edge: Edge) -> Axis {
            let values = marks.makeValues(scale, calendar)
            let ticks = values.enumerated().compactMap { index, entry -> Tick? in
                guard let position = scale.position(entry.0, extent: 1), position >= -1e-10, position <= 1 + 1e-10 else { return nil }
                let tick = AxisValue(index: index, count: values.count, plotted: entry.0, original: entry.1)
                return Tick(fraction: min(1, max(0, position)), value: tick, contents: marks.makeContent(tick))
            }
            return Axis(edge: edge, ticks: ticks)
        }
        let resolved = x.map { resolve($0, scales.x, edge: $0.position == .top ? .top : .bottom) }
            + y.map { resolve($0, scales.y, edge: $0.position == .leading ? .leading : .trailing) }
        axes = resolved
        let yLabels = resolved.contains { !$0.isHorizontal && $0.hasLabels }
        func extent(_ edge: Edge, labelSpace: CGFloat, minimum: CGFloat) -> CGFloat {
            resolved.filter { $0.edge == edge }.reduce(minimum) { current, axis in
                max(current, axis.tickLength + (axis.hasLabels ? labelSpace : 0))
            }
        }
        let labelWidth = min(64, max(36, size.width * 0.13))
        let left = min(size.width / 3, extent(.leading, labelSpace: labelWidth, minimum: 0))
        let right = min(size.width / 3, extent(.trailing, labelSpace: labelWidth, minimum: 0))
        let top = min(size.height / 3, extent(.top, labelSpace: 20, minimum: yLabels ? 7 : 0))
        let bottom = min(size.height / 3, extent(.bottom, labelSpace: 20, minimum: yLabels ? 7 : 0))
        plot = CGRect(x: left, y: top, width: max(0, size.width - left - right), height: max(0, size.height - top - bottom))
    }

    private func segment(_ tick: Tick, on axis: Axis) -> (start: CGPoint, end: CGPoint) {
        if axis.isHorizontal {
            let x = plot.minX + tick.fraction * plot.width
            return (CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY))
        }
        let y = plot.minY + tick.fraction * plot.height
        return (CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y))
    }

    @MainActor func draw(in context: inout GraphicsContext, grid: Bool) {
        for axis in axes {
            for tick in axis.ticks {
                let line = segment(tick, on: axis)
                for content in tick.contents {
                    if grid, let mark = content as? AxisGridLine {
                        context.stroke(Path { $0.move(to: line.start); $0.addLine(to: line.end) }, with: .style(mark.style), style: mark.stroke)
                    } else if !grid, let mark = content as? AxisTick {
                        let start = axis.edge == .top || axis.edge == .leading ? line.start : line.end
                        var end = start
                        switch axis.edge {
                        case .top: end.y -= mark.length
                        case .bottom: end.y += mark.length
                        case .leading: end.x -= mark.length
                        case .trailing: end.x += mark.length
                        }
                        context.stroke(Path { $0.move(to: start); $0.addLine(to: end) }, with: .style(mark.style), style: mark.stroke)
                    }
                }
            }
        }
    }

    var hasGrid: Bool { axes.flatMap(\.ticks).contains { $0.contents.contains { $0 is AxisGridLine } } }
    var hasTicks: Bool { axes.contains { $0.tickLength > 0 } }

    @MainActor func labels(chartSize: CGSize) -> [Label] {
        axes.flatMap { axis in
            axis.ticks.flatMap { tick in
                let line = segment(tick, on: axis)
                let gap = axis.tickLength + 5
                return tick.contents.compactMap { content -> Label? in
                    guard let label = content as? AxisValueLabel else { return nil }
                    let position: CGPoint
                    let anchor: UnitPoint
                    let width: CGFloat
                    switch axis.edge {
                    case .top:
                        position = CGPoint(x: line.start.x, y: line.start.y - gap)
                        anchor = .bottom
                        width = chartSize.width
                    case .bottom:
                        position = CGPoint(x: line.end.x, y: line.end.y + gap)
                        anchor = .top
                        width = chartSize.width
                    case .leading:
                        position = CGPoint(x: line.start.x - gap, y: line.start.y)
                        anchor = .trailing
                        width = position.x
                    case .trailing:
                        position = CGPoint(x: line.end.x + gap, y: line.end.y)
                        anchor = .leading
                        width = chartSize.width - position.x
                    }
                    let view = label.content(tick.value).font(.caption2).lineLimit(1)
                        .foregroundStyle(label.style ?? AnyShapeStyle(Color.secondary))
                    return Label(view: AnyView(view), position: position, anchor: label.anchor ?? anchor, widthLimit: max(0, width))
                }
            }
        }
    }
}

struct ChartAxisLabelLayout: Layout {
    let size: CGSize
    let labels: [ChartAxes.Label]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (label, view) in zip(labels, subviews) {
            let ideal = view.sizeThatFits(.unspecified)
            let width = min(ideal.width, label.widthLimit)
            let x = min(max(0, label.position.x - label.anchor.x * width), max(0, bounds.width - width))
            let y = min(max(0, label.position.y - label.anchor.y * ideal.height), max(0, bounds.height - ideal.height))
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(width: width, height: ideal.height))
        }
    }
}
