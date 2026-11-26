// The accessibility tree of a window's widgets, built the way SwiftUI and
// AppKit build theirs: controls are elements with a role, a name, a value
// and states; layout containers are transparent; what accessibility
// modifiers declare (AccessibilityProps) renames, hides, merges or groups.
// Backends that draw their own controls hand this tree to the platform's
// accessibility API (UI Automation, AT-SPI).

import CoreGraphics
import Foundation

/// A screen reader's idea of what an element is.
public enum AccessibleRole: Int32, Sendable {
    case group = 0, button, checkBox, switchControl, staticText, textField, textArea, image, link, slider
    case comboBox, tabList, progressBar, scrollArea, heading, menuButton, colorWell, stepper, separator
    case searchField, window, toggleButton
}

public struct AccessibleStates: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let disabled = AccessibleStates(rawValue: 1)
    public static let focusable = AccessibleStates(rawValue: 2)
    public static let focused = AccessibleStates(rawValue: 4)
    /// Checkable, and checked (`checkable` alone: unchecked).
    public static let checked = AccessibleStates(rawValue: 8)
    public static let checkable = AccessibleStates(rawValue: 16)
    public static let selected = AccessibleStates(rawValue: 32)
    public static let editable = AccessibleStates(rawValue: 64)
    public static let multiline = AccessibleStates(rawValue: 128)
    public static let protected = AccessibleStates(rawValue: 256)
    public static let mixed = AccessibleStates(rawValue: 512)
    public static let modal = AccessibleStates(rawValue: 1024)
}

/// One element: what a screen reader announces, where it is, and what
/// can be done with it.
@MainActor public final class AccessibleElement {
    public var role: AccessibleRole
    public var name: String
    public var value: String?
    public var hint: String?
    public var identifier: String?
    public var states: AccessibleStates = []
    /// In window coordinates.
    public var frame: CGRect
    /// Numeric value and range (sliders, steppers, progress).
    public var range: (value: Double, min: Double, max: Double)?
    public var actions: [(name: String, perform: () -> Void)] = []
    /// Sets the value (text fields); nil when it's read-only.
    public var setValue: ((String) -> Void)?
    public var children: [AccessibleElement] = []
    /// The widget it came from (to focus it, or find it again).
    public weak var source: AnyObject?

    public init(role: AccessibleRole, name: String = "", frame: CGRect = .zero) {
        self.role = role; self.name = name; self.frame = frame
    }

    /// Runs the named action ("default" for the primary one); false when
    /// there's no such action.
    @discardableResult public func perform(_ name: String = "default") -> Bool {
        guard let a = actions.first(where: { $0.name == name }) ?? (name == "default" ? actions.first : nil) else { return false }
        a.perform()
        return true
    }

    /// Depth-first, this element first.
    public var all: [AccessibleElement] { [self] + children.flatMap(\.all) }

    /// The text of this element and everything in it (a combined label).
    var spokenText: String {
        var parts: [String] = []
        if !name.isEmpty { parts.append(name) }
        if let value, !value.isEmpty, role != .textField, role != .textArea { parts.append(value) }
        for c in children { let t = c.spokenText; if !t.isEmpty { parts.append(t) } }
        return parts.joined(separator: ", ")
    }

    public func dump(_ indent: String = "") -> String {
        var line = indent + "\(role) \"\(name)\""
        if let value { line += " value=\"\(value)\"" }
        if let hint { line += " hint=\"\(hint)\"" }
        if !states.isEmpty { line += " states=\(states.rawValue)" }
        if !actions.isEmpty { line += " actions=" + actions.map(\.name).joined(separator: ",") }
        return ([line] + children.map { $0.dump(indent + "  ") }).joined(separator: "\n")
    }
}

/// A widget as the tree builder sees it.
@MainActor public protocol AccessibilitySourceWidget: AnyObject {
    var accessibilityKind: WidgetKind { get }
    var accessibilityProps: WidgetProps { get }
    var accessibilityEvents: WidgetEvents { get }
    /// In window coordinates.
    var accessibilityFrame: CGRect { get }
    /// Children in reading order (front to back is fine: the builder sorts
    /// siblings top to bottom, then leading to trailing).
    var accessibilityChildren: [AccessibilitySourceWidget] { get }
    /// Whether the widget has keyboard focus.
    var accessibilityFocused: Bool { get }
}

@MainActor public enum AccessibilityTree {
    /// The elements of `root`'s subtree (the window's content), under a
    /// window element named `title`.
    public static func build(_ root: AccessibilitySourceWidget, title: String, frame: CGRect) -> AccessibleElement {
        let window = AccessibleElement(role: .window, name: title, frame: frame)
        window.children = elements(root)
        return window
    }

    /// The elements one widget contributes (none, one, or its children's
    /// when it's a transparent container).
    public static func elements(_ w: AccessibilitySourceWidget) -> [AccessibleElement] {
        let p = w.accessibilityProps
        let a = p.accessibility
        if a?.hidden == true { return [] }
        if p.opacity <= 0.01 && a == nil { return [] }
        let kids = ordered(w.accessibilityChildren.flatMap { elements($0) })
        var out: [AccessibleElement]
        if let e = control(w, kids) {
            out = [e]
        } else {
            out = kids
        }
        guard let a else { return out }
        return apply(a, w, out)
    }

    /// Siblings in reading order: rows top to bottom, then leading to trailing.
    static func ordered(_ list: [AccessibleElement]) -> [AccessibleElement] {
        guard list.count > 1 else { return list }
        return list.enumerated().sorted { x, y in
            let a = x.element.frame, b = y.element.frame
            // Same row when they overlap vertically by half the shorter one.
            let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
            if overlap >= min(a.height, b.height) / 2 && overlap > 0 {
                return a.minX != b.minX ? a.minX < b.minX : x.offset < y.offset
            }
            return a.minY != b.minY ? a.minY < b.minY : x.offset < y.offset
        }.map(\.element)
    }

    /// The element a control is, or nil for layout containers.
    static func control(_ w: AccessibilitySourceWidget, _ kids: [AccessibleElement]) -> AccessibleElement? {
        let p = w.accessibilityProps, ev = w.accessibilityEvents
        let f = w.accessibilityFrame
        func make(_ role: AccessibleRole, _ name: String) -> AccessibleElement {
            let e = AccessibleElement(role: role, name: name, frame: f)
            e.source = w
            if !p.enabled { e.states.insert(.disabled) }
            if w.accessibilityFocused { e.states.insert(.focused) }
            return e
        }
        /// A clickable thing's name: its title, else what it contains.
        func label(_ fallback: String) -> String {
            if !p.title.isEmpty { return p.title }
            let t = kids.map(\.spokenText).filter { !$0.isEmpty }.joined(separator: ", ")
            if !t.isEmpty { return t }
            if case let .symbol(s) = p.image { return symbolName(s) }
            return fallback
        }
        var e: AccessibleElement
        switch w.accessibilityKind {
        case .container, .canvas, .divider:
            // Event containers with a tap, or AppKit accessibility actions, act as buttons.
            guard ev.onTap != nil || ev.onTapLocation != nil else { return nil }
            e = make(.button, label(""))
            e.states.insert(.focusable)
        case .scroll:
            return nil
        case .text:
            let s = p.text?.plain ?? p.string
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            e = make(.staticText, s)
        case .button, .tapArea:
            e = make(.button, label(""))
            e.states.insert(.focusable)
        case .menuButton:
            e = make(.menuButton, label(""))
            e.states.insert(.focusable)
        case let .toggle(kind):
            e = make(kind == .switch ? .switchControl : kind == .button ? .toggleButton : .checkBox, label(""))
            e.states.formUnion([.focusable, .checkable])
            if p.isOn { e.states.insert(.checked) }
            if p.indeterminate { e.states.insert(.mixed) }
            if let toggle = ev.onToggle { let on = p.isOn; e.actions.append(("default", { toggle(!on) })) }
        case let .textField(secure):
            e = make(.textField, p.placeholder)
            e.states.formUnion([.focusable, .editable])
            if secure { e.states.insert(.protected) } else { e.value = p.string }
            if let set = ev.onText { e.setValue = set }
        case .textEditor:
            e = make(.textArea, p.placeholder)
            e.states.formUnion([.focusable, .editable, .multiline])
            e.value = p.text?.plain ?? p.string
            if let set = ev.onText { e.setValue = set }
        case .slider:
            e = make(.slider, p.title)
            e.states.insert(.focusable)
            e.range = (p.number, p.range.lowerBound, p.range.upperBound)
            e.value = format(p.number)
            if let set = ev.onNumber {
                let step = p.step ?? (p.range.upperBound - p.range.lowerBound) / 10
                let v = p.number, r = p.range
                e.actions.append(("increment", { set(min(r.upperBound, v + step)) }))
                e.actions.append(("decrement", { set(max(r.lowerBound, v - step)) }))
            }
        case .stepper:
            e = make(.stepper, p.title)
            e.range = (p.number, p.range.lowerBound, p.range.upperBound)
            e.value = format(p.number)
            if let set = ev.onNumber {
                let step = p.step ?? 1, v = p.number, r = p.range
                e.actions.append(("increment", { set(min(r.upperBound, v + step)) }))
                e.actions.append(("decrement", { set(max(r.lowerBound, v - step)) }))
            }
        case .dropdown:
            e = make(.comboBox, p.title)
            e.states.insert(.focusable)
            if p.options.indices.contains(p.selected) { e.value = p.options[p.selected] }
        case .segmented:
            e = make(.tabList, p.title)
            for (i, title) in p.options.enumerated() {
                let tab = AccessibleElement(role: .toggleButton, name: title, frame: f)
                tab.states = i == p.selected ? [.checkable, .checked, .selected] : [.checkable]
                if let select = ev.onSelect { tab.actions.append(("default", { select(i) })) }
                e.children.append(tab)
            }
            return e
        case let .progress(circular):
            e = make(.progressBar, p.title)
            if !(circular && p.indeterminate) {
                e.range = (p.number, p.range.lowerBound, p.range.upperBound)
                e.value = format(p.number)
            }
        case .image:
            // Images are decorative unless they're labelled.
            guard let label = p.accessibility?.label else { return nil }
            e = make(.image, label)
        case .link:
            e = make(.link, label(""))
            e.states.insert(.focusable)
        case .colorWell:
            e = make(.colorWell, p.title)
            e.states.insert(.focusable)
        }
        // A control's primary action, unless it set its own.
        if !e.actions.contains(where: { $0.name == "default" }) {
            if let tap = ev.onTap { e.actions.insert(("default", tap), at: 0) }
            else if let tap = ev.onTapLocation {
                let c = CGPoint(x: f.width / 2, y: f.height / 2)
                e.actions.insert(("default", { tap(c) }), at: 0)
            }
        }
        // Text a button holds is its name, not separate elements.
        if [.button, .menuButton, .link, .checkBox, .switchControl, .toggleButton].contains(e.role) {
            e.children = kids.filter { $0.role != .staticText && $0.role != .image && !$0.actions.isEmpty }
        } else if e.role == .staticText || e.role == .image {
            e.children = []
        } else {
            e.children = kids
        }
        return e
    }

    /// What accessibility modifiers declared, applied to the elements a
    /// widget contributes.
    static func apply(_ a: AccessibilityProps, _ w: AccessibilitySourceWidget, _ list: [AccessibleElement]) -> [AccessibleElement] {
        let actions = w.accessibilityEvents.accessibilityActions
        let one: AccessibleElement
        if a.element {
            // One element standing for everything inside.
            switch a.children {
            case .contain:
                one = AccessibleElement(role: .group, name: a.label ?? "", frame: w.accessibilityFrame)
                one.children = list
            case .ignore, .combine:
                if list.count == 1, list[0].role != .group {
                    one = list[0]
                    if a.children == .combine { one.name = list[0].spokenText }
                } else {
                    one = AccessibleElement(role: a.traits.isEmpty ? .staticText : .group, frame: w.accessibilityFrame)
                    if a.children == .combine { one.name = list.map(\.spokenText).filter { !$0.isEmpty }.joined(separator: ", ") }
                    // Its children's actions are its own (a combined row's button).
                    for c in list.flatMap(\.all) { for act in c.actions where !one.actions.contains(where: { $0.name == act.name }) { one.actions.append(act) } }
                    one.states = list.first?.states.intersection([.disabled, .focused]) ?? []
                }
                one.children = []
            }
            one.source = w
        } else if list.count == 1 {
            // A label on a view that is one element (a control, a text) names that element.
            one = list[0]
        } else if a.label != nil || !a.traits.isEmpty || !actions.isEmpty {
            one = AccessibleElement(role: .group, name: "", frame: w.accessibilityFrame)
            one.children = list
            one.source = w
        } else if list.isEmpty && (a.label != nil || a.value != nil) {
            one = AccessibleElement(role: .staticText, frame: w.accessibilityFrame)
            one.source = w
        } else {
            // Only a hint or an identifier, over several elements: nothing to hang it on.
            return list
        }
        if let l = a.label { one.name = l }
        if let v = a.value { one.value = v }
        if let h = a.hint { one.hint = h }
        if let i = a.identifier { one.identifier = i }
        let traits = a.traits
        if traits.contains(.header) { one.role = .heading }
        if traits.contains(.button), ![.button, .menuButton, .toggleButton, .checkBox, .switchControl].contains(one.role) { one.role = .button }
        if traits.contains(.link) { one.role = .link }
        if traits.contains(.image), one.role == .staticText || one.role == .group { one.role = .image }
        if traits.contains(.searchField), one.role == .textField { one.role = .searchField }
        if traits.contains(.toggle), one.role == .button { one.role = .toggleButton; one.states.insert(.checkable) }
        if traits.contains(.selected) { one.states.insert(.selected) }
        if traits.contains(.modal) { one.states.insert(.modal) }
        if a.removedTraits.contains(.button), one.role == .button { one.role = .staticText }
        if a.removedTraits.contains(.selected) { one.states.remove(.selected) }
        if one.role == .button || one.role == .link { one.states.insert(.focusable) }
        for act in actions.reversed() {
            one.actions.removeAll { $0.name == act.name }
            one.actions.insert(act, at: 0)
        }
        return [one]
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(format: "%.2f", v)
    }

    /// A readable name for an SF Symbol ("square.and.arrow.up" → "square and arrow up").
    static func symbolName(_ s: String) -> String {
        s.split(separator: ".").filter { $0 != "fill" }.joined(separator: " ")
    }
}

extension HeadlessWidget: AccessibilitySourceWidget {
    public var accessibilityKind: WidgetKind { kind }
    public var accessibilityProps: WidgetProps { props }
    public var accessibilityEvents: WidgetEvents { events }
    public var accessibilityFrame: CGRect { windowFrame }
    public var accessibilityChildren: [AccessibilitySourceWidget] { children }
    public var accessibilityFocused: Bool { false }
}
