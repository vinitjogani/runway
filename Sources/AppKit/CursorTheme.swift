// The art of the system cursors: what NSCursor.arrow.image and hotSpot
// answer (apps draw pointers into recordings and previews with them). On
// Linux it's the desktop's Xcursor theme (XCURSOR_THEME, else the default
// theme's Inherits=, else Adwaita), read straight from its files: the same
// pictures the pointer shows. Elsewhere, or with no theme, there's no art.

import Foundation

enum CursorTheme {
    /// The cursors' size in points, as GTK and the desktop use by default.
    static let pointSize = 24

    struct Art {
        let width: Int, height: Int
        let rgba: [UInt8]
        /// From the top-left, in pixels.
        let hot: (x: Int, y: Int)
        /// The nominal size it was drawn for (pixels at 1×).
        let nominal: Int
    }

    private static let cache = NSLock()
    nonisolated(unsafe) private static var loaded: [String: Art?] = [:]

    /// The named (CSS) cursor at about `scale`× its point size.
    static func art(_ name: String, scale: Int = 2) -> Art? {
        let key = "\(name)@\(scale)"
        cache.lock(); defer { cache.unlock() }
        if let a = loaded[key] { return a }
        var found: Art?
        for file in files(name) {
            if let data = FileManager.default.contents(atPath: file), let a = parse(data, nominal: pointSize * scale) { found = a; break }
        }
        loaded[key] = found
        return found
    }

    /// Candidate files for `name`, theme by theme (each theme's inherited ones after it).
    static func files(_ name: String) -> [String] {
        #if os(Linux)
        var dirs: [String] = []
        if let home = ProcessInfo.processInfo.environment["HOME"] { dirs += [home + "/.icons", home + "/.local/share/icons"] }
        let data = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
        dirs += data.split(separator: ":").map { "\($0)/icons" } + ["/usr/share/pixmaps"]
        var themes: [String] = []
        func add(_ t: String) {
            guard !t.isEmpty, !themes.contains(t), themes.count < 8 else { return }
            themes.append(t)
            for d in dirs {
                guard let index = try? String(contentsOfFile: "\(d)/\(t)/index.theme", encoding: .utf8) else { continue }
                for line in index.split(separator: "\n") where line.hasPrefix("Inherits=") {
                    line.dropFirst("Inherits=".count).split(separator: ",").forEach { add($0.trimmingCharacters(in: .whitespaces)) }
                }
            }
        }
        add(ProcessInfo.processInfo.environment["XCURSOR_THEME"] ?? "default")
        add("Adwaita")
        let names = [name] + (aliases[name] ?? [])
        return themes.flatMap { t in dirs.flatMap { d in names.map { "\(d)/\(t)/cursors/\($0)" } } }
            .filter { FileManager.default.fileExists(atPath: $0) }
        #else
        return []
        #endif
    }

    /// Older (X11) names for the CSS ones, for themes without the latter.
    static let aliases: [String: [String]] = [
        "default": ["left_ptr", "arrow"], "text": ["xterm", "ibeam"], "pointer": ["hand2", "hand1"],
        "grab": ["openhand", "hand1"], "grabbing": ["closedhand", "fleur"], "crosshair": ["cross", "tcross"],
        "not-allowed": ["crossed_circle", "circle"], "copy": ["dnd-copy"], "alias": ["dnd-link"],
        "ew-resize": ["sb_h_double_arrow", "h_double_arrow"], "ns-resize": ["sb_v_double_arrow", "v_double_arrow"],
        "col-resize": ["sb_h_double_arrow"], "row-resize": ["sb_v_double_arrow"],
        "w-resize": ["left_side"], "e-resize": ["right_side"], "n-resize": ["top_side"], "s-resize": ["bottom_side"],
    ]

    /// An Xcursor file's image nearest `nominal` (the first frame of an animation).
    static func parse(_ d: Data, nominal: Int) -> Art? {
        let b = [UInt8](d)
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        guard b.count >= 16, b[0] == 0x58, b[1] == 0x63, b[2] == 0x75, b[3] == 0x72, // "Xcur"
              let header = u32(4), let count = u32(12), count < 4096 else { return nil }
        var best: (pos: Int, size: Int)?
        for i in 0..<count {
            let e = header + i * 12
            guard let type = u32(e), let sub = u32(e + 4), let pos = u32(e + 8), type == 0xFFFD_0002 else { continue }
            if best == nil || abs(sub - nominal) < abs(best!.size - nominal) { best = (pos, sub) }
        }
        guard let (pos, size) = best, let w = u32(pos + 16), let h = u32(pos + 20), let xh = u32(pos + 24), let yh = u32(pos + 28),
              w > 0, h > 0, w <= 1024, h <= 1024, pos + 36 + w * h * 4 <= b.count else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            // ARGB, premultiplied, little-endian: B G R A in memory.
            let o = pos + 36 + i * 4
            let a = Int(b[o + 3])
            func straight(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, Int(c) * 255 / a)) }
            rgba[i * 4] = straight(b[o + 2]); rgba[i * 4 + 1] = straight(b[o + 1]); rgba[i * 4 + 2] = straight(b[o]); rgba[i * 4 + 3] = UInt8(a)
        }
        return Art(width: w, height: h, rgba: rgba, hot: (xh, yh), nominal: size)
    }
}
