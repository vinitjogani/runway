// The widget tree of the Windows backend and the native resources behind
// it. Widgets are lightweight: Swift objects drawn by their window with
// Direct2D, so they can be translucent, rounded and antialiased, overlap
// freely and cost no HWND. Only text input uses a native child (an EDIT).

#if os(Windows)
import Foundation
import RunwayCore
import CRunwayWin32

// MARK: Native handles

/// Owns a native object and frees it with the right function, from any
/// thread, when the last reference goes away.
final class NativeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    private let release: (OpaquePointer) -> Void
    init(_ pointer: OpaquePointer, release: @escaping (OpaquePointer) -> Void) {
        self.pointer = pointer
        self.release = release
    }
    deinit { release(pointer) }
}

extension RGBA {
    var rw: rw_color { rw_color(r: Float(r), g: Float(g), b: Float(b), a: Float(a)) }
    init(_ c: rw_color) { self.init(Double(c.r), Double(c.g), Double(c.b), Double(c.a)) }
    /// This colour composited over an opaque one (GDI has no alpha).
    func over(_ base: RGBA) -> RGBA {
        RGBA(r * a + base.r * (1 - a), g * a + base.g * (1 - a), b * a + base.b * (1 - a), 1)
    }
    func adjusted(_ amount: Double) -> RGBA {
        amount >= 0 ? RGBA(r + (1 - r) * amount, g + (1 - g) * amount, b + (1 - b) * amount, a)
                    : RGBA(r * (1 + amount), g * (1 + amount), b * (1 + amount), a)
    }
}

// MARK: Fonts

/// Font families, chosen once the native layer is up (Windows 11 has the
/// variable Segoe UI and Fluent icons; Windows 10 the classic ones).
enum Fonts {
    nonisolated(unsafe) static var icon = "Segoe MDL2 Assets"
    nonisolated(unsafe) static var mono = "Consolas"
    nonisolated(unsafe) static var serif = "Georgia"

    static func configure() {
        if rw_font_available("Segoe Fluent Icons") != 0 { icon = "Segoe Fluent Icons" }
        // The first installed of the usual code fonts (Wine and trimmed
        // systems lack Consolas).
        for f in ["Cascadia Mono", "Consolas", "JetBrains Mono", "DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Courier New"]
            where rw_font_available(f) != 0 {
            mono = f
            break
        }
        for f in ["Georgia", "Cambria", "DejaVu Serif", "Liberation Serif", "Times New Roman"] where rw_font_available(f) != 0 {
            serif = f
            break
        }
    }

    nonisolated(unsafe) private static var known: [String: Bool] = [:]
    static func installed(_ family: String) -> Bool {
        if let k = known[family] { return k }
        let v = rw_font_available(family) != 0
        known[family] = v
        return v
    }

    static func family(for f: FontSpec) -> String? {
        if let fam = f.family, !fam.isEmpty, !fam.hasPrefix(".") {
            if ["SF Mono", "Menlo", "Monaco", "Courier", "SFMono-Regular"].contains(fam) { return mono }
            if fam == "System" || fam == "SF Pro" || fam == "SF Pro Text" || fam == "Helvetica Neue" || fam == "Helvetica" { return nil }
            return installed(fam) ? fam : (f.design == .monospaced ? mono : nil)
        }
        switch f.design {
        case .monospaced: return mono
        case .serif: return serif
        case .default, .rounded: return nil
        }
    }
}

// MARK: Text

/// A DirectWrite layout for a StyledText, re-made only when the text changes.
final class TextBox {
    private(set) var styled: StyledText?
    private var handle: NativeHandle?
    private var sizes: [CGFloat: CGSize] = [:]

    var pointer: OpaquePointer? { handle?.pointer }

    func set(_ t: StyledText) {
        plainKey = nil
        assign(t)
    }

    private func assign(_ t: StyledText) {
        guard t != styled else { return }
        styled = t
        sizes.removeAll(keepingCapacity: true)
        handle = TextBox.make(t).map { NativeHandle($0, release: { rw_text_free($0) }) }
    }

    private var plainKey: (String, CGFloat, FontWeightValue, String?, TextAlignmentValue, Int?)?

    /// Plain single-style text (control titles); skips rebuilding when unchanged.
    func set(_ string: String, size: CGFloat = 13, weight: FontWeightValue = .regular, family: String? = nil,
             alignment: TextAlignmentValue = .leading, lineLimit: Int? = 1) {
        if let k = plainKey, k.0 == string, k.1 == size, k.2 == weight, k.3 == family, k.4 == alignment, k.5 == lineLimit, styled != nil { return }
        plainKey = (string, size, weight, family, alignment, lineLimit)
        assign(StyledText(runs: [TextRun(string: string, font: FontSpec(size: size, weight: weight, family: family), color: nil)],
                       alignment: alignment, lineLimit: lineLimit))
    }

    /// The size wrapped to `width` (nil: unlimited), rounded up to whole DIPs.
    func measure(_ width: CGFloat?) -> CGSize {
        guard let p = pointer else { return .zero }
        let key = width.map { $0.isFinite ? max(0, $0) : -1 } ?? -1
        if let s = sizes[key] { return s }
        var w = 0.0, h = 0.0
        rw_text_measure(p, key > 0 ? Double(key) : (key == 0 ? 0.001 : 0), &w, &h)
        let s = CGSize(width: CGFloat(w).rounded(.up), height: CGFloat(h).rounded(.up))
        if sizes.count > 16 { sizes.removeAll(keepingCapacity: true) }
        sizes[key] = s
        return s
    }

    static func make(_ t: StyledText) -> OpaquePointer? {
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func dup(_ s: String) -> UnsafePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            owned.append(p)
            return UnsafePointer(p)
        }
        let runs: [rw_text_run] = t.runs.map { run in
            rw_text_run(text: dup(run.string), family: Fonts.family(for: run.font).flatMap(dup),
                        size: Float(run.font.size), weight: Int32(run.font.weight.rawValue),
                        italic: run.font.italic ? 1 : 0, tabular_digits: run.font.monospacedDigit ? 1 : 0,
                        underline: run.underline ? 1 : 0, strikethrough: run.strikethrough ? 1 : 0,
                        has_color: run.color == nil ? 0 : 1, color: (run.color ?? .black).rw)
        }
        let align: Int32 = t.alignment == .center ? RW_ALIGN_CENTER : t.alignment == .trailing ? RW_ALIGN_TRAILING : RW_ALIGN_LEADING
        let trunc: Int32 = t.truncation == .head ? RW_TRUNCATE_HEAD : t.truncation == .middle ? RW_TRUNCATE_MIDDLE : RW_TRUNCATE_TAIL
        return runs.withUnsafeBufferPointer { rw_text_create($0.baseAddress, Int32($0.count), align, Int32(t.lineLimit ?? 0), trunc) }
    }
}

/// Natural sizes of single-line control titles, shared by all widgets.
@MainActor enum TextMetrics {
    private struct Key: Hashable { let string: String; let size: CGFloat; let weight: FontWeightValue }
    private static var cache: [Key: CGSize] = [:]
    private static let box = TextBox()

    static func size(_ string: String, size: CGFloat, weight: FontWeightValue = .regular) -> CGSize {
        let k = Key(string: string, size: size, weight: weight)
        if let s = cache[k] { return s }
        box.set(string, size: size, weight: weight)
        let s = box.measure(nil)
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        cache[k] = s
        return s
    }
}

// MARK: Images

/// A decoded image (file or pixels); the GPU copy is made by the window.
final class ImageBox {
    private(set) var source: ImageSource = .none
    private var handle: NativeHandle?
    private(set) var size: CGSize?

    var pointer: OpaquePointer? { handle?.pointer }

    func set(_ s: ImageSource) {
        guard s != source else { return }
        source = s
        handle = nil
        size = nil
        var p: OpaquePointer?
        switch s {
        case let .file(path): p = rw_image_load_file(path)
        case let .pixels(w, h, rgba) where rgba.count >= w * h * 4: p = rgba.withUnsafeBufferPointer { rw_image_from_rgba(Int32(w), Int32(h), $0.baseAddress) }
        default: break
        }
        if let p {
            handle = NativeHandle(p, release: { rw_image_free($0) })
            var w: Int32 = 0, h: Int32 = 0
            rw_image_size(p, &w, &h)
            size = CGSize(width: Int(w), height: Int(h))
        }
    }
}

/// Image sources shared by every canvas that draws them.
@MainActor enum ImageCache {
    private static var images: [ImageSource: ImageBox] = [:]
    static func image(_ s: ImageSource) -> ImageBox {
        if let i = images[s] { return i }
        if images.count > 64 { images.removeAll() }
        let i = ImageBox()
        i.set(s)
        images[s] = i
        return i
    }
}

/// A path built once from shape elements.
final class PathBox {
    let handle: NativeHandle
    init(_ elements: [PathElement]) {
        let p = rw_path_create()!
        handle = NativeHandle(p, release: { rw_path_free($0) })
        for e in elements {
            switch e {
            case let .move(pt): rw_path_move(p, Double(pt.x), Double(pt.y))
            case let .line(pt): rw_path_line(p, Double(pt.x), Double(pt.y))
            case let .quad(pt, c): rw_path_quad(p, Double(c.x), Double(c.y), Double(pt.x), Double(pt.y))
            case let .curve(pt, c1, c2): rw_path_cubic(p, Double(c1.x), Double(c1.y), Double(c2.x), Double(c2.y), Double(pt.x), Double(pt.y))
            case .close: rw_path_close(p)
            }
        }
    }
    var pointer: OpaquePointer { handle.pointer }

    /// Shared glyph paths for control chrome (checkmarks, chevrons…).
    nonisolated(unsafe) private static var shared: [String: PathBox] = [:]
    static func shared(_ key: String, _ make: () -> [PathElement]) -> PathBox {
        if let p = shared[key] { return p }
        let p = PathBox(make())
        shared[key] = p
        return p
    }
}

// MARK: Widgets

@MainActor final class W32Widget: NativeWidget {
    let kind: WidgetKind
    var props = WidgetProps()
    var events = WidgetEvents()
    /// In the parent container's coordinates.
    var frame: CGRect = .zero
    var children: [W32Widget] = []
    weak var parent: W32Widget?
    /// Set on a window's root container.
    weak var hostWindow: W32Window?
    var contentSize: CGSize = .zero
    /// A scroll view's document and position.
    var document: W32Widget?
    var scrollOffset: CGPoint = .zero

    // Drawing resources.
    let label = TextBox()
    var texts: [TextBox] = []
    let image = ImageBox()
    var canvasTexts: [Int: TextBox] = [:]
    var canvasPaths: [Int: PathBox] = [:]
    var arc: (value: Double, path: PathBox)?

    // Text input.
    var edit: NativeHandle?
    weak var editWindow: W32Window?
    var editFocused = false
    var editText = ""

    var wantsFocus = false

    // AppKit extras (see Win32AppKit.swift).
    var pointerHandler: (@MainActor (PointerEvent) -> Bool)?
    var keyHandler: (@MainActor (KeyPress) -> Bool)?
    var focusable = false
    var ownsPoint: (@MainActor (CGPoint) -> Bool)?
    var hitTestable = true
    var passesThrough = false
    var focusObserver: (@MainActor (Bool) -> Void)?
    var cursor: CursorKind?
    var scrollObserver: (@MainActor (CGPoint) -> Void)?
    var scrollers = (horizontal: true, vertical: true)
    var fieldFocus: (@MainActor (Bool) -> Void)?
    var fieldKey: (@MainActor (KeyPress) -> Bool)?
    var searchField = false
    var keyEquivalent: KeyPress?
    var radio = false
    var styleClasses = Set<String>()
    var fieldAlignment: TextAlignmentValue = .leading
    var fieldEditable = true

    // Rich text (a text view).
    var isRich = false
    var rich: NativeHandle?
    var richConfig = TextViewConfig()
    var richEvents = TextViewEvents()
    var richRuns: [RichTextRun] = []
    var richString = ""
    var richSelection = 0..<0
    var richHeight: CGFloat = 0
    weak var richWindow: W32Window?
    struct RichApplied: Equatable { let config: TextViewConfig; let background: RGBA; let typing: Bool }
    var richConfigApplied: RichApplied?

    // Animation: a switch's knob position, 0 (off) … 1 (on).
    var knob: Double = 0
    var knobFrom: Double = 0
    var knobStart: Double?
    var hasBeenDrawn = false

    init(_ kind: WidgetKind) { self.kind = kind }

    var window: W32Window? {
        var w = self
        while let p = w.parent { w = p }
        return w.hostWindow
    }

    func invalidate() { window?.invalidate() }

    /// Widgets that take the mouse.
    var isInteractive: Bool {
        switch kind {
        case .button, .tapArea, .toggle, .textField, .textEditor, .slider, .dropdown, .segmented, .link, .colorWell, .stepper, .menuButton, .scroll:
            return true
        case .container, .text, .progress, .image, .canvas, .divider:
            return false
        }
    }

    var isScroll: Bool { if case .scroll = kind { return true } else { return false } }

    /// A text box for slot `i` (segments, options…).
    func text(_ i: Int) -> TextBox {
        while texts.count <= i { texts.append(TextBox()) }
        return texts[i]
    }

    /// The bounds in window coordinates (with scroll offsets applied).
    var windowFrame: CGRect {
        var f = frame
        var p = parent
        while let q = p {
            f = f.offsetBy(dx: q.frame.minX, dy: q.frame.minY)
            if let s = q.parent, case .scroll = s.kind, s.document === q {
                f = f.offsetBy(dx: -s.scrollOffset.x, dy: -s.scrollOffset.y)
            }
            p = q.parent
        }
        return f
    }

    var maxScroll: CGPoint {
        CGPoint(x: scrollers.horizontal ? max(0, contentSize.width - frame.width) : 0,
                y: scrollers.vertical ? max(0, contentSize.height - frame.height) : 0)
    }
}

// MARK: Theme

/// macOS's control palette, light and dark.
struct Theme {
    let dark: Bool

    var accent: RGBA { dark ? RGBA(hex: 0x0A84FF) : RGBA(hex: 0x007AFF) }
    var destructive: RGBA { dark ? RGBA(hex: 0xFF453A) : RGBA(hex: 0xFF3B30) }
    var windowBackground: RGBA { dark ? RGBA(hex: 0x1F1F1F) : RGBA(hex: 0xEDEDED) }
    var label: RGBA { dark ? RGBA(1, 1, 1, 0.85) : RGBA(0, 0, 0, 0.85) }
    var secondaryLabel: RGBA { dark ? RGBA(1, 1, 1, 0.55) : RGBA(0, 0, 0, 0.5) }
    var placeholder: RGBA { dark ? RGBA(1, 1, 1, 0.3) : RGBA(0, 0, 0, 0.3) }
    var link: RGBA { dark ? RGBA(hex: 0x419CFF) : RGBA(hex: 0x0068DA) }
    var separator: RGBA { dark ? RGBA(1, 1, 1, 0.1) : RGBA(0, 0, 0, 0.1) }

    // Push buttons and bezels.
    var buttonFace: RGBA { dark ? RGBA(1, 1, 1, 0.22) : RGBA(1, 1, 1) }
    var buttonPressed: RGBA { dark ? RGBA(1, 1, 1, 0.32) : RGBA(hex: 0xE3E3E3) }
    var buttonSelected: RGBA { dark ? RGBA(1, 1, 1, 0.38) : RGBA(hex: 0xD8D8D8) }
    var buttonBorder: RGBA { dark ? RGBA(1, 1, 1, 0.06) : RGBA(0, 0, 0, 0.12) }
    var buttonShadow: RGBA { dark ? RGBA(0, 0, 0, 0.35) : RGBA(0, 0, 0, 0.12) }
    var buttonHighlight: RGBA { RGBA(1, 1, 1, dark ? 0.1 : 0) }
    var hoverFill: RGBA { dark ? RGBA(1, 1, 1, 0.08) : RGBA(0, 0, 0, 0.06) }

    // Fields.
    var fieldBackground: RGBA { dark ? RGBA(hex: 0x2B2B2B) : RGBA(1, 1, 1) }
    var fieldBorder: RGBA { dark ? RGBA(1, 1, 1, 0.14) : RGBA(0, 0, 0, 0.16) }
    var textBackground: RGBA { dark ? RGBA(hex: 0x1E1E1E) : RGBA(1, 1, 1) }

    // Switches, checkboxes, sliders, progress, segmented controls.
    var switchOff: RGBA { dark ? RGBA(1, 1, 1, 0.16) : RGBA(0, 0, 0, 0.09) }
    var switchBorder: RGBA { dark ? RGBA(1, 1, 1, 0.05) : RGBA(0, 0, 0, 0.06) }
    var knobFace: RGBA { dark ? RGBA(hex: 0xD9D9D9) : RGBA(1, 1, 1) }
    var knobShadow: RGBA { RGBA(0, 0, 0, dark ? 0.45 : 0.28) }
    var checkboxFace: RGBA { dark ? RGBA(1, 1, 1, 0.1) : RGBA(1, 1, 1) }
    var checkboxBorder: RGBA { dark ? RGBA(1, 1, 1, 0.22) : RGBA(0, 0, 0, 0.24) }
    var track: RGBA { dark ? RGBA(1, 1, 1, 0.15) : RGBA(0, 0, 0, 0.1) }
    var segmentTrack: RGBA { dark ? RGBA(1, 1, 1, 0.08) : RGBA(0, 0, 0, 0.065) }
    var segmentSelected: RGBA { dark ? RGBA(1, 1, 1, 0.24) : RGBA(1, 1, 1) }
    var scrollThumb: RGBA { dark ? RGBA(1, 1, 1, 0.35) : RGBA(0, 0, 0, 0.35) }
    var scrollThumbHot: RGBA { dark ? RGBA(1, 1, 1, 0.55) : RGBA(0, 0, 0, 0.5) }
    var spinner: RGBA { dark ? RGBA(1, 1, 1, 0.75) : RGBA(0, 0, 0, 0.6) }
}

/// Control metrics by size, after AppKit's.
struct Metrics {
    let size: ControlSizeValue
    var height: CGFloat { switch size { case .mini: 16; case .small: 19; case .regular: 22; case .large, .extraLarge: 28 } }
    var font: CGFloat { switch size { case .mini: 9; case .small: 11; case .regular, .large, .extraLarge: 13 } }
    var radius: CGFloat { switch size { case .mini: 4; case .small: 5; case .regular: 6; case .large, .extraLarge: 7 } }
    var padding: CGFloat { switch size { case .mini: 6; case .small: 8; case .regular: 10; case .large, .extraLarge: 14 } }
    var checkbox: CGFloat { switch size { case .mini: 10; case .small: 12; case .regular, .large, .extraLarge: 14 } }
    var switchSize: CGSize {
        switch size {
        case .mini: CGSize(width: 26, height: 15)
        case .small: CGSize(width: 32, height: 18)
        case .regular: CGSize(width: 38, height: 22)
        case .large, .extraLarge: CGSize(width: 46, height: 26)
        }
    }
    var spinner: CGFloat { switch size { case .mini: 10; case .small: 16; case .regular: 32; case .large, .extraLarge: 40 } }
}

/// Seconds since boot, for animations.
var uptime: Double { ProcessInfo.processInfo.systemUptime }
#endif
