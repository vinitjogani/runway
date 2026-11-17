import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import XCTest

final class CoreImageTests: XCTestCase {
    let ctx = CIContext()

    /// RGBA bytes of `img` over `rect`, top row first.
    func pixels(_ img: CIImage, _ rect: CGRect) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Int(rect.width * rect.height) * 4)
        ctx.render(img, toBitmap: &b, rowBytes: Int(rect.width) * 4, bounds: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return b
    }
    func at(_ p: [UInt8], _ w: Int, _ x: Int, _ y: Int) -> [UInt8] { Array(p[(y * w + x) * 4..<(y * w + x) * 4 + 4]) }

    func testSourceOverAndRowOrder() {
        // Red over CI's upper half of a blue 4×4: the bitmap's first rows are red.
        let size = CGRect(x: 0, y: 0, width: 4, height: 4)
        let top = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 2, width: 4, height: 2))
        let img = top.composited(over: CIImage(color: .blue).cropped(to: size))
        XCTAssertEqual(img.extent, size)
        let p = pixels(img, size)
        XCTAssertEqual(at(p, 4, 0, 0), [255, 0, 0, 255])
        XCTAssertEqual(at(p, 4, 0, 3), [0, 0, 255, 255])
    }

    func testPixelBufferRoundTrip() {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 8, 6, kCVPixelFormatType_32BGRA, nil, &pb)
        let img = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 3))
        ctx.render(img, to: pb!)
        let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
        // Bottom half (rows 3…5) is the colour, BGRA; top half clear.
        let row = CVPixelBufferGetBytesPerRow(pb!)
        XCTAssertEqual([base[5 * row], base[5 * row + 1], base[5 * row + 2], base[5 * row + 3]], [255, 153, 51, 255])
        XCTAssertEqual(base[3], 0)
        let back = CIImage(cvPixelBuffer: pb!)
        XCTAssertEqual(back.extent, CGRect(x: 0, y: 0, width: 8, height: 6))
        XCTAssertEqual(at(pixels(back, back.extent), 8, 0, 5), [51, 153, 255, 255])
    }

    func testColorMatrixFadesAndAffineScales() {
        let img = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let shadow = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5),
        ])
        let p = pixels(shadow, shadow.extent)
        XCTAssertEqual(p[3], 128)
        XCTAssertEqual(p[0], 0)
        let big = img.transformed(by: CGAffineTransform(scaleX: 3, y: 2))
        XCTAssertEqual(big.extent, CGRect(x: 0, y: 0, width: 6, height: 4))
        XCTAssertEqual(at(pixels(big, big.extent), 6, 3, 2), [255, 255, 255, 255])
    }

    func testGaussianBlurSpreadsSymmetrically() {
        let dot = CIImage(color: .white).cropped(to: CGRect(x: 10, y: 10, width: 1, height: 1))
        let blurred = dot.applyingGaussianBlur(sigma: 2)
        XCTAssertEqual(blurred.extent, CGRect(x: 4, y: 4, width: 13, height: 13))
        let r = CGRect(x: 0, y: 0, width: 21, height: 21)
        let p = pixels(blurred, r)
        let left = at(p, 21, 8, 10)[3], right = at(p, 21, 12, 10)[3], centre = at(p, 21, 10, 10)[3]
        XCTAssertEqual(left, right)
        XCTAssertGreaterThan(centre, left)
        XCTAssertGreaterThan(left, 0)
    }

    func testBuiltinsGeneratorsAndMasks() {
        let rr = CIFilter.roundedRectangleGenerator()
        rr.extent = CGRect(x: 0, y: 0, width: 20, height: 20)
        rr.radius = 8
        rr.color = .white
        let mask = rr.outputImage!
        XCTAssertEqual(mask.extent, CGRect(x: 0, y: 0, width: 20, height: 20))
        let p = pixels(mask, mask.extent)
        XCTAssertEqual(at(p, 20, 0, 0)[3], 0, "corners are cut")
        XCTAssertEqual(at(p, 20, 10, 10)[3], 255)
        // Blend with the mask: red where the mask is, nothing elsewhere.
        let red = CIImage(color: .red).cropped(to: mask.extent)
        let clipped = red.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
        let c = pixels(clipped, mask.extent)
        XCTAssertEqual(at(c, 20, 10, 10), [255, 0, 0, 255])
        XCTAssertEqual(at(c, 20, 0, 0)[3], 0)
        // The ring: a mask minus a smaller one.
        let inner = CIFilter.roundedRectangleGenerator()
        inner.extent = CGRect(x: 4, y: 4, width: 12, height: 12)
        inner.radius = 4
        inner.color = .white
        let ring = mask.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner.outputImage!])
        XCTAssertEqual(at(pixels(ring, mask.extent), 20, 10, 10)[3], 0)
        XCTAssertEqual(at(pixels(ring, mask.extent), 20, 10, 1)[3], 255)

        let g = CIFilter.linearGradient()
        g.point0 = .zero
        g.point1 = CGPoint(x: 10, y: 0)
        g.color0 = .black
        g.color1 = .white
        let gp = pixels(g.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 10, height: 1)), CGRect(x: 0, y: 0, width: 10, height: 1))
        XCTAssertLessThan(gp[0], gp[36])
        let cc = CIFilter.colorControls()
        cc.inputImage = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        cc.saturation = 0
        let grey = pixels(cc.outputImage!, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(grey[0], grey[1])
        XCTAssertNotNil(CIFilter.randomGenerator().outputImage)
    }

    func testCreateCGImageAndOrientation() {
        let img = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 2))
        let cg = ctx.createCGImage(img, from: img.extent)!
        XCTAssertEqual(cg.width, 4)
        XCTAssertEqual(Array(cg.pixels[0..<4]), [0, 255, 0, 255])
        XCTAssertEqual(CIImage(cgImage: cg).oriented(.right).extent.size, CGSize(width: 2, height: 4))
        XCTAssertEqual(CIImage(cgImage: cg).oriented(.down).extent, CGRect(x: 0, y: 0, width: 4, height: 2))
        XCTAssertTrue(CIImage.empty().extent.isNull)
        XCTAssertNil(MTLCreateSystemDefaultDevice())
        XCTAssertNotNil(CIFilter(name: "CIGaussianBlur"))
        XCTAssertNil(CIFilter(name: "CINotAFilter"))
    }
}
