// NSResponder and target/action.
//
// Event messages (mouseDown(with:), keyDown(with:)…) are ordinary
// overridable methods; NSResponder's defaults pass them to `nextResponder`,
// as AppKit's do. Action messages (selectors) go through RunwayObjC:
// `NSApp.sendAction(_:to:from:)` → `RunwayObjC.sendAction`, which asks each
// candidate's generated dispatch table (app classes; the transpiler writes
// them) and then AppKit's registered selectors (`AppKitRuntime`). AppKit
// classes never adopt `SelectorDispatching` themselves, so app subclasses
// can. AppKit fills in `ObjCRuntime.responderChain` for nil-targeted
// actions.

import Foundation
import RunwayCore
import RunwayObjC

@preconcurrency @MainActor
open class NSResponder: NSObject {
    public override init() {
        super.init()
    }
    public required init?(coder: NSCoder) { super.init() }
    /// Sent after nib loading has connected every object (InterfaceBuilder/).
    open func awakeFromNib() {}
    open func prepareForInterfaceBuilder() {}

    private weak var _nextResponder: NSResponder?
    /// The next responder: views pass to their view controller or
    /// superview, a content view to its window.
    open var nextResponder: NSResponder? {
        get { _nextResponder }
        set { _nextResponder = newValue }
    }
    var explicitNextResponder: NSResponder? { _nextResponder }

    open var acceptsFirstResponder: Bool { false }
    open func becomeFirstResponder() -> Bool { true }
    open func resignFirstResponder() -> Bool { true }
    open func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
    open var menu: NSMenu?
    open var undoManager: UndoManager? { nextResponder?.undoManager }

    // MARK: Event messages (passed along the chain by default)

    open func mouseDown(with event: NSEvent) { nextResponder?.mouseDown(with: event) }
    open func mouseDragged(with event: NSEvent) { nextResponder?.mouseDragged(with: event) }
    open func mouseUp(with event: NSEvent) { nextResponder?.mouseUp(with: event) }
    open func rightMouseDown(with event: NSEvent) { nextResponder?.rightMouseDown(with: event) }
    open func rightMouseDragged(with event: NSEvent) { nextResponder?.rightMouseDragged(with: event) }
    open func rightMouseUp(with event: NSEvent) { nextResponder?.rightMouseUp(with: event) }
    open func otherMouseDown(with event: NSEvent) { nextResponder?.otherMouseDown(with: event) }
    open func otherMouseDragged(with event: NSEvent) { nextResponder?.otherMouseDragged(with: event) }
    open func otherMouseUp(with event: NSEvent) { nextResponder?.otherMouseUp(with: event) }
    open func mouseMoved(with event: NSEvent) { nextResponder?.mouseMoved(with: event) }
    open func mouseEntered(with event: NSEvent) { nextResponder?.mouseEntered(with: event) }
    open func mouseExited(with event: NSEvent) { nextResponder?.mouseExited(with: event) }
    open func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    open func cursorUpdate(with event: NSEvent) { nextResponder?.cursorUpdate(with: event) }
    open func magnify(with event: NSEvent) { nextResponder?.magnify(with: event) }
    open func rotate(with event: NSEvent) { nextResponder?.rotate(with: event) }
    open func swipe(with event: NSEvent) { nextResponder?.swipe(with: event) }
    open func smartMagnify(with event: NSEvent) { nextResponder?.smartMagnify(with: event) }
    open func pressureChange(with event: NSEvent) { nextResponder?.pressureChange(with: event) }
    open func beginGesture(with event: NSEvent) { nextResponder?.beginGesture(with: event) }
    open func endGesture(with event: NSEvent) { nextResponder?.endGesture(with: event) }
    open func tabletPoint(with event: NSEvent) { nextResponder?.tabletPoint(with: event) }

    open func keyDown(with event: NSEvent) {
        if let n = nextResponder { n.keyDown(with: event) } else { noResponder(for: Selector("keyDown:")) }
    }
    open func keyUp(with event: NSEvent) {
        if let n = nextResponder { n.keyUp(with: event) } else { noResponder(for: Selector("keyUp:")) }
    }
    open func flagsChanged(with event: NSEvent) { nextResponder?.flagsChanged(with: event) }

    /// The end of the chain for an event no one handled.
    open func noResponder(for eventSelector: Selector) {
        if eventSelector.name == "keyDown:" { KeyDispatch.unhandled = true }
    }

    /// Key equivalents (⌘-keys) before the key goes to the first responder.
    open func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    open func performMnemonic(_ string: String) -> Bool { false }

    // MARK: Actions

    /// Sends `action` to self or the first responder after it that handles it.
    open func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        var r: NSResponder? = self
        var seen = Set<ObjectIdentifier>()
        while let cur = r, seen.insert(ObjectIdentifier(cur)).inserted {
            if RunwayObjC.responds(cur, to: action) {
                var m = Message(.perform(action, [object]))
                return RunwayObjC.handle(cur, &m)
            }
            r = cur.nextResponder
        }
        return false
    }

    open func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? { nil }
    open func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        nextResponder?.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // MARK: Text input

    /// Turns key events into `insertText(_:)` and command selectors
    /// (`moveLeft:`, `insertNewline:`…) as the Mac's standard key bindings do.
    open func interpretKeyEvents(_ events: [NSEvent]) {
        for e in events where e.type == .keyDown {
            if let sel = KeyBindings.selector(for: e) { doCommand(by: sel) } else if let chars = e.characters, !chars.isEmpty, !e.modifierFlags.contains(.command) {
                insertText(chars)
            }
        }
    }
    open func insertText(_ insertString: Any) { nextResponder?.insertText(insertString) }
    /// Sends a command selector along the chain from self.
    open func doCommand(by selector: Selector) {
        if !tryToPerform(selector, with: nil) { nextResponder?.doCommand(by: selector) }
    }
    open func flushBufferedKeyEvents() {}

    // Standard key-binding actions (NSStandardKeyBindingResponding). Each
    // passes to the next responder unless overridden.
    open func moveUp(_ sender: Any?) { nextResponder?.moveUp(sender) }
    open func moveDown(_ sender: Any?) { nextResponder?.moveDown(sender) }
    open func moveLeft(_ sender: Any?) { nextResponder?.moveLeft(sender) }
    open func moveRight(_ sender: Any?) { nextResponder?.moveRight(sender) }
    open func moveForward(_ sender: Any?) { nextResponder?.moveForward(sender) }
    open func moveBackward(_ sender: Any?) { nextResponder?.moveBackward(sender) }
    open func moveWordLeft(_ sender: Any?) { nextResponder?.moveWordLeft(sender) }
    open func moveWordRight(_ sender: Any?) { nextResponder?.moveWordRight(sender) }
    open func moveWordForward(_ sender: Any?) { nextResponder?.moveWordForward(sender) }
    open func moveWordBackward(_ sender: Any?) { nextResponder?.moveWordBackward(sender) }
    open func moveToBeginningOfLine(_ sender: Any?) { nextResponder?.moveToBeginningOfLine(sender) }
    open func moveToEndOfLine(_ sender: Any?) { nextResponder?.moveToEndOfLine(sender) }
    open func moveToBeginningOfParagraph(_ sender: Any?) { nextResponder?.moveToBeginningOfParagraph(sender) }
    open func moveToEndOfParagraph(_ sender: Any?) { nextResponder?.moveToEndOfParagraph(sender) }
    open func moveToBeginningOfDocument(_ sender: Any?) { nextResponder?.moveToBeginningOfDocument(sender) }
    open func moveToEndOfDocument(_ sender: Any?) { nextResponder?.moveToEndOfDocument(sender) }
    open func moveUpAndModifySelection(_ sender: Any?) { nextResponder?.moveUpAndModifySelection(sender) }
    open func moveDownAndModifySelection(_ sender: Any?) { nextResponder?.moveDownAndModifySelection(sender) }
    open func moveLeftAndModifySelection(_ sender: Any?) { nextResponder?.moveLeftAndModifySelection(sender) }
    open func moveRightAndModifySelection(_ sender: Any?) { nextResponder?.moveRightAndModifySelection(sender) }
    open func moveWordLeftAndModifySelection(_ sender: Any?) { nextResponder?.moveWordLeftAndModifySelection(sender) }
    open func moveWordRightAndModifySelection(_ sender: Any?) { nextResponder?.moveWordRightAndModifySelection(sender) }
    open func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { nextResponder?.moveToBeginningOfLineAndModifySelection(sender) }
    open func moveToEndOfLineAndModifySelection(_ sender: Any?) { nextResponder?.moveToEndOfLineAndModifySelection(sender) }
    open func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { nextResponder?.moveToBeginningOfDocumentAndModifySelection(sender) }
    open func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { nextResponder?.moveToEndOfDocumentAndModifySelection(sender) }
    open func pageUp(_ sender: Any?) { nextResponder?.pageUp(sender) }
    open func pageDown(_ sender: Any?) { nextResponder?.pageDown(sender) }
    open func scrollPageUp(_ sender: Any?) { nextResponder?.scrollPageUp(sender) }
    open func scrollPageDown(_ sender: Any?) { nextResponder?.scrollPageDown(sender) }
    open func scrollLineUp(_ sender: Any?) { nextResponder?.scrollLineUp(sender) }
    open func scrollLineDown(_ sender: Any?) { nextResponder?.scrollLineDown(sender) }
    open func scrollToBeginningOfDocument(_ sender: Any?) { nextResponder?.scrollToBeginningOfDocument(sender) }
    open func scrollToEndOfDocument(_ sender: Any?) { nextResponder?.scrollToEndOfDocument(sender) }
    open func insertNewline(_ sender: Any?) { nextResponder?.insertNewline(sender) }
    open func insertLineBreak(_ sender: Any?) { nextResponder?.insertLineBreak(sender) }
    open func insertTab(_ sender: Any?) { nextResponder?.insertTab(sender) }
    open func insertBacktab(_ sender: Any?) { nextResponder?.insertBacktab(sender) }
    open func deleteBackward(_ sender: Any?) { nextResponder?.deleteBackward(sender) }
    open func deleteForward(_ sender: Any?) { nextResponder?.deleteForward(sender) }
    open func deleteWordBackward(_ sender: Any?) { nextResponder?.deleteWordBackward(sender) }
    open func deleteWordForward(_ sender: Any?) { nextResponder?.deleteWordForward(sender) }
    open func deleteToBeginningOfLine(_ sender: Any?) { nextResponder?.deleteToBeginningOfLine(sender) }
    open func deleteToEndOfLine(_ sender: Any?) { nextResponder?.deleteToEndOfLine(sender) }
    open func cancelOperation(_ sender: Any?) { nextResponder?.cancelOperation(sender) }
    open func complete(_ sender: Any?) { nextResponder?.complete(sender) }
    open func transpose(_ sender: Any?) { nextResponder?.transpose(sender) }
    open func capitalizeWord(_ sender: Any?) { nextResponder?.capitalizeWord(sender) }
    open func uppercaseWord(_ sender: Any?) { nextResponder?.uppercaseWord(sender) }
    open func lowercaseWord(_ sender: Any?) { nextResponder?.lowercaseWord(sender) }
    open func moveForwardAndModifySelection(_ sender: Any?) { nextResponder?.moveForwardAndModifySelection(sender) }
    open func moveBackwardAndModifySelection(_ sender: Any?) { nextResponder?.moveBackwardAndModifySelection(sender) }
    open func moveWordForwardAndModifySelection(_ sender: Any?) { nextResponder?.moveWordForwardAndModifySelection(sender) }
    open func moveWordBackwardAndModifySelection(_ sender: Any?) { nextResponder?.moveWordBackwardAndModifySelection(sender) }
    open func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) { nextResponder?.moveToBeginningOfParagraphAndModifySelection(sender) }
    open func moveToEndOfParagraphAndModifySelection(_ sender: Any?) { nextResponder?.moveToEndOfParagraphAndModifySelection(sender) }
    open func moveParagraphForwardAndModifySelection(_ sender: Any?) { nextResponder?.moveParagraphForwardAndModifySelection(sender) }
    open func moveParagraphBackwardAndModifySelection(_ sender: Any?) { nextResponder?.moveParagraphBackwardAndModifySelection(sender) }
    open func moveToLeftEndOfLine(_ sender: Any?) { nextResponder?.moveToLeftEndOfLine(sender) }
    open func moveToRightEndOfLine(_ sender: Any?) { nextResponder?.moveToRightEndOfLine(sender) }
    open func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { nextResponder?.moveToLeftEndOfLineAndModifySelection(sender) }
    open func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { nextResponder?.moveToRightEndOfLineAndModifySelection(sender) }
    open func pageUpAndModifySelection(_ sender: Any?) { nextResponder?.pageUpAndModifySelection(sender) }
    open func pageDownAndModifySelection(_ sender: Any?) { nextResponder?.pageDownAndModifySelection(sender) }
    open func centerSelectionInVisibleArea(_ sender: Any?) { nextResponder?.centerSelectionInVisibleArea(sender) }
    open func insertParagraphSeparator(_ sender: Any?) { nextResponder?.insertParagraphSeparator(sender) }
    open func insertTabIgnoringFieldEditor(_ sender: Any?) { nextResponder?.insertTabIgnoringFieldEditor(sender) }
    open func insertNewlineIgnoringFieldEditor(_ sender: Any?) { nextResponder?.insertNewlineIgnoringFieldEditor(sender) }
    open func insertContainerBreak(_ sender: Any?) { nextResponder?.insertContainerBreak(sender) }
    open func insertSingleQuoteIgnoringSubstitution(_ sender: Any?) { nextResponder?.insertSingleQuoteIgnoringSubstitution(sender) }
    open func insertDoubleQuoteIgnoringSubstitution(_ sender: Any?) { nextResponder?.insertDoubleQuoteIgnoringSubstitution(sender) }
    open func changeCaseOfLetter(_ sender: Any?) { nextResponder?.changeCaseOfLetter(sender) }
    open func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) { nextResponder?.deleteBackwardByDecomposingPreviousCharacter(sender) }
    open func deleteToBeginningOfParagraph(_ sender: Any?) { nextResponder?.deleteToBeginningOfParagraph(sender) }
    open func deleteToEndOfParagraph(_ sender: Any?) { nextResponder?.deleteToEndOfParagraph(sender) }
    open func yank(_ sender: Any?) { nextResponder?.yank(sender) }
    open func indent(_ sender: Any?) { nextResponder?.indent(sender) }
    open func selectAll(_ sender: Any?) { nextResponder?.selectAll(sender) }
    open func selectParagraph(_ sender: Any?) { nextResponder?.selectParagraph(sender) }
    open func selectLine(_ sender: Any?) { nextResponder?.selectLine(sender) }
    open func selectWord(_ sender: Any?) { nextResponder?.selectWord(sender) }
    open func setMark(_ sender: Any?) { nextResponder?.setMark(sender) }
    open func deleteToMark(_ sender: Any?) { nextResponder?.deleteToMark(sender) }
    open func selectToMark(_ sender: Any?) { nextResponder?.selectToMark(sender) }
    open func swapWithMark(_ sender: Any?) { nextResponder?.swapWithMark(sender) }
    open func quickLookPreviewItems(_ sender: Any?) { nextResponder?.quickLookPreviewItems(sender) }
    /// Find commands (NSTextFinder actions, by the sender's tag).
    open func performTextFinderAction(_ sender: Any?) { nextResponder?.performTextFinderAction(sender) }

    open func presentError(_ error: Error) -> Bool {
        let a = NSAlert()
        a.messageText = error.localizedDescription
        _ = a.runModal()
        return true
    }
    open func willPresentError(_ error: Error) -> Error { error }
}

// MARK: Apple event handlers by selector

extension NSAppleEventManager {
    /// Registers `handler` to receive the app's own events of a class and
    /// ID, as `handleEvent:withReplyEvent:`-style selectors.
    public func setEventHandler(_ handler: Any, andSelector handleEventSelector: Selector, forEventClass eventClass: AEEventClass,
                                andEventID eventID: AEEventID) {
        let target = handler as AnyObject
        _setEventHandler(forEventClass: eventClass, andEventID: eventID) { [weak target] event, reply in
            guard let target else { return }
            RunwayObjC.perform(target, handleEventSelector, [event, reply])
        }
    }
}

// MARK: Undo by selector

extension UndoManager {
    /// Registers `selector`, sent to `target` with `object`, as the undo action.
    public func registerUndo(withTarget target: Any, selector: Selector, object: Any?) {
        _registerUndo(withTarget: target as AnyObject) { RunwayObjC.perform($0, selector, [object]) }
    }
}

// MARK: Validation

/// Menu item validation (`validateMenuItem(_:)`). App classes implement it
/// as an ordinary method; AppKit calls it through RunwayObjC
/// (`"validateMenuItem:"`), so it needn't be declared on AppKit's classes.
@preconcurrency @MainActor public protocol NSMenuItemValidation: AnyObject {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool
}

public protocol NSValidatedUserInterfaceItem: AnyObject {
    var action: Selector? { get }
    var tag: Int { get }
}

@preconcurrency @MainActor public protocol NSUserInterfaceValidations: AnyObject {
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool
}

enum Validation {
    /// Whether `target` enables `item`: `validateMenuItem:` (protocol or
    /// dispatch table), else `validateUserInterfaceItem:`, else yes.
    @MainActor static func validate(_ item: NSMenuItem, with target: AnyObject) -> Bool {
        if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) }
        if RunwayObjC.responds(target, to: Selector("validateMenuItem:")) {
            return (RunwayObjC.perform(target, Selector("validateMenuItem:"), [item]) as? Bool) ?? true
        }
        if let v = target as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
        if RunwayObjC.responds(target, to: Selector("validateUserInterfaceItem:")) {
            return (RunwayObjC.perform(target, Selector("validateUserInterfaceItem:"), [item]) as? Bool) ?? true
        }
        return AppKitRuntime.validateBuiltIn(item, target)
    }
}

// MARK: The runtime glue

@MainActor enum AppKitRuntime {
    private static var installed = false

    /// Registers AppKit's own action methods with RunwayObjC and the
    /// responder chain for nil-targeted actions. Idempotent.
    static func install() {
        guard !installed else { return }
        installed = true
        ObjCRuntime.responderChain = { sender in
            MainActor.assumeIsolated { actionChain(for: sender) }
        }
        func reg<T: AnyObject>(_ name: String, _ type: T.Type, _ f: @escaping @MainActor (T, Any?) -> Any?) {
            registerSelector(Selector(name), for: type) { obj, args in
                MainActor.assumeIsolated { f(obj as! T, args.first ?? nil) }
            }
        }
        // NSApplication.
        reg("terminate:", NSApplication.self) { $0.terminate($1); return nil }
        reg("hide:", NSApplication.self) { $0.hide($1); return nil }
        reg("unhide:", NSApplication.self) { $0.unhide($1); return nil }
        reg("hideOtherApplications:", NSApplication.self) { $0.hideOtherApplications($1); return nil }
        reg("unhideAllApplications:", NSApplication.self) { $0.unhideAllApplications($1); return nil }
        reg("orderFrontStandardAboutPanel:", NSApplication.self) { $0.orderFrontStandardAboutPanel($1); return nil }
        reg("arrangeInFront:", NSApplication.self) { $0.arrangeInFront($1); return nil }
        reg("miniaturizeAll:", NSApplication.self) { $0.miniaturizeAll($1); return nil }
        reg("showHelp:", NSApplication.self) { $0.showHelp($1); return nil }
        // NSWindow.
        reg("performClose:", NSWindow.self) { $0.performClose($1); return nil }
        reg("performMiniaturize:", NSWindow.self) { $0.performMiniaturize($1); return nil }
        reg("miniaturize:", NSWindow.self) { $0.miniaturize($1); return nil }
        reg("performZoom:", NSWindow.self) { $0.performZoom($1); return nil }
        reg("zoom:", NSWindow.self) { $0.zoom($1); return nil }
        reg("toggleFullScreen:", NSWindow.self) { $0.toggleFullScreen($1); return nil }
        reg("makeKeyAndOrderFront:", NSWindow.self) { $0.makeKeyAndOrderFront($1); return nil }
        reg("orderFront:", NSWindow.self) { $0.orderFront($1); return nil }
        reg("orderOut:", NSWindow.self) { $0.orderOut($1); return nil }
        reg("selectNextKeyView:", NSWindow.self) { $0.selectNextKeyView($1); return nil }
        reg("selectPreviousKeyView:", NSWindow.self) { $0.selectPreviousKeyView($1); return nil }
        reg("toggleToolbarShown:", NSWindow.self) { $0.toggleToolbarShown($1); return nil }
        reg("undo:", NSWindow.self) { w, _ in w.undoManager?.undo(); return nil }
        reg("redo:", NSWindow.self) { w, _ in w.undoManager?.redo(); return nil }
        // Controllers.
        reg("showWindow:", NSWindowController.self) { $0.showWindow($1); return nil }
        reg("dismissController:", NSWindowController.self) { $0.dismissController($1); return nil }
        reg("dismissController:", NSViewController.self) { $0.dismiss($1); return nil }
        // Standard key bindings on every responder (overrides run).
        let bindings: [(String, @MainActor (NSResponder, Any?) -> Void)] = [
            ("moveUp:", { $0.moveUp($1) }), ("moveDown:", { $0.moveDown($1) }), ("moveLeft:", { $0.moveLeft($1) }), ("moveRight:", { $0.moveRight($1) }),
            ("moveForward:", { $0.moveForward($1) }), ("moveBackward:", { $0.moveBackward($1) }),
            ("moveWordLeft:", { $0.moveWordLeft($1) }), ("moveWordRight:", { $0.moveWordRight($1) }),
            ("moveWordForward:", { $0.moveWordForward($1) }), ("moveWordBackward:", { $0.moveWordBackward($1) }),
            ("moveToBeginningOfLine:", { $0.moveToBeginningOfLine($1) }), ("moveToEndOfLine:", { $0.moveToEndOfLine($1) }),
            ("moveToBeginningOfParagraph:", { $0.moveToBeginningOfParagraph($1) }), ("moveToEndOfParagraph:", { $0.moveToEndOfParagraph($1) }),
            ("moveToBeginningOfDocument:", { $0.moveToBeginningOfDocument($1) }), ("moveToEndOfDocument:", { $0.moveToEndOfDocument($1) }),
            ("moveUpAndModifySelection:", { $0.moveUpAndModifySelection($1) }), ("moveDownAndModifySelection:", { $0.moveDownAndModifySelection($1) }),
            ("moveLeftAndModifySelection:", { $0.moveLeftAndModifySelection($1) }), ("moveRightAndModifySelection:", { $0.moveRightAndModifySelection($1) }),
            ("moveWordLeftAndModifySelection:", { $0.moveWordLeftAndModifySelection($1) }), ("moveWordRightAndModifySelection:", { $0.moveWordRightAndModifySelection($1) }),
            ("moveToBeginningOfLineAndModifySelection:", { $0.moveToBeginningOfLineAndModifySelection($1) }),
            ("moveToEndOfLineAndModifySelection:", { $0.moveToEndOfLineAndModifySelection($1) }),
            ("moveToBeginningOfDocumentAndModifySelection:", { $0.moveToBeginningOfDocumentAndModifySelection($1) }),
            ("moveToEndOfDocumentAndModifySelection:", { $0.moveToEndOfDocumentAndModifySelection($1) }),
            ("pageUp:", { $0.pageUp($1) }), ("pageDown:", { $0.pageDown($1) }),
            ("scrollPageUp:", { $0.scrollPageUp($1) }), ("scrollPageDown:", { $0.scrollPageDown($1) }),
            ("scrollLineUp:", { $0.scrollLineUp($1) }), ("scrollLineDown:", { $0.scrollLineDown($1) }),
            ("scrollToBeginningOfDocument:", { $0.scrollToBeginningOfDocument($1) }), ("scrollToEndOfDocument:", { $0.scrollToEndOfDocument($1) }),
            ("insertNewline:", { $0.insertNewline($1) }), ("insertLineBreak:", { $0.insertLineBreak($1) }),
            ("insertTab:", { $0.insertTab($1) }), ("insertBacktab:", { $0.insertBacktab($1) }),
            ("deleteBackward:", { $0.deleteBackward($1) }), ("deleteForward:", { $0.deleteForward($1) }),
            ("deleteWordBackward:", { $0.deleteWordBackward($1) }), ("deleteWordForward:", { $0.deleteWordForward($1) }),
            ("deleteToBeginningOfLine:", { $0.deleteToBeginningOfLine($1) }), ("deleteToEndOfLine:", { $0.deleteToEndOfLine($1) }),
            ("cancelOperation:", { $0.cancelOperation($1) }), ("complete:", { $0.complete($1) }), ("transpose:", { $0.transpose($1) }),
            ("capitalizeWord:", { $0.capitalizeWord($1) }), ("uppercaseWord:", { $0.uppercaseWord($1) }), ("lowercaseWord:", { $0.lowercaseWord($1) }),
        ]
        for (name, f) in bindings { reg(name, NSResponder.self) { f($0, $1); return nil } }
    }

    /// Built-in validation for AppKit's own actions.
    static func validateBuiltIn(_ item: NSMenuItem, _ target: AnyObject) -> Bool {
        // Toggle Sidebar / Inspector: enabled when there's such a pane.
        if let svc = target as? NSSplitViewController, let a = item.action?.name, a == "toggleSidebar:" || a == "toggleInspector:" {
            let behavior: NSSplitViewItem.Behavior = a == "toggleSidebar:" ? .sidebar : .inspector
            guard let pane = svc.splitViewItems.first(where: { $0.behavior == behavior }) else { return false }
            let noun = behavior == .sidebar ? "Sidebar" : "Inspector"
            item.title = pane.isCollapsed ? "Show \(noun)" : "Hide \(noun)"
            return true
        }
        if let w = target as? NSWindow, let a = item.action?.name {
            switch a {
            case "performClose:": return w.styleMask.contains(.closable)
            case "performMiniaturize:": return w.styleMask.contains(.miniaturizable)
            case "performZoom:": return w.styleMask.contains(.resizable)
            case "undo:":
                guard let u = w.undoManager else { return false }
                item.title = u.undoMenuItemTitle
                return u.canUndo
            case "redo:":
                guard let u = w.undoManager else { return false }
                item.title = u.redoMenuItemTitle
                return u.canRedo
            case "toggleFullScreen:": item.title = w.styleMask.contains(.fullScreen) ? "Exit Full Screen" : "Enter Full Screen"; return true
            default: break
            }
        }
        return true
    }

    /// The responder chain for nil-targeted actions.
    static func actionChain(for sender: Any?) -> [AnyObject] {
        var out: [AnyObject] = []
        var seen = Set<ObjectIdentifier>()
        func add(_ o: AnyObject?) {
            guard let o, seen.insert(ObjectIdentifier(o)).inserted else { return }
            out.append(o)
        }
        func walk(_ w: NSWindow) {
            var r: NSResponder? = w.firstResponder ?? w
            var guardCount = 0
            while let cur = r, guardCount < 512 {
                add(cur)
                if cur === w { break }
                r = cur.nextResponder ?? (cur is NSView ? w : nil)
                guardCount += 1
            }
            add(w)
            var n = w.nextResponder
            while let cur = n, seen.insert(ObjectIdentifier(cur)).inserted { out.append(cur); n = cur.nextResponder }
            add(w.delegate)
            add(w.windowController)
            if let doc = w.windowController?.document { add(doc as AnyObject) }
        }
        let app = NSApplication.shared
        if let k = app.keyWindow { walk(k) }
        if let m = app.mainWindow, m !== app.keyWindow { walk(m) }
        add(app)
        add(app.delegate)
        return out
    }
}

// MARK: Standard key bindings

enum KeyBindings {
    /// The command a key event maps to, as the Mac's StandardKeyBinding.dict.
    @MainActor static func selector(for e: NSEvent) -> Selector? {
        let f = e.modifierFlags.intersection([.shift, .option, .control, .command])
        let shift = f.contains(.shift), alt = f.contains(.option), cmd = f.contains(.command)
        guard let c = e.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let name: String?
        switch Int(c.value) {
        case NSUpArrowFunctionKey: name = cmd ? (shift ? "moveToBeginningOfDocumentAndModifySelection:" : "moveToBeginningOfDocument:") : (shift ? "moveUpAndModifySelection:" : "moveUp:")
        case NSDownArrowFunctionKey: name = cmd ? (shift ? "moveToEndOfDocumentAndModifySelection:" : "moveToEndOfDocument:") : (shift ? "moveDownAndModifySelection:" : "moveDown:")
        case NSLeftArrowFunctionKey:
            name = cmd ? (shift ? "moveToBeginningOfLineAndModifySelection:" : "moveToBeginningOfLine:")
                : alt ? (shift ? "moveWordLeftAndModifySelection:" : "moveWordLeft:") : (shift ? "moveLeftAndModifySelection:" : "moveLeft:")
        case NSRightArrowFunctionKey:
            name = cmd ? (shift ? "moveToEndOfLineAndModifySelection:" : "moveToEndOfLine:")
                : alt ? (shift ? "moveWordRightAndModifySelection:" : "moveWordRight:") : (shift ? "moveRightAndModifySelection:" : "moveRight:")
        // Home and End as Linux and Windows keyboards use them (the Mac's
        // scroll the document; its line keys are ⌘← and ⌘→): the line's
        // start and end, the document's with Ctrl (⌘ here).
        case NSHomeFunctionKey:
            name = cmd ? (shift ? "moveToBeginningOfDocumentAndModifySelection:" : "moveToBeginningOfDocument:")
                : (shift ? "moveToBeginningOfLineAndModifySelection:" : "moveToBeginningOfLine:")
        case NSEndFunctionKey:
            name = cmd ? (shift ? "moveToEndOfDocumentAndModifySelection:" : "moveToEndOfDocument:")
                : (shift ? "moveToEndOfLineAndModifySelection:" : "moveToEndOfLine:")
        case NSPageUpFunctionKey: name = "scrollPageUp:"
        case NSPageDownFunctionKey: name = "scrollPageDown:"
        case NSDeleteFunctionKey: name = alt ? "deleteWordForward:" : "deleteForward:"
        case 0x7f, 0x08: name = cmd ? "deleteToBeginningOfLine:" : alt ? "deleteWordBackward:" : "deleteBackward:"
        case 0x0d, 0x03: name = alt ? "insertNewlineIgnoringFieldEditor:" : "insertNewline:"
        case 0x09: name = shift ? "insertBacktab:" : alt ? "insertTabIgnoringFieldEditor:" : "insertTab:"
        case 0x19: name = "insertBacktab:"
        case 0x1b: name = "cancelOperation:"
        default: name = nil
        }
        return name.map { Selector($0) }
    }
}
