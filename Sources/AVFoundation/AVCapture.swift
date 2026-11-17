// Capture: devices from GStreamer's device monitor (V4L2/PipeWire cameras,
// PulseAudio/PipeWire microphones), authorization (granted: Linux has no
// per-app media permission), and AVCaptureSession running one pipeline per
// input (v4l2src / pulsesrc → appsink) on a thread that hands sample buffers
// to the outputs' delegates, plus a movie file output that encodes them.

import CRunwayGst
import CoreMedia
import CoreVideo
import Foundation

public enum AVAuthorizationStatus: Int, Sendable { case notDetermined = 0, restricted, denied, authorized }

open class AVCaptureDevice: NSObject, @unchecked Sendable {
    public struct DeviceType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let builtInWideAngleCamera = DeviceType(rawValue: "AVCaptureDeviceTypeBuiltInWideAngleCamera")
        public static let external = DeviceType(rawValue: "AVCaptureDeviceTypeExternal")
        public static let externalUnknown = DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown")
        public static let continuityCamera = DeviceType(rawValue: "AVCaptureDeviceTypeContinuityCamera")
        public static let deskViewCamera = DeviceType(rawValue: "AVCaptureDeviceTypeDeskViewCamera")
        public static let microphone = DeviceType(rawValue: "AVCaptureDeviceTypeMicrophone")
        public static let builtInMicrophone = DeviceType(rawValue: "AVCaptureDeviceTypeBuiltInMicrophone")
    }
    public enum Position: Int, Sendable { case unspecified = 0, back, front }
    public enum TorchMode: Int, Sendable { case off = 0, on, auto }
    public enum FocusMode: Int, Sendable { case locked = 0, autoFocus, continuousAutoFocus }

    public static let wasConnectedNotification = Notification.Name("AVCaptureDeviceWasConnectedNotification")
    public static let wasDisconnectedNotification = Notification.Name("AVCaptureDeviceWasDisconnectedNotification")

    public let uniqueID: String
    public let localizedName: String
    public let modelID: String
    public let manufacturer: String
    public let deviceType: DeviceType
    public let position: Position = .unspecified
    let media: AVMediaType
    let api: String
    let isDefaultDevice: Bool

    init(id: String, name: String, media: AVMediaType, api: String, isDefault: Bool) {
        uniqueID = id
        localizedName = name
        modelID = name
        manufacturer = ""
        self.media = media
        self.api = api
        isDefaultDevice = isDefault
        deviceType = media == .audio ? .microphone : .external
        super.init()
    }

    open func hasMediaType(_ mediaType: AVMediaType) -> Bool { mediaType == media }
    open var isConnected: Bool { true }
    open var isSuspended: Bool { false }
    open var isInUseByAnotherApplication: Bool { false }
    open var hasTorch: Bool { false }
    open var hasFlash: Bool { false }
    open var formats: [AVCaptureDevice.Format] { [Format()] }
    open var activeFormat = Format()
    open var activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
    open var activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
    open var linkedDevices: [AVCaptureDevice] { [] }
    open func lockForConfiguration() throws {}
    open func unlockForConfiguration() {}
    open func supportsSessionPreset(_ preset: AVCaptureSession.Preset) -> Bool { true }

    open class Format: NSObject, @unchecked Sendable {
        public var formatDescription: CMFormatDescription { CMFormatDescription(mediaType: kCMMediaType_Video, subType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, dimensions: .init(width: 1280, height: 720)) }
        public var videoSupportedFrameRateRanges: [AVFrameRateRange] { [AVFrameRateRange()] }
        public var mediaType: AVMediaType { .video }
    }

    // Discovery.
    static func all(_ media: AVMediaType) -> [AVCaptureDevice] {
        guard Gst.available else { return [] }
        final class Sink { var out: [AVCaptureDevice] = []; let media: AVMediaType; init(_ m: AVMediaType) { media = m } }
        let sink = Sink(media)
        let ctx = Unmanaged.passUnretained(sink).toOpaque()
        _ = rg_list_devices(media == .audio ? "Audio/Source" : "Video/Source", { ctx, name, id, api, isDefault in
            guard let ctx, let name, let id else { return }
            let s = Unmanaged<Sink>.fromOpaque(ctx).takeUnretainedValue()
            let n = String(cString: name), i = String(cString: id), a = api.map { String(cString: $0) } ?? ""
            // A monitor of an output isn't a microphone.
            if s.media == .audio, n.hasPrefix("Monitor of") || i.hasSuffix(".monitor") { return }
            if s.out.contains(where: { $0.uniqueID == i }) { return }
            s.out.append(AVCaptureDevice(id: i, name: n, media: s.media, api: a, isDefault: isDefault != 0))
        }, ctx)
        if media == .video, sink.out.isEmpty {
            // No monitor provider: V4L2 nodes directly.
            let nodes = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("video") }.sorted()
            for n in nodes {
                let name = (try? String(contentsOfFile: "/sys/class/video4linux/\(n)/name", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? n
                sink.out.append(AVCaptureDevice(id: "/dev/\(n)", name: name, media: .video, api: "v4l2", isDefault: sink.out.isEmpty))
            }
        }
        return sink.out
    }

    open class func devices(for mediaType: AVMediaType) -> [AVCaptureDevice] { all(mediaType) }
    open class func devices() -> [AVCaptureDevice] { all(.video) + all(.audio) }
    open class func `default`(for mediaType: AVMediaType) -> AVCaptureDevice? {
        let d = all(mediaType)
        return d.first(where: \.isDefaultDevice) ?? d.first
    }
    open class func `default`(_ deviceType: DeviceType, for mediaType: AVMediaType?, position: Position) -> AVCaptureDevice? {
        `default`(for: mediaType ?? (deviceType == .microphone || deviceType == .builtInMicrophone ? .audio : .video))
    }
    public convenience init?(uniqueID deviceUniqueID: String) {
        guard let d = (AVCaptureDevice.all(.video) + AVCaptureDevice.all(.audio)).first(where: { $0.uniqueID == deviceUniqueID }) else { return nil }
        self.init(id: d.uniqueID, name: d.localizedName, media: d.media, api: d.api, isDefault: d.isDefaultDevice)
    }

    // Authorization: no per-app gate on Linux (device nodes and PipeWire decide).
    open class func authorizationStatus(for mediaType: AVMediaType) -> AVAuthorizationStatus { .authorized }
    open class func requestAccess(for mediaType: AVMediaType, completionHandler handler: @escaping @Sendable (Bool) -> Void) { handler(true) }
    public class func requestAccess(for mediaType: AVMediaType) async -> Bool { true }

    public final class DiscoverySession: NSObject, @unchecked Sendable {
        public let devices: [AVCaptureDevice]
        public init(deviceTypes: [DeviceType], mediaType: AVMediaType?, position: Position) {
            let wantsAudio = mediaType == .audio || (mediaType == nil && deviceTypes.contains { $0 == .microphone || $0 == .builtInMicrophone })
            let wantsVideo = mediaType == .video || (mediaType == nil && deviceTypes.contains { $0 != .microphone && $0 != .builtInMicrophone })
            var d: [AVCaptureDevice] = []
            if wantsVideo { d += AVCaptureDevice.all(.video).filter { deviceTypes.contains($0.deviceType) || deviceTypes.contains(.external) } }
            if wantsAudio { d += AVCaptureDevice.all(.audio).filter { deviceTypes.contains($0.deviceType) || deviceTypes.contains(.external) } }
            devices = d
            super.init()
        }
        public static func discoverySession(deviceTypes: [DeviceType], mediaType: AVMediaType?, position: Position) -> DiscoverySession {
            DiscoverySession(deviceTypes: deviceTypes, mediaType: mediaType, position: position)
        }
    }

    /// The launch description of a source for this device.
    var sourceElement: String {
        if media == .audio {
            if Gst.has("pulsesrc") { return "pulsesrc device=\"\(uniqueID)\"" }
            return Gst.has("pipewiresrc") ? "pipewiresrc target-object=\"\(uniqueID)\"" : "autoaudiosrc"
        }
        if uniqueID.hasPrefix("/dev/"), Gst.has("v4l2src") { return "v4l2src device=\(uniqueID)" }
        return Gst.has("pipewiresrc") ? "pipewiresrc target-object=\"\(uniqueID)\"" : "autovideosrc"
    }
}

public final class AVFrameRateRange: NSObject, @unchecked Sendable {
    public let minFrameRate: Float64 = 1, maxFrameRate: Float64 = 30
    public let minFrameDuration = CMTime(value: 1, timescale: 30), maxFrameDuration = CMTime(value: 1, timescale: 1)
}

// MARK: Inputs and outputs

open class AVCaptureInput: NSObject, @unchecked Sendable {
    open var ports: [AVCaptureInput.Port] { [] }
    open class Port: NSObject, @unchecked Sendable {}
}

open class AVCaptureDeviceInput: AVCaptureInput, @unchecked Sendable {
    public let device: AVCaptureDevice
    public init(device: AVCaptureDevice) throws {
        guard Gst.available else { throw avError(.deviceNotConnected, "Capture needs GStreamer, which isn't available here.") }
        self.device = device
        super.init()
    }
    public class func deviceInput(withDevice device: AVCaptureDevice) throws -> AVCaptureDeviceInput { try AVCaptureDeviceInput(device: device) }
}

open class AVCaptureConnection: NSObject, @unchecked Sendable {
    open var isEnabled = true
    open var isActive: Bool { true }
    open var isVideoMirrored = false
    open var automaticallyAdjustsVideoMirroring = true
    open var videoRotationAngle: CGFloat = 0
    open var isVideoMirroringSupported: Bool { true }
    open func isVideoRotationAngleSupported(_ angle: CGFloat) -> Bool { angle == 0 }
    weak var output: AVCaptureOutput?
}

open class AVCaptureOutput: NSObject, @unchecked Sendable {
    weak var session: AVCaptureSession?
    let theConnection = AVCaptureConnection()
    open var connections: [AVCaptureConnection] { [theConnection] }
    open func connection(with mediaType: AVMediaType) -> AVCaptureConnection? { theConnection }
    var wants: AVMediaType { .video }
    func deliver(_ sb: CMSampleBuffer) {}
}

public protocol AVCaptureVideoDataOutputSampleBufferDelegate: AnyObject {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection)
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection)
}
extension AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}
public protocol AVCaptureAudioDataOutputSampleBufferDelegate: AnyObject {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection)
}
extension AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
}

open class AVCaptureVideoDataOutput: AVCaptureOutput, @unchecked Sendable {
    open var videoSettings: [String: Any]! = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
    open var alwaysDiscardsLateVideoFrames = true
    open var automaticallyConfiguresOutputBufferDimensions = true
    public private(set) weak var sampleBufferDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    public private(set) var sampleBufferCallbackQueue: DispatchQueue?
    public override init() { super.init() }
    open func setSampleBufferDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate?, queue: DispatchQueue?) {
        sampleBufferDelegate = delegate
        sampleBufferCallbackQueue = queue
    }
    open var availableVideoPixelFormatTypes: [OSType] { [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA] }
    var pixelFormat: OSType {
        (videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
            ?? (videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType) ?? kCVPixelFormatType_32BGRA
    }
    override func deliver(_ sb: CMSampleBuffer) {
        guard let d = sampleBufferDelegate else { return }
        let box = UncheckedBox((d, sb, self))
        let work: @Sendable () -> Void = { box.value.0.captureOutput(box.value.2, didOutput: box.value.1, from: box.value.2.theConnection) }
        if let q = sampleBufferCallbackQueue { q.sync(execute: work) } else { work() }
    }
}

open class AVCaptureAudioDataOutput: AVCaptureOutput, @unchecked Sendable {
    open var audioSettings: [String: Any]!
    public private(set) weak var sampleBufferDelegate: AVCaptureAudioDataOutputSampleBufferDelegate?
    public private(set) var sampleBufferCallbackQueue: DispatchQueue?
    public override init() { super.init() }
    override var wants: AVMediaType { .audio }
    open func setSampleBufferDelegate(_ delegate: AVCaptureAudioDataOutputSampleBufferDelegate?, queue: DispatchQueue?) {
        sampleBufferDelegate = delegate
        sampleBufferCallbackQueue = queue
    }
    override func deliver(_ sb: CMSampleBuffer) {
        guard let d = sampleBufferDelegate else { return }
        let box = UncheckedBox((d, sb, self))
        let work: @Sendable () -> Void = { box.value.0.captureOutput(box.value.2, didOutput: box.value.1, from: box.value.2.theConnection) }
        if let q = sampleBufferCallbackQueue { q.sync(execute: work) } else { work() }
    }
}

public protocol AVCaptureFileOutputRecordingDelegate: AnyObject {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?)
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection])
}
extension AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {}
}

open class AVCaptureFileOutput: AVCaptureOutput, @unchecked Sendable {
    public private(set) var outputFileURL: URL?
    public private(set) var isRecording = false
    open var maxRecordedDuration: CMTime = .invalid
    open var recordedDuration: CMTime { first.map { CMClockGetTime(CMClockGetHostTimeClock()) - $0 } ?? .zero }
    private var writer: AVAssetWriter?
    private var inputs: [AVMediaType: AVAssetWriterInput] = [:]
    private weak var delegate: AVCaptureFileOutputRecordingDelegate?
    private var first: CMTime?
    private let lock = NSLock()

    open func startRecording(to outputFileURL: URL, recordingDelegate delegate: AVCaptureFileOutputRecordingDelegate) {
        lock.lock(); defer { lock.unlock() }
        self.outputFileURL = outputFileURL
        self.delegate = delegate
        try? FileManager.default.removeItem(at: outputFileURL)
        writer = try? AVAssetWriter(outputURL: outputFileURL, fileType: outputFileURL.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        isRecording = writer != nil
        first = nil
        inputs = [:]
        if isRecording { delegate.fileOutput(self, didStartRecordingTo: outputFileURL, from: connections) }
    }
    open func stopRecording() {
        lock.lock()
        let w = writer, url = outputFileURL, d = delegate
        writer = nil
        isRecording = false
        lock.unlock()
        guard let w, let url else { return }
        w.finishWriting { [self] in d?.fileOutput(self, didFinishRecordingTo: url, from: connections, error: w.error) }
    }
    override func deliver(_ sb: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let w = writer, isRecording else { return }
        let media: AVMediaType = sb.imageBuffer != nil ? .video : .audio
        if inputs[media] == nil {
            guard w.status == .unknown else { return }
            if media == .video, let pb = sb.imageBuffer as? CVPixelBuffer {
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: pb.width, AVVideoHeightKey: pb.height])
                i.expectsMediaDataInRealTime = true
                w.add(i)
                inputs[.video] = i
            } else if media == .audio {
                let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
                w.add(i)
                inputs[.audio] = i
            }
            // The file starts once every connected stream has a format.
            let want = Set((session?.outputs ?? []).compactMap { _ in AVMediaType?.none })
            _ = want
            if w.startWriting() {
                w.startSession(atSourceTime: sb.presentationTimeStamp)
                first = sb.presentationTimeStamp
            }
        }
        _ = inputs[media]?.append(sb)
    }
}
open class AVCaptureMovieFileOutput: AVCaptureFileOutput, @unchecked Sendable {
    public override init() { super.init() }
    open var availableVideoCodecTypes: [AVVideoCodecType] { [.h264, .hevc] }
    open func setOutputSettings(_ outputSettings: [String: Any]?, for connection: AVCaptureConnection) {}
}
open class AVCaptureAudioFileOutput: AVCaptureFileOutput, @unchecked Sendable {
    public override init() { super.init() }
    override var wants: AVMediaType { .audio }
}

// MARK: Session

open class AVCaptureSession: NSObject, @unchecked Sendable {
    public struct Preset: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let high = Preset(rawValue: "AVCaptureSessionPresetHigh"), medium = Preset(rawValue: "AVCaptureSessionPresetMedium")
        public static let low = Preset(rawValue: "AVCaptureSessionPresetLow"), photo = Preset(rawValue: "AVCaptureSessionPresetPhoto")
        public static let hd1280x720 = Preset(rawValue: "AVCaptureSessionPreset1280x720"), hd1920x1080 = Preset(rawValue: "AVCaptureSessionPreset1920x1080")
        public static let hd4K3840x2160 = Preset(rawValue: "AVCaptureSessionPreset3840x2160"), vga640x480 = Preset(rawValue: "AVCaptureSessionPreset640x480")
        public static let qHD960x540 = Preset(rawValue: "AVCaptureSessionPreset960x540"), inputPriority = Preset(rawValue: "AVCaptureSessionPresetInputPriority")
        var size: (Int, Int)? {
            switch self {
            case .hd1280x720, .high: (1280, 720)
            case .hd1920x1080: (1920, 1080)
            case .hd4K3840x2160: (3840, 2160)
            case .vga640x480, .medium: (640, 480)
            case .qHD960x540: (960, 540)
            case .low: (320, 240)
            default: nil
            }
        }
    }
    public static let runtimeErrorNotification = Notification.Name("AVCaptureSessionRuntimeErrorNotification")
    public static let didStartRunningNotification = Notification.Name("AVCaptureSessionDidStartRunningNotification")
    public static let didStopRunningNotification = Notification.Name("AVCaptureSessionDidStopRunningNotification")
    public static let wasInterruptedNotification = Notification.Name("AVCaptureSessionWasInterruptedNotification")
    public static let errorKey = "AVCaptureSessionErrorKey"

    public private(set) var inputs: [AVCaptureInput] = []
    public private(set) var outputs: [AVCaptureOutput] = []
    open var sessionPreset: Preset = .high
    public private(set) var isRunning = false
    public private(set) var isInterrupted = false
    /// Samples are stamped on the host clock.
    open var synchronizationClock: CMClock? { CMClockGetHostTimeClock() }
    open var masterClock: CMClock? { synchronizationClock }
    open var connections: [AVCaptureConnection] { outputs.flatMap(\.connections) }
    private var pipelines: [(GstPipeline, AVCaptureDevice)] = []
    private var threads: [Thread] = []
    private let lock = NSLock()

    public override init() { super.init() }

    open func beginConfiguration() {}
    open func commitConfiguration() {}
    open func canSetSessionPreset(_ preset: Preset) -> Bool { true }
    open func canAddInput(_ input: AVCaptureInput) -> Bool { !inputs.contains { $0 === input } }
    open func addInput(_ input: AVCaptureInput) { if canAddInput(input) { inputs.append(input) } }
    open func removeInput(_ input: AVCaptureInput) { inputs.removeAll { $0 === input } }
    open func canAddOutput(_ output: AVCaptureOutput) -> Bool { !outputs.contains { $0 === output } }
    open func addOutput(_ output: AVCaptureOutput) {
        guard canAddOutput(output) else { return }
        output.session = self
        outputs.append(output)
    }
    open func removeOutput(_ output: AVCaptureOutput) { outputs.removeAll { $0 === output } }
    open func addInputWithNoConnections(_ input: AVCaptureInput) { addInput(input) }
    open func addOutputWithNoConnections(_ output: AVCaptureOutput) { addOutput(output) }
    open func addConnection(_ connection: AVCaptureConnection) {}
    open func canAddConnection(_ connection: AVCaptureConnection) -> Bool { true }

    /// Starts one pipeline per device input (blocks until they run, like Apple's).
    open func startRunning() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()
        for case let input as AVCaptureDeviceInput in inputs {
            let dev = input.device
            let desc: String
            if dev.media == .audio {
                desc = "\(dev.sourceElement) ! audioconvert ! audioresample ! audio/x-raw,format=F32LE,layout=interleaved,rate=48000,channels=2 ! appsink name=sink sync=false max-buffers=16"
            } else {
                let fmt = (outputs.compactMap { $0 as? AVCaptureVideoDataOutput }.first?.pixelFormat) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "NV12" : "BGRA"
                let size = sessionPreset.size.map { ",width=\($0.0),height=\($0.1)" } ?? ""
                desc = "\(dev.sourceElement) ! videoconvert ! videoscale ! video/x-raw,format=\(fmt)\(size) ! appsink name=sink sync=false max-buffers=2 drop=true"
            }
            guard let p = try? GstPipeline(desc), p.state(.playing, timeout: 5) else {
                NotificationCenter.default.post(name: Self.runtimeErrorNotification, object: self,
                                                userInfo: [Self.errorKey: avError(.deviceNotConnected, "Couldn't open \(dev.localizedName).")])
                continue
            }
            pipelines.append((p, dev))
            let t = Thread { [weak self] in self?.pump(p, dev) }
            t.name = "AVCaptureSession \(dev.localizedName)"
            threads.append(t)
            t.start()
        }
        NotificationCenter.default.post(name: Self.didStartRunningNotification, object: self)
    }

    private func pump(_ p: GstPipeline, _ dev: AVCaptureDevice) {
        while isRunning {
            switch p.pull("sink", timeout: 0.5) {
            case .sample(var f):
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                var sb: CMSampleBuffer?
                if dev.media == .audio, let data = f.data {
                    let bytes = Data(bytes: data, count: Int(f.size))
                    let frames = Int(f.size) / 8
                    sb = CMSampleBuffer(pcm: bytes, format: .pcm(rate: 48000, channels: 2, bits: 32, float: true),
                                        presentationTimeStamp: now - CMTime(value: Int64(frames), timescale: 48000))
                } else if let pb = pixelBuffer(from: f) {
                    sb = CMSampleBuffer(imageBuffer: pb, timing: CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: now, decodeTimeStamp: .invalid))
                }
                rg_frame_release(&f)
                guard let sb else { continue }
                for o in outputs where o.wants == dev.media || o is AVCaptureMovieFileOutput { o.deliver(sb) }
            case .timeout: continue
            case .eos, .error:
                NotificationCenter.default.post(name: Self.runtimeErrorNotification, object: self,
                                                userInfo: [Self.errorKey: avError(.deviceWasDisconnected, p.lastError ?? "\(dev.localizedName) stopped.")])
                return
            }
        }
    }

    open func stopRunning() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        let ps = pipelines
        pipelines = []
        threads = []
        lock.unlock()
        for (p, _) in ps { p.state(.null) }
        NotificationCenter.default.post(name: Self.didStopRunningNotification, object: self)
    }
}

/// The camera's picture in a layer (frames arrive while the session runs).
open class AVCaptureVideoPreviewLayer: CALayer, @unchecked Sendable {
    open var session: AVCaptureSession?
    open var videoGravity: AVLayerVideoGravity = .resizeAspect
    open var connection: AVCaptureConnection? { AVCaptureConnection() }
    public override init() { super.init() }
    public convenience init(session: AVCaptureSession) {
        self.init()
        self.session = session
    }
    public convenience init(sessionWithNoConnection session: AVCaptureSession) { self.init(session: session) }
    public override init(layer: Any) { super.init(layer: layer) }
    open func setSessionWithNoConnection(_ session: AVCaptureSession) { self.session = session }
    open func captureDevicePointConverted(fromLayerPoint p: CGPoint) -> CGPoint {
        CGPoint(x: bounds.width > 0 ? p.x / bounds.width : 0, y: bounds.height > 0 ? p.y / bounds.height : 0)
    }
}
