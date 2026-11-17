// Pasteboard items, the text finder (Find, Find Next…), printing, and
// attributed strings from HTML.

import Foundation
import CoreGraphics
import RunwayCore

// MARK: Pasteboard items

/// One item's data in several types, written to a pasteboard (a drag's or
/// the clipboard).
@preconcurrency @MainActor
public final class NSPasteboardItem: NSObject, NSPasteboardWriting {
    private var values: [(NSPasteboard.PasteboardType, Any)] = []
    public override init() { super.init() }

    public var types: [NSPasteboard.PasteboardType] { values.map(\.0) }
    public func availableType(from types: [NSPasteboard.PasteboardType]) -> NSPasteboard.PasteboardType? { types.first { self.types.contains($0) } }

    private func set(_ value: Any, _ type: NSPasteboard.PasteboardType) -> Bool {
        values.removeAll { $0.0 == type }
        values.append((type, value))
        return true
    }
    @discardableResult public func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool { set(string, type) }
    @discardableResult public func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool { set(data, type) }
    @discardableResult public func setPropertyList(_ propertyList: Any, forType type: NSPasteboard.PasteboardType) -> Bool { set(propertyList, type) }

    public func string(forType type: NSPasteboard.PasteboardType) -> String? {
        switch values.first(where: { $0.0 == type })?.1 {
        case let s as String: s
        case let d as Data: String(data: d, encoding: .utf8)
        default: nil
        }
    }
    public func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        switch values.first(where: { $0.0 == type })?.1 {
        case let d as Data: d
        case let s as String: Data(s.utf8)
        default: nil
        }
    }
    public func propertyList(forType type: NSPasteboard.PasteboardType) -> Any? { values.first { $0.0 == type }?.1 }
}

// MARK: Text finder

/// The Find commands of a text view's find interface.
@preconcurrency @MainActor
open class NSTextFinder: NSObject {
    public enum Action: Int, Sendable {
        case showFindInterface = 1, nextMatch = 2, previousMatch = 3, replaceAll = 4, replace = 5, replaceAndFind = 6
        case setSearchString = 7, replaceAllInSelection = 8, selectAll = 9, selectAllInSelection = 10, hideFindInterface = 11
        case showReplaceInterface = 12, hideReplaceInterface = 13
    }
    open weak var client: NSTextView?
    open var isIncrementalSearchingEnabled = false
    open var incrementalSearchingShouldDimContentView = true
    public override init() { super.init() }

    /// The search string the Find commands use (the find pasteboard).
    public static var searchString: String {
        get { NSPasteboard(name: .find).string(forType: .string) ?? "" }
        set {
            let p = NSPasteboard(name: .find)
            p.clearContents()
            p.setString(newValue, forType: .string)
        }
    }

    open func validateAction(_ op: Action) -> Bool {
        switch op {
        case .nextMatch, .previousMatch, .selectAll: !Self.searchString.isEmpty
        case .setSearchString: client.map { $0.selectedRange.length > 0 } ?? false
        default: client != nil
        }
    }

    /// Performs a Find command on the client text view.
    open func performAction(_ op: Action) {
        guard let tv = client else { return }
        let text = tv.string as NSString
        switch op {
        case .setSearchString:
            let r = tv.selectedRange
            if r.length > 0 { Self.searchString = text.substring(with: r) }
        case .nextMatch, .previousMatch:
            let needle = Self.searchString
            guard !needle.isEmpty, text.length > 0 else { NSSound.beep(); return }
            let sel = tv.selectedRange
            var found: NSRange
            if op == .nextMatch {
                let start = min(NSMaxRange(sel), text.length)
                found = text.range(of: needle, options: .caseInsensitive, range: NSRange(location: start, length: text.length - start))
                if found.location == NSNotFound { found = text.range(of: needle, options: .caseInsensitive) }
            } else {
                found = text.range(of: needle, options: [.caseInsensitive, .backwards], range: NSRange(location: 0, length: sel.location))
                if found.location == NSNotFound { found = text.range(of: needle, options: [.caseInsensitive, .backwards]) }
            }
            guard found.location != NSNotFound else { NSSound.beep(); return }
            tv.setSelectedRange(found)
            tv.scrollRangeToVisible(found)
            tv.showFindIndicator(for: found)
        default:
            break
        }
    }
    open func cancelFindIndicator() {}
    open func noteClientStringWillChange() {}
}

extension NSTextView {
    /// The text view's Find commands: an NSMenuItem (or control) whose tag
    /// is an `NSTextFinder.Action`.
    func runTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? NSTextFinder.Action.showFindInterface.rawValue
        guard let op = NSTextFinder.Action(rawValue: tag) else { return }
        let finder = NSTextFinder()
        finder.client = self
        finder.performAction(op)
    }
}

// MARK: Printing

/// Page setup for printing: paper, margins, pagination.
@preconcurrency @MainActor
open class NSPrintInfo: NSObject, NSCopying {
    public enum PaginationMode: UInt, Sendable { case automatic = 0, fit = 1, clip = 2 }
    public enum PaperOrientation: Int, Sendable { case portrait = 0, landscape = 1 }
    public struct AttributeKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let jobDisposition = AttributeKey(rawValue: "NSJobDisposition"), jobSavingURL = AttributeKey(rawValue: "NSJobSavingURL")
    }
    public struct JobDisposition: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let spool = JobDisposition(rawValue: "NSPrintSpoolJob"), save = JobDisposition(rawValue: "NSPrintSaveJob")
        public static let preview = JobDisposition(rawValue: "NSPrintPreviewJob"), cancel = JobDisposition(rawValue: "NSPrintCancelJob")
    }

    public static var shared = NSPrintInfo()
    /// US Letter, in points.
    open var paperSize = NSSize(width: 612, height: 792)
    open var leftMargin: CGFloat = 72, rightMargin: CGFloat = 72, topMargin: CGFloat = 90, bottomMargin: CGFloat = 90
    open var horizontalPagination: PaginationMode = .clip
    open var verticalPagination: PaginationMode = .automatic
    open var isHorizontallyCentered = true
    open var isVerticallyCentered = true
    open var orientation: PaperOrientation = .portrait
    open var scalingFactor: CGFloat = 1
    open var jobDisposition: JobDisposition = .spool
    open var dictionary: NSMutableDictionary = [:]
    open var imageablePageBounds: NSRect { NSRect(x: leftMargin, y: bottomMargin, width: paperSize.width - leftMargin - rightMargin, height: paperSize.height - topMargin - bottomMargin) }

    public override init() { super.init() }
    public init(dictionary attributes: [AttributeKey: Any]) { super.init() }
    open func copy(with zone: NSZone? = nil) -> Any {
        let c = NSPrintInfo()
        c.paperSize = paperSize
        c.leftMargin = leftMargin; c.rightMargin = rightMargin; c.topMargin = topMargin; c.bottomMargin = bottomMargin
        c.horizontalPagination = horizontalPagination; c.verticalPagination = verticalPagination
        c.isHorizontallyCentered = isHorizontallyCentered; c.isVerticallyCentered = isVerticallyCentered
        c.orientation = orientation; c.scalingFactor = scalingFactor; c.jobDisposition = jobDisposition
        return c
    }
    open func updateFromPMPrintSettings() {}
}

/// Prints a view. Runway has no print system to hand pages to, so
/// running the operation reports failure (as a cancelled print does).
@preconcurrency @MainActor
open class NSPrintOperation: NSObject {
    public let view: NSView?
    open var printInfo: NSPrintInfo
    open var jobTitle: String?
    open var showsPrintPanel = true
    open var showsProgressPanel = true
    open var canSpawnSeparateThread = false
    public static var current: NSPrintOperation?

    public init(view: NSView, printInfo: NSPrintInfo) {
        self.view = view
        self.printInfo = printInfo
        super.init()
    }
    public convenience init(view: NSView) { self.init(view: view, printInfo: .shared) }
    public static func printOperation(with view: NSView, printInfo: NSPrintInfo) -> NSPrintOperation { NSPrintOperation(view: view, printInfo: printInfo) }
    public static func printOperation(with view: NSView) -> NSPrintOperation { NSPrintOperation(view: view) }

    /// Runs the operation; false: nothing was printed.
    @discardableResult
    open func run() -> Bool { false }
    open func runModal(for docWindow: NSWindow, delegate: Any?, didRun didRunSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        let ok = run()
        if let d = delegate as AnyObject?, let sel = didRunSelector {
            RunwayObjC.perform(d, sel, [self, ok, contextInfo as Any])
        }
    }
}

// MARK: Attributed strings from HTML

extension NSAttributedString {
    public struct DocumentType: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let plain = DocumentType(rawValue: "NSPlainText"), rtf = DocumentType(rawValue: "NSRTF")
        public static let rtfd = DocumentType(rawValue: "NSRTFD"), html = DocumentType(rawValue: "NSHTML")
        public static let docFormat = DocumentType(rawValue: "NSDocFormat"), wordML = DocumentType(rawValue: "NSWordML")
        public static let webArchive = DocumentType(rawValue: "NSWebArchive"), officeOpenXML = DocumentType(rawValue: "NSOfficeOpenXML")
    }
    public struct DocumentReadingOptionKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let documentType = DocumentReadingOptionKey(rawValue: "DocumentType")
        public static let characterEncoding = DocumentReadingOptionKey(rawValue: "CharacterEncoding")
        public static let defaultAttributes = DocumentReadingOptionKey(rawValue: "DefaultAttributes")
        public static let baseURL = DocumentReadingOptionKey(rawValue: "BaseURL")
    }
    public struct DocumentAttributeKey: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let documentType = DocumentAttributeKey(rawValue: "DocumentType")
        public static let characterEncoding = DocumentAttributeKey(rawValue: "CharacterEncoding")
        public static let title = DocumentAttributeKey(rawValue: "NSTitleDocumentAttribute")
    }

    /// Reads HTML: its text with links, headings, list items and paragraph
    /// breaks, with bold, italic, code, underline and strikethrough as fonts
    /// and attributes (style sheets and scripts are skipped).
    public convenience init?(html data: Data, options: [DocumentReadingOptionKey: Any] = [:],
                             documentAttributes dict: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) {
        let encoding = (options[.characterEncoding] as? UInt).map { String.Encoding(rawValue: $0) } ?? .utf8
        guard let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        self.init(attributedString: HTMLReader.read(html))
    }
    public convenience init?(html data: Data, documentAttributes dict: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) {
        self.init(html: data, options: [:], documentAttributes: dict)
    }
    public convenience init(data: Data, options: [DocumentReadingOptionKey: Any] = [:],
                            documentAttributes dict: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) throws {
        let type = options[.documentType] as? DocumentType
        if type == .html || (type == nil && String(data: data.prefix(256), encoding: .utf8)?.lowercased().contains("<html") == true) {
            guard let s = NSAttributedString(html: data, options: options, documentAttributes: dict) else { throw CocoaError(.fileReadCorruptFile) }
            self.init(attributedString: s)
        } else {
            guard let s = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
            self.init(string: s)
        }
    }
}

/// A small HTML reader for NSAttributedString(html:).
enum HTMLReader {
    static func read(_ html: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "")
        var skip = 0
        var links: [String?] = []
        var pendingBreak = false
        var bold = 0, italic = 0, code = 0, underline = 0, strike = 0, heading = 0
        func emit(_ text: String) {
            guard skip == 0, !text.isEmpty else { return }
            if pendingBreak, out.length > 0 { out.append(NSAttributedString(string: "\n")) }
            pendingBreak = false
            // The Mac's defaults: Times 12, headings bold and larger, code in Courier.
            let size: CGFloat = heading > 0 ? [24, 18, 14, 12, 10, 8][heading - 1] : 12
            let spec = FontSpec(size: size, weight: bold > 0 || heading > 0 ? .bold : .regular, design: code > 0 ? .monospaced : .serif,
                                italic: italic > 0)
            var attrs: [NSAttributedString.Key: Any] = [.font: NSFont(spec: spec)]
            if let l = links.last, let href = l, let url = NSURL(string: href) { attrs[.link] = url }
            if underline > 0 { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if strike > 0 { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        var i = html.startIndex
        var text = ""
        func flushText() {
            let collapsed = decode(text).replacingOccurrences(of: "[ \t\r\n]+", with: " ", options: .regularExpression)
            let trimmed = out.length == 0 || out.string.hasSuffix("\n") || pendingBreak ? String(collapsed.drop { $0 == " " }) : collapsed
            emit(trimmed)
            text = ""
        }
        while i < html.endIndex {
            if html[i] == "<", let close = html[i...].firstIndex(of: ">") {
                flushText()
                let tag = html[html.index(after: i)..<close].trimmingCharacters(in: .whitespaces)
                i = html.index(after: close)
                if tag.hasPrefix("!") { continue }
                let closing = tag.hasPrefix("/")
                let body = closing ? String(tag.dropFirst()) : tag
                let name = body.split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "\n" }).first.map { $0.lowercased() } ?? ""
                let d = closing ? -1 : 1
                switch name {
                case "style", "script", "head", "title": skip = max(0, skip + d)
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    pendingBreak = true
                    heading = closing ? 0 : Int(name.dropFirst()) ?? 1
                case "b", "strong": bold = max(0, bold + d)
                case "i", "em", "cite", "var", "dfn": italic = max(0, italic + d)
                case "code", "tt", "kbd", "samp", "pre": code = max(0, code + d)
                case "u", "ins": underline = max(0, underline + d)
                case "s", "strike", "del": strike = max(0, strike + d)
                case "a":
                    if closing { _ = links.popLast() } else { links.append(attribute("href", in: body)) }
                case "br": if !closing { out.append(NSAttributedString(string: "\n")) }
                case "p", "div", "tr", "blockquote", "ul", "ol", "table", "section", "article", "header", "footer", "hr":
                    pendingBreak = true
                case "li":
                    if !closing {
                        pendingBreak = true
                        emit("• ")
                    }
                case "td", "th": if closing { emit("\t") }
                default: break
                }
            } else {
                text.append(html[i])
                i = html.index(after: i)
            }
        }
        flushText()
        return out
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: name + "=") else { return nil }
        var rest = tag[r.upperBound...]
        guard let q = rest.first else { return nil }
        if q == "\"" || q == "'" {
            rest = rest.dropFirst()
            return rest.firstIndex(of: q).map { decode(String(rest[..<$0])) }
        }
        return String(rest.prefix { $0 != " " && $0 != ">" })
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (e, c) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", "\u{00A0}"), ("&mdash;", "—"),
                       ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: e, with: c)
        }
        // Numeric references.
        while let r = out.range(of: "&#[0-9xX]+;", options: .regularExpression) {
            let body = out[r].dropFirst(2).dropLast()
            let v = body.first == "x" || body.first == "X" ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            out.replaceSubrange(r, with: v.flatMap(Unicode.Scalar.init).map { String($0) } ?? "")
        }
        return out
    }
}


// MARK: RTF and paragraph helpers

extension NSAttributedString {
    /// The text of RTF data: control words and groups are dropped, escapes
    /// decoded. Fonts, colours and paragraph styles aren't carried over.
    static func _plainText(fromRTF data: Data) -> String? {
        guard let rtf = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1), rtf.hasPrefix("{\\rtf") else { return nil }
        var out = ""
        var skipDepth: Int?
        var depth = 0
        let chars = Array(rtf.unicodeScalars)
        var i = 0
        let destinations: Set<String> = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "expandedcolortbl", "listtable", "listoverridetable", "generator", "header", "footer"]
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "{": depth += 1; i += 1
            case "}":
                if let s = skipDepth, depth <= s { skipDepth = nil }
                depth -= 1
                i += 1
            case "\\":
                i += 1
                guard i < chars.count else { break }
                let n = chars[i]
                if n == "\\" || n == "{" || n == "}" { if skipDepth == nil { out.unicodeScalars.append(n) }; i += 1; continue }
                if n == "'" {
                    // \'hh: a byte in the document's code page (Latin-1 here).
                    let hex = String(String.UnicodeScalarView(chars[min(i + 1, chars.count)..<min(i + 3, chars.count)]))
                    if skipDepth == nil, let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
                    i += 3
                    continue
                }
                if n == "*" { if skipDepth == nil { skipDepth = depth }; i += 1; continue }
                if n == "\n" || n == "\r" { if skipDepth == nil { out += "\n" }; i += 1; continue }
                var word = ""
                while i < chars.count, CharacterSet.letters.contains(chars[i]) { word.unicodeScalars.append(chars[i]); i += 1 }
                var number = ""
                if i < chars.count, chars[i] == "-" { number = "-"; i += 1 }
                while i < chars.count, CharacterSet.decimalDigits.contains(chars[i]) { number.unicodeScalars.append(chars[i]); i += 1 }
                if i < chars.count, chars[i] == " " { i += 1 }
                if destinations.contains(word), skipDepth == nil { skipDepth = depth }
                guard skipDepth == nil else { continue }
                switch word {
                case "par", "line": out += "\n"
                case "tab": out += "\t"
                case "u":
                    if let v = Int(number), let u = Unicode.Scalar(UInt32(v < 0 ? v + 65536 : v)) { out.unicodeScalars.append(u) }
                    // The fallback character that follows.
                    if i < chars.count, chars[i] != "\\", chars[i] != "{", chars[i] != "}" { i += 1 }
                default: break
                }
            case "\n", "\r": i += 1
            default:
                if skipDepth == nil { out.unicodeScalars.append(c) }
                i += 1
            }
        }
        return out
    }

    public convenience init?(rtf data: Data, documentAttributes dict: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) {
        guard let text = NSAttributedString._plainText(fromRTF: data) else { return nil }
        self.init(string: text)
    }
    public convenience init?(rtfd data: Data, documentAttributes dict: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) {
        self.init(rtf: data, documentAttributes: dict)
    }
    public convenience init?(docFormat data: Data, documentAttributes dict: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) { return nil }
}

extension NSMutableAttributedString {
    private func updateParagraphStyle(in range: NSRange, _ change: (NSMutableParagraphStyle) -> Void) {
        guard range.length > 0 else { return }
        enumerateAttribute(.paragraphStyle, in: range, options: []) { value, r, _ in
            let style = ((value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            change(style)
            addAttribute(.paragraphStyle, value: style, range: r)
        }
    }
    public func setAlignment(_ alignment: NSTextAlignment, range: NSRange) { updateParagraphStyle(in: range) { $0.alignment = alignment } }
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, range: NSRange) { updateParagraphStyle(in: range) { $0.baseWritingDirection = writingDirection } }
    public func superscriptRange(_ range: NSRange) { addAttribute(.superscript, value: 1, range: range) }
    public func subscriptRange(_ range: NSRange) { addAttribute(.superscript, value: -1, range: range) }
    public func unscriptRange(_ range: NSRange) { removeAttribute(.superscript, range: range) }
    public func applyFontTraits(_ traitMask: NSFontTraitMask, range: NSRange) {
        enumerateAttribute(.font, in: range, options: []) { value, r, _ in
            guard let font = value as? NSFont else { return }
            addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: traitMask), range: r)
        }
    }
    public func fixAttributes(in range: NSRange) {}
}


// MARK: Text input clients

/// What a view that takes text from input methods implements. NSTextView does.
@preconcurrency @MainActor public protocol NSTextInputClient: AnyObject {
    func insertText(_ string: Any, replacementRange: NSRange)
    func doCommand(by selector: Selector)
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange)
    func unmarkText()
    func selectedRange() -> NSRange
    func markedRange() -> NSRange
    func hasMarkedText() -> Bool
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString?
    func validAttributesForMarkedText() -> [NSAttributedString.Key]
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect
    func characterIndex(for point: NSPoint) -> Int
}

extension NSTextInputClient {
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    public func doCommand(by selector: Selector) {}
    public func attributedString() -> NSAttributedString { NSAttributedString() }
    public func fractionOfDistanceThroughGlyph(for point: NSPoint) -> CGFloat { 0 }
    public func baselineDeltaForCharacter(at index: Int) -> CGFloat { 0 }
    public func windowLevel() -> Int { 0 }
    public func drawsVerticallyForCharacter(at charIndex: Int) -> Bool { false }
}

extension NSTextView: NSTextInputClient {
    /// A text view on TextKit 2 (`usingTextLayoutManager: true`) or TextKit 1:
    /// the same view here.
    public convenience init(usingTextLayoutManager: Bool) { self.init(frame: .zero) }
}

/// The input context of a view: input methods are the toolkit's, so this
/// only answers and forwards.
@preconcurrency @MainActor open class NSTextInputContext: NSObject {
    public static var current: NSTextInputContext? { nil }
    public let client: any NSTextInputClient
    public init(client: any NSTextInputClient) { self.client = client; super.init() }
    open var acceptsGlyphInfo = false
    open var allowedInputSourceLocales: [String]?
    open var keyboardInputSources: [String]? { nil }
    open var selectedKeyboardInputSource: String?
    open func activate() {}
    open func deactivate() {}
    open func handleEvent(_ event: NSEvent) -> Bool { false }
    open func discardMarkedText() {}
    open func invalidateCharacterCoordinates() {}
    open func textInputClientWillStartScrollingOrZooming() {}
    open func textInputClientDidEndScrollingOrZooming() {}
    public static let keyboardSelectionDidChangeNotification = Notification.Name("NSTextInputContextKeyboardSelectionDidChangeNotification")
}

extension NSView {
    /// The view's input context (none: input methods compose in the toolkit's widgets).
    public var inputContext: NSTextInputContext? { nil }
}

// The pre-Swift 4.2 spellings of UndoManager's notifications.
extension Notification.Name {
    public static let NSUndoManagerCheckpoint = UndoManager.checkpointNotification
    public static let NSUndoManagerWillUndoChange = UndoManager.willUndoChangeNotification
    public static let NSUndoManagerWillRedoChange = UndoManager.willRedoChangeNotification
    public static let NSUndoManagerDidUndoChange = UndoManager.didUndoChangeNotification
    public static let NSUndoManagerDidRedoChange = UndoManager.didRedoChangeNotification
    public static let NSUndoManagerDidOpenUndoGroup = UndoManager.didOpenUndoGroupNotification
    public static let NSUndoManagerWillCloseUndoGroup = UndoManager.willCloseUndoGroupNotification
    public static let NSUndoManagerDidCloseUndoGroup = UndoManager.didCloseUndoGroupNotification
}


// MARK: AppKit's AttributedString attributes

extension AttributeScopes {
    /// `attributedString.foregroundColor = NSColor…`: AppKit's attributes on AttributedString.
    public struct AppKitAttributes: AttributeScope {
        public let font: FontAttribute
        public let paragraphStyle: ParagraphStyleAttribute
        public let foregroundColor: ForegroundColorAttribute
        public let backgroundColor: BackgroundColorAttribute
        public let ligature: LigatureAttribute
        public let kern: KernAttribute
        public let tracking: TrackingAttribute
        public let strikethroughStyle: StrikethroughStyleAttribute
        public let underlineStyle: UnderlineStyleAttribute
        public let strokeColor: StrokeColorAttribute
        public let strokeWidth: StrokeWidthAttribute
        public let shadow: ShadowAttribute
        public let baselineOffset: BaselineOffsetAttribute
        public let underlineColor: UnderlineColorAttribute
        public let strikethroughColor: StrikethroughColorAttribute
        public let obliqueness: ObliquenessAttribute
        public let expansion: ExpansionAttribute
        public let cursor: CursorAttribute
        public let toolTip: ToolTipAttribute
        public let superscript: SuperscriptAttribute
        public let foundation: AttributeScopes.FoundationAttributes

        public enum FontAttribute: AttributedStringKey { public typealias Value = NSFont; public static let name = "NSFont" }
        public enum ParagraphStyleAttribute: AttributedStringKey { public typealias Value = NSParagraphStyle; public static let name = "NSParagraphStyle" }
        public enum ForegroundColorAttribute: AttributedStringKey { public typealias Value = NSColor; public static let name = "NSColor" }
        public enum BackgroundColorAttribute: AttributedStringKey { public typealias Value = NSColor; public static let name = "NSBackgroundColor" }
        public enum LigatureAttribute: AttributedStringKey { public typealias Value = Int; public static let name = "NSLigature" }
        public enum KernAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "NSKern" }
        public enum TrackingAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "NSTracking" }
        public enum StrikethroughStyleAttribute: AttributedStringKey { public typealias Value = NSUnderlineStyle; public static let name = "NSStrikethrough" }
        public enum UnderlineStyleAttribute: AttributedStringKey { public typealias Value = NSUnderlineStyle; public static let name = "NSUnderline" }
        public enum StrokeColorAttribute: AttributedStringKey { public typealias Value = NSColor; public static let name = "NSStrokeColor" }
        public enum StrokeWidthAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "NSStrokeWidth" }
        public enum ShadowAttribute: AttributedStringKey { public typealias Value = NSShadow; public static let name = "NSShadow" }
        public enum BaselineOffsetAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "NSBaselineOffset" }
        public enum UnderlineColorAttribute: AttributedStringKey { public typealias Value = NSColor; public static let name = "NSUnderlineColor" }
        public enum StrikethroughColorAttribute: AttributedStringKey { public typealias Value = NSColor; public static let name = "NSStrikethroughColor" }
        public enum ObliquenessAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "NSObliqueness" }
        public enum ExpansionAttribute: AttributedStringKey { public typealias Value = CGFloat; public static let name = "NSExpansion" }
        public enum CursorAttribute: AttributedStringKey { public typealias Value = NSCursor; public static let name = "NSCursor" }
        public enum ToolTipAttribute: AttributedStringKey { public typealias Value = String; public static let name = "NSToolTip" }
        public enum SuperscriptAttribute: AttributedStringKey { public typealias Value = Int; public static let name = "NSSuperScript" }
    }
    public var appKit: AppKitAttributes.Type { AppKitAttributes.self }
}

extension AttributeDynamicLookup {
    /// Disfavoured: where SwiftUI's attribute of the same name fits too (`.foregroundColor = .black`), SwiftUI's is meant.
    @_disfavoredOverload
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.AppKitAttributes, T>) -> T { self[T.self] }
}
