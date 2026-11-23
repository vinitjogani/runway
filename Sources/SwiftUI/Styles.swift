// Control styles. SwiftUI's are protocols with static members
// (`.pickerStyle(.segmented)`); each maps to a kind the controls read.

import Foundation
import RunwayCore

enum PickerStyleKind: Hashable { case automatic, menu, segmented, radioGroup, inline, palette, wheel }
enum ToggleStyleKind: Hashable { case automatic, `switch`, checkbox, button }
enum ButtonStyleKind: Hashable { case automatic, bordered, borderedProminent, borderless, plain, link, glass, accessoryBar }
enum TextFieldStyleKind: Hashable { case automatic, roundedBorder, plain, squareBorder }
enum FormStyleKind: Hashable { case automatic, grouped, columns }
enum LabelStyleKind: Hashable { case automatic, iconOnly, titleOnly, titleAndIcon }
enum ProgressStyleKind: Hashable { case automatic, linear, circular }

public protocol PickerStyle { var _kind: _StyleToken { get } }
/// A toggle's look: a built-in style, or `makeBody` drawing it from the configuration.
public protocol ToggleStyle {
    associatedtype Body: View
    @ViewBuilder @MainActor func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ToggleStyleConfiguration
    var _kind: _StyleToken { get }
}
public protocol PrimitiveButtonStyle { var _kind: _StyleToken { get } }
public protocol TextFieldStyle { var _kind: _StyleToken { get } }
public protocol FormStyle { var _kind: _StyleToken { get } }
public protocol LabelStyle {
    associatedtype Body: View
    @ViewBuilder @MainActor func makeBody(configuration: Configuration) -> Body
    typealias Configuration = LabelStyleConfiguration
    var _kind: _StyleToken { get }
}
public protocol ProgressViewStyle {
    associatedtype Body: View
    @ViewBuilder @MainActor func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ProgressViewStyleConfiguration
    var _kind: _StyleToken { get }
}
public protocol MenuStyle {
    associatedtype Body: View
    @ViewBuilder @MainActor func makeBody(configuration: Configuration) -> Body
    typealias Configuration = MenuStyleConfiguration
}
public protocol ListStyle {}
public protocol TabViewStyle {}
public protocol NavigationSplitViewStyle {}
public protocol DatePickerStyle {}
public protocol GroupBoxStyle {
    associatedtype Body: View
    @ViewBuilder @MainActor func makeBody(configuration: Configuration) -> Body
    typealias Configuration = GroupBoxStyleConfiguration
}
public protocol ControlGroupStyle {}
public protocol WindowStyle {}
public protocol WindowToolbarStyle {}
public protocol IndexViewStyle {}

/// Opaque token naming a built-in style.
public struct _StyleToken: Hashable, Sendable { let name: String }

extension ToggleStyle { public var _kind: _StyleToken { _StyleToken(name: "custom") } }
extension LabelStyle { public var _kind: _StyleToken { _StyleToken(name: "custom") } }
extension ProgressViewStyle { public var _kind: _StyleToken { _StyleToken(name: "custom") } }

/// A label part of a style configuration, resolved where the style puts it.
public struct _StyleContent: View, PrimitiveView {
    public typealias Body = Never
    let resolveContent: @MainActor (ResolveContext) -> [LayoutNode]
    init(_ resolve: @escaping @MainActor (ResolveContext) -> [LayoutNode]) { resolveContent = resolve }
    init<V: View>(_ view: V) { resolveContent = { $0.resolve(view, "part") } }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] { resolveContent(ctx) }
}

public struct ToggleStyleConfiguration {
    public typealias Label = _StyleContent
    public let label: Label
    @Binding public var isOn: Bool
    public var isMixed = false
    public init(label: Label, isOn: Binding<Bool>) { self.label = label; _isOn = isOn }
    public var _isOnBinding: Binding<Bool> { $isOn }
}

public struct LabelStyleConfiguration {
    public typealias Title = _StyleContent
    public typealias Icon = _StyleContent
    public let title: Title
    public let icon: Icon
}

public struct ProgressViewStyleConfiguration {
    public typealias Label = _StyleContent
    public typealias CurrentValueLabel = _StyleContent
    public let fractionCompleted: Double?
    public var label: Label?
    public var currentValueLabel: CurrentValueLabel?
}

public struct MenuStyleConfiguration {
    public typealias Label = _StyleContent
    public typealias Content = _StyleContent
}

public struct GroupBoxStyleConfiguration {
    public typealias Label = _StyleContent
    public typealias Content = _StyleContent
    public let label: Label
    public let content: Content
}

struct AnyToggleStyle {
    let make: @MainActor (ToggleStyleConfiguration) -> AnyView
}

struct AnyLabelStyle {
    let make: @MainActor (LabelStyleConfiguration) -> AnyView
}

public struct _Style: PickerStyle, ToggleStyle, PrimitiveButtonStyle, TextFieldStyle, FormStyle, LabelStyle, ProgressViewStyle,
    MenuStyle, ListStyle, TabViewStyle, NavigationSplitViewStyle, DatePickerStyle, GroupBoxStyle, ControlGroupStyle, WindowStyle, WindowToolbarStyle, IndexViewStyle {
    public typealias Body = Never
    public let _kind: _StyleToken
    init(_ name: String) { _kind = _StyleToken(name: name) }
    /// `LinkButtonStyle()`, `SwitchToggleStyle()`…: the platform's style.
    public init() { _kind = _StyleToken(name: "automatic") }
    public func makeBody(configuration: ToggleStyleConfiguration) -> Never { fatalError("built-in style") }
    public func makeBody(configuration: LabelStyleConfiguration) -> Never { fatalError("built-in style") }
    public func makeBody(configuration: ProgressViewStyleConfiguration) -> Never { fatalError("built-in style") }
    public func makeBody(configuration: MenuStyleConfiguration) -> Never { fatalError("built-in style") }
    public func makeBody(configuration: GroupBoxStyleConfiguration) -> Never { fatalError("built-in style") }
}

public typealias DefaultPickerStyle = _Style
public typealias SegmentedPickerStyle = _Style
public typealias MenuPickerStyle = _Style
public typealias RadioGroupPickerStyle = _Style
public typealias InlinePickerStyle = _Style
public typealias PalettePickerStyle = _Style
public typealias SwitchToggleStyle = _Style
public typealias CheckboxToggleStyle = _Style
public typealias ButtonToggleStyle = _Style
public typealias DefaultToggleStyle = _Style
public typealias BorderedButtonStyle = _Style
public typealias BorderedProminentButtonStyle = _Style
public typealias BorderlessButtonStyle = _Style
public typealias PlainButtonStyle = _Style
public typealias LinkButtonStyle = _Style
public typealias DefaultButtonStyle = _Style
public typealias GlassButtonStyle = _Style
public typealias RoundedBorderTextFieldStyle = _Style
public typealias PlainTextFieldStyle = _Style
public typealias SquareBorderTextFieldStyle = _Style
public typealias GroupedFormStyle = _Style
public typealias ColumnsFormStyle = _Style
public typealias IconOnlyLabelStyle = _Style
public typealias TitleOnlyLabelStyle = _Style
public typealias TitleAndIconLabelStyle = _Style
public typealias LinearProgressViewStyle = _Style
public typealias CircularProgressViewStyle = _Style

extension PickerStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var menu: _Style { _Style("menu") }
    public static var segmented: _Style { _Style("segmented") }
    public static var radioGroup: _Style { _Style("radioGroup") }
    public static var inline: _Style { _Style("inline") }
    public static var palette: _Style { _Style("palette") }
    public static var wheel: _Style { _Style("wheel") }
}
extension ToggleStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var `switch`: _Style { _Style("switch") }
    public static var checkbox: _Style { _Style("checkbox") }
    public static var button: _Style { _Style("button") }
}
extension PrimitiveButtonStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var bordered: _Style { _Style("bordered") }
    public static var borderedProminent: _Style { _Style("borderedProminent") }
    public static var borderless: _Style { _Style("borderless") }
    public static var plain: _Style { _Style("plain") }
    public static var link: _Style { _Style("link") }
    public static var glass: _Style { _Style("glass") }
    public static var glassProminent: _Style { _Style("borderedProminent") }
    public static var accessoryBar: _Style { _Style("accessoryBar") }
    public static var accessoryBarAction: _Style { _Style("accessoryBar") }
}
extension TextFieldStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var roundedBorder: _Style { _Style("roundedBorder") }
    public static var plain: _Style { _Style("plain") }
    public static var squareBorder: _Style { _Style("squareBorder") }
}
extension FormStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var grouped: _Style { _Style("grouped") }
    public static var columns: _Style { _Style("columns") }
}
extension LabelStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var iconOnly: _Style { _Style("iconOnly") }
    public static var titleOnly: _Style { _Style("titleOnly") }
    public static var titleAndIcon: _Style { _Style("titleAndIcon") }
}
extension ProgressViewStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var linear: _Style { _Style("linear") }
    public static var circular: _Style { _Style("circular") }
}
extension MenuStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var button: _Style { _Style("button") }
    public static var borderlessButton: _Style { _Style("borderless") }
    public static var borderless: _Style { _Style("borderless") }
}
extension ListStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var sidebar: _Style { _Style("sidebar") }
    public static var inset: _Style { _Style("inset") }
    public static var plain: _Style { _Style("plain") }
    public static var bordered: _Style { _Style("bordered") }
    public static var grouped: _Style { _Style("grouped") }
    public static var insetGrouped: _Style { _Style("insetGrouped") }
}
extension TabViewStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var grouped: _Style { _Style("grouped") }
    public static var tabBarOnly: _Style { _Style("tabBarOnly") }
    public static var sidebarAdaptable: _Style { _Style("sidebarAdaptable") }
}
extension NavigationSplitViewStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var balanced: _Style { _Style("balanced") }
    public static var prominentDetail: _Style { _Style("prominentDetail") }
}
extension GroupBoxStyle where Self == _Style { public static var automatic: _Style { _Style("automatic") } }
extension DatePickerStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var field: _Style { _Style("field") }
    public static var graphical: _Style { _Style("graphical") }
    public static var compact: _Style { _Style("compact") }
}
extension WindowStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var hiddenTitleBar: _Style { _Style("hiddenTitleBar") }
    public static var titleBar: _Style { _Style("titleBar") }
    public static var plain: _Style { _Style("plain") }
}
extension WindowToolbarStyle where Self == _Style {
    public static var automatic: _Style { _Style("automatic") }
    public static var unified: _Style { _Style("unified") }
    public static var unifiedCompact: _Style { _Style("unifiedCompact") }
    public static var expanded: _Style { _Style("expanded") }
}

/// A custom ButtonStyle: `makeBody` decorates the label.
@MainActor @preconcurrency
public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder @MainActor func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ButtonStyleConfiguration
}

public struct ButtonStyleConfiguration {
    public struct Label: View, PrimitiveView {
        public typealias Body = Never
        let resolveLabel: @MainActor (ResolveContext) -> [LayoutNode]
        func resolve(in ctx: ResolveContext) -> [LayoutNode] { resolveLabel(ctx) }
    }
    public let label: Label
    public let isPressed: Bool
    public let role: ButtonRole?
}

struct AnyButtonStyle {
    let make: @MainActor (ButtonStyleConfiguration) -> AnyView
}

extension View {
    public func pickerStyle<S: PickerStyle>(_ s: S) -> some View {
        let k: PickerStyleKind = switch s._kind.name {
        case "segmented", "palette": .segmented
        case "radioGroup": .radioGroup
        case "inline": .inline
        case "menu": .menu
        default: .automatic
        }
        return environment { $0._pickerStyle = k }
    }
    public func toggleStyle<S: ToggleStyle>(_ s: S) -> some View {
        let k: ToggleStyleKind = switch s._kind.name {
        case "switch": .switch
        case "checkbox": .checkbox
        case "button": .button
        default: .automatic
        }
        if s._kind.name == "custom" {
            return environment { $0._customToggleStyle = AnyToggleStyle(make: { AnyView(s.makeBody(configuration: $0)) }) }
        }
        return environment { $0._toggleStyle = k; $0._customToggleStyle = nil }
    }
    public func buttonStyle<S: PrimitiveButtonStyle>(_ s: S) -> some View {
        let k: ButtonStyleKind = switch s._kind.name {
        case "bordered": .bordered
        case "borderedProminent": .borderedProminent
        case "borderless": .borderless
        case "plain": .plain
        case "link": .link
        case "glass": .glass
        case "accessoryBar": .accessoryBar
        default: .automatic
        }
        return environment { $0._buttonStyle = k; $0._customButtonStyle = nil }
    }
    public func buttonStyle<S: ButtonStyle>(_ s: S) -> some View {
        environment { $0._customButtonStyle = AnyButtonStyle(make: { AnyView(s.makeBody(configuration: $0)) }) }
    }
    public func textFieldStyle<S: TextFieldStyle>(_ s: S) -> some View {
        let k: TextFieldStyleKind = switch s._kind.name {
        case "plain": .plain
        case "roundedBorder": .roundedBorder
        case "squareBorder": .squareBorder
        default: .automatic
        }
        return environment { $0._textFieldStyle = k }
    }
    public func formStyle<S: FormStyle>(_ s: S) -> some View {
        let k: FormStyleKind = s._kind.name == "grouped" ? .grouped : s._kind.name == "columns" ? .columns : .automatic
        return environment { $0._formStyle = k }
    }
    public func labelStyle<S: LabelStyle>(_ s: S) -> some View {
        let k: LabelStyleKind = switch s._kind.name {
        case "iconOnly": .iconOnly
        case "titleOnly": .titleOnly
        case "titleAndIcon": .titleAndIcon
        default: .automatic
        }
        if s._kind.name == "custom" {
            return environment { $0._customLabelStyle = AnyLabelStyle(make: { AnyView(s.makeBody(configuration: $0)) }) }
        }
        return environment { $0._labelStyle = k; $0._customLabelStyle = nil }
    }
    public func progressViewStyle<S: ProgressViewStyle>(_ s: S) -> some View {
        let k: ProgressStyleKind = s._kind.name == "linear" ? .linear : s._kind.name == "circular" ? .circular : .automatic
        return environment { $0._progressStyle = k }
    }
    public func menuStyle<S: MenuStyle>(_ s: S) -> some View { self }
    public func listStyle<S: ListStyle>(_ s: S) -> some View {
        environment { $0._insetGroupedListStyle = (s as? _Style)?._kind.name == "insetGrouped" }
    }
    public func tabViewStyle<S: TabViewStyle>(_ s: S) -> some View { self }
    public func navigationSplitViewStyle<S: NavigationSplitViewStyle>(_ s: S) -> some View { self }
    public func datePickerStyle<S: DatePickerStyle>(_ s: S) -> some View { self }
    public func groupBoxStyle<S: GroupBoxStyle>(_ s: S) -> some View { self }
    public func controlGroupStyle<S: ControlGroupStyle>(_ s: S) -> some View { self }
    public func indexViewStyle<S: IndexViewStyle>(_ s: S) -> some View { self }
    public func buttonBorderShape(_ shape: ButtonBorderShape) -> some View { environment { $0[ButtonBorderShapeKey.self] = shape } }
    public func menuIndicator(_ visibility: Visibility) -> some View { self }
}

public struct ButtonBorderShape: Sendable {
    let isCapsule: Bool
    public static let automatic = Self(isCapsule: false), capsule = Self(isCapsule: true)
    public static let roundedRectangle = Self(isCapsule: false), circle = Self(isCapsule: true)
    public static func roundedRectangle(radius: CGFloat) -> ButtonBorderShape { .roundedRectangle }
}

struct ButtonBorderShapeKey: EnvironmentKey { static let defaultValue = ButtonBorderShape.automatic }

public enum Visibility: Hashable, Sendable, CaseIterable { case automatic, visible, hidden }
