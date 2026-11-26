// Paints a window's widget tree with Direct2D: macOS-style controls
// (push buttons, switches, checkboxes, segmented controls, pop-up buttons,
// fields, sliders, progress, steppers, colour wells), text, images,
// canvases and overlay scroll bars.

#if os(Windows)
import Foundation
import RunwayCore
import CoreGraphics
import CRunwayWin32

@MainActor final class Painter {
    unowned let window: W32Window
    private var n: OpaquePointer!
    private var theme = Theme(dark: false)
    private var scale: CGFloat = 1
    /// Solid fills drawn so far this pass (window coordinates), so a plain
    /// text field's EDIT can match whatever is behind it.
    private var fills: [(CGRect, RGBA)] = []
    /// The shortest animation frame interval requested this pass (seconds).
    private var frameInterval: Double?

    init(window: W32Window) { self.window = window }

    // MARK: The pass

    func paint(_ native: OpaquePointer) {
        n = native
        theme = window.backend.theme
        scale = window.scale
        fills.removeAll(keepingCapacity: true)
        frameInterval = nil
        rw_draw_clear(n, (rw_window_backdrop(n) != 0 ? theme.windowBackground.withAlpha(0) : theme.windowBackground).rw)
        window.beginEditPass()
        let bounds = CGRect(origin: .zero, size: window.contentSize)
        for c in window.root.children { paint(c, origin: .zero, clip: bounds, alpha: 1) }
        window.endEditPass()
        rw_window_set_timer(n, frameInterval.map { Int32(($0 * 1000).rounded()) } ?? 0)
        n = nil
    }

    private func wantFrames(every seconds: Double) {
        frameInterval = min(frameInterval ?? seconds, seconds)
    }

    private func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
    private var hairline: CGFloat { scale >= 2 ? 0.5 : 1 / scale }

    private func paint(_ w: W32Widget, origin: CGPoint, clip: CGRect, alpha: Double) {
        let a = alpha * w.props.opacity
        guard a > 0.004 else { return }
        let f = CGRect(x: snap(origin.x + w.frame.minX), y: snap(origin.y + w.frame.minY),
                       width: snap(w.frame.width), height: snap(w.frame.height))
        let leaf = w.children.isEmpty && w.document == nil
        // Off-screen leaves are skipped (an EDIT not drawn is hidden after the pass).
        if leaf, !f.intersects(clip) { return }
        w.hasBeenDrawn = true
        let dim = w.isInteractive && !w.props.enabled && w.kind != .tapArea && !w.isScroll
        let own = dim ? a * 0.45 : a
        rw_draw_set_offset(n, Double(f.minX), Double(f.minY))
        rw_draw_set_alpha(n, Float(own))
        snapOffsetX = f.minX
        snapOffsetY = f.minY
        draw(w, f, clip: clip, alpha: own)

        if case .scroll = w.kind {
            let inner = clip.intersection(f)
            guard !inner.isNull, inner.width > 0, inner.height > 0 else { return }
            rw_draw_set_offset(n, 0, 0)
            rw_draw_push_clip(n, Double(inner.minX), Double(inner.minY), Double(inner.width), Double(inner.height))
            if let doc = w.document {
                let o = CGPoint(x: f.minX - w.scrollOffset.x, y: f.minY - w.scrollOffset.y)
                for c in doc.children { paint(c, origin: o, clip: inner, alpha: a) }
            }
            rw_draw_set_offset(n, 0, 0)
            rw_draw_pop_clip(n)
            scrollBars(w, f, alpha: a)
            return
        }
        guard !w.children.isEmpty else { return }
        var childClip = clip
        if w.props.clips {
            childClip = clip.intersection(f)
            if childClip.isNull { return }
            rw_draw_set_offset(n, 0, 0)
            rw_draw_push_clip(n, Double(childClip.minX), Double(childClip.minY), Double(childClip.width), Double(childClip.height))
        }
        let childAlpha = w.kind == .button ? own : a
        for c in w.children { paint(c, origin: f.origin, clip: childClip, alpha: childAlpha) }
        if w.props.clips {
            rw_draw_set_offset(n, 0, 0)
            rw_draw_pop_clip(n)
        }
    }

    // MARK: Primitives (in the widget's coordinates)

    private func fill(_ r: CGRect, _ radius: CGFloat, _ c: RGBA) {
        guard c.a > 0 else { return }
        rw_draw_paint_color(n, c.rw)
        rw_draw_rect(n, 1, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), Double(radius), 0)
    }

    private func stroke(_ r: CGRect, _ radius: CGFloat, _ c: RGBA, width: CGFloat) {
        guard c.a > 0 else { return }
        rw_draw_paint_color(n, c.rw)
        let i = r.insetBy(dx: width / 2, dy: width / 2)
        rw_draw_rect(n, 0, Double(i.minX), Double(i.minY), Double(i.width), Double(i.height), Double(max(0, radius - width / 2)), Double(width))
    }

    private func fillGradient(_ r: CGRect, _ radius: CGFloat, top: RGBA, bottom: RGBA) {
        var stops = [rw_stop(location: 0, color: top.rw), rw_stop(location: 1, color: bottom.rw)]
        rw_draw_paint_linear(n, Double(r.minX), Double(r.minY), Double(r.minX), Double(r.maxY), &stops, 2)
        rw_draw_rect(n, 1, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), Double(radius), 0)
    }

    private func circle(_ r: CGRect, _ c: RGBA) {
        rw_draw_paint_color(n, c.rw)
        rw_draw_ellipse(n, 1, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), 0)
    }

    private func strokePath(_ p: PathBox, _ c: RGBA, width: CGFloat) {
        rw_draw_paint_color(n, c.rw)
        rw_draw_set_round_caps(n, 1)
        rw_draw_path(n, 0, p.pointer, Double(width))
        rw_draw_set_round_caps(n, 0)
    }

    /// Text vertically centred in `r` (or from its top).
    /// An SF Symbol as Runway's vector art, centred in `r` (widget
    /// coordinates); the icon font's glyph where there's no art.
    private func symbol(_ name: String, _ r: CGRect, _ c: RGBA, fallback: TextBox, background: RGBA) {
        guard let shapes = SymbolPaths.shapes(name) else {
            Symbols.set(fallback, name, size: min(r.width, r.height) / 1.2 * 1.15, alignment: .center)
            text(fallback, r, c)
            return
        }
        let side = min(r.width, r.height)
        let k = side / 24
        // Paths made at the drawn size, so strokes stay at least a pixel wide.
        let boxes = Painter.symbolBoxes(name, shapes, scale: k)
        rw_draw_set_transform(n, 1, 0, 0, 1, Double(snap(r.midX - side / 2)), Double(snap(r.midY - side / 2)))
        rw_draw_set_round_caps(n, 1)
        for (shape, box) in zip(shapes, boxes) {
            rw_draw_paint_color(n, (shape.knockout ? background : c).rw)
            if shape.fill { rw_draw_path(n, 1, box.pointer, 0) }
            if shape.stroke { rw_draw_path(n, 0, box.pointer, Double(max(1 / scale, shape.strokeWidth * k))) }
        }
        rw_draw_set_round_caps(n, 0)
        rw_draw_set_transform(n, 1, 0, 0, 1, 0, 0)
    }

    private static var symbolPaths: [String: [PathBox]] = [:]
    private static func symbolBoxes(_ name: String, _ shapes: [SymbolShape], scale k: CGFloat) -> [PathBox] {
        let key = "\(name)@\(k)"
        if let b = symbolPaths[key] { return b }
        let t = CGAffineTransform(scaleX: k, y: k)
        let boxes = shapes.map { shape in
            PathBox(shape.elements.map {
                switch $0 {
                case let .move(p): .move(p.applying(t))
                case let .line(p): .line(p.applying(t))
                case let .quad(p, c): .quad(p.applying(t), control: c.applying(t))
                case let .curve(p, a, b): .curve(p.applying(t), control1: a.applying(t), control2: b.applying(t))
                case .close: .close
                }
            })
        }
        if symbolPaths.count > 1024 { symbolPaths.removeAll() }
        symbolPaths[key] = boxes
        return boxes
    }

    private func symbolName(_ name: String, _ variant: String?) -> String {
        guard let v = variant, !v.isEmpty, !name.hasSuffix("." + v) else { return name }
        return name + "." + v
    }

    private func text(_ t: TextBox, _ r: CGRect, _ c: RGBA, centred: Bool = true) {
        guard let p = t.pointer else { return }
        let s = t.measure(r.width)
        let y = centred ? snap(r.minY + (r.height - s.height) / 2) : r.minY
        rw_draw_text(n, p, Double(r.minX), Double(y), Double(r.width), Double(s.height), c.rw)
    }

    private func title(_ t: TextBox, _ s: String, _ m: Metrics, weight: FontWeightValue = .regular, align: TextAlignmentValue = .center) -> TextBox {
        t.set(s, size: m.font, weight: weight, alignment: align)
        return t
    }

    /// A rounded bezel with the Mac's soft drop shadow.
    private func bezel(_ r: CGRect, _ radius: CGFloat, face: RGBA, pressed: Bool) {
        fill(r.offsetBy(dx: 0, dy: 0.5), radius, theme.buttonShadow)
        fill(r, radius, pressed ? theme.buttonPressed : face)
        stroke(r, radius, theme.buttonBorder, width: hairline)
        if theme.dark {
            // A faint top highlight, as on the Mac's dark bezels.
            rw_draw_paint_color(n, theme.buttonHighlight.rw)
            rw_draw_line(n, Double(r.minX + radius), Double(r.minY + hairline / 2), Double(r.maxX - radius), Double(r.minY + hairline / 2), Double(hairline))
        }
    }

    private func accentBezel(_ r: CGRect, _ radius: CGFloat, _ tint: RGBA, pressed: Bool) {
        fill(r.offsetBy(dx: 0, dy: 0.5), radius, RGBA(0, 0, 0, theme.dark ? 0.35 : 0.15))
        let base = pressed ? tint.adjusted(-0.12) : tint
        fillGradient(r, radius, top: base.adjusted(0.08), bottom: base)
    }

    private func isPressed(_ w: W32Widget) -> Bool {
        if case let .press(p)? = window.drag, p === w { return window.pressedInside }
        return false
    }

    private func controlRect(_ size: CGSize, _ m: Metrics) -> CGRect {
        let h = min(size.height, max(m.height, 0))
        return CGRect(x: 0, y: snap((size.height - h) / 2), width: size.width, height: h)
    }

    // MARK: Widgets

    private func draw(_ w: W32Widget, _ f: CGRect, clip: CGRect, alpha: Double) {
        let p = w.props
        let m = Metrics(size: p.controlSize)
        let size = f.size
        let bounds = CGRect(origin: .zero, size: size)
        let tint = p.tint ?? theme.accent
        switch w.kind {
        case .container, .scroll:
            break
        case .tapArea:
            break
        case .text:
            text(w.label, bounds, theme.label)
        case .button:
            pushButton(w, bounds, m, tint)
        case let .toggle(k):
            switch k {
            case .switch: switchControl(w, bounds, m, tint)
            case .checkbox: checkbox(w, bounds, m, tint)
            case .button:
                let r = controlRect(size, m)
                bezel(r, m.radius, face: p.isOn ? theme.buttonSelected : theme.buttonFace, pressed: isPressed(w))
                text(title(w.label, p.title, m), r.insetBy(dx: m.padding / 2, dy: 0), theme.label)
            }
        case .textField:
            textField(w, f, clip: clip, m, tint)
        case .textEditor:
            textEditor(w, f, clip: clip, tint)
        case .slider:
            slider(w, bounds, tint)
        case .stepper:
            stepper(w, bounds, m)
        case .dropdown:
            popUpButton(w, bounds, m, tint)
        case .menuButton:
            menuButton(w, bounds, m)
        case .segmented:
            segmented(w, bounds, m)
        case let .progress(circular):
            if circular { spinner(w, bounds) } else { progressBar(w, bounds, tint) }
        case .image:
            image(w, bounds)
        case .canvas:
            canvas(w, f, alpha: alpha)
        case .divider:
            fill(bounds, 0, theme.separator)
        case .link:
            let hot = window.hovered === w
            let c = p.tint ?? theme.link
            w.label.set(StyledText(runs: [TextRun(string: p.title, font: FontSpec(size: m.font), color: nil, underline: hot)], lineLimit: 1))
            text(w.label, bounds, isPressed(w) ? c.adjusted(-0.2) : c)
        case .colorWell:
            let r = controlRect(size, m)
            bezel(r, m.radius, face: theme.buttonFace, pressed: isPressed(w))
            let swatch = r.insetBy(dx: 4, dy: 4)
            fill(swatch, 3, p.color.withAlpha(1).multiplyingAlpha(max(p.color.a, 0.1)))
            stroke(swatch, 3, RGBA(0, 0, 0, theme.dark ? 0.4 : 0.15), width: hairline)
        }
    }

    private func pushButton(_ w: W32Widget, _ b: CGRect, _ m: Metrics, _ tint: RGBA) {
        let p = w.props
        let pressed = isPressed(w)
        let r = p.hasContent ? b : controlRect(b.size, m)
        let accent = p.prominent || p.isDefault
        let fg: RGBA
        if !p.bordered {
            if pressed { fill(r, m.radius, theme.buttonPressed) } else if window.hovered === w { fill(r, m.radius, theme.hoverFill) }
            fg = p.isDestructive ? theme.destructive : theme.label
        } else if accent {
            accentBezel(r, m.radius, p.isDestructive ? theme.destructive : tint, pressed: pressed)
            fg = RGBA(1, 1, 1)
        } else {
            bezel(r, m.radius, face: theme.buttonFace, pressed: pressed)
            fg = p.isDestructive ? theme.destructive : theme.label
        }
        guard !p.hasContent else { return }
        text(title(w.label, p.title, m), r.insetBy(dx: m.padding - 2, dy: 0), fg)
    }

    private func switchControl(_ w: W32Widget, _ b: CGRect, _ m: Metrics, _ tint: RGBA) {
        let p = w.props
        let s = m.switchSize
        let r = CGRect(x: 0, y: snap((b.height - s.height) / 2), width: s.width, height: s.height)
        // Knob position, eased toward the value.
        let target: Double = p.isOn ? 1 : 0
        if let start = w.knobStart {
            let t = min(1, (uptime - start) / 0.16)
            let eased = 1 - pow(1 - t, 3)
            w.knob = w.knobFrom + (target - w.knobFrom) * eased
            if t >= 1 { w.knobStart = nil; w.knob = target } else { wantFrames(every: 1.0 / 60) }
        } else {
            w.knob = target
        }
        let k = CGFloat(w.knob)
        fill(r, s.height / 2, theme.switchOff)
        if k > 0 {
            fill(r, s.height / 2, tint.multiplyingAlpha(Double(k)))
        }
        stroke(r, s.height / 2, theme.switchBorder, width: hairline)
        let d = s.height - 2
        let knob = CGRect(x: 1 + k * (s.width - s.height), y: r.minY + 1, width: d, height: d)
        circle(knob.offsetBy(dx: 0, dy: 0.5).insetBy(dx: -0.25, dy: -0.25), theme.knobShadow)
        circle(knob, isPressed(w) ? theme.knobFace.adjusted(-0.06) : (k > 0.5 ? RGBA(1, 1, 1) : theme.knobFace))
    }

    private func checkmark(_ size: CGFloat) -> PathBox {
        PathBox.shared("check\(size)") {
            let u = size / 14
            return [.move(CGPoint(x: 3.5 * u, y: 7.4 * u)), .line(CGPoint(x: 6.1 * u, y: 10 * u)), .line(CGPoint(x: 10.6 * u, y: 4.2 * u))]
        }
    }

    private func checkbox(_ w: W32Widget, _ b: CGRect, _ m: Metrics, _ tint: RGBA) {
        let p = w.props
        let s = m.checkbox
        let box = CGRect(x: 0, y: snap((b.height - s) / 2), width: s, height: s)
        let radius = s * 0.25
        if p.isOn {
            accentBezel(box, radius, tint, pressed: isPressed(w))
            rw_draw_set_offset(n, Double(snapOffsetX + box.minX), Double(snapOffsetY + box.minY))
            strokePath(checkmark(s), RGBA(1, 1, 1), width: s >= 14 ? 1.8 : 1.5)
            rw_draw_set_offset(n, Double(snapOffsetX), Double(snapOffsetY))
        } else {
            fill(box.offsetBy(dx: 0, dy: 0.5), radius, RGBA(0, 0, 0, theme.dark ? 0.2 : 0.06))
            fill(box, radius, isPressed(w) ? theme.buttonPressed : theme.checkboxFace)
            stroke(box, radius, theme.checkboxBorder, width: hairline)
        }
        guard !p.title.isEmpty else { return }
        let t = title(w.label, p.title, m, align: .leading)
        text(t, CGRect(x: s + 6, y: 0, width: max(0, b.width - s - 6), height: b.height), theme.label)
    }

    // The widget's absolute origin while it draws (set by `paint`).
    private var snapOffsetX: CGFloat = 0
    private var snapOffsetY: CGFloat = 0

    private func textField(_ w: W32Widget, _ f: CGRect, clip: CGRect, _ m: Metrics, _ tint: RGBA) {
        let p = w.props
        let r = controlRect(f.size, m)
        let bg: RGBA
        if p.bordered {
            if w.editFocused {
                stroke(r.insetBy(dx: -3, dy: -3), m.radius + 3, tint.withAlpha(0.45), width: 3.5)
            }
            fill(r, m.radius - 1, theme.fieldBackground)
            stroke(r, m.radius - 1, w.editFocused ? tint : theme.fieldBorder, width: w.editFocused ? 1 : hairline)
            bg = theme.fieldBackground.over(theme.windowBackground)
        } else {
            bg = background(behind: f)
        }
        let lineHeight = (m.font * 1.36).rounded(.up)
        let inset: CGFloat = p.bordered ? 6 : 0
        let editFrame = CGRect(x: f.minX + inset, y: f.minY + snap((f.height - lineHeight) / 2), width: max(0, f.width - 2 * inset), height: lineHeight)
        let textColor = (p.enabled ? theme.label : theme.secondaryLabel).over(bg)
        window.placeEdit(w, frame: editFrame, clip: clip.intersection(f.insetBy(dx: -1, dy: -1)), multiline: false,
                         style: (size: m.font, text: textColor, background: bg))
    }

    private func textEditor(_ w: W32Widget, _ f: CGRect, clip: CGRect, _ tint: RGBA) {
        let b = CGRect(origin: .zero, size: f.size)
        if w.isRich {
            // An AppKit text view: its background, then the RichEdit over it.
            let c = w.richConfig
            let fillColor = c.background ?? theme.textBackground
            if c.drawsBackground { fill(b, 0, fillColor) }
            let bg = c.drawsBackground ? fillColor.over(background(behind: f)) : background(behind: f)
            window.placeRich(w, frame: f, clip: clip, background: bg)
            return
        }
        fill(b, 0, theme.textBackground)
        stroke(b, 0, w.editFocused ? tint.withAlpha(0.7) : theme.fieldBorder, width: hairline)
        let bg = theme.textBackground.over(theme.windowBackground)
        let inner = f.insetBy(dx: 5, dy: 4)
        window.placeEdit(w, frame: inner, clip: clip.intersection(f), multiline: true,
                         style: (size: 13, text: theme.label.over(bg), background: bg))
    }

    /// The opaque colour drawn behind a rectangle so far this pass.
    private func background(behind r: CGRect) -> RGBA {
        let base = rw_window_backdrop(n) != 0 ? (theme.dark ? RGBA(hex: 0x202020) : RGBA(hex: 0xF3F3F3)) : theme.windowBackground
        var layers: [RGBA] = []
        let probe = CGPoint(x: r.midX, y: r.midY)
        for (rect, c) in fills.reversed() where rect.contains(probe) {
            layers.append(c)
            if c.a >= 0.999 { break }
        }
        var out = base
        for c in layers.reversed() { out = c.over(out) }
        return out
    }

    private func slider(_ w: W32Widget, _ b: CGRect, _ tint: RGBA) {
        let p = w.props
        let knob: CGFloat = 18
        let span = p.range.upperBound - p.range.lowerBound
        let t = CGFloat(span > 0 ? max(0, min(1, (p.number - p.range.lowerBound) / span)) : 0)
        let cy = b.midY
        let track = CGRect(x: knob / 2 - 2, y: snap(cy - 2), width: b.width - knob + 4, height: 4)
        fill(track, 2, theme.track)
        let x = knob / 2 + t * (b.width - knob)
        fill(CGRect(x: track.minX, y: track.minY, width: x - track.minX, height: 4), 2, tint)
        let k = CGRect(x: snap(x - knob / 2), y: snap(cy - knob / 2), width: knob, height: knob)
        circle(k.offsetBy(dx: 0, dy: 0.5).insetBy(dx: -0.5, dy: -0.5), theme.knobShadow.multiplyingAlpha(0.8))
        var dragging = false
        if case let .slider(s)? = window.drag, s === w { dragging = true }
        circle(k, dragging ? theme.knobFace.adjusted(-0.05) : theme.knobFace)
    }

    static func stepperText(_ p: WidgetProps) -> String {
        let v = p.number
        if v.rounded() == v, abs(v) < 1e15 { return String(Int64(v)) }
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private func chevron(_ key: String, _ pts: [CGPoint]) -> PathBox {
        PathBox.shared(key) { [.move(pts[0])] + pts.dropFirst().map { .line($0) } }
    }

    private func stepper(_ w: W32Widget, _ b: CGRect, _ m: Metrics) {
        let r = controlRect(b.size, m)
        let arrows = CGRect(x: r.maxX - 15, y: r.minY, width: 15, height: r.height)
        let field = CGRect(x: r.minX, y: r.minY, width: arrows.minX - 4, height: r.height)
        fill(field, m.radius - 1, theme.fieldBackground)
        stroke(field, m.radius - 1, theme.fieldBorder, width: hairline)
        text(title(w.label, Self.stepperText(w.props), m, align: .trailing), field.insetBy(dx: 6, dy: 0), theme.label)
        bezel(arrows, 5, face: theme.buttonFace, pressed: false)
        if isPressed(w) {
            let up = window.mouse.y < snapOffsetY + b.midY
            fill(up ? CGRect(x: arrows.minX, y: arrows.minY, width: arrows.width, height: arrows.height / 2)
                    : CGRect(x: arrows.minX, y: arrows.midY, width: arrows.width, height: arrows.height / 2), 5, theme.buttonPressed)
        }
        rw_draw_paint_color(n, theme.separator.rw)
        rw_draw_line(n, Double(arrows.minX + 3), Double(arrows.midY), Double(arrows.maxX - 3), Double(arrows.midY), Double(hairline))
        let cx = arrows.midX, c = theme.label
        rw_draw_set_offset(n, Double(snapOffsetX + cx), Double(snapOffsetY + arrows.minY))
        let q = arrows.height / 4
        strokePath(chevron("su", [CGPoint(x: -3, y: q + 1.5), CGPoint(x: 0, y: q - 1.5), CGPoint(x: 3, y: q + 1.5)]), c, width: 1.3)
        strokePath(chevron("sd\(arrows.height)", [CGPoint(x: -3, y: 3 * q - 1.5), CGPoint(x: 0, y: 3 * q + 1.5), CGPoint(x: 3, y: 3 * q - 1.5)]), c, width: 1.3)
        rw_draw_set_offset(n, Double(snapOffsetX), Double(snapOffsetY))
    }

    private func popUpButton(_ w: W32Widget, _ b: CGRect, _ m: Metrics, _ tint: RGBA) {
        let p = w.props
        let r = controlRect(b.size, m)
        bezel(r, m.radius, face: theme.buttonFace, pressed: isPressed(w))
        let shown = p.options.indices.contains(p.selected) ? p.options[p.selected] : (p.options.isEmpty ? p.title : "")
        let accessory = CGRect(x: r.maxX - 19, y: r.minY + 3, width: 16, height: r.height - 6)
        text(title(w.label, shown, m, align: .leading), CGRect(x: r.minX + 8, y: r.minY, width: max(0, accessory.minX - r.minX - 12), height: r.height), theme.label)
        // Since Big Sur: the accent square with white up/down chevrons.
        fillGradient(accessory, 4, top: tint.adjusted(0.08), bottom: tint)
        rw_draw_set_offset(n, Double(snapOffsetX + accessory.midX), Double(snapOffsetY + accessory.midY))
        strokePath(chevron("pu", [CGPoint(x: -2.5, y: -1.5), CGPoint(x: 0, y: -4), CGPoint(x: 2.5, y: -1.5)]), RGBA(1, 1, 1), width: 1.4)
        strokePath(chevron("pd", [CGPoint(x: -2.5, y: 1.5), CGPoint(x: 0, y: 4), CGPoint(x: 2.5, y: 1.5)]), RGBA(1, 1, 1), width: 1.4)
        rw_draw_set_offset(n, Double(snapOffsetX), Double(snapOffsetY))
    }

    private func menuButton(_ w: W32Widget, _ b: CGRect, _ m: Metrics) {
        let p = w.props
        let r = controlRect(b.size, m)
        let pressed = isPressed(w)
        if p.bordered { bezel(r, m.radius, face: theme.buttonFace, pressed: pressed) }
        else if pressed { fill(r, m.radius, theme.buttonPressed) }
        else if window.hovered === w { fill(r, m.radius, theme.hoverFill) }
        if p.hasContent { return }
        let chevronX = r.maxX - 10
        if p.title.isEmpty, case let .symbol(name) = p.image {
            let side = (m.font * 1.25).rounded()
            symbol(name, CGRect(x: r.minX + (p.bordered ? 8 : 3), y: r.midY - side / 2, width: side, height: side), theme.label,
                   fallback: w.label, background: theme.windowBackground)
        } else {
            text(title(w.label, p.title, m, align: .leading), CGRect(x: r.minX + m.padding, y: r.minY, width: max(0, chevronX - r.minX - m.padding - 6), height: r.height), theme.label)
        }
        rw_draw_set_offset(n, Double(snapOffsetX + chevronX), Double(snapOffsetY + r.midY))
        strokePath(chevron("md", [CGPoint(x: -3, y: -1.5), CGPoint(x: 0, y: 1.5), CGPoint(x: 3, y: -1.5)]), theme.secondaryLabel, width: 1.4)
        rw_draw_set_offset(n, Double(snapOffsetX), Double(snapOffsetY))
    }

    /// Segment widths for the frame: each title's width plus padding, scaled to fit.
    private func segmentWidths(_ w: W32Widget, width: CGFloat) -> [CGFloat] {
        let m = Metrics(size: w.props.controlSize)
        let natural = w.props.options.map { TextMetrics.size($0, size: m.font).width + 2 * m.padding }
        let total = natural.reduce(0, +)
        guard total > 0 else { return natural }
        return natural.map { $0 * width / total }
    }

    func segmentIndex(_ w: W32Widget, x: CGFloat, width: CGFloat) -> Int? {
        var edge: CGFloat = 0
        for (i, s) in segmentWidths(w, width: width).enumerated() {
            edge += s
            if x < edge { return i }
        }
        return nil
    }

    private func segmented(_ w: W32Widget, _ b: CGRect, _ m: Metrics) {
        let p = w.props
        let r = controlRect(b.size, m)
        fill(r, m.radius, theme.segmentTrack)
        let widths = segmentWidths(w, width: r.width)
        var x = r.minX
        var pressedIndex: Int?
        if isPressed(w) { pressedIndex = segmentIndex(w, x: window.mouse.x - snapOffsetX, width: r.width) }
        for (i, sw) in widths.enumerated() {
            let seg = CGRect(x: x, y: r.minY, width: sw, height: r.height)
            if i == p.selected {
                let pill = seg.insetBy(dx: 1, dy: 1)
                fill(pill.offsetBy(dx: 0, dy: 0.5), m.radius - 1, RGBA(0, 0, 0, theme.dark ? 0.3 : 0.12))
                fill(pill, m.radius - 1, theme.segmentSelected)
            } else if i == pressedIndex {
                fill(seg.insetBy(dx: 1, dy: 1), m.radius - 1, theme.hoverFill)
            }
            if i > 0, i != p.selected, i - 1 != p.selected {
                rw_draw_paint_color(n, theme.separator.rw)
                rw_draw_line(n, Double(snap(x)), Double(r.midY - 6), Double(snap(x)), Double(r.midY + 6), Double(hairline))
            }
            text(title(w.text(i + 1), p.options[i], m), seg.insetBy(dx: 4, dy: 0), theme.label)
            x += sw
        }
    }

    private func progressBar(_ w: W32Widget, _ b: CGRect, _ tint: RGBA) {
        let p = w.props
        let h: CGFloat = min(6, b.height)
        let r = CGRect(x: 0, y: snap((b.height - h) / 2), width: b.width, height: h)
        fill(r, h / 2, theme.track)
        if p.indeterminate {
            // A segment sweeping across the track.
            let period = 1.4
            let t = CGFloat(uptime.truncatingRemainder(dividingBy: period) / period)
            let seg = r.width * 0.3
            let x = -seg + t * (r.width + seg)
            rw_draw_set_offset(n, 0, 0)
            rw_draw_push_clip(n, Double(snapOffsetX + r.minX), Double(snapOffsetY + r.minY), Double(r.width), Double(r.height))
            rw_draw_set_offset(n, Double(snapOffsetX), Double(snapOffsetY))
            fill(CGRect(x: x, y: r.minY, width: seg, height: h), h / 2, tint)
            rw_draw_set_offset(n, 0, 0)
            rw_draw_pop_clip(n)
            rw_draw_set_offset(n, Double(snapOffsetX), Double(snapOffsetY))
            wantFrames(every: 1.0 / 60)
        } else if p.number > 0 {
            fill(CGRect(x: 0, y: r.minY, width: max(h, r.width * CGFloat(min(1, p.number))), height: h), h / 2, tint)
        }
    }

    private func spinner(_ w: W32Widget, _ b: CGRect) {
        let p = w.props
        let s = min(b.width, b.height)
        let c = CGPoint(x: b.midX, y: b.midY)
        if !p.indeterminate {
            // Determinate circular progress: a ring that fills clockwise.
            let lw = max(2, s * 0.1)
            let ring = CGRect(x: c.x - s / 2 + lw / 2, y: c.y - s / 2 + lw / 2, width: s - lw, height: s - lw)
            rw_draw_paint_color(n, theme.track.rw)
            rw_draw_ellipse(n, 0, Double(ring.minX), Double(ring.minY), Double(ring.width), Double(ring.height), Double(lw))
            let v = min(1, max(0, p.number))
            guard v > 0 else { return }
            if w.arc?.value != v || w.arc == nil {
                let steps = max(2, Int(48 * v))
                let rad = ring.width / 2
                var els: [PathElement] = []
                for i in 0...steps {
                    let a = -Double.pi / 2 + 2 * Double.pi * v * Double(i) / Double(steps)
                    let pt = CGPoint(x: c.x + rad * CGFloat(cos(a)), y: c.y + rad * CGFloat(sin(a)))
                    els.append(i == 0 ? .move(pt) : .line(pt))
                }
                w.arc = (v, PathBox(els))
            }
            strokePath(w.arc!.path, p.tint ?? theme.accent, width: lw)
            return
        }
        // The Mac's spinning lines: twelve spokes fading around the circle.
        let phase = Int(uptime * 12) % 12
        let r = s / 2
        let lw = max(1.5, s * 0.085)
        rw_draw_set_round_caps(n, 1)
        for i in 0..<12 {
            let a = Double(i) * Double.pi / 6 - Double.pi / 2
            let age = (phase - i + 12) % 12
            let alpha = 1 - Double(age) / 12 * 0.85
            rw_draw_paint_color(n, theme.spinner.multiplyingAlpha(alpha).rw)
            let ca = CGFloat(cos(a)), sa = CGFloat(sin(a))
            rw_draw_line(n, Double(c.x + ca * r * 0.48), Double(c.y + sa * r * 0.48), Double(c.x + ca * (r - lw / 2)), Double(c.y + sa * (r - lw / 2)), Double(lw))
        }
        rw_draw_set_round_caps(n, 0)
        wantFrames(every: 1.0 / 12)
    }

    private func image(_ w: W32Widget, _ b: CGRect) {
        let p = w.props
        switch p.image {
        case let .symbol(name):
            let side = min(b.width, b.height, (p.imagePointSize * 1.2).rounded())
            let box = CGRect(x: b.midX - side / 2, y: b.midY - side / 2, width: side, height: side)
            symbol(symbolName(name, p.imageSymbolVariant), box, p.imageTint ?? theme.label, fallback: w.label,
                   background: background(behind: w.windowFrame))
        case .file, .pixels:
            if let img = w.image.pointer { rw_draw_image(n, img, 0, 0, Double(b.width), Double(b.height)) }
        case .none:
            break
        }
    }

    // MARK: Canvas

    private func canvas(_ w: W32Widget, _ f: CGRect, alpha: Double) {
        for (i, cmd) in w.props.drawing.enumerated() {
            switch cmd {
            case let .fill(shape, paint):
                if setPaint(paint, shape.bounds) {
                    drawShape(w, i, shape, fill: true, width: 0)
                    if case let .color(c) = paint, c.a > 0 {
                        switch shape {
                        case .rect, .roundedRect: fills.append((shape.bounds.offsetBy(dx: f.minX, dy: f.minY), c.multiplyingAlpha(w.props.opacity)))
                        default: break
                        }
                    }
                }
            case let .stroke(shape, paint, style):
                if setPaint(paint, shape.bounds) {
                    let dash = style.dashLengths
                    if !dash.isEmpty { var d = dash.map { Float($0) }; rw_draw_set_dash(n, &d, Int32(d.count)) }
                    drawShape(w, i, shape, fill: false, width: style.lineWidth)
                    if !dash.isEmpty { rw_draw_set_dash(n, nil, 0) }
                }
            case let .image(source, rect):
                if case let .symbol(name) = source {
                    let t = w.canvasTexts[i] ?? TextBox()
                    w.canvasTexts[i] = t
                    symbol(name, rect, theme.label, fallback: t, background: background(behind: rect.offsetBy(dx: f.minX, dy: f.minY)))
                } else if let img = ImageCache.image(source).pointer {
                    rw_draw_image(n, img, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height))
                }
            case let .text(styled, rect):
                let t = w.canvasTexts[i] ?? TextBox()
                w.canvasTexts[i] = t
                t.set(styled)
                if let p = t.pointer { rw_draw_text(n, p, Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height), theme.label.rw) }
            case let .displayList(list):
                DisplayListPlayer.replay(list, n, origin: f.origin, alpha: alpha)
            }
        }
    }

    /// Sets the current paint; false if there is nothing to draw.
    private func setPaint(_ paint: Paint, _ b: CGRect) -> Bool {
        switch paint {
        case let .color(c):
            guard c.a > 0 else { return false }
            rw_draw_paint_color(n, c.rw)
        case let .linearGradient(stops, s, e):
            var st = stops.map { rw_stop(location: Float($0.location), color: $0.color.rw) }
            rw_draw_paint_linear(n, Double(b.minX + s.x * b.width), Double(b.minY + s.y * b.height),
                                 Double(b.minX + e.x * b.width), Double(b.minY + e.y * b.height), &st, Int32(st.count))
        case let .radialGradient(stops, c, r0, r1):
            var st = stops.map { rw_stop(location: Float($0.location), color: $0.color.rw) }
            rw_draw_paint_radial(n, Double(b.minX + c.x * b.width), Double(b.minY + c.y * b.height), Double(r0), Double(r1), &st, Int32(st.count))
        }
        return true
    }

    private func drawShape(_ w: W32Widget, _ i: Int, _ shape: ShapePath, fill: Bool, width: CGFloat) {
        let f: Int32 = fill ? 1 : 0
        switch shape {
        case let .rect(r):
            rw_draw_rect(n, f, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), 0, Double(width))
        case let .roundedRect(r, radius):
            rw_draw_rect(n, f, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), Double(radius), Double(width))
        case let .ellipse(r):
            rw_draw_ellipse(n, f, Double(r.minX), Double(r.minY), Double(r.width), Double(r.height), Double(width))
        case let .inset(s, d):
            drawShape(w, i, s.insetBy(d), fill: fill, width: width)
        case let .path(els):
            let p = w.canvasPaths[i] ?? PathBox(els)
            w.canvasPaths[i] = p
            rw_draw_path(n, f, p.pointer, Double(width))
        }
    }

    // MARK: Scroll bars

    /// Overlay scroll bars, shown while the pointer is over the view.
    private func scrollBars(_ w: W32Widget, _ f: CGRect, alpha: Double) {
        var dragging = false
        if case let .scrollThumb(s, _, _, _)? = window.drag, s === w { dragging = true }
        guard dragging || window.hoveredScroll === w else { return }
        rw_draw_set_offset(n, Double(f.minX), Double(f.minY))
        rw_draw_set_alpha(n, Float(alpha))
        let m = w.maxScroll
        let local = CGPoint(x: window.mouse.x - f.minX, y: window.mouse.y - f.minY)
        if m.y > 0.5 {
            let (pos, length, _) = window.thumb(w, vertical: true)
            let hot = dragging || local.x >= f.width - 12
            let width: CGFloat = hot ? 9 : 7
            fill(CGRect(x: f.width - width - 2, y: pos, width: width, height: length), width / 2, hot ? theme.scrollThumbHot : theme.scrollThumb)
        }
        if m.x > 0.5 {
            let (pos, length, _) = window.thumb(w, vertical: false)
            let hot = dragging || local.y >= f.height - 12
            let height: CGFloat = hot ? 9 : 7
            fill(CGRect(x: pos, y: f.height - height - 2, width: length, height: height), height / 2, hot ? theme.scrollThumbHot : theme.scrollThumb)
        }
    }
}
#endif
