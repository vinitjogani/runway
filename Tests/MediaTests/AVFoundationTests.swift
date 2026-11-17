@testable import AVFoundation
import XCTest

/// A 2 s, 320×240, 30 fps red H.264 + 440 Hz AAC MP4, made once with gst-launch.
enum MediaFixture {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("runway-media-tests-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func launch(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gst-launch-1.0", "-q"] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static let movie: URL? = {
        let url = dir.appendingPathComponent("red.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let ok = launch(("videotestsrc pattern=red num-buffers=60 ! video/x-raw,width=320,height=240,framerate=30/1 ! x264enc ! h264parse ! "
                         + "mp4mux name=m ! filesink location=\(url.path) audiotestsrc freq=440 num-buffers=94 samplesperbuffer=1024 ! "
                         + "audio/x-raw,rate=48000,channels=2 ! audioconvert ! avenc_aac ! aacparse ! m.").split(separator: " ").map(String.init))
        return ok ? url : nil
    }()
}

final class AVFoundationTests: XCTestCase {
    func movie() throws -> URL {
        try XCTSkipUnless(GstFixture.isAvailable, "GStreamer isn't available")
        return try XCTUnwrap(MediaFixture.movie, "gst-launch couldn't make the fixture")
    }

    func testAssetDurationTracksAndSize() async throws {
        let asset = AVURLAsset(url: try movie(), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.1)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        let (size, transform) = try await video[0].load(.naturalSize, .preferredTransform)
        XCTAssertEqual(size, CGSize(width: 320, height: 240))
        XCTAssertTrue(transform.isIdentity)
        XCTAssertEqual(video[0].nominalFrameRate, 30, accuracy: 0.5)
    }

    func testMissingFileFailsThroughTheLoadError() async {
        let asset = AVURLAsset(url: URL(fileURLWithPath: "/nonexistent/clip.mov"))
        do {
            _ = try await asset.load(.duration)
            XCTFail("loaded a missing file")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testImageGeneratorFrame() async throws {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: try movie()))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let (cg, actual) = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        XCTAssertEqual(cg.width, 320)
        XCTAssertEqual(cg.height, 240)
        XCTAssertEqual(actual.seconds, 1, accuracy: 0.05)
        let i = (120 * 320 + 160) * 4
        XCTAssertGreaterThan(cg.pixels[i], 200, "red")
        XCTAssertLessThan(cg.pixels[i + 1], 60)
        gen.maximumSize = CGSize(width: 160, height: 160)
        XCTAssertEqual(try gen.copyCGImage(at: .zero, actualTime: nil).width, 160)
    }

    func testCompositionWithACustomCompositor() async throws {
        let src = AVURLAsset(url: try movie())
        let comp = AVMutableComposition()
        let vt = try XCTUnwrap(comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let srcTrack = try await src.loadTracks(withMediaType: .video)[0]
        try vt.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)), of: srcTrack, at: .zero)
        try vt.insertTimeRange(CMTimeRange(start: CMTime(value: 1, timescale: 2), duration: CMTime(value: 1, timescale: 2)), of: srcTrack, at: CMTime(value: 1, timescale: 1))
        XCTAssertEqual(vt.timeRange.end.seconds, 1.5, accuracy: 1e-9)
        XCTAssertEqual(vt.segments.count, 2)
        vt.removeTimeRange(CMTimeRange(start: CMTime(value: 1, timescale: 4), duration: CMTime(value: 1, timescale: 4)))
        XCTAssertEqual(comp.duration.seconds, 1.25, accuracy: 1e-9)
        XCTAssertEqual(comp.tracks.count, 1)

        let v = AVMutableVideoComposition()
        v.customVideoCompositorClass = HalfCompositor.self
        v.renderSize = CGSize(width: 64, height: 48)
        v.frameDuration = CMTime(value: 1, timescale: 30)
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        ins.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: vt)]
        v.instructions = [ins]
        let gen = AVAssetImageGenerator(asset: comp)
        gen.videoComposition = v
        let (cg, _) = try await gen.image(at: CMTime(seconds: 1.1, preferredTimescale: 600))
        XCTAssertEqual(cg.width, 64)
        // Left half the source (red), right half blue.
        XCTAssertGreaterThan(cg.pixels[(24 * 64 + 10) * 4], 200)
        XCTAssertGreaterThan(cg.pixels[(24 * 64 + 50) * 4 + 2], 200)
    }

    func testWriterThenReaderRoundTrip() async throws {
        _ = try movie()
        let url = MediaFixture.dir.appendingPathComponent("green-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(writer.error.map { "\($0)" } ?? "")")
        writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            let pb = CVPixelBuffer(width: 64, height: 48, pixelFormat: kCVPixelFormatType_32BGRA)!
            let p = pb.base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<48 { for x in 0..<64 { let o = y * pb.bytesPerRow + x * 4; p[o] = 0; p[o + 1] = 255; p[o + 2] = 0; p[o + 3] = 255 } }
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(writer.error.map { "\($0)" } ?? "")")

        let asset = AVURLAsset(url: url)
        let d = try await asset.load(.duration)
        XCTAssertEqual(d.seconds, 1, accuracy: 0.1)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: try await asset.loadTracks(withMediaType: .video)[0],
                                           outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        var green = false
        while let s = out.copyNextSampleBuffer() {
            if frames == 10, let pb = CMSampleBufferGetImageBuffer(s) {
                let p = pb.base.assumingMemoryBound(to: UInt8.self)
                green = p[1] > 200 && p[2] < 60
            }
            frames += 1
        }
        XCTAssertEqual(frames, 30)
        XCTAssertTrue(green)
        XCTAssertEqual(reader.status, .completed)
    }

    /// A writer input's transform (a phone's portrait video) is stored in
    /// the file and read back as the track's preferredTransform.
    func testWriterStoresTheTransform() async throws {
        _ = try movie()
        let url = MediaFixture.dir.appendingPathComponent("turned-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48])
        let turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 48, ty: 0)
        input.transform = turn
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<10 {
            XCTAssertTrue(adaptor.append(CVPixelBuffer(width: 64, height: 48, pixelFormat: kCVPixelFormatType_32BGRA)!,
                                         withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        XCTAssertEqual(size, CGSize(width: 64, height: 48))
        XCTAssertEqual(transform, turn)
    }

    func testAudioMixReaderAndVolume() async throws {
        let asset = AVURLAsset(url: try movie())
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(value: 1, timescale: 2), duration: CMTime(value: 1, timescale: 2))
        let out = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ])
        let mix = AVMutableAudioMix()
        let p = AVMutableAudioMixInputParameters(track: track)
        p.setVolume(0.5, at: .zero)
        mix.inputParameters = [p]
        out.audioMix = mix
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var peak: Float = 0, n = 0
        while let s = out.copyNextSampleBuffer() {
            let b = CMSampleBufferGetDataBuffer(s)!
            var f = [Float](repeating: 0, count: CMBlockBufferGetDataLength(b) / 4)
            CMBlockBufferCopyDataBytes(b, atOffset: 0, dataLength: f.count * 4, destination: &f)
            peak = max(peak, f.map(abs).max() ?? 0)
            n += f.count
        }
        XCTAssertEqual(n, 24000, "half a second at 48 kHz")
        XCTAssertGreaterThan(peak, 0.05)
        XCTAssertLessThan(peak, 0.55, "at half volume")
    }

    func testVolumeRampLookup() {
        let p = AVMutableAudioMixInputParameters()
        p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1)))
        var a: Float = -1, b: Float = -1
        var r = CMTimeRange.zero
        XCTAssertTrue(p.getVolumeRamp(for: CMTime(seconds: 1.5, preferredTimescale: 600), startVolume: &a, endVolume: &b, timeRange: &r))
        XCTAssertEqual(a, 0)
        XCTAssertEqual(b, 1)
        XCTAssertEqual(p.volume(at: CMTime(seconds: 1.5, preferredTimescale: 600)), 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.volume(at: CMTime(seconds: 3, preferredTimescale: 600)), 1)
        XCTAssertEqual(NSValue(timeRange: r).timeRangeValue, r)
    }

    func testExportSessionRoundTrip() async throws {
        let asset = AVURLAsset(url: try movie())
        let url = MediaFixture.dir.appendingPathComponent("export-\(UUID().uuidString).mp4")
        let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset640x480))
        try await session.export(to: url, as: .mp4)
        XCTAssertEqual(session.status, .completed)
        let back = AVURLAsset(url: url)
        let d = try await back.load(.duration)
        XCTAssertEqual(d.seconds, 2, accuracy: 0.15)
        let a = try await back.loadTracks(withMediaType: .audio)
        XCTAssertEqual(a.count, 1)
    }

    func testPlayerClockSeeksAndPlays() async throws {
        let item = AVPlayerItem(url: try movie())
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let deadline = Date().addingTimeInterval(10)
        while item.status != .readyToPlay, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        let ok = await player.seek(to: CMTime(seconds: 0.5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        XCTAssertTrue(ok)
        XCTAssertEqual(player.currentTime().seconds, 0.5, accuracy: 0.01)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        XCTAssertTrue(output.hasNewPixelBuffer(forItemTime: player.currentTime()))
        XCTAssertNotNil(output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil))
        player.play()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertGreaterThan(player.currentTime().seconds, 0.6)
        player.pause()
        XCTAssertEqual(player.timeControlStatus, .paused)
    }

    /// A layer attached before the item has loaded shows its first picture
    /// once it has (nothing else asks), and seeks made while a frame is being
    /// drawn still end on the picture at the last seek.
    @MainActor
    func testPlayerLayerShowsTheFirstFrameAndTheLatestSeek() async throws {
        let item = AVPlayerItem(url: try movie())
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let layer = AVPlayerLayer(player: player)
        XCTAssertNil(layer.contents)
        var deadline = Date().addingTimeInterval(10)
        while layer.contents == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(layer.isReadyForDisplay)
        XCTAssertEqual((layer.contents as? CGImage)?.width, 320)
        for s in [0.2, 0.4, 0.6, 1.5] { player.seek(to: CMTime(seconds: s, preferredTimescale: 600)) { _ in } }
        layer.contents = nil
        deadline = Date().addingTimeInterval(10)
        while layer.contents == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(layer.contents, "a picture after the seeks")
    }

    func testCaptureAuthorizationAndDiscovery() async {
        XCTAssertEqual(AVCaptureDevice.authorizationStatus(for: .video), .authorized)
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        XCTAssertTrue(granted)
        // Whatever this machine has; discovery must not crash or hang.
        _ = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
    }

    func testAudioFileWriteAndRead() throws {
        _ = try movie()
        let url = MediaFixture.dir.appendingPathComponent("tone-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buf.frameLength = 4800
            for i in 0..<4800 { buf.floatChannelData![0][i] = 0.5 * sin(Float(i) * 0.05) }
            try file.write(from: buf)
            file.close()
        }
        let read = try AVAudioFile(forReading: url)
        XCTAssertEqual(read.length, 4800, accuracy: 10)
        XCTAssertEqual(read.processingFormat.sampleRate, 48000)
        let buf = AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: 4800)!
        try read.read(into: buf)
        XCTAssertGreaterThan(buf.frameLength, 4000)
        XCTAssertGreaterThan((0..<Int(buf.frameLength)).map { abs(buf.floatChannelData![0][$0]) }.max() ?? 0, 0.4)
    }
}

/// Left half the source frame, right half blue.
final class HalfCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        DispatchQueue.global().async {
            guard let out = request.renderContext.newPixelBuffer(), let id = request.sourceTrackIDs.first?.int32Value,
                  let src = request.sourceFrame(byTrackID: id) else { return request.finish(with: NSError(domain: "test", code: 1)) }
            let rgba = src.rgba()
            let o = out.base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<out.height {
                for x in 0..<out.width {
                    let d = y * out.bytesPerRow + x * 4
                    if x < out.width / 2 {
                        let sx = x * src.width / out.width, sy = y * src.height / out.height, s = (sy * src.width + sx) * 4
                        o[d] = rgba[s + 2]; o[d + 1] = rgba[s + 1]; o[d + 2] = rgba[s]; o[d + 3] = 255
                    } else {
                        o[d] = 255; o[d + 1] = 0; o[d + 2] = 0; o[d + 3] = 255
                    }
                }
            }
            request.finish(withComposedVideoFrame: out)
        }
    }
}

enum GstFixture {
    static var isAvailable: Bool { FileManager.default.fileExists(atPath: "/usr/bin/gst-launch-1.0") }
}
