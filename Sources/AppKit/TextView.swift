// NSTextView on the platform's text view (GtkTextView): its text lives in
// an NSTextStorage (an NSMutableAttributedString) whose fonts, colours,
// underlines and paragraph styles become text tags, laid out with the
// NSLayoutManager delegate's glyphs (null glyphs hidden, control glyphs as
// spacers) and paragraph spacing, and drawn with the layout manager's
// drawBackground under the text. Editing is AppKit's: keys come through
// the responder chain (keyDown → interpretKeyEvents → doCommand(by:) →
// insertNewline:, deleteBackward:, moveLeft:…), typed text through the
// toolkit's input method into insertText(_:replacementRange:), and every
// change through shouldChangeText / the storage / didChangeText, with
// undo registered on the undo manager; the view only shows the result.

import Foundation
import CoreGraphics
import RunwayCore
import RunwayFoundation

// MARK: Attributes

extension NSAttributedString.Key {
}

public final class NSTextTab: NSObject, @unchecked Sendable {
    public enum TabType: UInt, Sendable { case leftTabStopType, rightTabStopType, centerTabStopType, decimalTabStopType }
    public typealias OptionKey = String
    public let location: CGFloat
    public let alignment: NSTextAlignment
    public init(textAlignment: NSTextAlignment, location: CGFloat, options: [OptionKey: Any] = [:]) { alignment = textAlignment; self.location = location }
    public init(type: TabType, location: CGFloat) { alignment = type == .rightTabStopType ? .right : type == .centerTabStopType ? .center : .left; self.location = location }
}

extension NSParagraphStyle {
    /// The paragraph as the backend's spec.
    var spec: ParagraphSpec {
        var s = ParagraphSpec()
        s.alignment = alignment.value
        s.justified = alignment == .justified
        s.lineSpacing = lineSpacing
        s.lineHeightMultiple = lineHeightMultiple
        s.minimumLineHeight = minimumLineHeight
        s.maximumLineHeight = maximumLineHeight
        s.paragraphSpacing = paragraphSpacing
        s.paragraphSpacingBefore = paragraphSpacingBefore
        s.firstLineHeadIndent = firstLineHeadIndent
        s.headIndent = headIndent
        s.tailIndent = tailIndent
        return s
    }
}

extension NSAttributedString {
    /// The string's runs with every attribute a text view shows.
    func richRuns(defaultFont: FontSpec, defaultColor: RGBA?) -> [RichTextRun] {
        var out: [RichTextRun] = []
        let ns = string as NSString
        let full = NSRange(location: 0, length: length)
        guard full.length > 0 else { return [] }
        enumerateAttributes(in: full, options: []) { attrs, range, _ in
            var run = RichTextRun(string: ns.substring(with: range), font: (attrs[.font] as? NSFont)?.spec ?? defaultFont,
                                  color: (attrs[.foregroundColor] as? NSColor)?.rgbaValue ?? defaultColor)
            run.background = (attrs[.backgroundColor] as? NSColor)?.rgbaValue
            run.underline = Self.intValue(attrs[.underlineStyle]) != 0
            run.strikethrough = Self.intValue(attrs[.strikethroughStyle]) != 0
            run.baselineOffset = CGFloat(Self.doubleValue(attrs[.baselineOffset]))
            run.kern = CGFloat(Self.doubleValue(attrs[.kern]))
            if let l = attrs[.link] { run.link = (l as? URL)?.absoluteString ?? "\(l)" }
            if run.link != nil, attrs[.foregroundColor] == nil { run.color = NSColor.linkColor.rgbaValue; run.underline = true }
            run.paragraph = (attrs[.paragraphStyle] as? NSParagraphStyle)?.spec
            out.append(run)
        }
        return out
    }

    static func intValue(_ v: Any?) -> Int {
        switch v {
        case let i as Int: i
        case let n as NSNumber: n.intValue
        case let u as NSUnderlineStyle: u.rawValue
        default: 0
        }
    }
    static func doubleValue(_ v: Any?) -> Double {
        switch v {
        case let d as Double: d
        case let c as CGFloat: Double(c)
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        default: 0
        }
    }
}

// MARK: Text storage

public struct NSTextStorageEditActions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let editedAttributes = NSTextStorageEditActions(rawValue: 1)
    public static let editedCharacters = NSTextStorageEditActions(rawValue: 2)
}

extension NSTextStorage {
    public typealias EditActions = NSTextStorageEditActions
}

public protocol NSTextStorageDelegate: AnyObject {
    func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int)
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int)
}
extension NSTextStorageDelegate {
    public func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {}
    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {}
}

/// The text a text view shows. Every mutation is noted; when the outermost
/// edit ends the storage processes it (delegate, then the text views).
///
/// It keeps its own runs rather than Core Foundation's: swift-corelibs'
/// CFAttributedString halts comparing neighbouring runs whose values are
/// distinct app objects (two NSFonts), which text views make all the time.
open class NSTextStorage: NSMutableAttributedString, @unchecked Sendable {
    open weak var delegate: NSTextStorageDelegate?
    open private(set) var layoutManagers: [NSLayoutManager] = []
    open private(set) var editedMask: NSTextStorageEditActions = []
    open private(set) var editedRange = NSRange(location: NSNotFound, length: 0)
    open private(set) var changeInLength = 0
    open var fixesAttributesLazily: Bool { false }
    private var depth = 0
    /// Text views showing this storage resync through this (with the
    /// round's edited mask, range and change in length).
    var observers: [(AnyObject?, (NSTextStorageEditActions, NSRange, Int) -> Void)] = []

    private struct Run { var length: Int; var attrs: [NSAttributedString.Key: Any] }
    private let text = NSMutableString(string: "")
    private var runs: [Run] = []

    public static let willProcessEditingNotification = Notification.Name("NSTextStorageWillProcessEditingNotification")
    public static let didProcessEditingNotification = Notification.Name("NSTextStorageDidProcessEditingNotification")

    public convenience init() { self.init(string: "") }
    public override init(string: String) {
        super.init(string: "")
        place(string, [:], at: 0)
    }
    public override init(string: String, attributes: [NSAttributedString.Key: Any]? = nil) {
        super.init(string: "")
        place(string, attributes ?? [:], at: 0)
    }
    public override init(attributedString: NSAttributedString) {
        super.init(string: "")
        insertRuns(of: attributedString, at: 0)
    }
    public required init?(coder: NSCoder) { fatalError("NSCoder isn't supported") }

    open func addLayoutManager(_ lm: NSLayoutManager) { layoutManagers.append(lm); MainActor.assumeIsolated { lm.textStorage = self } }
    open func removeLayoutManager(_ lm: NSLayoutManager) { layoutManagers.removeAll { $0 === lm } }

    // MARK: Reading

    open override var string: String { text as String }
    open override var length: Int { text.length }
    open override var mutableString: NSMutableString { text }

    /// The run holding `loc`, with its range.
    private func run(at loc: Int) -> (Int, NSRange)? {
        var start = 0
        for (i, r) in runs.enumerated() {
            if loc < start + r.length { return (i, NSRange(location: start, length: r.length)) }
            start += r.length
        }
        return nil
    }

    open override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        guard let (i, r) = run(at: location) else { range?.pointee = NSRange(location: location, length: 0); return [:] }
        range?.pointee = r
        return runs[i].attrs
    }
    open override func attribute(_ name: NSAttributedString.Key, at location: Int, effectiveRange range: NSRangePointer?) -> Any? {
        attributes(at: location, effectiveRange: range)[name]
    }
    /// The runs around `location` (within `limit`) whose attributes `same` says match it.
    private func longest(at location: Int, in limit: NSRange, _ same: ([NSAttributedString.Key: Any], [NSAttributedString.Key: Any]) -> Bool) -> NSRange {
        guard let (i, r) = run(at: location) else { return NSRange(location: location, length: 0) }
        var lo = r.location, hi = NSMaxRange(r)
        var j = i - 1
        while j >= 0, lo > limit.location, same(runs[j].attrs, runs[i].attrs) { lo -= runs[j].length; j -= 1 }
        j = i + 1
        while j < runs.count, hi < NSMaxRange(limit), same(runs[j].attrs, runs[i].attrs) { hi += runs[j].length; j += 1 }
        return NSIntersectionRange(NSRange(location: lo, length: hi - lo), limit)
    }
    open override func attributes(at location: Int, longestEffectiveRange range: NSRangePointer?, in rangeLimit: NSRange) -> [NSAttributedString.Key: Any] {
        let a = attributes(at: location, effectiveRange: nil)
        range?.pointee = longest(at: location, in: rangeLimit) { x, y in
            x.count == y.count && x.allSatisfy { k, v in NSTextStorage.same(v, y[k]) }
        }
        return a
    }
    open override func attribute(_ name: NSAttributedString.Key, at location: Int, longestEffectiveRange range: NSRangePointer?, in rangeLimit: NSRange) -> Any? {
        let v = attributes(at: location, effectiveRange: nil)[name]
        range?.pointee = longest(at: location, in: rangeLimit) { x, y in NSTextStorage.same(x[name], y[name]) }
        return v
    }
    /// Whether two attribute values are equal (as `isEqual(_:)` says for objects).
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (x as NSObject, y as NSObject): return x.isEqual(y)
        case let (x as AnyHashable, y as AnyHashable): return x == y
        default: return (a as AnyObject) === (b as AnyObject)
        }
    }

    open override func enumerateAttributes(in enumerationRange: NSRange, options opts: NSAttributedString.EnumerationOptions = [],
                                           using block: ([NSAttributedString.Key: Any], NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var pieces: [([NSAttributedString.Key: Any], NSRange)] = []
        var start = 0
        for r in runs {
            let rr = NSIntersectionRange(NSRange(location: start, length: r.length), enumerationRange)
            if rr.length > 0 { pieces.append((r.attrs, rr)) }
            start += r.length
        }
        if opts.contains(.reverse) { pieces.reverse() }
        var stop: ObjCBool = false
        for (a, r) in pieces {
            block(a, r, &stop)
            if stop.boolValue { break }
        }
    }
    open override func enumerateAttribute(_ name: NSAttributedString.Key, in enumerationRange: NSRange, options opts: NSAttributedString.EnumerationOptions = [],
                                          using block: (Any?, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        // Runs whose value is the same are one range, as AppKit gives the
        // longest effective range unless told it needn't.
        var pieces: [(Any?, NSRange)] = []
        enumerateAttributes(in: enumerationRange, options: []) { a, r, _ in
            if !opts.contains(.longestEffectiveRangeNotRequired), let last = pieces.last, NSMaxRange(last.1) == r.location, Self.same(last.0, a[name]) {
                pieces[pieces.count - 1].1.length += r.length
            } else {
                pieces.append((a[name], r))
            }
        }
        if opts.contains(.reverse) { pieces.reverse() }
        var stop: ObjCBool = false
        for (v, r) in pieces {
            block(v, r, &stop)
            if stop.boolValue { break }
        }
    }

    open override func attributedSubstring(from range: NSRange) -> NSAttributedString {
        let out = NSTextStorage()
        enumerateAttributes(in: range) { a, r, _ in out.place(self.text.substring(with: r), a, at: out.length) }
        return out
    }

    open override func isEqual(to other: NSAttributedString) -> Bool { other.string == string }

    // MARK: Primitive edits (no notifications)

    /// Inserts `s` with `attrs` at `loc`.
    private func place(_ s: String, _ attrs: [NSAttributedString.Key: Any], at loc: Int) {
        let n = (s as NSString).length
        guard n > 0 else { return }
        text.insert(s, at: loc)
        splitRun(at: loc)
        var start = 0, i = 0
        while i < runs.count, start < loc { start += runs[i].length; i += 1 }
        runs.insert(Run(length: n, attrs: attrs), at: i)
    }

    /// Splits the run containing `loc` so a run starts there.
    private func splitRun(at loc: Int) {
        guard let (i, r) = run(at: loc), r.location != loc else { return }
        let head = loc - r.location
        let tail = runs[i].length - head
        runs[i].length = head
        runs.insert(Run(length: tail, attrs: runs[i].attrs), at: i + 1)
    }

    private func remove(_ range: NSRange) {
        guard range.length > 0 else { return }
        text.deleteCharacters(in: range)
        splitRun(at: range.location)
        splitRun(at: NSMaxRange(range))
        var start = 0, kept: [Run] = []
        for r in runs {
            let inRange = start >= range.location && start + r.length <= NSMaxRange(range)
            if !inRange { kept.append(r) }
            start += r.length
        }
        runs = kept
    }

    private func insertRuns(of a: NSAttributedString, at loc: Int) {
        var at = loc
        let ns = a.string as NSString
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length), options: []) { attrs, r, _ in
            place(ns.substring(with: r), attrs, at: at)
            at += r.length
        }
    }

    /// Applies `change` to each run's attributes inside `range`.
    private func modify(_ range: NSRange, _ change: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard range.length > 0 else { return }
        splitRun(at: range.location)
        splitRun(at: NSMaxRange(range))
        var start = 0
        for i in runs.indices {
            if start >= range.location, start + runs[i].length <= NSMaxRange(range) { change(&runs[i].attrs) }
            start += runs[i].length
        }
    }

    // MARK: Editing

    open func edited(_ mask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        editedMask.formUnion(mask)
        let newRange = NSRange(location: range.location, length: range.length + delta)
        editedRange = editedRange.location == NSNotFound ? newRange : NSUnionRange(editedRange, newRange)
        changeInLength += delta
        // Changes the delegate makes while editing is processed (attribute
        // fixes in didProcessEditing) join this round, as in AppKit, rather
        // than starting another.
        if depth == 0, !isProcessingEditing { processEditing() }
    }
    private var isProcessingEditing = false

    open func processEditing() {
        isProcessingEditing = true
        defer { isProcessingEditing = false }
        delegate?.textStorage(self, willProcessEditing: editedMask, range: editedRange, changeInLength: changeInLength)
        NotificationCenter.default.post(name: Self.willProcessEditingNotification, object: self)
        delegate?.textStorage(self, didProcessEditing: editedMask, range: editedRange, changeInLength: changeInLength)
        NotificationCenter.default.post(name: Self.didProcessEditingNotification, object: self)
        // What the delegate changed while processing joined this round.
        let (mask, range, delta) = (editedMask, editedRange, changeInLength)
        editedMask = []
        editedRange = NSRange(location: NSNotFound, length: 0)
        changeInLength = 0
        observers.removeAll { $0.0 == nil }
        for o in observers { o.1(mask, range, delta) }
    }

    open override func beginEditing() { depth += 1 }
    open override func endEditing() {
        depth = max(0, depth - 1)
        if depth == 0, !isProcessingEditing, !editedMask.isEmpty { processEditing() }
    }

    private func batch(_ mask: NSTextStorageEditActions, _ range: NSRange, _ delta: Int, _ work: () -> Void) {
        depth += 1
        work()
        depth -= 1
        edited(mask, range: range, changeInLength: delta)
    }

    open override func replaceCharacters(in range: NSRange, with str: String) {
        let delta = (str as NSString).length - range.length
        // New text takes the attributes of the text it replaces (or precedes it).
        let attrs = length == 0 ? [:] : attributes(at: max(0, min(range.location > 0 && range.length == 0 ? range.location - 1 : range.location, length - 1)), effectiveRange: nil)
        batch([.editedCharacters, .editedAttributes], range, delta) {
            remove(range)
            place(str, attrs, at: range.location)
        }
    }
    open override func replaceCharacters(in range: NSRange, with attrString: NSAttributedString) {
        let delta = attrString.length - range.length
        batch([.editedCharacters, .editedAttributes], range, delta) {
            remove(range)
            insertRuns(of: attrString, at: range.location)
        }
    }
    open override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        batch(.editedAttributes, range, 0) { modify(range) { $0 = attrs ?? [:] } }
    }
    open override func addAttribute(_ name: NSAttributedString.Key, value: Any, range: NSRange) {
        batch(.editedAttributes, range, 0) { modify(range) { $0[name] = value } }
    }
    open override func addAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange) {
        batch(.editedAttributes, range, 0) { modify(range) { for (k, v) in attrs { $0[k] = v } } }
    }
    open override func removeAttribute(_ name: NSAttributedString.Key, range: NSRange) {
        batch(.editedAttributes, range, 0) { modify(range) { $0[name] = nil } }
    }
    open override func insert(_ attrString: NSAttributedString, at loc: Int) {
        batch([.editedCharacters, .editedAttributes], NSRange(location: loc, length: 0), attrString.length) { insertRuns(of: attrString, at: loc) }
    }
    open override func append(_ attrString: NSAttributedString) {
        let loc = length
        batch([.editedCharacters, .editedAttributes], NSRange(location: loc, length: 0), attrString.length) { insertRuns(of: attrString, at: loc) }
    }
    open override func deleteCharacters(in range: NSRange) {
        batch(.editedCharacters, range, -range.length) { remove(range) }
    }
    open override func setAttributedString(_ attrString: NSAttributedString) {
        let old = length
        batch([.editedCharacters, .editedAttributes], NSRange(location: 0, length: old), attrString.length - old) {
            remove(NSRange(location: 0, length: old))
            insertRuns(of: attrString, at: 0)
        }
    }

    /// Paragraph ranges, for code that walks paragraphs.
    open var paragraphs: [NSAttributedString] {
        var out: [NSAttributedString] = []
        var loc = 0
        while loc < text.length {
            let r = text.paragraphRange(for: NSRange(location: loc, length: 0))
            out.append(attributedSubstring(from: r))
            loc = NSMaxRange(r)
        }
        return out
    }
}

/// A glyph: here one per UTF-16 unit of the text (the toolkit shapes text itself).
public typealias CGGlyph = UInt16

@preconcurrency @MainActor public protocol NSLayoutManagerDelegate: AnyObject {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction
    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect
    func layoutManager(_ layoutManager: NSLayoutManager, lineSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: NSRect) -> CGFloat
    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingBeforeGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: NSRect) -> CGFloat
    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: NSRect) -> CGFloat
    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool)
    func layoutManagerDidInvalidateLayout(_ sender: NSLayoutManager)
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any] , forDrawingToScreen toScreen: Bool,
                       atCharacterIndex charIndex: Int, effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any]?
}

/// What the delegate methods a delegate doesn't implement return, so the
/// layout manager can tell "not implemented" (use the paragraph style) from
/// an answer of 0.
let unimplementedSpacing = -CGFloat.greatestFiniteMagnitude

extension NSLayoutManagerDelegate {
    public func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                              characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int { 0 }
    public func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction, forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction { action }
    public func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                              proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: unimplementedSpacing, height: 0)
    }
    public func layoutManager(_ layoutManager: NSLayoutManager, lineSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: NSRect) -> CGFloat { unimplementedSpacing }
    public func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingBeforeGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: NSRect) -> CGFloat { unimplementedSpacing }
    public func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int, withProposedLineFragmentRect rect: NSRect) -> CGFloat { unimplementedSpacing }
    public func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {}
    public func layoutManagerDidInvalidateLayout(_ sender: NSLayoutManager) {}
    public func layoutManager(_ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any], forDrawingToScreen toScreen: Bool,
                              atCharacterIndex charIndex: Int, effectiveRange effectiveCharRange: NSRangePointer?) -> [NSAttributedString.Key: Any]? { attrs }
}

/// TextKit 1's layout manager over the toolkit's own layout. Glyphs are the
/// text's UTF-16 units; their properties come from the delegate as in
/// AppKit (`shouldGenerateGlyphs`: null glyphs are laid out as nothing,
/// control glyphs as the delegate says, whitespace of a chosen width
/// included), and so does paragraph spacing. Geometry (line fragments,
/// glyph locations, bounding rects, hit testing) is the text view's layout.
/// `drawBackground` and `drawGlyphs` run when the text view draws, under
/// the toolkit's text: an override's drawing shows there.
open class NSLayoutManager: NSObject {
    public struct GlyphProperty: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let null = GlyphProperty(rawValue: 1), controlCharacter = GlyphProperty(rawValue: 2)
        public static let elastic = GlyphProperty(rawValue: 4), nonBaseCharacter = GlyphProperty(rawValue: 8)
    }
    public struct ControlCharacterAction: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let zeroAdvancement = ControlCharacterAction(rawValue: 1), whitespace = ControlCharacterAction(rawValue: 2)
        public static let horizontalTab = ControlCharacterAction(rawValue: 4), lineBreak = ControlCharacterAction(rawValue: 8)
        public static let paragraphBreak = ControlCharacterAction(rawValue: 16), containerBreak = ControlCharacterAction(rawValue: 32)
    }

    open weak var textStorage: NSTextStorage?
    open private(set) var textContainers: [NSTextContainer] = []
    open var allowsNonContiguousLayout = false
    open var hasNonContiguousLayout: Bool { false }
    open var showsInvisibleCharacters = false
    open var showsControlCharacters = false
    open var usesFontLeading = true
    open var limitsLayoutForSuspiciousContents = false
    open var backgroundLayoutEnabled = true
    open weak var delegate: NSLayoutManagerDelegate?
    weak var textView: NSTextView?
    public override init() { super.init() }

    open func addTextContainer(_ c: NSTextContainer) { textContainers.append(c); c.layoutManager = self }
    open func insertTextContainer(_ c: NSTextContainer, at i: Int) { textContainers.insert(c, at: i); c.layoutManager = self }
    open func removeTextContainer(at i: Int) { textContainers.remove(at: i) }
    open func replaceTextStorage(_ s: NSTextStorage) { s.addLayoutManager(self) }
    open func ensureLayout(for container: NSTextContainer) {}
    open func ensureLayout(forCharacterRange range: NSRange) {}
    open func ensureLayout(forGlyphRange range: NSRange) {}
    open func ensureLayout(forBoundingRect rect: NSRect, in container: NSTextContainer) {}

    // MARK: Invalidation (the text view shows the range again)

    open func invalidateLayout(forCharacterRange r: NSRange, actualCharacterRange: UnsafeMutablePointer<NSRange>?) {
        actualCharacterRange?.pointee = r
        onMainThread {
            textView?.refreshText(in: r)
            delegate?.layoutManagerDidInvalidateLayout(self)
        }
    }
    open func invalidateGlyphs(forCharacterRange r: NSRange, changeInLength delta: Int, actualCharacterRange: UnsafeMutablePointer<NSRange>?) {
        actualCharacterRange?.pointee = r
        onMainThread { textView?.refreshText(in: r) }
    }
    open func invalidateDisplay(forCharacterRange r: NSRange) { onMainThread { textView?.needsDisplay = true } }
    open func invalidateDisplay(forGlyphRange r: NSRange) { invalidateDisplay(forCharacterRange: r) }
    open func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions, range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {}

    // MARK: Glyphs

    /// Each glyph's properties (one glyph per UTF-16 unit).
    private var properties: [GlyphProperty] = []
    /// Control glyphs laid out as whitespace of a width of their own.
    private var spacerWidths: [Int: CGFloat] = [:]
    /// The glyphs `setGlyphs` was given while the delegate generated a range.
    private var generated: [Int: GlyphProperty]?

    /// The text changed: `old` characters became `newLength` (properties
    /// outside keep theirs).
    func textReplaced(_ old: NSRange, newLength: Int) {
        let lo = min(old.location, properties.count), hi = min(NSMaxRange(old), properties.count)
        properties.replaceSubrange(lo..<hi, with: repeatElement([], count: newLength))
        let delta = newLength - old.length
        if !spacerWidths.isEmpty {
            var moved: [Int: CGFloat] = [:]
            for (i, w) in spacerWidths where i < old.location || i >= NSMaxRange(old) { moved[i >= NSMaxRange(old) ? i + delta : i] = w }
            spacerWidths = moved
        }
    }

    /// Generates the glyphs of a range, asking the delegate as TextKit does,
    /// a run of one font at a time.
    @MainActor func generateGlyphs(in range: NSRange) {
        guard let ts = textStorage else { return }
        let length = ts.length
        if properties.count != length { properties = Array(repeating: [], count: length); spacerWidths = [:] }
        let r = NSIntersectionRange(range, NSRange(location: 0, length: length))
        guard r.length > 0 else { return }
        let s = ts.mutableString
        for i in r.location..<NSMaxRange(r) { spacerWidths[i] = nil }
        var runs: [(NSRange, NSFont)] = []
        ts.enumerateAttribute(.font, in: r, options: []) { value, sub, _ in runs.append((sub, value as? NSFont ?? .systemFont(ofSize: 12))) }
        for (sub, font) in runs {
            var glyphs = [CGGlyph](repeating: 0, count: sub.length)
            var props = [GlyphProperty](repeating: [], count: sub.length)
            var indexes = [Int](repeating: 0, count: sub.length)
            for k in 0..<sub.length {
                let ci = sub.location + k
                let c = s.character(at: ci)
                glyphs[k] = c
                indexes[k] = ci
                if Self.isControl(c) { props[k] = .controlCharacter }
            }
            generated = [:]
            let taken = glyphs.withUnsafeBufferPointer { g in
                props.withUnsafeBufferPointer { p in
                    indexes.withUnsafeBufferPointer { ix in
                        delegate?.layoutManager(self, shouldGenerateGlyphs: g.baseAddress!, properties: p.baseAddress!, characterIndexes: ix.baseAddress!,
                                                font: font, forGlyphRange: sub) ?? 0
                    }
                }
            }
            let set = generated ?? [:]
            generated = nil
            for k in 0..<sub.length {
                let ci = sub.location + k
                properties[ci] = taken > 0 ? set[ci] ?? props[k] : props[k]
            }
        }
        // Control characters: the delegate's action, and a width for whitespace.
        let container = textContainers.first
        for ci in r.location..<NSMaxRange(r) where properties[ci].contains(.controlCharacter) {
            let c = s.character(at: ci)
            let natural: ControlCharacterAction = c == 10 || c == 13 || c == 0x2029 ? .paragraphBreak : c == 0x2028 ? .lineBreak : c == 9 ? .horizontalTab
                : c == 12 ? .containerBreak : .zeroAdvancement
            let action = delegate?.layoutManager(self, shouldUse: natural, forControlCharacterAt: ci) ?? natural
            if action.contains(.whitespace), let container {
                let box = delegate?.layoutManager(self, boundingBoxForControlGlyphAt: ci, for: container,
                                                   proposedLineFragment: NSRect(x: 0, y: 0, width: container.size.width, height: 0),
                                                   glyphPosition: .zero, characterIndex: ci)
                if let w = box?.width, w != unimplementedSpacing { spacerWidths[ci] = max(0, w) }
            } else if action == .zeroAdvancement, natural != .zeroAdvancement {
                properties[ci].insert(.null)
            }
        }
    }

    static func isControl(_ c: UInt16) -> Bool { c < 32 || c == 0x7f || c == 0x2028 || c == 0x2029 || (0x200b...0x200f).contains(c) || c == 0xfeff }

    /// Whether a glyph is laid out as nothing, and a control glyph's width as whitespace.
    func isHidden(_ i: Int) -> Bool { i < properties.count && properties[i].contains(.null) }
    func spacerWidth(_ i: Int) -> CGFloat? { spacerWidths[i] }

    open var numberOfGlyphs: Int { textStorage?.length ?? 0 }
    open func glyphRange(for container: NSTextContainer) -> NSRange { NSRange(location: 0, length: numberOfGlyphs) }
    open func characterRange(forGlyphRange r: NSRange, actualGlyphRange: UnsafeMutablePointer<NSRange>?) -> NSRange { actualGlyphRange?.pointee = r; return r }
    open func glyphRange(forCharacterRange r: NSRange, actualCharacterRange: UnsafeMutablePointer<NSRange>?) -> NSRange { actualCharacterRange?.pointee = r; return r }
    open func glyphIndexForCharacter(at i: Int) -> Int { i }
    open func characterIndexForGlyph(at i: Int) -> Int { i }
    open func glyph(at i: Int) -> CGGlyph { CGGlyph(truncatingIfNeeded: (textStorage?.string as NSString?)?.character(at: i) ?? 0) }
    open func glyph(at i: Int, isValidIndex: UnsafeMutablePointer<ObjCBool>?) -> CGGlyph {
        isValidIndex?.pointee = ObjCBool(isValidGlyphIndex(i))
        return isValidGlyphIndex(i) ? glyph(at: i) : 0
    }
    open func cgGlyph(at i: Int) -> CGGlyph { glyph(at: i) }
    open func isValidGlyphIndex(_ i: Int) -> Bool { i >= 0 && i < numberOfGlyphs }
    open func propertyForGlyph(at i: Int) -> GlyphProperty {
        if properties.count != numberOfGlyphs { onMainThread { generateGlyphs(in: NSRange(location: 0, length: numberOfGlyphs)) } }
        return i >= 0 && i < properties.count ? properties[i] : []
    }
    /// Called by the delegate from `shouldGenerateGlyphs` with the glyphs it wants.
    open func setGlyphs(_ glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<GlyphProperty>, characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) {
        for k in 0..<glyphRange.length {
            let ci = charIndexes[k]
            if generated != nil { generated?[ci] = props[k] } else if ci < properties.count { properties[ci] = props[k] }
        }
    }
    open func textContainer(forGlyphAt i: Int, effectiveRange: UnsafeMutablePointer<NSRange>?) -> NSTextContainer? {
        effectiveRange?.pointee = NSRange(location: 0, length: numberOfGlyphs)
        return textContainers.first
    }
    open func textContainer(forGlyphAt i: Int, effectiveRange: UnsafeMutablePointer<NSRange>?, withoutAdditionalLayout: Bool) -> NSTextContainer? {
        textContainer(forGlyphAt: i, effectiveRange: effectiveRange)
    }

    // MARK: Geometry, from the view (in the container's coordinates)

    private var containerOrigin: CGPoint { onMainThread { textView?.textContainerOrigin ?? .zero } }
    private var containerWidth: CGFloat { textContainers.first?.size.width ?? onMainThread { textView?.bounds.width ?? 0 } }

    /// Where a glyph is laid out, in the view.
    private func layout(_ i: Int) -> TextCharacterLayout? {
        onMainThread {
            guard let tv = textView, numberOfGlyphs > 0 else { return nil }
            return tv.characterLayout(at: max(0, min(i, numberOfGlyphs)))
        }
    }

    @preconcurrency @MainActor open func usedRect(for container: NSTextContainer) -> CGRect {
        guard let tv = textView else { return .zero }
        let o = tv.textContainerOrigin
        return CGRect(x: 0, y: 0, width: container.size.width, height: max(0, tv.textHeight - o.y - tv.textContainerInset.height))
    }
    /// The rect around a range's glyphs, in the container's coordinates.
    open func boundingRect(forGlyphRange r: NSRange, in container: NSTextContainer) -> NSRect {
        guard numberOfGlyphs > 0, let a = layout(min(r.location, numberOfGlyphs - 1)) else { return .zero }
        var u = a.rect
        if r.length > 1, let b = layout(min(NSMaxRange(r) - 1, numberOfGlyphs - 1)) {
            if b.rect.minY > a.rect.maxY - 1 {
                // More than one line: the full width of the lines.
                let o = containerOrigin
                u = CGRect(x: o.x, y: a.rect.minY, width: containerWidth, height: b.rect.maxY - a.rect.minY)
            } else {
                u = u.union(b.rect)
            }
        }
        let o = containerOrigin
        return u.offsetBy(dx: -o.x, dy: -o.y)
    }
    open func lineFragmentRect(forGlyphAt i: Int, effectiveRange: UnsafeMutablePointer<NSRange>?) -> NSRect {
        guard let l = layout(i) else { effectiveRange?.pointee = NSRange(location: 0, length: 0); return .zero }
        if let effectiveRange { effectiveRange.pointee = lineGlyphRange(at: i, top: l.rect.minY) }
        return CGRect(x: 0, y: l.lineTop - containerOrigin.y, width: containerWidth, height: l.lineBottom - l.lineTop)
    }
    open func lineFragmentRect(forGlyphAt i: Int, effectiveRange: UnsafeMutablePointer<NSRange>?, withoutAdditionalLayout: Bool) -> NSRect {
        lineFragmentRect(forGlyphAt: i, effectiveRange: effectiveRange)
    }
    open func lineFragmentUsedRect(forGlyphAt i: Int, effectiveRange: UnsafeMutablePointer<NSRange>?) -> NSRect {
        lineFragmentRect(forGlyphAt: i, effectiveRange: effectiveRange)
    }
    open func lineFragmentUsedRect(forGlyphAt i: Int, effectiveRange: UnsafeMutablePointer<NSRange>?, withoutAdditionalLayout: Bool) -> NSRect {
        lineFragmentUsedRect(forGlyphAt: i, effectiveRange: effectiveRange)
    }
    /// A glyph's location: x in the container, y its baseline from its line fragment's top.
    open func location(forGlyphAt i: Int) -> NSPoint {
        guard let l = layout(i) else { return .zero }
        return CGPoint(x: l.rect.minX - containerOrigin.x, y: l.baseline - l.lineTop)
    }
    /// The glyphs on the display line holding `i` (whose glyphs' boxes start at `top`).
    private func lineGlyphRange(at i: Int, top: CGFloat) -> NSRange {
        guard let s = textStorage?.mutableString, s.length > 0 else { return NSRange(location: 0, length: 0) }
        let para = s.paragraphRange(for: NSRange(location: min(i, s.length - 1), length: 0))
        var a = min(i, s.length - 1), b = a
        while a > para.location, let l = layout(a - 1), abs(l.rect.minY - top) < 1 { a -= 1 }
        while b + 1 < NSMaxRange(para), let l = layout(b + 1), abs(l.rect.minY - top) < 1 { b += 1 }
        return NSRange(location: a, length: b - a + 1)
    }
    open func glyphIndex(for point: NSPoint, in container: NSTextContainer, fractionOfDistanceThroughGlyph: UnsafeMutablePointer<CGFloat>?) -> Int {
        let o = containerOrigin
        let i = onMainThread { textView?.characterIndex(at: CGPoint(x: point.x + o.x, y: point.y + o.y)) ?? 0 }
        if let f = fractionOfDistanceThroughGlyph {
            f.pointee = 0
            if let l = layout(i), l.rect.width > 0 { f.pointee = max(0, min(1, (point.x + o.x - l.rect.minX) / l.rect.width)) }
        }
        return min(i, max(0, numberOfGlyphs - 1))
    }
    open func glyphIndex(for point: NSPoint, in container: NSTextContainer) -> Int { glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil) }
    open func characterIndex(for point: NSPoint, in container: NSTextContainer, fractionOfDistanceBetweenInsertionPoints: UnsafeMutablePointer<CGFloat>?) -> Int {
        glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: fractionOfDistanceBetweenInsertionPoints)
    }
    open func glyphRange(forBoundingRect rect: NSRect, in container: NSTextContainer) -> NSRange {
        guard numberOfGlyphs > 0 else { return NSRange(location: 0, length: 0) }
        let a = glyphIndex(for: rect.origin, in: container)
        let b = glyphIndex(for: CGPoint(x: rect.maxX, y: rect.maxY), in: container)
        let lo = min(a, b), hi = min(numberOfGlyphs - 1, max(a, b))
        return NSRange(location: lo, length: hi - lo + 1)
    }
    open func glyphRange(forBoundingRectWithoutAdditionalLayout rect: NSRect, in container: NSTextContainer) -> NSRange { glyphRange(forBoundingRect: rect, in: container) }

    /// Calls `block` for each line fragment in the range.
    open func enumerateLineFragments(forGlyphRange r: NSRange, using block: (NSRect, NSRect, NSTextContainer, NSRange, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard let c = textContainers.first, numberOfGlyphs > 0 else { return }
        var loc = r.location
        var stop: ObjCBool = false
        while loc < min(NSMaxRange(r), numberOfGlyphs), !stop.boolValue {
            var lr = NSRange()
            let rect = lineFragmentRect(forGlyphAt: loc, effectiveRange: &lr)
            block(rect, lineFragmentUsedRect(forGlyphAt: loc, effectiveRange: nil), c, lr, &stop)
            loc = max(NSMaxRange(lr), loc + 1)
        }
    }
    /// The rects (one per line) that enclose a range's glyphs.
    open func enumerateEnclosingRects(forGlyphRange r: NSRange, withinSelectedGlyphRange sel: NSRange, in container: NSTextContainer, using block: (NSRect, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard numberOfGlyphs > 0, r.length > 0 else {
            var stop: ObjCBool = false
            block(boundingRect(forGlyphRange: r, in: container), &stop)
            return
        }
        let o = containerOrigin
        var rects: [CGRect] = []
        var current: CGRect?
        for i in r.location..<min(NSMaxRange(r), numberOfGlyphs) {
            guard let l = layout(i) else { continue }
            if isHidden(i) { continue }
            if let c = current, abs(c.minY - l.rect.minY) < 1 {
                current = c.union(l.rect)
            } else {
                if let c = current { rects.append(c) }
                current = l.rect
            }
        }
        if let c = current { rects.append(c) }
        var stop: ObjCBool = false
        for rect in rects {
            block(rect.offsetBy(dx: -o.x, dy: -o.y), &stop)
            if stop.boolValue { break }
        }
    }
    open func defaultLineHeight(for font: NSFont) -> CGFloat { (font.pointSize * 1.25).rounded(.up) }
    open func defaultBaselineOffset(for font: NSFont) -> CGFloat { (font.pointSize * 0.95).rounded() }
    open var extraLineFragmentRect: NSRect { .zero }
    open var extraLineFragmentUsedRect: NSRect { .zero }
    open var extraLineFragmentTextContainer: NSTextContainer? { nil }

    // MARK: Drawing
    //
    // The text view calls these as it draws, under the toolkit's text: the
    // toolkit draws the glyphs and background colours themselves, so the
    // defaults draw nothing, and an override draws its decorations.
    open func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {}
    open func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {}
    open func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        let rects = Array(UnsafeBufferPointer(start: rectArray, count: rectCount))
        onMainThread { rects.forEach { $0.fill() } }
    }
    open func drawUnderline(forGlyphRange glyphRange: NSRange, underlineType: NSUnderlineStyle, baselineOffset: CGFloat, lineFragmentRect: NSRect, lineFragmentGlyphRange: NSRange, containerOrigin: NSPoint) {}
    open func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<NSPoint>, count glyphCount: Int, font: NSFont, textMatrix: CGAffineTransform, attributes: [NSAttributedString.Key: Any] = [:], in context: CGContext) {}

    // MARK: Temporary attributes (spelling marks, find highlights, hover)
    //
    // Shown over the storage's attributes, without changing the text.

    private var temporary: [(NSRange, [NSAttributedString.Key: Any])] = []
    private func temporaryChanged(_ r: NSRange) { onMainThread { textView?.refreshText(in: r) } }
    open func addTemporaryAttribute(_ key: NSAttributedString.Key, value: Any, forCharacterRange r: NSRange) {
        addTemporaryAttributes([key: value], forCharacterRange: r)
    }
    open func addTemporaryAttributes(_ attrs: [NSAttributedString.Key: Any], forCharacterRange r: NSRange) {
        guard r.length > 0 else { return }
        temporary.append((r, attrs))
        temporaryChanged(r)
    }
    open func setTemporaryAttributes(_ attrs: [NSAttributedString.Key: Any], forCharacterRange r: NSRange) {
        removeTemporaries(in: r) { _ in true }
        if !attrs.isEmpty { temporary.append((r, attrs)) }
        temporaryChanged(r)
    }
    open func removeTemporaryAttribute(_ key: NSAttributedString.Key, forCharacterRange r: NSRange) {
        removeTemporaries(in: r) { $0 == key }
        temporaryChanged(r)
    }
    /// Removes the matching keys inside `r`, keeping the parts of each range outside it.
    private func removeTemporaries(in r: NSRange, _ matches: (NSAttributedString.Key) -> Bool) {
        var out: [(NSRange, [NSAttributedString.Key: Any])] = []
        for (range, attrs) in temporary {
            let overlap = NSIntersectionRange(range, r)
            guard overlap.length > 0 else { out.append((range, attrs)); continue }
            let kept = attrs.filter { !matches($0.key) }
            if !kept.isEmpty { out.append((overlap, kept)) }
            if range.location < r.location { out.append((NSRange(location: range.location, length: r.location - range.location), attrs)) }
            if NSMaxRange(range) > NSMaxRange(r) { out.append((NSRange(location: NSMaxRange(r), length: NSMaxRange(range) - NSMaxRange(r)), attrs)) }
        }
        temporary = out
    }
    open func temporaryAttributes(atCharacterIndex i: Int, effectiveRange: UnsafeMutablePointer<NSRange>?) -> [NSAttributedString.Key: Any] {
        var out: [NSAttributedString.Key: Any] = [:]
        var lo = 0, hi = Int.max
        for (r, a) in temporary {
            if NSLocationInRange(i, r) {
                for (k, v) in a { out[k] = v }
                lo = max(lo, r.location); hi = min(hi, NSMaxRange(r))
            } else if r.location > i {
                hi = min(hi, r.location)
            } else if NSMaxRange(r) <= i {
                lo = max(lo, NSMaxRange(r))
            }
        }
        effectiveRange?.pointee = NSRange(location: lo, length: hi == Int.max ? max(0, numberOfGlyphs - lo) : hi - lo)
        return out
    }
    open func temporaryAttribute(_ key: NSAttributedString.Key, atCharacterIndex i: Int, effectiveRange: UnsafeMutablePointer<NSRange>?) -> Any? {
        temporaryAttributes(atCharacterIndex: i, effectiveRange: effectiveRange)[key]
    }
    /// The places inside `r` where temporary attributes start or end.
    func temporaryBoundaries(in r: NSRange) -> [Int] {
        var out: [Int] = []
        for (t, _) in temporary {
            if t.location > r.location, t.location < NSMaxRange(r) { out.append(t.location) }
            if NSMaxRange(t) > r.location, NSMaxRange(t) < NSMaxRange(r) { out.append(NSMaxRange(t)) }
        }
        return out
    }
    var hasTemporaryAttributes: Bool { !temporary.isEmpty }
}

open class NSTextContainer: NSObject {
    open var size: CGSize
    open var containerSize: CGSize { get { size } set { size = newValue } }
    open var widthTracksTextView = true
    open var heightTracksTextView = false
    open var lineFragmentPadding: CGFloat = 5
    open var maximumNumberOfLines = 0
    open var lineBreakMode: NSLineBreakMode = .byWordWrapping
    open weak var layoutManager: NSLayoutManager?
    @preconcurrency @MainActor open weak var textView: NSTextView?
    public init(size: CGSize) { self.size = size; super.init() }
    public convenience init(containerSize: CGSize) { self.init(size: containerSize) }
    public override convenience init() { self.init(size: CGSize(width: 1e7, height: 1e7)) }
}

public enum NSSelectionAffinity: UInt, Sendable { case upstream = 0, downstream = 1 }
public enum NSSelectionGranularity: UInt, Sendable { case selectByCharacter = 0, selectByWord, selectByParagraph }

// MARK: Delegates

@preconcurrency @MainActor public protocol NSTextDelegate: AnyObject {
    func textShouldBeginEditing(_ textObject: NSText) -> Bool
    func textShouldEndEditing(_ textObject: NSText) -> Bool
    func textDidBeginEditing(_ notification: Notification)
    func textDidEndEditing(_ notification: Notification)
    func textDidChange(_ notification: Notification)
}
extension NSTextDelegate {
    public func textShouldBeginEditing(_ textObject: NSText) -> Bool { true }
    public func textShouldEndEditing(_ textObject: NSText) -> Bool { true }
    public func textDidBeginEditing(_ notification: Notification) {}
    public func textDidEndEditing(_ notification: Notification) {}
    public func textDidChange(_ notification: Notification) {}
}

@preconcurrency @MainActor public protocol NSTextViewDelegate: NSTextDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool
    func textViewDidChangeSelection(_ notification: Notification)
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange
    func undoManager(for view: NSTextView) -> UndoManager?
}
extension NSTextViewDelegate {
    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool { true }
    public func textViewDidChangeSelection(_ notification: Notification) {}
    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool { false }
    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { false }
    public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange { new }
    public func undoManager(for view: NSTextView) -> UndoManager? { nil }
}

// MARK: NSText and NSTextView

@preconcurrency @MainActor
open class NSText: NSView {
    public static let didBeginEditingNotification = Notification.Name("NSTextDidBeginEditingNotification")
    public static let didEndEditingNotification = Notification.Name("NSTextDidEndEditingNotification")
    public static let didChangeNotification = Notification.Name("NSTextDidChangeNotification")
    public static let movementUserInfoKey = "NSTextMovement"

    public override init(frame frameRect: CGRect) { super.init(frame: frameRect) }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        super.init(coder: coder)
        IBDecoding.leave(self, coder)
    }

    open var string: String { get { "" } set {} }
    open var isFieldEditor = false
    open var isHorizontallyResizable = false
    open var isVerticallyResizable = true
    open var minSize: CGSize = .zero
    open var maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    /// The selected characters (UTF-16).
    open var selectedRange: NSRange {
        get { textSelection }
        set { setTextSelection(newValue) }
    }
    // The selection's storage, which text views override. (NSTextView also
    // has NSTextInputClient's `selectedRange()` method, so the property
    // itself stays here.)
    var textSelection: NSRange { NSRange(location: 0, length: 0) }
    func setTextSelection(_ r: NSRange) {}
}

@preconcurrency @MainActor
open class NSTextView: NSText {
    open override var isFlipped: Bool { true }
    public static let didChangeSelectionNotification = Notification.Name("NSTextViewDidChangeSelectionNotification")
    public static let willChangeNotifyingTextViewNotification = Notification.Name("NSTextViewWillChangeNotifyingTextViewNotification")

    open weak var delegate: NSTextViewDelegate?
    open private(set) var textStorage: NSTextStorage?
    open private(set) var layoutManager: NSLayoutManager?
    open var textContainer: NSTextContainer?
    open var textContainerInset: CGSize = .zero { didSet { configure(); sizeToFitText() } }
    open var textContainerOrigin: CGPoint { CGPoint(x: textContainerInset.width, y: textContainerInset.height) }
    open var writablePasteboardTypes: [NSPasteboard.PasteboardType] { isRichText ? [.rtf, .string] : [.string] }
    open var readablePasteboardTypes: [NSPasteboard.PasteboardType] { isRichText ? [.rtf, .string] : [.string] }
    open var acceptableDragTypes: [NSPasteboard.PasteboardType] { readablePasteboardTypes }
    open var selectionAffinity: NSSelectionAffinity = .downstream
    open var selectionGranularity: NSSelectionGranularity = .selectByCharacter
    open var rangesForUserTextChange: [NSValue]? { isEditable ? [NSValue(range: selectedRange)] : nil }
    open var rangeForUserTextChange: NSRange { isEditable ? selectedRange : NSRange(location: NSNotFound, length: 0) }

    /// A character's layout in the view (the toolkit's).
    func characterLayout(at utf16: Int) -> TextCharacterLayout? {
        guard hasRichBackend, let ak = Runway.appKit else { return nil }
        return ak.textViewCharacterLayout(native, at: TextOffsets.scalarOffset(utf16: utf16, in: string))
    }
    /// A character's rect in the view (the toolkit's layout).
    func characterRect(at utf16: Int) -> CGRect {
        guard hasRichBackend, let ak = Runway.appKit else { return .zero }
        return ak.textViewCharacterRect(native, at: TextOffsets.scalarOffset(utf16: utf16, in: string))
    }
    /// The character nearest a point in the view (UTF-16 offset).
    func characterIndex(at p: CGPoint) -> Int {
        guard hasRichBackend, let ak = Runway.appKit else { return 0 }
        return TextOffsets.utf16Offset(scalar: ak.textViewCharacterIndex(native, at: p), in: string)
    }
    /// The first rect of a character range, in screen coordinates (NSTextInputClient).
    open func firstRect(forCharacterRange r: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = r
        let local = characterRect(at: r.location)
        let inWindow = convert(local, to: nil)
        return window?.convertToScreen(inWindow) ?? inWindow
    }
    open func characterIndexForInsertion(at point: NSPoint) -> Int { characterIndex(at: point) }
    open func characterIndex(for point: NSPoint) -> Int {
        let p = window.map { convert($0.convertPoint(fromScreen: point), from: nil) } ?? point
        return characterIndex(at: p)
    }

    // MARK: Selection

    open func setSelectedRange(_ r: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        setSelectedRanges([NSValue(range: r)], affinity: affinity, stillSelecting: stillSelecting)
    }
    /// Every selection change comes here (as in AppKit, so overrides see
    /// them all): the delegate's say, the view, the notification.
    open func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        selectionAffinity = affinity
        guard let first = ranges.first?.rangeValue else { return }
        var new = clamp(first)
        let old = selection
        if !stillSelecting, new != old, let d = delegate {
            new = clamp(d.textView(self, willChangeSelectionFromCharacterRange: old, toCharacterRange: new))
        }
        selection = new
        if hasRichBackend { Runway.appKit?.setTextViewSelection(native, scalarRange(new, in: string)) }
        guard new != old else { return }
        if new.location != typingEnd { typingUndo = nil }
        // Typing continues in the attributes of the text before the caret.
        if new.length == 0, let ts = textStorage, ts.length > 0, !changingText {
            typingAttributes = ts.attributes(at: max(0, min(new.location - 1, ts.length - 1)), effectiveRange: nil)
        }
        if !stillSelecting {
            let n = Notification(name: NSTextView.didChangeSelectionNotification, object: self, userInfo: ["NSOldSelectedCharacterRange": NSValue(range: old)])
            delegate?.textViewDidChangeSelection(n)
            NotificationCenter.default.post(n)
        }
    }
    open func selectionRange(forProposedRange r: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        guard granularity != .selectByCharacter, let s = string as NSString? else { return r }
        return granularity == .selectByParagraph ? s.paragraphRange(for: r) : r
    }
    private func clamp(_ r: NSRange) -> NSRange {
        let len = (string as NSString).length
        let loc = min(max(0, r.location == NSNotFound ? len : r.location), len)
        return NSRange(location: loc, length: min(max(0, r.length), len - loc))
    }

    // MARK: Pasteboard

    open func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let r = selectedRange
        guard r.length > 0 else { return false }
        switch type {
        case .string: return pboard.setString((string as NSString).substring(with: r), forType: .string)
        default: return false
        }
    }
    open func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard selectedRange.length > 0 else { return false }
        pboard.declareTypes(types, owner: nil)
        var wrote = false
        for t in types where writeSelection(to: pboard, type: t) { wrote = true }
        return wrote
    }
    /// Reads `type` from the pasteboard into the selection (overridden by editors).
    open func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let s = pboard.string(forType: .string) else { return false }
        let r = rangeForUserTextChange
        guard r.location != NSNotFound, shouldChangeText(in: r, replacementString: s), let ts = textStorage else { return false }
        changingText = true
        ts.replaceCharacters(in: r, with: NSAttributedString(string: s, attributes: typingAttributes))
        changingText = false
        setSelectedRange(NSRange(location: r.location + (s as NSString).length, length: 0))
        didChangeText()
        return true
    }
    /// The first readable type the pasteboard has, read.
    open func readSelection(from pboard: NSPasteboard) -> Bool {
        let available = pboard.types ?? []
        for t in readablePasteboardTypes where available.contains(t) || (t == .string && pboard.string(forType: .string) != nil) {
            if readSelection(from: pboard, type: t) { return true }
        }
        return false
    }
    open func preferredPasteboardType(from availableTypes: [NSPasteboard.PasteboardType], restrictedToTypesFrom allowedTypes: [NSPasteboard.PasteboardType]?) -> NSPasteboard.PasteboardType? {
        availableTypes.first { allowedTypes?.contains($0) ?? true }
    }
    open func pasteAsPlainText(_ sender: Any?) {
        guard isEditable else { return }
        _ = readSelection(from: .general, type: .string)
    }
    open func pasteAsRichText(_ sender: Any?) { paste(sender) }
    open func dragOperation(for dragInfo: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation { isEditable ? .copy : [] }
    open func clicked(onLink link: Any, at charIndex: Int) {
        if delegate?.textView(self, clickedOnLink: link, at: charIndex) == true { return }
        if let u = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
    }

    open override var usesNativeKeyboardFocus: Bool { true }
    /// Keys with commands (Return, arrows, ⌘-keys…) come as key events
    /// through the responder chain, as on the Mac; typed text through the
    /// toolkit's input method into `insertText`.
    var takesKeyEvents: Bool { hasRichBackend && !isFieldEditor }
    open override var acceptsFirstResponder: Bool { isSelectable || isEditable }
    open var isEditable = true { didSet { configure() } }
    open var isSelectable = true { didSet { configure() } }
    open var isRichText = true
    open var importsGraphics = false
    open var allowsUndo = true { didSet { configure() } }
    open var usesFindBar = false
    open var usesFindPanel = false
    open var isIncrementalSearchingEnabled = false
    open var usesFontPanel = true
    open var usesRuler = false
    open var isRulerVisible = false
    open var usesInspectorBar = false
    open var allowsImageEditing = false
    open var allowsDocumentBackgroundColorChange = false
    open var isAutomaticQuoteSubstitutionEnabled = false
    open var isAutomaticDashSubstitutionEnabled = false
    open var isAutomaticTextReplacementEnabled = false
    open var isAutomaticSpellingCorrectionEnabled = false
    open var isAutomaticLinkDetectionEnabled = false
    open var isAutomaticDataDetectionEnabled = false
    open var isAutomaticTextCompletionEnabled = false
    open var isContinuousSpellCheckingEnabled = false
    open var isGrammarCheckingEnabled = false
    open var smartInsertDeleteEnabled = false
    open var displaysLinkToolTips = true
    open var drawsBackground = true { didSet { configure() } }
    open var backgroundColor: NSColor = .textBackgroundColor { didSet { configure() } }
    open var insertionPointColor: NSColor = .textColor { didSet { configure() } }
    open var selectedTextAttributes: [NSAttributedString.Key: Any] = [:]
    open var linkTextAttributes: [NSAttributedString.Key: Any]?
    open var markedTextAttributes: [NSAttributedString.Key: Any]?
    open var defaultParagraphStyle: NSParagraphStyle?
    open var typingAttributes: [NSAttributedString.Key: Any] = [:]
    open var alignment: NSTextAlignment = .natural
    open var baseWritingDirection: NSWritingDirection = .natural
    open var enabledTextCheckingTypes: UInt64 = 0
    open var allowedInputSourceLocales: [String]?

    open var font: NSFont? {
        didSet {
            if let f = font {
                typingAttributes[.font] = f
                if let ts = textStorage, ts.length > 0, !isRichText { ts.addAttribute(.font, value: f, range: NSRange(location: 0, length: ts.length)) }
            }
            configure()
        }
    }
    open var textColor: NSColor? {
        didSet {
            if let c = textColor {
                typingAttributes[.foregroundColor] = c
                if let ts = textStorage, ts.length > 0, !isRichText { ts.addAttribute(.foregroundColor, value: c, range: NSRange(location: 0, length: ts.length)) }
            }
            configure()
        }
    }

    let native: NativeWidget
    private let hasRichBackend: Bool
    private var editing = false
    private var selection = NSRange(location: 0, length: 0)
    /// Set while the view changes its own storage (selection changes then
    /// keep the typing attributes).
    private var changingText = false
    /// The text (UTF-16) the native view shows.
    private var shown: [UInt16] = []
    open override var undoManager: UndoManager? { delegate?.undoManager(for: self) ?? window?.undoManager ?? ownUndo }
    private lazy var ownUndo = UndoManager()

    public override init(frame frameRect: CGRect) {
        let made: (NativeWidget, Bool) = MainActor.assumeIsolated {
            AppKitControls.install()
            if let ak = Runway.appKit { return (ak.makeTextView(), true) }
            return (Runway.backend.makeWidget(.textEditor), false)
        }
        native = made.0
        hasRichBackend = made.1
        super.init(frame: frameRect)
        onMain { setUp(storage: NSTextStorage(), container: nil) }
    }
    public init(frame frameRect: CGRect, textContainer container: NSTextContainer?) {
        AppKitControls.install()
        if let ak = Runway.appKit { native = ak.makeTextView(); hasRichBackend = true } else { native = Runway.backend.makeWidget(.textEditor); hasRichBackend = false }
        super.init(frame: frameRect)
        setUp(storage: container?.layoutManager?.textStorage ?? NSTextStorage(), container: container)
    }
    public required init?(coder: NSCoder) {
        IBDecoding.enter(coder)
        let made: (NativeWidget, Bool) = MainActor.assumeIsolated {
            AppKitControls.install()
            if let ak = Runway.appKit { return (ak.makeTextView(), true) }
            return (Runway.backend.makeWidget(.textEditor), false)
        }
        native = made.0
        hasRichBackend = made.1
        super.init(coder: coder)
        onMain { setUp(storage: NSTextStorage(), container: nil) }
        IBDecoding.leave(self, coder)
    }

    private func setUp(storage: NSTextStorage, container: NSTextContainer?) {
        let lm = container?.layoutManager ?? NSLayoutManager()
        let tc = container ?? NSTextContainer(size: CGSize(width: frame.width, height: 1e7))
        if container == nil { lm.addTextContainer(tc); tc.layoutManager = lm }
        if storage.layoutManagers.isEmpty { storage.addLayoutManager(lm) }
        lm.textView = self
        tc.textView = self
        layoutManager = lm
        textContainer = tc
        textStorage = storage
        storage.observers.append((self, { [weak self] mask, range, delta in self?.storageEdited(mask, range, delta) }))
        typingAttributes = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]
        configure()
        pushAll()
    }

    /// A shared, never-shown text view standing in for the field editor
    /// of text fields (for `control(_:textView:doCommandBy:)`).
    private static var fieldEditors: [ObjectIdentifier: NSTextView] = [:]
    /// The text field this field editor is editing (its text lives in the
    /// field's own entry, so selection commands go there).
    weak var fieldEditorClient: NSTextField?

    static func fieldEditor(for control: NSControl) -> NSTextView {
        let key = ObjectIdentifier(control.hostWindow ?? NSApp)
        if let e = fieldEditors[key] { return e }
        let e = NSTextView(frame: .zero)
        e.isFieldEditor = true
        e.isRichText = false
        fieldEditors[key] = e
        return e
    }

    // MARK: Content

    open override var string: String {
        get { textStorage?.string ?? "" }
        set {
            guard let ts = textStorage else { return }
            ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: NSAttributedString(string: newValue, attributes: typingAttributes))
        }
    }
    open func attributedString() -> NSAttributedString { textStorage.map { $0.attributedSubstring(from: NSRange(location: 0, length: $0.length)) } ?? NSAttributedString(string: "") }

    private var defaultSpec: FontSpec { (font ?? (typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: 13)).spec }

    /// The storage changed: show the change.
    private func storageEdited(_ mask: NSTextStorageEditActions, _ range: NSRange, _ delta: Int) {
        guard hasRichBackend else { pushPlain(); return }
        push(edited: range.location == NSNotFound ? nil : range)
        if mask.contains(.editedCharacters) {
            selection = clamp(selection)
            if let ak = Runway.appKit { ak.setTextViewSelection(native, scalarRange(selection, in: string)) }
        }
        needsDisplay = true
        sizeToFitText()
    }

    /// Shows a range again (its attributes, temporary ones or glyphs changed).
    func refreshText(in range: NSRange) {
        guard hasRichBackend, let ts = textStorage else { return }
        let r = NSIntersectionRange(range, NSRange(location: 0, length: ts.length))
        if pendingRefresh == nil {
            Runway.backend.schedule { [weak self] in
                guard let self, let r = self.pendingRefresh else { return }
                self.pendingRefresh = nil
                self.push(edited: r)
                self.needsDisplay = true
            }
        }
        pendingRefresh = pendingRefresh.map { NSUnionRange($0, r) } ?? r
    }
    private var pendingRefresh: NSRange?

    /// Sends the whole storage to the native view.
    private func pushAll() {
        guard hasRichBackend else { pushPlain(); return }
        shown = []
        push(edited: NSRange(location: 0, length: textStorage?.length ?? 0))
        sizeToFitText()
    }

    private func pushPlain() {
        guard let ts = textStorage else { return }
        var p = WidgetProps()
        p.string = ts.string
        var e = WidgetEvents()
        e.onText = { [weak self] s in self?.plainEdited(s) }
        Runway.backend.update(native, props: p, events: e)
    }

    /// Updates the native view from the storage: the paragraphs whose text
    /// changed since it was last shown (found by comparing) and those in
    /// `edited` (attributes) are replaced or restyled.
    private func push(edited: NSRange?) {
        guard let ts = textStorage, let ak = Runway.appKit else { return }
        let new = Array(ts.string.utf16)
        let old = shown
        var p = 0
        let n = min(old.count, new.count)
        while p < n, old[p] == new[p] { p += 1 }
        var sfx = 0
        while sfx < n - p, old[old.count - 1 - sfx] == new[new.count - 1 - sfx] { sfx += 1 }
        let textChanged = old.count != new.count || p < n
        var start = new.count, end = 0
        if textChanged { start = p; end = new.count - sfx }
        if let e = edited, e.location != NSNotFound {
            let c = NSIntersectionRange(e, NSRange(location: 0, length: new.count))
            if c.length > 0 || (c.location <= new.count && e.length == 0 && textChanged) {
                start = min(start, c.location); end = max(end, NSMaxRange(c))
            }
        }
        guard start <= end, textChanged || end > start else { return }
        // Whole paragraphs: paragraph spacing and styles belong to them.
        let s = ts.mutableString
        if s.length > 0 {
            start = s.paragraphRange(for: NSRange(location: min(start, s.length), length: 0)).location
            if end > start { end = NSMaxRange(s.paragraphRange(for: NSRange(location: min(end - 1, s.length - 1), length: 0))) }
            end = max(end, min(s.length, new.count - sfx))
        }
        let delta = new.count - old.count
        let oldEnd = max(start, min(old.count, end - delta))
        layoutManager?.textReplaced(NSRange(location: start, length: oldEnd - start), newLength: end - start)
        let range = NSRange(location: start, length: end - start)
        layoutManager?.generateGlyphs(in: range)
        let runs = richRuns(in: range)
        let a = Self.scalars(new, upTo: start), b = Self.scalars(old, upTo: oldEnd)
        shown = new
        ak.editTextView(native, replacing: a..<max(a, b), with: runs, all: { [unowned self] in self.richRuns(in: NSRange(location: 0, length: new.count)) })
    }

    private static func scalars(_ u: [UInt16], upTo end: Int) -> Int {
        var n = 0
        for i in 0..<min(end, u.count) where !(0xDC00...0xDFFF).contains(u[i]) { n += 1 }
        return n
    }

    /// The runs a range shows: the storage's attributes over temporary
    /// ones, null glyphs hidden, whitespace control glyphs as spacers, and
    /// the layout manager delegate's paragraph spacing.
    private func richRuns(in range: NSRange) -> [RichTextRun] {
        guard let ts = textStorage, range.length > 0 else { return [] }
        let s = ts.mutableString
        let lm = layoutManager
        // Where runs break: attribute runs, temporary attributes, glyph kinds.
        var cuts = Set<Int>([range.location, NSMaxRange(range)])
        ts.enumerateAttributes(in: range, options: []) { _, r, _ in cuts.insert(r.location); cuts.insert(NSMaxRange(r)) }
        lm?.temporaryBoundaries(in: range).forEach { cuts.insert($0) }
        var kind = -1
        for i in range.location..<NSMaxRange(range) {
            let k = lm?.spacerWidth(i) != nil ? 2 : lm?.isHidden(i) == true ? 1 : 0
            if k != kind || k == 2 { cuts.insert(i); if k == 2 { cuts.insert(i + 1) } }
            kind = k
        }
        // Paragraph spacing the delegate gives, by paragraph start.
        var spacing: [Int: (before: CGFloat, after: CGFloat)] = [:]
        if let lm, let d = lm.delegate {
            let width = textContainer?.size.width ?? bounds.width
            var at = s.paragraphRange(for: NSRange(location: range.location, length: 0)).location
            while at < NSMaxRange(range) {
                let pr = s.paragraphRange(for: NSRange(location: at, length: 0))
                let rect = NSRect(x: 0, y: 0, width: width, height: 0)
                let before = d.layoutManager(lm, paragraphSpacingBeforeGlyphAt: at, withProposedLineFragmentRect: rect)
                let after = d.layoutManager(lm, paragraphSpacingAfterGlyphAt: max(at, NSMaxRange(pr) - 1), withProposedLineFragmentRect: rect)
                if before != unimplementedSpacing || after != unimplementedSpacing { spacing[pr.location] = (before, after); if pr.location > range.location { cuts.insert(pr.location) } }
                guard NSMaxRange(pr) > at else { break }
                at = NSMaxRange(pr)
            }
        }
        let font = defaultSpec, color = (textColor ?? .textColor).rgbaValue
        var out: [RichTextRun] = []
        let sorted = cuts.sorted()
        var paragraph = s.paragraphRange(for: NSRange(location: range.location, length: 0))
        for (a, b) in zip(sorted, sorted.dropFirst()) where b > a {
            if a >= NSMaxRange(paragraph) { paragraph = s.paragraphRange(for: NSRange(location: a, length: 0)) }
            var attrs = ts.attributes(at: a, effectiveRange: nil)
            if let lm, lm.hasTemporaryAttributes {
                var temp = lm.temporaryAttributes(atCharacterIndex: a, effectiveRange: nil)
                if let d = lm.delegate, !temp.isEmpty { temp = d.layoutManager(lm, shouldUseTemporaryAttributes: temp, forDrawingToScreen: true, atCharacterIndex: a, effectiveRange: nil) ?? [:] }
                for (k, v) in temp { attrs[k] = v }
            }
            var run = Self.run(s.substring(with: NSRange(location: a, length: b - a)), attrs, defaultFont: font, defaultColor: color)
            if run.paragraph == nil, let p = defaultParagraphStyle { run.paragraph = p.spec }
            if let sp = spacing[paragraph.location] {
                var p = run.paragraph ?? ParagraphSpec()
                if sp.before != unimplementedSpacing { p.paragraphSpacingBefore = sp.before }
                if sp.after != unimplementedSpacing { p.paragraphSpacing = sp.after }
                run.paragraph = p
            }
            if lm?.isHidden(a) == true { run.hidden = true }
            if let w = lm?.spacerWidth(a) { run.spacerWidth = w }
            out.append(run)
        }
        return out
    }

    /// A run with every attribute a text view shows.
    static func run(_ string: String, _ attrs: [NSAttributedString.Key: Any], defaultFont: FontSpec, defaultColor: RGBA?) -> RichTextRun {
        var run = RichTextRun(string: string, font: (attrs[.font] as? NSFont)?.spec ?? defaultFont,
                              color: (attrs[.foregroundColor] as? NSColor)?.rgbaValue ?? defaultColor)
        run.background = (attrs[.backgroundColor] as? NSColor)?.rgbaValue
        let underline = NSAttributedString.intValue(attrs[.underlineStyle])
        run.underline = underline != 0
        run.underlineStyle = underline & 0xF == NSUnderlineStyle.double.rawValue ? 3 : underline & 0xF == NSUnderlineStyle.thick.rawValue ? 2 : 1
        run.underlineColor = (attrs[.underlineColor] as? NSColor)?.rgbaValue
        run.strikethrough = NSAttributedString.intValue(attrs[.strikethroughStyle]) != 0
        run.strikethroughColor = (attrs[.strikethroughColor] as? NSColor)?.rgbaValue
        run.baselineOffset = CGFloat(NSAttributedString.doubleValue(attrs[.baselineOffset]))
        run.kern = CGFloat(NSAttributedString.doubleValue(attrs[.kern]))
        if let l = attrs[.link] { run.link = (l as? URL)?.absoluteString ?? "\(l)" }
        if run.link != nil, attrs[.foregroundColor] == nil { run.color = NSColor.linkColor.rgbaValue; run.underline = true }
        run.paragraph = (attrs[.paragraphStyle] as? NSParagraphStyle)?.spec
        return run
    }

    private func configure() {
        guard hasRichBackend, let ak = Runway.appKit else { return }
        var c = TextViewConfig()
        c.editable = isEditable
        c.selectable = isSelectable
        c.wraps = !isHorizontallyResizable
        let padding = textContainer?.lineFragmentPadding ?? 5
        let o = textContainerOrigin
        // The text sits at the container's origin; below it the inset's room
        // (an override may move the origin within the insets).
        let containerWidth = textContainer.map { $0.widthTracksTextView ? bounds.width - 2 * textContainerInset.width : $0.size.width } ?? bounds.width
        let trailing = max(0, bounds.width - o.x - containerWidth)
        c.insets = EdgeInsetsValue(top: max(0, o.y), leading: o.x + padding,
                                   bottom: max(0, 2 * textContainerInset.height - o.y), trailing: (bounds.width > 0 ? trailing : textContainerInset.width) + padding)
        c.background = backgroundColor.rgbaValue
        c.drawsBackground = drawsBackground
        c.font = defaultSpec
        c.textColor = (textColor ?? .textColor).rgbaValue
        c.allowsUndo = allowsUndo
        if insertionPointColor !== NSColor.textColor { c.caretColor = insertionPointColor.rgbaValue }
        guard c != lastConfig || !configured else { return }
        lastConfig = c
        configured = true
        var e = TextViewEvents()
        e.shouldChange = { [weak self] r, s in self?.nativeShouldChange(r, s) ?? true }
        e.didChange = { [weak self] r, s in self?.nativeDidChange(r, s) }
        e.insertText = { [weak self] s in self?.typed(s) ?? false }
        e.userSelection = { [weak self] r, dragging in self?.userSelected(r, dragging: dragging) }
        e.focusChanged = { [weak self] f in self?.nativeFocusChanged(f) }
        e.key = { [weak self] k in self?.nativeKey(k) ?? false }
        e.pointer = { [weak self] p in self?.nativePointer(p) ?? false }
        e.heightChanged = { [weak self] _ in self?.layoutSettled() }
        ak.configureTextView(native, c, events: e)
    }
    /// The toolkit finished laying the text out (it does so in steps after
    /// an edit): the view's height, the layout manager's drawing (its
    /// geometry may have moved) and its delegate hear of it.
    private func layoutSettled() {
        sizeToFitText()
        needsDisplay = true
        if let lm = layoutManager { lm.delegate?.layoutManager(lm, didCompleteLayoutFor: textContainer, atEnd: true) }
    }
    private var lastConfig = TextViewConfig()
    private var configured = false

    private func nsRange(_ r: Range<Int>, in s: String) -> NSRange {
        let a = TextOffsets.utf16Offset(scalar: r.lowerBound, in: s)
        let b = TextOffsets.utf16Offset(scalar: r.upperBound, in: s)
        return NSRange(location: a, length: b - a)
    }
    private func scalarRange(_ r: NSRange, in s: String) -> Range<Int> {
        let a = TextOffsets.scalarOffset(utf16: r.location, in: s)
        let b = TextOffsets.scalarOffset(utf16: NSMaxRange(r), in: s)
        return a..<max(a, b)
    }

    // MARK: Input from the native view

    /// Text the user typed (or an input method committed): `insertText`, as on the Mac.
    private func typed(_ s: String) -> Bool {
        guard isEditable else { return false }
        let before = changeCount
        userTyping = true
        insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
        userTyping = false
        return changeCount != before
    }
    /// Counts the view's changes (so callers can tell whether one happened).
    private var changeCount = 0

    private func userSelected(_ r: Range<Int>, dragging: Bool) {
        let new = nsRange(r, in: string)
        guard new != selection || !dragging else { return }
        setSelectedRanges([NSValue(range: new)], affinity: selectionAffinity, stillSelecting: dragging)
    }

    /// Set by `mouseDown(with:)`'s default: the toolkit handles the press
    /// (caret placement, selection by dragging, double-click words).
    private var pressGoesNative = false
    private var pressConsumed = false
    /// Presses in the view go through the window as events (so an
    /// override of `mouseDown(with:)` sees them first).
    private func nativePointer(_ e: PointerEvent) -> Bool {
        guard let w = window else { return false }
        let p = convert(e.location, to: nil)
        var raw = RawEvent(kind: e.kind == .down ? .mouseDown : .mouseUp)
        raw.button = e.button
        raw.location = CGPoint(x: p.x, y: w.contentSize.height - p.y)
        var m: RawModifiers = []
        if e.modifiers.contains(.shift) { m.insert(.shift) }
        if e.modifiers.contains(.command) { m.insert(.control) }
        if e.modifiers.contains(.option) { m.insert(.alt) }
        if e.modifiers.contains(.control) { m.insert(.super) }
        raw.modifiers = m
        raw.timestamp = ProcessInfo.processInfo.systemUptime
        if e.kind == .down {
            pressGoesNative = false
            _ = w.handleRaw(raw)
            pressConsumed = !pressGoesNative
            return pressConsumed
        }
        _ = w.handleRaw(raw)
        return pressConsumed
    }

    open override func mouseDown(with event: NSEvent) {
        // The toolkit places the caret and selects.
        pressGoesNative = true
    }
    open override func mouseUp(with event: NSEvent) {}
    open override func mouseDragged(with event: NSEvent) {}

    private func nativeShouldChange(_ r: Range<Int>, _ s: String) -> Bool {
        if !editing {
            if !(delegate?.textShouldBeginEditing(self) ?? true) { return false }
        }
        return shouldChangeText(in: nsRange(r, in: string), replacementString: s)
    }

    /// Before an edit: the delegate's say, and the undo for it (AppKit
    /// registers an edit's undo here).
    open func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        guard isEditable else { return false }
        if !editing, !(delegate?.textShouldBeginEditing(self) ?? true) { return false }
        guard delegate?.textView(self, shouldChangeTextIn: range, replacementString: replacementString) ?? true else { return false }
        if let s = replacementString { registerUndo(replacing: range, with: s) }
        return true
    }

    // MARK: Undo

    private final class Change {
        var location: Int
        var length: Int
        var original: NSAttributedString
        init(location: Int, length: Int, original: NSAttributedString) { self.location = location; self.length = length; self.original = original }
    }
    /// The typing being coalesced into one undo step, and where it ends.
    private var typingUndo: Change?
    private var typingEnd: Int { typingUndo.map { $0.location + $0.length } ?? -1 }
    private var userTyping = false

    private func registerUndo(replacing range: NSRange, with s: String) {
        guard allowsUndo, let ts = textStorage, let um = undoManager, um.isUndoRegistrationEnabled, NSMaxRange(range) <= ts.length else { return }
        let n = (s as NSString).length
        let typing = userTyping && !um.isUndoing && !um.isRedoing
        if typing, let t = typingUndo {
            if range.length == 0, range.location == t.location + t.length {
                t.length += n
                return
            }
            if n == 0, range.length > 0, NSMaxRange(range) == t.location + t.length {
                // Deleting backward: what was typed goes first, then what was there before.
                let typedPart = min(range.length, t.length)
                t.length -= typedPart
                if range.length > typedPart {
                    let more = NSRange(location: range.location, length: range.length - typedPart)
                    let m = NSTextStorage(attributedString: ts.attributedSubstring(from: more))
                    m.append(t.original)
                    t.original = m
                    t.location = range.location
                }
                return
            }
        }
        let change = Change(location: range.location, length: n, original: ts.attributedSubstring(from: range))
        um.registerUndo(withTarget: self) { tv in tv.revert(change) }
        typingUndo = typing ? change : nil
    }

    /// Undoes (or redoes) a change: its text back as it was.
    private func revert(_ c: Change) {
        guard let ts = textStorage else { return }
        let range = NSRange(location: c.location, length: c.length)
        guard NSMaxRange(range) <= ts.length else { return }
        typingUndo = nil
        guard shouldChangeText(in: range, replacementString: c.original.string) else { return }
        changingText = true
        ts.replaceCharacters(in: range, with: c.original)
        changingText = false
        didChangeText()
        setSelectedRange(c.original.length > 0 ? NSRange(location: c.location, length: c.original.length) : NSRange(location: c.location, length: 0))
        scrollRangeToVisible(selectedRange)
    }

    open func breakUndoCoalescing() { typingUndo = nil }
    open var isCoalescingUndo: Bool { typingUndo != nil }

    private func nativeDidChange(_ r: Range<Int>, _ s: String) {
        guard let ts = textStorage else { return }
        let range = nsRange(r, in: ts.string)
        changingText = true
        ts.replaceCharacters(in: range, with: NSAttributedString(string: s, attributes: typingAttributes))
        changingText = false
        didChangeText()
    }

    private func plainEdited(_ s: String) {
        guard let ts = textStorage, s != ts.string else { return }
        ts.replaceCharacters(in: NSRange(location: 0, length: ts.length), with: NSAttributedString(string: s, attributes: typingAttributes))
        didChangeText()
    }

    open func didChangeText() {
        changeCount += 1
        if !editing {
            editing = true
            let n = Notification(name: NSText.didBeginEditingNotification, object: self)
            delegate?.textDidBeginEditing(n)
            NotificationCenter.default.post(n)
        }
        let n = Notification(name: NSText.didChangeNotification, object: self)
        delegate?.textDidChange(n)
        NotificationCenter.default.post(n)
    }

    private func nativeFocusChanged(_ focused: Bool) {
        guard !focused, editing else { return }
        editing = false
        typingUndo = nil
        let n = Notification(name: NSText.didEndEditingNotification, object: self)
        delegate?.textDidEndEditing(n)
        NotificationCenter.default.post(n)
    }

    /// Keys the native view reports before handling them, when the view
    /// isn't in a window that sends them as events (tests, field editors).
    private func nativeKey(_ k: KeyPress) -> Bool {
        if window != nil, takesKeyEvents { return false }
        if k.command {
            switch (k.key, k.shift) {
            case ("z", false): undoManager?.undo(); return true
            case ("z", true): undoManager?.redo(); return true
            default: return false
            }
        }
        let sel: String? = switch k.key {
        case "return": k.option ? "insertNewlineIgnoringFieldEditor:" : "insertNewline:"
        case "tab": k.shift ? "insertBacktab:" : "insertTab:"
        case "escape": "cancelOperation:"
        case "up": "moveUp:"
        case "down": "moveDown:"
        case "backspace": "deleteBackward:"
        default: nil
        }
        guard let sel else { return false }
        guard takesKeyEvents else { return delegate?.textView(self, doCommandBy: Selector(sel)) == true }
        doCommand(by: Selector(sel))
        return true
    }

    // MARK: Keys and commands (NSStandardKeyBindingResponding)

    open override func keyDown(with event: NSEvent) {
        let f = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if f.contains(.command), KeyBindings.selector(for: event) == nil {
            // What the Edit menu would send, for apps without one.
            switch (event.charactersIgnoringModifiers?.lowercased() ?? "", f.contains(.shift)) {
            case ("c", false): copy(nil)
            case ("x", false): cut(nil)
            case ("v", false): paste(nil)
            case ("v", true): pasteAsPlainText(nil)
            case ("a", false): selectAll(nil)
            case ("z", false): undoManager?.undo()
            case ("z", true): undoManager?.redo()
            default: super.keyDown(with: event)
            }
            return
        }
        interpretKeyEvents([event])
    }

    /// The delegate first, then the view (and the responder chain after it).
    open override func doCommand(by selector: Selector) {
        if delegate?.textView(self, doCommandBy: selector) == true { return }
        super.doCommand(by: selector)
    }

    open override func insertText(_ s: Any) { insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }

    /// Inserts at the selection (or `replacementRange`), as typing does:
    /// the delegate's say, the typing attributes, the caret after it.
    open func insertText(_ s: Any, replacementRange: NSRange) {
        var str = (s as? NSAttributedString)?.string ?? (s as? String) ?? "\(s)"
        let range = replacementRange.location == NSNotFound ? rangeForUserTextChange : replacementRange
        guard range.location != NSNotFound, let ts = textStorage else { return }
        if userTyping, str.count == 1 { str = substituted(str, at: range.location) }
        guard shouldChangeText(in: range, replacementString: str) else { return }
        let a = (s as? NSAttributedString) ?? NSAttributedString(string: str, attributes: typingAttributes)
        changingText = true
        ts.replaceCharacters(in: range, with: a)
        changingText = false
        setSelectedRange(NSRange(location: range.location + a.length, length: 0))
        didChangeText()
        scrollRangeToVisible(selectedRange)
    }

    /// Smart quotes, as the Mac types them.
    private func substituted(_ s: String, at loc: Int) -> String {
        guard isAutomaticQuoteSubstitutionEnabled, s == "\"" || s == "'" else { return s }
        let ns = string as NSString
        let prev: unichar = loc > 0 ? ns.character(at: loc - 1) : 32
        let opening = prev == 32 || prev == 10 || prev == 9 || "([{<“‘—–-".utf16.contains(prev)
        if s == "\"" { return opening ? "\u{201C}" : "\u{201D}" }
        return opening ? "\u{2018}" : "\u{2019}"
    }

    /// Replaces a range with text through the delegate and undo, as editing commands do.
    private func edit(_ range: NSRange, _ s: String, caret: Int? = nil) {
        guard isEditable, let ts = textStorage, NSMaxRange(range) <= ts.length else { return }
        guard shouldChangeText(in: range, replacementString: s) else { return }
        changingText = true
        ts.replaceCharacters(in: range, with: NSAttributedString(string: s, attributes: typingAttributes))
        changingText = false
        setSelectedRange(NSRange(location: caret ?? range.location + (s as NSString).length, length: 0))
        didChangeText()
        scrollRangeToVisible(selectedRange)
    }

    private func typingCommand(_ body: () -> Void) {
        userTyping = true
        body()
        userTyping = false
    }

    open override func insertNewline(_ sender: Any?) {
        if isFieldEditor { fieldEditorClient?.submitted(); return }
        typingCommand { insertText("\n") }
    }
    open override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { typingCommand { insertText("\n") } }
    open override func insertLineBreak(_ sender: Any?) { typingCommand { insertText("\u{2028}") } }
    open override func insertParagraphSeparator(_ sender: Any?) { insertNewline(sender) }
    open override func insertTab(_ sender: Any?) {
        if isFieldEditor { window?.selectNextKeyView(sender); return }
        typingCommand { insertText("\t") }
    }
    open override func insertTabIgnoringFieldEditor(_ sender: Any?) { typingCommand { insertText("\t") } }
    open override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }

    open override func deleteBackward(_ sender: Any?) {
        let r = selectedRange
        if r.length > 0 { typingCommand { edit(r, "") }; return }
        guard r.location > 0 else { return }
        let ns = string as NSString
        let prev = ns.rangeOfComposedCharacterSequence(at: r.location - 1)
        typingCommand { edit(prev, "") }
    }
    open override func deleteForward(_ sender: Any?) {
        let r = selectedRange
        if r.length > 0 { edit(r, ""); return }
        let ns = string as NSString
        guard r.location < ns.length else { return }
        edit(ns.rangeOfComposedCharacterSequence(at: r.location), "")
    }
    open override func deleteWordBackward(_ sender: Any?) {
        let r = selectedRange
        if r.length > 0 { edit(r, ""); return }
        let start = wordBoundary(from: r.location, forward: false)
        edit(NSRange(location: start, length: r.location - start), "")
    }
    open override func deleteWordForward(_ sender: Any?) {
        let r = selectedRange
        if r.length > 0 { edit(r, ""); return }
        let end = wordBoundary(from: r.location, forward: true)
        edit(NSRange(location: r.location, length: end - r.location), "")
    }
    open override func deleteToBeginningOfLine(_ sender: Any?) {
        let r = selectedRange
        if r.length > 0 { edit(r, ""); return }
        let start = (string as NSString).lineRange(for: NSRange(location: r.location, length: 0)).location
        edit(NSRange(location: start, length: r.location - start), "")
    }
    open override func deleteToEndOfLine(_ sender: Any?) {
        let r = selectedRange
        let ns = string as NSString
        var end = NSMaxRange(ns.lineRange(for: NSRange(location: r.location, length: 0)))
        if end > r.location, end <= ns.length, end > 0, ns.character(at: end - 1) == 10 { end -= 1 }
        edit(NSRange(location: r.location, length: max(r.length, end - r.location)), "")
    }
    open override func deleteToBeginningOfParagraph(_ sender: Any?) { deleteToBeginningOfLine(sender) }
    open override func deleteToEndOfParagraph(_ sender: Any?) { deleteToEndOfLine(sender) }

    /// The next word boundary from `i` (letters and digits make words).
    private func wordBoundary(from i: Int, forward: Bool) -> Int {
        let ns = string as NSString
        func isWord(_ c: unichar) -> Bool { Character(Unicode.Scalar(c) ?? " ").isLetter || Character(Unicode.Scalar(c) ?? " ").isNumber }
        var j = i
        if forward {
            while j < ns.length, !isWord(ns.character(at: j)) { j += 1 }
            while j < ns.length, isWord(ns.character(at: j)) { j += 1 }
        } else {
            while j > 0, !isWord(ns.character(at: j - 1)) { j -= 1 }
            while j > 0, isWord(ns.character(at: j - 1)) { j -= 1 }
        }
        return j
    }

    /// Caret movement: the toolkit's (it knows the lines as laid out); the
    /// selection comes back through `setSelectedRanges`.
    private func move(_ step: TextMoveStep, _ count: Int, extend: Bool = false) {
        typingUndo = nil
        if hasRichBackend, let ak = Runway.appKit {
            ak.textViewMove(native, by: step, count: count, extend: extend)
            scrollRangeToVisible(NSRange(location: count < 0 ? selection.location : NSMaxRange(selection), length: 0))
            return
        }
        let ns = string as NSString
        let r = selectedRange
        var to = count < 0 ? r.location : NSMaxRange(r)
        switch step {
        case .character: if r.length == 0 || extend { to = max(0, min(ns.length, to + count)) }
        case .document: to = count < 0 ? 0 : ns.length
        default:
            let lr = ns.lineRange(for: NSRange(location: to, length: 0))
            to = count < 0 ? lr.location : max(lr.location, NSMaxRange(lr) - (NSMaxRange(lr) > 0 && ns.character(at: NSMaxRange(lr) - 1) == 10 ? 1 : 0))
        }
        if extend {
            let anchor = count < 0 ? NSMaxRange(r) : r.location
            setSelectedRange(NSRange(location: min(anchor, to), length: abs(anchor - to)))
        } else {
            setSelectedRange(NSRange(location: to, length: 0))
        }
    }

    open override func moveLeft(_ sender: Any?) { move(.character, -1) }
    open override func moveRight(_ sender: Any?) { move(.character, 1) }
    open override func moveBackward(_ sender: Any?) { move(.character, -1) }
    open override func moveForward(_ sender: Any?) { move(.character, 1) }
    open override func moveUp(_ sender: Any?) { move(.displayLine, -1) }
    open override func moveDown(_ sender: Any?) { move(.displayLine, 1) }
    open override func moveWordLeft(_ sender: Any?) { move(.word, -1) }
    open override func moveWordRight(_ sender: Any?) { move(.word, 1) }
    open override func moveWordBackward(_ sender: Any?) { move(.word, -1) }
    open override func moveWordForward(_ sender: Any?) { move(.word, 1) }
    open override func moveToBeginningOfLine(_ sender: Any?) { move(.displayLineEnd, -1) }
    open override func moveToEndOfLine(_ sender: Any?) { move(.displayLineEnd, 1) }
    open override func moveToLeftEndOfLine(_ sender: Any?) { move(.displayLineEnd, -1) }
    open override func moveToRightEndOfLine(_ sender: Any?) { move(.displayLineEnd, 1) }
    open override func moveToBeginningOfParagraph(_ sender: Any?) { move(.paragraphEnd, -1) }
    open override func moveToEndOfParagraph(_ sender: Any?) { move(.paragraphEnd, 1) }
    open override func moveToBeginningOfDocument(_ sender: Any?) { move(.document, -1) }
    open override func moveToEndOfDocument(_ sender: Any?) { move(.document, 1) }
    open override func moveLeftAndModifySelection(_ sender: Any?) { move(.character, -1, extend: true) }
    open override func moveRightAndModifySelection(_ sender: Any?) { move(.character, 1, extend: true) }
    open override func moveBackwardAndModifySelection(_ sender: Any?) { move(.character, -1, extend: true) }
    open override func moveForwardAndModifySelection(_ sender: Any?) { move(.character, 1, extend: true) }
    open override func moveUpAndModifySelection(_ sender: Any?) { move(.displayLine, -1, extend: true) }
    open override func moveDownAndModifySelection(_ sender: Any?) { move(.displayLine, 1, extend: true) }
    open override func moveWordLeftAndModifySelection(_ sender: Any?) { move(.word, -1, extend: true) }
    open override func moveWordRightAndModifySelection(_ sender: Any?) { move(.word, 1, extend: true) }
    open override func moveWordBackwardAndModifySelection(_ sender: Any?) { move(.word, -1, extend: true) }
    open override func moveWordForwardAndModifySelection(_ sender: Any?) { move(.word, 1, extend: true) }
    open override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) { move(.displayLineEnd, -1, extend: true) }
    open override func moveToEndOfLineAndModifySelection(_ sender: Any?) { move(.displayLineEnd, 1, extend: true) }
    open override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) { move(.displayLineEnd, -1, extend: true) }
    open override func moveToRightEndOfLineAndModifySelection(_ sender: Any?) { move(.displayLineEnd, 1, extend: true) }
    open override func moveToBeginningOfParagraphAndModifySelection(_ sender: Any?) { move(.paragraphEnd, -1, extend: true) }
    open override func moveToEndOfParagraphAndModifySelection(_ sender: Any?) { move(.paragraphEnd, 1, extend: true) }
    open override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { move(.document, -1, extend: true) }
    open override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { move(.document, 1, extend: true) }
    open override func pageUp(_ sender: Any?) { move(.page, -1) }
    open override func pageDown(_ sender: Any?) { move(.page, 1) }
    open override func pageUpAndModifySelection(_ sender: Any?) { move(.page, -1, extend: true) }
    open override func pageDownAndModifySelection(_ sender: Any?) { move(.page, 1, extend: true) }
    open override func scrollPageUp(_ sender: Any?) { scrollBy(page: -1) }
    open override func scrollPageDown(_ sender: Any?) { scrollBy(page: 1) }
    open override func scrollToBeginningOfDocument(_ sender: Any?) { enclosingScrollView?.contentView.scroll(to: .zero) }
    open override func scrollToEndOfDocument(_ sender: Any?) {
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.scroll(to: CGPoint(x: 0, y: max(0, bounds.height - clip.bounds.height)))
    }
    private func scrollBy(page: CGFloat) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let y = max(0, min(bounds.height - clip.bounds.height, clip.bounds.minY + page * clip.bounds.height * 0.9))
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
    }
    open override func selectParagraph(_ sender: Any?) { setSelectedRange((string as NSString).paragraphRange(for: selectedRange)) }
    open override func selectLine(_ sender: Any?) { selectParagraph(sender) }
    open override func selectWord(_ sender: Any?) {
        let r = selectedRange
        let a = wordBoundary(from: r.location, forward: false), b = wordBoundary(from: r.location, forward: true)
        setSelectedRange(NSRange(location: a, length: b - a))
    }

    // MARK: Editing API

    override var textSelection: NSRange { selection }
    override func setTextSelection(_ r: NSRange) { setSelectedRange(r) }
    // NSTextInputClient: the selection and marked (composing) text. Input
    // methods compose in the toolkit's own text view (it shows the
    // composition), so there's never marked text here.
    open func selectedRange() -> NSRange { selection }
    open func hasMarkedText() -> Bool { false }
    open func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    open func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    open func unmarkText() {}
    open func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Writing Tools (macOS 15): which experience the view offers.
    open var writingToolsBehavior: NSWritingToolsBehavior = .default
    open var allowedWritingToolsResultOptions: NSWritingToolsResultOptions = []
    open var isWritingToolsActive: Bool { false }

    open var selectedRanges: [NSValue] {
        get { [NSValue(range: selection)] }
        set { setSelectedRanges(newValue, affinity: selectionAffinity, stillSelecting: false) }
    }
    open func setSelectedRange(_ r: NSRange) {
        setSelectedRange(r, affinity: .downstream, stillSelecting: false)
    }
    /// Find commands: an NSMenuItem (or control) whose tag is an
    /// `NSTextFinder.Action`.
    open override func performTextFinderAction(_ sender: Any?) { runTextFinderAction(sender) }

    open override func selectAll(_ sender: Any?) {
        if isFieldEditor, let field = fieldEditorClient {
            field.selectText(sender)
            return
        }
        setSelectedRange(NSRange(location: 0, length: (string as NSString).length))
    }

    open func replaceCharacters(in range: NSRange, with s: String) { textStorage?.replaceCharacters(in: range, with: s) }
    /// Scrolls the enclosing scroll view to show a range.
    open func scrollRangeToVisible(_ range: NSRange) {
        guard let clip = enclosingScrollView?.contentView, (string as NSString).length > 0 || range.location == 0 else { return }
        let r: CGRect
        if let l = characterLayout(at: min(range.location, (string as NSString).length)) {
            r = CGRect(x: 0, y: l.lineTop, width: 1, height: max(1, l.lineBottom - l.lineTop))
        } else {
            let frac = CGFloat(range.location) / CGFloat(max(1, (string as NSString).length))
            r = CGRect(x: 0, y: frac * bounds.height, width: 1, height: 20)
        }
        let visible = clip.bounds
        guard r.minY < visible.minY || r.maxY > visible.maxY else { return }
        let y = r.minY < visible.minY ? r.minY - 8 : r.maxY - visible.height + 8
        clip.scroll(to: CGPoint(x: visible.minX, y: max(0, min(y, bounds.height - visible.height))))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
    open func setAlignment(_ a: NSTextAlignment, range: NSRange) {
        let p = NSMutableParagraphStyle()
        p.alignment = a
        textStorage?.addAttribute(.paragraphStyle, value: p, range: range)
    }
    open func setTextColor(_ c: NSColor?, range: NSRange) {
        if let c { textStorage?.addAttribute(.foregroundColor, value: c, range: range) } else { textStorage?.removeAttribute(.foregroundColor, range: range) }
    }
    open func setFont(_ f: NSFont, range: NSRange) { textStorage?.addAttribute(.font, value: f, range: range) }

    // MARK: Pasteboard actions

    open func copy(_ sender: Any?) {
        guard selectedRange.length > 0 else { return }
        _ = writeSelection(to: .general, types: writablePasteboardTypes)
    }
    open func cut(_ sender: Any?) {
        guard isEditable, selectedRange.length > 0 else { return }
        copy(sender)
        delete(sender)
    }
    open func paste(_ sender: Any?) {
        guard isEditable else { return }
        breakUndoCoalescing()
        _ = readSelection(from: .general)
        breakUndoCoalescing()
    }
    open func delete(_ sender: Any?) {
        let r = selectedRange
        guard r.length > 0 else { return }
        edit(r, "")
    }

    open func undo() { undoManager?.undo() }
    open func redo() { undoManager?.redo() }
    open func checkTextInDocument(_ sender: Any?) {}
    open func performFindPanelAction(_ sender: Any?) {}
    open func showFindIndicator(for range: NSRange) {}
    open func updateInsertionPointStateAndRestartTimer(_ restart: Bool) {}
    open func setNeedsDisplay(_ rect: CGRect, avoidAdditionalLayout: Bool) { needsDisplay = true }
    open func toggleContinuousSpellChecking(_ sender: Any?) { isContinuousSpellCheckingEnabled.toggle() }

    /// The standard editing menu (right click).
    open override class var defaultMenu: NSMenu? {
        let m = NSMenu(title: "Text")
        m.addItem(withTitle: "Cut", action: Selector("cut:"), keyEquivalent: "x")
        m.addItem(withTitle: "Copy", action: Selector("copy:"), keyEquivalent: "c")
        m.addItem(withTitle: "Paste", action: Selector("paste:"), keyEquivalent: "v")
        m.addItem(.separator())
        m.addItem(withTitle: "Select All", action: Selector("selectAll:"), keyEquivalent: "a")
        return m
    }

    /// Runway: puts keyboard focus in the text view.
    open func _runwayFocus() { Runway.appKit?.focus(native) }

    // MARK: Drawing

    /// Draws the layout manager's background and glyphs; the toolkit
    /// draws the text itself over what they draw. What an override draws
    /// after calling this shows above the text.
    open override func draw(_ dirtyRect: NSRect) {
        if let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 {
            let glyphs = lm.glyphRange(for: tc)
            lm.drawBackground(forGlyphRange: glyphs, at: textContainerOrigin)
            lm.drawGlyphs(forGlyphRange: glyphs, at: textContainerOrigin)
        }
        textDrawingSplit = NSGraphicsContext.current?.cgContext.displayList.ops.count
    }
    /// Where the drawing under the text ends in the recording.
    private var textDrawingSplit: Int?

    override func render() {
        guard hasRichBackend, let ak = Runway.appKit else { return super.render() }
        textDrawingSplit = nil
        let list = recordDrawing()
        let split = min(textDrawingSplit ?? 0, list.ops.count)
        let below = CGDisplayList(Array(list.ops[..<split])), above = CGDisplayList(Array(list.ops[split...]))
        ak.setTextViewLayers(native, below: below.isEmpty ? nil : below, above: above.isEmpty ? nil : above)
    }

    // MARK: Size

    var textHeight: CGFloat {
        if hasRichBackend, let ak = Runway.appKit { return ak.textViewHeight(native, width: bounds.width).rounded(.up) }
        return max(bounds.height, 100)
    }

    /// Grows (or shrinks) the view to its text, as a vertically resizable
    /// text view in a scroll view does, never below the visible area.
    func sizeToFitText() {
        guard isVerticallyResizable, bounds.width > 0 else { return }
        var h = max(textHeight, minSize.height)
        if let clip = superview as? NSClipView { h = max(h, clip.bounds.height) }
        h = min(h, maxSize.height)
        if abs(h - frame.height) >= 1 { setFrameSize(CGSize(width: frame.width, height: h)) }
    }

    open func sizeToFit() { sizeToFitText() }

    override func place() {
        placementDirty = false; placeChildren(below: [(native, bounds)]) }
    open override func frameSizeChanged(from old: CGSize) {
        super.frameSizeChanged(from: old)
        layoutSubviews()
        if old.width != frame.width {
            if textContainer?.widthTracksTextView ?? true { textContainer?.size.width = max(0, frame.width - 2 * textContainerInset.width) }
            configure()
            Runway.backend.schedule { [weak self] in self?.sizeToFitText() }
        }
        needsDisplay = true
    }

    /// A text view in a scroll view, sized and set up as Xcode's template makes one.
    public static func scrollableTextView() -> NSScrollView {
        let sv = NSScrollView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        sv.hasVerticalScroller = true
        sv.borderType = .noBorder
        let tv = NSTextView(frame: CGRect(origin: .zero, size: sv.contentSize))
        tv.autoresizingMask = [.width]
        tv.textContainerInset = .zero
        sv.documentView = tv
        return sv
    }
    public static func scrollablePlainDocumentContentTextView() -> NSScrollView {
        let sv = scrollableTextView()
        (sv.documentView as? NSTextView)?.isRichText = false
        return sv
    }
    public static func scrollableDocumentContentTextView() -> NSScrollView { scrollableTextView() }
}

extension NSView {
    /// The nearest scroll view this view is in.
    public var enclosingScrollView: NSScrollView? {
        var p = superview
        while let v = p { if let s = v as? NSScrollView { return s }; p = v.superview }
        return nil
    }
}

public enum NSWritingToolsBehavior: Int, Sendable { case none = -1, `default` = 0, complete = 1, limited = 2 }
public struct NSWritingToolsResultOptions: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let plainText = Self(rawValue: 1 << 0), richText = Self(rawValue: 1 << 1), list = Self(rawValue: 1 << 2)
    public static let table = Self(rawValue: 1 << 3)
}
