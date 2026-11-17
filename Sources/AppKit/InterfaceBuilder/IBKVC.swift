// Connections by key: outlets (the app's `@IBOutlet`s through the
// transpiler's generated KVC tables; AppKit's own outlets — delegates,
// data sources, `view`, `window`, `menu`, `nextKeyView`… — here), actions,
// and user-defined runtime attributes.

import Foundation
import QuartzCore

@MainActor
enum IBKVC {
    /// Sets outlet `key` of `source` to `value` (an object, an array for
    /// outlet collections, or nil for First Responder).
    static func setOutlet(_ key: String, of source: AnyObject, to value: Any?, loader: IBLoader?) {
        // The app's classes: their generated table (`@IBOutlet var x`).
        var m = Message(.setValue(key, value))
        if RunwayObjC.handle(source, &m) { return }
        if setFrameworkOutlet(key, of: source, to: value) { return }
        loader?.report("\(type(of: source)) has no outlet '\(key)' Runway can set")
    }

    /// AppKit's outlets.
    static func setFrameworkOutlet(_ key: String, of source: AnyObject, to value: Any?) -> Bool {
        let obj = value.flatMap { $0 as AnyObject? }
        switch (key, source) {
        case ("delegate", let a as NSApplication):
            guard let d = obj as? NSApplicationDelegate else { return false }
            a.delegate = d
            IBRetained.keep(obj!)
            return true
        case ("delegate", let w as NSWindow): w.delegate = obj as? NSWindowDelegate; return true
        case ("delegate", let t as NSTableView): t.delegate = obj as? NSTableViewDelegate; return true
        case ("dataSource", let t as NSTableView): t.dataSource = obj as? NSTableViewDataSource; return true
        case ("delegate", let t as NSTextField): t.delegate = obj as? NSTextFieldDelegate; return true
        case ("dataSource", let c as NSComboBox): c.dataSource = obj as? NSComboBoxDataSource; return true
        case ("delegate", let t as NSTextView): t.delegate = obj as? NSTextViewDelegate; return true
        case ("delegate", let m as NSMenu): m.delegate = obj as? NSMenuDelegate; return true
        case ("delegate", let s as NSSplitView): s.delegate = obj as? NSSplitViewDelegate; return true
        case ("delegate", let s as NSStackView): s.delegate = obj as? NSStackViewDelegate; return true
        case ("delegate", let t as NSTabView): t.delegate = obj as? NSTabViewDelegate; return true
        case ("delegate", let p as NSPopover): p.delegate = obj as? NSPopoverDelegate; return true
        case ("delegate", let c as NSCollectionView): c.delegate = obj as? NSCollectionViewDelegate; return true
        case ("dataSource", let c as NSCollectionView): c.dataSource = obj as? NSCollectionViewDataSource; return true
        case ("delegate", let t as NSToolbar):
            if let p = IBToolbarProvider.provider(t) { p.appDelegate = obj as? NSToolbarDelegate; t.reload() } else { t.delegate = obj as? NSToolbarDelegate }
            return true
        case ("delegate", let d as NSDatePicker): d.delegate = obj as? NSDatePickerCellDelegate; return true
        case ("view", let vc as NSViewController):
            guard let v = obj as? NSView else { return false }
            vc.view = v
            return true
        case ("view", let t as NSTabViewItem): t.view = obj as? NSView; return true
        case ("view", let i as NSMenuItem): i.view = obj as? NSView; return true
        case ("view", let i as NSToolbarItem): i.view = obj as? NSView; return true
        case ("window", let wc as NSWindowController): wc.window = obj as? NSWindow; return true
        case ("contentViewController", let p as NSPopover): p.contentViewController = obj as? NSViewController; return true
        case ("contentViewController", let w as NSWindow): w.contentViewController = obj as? NSViewController; return true
        case ("contentView", let w as NSWindow): w.contentView = obj as? NSView; return true
        case ("contentView", let b as NSBox): b.contentView = obj as? NSView; return true
        case ("initialFirstResponder", let w as NSWindow): w.initialFirstResponder = obj as? NSView; return true
        case ("nextKeyView", let v as NSView): v.nextKeyView = obj as? NSView; return true
        case ("menu", let r as NSResponder): r.menu = obj as? NSMenu; return true
        case ("menu", let i as NSStatusItem): i.menu = obj as? NSMenu; return true
        case ("submenu", let i as NSMenuItem): i.submenu = obj as? NSMenu; return true
        case ("textField", let c as NSTableCellView): c.textField = obj as? NSTextField; return true
        case ("imageView", let c as NSTableCellView): c.imageView = obj as? NSImageView; return true
        case ("documentView", let s as NSScrollView): s.documentView = obj as? NSView; return true
        case ("formatter", let c as NSControl): c.formatter = obj as? Formatter; return true
        case ("mainMenu", let a as NSApplication): a.mainMenu = obj as? NSMenu; return true
        case ("windowsMenu", let a as NSApplication): a.windowsMenu = obj as? NSMenu; return true
        case ("servicesMenu", let a as NSApplication): a.servicesMenu = obj as? NSMenu; return true
        case ("helpMenu", let a as NSApplication): a.helpMenu = obj as? NSMenu; return true
        case ("outlineTableColumn", let o as NSOutlineView): o.outlineTableColumn = obj as? NSTableColumn; return true
        case ("headerView", let t as NSTableView): t.headerView = obj as? NSTableHeaderView; return true
        case ("cornerView", let t as NSTableView): t.cornerView = obj as? NSView; return true
        case ("toolbar", let w as NSWindow): w.toolbar = obj as? NSToolbar; return true
        case ("searchMenuTemplate", let s as NSSearchField): s.searchMenuTemplate = obj as? NSMenu; return true
        case ("splitView", let s as NSSplitViewController):
            if let v = obj as? NSSplitView { s.splitView = v }
            return true
        case ("tabView", let t as NSTabViewController):
            if let v = obj as? NSTabView { t.tabView = v }
            return true
        case ("collectionView", let i as NSCollectionViewItem): _ = i; return true
        case ("representedObject", let vc as NSViewController): vc.representedObject = value; return true
        case ("representedObject", let i as NSMenuItem): i.representedObject = value; return true
        case ("target", let c as NSControl): c.target = obj; return true
        case ("target", let i as NSMenuItem): i.target = obj; return true
        case ("dockMenu", _): return true
        default:
            return false
        }
    }

    /// An action connection: the source sends `selector` to `target`
    /// (nil: the responder chain).
    static func setAction(_ selector: Selector, target: AnyObject?, of source: AnyObject, trigger: String? = nil) {
        if trigger == "doubleAction", let t = source as? NSTableView {
            t.doubleAction = selector
            t.target = target
            return
        }
        switch source {
        case let c as NSControl: c.target = target; c.action = selector
        case let i as NSMenuItem: i.target = target; i.action = selector
        case let i as NSToolbarItem: i.target = target; i.action = selector
        default:
            var m = Message(.setValue("action", selector))
            _ = RunwayObjC.handle(source, &m)
            var t = Message(.setValue("target", target))
            _ = RunwayObjC.handle(source, &t)
        }
    }

    // MARK: User-defined runtime attributes

    static func applyRuntimeAttributes(_ list: IBElement, to object: AnyObject, loader: IBLoader) {
        list.consumed = true
        for a in list.children("userDefinedRuntimeAttribute") {
            guard let path = a["keyPath"] else { continue }
            let value = runtimeValue(a, loader: loader)
            setValue(value, forKeyPath: path, of: object, loader: loader)
        }
    }

    static func runtimeValue(_ a: IBElement, loader: IBLoader) -> Any? {
        let v = a["value"]
        switch a["type"] {
        case "boolean": return v.map { $0 == "YES" } ?? false
        case "number":
            if let v, let d = Double(v) { return v.contains(".") ? NSNumber(value: d) : NSNumber(value: Int(d)) }
            if let r = a.child(key: "value", "real")?.double("value") { return NSNumber(value: r) }
            if let i = a.child(key: "value", "integer")?.int("value") { return NSNumber(value: i) }
            return nil
        case "string": return v ?? IBValue.string(a.child(key: "value", "string")) ?? ""
        case "localizedString": return v.map { Bundle.main.localizedString(forKey: $0, value: $0, table: nil) }
        case "color": return IBValue.color(a.child(key: "value", "color"), resources: loader.resources)
        case "image": return IBValue.image(named: v)
        case "point": return IBValue.point(a.child(key: "value", "point")).map { NSValue(point: $0) }
        case "size": return IBValue.size(a.child(key: "value", "size")).map { NSValue(size: $0) }
        case "rect": return IBValue.rect(a.child(key: "value", "rect")).map { NSValue(rect: $0) }
        case "range":
            guard let r = a.child(key: "value", "range") else { return nil }
            return NSValue(range: NSRange(location: r.int("location") ?? 0, length: r.int("length") ?? 0))
        case "nil": return nil
        default: return v
        }
    }

    /// KVC set along a key path: the app's tables first, then AppKit
    /// properties IB documents commonly set (layer styling, colours, flags).
    static func setValue(_ value: Any?, forKeyPath path: String, of object: AnyObject, loader: IBLoader?) {
        var parts = path.split(separator: ".").map(String.init)
        let last = parts.removeLast()
        var target: AnyObject = object
        for p in parts {
            if p == "layer", let v = target as? NSView {
                v.wantsLayer = true
                guard let l = v.layer else { return }
                target = l
                continue
            }
            var m = Message(.value(p))
            guard RunwayObjC.handle(target, &m), let next = m.result.map({ $0 as AnyObject }) else {
                loader?.report("runtime attribute \(path): no '\(p)' on \(type(of: target))")
                return
            }
            target = next
        }
        var m = Message(.setValue(last, value))
        if RunwayObjC.handle(target, &m) { return }
        if setFrameworkValue(last, of: target, to: value) { return }
        if setFrameworkOutlet(last, of: target, to: value) { return }
        loader?.report("runtime attribute \(path): \(type(of: target)) isn't key value coding-compliant for '\(last)'")
    }

    static func cgColor(_ v: Any?) -> CGColor? {
        if let c = v as? NSColor { return c.cgColor }
        return v as? CGColor
    }
    static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let b as Bool: return b ? 1 : 0
        case let s as String: return Double(s)
        default: return nil
        }
    }
    static func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        return number(v).map { $0 != 0 }
    }

    static func setFrameworkValue(_ key: String, of target: AnyObject, to value: Any?) -> Bool {
        if let l = target as? CALayer {
            switch key {
            case "cornerRadius": if let n = number(value) { l.cornerRadius = CGFloat(n) }; return true
            case "borderWidth": if let n = number(value) { l.borderWidth = CGFloat(n) }; return true
            case "borderColor": l.borderColor = cgColor(value); return true
            case "backgroundColor": l.backgroundColor = cgColor(value); return true
            case "masksToBounds": if let b = bool(value) { l.masksToBounds = b }; return true
            case "opacity": if let n = number(value) { l.opacity = Float(n) }; return true
            default: return false
            }
        }
        switch (key, target) {
        case ("toolTip", let v as NSView): v.toolTip = value as? String; return true
        case ("hidden", let v as NSView): v.isHidden = bool(value) ?? false; return true
        case ("alphaValue", let v as NSView): if let n = number(value) { v.alphaValue = CGFloat(n) }; return true
        case ("wantsLayer", let v as NSView): v.wantsLayer = bool(value) ?? false; return true
        case ("identifier", let v as NSView): v.identifier = (value as? String).map { NSUserInterfaceItemIdentifier($0) }; return true
        case ("enabled", let c as NSControl): c.isEnabled = bool(value) ?? true; return true
        case ("stringValue", let c as NSControl): c.stringValue = value as? String ?? ""; return true
        case ("doubleValue", let c as NSControl): c.doubleValue = number(value) ?? 0; return true
        case ("integerValue", let c as NSControl): c.integerValue = Int(number(value) ?? 0); return true
        case ("tag", let c as NSView): if let n = number(value) { (c as? NSControl)?.tag = Int(n) }; return true
        case ("textColor", let t as NSTextField): t.textColor = value as? NSColor; return true
        case ("backgroundColor", let t as NSTextField): t.backgroundColor = value as? NSColor; return true
        case ("drawsBackground", let t as NSTextField): t.drawsBackground = bool(value) ?? false; return true
        case ("placeholderString", let t as NSTextField): t.placeholderString = value as? String; return true
        case ("contentTintColor", let b as NSButton): b.contentTintColor = value as? NSColor; return true
        case ("bezelColor", let b as NSButton): b.bezelColor = value as? NSColor; return true
        case ("title", let b as NSButton): b.title = value as? String ?? ""; return true
        case ("image", let b as NSButton): b.image = value as? NSImage; return true
        case ("image", let i as NSImageView): i.image = value as? NSImage; return true
        case ("contentTintColor", let i as NSImageView): i.contentTintColor = value as? NSColor; return true
        case ("fillColor", let b as NSBox): if let c = value as? NSColor { b.fillColor = c }; return true
        case ("borderColor", let b as NSBox): if let c = value as? NSColor { b.borderColor = c }; return true
        case ("cornerRadius", let b as NSBox): if let n = number(value) { b.cornerRadius = CGFloat(n) }; return true
        case ("backgroundColor", let w as NSWindow): w.backgroundColor = value as? NSColor; return true
        case ("title", let w as NSWindow): w.title = value as? String ?? ""; return true
        case ("title", let i as NSMenuItem): i.title = value as? String ?? ""; return true
        case ("rowHeight", let t as NSTableView): if let n = number(value) { t.rowHeight = CGFloat(n) }; return true
        case ("spacing", let s as NSStackView): if let n = number(value) { s.spacing = CGFloat(n) }; return true
        case ("material", let v as NSVisualEffectView): if let n = number(value), let m = NSVisualEffectView.Material(rawValue: Int(n)) { v.material = m }; return true
        case ("preferredContentSize", let vc as NSViewController): if let s = (value as? NSValue)?.sizeValue { vc.preferredContentSize = s }; return true
        default: return false
        }
    }
}

/// Objects nib loading keeps alive (Cocoa's nib loading retains its
/// top-level objects; delegates are weak references).
@preconcurrency @MainActor public enum IBRetained {
    static var objects: [AnyObject] = []
    static func keep(_ o: AnyObject) { if !objects.contains(where: { $0 === o }) { objects.append(o) } }
}
