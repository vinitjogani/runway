// UniformTypeIdentifiers for Linux and Windows: Apple's type tree for the
// common types, with filename extensions and MIME types; unknown
// extensions are looked up in the freedesktop shared-mime-info database
// (/usr/share/mime/globs2) where it exists.

import Foundation

public struct UTTagClass: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let filenameExtension = UTTagClass(rawValue: "public.filename-extension")
    public static let mimeType = UTTagClass(rawValue: "public.mime-type")
}

public struct UTType: Hashable, Sendable, Codable, CustomStringConvertible {
    public let identifier: String

    struct Info: Sendable {
        let parents: [String]
        let extensions: [String]
        let mimes: [String]
        let name: String
    }

    nonisolated(unsafe) static var registry: [String: Info] = {
        var r: [String: Info] = [:]
        func add(_ id: String, _ parents: [String], _ exts: [String] = [], _ mimes: [String] = [], _ name: String = "") {
            r[id] = Info(parents: parents, extensions: exts, mimes: mimes, name: name.isEmpty ? id : name)
        }
        add("public.item", [])
        add("public.content", [])
        add("public.data", ["public.item"], [], ["application/octet-stream"], "data")
        add("public.directory", ["public.item"])
        add("public.folder", ["public.directory"], [], ["inode/directory"], "folder")
        add("com.apple.package", ["public.directory"])
        add("public.composite-content", ["public.content"])
        add("public.archive", ["public.data"])
        add("public.text", ["public.data", "public.content"], [], ["text/plain"], "text")
        add("public.plain-text", ["public.text"], ["txt", "text"], ["text/plain"], "plain text")
        add("public.utf8-plain-text", ["public.plain-text"], [], ["text/plain;charset=utf-8"], "UTF-8 plain text")
        add("public.utf16-plain-text", ["public.plain-text"])
        add("public.rtf", ["public.text"], ["rtf"], ["text/rtf"], "rich text")
        add("public.html", ["public.text"], ["html", "htm"], ["text/html"], "HTML")
        add("public.xml", ["public.text"], ["xml"], ["application/xml", "text/xml"], "XML")
        add("public.json", ["public.text"], ["json"], ["application/json"], "JSON")
        add("public.yaml", ["public.text"], ["yaml", "yml"], ["application/x-yaml"], "YAML")
        add("public.comma-separated-values-text", ["public.text"], ["csv"], ["text/csv"], "CSV")
        add("public.tab-separated-values-text", ["public.text"], ["tsv"], ["text/tab-separated-values"], "TSV")
        add("public.source-code", ["public.plain-text"])
        add("public.swift-source", ["public.source-code"], ["swift"], ["text/x-swift"])
        add("public.shell-script", ["public.source-code"], ["sh"], ["application/x-sh"])
        add("com.netscape.javascript-source", ["public.source-code"], ["js", "mjs"], ["text/javascript"])
        add("net.daringfireball.markdown", ["public.plain-text"], ["md", "markdown", "mdown"], ["text/markdown"], "Markdown")
        add("public.url", ["public.data"], [], [], "URL")
        add("public.file-url", ["public.url"], [], [], "file URL")
        add("public.image", ["public.data", "public.content"], [], ["image/*"], "image")
        add("public.png", ["public.image"], ["png"], ["image/png"], "PNG image")
        add("public.jpeg", ["public.image"], ["jpg", "jpeg", "jpe"], ["image/jpeg"], "JPEG image")
        add("com.compuserve.gif", ["public.image"], ["gif"], ["image/gif"], "GIF image")
        add("org.webmproject.webp", ["public.image"], ["webp"], ["image/webp"], "WebP image")
        add("public.heic", ["public.image"], ["heic"], ["image/heic"], "HEIC image")
        add("public.heif", ["public.image"], ["heif"], ["image/heif"], "HEIF image")
        add("public.tiff", ["public.image"], ["tif", "tiff"], ["image/tiff"], "TIFF image")
        add("com.microsoft.bmp", ["public.image"], ["bmp"], ["image/bmp"], "BMP image")
        add("com.microsoft.ico", ["public.image"], ["ico"], ["image/vnd.microsoft.icon"], "icon")
        add("com.apple.icns", ["public.image"], ["icns"], ["image/icns"], "Apple icon")
        add("public.svg-image", ["public.image"], ["svg"], ["image/svg+xml"], "SVG image")
        add("public.avif", ["public.image"], ["avif"], ["image/avif"], "AVIF image")
        add("com.adobe.pdf", ["public.data", "public.composite-content"], ["pdf"], ["application/pdf"], "PDF document")
        add("public.audiovisual-content", ["public.data", "public.content"])
        add("public.movie", ["public.audiovisual-content"], [], ["video/*"], "movie")
        add("public.video", ["public.movie"])
        add("public.audio", ["public.audiovisual-content"], [], ["audio/*"], "audio")
        add("public.mpeg-4", ["public.movie"], ["mp4", "m4v"], ["video/mp4"], "MPEG-4 movie")
        add("com.apple.quicktime-movie", ["public.movie"], ["mov", "qt"], ["video/quicktime"], "QuickTime movie")
        add("org.webmproject.webm", ["public.movie"], ["webm"], ["video/webm"], "WebM movie")
        add("public.avi", ["public.movie"], ["avi"], ["video/x-msvideo"], "AVI movie")
        add("org.matroska.mkv", ["public.movie"], ["mkv"], ["video/x-matroska"], "Matroska movie")
        add("public.mp3", ["public.audio"], ["mp3"], ["audio/mpeg"], "MP3 audio")
        add("com.microsoft.waveform-audio", ["public.audio"], ["wav", "wave"], ["audio/wav"], "WAVE audio")
        add("public.aiff-audio", ["public.audio"], ["aiff", "aif"], ["audio/aiff"], "AIFF audio")
        add("public.mpeg-4-audio", ["public.audio"], ["m4a"], ["audio/mp4"], "MPEG-4 audio")
        add("org.xiph.flac", ["public.audio"], ["flac"], ["audio/flac"], "FLAC audio")
        add("org.xiph.ogg-audio", ["public.audio"], ["ogg", "oga"], ["audio/ogg"], "Ogg audio")
        add("public.zip-archive", ["public.archive"], ["zip"], ["application/zip"], "ZIP archive")
        add("org.gnu.gnu-zip-archive", ["public.archive"], ["gz", "gzip"], ["application/gzip"], "gzip archive")
        add("public.tar-archive", ["public.archive"], ["tar"], ["application/x-tar"], "tar archive")
        add("com.apple.application", ["public.data"])
        add("com.apple.application-bundle", ["com.apple.application", "com.apple.package"], ["app"])
        add("public.executable", ["public.data"])
        add("public.font", ["public.data"], ["ttf", "otf"], ["font/ttf"], "font")
        add("public.vcard", ["public.text"], ["vcf"], ["text/vcard"], "vCard")
        add("public.calendar-event", ["public.data"], ["ics"], ["text/calendar"])
        add("public.log", ["public.plain-text"], ["log"], ["text/x-log"])
        return r
    }()

    init(_id identifier: String) { self.identifier = identifier }
    /// Fails for identifiers that aren't reverse-DNS.
    public init?(_ identifier: String) {
        guard UTType.registry[identifier] != nil || identifier.contains(".") else { return nil }
        self.identifier = identifier
    }

    /// Declares a type the app exports (as its Info.plist would).
    public init(exportedAs identifier: String, conformingTo parent: UTType? = nil) {
        self.identifier = identifier
        if UTType.registry[identifier] == nil {
            UTType.registry[identifier] = Info(parents: [parent?.identifier ?? "public.data"], extensions: [], mimes: [], name: identifier)
        }
    }
    public init(importedAs identifier: String, conformingTo parent: UTType? = nil) { self.init(exportedAs: identifier, conformingTo: parent) }

    public init?(filenameExtension ext: String, conformingTo parent: UTType = .data) {
        let e = ext.lowercased()
        if let hit = UTType.registry.first(where: { $0.value.extensions.contains(e) && UTType(_id: $0.key).conforms(to: parent) }) {
            identifier = hit.key
            return
        }
        // The platform's MIME database knows more extensions.
        if let mime = UTType.systemMIME(forExtension: e) {
            let id = "dyn.mime." + mime
            UTType.registry[id] = Info(parents: [UTType.parentForMIME(mime)], extensions: [e], mimes: [mime], name: mime)
            if UTType(_id: id).conforms(to: parent) { identifier = id; return }
        }
        return nil
    }

    public init?(mimeType: String, conformingTo parent: UTType = .data) {
        let m = mimeType.lowercased()
        guard let hit = UTType.registry.first(where: { $0.value.mimes.contains(m) && UTType(_id: $0.key).conforms(to: parent) }) else { return nil }
        identifier = hit.key
    }

    public init?(tag: String, tagClass: UTTagClass, conformingTo parent: UTType?) {
        switch tagClass {
        case .filenameExtension: self.init(filenameExtension: tag, conformingTo: parent ?? .data)
        case .mimeType: self.init(mimeType: tag, conformingTo: parent ?? .data)
        default: return nil
        }
    }

    var info: Info? { UTType.registry[identifier] }
    public var preferredFilenameExtension: String? { info?.extensions.first }
    public var preferredMIMEType: String? { info?.mimes.first }
    public var localizedDescription: String? { info?.name }
    public var tags: [UTTagClass: [String]] {
        guard let i = info else { return [:] }
        return [.filenameExtension: i.extensions, .mimeType: i.mimes]
    }
    public var isDeclared: Bool { info != nil }
    public var isDynamic: Bool { identifier.hasPrefix("dyn.") }
    public var isPublic: Bool { identifier.hasPrefix("public.") }
    public var supertypes: Set<UTType> {
        var out = Set<UTType>()
        var queue = info?.parents ?? []
        while let p = queue.popLast() {
            if out.insert(UTType(_id: p)).inserted { queue += UTType.registry[p]?.parents ?? [] }
        }
        return out
    }

    public func conforms(to other: UTType) -> Bool { self == other || supertypes.contains(other) }
    public func isSupertype(of other: UTType) -> Bool { other.conforms(to: self) }
    public func isSubtype(of other: UTType) -> Bool { conforms(to: other) }

    public var description: String { identifier }

    public static func types(tag: String, tagClass: UTTagClass, conformingTo parent: UTType?) -> [UTType] {
        UTType(tag: tag, tagClass: tagClass, conformingTo: parent).map { [$0] } ?? []
    }

    // MARK: The platform's MIME database

    nonisolated(unsafe) static var globs: [String: String]? = nil
    static func systemMIME(forExtension ext: String) -> String? {
        if globs == nil {
            var g: [String: String] = [:]
            for path in ["/usr/share/mime/globs2", "/usr/local/share/mime/globs2"] {
                guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                for line in s.split(separator: "\n") where !line.hasPrefix("#") {
                    // weight:mime:glob
                    let parts = line.split(separator: ":", maxSplits: 2)
                    guard parts.count == 3, parts[2].hasPrefix("*.") else { continue }
                    let e = String(parts[2].dropFirst(2)).lowercased()
                    if g[e] == nil { g[e] = String(parts[1]) }
                }
            }
            globs = g
        }
        return globs?[ext]
    }

    static func parentForMIME(_ m: String) -> String {
        if m.hasPrefix("image/") { return "public.image" }
        if m.hasPrefix("video/") { return "public.movie" }
        if m.hasPrefix("audio/") { return "public.audio" }
        if m.hasPrefix("text/") { return "public.text" }
        return "public.data"
    }

    // MARK: Well-known types

    public static let item = UTType(_id: "public.item")
    public static let content = UTType(_id: "public.content")
    public static let compositeContent = UTType(_id: "public.composite-content")
    public static let data = UTType(_id: "public.data")
    public static let directory = UTType(_id: "public.directory")
    public static let folder = UTType(_id: "public.folder")
    public static let package = UTType(_id: "com.apple.package")
    public static let archive = UTType(_id: "public.archive")
    public static let text = UTType(_id: "public.text")
    public static let plainText = UTType(_id: "public.plain-text")
    public static let utf8PlainText = UTType(_id: "public.utf8-plain-text")
    public static let utf16PlainText = UTType(_id: "public.utf16-plain-text")
    public static let rtf = UTType(_id: "public.rtf")
    public static let html = UTType(_id: "public.html")
    public static let xml = UTType(_id: "public.xml")
    public static let json = UTType(_id: "public.json")
    public static let yaml = UTType(_id: "public.yaml")
    public static let commaSeparatedText = UTType(_id: "public.comma-separated-values-text")
    public static let tabSeparatedText = UTType(_id: "public.tab-separated-values-text")
    public static let sourceCode = UTType(_id: "public.source-code")
    public static let swiftSource = UTType(_id: "public.swift-source")
    public static let shellScript = UTType(_id: "public.shell-script")
    public static let javaScript = UTType(_id: "com.netscape.javascript-source")
    public static let url = UTType(_id: "public.url")
    public static let fileURL = UTType(_id: "public.file-url")
    public static let image = UTType(_id: "public.image")
    public static let png = UTType(_id: "public.png")
    public static let jpeg = UTType(_id: "public.jpeg")
    public static let gif = UTType(_id: "com.compuserve.gif")
    public static let webP = UTType(_id: "org.webmproject.webp")
    public static let heic = UTType(_id: "public.heic")
    public static let heif = UTType(_id: "public.heif")
    public static let tiff = UTType(_id: "public.tiff")
    public static let bmp = UTType(_id: "com.microsoft.bmp")
    public static let ico = UTType(_id: "com.microsoft.ico")
    public static let icns = UTType(_id: "com.apple.icns")
    public static let svg = UTType(_id: "public.svg-image")
    public static let pdf = UTType(_id: "com.adobe.pdf")
    public static let audiovisualContent = UTType(_id: "public.audiovisual-content")
    public static let movie = UTType(_id: "public.movie")
    public static let video = UTType(_id: "public.video")
    public static let audio = UTType(_id: "public.audio")
    public static let mpeg4Movie = UTType(_id: "public.mpeg-4")
    public static let quickTimeMovie = UTType(_id: "com.apple.quicktime-movie")
    public static let avi = UTType(_id: "public.avi")
    public static let mp3 = UTType(_id: "public.mp3")
    public static let wav = UTType(_id: "com.microsoft.waveform-audio")
    public static let aiff = UTType(_id: "public.aiff-audio")
    public static let mpeg4Audio = UTType(_id: "public.mpeg-4-audio")
    public static let zip = UTType(_id: "public.zip-archive")
    public static let gzip = UTType(_id: "org.gnu.gnu-zip-archive")
    public static let application = UTType(_id: "com.apple.application")
    public static let applicationBundle = UTType(_id: "com.apple.application-bundle")
    public static let executable = UTType(_id: "public.executable")
    public static let font = UTType(_id: "public.font")
    public static let vCard = UTType(_id: "public.vcard")
    public static let log = UTType(_id: "public.log")
}

extension URL {
    public var uniformType: UTType? { UTType(filenameExtension: pathExtension) }
}

/// `URLResourceValues.contentType` stand-in.
extension UTType {
    public static func of(_ url: URL) -> UTType? {
        var dir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &dir), dir.boolValue { return .folder }
        return UTType(filenameExtension: url.pathExtension)
    }
}

// MARK: URL resource values

extension URLResourceKey {
    /// The file's type as a UTType (`URLResourceValues.contentType`).
    public static let contentTypeKey = URLResourceKey(rawValue: "NSURLContentTypeKey")
}
extension URLResourceValues {
    /// The file's type, when it was asked for with `.contentTypeKey` and
    /// the resource value was supplied.
    public var contentType: UTType? { allValues[.contentTypeKey] as? UTType }
}
