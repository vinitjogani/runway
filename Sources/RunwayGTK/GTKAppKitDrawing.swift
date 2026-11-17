// Core Graphics on Cairo: replays CGDisplayLists (AppKit views'
// `draw(_:)`, recorded by CGContext) onto a Cairo context, and lays out
// and measures text with Pango for string drawing.

#if os(Linux)
import Foundation
import CGtk
import CRunwayGtk
import RunwayCore
import CoreGraphics

enum AppKitCairo {
    /// Replays `list` on `cr`, whose current matrix is the list's device space.
    static func replay(_ list: CGDisplayList, _ cr: OpaquePointer) {
        var base = cairo_matrix_t()
        cairo_get_matrix(cr, &base)
        cairo_save(cr)
        var depth = 0
        for op in list.ops {
            switch op {
            case .save: cairo_save(cr); depth += 1
            case .restore: if depth > 0 { cairo_restore(cr); depth -= 1 }
            default: execute(op, cr, base: &base)
            }
        }
        while depth > 0 { cairo_restore(cr); depth -= 1 }
        cairo_restore(cr)
    }

    static func setMatrix(_ cr: OpaquePointer, _ base: inout cairo_matrix_t, _ t: CGAffineTransform) {
        cairo_set_matrix(cr, &base)
        var m = cairo_matrix_t(xx: Double(t.a), yx: Double(t.b), xy: Double(t.c), yy: Double(t.d), x0: Double(t.tx), y0: Double(t.ty))
        cairo_transform(cr, &m)
    }

    static func path(_ p: CGPath, _ cr: OpaquePointer) {
        cairo_new_path(cr)
        var current = CGPoint.zero, start = CGPoint.zero
        for op in p.ops {
            switch op {
            case let .move(q): cairo_move_to(cr, q.x, q.y); current = q; start = q
            case let .line(q): cairo_line_to(cr, q.x, q.y); current = q
            case let .quad(c, q):
                let c1 = CGPoint(x: current.x + 2 / 3 * (c.x - current.x), y: current.y + 2 / 3 * (c.y - current.y))
                let c2 = CGPoint(x: q.x + 2 / 3 * (c.x - q.x), y: q.y + 2 / 3 * (c.y - q.y))
                cairo_curve_to(cr, c1.x, c1.y, c2.x, c2.y, q.x, q.y)
                current = q
            case let .cubic(a, b, q): cairo_curve_to(cr, a.x, a.y, b.x, b.y, q.x, q.y); current = q
            case .close: cairo_close_path(cr); current = start
            }
        }
    }

    static func cairoOperator(_ m: CGBlendMode) -> cairo_operator_t {
        switch m {
        case .normal: CAIRO_OPERATOR_OVER
        case .multiply: CAIRO_OPERATOR_MULTIPLY
        case .screen: CAIRO_OPERATOR_SCREEN
        case .overlay: CAIRO_OPERATOR_OVERLAY
        case .darken: CAIRO_OPERATOR_DARKEN
        case .lighten: CAIRO_OPERATOR_LIGHTEN
        case .colorDodge: CAIRO_OPERATOR_COLOR_DODGE
        case .colorBurn: CAIRO_OPERATOR_COLOR_BURN
        case .softLight: CAIRO_OPERATOR_SOFT_LIGHT
        case .hardLight: CAIRO_OPERATOR_HARD_LIGHT
        case .difference: CAIRO_OPERATOR_DIFFERENCE
        case .exclusion: CAIRO_OPERATOR_EXCLUSION
        case .hue: CAIRO_OPERATOR_HSL_HUE
        case .saturation: CAIRO_OPERATOR_HSL_SATURATION
        case .color: CAIRO_OPERATOR_HSL_COLOR
        case .luminosity: CAIRO_OPERATOR_HSL_LUMINOSITY
        case .clear: CAIRO_OPERATOR_CLEAR
        case .copy: CAIRO_OPERATOR_SOURCE
        case .sourceIn: CAIRO_OPERATOR_IN
        case .sourceOut: CAIRO_OPERATOR_OUT
        case .sourceAtop: CAIRO_OPERATOR_ATOP
        case .destinationOver: CAIRO_OPERATOR_DEST_OVER
        case .destinationIn: CAIRO_OPERATOR_DEST_IN
        case .destinationOut: CAIRO_OPERATOR_DEST_OUT
        case .destinationAtop: CAIRO_OPERATOR_DEST_ATOP
        case .xor: CAIRO_OPERATOR_XOR
        case .plusDarker: CAIRO_OPERATOR_SATURATE
        case .plusLighter: CAIRO_OPERATOR_ADD
        }
    }

    static func begin(_ cr: OpaquePointer, _ s: CGDrawState) {
        cairo_set_operator(cr, cairoOperator(s.blendMode))
        cairo_set_antialias(cr, s.antialias ? CAIRO_ANTIALIAS_DEFAULT : CAIRO_ANTIALIAS_NONE)
    }

    static func color(_ cr: OpaquePointer, _ c: [CGFloat], _ alpha: CGFloat) {
        cairo_set_source_rgba(cr, c[0], c[1], c[2], c[3] * alpha)
    }

    static func strokeStyle(_ cr: OpaquePointer, _ st: CGStrokeStyle) {
        cairo_set_line_width(cr, st.lineWidth)
        cairo_set_line_cap(cr, st.lineCap == .round ? CAIRO_LINE_CAP_ROUND : st.lineCap == .square ? CAIRO_LINE_CAP_SQUARE : CAIRO_LINE_CAP_BUTT)
        cairo_set_line_join(cr, st.lineJoin == .round ? CAIRO_LINE_JOIN_ROUND : st.lineJoin == .bevel ? CAIRO_LINE_JOIN_BEVEL : CAIRO_LINE_JOIN_MITER)
        cairo_set_miter_limit(cr, st.miterLimit)
        if st.dashLengths.isEmpty { cairo_set_dash(cr, nil, 0, 0) } else {
            st.dashLengths.map(Double.init).withUnsafeBufferPointer { cairo_set_dash(cr, $0.baseAddress, Int32($0.count), st.dashPhase) }
        }
    }

    /// Shadows: the shape again, offset, in the shadow colour (no blur;
    /// Cairo has none, and the offset copy reads as the shadow).
    static func shadow(_ cr: OpaquePointer, _ base: inout cairo_matrix_t, _ s: CGDrawState, _ draw: () -> Void) {
        guard let sh = s.shadow, sh.color.count == 4, sh.color[3] > 0 else { return }
        cairo_save(cr)
        cairo_set_matrix(cr, &base)
        cairo_translate(cr, sh.offset.width, -sh.offset.height)
        var m = cairo_matrix_t(xx: Double(s.ctm.a), yx: Double(s.ctm.b), xy: Double(s.ctm.c), yy: Double(s.ctm.d), x0: Double(s.ctm.tx), y0: Double(s.ctm.ty))
        cairo_transform(cr, &m)
        let softened = [sh.color[0], sh.color[1], sh.color[2], sh.color[3] * (sh.blur > 1 ? 0.6 : 1)]
        color(cr, softened, s.alpha)
        draw()
        cairo_restore(cr)
    }

    static func execute(_ op: CGDisplayOp, _ cr: OpaquePointer, base: inout cairo_matrix_t) {
        switch op {
        case .save, .restore:
            break
        case let .clip(p, rule, ctm):
            setMatrix(cr, &base, ctm)
            path(p, cr)
            cairo_set_fill_rule(cr, rule == .evenOdd ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING)
            cairo_clip(cr)
        case let .fill(p, rule, c, s):
            shadow(cr, &base, s) {
                path(p, cr)
                cairo_set_fill_rule(cr, rule == .evenOdd ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING)
                cairo_fill(cr)
            }
            setMatrix(cr, &base, s.ctm)
            begin(cr, s)
            path(p, cr)
            cairo_set_fill_rule(cr, rule == .evenOdd ? CAIRO_FILL_RULE_EVEN_ODD : CAIRO_FILL_RULE_WINDING)
            color(cr, c, s.alpha)
            cairo_fill(cr)
            cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        case let .stroke(p, st, c, s):
            shadow(cr, &base, s) {
                path(p, cr); strokeStyle(cr, st); cairo_stroke(cr)
            }
            setMatrix(cr, &base, s.ctm)
            begin(cr, s)
            path(p, cr)
            strokeStyle(cr, st)
            color(cr, c, s.alpha)
            cairo_stroke(cr)
            cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        case let .clear(r, ctm):
            setMatrix(cr, &base, ctm)
            cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
            cairo_rectangle(cr, r.minX, r.minY, r.width, r.height)
            cairo_fill(cr)
            cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        case let .image(img, r, q, s):
            guard img.width > 0, img.height > 0, r.width != 0, r.height != 0, let surface = ImageSurfaces.surface(for: img) else { return }
            setMatrix(cr, &base, s.ctm)
            begin(cr, s)
            cairo_save(cr)
            // The image's top row sits at the rect's maxY.
            cairo_translate(cr, r.minX, r.maxY)
            cairo_scale(cr, r.width / CGFloat(img.width), -r.height / CGFloat(img.height))
            cairo_set_source_surface(cr, surface, 0, 0)
            let filter: cairo_filter_t = q == .none ? CAIRO_FILTER_NEAREST : q == .low ? CAIRO_FILTER_FAST : q == .high ? CAIRO_FILTER_BEST : CAIRO_FILTER_GOOD
            cairo_pattern_set_filter(cairo_get_source(cr), filter)
            cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD)
            cairo_rectangle(cr, 0, 0, Double(img.width), Double(img.height))
            cairo_clip(cr)
            if s.alpha < 1 { cairo_paint_with_alpha(cr, s.alpha) } else { cairo_paint(cr) }
            cairo_restore(cr)
            cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        case let .linearGradient(g, a, b, o, s):
            setMatrix(cr, &base, s.ctm)
            begin(cr, s)
            let pat = cairo_pattern_create_linear(a.x, a.y, b.x, b.y)!
            paintGradient(g, pat, o, s, cr)
        case let .radialGradient(g, c0, r0, c1, r1, o, s):
            setMatrix(cr, &base, s.ctm)
            begin(cr, s)
            let pat = cairo_pattern_create_radial(c0.x, c0.y, r0, c1.x, c1.y, r1)!
            paintGradient(g, pat, o, s, cr)
        case let .text(layout, origin, flipped, s):
            setMatrix(cr, &base, s.ctm)
            begin(cr, s)
            cairo_save(cr)
            cairo_translate(cr, origin.x, origin.y)
            if !flipped { cairo_scale(cr, 1, -1) }
            if let h = layout.height, let w = layout.width {
                cairo_rectangle(cr, 0, 0, w, h)
                cairo_clip(cr)
            }
            // Translucent text is drawn opaque into a group painted with its
            // alpha: Pango's alpha attribute stays set on the shared Cairo
            // renderer GTK draws its own text with, dimming every label
            // drawn after it.
            let alphas = Set(layout.runs.map { $0.color.count == 4 ? $0.color[3] : 1 })
            let uniform = alphas.count <= 1
            let opacity = (uniform ? alphas.first ?? 1 : 1) * s.alpha
            let pl = pango_cairo_create_layout(cr)!
            PangoText.configure(pl, layout, alpha: !uniform)
            if opacity < 1 {
                cairo_push_group(cr)
                pango_cairo_show_layout(cr, pl)
                cairo_pop_group_to_source(cr)
                cairo_paint_with_alpha(cr, opacity)
            } else {
                pango_cairo_show_layout(cr, pl)
            }
            if !uniform {
                // Runs of different alphas: put the renderer's alpha back.
                pango_layout_set_markup(pl, "<span alpha=\"100%\"> </span>", -1)
                pango_cairo_show_layout(cr, pl)
            }
            g_object_unref(UnsafeMutableRawPointer(pl))
            cairo_restore(cr)
            cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
        }
    }

    static func paintGradient(_ g: CGGradient, _ pat: OpaquePointer, _ o: CGGradientDrawingOptions, _ s: CGDrawState, _ cr: OpaquePointer) {
        for (c, l) in zip(g.colors, g.locations) { cairo_pattern_add_color_stop_rgba(pat, l, c[0], c[1], c[2], c[3]) }
        // Cairo extends both ends or neither; CG's options extend each.
        let both = o.contains(.drawsBeforeStartLocation) && o.contains(.drawsAfterEndLocation)
        cairo_pattern_set_extend(pat, both ? CAIRO_EXTEND_PAD : CAIRO_EXTEND_NONE)
        if !both, !o.isEmpty {
            // One side extends: pad, then let the stops' ends stand in (good
            // enough for the common "fill past the end" use).
            cairo_pattern_set_extend(pat, CAIRO_EXTEND_PAD)
        }
        cairo_set_source(cr, pat)
        if s.alpha < 1 { cairo_paint_with_alpha(cr, s.alpha) } else { cairo_paint(cr) }
        cairo_pattern_destroy(pat)
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
    }
}

/// CGImages as Cairo surfaces, converted once and kept for the images
/// drawn most recently.
enum ImageSurfaces {
    private struct Entry { weak var image: CGImage?; let surface: OpaquePointer }
    nonisolated(unsafe) private static var cache: [ObjectIdentifier: Entry] = [:]
    nonisolated(unsafe) private static var order: [ObjectIdentifier] = []
    private static let limit = 64

    static func surface(for img: CGImage) -> OpaquePointer? {
        let id = ObjectIdentifier(img)
        if let e = cache[id], e.image === img { return e.surface }
        if let e = cache.removeValue(forKey: id) { cairo_surface_destroy(e.surface); order.removeAll { $0 == id } }
        guard let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(img.width), Int32(img.height)) else { return nil }
        cairo_surface_flush(s)
        let stride = Int(cairo_image_surface_get_stride(s))
        guard let data = cairo_image_surface_get_data(s) else { cairo_surface_destroy(s); return nil }
        let px = img.pixels
        for y in 0..<img.height {
            let row = data + y * stride
            for x in 0..<img.width {
                let i = (y * img.width + x) * 4
                let a = UInt32(img.hasAlpha ? px[i + 3] : 255)
                let r = UInt32(px[i]) * a / 255, g = UInt32(px[i + 1]) * a / 255, b = UInt32(px[i + 2]) * a / 255
                row.advanced(by: x * 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee = a << 24 | r << 16 | g << 8 | b }
            }
        }
        cairo_surface_mark_dirty(s)
        cache[id] = Entry(image: img, surface: s)
        order.append(id)
        if order.count > limit {
            let old = order.removeFirst()
            if let e = cache.removeValue(forKey: old) { cairo_surface_destroy(e.surface) }
        }
        return s
    }
}

/// Pango layouts for CGTextLayout.
enum PangoText {
    nonisolated(unsafe) static var systemFamily: String = {
        guard let settings = gtk_settings_get_default() else { return "Sans" }
        var v = GValue()
        g_value_init(&v, GType(16 << 2))   // G_TYPE_STRING
        g_object_get_property(UnsafeMutablePointer<GObject>(settings), "gtk-font-name", &v)
        defer { g_value_unset(&v) }
        guard let s = g_value_get_string(&v), let desc = pango_font_description_from_string(s) else { return "Sans" }
        defer { pango_font_description_free(desc) }
        return pango_font_description_get_family(desc).map { String(cString: $0) } ?? "Sans"
    }()

    static func markup(_ layout: CGTextLayout, alpha: Bool = true) -> String {
        var out = ""
        for r in layout.runs {
            var desc = r.monospaced ? "Monospace" : (r.family.map { $0 == "System" || $0.hasPrefix(".") ? systemFamily : $0 } ?? systemFamily)
            switch r.weight {
            case ..<150: desc += " Ultra-Light"
            case ..<250: desc += " Thin"
            case ..<350: desc += " Light"
            case ..<450: break
            case ..<550: desc += " Medium"
            case ..<650: desc += " Semi-Bold"
            case ..<750: desc += " Bold"
            case ..<850: desc += " Heavy"
            default: desc += " Ultra-Heavy"
            }
            if r.italic { desc += " Italic" }
            desc += " \(max(1, r.size))px"
            func hex(_ c: [CGFloat]) -> String {
                c.prefix(3).map { v -> String in let i = Int((max(0, min(1, v)) * 255).rounded()); return (i < 16 ? "0" : "") + String(i, radix: 16) }.joined()
            }
            var attrs = "font_desc=\"\(desc)\" foreground=\"#\(hex(r.color))\""
            if alpha { attrs += " alpha=\"\(max(1, Int((r.color[3] * 100).rounded())))%\"" }
            if let bg = r.backgroundColor { attrs += " background=\"#\(hex(bg))\" bgalpha=\"\(max(1, Int((bg[3] * 100).rounded())))%\"" }
            if r.underline { attrs += " underline=\"single\"" }
            if r.strikethrough { attrs += " strikethrough=\"true\"" }
            if r.kern != 0 { attrs += " letter_spacing=\"\(Int(r.kern * 1024))\"" }
            if r.baselineOffset != 0 { attrs += " rise=\"\(Int(r.baselineOffset * 1024))\"" }
            let escaped = g_markup_escape_text(r.string, -1)!
            out += "<span \(attrs)>\(String(cString: escaped))</span>"
            g_free(escaped)
        }
        return out
    }

    static func configure(_ pl: OpaquePointer, _ layout: CGTextLayout, alpha: Bool = true) {
        pango_layout_set_markup(pl, markup(layout, alpha: alpha), -1)
        if let w = layout.width, w > 0 {
            pango_layout_set_width(pl, Int32(w * CGFloat(PANGO_SCALE)))
            switch layout.lineBreak {
            case .wordWrap: pango_layout_set_wrap(pl, PANGO_WRAP_WORD_CHAR)
            case .charWrap: pango_layout_set_wrap(pl, PANGO_WRAP_CHAR)
            case .clip: pango_layout_set_width(pl, -1)
            case .truncateHead: pango_layout_set_ellipsize(pl, PANGO_ELLIPSIZE_START)
            case .truncateTail: pango_layout_set_ellipsize(pl, PANGO_ELLIPSIZE_END)
            case .truncateMiddle: pango_layout_set_ellipsize(pl, PANGO_ELLIPSIZE_MIDDLE)
            }
        }
        if layout.maximumLines > 0 {
            pango_layout_set_height(pl, -Int32(layout.maximumLines))
            if layout.lineBreak == .wordWrap || layout.lineBreak == .charWrap { pango_layout_set_ellipsize(pl, PANGO_ELLIPSIZE_END) }
        }
        switch layout.alignment {
        case .center: pango_layout_set_alignment(pl, PANGO_ALIGN_CENTER)
        case .right: pango_layout_set_alignment(pl, PANGO_ALIGN_RIGHT)
        case .justified: pango_layout_set_justify(pl, 1)
        default: pango_layout_set_alignment(pl, PANGO_ALIGN_LEFT)
        }
        if layout.lineSpacing != 0 { pango_layout_set_spacing(pl, Int32(layout.lineSpacing * CGFloat(PANGO_SCALE))) }
    }

    nonisolated(unsafe) private static var scratch: OpaquePointer? = {
        guard let s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1), let cr = cairo_create(s) else { return nil }
        cairo_surface_destroy(s)
        return pango_cairo_create_layout(cr).map { l in cairo_destroy(cr); return l }
    }()

    static func measure(_ layout: CGTextLayout) -> CGSize {
        guard let pl = scratch else { return .zero }
        pango_layout_set_width(pl, -1)
        pango_layout_set_height(pl, -1)
        pango_layout_set_ellipsize(pl, PANGO_ELLIPSIZE_NONE)
        pango_layout_set_wrap(pl, PANGO_WRAP_WORD)
        pango_layout_set_justify(pl, 0)
        pango_layout_set_spacing(pl, 0)
        configure(pl, layout)
        var ink = PangoRectangle(), logical = PangoRectangle()
        pango_layout_get_pixel_extents(pl, &ink, &logical)
        var w = CGFloat(logical.width)
        if let lw = layout.width, lw > 0, layout.lineBreak != .clip { w = min(w, lw) }
        return CGSize(width: w, height: CGFloat(logical.height))
    }
}
#endif
