import XCTest
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
}
