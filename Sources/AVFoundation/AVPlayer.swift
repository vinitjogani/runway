// Playback: AVPlayer, AVPlayerItem, AVQueuePlayer, AVPlayerLooper,
// AVPlayerLayer, AVPlayerItemVideoOutput and AVAudioPlayer.
//
// A player keeps its own clock (time = anchor + elapsed × rate); pictures come
// from FrameComposer at the clock's time (so compositions and custom
// compositors play exactly as they export), and sound from a GStreamer
// playbin (audio only) for file items. While playing — and only then — a GLib
// timeout on the main loop advances observers, layers and end-of-item.

import CRunwayGst
import CoreMedia
import CoreVideo
import Foundation

// MARK: Main-loop ticks

/// A GLib timeout on the default main context while something plays.
final class MainLoopTicker: @unchecked Sendable {
    private var source: UInt32 = 0
    private let box: Box
    final class Box { weak var owner: AnyObject?; let tick: (AnyObject) -> Bool; init(_ t: @escaping (AnyObject) -> Bool) { tick = t } }

    init(owner: AnyObject, tick: @escaping (AnyObject) -> Bool) {
        box = Box(tick)
        box.owner = owner
    }
    deinit { stop() }

    var running: Bool { source != 0 }

    func start(intervalMS: UInt32) {
        guard source == 0 else { return }
        let ctx = Unmanaged.passRetained(box).toOpaque()
        source = rg_timeout_add(max(intervalMS, 10), { raw in
            guard let raw else { return 0 }
            let b = Unmanaged<MainLoopTicker.Box>.fromOpaque(raw).takeUnretainedValue()
            guard let o = b.owner, b.tick(o) else {
                Unmanaged<MainLoopTicker.Box>.fromOpaque(raw).release()
                return 0
            }
            return 1
        }, ctx)
        if source == 0 { Unmanaged<Box>.fromOpaque(ctx).release() }
    }

    func stop() {
        guard source != 0 else { return }
        rg_source_remove(source)
        source = 0
        // The trampoline's retain is released when GLib drops the source: the next tick sees no owner.
    }
}

func onMain(_ queue: DispatchQueue?, _ work: @escaping @Sendable () -> Void) {
    if queue == nil || queue === DispatchQueue.main {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    } else {
        queue!.async(execute: work)
    }
}

// MARK: Items

open class AVPlayerItem: NSObject, @unchecked Sendable {
    public enum Status: Int, Sendable { case unknown = 0, readyToPlay, failed }

    public static let didPlayToEndTimeNotification = Notification.Name("AVPlayerItemDidPlayToEndTimeNotification")
    public static let failedToPlayToEndTimeNotification = Notification.Name("AVPlayerItemFailedToPlayToEndTimeNotification")
    public static let timeJumpedNotification = Notification.Name("AVPlayerItemTimeJumpedNotification")
    public static let playbackStalledNotification = Notification.Name("AVPlayerItemPlaybackStalledNotification")
    public static let newAccessLogEntryNotification = Notification.Name("AVPlayerItemNewAccessLogEntryNotification")
    public static let newErrorLogEntryNotification = Notification.Name("AVPlayerItemNewErrorLogEntryNotification")
    public static let mediaSelectionDidChangeNotification = Notification.Name("AVPlayerItemMediaSelectionDidChangeNotification")
    public static let failedToPlayToEndTimeErrorKey = "AVPlayerItemFailedToPlayToEndTimeErrorKey"

    public let asset: AVAsset
    public private(set) var status: Status = .unknown
    public private(set) var error: Error?
    open var videoComposition: AVVideoComposition? { didSet { resetComposer() } }
    open var audioMix: AVAudioMix?
    open var preferredForwardBufferDuration: TimeInterval = 0
    open var forwardPlaybackEndTime: CMTime = .invalid
    open var reversePlaybackEndTime: CMTime = .invalid
    open var canUseNetworkResourcesForLiveStreamingWhilePaused = false
    open var appliesPerFrameHDRDisplayMetadata = true
    open var audioTimePitchAlgorithm: AVAudioTimePitchAlgorithm = .spectral
    open var seekingWaitsForVideoCompositionRendering = false
    open var preferredPeakBitRate: Double = 0
    open var preferredMaximumResolution: CGSize = .zero
    public private(set) var outputs: [AVPlayerItemOutput] = []
    weak var player: AVPlayer?
    var time: CMTime = .zero
    private var composer: FrameComposer?
    private let lock = NSLock()
    private var loadedDuration: CMTime = .indefinite

    public init(asset: AVAsset, automaticallyLoadedAssetKeys: [String]? = nil) {
        self.asset = asset
        super.init()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                _ = try asset.loadedTracks()
                let d = asset.duration
                lock.lock(); loadedDuration = d; status = .readyToPlay; lock.unlock()
                DispatchQueue.main.async { [self] in player?.itemBecameReady(self) }
            } catch {
                lock.lock(); self.error = error; status = .failed; lock.unlock()
                NotificationCenter.default.post(name: AVPlayerItem.failedToPlayToEndTimeNotification, object: self,
                                                userInfo: [AVPlayerItem.failedToPlayToEndTimeErrorKey: error])
            }
        }
    }
    public convenience init(asset: AVAsset) { self.init(asset: asset, automaticallyLoadedAssetKeys: nil) }
    public convenience init(url URL: URL) { self.init(asset: AVURLAsset(url: URL)) }

    open var duration: CMTime { lock.lock(); defer { lock.unlock() }; return status == .readyToPlay ? loadedDuration : .indefinite }
    open var presentationSize: CGSize { frameComposer.renderSize }
    open var tracks: [AVPlayerItemTrack] { asset.allTracks.map(AVPlayerItemTrack.init) }
    open var seekableTimeRanges: [NSValue] { [NSValue(timeRange: CMTimeRange(start: .zero, duration: duration))] }
    open var loadedTimeRanges: [NSValue] { seekableTimeRanges }
    open var isPlaybackLikelyToKeepUp: Bool { status == .readyToPlay }
    open var isPlaybackBufferFull: Bool { status == .readyToPlay }
    open var isPlaybackBufferEmpty: Bool { false }
    open var canPlayFastForward: Bool { true }
    open var canPlayReverse: Bool { false }
    open var canStepForward: Bool { true }
    open var canStepBackward: Bool { true }

    open func currentTime() -> CMTime { player?.currentItem === self ? player!.currentTime() : time }
    open func seek(to time: CMTime, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        if let p = player, p.currentItem === self { p.seek(to: time, completionHandler: completionHandler ?? { _ in }) } else {
            self.time = time
            completionHandler?(true)
        }
    }
    open func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: (@Sendable (Bool) -> Void)? = nil) {
        seek(to: time, completionHandler: completionHandler)
    }
    open func step(byCount stepCount: Int) {
        let fd = frameComposer.frameDuration
        seek(to: currentTime() + CMTimeMultiply(fd, multiplier: Int32(stepCount)))
    }
    open func cancelPendingSeeks() {}

    open func add(_ output: AVPlayerItemOutput) {
        output.item = self
        outputs.append(output)
    }
    open func remove(_ output: AVPlayerItemOutput) { outputs.removeAll { $0 === output } }

    var frameComposer: FrameComposer {
        lock.lock(); defer { lock.unlock() }
        if let c = composer { return c }
        let c = FrameComposer(asset: asset, composition: videoComposition)
        composer = c
        return c
    }
    private func resetComposer() { lock.lock(); composer = nil; lock.unlock() }

    /// The picture at item time `t` (decoded on demand).
    func frame(at t: CMTime) -> CVPixelBuffer? { frameComposer.frame(at: t) }
}

open class AVPlayerItemTrack: NSObject, @unchecked Sendable {
    public let assetTrack: AVAssetTrack?
    open var isEnabled = true
    open var currentVideoFrameRate: Float { assetTrack?.nominalFrameRate ?? 0 }
    init(_ t: AVAssetTrack) { assetTrack = t; super.init() }
}

open class AVPlayerItemOutput: NSObject, @unchecked Sendable {
    weak var item: AVPlayerItem?
    open var suppressesPlayerRendering = false
    open func itemTime(forHostTime hostTimeInSeconds: CFTimeInterval) -> CMTime { item?.currentTime() ?? .invalid }
    open func itemTime(forMachAbsoluteTime machAbsoluteTime: Int64) -> CMTime { item?.currentTime() ?? .invalid }
}

/// Frames of the item at a time, decoded on demand (BGRA unless asked otherwise).
open class AVPlayerItemVideoOutput: AVPlayerItemOutput, @unchecked Sendable {
    public let pixelBufferAttributes: [String: Any]?
    private var lastTime: CMTime = .invalid
    public init(pixelBufferAttributes: [String: Any]?) {
        self.pixelBufferAttributes = pixelBufferAttributes
        super.init()
    }
    public convenience init(outputSettings: [String: Any]?) { self.init(pixelBufferAttributes: outputSettings) }
    open func hasNewPixelBuffer(forItemTime itemTime: CMTime) -> Bool {
        guard let item, item.status == .readyToPlay else { return false }
        return !(lastTime.isNumeric && CMTimeCompare(lastTime, itemTime) == 0)
    }
    open func copyPixelBuffer(forItemTime itemTime: CMTime, itemTimeForDisplay outItemTimeForDisplay: UnsafeMutablePointer<CMTime>?) -> CVPixelBuffer? {
        guard let item, let pb = item.frame(at: itemTime) else { return nil }
        lastTime = itemTime
        outItemTimeForDisplay?.pointee = itemTime
        return pb
    }
    open func requestNotificationOfMediaDataChange(withAdvanceInterval interval: TimeInterval) {}
    open func setDelegate(_ delegate: AnyObject?, queue: DispatchQueue?) {}
}

// MARK: Player

open class AVPlayer: NSObject, @unchecked Sendable {
    public enum Status: Int, Sendable { case unknown = 0, readyToPlay, failed }
    public enum TimeControlStatus: Int, Sendable { case paused = 0, waitingToPlayAtSpecifiedRate, playing }
    public enum ActionAtItemEnd: Int, Sendable { case advance = 0, pause, none }
    public struct WaitingReason: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let toMinimizeStalls = WaitingReason(rawValue: "AVPlayerWaitingToMinimizeStallsReason")
        public static let noItemToPlay = WaitingReason(rawValue: "AVPlayerWaitingWithNoItemToPlayReason")
    }
    public static let rateDidChangeNotification = Notification.Name("AVPlayerRateDidChangeNotification")

    public private(set) var currentItem: AVPlayerItem?
    open var actionAtItemEnd: ActionAtItemEnd = .pause
    open var automaticallyWaitsToMinimizeStalling = true
    open var preventsDisplaySleepDuringVideoPlayback = true
    open var allowsExternalPlayback = false
    open var appliesMediaSelectionCriteriaAutomatically = true
    open var defaultRate: Float = 1
    open var volume: Float = 1 { didSet { if let a = audio { a.set(nil, "volume", double: Double(volume)) } } }
    open var isMuted = false { didSet { if let a = audio { a.set(nil, "mute", bool: isMuted) } } }
    public private(set) var error: Error?
    public private(set) var reasonForWaitingToPlay: WaitingReason?

    private let lock = NSRecursiveLock()
    private var anchorItemTime: CMTime = .zero
    private var anchorHost: Double = 0
    private var _rate: Float = 0
    private var audio: GstPipeline?
    private var audioItem: ObjectIdentifier?
    private var observers: [Observer] = []
    private var ticker: MainLoopTicker!
    private var layers: [WeakLayer] = []
    var loops = false

    final class Observer: @unchecked Sendable {
        let interval: Double?
        let boundaries: [CMTime]
        let queue: DispatchQueue?
        let block: @Sendable (CMTime) -> Void
        let boundaryBlock: (@Sendable () -> Void)?
        var lastFire: Double = -.infinity
        var lastTime: CMTime = .invalid
        init(interval: Double?, boundaries: [CMTime], queue: DispatchQueue?, block: @escaping @Sendable (CMTime) -> Void, boundary: (@Sendable () -> Void)?) {
            self.interval = interval; self.boundaries = boundaries; self.queue = queue; self.block = block; boundaryBlock = boundary
        }
    }
    struct WeakLayer { weak var layer: AVPlayerLayer? }

    public override init() {
        super.init()
        ticker = MainLoopTicker(owner: self) { ($0 as! AVPlayer).tick() }
    }
    public convenience init(url URL: URL) { self.init(playerItem: AVPlayerItem(url: URL)) }
    public convenience init(playerItem item: AVPlayerItem?) {
        self.init()
        replaceCurrentItem(with: item)
    }
    deinit { audio?.state(.null) }

    open var status: Status {
        switch currentItem?.status {
        case .failed: .failed
        case .readyToPlay: .readyToPlay
        default: currentItem == nil ? .unknown : .unknown
        }
    }

    private static var host: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    open func replaceCurrentItem(with item: AVPlayerItem?) {
        lock.lock()
        currentItem?.player = nil
        currentItem = item
        item?.player = self
        anchorItemTime = item?.time ?? .zero
        anchorHost = Self.host
        stopAudio()
        lock.unlock()
        if _rate != 0 { startAudio() }
        refreshLayers()
    }

    open var rate: Float {
        get { lock.lock(); defer { lock.unlock() }; return _rate }
        set { setRate(newValue) }
    }

    open var timeControlStatus: TimeControlStatus { rate != 0 ? (currentItem?.status == .readyToPlay ? .playing : .waitingToPlayAtSpecifiedRate) : .paused }

    open func play() { setRate(defaultRate > 0 ? defaultRate : 1) }
    open func pause() { setRate(0) }
    open func playImmediately(atRate rate: Float) { setRate(rate) }
    open func setRate(_ rate: Float, time itemTime: CMTime, atHostTime hostClockTime: CMTime) {
        if itemTime.isNumeric { seek(to: itemTime) }
        setRate(rate)
    }

    private func setRate(_ r: Float) {
        lock.lock()
        let now = currentTimeLocked()
        anchorItemTime = now
        anchorHost = Self.host
        let changed = r != _rate
        _rate = r
        lock.unlock()
        guard changed else { return }
        if r != 0 {
            startAudio()
            let interval = observers.compactMap(\.interval).min() ?? (1.0 / 30)
            ticker.start(intervalMS: UInt32(max(min(interval, 1.0 / 30), 0.01) * 1000))
        } else {
            ticker.stop()
            audio?.stateAsync(.paused)
        }
        NotificationCenter.default.post(name: Self.rateDidChangeNotification, object: self)
        fireObservers(force: true)
        refreshLayers()
    }

    private func currentTimeLocked() -> CMTime {
        guard let item = currentItem else { return .zero }
        var t = anchorItemTime
        if _rate != 0, item.status == .readyToPlay {
            t = anchorItemTime + CMTime(seconds: (Self.host - anchorHost) * Double(_rate), preferredTimescale: 600_000)
        }
        let d = item.duration
        if d.isNumeric, t > d { t = d }
        if t < .zero { t = .zero }
        return t
    }

    open func currentTime() -> CMTime {
        lock.lock(); defer { lock.unlock() }
        return currentTimeLocked()
    }

    open func seek(to time: CMTime) { seek(to: time) { _ in } }
    open func seek(to time: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) {
        seek(to: time, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity, completionHandler: completionHandler)
    }
    open func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) {
        seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { _ in }
    }
    open func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        let t = time.isNumeric ? CMTimeMaximum(time, .zero) : .zero
        anchorItemTime = t
        anchorHost = Self.host
        currentItem?.time = t
        let a = audio
        lock.unlock()
        a?.seek(t.seconds, accurate: toleranceBefore == .zero)
        if let item = currentItem { NotificationCenter.default.post(name: AVPlayerItem.timeJumpedNotification, object: item) }
        fireObservers(force: true)
        refreshLayers()
        completionHandler(true)
    }
    public func seek(to time: CMTime) async -> Bool {
        await withCheckedContinuation { c in seek(to: time) { c.resume(returning: $0) } }
    }
    public func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool {
        await withCheckedContinuation { c in seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { c.resume(returning: $0) } }
    }
    open func seek(to date: Date) {}
    open func cancelPendingPrerolls() {}
    open func preroll(atRate rate: Float, completionHandler: (@Sendable (Bool) -> Void)?) { completionHandler?(true) }

    // MARK: Observers

    open func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping @Sendable (CMTime) -> Void) -> Any {
        let o = Observer(interval: max(interval.seconds, 0.01), boundaries: [], queue: queue, block: block, boundary: nil)
        lock.lock(); observers.append(o); lock.unlock()
        if _rate != 0, ticker.running, interval.seconds < 1.0 / 30 {
            ticker.stop()
            ticker.start(intervalMS: UInt32(max(interval.seconds, 0.01) * 1000))
        }
        return o
    }
    open func addBoundaryTimeObserver(forTimes times: [NSValue], queue: DispatchQueue?, using block: @escaping @Sendable () -> Void) -> Any {
        let o = Observer(interval: nil, boundaries: times.compactMap(\.timeValue).sorted(), queue: queue, block: { _ in }, boundary: block)
        lock.lock(); observers.append(o); lock.unlock()
        return o
    }
    open func removeTimeObserver(_ observer: Any) {
        guard let o = observer as? Observer else { return }
        lock.lock(); observers.removeAll { $0 === o }; lock.unlock()
    }

    private func fireObservers(force: Bool) {
        lock.lock()
        let t = currentTimeLocked()
        let list = observers
        lock.unlock()
        let now = Self.host
        for o in list {
            if let i = o.interval {
                if force || now - o.lastFire >= i * 0.95 {
                    o.lastFire = now
                    let b = o.block
                    onMain(o.queue) { b(t) }
                }
            } else if let bb = o.boundaryBlock, o.lastTime.isNumeric, !force {
                if o.boundaries.contains(where: { $0 > o.lastTime && $0 <= t }) { onMain(o.queue) { bb() } }
            }
            o.lastTime = t
        }
    }

    /// One main-loop tick while playing: observers, layers, end of item.
    private func tick() -> Bool {
        lock.lock()
        let playing = _rate != 0
        let t = currentTimeLocked()
        let item = currentItem
        lock.unlock()
        guard playing else { return false }
        _ = audio?.poll()
        fireObservers(force: false)
        refreshLayers()
        if let item, item.status == .readyToPlay {
            let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime : item.duration
            if end.isNumeric, t >= end {
                itemEnded(item)
            }
        }
        return _rate != 0
    }

    func itemEnded(_ item: AVPlayerItem) {
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        if loops {
            seek(to: .zero)
            return
        }
        switch actionAtItemEnd {
        case .pause: setRate(0)
        case .advance:
            if let q = self as? AVQueuePlayer { q.advanceToNextItem() } else { setRate(0) }
        case .none: break
        }
    }

    // MARK: Sound (file items)

    private func startAudio() {
        guard !isMuted, let item = currentItem, let url = (item.asset as? AVURLAsset)?.url, item.videoComposition == nil else { return }
        lock.lock()
        if audioItem == ObjectIdentifier(item), let a = audio {
            lock.unlock()
            a.seek(currentTime().seconds, accurate: true)
            a.stateAsync(.playing)
            return
        }
        lock.unlock()
        stopAudio()
        guard Gst.available, let p = try? GstPipeline("playbin name=pb") else { return }
        p.set(nil, "uri", Gst.uri(url))
        p.set(nil, "flags", int: 0x02 | 0x10) // audio + soft volume: pictures come from the composer
        p.set(nil, "volume", double: Double(volume))
        guard p.state(.paused, timeout: 5) else { return }
        p.seek(currentTime().seconds, accurate: true)
        p.stateAsync(.playing)
        lock.lock()
        audio = p
        audioItem = ObjectIdentifier(item)
        lock.unlock()
    }
    private func stopAudio() {
        lock.lock()
        let a = audio
        audio = nil
        audioItem = nil
        lock.unlock()
        a?.state(.null)
    }

    // MARK: Layers

    func attach(_ layer: AVPlayerLayer) {
        layers.removeAll { $0.layer == nil || $0.layer === layer }
        layers.append(WeakLayer(layer: layer))
        refreshLayers()
    }
    func detach(_ layer: AVPlayerLayer) { layers.removeAll { $0.layer == nil || $0.layer === layer } }

    private let render = DispatchQueue(label: "runway.avplayer.render")
    private var rendering = false
    /// A refresh asked for while a frame was in flight: drawn when it lands.
    private var refreshPending = false

    /// Draws the current picture into attached layers. One frame is in
    /// flight at a time; asks made meanwhile (a seek, a style change) are
    /// folded into one more frame at the then-current time when it lands,
    /// so the layer always ends on the latest picture.
    func refreshLayers() {
        let live = layers.compactMap(\.layer)
        guard !live.isEmpty, let item = currentItem, item.status == .readyToPlay else { return }
        lock.lock()
        if rendering { refreshPending = true; lock.unlock(); return }
        rendering = true
        refreshPending = false
        lock.unlock()
        let t = currentTime()
        render.async { [self] in
            let pb = item.frame(at: t)
            let image = pb.map { CGImage(width: $0.width, height: $0.height, rgba: $0.rgba(), hasAlpha: false) }
            let box = UncheckedBox(image)
            onMain(.main) { [self] in
                // Only the item still playing shows its picture.
                if let image = box.value, currentItem === item { for l in live { l.show(image) } }
                lock.lock()
                rendering = false
                let again = refreshPending
                lock.unlock()
                if again { refreshLayers() }
            }
        }
    }

    /// The item finished loading: show its first picture.
    func itemBecameReady(_ item: AVPlayerItem) {
        guard currentItem === item else { return }
        refreshLayers()
        fireObservers(force: true)
    }
}

struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

open class AVQueuePlayer: AVPlayer, @unchecked Sendable {
    private var queue: [AVPlayerItem] = []
    public override init() {
        super.init()
        actionAtItemEnd = .advance
    }
    public convenience init(items: [AVPlayerItem]) {
        self.init()
        queue = items
        replaceCurrentItem(with: items.first)
    }
    open func items() -> [AVPlayerItem] { queue }
    open func advanceToNextItem() {
        if !queue.isEmpty { queue.removeFirst() }
        replaceCurrentItem(with: queue.first)
        if queue.isEmpty { pause() }
    }
    open func canInsert(_ item: AVPlayerItem, after afterItem: AVPlayerItem?) -> Bool { !queue.contains { $0 === item } }
    open func insert(_ item: AVPlayerItem, after afterItem: AVPlayerItem?) {
        if let a = afterItem, let i = queue.firstIndex(where: { $0 === a }) { queue.insert(item, at: i + 1) } else { queue.append(item) }
        if currentItem == nil { replaceCurrentItem(with: queue.first) }
    }
    open func remove(_ item: AVPlayerItem) {
        let wasCurrent = currentItem === item
        queue.removeAll { $0 === item }
        if wasCurrent { replaceCurrentItem(with: queue.first) }
    }
    open func removeAllItems() {
        queue.removeAll()
        replaceCurrentItem(with: nil)
    }
}

/// Plays one item again and again on a queue player.
open class AVPlayerLooper: NSObject, @unchecked Sendable {
    public enum Status: Int, Sendable { case unknown = 0, ready, failed, cancelled }
    public private(set) var status: Status = .unknown
    public private(set) var error: Error?
    public private(set) var loopCount = 0
    public private(set) var loopingPlayerItems: [AVPlayerItem] = []
    private weak var player: AVQueuePlayer?
    private var token: NSObjectProtocol?

    public init(player: AVQueuePlayer, templateItem itemToLoop: AVPlayerItem, timeRange loopRange: CMTimeRange = CMTimeRange(start: .zero, duration: .positiveInfinity)) {
        self.player = player
        super.init()
        player.removeAllItems()
        player.insert(itemToLoop, after: nil)
        loopingPlayerItems = [itemToLoop]
        player.loops = true
        status = .ready
        if loopRange.start.isNumeric, loopRange.start > .zero { player.seek(to: loopRange.start) }
        if loopRange.duration.isNumeric { itemToLoop.forwardPlaybackEndTime = loopRange.end }
        token = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: itemToLoop, queue: nil) { [weak self] _ in
            self?.loopCount += 1
        }
    }
    public convenience init(player: AVQueuePlayer, templateItem itemToLoop: AVPlayerItem) {
        self.init(player: player, templateItem: itemToLoop, timeRange: CMTimeRange(start: .zero, duration: .positiveInfinity))
    }
    deinit {
        player?.loops = false
        if let token { NotificationCenter.default.removeObserver(token) }
    }
    open func disableLooping() {
        player?.loops = false
        status = .cancelled
    }
}

// MARK: Layers

public struct AVLayerVideoGravity: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let resizeAspect = Self(rawValue: "AVLayerVideoGravityResizeAspect")
    public static let resizeAspectFill = Self(rawValue: "AVLayerVideoGravityResizeAspectFill")
    public static let resize = Self(rawValue: "AVLayerVideoGravityResize")
}

/// Shows a player's picture as its contents (a CGImage, refreshed while
/// playing and after seeks), fitted by `videoGravity`.
open class AVPlayerLayer: CALayer, @unchecked Sendable {
    open var player: AVPlayer? {
        didSet {
            oldValue?.detach(self)
            player?.attach(self)
        }
    }
    open var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet {
            contentsGravity = switch videoGravity {
            case .resizeAspectFill: .resizeAspectFill
            case .resize: .resize
            default: .resizeAspect
            }
        }
    }
    public private(set) var isReadyForDisplay = false
    open var pixelBufferAttributes: [String: Any]?

    public override init() {
        super.init()
        contentsGravity = .resizeAspect
    }
    public convenience init(player: AVPlayer?) {
        self.init()
        self.player = player
        player?.attach(self)
    }
    public override init(layer: Any) { super.init(layer: layer) }

    open var videoRect: CGRect {
        guard let image = contentsImage else { return .zero }
        return contentsRect(for: image, in: bounds)
    }

    func show(_ image: CGImage) {
        isReadyForDisplay = true
        contents = image
    }

    open func displayedPixelBuffer() -> CVPixelBuffer? { nil }
}

// MARK: AVAudioPlayer

public protocol AVAudioPlayerDelegate: AnyObject {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool)
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?)
}
extension AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {}
    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {}
}

/// Plays a sound file through GStreamer's playbin.
open class AVAudioPlayer: NSObject, @unchecked Sendable {
    public let url: URL?
    public let data: Data?
    open weak var delegate: AVAudioPlayerDelegate?
    open var numberOfLoops = 0
    open var volume: Float = 1 { didSet { pipeline?.set(nil, "volume", double: Double(volume)) } }
    open var pan: Float = 0
    open var enableRate = false
    open var rate: Float = 1
    open var isMeteringEnabled = false
    public let duration: TimeInterval
    public private(set) var isPlaying = false
    private var pipeline: GstPipeline?
    private var ticker: MainLoopTicker!
    private var loopsLeft = 0
    private var tempFile: URL?

    public init(contentsOf url: URL) throws {
        let info = try MediaInfo.read(url).get()
        guard info.audioCount > 0 else { throw NSError(domain: NSOSStatusErrorDomain, code: 1_954_115_647, userInfo: [NSLocalizedDescriptionKey: "The file has no sound."]) }
        self.url = url
        data = nil
        duration = info.duration
        super.init()
        ticker = MainLoopTicker(owner: self) { ($0 as! AVAudioPlayer).tick() }
    }
    public convenience init(contentsOf url: URL, fileTypeHint utiString: String?) throws { try self.init(contentsOf: url) }
    public convenience init(data: Data) throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("runway-audio-\(UUID().uuidString)")
        try data.write(to: tmp)
        try self.init(contentsOf: tmp)
        tempFile = tmp
    }
    public convenience init(data: Data, fileTypeHint utiString: String?) throws { try self.init(data: data) }
    deinit {
        pipeline?.state(.null)
        if let tempFile { try? FileManager.default.removeItem(at: tempFile) }
    }

    @discardableResult
    open func prepareToPlay() -> Bool {
        if pipeline != nil { return true }
        guard let url, let p = try? GstPipeline("playbin name=pb") else { return false }
        p.set(nil, "uri", Gst.uri(url))
        p.set(nil, "flags", int: 0x02 | 0x10)
        p.set(nil, "volume", double: Double(volume))
        guard p.state(.paused, timeout: 5) else { return false }
        pipeline = p
        return true
    }
    @discardableResult
    open func play() -> Bool {
        guard prepareToPlay(), let p = pipeline else { return false }
        if !isPlaying { loopsLeft = numberOfLoops }
        p.stateAsync(.playing)
        isPlaying = true
        ticker.start(intervalMS: 50)
        return true
    }
    @discardableResult
    open func play(atTime time: TimeInterval) -> Bool { play() }
    open func pause() {
        pipeline?.stateAsync(.paused)
        isPlaying = false
        ticker.stop()
    }
    open func stop() {
        pause()
        pipeline?.seek(0)
    }
    open var currentTime: TimeInterval {
        get { pipeline?.position ?? 0 }
        set { pipeline?.seek(newValue) }
    }
    open var deviceCurrentTime: TimeInterval { CACurrentMediaTime() }
    open var numberOfChannels: Int { (url.flatMap { try? MediaInfo.read($0).get() })?.channels ?? 0 }
    open func updateMeters() {}
    open func averagePower(forChannel channelNumber: Int) -> Float { -160 }
    open func peakPower(forChannel channelNumber: Int) -> Float { -160 }
    open func setVolume(_ volume: Float, fadeDuration duration: TimeInterval) { self.volume = volume }

    private func tick() -> Bool {
        guard isPlaying, let p = pipeline else { return false }
        let bus = p.poll()
        if bus.contains(.error) {
            isPlaying = false
            delegate?.audioPlayerDecodeErrorDidOccur(self, error: avError(.decodeFailed, p.lastError ?? "Playback failed."))
            return false
        }
        if bus.contains(.eos) {
            if loopsLeft != 0 {
                if loopsLeft > 0 { loopsLeft -= 1 }
                p.seek(0)
                return true
            }
            isPlaying = false
            p.stateAsync(.paused)
            p.seek(0)
            delegate?.audioPlayerDidFinishPlaying(self, successfully: true)
            return false
        }
        return true
    }
}
