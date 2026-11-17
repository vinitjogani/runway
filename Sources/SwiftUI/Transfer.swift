// Drag and drop, sharing and file export in SwiftUI's terms: onDrop with
// item providers or a DropDelegate, dropDestination/draggable with
// Transferable items, ShareLink, fileExporter. They compile and keep their
// values; the backends don't route SwiftUI drops yet, so drop handlers
// aren't called (AppKit's NSView drag and drop works).

import Foundation
import UniformTypeIdentifiers
@_exported import CoreTransferable
import RunwayCore

public struct DropInfo {
    public var location: CGPoint
    let providers: [NSItemProvider]
    public init(location: CGPoint = .zero, itemProviders: [NSItemProvider] = []) {
        self.location = location
        providers = itemProviders
    }
    public func hasItemsConforming(to contentTypes: [UTType]) -> Bool {
        providers.contains { p in contentTypes.contains { p.hasItemConformingToTypeIdentifier($0.identifier) } }
    }
    public func hasItemsConforming(to typeIdentifiers: [String]) -> Bool {
        providers.contains { p in typeIdentifiers.contains { p.hasItemConformingToTypeIdentifier($0) } }
    }
    public func itemProviders(for contentTypes: [UTType]) -> [NSItemProvider] {
        providers.filter { p in contentTypes.contains { p.hasItemConformingToTypeIdentifier($0.identifier) } }
    }
    public func itemProviders(for typeIdentifiers: [String]) -> [NSItemProvider] {
        providers.filter { p in typeIdentifiers.contains { p.hasItemConformingToTypeIdentifier($0) } }
    }
}

public enum DropOperation: Sendable { case cancel, forbidden, copy, move }

public struct DropProposal: Sendable {
    public let operation: DropOperation
    public init(operation: DropOperation) { self.operation = operation }
}

@MainActor @preconcurrency
public protocol DropDelegate {
    func validateDrop(info: DropInfo) -> Bool
    func performDrop(info: DropInfo) -> Bool
    func dropEntered(info: DropInfo)
    func dropUpdated(info: DropInfo) -> DropProposal?
    func dropExited(info: DropInfo)
}

extension DropDelegate {
    public func validateDrop(info: DropInfo) -> Bool { true }
    public func dropEntered(info: DropInfo) {}
    public func dropUpdated(info: DropInfo) -> DropProposal? { nil }
    public func dropExited(info: DropInfo) {}
}

extension View {
    public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?, perform action: @escaping ([NSItemProvider]) -> Bool) -> some View { self }
    public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?, perform action: @escaping ([NSItemProvider], CGPoint) -> Bool) -> some View { self }
    public func onDrop(of supportedTypes: [String], isTargeted: Binding<Bool>?, perform action: @escaping ([NSItemProvider]) -> Bool) -> some View { self }
    public func onDrop(of supportedContentTypes: [UTType], delegate: DropDelegate) -> some View { self }
    public func onDrop(of supportedTypes: [String], delegate: DropDelegate) -> some View { self }

    public func dropDestination<T: Transferable>(for payloadType: T.Type = T.self, action: @escaping (_ items: [T], _ location: CGPoint) -> Bool,
                                                 isTargeted: @escaping (Bool) -> Void = { _ in }) -> some View { self }
    public func draggable<T: Transferable>(_ payload: @autoclosure @escaping () -> T) -> some View { self }
    public func draggable<T: Transferable, V: View>(_ payload: @autoclosure @escaping () -> T, @ViewBuilder preview: () -> V) -> some View { self }
    public func itemProvider(_ action: (() -> NSItemProvider?)?) -> some View { self }
    public func copyable<T: Transferable>(_ payload: @autoclosure @escaping () -> [T]) -> some View { self }
    public func cuttable<T: Transferable>(for payloadType: T.Type = T.self, action: @escaping () -> [T]) -> some View { self }
    public func pasteDestination<T: Transferable>(for payloadType: T.Type = T.self, action: @escaping ([T]) -> Void,
                                                  validator: @escaping ([T]) -> [T]? = { $0 }) -> some View { self }

    public func fileExporter<T: Transferable>(isPresented: Binding<Bool>, item: T?, contentTypes: [UTType] = [], defaultFilename: String? = nil,
                                              onCompletion: @escaping (Result<URL, Error>) -> Void,
                                              onCancellation: @escaping () -> Void = {}) -> some View {
        fileExporterPanel(isPresented: isPresented, defaultFilename: defaultFilename, onCancellation: onCancellation) { url in
            guard let item else { return }
            Task { @MainActor in
                do {
                    let data = try await item.exported(as: contentTypes.first)
                    try data.write(to: url)
                    onCompletion(.success(url))
                } catch { onCompletion(.failure(error)) }
            }
        }
    }
    public func fileExporter<D: FileDocument>(isPresented: Binding<Bool>, document: D?, contentType: UTType, defaultFilename: String? = nil,
                                              onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        fileExporterPanel(isPresented: isPresented, defaultFilename: defaultFilename, onCancellation: {}) { url in
            guard let document else { return }
            do {
                let wrapper = try document.fileWrapper(configuration: FileDocumentWriteConfiguration(contentType: contentType, existingFile: nil))
                try wrapper.regularFileContents?.write(to: url)
                onCompletion(.success(url))
            } catch { onCompletion(.failure(error)) }
        }
    }
    public func fileDialogDefaultDirectory(_ url: URL?) -> some View { self }
    public func fileDialogMessage(_ message: Text?) -> some View { self }
    public func fileDialogMessage(_ message: String) -> some View { self }
    public func fileDialogConfirmationLabel(_ label: Text?) -> some View { self }
    public func fileDialogConfirmationLabel(_ label: String) -> some View { self }
    public func fileDialogImportsUnresolvedAliases(_ imports: Bool) -> some View { self }
    public func fileDialogBrowserOptions(_ options: FileDialogBrowserOptions) -> some View { self }
    public func fileDialogURLEnabled(_ predicate: Predicate<URL>) -> some View { self }
    public func fileDialogCustomizationID(_ id: String) -> some View { self }

    /// Opens a save panel when `isPresented` turns on.
    func fileExporterPanel(isPresented: Binding<Bool>, defaultFilename: String?, onCancellation: @escaping () -> Void,
                           write: @escaping @MainActor (URL) -> Void) -> some View {
        onChange(of: isPresented.wrappedValue) { _, presented in
            guard presented else { return }
            let panel = NSSavePanel()
            if let defaultFilename { panel.nameFieldStringValue = defaultFilename }
            panel.begin { response in
                isPresented.wrappedValue = false
                if response == .OK, let url = panel.url { write(url) } else { onCancellation() }
            }
        }
    }
}

public struct FileDialogBrowserOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let enumeratePackages = Self(rawValue: 1)
    public static let includeHiddenFiles = Self(rawValue: 2)
    public static let displayFileExtensions = Self(rawValue: 4)
}

// MARK: Documents

public protocol FileDocument {
    static var readableContentTypes: [UTType] { get }
    static var writableContentTypes: [UTType] { get }
    init(configuration: FileDocumentReadConfiguration) throws
    func fileWrapper(configuration: FileDocumentWriteConfiguration) throws -> FileWrapper
}

extension FileDocument {
    public static var writableContentTypes: [UTType] { readableContentTypes }
}

public struct FileDocumentReadConfiguration {
    public let contentType: UTType
    public let file: FileWrapper
}

public struct FileDocumentWriteConfiguration {
    public let contentType: UTType
    public let existingFile: FileWrapper?
}

// MARK: ShareLink

/// Sharing on Linux: the item is copied to the clipboard (there is no
/// system share sheet), the way "Copy" is the share action everywhere.
public struct ShareLink<Label: View>: View {
    let text: String?
    let label: Label

    public var body: some View {
        Button(action: {
            guard let text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }) { label }
    }
}

private func shareText<T: Transferable>(_ item: T) -> String? {
    if let s = item as? String { return s }
    if let u = item as? URL { return u.isFileURL ? u.path : u.absoluteString }
    return nil
}

extension ShareLink {
    public init<I: Transferable>(item: I, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {
        text = shareText(item)
        self.label = label()
    }
    public init<I: Transferable>(item: I, subject: Text? = nil, message: Text? = nil, preview: SharePreview<Image, Image>, @ViewBuilder label: () -> Label) {
        text = shareText(item)
        self.label = label()
    }
    public init<Data: RandomAccessCollection>(items: Data, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label)
        where Data.Element: Transferable {
        text = items.compactMap(shareText).joined(separator: "\n")
        self.label = label()
    }
}

extension ShareLink where Label == SwiftUI.Label<Text, Image> {
    public init<I: Transferable>(item: I, subject: Text? = nil, message: Text? = nil) {
        self.init(item: item, subject: subject, message: message) { SwiftUI.Label("Share…", systemImage: "square.and.arrow.up") }
    }
    public init<I: Transferable>(_ titleKey: LocalizedStringKey, item: I, subject: Text? = nil, message: Text? = nil) {
        self.init(item: item, subject: subject, message: message) { SwiftUI.Label(titleKey, systemImage: "square.and.arrow.up") }
    }
    @_disfavoredOverload
    public init<S: StringProtocol, I: Transferable>(_ title: S, item: I, subject: Text? = nil, message: Text? = nil) {
        self.init(item: item, subject: subject, message: message) { SwiftUI.Label(title, systemImage: "square.and.arrow.up") }
    }
    public init<I: Transferable>(_ titleKey: LocalizedStringKey, item: I, subject: Text? = nil, message: Text? = nil, preview: SharePreview<Image, Image>) {
        self.init(item: item, subject: subject, message: message) { SwiftUI.Label(titleKey, systemImage: "square.and.arrow.up") }
    }
}

public struct SharePreview<Image, Icon> {
    public init(_ titleKey: LocalizedStringKey) where Image == Never, Icon == Never {}
    public init(_ titleKey: LocalizedStringKey, image: Image) where Icon == Never {}
    public init(_ titleKey: LocalizedStringKey, icon: Icon) where Image == Never {}
    public init(_ titleKey: LocalizedStringKey, image: Image, icon: Icon) {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S) where Image == Never, Icon == Never {}
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, image: Image) where Icon == Never {}
}

extension Image: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        DataRepresentation<Image>(exportedContentType: .png) { _ in Data() }
    }
}
