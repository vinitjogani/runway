// Window chrome on Linux and Windows: where the Mac's titlebar and toolbar
// go, and what they leave the content.
//
// A titled window has the backend's titlebar row (window buttons at the
// leading edge, then the menu bar, which the Mac keeps at the top of the
// screen, and the title, centred) above its content, never over it. A
// visible toolbar adds a band below that row, as tall as the Mac's toolbar
// style makes it; the band shows the title and the items, split at the
// sidebar and inspector tracking separators as on the Mac. With
// `.fullSizeContentView` the content runs under the band (its views get
// the band as their safe area's top inset, `contentLayoutRect` leaves it
// out, and clicks on the band's empty parts reach the content or drag the
// window); otherwise the band sits above the content, on the titlebar's
// material.

import Foundation
import CoreGraphics
import RunwayCore

extension NSWindow {
    /// The toolbar band's height: what the Mac's toolbar style gives its
    /// titlebar, less the titlebar row the backend already shows.
    var toolbarBandHeight: CGFloat {
        guard styleMask.contains(.titled), let t = toolbar, t.isVisible else { return 0 }
        switch toolbarStyle {
        case .unifiedCompact: return 38
        case .expanded, .preference: return 52
        default: return 46
        }
    }

    /// The toolbar band above content that isn't full-size.
    var chromeAbove: CGFloat { styleMask.contains(.fullSizeContentView) ? 0 : toolbarBandHeight }

    /// How much of full-size content the toolbar band covers: the content
    /// view's safe-area top inset.
    var titlebarInset: CGFloat { styleMask.contains(.fullSizeContentView) ? toolbarBandHeight : 0 }

    /// The native window's content: the content view and a band above it.
    var canvasSize: CGSize {
        let s = contentSize
        return CGSize(width: s.width, height: s.height + chromeAbove)
    }

    /// The toolbar's band, once the toolbar is in the window.
    var shownToolbarStrip: ToolbarStrip? {
        guard toolbarBandHeight > 0, let s = toolbar?.strip else { return nil }
        return s
    }

    /// The band's place in window coordinates (y up): over the top of
    /// full-size content, else above it.
    var toolbarBandRect: CGRect {
        let s = contentSize, band = toolbarBandHeight
        let full = styleMask.contains(.fullSizeContentView)
        return CGRect(x: 0, y: full ? s.height - band : s.height, width: s.width, height: band)
    }

    /// The toolbar, title or style changed what the titlebar holds.
    func chromeDidChange() {
        updateTitlebarTitle()
        if let v = contentView {
            let s = contentSize
            if v.frame.size != s { v.frame = CGRect(origin: .zero, size: s) }
        }
        attachContent()
        contentView?.safeAreaMayHaveChanged()
        contentView?.needsLayout = true
    }

    /// The titlebar row shows the title unless it's hidden or the toolbar
    /// shows it.
    func updateTitlebarTitle() {
        guard let n = nativeWindow else { return }
        Runway.appKit?.setTitlebarShowsTitle(n, titleVisibility == .visible && toolbarBandHeight == 0)
        Runway.appKit?.setContentUnderToolbarBand(n, styleMask.contains(.fullSizeContentView))
        Runway.appKit?.setToolbarBand(n, height: toolbarBandHeight)
    }

    /// The window buttons as views where the backend draws them (AppKit
    /// apps measure against them, e.g. to start a bar after them). Nil
    /// while they're in a titlebar row above the content, which views
    /// can't reach.
    func windowButtonView(_ b: ButtonType) -> NSView? {
        guard let n = nativeWindow, let frames = Runway.appKit?.windowButtonFrames(n), frames.count == 3 else { return nil }
        let index: Int
        switch b {
        case .closeButton: index = 0
        case .miniaturizeButton: index = 1
        case .zoomButton: index = 2
        default: return nil
        }
        let s = contentSize
        let top = s.height + chromeAbove
        let host = windowButtonHost ?? {
            let h = NSView(frame: .zero)
            windowButtonHost = h
            for _ in 0..<3 { h.addSubview(NSButton(frame: .zero)) }
            return h
        }()
        // The host spans the content in window coordinates (y up); the
        // buttons sit in it where the canvas has them.
        host.frame = CGRect(x: 0, y: 0, width: s.width, height: top)
        for (i, f) in frames.enumerated() {
            host.subviews[i].frame = CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)
        }
        return host.subviews[index]
    }

    /// Places the band's view where the band is.
    func placeToolbarStrip() {
        guard let strip = shownToolbarStrip else { return }
        let r = toolbarBandRect
        let floats = styleMask.contains(.fullSizeContentView)
        if strip.floatsOverContent != floats { strip.floatsOverContent = floats }
        if strip.window !== self { strip.setWindowRecursively(self) }
        if strip.frame != r { strip.frame = r } else { strip.relayout() }
    }

    /// A toolbar item (or a view in one) under `p`, in window coordinates.
    func toolbarHit(_ p: CGPoint) -> NSView? {
        guard let strip = shownToolbarStrip, let hit = strip.hitTest(p), hit !== strip else { return nil }
        return hit
    }

    /// A press on the band that isn't on an item, or on full-size content
    /// in the band that lets the window move (not a control, and nothing
    /// that says `mouseDownCanMoveWindow` is false): it drags the window,
    /// and a double click zooms it, as the Mac's titlebar does.
    func titlebarMouseDown(_ e: NSEvent) -> Bool {
        guard toolbarBandHeight > 0 else { return false }
        let p = e.locationInWindow
        guard toolbarBandRect.contains(p), toolbarHit(p) == nil else { return false }
        if styleMask.contains(.fullSizeContentView), let hit = contentView?.hitTest(p) {
            var v: NSView? = hit
            while let cur = v {
                if cur is NSControl || !cur.mouseDownCanMoveWindow { return false }
                v = cur.superview
            }
        }
        if e.clickCount == 2 { performZoom(nil) } else { performDrag(with: e) }
        return true
    }
}
