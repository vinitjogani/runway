// A backend with no display: deterministic text metrics, widgets recorded
// as a tree. Unit tests drive the SwiftUI layer through it, and
// `runway run --headless` prints what a window would show.

import CoreGraphics

@MainActor public final class HeadlessWidget: NativeWidget, CustomStringConvertible {
    public let kind: WidgetKind
    public var props = WidgetProps()
    public var events = WidgetEvents()
    public var frame: CGRect = .zero
    public var children: [HeadlessWidget] = []
    public var contentSize: CGSize = .zero
    public weak var parent: HeadlessWidget?
    public var destroyed = false
    init(_ kind: WidgetKind) { self.kind = kind }

    public nonisolated var description: String { "HeadlessWidget" }

    /// Depth-first, drawing order.
    public var all: [HeadlessWidget] { [self] + children.flatMap(\.all) }

    /// Frame in window coordinates.
    public var windowFrame: CGRect {
        var f = frame
        var p = parent
        while let q = p { f = f.offsetBy(dx: q.frame.minX, dy: q.frame.minY); p = q.parent }
        return f
    }

    public func dump(_ indent: String = "") -> String {
        let f = frame
        let box = "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)))"
        var label = "\(kind)"
        switch kind {
        case .text: label = "text \"\(props.text?.plain ?? "")\""
        case .button: label = "button \"\(props.title)\"" + (props.isDefault ? " [default]" : "") + (props.enabled ? "" : " [disabled]")
        case .toggle: label = "toggle \"\(props.title)\" \(props.isOn ? "on" : "off")"
        case .textField: label = "textField \"\(props.string)\" placeholder=\"\(props.placeholder)\""
        case .slider: label = "slider \(props.number)"
        case .dropdown, .segmented: label = "\(kind) \(props.options) selected=\(props.selected)"
        case .progress: label = "progress \(props.indeterminate ? "indeterminate" : "\(props.number)")"
        case .image: label = "image \(props.image)"
        case .canvas: label = "canvas \(props.drawing.count) ops"
        case .link: label = "link \"\(props.title)\""
        default: break
        }
        return ([indent + label + " " + box] + children.map { $0.dump(indent + "  ") }).joined(separator: "\n")
    }
}

@MainActor public final class HeadlessWindow: NativeWindow {
    public let content: NativeWidget
    public var title: String
    public private(set) var contentSize: CGSize
    public var onResize: ((CGSize) -> Void)?
    public var onCloseRequest: (() -> Bool)?
    public var onClosed: (() -> Void)?
    public var onKey: ((KeyPress) -> Bool)?
    public var isVisible = false
    public var minimumSize: CGSize = .zero
    public var resizable = true
    weak var backend: HeadlessBackend?

    init(_ options: WindowOptions, backend: HeadlessBackend) {
        title = options.title
        contentSize = options.size
        resizable = options.resizable
        content = HeadlessWidget(.container)
        self.backend = backend
    }
    public var root: HeadlessWidget { content as! HeadlessWidget }
    public func setContentSize(_ size: CGSize) { contentSize = size; root.frame.size = size }
    public func setMinimumSize(_ size: CGSize) { minimumSize = size }
    public func setResizable(_ resizable: Bool) { self.resizable = resizable }
    public func show() { isVisible = true }
    public func close() {
        guard isVisible else { return }
        isVisible = false
        onClosed?()
        backend?.windows.removeAll { $0 === self }
    }
    public func center() {}
    /// Simulates the user resizing the window.
    public func resize(to size: CGSize) { setContentSize(size); onResize?(size) }
    @discardableResult public func press(_ key: KeyPress) -> Bool { onKey?(key) ?? false }
}

@MainActor public final class HeadlessServices: PlatformServices {
    public var clipboard: String?
    public var clipboardFiles: [URL] = []
    public var opened: [URL] = []
    public var revealed: [URL] = []
    public var sounds: [String] = []
    public var alertAnswer = 0
    public func copyToClipboard(string: String) { clipboard = string }
    public func copyToClipboard(fileURLs: [URL]) { clipboardFiles = fileURLs; clipboard = fileURLs.map(\.path).joined(separator: "\n") }
    public func clipboardString() -> String? { clipboard }
    public func open(_ url: URL) -> Bool { opened.append(url); return true }
    public func reveal(_ urls: [URL]) { revealed += urls }
    public func playSound(named: String) -> Bool { sounds.append(named); return true }
    public func beep() { sounds.append("beep") }
    public func chooseFiles(title: String, allowsMultiple: Bool, canChooseDirectories: Bool, extensions: [String]) -> [URL]? { nil }
    public func chooseSaveLocation(title: String, suggestedName: String) -> URL? { nil }
    public func alert(title: String, message: String, buttons: [String], destructive: Int?) -> Int { alertAnswer }
}

@MainActor public final class HeadlessBackend: Backend {
    public let name = "headless"
    public var colorScheme: ColorSchemeValue = .light
    public var onColorSchemeChange: (() -> Void)?
    public let headlessServices = HeadlessServices()
    public var services: PlatformServices { headlessServices }
    public internal(set) var windows: [HeadlessWindow] = []
    private var queue: [@MainActor () -> Void] = []
    private var running = false

    public init() {}

    public func makeWidget(_ kind: WidgetKind) -> NativeWidget {
        let w = HeadlessWidget(kind)
        if case .scroll = kind {
            let doc = HeadlessWidget(.container)
            doc.parent = w
            w.children = [doc]
        }
        return w
    }

    public func update(_ widget: NativeWidget, props: WidgetProps, events: WidgetEvents) {
        let w = widget as! HeadlessWidget
        w.props = props
        w.events = events
    }

    /// Average glyph advance as a fraction of the point size.
    public static let advance: CGFloat = 0.55
    public static func lineHeight(_ size: CGFloat) -> CGFloat { (size * 1.25).rounded(.up) }

    public static func measureText(_ t: StyledText, width: CGFloat?) -> CGSize {
        let size = t.runs.map(\.font.size).max() ?? 13
        let lines = t.plain.split(separator: "\n", omittingEmptySubsequences: false)
        var widest: CGFloat = 0
        var count = 0
        for line in lines {
            let natural = (CGFloat(line.count) * size * advance).rounded(.up)
            if let w = width, natural > w, w > 0, t.lineLimit != 1 {
                // Greedy word wrap.
                var lineW: CGFloat = 0
                var n = 1
                for word in line.split(separator: " ") {
                    let ww = CGFloat(word.count + 1) * size * advance
                    if lineW + ww > w, lineW > 0 { n += 1; lineW = ww } else { lineW += ww }
                }
                widest = max(widest, w)
                count += n
            } else {
                widest = max(widest, width.map { min($0, natural) } ?? natural)
                count += 1
            }
        }
        if let limit = t.lineLimit { count = min(count, limit) }
        return CGSize(width: widest, height: CGFloat(max(count, 1)) * lineHeight(size))
    }

    /// Lines of `lineHeight(size)` with the baseline at 80% of each.
    public func textBaselines(_ widget: NativeWidget, width: CGFloat?) -> (first: CGFloat, last: CGFloat)? {
        let w = widget as! HeadlessWidget
        guard w.kind == .text, let t = w.props.text else { return nil }
        let size = t.runs.map(\.font.size).max() ?? 13
        let line = Self.lineHeight(size)
        let h = Self.measureText(t, width: width).height
        return (line * 0.8, h - line * 0.2)
    }

    public func measure(_ widget: NativeWidget, proposal: ProposedSize) -> CGSize {
        let w = widget as! HeadlessWidget
        let p = w.props
        let scale: CGFloat = p.controlSize == .large ? 1.2 : p.controlSize == .small ? 0.85 : 1
        func label(_ s: String) -> CGFloat { (CGFloat(s.count) * 13 * Self.advance).rounded(.up) }
        switch w.kind {
        case .text:
            return Self.measureText(p.text ?? StyledText(runs: []), width: proposal.width)
        case .button:
            return CGSize(width: label(p.title) + 24, height: 22 * scale)
        case .link:
            return CGSize(width: label(p.title), height: 16)
        case .toggle(let k):
            let box: CGFloat = k == .switch ? 38 : 16
            return CGSize(width: box + (p.title.isEmpty ? 0 : label(p.title) + 6), height: 22)
        case .textField, .colorWell, .stepper:
            return CGSize(width: proposal.width ?? 120, height: 22 * scale)
        case .textEditor:
            return CGSize(width: proposal.width ?? 200, height: proposal.height ?? 100)
        case .slider:
            return CGSize(width: proposal.width ?? 120, height: 20)
        case .dropdown, .menuButton:
            return CGSize(width: (p.options.map(label).max() ?? label(p.title)) + 36, height: 22 * scale)
        case .segmented:
            return CGSize(width: p.options.map { label($0) + 20 }.reduce(0, +), height: 22 * scale)
        case .progress(let circular):
            return circular ? CGSize(width: 20, height: 20) : CGSize(width: proposal.width ?? 120, height: 6)
        case .image:
            if case let .pixels(iw, ih, _) = p.image { return CGSize(width: iw, height: ih) }
            return CGSize(width: p.imagePointSize * 1.2, height: p.imagePointSize * 1.2)
        case .divider:
            return CGSize(width: 1, height: 1)
        case .container, .scroll, .tapArea, .canvas:
            return proposal.replacingUnspecified(by: .zero)
        }
    }

    public func contentInsets(_ widget: NativeWidget) -> EdgeInsetsValue {
        let w = widget as! HeadlessWidget
        if w.kind == .button { return EdgeInsetsValue(top: 3, leading: 10, bottom: 3, trailing: 10) }
        return .zero
    }

    public func childContainer(_ widget: NativeWidget) -> NativeWidget {
        let w = widget as! HeadlessWidget
        if case .scroll = w.kind { return w.children[0] }
        return w
    }

    /// How many times children were (re)placed (tests of incremental commits).
    public private(set) var setChildrenCalls = 0

    public func setChildren(_ container: NativeWidget, _ children: [(NativeWidget, CGRect)], contentSize: CGSize) {
        setChildrenCalls += 1
        let c = container as! HeadlessWidget
        c.contentSize = contentSize
        c.children = children.map { pair in
            let w = pair.0 as! HeadlessWidget
            w.frame = pair.1
            w.parent = c
            return w
        }
        if let parent = c.parent, case .scroll = parent.kind { c.frame = CGRect(origin: .zero, size: contentSize) }
    }

    public func destroy(_ widget: NativeWidget) {
        let w = widget as! HeadlessWidget
        w.destroyed = true
        w.parent?.children.removeAll { $0 === w }
    }

    public func makeWindow(_ options: WindowOptions, parent: NativeWindow?) -> NativeWindow {
        let w = HeadlessWindow(options, backend: self)
        w.root.frame = CGRect(origin: .zero, size: options.size)
        windows.append(w)
        return w
    }

    public func run(_ start: @escaping @MainActor () -> Void) {
        start()
        drain()
    }

    public func quit() { running = false }

    public func schedule(_ work: @escaping @MainActor () -> Void) { queue.append(work) }

    /// Runs scheduled work until none is left (tests call this after events).
    public func drain(limit: Int = 1000) {
        var n = 0
        while !queue.isEmpty, n < limit {
            let w = queue.removeFirst()
            w()
            n += 1
        }
    }
}
