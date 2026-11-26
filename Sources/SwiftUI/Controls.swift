// Controls, each a native widget: buttons, toggles, text fields, sliders,
// pickers (menu and segmented), menus, links, progress, colour wells.
// Labels follow macOS conventions; in a grouped Form a control becomes a
// row: its label leading, the control trailing.

import Foundation
import RunwayCore

public enum ButtonRole: Hashable, Sendable { case destructive, cancel, close, confirm }

extension ResolveContext {
    /// Props every control shares.
    func baseProps() -> WidgetProps {
        var p = WidgetProps()
        p.enabled = env.isEnabled
        p.tooltip = env._help
        p.opacity = env._opacity
        p.controlSize = env.controlSize.value
        p.tint = env._tint?.resolve(env)
        return p
    }

    /// A text-only label's string, or nil if the label is richer.
    func plainTitle<L: View>(_ label: L) -> String? {
        if let t = label as? Text { return t.plainText }
        var c = self
        c.dryRun = true
        let nodes = c.resolve(label, "probe")
        if nodes.count == 1, let w = nodes[0] as? WidgetNode, let t = w.text { return t }
        return nil
    }

    func labelText<L: View>(_ label: L) -> String {
        if let t = label as? Text { return t.plainText }
        var c = self
        c.dryRun = true
        return c.resolve(label, "probe").compactMap(\.textContent).joined(separator: " ")
    }

    /// Registers keyboard shortcuts for a control's action.
    func registerShortcut(_ action: @escaping @MainActor () -> Void) {
        guard env.isEnabled, !dryRun, let s = env._shortcut else { return }
        if s == .defaultAction { host.defaultAction = action } else if s == .cancelAction { host.cancelAction = action } else { host.shortcuts.append((s.keyPress, action)) }
    }

    /// A row in a grouped form: label leading, control trailing.
    func formRow(label: [LayoutNode], control: [LayoutNode]) -> [LayoutNode] {
        if env._labelsHidden || label.isEmpty { return control }
        if env._inFormRow {
            return [StackNode(axis: .horizontal, alignment: 0.5, spacing: 12, children: label + [SpacerNode(minLength: 0, axis: .horizontal)] + control)]
        }
        return [StackNode(axis: .horizontal, alignment: 0.5, spacing: 6, children: label + control)]
    }
}

// MARK: Menu items

/// Labels that show an SF Symbol (Label with an Image icon, an Image):
/// what a menu item shows beside its title.
protocol _MenuSymbolLabel { var _menuSymbol: String? { get } }
extension Image: _MenuSymbolLabel {
    var _menuSymbol: String? { if case let .symbol(s) = imageSource { return s }; return nil }
}
extension Label: _MenuSymbolLabel where Icon == Image {
    var _menuSymbol: String? { icon._menuSymbol }
}
func menuSymbol<L: View>(_ label: L) -> String? { (label as? _MenuSymbolLabel)?._menuSymbol }

// MARK: Button

public struct Button<Label: View>: View, PrimitiveView {
    public typealias Body = Never
    let label: Label
    let role: ButtonRole?
    let action: @MainActor () -> Void

    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.label = label(); self.action = action; role = nil
    }
    public init(role: ButtonRole?, action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.label = label(); self.action = action; self.role = role
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let env = ctx.env
        let backend = ctx.host.backend
        let role = self.role ?? env._buttonRole
        let after = env[AfterButtonActionKey.self]
        let base = self.action
        let action: @MainActor () -> Void = { base(); after?.run() }
        var item = MenuItemSpec(title: ctx.labelText(label), enabled: env.isEnabled, symbol: menuSymbol(label), action: action)
        if let s = env._shortcut, s != .defaultAction, s != .cancelAction { item.shortcut = s.keyPress }
        item.destructive = role == .destructive
        ctx.registerShortcut(action)
        if role == .cancel, env._shortcut == nil, !ctx.dryRun { ctx.host.cancelAction = ctx.host.cancelAction ?? action }

        var events = WidgetEvents()
        events.onTap = { if env.isEnabled { action() } }
        var p = ctx.baseProps()
        p.isDefault = env._shortcut == .defaultAction
        p.isCancel = env._shortcut == .cancelAction || role == .cancel
        p.isDestructive = role == .destructive
        p.prominent = env._buttonStyle == .borderedProminent || p.isDefault
        p.capsuleButton = env._mobilePreview && env[ButtonBorderShapeKey.self].isCapsule

        // A custom ButtonStyle decorates the label in a tap area.
        if let style = env._customButtonStyle {
            let lbl = label
            let config = ButtonStyleConfiguration(label: .init(resolveLabel: { c in c.resolve(lbl, "label") }), isPressed: false, role: role)
            let body = style.make(config)
            let content = ctx.with { $0._customButtonStyle = nil }.resolve(body, "styled")
            return [tapArea(ctx, content: content, events: events, props: p, item: item)]
        }

        let style = env._buttonStyle
        let title = ctx.plainTitle(label)
        if style == .link, let title {
            let w = ctx.widget(.link)
            p.title = title
            if let w { backend.update(w, props: p, events: events) }
            return [WidgetNode(w, backend: backend, text: title, item: item)]
        }
        let chromeless = style == .plain || style == .borderless || style == .link || style == .accessoryBar
        if let title, !chromeless, !env._mobilePreview {
            let w = ctx.widget(.button)
            p.title = title
            if let w { backend.update(w, props: p, events: events) }
            return [WidgetNode(w, backend: backend, text: title, item: item)]
        }
        // Rich labels (icons, stacks), or plain styles: the label itself is drawn.
        let labelCtx = ctx.with { env in
            if style == .borderless || style == .accessoryBar, env._foreground == nil {
                env._foreground = AnyShapeStyle(role == .destructive ? Color.red : Color.secondary)
            }
            if role == .destructive, env._foreground == nil { env._foreground = AnyShapeStyle(Color.red) }
            if env._mobilePreview, env._foreground == nil {
                let tint = env._tint ?? .accentColor
                if p.prominent {
                    let color = tint.resolve(env)
                    let luminance = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
                    env._foreground = AnyShapeStyle(luminance > 0.55 ? Color.black : Color.white)
                } else if style == .automatic {
                    env._foreground = AnyShapeStyle(tint)
                }
            }
        }
        let content = labelCtx.resolve(label, "label")
        if chromeless { return [tapArea(ctx, content: content, events: events, props: p, item: item)] }
        let w = ctx.widget(.button)
        p.hasContent = true
        if env._mobilePreview, style == .automatic, !p.prominent { p.bordered = false }
        if let w { backend.update(w, props: p, events: events) }
        let inner: LayoutNode = content.count == 1 ? content[0] : StackNode(axis: .horizontal, alignment: 0.5, spacing: 4, children: content)
        let node = ContainerNode(widget: w, backend: backend, content: inner, sizing: .hug, insets: w.map { backend.contentInsets($0) } ?? .zero)
        let minHeight: CGFloat = switch env.controlSize {
        case .mini: 15
        case .small: 18
        case .large, .extraLarge: 28
        default: 22
        }
        node.minSize = CGSize(width: 0, height: minHeight)
        node.item = item
        return [node]
    }

    private func tapArea(_ ctx: ResolveContext, content: [LayoutNode], events: WidgetEvents, props: WidgetProps, item: MenuItemSpec) -> LayoutNode {
        let w = ctx.widget(.tapArea)
        if let w { ctx.host.backend.update(w, props: props, events: events) }
        let inner: LayoutNode = content.count == 1 ? content[0] : StackNode(axis: .horizontal, alignment: 0.5, spacing: 4, children: content)
        let node = ContainerNode(widget: w, backend: ctx.host.backend, content: inner, sizing: .hug)
        if ctx.env._mobileToolbarItem {
            let height = (ctx.env._mobilePreviewProfile ?? .iphonePro).toolbarHeight
            node.minSize = CGSize(width: height, height: height)
        }
        node.item = item
        return node
    }
}

extension Button where Label == Text {
    public init(_ titleKey: LocalizedStringKey, action: @escaping @MainActor () -> Void) { self.init(action: action) { Text(titleKey) } }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, action: @escaping @MainActor () -> Void) { self.init(action: action) { Text(title) } }
    public init(_ titleKey: LocalizedStringKey, role: ButtonRole?, action: @escaping @MainActor () -> Void) { self.init(role: role, action: action) { Text(titleKey) } }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping @MainActor () -> Void) { self.init(role: role, action: action) { Text(title) } }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { SwiftUI.Label(titleKey, systemImage: systemImage) }
    }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String, action: @escaping @MainActor () -> Void) {
        self.init(action: action) { SwiftUI.Label(title, systemImage: systemImage) }
    }
    public init(_ titleKey: LocalizedStringKey, systemImage: String, role: ButtonRole?, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(titleKey, systemImage: systemImage) }
    }
}

// MARK: Label

public struct Label<Title: View, Icon: View>: View, PrimitiveView {
    public typealias Body = Never
    let title: Title
    let icon: Icon
    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) { self.title = title(); self.icon = icon() }
    public init(_ configuration: LabelStyleConfiguration) where Title == LabelStyleConfiguration.Title, Icon == LabelStyleConfiguration.Icon {
        title = configuration.title; icon = configuration.icon
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        if let custom = ctx.env._customLabelStyle, !ctx.env._inMenu {
            // The style lays the label out; a Label(configuration) inside
            // it lays out plainly.
            let title = self.title, icon = self.icon
            let inner = ctx.with { $0._customLabelStyle = nil }
            let config = LabelStyleConfiguration(title: _StyleContent { c in c.with { $0._customLabelStyle = nil }.resolve(title, "title") },
                                                 icon: _StyleContent { c in c.with { $0._customLabelStyle = nil }.resolve(icon, "icon") })
            return inner.resolve(custom.make(config), "style")
        }
        let style = ctx.env._labelStyle
        let t = style == .iconOnly ? [] : ctx.resolve(title, "title")
        let i = style == .titleOnly ? [] : ctx.resolve(icon, "icon")
        if ctx.env._inMenu { return t }
        let row = i + t
        return row.count == 1 ? row : [StackNode(axis: .horizontal, alignment: 0.5, spacing: 6, children: row)]
    }
}

extension Label where Title == Text, Icon == Image {
    public init(_ titleKey: LocalizedStringKey, systemImage: String) { self.init(title: { Text(titleKey) }, icon: { Image(systemName: systemImage) }) }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, systemImage: String) { self.init(title: { Text(title) }, icon: { Image(systemName: systemImage) }) }
    public init(_ titleKey: LocalizedStringKey, image: String) { self.init(title: { Text(titleKey) }, icon: { Image(image) }) }
}

// MARK: Toggle

public struct Toggle<Label: View>: View, PrimitiveView {
    public typealias Body = Never
    let label: Label
    let isOn: Binding<Bool>
    public init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) { self.isOn = isOn; self.label = label() }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let env = ctx.env
        if let custom = env._customToggleStyle {
            let config = ToggleStyleConfiguration(label: _StyleContent(label), isOn: isOn)
            return ctx.with { $0._customToggleStyle = nil }.resolve(custom.make(config), "styled")
        }
        let backend = ctx.host.backend
        var style = env._toggleStyle
        if style == .automatic { style = env._inFormRow ? .switch : .checkbox }
        let isOn = self.isOn
        var events = WidgetEvents()
        events.onToggle = { isOn.wrappedValue = $0 }
        var p = ctx.baseProps()
        p.isOn = isOn.wrappedValue
        var item = MenuItemSpec(title: ctx.labelText(label), enabled: env.isEnabled, checked: p.isOn, symbol: menuSymbol(label)) { isOn.wrappedValue.toggle() }
        if let s = env._shortcut, s != .defaultAction, s != .cancelAction { item.shortcut = s.keyPress }
        let kind: ToggleKind = style == .switch ? .switch : style == .button ? .button : .checkbox
        let title = ctx.plainTitle(label) ?? ctx.labelText(label)
        // Checkboxes and toggle buttons carry their own title; switches sit
        // trailing with the label leading.
        if kind != .switch || env._labelsHidden {
            p.title = env._labelsHidden && kind != .button ? "" : title
            if kind == .checkbox, env._inFormRow, !env._labelsHidden {
                p.title = ""
                let w = ctx.widget(.toggle(kind))
                if let w { backend.update(w, props: p, events: events) }
                return ctx.formRow(label: ctx.resolve(label, "label"), control: [WidgetNode(w, backend: backend, item: item)])
            }
            let w = ctx.widget(.toggle(kind))
            if let w { backend.update(w, props: p, events: events) }
            return [WidgetNode(w, backend: backend, text: title, item: item)]
        }
        let w = ctx.widget(.toggle(.switch))
        if let w { backend.update(w, props: p, events: events) }
        return ctx.formRow(label: ctx.resolve(label, "label"), control: [WidgetNode(w, backend: backend, item: item)])
    }
}

extension Toggle where Label == Text {
    public init(_ titleKey: LocalizedStringKey, isOn: Binding<Bool>) { self.init(isOn: isOn) { Text(titleKey) } }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) { self.init(isOn: isOn) { Text(title) } }
}

extension Toggle where Label == SwiftUI.Label<Text, Image> {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { SwiftUI.Label(titleKey, systemImage: systemImage) }
    }
}

// MARK: Text input

public struct TextField<Label: View>: View, PrimitiveView {
    public typealias Body = Never
    let label: Label
    let text: Binding<String>
    let prompt: Text?
    var secure = false
    var axisVertical = false

    public init(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> Label) { self.text = text; self.prompt = prompt; self.label = label() }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let env = ctx.env
        let backend = ctx.host.backend
        let text = self.text
        var events = WidgetEvents()
        events.onText = { if text.wrappedValue != $0 { text.wrappedValue = $0 } }
        events.onSubmit = env._onSubmit
        var p = ctx.baseProps()
        p.string = text.wrappedValue
        let title = ctx.labelText(label)
        p.placeholder = prompt?.plainText ?? title
        p.bordered = env._textFieldStyle != .plain && (!env._mobilePreview || env._textFieldStyle != .automatic)
        if env._mobilePreview || env.font != nil { p.text = Text(verbatim: "").styled(env) }
        let w = ctx.widget(.textField(secure: secure))
        if let w { backend.update(w, props: p, events: events) }
        ctx.adoptFocus(w, textField: true)
        let field = WidgetNode(w, backend: backend)
        field.flexibleWidth = true
        field.idealWidth = 120
        field.minWidth = 40
        // In a form, a field with a prompt shows its label leading.
        if env._inFormRow, prompt != nil, !title.isEmpty {
            return ctx.formRow(label: ctx.resolve(label, "label"), control: [field])
        }
        return [field]
    }
}

extension TextField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text? = nil) { self.init(text: text, prompt: prompt) { Text(titleKey) } }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text? = nil) { self.init(text: text, prompt: prompt) { Text(title) } }
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, axis: Axis) { self.init(text: text, prompt: nil) { Text(titleKey) }; axisVertical = axis == .vertical }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, axis: Axis) { self.init(text: text, prompt: nil) { Text(title) }; axisVertical = axis == .vertical }
    /// Values with a Foundation formatter: shown through it, parsed back
    /// (numbers also from plain text) when the text changes.
    public init<V>(_ titleKey: LocalizedStringKey, value: Binding<V>, formatter: Formatter, prompt: Text? = nil) {
        self.init(text: TextField._formatted(value, formatter), prompt: prompt) { Text(titleKey) }
    }
    @_disfavoredOverload public init<S: StringProtocol, V>(_ title: S, value: Binding<V>, formatter: Formatter, prompt: Text? = nil) {
        self.init(text: TextField._formatted(value, formatter), prompt: prompt) { Text(title) }
    }
    static func _formatted<V>(_ value: Binding<V>, _ formatter: Formatter) -> Binding<String> {
        Binding<String>(get: { formatter.string(for: value.wrappedValue) ?? "\(value.wrappedValue)" }, set: { text in
            var parsed: Any?
            if let nf = formatter as? NumberFormatter { parsed = nf.number(from: text) ?? Double(text).map { NSNumber(value: $0) } }
            else if let df = formatter as? DateFormatter { parsed = df.date(from: text) }
            else { parsed = text }
            if let v = parsed as? V { value.wrappedValue = v; return }
            guard let n = parsed as? NSNumber else { return }
            let candidates: [Any] = [n.doubleValue, n.intValue, CGFloat(n.doubleValue), n.floatValue, n.int32Value, n.int64Value, n.uintValue, n.boolValue]
            for c in candidates { if let v = c as? V { value.wrappedValue = v; return } }
        })
    }
    /// Values with a format: edited as text, parsed back on change.
    public init<F: ParseableFormatStyle>(_ titleKey: LocalizedStringKey, value: Binding<F.FormatInput>, format: F, prompt: Text? = nil) where F.FormatOutput == String {
        let b = Binding<String>(get: { format.format(value.wrappedValue) }, set: { if let v = try? format.parseStrategy.parse($0) { value.wrappedValue = v } })
        self.init(text: b, prompt: prompt) { Text(titleKey) }
    }
}

public struct SecureField<Label: View>: View {
    let field: TextField<Label>
    public init(text: Binding<String>, prompt: Text? = nil, @ViewBuilder label: () -> Label) {
        var f = TextField(text: text, prompt: prompt, label: label)
        f.secure = true
        field = f
    }
    public var body: some View { field }
}

extension SecureField where Label == Text {
    public init(_ titleKey: LocalizedStringKey, text: Binding<String>, prompt: Text? = nil) { self.init(text: text, prompt: prompt) { Text(titleKey) } }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text? = nil) { self.init(text: text, prompt: prompt) { Text(title) } }
}

public struct TextEditor: View, PrimitiveView {
    public typealias Body = Never
    let text: Binding<String>
    var selection: Binding<TextSelection?>?
    public init(text: Binding<String>) { self.text = text }
    public init(text: Binding<String>, selection: Binding<TextSelection?>) { self.text = text; self.selection = selection }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let text = self.text
        var events = WidgetEvents()
        events.onText = { if text.wrappedValue != $0 { text.wrappedValue = $0 } }
        var p = ctx.baseProps()
        p.string = text.wrappedValue
        p.clearBackground = ctx.env._scrollContentBackgroundHidden
        if let font = ctx.env.font { p.text = Text(verbatim: "").font(font).styled(ctx.env) }
        if let selection {
            let string = text.wrappedValue
            p.selection = selection.wrappedValue.map { $0.scalarRange(in: string) }
            events.onSelection = { r in
                let current = text.wrappedValue
                let new = TextSelection(scalarRange: r, in: current)
                if selection.wrappedValue != new { selection.wrappedValue = new }
            }
        }
        let w = ctx.widget(.textEditor)
        if let w { ctx.host.backend.update(w, props: p, events: events) }
        ctx.adoptFocus(w, textField: true)
        let n = WidgetNode(w, backend: ctx.host.backend)
        n.flexibleWidth = true
        n.flexibleHeight = true
        return [n]
    }
}

// MARK: Slider, Stepper

public struct Slider<Label: View>: View, PrimitiveView {
    public typealias Body = Never
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double?
    let label: Label
    let onEditingChanged: (Bool) -> Void

    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1, step: V.Stride? = nil,
                                        @ViewBuilder label: () -> Label, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        range = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.step = step.map { Double($0) }
        self.label = label()
        self.onEditingChanged = onEditingChanged
    }

    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride? = nil,
                                        @ViewBuilder label: () -> Label, @ViewBuilder minimumValueLabel: () -> some View, @ViewBuilder maximumValueLabel: () -> some View,
                                        onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.init(value: value, in: bounds, step: step, label: label, onEditingChanged: onEditingChanged)
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let value = self.value
        let edited = onEditingChanged
        var events = WidgetEvents()
        events.onNumber = { v in
            edited(true)
            value.wrappedValue = v
            edited(false)
        }
        var p = ctx.baseProps()
        p.number = value.wrappedValue
        p.range = range
        p.step = step
        let w = ctx.widget(.slider)
        if let w { ctx.host.backend.update(w, props: p, events: events) }
        let n = WidgetNode(w, backend: ctx.host.backend)
        n.flexibleWidth = true
        n.idealWidth = 150
        n.minWidth = 40
        let lbl = Label.self == EmptyView.self ? [] : ctx.resolve(label, "label")
        return ctx.formRow(label: lbl, control: [n])
    }
}

extension Slider where Label == EmptyView {
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1, step: V.Stride? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.init(value: value, in: bounds, step: step, label: { EmptyView() }, onEditingChanged: onEditingChanged)
    }
}

public struct Stepper<Label: View>: View, PrimitiveView {
    public typealias Body = Never
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let label: Label
    public init<V: Strideable & BinaryInteger>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, @ViewBuilder label: () -> Label) where V.Stride: BinaryInteger {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0.rounded()) })
        range = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.step = Double(step)
        self.label = label()
    }
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1, @ViewBuilder label: () -> Label) where V.Stride: BinaryFloatingPoint {
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        range = Double(bounds.lowerBound)...Double(bounds.upperBound)
        self.step = Double(step)
        self.label = label()
    }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let value = self.value
        var events = WidgetEvents()
        events.onNumber = { value.wrappedValue = $0 }
        var p = ctx.baseProps()
        p.number = value.wrappedValue
        p.range = range
        p.step = step
        let w = ctx.widget(.stepper)
        if let w { ctx.host.backend.update(w, props: p, events: events) }
        let n = WidgetNode(w, backend: ctx.host.backend)
        return ctx.formRow(label: ctx.resolve(label, "label"), control: [n])
    }
}

extension Stepper where Label == Text {
    public init<V: Strideable & BinaryInteger>(_ titleKey: LocalizedStringKey, value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1) where V.Stride: BinaryInteger {
        self.init(value: value, in: bounds, step: step) { Text(titleKey) }
    }
}

// MARK: Picker

public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let label: Label
    let selection: Binding<SelectionValue>
    let content: Content

    public init(selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.selection = selection; self.content = content(); self.label = label()
    }

    struct Option { let title: String; let tag: AnyHashable; let value: Any }

    func options(_ ctx: ResolveContext) -> [Option] {
        var c = ctx
        c.dryRun = true
        var out: [Option] = []
        func walk(_ n: LayoutNode) {
            if let t = n.tag { out.append(Option(title: n.textContent ?? "\(t.base)", tag: t, value: n.tagValue as Any)); return }
            n.children.forEach(walk)
        }
        c.resolve(content, "options").forEach(walk)
        return out
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let env = ctx.env
        let backend = ctx.host.backend
        let opts = options(ctx)
        let selection = self.selection
        let current = AnyHashable(selection.wrappedValue)
        var events = WidgetEvents()
        events.onSelect = { i in
            guard opts.indices.contains(i), let v = opts[i].value as? SelectionValue else { return }
            if AnyHashable(v) != AnyHashable(selection.wrappedValue) { selection.wrappedValue = v }
        }
        var p = ctx.baseProps()
        p.options = opts.map(\.title)
        p.selected = opts.firstIndex { $0.tag == current } ?? -1
        let title = ctx.labelText(label)
        p.title = title
        if env._inMenu {
            guard !opts.isEmpty else { return [] }
            let children = opts.enumerated().map { i, o in
                MenuItemSpec(title: o.title, enabled: env.isEnabled, checked: i == p.selected) { events.onSelect?(i) }
            }
            if env._mobilePreview, env._pickerStyle != .menu {
                return children.map { WidgetNode(nil, backend: backend, text: $0.title, item: $0) }
            }
            let item = MenuItemSpec(title: title, children: children)
            return [WidgetNode(nil, backend: backend, text: title, item: item)]
        }
        let segmented = env._pickerStyle == .segmented || env._pickerStyle == .inline && opts.count <= 4
        // A menu picker in a grouped form is a borderless pop-up (value and
        // chevrons), as macOS draws it there.
        p.bordered = !(env._inFormRow && env._pickerStyle != .menu)
        let w = ctx.widget(segmented ? .segmented : .dropdown)
        if let w { backend.update(w, props: p, events: events) }
        let control = WidgetNode(w, backend: backend)
        if env._mobilePreview, segmented {
            control.flexibleWidth = true
            control.flexibleHeight = true
            let frame = FrameNode(child: control, alignment: .center)
            frame.height = 32
            return [frame]
        }
        let lbl = title.isEmpty ? [] : ctx.resolve(label, "label")
        return ctx.formRow(label: lbl, control: [control])
    }
}

extension Picker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(titleKey) }
    }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(title) }
    }
}

extension Picker where Label == SwiftUI.Label<Text, Image> {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { SwiftUI.Label(titleKey, systemImage: systemImage) }
    }
}

/// `.tag(_:)`: the value a Picker row selects.
struct TagView<Content: View, V: Hashable>: View, PrimitiveView {
    typealias Body = Never
    let content: Content
    let value: V
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        ctx.resolve(content, "tag").map { n in
            let t = TaggedNode(n)
            t.tag = AnyHashable(value)
            t.tagValue = value
            return t
        }
    }
}

extension View {
    public func tag<V: Hashable>(_ tag: V) -> some View { TagView(content: self, value: tag) }
    public func tag<V: Hashable>(_ tag: V, includeOptional: Bool) -> some View { TagView(content: self, value: tag) }
}

// MARK: Menu

public struct Menu<Label: View, Content: View>: View, PrimitiveView {
    public typealias Body = Never
    let label: Label
    let content: Content
    let primaryAction: (@MainActor () -> Void)?
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) { self.content = content(); self.label = label(); primaryAction = nil }
    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label, primaryAction: @escaping @MainActor () -> Void) {
        self.content = content(); self.label = label(); self.primaryAction = primaryAction
    }

    func items(_ ctx: ResolveContext) -> [MenuItemSpec] {
        var c = ctx.with { $0._inMenu = true }
        c.dryRun = true
        var out: [MenuItemSpec] = []
        func walk(_ n: LayoutNode) {
            if let m = n.menuItem { out.append(m); return }
            if n is DividerMarker { out.append(.separator); return }
            n.children.forEach(walk)
        }
        c.resolve(content, "items").forEach(walk)
        return out
    }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let title = ctx.labelText(label)
        let menu = items(ctx)
        if ctx.env._inMenu {
            return [WidgetNode(nil, backend: ctx.host.backend, text: title, item: MenuItemSpec(title: title, enabled: ctx.env.isEnabled, children: menu))]
        }
        var p = ctx.baseProps()
        p.title = title
        p.bordered = !ctx.env._mobileToolbarItem && ctx.env._buttonStyle != .borderless && ctx.env._buttonStyle != .plain
        p.hasContent = ctx.env._mobilePreview
        if !p.hasContent, case let .symbol(s)? = ctx.plainTitle(label) == nil ? firstSymbol(ctx) : nil { p.image = .symbol(s) }
        var events = WidgetEvents()
        events.menu = menu
        events.onTap = primaryAction
        let w = ctx.widget(.menuButton)
        if let w { ctx.host.backend.update(w, props: p, events: events) }
        if p.hasContent {
            let labelContext = ctx.with { env in
                if env._foreground == nil { env._foreground = AnyShapeStyle(env._tint ?? .accentColor) }
            }
            let children = labelContext.resolve(label, "label")
            let content = children.count == 1 ? children[0] : StackNode(axis: .horizontal, alignment: 0.5, spacing: 4, children: children)
            let backend = ctx.host.backend
            let node = ContainerNode(widget: w, backend: backend, content: content, sizing: .hug,
                                     insets: w.map { backend.contentInsets($0) } ?? .zero)
            let minimum = ctx.env._mobileToolbarItem ? (ctx.env._mobilePreviewProfile ?? .iphonePro).toolbarHeight : 36
            node.minSize = CGSize(width: minimum, height: minimum)
            return [node]
        }
        return [WidgetNode(w, backend: ctx.host.backend, text: title)]
    }

    private func firstSymbol(_ ctx: ResolveContext) -> ImageSource? {
        if let l = label as? SwiftUI.Label<Text, Image> { return l.icon.imageSource }
        if let i = label as? Image { return i.imageSource }
        return nil
    }
}

extension Menu where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) { self.init(content: content) { Text(titleKey) } }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) { self.init(content: content) { Text(title) } }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    public init(_ titleKey: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(titleKey, systemImage: systemImage) }
    }
}

/// Marks a Divider inside a menu.
final class DividerMarker: LayoutNode {}

// MARK: Link

public struct Link<Label: View>: View, PrimitiveView {
    public typealias Body = Never
    let label: Label
    let destination: URL
    public init(destination: URL, @ViewBuilder label: () -> Label) { self.destination = destination; self.label = label() }

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let url = destination
        let open = ctx.env.openURL
        var events = WidgetEvents()
        events.onTap = { open(url) }
        var p = ctx.baseProps()
        let item = MenuItemSpec(title: ctx.labelText(label)) { open(url) }
        if let title = ctx.plainTitle(label) {
            p.title = title
            if let font = ctx.env.font { p.text = StyledText(runs: [TextRun(string: title, font: font.resolved(in: ctx.env), color: nil)]) }
            let w = ctx.widget(.link)
            if let w { ctx.host.backend.update(w, props: p, events: events) }
            return [WidgetNode(w, backend: ctx.host.backend, text: title, item: item)]
        }
        let content = ctx.with { $0._foreground = AnyShapeStyle(Color.accentColor) }.resolve(label, "label")
        let w = ctx.widget(.tapArea)
        if let w { ctx.host.backend.update(w, props: p, events: events) }
        let inner: LayoutNode = content.count == 1 ? content[0] : StackNode(axis: .horizontal, alignment: 0.5, spacing: 4, children: content)
        let node = ContainerNode(widget: w, backend: ctx.host.backend, content: inner, sizing: .hug)
        node.item = item
        return [node]
    }
}

extension Link where Label == Text {
    public init(_ titleKey: LocalizedStringKey, destination: URL) { self.init(destination: destination) { Text(titleKey) } }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, destination: URL) { self.init(destination: destination) { Text(title) } }
}

// MARK: ProgressView

public struct ProgressView<Label: View, CurrentValueLabel: View>: View, PrimitiveView {
    public typealias Body = Never
    let value: Double?
    let total: Double
    let label: Label?
    var currentValueLabel: CurrentValueLabel?

    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        var p = ctx.baseProps()
        let style = ctx.env._progressStyle
        let circular = style == .circular || (style == .automatic && value == nil)
        p.indeterminate = value == nil
        p.number = value.map { total > 0 ? min(1, max(0, $0 / total)) : 0 } ?? 0
        let w = ctx.widget(.progress(circular: circular))
        if let w { ctx.host.backend.update(w, props: p, events: WidgetEvents()) }
        let n = WidgetNode(w, backend: ctx.host.backend)
        if !circular { n.flexibleWidth = true; n.idealWidth = 160 }
        var children: [LayoutNode] = []
        if let label, Label.self != EmptyView.self { children += ctx.resolve(label, "label") }
        children.append(n)
        if let currentValueLabel, CurrentValueLabel.self != EmptyView.self {
            children += ctx.resolve(currentValueLabel.font(.caption).foregroundStyle(.secondary), "current")
        }
        if children.count > 1 { return [StackNode(axis: .vertical, alignment: 0, spacing: 4, children: children)] }
        return [n]
    }
}

extension ProgressView {
    /// A bar with a label above and the current value's description below.
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0, @ViewBuilder label: () -> Label,
                                        @ViewBuilder currentValueLabel: () -> CurrentValueLabel) {
        self.value = value.map { Double($0) }
        self.total = Double(total)
        self.label = label()
        self.currentValueLabel = currentValueLabel()
    }
}

extension ProgressView where Label == EmptyView, CurrentValueLabel == EmptyView {
    public init() { value = nil; total = 1; label = nil }
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0) { self.value = value.map { Double($0) }; self.total = Double(total); label = nil }
}

extension ProgressView where CurrentValueLabel == EmptyView {
    public init(@ViewBuilder label: () -> Label) { value = nil; total = 1; self.label = label() }
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0, @ViewBuilder label: () -> Label) {
        self.value = value.map { Double($0) }; self.total = Double(total); self.label = label()
    }
}

extension ProgressView where Label == Text, CurrentValueLabel == EmptyView {
    public init(_ titleKey: LocalizedStringKey) { value = nil; total = 1; label = Text(titleKey) }
    public init<V: BinaryFloatingPoint>(_ titleKey: LocalizedStringKey, value: V?, total: V = 1.0) {
        self.value = value.map { Double($0) }; self.total = Double(total); label = Text(titleKey)
    }
}

// MARK: ColorPicker

public struct ColorPicker<Label: View>: View, PrimitiveView {
    public typealias Body = Never
    let selection: Binding<Color>
    let supportsOpacity: Bool
    let label: Label
    public init(selection: Binding<Color>, supportsOpacity: Bool = true, @ViewBuilder label: () -> Label) {
        self.selection = selection; self.supportsOpacity = supportsOpacity; self.label = label()
    }
    func resolve(in ctx: ResolveContext) -> [LayoutNode] {
        let selection = self.selection
        var events = WidgetEvents()
        events.onColor = { selection.wrappedValue = Color(rgba: $0) }
        var p = ctx.baseProps()
        p.color = selection.wrappedValue.resolve(ctx.env)
        let w = ctx.widget(.colorWell)
        if let w { ctx.host.backend.update(w, props: p, events: events) }
        let n = WidgetNode(w, backend: ctx.host.backend)
        n.idealWidth = 44
        let lbl = ctx.labelText(label).isEmpty ? [] : ctx.resolve(label, "label")
        return ctx.formRow(label: lbl, control: [n])
    }
}

extension ColorPicker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<Color>, supportsOpacity: Bool = true) {
        self.init(selection: selection, supportsOpacity: supportsOpacity) { Text(titleKey) }
    }
    @_disfavoredOverload public init<S: StringProtocol>(_ title: S, selection: Binding<Color>, supportsOpacity: Bool = true) {
        self.init(selection: selection, supportsOpacity: supportsOpacity) { Text(title) }
    }
}

extension ColorPicker {
    /// For CGColor bindings.
    public init(selection: Binding<CGColor>, supportsOpacity: Bool = true, @ViewBuilder label: () -> Label) {
        self.init(selection: Binding(get: {
            let c = selection.wrappedValue.components ?? [0, 0, 0, 1]
            return Color(red: Double(c[0]), green: Double(c.count > 1 ? c[1] : c[0]), blue: Double(c.count > 2 ? c[2] : c[0]), opacity: Double(c.last ?? 1))
        }, set: { color in
            let rgba = MainActor.assumeIsolated { color.resolve(EnvironmentValues()) }
            selection.wrappedValue = CGColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
        }), supportsOpacity: supportsOpacity, label: label)
    }
}
