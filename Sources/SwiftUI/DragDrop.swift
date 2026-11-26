// SwiftUI drag and drop: drop destinations (onDrop, dropDestination) wrap
// their view in a pass-through container whose `onDrop` event the backend
// calls for drags over it; drag sources (draggable, onDrag) watch the
// pointer and start a native drag once it moves with the button down.

import Foundation
import UniformTypeIdentifiers
import CoreTransferable
import RunwayCore

/// What a drag carries, as SwiftUI's item providers.
@MainActor enum DragContents {
    static func providers(_ e: RawDragEvent) -> [NSItemProvider] {
        e.fileURLs.compactMap { NSItemProvider(contentsOf: $0) ?? NSItemProvider(object: $0) }
            + e.strings.map { s in
                if let u = URL(string: s), u.scheme == "http" || u.scheme == "https" { return NSItemProvider(object: u) }
                return NSItemProvider(object: s)
            }
    }

    /// Whether providers offer one of `types` (identifiers).
    static func accepts(_ providers: [NSItemProvider], _ types: [String]) -> Bool {
        let all = Set([UTType.item, .data, .content].map(\.identifier))
        if types.contains(where: { all.contains($0) }) { return !providers.isEmpty }
        return providers.contains { p in
            types.contains { t in
                p.hasItemConformingToTypeIdentifier(t)
                    || (t == UTType.url.identifier && p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
                    || (t == UTType.text.identifier && p.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier))
                    || (t == UTType.plainText.identifier && p.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier))
            }
        }
    }

    /// Items of `T` a drag carries; `done` gets them (at once for strings
    /// and URLs, after importing for other types).
    static func items<T: Transferable>(_ e: RawDragEvent, as: T.Type, done: @escaping @MainActor ([T]) -> Void) {
        if T.self == URL.self {
            let urls = e.fileURLs + e.strings.compactMap { s -> URL? in
                guard let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)), u.scheme != nil else { return nil }
                return u
            }
            done(urls as! [T])
            return
        }
        if T.self == String.self {
            done((e.strings + e.fileURLs.map(\.absoluteString)) as! [T])
            return
        }
        let files = e.fileURLs, strings = e.strings
        Task { @MainActor in
            var out: [T] = []
            for f in files { if let t = try? await T._importing(file: f) { out.append(t) } }
            for s in strings { if let t = try? await T(importing: Data(s.utf8), contentType: .utf8PlainText) { out.append(t) } }
            done(out)
        }
    }

    /// A Transferable item as text and files for a drag out of the app.
    static func payload<T: Transferable>(_ item: T) -> DragPayload {
        if let s = item as? String { return DragPayload(strings: [s]) }
        if let u = item as? URL { return u.isFileURL ? DragPayload(fileURLs: [u]) : DragPayload(strings: [u.absoluteString]) }
        if let a = item as? AttributedString { return DragPayload(strings: [String(a.characters)]) }
        // Other types: their text or file export, waited for briefly
        // (exports are plain conversions; one that needs this thread fails).
        for c in T._conversions {
            if let f = c.exportFile, let url = wait({ try await f(item) }) { return DragPayload(fileURLs: [url]) }
            if let e = c.exportData, c.contentType.conforms(to: .text) || c.contentType.conforms(to: .url),
               let data = wait({ try await e(item) }) {
                let s = String(decoding: data, as: UTF8.self)
                if c.contentType.conforms(to: .fileURL), let u = URL(string: s) { return DragPayload(fileURLs: [u]) }
                return DragPayload(strings: [s])
            }
        }
        return DragPayload()
    }

    private nonisolated static func wait<R: Sendable>(_ work: @escaping @Sendable () async throws -> R) -> R? {
        let box = WaitBox<R>(), done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await work()
            done.signal()
        }
        return done.wait(timeout: .now() + 1) == .success ? box.value : nil
    }
}

/// Watches a press for movement that starts a drag.
@MainActor final class DragSourceState {
    var start: CGPoint?
    var started = false
}

extension View {
    /// Wraps the view in a drop destination.
    func dropZone(_ handle: @escaping @MainActor (RawDragEvent, DropDelegateState) -> RawDragOperation) -> some View {
        nodes("drop") { ns, ctx in
            guard !ctx.dryRun else { return ns }
            let backend = ctx.host.backend
            let state = ctx.host.interactionState(ctx.path + "#drop") { DropDelegateState() }
            let w = ctx.host.customWidget(ctx.path + "#drop", fresh: false) {
                let w = backend.makeWidget(.container)
                (backend as? AppKitBackend)?.setPassesThrough(w, true)
                return w
            }
            var e = WidgetEvents()
            e.onDrop = { ev in MainActor.assumeIsolated { handle(ev, state) } }
            backend.update(w, props: ctx.baseProps(), events: e)
            let inner: LayoutNode = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            return [ContainerNode.modifier(w, backend, inner)]
        }
    }

    /// Starts a native drag of what `payload` gives once a press moves.
    func dragSource(_ payload: @escaping @MainActor () -> DragPayload) -> some View {
        pointerArea("drag") { h, ctx in
            let state: DragSourceState = ctx.host.interactionState(ctx.path + "#drag") { DragSourceState() }
            let backend = ctx.host.backend
            h.pointer = { [weak h] e in
                switch e.kind {
                case .down where e.button == 0:
                    state.start = e.location
                    state.started = false
                    return false
                case .dragged:
                    guard let s = state.start, !state.started, let w = h?.widget else { return state.started }
                    guard hypot(e.location.x - s.x, e.location.y - s.y) >= 4 else { return false }
                    let p = payload()
                    guard !p.isEmpty else { state.start = nil; return false }
                    state.started = true
                    backend.beginDrag(p, from: w) { _ in state.start = nil; state.started = false }
                    return true
                case .up:
                    let took = state.started
                    state.start = nil
                    state.started = false
                    return took
                default:
                    return false
                }
            }
        }
    }

    public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?, perform action: @escaping ([NSItemProvider]) -> Bool) -> some View {
        onDrop(of: supportedContentTypes.map(\.identifier), isTargeted: isTargeted, perform: action)
    }
    public func onDrop(of supportedContentTypes: [UTType], isTargeted: Binding<Bool>?, perform action: @escaping ([NSItemProvider], CGPoint) -> Bool) -> some View {
        let types = supportedContentTypes.map(\.identifier)
        return dropZone { e, _ in
            let providers = DragContents.providers(e)
            let ok = DragContents.accepts(providers, types)
            switch e.kind {
            case .entered, .updated:
                if isTargeted?.wrappedValue != ok { isTargeted?.wrappedValue = ok }
                return ok ? .copy : []
            case .exited:
                if isTargeted?.wrappedValue == true { isTargeted?.wrappedValue = false }
                return []
            case .perform:
                if isTargeted?.wrappedValue == true { isTargeted?.wrappedValue = false }
                return ok && action(providers, e.location) ? .copy : []
            }
        }
    }
    public func onDrop(of supportedTypes: [String], isTargeted: Binding<Bool>?, perform action: @escaping ([NSItemProvider]) -> Bool) -> some View {
        onDrop(of: supportedTypes.compactMap { UTType($0) }, isTargeted: isTargeted) { providers, _ in action(providers) }
    }
    public func onDrop(of supportedContentTypes: [UTType], delegate: DropDelegate) -> some View {
        let types = supportedContentTypes.map(\.identifier)
        return dropZone { e, state in
            let providers = DragContents.providers(e)
            let info = DropInfo(location: e.location, itemProviders: providers)
            guard DragContents.accepts(providers, types) else { return [] }
            switch e.kind {
            case .entered, .updated:
                if !state.inside {
                    guard delegate.validateDrop(info: info) else { return [] }
                    state.inside = true
                    delegate.dropEntered(info: info)
                }
                switch delegate.dropUpdated(info: info)?.operation {
                case .cancel?, .forbidden?: return []
                case .move?: return .move
                default: return .copy
                }
            case .exited:
                if state.inside { state.inside = false; delegate.dropExited(info: info) }
                return []
            case .perform:
                state.inside = false
                return delegate.validateDrop(info: info) && delegate.performDrop(info: info) ? .copy : []
            }
        }
    }
    public func onDrop(of supportedTypes: [String], delegate: DropDelegate) -> some View {
        onDrop(of: supportedTypes.compactMap { UTType($0) }, delegate: delegate)
    }

    public func dropDestination<T: Transferable>(for payloadType: T.Type = T.self, action: @escaping (_ items: [T], _ location: CGPoint) -> Bool,
                                                 isTargeted: @escaping (Bool) -> Void = { _ in }) -> some View {
        return dropZone { e, state in
            let empty = e.fileURLs.isEmpty && e.strings.isEmpty
            switch e.kind {
            case .entered, .updated:
                if !state.inside { state.inside = true; isTargeted(true) }
                return empty ? [] : .copy
            case .exited:
                if state.inside { state.inside = false; isTargeted(false) }
                return []
            case .perform:
                if state.inside { state.inside = false; isTargeted(false) }
                guard !empty else { return [] }
                var accepted = true
                let location = e.location
                DragContents.items(e, as: T.self) { items in
                    guard !items.isEmpty else { accepted = false; return }
                    accepted = action(items, location)
                }
                return accepted ? .copy : []
            }
        }
    }

    public func draggable<T: Transferable>(_ payload: @autoclosure @escaping () -> T) -> some View {
        dragSource { DragContents.payload(payload()) }
    }
    public func draggable<T: Transferable, V: View>(_ payload: @autoclosure @escaping () -> T, @ViewBuilder preview: () -> V) -> some View {
        dragSource { DragContents.payload(payload()) }
    }
    public func onDrag(_ data: @escaping () -> NSItemProvider) -> some View {
        dragSource {
            let c = data()._runwayImmediateContents()
            return DragPayload(strings: c.strings, fileURLs: c.urls)
        }
    }
    public func onDrag<V: View>(_ data: @escaping () -> NSItemProvider, @ViewBuilder preview: () -> V) -> some View {
        onDrag(data)
    }
    public func itemProvider(_ action: (() -> NSItemProvider?)?) -> some View {
        guard let action else { return AnyView(self) }
        return AnyView(dragSource {
            guard let p = action() else { return DragPayload() }
            let c = p._runwayImmediateContents()
            return DragPayload(strings: c.strings, fileURLs: c.urls)
        })
    }
}

@MainActor final class DropDelegateState { var inside = false }

private final class WaitBox<R>: @unchecked Sendable { var value: R?; init() {} }
