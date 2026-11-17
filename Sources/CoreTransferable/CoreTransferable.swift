// CoreTransferable: how a type moves through drag and drop, the
// pasteboard, sharing and file import/export. Representations are kept as
// values so SwiftUI's drop destinations, ShareLink and file exporters can
// turn items into data or files and back.

@_exported import Foundation
@_exported import UniformTypeIdentifiers

public protocol Transferable {
    associatedtype Representation: TransferRepresentation
    @TransferRepresentationBuilder<Self> static var transferRepresentation: Representation { get }
}

public protocol TransferRepresentation<Item> {
    associatedtype Item: Transferable
    associatedtype Body: TransferRepresentation
    var body: Body { get }
    /// Runway: this representation as simple conversions.
    var _conversions: [_TransferConversion<Item>] { get }
}

extension TransferRepresentation {
    public var _conversions: [_TransferConversion<Item>] { (body._conversions as? [_TransferConversion<Item>]) ?? [] }
}

extension Never: TransferRepresentation {
    public typealias Item = Never
    public var body: Never { fatalError() }
    public var _conversions: [_TransferConversion<Never>] { [] }
}

extension Never: Transferable {
    public static var transferRepresentation: Never { fatalError() }
}

/// One way an item becomes bytes or a file of a content type, and back.
public struct _TransferConversion<Item> {
    public var contentType: UTType
    public var exportData: ((Item) async throws -> Data)?
    public var importData: ((Data) async throws -> Item)?
    public var exportFile: ((Item) async throws -> URL)?
    public var importFile: ((URL) async throws -> Item)?
    public var suggestedFileName: ((Item) -> String?)?
    public var isExportable: (Item) -> Bool = { _ in true }
}

@resultBuilder
public enum TransferRepresentationBuilder<Item: Transferable> {
    public static func buildExpression<R: TransferRepresentation>(_ r: R) -> R where R.Item == Item { r }
    public static func buildBlock<R: TransferRepresentation>(_ r: R) -> R where R.Item == Item { r }
    public static func buildBlock<each R: TransferRepresentation>(_ r: repeat each R) -> _TupleTransferRepresentation<Item> {
        var all: [_TransferConversion<Item>] = []
        for x in repeat each r { all += (x._conversions as? [_TransferConversion<Item>]) ?? [] }
        return _TupleTransferRepresentation(conversions: all)
    }
    public static func buildLimitedAvailability<R: TransferRepresentation>(_ r: R) -> _TupleTransferRepresentation<Item> where R.Item == Item {
        _TupleTransferRepresentation(conversions: r._conversions)
    }
}

public struct _TupleTransferRepresentation<Item: Transferable>: TransferRepresentation {
    let conversions: [_TransferConversion<Item>]
    public var body: Never { fatalError() }
    public var _conversions: [_TransferConversion<Item>] { conversions }
}

// MARK: Representations

public struct DataRepresentation<Item: Transferable>: TransferRepresentation {
    let conversion: _TransferConversion<Item>
    public init(contentType: UTType, exporting: @escaping @Sendable (Item) async throws -> Data,
                importing: @escaping @Sendable (Data) async throws -> Item) {
        conversion = _TransferConversion(contentType: contentType, exportData: exporting, importData: importing)
    }
    public init(exportedContentType: UTType, exporting: @escaping @Sendable (Item) async throws -> Data) {
        conversion = _TransferConversion(contentType: exportedContentType, exportData: exporting)
    }
    public init(importedContentType: UTType, importing: @escaping @Sendable (Data) async throws -> Item) {
        conversion = _TransferConversion(contentType: importedContentType, importData: importing)
    }
    public var body: Never { fatalError() }
    public var _conversions: [_TransferConversion<Item>] { [conversion] }
}

public struct SentTransferredFile: Sendable {
    public var file: URL
    public var allowAccessingOriginalFile: Bool
    public init(_ file: URL, allowAccessingOriginalFile: Bool = false) {
        self.file = file
        self.allowAccessingOriginalFile = allowAccessingOriginalFile
    }
}

public struct ReceivedTransferredFile: Sendable {
    public var file: URL
    public var isOriginalFile: Bool
    public init(file: URL, isOriginalFile: Bool) { self.file = file; self.isOriginalFile = isOriginalFile }
}

public struct FileRepresentation<Item: Transferable>: TransferRepresentation {
    let conversion: _TransferConversion<Item>
    public init(contentType: UTType, shouldAttemptToOpenInPlace: Bool = false,
                exporting: @escaping @Sendable (Item) async throws -> SentTransferredFile,
                importing: @escaping @Sendable (ReceivedTransferredFile) async throws -> Item) {
        conversion = _TransferConversion(contentType: contentType, exportFile: { try await exporting($0).file },
                                         importFile: { try await importing(ReceivedTransferredFile(file: $0, isOriginalFile: true)) })
    }
    public init(exportedContentType: UTType, shouldAllowToOpenInPlace: Bool = false,
                exporting: @escaping @Sendable (Item) async throws -> SentTransferredFile) {
        conversion = _TransferConversion(contentType: exportedContentType, exportFile: { try await exporting($0).file })
    }
    public init(importedContentType: UTType, shouldAttemptToOpenInPlace: Bool = false,
                importing: @escaping @Sendable (ReceivedTransferredFile) async throws -> Item) {
        conversion = _TransferConversion(contentType: importedContentType,
                                         importFile: { try await importing(ReceivedTransferredFile(file: $0, isOriginalFile: true)) })
    }
    public var body: Never { fatalError() }
    public var _conversions: [_TransferConversion<Item>] { [conversion] }
}

public struct CodableRepresentation<Item: Transferable & Codable>: TransferRepresentation {
    let conversion: _TransferConversion<Item>
    public init(for itemType: Item.Type = Item.self, contentType: UTType) {
        self.init(for: itemType, contentType: contentType, encoder: JSONEncoder(), decoder: JSONDecoder())
    }
    public init(for itemType: Item.Type = Item.self, contentType: UTType, encoder: JSONEncoder, decoder: JSONDecoder) {
        nonisolated(unsafe) let e = encoder, d = decoder
        conversion = _TransferConversion(contentType: contentType, exportData: { try e.encode($0) },
                                         importData: { try d.decode(Item.self, from: $0) })
    }
    public var body: Never { fatalError() }
    public var _conversions: [_TransferConversion<Item>] { [conversion] }
}

public struct ProxyRepresentation<Item: Transferable, ProxyRepresentation: Transferable>: TransferRepresentation {
    let conversions: [_TransferConversion<Item>]
    public init(exporting: @escaping @Sendable (Item) throws -> ProxyRepresentation) {
        conversions = ProxyRepresentation._conversions.map { c in
            var r = _TransferConversion<Item>(contentType: c.contentType)
            if let ed = c.exportData { r.exportData = { try await ed(try exporting($0)) } }
            if let ef = c.exportFile { r.exportFile = { try await ef(try exporting($0)) } }
            return r
        }
    }
    public init(exporting: @escaping @Sendable (Item) throws -> ProxyRepresentation,
                importing: @escaping @Sendable (ProxyRepresentation) throws -> Item) {
        conversions = ProxyRepresentation._conversions.map { c in
            var r = _TransferConversion<Item>(contentType: c.contentType)
            if let ed = c.exportData { r.exportData = { try await ed(try exporting($0)) } }
            if let ef = c.exportFile { r.exportFile = { try await ef(try exporting($0)) } }
            if let id = c.importData { r.importData = { try importing(try await id($0)) } }
            if let i = c.importFile { r.importFile = { try importing(try await i($0)) } }
            return r
        }
    }
    public init(importing: @escaping @Sendable (ProxyRepresentation) throws -> Item) {
        conversions = ProxyRepresentation._conversions.map { c in
            var r = _TransferConversion<Item>(contentType: c.contentType)
            if let id = c.importData { r.importData = { try importing(try await id($0)) } }
            if let i = c.importFile { r.importFile = { try importing(try await i($0)) } }
            return r
        }
    }
    public var body: Never { fatalError() }
    public var _conversions: [_TransferConversion<Item>] { conversions }
}

/// A representation with one of its conversions adjusted.
public struct _ModifiedTransferRepresentation<Item: Transferable>: TransferRepresentation {
    let conversions: [_TransferConversion<Item>]
    public var body: Never { fatalError() }
    public var _conversions: [_TransferConversion<Item>] { conversions }
}

extension TransferRepresentation {
    public func suggestedFileName(_ fileName: String) -> _ModifiedTransferRepresentation<Item> {
        _ModifiedTransferRepresentation(conversions: _conversions.map { var c = $0; c.suggestedFileName = { _ in fileName }; return c })
    }
    public func suggestedFileName(_ fileName: @escaping (Item) -> String?) -> _ModifiedTransferRepresentation<Item> {
        _ModifiedTransferRepresentation(conversions: _conversions.map { var c = $0; c.suggestedFileName = fileName; return c })
    }
    public func exportingCondition(_ condition: @escaping (Item) -> Bool) -> _ModifiedTransferRepresentation<Item> {
        _ModifiedTransferRepresentation(conversions: _conversions.map { var c = $0; c.isExportable = condition; return c })
    }
    public func visibility(_ visibility: TransferRepresentationVisibility) -> _ModifiedTransferRepresentation<Item> {
        _ModifiedTransferRepresentation(conversions: _conversions)
    }
}

public struct TransferRepresentationVisibility: Sendable {
    public static let all = Self(), team = Self(), group = Self(), ownProcess = Self()
}

// MARK: Importing / exporting helpers

public enum TransferableError: Error { case noRepresentation(UTType?) }

extension Transferable {
    /// This type's conversions.
    public static var _conversions: [_TransferConversion<Self>] {
        (transferRepresentation._conversions as? [_TransferConversion<Self>]) ?? []
    }

    /// The content types this type exports, in preference order.
    public static var _exportedContentTypes: [UTType] {
        _conversions.filter { $0.exportData != nil || $0.exportFile != nil }.map(\.contentType)
    }
    public static var _importedContentTypes: [UTType] {
        _conversions.filter { $0.importData != nil || $0.importFile != nil }.map(\.contentType)
    }

    /// The item's data in `contentType` (or its first representation).
    public func exported(as contentType: UTType? = nil) async throws -> Data {
        for c in Self._conversions where contentType == nil || c.contentType.conforms(to: contentType!) {
            guard c.isExportable(self) else { continue }
            if let e = c.exportData { return try await e(self) }
            if let f = c.exportFile { return try Data(contentsOf: try await f(self)) }
        }
        throw TransferableError.noRepresentation(contentType)
    }

    /// An item from data of `contentType`.
    public init(importing data: Data, contentType: UTType?) async throws {
        for c in Self._conversions where contentType == nil || contentType!.conforms(to: c.contentType) {
            if let i = c.importData { self = try await i(data); return }
            if let f = c.importFile {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(c.contentType.preferredFilenameExtension ?? "data")
                try data.write(to: url)
                self = try await f(url)
                return
            }
        }
        throw TransferableError.noRepresentation(contentType)
    }

    /// An item from a file (drops and imports of files).
    public static func _importing(file url: URL) async throws -> Self {
        let type = UTType(filenameExtension: url.pathExtension)
        for c in _conversions where type == nil || type!.conforms(to: c.contentType) {
            if let f = c.importFile { return try await f(url) }
            if let i = c.importData { return try await i(try Data(contentsOf: url)) }
        }
        throw TransferableError.noRepresentation(type)
    }
}

// MARK: Standard conformances

extension String: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<String>(contentType: .utf8PlainText, exporting: { Data($0.utf8) },
                                   importing: { String(decoding: $0, as: UTF8.self) })
    }
}

extension Data: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<Data>(contentType: .data, exporting: { $0 }, importing: { $0 })
    }
}

extension URL: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<URL>(contentType: .url, exporting: { Data($0.absoluteString.utf8) },
                                importing: { d in
                                    guard let u = URL(string: String(decoding: d, as: UTF8.self)) else { throw TransferableError.noRepresentation(.url) }
                                    return u
                                })
    }
}

extension AttributedString: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<AttributedString>(contentType: .utf8PlainText, exporting: { Data(String($0.characters).utf8) },
                                             importing: { AttributedString(String(decoding: $0, as: UTF8.self)) })
    }
}
