// SwiftUI's accessibility modifiers. Each wraps its view in a pass-through
// container whose props carry what it declares; modifiers applied in a row
// merge into one wrapper. Backends expose the container (or, when it wraps
// a single control, that control) to assistive technologies.

import Foundation
import RunwayCore

extension View {
    /// Records accessibility information on the view's wrapper.
    func accessibility(_ change: @escaping @MainActor (inout AccessibilityProps) -> Void,
                       actions: [(name: String, perform: () -> Void)] = []) -> some View {
        nodes("a11y") { ns, ctx in
            guard !ctx.dryRun else { return ns }
            let backend = ctx.host.backend
            // Directly on another accessibility modifier: one wrapper for both.
            var props = AccessibilityProps()
            change(&props)
            var allActions = actions
            var content = ns.count == 1 ? ns[0] : ZStackNode(alignment: .center, children: ns)
            var reuse: NativeWidget?
            if ns.count == 1, let inner = ns[0] as? ContainerNode, let current = inner.accessibility {
                let merged = props.over(current)
                // Same role: the inner wrapper serves (one native widget for the chain).
                if merged.wrapperRole == current.wrapperRole { reuse = inner.widget }
                props = merged
                allActions += inner.accessibilityActions
                content = inner.content
            }
            let role = props.wrapperRole
            let w = reuse ?? ctx.host.customWidget(ctx.path + "#a11y\(role.rawValue)", fresh: false) {
                let w = backend.makeAccessibilityContainer(role: role)
                (backend as? AppKitBackend)?.setPassesThrough(w, true)
                return w
            }
            var p = ctx.baseProps()
            p.accessibility = props
            var e = WidgetEvents()
            e.accessibilityActions = allActions
            backend.update(w, props: p, events: e)
            let node = ContainerNode.modifier(w, backend, content)
            node.accessibility = props
            node.accessibilityActions = allActions
            return [node]
        }
    }

    public func accessibilityLabel(_ label: Text) -> some View { accessibility { $0.label = label.plainText } }
    public func accessibilityLabel(_ label: LocalizedStringKey) -> some View { accessibility { $0.label = label.string } }
    @_disfavoredOverload public func accessibilityLabel<S: StringProtocol>(_ label: S) -> some View {
        let s = String(label)
        return accessibility { $0.label = s }
    }
    public func accessibilityValue(_ value: Text) -> some View { accessibility { $0.value = value.plainText } }
    public func accessibilityValue(_ value: LocalizedStringKey) -> some View { accessibility { $0.value = value.string } }
    @_disfavoredOverload public func accessibilityValue<S: StringProtocol>(_ value: S) -> some View {
        let s = String(value)
        return accessibility { $0.value = s }
    }
    public func accessibilityHint(_ hint: Text) -> some View { accessibility { $0.hint = hint.plainText } }
    public func accessibilityHint(_ hint: LocalizedStringKey) -> some View { accessibility { $0.hint = hint.string } }
    @_disfavoredOverload public func accessibilityHint<S: StringProtocol>(_ hint: S) -> some View {
        let s = String(hint)
        return accessibility { $0.hint = s }
    }
    public func accessibilityIdentifier(_ id: String) -> some View { accessibility { $0.identifier = id } }
    public func accessibilityHidden(_ hidden: Bool) -> some View { accessibility { $0.hidden = hidden } }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View {
        accessibility { $0.element = true; $0.children = children.value }
    }
    public func accessibilityAddTraits(_ traits: AccessibilityTraits) -> some View {
        accessibility { $0.traits = AccessibilityProps.Traits(rawValue: traits.rawValue) }
    }
    public func accessibilityRemoveTraits(_ traits: AccessibilityTraits) -> some View {
        accessibility { $0.removedTraits = AccessibilityProps.Traits(rawValue: traits.rawValue) }
    }
    public func accessibilityHeading(_ level: AccessibilityHeadingLevel) -> some View {
        accessibility { $0.traits = .header }
    }
    public func accessibilityAction(_ kind: AccessibilityActionKind = .default, _ handler: @escaping () -> Void) -> some View {
        accessibility({ _ in }, actions: [(kind.name, handler)])
    }
    public func accessibilityAction(named name: Text, _ handler: @escaping () -> Void) -> some View {
        accessibility({ _ in }, actions: [(name.plainText, handler)])
    }
    public func accessibilityAction(named name: LocalizedStringKey, _ handler: @escaping () -> Void) -> some View {
        accessibility({ _ in }, actions: [(name.string, handler)])
    }
    public func accessibilityAdjustableAction(_ handler: @escaping (AccessibilityAdjustmentDirection) -> Void) -> some View {
        accessibility({ _ in }, actions: [("increment", { handler(.increment) }), ("decrement", { handler(.decrement) })])
    }
    public func accessibilitySortPriority(_ p: Double) -> some View { self }
}

public enum AccessibilityHeadingLevel: Sendable { case unspecified, h1, h2, h3, h4, h5, h6 }
