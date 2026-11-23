import XCTest
import RunwayCore
import SwiftUI

@MainActor
final class ShapeGeometryTests: XCTestCase {
    func testCircleInsetAccumulatesAndKeepsCenter() {
        let bounds = CGRect(x: 5, y: 10, width: 120, height: 100)
        let circle = Circle().inset(by: 4).inset(by: 6)
        XCTAssertEqual(circle.path(in: bounds).boundingRect, CGRect(x: 25, y: 20, width: 80, height: 80))
        XCTAssertTrue(circle.inset(by: 40).path(in: bounds).isEmpty)
    }

    func testTrimmedPathKeepsSubpathGaps() {
        let path = Path { path in
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: 10, y: 0))
            path.move(to: CGPoint(x: 50, y: 50))
            path.addLine(to: CGPoint(x: 50, y: 60))
        }
        let trimmed = path.trimmedPath(from: 0.25, to: 0.75)
        XCTAssertEqual(trimmed.cgPath.ops, [
            .move(CGPoint(x: 5, y: 0)), .line(CGPoint(x: 10, y: 0)),
            .move(CGPoint(x: 50, y: 50)), .line(CGPoint(x: 50, y: 55)),
        ])
        XCTAssertTrue(path.trimmedPath(from: 0.25, to: 0.25).isEmpty)
        XCTAssertEqual(path.trimmedPath(from: 0, to: 1), path)
    }

    func testInsetQuarterCircleRotatesToTop() {
        let arc = Circle().inset(by: 4).trim(to: 0.25).rotation(.degrees(-90))
        let path = arc.path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).cgPath
        guard case let .move(start)? = path.ops.first else { return XCTFail("Arc must have a starting point") }
        XCTAssertEqual(start.x, 50, accuracy: 0.001)
        XCTAssertEqual(start.y, 4, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint.x, 96, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint.y, 50, accuracy: 0.001)
    }

    func testRotationEffectRotatesAFramedShapeAboutTheRequestedAnchor() {
        let backend = HeadlessBackend()
        let view = Rectangle().fill(.red).frame(width: 40, height: 20)
            .rotationEffect(.degrees(90), anchor: .topLeading)
        let host = ViewHost(view, backend: backend)
        host.setSize(CGSize(width: 100, height: 100))
        host.render()

        guard let canvas = (host.container as? HeadlessWidget)?.all.first(where: { $0.kind == .canvas }),
              case let .fill(path, _)? = canvas.props.drawing.first else { return XCTFail("Missing rotated drawing") }
        XCTAssertEqual(canvas.frame, CGRect(x: 10, y: 40, width: 20, height: 40))
        XCTAssertEqual(path.bounds, CGRect(x: 0, y: 0, width: 20, height: 40))
    }

    func testCanvasAndRotatedShapeKeepStrokeStyle() {
        let style = StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .bevel,
                                miterLimit: 4, dash: [3, 2], dashPhase: 1)
        let view = VStack {
            Circle().inset(by: 4).trim(to: 0.88).stroke(.teal, style: style).rotationEffect(.degrees(-90))
            Canvas { context, size in
                context.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.teal), style: style)
            }
        }
        let host = ViewHost(view, backend: HeadlessBackend())
        host.setSize(CGSize(width: 100, height: 220))
        host.render()

        let root = host.container as! HeadlessWidget
        let styles = root.all.flatMap(\.props.drawing).compactMap { command -> CGStrokeStyle? in
            guard case let .stroke(_, _, style) = command else { return nil }
            return style
        }
        XCTAssertEqual(styles.count, 2)
        for style in styles {
            XCTAssertEqual(style.lineWidth, 8)
            XCTAssertEqual(style.lineCap, .round)
            XCTAssertEqual(style.lineJoin, .bevel)
            XCTAssertEqual(style.miterLimit, 4)
            XCTAssertEqual(style.dashLengths, [3, 2])
            XCTAssertEqual(style.dashPhase, 1)
        }
    }
}
