import CoreGraphics
import CoreText
import FoundationModels
import ImageIO
import Metal
import QuartzCore
import ScreenCaptureKit
import Speech
import Vision
import VideoToolbox
import XCTest

final class CoreGraphicsTests: XCTestCase {
    func context(_ w: Int, _ h: Int, info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
    }
    func px(_ img: CGImage, _ x: Int, _ y: Int) -> [UInt8] { Array(img.pixels[(y * img.width + x) * 4..<(y * img.width + x) * 4 + 4]) }

    func testFillsStrokesAndTransforms() {
        let ctx = context(20, 20)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 20, height: 20))
        var img = ctx.makeImage()!
        XCTAssertEqual(px(img, 10, 10), [255, 0, 0, 255])
        XCTAssertEqual(px(img, 0, 0)[3], 0, "outside the circle")
        XCTAssertGreaterThan(px(img, 3, 3)[3], 0, "anti-aliased edge")
        // A flip to top-left space, then a 2-pixel horizontal line near the top.
        ctx.clear(CGRect(x: 0, y: 0, width: 20, height: 20))
        ctx.translateBy(x: 0, y: 20)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: 0, y: 3))
        ctx.addLine(to: CGPoint(x: 20, y: 3))
        ctx.strokePath()
        img = ctx.makeImage()!
        XCTAssertEqual(px(img, 10, 2), [0, 0, 0, 255])
        XCTAssertEqual(px(img, 10, 10)[3], 0)
    }

    func testRoundedPathsGradientsAndShadows() {
        let ctx = context(40, 40)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 5, y: 5, width: 30, height: 30), cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.setFillColor(CGColor.white)
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 4, color: CGColor(gray: 0, alpha: 0.5))
        ctx.fillPath()
        let img = ctx.makeImage()!
        XCTAssertEqual(px(img, 20, 20), [255, 255, 255, 255])
        XCTAssertEqual(px(img, 5, 5)[3] < 255, true, "rounded corner")
        XCTAssertGreaterThan(px(img, 20, 37)[3], 0, "shadow below")
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor.black, CGColor.white] as CFArray, locations: [0, 1])!
        let gc = context(10, 1)
        gc.drawLinearGradient(g, start: .zero, end: CGPoint(x: 10, y: 0), options: [])
        let gi = gc.makeImage()!
        XCTAssertLessThan(px(gi, 1, 0)[0], px(gi, 8, 0)[0])
    }

    func testByteOrdersAndFloatContexts() {
        // premultipliedFirst + 32Little is BGRA in memory.
        var bytes = [UInt8](repeating: 0, count: 4 * 4)
        let ctx = CGContext(data: &bytes, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(Array(bytes[0..<4]), [0, 0, 255, 255])
        let half = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 16, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        XCTAssertNotNil(half)
        half!.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        half!.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertEqual(Int(half!.makeImage()!.pixels[0]), 128, accuracy: 1, "linear storage, sRGB image")
        var alpha = [UInt8](repeating: 0, count: 4)
        let a8 = CGContext(data: &alpha, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)!
        a8.draw(CGImage(width: 1, height: 1, rgba: [9, 9, 9, 200]), in: CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(alpha, [200, 200, 200, 200])
    }

    func testDisplaysAndAccess() {
        XCTAssertFalse(CGDisplayServices.displays.isEmpty)
        XCTAssertEqual(CGDisplayBounds(CGMainDisplayID()).width > 0, true)
        XCTAssertNotNil(CGDisplayCopyDisplayMode(CGMainDisplayID()))
        XCTAssertTrue(CGPreflightScreenCaptureAccess())
        XCTAssertNil(CGPDFDocument(URL(fileURLWithPath: "/tmp/none.pdf") as CFURL))
    }
}

final class CoreTextTests: XCTestCase {
    func attributed(_ s: String, size: CGFloat = 20) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [NSAttributedString.Key(rawValue: "NSFont"): CTFont(family: nil, size: size),
                                                   NSAttributedString.Key(rawValue: "CTForegroundColor"): CGColor.black])
    }

    func testMeasuresAndWraps() {
        let line = CTLineCreateWithAttributedString(attributed("Hello, world"))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let w = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        XCTAssertGreaterThan(w, 60)
        XCTAssertGreaterThan(ascent, 10)
        let setter = CTFramesetterCreateWithAttributedString(attributed("one two three four five six seven eight nine ten"))
        let wide = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), nil)
        let narrow = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: 80, height: CGFloat.greatestFiniteMagnitude), nil)
        XCTAssertGreaterThan(narrow.height, wide.height * 2)
        XCTAssertLessThanOrEqual(narrow.width, 80.5)
        XCTAssertFalse((CTFontManagerCopyAvailableFontFamilyNames() as! [String]).isEmpty)
    }

    func testDrawsIntoAContext() {
        let ctx = CGContext(data: nil, width: 120, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.textPosition = CGPoint(x: 4, y: 12)
        CTLineDraw(CTLineCreateWithAttributedString(attributed("Hg")), ctx)
        let img = ctx.makeImage()!
        XCTAssertGreaterThan(img.pixels.enumerated().filter { $0.offset % 4 == 3 && $0.element > 128 }.count, 20)
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed("Frame")), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 0, y: 0, width: 120, height: 40), transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }
}

final class LayerAndAvailabilityTests: XCTestCase {
    func testLayerGeometryTreeAndRender() {
        let root = CALayer()
        var invalidated = 0
        root.onInvalidate = { invalidated += 1 }
        root.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        root.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        let child = CALayer()
        child.frame = CGRect(x: 2, y: 2, width: 4, height: 4)
        child.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        root.addSublayer(child)
        XCTAssertEqual(child.position, CGPoint(x: 4, y: 4))
        XCTAssertGreaterThan(invalidated, 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var done = false
        CATransaction.setCompletionBlock { done = true }
        child.frame.origin = CGPoint(x: 5, y: 5)
        CATransaction.commit()
        XCTAssertTrue(done)
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        root.render(in: ctx)
        let img = ctx.makeImage()!
        XCTAssertEqual(Array(img.pixels[(3 * 10 + 6) * 4..<(3 * 10 + 6) * 4 + 3]), [255, 0, 0], "child at CG (5…9, 5…9) → top rows")
        XCTAssertEqual(Array(img.pixels[(9 * 10) * 4..<(9 * 10) * 4 + 3]), [0, 0, 255])
        let a = CABasicAnimation(keyPath: "opacity")
        child.add(a, forKey: "fade")
        XCTAssertNil(child.animation(forKey: "fade"))
    }

    func testUnavailableFrameworksAnswerHonestly() async throws {
        XCTAssertNil(MTLCreateSystemDefaultDevice())
        XCTAssertEqual(SystemLanguageModel.default.availability, .unavailable(.deviceNotEligible))
        do {
            _ = try await LanguageModelSession(instructions: "x").respond(to: "hi")
            XCTFail("responded")
        } catch {}
        XCTAssertEqual(SFSpeechRecognizer.authorizationStatus(), .restricted)
        XCTAssertFalse(SpeechTranscriber.isAvailable)
        XCTAssertFalse(SFSpeechRecognizer()?.isAvailable ?? true)
        let req = VNRecognizeTextRequest()
        XCTAssertThrowsError(try VNImageRequestHandler(cgImage: CGImage(width: 1, height: 1, rgba: [0, 0, 0, 255])).perform([req]))
        var session: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: 2, height: 2, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                                  imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                  compressionSessionOut: &session), kVTCouldNotFindVideoEncoderErr)
    }

    func testScreenCaptureFailsThroughStreamErrors() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        XCTAssertFalse(content.displays.isEmpty)
        XCTAssertTrue(content.windows.isEmpty)
        let filter = SCContentFilter(display: content.displays[0], excludingWindows: [])
        XCTAssertGreaterThan(filter.contentRect.width, 0)
        guard ProcessInfo.processInfo.environment["DISPLAY"] == nil else { return }
        let stream = SCStream(filter: filter, configuration: SCStreamConfiguration(), delegate: nil)
        do {
            try await stream.startCapture()
            XCTFail("captured without a display server")
        } catch let e as SCStreamError {
            XCTAssertEqual(e.code, .failedToStart)
        }
    }
}
