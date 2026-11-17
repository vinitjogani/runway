import CoreMedia
import CoreVideo
import XCTest

final class CoreMediaTests: XCTestCase {
    func testArithmeticAcrossTimescales() {
        let a = CMTime(value: 1, timescale: 3), b = CMTime(value: 1, timescale: 2)
        let s = a + b
        XCTAssertEqual(s.value, 5)
        XCTAssertEqual(s.timescale, 6)
        XCTAssertFalse(s.hasBeenRounded)
        XCTAssertEqual((b - a).value, 1)
        XCTAssertEqual((b - a).timescale, 6)
        XCTAssertEqual(CMTimeAdd(CMTime(value: 1, timescale: 600), CMTime(value: 1, timescale: 600)).value, 2)
        XCTAssertEqual((CMTime(value: 3, timescale: 10) * Int32(4)).seconds, 1.2, accuracy: 1e-12)
        XCTAssertEqual(CMTimeMultiplyByRatio(CMTime(value: 10, timescale: 30), multiplier: 1, divisor: 3).value, 3) // 3.33 → 3
        XCTAssertEqual(CMTimeMultiplyByFloat64(CMTime(value: 30, timescale: 30), multiplier: 1.5).seconds, 1.5, accuracy: 1e-12)
    }

    func testComparisonIsExactAndOrdersSpecialValues() {
        XCTAssertEqual(CMTime(value: 1, timescale: 3), CMTime(value: 2, timescale: 6))
        XCTAssertLessThan(CMTime(value: 1, timescale: 3), CMTime(value: 334, timescale: 1000))
        XCTAssertEqual(CMTimeCompare(CMTime(value: Int64.max / 2, timescale: 7), CMTime(value: Int64.max / 2, timescale: 9)), 1)
        let order: [CMTime] = [.negativeInfinity, CMTime(seconds: -5, preferredTimescale: 1), .zero, CMTime(seconds: 1e6, preferredTimescale: 1), .indefinite, .positiveInfinity, .invalid]
        for i in 0..<(order.count - 1) { XCTAssertEqual(CMTimeCompare(order[i], order[i + 1]), -1, "\(order[i]) < \(order[i + 1])") }
        XCTAssertEqual(CMTimeCompare(.invalid, .invalid), 0)
        XCTAssertEqual(Set([CMTime(value: 1, timescale: 2), CMTime(value: 2, timescale: 4)]).count, 1)
    }

    func testSpecialValueArithmetic() {
        XCTAssertTrue((CMTime.positiveInfinity + CMTime(value: 1, timescale: 1)).isPositiveInfinity)
        XCTAssertFalse((CMTime.positiveInfinity + CMTime.negativeInfinity).isValid)
        XCTAssertTrue((CMTime.positiveInfinity - CMTime.negativeInfinity).isPositiveInfinity)
        XCTAssertTrue((CMTime.indefinite + .zero).isIndefinite)
        XCTAssertFalse((CMTime.invalid + .zero).isValid)
        XCTAssertTrue(CMTime(value: Int64.max, timescale: 1) + CMTime(value: 1, timescale: 1) == .positiveInfinity)
        XCTAssertTrue(CMTime(seconds: .nan, preferredTimescale: 600) == .invalid)
        XCTAssertTrue(CMTime(seconds: .infinity, preferredTimescale: 600).isPositiveInfinity)
        XCTAssertTrue(CMTime(seconds: 1, preferredTimescale: 600).isNumeric)
        XCTAssertFalse(CMTime(value: 1, timescale: 0).isValid)
    }

    func testSecondsAndRounding() {
        let t = CMTime(seconds: 1.0 / 3, preferredTimescale: 600)
        XCTAssertEqual(t.value, 200)
        XCTAssertFalse(t.hasBeenRounded)
        let r = CMTime(seconds: 0.0001, preferredTimescale: 600)
        XCTAssertTrue(r.hasBeenRounded)
        XCTAssertEqual(CMTime(value: 1, timescale: 3).convertScale(10, method: .roundHalfAwayFromZero).value, 3)
        XCTAssertEqual(CMTime(value: 2, timescale: 3).convertScale(10, method: .roundTowardZero).value, 6)
        XCTAssertEqual(CMTime(value: 2, timescale: 3).convertScale(10, method: .roundAwayFromZero).value, 7)
        XCTAssertEqual(CMTime(value: -2, timescale: 3).convertScale(10, method: .roundTowardNegativeInfinity).value, -7)
        XCTAssertEqual(CMTimeGetSeconds(CMTime(value: 3, timescale: 4)), 0.75)
        XCTAssertTrue(CMTimeGetSeconds(.invalid).isNaN)
        XCTAssertEqual(CMTimeAbsoluteValue(CMTime(value: -3, timescale: 4)).value, 3)
        XCTAssertEqual(CMTimeMaximum(CMTime(value: 1, timescale: 2), CMTime(value: 2, timescale: 3)), CMTime(value: 2, timescale: 3))
        XCTAssertEqual(CMTimeMinimum(.invalid, CMTime(value: 1, timescale: 2)), CMTime(value: 1, timescale: 2))
    }

    func testRangesAndMappings() {
        let r = CMTimeRange(start: CMTime(value: 1, timescale: 1), end: CMTime(value: 3, timescale: 1))
        XCTAssertEqual(r.duration, CMTime(value: 2, timescale: 1))
        XCTAssertTrue(r.containsTime(CMTime(value: 1, timescale: 1)))
        XCTAssertFalse(r.containsTime(CMTime(value: 3, timescale: 1)))
        let o = CMTimeRange(start: CMTime(value: 2, timescale: 1), duration: CMTime(value: 5, timescale: 1))
        XCTAssertEqual(r.intersection(o), CMTimeRange(start: CMTime(value: 2, timescale: 1), end: CMTime(value: 3, timescale: 1)))
        XCTAssertEqual(r.union(o).end, CMTime(value: 7, timescale: 1))
        XCTAssertTrue(CMTimeRange(start: .zero, end: CMTime(value: 10, timescale: 1)).containsTimeRange(r))
        XCTAssertTrue(CMTimeRange.zero.isEmpty)
        XCTAssertFalse(CMTimeRange.invalid.isValid)
        XCTAssertEqual(r.intersection(CMTimeRange(start: CMTime(value: 5, timescale: 1), duration: CMTime(value: 1, timescale: 1))), .zero)
        let doubled = CMTimeMapTimeFromRangeToRange(CMTime(value: 2, timescale: 1), fromRange: r, toRange: CMTimeRange(start: .zero, duration: CMTime(value: 4, timescale: 1)))
        XCTAssertEqual(doubled.seconds, 2, accuracy: 1e-9)
        XCTAssertEqual(CMTimeClampToRange(CMTime(value: 9, timescale: 1), range: r), r.end)
        let m = CMTimeMapping(target: r)
        XCTAssertTrue(m.isEmpty)
        let encoded = try! JSONEncoder().encode(CMTime(value: 7, timescale: 30))
        XCTAssertEqual(try! JSONDecoder().decode(CMTime.self, from: encoded), CMTime(value: 7, timescale: 30))
    }

    func testHostClockAndTimebase() {
        let a = CMClockGetTime(CMClockGetHostTimeClock())
        let b = CMClockGetTime(CMClockGetHostTimeClock())
        XCTAssertGreaterThanOrEqual(b, a)
        XCTAssertEqual(CMSyncConvertTime(a, from: CMClockGetHostTimeClock(), to: CMClockGetHostTimeClock()), a)
        let tb = CMTimebase(sourceClock: .hostTimeClock)
        tb.setTime(CMTime(value: 10, timescale: 1))
        XCTAssertEqual(tb.time.seconds, 10, accuracy: 0.01) // rate 0: stands still
    }

    func testSampleBuffersRetime() {
        let pb = CVPixelBuffer(width: 4, height: 2, pixelFormat: kCVPixelFormatType_32BGRA)!
        let sb = CMSampleBuffer(imageBuffer: pb, timing: CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: CMTime(value: 3, timescale: 30), decodeTimeStamp: .invalid))
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(CMSampleBufferGetFormatDescription(sb)!).width, 4)
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        timing[0].presentationTimeStamp = timing[0].presentationTimeStamp + CMTime(value: 1, timescale: 1)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sb, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(out!).seconds, 1.1, accuracy: 1e-9)
        XCTAssertTrue(CMSampleBufferGetImageBuffer(out!) === pb)

        let pcm = CMSampleBuffer(pcm: Data(count: 4800 * 8), format: .pcm(rate: 48000, channels: 2, bits: 32, float: true), presentationTimeStamp: .zero)
        XCTAssertEqual(pcm.numSamples, 4800)
        XCTAssertEqual(pcm.duration.seconds, 0.1, accuracy: 1e-9)
        XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(pcm.formatDescription!)?.pointee.mChannelsPerFrame, 2)
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        XCTAssertEqual(CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(pcm)!, atOffset: 0, lengthAtOffsetOut: &len, totalLengthOut: nil, dataPointerOut: &ptr), noErr)
        XCTAssertEqual(len, 4800 * 8)
    }

    func testPixelBuffersAndPlanes() {
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 6, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb), kCVReturnSuccess)
        let b = pb!
        XCTAssertEqual(CVPixelBufferGetPlaneCount(b), 2)
        XCTAssertEqual(CVPixelBufferGetWidthOfPlane(b, 1), 3)
        XCTAssertEqual(CVPixelBufferGetHeightOfPlane(b, 1), 2)
        XCTAssertGreaterThanOrEqual(CVPixelBufferGetBytesPerRowOfPlane(b, 0), 6)
        // A mid-grey written as RGBA reads back (within YCbCr rounding).
        b.write(rgba: [UInt8](repeating: 128, count: 6 * 4 * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }, width: 6, height: 4)
        let back = b.rgba()
        XCTAssertEqual(Int(back[0]), 128, accuracy: 2)
        XCTAssertEqual(back[3], 255)
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, OSType(fourCC: "zzzz"), nil, &pb), kCVReturnInvalidPixelFormat)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(b, .readOnly), kCVReturnSuccess)
        XCTAssertNotNil(CVPixelBufferGetBaseAddressOfPlane(b, 1))
        CVPixelBufferUnlockBaseAddress(b, .readOnly)
        CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        XCTAssertNotNil(CVBufferCopyAttachment(b, kCVImageBufferYCbCrMatrixKey, nil))
    }

    func testDisplayLinkTicksOnlyWhileRunning() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        let ticks = expectation(description: "ticks")
        ticks.assertForOverFulfill = false
        CVDisplayLinkSetOutputHandler(link!) { _, _, _, _, _ in ticks.fulfill(); return kCVReturnSuccess }
        XCTAssertFalse(CVDisplayLinkIsRunning(link!))
        CVDisplayLinkStart(link!)
        wait(for: [ticks], timeout: 2)
        CVDisplayLinkStop(link!)
        XCTAssertFalse(CVDisplayLinkIsRunning(link!))
    }
}
