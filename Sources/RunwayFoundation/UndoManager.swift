// UndoManager (Foundation's on the Mac; swift-corelibs-foundation lacks
// it): groups of undo actions, redo, nesting, action names, levels, and
// the notifications, with registration by closure (and by selector, which
// AppKit adds: selectors are RunwayObjC's).

import Foundation

open class UndoManager: NSObject, @unchecked Sendable {
    private struct Action { weak var target: AnyObject?; let run: (AnyObject) -> Void }
    private final class Group { var actions: [Action] = []; var name = ""; var children: [Group] = [] }

    private var undoStack: [Group] = []
    private var redoStack: [Group] = []
    private var open: [Group] = []
    public private(set) var isUndoing = false
    public private(set) var isRedoing = false
    public var groupsByEvent = true
    public var levelsOfUndo = 0
    public private(set) var isUndoRegistrationEnabled = true
    private var disableCount = 0
    public var runLoopModes: [RunLoop.Mode] = [.default]
    private var autoGroupOpen = false

    public static let checkpointNotification = Notification.Name("NSUndoManagerCheckpointNotification")
    public static let willUndoChangeNotification = Notification.Name("NSUndoManagerWillUndoChangeNotification")
    public static let willRedoChangeNotification = Notification.Name("NSUndoManagerWillRedoChangeNotification")
    public static let didUndoChangeNotification = Notification.Name("NSUndoManagerDidUndoChangeNotification")
    public static let didRedoChangeNotification = Notification.Name("NSUndoManagerDidRedoChangeNotification")
    public static let didOpenUndoGroupNotification = Notification.Name("NSUndoManagerDidOpenUndoGroupNotification")
    public static let willCloseUndoGroupNotification = Notification.Name("NSUndoManagerWillCloseUndoGroupNotification")
    public static let didCloseUndoGroupNotification = Notification.Name("NSUndoManagerDidCloseUndoGroupNotification")

    public override init() { super.init() }

    public var groupingLevel: Int { open.count }

    public func beginUndoGrouping() {
        open.append(Group())
        NotificationCenter.default.post(name: Self.didOpenUndoGroupNotification, object: self)
    }
    public func endUndoGrouping() {
        guard let g = open.popLast() else { return }
        NotificationCenter.default.post(name: Self.willCloseUndoGroupNotification, object: self)
        if let parent = open.last {
            parent.children.append(g)
            if parent.name.isEmpty { parent.name = g.name }
        } else if !g.actions.isEmpty || !g.children.isEmpty {
            if isUndoing { redoStack.append(g) } else {
                undoStack.append(g)
                if !isRedoing { redoStack.removeAll() }
                if levelsOfUndo > 0, undoStack.count > levelsOfUndo { undoStack.removeFirst(undoStack.count - levelsOfUndo) }
            }
        }
        NotificationCenter.default.post(name: Self.didCloseUndoGroupNotification, object: self)
    }

    /// Registers in the open group, opening one for this turn of the run
    /// loop when grouping by event.
    private func register(_ a: Action) {
        guard disableCount == 0 else { return }
        if open.isEmpty {
            guard groupsByEvent else { return }
            beginUndoGrouping()
            autoGroupOpen = true
            RunLoop.main.perform { [weak self] in self?.closeAutoGroup() }
            DispatchQueue.main.async { [weak self] in self?.closeAutoGroup() }
        }
        open.last!.actions.append(a)
    }
    private func closeAutoGroup() {
        guard autoGroupOpen else { return }
        autoGroupOpen = false
        while !open.isEmpty { endUndoGrouping() }
    }

    public func registerUndo<Target: AnyObject>(withTarget target: Target, handler: @escaping (Target) -> Void) {
        register(Action(target: target) { handler($0 as! Target) })
    }
    /// Registers `action` to run on `target` (kept weakly) when undone.
    public func _registerUndo(withTarget target: AnyObject, action: @escaping (AnyObject) -> Void) {
        register(Action(target: target, run: action))
    }
    public func prepare(withInvocationTarget target: Any) -> Any { target }

    public var canUndo: Bool { flushAuto(); return !undoStack.isEmpty }
    public var canRedo: Bool { flushAuto(); return !redoStack.isEmpty }
    private func flushAuto() { if autoGroupOpen { closeAutoGroup() } }

    private func run(_ g: Group) {
        for c in g.children.reversed() { run(c) }
        for a in g.actions.reversed() { if let t = a.target { a.run(t) } }
    }

    public func undo() {
        flushAuto()
        while !open.isEmpty { endUndoGrouping() }
        undoNestedGroup()
    }
    public func undoNestedGroup() {
        guard let g = undoStack.popLast() else { return }
        NotificationCenter.default.post(name: Self.willUndoChangeNotification, object: self)
        isUndoing = true
        beginUndoGrouping()
        run(g)
        open.last?.name = g.name
        endUndoGrouping()
        isUndoing = false
        NotificationCenter.default.post(name: Self.didUndoChangeNotification, object: self)
    }
    public func redo() {
        flushAuto()
        guard let g = redoStack.popLast() else { return }
        NotificationCenter.default.post(name: Self.willRedoChangeNotification, object: self)
        isRedoing = true
        beginUndoGrouping()
        run(g)
        open.last?.name = g.name
        endUndoGrouping()
        isRedoing = false
        NotificationCenter.default.post(name: Self.didRedoChangeNotification, object: self)
    }

    public func removeAllActions() { undoStack.removeAll(); redoStack.removeAll(); open.removeAll(); autoGroupOpen = false }
    public func removeAllActions(withTarget target: Any) {
        let t = target as AnyObject
        func strip(_ g: Group) { g.actions.removeAll { $0.target === t }; g.children.forEach(strip) }
        (undoStack + redoStack + open).forEach(strip)
    }
    public func disableUndoRegistration() { disableCount += 1; isUndoRegistrationEnabled = false }
    public func enableUndoRegistration() { disableCount = max(0, disableCount - 1); isUndoRegistrationEnabled = disableCount == 0 }

    public func setActionName(_ name: String) { (open.last ?? undoStack.last)?.name = name }
    public var undoActionName: String { flushAuto(); return undoStack.last?.name ?? "" }
    public var redoActionName: String { redoStack.last?.name ?? "" }
    public var undoMenuItemTitle: String { undoMenuTitle(forUndoActionName: undoActionName) }
    public var redoMenuItemTitle: String { redoMenuTitle(forUndoActionName: redoActionName) }
    public func undoMenuTitle(forUndoActionName name: String) -> String { name.isEmpty ? "Undo" : "Undo \(name)" }
    public func redoMenuTitle(forUndoActionName name: String) -> String { name.isEmpty ? "Redo" : "Redo \(name)" }
    public var undoActionIsDiscardable: Bool { false }
    public var redoActionIsDiscardable: Bool { false }
    public func setActionIsDiscardable(_ discardable: Bool) {}
}
