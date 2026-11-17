// ScreenCaptureKit for Linux.
//
//   SCShareableContent   displays from GDK monitors (read on the main
//                        actor); windows and other apps are empty (neither
//                        Wayland nor the portals list them).
//   SCStream             on an X11 session, display capture with GStreamer's
//                        ximagesrc (and system audio from the default sink's
//                        monitor through pulsesrc), delivering CMSampleBuffers
//                        with ScreenCaptureKit's frame-info attachments.
//                        Elsewhere (Wayland needs the XDG ScreenCast portal +
//                        PipeWire, not wired up yet) `startCapture` fails
//                        with SCStreamError.failedToStart.
//   SCContentSharingPicker  the system picker would be the portal's dialog;
//                        `present()` reports a start failure to observers,
//                        so apps fall back to their own display list.

@_exported import CoreGraphics
@_exported import CoreMedia
@_exported import CoreVideo
@_exported import Foundation
import AVFoundation
import CRunwayGst
#if os(Linux)
import CGtk
#endif

// MARK: Errors

public let SCStreamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"

public struct SCStreamError: CustomNSError, Hashable, Sendable {
    public enum Code: Int, Sendable {
        case userDeclined = -3801, failedToStart = -3802, missingEntitlements = -3803, failedApplicationConnectionInvalid = -3804
        case failedApplicationConnectionInterrupted = -3805, failedNoMatchingApplicationContext = -3806, attemptToStartStreamState = -3807
        case attemptToStopStreamState = -3808, attemptToUpdateFilterState = -3809, attemptToConfigStreamState = -3810, internalError = -3811
        case invalidParameter = -3812, noWindowList = -3813, noDisplayList = -3814, noCaptureSource = -3815, removingStream = -3816
        case userStopped = -3817, failedToStartAudioCapture = -3818, failedToStopAudioCapture = -3819, failedToStartMicrophoneCapture = -3820
        case systemStoppedStream = -3821
    }
    public let _nsError: NSError
    public init(_nsError: NSError) { self._nsError = _nsError }
    public init(_ code: Code, _ message: String) {
        _nsError = NSError(domain: SCStreamErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }
    public static var errorDomain: String { SCStreamErrorDomain }
    public var errorCode: Int { _nsError.code }
    public var errorUserInfo: [String: Any] { _nsError.userInfo }
    public var code: Code { Code(rawValue: _nsError.code) ?? .internalError }
    public static func == (a: SCStreamError, b: SCStreamError) -> Bool { a.errorCode == b.errorCode }
    public func hash(into h: inout Hasher) { h.combine(errorCode) }
}

// MARK: Shareable content

public final class SCRunningApplication: NSObject, @unchecked Sendable {
    public let bundleIdentifier: String
    public let applicationName: String
    public let processID: pid_t
    init(bundleIdentifier: String, applicationName: String, processID: pid_t) {
        self.bundleIdentifier = bundleIdentifier; self.applicationName = applicationName; self.processID = processID
        super.init()
    }
}

public final class SCWindow: NSObject, @unchecked Sendable {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let title: String?
    public let windowLayer: Int
    public let owningApplication: SCRunningApplication?
    public let isOnScreen: Bool
    public let isActive: Bool
    init(windowID: CGWindowID, frame: CGRect, title: String?, owningApplication: SCRunningApplication?) {
        self.windowID = windowID; self.frame = frame; self.title = title; windowLayer = 0
        self.owningApplication = owningApplication; isOnScreen = true; isActive = false
        super.init()
    }
}

public final class SCDisplay: NSObject, @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    /// Points.
    public let width: Int
    public let height: Int
    /// Global points, top-left origin.
    public let frame: CGRect
    let pixelWidth: Int, pixelHeight: Int
    init(_ d: CGDisplayInfo) {
        displayID = d.id
        width = Int(d.bounds.width)
        height = Int(d.bounds.height)
        frame = d.bounds
        pixelWidth = d.pixelWidth
        pixelHeight = d.pixelHeight
        super.init()
    }
}

/// GDK's monitors (main thread only), cached for other threads.
enum Monitors {
    nonisolated(unsafe) static var cache: [CGDisplayInfo] = []
    static let lock = NSLock()

    static func read() -> [CGDisplayInfo] {
        #if os(Linux)
        guard Thread.isMainThread, let display = gdk_display_get_default(), let list = gdk_display_get_monitors(display) else { return cached }
        var out: [CGDisplayInfo] = []
        let n = g_list_model_get_n_items(list)
        for i in 0..<n {
            guard let item = g_list_model_get_item(list, i) else { continue }
            let mon = OpaquePointer(item)
            var r = GdkRectangle()
            gdk_monitor_get_geometry(mon, &r)
            let scale = Int(gdk_monitor_get_scale_factor(mon))
            let name = gdk_monitor_get_model(mon).map { String(cString: $0) } ?? gdk_monitor_get_connector(mon).map { String(cString: $0) } ?? "Display"
            out.append(CGDisplayInfo(id: CGDirectDisplayID(i + 1), bounds: CGRect(x: Int(r.x), y: Int(r.y), width: Int(r.width), height: Int(r.height)),
                                     pixelWidth: Int(r.width) * scale, pixelHeight: Int(r.height) * scale,
                                     refreshRate: Double(gdk_monitor_get_refresh_rate(mon)) / 1000, name: name, isMain: i == 0))
            g_object_unref(item)
        }
        lock.lock(); cache = out; lock.unlock()
        return out
        #else
        return cached
        #endif
    }
    static var cached: [CGDisplayInfo] { lock.lock(); defer { lock.unlock() }; return cache }

    static func install() {
        CGDisplayServices.installIfAbsent { Monitors.read() }
    }
}

public final class SCShareableContent: NSObject, @unchecked Sendable {
    public let displays: [SCDisplay]
    public let windows: [SCWindow]
    public let applications: [SCRunningApplication]

    init(displays: [SCDisplay]) {
        self.displays = displays
        windows = []
        applications = []
        super.init()
    }

    static func make() async -> SCShareableContent {
        Monitors.install()
        let infos = await MainActor.run { CGDisplayServices.displays }
        return SCShareableContent(displays: infos.map(SCDisplay.init))
    }

    public class func excludingDesktopWindows(_ excludeDesktopWindows: Bool, onScreenWindowsOnly: Bool) async throws -> SCShareableContent { await make() }
    public class var current: SCShareableContent { get async throws { await make() } }
    public class func excludingDesktopWindows(_ excludeDesktopWindows: Bool, onScreenWindowsOnlyBelow window: SCWindow) async throws -> SCShareableContent { await make() }
    public class func excludingDesktopWindows(_ excludeDesktopWindows: Bool, onScreenWindowsOnlyAbove window: SCWindow) async throws -> SCShareableContent { await make() }
    public class func getExcludingDesktopWindows(_ excludeDesktopWindows: Bool, onScreenWindowsOnly: Bool,
                                                 completionHandler: @escaping @Sendable (SCShareableContent?, Error?) -> Void) {
        Task { completionHandler(await make(), nil) }
    }
    public class func getWithCompletionHandler(_ completionHandler: @escaping @Sendable (SCShareableContent?, Error?) -> Void) {
        Task { completionHandler(await make(), nil) }
    }
    public class func info(for filter: SCContentFilter) -> SCShareableContentInfo { SCShareableContentInfo(filter) }
}

public final class SCShareableContentInfo: NSObject, @unchecked Sendable {
    public let style: SCShareableContentStyle
    public let pointPixelScale: Float
    public let contentRect: CGRect
    init(_ f: SCContentFilter) { style = f.style; pointPixelScale = f.pointPixelScale; contentRect = f.contentRect; super.init() }
}

public enum SCShareableContentStyle: Int, Sendable { case none = 0, window, display, application }

public final class SCContentFilter: NSObject, @unchecked Sendable {
    public let style: SCShareableContentStyle
    public let includedDisplays: [SCDisplay]
    public let includedWindows: [SCWindow]
    public let includedApplications: [SCRunningApplication]
    public var includeMenuBar = true
    public var streamType: SCStreamType { style == .window ? .window : .display }

    public init(desktopIndependentWindow window: SCWindow) {
        style = .window; includedDisplays = []; includedWindows = [window]; includedApplications = []
        super.init()
    }
    public init(display: SCDisplay, excludingWindows: [SCWindow]) {
        style = .display; includedDisplays = [display]; includedWindows = []; includedApplications = []
        super.init()
    }
    public init(display: SCDisplay, including: [SCWindow]) {
        style = .window; includedDisplays = [display]; includedWindows = including; includedApplications = []
        super.init()
    }
    public init(display: SCDisplay, including applications: [SCRunningApplication], exceptingWindows: [SCWindow]) {
        style = .application; includedDisplays = [display]; includedWindows = []; includedApplications = applications
        super.init()
    }
    public init(display: SCDisplay, excludingApplications applications: [SCRunningApplication], exceptingWindows: [SCWindow]) {
        style = .display; includedDisplays = [display]; includedWindows = []; includedApplications = []
        super.init()
    }

    /// Pixels per point of the captured content.
    public var pointPixelScale: Float {
        if let d = includedDisplays.first, d.width > 0 { return Float(d.pixelWidth) / Float(d.width) }
        return 1
    }
    /// The content's rectangle in points (its own space).
    public var contentRect: CGRect {
        if style == .window, let w = includedWindows.first { return CGRect(origin: .zero, size: w.frame.size) }
        if let d = includedDisplays.first { return CGRect(x: 0, y: 0, width: d.width, height: d.height) }
        return .zero
    }
}

public enum SCStreamType: Int, Sendable { case window = 0, display }

// MARK: Streams

public enum SCStreamOutputType: Int, Sendable { case screen = 0, audio, microphone }

public enum SCFrameStatus: Int, Sendable { case complete = 0, idle, blank, suspended, started, stopped }

public struct SCStreamFrameInfo: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let status = Self(rawValue: "SCStreamUpdateFrameStatus"), displayTime = Self(rawValue: "SCStreamUpdateFrameDisplayTime")
    public static let scaleFactor = Self(rawValue: "SCStreamUpdateFrameScaleFactor"), contentScale = Self(rawValue: "SCStreamUpdateFrameContentScale")
    public static let contentRect = Self(rawValue: "SCStreamUpdateFrameContentRect"), dirtyRects = Self(rawValue: "SCStreamUpdateFrameDirtyRects")
    public static let screenRect = Self(rawValue: "SCStreamUpdateFrameScreenRect"), boundingRect = Self(rawValue: "SCStreamUpdateFrameBoundingRect")
    public static let presenterOverlayContentRect = Self(rawValue: "SCStreamUpdateFramePresenterOverlayContentRect")
}

public final class SCStreamConfiguration: NSObject, @unchecked Sendable {
    public var width = 1920
    public var height = 1080
    public var minimumFrameInterval = CMTime(value: 1, timescale: 60)
    public var pixelFormat: OSType = kCVPixelFormatType_32BGRA
    public var scalesToFit = true
    public var preservesAspectRatio = true
    public var sourceRect: CGRect = .null
    public var destinationRect: CGRect = .null
    public var queueDepth = 3
    public var colorMatrix: CFString = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
    public var colorSpaceName: CFString = CGColorSpace.sRGB
    public var backgroundColor: CGColor = .black
    public var showsCursor = true
    public var showMouseClicks = false
    public var capturesAudio = false
    public var sampleRate = 48000
    public var channelCount = 2
    public var excludesCurrentProcessAudio = false
    public var captureMicrophone = false
    public var microphoneCaptureDeviceID: String?
    public var ignoreShadowsSingleWindow = true
    public var ignoreShadowsDisplay = false
    public var ignoreGlobalClipDisplay = false
    public var ignoreGlobalClipSingleWindow = false
    public var shouldBeOpaque = false
    public var capturesShadowsOnly = false
    public var includeChildWindows = true
    public var presenterOverlayPrivacyAlertSetting = 0
    public var streamName: String?
    public override init() { super.init() }
}

public protocol SCStreamOutput: NSObjectProtocol {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
}
extension SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}
public protocol SCStreamDelegate: NSObjectProtocol {
    func stream(_ stream: SCStream, didStopWithError error: Error)
    func outputVideoEffectDidStart(for stream: SCStream)
    func outputVideoEffectDidStop(for stream: SCStream)
}
extension SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {}
    public func outputVideoEffectDidStart(for stream: SCStream) {}
    public func outputVideoEffectDidStop(for stream: SCStream) {}
}

public final class SCStream: NSObject, @unchecked Sendable {
    private var filter: SCContentFilter
    private var configuration: SCStreamConfiguration
    private weak var delegate: SCStreamDelegate?
    private var outputs: [(SCStreamOutput, SCStreamOutputType, DispatchQueue)] = []
    private var pipelines: [(GstPipeline, SCStreamOutputType)] = []
    private var threads: [Thread] = []
    private var running = false
    private let lock = NSLock()

    public init(filter: SCContentFilter, configuration: SCStreamConfiguration, delegate: SCStreamDelegate?) {
        self.filter = filter
        self.configuration = configuration
        self.delegate = delegate
        super.init()
    }

    public func addStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue?) throws {
        lock.lock(); defer { lock.unlock() }
        outputs.append((output, type, sampleHandlerQueue ?? DispatchQueue(label: "SCStream.output")))
    }
    public func removeStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType) throws {
        lock.lock(); defer { lock.unlock() }
        outputs.removeAll { $0.0 === output && $0.1 == type }
    }
    public func updateConfiguration(_ c: SCStreamConfiguration) async throws { configuration = c }
    public func updateContentFilter(_ f: SCContentFilter) async throws { filter = f }
    public func updateConfiguration(_ c: SCStreamConfiguration, completionHandler: (@Sendable (Error?) -> Void)?) { configuration = c; completionHandler?(nil) }
    public func updateContentFilter(_ f: SCContentFilter, completionHandler: (@Sendable (Error?) -> Void)?) { filter = f; completionHandler?(nil) }

    /// Where display capture can come from on this session.
    static var x11: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["DISPLAY"].map { !$0.isEmpty } == true && env["WAYLAND_DISPLAY"].map { !$0.isEmpty } != true && Gst.has("ximagesrc")
    }

    public func startCapture() async throws {
        if lock.withLock({ running }) { throw SCStreamError(.attemptToStartStreamState, "The stream is already running.") }
        guard Gst.available else { throw SCStreamError(.failedToStart, "Screen capture needs GStreamer, which isn't available here.") }
        guard filter.style == .display, let display = filter.includedDisplays.first else {
            throw SCStreamError(.noCaptureSource, "Only whole displays can be captured on Linux (windows aren't listed to apps).")
        }
        guard Self.x11 else {
            throw SCStreamError(.failedToStart, "Screen capture on Wayland needs the desktop's ScreenCast portal and PipeWire, which Runway doesn't use yet. On an X11 session displays can be captured.")
        }
        let c = configuration
        let fps = c.minimumFrameInterval.isNumeric && c.minimumFrameInterval.seconds > 0 ? max(1, Int((1 / c.minimumFrameInterval.seconds).rounded())) : 60
        let f = display.frame
        let fmt = c.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || c.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? "NV12" : "BGRA"
        let scale = Double(display.pixelWidth) / Double(max(display.width, 1))
        let x0 = Int(f.minX * scale), y0 = Int(f.minY * scale)
        let video = "ximagesrc startx=\(x0) starty=\(y0) endx=\(x0 + display.pixelWidth - 1) endy=\(y0 + display.pixelHeight - 1) use-damage=false show-pointer=\(c.showsCursor) ! video/x-raw,framerate=\(fps)/1 ! videoconvert ! videoscale ! video/x-raw,format=\(fmt),width=\(c.width),height=\(c.height) ! appsink name=sink sync=false max-buffers=\(max(c.queueDepth, 1)) drop=true"
        var started: [(GstPipeline, SCStreamOutputType)] = []
        do {
            let p = try GstPipeline(video)
            guard p.state(.playing, timeout: 5) else { throw SCStreamError(.failedToStart, p.lastError ?? "The display couldn't be captured.") }
            started.append((p, .screen))
        }
        if c.capturesAudio, Gst.has("pulsesrc") {
            let audio = "pulsesrc device=@DEFAULT_MONITOR@ ! audioconvert ! audioresample ! audio/x-raw,format=F32LE,layout=interleaved,rate=\(c.sampleRate),channels=\(c.channelCount) ! appsink name=sink sync=false max-buffers=16"
            if let p = try? GstPipeline(audio), p.state(.playing, timeout: 5) { started.append((p, .audio)) }
        }
        lock.withLock {
            running = true
            pipelines = started
        }
        for (p, type) in started {
            let t = Thread { [weak self] in self?.pump(p, type) }
            t.name = "SCStream \(type)"
            threads.append(t)
            t.start()
        }
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func pump(_ p: GstPipeline, _ type: SCStreamOutputType) {
        let c = configuration
        while isRunning {
            switch p.pull("sink", timeout: 0.5) {
            case .sample(var f):
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                var sb: CMSampleBuffer?
                if type == .audio, let data = f.data {
                    let frames = Int(f.size) / (4 * c.channelCount)
                    sb = CMSampleBuffer(pcm: Data(bytes: data, count: Int(f.size)), format: .pcm(rate: Double(c.sampleRate), channels: c.channelCount, bits: 32, float: true),
                                        presentationTimeStamp: now - CMTime(value: Int64(frames), timescale: Int32(c.sampleRate)))
                } else if let pb = pixelBuffer(from: f) {
                    let s = CMSampleBuffer(imageBuffer: pb, timing: CMSampleTimingInfo(duration: c.minimumFrameInterval, presentationTimeStamp: now, decodeTimeStamp: .invalid))
                    s.setSampleAttachments([[SCStreamFrameInfo.status: SCFrameStatus.complete.rawValue, SCStreamFrameInfo.displayTime: now.value,
                                             SCStreamFrameInfo.scaleFactor: 1.0, SCStreamFrameInfo.contentScale: 1.0,
                                             SCStreamFrameInfo.contentRect: CGRect(x: 0, y: 0, width: c.width, height: c.height)] as [AnyHashable: Any]])
                    sb = s
                }
                rg_frame_release(&f)
                guard let sb else { continue }
                lock.lock()
                let targets = outputs.filter { $0.1 == type }
                lock.unlock()
                for (o, t, q) in targets {
                    let box = Box((o, sb))
                    q.async { box.value.0.stream(self, didOutputSampleBuffer: box.value.1, of: t) }
                }
            case .timeout: continue
            case .eos, .error:
                let e = SCStreamError(.systemStoppedStream, p.lastError ?? "Capture stopped.")
                lock.lock(); running = false; lock.unlock()
                delegate?.stream(self, didStopWithError: e)
                return
            }
        }
    }

    public func stopCapture() async throws {
        let ps: [(GstPipeline, SCStreamOutputType)]? = lock.withLock {
            guard running else { return nil }
            running = false
            let ps = pipelines
            pipelines = []
            threads = []
            return ps
        }
        guard let ps else { throw SCStreamError(.attemptToStopStreamState, "The stream isn't running.") }
        for (p, _) in ps { p.state(.null) }
    }

    public func startCapture(completionHandler: (@Sendable (Error?) -> Void)?) {
        Task { do { try await startCapture(); completionHandler?(nil) } catch { completionHandler?(error) } }
    }
    public func stopCapture(completionHandler: (@Sendable (Error?) -> Void)?) {
        Task { do { try await stopCapture(); completionHandler?(nil) } catch { completionHandler?(error) } }
    }
}

struct Box<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

// MARK: Picker

public struct SCContentSharingPickerMode: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let singleWindow = Self(rawValue: 1), multipleWindows = Self(rawValue: 2), singleApplication = Self(rawValue: 4)
    public static let multipleApplications = Self(rawValue: 8), singleDisplay = Self(rawValue: 16)
}

public struct SCContentSharingPickerConfiguration: Sendable {
    public var allowedPickerModes: SCContentSharingPickerMode = [.singleWindow, .multipleWindows, .singleApplication, .multipleApplications, .singleDisplay]
    public var excludedWindowIDs: [Int] = []
    public var excludedBundleIDs: [String] = []
    public var allowsChangingSelectedContent = true
    public init() {}
}

public protocol SCContentSharingPickerObserver: NSObjectProtocol {
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?)
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?)
    func contentSharingPickerStartDidFailWithError(_ error: any Error)
}

public final class SCContentSharingPicker: NSObject, @unchecked Sendable {
    nonisolated(unsafe) public static let shared = SCContentSharingPicker()
    public var defaultConfiguration = SCContentSharingPickerConfiguration()
    public var maximumStreamCount: Int?
    public var isActive = false
    private var observers: [SCContentSharingPickerObserver] = []
    private override init() { super.init() }

    public func add(_ observer: SCContentSharingPickerObserver) { observers.append(observer) }
    public func remove(_ observer: SCContentSharingPickerObserver) { observers.removeAll { $0 === observer } }
    public func setConfiguration(_ c: SCContentSharingPickerConfiguration?, for stream: SCStream) {}

    /// No system picker here: observers hear that it couldn't start.
    public func present() {
        let e = SCStreamError(.failedToStart, "There's no system content picker on this platform.")
        for o in observers { o.contentSharingPickerStartDidFailWithError(e) }
    }
    public func present(using contentStyle: SCShareableContentStyle) { present() }
    public func present(for stream: SCStream) { present() }
    public func present(for stream: SCStream, using contentStyle: SCShareableContentStyle) { present() }
}

// MARK: Screenshots

public final class SCScreenshotManager: NSObject, @unchecked Sendable {
    public class func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        throw SCStreamError(.failedToStart, "Screenshots need the desktop's Screenshot portal, which Runway doesn't use yet.")
    }
    public class func captureSampleBuffer(contentFilter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CMSampleBuffer {
        throw SCStreamError(.failedToStart, "Screenshots need the desktop's Screenshot portal, which Runway doesn't use yet.")
    }
}
