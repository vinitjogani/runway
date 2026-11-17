// Asset catalogs at run time. `runway` converts an app's `.xcassets` into a
// `RunwayAssets/RunwayAssets.json` plus the image files, shipped in the
// app's resources (see Sources/runway/Resources.swift for the format). This
// is the lookup SwiftUI's `Color("Name")` / `Image("name")` and AppKit's
// `NSColor(named:)` / `NSImage(named:)` use.
//
// Catalogs are found in, in order: the directories in RUNWAY_ASSETS_PATH,
// directories registered with `register(directory:)`, Bundle.main's
// resources, the executable's directory and every SwiftPM resource bundle
// (`*.resources`) next to it. Earlier catalogs win for a name.

import Foundation

public enum RunwayAssets {
    /// An sRGB colour, components 0…1.
    public struct RGBA: Equatable, Hashable, Sendable {
        public var red: Double, green: Double, blue: Double, alpha: Double
        public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }
    }

    /// One image file of an image set.
    public struct ImageFile: Equatable, Sendable {
        /// "1x", "2x", "3x", "any" (vector or unscaled), or "16x16@2x" for app icons.
        public var scale: String
        public var dark: Bool
        public var path: String
    }

    /// A colour set's light and dark appearances (dark falls back to light).
    public static func color(named name: String) -> (light: RGBA, dark: RGBA)? {
        store.withLock { $0.load().colors[name] }
    }

    /// The best file for an image set: the requested scale (or the nearest),
    /// in the dark appearance when asked and present.
    public static func imagePath(named name: String, scale: Int = 1, dark: Bool = false) -> String? {
        let files = imageFiles(named: name)
        guard !files.isEmpty else { return nil }
        let pool = dark && files.contains(where: \.dark) ? files.filter(\.dark) : files.filter { !$0.dark }
        let candidates = pool.isEmpty ? files : pool
        if let vector = candidates.first(where: { $0.scale == "any" }) { return vector.path }
        func numeric(_ s: String) -> Int { Int(s.split(separator: "@").last?.filter(\.isNumber) ?? "") ?? 1 }
        return candidates.min { abs(numeric($0.scale) - scale) < abs(numeric($1.scale) - scale) }?.path
    }

    /// An image by name, as `NSImage(named:)` and `Image("name")` find it:
    /// an image set of the asset catalogs, else a file among the bundle's
    /// resources (with or without its extension).
    public static func resolveImage(named name: String, bundle: Bundle? = nil, dark: Bool = false, scale: Int = 1) -> (path: String, template: Bool, scale: Int)? {
        guard !name.isEmpty else { return nil }
        let files = imageFiles(named: name)
        if !files.isEmpty {
            let pool = dark && files.contains(where: \.dark) ? files.filter(\.dark) : files.filter { !$0.dark }
            let candidates = pool.isEmpty ? files : pool
            func numeric(_ s: String) -> Int { Int(s.split(separator: "@").last?.filter(\.isNumber) ?? "") ?? 1 }
            if let best = candidates.min(by: { abs(numeric($0.scale) - scale) < abs(numeric($1.scale) - scale) }) {
                return (best.path, isTemplate(named: name), best.scale.hasSuffix("any") ? 1 : numeric(best.scale))
            }
        }
        let bundles = [bundle, Bundle.main].compactMap { $0 }
        for b in bundles {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, let u = b.url(forResource: (name as NSString).deletingPathExtension, withExtension: ext) { return (u.path, false, 1) }
            for e in ["png", "jpg", "jpeg", "tiff", "tif", "gif", "icns", "svg", "pdf", "webp", "bmp", "heic"] {
                if let u = b.url(forResource: name, withExtension: e) { return (u.path, name.hasSuffix("Template"), 1) }
                if let u = b.url(forResource: name + "@2x", withExtension: e) { return (u.path, name.hasSuffix("Template"), 2) }
            }
        }
        return nil
    }

    /// Every file of an image set.
    public static func imageFiles(named name: String) -> [ImageFile] {
        store.withLock { $0.load().images[name]?.files ?? [] }
    }

    /// Whether the image set renders as a template (tinted) image.
    public static func isTemplate(named name: String) -> Bool {
        store.withLock { $0.load().images[name]?.template ?? false }
    }

    /// A data set's file (NSDataAsset).
    public static func dataPath(named name: String) -> String? {
        store.withLock { $0.load().data[name] }
    }

    /// Every colour, image and data name known.
    public static var names: (colors: [String], images: [String], data: [String]) {
        store.withLock { s in
            let c = s.load()
            return (c.colors.keys.sorted(), c.images.keys.sorted(), c.data.keys.sorted())
        }
    }

    /// Adds a directory holding RunwayAssets.json (or a RunwayAssets/ folder)
    /// to search, ahead of the bundle locations.
    public static func register(directory: URL) {
        store.withLock { s in
            s.extra.append(directory)
            s.catalog = nil
        }
    }

    // MARK: Loading

    struct ImageSet { var files: [ImageFile]; var template: Bool }
    struct Catalog {
        var colors: [String: (light: RGBA, dark: RGBA)] = [:]
        var images: [String: ImageSet] = [:]
        var data: [String: String] = [:]
    }

    struct Store {
        var extra: [URL] = []
        var catalog: Catalog?

        mutating func load() -> Catalog {
            if let catalog { return catalog }
            var c = Catalog()
            for dir in searchDirectories() { RunwayAssets.merge(dir, into: &c) }
            catalog = c
            return c
        }

        func searchDirectories() -> [URL] {
            var dirs: [URL] = []
            if let env = ProcessInfo.processInfo.environment["RUNWAY_ASSETS_PATH"] {
                #if os(Windows)
                let sep: Character = ";"
                #else
                let sep: Character = ":"
                #endif
                dirs += env.split(separator: sep).map { URL(fileURLWithPath: String($0)) }
            }
            dirs += extra
            if let r = Bundle.main.resourceURL { dirs.append(r) }
            let exeDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ".")).deletingLastPathComponent()
            dirs.append(exeDir)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: exeDir.path)) ?? []
            for e in entries.sorted() where e.hasSuffix(".resources") || e.hasSuffix(".bundle") {
                dirs.append(exeDir.appendingPathComponent(e))
                dirs.append(exeDir.appendingPathComponent(e).appendingPathComponent("Contents/Resources"))
            }
            var seen = Set<String>()
            return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
        }
    }

    static let store = Locked(Store())

    static func merge(_ dir: URL, into c: inout Catalog) {
        for candidate in [dir.appendingPathComponent("RunwayAssets/RunwayAssets.json"), dir.appendingPathComponent("RunwayAssets.json")] {
            guard let d = try? Data(contentsOf: candidate),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let base = candidate.deletingLastPathComponent()
            func rgba(_ v: Any?) -> RGBA? {
                guard let a = v as? [Any], a.count >= 3 else { return nil }
                let n = a.map { ($0 as? NSNumber)?.doubleValue ?? 0 }
                return RGBA(red: n[0], green: n[1], blue: n[2], alpha: n.count > 3 ? n[3] : 1)
            }
            for (name, v) in json["colors"] as? [String: Any] ?? [:] where c.colors[name] == nil {
                let d = v as? [String: Any] ?? [:]
                if let light = rgba(d["light"]) { c.colors[name] = (light, rgba(d["dark"]) ?? light) }
            }
            for (name, v) in json["images"] as? [String: Any] ?? [:] where c.images[name] == nil {
                let d = v as? [String: Any] ?? [:]
                var files: [ImageFile] = []
                for (scale, rel) in d["files"] as? [String: String] ?? [:] { files.append(ImageFile(scale: scale, dark: false, path: base.appendingPathComponent(rel).path)) }
                for (scale, rel) in d["dark"] as? [String: String] ?? [:] { files.append(ImageFile(scale: scale, dark: true, path: base.appendingPathComponent(rel).path)) }
                files.sort { ($0.dark ? 1 : 0, $0.scale) < ($1.dark ? 1 : 0, $1.scale) }
                c.images[name] = ImageSet(files: files, template: d["template"] as? Bool ?? false)
            }
            for (name, rel) in json["data"] as? [String: String] ?? [:] where c.data[name] == nil {
                c.data[name] = base.appendingPathComponent(rel).path
            }
            return
        }
    }

    /// A minimal lock-protected box (Mutex needs macOS 15 / newer runtimes).
    final class Locked<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()
        init(_ v: Value) { value = v }
        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.lock(); defer { lock.unlock() }
            return body(&value)
        }
    }
}
