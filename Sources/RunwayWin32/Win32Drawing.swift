// Core Graphics on the native drawing layer: replays CGDisplayLists (AppKit
// views' `draw(_:)`, recorded by CGContext) with rw_draw_*, and lays out and
// measures their text with the same text boxes the controls use.

#if os(Windows)
import Foundation
import RunwayCore
import CoreGraphics
import CRunwayWin32

@MainActor enum DisplayListPlayer {
    /// Replays `list` in a widget whose top-left is at `origin` (window DIPs).
    static func replay(_ list: CGDisplayList, _ n: OpaquePointer, origin: CGPoint, alpha: Double) {
        var clips: [Int] = [0]   // clips pushed at each save level
        func setTransform(_ t: CGAffineTransform) {
            rw_draw_set_transform(n, Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty))
        }
        for op in list.ops {
            switch op {
            case .save:
                clips.append(0)
            case .restore:
                guard clips.count > 1 else { continue }
                for _ in 0..<clips.removeLast() { rw_draw_pop_clip(n) }
            case let .clip(p, rule, ctm):
                setTransform(ctm)
                let box = path(p, evenOdd: rule == .evenOdd)
                rw_draw_push_clip_path(n, box.pointer)
                clips[clips.count - 1] += 1
            case let .fill(p, rule, c, s):
                let box = path(p, evenOdd: rule == .evenOdd)
                shadow(s, n, alpha) { rw_draw_path(n, 1, box.pointer, 0) }
                setTransform(s.ctm)
                rw_draw_set_alpha(n, Float(alpha * s.alpha))
                rw_draw_paint_color(n, color(c))
                rw_draw_path(n, 1, box.pointer, 0)
            case let .stroke(p, st, c, s):
                let box = path(p, evenOdd: false)
                strokeStyle(st, n)
                shadow(s, n, alpha) { rw_draw_path(n, 0, box.pointer, Double(st.lineWidth)) }
                setTransform(s.ctm)
                rw_draw_set_alpha(n, Float(alpha * s.alpha))
                rw_draw_paint_color(n, color(c))
                rw_draw_path(n, 0, box.pointer, Double(st.lineWidth))
                rw_draw_set_dash(n, nil, 0)
                rw_draw_set_round_caps(n, 0)
            case .clear:
                break   // the window has no layer to punch through
            case let .image(img, r, _, s):
                guard img.width > 0, img.height > 0, r.width != 0, r.height != 0, let bitmap = bitmap(img) else { continue }
                // The image's top row sits at the rect's maxY.
                let t = CGAffineTransform(a: r.width / CGFloat(img.width), b: 0, c: 0, d: -r.height / CGFloat(img.height), tx: r.minX, ty: r.maxY)
                setTransform(t.concatenating(s.ctm))
                rw_draw_set_alpha(n, Float(alpha * s.alpha))
                rw_draw_image(n, bitmap, 0, 0, Double(img.width), Double(img.height))
            case let .linearGradient(g, a, b, _, s):
                setTransform(s.ctm)
                rw_draw_set_alpha(n, Float(alpha * s.alpha))
                var stops = gradientStops(g)
                rw_draw_paint_linear(n, Double(a.x), Double(a.y), Double(b.x), Double(b.y), &stops, Int32(stops.count))
                rw_draw_rect(n, 1, -1e5, -1e5, 2e5, 2e5, 0, 0)
            case let .radialGradient(g, c0, r0, _, r1, _, s):
                setTransform(s.ctm)
                rw_draw_set_alpha(n, Float(alpha * s.alpha))
                var stops = gradientStops(g)
                rw_draw_paint_radial(n, Double(c0.x), Double(c0.y), Double(r0), Double(r1), &stops, Int32(stops.count))
                rw_draw_rect(n, 1, -1e5, -1e5, 2e5, 2e5, 0, 0)
            case let .text(layout, at, flipped, s):
                let box = textBox(layout)
                guard let p = box.pointer else { continue }
                var t = CGAffineTransform(translationX: at.x, y: at.y)
                if !flipped { t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: at.x, ty: at.y) }
                setTransform(t.concatenating(s.ctm))
                rw_draw_set_alpha(n, Float(alpha * s.alpha))
                let size = box.measure(layout.width)
                let w = layout.width ?? size.width
                let h = layout.height ?? size.height
                rw_draw_text(n, p, 0, 0, Double(max(w, size.width)), Double(h), RGBA(0, 0, 0, 1).rw)
            }
        }
        while clips.count > 0 {
            for _ in 0..<clips.removeLast() { rw_draw_pop_clip(n) }
        }
        rw_draw_set_offset(n, Double(origin.x), Double(origin.y))
        rw_draw_set_alpha(n, Float(alpha))
    }

    private static func color(_ c: [CGFloat]) -> rw_color {
        let v = c.count >= 4 ? c : (c.count == 2 ? [c[0], c[0], c[0], c[1]] : [0, 0, 0, 1])
        return rw_color(r: Float(v[0]), g: Float(v[1]), b: Float(v[2]), a: Float(v[3]))
    }

    private static func strokeStyle(_ st: CGStrokeStyle, _ n: OpaquePointer) {
        rw_draw_set_round_caps(n, st.lineCap == .round || st.lineJoin == .round ? 1 : 0)
        if st.dashLengths.isEmpty { rw_draw_set_dash(n, nil, 0) } else {
            var d = st.dashLengths.map { Float($0 / max(st.lineWidth, 0.0001)) }
            rw_draw_set_dash(n, &d, Int32(d.count))
        }
    }

    /// Shadows: the shape again, offset, in the shadow's colour (no blur).
    private static func shadow(_ s: CGDrawState, _ n: OpaquePointer, _ alpha: Double, _ draw: () -> Void) {
        guard let sh = s.shadow, sh.color.count == 4, sh.color[3] > 0 else { return }
        let t = s.ctm.concatenating(CGAffineTransform(translationX: sh.offset.width, y: -sh.offset.height))
        rw_draw_set_transform(n, Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty))
        rw_draw_set_alpha(n, Float(alpha * s.alpha))
        rw_draw_paint_color(n, color([sh.color[0], sh.color[1], sh.color[2], sh.color[3] * (sh.blur > 1 ? 0.6 : 1)]))
        draw()
    }

    private static func gradientStops(_ g: CGGradient) -> [rw_stop] {
        zip(g.colors, g.locations).map { c, l in rw_stop(location: Float(l), color: color(c)) }
    }

    // MARK: Caches

    private static var paths: [CGPath: PathBox] = [:]
    private static var evenOddPaths: [CGPath: PathBox] = [:]

    private static func path(_ p: CGPath, evenOdd: Bool) -> PathBox {
        if let b = evenOdd ? evenOddPaths[p] : paths[p] { return b }
        var elements: [PathElement] = []
        var current = CGPoint.zero
        for op in p.ops {
            switch op {
            case let .move(q): elements.append(.move(q)); current = q
            case let .line(q): elements.append(.line(q)); current = q
            case let .quad(c, q): elements.append(.quad(q, control: c)); current = q
            case let .cubic(a, b, q): elements.append(.curve(q, control1: a, control2: b)); current = q
            case .close: elements.append(.close)
            }
        }
        _ = current
        let box = PathBox(elements)
        if evenOdd { rw_path_set_even_odd(box.pointer, 1) }
        if paths.count + evenOddPaths.count > 512 { paths.removeAll(); evenOddPaths.removeAll() }
        if evenOdd { evenOddPaths[p] = box } else { paths[p] = box }
        return box
    }

    private final class Bitmap { weak var image: CGImage?; let handle: NativeHandle; init(_ i: CGImage, _ h: NativeHandle) { image = i; handle = h } }
    private static var bitmaps: [ObjectIdentifier: Bitmap] = [:]

    private static func bitmap(_ img: CGImage) -> OpaquePointer? {
        let id = ObjectIdentifier(img)
        if let b = bitmaps[id], b.image === img { return b.handle.pointer }
        var px = img.pixels
        if !img.hasAlpha { for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 } }
        guard px.count >= img.width * img.height * 4,
              let p = px.withUnsafeBufferPointer({ rw_image_from_rgba(Int32(img.width), Int32(img.height), $0.baseAddress) }) else { return nil }
        if bitmaps.count > 64 { bitmaps = bitmaps.filter { $0.value.image != nil }; if bitmaps.count > 64 { bitmaps.removeAll() } }
        let b = Bitmap(img, NativeHandle(p, release: { rw_image_free($0) }))
        bitmaps[id] = b
        return p
    }

    private static var texts: [CGTextLayout: TextBox] = [:]

    static func textBox(_ layout: CGTextLayout) -> TextBox {
        if let t = texts[layout] { return t }
        let box = TextBox()
        box.set(styled(layout))
        if texts.count > 512 { texts.removeAll() }
        texts[layout] = box
        return box
    }

    static func styled(_ layout: CGTextLayout) -> StyledText {
        let runs = layout.runs.map { r -> TextRun in
            let family = r.monospaced ? Fonts.mono : (r.family == "System" || r.family?.hasPrefix(".") == true ? nil : r.family)
            let weight = FontWeightValue.closest(to: r.weight)
            var t = TextRun(string: r.string, font: FontSpec(size: r.size, weight: weight, family: family), color: RGBA(color(r.color)))
            t.font.italic = r.italic
            t.underline = r.underline
            t.strikethrough = r.strikethrough
            if let bg = r.backgroundColor { t.background = RGBA(color(bg)) }
            return t
        }
        let align: TextAlignmentValue = switch layout.alignment {
        case .center: .center
        case .right: .trailing
        default: .leading
        }
        var limit: Int? = layout.maximumLines > 0 ? layout.maximumLines : nil
        var truncation: TruncationValue = .tail
        switch layout.lineBreak {
        case .clip: limit = 1
        case .truncateHead: limit = 1; truncation = .head
        case .truncateMiddle: limit = 1; truncation = .middle
        case .truncateTail: limit = 1
        case .wordWrap, .charWrap: break
        }
        return StyledText(runs: runs, alignment: align, lineLimit: limit, truncation: truncation)
    }

    static func measure(_ layout: CGTextLayout) -> CGSize {
        let s = textBox(layout).measure(layout.width)
        var w = s.width
        if let lw = layout.width, lw > 0, layout.lineBreak != .clip { w = min(w, lw) }
        return CGSize(width: w, height: s.height)
    }
}

extension FontWeightValue {
    /// The weight nearest a CSS weight (100…900).
    static func closest(to css: Int) -> FontWeightValue {
        var best = FontWeightValue.regular
        var distance = Int.max
        for w in [FontWeightValue.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black] {
            let d = abs(Int(w.rawValue) - css)
            if d < distance { distance = d; best = w }
        }
        return best
    }
}
#endif
