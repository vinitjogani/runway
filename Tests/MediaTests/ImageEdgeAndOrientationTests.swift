// Core Image's sampling at an image's edges (clamped inside its extent, as
// on the Mac: scaled images keep hard, opaque edges) and EXIF orientation
// written by CGImageDestination and applied when reading PNGs.

import CoreImage
import ImageIO
import XCTest

final class ImageEdgeAndOrientationTests: XCTestCase {
    /// `w`×`h` with red = x and green = y ramps (0…255), opaque.
    func ramp(_ w: Int, _ h: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            bytes[(y * w + x) * 4] = UInt8((Double(x) / Double(w - 1) * 255).rounded())
            bytes[(y * w + x) * 4 + 1] = UInt8((Double(y) / Double(h - 1) * 255).rounded())
            bytes[(y * w + x) * 4 + 2] = 0
        } }
        return CGImage(width: w, height: h, rgba: bytes, hasAlpha: false)
    }

    func testScaledImageKeepsOpaqueEdges() {
        let i = CIImage(cgImage: ramp(40, 10)).transformed(by: CGAffineTransform(scaleX: 5, y: 5))
        let ctx = CIContext()
        let cg = ctx.createCGImage(i, from: i.extent)!
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(cg.pixels[(y * cg.width + x) * 4..<(y * cg.width + x) * 4 + 4]) }
        for (x, y) in [(0, 0), (199, 0), (0, 49), (199, 49), (100, 0), (100, 49)] {
            XCTAssertEqual(px(x, y)[3], 255, "edge pixel (\(x), \(y)) is opaque")
        }
        XCTAssertEqual(px(0, 25)[0], 0, "the left edge is the first column, unblended")
        XCTAssertEqual(px(199, 25)[0], 255)
        // Nothing outside the extent.
        let outside = ctx.createCGImage(i, from: CGRect(x: 200, y: 0, width: 4, height: 4))!
        XCTAssertEqual(outside.pixels[3], 0)
    }

    func testPNGOrientationRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orientation-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ramp(10, 40), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        XCTAssertEqual((props?["Orientation"] as? NSNumber)?.intValue, 6)
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(src, 0, nil)?.width, 10, "stored as it was")
        let upright = try XCTUnwrap(CIImage(contentsOf: url, options: [.applyOrientationProperty: true]))
        XCTAssertEqual(upright.extent.size, CGSize(width: 40, height: 10))
        let cg = CIContext().createCGImage(upright, from: upright.extent)!
        func px(_ x: Int, _ y: Int) -> [UInt8] { Array(cg.pixels[(y * cg.width + x) * 4..<(y * cg.width + x) * 4 + 3]) }
        // Turned a quarter clockwise: the stored left column runs along the top,
        // its bottom-left corner at the top-left.
        XCTAssertEqual(px(0, 0), [0, 255, 0])
        XCTAssertEqual(px(39, 0), [0, 0, 0])
        XCTAssertEqual(px(0, 9), [255, 255, 0])
    }
}
