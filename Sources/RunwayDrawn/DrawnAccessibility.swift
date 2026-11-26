// The drawn backend's accessibility: RunwayCore's AccessibilityTree over
// the widget tree, flattened into rw_a11y_node for the platform layer (UI
// Automation on Windows, AT-SPI through GTK on Linux), which sends back
// actions, new values and focus requests by node index. Nothing is built
// until an assistive technology asks for a window's tree.

import Foundation
import RunwayCore
import CRunwayDrawn

extension DrawnWidget: AccessibilitySourceWidget {
    var accessibilityKind: WidgetKind { kind }
    var accessibilityProps: WidgetProps { props }
    var accessibilityEvents: WidgetEvents { events }
    var accessibilityFrame: CGRect { windowFrame }
    var accessibilityChildren: [AccessibilitySourceWidget] {
        if let d = document { return children + [d] }
        return children
    }
    var accessibilityFocused: Bool {
        editFocused || (hostWindow?.focusedContainer === self)
    }
}

extension DrawnWindow {
    /// Sends the window's tree when an assistive technology wants it; called
    /// after changes, at most a few times a second.
    func accessibilityChanged() {
        guard let n = native, rw_window_a11y_wanted(n) != 0, !a11yPending else { return }
        a11yPending = true
        backend.after(0.15) { [weak self] in
            self?.a11yPending = false
            self?.sendAccessibility()
        }
    }

    func sendAccessibility() {
        guard let n = native else { return }
        let tree = AccessibilityTree.build(root, title: title, frame: CGRect(origin: .zero, size: contentSize))
        var flat: [AccessibleElement] = []
        var parents: [Int32] = []
        var uids: [Int64] = []
        // An element's id: its widget's, else derived from its parent's and
        // its place there (so it holds across updates).
        func walk(_ e: AccessibleElement, _ parent: Int32, _ place: Int) {
            let index = Int32(flat.count)
            var uid: Int64
            if let s = e.source { uid = Int64(truncatingIfNeeded: ObjectIdentifier(s).hashValue) &* 31 &+ Int64(e.role.rawValue) }
            else if parent >= 0 { uid = uids[Int(parent)] &* 1_000_003 &+ Int64(place) &+ 1 }
            else { uid = 1 }
            uid &= Int64.max
            if uid == 0 { uid = 2 }
            flat.append(e)
            parents.append(parent)
            uids.append(uid)
            for (k, c) in e.children.enumerated() { walk(c, index, k) }
        }
        walk(tree, -1, 0)
        a11yElements = flat
        // C strings live until the call returns.
        var owned: [UnsafeMutablePointer<CChar>] = []
        func c(_ s: String?) -> UnsafePointer<CChar>? {
            guard let s else { return nil }
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        defer { owned.forEach { free($0) } }
        var nodes: [rw_a11y_node] = []
        nodes.reserveCapacity(flat.count)
        for (i, e) in flat.enumerated() {
            var node = rw_a11y_node()
            node.parent = parents[i]
            node.role = e.role.rawValue
            node.states = e.states.rawValue
            node.x = Double(e.frame.minX); node.y = Double(e.frame.minY)
            node.width = Double(e.frame.width); node.height = Double(e.frame.height)
            node.name = c(e.name)
            node.value = c(e.value)
            node.hint = c(e.hint)
            node.identifier = c(e.identifier)
            node.actions = e.actions.isEmpty ? nil : c(e.actions.map(\.name).joined(separator: "\n"))
            if let r = e.range { node.has_range = 1; node.number = r.value; node.minimum = r.min; node.maximum = r.max }
            node.settable = e.setValue != nil ? 1 : 0
            node.uid = uids[i]
            nodes.append(node)
        }
        nodes.withUnsafeBufferPointer { rw_window_set_a11y(n, $0.baseAddress, Int32($0.count)) }
    }

    /// An assistive technology's request (RW_EV_A11Y_*).
    func accessibilityEvent(_ ev: rw_event) -> Bool {
        if ev.type == RW_EV_A11Y_WANTED { sendAccessibility(); return true }
        let index = Int(ev.clicks)
        guard a11yElements.indices.contains(index) else { return false }
        let e = a11yElements[index]
        switch ev.type {
        case RW_EV_A11Y_ACTION:
            let k = Int(ev.key)
            guard e.actions.indices.contains(k) else { return false }
            e.actions[k].perform()
        case RW_EV_A11Y_SET:
            guard let set = e.setValue else { return false }
            set(ev.text.map { String(cString: $0) } ?? "")
        case RW_EV_A11Y_FOCUS:
            guard let w = e.source as? DrawnWidget else { return false }
            if let r = w.rich { rw_rich_focus(r.pointer) }
            else if let ed = w.edit { rw_edit_focus(ed.pointer, 1) }
            else if w.focusable { setFocusedContainer(w) }
            else { return false }
        default:
            return false
        }
        accessibilityChanged()
        return true
    }
}
