// NSVisualEffectView: the Mac's blurred materials, drawn as the material's
// translucent tint (no blur behind windows here), following the view's
// appearance.

import Foundation

@preconcurrency @MainActor
open class NSVisualEffectView: NSView {
    public enum Material: Int, Sendable {
        case appearanceBased = 0, light = 1, dark = 2, titlebar = 3, selection = 4, menu = 5, popover = 6, sidebar = 7
        case mediumLight = 8, ultraDark = 9, headerView = 10, sheet = 11, windowBackground = 12, hudWindow = 13
        case fullScreenUI = 15, toolTip = 17, contentBackground = 18, underWindowBackground = 21, underPageBackground = 22
    }
    public enum BlendingMode: Int, Sendable { case behindWindow, withinWindow }
    public enum State: Int, Sendable { case followsWindowActiveState, active, inactive }

    open var material: Material = .appearanceBased { didSet { needsDisplay = true } }
    open var blendingMode: BlendingMode = .behindWindow { didSet { needsDisplay = true } }
    open var state: State = .followsWindowActiveState
    open var isEmphasized = false { didSet { needsDisplay = true } }
    open var maskImage: NSImage? { didSet { needsDisplay = true } }
    open var interiorBackgroundStyle: Int { 0 }

    /// The tint (white level, alpha) for light and dark.
    private var tint: (light: (CGFloat, CGFloat), dark: (CGFloat, CGFloat)) {
        switch material {
        case .sidebar, .underWindowBackground: ((0.93, 0.82), (0.17, 0.82))
        case .titlebar, .headerView: ((0.96, 0.9), (0.2, 0.9))
        case .menu, .popover, .toolTip: ((0.97, 0.94), (0.16, 0.94))
        case .hudWindow, .dark, .ultraDark, .fullScreenUI: ((0.12, 0.8), (0.1, 0.85))
        case .selection: ((0.0, 0.12), (1, 0.15))
        case .sheet, .windowBackground, .contentBackground, .underPageBackground: ((0.93, 0.97), (0.2, 0.97))
        case .light, .mediumLight: ((0.95, 0.85), (0.95, 0.85))
        case .appearanceBased: ((0.94, 0.85), (0.18, 0.85))
        }
    }

    open override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let (w, a) = dark ? tint.dark : tint.light
        if material == .selection {
            NSColor.controlAccentColor.withAlphaComponent(isEmphasized ? 1 : 0.25).setFill()
        } else {
            NSColor(white: w, alpha: a).setFill()
        }
        bounds.fill()
    }
    open override var isOpaque: Bool { false }
}
