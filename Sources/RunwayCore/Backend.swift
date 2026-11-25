// The contract between Runway's SwiftUI layer and a platform toolkit.
//
// SwiftUI semantics (state, environment, layout) live above this line and
// are the same on every platform. A backend only provides native widgets,
// measures them, places them at the frames the layout engine computes, and
// reports user input. That keeps each backend small (GTK 4 on Linux, Win32
// on Windows, a headless one for tests) and keeps layout identical across
// them.

import CoreGraphics

/// A size proposal: `nil` on an axis means "your ideal size".
public struct ProposedSize: Hashable, Sendable {
    public var width: CGFloat?
    public var height: CGFloat?
    public init(width: CGFloat?, height: CGFloat?) { self.width = width; self.height = height }
    public static let unspecified = ProposedSize(width: nil, height: nil)
    public static let zero = ProposedSize(width: 0, height: 0)
    public static let infinity = ProposedSize(width: .infinity, height: .infinity)
    public init(_ size: CGSize) { self.init(width: size.width, height: size.height) }
    public func replacingUnspecified(by size: CGSize) -> CGSize { CGSize(width: width ?? size.width, height: height ?? size.height) }
}

/// The kinds of native widget a backend provides.
public enum WidgetKind: Hashable, Sendable {
    /// Holds child widgets at absolute frames (a `RunwayCanvas` on GTK, a
    /// child window on Win32).
    case container
    /// A scroll view; children go in its `content` container.
    case scroll(horizontal: Bool, vertical: Bool)
    case text
    case button
    /// A clickable area with no chrome (plain-style buttons with custom
    /// labels, tap gestures); its children go in itself.
    case tapArea
    case toggle(ToggleKind)
    case textField(secure: Bool)
    case textEditor
    case slider
    case dropdown
    case segmented
    case progress(circular: Bool)
    case image
    case canvas
    case divider
    case link
    case colorWell
    case stepper
    case menuButton
}

public enum ToggleKind: Hashable, Sendable { case `switch`, checkbox, button }

public enum ControlSizeValue: Int, Hashable, Sendable { case mini, small, regular, large, extraLarge }

public enum TextAlignmentValue: Hashable, Sendable { case leading, center, trailing }

public enum TruncationValue: Hashable, Sendable { case head, middle, tail }

/// A run of text with its style.
public struct TextRun: Hashable, Sendable {
    public var string: String
    public var font: FontSpec
    public var color: RGBA?
    public var underline: Bool = false
    public var strikethrough: Bool = false
    public var tracking: CGFloat
    /// A highlight behind the run.
    public var background: RGBA?
    /// A link the run opens when clicked.
    public var link: String?
    public init(string: String, font: FontSpec, color: RGBA?, underline: Bool = false, strikethrough: Bool = false, tracking: CGFloat = 0,
                background: RGBA? = nil, link: String? = nil) {
        self.string = string; self.font = font; self.color = color; self.underline = underline; self.strikethrough = strikethrough
        self.tracking = tracking; self.background = background; self.link = link
    }
}

public struct StyledText: Hashable, Sendable {
    public var runs: [TextRun]
    public var alignment: TextAlignmentValue = .leading
    public var lineLimit: Int?
    public var truncation: TruncationValue = .tail
    /// The user can select and copy the text.
    public var selectable = false
    /// Extra space between lines (points).
    public var lineSpacing: CGFloat = 0
    public init(runs: [TextRun], alignment: TextAlignmentValue = .leading, lineLimit: Int? = nil, truncation: TruncationValue = .tail) {
        self.runs = runs; self.alignment = alignment; self.lineLimit = lineLimit; self.truncation = truncation
    }
    public var plain: String { runs.map(\.string).joined() }
}

/// An image for an image widget: a symbol (SF Symbols name, mapped by the
/// backend to its icon theme), a file, or pixels.
public enum ImageSource: Hashable, Sendable {
    case symbol(String)
    case file(String)
    case pixels(width: Int, height: Int, rgba: [UInt8])
    case none
}

/// Blurs preceding sibling content inside a rectangular or rounded widget frame.
public struct BackdropBlur: Equatable, Sendable {
    public let radius: CGFloat
    /// An infinite corner radius clips the frame to a capsule.
    public let cornerRadius: CGFloat

    public init(radius: CGFloat, cornerRadius: CGFloat) {
        self.radius = radius
        self.cornerRadius = cornerRadius
    }
}

/// Everything a widget shows. Backends read what applies to their kind.
public struct WidgetProps: Equatable, Sendable {
    public var text: StyledText?
    /// Button/toggle/link title, placeholder for text fields.
    public var title: String = ""
    public var placeholder: String = ""
    public var enabled = true
    public var tooltip: String?
    public var opacity: Double = 1
    public var controlSize: ControlSizeValue = .regular
    public var tint: RGBA?
    // Values.
    public var isOn = false
    public var string = ""
    public var number: Double = 0
    public var range: ClosedRange<Double> = 0...1
    public var step: Double?
    public var options: [String] = []
    public var selected: Int = -1
    public var indeterminate = false
    public var color: RGBA = .black
    // Roles.
    public var isDefault = false
    public var isCancel = false
    public var isDestructive = false
    public var prominent = false
    public var bordered = true
    public var capsuleButton = false
    public var hasContent = false
    // Image.
    public var image: ImageSource = .none
    public var imageSymbolVariant: String?
    public var imageTint: RGBA?
    public var imagePointSize: CGFloat = 13
    // Canvas.
    public var drawing: [DrawCommand] = []
    /// A text editor's selection to apply (Unicode scalar offsets); nil
    /// leaves the user's.
    public var selection: Range<Int>?
    public var backdropBlur: BackdropBlur?
    public var clips = false
    /// A canvas that takes pointer events where it's drawn (SwiftUI's
    /// filled shapes); canvases are otherwise transparent to the pointer.
    public var hitTestable = false
    /// A tap area's clicks per tap (2: double-click).
    public var tapCount = 1
    /// A text editor or list without its own background (SwiftUI's
    /// scrollContentBackground(.hidden)).
    public var clearBackground = false
    public init() {}
}

/// What a widget reports back. Closures are replaced on every render.
@MainActor public struct WidgetEvents {
    public var onTap: (() -> Void)?
    public var onTapLocation: ((CGPoint) -> Void)?
    public var onToggle: ((Bool) -> Void)?
    public var onText: ((String) -> Void)?
    public var onSubmit: (() -> Void)?
    public var onNumber: ((Double) -> Void)?
    public var onSelect: ((Int) -> Void)?
    public var onColor: ((RGBA) -> Void)?
    public var onFocus: ((Bool) -> Void)?
    /// A text editor's selection changed (Unicode scalar offsets).
    public var onSelection: ((Range<Int>) -> Void)?
    public var menu: [MenuItemSpec] = []
    public init() {}
}

/// A menu item for menus and context menus.
@MainActor public struct MenuItemSpec {
    public var title: String
    public var enabled: Bool
    public var checked: Bool
    public var isSeparator: Bool
    public var children: [MenuItemSpec]
    public var action: (() -> Void)?
    public init(title: String, enabled: Bool = true, checked: Bool = false, isSeparator: Bool = false, children: [MenuItemSpec] = [], action: (() -> Void)? = nil) {
        self.title = title; self.enabled = enabled; self.checked = checked; self.isSeparator = isSeparator; self.children = children; self.action = action
    }
    public static var separator: MenuItemSpec { MenuItemSpec(title: "", isSeparator: true) }
}

/// A native widget, opaque to the layer above.
@MainActor public protocol NativeWidget: AnyObject {}

/// A top-level window.
@MainActor public protocol NativeWindow: AnyObject {
    var content: NativeWidget { get }
    var title: String { get set }
    /// The content area's size.
    var contentSize: CGSize { get }
    func setContentSize(_ size: CGSize)
    func setMinimumSize(_ size: CGSize)
    func setResizable(_ resizable: Bool)
    func show()
    /// Shows the window without making it the active one (a panel that
    /// can't become key, such as a floating formatting bar).
    func showWithoutActivating()
    func close()
    func center()
    /// Called with the new content size when the user resizes.
    var onResize: ((CGSize) -> Void)? { get set }
    /// Return false to keep the window open.
    var onCloseRequest: (() -> Bool)? { get set }
    var onClosed: (() -> Void)? { get set }
    /// Key shortcuts: Return/Escape for default/cancel buttons, menus.
    var onKey: ((KeyPress) -> Bool)? { get set }
}

extension NativeWindow {
    public func showWithoutActivating() { show() }
}

public struct KeyPress: Hashable, Sendable {
    public var key: String           // "return", "escape", "tab", "a"…, lowercased
    public var command: Bool         // ⌘ on macOS; Ctrl on Linux and Windows
    public var shift: Bool
    public var option: Bool
    public var control: Bool
    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }
}

public struct WindowOptions: Sendable {
    public var title: String
    public var size: CGSize
    public var resizable: Bool
    public var modal: Bool
    /// The window's own titlebar row: window buttons, the menu bar and the
    /// title (`.standard`), or none (a sheet).
    public var titlebar: Titlebar = .standard
    public enum Titlebar: Sendable { case standard, none }
    public init(title: String, size: CGSize, resizable: Bool = true, modal: Bool = false, titlebar: Titlebar = .standard) {
        self.title = title; self.size = size; self.resizable = resizable; self.modal = modal; self.titlebar = titlebar
    }
}

public enum ColorSchemeValue: Hashable, Sendable { case light, dark }

/// A platform toolkit.
@MainActor public protocol Backend: AnyObject {
    var name: String { get }

    // Widgets.
    func makeWidget(_ kind: WidgetKind) -> NativeWidget
    func update(_ widget: NativeWidget, props: WidgetProps, events: WidgetEvents)
    /// The widget's size for a proposal: its natural size, wrapped to the
    /// proposed width where it can wrap.
    func measure(_ widget: NativeWidget, proposal: ProposedSize) -> CGSize
    /// The chrome a button or scroll view adds around its content.
    func contentInsets(_ widget: NativeWidget) -> EdgeInsetsValue
    /// The container children go in: the widget itself for containers and
    /// tap areas, the scroll view's document, the button's label area.
    func childContainer(_ widget: NativeWidget) -> NativeWidget
    /// Places `children` (in drawing order) in `container` at the given
    /// frames, removing any others it holds; `contentSize` is what the
    /// container asks for (a scroll view's document size).
    func setChildren(_ container: NativeWidget, _ children: [(NativeWidget, CGRect)], contentSize: CGSize)
    func destroy(_ widget: NativeWidget)

    // Windows and the loop.
    func makeWindow(_ options: WindowOptions, parent: NativeWindow?) -> NativeWindow
    func run(_ start: @escaping @MainActor () -> Void)
    func quit()
    /// Runs `work` soon, on the main loop, once.
    func schedule(_ work: @escaping @MainActor () -> Void)
    var colorScheme: ColorSchemeValue { get }
    var onColorSchemeChange: (() -> Void)? { get set }

    // Platform services AppKit-style code expects.
    var services: PlatformServices { get }
}

public struct EdgeInsetsValue: Hashable, Sendable {
    public var top, leading, bottom, trailing: CGFloat
    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    public static let zero = EdgeInsetsValue()
}

/// Desktop integration, each mapped to the platform's own mechanism.
@MainActor public protocol PlatformServices: AnyObject {
    func copyToClipboard(string: String)
    func copyToClipboard(fileURLs: [URL])
    func clipboardString() -> String?
    /// Opens a URL or file with its default handler (xdg-open, ShellExecute).
    func open(_ url: URL) -> Bool
    /// Shows files in the file manager (FileManager1 over D-Bus or the
    /// parent folder on Linux, `explorer /select,` on Windows).
    func reveal(_ urls: [URL])
    /// Plays a named system sound (freedesktop sound theme, Windows system
    /// sounds), or beeps.
    func playSound(named: String) -> Bool
    func beep()
    /// File dialogs; `nil` when cancelled.
    func chooseFiles(title: String, allowsMultiple: Bool, canChooseDirectories: Bool, extensions: [String]) -> [URL]?
    func chooseSaveLocation(title: String, suggestedName: String) -> URL?
    /// A blocking alert; returns the index of the button clicked.
    func alert(title: String, message: String, buttons: [String], destructive: Int?) -> Int
}
