// App and scenes (WindowGroup, Window, Settings), windows hosting views,
// sheets and alerts, and the AppKit bridges: NSHostingController,
// NSHostingView, Color(nsColor:), Image(nsImage:).

@_exported import Foundation
@_exported import CoreGraphics
@_exported import Observation
// On macOS, SwiftUI re-exports AppKit (NSView, NSViewRepresentable hosts…).
@_exported import AppKit
import RunwayCore
import RunwayPlatform
import AppKit

// MARK: App

@MainActor @preconcurrency
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder @MainActor @preconcurrency var body: Self.Body { get }
    @MainActor @preconcurrency init()
}

extension App {
    @MainActor @preconcurrency public static func main() {
        RunwayPlatform.installDefaultBackend()
        SwiftUIRuntime.install()
        let app = Self()
        let registry = SceneRegistry.shared
        Runway.backend.run {
            // An NSApplicationDelegateAdaptor's delegate hears launching
            // around the scenes' first windows, as on the Mac.
            let n = Notification(name: NSApplication.didFinishLaunchingNotification, object: NSApplication.shared)
            NSApplication.shared.delegate?.applicationWillFinishLaunching(n)
            registry.load(app)
            registry.openInitial()
            NSApplication.shared.delegate?.applicationDidFinishLaunching(n)
            NotificationCenter.default.post(n)
        }
    }
}

@MainActor @preconcurrency
public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder @MainActor @preconcurrency var body: Self.Body { get }
}

extension Never: Scene {}

@MainActor protocol PrimitiveScene {
    func collect(into registry: SceneRegistry)
}

extension PrimitiveScene {
    public var body: Never { fatalError() }
}

@resultBuilder
public enum SceneBuilder {
    public static func buildBlock<each S: Scene>(_ scenes: repeat each S) -> _TupleScene<repeat each S> { _TupleScene(repeat each scenes) }
    public static func buildExpression<S: Scene>(_ s: S) -> S { s }
    public static func buildOptional<S: Scene>(_ s: S?) -> _OptionalScene<S> { _OptionalScene(scene: s) }
    public static func buildEither<T: Scene, F: Scene>(first: T) -> _EitherScene<T, F> { _EitherScene(first: first, second: nil) }
    public static func buildEither<T: Scene, F: Scene>(second: F) -> _EitherScene<T, F> { _EitherScene(first: nil, second: second) }
    public static func buildLimitedAvailability<S: Scene>(_ s: S) -> S { s }
}

public struct _TupleScene<each S: Scene>: Scene, PrimitiveScene {
    public typealias Body = Never
    let scenes: (repeat each S)
    init(_ s: repeat each S) { scenes = (repeat each s) }
    func collect(into registry: SceneRegistry) { for s in repeat each scenes { registry.collect(s) } }
}

public struct _OptionalScene<S: Scene>: Scene, PrimitiveScene {
    public typealias Body = Never
    let scene: S?
    func collect(into registry: SceneRegistry) { if let scene { registry.collect(scene) } }
}

public struct _EitherScene<T: Scene, F: Scene>: Scene, PrimitiveScene {
    public typealias Body = Never
    let first: T?, second: F?
    func collect(into registry: SceneRegistry) {
        if let first { registry.collect(first) }
        if let second { registry.collect(second) }
    }
}

/// A scene's window: a title, a default size, and a view.
struct SceneSpec {
    enum Kind { case group, single, settings, menuBarExtra }
    let id: String?
    let kind: Kind
    var title: String
    var defaultSize: CGSize?
    var resizability: WindowResizability = .automatic
    let content: () -> AnyView
}

public struct WindowGroup<Content: View>: Scene, PrimitiveScene {
    public typealias Body = Never
    var spec: SceneSpec
    public init(@ViewBuilder content: @escaping () -> Content) { spec = SceneSpec(id: nil, kind: .group, title: "", content: { AnyView(content()) }) }
    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) { spec = SceneSpec(id: nil, kind: .group, title: title, content: { AnyView(content()) }) }
    public init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) { self.init(title.string, content: content) }
    public init(_ title: String, id: String, @ViewBuilder content: @escaping () -> Content) { spec = SceneSpec(id: id, kind: .group, title: title, content: { AnyView(content()) }) }
    public init(id: String, @ViewBuilder content: @escaping () -> Content) { spec = SceneSpec(id: id, kind: .group, title: "", content: { AnyView(content()) }) }
    func collect(into registry: SceneRegistry) { registry.add(spec) }
}

public struct Window<Content: View>: Scene, PrimitiveScene {
    public typealias Body = Never
    var spec: SceneSpec
    public init(_ title: String, id: String, @ViewBuilder content: @escaping () -> Content) { spec = SceneSpec(id: id, kind: .single, title: title, content: { AnyView(content()) }) }
    public init(_ title: LocalizedStringKey, id: String, @ViewBuilder content: @escaping () -> Content) { self.init(title.string, id: id, content: content) }
    func collect(into registry: SceneRegistry) { registry.add(spec) }
}

/// Settings: opened with ⌘, (Ctrl+,).
public struct Settings<Content: View>: Scene, PrimitiveScene {
    public typealias Body = Never
    var spec: SceneSpec
    public init(@ViewBuilder content: @escaping () -> Content) {
        spec = SceneSpec(id: "settings", kind: .settings, title: "Settings", resizability: .contentSize, content: { AnyView(content()) })
    }
    func collect(into registry: SceneRegistry) { registry.add(spec) }
}

/// A menu bar extra: a status item (the desktop's tray, or Runway's own
/// strip of status items where there is none) whose click opens the
/// content in a window sized to it.
public struct MenuBarExtra<Label: View, Content: View>: Scene, PrimitiveScene {
    public typealias Body = Never
    let content: () -> Content
    let title: String
    var systemImage: String?
    var image: String?
    var isInserted: Binding<Bool>?
    public init(_ title: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) where Label == SwiftUI.Label<Text, Image> {
        self.title = title; self.content = content; self.systemImage = systemImage
    }
    public init(_ title: String, systemImage: String, isInserted: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) where Label == SwiftUI.Label<Text, Image> {
        self.title = title; self.content = content; self.systemImage = systemImage; self.isInserted = isInserted
    }
    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) where Label == Text {
        self.title = title; self.content = content
    }
    public init(_ title: String, isInserted: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) where Label == Text {
        self.title = title; self.content = content; self.isInserted = isInserted
    }
    public init(_ title: String, image: String, @ViewBuilder content: @escaping () -> Content) where Label == SwiftUI.Label<Text, Image> {
        self.title = title; self.content = content; self.image = image
    }
    public init(_ title: String, image: String, isInserted: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) where Label == SwiftUI.Label<Text, Image> {
        self.title = title; self.content = content; self.image = image; self.isInserted = isInserted
    }
    public init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {
        self.title = ""; self.content = content
    }
    public init(isInserted: Binding<Bool>, @ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {
        self.title = ""; self.content = content; self.isInserted = isInserted
    }
    func collect(into registry: SceneRegistry) {
        let c = content
        let id = "menubar." + (title.isEmpty ? "\(registry.extras.count)" : title)
        registry.add(SceneSpec(id: id, kind: .menuBarExtra, title: title, resizability: .contentSize, content: { AnyView(VStack(alignment: .leading, spacing: 4) { c() }.padding(10)) }))
        registry.extras.append(MenuBarExtraSpec(id: id, title: title, systemImage: systemImage, image: image, isInserted: isInserted))
    }
}

struct MenuBarExtraSpec {
    let id: String
    let title: String
    let systemImage: String?
    let image: String?
    let isInserted: Binding<Bool>?
}

public struct MenuBarExtraStyle: Sendable { public static let menu = MenuBarExtraStyle(), window = MenuBarExtraStyle(), automatic = MenuBarExtraStyle() }

public enum WindowResizability: Sendable { case automatic, contentSize, contentMinSize }

public struct Commands {}
public struct CommandGroup<Content: View> {
    public init(replacing: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {}
    public init(after: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {}
    public init(before: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {}
}
public struct CommandMenu<Content: View> {
    public init(_ name: String, @ViewBuilder content: () -> Content) {}
}
public struct CommandGroupPlacement: Sendable {
    public static let appInfo = Self(), appSettings = Self(), appTermination = Self(), newItem = Self(), saveItem = Self()
    public static let importExport = Self(), printItem = Self(), undoRedo = Self(), pasteboard = Self(), textEditing = Self()
    public static let toolbar = Self(), sidebar = Self(), windowSize = Self(), windowArrangement = Self(), help = Self(), singleWindowList = Self()
}
@resultBuilder public enum CommandsBuilder {
    public static func buildBlock(_ parts: Any...) -> Commands { Commands() }
}

extension Scene {
    public func defaultSize(width: CGFloat, height: CGFloat) -> some Scene { SceneModifier(base: self) { $0.defaultSize = CGSize(width: width, height: height) } }
    public func defaultSize(_ size: CGSize) -> some Scene { defaultSize(width: size.width, height: size.height) }
    public func windowResizability(_ r: WindowResizability) -> some Scene { SceneModifier(base: self) { $0.resizability = r } }
    public func commands(@CommandsBuilder content: () -> Commands) -> some Scene { self }
    public func windowStyle<S: WindowStyle>(_ style: S) -> some Scene { self }
    public func windowToolbarStyle<S: WindowToolbarStyle>(_ style: S) -> some Scene { self }
    public func defaultPosition(_ p: UnitPoint) -> some Scene { self }
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some Scene { self }
    public func handlesExternalEvents(matching: Set<String>) -> some Scene { self }
    public func restorationBehavior(_ b: Any) -> some Scene { self }
    public func defaultLaunchBehavior(_ b: Any) -> some Scene { self }
}

struct SceneModifier<Base: Scene>: Scene, PrimitiveScene {
    typealias Body = Never
    let base: Base
    let transform: (inout SceneSpec) -> Void
    func collect(into registry: SceneRegistry) {
        let start = registry.specs.count
        registry.collect(base)
        for i in start..<registry.specs.count { transform(&registry.specs[i]) }
    }
}

/// The app's scenes and their open windows.
@MainActor final class SceneRegistry {
    static let shared = SceneRegistry()
    var specs: [SceneSpec] = []
    var extras: [MenuBarExtraSpec] = []
    private var statusItems: [NSStatusItem] = []
    private var open: [String: WindowHost] = [:]
    private var appHost: ViewHost?
    private var counter = 0

    func load<A: App>(_ app: A) {
        // The App's own @State lives in a host of its own.
        let h = ViewHost(EmptyView())
        h.link(app, ResolveContext(host: h, env: EnvironmentValues(), path: "app"))
        appHost = h
        specs.removeAll()
        extras.removeAll()
        collect(app.body)
    }

    func collect<S: Scene>(_ scene: S) {
        if let p = scene as? PrimitiveScene { p.collect(into: self); return }
        collect(scene.body)
    }

    func add(_ spec: SceneSpec) { specs.append(spec) }

    /// At launch: the first window scene opens, and each inserted menu
    /// bar extra gets its status item. Settings (and an app with nothing
    /// but menu bar extras) open no window, as on the Mac.
    func openInitial() {
        for extra in extras where extra.isInserted?.wrappedValue ?? true {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let symbol = extra.systemImage { item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: extra.title) }
            else if let name = extra.image { item.button?.image = NSImage(named: name) }
            if item.button?.image == nil { item.button?.title = extra.title }
            item.button?.toolTip = extra.title
            let id = extra.id
            item.button?.handler = { [weak self] _ in
                guard let self else { return }
                if self.open[id] != nil { self.close(id: id) } else { self.open(id: id) }
            }
            statusItems.append(item)
        }
        if let first = specs.first(where: { $0.kind == .group || $0.kind == .single }) { show(first) }
    }

    func open(id: String) {
        if let w = open[id] { w.window.show(); return }
        if let spec = specs.first(where: { $0.id == id }) { show(spec) }
    }

    func close(id: String) { open[id]?.window.close() }

    func openSettings() { open(id: "settings") }

    private func show(_ spec: SceneSpec) {
        let key: String
        if let id = spec.id, spec.kind != .group { key = id } else { counter += 1; key = (spec.id ?? "window") + "#\(counter)" }
        if let w = open[key] { w.window.show(); return }
        let host = WindowHost(title: spec.title, view: spec.content(), size: spec.defaultSize, sizedToContent: spec.resizability == .contentSize)
        host.onClose = { [weak self] in
            self?.open[key] = nil
            // An app with status items lives on without windows.
            if self?.open.isEmpty == true, NSStatusBar.system.items.isEmpty { Runway.backend.quit() }
        }
        host.extraKeys = { [weak self] key in
            if key.command, key.key == "," { self?.openSettings(); return true }
            if key.command, key.key == "q" { Runway.backend.quit(); return true }
            return false
        }
        open[key] = host
        host.window.show()
    }
}

/// A native window showing a SwiftUI view.
@MainActor final class WindowHost {
    let window: NativeWindow
    let host: ViewHost
    var onClose: (() -> Void)?
    var extraKeys: ((KeyPress) -> Bool)?

    init(title: String, view: AnyView, size: CGSize?, sizedToContent: Bool, parent: NativeWindow? = nil, modal: Bool = false, environment: EnvironmentValues = EnvironmentValues()) {
        let backend = Runway.backend
        // One host: it resolves the tree once to learn its ideal size (the
        // window's initial size); the first render then only lays it out.
        let content = backend.makeWidget(.container)
        host = ViewHost(view, backend: backend, container: content, environment: environment)
        let ideal = size == nil ? host.idealSize() : .zero
        let initial = size ?? CGSize(width: max(ideal.width, 200).rounded(.up), height: max(ideal.height, 80).rounded(.up))
        window = backend.makeWindow(WindowOptions(title: title, size: initial, resizable: !sizedToContent, modal: modal), parent: parent)
        host.window = window
        backend.setChildren(window.content, [(content, CGRect(origin: .zero, size: initial))], contentSize: initial)
        host.setSize(initial)
        window.onResize = { [weak self] s in
            guard let self else { return }
            Runway.backend.setChildren(self.window.content, [(self.host.container, CGRect(origin: .zero, size: s))], contentSize: s)
            self.host.setSize(s)
        }
        window.onKey = { [weak self] key in
            guard let self else { return false }
            return self.host.handleKey(key) || (self.extraKeys?(key) ?? false)
        }
        window.onClosed = { [weak self] in
            self?.host.tearDown()
            self?.onClose?()
        }
        host.onTitleChange = { [weak window] t in window?.title = t }
        if sizedToContent {
            host.onIdealSizeChange = { [weak self] s in
                guard let self else { return }
                let rounded = CGSize(width: s.width.rounded(.up), height: s.height.rounded(.up))
                if rounded != self.window.contentSize, rounded.width > 0, rounded.height > 0 {
                    self.window.setContentSize(rounded)
                    Runway.backend.setChildren(self.window.content, [(self.host.container, CGRect(origin: .zero, size: rounded))], contentSize: rounded)
                    self.host.setSize(rounded)
                }
            }
        }
        host.render()
        if window.title.isEmpty, let t = host.title { window.title = t }
    }
}

// MARK: Sheets and alerts

/// A modal window presented from a view (sheet, alert, confirmation dialog).
@MainActor final class Presentation {
    var content: () -> AnyView
    var onDismiss: () -> Void
    let title: String
    private var windowHost: WindowHost?
    init(title: String, content: @escaping () -> AnyView, onDismiss: @escaping () -> Void) {
        self.title = title; self.content = content; self.onDismiss = onDismiss
    }
    func update(_ other: Presentation) {
        content = other.content
        onDismiss = other.onDismiss
        windowHost?.host.setRoot(content())
    }
    func open(parent: NativeWindow?) {
        var env = EnvironmentValues()
        let dismiss = onDismiss
        env.dismiss = DismissAction { dismiss() }
        env.isPresented = true
        let w = WindowHost(title: title, view: content(), size: nil, sizedToContent: true, parent: parent, modal: true, environment: env)
        w.onClose = { [weak self] in
            guard let self, self.windowHost != nil else { return }
            self.windowHost = nil
            self.onDismiss()
        }
        windowHost = w
        w.window.show()
    }
    func dismissWindow() {
        let w = windowHost
        windowHost = nil
        w?.window.close()
    }
}

extension View {
    public func sheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        nodes("sheet") { ns, ctx in
            if isPresented.wrappedValue, !ctx.dryRun {
                ctx.host.present(ctx.path, Presentation(title: "", content: { AnyView(content()) }, onDismiss: {
                    if isPresented.wrappedValue { isPresented.wrappedValue = false }
                    onDismiss?()
                }))
            }
            return ns
        }
    }

    public func sheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        nodes("sheet") { ns, ctx in
            if let value = item.wrappedValue, !ctx.dryRun {
                ctx.host.present(ctx.path + "=\(value.id)", Presentation(title: "", content: { AnyView(content(value)) }, onDismiss: {
                    if item.wrappedValue != nil { item.wrappedValue = nil }
                    onDismiss?()
                }))
            }
            return ns
        }
    }

    public func popover<Content: View>(isPresented: Binding<Bool>, attachmentAnchor: Any? = nil, arrowEdge: Edge? = nil, @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, content: content)
    }

    public func alert<A: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A) -> some View {
        alert(title, isPresented: isPresented, actions: actions, message: { EmptyView() })
    }
    public func alert<A: View>(_ title: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A) -> some View {
        alert(title.string, isPresented: isPresented, actions: actions, message: { EmptyView() })
    }
    public func alert<A: View, M: View>(_ title: LocalizedStringKey, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        alert(title.string, isPresented: isPresented, actions: actions, message: message)
    }
    public func alert<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        sheet(isPresented: isPresented) { AlertBody(title: title, message: AnyView(message()), actions: AnyView(actions()), isPresented: isPresented) }
    }
    public func alert<T, A: View, M: View>(_ title: String, isPresented: Binding<Bool>, presenting data: T?, @ViewBuilder actions: @escaping (T) -> A, @ViewBuilder message: @escaping (T) -> M) -> some View {
        sheet(isPresented: isPresented) {
            if let data { AlertBody(title: title, message: AnyView(message(data)), actions: AnyView(actions(data)), isPresented: isPresented) }
        }
    }
    public func confirmationDialog<A: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A) -> some View {
        alert(title, isPresented: isPresented, actions: actions)
    }
    public func confirmationDialog<A: View, M: View>(_ title: String, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A, @ViewBuilder message: @escaping () -> M) -> some View {
        alert(title, isPresented: isPresented, actions: actions, message: message)
    }
    public func confirmationDialog<A: View>(_ title: LocalizedStringKey, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: @escaping () -> A) -> some View {
        alert(title.string, isPresented: isPresented, actions: actions)
    }
    /// The system's open dialog, for files of the given types (folders when `.folder` is among them).
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool, onCompletion: @escaping (Result<[URL], Error>) -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes, allowsMultipleSelection: allowsMultipleSelection, onCompletion: onCompletion, onCancellation: {})
    }
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], allowsMultipleSelection: Bool, onCompletion: @escaping (Result<[URL], Error>) -> Void,
                             onCancellation: @escaping () -> Void) -> some View {
        nodes("importer") { ns, ctx in
            if isPresented.wrappedValue, !ctx.dryRun {
                isPresented.wrappedValue = false
                let folders = allowedContentTypes.contains { $0 == .folder || $0 == .directory }
                let extensions = allowedContentTypes.compactMap(\.preferredFilenameExtension)
                let urls = Runway.backend.services.chooseFiles(title: "Open", allowsMultiple: allowsMultipleSelection, canChooseDirectories: folders,
                                                               extensions: extensions.count == allowedContentTypes.count ? extensions : [])
                if let urls, !urls.isEmpty { onCompletion(.success(urls)) } else { onCancellation() }
            }
            return ns
        }
    }
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes, onCompletion: onCompletion, onCancellation: {})
    }
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], onCompletion: @escaping (Result<URL, Error>) -> Void,
                             onCancellation: @escaping () -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: allowedContentTypes, allowsMultipleSelection: false, onCompletion: { result in
            switch result {
            case .success(let urls): if let first = urls.first { onCompletion(.success(first)) }
            case .failure(let error): onCompletion(.failure(error))
            }
        }, onCancellation: onCancellation)
    }
}

/// An alert as a small modal window: title, message, buttons trailing.
/// Runs after a button's action (alerts and dialogs dismiss themselves).
struct AfterButtonAction { let run: @MainActor () -> Void }
struct AfterButtonActionKey: EnvironmentKey { static var defaultValue: AfterButtonAction? { nil } }

struct AlertBody: View {
    let title: String
    let message: AnyView
    let actions: AnyView
    let isPresented: Binding<Bool>
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            message.font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Spacer()
                // As in SwiftUI, any button in an alert dismisses it after its action.
                actions.environment { env in
                    env._buttonRole = nil
                    env[AfterButtonActionKey.self] = AfterButtonAction { isPresented.wrappedValue = false }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 280, maxWidth: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: AppKit bridges

/// A view controller showing a SwiftUI view in an NSWindow.
@preconcurrency @MainActor
open class NSHostingController<Content: View>: NSViewController {
    public var rootView: Content { didSet { hostingView.rootView = rootView } }
    public var sizingOptions: NSHostingSizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
    private lazy var hostingView = NSHostingView(rootView: rootView)

    public init(rootView: Content) {
        RunwayPlatform.installDefaultBackend()
        SwiftUIRuntime.install()
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }
    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }

    open override func loadView() { view = hostingView }

    open override var preferredContentSize: CGSize {
        get { sizingOptions.contains(.preferredContentSize) || sizingOptions.contains(.intrinsicContentSize) ? hostingView.fittingSize : super.preferredContentSize }
        set { super.preferredContentSize = newValue }
    }
    open override var contentSizeForWindow: CGSize? { sizingOptions.isEmpty ? nil : hostingView.fittingSize }
    public func sizeThatFits(in size: CGSize) -> CGSize { hostingView.fittingSize }
}

public struct NSHostingSizingOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let minSize = NSHostingSizingOptions(rawValue: 1)
    public static let intrinsicContentSize = NSHostingSizingOptions(rawValue: 2)
    public static let maxSize = NSHostingSizingOptions(rawValue: 4)
    public static let preferredContentSize = NSHostingSizingOptions(rawValue: 8)
    public static let standardBounds: NSHostingSizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
}

/// An NSView showing a SwiftUI view.
@preconcurrency @MainActor
open class NSHostingView<Content: View>: NSView, KeyHandling {
    public var rootView: Content { didSet { host.setRoot(rootView) } }
    public var sizingOptions: NSHostingSizingOptions = .standardBounds
    let host: ViewHost

    public init(rootView: Content) {
        RunwayPlatform.installDefaultBackend()
        SwiftUIRuntime.install()
        self.rootView = rootView
        let container = Runway.backend.makeWidget(.container)
        host = ViewHost(rootView, container: container)
        super.init(frame: .zero)
        Runway.backend.setChildren(widget, [(container, .zero)], contentSize: .zero)
    }
    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }

    open override var managesOwnContent: Bool { true }

    open override func frameSizeChanged(from old: CGSize) {
        Runway.backend.setChildren(widget, [(host.container, bounds)], contentSize: frame.size)
        host.setSize(frame.size)
        host.renderIfNeeded()
    }

    open override var fittingSize: CGSize {
        let s = host.idealSize()
        return CGSize(width: s.width.rounded(.up), height: s.height.rounded(.up))
    }
    open override var intrinsicContentSize: CGSize { fittingSize }

    public func handleKey(_ key: KeyPress) -> Bool { host.handleKey(key) }
}

extension Color {
    /// Follows the NSColor's light/dark provider.
    public init(nsColor: NSColor) {
        if let id = nsColor.providerID { self = ColorProviders.color(id: id) } else { self.init(rgba: nsColor.rgba(dark: false)) }
    }
    /// `Color(.systemRed)`: the NSColor as a Color.
    public init(_ color: NSColor) { self.init(nsColor: color) }
}

extension NSColor {
    public convenience init(_ color: Color) {
        self.init(name: nil) { a in
            NSColor(rgba: MainActor.assumeIsolated {
                var env = EnvironmentValues()
                env.colorScheme = a.isDark ? .dark : .light
                return color.resolve(env)
            })
        }
    }
}

extension Image {
    public init(nsImage: NSImage) {
        switch nsImage.imageSource {
        case let .pixels(w, h, px): self.init(width: w, height: h, rgba: px)
        case let .file(p): self.init(file: p)
        case let .symbol(s): self.init(systemName: s)
        case .none: self.init(systemName: "")
        }
    }
}

/// SwiftUI's hooks into lower layers, installed once.
@MainActor enum SwiftUIRuntime {
    private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        ColorProviderRegistry.registrar = { f in ColorProviders.register(f) }
    }
}

/// NSViewRepresentable: AppKit views inside SwiftUI. AppKit views other
/// than Runway's own aren't native widgets here, so the representable's
/// view shows as an empty area of its size.
@MainActor @preconcurrency
public protocol NSViewRepresentable: View where Body == Never {
    associatedtype NSViewType: NSView
    associatedtype Coordinator = Void
    func makeNSView(context: Context) -> NSViewType
    func updateNSView(_ nsView: NSViewType, context: Context)
    func makeCoordinator() -> Coordinator
    static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator)
    typealias Context = NSViewRepresentableContext<Self>
}

extension NSViewRepresentable {
    public var body: Never { fatalError() }
    public static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator) {}
}
extension NSViewRepresentable where Coordinator == Void {
    public func makeCoordinator() {}
}

public struct NSViewRepresentableContext<R: NSViewRepresentable> {
    public let coordinator: R.Coordinator
    public var environment: EnvironmentValues
    public var transaction: Transaction { Transaction() }
}

/// A view controller in a SwiftUI hierarchy: its view is hosted like an
/// NSViewRepresentable's, and the controller is kept with it.
@MainActor @preconcurrency
public protocol NSViewControllerRepresentable: View where Body == Never {
    associatedtype NSViewControllerType: NSViewController
    associatedtype Coordinator = Void
    @MainActor func makeNSViewController(context: Context) -> NSViewControllerType
    @MainActor func updateNSViewController(_ nsViewController: NSViewControllerType, context: Context)
    func makeCoordinator() -> Coordinator
    static func dismantleNSViewController(_ nsViewController: NSViewControllerType, coordinator: Coordinator)
    typealias Context = NSViewControllerRepresentableContext<Self>
}

extension NSViewControllerRepresentable {
    public var body: Never { fatalError() }
    public static func dismantleNSViewController(_ nsViewController: NSViewControllerType, coordinator: Coordinator) {}
}
extension NSViewControllerRepresentable where Coordinator == Void {
    public func makeCoordinator() {}
}

public struct NSViewControllerRepresentableContext<R: NSViewControllerRepresentable> {
    public let coordinator: R.Coordinator
    public var environment: EnvironmentValues
    public var transaction: Transaction { Transaction() }
}

/// The NSViewRepresentable an NSViewControllerRepresentable resolves through.
struct _ControllerHost<R: NSViewControllerRepresentable>: NSViewRepresentable {
    let base: R
    final class Coordinator { var controller: R.NSViewControllerType?; var inner: R.Coordinator? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let inner = base.makeCoordinator()
        let c = base.makeNSViewController(context: NSViewControllerRepresentableContext<R>(coordinator: inner, environment: context.environment))
        context.coordinator.controller = c
        context.coordinator.inner = inner
        return c.view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let c = context.coordinator.controller, let inner = context.coordinator.inner else { return }
        base.updateNSViewController(c, context: NSViewControllerRepresentableContext<R>(coordinator: inner, environment: context.environment))
    }
}

/// How an NSViewRepresentable resolves: its NSView (a Runway container,
/// with whatever Runway views it holds) is made once per path, updated
/// every render, and takes the space offered.
final class RepresentableState<R: NSViewRepresentable> {
    let view: R.NSViewType
    let coordinator: R.Coordinator
    init(view: R.NSViewType, coordinator: R.Coordinator) { self.view = view; self.coordinator = coordinator }
}

extension NSViewRepresentable {
    @MainActor func resolveRepresentable(in ctx: ResolveContext) -> [LayoutNode] {
        if ctx.dryRun { return [] }
        let key = ctx.path + ":" + String(describing: Self.self)
        let box = ctx.host.stateBox(key) { () -> RepresentableState<Self>? in nil }
        if box.value == nil {
            let coordinator = makeCoordinator()
            let context = NSViewRepresentableContext<Self>(coordinator: coordinator, environment: ctx.env)
            box.value = RepresentableState(view: makeNSView(context: context), coordinator: coordinator)
        }
        let state = box.value!
        updateNSView(state.view, context: NSViewRepresentableContext<Self>(coordinator: state.coordinator, environment: ctx.env))
        return [RepresentedNode(state.view)]
    }
}

/// Places an NSView's container and sizes the view to its frame.
final class RepresentedNode: LayoutNode {
    let view: NSView
    init(_ view: NSView) { self.view = view }
    override func sizeThatFits(_ p: ProposedSize) -> CGSize {
        let i = view.intrinsicContentSize
        return CGSize(width: p.width.flatMap { $0.isFinite ? $0 : nil } ?? (i.width > 0 ? i.width : 10),
                      height: p.height.flatMap { $0.isFinite ? $0 : nil } ?? (i.height > 0 ? i.height : 10))
    }
    override func place(_ rect: CGRect, _ sink: PlacementSink) {
        if view.frame.size != rect.size { view.frame = CGRect(origin: .zero, size: rect.size) }
        sink.add(view.widget, rect)
    }
}

extension NSViewControllerRepresentable {
    @MainActor func resolveControllerRepresentable(in ctx: ResolveContext) -> [LayoutNode] {
        _ControllerHost(base: self).resolveRepresentable(in: ctx)
    }
}
