// AVKit for Linux and Windows: AVPlayerView as an NSView that owns an
// AVPlayerLayer for its player. The picture reaches the screen once
// Runway's AppKit hosts layer trees (the layer's `contents` are kept
// current while the player plays; see QuartzCore's CALayer.onInvalidate);
// until then the view lays out and the player plays (sound) as usual.

@_exported import AppKit
@_exported import AVFoundation
@_exported import Foundation

@preconcurrency @MainActor
open class AVPlayerView: NSView {
    public enum ControlsStyle: Int, Sendable { case none = 0, inline, floating, minimal, `default` }
    public enum TrimResult: Int, Sendable { case okButton = 0, cancelButton }

    /// The layer that shows the player's picture.
    public let playerLayer = AVPlayerLayer()
    open var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }
    open var controlsStyle: ControlsStyle = .default
    open var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }
    open var showsFullScreenToggleButton = false
    open var showsFrameSteppingButtons = false
    open var showsSharingServiceButton = false
    open var showsTimecodes = false
    open var allowsPictureInPicturePlayback = false
    open var allowsVideoFrameAnalysis = false
    open var updatesNowPlayingInfoCenter = true
    open var isReadyForDisplay: Bool { playerLayer.isReadyForDisplay }
    open var videoBounds: CGRect { playerLayer.videoRect }
    open var canBeginTrimming: Bool { false }
    open weak var delegate: AVPlayerViewDelegate?
    open var pictureInPictureDelegate: AnyObject?

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
    }
    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }

    open func beginTrimming(completionHandler handler: ((TrimResult) -> Void)? = nil) { handler?(.cancelButton) }
    open func flashChapterNumber(_ chapterNumber: Int, chapterTitle: String) {}
}

@preconcurrency @MainActor
public protocol AVPlayerViewDelegate: AnyObject {}
@preconcurrency @MainActor
public protocol AVPlayerViewPictureInPictureDelegate: AnyObject {}

/// AirPlay route picking: no routes here.
@preconcurrency @MainActor
open class AVRoutePickerView: NSView {
    open var isRoutePickerButtonBordered = true
    public override init(frame frameRect: CGRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }
}

/// Camera previews in a view (frames come from the session's preview layer).
@preconcurrency @MainActor
open class AVCaptureView: NSView {
    open var session: AVCaptureSession?
    open var controlsStyle: AVPlayerView.ControlsStyle = .default
    open var videoGravity: AVLayerVideoGravity = .resizeAspect
    public override init(frame frameRect: CGRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }
    open func setSession(_ session: AVCaptureSession?, showVideoPreview: Bool, showAudioPreview: Bool) { self.session = session }
}
