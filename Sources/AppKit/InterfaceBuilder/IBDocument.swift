// Interface Builder documents: finding them in a bundle, parsing, and their
// localizations.
//
// Xcode compiles .xib/.storyboard into binary .nib files; Runway reads the
// source documents themselves (the build tool copies them into the app's
// resources, keeping Base.lproj and <lang>.lproj). A document format
// written by Xcode 12–16 for macOS ("MacOSX.Cocoa") is supported.
// Base internationalization: `<lang>.lproj/<Name>.strings` next to a Base
// document overrides its strings ("<objectID>.<property>" = "…").

import Foundation

public final class IBDocument: @unchecked Sendable {
    public enum Kind: Sendable { case xib, storyboard }

    public let kind: Kind
    public let name: String
    public let url: URL?
    public let root: IBElement
    /// Every element with an `id`, by id.
    public private(set) var elements: [String: IBElement] = [:]
    /// Localized strings: object id → property → string.
    var localizations: [String: [String: String]] = [:]

    public init(root: IBElement, name: String, url: URL?) throws {
        self.root = root
        self.name = name
        self.url = url
        guard root.name == "document" else { throw IBError.notADocument(name) }
        let type = root.attributes["type"] ?? ""
        kind = type.contains("Storyboard") ? .storyboard : .xib
        if let rt = root.attributes["targetRuntime"], !rt.hasPrefix("MacOSX") { throw IBError.unsupportedRuntime(name, rt) }
        for e in root.descendants() { if let id = e.attributes["id"] { elements[id] = e } }
    }

    public convenience init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let root = try IBXMLParser.parse(data)
        try self.init(root: root, name: url.deletingPathExtension().lastPathComponent, url: url)
        loadLocalizations()
    }

    public convenience init(data: Data, name: String = "") throws {
        try self.init(root: try IBXMLParser.parse(data), name: name, url: nil)
    }

    /// `<objects>` of a xib (its top level), nil for a storyboard.
    public var objects: IBElement? { root.child("objects") }
    public var scenes: [IBElement] { root.child("scenes")?.children("scene") ?? [] }
    public var initialViewControllerID: String? { root.attributes["initialViewController"] }

    /// The scene holding the object with this id.
    public func scene(containing id: String) -> IBElement? {
        var e = elements[id]
        while let x = e, x.name != "scene" { e = x.parent }
        return e
    }

    /// The controller (or other object) whose `storyboardIdentifier` is `identifier`.
    public func element(storyboardIdentifier identifier: String) -> IBElement? {
        for s in scenes {
            for o in s.child("objects")?.children ?? [] where o.attributes["storyboardIdentifier"] == identifier { return o }
        }
        return nil
    }

    func localized(_ id: String?, _ property: String) -> String? {
        guard let id else { return nil }
        return localizations[id]?[property]
    }

    /// Reads `<lang>.lproj/<name>.strings` for the preferred language, when
    /// the document is in Base.lproj.
    private func loadLocalizations() {
        guard let url, url.deletingLastPathComponent().lastPathComponent == "Base.lproj" else { return }
        let resources = url.deletingLastPathComponent().deletingLastPathComponent()
        for lang in IBDocument.preferredLanguages() {
            let strings = resources.appendingPathComponent("\(lang).lproj/\(name).strings")
            guard let text = (try? String(contentsOf: strings, encoding: .utf8)) ?? (try? String(contentsOf: strings, encoding: .utf16)) else { continue }
            for (k, v) in IBDocument.parseStrings(text) {
                guard let dot = k.firstIndex(of: ".") else { continue }
                localizations[String(k[..<dot]), default: [:]][String(k[k.index(after: dot)...])] = v
            }
            return
        }
    }

    static func preferredLanguages() -> [String] {
        var out: [String] = []
        let env = ProcessInfo.processInfo.environment
        for v in [env["LC_ALL"], env["LC_MESSAGES"], env["LANG"]].compactMap({ $0 }) where !v.isEmpty && v != "C" && v != "POSIX" {
            let code = v.split(separator: ".").first.map(String.init) ?? v
            out.append(code.replacingOccurrences(of: "_", with: "-"))
            if let lang = code.split(separator: "_").first { out.append(String(lang)) }
        }
        out += Locale.preferredLanguages
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// A `.strings` file's pairs (`"key" = "value";`, comments allowed).
    static func parseStrings(_ text: String) -> [(String, String)] {
        var out: [(String, String)] = []
        let s = Array(text.unicodeScalars)
        var i = 0
        func skip() {
            while i < s.count {
                if s[i].properties.isWhitespace { i += 1 }
                else if s[i] == "/", i + 1 < s.count, s[i + 1] == "*" {
                    i += 2
                    while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { i += 1 }
                    i += 2
                } else if s[i] == "/", i + 1 < s.count, s[i + 1] == "/" {
                    while i < s.count, s[i] != "\n" { i += 1 }
                } else { break }
            }
        }
        func string() -> String? {
            guard i < s.count, s[i] == "\"" else { return nil }
            i += 1
            var r = String.UnicodeScalarView()
            while i < s.count, s[i] != "\"" {
                if s[i] == "\\", i + 1 < s.count {
                    i += 1
                    switch s[i] {
                    case "n": r.append("\n")
                    case "t": r.append("\t")
                    case "r": r.append("\r")
                    case "U", "u":
                        var hex = ""
                        while hex.count < 4, i + 1 < s.count, s[i + 1].properties.isASCIIHexDigit { i += 1; hex.unicodeScalars.append(s[i]) }
                        if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { r.append(u) }
                    default: r.append(s[i])
                    }
                } else { r.append(s[i]) }
                i += 1
            }
            i += 1
            return String(r)
        }
        while i < s.count {
            skip()
            guard let k = string() else { break }
            skip()
            guard i < s.count, s[i] == "=" else { break }
            i += 1
            skip()
            guard let v = string() else { break }
            skip()
            if i < s.count, s[i] == ";" { i += 1 }
            out.append((k, v))
        }
        return out
    }

    // MARK: Finding documents

    private nonisolated(unsafe) static var cache: [String: IBDocument] = [:]
    private static let cacheLock = NSLock()

    /// The document named `name` (no extension) in `bundle`: a storyboard
    /// for `kind == .storyboard`, else a xib (or either for nil).
    public static func named(_ name: String, bundle: Bundle?, kind: Kind? = nil) throws -> IBDocument {
        let bundle = bundle ?? .main
        let exts: [String] = kind == .storyboard ? ["storyboard"] : kind == .xib ? ["xib"] : ["xib", "storyboard"]
        guard let url = locate(name, extensions: exts, bundle: bundle) else {
            if locate(name, extensions: ["nib", "storyboardc"], bundle: bundle) != nil { throw IBError.compiledOnly(name) }
            throw IBError.notFound(name)
        }
        cacheLock.lock()
        if let d = cache[url.path] { cacheLock.unlock(); return d }
        cacheLock.unlock()
        let d = try IBDocument(contentsOf: url)
        cacheLock.lock(); cache[url.path] = d; cacheLock.unlock()
        return d
    }

    /// Whether a document named `name` exists in `bundle`.
    public static func exists(_ name: String, bundle: Bundle?, kind: Kind? = nil) -> Bool {
        let exts: [String] = kind == .storyboard ? ["storyboard"] : kind == .xib ? ["xib"] : ["xib", "storyboard"]
        return locate(name, extensions: exts, bundle: bundle ?? .main) != nil
    }

    /// Searches the bundle's resources: the preferred localizations, Base,
    /// English, the top level, then SwiftPM resource bundles beside it.
    static func locate(_ name: String, extensions: [String], bundle: Bundle) -> URL? {
        var roots: [URL] = []
        for p in [bundle.resourcePath, bundle.bundlePath].compactMap({ $0 }) {
            let u = URL(fileURLWithPath: p)
            if !roots.contains(u) { roots.append(u) }
        }
        // corelibs reads a flat executable directory as the main bundle.
        if let exe = bundle.executableURL?.deletingLastPathComponent(), !roots.contains(exe) { roots.append(exe) }
        let fm = FileManager.default
        var dirs: [URL] = []
        let langs = preferredLanguages() + bundle.preferredLocalizations + ["Base", "en", "English"]
        for r in roots {
            for l in langs { dirs.append(r.appendingPathComponent("\(l).lproj")) }
            dirs.append(r)
            dirs.append(r.appendingPathComponent("Resources"))
            dirs.append(r.appendingPathComponent("Contents/Resources"))
        }
        for d in dirs {
            for e in extensions {
                let u = d.appendingPathComponent("\(name).\(e)")
                if fm.fileExists(atPath: u.path) { return u }
            }
        }
        // SwiftPM resource bundles (<Package>_<Target>.resources) and others.
        for r in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: r.path) else { continue }
            for item in items.sorted() where item.hasSuffix(".resources") || item.hasSuffix(".bundle") {
                if let b = Bundle(path: r.appendingPathComponent(item).path), b.bundlePath != bundle.bundlePath,
                   let u = locate(name, extensions: extensions, bundle: b) { return u }
            }
        }
        return nil
    }
}

public enum IBError: Error, CustomStringConvertible {
    case notFound(String)
    case compiledOnly(String)
    case notADocument(String)
    case unsupportedRuntime(String, String)
    case noSuchIdentifier(String)

    public var description: String {
        switch self {
        case .notFound(let n): return "no Interface Builder document named \(n) in the bundle"
        case .compiledOnly(let n): return "\(n) is only in compiled form (.nib); Runway reads .xib/.storyboard sources"
        case .notADocument(let n): return "\(n) isn't an Interface Builder document"
        case .unsupportedRuntime(let n, let rt): return "\(n) targets \(rt), not macOS"
        case .noSuchIdentifier(let i): return "no controller with identifier \(i)"
        }
    }
}
