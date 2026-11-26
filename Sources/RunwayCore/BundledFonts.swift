// The fonts Runway ships inside every app (see CRunwayFonts): written once
// to a per-user cache folder, where backends register them with the
// toolkit (fontconfig, DirectWrite and GDI) before any text is laid out.
//
// Inter stands in for the Mac's San Francisco and JetBrains Mono for SF
// Mono; both are under the SIL Open Font License. Set RUNWAY_SYSTEM_FONTS=1
// to use the desktop's own fonts instead.

import Foundation
import CRunwayFonts

public enum BundledFonts {
    /// The UI family (SF Pro's stand-in).
    public static let uiFamily = "Inter"
    /// The code family (SF Mono's and Menlo's stand-in).
    public static let monoFamily = "JetBrains Mono"

    /// Whether apps use the bundled fonts (the default).
    public static var enabled: Bool { ProcessInfo.processInfo.environment["RUNWAY_SYSTEM_FONTS"] == nil }

    /// Mac font names apps ask for by name, and the bundled family that
    /// draws them.
    public static let aliases: [(String, String)] = [
        ("SF Pro", uiFamily), ("SF Pro Text", uiFamily), ("SF Pro Display", uiFamily), (".AppleSystemUIFont", uiFamily),
        ("System Font", uiFamily), ("Helvetica Neue", uiFamily), ("Lucida Grande", uiFamily),
        ("SF Mono", monoFamily), ("SFMono-Regular", monoFamily), ("Menlo", monoFamily), ("Monaco", monoFamily),
    ]

    private static var cached: [String]?

    /// The font files on disk, written on first use (nil entries skipped
    /// when the cache folder can't be written).
    public static func files() -> [String] {
        if let c = cached { return c }
        var count: Int32 = 0
        guard let list = runway_bundled_fonts(&count) else { cached = []; return [] }
        let dir = cacheDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [String] = []
        for i in 0..<Int(count) {
            let f = list[i]
            guard let name = f.file_name.map({ String(cString: $0) }), let data = f.data else { continue }
            let url = dir.appendingPathComponent(name)
            let size = Int(f.size)
            let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            if existing != size {
                // Write beside it, then move into place: other app instances may be reading.
                let temp = dir.appendingPathComponent(name + ".\(ProcessInfo.processInfo.processIdentifier).tmp")
                do {
                    try Data(bytes: data, count: size).write(to: temp)
                    _ = try? FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: temp, to: url)
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    if (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) != size { continue }
                }
            }
            out.append(url.path)
        }
        cached = out
        return out
    }

    /// The font files to register (none when the system's fonts are asked for).
    public static func filesToRegister() -> [String] { enabled ? files() : [] }

    static func cacheDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        #if os(Windows)
        let base = env["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Runway").appendingPathComponent("Fonts")
        #else
        let base = env["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return base.appendingPathComponent("runway").appendingPathComponent("fonts")
        #endif
    }
}
