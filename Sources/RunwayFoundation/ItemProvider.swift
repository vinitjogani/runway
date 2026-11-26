// NSItemProvider (Foundation's on Apple platforms; corelibs lacks it): the
// promise of data in one or more representations, handed between a drag
// source and a drop target, a share sheet or a service. Representations are
// registered by type identifier (UTI) with a load handler and loaded
// asynchronously; strings, URLs, data and file URLs are understood as the
// standard types (`public.utf8-plain-text`, `public.url`, `public.file-url`).

import Foundation

public enum NSItemProviderRepresentationVisibility: Int, Sendable {
    case all = 0, team = 1, group = 2, ownProcess = 3
}

public struct NSItemProviderFileOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let openInPlace = NSItemProviderFileOptions(rawValue: 1)
}

/// A class whose instances can be written to an item provider.
public protocol NSItemProviderWriting: AnyObject {
    static var writableTypeIdentifiersForItemProvider: [String] { get }
    func loadData(withTypeIdentifier typeIdentifier: String, forItemProviderCompletionHandler completionHandler: @escaping @Sendable (Data?, Error?) -> Void) -> Progress?
}
/// A class whose instances can be made from an item provider's data.
public protocol NSItemProviderReading: AnyObject {
    static var readableTypeIdentifiersForItemProvider: [String] { get }
    static func object(withItemProviderData data: Data, typeIdentifier: String) throws -> Self
}

public let NSItemProviderErrorDomain = "NSItemProviderErrorDomain"
public let NSItemProviderPreferredImageSizeKey = "NSItemProviderPreferredImageSizeKey"

open class NSItemProvider: NSObject, NSCopying, @unchecked Sendable {
    public typealias CompletionHandler = (Any?, Error?) -> Void
    public typealias LoadHandler = (@escaping CompletionHandler, AnyClass?, [AnyHashable: Any]?) -> Void

    public enum ErrorCode: Int, Sendable {
        case unknownError = -1, itemUnavailableError = -1000, unexpectedValueClassError = -1100, unavailableCoercionError = -1200
    }
    public static let errorDomain = NSItemProviderErrorDomain

    /// One registered representation.
    struct Representation {
        let type: String
        let visibility: NSItemProviderRepresentationVisibility
        let fileOptions: NSItemProviderFileOptions
        /// Produces the data (or file) for the type.
        let load: (@escaping (Payload?, Error?) -> Void) -> Progress?
    }
    enum Payload {
        case data(Data)
        case file(URL, inPlace: Bool)
        case item(Any)
    }

    private let lock = NSLock()
    private var representations: [Representation] = []
    open var suggestedName: String?

    public override init() { super.init() }

    /// A provider for `item` as `typeIdentifier` (a string, URL, data, or
    /// any value a reader of that type expects).
    public convenience init(item: Any?, typeIdentifier: String?) {
        self.init()
        guard let item else { return }
        let type = typeIdentifier ?? Self.standardType(of: item)
        if let type { registerValue(item, as: type) }
    }

    /// A provider for a file: its contents by its type, and the file itself.
    public convenience init?(contentsOf fileURL: URL) {
        guard fileURL.isFileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        self.init()
        suggestedName = fileURL.lastPathComponent
        let type = Self.typeIdentifier(forPathExtension: fileURL.pathExtension)
        registerFileRepresentation(forTypeIdentifier: type, fileOptions: [], visibility: .all) { done in
            done(fileURL, false, nil)
            return nil
        }
        registerValue(fileURL, as: Self.fileURLType)
    }

    public convenience init(object: NSItemProviderWriting) {
        self.init()
        registerObject(object, visibility: .all)
    }

    /// A provider for a string, URL or data value.
    public convenience init(object: String) { self.init(item: object, typeIdentifier: Self.plainTextType) }
    public convenience init(object: URL) { self.init(item: object, typeIdentifier: object.isFileURL ? Self.fileURLType : Self.urlType) }

    open func copy(with zone: NSZone? = nil) -> Any {
        let c = NSItemProvider()
        c.representations = lock.withLock { representations }
        c.suggestedName = suggestedName
        return c
    }

    // MARK: Registering

    open func registerDataRepresentation(forTypeIdentifier typeIdentifier: String, visibility: NSItemProviderRepresentationVisibility,
                                         loadHandler: @escaping (@escaping (Data?, Error?) -> Void) -> Progress?) {
        add(Representation(type: typeIdentifier, visibility: visibility, fileOptions: []) { done in
            loadHandler { data, error in done(data.map { .data($0) }, error) }
        })
    }

    open func registerFileRepresentation(forTypeIdentifier typeIdentifier: String, fileOptions: NSItemProviderFileOptions = [],
                                         visibility: NSItemProviderRepresentationVisibility,
                                         loadHandler: @escaping (@escaping (URL?, Bool, Error?) -> Void) -> Progress?) {
        add(Representation(type: typeIdentifier, visibility: visibility, fileOptions: fileOptions) { done in
            loadHandler { url, inPlace, error in done(url.map { .file($0, inPlace: inPlace) }, error) }
        })
    }

    open func registerObject(_ object: NSItemProviderWriting, visibility: NSItemProviderRepresentationVisibility) {
        for type in Swift.type(of: object).writableTypeIdentifiersForItemProvider {
            registerDataRepresentation(forTypeIdentifier: type, visibility: visibility) { done in
                object.loadData(withTypeIdentifier: type) { data, error in done(data, error) }
            }
        }
    }

    open func registerObject(ofClass aClass: NSItemProviderWriting.Type, visibility: NSItemProviderRepresentationVisibility,
                             loadHandler: @escaping (@escaping (NSItemProviderWriting?, Error?) -> Void) -> Progress?) {
        for type in aClass.writableTypeIdentifiersForItemProvider {
            registerDataRepresentation(forTypeIdentifier: type, visibility: visibility) { done in
                loadHandler { object, error in
                    guard let object else { done(nil, error); return }
                    _ = object.loadData(withTypeIdentifier: type) { data, error in done(data, error) }
                }
            }
        }
    }

    /// The older, coercing registration: the handler is asked for the item.
    open func registerItem(forTypeIdentifier typeIdentifier: String, loadHandler: @escaping LoadHandler) {
        add(Representation(type: typeIdentifier, visibility: .all, fileOptions: []) { done in
            loadHandler({ item, error in done(item.map { .item($0) }, error) }, nil, nil)
            return nil
        })
    }

    private func add(_ r: Representation) { lock.withLock { representations.append(r) } }

    private func registerValue(_ value: Any, as type: String) {
        add(Representation(type: type, visibility: .all, fileOptions: []) { done in
            done(.item(value), nil)
            return nil
        })
    }

    /// Runway: the text and URLs this provider hands over without waiting
    /// (what a drag out of the app carries); loaders that answer later are skipped.
    public func _runwayImmediateContents() -> (strings: [String], urls: [URL]) {
        var strings: [String] = [], urls: [URL] = []
        for r in lock.withLock({ representations }) {
            var got: Payload?
            _ = r.load { p, _ in got = p }
            switch got {
            case let .item(v as String): strings.append(v)
            case let .item(v as NSString): strings.append(v as String)
            case let .item(v as URL): urls.append(v)
            case let .file(u, _): urls.append(u)
            case let .data(d) where Self.textTypes.contains(where: { Self.type(r.type, conformsTo: $0) }):
                strings.append(String(decoding: d, as: UTF8.self))
            case let .data(d) where Self.type(r.type, conformsTo: Self.urlType):
                if let u = URL(string: String(decoding: d, as: UTF8.self)) { urls.append(u) }
            default: break
            }
        }
        var seenURLs = Set<URL>(), seenStrings = Set<String>()
        return (strings.filter { seenStrings.insert($0).inserted }, urls.filter { seenURLs.insert($0).inserted })
    }

    // MARK: Asking

    open var registeredTypeIdentifiers: [String] {
        var seen = Set<String>()
        return lock.withLock { representations }.map(\.type).filter { seen.insert($0).inserted }
    }
    open func registeredTypeIdentifiers(fileOptions: NSItemProviderFileOptions) -> [String] {
        var seen = Set<String>()
        return lock.withLock { representations }.filter { $0.fileOptions.isSuperset(of: fileOptions) }.map(\.type).filter { seen.insert($0).inserted }
    }
    open func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool { representation(conformingTo: typeIdentifier) != nil }
    open func hasRepresentationConforming(toTypeIdentifier typeIdentifier: String, fileOptions: NSItemProviderFileOptions = []) -> Bool {
        representation(conformingTo: typeIdentifier, fileOptions: fileOptions) != nil
    }

    func representation(conformingTo type: String, fileOptions: NSItemProviderFileOptions = []) -> Representation? {
        let all = lock.withLock { representations }.filter { $0.fileOptions.isSuperset(of: fileOptions) }
        return all.first { $0.type == type } ?? all.first { Self.type($0.type, conformsTo: type) }
    }

    // MARK: Loading

    @discardableResult
    open func loadDataRepresentation(forTypeIdentifier typeIdentifier: String,
                                     completionHandler: @escaping @Sendable (Data?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let r = representation(conformingTo: typeIdentifier) else {
            completionHandler(nil, Self.error(.unavailableCoercionError, typeIdentifier))
            return progress
        }
        let child = r.load { payload, error in
            progress.completedUnitCount = 1
            switch payload {
            case let .data(d)?: completionHandler(d, nil)
            case let .file(url, _)?:
                do { completionHandler(try Data(contentsOf: url), nil) } catch { completionHandler(nil, error) }
            case let .item(v)?:
                if let d = Self.data(from: v, type: typeIdentifier) { completionHandler(d, nil) } else {
                    completionHandler(nil, Self.error(.unexpectedValueClassError, typeIdentifier))
                }
            case nil: completionHandler(nil, error ?? Self.error(.itemUnavailableError, typeIdentifier))
            }
        }
        if let child { progress.addChild(child, withPendingUnitCount: 0) }
        return progress
    }

    /// Loads the representation as a file: a temporary copy that's removed
    /// when the handler returns (as on Apple platforms).
    @discardableResult
    open func loadFileRepresentation(forTypeIdentifier typeIdentifier: String,
                                     completionHandler: @escaping @Sendable (URL?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let r = representation(conformingTo: typeIdentifier) else {
            completionHandler(nil, Self.error(.unavailableCoercionError, typeIdentifier))
            return progress
        }
        let name = suggestedName
        let child = r.load { payload, error in
            progress.completedUnitCount = 1
            do {
                switch payload {
                case let .file(url, _)?:
                    let tmp = try Self.temporaryCopy(of: url, name: url.lastPathComponent)
                    completionHandler(tmp, nil)
                    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
                case let .data(d)?:
                    let tmp = try Self.temporaryFile(d, name: name, type: typeIdentifier)
                    completionHandler(tmp, nil)
                    try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
                case let .item(v)?:
                    if let url = v as? URL, url.isFileURL {
                        let tmp = try Self.temporaryCopy(of: url, name: url.lastPathComponent)
                        completionHandler(tmp, nil)
                        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
                    } else if let d = Self.data(from: v, type: typeIdentifier) {
                        let tmp = try Self.temporaryFile(d, name: name, type: typeIdentifier)
                        completionHandler(tmp, nil)
                        try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())
                    } else {
                        completionHandler(nil, Self.error(.unexpectedValueClassError, typeIdentifier))
                    }
                case nil: completionHandler(nil, error ?? Self.error(.itemUnavailableError, typeIdentifier))
                }
            } catch {
                completionHandler(nil, error)
            }
        }
        if let child { progress.addChild(child, withPendingUnitCount: 0) }
        return progress
    }

    @discardableResult
    open func loadInPlaceFileRepresentation(forTypeIdentifier typeIdentifier: String,
                                            completionHandler: @escaping @Sendable (URL?, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        guard let r = representation(conformingTo: typeIdentifier) else {
            completionHandler(nil, false, Self.error(.unavailableCoercionError, typeIdentifier))
            return progress
        }
        let name = suggestedName
        let child = r.load { payload, error in
            progress.completedUnitCount = 1
            switch payload {
            case let .file(url, inPlace)?: completionHandler(url, inPlace, nil)
            case let .item(v)? where (v as? URL)?.isFileURL == true: completionHandler(v as? URL, true, nil)
            case let .data(d)?:
                do { completionHandler(try Self.temporaryFile(d, name: name, type: typeIdentifier), false, nil) } catch { completionHandler(nil, false, error) }
            case .item?: completionHandler(nil, false, Self.error(.unexpectedValueClassError, typeIdentifier))
            case nil: completionHandler(nil, false, error ?? Self.error(.itemUnavailableError, typeIdentifier))
            }
        }
        if let child { progress.addChild(child, withPendingUnitCount: 0) }
        return progress
    }

    /// The item for `typeIdentifier`: a URL for URL types, a string for
    /// text, else the data (or whatever the registered handler gave).
    open func loadItem(forTypeIdentifier typeIdentifier: String, options: [AnyHashable: Any]? = nil,
                       completionHandler: CompletionHandler? = nil) {
        guard let r = representation(conformingTo: typeIdentifier) else {
            completionHandler?(nil, Self.error(.unavailableCoercionError, typeIdentifier))
            return
        }
        _ = r.load { payload, error in
            switch payload {
            case let .item(v)?: completionHandler?(v, nil)
            case let .file(url, _)?: completionHandler?(url, nil)
            case let .data(d)?: completionHandler?(Self.value(from: d, type: typeIdentifier), nil)
            case nil: completionHandler?(nil, error ?? Self.error(.itemUnavailableError, typeIdentifier))
            }
        }
    }

    // MARK: Objects

    open func canLoadObject(ofClass aClass: NSItemProviderReading.Type) -> Bool {
        aClass.readableTypeIdentifiersForItemProvider.contains { hasItemConformingToTypeIdentifier($0) }
    }
    @discardableResult
    open func loadObject(ofClass aClass: NSItemProviderReading.Type,
                         completionHandler: @escaping @Sendable (NSItemProviderReading?, Error?) -> Void) -> Progress {
        guard let type = aClass.readableTypeIdentifiersForItemProvider.first(where: { hasItemConformingToTypeIdentifier($0) }) else {
            completionHandler(nil, Self.error(.unavailableCoercionError, aClass.readableTypeIdentifiersForItemProvider.first ?? ""))
            return Progress(totalUnitCount: 1)
        }
        nonisolated(unsafe) let reader = aClass
        return loadDataRepresentation(forTypeIdentifier: type) { data, error in
            guard let data else { completionHandler(nil, error); return }
            do { completionHandler(try reader.object(withItemProviderData: data, typeIdentifier: type), nil) } catch { completionHandler(nil, error) }
        }
    }

    // Swift value types (the overlay's `_ObjectiveCBridgeable` loading).
    public func canLoadObject(ofClass: String.Type) -> Bool { Self.textTypes.contains { hasItemConformingToTypeIdentifier($0) } }
    public func canLoadObject(ofClass: URL.Type) -> Bool { [Self.urlType, Self.fileURLType].contains { hasItemConformingToTypeIdentifier($0) } }

    @discardableResult
    public func loadObject(ofClass: String.Type, completionHandler: @escaping @Sendable (String?, Error?) -> Void) -> Progress {
        guard let type = Self.textTypes.first(where: { hasItemConformingToTypeIdentifier($0) }) else {
            completionHandler(nil, Self.error(.unavailableCoercionError, Self.plainTextType))
            return Progress(totalUnitCount: 1)
        }
        return loadDataRepresentation(forTypeIdentifier: type) { data, error in
            completionHandler(data.flatMap { String(data: $0, encoding: .utf8) }, data == nil ? error : nil)
        }
    }

    @discardableResult
    public func loadObject(ofClass: URL.Type, completionHandler: @escaping @Sendable (URL?, Error?) -> Void) -> Progress {
        guard let type = [Self.fileURLType, Self.urlType].first(where: { hasItemConformingToTypeIdentifier($0) }) else {
            completionHandler(nil, Self.error(.unavailableCoercionError, Self.urlType))
            return Progress(totalUnitCount: 1)
        }
        return loadDataRepresentation(forTypeIdentifier: type) { data, error in
            let url = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            completionHandler(url, url == nil ? (error ?? Self.error(.unexpectedValueClassError, type)) : nil)
        }
    }

    // MARK: Types

    public static let plainTextType = "public.utf8-plain-text"
    public static let urlType = "public.url"
    public static let fileURLType = "public.file-url"
    static let textTypes = ["public.utf8-plain-text", "public.plain-text", "public.text", "public.utf16-plain-text"]

    /// The parents of the standard types (Apple's conformance tree, the
    /// part item providers meet).
    static let parents: [String: [String]] = [
        "public.utf8-plain-text": ["public.plain-text"], "public.utf16-plain-text": ["public.plain-text"],
        "public.plain-text": ["public.text"], "public.html": ["public.text"], "public.rtf": ["public.text"],
        "public.text": ["public.data", "public.content"], "public.file-url": ["public.url"], "public.url": ["public.data"],
        "public.png": ["public.image"], "public.jpeg": ["public.image"], "public.tiff": ["public.image"], "public.heic": ["public.image"],
        "com.compuserve.gif": ["public.image"], "public.image": ["public.data", "public.content"],
        "public.mpeg-4": ["public.movie"], "com.apple.quicktime-movie": ["public.movie"], "public.movie": ["public.audiovisual-content"],
        "public.mp3": ["public.audio"], "com.microsoft.waveform-audio": ["public.audio"], "public.mpeg-4-audio": ["public.audio"],
        "public.audio": ["public.audiovisual-content"], "public.audiovisual-content": ["public.data", "public.content"],
        "com.adobe.pdf": ["public.data", "public.composite-content"], "public.json": ["public.text"],
        "net.daringfireball.markdown": ["public.plain-text"], "public.content": [], "public.data": ["public.item"],
    ]
    static func type(_ type: String, conformsTo target: String) -> Bool {
        if type == target || target == "public.item" { return true }
        var queue = parents[type] ?? [], seen = Set<String>()
        while let t = queue.popLast() {
            if t == target { return true }
            if seen.insert(t).inserted { queue += parents[t] ?? [] }
        }
        return false
    }
    static func typeIdentifier(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "txt", "text": "public.utf8-plain-text"
        case "md", "markdown": "net.daringfireball.markdown"
        case "html", "htm": "public.html"
        case "rtf": "public.rtf"
        case "json": "public.json"
        case "png": "public.png"
        case "jpg", "jpeg": "public.jpeg"
        case "tif", "tiff": "public.tiff"
        case "gif": "com.compuserve.gif"
        case "heic": "public.heic"
        case "pdf": "com.adobe.pdf"
        case "mp4", "m4v": "public.mpeg-4"
        case "mov": "com.apple.quicktime-movie"
        case "mp3": "public.mp3"
        case "wav": "com.microsoft.waveform-audio"
        case "m4a": "public.mpeg-4-audio"
        default: "public.data"
        }
    }
    static func standardType(of item: Any) -> String? {
        switch item {
        case is String, is NSString: plainTextType
        case let u as URL: u.isFileURL ? fileURLType : urlType
        case let u as NSURL: u.isFileURL ? fileURLType : urlType
        case is Data, is NSData: "public.data"
        default: nil
        }
    }
    /// A value's bytes as the given type would carry them.
    static func data(from value: Any, type: String) -> Data? {
        switch value {
        case let d as Data: d
        case let d as NSData: d as Data
        case let s as String: Data(s.utf8)
        case let s as NSString: Data((s as String).utf8)
        case let u as URL: Data(u.absoluteString.utf8)
        case let u as NSURL: Data((u as URL).absoluteString.utf8)
        default: nil
        }
    }
    static func value(from data: Data, type: String) -> Any {
        if Self.type(type, conformsTo: urlType), let s = String(data: data, encoding: .utf8), let u = URL(string: s) { return u }
        if Self.type(type, conformsTo: "public.plain-text"), let s = String(data: data, encoding: .utf8) { return s }
        return data
    }

    static func error(_ code: ErrorCode, _ type: String) -> NSError {
        NSError(domain: errorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "Cannot load representation of type \(type)"])
    }
    private static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NSItemProvider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func temporaryCopy(of url: URL, name: String) throws -> URL {
        let dest = try temporaryDirectory().appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
    static func temporaryFile(_ data: Data, name: String?, type: String) throws -> URL {
        let dest = try temporaryDirectory().appendingPathComponent(name ?? "item")
        try data.write(to: dest)
        return dest
    }
}
