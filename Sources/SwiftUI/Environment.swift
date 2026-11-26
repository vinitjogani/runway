// EnvironmentValues: what flows down the tree (fonts, colours, styles,
// enabled state, actions such as dismiss and openURL).

import Foundation
#if os(Windows)
import WinSDK
#endif
import RunwayCore

public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

public struct EnvironmentValues: @unchecked Sendable {
    var values: [ObjectIdentifier: Any] = [:]
    var objects: [ObjectIdentifier: AnyObject] = [:]
    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { values[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set {
            // Writing what's already there would copy the storage (it's
            // shared with the parent's environment) and make every view
            // below look like it got a new environment.
            if MainThread.isCurrent, let old = values[ObjectIdentifier(key)], MainActor.assumeIsolated({ FieldLayout.equalAny(old, newValue) }),
               Self.nilness(old) == Self.nilness(newValue) { return }
            values[ObjectIdentifier(key)] = newValue
        }
    }

    /// Whether an optional value is nil (nil for non-optionals): values that
    /// compare as view inputs do (closures ignored) still differ in this.
    static func nilness(_ v: Any) -> Bool? {
        let m = Mirror(reflecting: v)
        return m.displayStyle == .optional ? m.children.isEmpty : nil
    }

    /// Whether two environments hold the same values (a view resolved in
    /// one would come out the same in the other). Shared storage answers
    /// at once; otherwise values compare as view inputs do.
    @MainActor func memoEquals(_ other: EnvironmentValues) -> Bool {
        let a = Self.storageID(values), b = Self.storageID(other.values)
        let oa = Self.storageID(objects), ob = Self.storageID(other.objects)
        if a == b, oa == ob { return true }
        // Siblings (ForEach rows) compare the same pair of storages.
        if let last = Self.lastComparison,
           Self.storageID(last.x.values) == a, Self.storageID(last.y.values) == b,
           Self.storageID(last.x.objects) == oa, Self.storageID(last.y.objects) == ob {
            return last.equal
        }
        let equal = Self.compare(self, other)
        // Holding both keeps their storages alive, so the addresses compared
        // above can't be reused by other values.
        Self.lastComparison = (self, other, equal)
        return equal
    }

    @MainActor private static func compare(_ x: EnvironmentValues, _ y: EnvironmentValues) -> Bool {
        guard x.values.count == y.values.count, x.objects.count == y.objects.count else { return false }
        for (k, v) in x.objects { guard let o = y.objects[k], o === v else { return false } }
        for (k, v) in x.values { guard let o = y.values[k], FieldLayout.equalAny(v, o) else { return false } }
        return true
    }

    private static func storageID<K, V>(_ d: [K: V]) -> UInt { withUnsafeBytes(of: d) { $0.load(as: UInt.self) } }
    @MainActor private static var lastComparison: (x: EnvironmentValues, y: EnvironmentValues, equal: Bool)?

    // Built-in values. Internal ones start with an underscore.
    public var font: Font? { get { self[FontKey.self] } set { self[FontKey.self] = newValue } }
    public var colorScheme: ColorScheme { get { self[ColorSchemeKey.self] } set { self[ColorSchemeKey.self] = newValue } }
    public var isEnabled: Bool { get { self[EnabledKey.self] } set { self[EnabledKey.self] = newValue } }
    public var controlSize: ControlSize { get { self[ControlSizeKey.self] } set { self[ControlSizeKey.self] = newValue } }
    public var lineLimit: Int? { get { self[LineLimitKey.self] } set { self[LineLimitKey.self] = newValue } }
    public var truncationMode: Text.TruncationMode { get { self[TruncationKey.self] } set { self[TruncationKey.self] = newValue } }
    public var multilineTextAlignment: TextAlignment { get { self[AlignmentKey.self] } set { self[AlignmentKey.self] = newValue } }
    public var isScrollEnabled: Bool { get { self[ScrollEnabledKey.self] } set { self[ScrollEnabledKey.self] = newValue } }
    public var locale: Locale { get { self[LocaleKey.self] } set { self[LocaleKey.self] = newValue } }
    public var calendar: Calendar { get { self[CalendarKey.self] } set { self[CalendarKey.self] = newValue } }
    public var timeZone: TimeZone { get { self[TimeZoneKey.self] } set { self[TimeZoneKey.self] = newValue } }
    public var dismiss: DismissAction { get { self[DismissKey.self] } set { self[DismissKey.self] = newValue } }
    public var openURL: OpenURLAction { get { self[OpenURLKey.self] } set { self[OpenURLKey.self] = newValue } }
    public var openWindow: OpenWindowAction { OpenWindowAction() }
    public var dismissWindow: DismissWindowAction { DismissWindowAction() }
    public var isPresented: Bool { get { self[PresentedKey.self] } set { self[PresentedKey.self] = newValue } }
    public var displayScale: CGFloat { get { self[DisplayScaleKey.self] } set { self[DisplayScaleKey.self] = newValue } }
    public var horizontalSizeClass: UserInterfaceSizeClass? { get { self[HorizontalSizeClassKey.self] } set { self[HorizontalSizeClassKey.self] = newValue } }
    public var verticalSizeClass: UserInterfaceSizeClass? { get { self[VerticalSizeClassKey.self] } set { self[VerticalSizeClassKey.self] = newValue } }
    public var layoutDirection: LayoutDirection { get { self[LayoutDirectionKey.self] } set { self[LayoutDirectionKey.self] = newValue } }
    public var undoManager: AnyObject? { nil }
    public var scenePhase: ScenePhase { get { self[ScenePhaseKey.self] } set { self[ScenePhaseKey.self] = newValue } }
    public var accessibilityReduceMotion: Bool { false }
    public var accessibilityReduceTransparency: Bool { false }
    public var accessibilityDifferentiateWithoutColor: Bool { false }
    public var accessibilityInvertColors: Bool { false }
    public var colorSchemeContrast: ColorSchemeContrast { .standard }

    var _foreground: AnyShapeStyle? { get { self[ForegroundKey.self] } set { self[ForegroundKey.self] = newValue } }
    var _tint: Color? { get { self[TintKey.self] } set { self[TintKey.self] = newValue } }
    var _fontWeight: Font.Weight? { get { self[FontWeightKey.self] } set { self[FontWeightKey.self] = newValue } }
    var _italic: Bool { get { self[ItalicKey.self] } set { self[ItalicKey.self] = newValue } }
    var _monospacedDigit: Bool { get { self[MonoDigitKey.self] } set { self[MonoDigitKey.self] = newValue } }
    var _opacity: Double { get { self[OpacityKey.self] } set { self[OpacityKey.self] = newValue } }
    var _help: String? { get { self[HelpKey.self] } set { self[HelpKey.self] = newValue } }
    var _labelsHidden: Bool { get { self[LabelsHiddenKey.self] } set { self[LabelsHiddenKey.self] = newValue } }
    var _pickerStyle: PickerStyleKind { get { self[PickerStyleKey.self] } set { self[PickerStyleKey.self] = newValue } }
    var _toggleStyle: ToggleStyleKind { get { self[ToggleStyleKey.self] } set { self[ToggleStyleKey.self] = newValue } }
    var _buttonStyle: ButtonStyleKind { get { self[ButtonStyleKey.self] } set { self[ButtonStyleKey.self] = newValue } }
    var _customButtonStyle: AnyButtonStyle? { get { self[CustomButtonStyleKey.self] } set { self[CustomButtonStyleKey.self] = newValue } }
    var _customToggleStyle: AnyToggleStyle? { get { self[CustomToggleStyleKey.self] } set { self[CustomToggleStyleKey.self] = newValue } }
    var _customLabelStyle: AnyLabelStyle? { get { self[CustomLabelStyleKey.self] } set { self[CustomLabelStyleKey.self] = newValue } }
    /// Whether the nearest focusable view has focus (false: focus isn't tracked into SwiftUI yet).
    public var isFocused: Bool { get { self[IsFocusedKey.self] } set { self[IsFocusedKey.self] = newValue } }
    var _textFieldStyle: TextFieldStyleKind { get { self[TextFieldStyleKey.self] } set { self[TextFieldStyleKey.self] = newValue } }
    var _formStyle: FormStyleKind { get { self[FormStyleKey.self] } set { self[FormStyleKey.self] = newValue } }
    var _labelStyle: LabelStyleKind { get { self[LabelStyleKey.self] } set { self[LabelStyleKey.self] = newValue } }
    var _progressStyle: ProgressStyleKind { get { self[ProgressStyleKey.self] } set { self[ProgressStyleKey.self] = newValue } }
    var _inForm: Bool { get { self[InFormKey.self] } set { self[InFormKey.self] = newValue } }
    var _inFormRow: Bool { get { self[InFormRowKey.self] } set { self[InFormRowKey.self] = newValue } }
    var _stackAxis: Axis? { get { self[StackAxisKey.self] } set { self[StackAxisKey.self] = newValue } }
    var _onSubmit: (@MainActor () -> Void)? { get { self[SubmitKey.self] } set { self[SubmitKey.self] = newValue } }
    var _shortcut: KeyboardShortcut? { get { self[ShortcutKey.self] } set { self[ShortcutKey.self] = newValue } }
    var _buttonRole: ButtonRole? { get { self[RoleKey.self] } set { self[RoleKey.self] = newValue } }
    var _host: ViewHost? { get { (self[HostKey.self] as WeakHost).host } set { self[HostKey.self] = WeakHost(host: newValue) } }
    var _inMenu: Bool { get { self[InMenuKey.self] } set { self[InMenuKey.self] = newValue } }
}

struct WeakHost { weak var host: ViewHost? }

/// Whether this is the main thread, without Foundation's Thread.isMainThread
/// (a system call on Linux): the main thread's pthread, read once.
enum MainThread {
    #if os(Windows)
    nonisolated(unsafe) private static var main: DWORD? = nil
    static func record() { if main == nil { main = GetCurrentThreadId() } }
    static var isCurrent: Bool { main == GetCurrentThreadId() }
    #else
    nonisolated(unsafe) private static var main: pthread_t? = nil
    /// Called on the main thread before any view is resolved.
    static func record() { if main == nil { main = pthread_self() } }
    static var isCurrent: Bool {
        guard let m = main else { return false }
        return pthread_equal(m, pthread_self()) != 0
    }
    #endif
}

struct FontKey: EnvironmentKey { static var defaultValue: Font? { nil } }
struct ColorSchemeKey: EnvironmentKey { static var defaultValue: ColorScheme { .light } }
struct EnabledKey: EnvironmentKey { static var defaultValue: Bool { true } }
struct ControlSizeKey: EnvironmentKey { static var defaultValue: ControlSize { .regular } }
struct LineLimitKey: EnvironmentKey { static var defaultValue: Int? { nil } }
struct TruncationKey: EnvironmentKey { static var defaultValue: Text.TruncationMode { .tail } }
struct AlignmentKey: EnvironmentKey { static var defaultValue: TextAlignment { .leading } }
struct ScrollEnabledKey: EnvironmentKey { static var defaultValue: Bool { true } }
struct LocaleKey: EnvironmentKey { static var defaultValue: Locale { .current } }
struct CalendarKey: EnvironmentKey { static var defaultValue: Calendar { .current } }
struct TimeZoneKey: EnvironmentKey { static var defaultValue: TimeZone { .current } }
struct DismissKey: EnvironmentKey { static var defaultValue: DismissAction { DismissAction(nil) } }
struct OpenURLKey: EnvironmentKey { static var defaultValue: OpenURLAction { OpenURLAction(handler: nil) } }
struct PresentedKey: EnvironmentKey { static var defaultValue: Bool { false } }
struct DisplayScaleKey: EnvironmentKey { static var defaultValue: CGFloat { 1 } }
struct HorizontalSizeClassKey: EnvironmentKey { static var defaultValue: UserInterfaceSizeClass? { .regular } }
struct VerticalSizeClassKey: EnvironmentKey { static var defaultValue: UserInterfaceSizeClass? { .regular } }
struct LayoutDirectionKey: EnvironmentKey { static var defaultValue: LayoutDirection { .leftToRight } }
struct ScenePhaseKey: EnvironmentKey { static var defaultValue: ScenePhase { .active } }
struct ForegroundKey: EnvironmentKey { static var defaultValue: AnyShapeStyle? { nil } }
struct TintKey: EnvironmentKey { static var defaultValue: Color? { nil } }
struct FontWeightKey: EnvironmentKey { static var defaultValue: Font.Weight? { nil } }
struct ItalicKey: EnvironmentKey { static var defaultValue: Bool { false } }
struct MonoDigitKey: EnvironmentKey { static var defaultValue: Bool { false } }
struct OpacityKey: EnvironmentKey { static var defaultValue: Double { 1 } }
struct HelpKey: EnvironmentKey { static var defaultValue: String? { nil } }
struct LabelsHiddenKey: EnvironmentKey { static var defaultValue: Bool { false } }
struct PickerStyleKey: EnvironmentKey { static var defaultValue: PickerStyleKind { .automatic } }
struct ToggleStyleKey: EnvironmentKey { static var defaultValue: ToggleStyleKind { .automatic } }
struct ButtonStyleKey: EnvironmentKey { static var defaultValue: ButtonStyleKind { .automatic } }
struct CustomButtonStyleKey: EnvironmentKey { static var defaultValue: AnyButtonStyle? { nil } }
struct CustomToggleStyleKey: EnvironmentKey { static var defaultValue: AnyToggleStyle? { nil } }
struct CustomLabelStyleKey: EnvironmentKey { static var defaultValue: AnyLabelStyle? { nil } }
struct IsFocusedKey: EnvironmentKey { static var defaultValue: Bool { false } }
struct TextFieldStyleKey: EnvironmentKey { static var defaultValue: TextFieldStyleKind { .automatic } }
struct FormStyleKey: EnvironmentKey { static var defaultValue: FormStyleKind { .automatic } }
struct LabelStyleKey: EnvironmentKey { static var defaultValue: LabelStyleKind { .automatic } }
struct ProgressStyleKey: EnvironmentKey { static var defaultValue: ProgressStyleKind { .automatic } }
struct InFormKey: EnvironmentKey { static var defaultValue: Bool { false } }
struct InFormRowKey: EnvironmentKey { static var defaultValue: Bool { false } }
struct StackAxisKey: EnvironmentKey { static var defaultValue: Axis? { nil } }
struct SubmitKey: EnvironmentKey { static var defaultValue: (@MainActor () -> Void)? { nil } }
struct ShortcutKey: EnvironmentKey { static var defaultValue: KeyboardShortcut? { nil } }
struct RoleKey: EnvironmentKey { static var defaultValue: ButtonRole? { nil } }
struct HostKey: EnvironmentKey { static var defaultValue: WeakHost { WeakHost(host: nil) } }
struct InMenuKey: EnvironmentKey { static var defaultValue: Bool { false } }

public enum ColorScheme: Hashable, Sendable, CaseIterable { case light, dark }
public enum ColorSchemeContrast: Hashable, Sendable { case standard, increased }
public enum UserInterfaceSizeClass: Hashable, Sendable { case compact, regular }
public enum LayoutDirection: Hashable, Sendable { case leftToRight, rightToLeft }
public enum ScenePhase: Hashable, Sendable { case background, inactive, active }

public enum ControlSize: Hashable, Sendable, CaseIterable {
    case mini, small, regular, large, extraLarge
    var value: ControlSizeValue {
        switch self {
        case .mini: .mini
        case .small: .small
        case .regular: .regular
        case .large: .large
        case .extraLarge: .extraLarge
        }
    }
}

public enum TextAlignment: Hashable, Sendable, CaseIterable { case leading, center, trailing }

public struct DismissAction: @unchecked Sendable {
    let action: (@MainActor () -> Void)?
    init(_ action: (@MainActor () -> Void)?) { self.action = action }
    @preconcurrency @MainActor public func callAsFunction() { action?() }
}

public struct OpenURLAction: @unchecked Sendable {
    public struct Result: Sendable {
        public static let handled = Result()
        public static let discarded = Result()
        public static let systemAction = Result()
    }
    let handler: ((URL) -> Result)?
    public init(handler: @escaping (URL) -> Result) { self.handler = handler }
    init(handler: ((URL) -> Result)?) { self.handler = handler }
    @preconcurrency @MainActor public func callAsFunction(_ url: URL) {
        if let h = handler { _ = h(url) } else { _ = Runway.backend.services.open(url) }
    }
}

public struct OpenWindowAction: Sendable {
    @preconcurrency @MainActor public func callAsFunction(id: String) { SceneRegistry.shared.open(id: id) }
    @preconcurrency @MainActor public func callAsFunction<D: Codable & Hashable>(id: String, value: D) { SceneRegistry.shared.open(id: id) }
}

public struct DismissWindowAction: Sendable {
    @preconcurrency @MainActor public func callAsFunction(id: String) { SceneRegistry.shared.close(id: id) }
    @preconcurrency @MainActor public func callAsFunction() {}
}

// MARK: Modifiers that set the environment

struct EnvironmentModifierView<Content: View>: View, PrimitiveView {
    typealias Body = Never
    let content: Content
    let transform: @MainActor (inout EnvironmentValues) -> Void
    func resolve(in ctx: ResolveContext) -> [LayoutNode] { ctx.with(transform).resolve(content, "e") }
}

extension View {
    func environment(_ transform: @escaping @MainActor (inout EnvironmentValues) -> Void) -> some View {
        EnvironmentModifierView(content: self, transform: transform)
    }

    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> some View {
        environment { $0[keyPath: keyPath] = value }
    }

    /// Puts an @Observable object in the environment, for `@Environment(T.self)`.
    public func environment<T: AnyObject & Observable>(_ object: T?) -> some View {
        environment { env in if let object { env.objects[ObjectIdentifier(T.self)] = object } }
    }

    public func transformEnvironment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, transform: @escaping (inout V) -> Void) -> some View {
        environment { transform(&$0[keyPath: keyPath]) }
    }

    public func font(_ font: Font?) -> some View { environment { $0.font = font } }
    public func fontWeight(_ weight: Font.Weight?) -> some View { environment { $0._fontWeight = weight } }
    public func bold(_ isActive: Bool = true) -> some View { environment { if isActive { $0._fontWeight = .bold } } }
    public func italic(_ isActive: Bool = true) -> some View { environment { if isActive { $0._italic = true } } }
    public func monospacedDigit() -> some View { environment { $0._monospacedDigit = true } }
    public func monospaced(_ isActive: Bool = true) -> some View {
        environment { env in if isActive { env.font = (env.font ?? .body).monospaced() } }
    }
    public func fontDesign(_ design: Font.Design?) -> some View {
        environment { env in if let design { env.font = (env.font ?? .body).design(design) } }
    }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> some View { environment { $0._foreground = AnyShapeStyle(style) } }
    public func foregroundStyle<S1: ShapeStyle, S2: ShapeStyle>(_ primary: S1, _ secondary: S2) -> some View { environment { $0._foreground = AnyShapeStyle(primary) } }
    public func foregroundColor(_ color: Color?) -> some View { environment { $0._foreground = color.map { AnyShapeStyle($0) } } }
    public func tint(_ tint: Color?) -> some View { environment { $0._tint = tint } }
    public func tint<S: ShapeStyle>(_ tint: S?) -> some View { environment { env in if let t = tint as? Color { env._tint = t } } }
    public func accentColor(_ color: Color?) -> some View { tint(color) }
    public func disabled(_ disabled: Bool) -> some View { environment { if disabled { $0.isEnabled = false } } }
    public func controlSize(_ size: ControlSize) -> some View { environment { $0.controlSize = size } }
    public func lineLimit(_ n: Int?) -> some View { environment { $0.lineLimit = n } }
    public func lineLimit(_ n: Int, reservesSpace: Bool) -> some View { environment { $0.lineLimit = n } }
    public func lineLimit(_ range: ClosedRange<Int>) -> some View { environment { $0.lineLimit = range.upperBound } }
    public func lineLimit(_ range: PartialRangeFrom<Int>) -> some View { environment { $0.lineLimit = nil } }
    public func truncationMode(_ mode: Text.TruncationMode) -> some View { environment { $0.truncationMode = mode } }
    public func multilineTextAlignment(_ a: TextAlignment) -> some View { environment { $0.multilineTextAlignment = a } }
    public func help(_ text: String) -> some View { environment { $0._help = text } }
    public func help(_ text: Text) -> some View { environment { $0._help = text.plainText } }
    public func labelsHidden() -> some View { environment { $0._labelsHidden = true } }
    public func scrollDisabled(_ disabled: Bool) -> some View { environment { if disabled { $0.isScrollEnabled = false } } }
    public func opacity(_ opacity: Double) -> some View { environment { $0._opacity *= opacity } }
    public func preferredColorScheme(_ scheme: ColorScheme?) -> some View { environment { env in if let scheme { env.colorScheme = scheme } } }
    public func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping @MainActor () -> Void) -> some View {
        environment { $0._onSubmit = action }
    }
    public func keyboardShortcut(_ shortcut: KeyboardShortcut?) -> some View { environment { $0._shortcut = shortcut } }
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        environment { $0._shortcut = KeyboardShortcut(key, modifiers: modifiers) }
    }
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command, localization: KeyboardShortcut.Localization) -> some View {
        environment { $0._shortcut = KeyboardShortcut(key, modifiers: modifiers) }
    }
}

public struct SubmitTriggers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let text = SubmitTriggers(rawValue: 1)
    public static let search = SubmitTriggers(rawValue: 2)
}

// MARK: Keyboard shortcuts

public struct KeyEquivalent: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
    public let character: Character
    public init(_ character: Character) { self.character = character }
    public init(extendedGraphemeClusterLiteral value: Character) { character = value }
    public static let `return` = KeyEquivalent("\r")
    public static let escape = KeyEquivalent("\u{1b}")
    public static let delete = KeyEquivalent("\u{8}")
    public static let deleteForward = KeyEquivalent("\u{7f}")
    public static let tab = KeyEquivalent("\t")
    public static let space = KeyEquivalent(" ")
    public static let upArrow = KeyEquivalent("\u{F700}")
    public static let downArrow = KeyEquivalent("\u{F701}")
    public static let leftArrow = KeyEquivalent("\u{F702}")
    public static let rightArrow = KeyEquivalent("\u{F703}")
    public static let home = KeyEquivalent("\u{F729}")
    public static let end = KeyEquivalent("\u{F72B}")
    public static let pageUp = KeyEquivalent("\u{F72C}")
    public static let pageDown = KeyEquivalent("\u{F72D}")
    public static let clear = KeyEquivalent("\u{F739}")
    var keyName: String {
        switch character {
        case "\r": "return"
        case "\u{1b}": "escape"
        case "\u{8}": "backspace"
        case "\u{7f}": "delete"
        case "\t": "tab"
        case " ": "space"
        case "\u{F700}": "up"
        case "\u{F701}": "down"
        case "\u{F702}": "left"
        case "\u{F703}": "right"
        case "\u{F729}": "home"
        case "\u{F72B}": "end"
        default: String(character).lowercased()
        }
    }
}

public struct EventModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = EventModifiers(rawValue: 1 << 0)
    public static let control = EventModifiers(rawValue: 1 << 1)
    public static let option = EventModifiers(rawValue: 1 << 2)
    public static let command = EventModifiers(rawValue: 1 << 3)
    public static let capsLock = EventModifiers(rawValue: 1 << 4)
    public static let numericPad = EventModifiers(rawValue: 1 << 5)
    public static let all = EventModifiers(rawValue: 0x3f)
}

public struct KeyboardShortcut: Hashable, Sendable {
    public enum Localization: Sendable { case automatic, withoutMirroring, custom }
    public let key: KeyEquivalent
    public let modifiers: EventModifiers
    public var localization: Localization = .automatic
    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) { self.key = key; self.modifiers = modifiers }
    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command, localization: Localization) {
        self.key = key; self.modifiers = modifiers; self.localization = localization
    }
    public static let defaultAction = KeyboardShortcut(.return, modifiers: [])
    public static let cancelAction = KeyboardShortcut(.escape, modifiers: [])

    /// ⌘ maps to Ctrl on Linux and Windows.
    var keyPress: RunwayCore.KeyPress {
        RunwayCore.KeyPress(key: key.keyName, command: modifiers.contains(.command), shift: modifiers.contains(.shift),
                 option: modifiers.contains(.option), control: modifiers.contains(.control))
    }
}


/// The default of an `@Entry` environment value (the transpiler's
/// generated key): evaluated once, whatever isolation the expression has
/// (SwiftUI reads environment defaults on the main actor).
public func _entryDefault<T>(_ make: @MainActor () -> T) -> T {
    withoutActuallyEscaping(make) { escapable in
        unsafeBitCast(escapable, to: (() -> T).self)()
    }
}
