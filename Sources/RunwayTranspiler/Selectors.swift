// Objective-C selector names for Swift declarations and `#selector`
// expressions, following Swift's own @objc naming:
//   func save()                      "save"
//   func save(_ sender: Any?)        "save:"
//   func open(url: URL)              "openWithUrl:"
//   func tableView(_:didSelect:)     "tableView:didSelect:"
//   var title (getter / setter)      "title" / "setTitle:"

import SwiftSyntax

enum Selectors {
    /// `labels` are argument labels, nil for `_`.
    static func name(base: String, labels: [String?]) -> String {
        guard let first = labels.first else { return base }
        var s = base
        if let f = first, !f.isEmpty { s += "With" + capitalized(f) }
        s += ":"
        for l in labels.dropFirst() { s += (l ?? "") + ":" }
        return s
    }

    static func setter(_ property: String) -> String { "set" + capitalized(property) + ":" }

    static func capitalized(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }

    /// The selector an explicit `@objc(name:)` gives, if any.
    static func explicitName(_ attributes: AttributeListSyntax) -> String? {
        for case .attribute(let a) in attributes where attributeName(a) == "objc" {
            if case .objCName(let pieces) = a.arguments {
                return pieces.trimmedDescription.filter { !$0.isWhitespace }
            }
        }
        return nil
    }

    static func attributeName(_ a: AttributeSyntax) -> String {
        a.attributeName.trimmedDescription
    }

    static func labels(_ params: FunctionParameterListSyntax) -> [String?] {
        params.map { p in p.firstName.tokenKind == .wildcard ? nil : p.firstName.text }
    }

    /// AppKit/Foundation action methods that take a sender, for
    /// `#selector(NSApplication.terminate)` style references whose arity
    /// isn't visible in the package.
    static let senderActions: Set<String> = [
        "terminate", "hide", "hideOtherApplications", "unhideAllApplications", "orderFrontStandardAboutPanel",
        "orderFrontCharacterPalette", "arrangeInFront", "miniaturizeAll", "showHelp", "performClose", "performMiniaturize",
        "performZoom", "toggleFullScreen", "toggleToolbarShown", "runToolbarCustomizationPalette", "toggleSidebar",
        "close", "miniaturize", "deminiaturize", "zoom", "makeKeyAndOrderFront", "orderFront", "orderOut", "orderBack",
        "copy", "cut", "paste", "pasteAsPlainText", "delete", "selectAll", "undo", "redo", "cancelOperation",
        "newDocument", "openDocument", "saveDocument", "saveDocumentAs", "revertDocumentToSaved", "printDocument",
        "runPageLayout", "performFindPanelAction", "performTextFinderAction", "centerSelectionInVisibleArea",
        "toggleContinuousSpellChecking", "checkSpelling", "showGuessPanel", "orderFrontFontPanel", "orderFrontColorPanel",
        "addFontTrait", "modifyFont", "underline", "alignLeft", "alignCenter", "alignRight", "alignJustified",
        "toggleRuler", "startSpeaking", "stopSpeaking", "takeStringValueFrom", "takeIntValueFrom", "takeDoubleValueFrom",
        "performClick", "selectNextKeyView", "selectPreviousKeyView", "clearRecentDocuments", "toggleTabBar",
        "selectNextTab", "selectPreviousTab", "moveTabToNewWindow", "mergeAllWindows", "newWindowForTab",
        "showWindow", "toggle", "toggleSmartInsertDelete", "capitalizeWord", "lowercaseWord", "uppercaseWord",
    ]
}
