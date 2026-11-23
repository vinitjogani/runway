import XCTest
import RunwayCore
@testable import Charts

final class ChartsTests: XCTestCase {
    struct Sample: Identifiable { let id: Int; let name: String; let value: Double }

    @MainActor func testMarksCollect() {
        let samples = [Sample(id: 1, name: "a", value: 2), Sample(id: 2, name: "b", value: 5)]
        let chart = Chart {
            ForEach(samples) { s in
                BarMark(x: .value("Name", s.name), y: .value("Value", s.value)).foregroundStyle(.red)
            }
            RuleMark(y: .value("Limit", 4))
            if samples.count > 1 { LineMark(x: .value("Name", "a"), y: .value("Value", 1.0)) }
        }
        let marks = chart.content._marks
        XCTAssertEqual(marks.count, 4)
        XCTAssertEqual(marks[0].x, _PlotValue.category("a"))
        XCTAssertEqual(marks[0].y, _PlotValue.number(2))
        let donut = Chart {
            SectorMark(angle: .value("System", 0.2), innerRadius: .ratio(0.8)).foregroundStyle(.blue)
            SectorMark(angle: .value("Idle", 0.8), innerRadius: .ratio(0.8))
        }
        XCTAssertEqual(donut.content._marks.compactMap(\.angle), [0.2, 0.8])
        _ = donut.chartLegend(.hidden).chartBackground { proxy in Text("\(proxy.plotSize.width)") }.chartYScale(domain: 0...10)
    }

    @MainActor func testRangedAreasAndLinesKeepTheirSeriesAndBaseline() {
        let points = [0, 1, 3, 4]
        let chart = Chart(points, id: \.self) { point in
            let segment = point < 2 ? 0 : 1
            AreaMark(x: .value("Elapsed", point), yStart: .value("Baseline", 5), yEnd: .value("Heart rate", 15),
                     series: .value("Segment", segment))
            LineMark(x: .value("Elapsed", point), y: .value("Heart rate", 15), series: .value("Segment", segment))
        }
        let backend = HeadlessBackend()
        let host = ViewHost(chart.chartYScale(domain: 0...20), backend: backend)
        host.setSize(CGSize(width: 200, height: 100))
        host.render()
        let canvas = (host.container as! HeadlessWidget).all.first { $0.kind == .canvas }
        let commands = canvas?.props.drawing ?? []
        XCTAssertEqual(commands.count, 4)
        guard commands.count == 4,
              case .fill(let firstArea, _) = commands[0], case .stroke = commands[1],
              case .fill = commands[2], case .stroke = commands[3] else {
            return XCTFail("Expected a separate fill and line for each segment")
        }
        XCTAssertEqual(firstArea.bounds, CGRect(x: 0, y: 25, width: 50, height: 50))
    }

    @MainActor func testSpatialChartGestureSelectsDateAtTapLocation() throws {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let end = start.addingTimeInterval(60)
        var selected: Date?
        let selection = Binding(get: { selected }, set: { selected = $0 })
        let chart = Chart {
            PointMark(x: .value("Time", start), y: .value("Value", 1))
            PointMark(x: .value("Time", end), y: .value("Value", 2))
        }
        .chartXScale(domain: start...end)
        .chartYAxis {
            AxisMarks(position: .leading, values: [1, 2]) { tick in
                AxisValueLabel { Text("Y \(tick.as(Int.self) ?? 0)") }
            }
        }
        .chartXSelection(value: selection)
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { proxy.selectXValue(at: $0.location.x) }
        }
        let host = ViewHost(chart, backend: HeadlessBackend())
        host.setSize(CGSize(width: 200, height: 100))
        host.render()
        let tapArea = try XCTUnwrap((host.container as! HeadlessWidget).all.first { $0.kind == .tapArea })
        let tap = try XCTUnwrap(tapArea.events.onTapLocation)
        XCTAssertGreaterThan(tapArea.windowFrame.minX, 0)
        XCTAssertLessThan(tapArea.frame.width, 200)
        tap(CGPoint(x: tapArea.frame.width * 0.75, y: 50))
        XCTAssertEqual(selected, start.addingTimeInterval(45))
    }

    @MainActor func testAxesRenderFormattedLabelsTicksAndStyledGrid() throws {
        let monday = Date(timeIntervalSinceReferenceDate: 0)
        let wednesday = monday.addingTimeInterval(172_800)
        let locale = Locale(identifier: "en_US")
        let timezone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let format = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, timeZone: timezone).weekday(.abbreviated)
        let chart = Chart {
            RectangleMark(xStart: .value("Date", monday), xEnd: .value("Date", wednesday),
                          yStart: .value("Value", 0), yEnd: .value("Value", 80)).cornerRadius(3)
        }
        .chartXScale(domain: monday...wednesday)
        .chartYScale(domain: 0...100)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: [monday, wednesday]) { tick in
                AxisTick(length: 4)
                AxisValueLabel(format: format, anchor: tick.index == 0 ? .topLeading : .topTrailing)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { tick in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 1])).foregroundStyle(Color.red)
                AxisValueLabel { Text("\(tick.as(Int.self) ?? -1) bpm") }
            }
        }
        let host = ViewHost(chart, backend: HeadlessBackend())
        host.setSize(CGSize(width: 250, height: 150))
        host.render()
        let root = host.container as! HeadlessWidget
        let labels = Dictionary(uniqueKeysWithValues: root.all.compactMap { widget in widget.props.text.map { ($0.plain, widget.windowFrame) } })
        let firstDate = try XCTUnwrap(labels["Mon"])
        let lastDate = try XCTUnwrap(labels["Wed"])
        let midpoint = try XCTUnwrap(labels["50 bpm"])
        XCTAssertLessThan(firstDate.minX, lastDate.minX)
        XCTAssertLessThan(midpoint.maxX, firstDate.minX)
        XCTAssertGreaterThan(firstDate.minY, midpoint.maxY)

        let strokes = root.all.flatMap(\.props.drawing).compactMap { command -> (CGRect, CGFloat, [CGFloat])? in
            guard case .stroke(let shape, _, let style) = command else { return nil }
            return (shape.bounds, style.lineWidth, style.dashLengths)
        }
        XCTAssertEqual(strokes.filter { $0.1 == 0.5 && $0.2 == [2, 1] && $0.0.width > 0 }.count, 3)
        XCTAssertEqual(strokes.filter { $0.0.height == 4 && $0.2.isEmpty }.count, 2)
        XCTAssertTrue(root.all.contains { $0.props.clips })
        XCTAssertTrue(root.all.flatMap(\.props.drawing).contains {
            if case .fill(.roundedRect(_, radius: 3), _) = $0 { return true }
            return false
        })
    }

    @MainActor func testMonotoneInterpolationUsesCurvesWithoutOvershootingPeaks() throws {
        let values = [10, 30, 20]
        let chart = Chart(Array(values.enumerated()), id: \.offset) { index, value in
            LineMark(x: .value("X", index), y: .value("Y", value)).interpolationMethod(.monotone)
        }.chartYScale(domain: 0...40)
        let host = ViewHost(chart, backend: HeadlessBackend())
        host.setSize(CGSize(width: 200, height: 100))
        host.render()
        let commands = (host.container as! HeadlessWidget).all.flatMap(\.props.drawing)
        guard let first = commands.first, case .stroke(.path(let elements), _, _) = first else {
            return XCTFail("Expected a line path")
        }
        let curves = elements.compactMap { element -> [CGPoint]? in
            if case .curve(let end, let control1, let control2) = element { return [end, control1, control2] }
            return nil
        }
        XCTAssertEqual(curves.count, 2)
        XCTAssertTrue(curves.joined().allSatisfy { $0.y >= 25 && $0.y <= 75 })
    }
}
