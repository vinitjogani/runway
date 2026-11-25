// SF Symbols names drawn with open icon art (the generated table; Lucide,
// ISC licence) for backends without Apple's symbols. The table holds base
// glyphs; SF's variants are composed here as SF Symbols composes them:
//
//   name.fill            the glyph's shapes filled
//   name.circle          the glyph, smaller, in a stroked circle
//   name.circle.fill     the glyph knocked out of a filled circle
//   name.square(.fill)   the same in a rounded square
//   name.slash           a diagonal slash through it
//
// Badges and other qualifiers that have no art of their own fall back to
// their base glyph, so any SF name built from a mapped base draws something
// recognisable. The SVG uses `currentColor` for the ink: backends tint it.

import Foundation

public enum SymbolArt {
    /// A standalone SVG keyed by the exact symbol name in the GTK preview's
    /// local artwork directory. The preview paints its silhouette in the icon tint.
    public static func overrideSVG(_ name: String) -> String? {
        #if os(Linux)
        guard let path = ProcessInfo.processInfo.environment["RUNWAY_SYMBOLS_PATH"], !path.isEmpty else { return nil }
        return overrideSVG(name, in: URL(fileURLWithPath: path, isDirectory: true))
        #else
        return nil
        #endif
    }

    private static let overrideNameCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    static func overrideSVG(_ name: String, in directory: URL) -> String? {
        guard let first = name.first, first.isLetter || first.isNumber,
              name.unicodeScalars.allSatisfy(overrideNameCharacters.contains) else { return nil }
        let file = directory.appendingPathComponent("\(name).svg")
        guard let svg = try? String(contentsOf: file, encoding: .utf8), svg.contains("<svg") else { return nil }
        return svg
    }

    /// Stroke width on the 24-unit grid for an SF weight (regular ≈ SF's
    /// regular stroke at text sizes).
    public static func strokeWidth(weight: Double) -> Double {
        // NSFont.Weight-style values: -0.8 ultraLight … 0 regular … 0.62 black.
        switch weight {
        case ..<(-0.6): return 1.0
        case ..<(-0.3): return 1.3
        case ..<(-0.1): return 1.55
        case ..<0.15: return 1.75
        case ..<0.27: return 2.0
        case ..<0.35: return 2.2
        case ..<0.5: return 2.5
        default: return 2.8
        }
    }

    struct Parts: Equatable { var base: String; var fill = false; var enclosure: Enclosure? = nil; var slash = false }
    enum Enclosure: Equatable { case circle, square, bubble }

    /// Splits an SF name into a mapped base and its variants, or nil when
    /// nothing in it is mapped.
    static func resolve(_ name: String) -> Parts? {
        if table[name] != nil { return Parts(base: name, fill: name.hasSuffix(".fill") && !name.hasSuffix("inset.filled")) }
        var tokens = name.split(separator: ".").map(String.init)
        // ".fill" anywhere qualifies the glyph (folder.fill.badge.plus).
        let fill = tokens.contains("fill")
        tokens.removeAll { $0 == "fill" }
        var parts = Parts(base: "", fill: fill)
        while !tokens.isEmpty {
            let candidate = tokens.joined(separator: ".")
            if table[candidate] != nil {
                parts.base = candidate
                // A shape name that is its own base (circle.fill) is just filled.
                return parts
            }
            let last = tokens.removeLast()
            switch last {
            case "circle" where parts.enclosure == nil: parts.enclosure = .circle
            case "square" where parts.enclosure == nil: parts.enclosure = .square
            // checkmark.bubble: a glyph in a speech bubble.
            case "bubble" where parts.enclosure == nil: parts.enclosure = .bubble
            case "slash": parts.slash = true
            default: break  // badge, 2, rtl, ar, trianglebadge.exclamationmark…
            }
        }
        return nil
    }

    /// The symbol as a complete SVG (24×24 view box, ink `currentColor`),
    /// or nil for names with no art.
    public static func svg(_ name: String, weight: Double = 0) -> String? {
        if name == "person.crop.circle.fill" { return filledProfile }
        guard let p = resolve(name), let glyph = table[p.base] else { return nil }
        let sw = strokeWidth(weight: weight)
        let ink = "currentColor"
        func filled(_ s: String) -> String { s.replacingOccurrences(of: "data-fill=\"1\"", with: "fill=\"\(ink)\"") }
        var body: String
        switch p.enclosure {
        case nil:
            body = "<g fill=\"\(p.fill ? ink : "none")\">\(filled(glyph))</g>"
            if p.slash { body += "<path d=\"M3 3l18 18\"/>" }
        case let shape?:
            let outline = switch shape {
            case .circle: "<circle cx=\"12\" cy=\"12\" r=\"10\"/>"
            case .square: "<rect x=\"2.5\" y=\"2.5\" width=\"19\" height=\"19\" rx=\"5\"/>"
            case .bubble: "<path d=\"M7.9 20A9 9 0 1 0 4 16.1L2 22Z\"/>"
            }
            // The glyph at about half size, its stroke kept at the outline's weight.
            let k = shape == .bubble ? 0.5 : 0.55
            let (cx, cy) = shape == .bubble ? (12.6, 11.4) : (12.0, 12.0)
            let inner = "<g transform=\"translate(\(cx) \(cy)) scale(\(k)) translate(-12 -12)\" stroke-width=\"\(sw / k)\">\(filled(glyph))</g>"
            if p.fill {
                // Knocked out: the shape filled, the glyph cut through it.
                let id = "k\(abs(name.hashValue) % 100000)"
                body = "<defs><mask id=\"\(id)\"><rect width=\"24\" height=\"24\" fill=\"#fff\"/>"
                    + "<g stroke=\"#000\" fill=\"none\">\(inner.replacingOccurrences(of: "fill=\"\(ink)\"", with: "fill=\"#000\""))</g></mask></defs>"
                    + "<g mask=\"url(#\(id))\" fill=\"\(ink)\" stroke=\"\(ink)\">\(outline)</g>"
            } else {
                body = outline + "<g fill=\"none\">\(inner)</g>"
            }
            if p.slash { body += "<path d=\"M4 4l16 16\"/>" }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"\(ink)\" "
            + "stroke-width=\"\(sw)\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\(body)</svg>"
    }

    private static let filledProfile = #"""
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">
      <mask id="profile">
        <rect width="24" height="24" fill="white"/>
        <circle cx="12" cy="9" r="3.1" fill="black"/>
        <path d="M5 21v-1c0-3.8 3.1-6 7-6s7 2.2 7 6v1z" fill="black"/>
      </mask>
      <circle cx="12" cy="12" r="10" fill="currentColor" mask="url(#profile)"/>
    </svg>
    """#
}
