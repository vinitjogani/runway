// SymbolArt's SVG as vector paths, for backends that draw symbols
// themselves: the subset the generated art uses (path data with every
// command including arcs, circle, ellipse, rect with corner radii, line,
// polyline, polygon, groups with translate/scale transforms, a stroke-width
// override, filled shapes, and the knock-out mask of ".fill" enclosures).

import Foundation
import CoreGraphics

public struct SymbolShape: Hashable, Sendable {
    /// In the art's 24×24 grid.
    public var elements: [PathElement]
    public var fill: Bool
    public var stroke: Bool
    public var strokeWidth: CGFloat
    /// Cut out of what's drawn before it (drawn in the background colour).
    public var knockout: Bool
}

public enum SymbolPaths {
    nonisolated(unsafe) private static var cache: [String: [SymbolShape]] = [:]
    private static let lock = NSLock()

    /// The symbol's shapes, or nil when there's no art for it.
    public static func shapes(_ name: String, weight: Double = 0) -> [SymbolShape]? {
        let key = "\(name)|\(weight)"
        lock.lock()
        if let s = cache[key] { lock.unlock(); return s }
        lock.unlock()
        guard let svg = SymbolArt.svg(name, weight: weight) else { return nil }
        let shapes = parse(svg)
        lock.lock()
        if cache.count > 1024 { cache.removeAll() }
        cache[key] = shapes
        lock.unlock()
        return shapes
    }

    // MARK: The SVG

    private struct Style {
        var fill = false
        var stroke = true
        var fillInk = "currentColor"
        var strokeInk = "currentColor"
        var strokeWidth: CGFloat = 1.75
        var transform = CGAffineTransform.identity
        var mask: String?
    }

    private struct Tag {
        var name: String
        var attrs: [String: String]
        var closing: Bool
        var selfClosing: Bool
    }

    private static func isBlack(_ ink: String) -> Bool { ["#000", "#000000", "black"].contains(ink.lowercased()) }
    private static func isWhite(_ ink: String) -> Bool { ["#fff", "#ffffff", "white"].contains(ink.lowercased()) }

    static func parse(_ svg: String) -> [SymbolShape] {
        var shapes: [SymbolShape] = []
        var stack: [Style] = [Style()]
        var inDefs = 0
        var mask: String?
        var masks: [String: [SymbolShape]] = [:]
        for tag in tags(svg) {
            if tag.closing {
                switch tag.name {
                case "g":
                    if stack.count > 1, let done = stack.popLast(), let m = done.mask, inDefs == 0 { shapes += masks[m] ?? [] }
                case "defs": inDefs = max(0, inDefs - 1)
                case "mask": mask = nil
                default: break
                }
                continue
            }
            var style = stack.last ?? Style()
            style.mask = nil
            apply(tag.attrs, to: &style)
            switch tag.name {
            case "svg":
                stack[0] = style
            case "defs":
                if !tag.selfClosing { inDefs += 1 }
            case "mask":
                if !tag.selfClosing { mask = tag.attrs["id"] }
            case "g":
                if !tag.selfClosing { stack.append(style) }
            default:
                guard let elements = geometry(tag.name, tag.attrs) else { continue }
                let sx = sqrt(style.transform.a * style.transform.a + style.transform.b * style.transform.b)
                var shape = SymbolShape(elements: transformed(elements, style.transform), fill: style.fill, stroke: style.stroke,
                                        strokeWidth: style.strokeWidth * (sx > 0 ? sx : 1), knockout: false)
                if let m = mask {
                    // In a mask, white keeps and black cuts: keep the cuts.
                    let blackFill = style.fill && isBlack(style.fillInk)
                    let blackStroke = style.stroke && isBlack(style.strokeInk)
                    guard blackFill || blackStroke else { continue }
                    shape.fill = blackFill
                    shape.stroke = blackStroke
                    shape.knockout = true
                    masks[m, default: []].append(shape)
                } else if inDefs == 0 {
                    shapes.append(shape)
                    if let m = style.mask { shapes += masks[m] ?? [] }
                }
            }
        }
        return shapes
    }

    private static func maskID(_ v: String) -> String? {
        guard let a = v.range(of: "#"), let b = v.range(of: ")", range: a.upperBound..<v.endIndex) else { return nil }
        return String(v[a.upperBound..<b.lowerBound])
    }

    private static func apply(_ attrs: [String: String], to style: inout Style) {
        if let f = attrs["fill"] { style.fill = f != "none" && f != "transparent"; style.fillInk = f }
        if let s = attrs["stroke"] { style.stroke = s != "none"; style.strokeInk = s }
        if let w = attrs["stroke-width"], let v = Double(w) { style.strokeWidth = CGFloat(v) }
        if let t = attrs["transform"] { style.transform = parseTransform(t).concatenating(style.transform) }
        if let m = attrs["mask"] { style.mask = maskID(m) }
    }

    private static func parseTransform(_ s: String) -> CGAffineTransform {
        var t = CGAffineTransform.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[rest.startIndex..<open].trimmingCharacters(in: .whitespaces)
            let args = numbers(String(rest[rest.index(after: open)..<close]))
            var m = CGAffineTransform.identity
            switch name {
            case "translate": m = CGAffineTransform(translationX: CGFloat(args.first ?? 0), y: CGFloat(args.count > 1 ? args[1] : 0))
            case "scale": m = CGAffineTransform(scaleX: CGFloat(args.first ?? 1), y: CGFloat(args.count > 1 ? args[1] : (args.first ?? 1)))
            case "rotate":
                let a = CGFloat((args.first ?? 0) * .pi / 180)
                m = CGAffineTransform(rotationAngle: a)
                if args.count >= 3 {
                    let cx = CGFloat(args[1]), cy = CGFloat(args[2])
                    m = CGAffineTransform(translationX: -cx, y: -cy).concatenating(m).concatenating(CGAffineTransform(translationX: cx, y: cy))
                }
            case "matrix" where args.count == 6:
                m = CGAffineTransform(a: CGFloat(args[0]), b: CGFloat(args[1]), c: CGFloat(args[2]), d: CGFloat(args[3]), tx: CGFloat(args[4]), ty: CGFloat(args[5]))
            default: break
            }
            // SVG applies the list left to right, outermost first.
            t = m.concatenating(t)
            rest = rest[rest.index(after: close)...]
        }
        return t
    }

    private static func transformed(_ e: [PathElement], _ t: CGAffineTransform) -> [PathElement] {
        guard t != .identity else { return e }
        return e.map {
            switch $0 {
            case let .move(p): .move(p.applying(t))
            case let .line(p): .line(p.applying(t))
            case let .quad(p, c): .quad(p.applying(t), control: c.applying(t))
            case let .curve(p, a, b): .curve(p.applying(t), control1: a.applying(t), control2: b.applying(t))
            case .close: .close
            }
        }
    }

    // MARK: Shapes

    private static func num(_ a: [String: String], _ k: String, _ d: Double = 0) -> CGFloat { CGFloat(a[k].flatMap(Double.init) ?? d) }

    private static func geometry(_ name: String, _ a: [String: String]) -> [PathElement]? {
        switch name {
        case "path":
            return a["d"].map(pathData)
        case "circle":
            let r = num(a, "r")
            return ellipse(num(a, "cx"), num(a, "cy"), r, r)
        case "ellipse":
            return ellipse(num(a, "cx"), num(a, "cy"), num(a, "rx"), num(a, "ry"))
        case "rect":
            let x = num(a, "x"), y = num(a, "y"), w = num(a, "width"), h = num(a, "height")
            var rx = num(a, "rx", -1), ry = num(a, "ry", -1)
            if rx < 0 { rx = max(ry, 0) }
            if ry < 0 { ry = rx }
            rx = min(rx, w / 2); ry = min(ry, h / 2)
            if rx <= 0 { return [.move(CGPoint(x: x, y: y)), .line(CGPoint(x: x + w, y: y)), .line(CGPoint(x: x + w, y: y + h)), .line(CGPoint(x: x, y: y + h)), .close] }
            let k: CGFloat = 0.5523
            return [
                .move(CGPoint(x: x + rx, y: y)), .line(CGPoint(x: x + w - rx, y: y)),
                .curve(CGPoint(x: x + w, y: y + ry), control1: CGPoint(x: x + w - rx + rx * k, y: y), control2: CGPoint(x: x + w, y: y + ry - ry * k)),
                .line(CGPoint(x: x + w, y: y + h - ry)),
                .curve(CGPoint(x: x + w - rx, y: y + h), control1: CGPoint(x: x + w, y: y + h - ry + ry * k), control2: CGPoint(x: x + w - rx + rx * k, y: y + h)),
                .line(CGPoint(x: x + rx, y: y + h)),
                .curve(CGPoint(x: x, y: y + h - ry), control1: CGPoint(x: x + rx - rx * k, y: y + h), control2: CGPoint(x: x, y: y + h - ry + ry * k)),
                .line(CGPoint(x: x, y: y + ry)),
                .curve(CGPoint(x: x + rx, y: y), control1: CGPoint(x: x, y: y + ry - ry * k), control2: CGPoint(x: x + rx - rx * k, y: y)),
                .close,
            ]
        case "line":
            return [.move(CGPoint(x: num(a, "x1"), y: num(a, "y1"))), .line(CGPoint(x: num(a, "x2"), y: num(a, "y2")))]
        case "polyline", "polygon":
            let v = numbers(a["points"] ?? "")
            guard v.count >= 4 else { return nil }
            var out: [PathElement] = [.move(CGPoint(x: v[0], y: v[1]))]
            var i = 2
            while i + 1 < v.count { out.append(.line(CGPoint(x: v[i], y: v[i + 1]))); i += 2 }
            if name == "polygon" { out.append(.close) }
            return out
        default:
            return nil
        }
    }

    private static func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> [PathElement] {
        let k: CGFloat = 0.5523
        return [
            .move(CGPoint(x: cx + rx, y: cy)),
            .curve(CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + ry * k), control2: CGPoint(x: cx + rx * k, y: cy + ry)),
            .curve(CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - rx * k, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + ry * k)),
            .curve(CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - ry * k), control2: CGPoint(x: cx - rx * k, y: cy - ry)),
            .curve(CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + rx * k, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - ry * k)),
            .close,
        ]
    }

    // MARK: Path data

    static func numbers(_ s: String) -> [Double] {
        var out: [Double] = []
        var cur = ""
        func flush() { if let v = Double(cur) { out.append(v) }; cur = "" }
        var prev: Character = " "
        for c in s {
            if c.isNumber {
                cur.append(c)
            } else if c == "." {
                if cur.contains("."), !cur.contains("e") { flush() }
                cur.append(c)
            } else if c == "-" || c == "+" {
                if prev == "e" || prev == "E" { cur.append(c) } else { flush(); cur.append(c) }
            } else if c == "e" || c == "E" {
                cur.append(c)
            } else {
                flush()
            }
            prev = c
        }
        flush()
        return out
    }

    /// SVG path data: every command, absolute and relative, arcs as curves.
    static func pathData(_ d: String) -> [PathElement] {
        var out: [PathElement] = []
        // Split into commands with their numbers (arc flags may run together: "a1 1 0 01 2 2").
        var commands: [(Character, [Double])] = []
        var current: Character?
        var buffer = ""
        for c in d {
            if c.isLetter, c != "e", c != "E" {
                if let k = current { commands.append((k, k == "a" || k == "A" ? arcNumbers(buffer) : numbers(buffer))) }
                current = c
                buffer = ""
            } else {
                buffer.append(c)
            }
        }
        if let k = current { commands.append((k, k == "a" || k == "A" ? arcNumbers(buffer) : numbers(buffer))) }

        var p = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        for (cmd, v) in commands {
            let rel = cmd.isLowercase
            func pt(_ x: Double, _ y: Double) -> CGPoint { rel ? CGPoint(x: p.x + x, y: p.y + y) : CGPoint(x: x, y: y) }
            switch cmd.uppercased().first! {
            case "M":
                var i = 0
                while i + 1 < v.count {
                    let q = pt(v[i], v[i + 1])
                    if i == 0 { out.append(.move(q)); start = q } else { out.append(.line(q)) }
                    p = q; i += 2
                }
                lastCubic = nil; lastQuad = nil
            case "L":
                var i = 0
                while i + 1 < v.count { let q = pt(v[i], v[i + 1]); out.append(.line(q)); p = q; i += 2 }
                lastCubic = nil; lastQuad = nil
            case "H":
                for x in v { let q = CGPoint(x: rel ? p.x + x : x, y: p.y); out.append(.line(q)); p = q }
                lastCubic = nil; lastQuad = nil
            case "V":
                for y in v { let q = CGPoint(x: p.x, y: rel ? p.y + y : y); out.append(.line(q)); p = q }
                lastCubic = nil; lastQuad = nil
            case "C":
                var i = 0
                while i + 5 < v.count {
                    let a = pt(v[i], v[i + 1]), b = pt(v[i + 2], v[i + 3]), q = pt(v[i + 4], v[i + 5])
                    out.append(.curve(q, control1: a, control2: b)); lastCubic = b; p = q; i += 6
                }
                lastQuad = nil
            case "S":
                var i = 0
                while i + 3 < v.count {
                    let a = lastCubic.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p
                    let b = pt(v[i], v[i + 1]), q = pt(v[i + 2], v[i + 3])
                    out.append(.curve(q, control1: a, control2: b)); lastCubic = b; p = q; i += 4
                }
                lastQuad = nil
            case "Q":
                var i = 0
                while i + 3 < v.count {
                    let c = pt(v[i], v[i + 1]), q = pt(v[i + 2], v[i + 3])
                    out.append(.quad(q, control: c)); lastQuad = c; p = q; i += 4
                }
                lastCubic = nil
            case "T":
                var i = 0
                while i + 1 < v.count {
                    let c = lastQuad.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p
                    let q = pt(v[i], v[i + 1])
                    out.append(.quad(q, control: c)); lastQuad = c; p = q; i += 2
                }
                lastCubic = nil
            case "A":
                var i = 0
                while i + 6 < v.count {
                    let q = pt(v[i + 5], v[i + 6])
                    out += arc(from: p, to: q, rx: v[i], ry: v[i + 1], angle: v[i + 2], large: v[i + 3] != 0, sweep: v[i + 4] != 0)
                    p = q; i += 7
                }
                lastCubic = nil; lastQuad = nil
            case "Z":
                out.append(.close); p = start
                lastCubic = nil; lastQuad = nil
            default:
                break
            }
        }
        return out
    }

    /// Arc arguments, where the two flags may be written without separators.
    private static func arcNumbers(_ s: String) -> [Double] {
        var out: [Double] = []
        var chars = Array(s)
        var i = 0
        func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" { i += 1 } }
        func number() -> Double? {
            skip()
            var j = i
            var sawDot = false, sawE = false
            if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
            while j < chars.count {
                let c = chars[j]
                if c.isNumber { j += 1 }
                else if c == ".", !sawDot, !sawE { sawDot = true; j += 1 }
                else if (c == "e" || c == "E"), !sawE { sawE = true; j += 1; if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 } }
                else { break }
            }
            guard j > i, let v = Double(String(chars[i..<j])) else { return nil }
            i = j
            return v
        }
        func flag() -> Double? {
            skip()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1" ? 1 : 0
        }
        while i < chars.count {
            guard let rx = number(), let ry = number(), let a = number(), let l = flag(), let sw = flag(), let x = number(), let y = number() else { break }
            out += [rx, ry, a, l, sw, x, y]
        }
        chars = []
        return out
    }

    /// An SVG arc as cubic curves (the endpoint parameterisation of SVG 1.1 F.6).
    private static func arc(from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double, angle: Double, large: Bool, sweep: Bool) -> [PathElement] {
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 || p0 == p1 { return [.line(p1)] }
        let phi = angle * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (Double(p0.x) - Double(p1.x)) / 2, dy = (Double(p0.y) - Double(p1.y)) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var k = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { k = -k }
        let cx1 = k * rx * y1 / ry, cy1 = -k * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (Double(p0.x) + Double(p1.x)) / 2
        let cy = sinP * cx1 + cosP * cy1 + (Double(p0.y) + Double(p1.y)) / 2
        func angleOf(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let t1 = angleOf(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var dt = angleOf((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, dt > 0 { dt -= 2 * .pi } else if sweep, dt < 0 { dt += 2 * .pi }
        let segments = max(1, Int(ceil(abs(dt) / (.pi / 2))))
        let step = dt / Double(segments)
        let alpha = 4.0 / 3.0 * tan(step / 4)
        var out: [PathElement] = []
        var t = t1
        func point(_ t: Double) -> (Double, Double) {
            let x = rx * cos(t), y = ry * sin(t)
            return (cosP * x - sinP * y + cx, sinP * x + cosP * y + cy)
        }
        func derivative(_ t: Double) -> (Double, Double) {
            let x = -rx * sin(t), y = ry * cos(t)
            return (cosP * x - sinP * y, sinP * x + cosP * y)
        }
        for i in 0..<segments {
            let t2 = t + step
            let (ax, ay) = point(t), (bx, by) = point(t2)
            let (dax, day) = derivative(t), (dbx, dby) = derivative(t2)
            let end = i == segments - 1 ? p1 : CGPoint(x: bx, y: by)
            out.append(.curve(end, control1: CGPoint(x: ax + alpha * dax, y: ay + alpha * day),
                              control2: CGPoint(x: bx - alpha * dbx, y: by - alpha * dby)))
            t = t2
        }
        return out
    }

    // MARK: Tags

    private static func tags(_ s: String) -> [Tag] {
        var out: [Tag] = []
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            var body = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            if body.hasPrefix("?") || body.hasPrefix("!") { continue }
            var closing = false, selfClosing = false
            if body.hasPrefix("/") { closing = true; body = body.dropFirst() }
            if body.hasSuffix("/") { selfClosing = true; body = body.dropLast() }
            let name = String(body.prefix { !$0.isWhitespace })
            out.append(Tag(name: name, attrs: attributes(String(body.dropFirst(name.count))), closing: closing, selfClosing: selfClosing))
        }
        return out
    }

    private static func attributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        var rest = Substring(s)
        while let eq = rest.firstIndex(of: "=") {
            let key = rest[rest.startIndex..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            var after = rest[rest.index(after: eq)...].drop { $0.isWhitespace }
            guard let quote = after.first, quote == "\"" || quote == "'" else { break }
            after = after.dropFirst()
            guard let end = after.firstIndex(of: quote) else { break }
            out[key] = String(after[after.startIndex..<end])
            rest = after[after.index(after: end)...]
        }
        return out
    }
}
