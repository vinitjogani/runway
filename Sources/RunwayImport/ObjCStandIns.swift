// Swift stand-ins for Objective-C and C declarations.
//
// From the model ObjCHeaders.swift reads, this writes Swift source that
// declares the same API under the names Swift's Clang importer gives it on
// a Mac (`initWithFoo:` → `init(foo:)`, `pathForResource:ofType:` →
// `path(forResource:ofType:)`, NS_ENUM cases without their common prefix,
// `FooRef` → `Foo`, NSError** → `throws`). The implementations aren't
// compiled (no Objective-C, no Apple SDK on Linux), so the stand-ins do
// nothing and answer "unavailable": objects can be made and hold their
// properties, methods return false / 0 / nil / empty values, functions that
// report errors return a failure code. An app then builds and runs with
// the feature behind those headers switched off.

import Foundation

public struct ObjCStandInOptions {
    /// `public` for a module's API (package targets, framework headers),
    /// `internal` for a bridging header (the names are the target's own).
    public var access = "public"
    /// Modules the generated file imports besides Foundation.
    public var imports: [String] = []
    /// A bridging header makes what it includes visible to every file of the target.
    public var reexportImports = false
    /// Type names the modules in scope already declare (Runway's frameworks,
    /// Foundation): forward-declared classes and opaque references with
    /// these names aren't declared again.
    public var knownTypes: Set<String> = []
    /// Global functions, constants and variables already in scope.
    public var knownValues: Set<String> = []
    /// What the stand-in is for, in the file's header comment.
    public var origin = ""
    public init() {}
}

/// Swift keywords that need backticks as identifiers.
private let swiftKeywords: Set<String> = [
    "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout", "internal", "let", "open",
    "operator", "private", "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case",
    "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where",
    "while", "as", "Any", "catch", "false", "is", "nil", "super", "self", "Self", "throw", "throws", "true", "try", "_",
]

func escaped(_ name: String) -> String { swiftKeywords.contains(name) ? "`\(name)`" : name }

/// camelCase words: `URLForKey` → `URL`, `For`, `Key`.
func camelWords(_ s: String) -> [String] {
    var out: [String] = []
    let c = Array(s)
    var start = 0
    var i = 1
    while i <= c.count {
        if i == c.count { out.append(String(c[start..<i])); break }
        let prev = c[i - 1], cur = c[i]
        let next: Character? = i + 1 < c.count ? c[i + 1] : nil
        var boundary = false
        if cur == "_" || prev == "_" { boundary = true }
        else if cur.isUppercase, prev.isLowercase || prev.isNumber { boundary = true }
        else if cur.isUppercase, prev.isUppercase, let n = next, n.isLowercase, !(n == "s" && (i + 2 == c.count || c[i + 2].isUppercase)) { boundary = true }
        if boundary { out.append(String(c[start..<i])); start = i }
        i += 1
    }
    return out.filter { !$0.isEmpty }
}

/// `URLSession` → `urlSession`, `Foo` → `foo`, `HTTPBody` → `httpBody`.
func lowerCamel(_ s: String) -> String {
    guard let first = s.first, first.isUppercase else { return s }
    let words = camelWords(s)
    guard let w = words.first else { return s }
    // A leading acronym lowercases whole.
    if w.count > 1, w == w.uppercased() { return w.lowercased() + words.dropFirst().joined() }
    return w.prefix(1).lowercased() + w.dropFirst() + words.dropFirst().joined()
}

private let prepositions: Set<String> = [
    "Above", "After", "Along", "Alongside", "As", "At", "Before", "Below", "By", "Following", "For", "From", "Given", "In", "Including",
    "Inside", "Into", "Matching", "Of", "On", "Passing", "Preceding", "Since", "To", "Until", "Using", "Via", "When", "With", "Within",
]

public struct ObjCStandInWriter {
    var model: ObjCHeaderModel
    var options: ObjCStandInOptions
    var constants: [String: Int64]
    private var typedefs: [String: CTypedef] = [:]
    private var structNames = Set<String>()
    private var enumByName: [String: CEnum] = [:]
    private var classNames = Set<String>()
    private var protocolNames = Set<String>()
    private var opaqueNames = Set<String>()
    private var lines: [String] = []
    private var access: String { options.access == "internal" ? "" : options.access + " " }
    private var classAccess: String { options.access == "public" ? "open " : access }

    public init(model: ObjCHeaderModel, constants: [String: Int64], options: ObjCStandInOptions) {
        self.model = model
        self.options = options
        self.constants = constants
        for td in model.typedefs { typedefs[td.name] = td }
        structNames = Set(model.structs.map(\.name))
        for e in model.enums where e.style != .anonymous { enumByName[e.name] = e }
        for c in model.containers {
            if c.kind == .interface { classNames.insert(c.name) }
            if c.kind == .proto { protocolNames.insert(c.name) }
        }
    }

    // MARK: Types

    enum Position { case parameter, result, property, field, generic, typealiasTarget }

    private static let scalarTypes: [String: String] = [
        "void": "Void", "BOOL": "Bool", "bool": "Bool", "_Bool": "Bool", "Boolean": "Bool", "char": "CChar", "signed char": "Int8",
        "unsigned char": "UInt8", "short": "Int16", "unsigned short": "UInt16", "int": "Int32", "unsigned int": "UInt32", "unsigned": "UInt32",
        "signed": "Int32", "signed int": "Int32", "long": "Int", "unsigned long": "UInt", "long long": "Int64", "unsigned long long": "UInt64",
        "long int": "Int", "unsigned long int": "UInt", "short int": "Int16", "unsigned short int": "UInt16", "long long int": "Int64",
        "unsigned long long int": "UInt64", "float": "Float", "double": "Double", "long double": "Double", "NSInteger": "Int", "NSUInteger": "UInt",
        "CGFloat": "CGFloat", "size_t": "Int", "ssize_t": "Int", "int8_t": "Int8", "uint8_t": "UInt8", "int16_t": "Int16", "uint16_t": "UInt16",
        "int32_t": "Int32", "uint32_t": "UInt32", "int64_t": "Int64", "uint64_t": "UInt64", "intptr_t": "Int", "uintptr_t": "UInt",
        "UInt8": "UInt8", "SInt8": "Int8", "UInt16": "UInt16", "SInt16": "Int16", "UInt32": "UInt32", "SInt32": "Int32", "UInt64": "UInt64",
        "SInt64": "Int64", "Float32": "Float", "Float64": "Double", "unichar": "unichar", "NSTimeInterval": "TimeInterval",
        "CFTimeInterval": "CFTimeInterval", "CFIndex": "Int", "u_int32_t": "UInt32", "u_int8_t": "UInt8", "u_int16_t": "UInt16",
        "u_int64_t": "UInt64", "off_t": "Int64", "pid_t": "pid_t", "uid_t": "uid_t", "gid_t": "gid_t", "time_t": "time_t", "va_list": "CVaListPointer",
        "Byte": "UInt8", "SignedByte": "Int8", "UniChar": "UInt16", "OSStatus": "OSStatus", "OSErr": "Int16", "OSType": "OSType",
        "FourCharCode": "FourCharCode", "mach_port_t": "mach_port_t", "dispatch_queue_t": "DispatchQueue", "dispatch_block_t": "() -> Void",
        "dispatch_source_t": "DispatchSourceProtocol", "dispatch_semaphore_t": "DispatchSemaphore", "dispatch_group_t": "DispatchGroup",
        "dispatch_data_t": "DispatchData", "dispatch_time_t": "UInt64", "SEL": "Selector", "Class": "AnyClass", "instancetype": "Self",
        "NSStringEncoding": "UInt", "NSZone": "NSZone", "uuid_t": "uuid_t", "IMP": "OpaquePointer", "Float80": "Double", "wchar_t": "Int32",
        "mode_t": "mode_t", "dev_t": "dev_t", "xpc_object_t": "xpc_object_t", "xpc_connection_t": "xpc_connection_t", "__uint32_t": "UInt32",
        "__int32_t": "Int32", "__uint64_t": "UInt64", "__int64_t": "Int64", "__uint16_t": "UInt16", "__uint8_t": "UInt8", "ptrdiff_t": "Int",
        "NSComparisonResult": "ComparisonResult", "id": "Any", "CFTypeRef": "CFTypeRef",
    ]

    /// Objective-C classes Swift bridges to value types.
    private static let bridged: [String: String] = [
        "NSString": "String", "NSMutableString": "NSMutableString", "NSData": "Data", "NSDate": "Date", "NSURL": "URL", "NSError": "Error",
        "NSUUID": "UUID", "NSIndexPath": "IndexPath", "NSIndexSet": "IndexSet", "NSLocale": "Locale", "NSTimeZone": "TimeZone",
        "NSCalendar": "Calendar", "NSDateComponents": "DateComponents", "NSCharacterSet": "CharacterSet", "NSURLRequest": "URLRequest",
        "NSURLComponents": "URLComponents", "NSNotification": "Notification", "NSURLQueryItem": "URLQueryItem", "NSDecimalNumber": "NSDecimalNumber",
        "NSAffineTransform": "AffineTransform", "NSDateInterval": "DateInterval", "NSPersonNameComponents": "PersonNameComponents",
        "NSURLSession": "URLSession", "NSURLResponse": "URLResponse", "NSHTTPURLResponse": "HTTPURLResponse", "NSBundle": "Bundle",
        "NSNotificationCenter": "NotificationCenter", "NSUserDefaults": "UserDefaults", "NSFileManager": "FileManager", "NSTimer": "Timer",
        "NSThread": "Thread", "NSOperationQueue": "OperationQueue", "NSOperation": "Operation", "NSRunLoop": "RunLoop", "NSFileHandle": "FileHandle",
        "NSProcessInfo": "ProcessInfo", "NSTask": "Process", "NSPipe": "Pipe", "NSFormatter": "Formatter", "NSDateFormatter": "DateFormatter",
        "NSNumberFormatter": "NumberFormatter", "NSURLSessionTask": "URLSessionTask", "NSURLSessionDataTask": "URLSessionDataTask",
        "NSProgress": "Progress", "NSScanner": "Scanner", "NSInputStream": "InputStream", "NSOutputStream": "OutputStream", "NSStream": "Stream",
        "NSPort": "Port", "NSHost": "Host", "NSXMLParser": "XMLParser", "NSJSONSerialization": "JSONSerialization", "NSURLCache": "URLCache",
        "NSHTTPCookie": "HTTPCookie", "NSHTTPCookieStorage": "HTTPCookieStorage", "NSURLCredential": "URLCredential", "NSLock": "NSLock",
        "NSMutableURLRequest": "NSMutableURLRequest", "NSNotificationName": "Notification.Name", "NSRunLoopMode": "RunLoop.Mode",
        "NSUndoManager": "UndoManager", "NSPropertyListSerialization": "PropertyListSerialization", "NSByteCountFormatter": "ByteCountFormatter",
        "NSURLSessionConfiguration": "URLSessionConfiguration", "NSKeyedArchiver": "NSKeyedArchiver", "NSDistributedNotificationCenter": "DistributedNotificationCenter",
        "NSMeasurement": "Measurement", "NSUnit": "Unit", "NSMessagePort": "MessagePort", "NSSocketPort": "SocketPort", "NSPortMessage": "PortMessage",
        "NSExceptionName": "NSExceptionName", "NSErrorDomain": "String", "NSErrorUserInfoKey": "String", "NSAttributedStringKey": "NSAttributedString.Key",
        "NSKeyValueChangeKey": "NSKeyValueChangeKey", "NSFileAttributeKey": "FileAttributeKey", "NSURLResourceKey": "URLResourceKey",
        "NSProgressKind": "ProgressKind", "NSTextCheckingResult": "NSTextCheckingResult", "NSRegularExpression": "NSRegularExpression",
        "NSTimeInterval": "TimeInterval", "NSRange": "NSRange", "NSPoint": "NSPoint", "NSSize": "NSSize", "NSRect": "NSRect",
    ]

    func resolvedTypedef(_ name: String, depth: Int = 0) -> CType? {
        guard depth < 8, let td = typedefs[name], td.opaqueStruct == nil, !td.isTypedEnum else { return nil }
        if case .none = td.type.callable, td.type.pointers == 0, let deeper = resolvedTypedef(td.type.base, depth: depth + 1) { return deeper }
        return td.type
    }

    /// Framework types Swift nests or renames.
    private static let renamed: [String: String] = [
        "NSEventModifierFlags": "NSEvent.ModifierFlags", "NSEventType": "NSEvent.EventType", "NSEventMask": "NSEvent.EventTypeMask",
        "NSWindowStyleMask": "NSWindow.StyleMask", "NSWindowLevel": "NSWindow.Level", "NSControlStateValue": "NSControl.StateValue",
        "NSCellStateValue": "NSControl.StateValue", "NSValueTransformer": "ValueTransformer", "NSPasteboardType": "NSPasteboard.PasteboardType",
        "NSImageName": "NSImage.Name", "NSLayoutAttribute": "NSLayoutConstraint.Attribute", "NSBezelStyle": "NSButton.BezelStyle",
        "NSControlSize": "NSControl.ControlSize", "NSModalResponse": "NSApplication.ModalResponse", "NSAppearanceName": "NSAppearance.Name",
        "NSStoryboardName": "NSStoryboard.Name", "NSNibName": "NSNib.Name", "NSToolbarItemIdentifier": "NSToolbarItem.Identifier",
        "NSToolbarIdentifier": "NSToolbar.Identifier", "NSWindowFrameAutosaveName": "NSWindow.FrameAutosaveName", "NSColorName": "NSColor.Name",
        "NSBackingStoreType": "NSWindow.BackingStoreType", "NSWindowCollectionBehavior": "NSWindow.CollectionBehavior",
        "NSEventPhase": "NSEvent.Phase", "NSEventSubtype": "NSEvent.EventSubtype", "NSLayoutPriority": "NSLayoutConstraint.Priority",
        "NSLayoutConstraintOrientation": "NSLayoutConstraint.Orientation", "NSUserInterfaceLayoutOrientation": "NSUserInterfaceLayoutOrientation",
        "NSTableViewRowSizeStyle": "NSTableView.RowSizeStyle", "NSApplicationActivationPolicy": "NSApplication.ActivationPolicy",
        "NSApplicationPresentationOptions": "NSApplication.PresentationOptions", "NSWorkspaceLaunchOptions": "NSWorkspace.LaunchOptions",
        "NSSoundName": "NSSound.Name", "NSTouchBarItemIdentifier": "NSTouchBarItem.Identifier", "NSBindingName": "NSBindingName",
        "NSDragOperation": "NSDragOperation", "NSTextAlignment": "NSTextAlignment", "NSLineBreakMode": "NSLineBreakMode",
        "NSStringCompareOptions": "NSString.CompareOptions", "NSDataReadingOptions": "Data.ReadingOptions", "NSDataWritingOptions": "Data.WritingOptions",
        "NSJSONReadingOptions": "JSONSerialization.ReadingOptions", "NSJSONWritingOptions": "JSONSerialization.WritingOptions",
        "NSURLBookmarkCreationOptions": "URL.BookmarkCreationOptions", "NSKeyValueObservingOptions": "NSKeyValueObservingOptions",
        "NSOperationQueuePriority": "Operation.QueuePriority", "NSQualityOfService": "QualityOfService", "NSCalendarUnit": "NSCalendar.Unit",
        "NSAttributedStringEnumerationOptions": "NSAttributedString.EnumerationOptions", "NSRegularExpressionOptions": "NSRegularExpression.Options",
        "NSMatchingOptions": "NSRegularExpression.MatchingOptions", "NSPropertyListFormat": "PropertyListSerialization.PropertyListFormat",
        "NSSearchPathDirectory": "FileManager.SearchPathDirectory", "NSSearchPathDomainMask": "FileManager.SearchPathDomainMask",
        "NSDirectoryEnumerationOptions": "FileManager.DirectoryEnumerationOptions", "NSFileManagerItemReplacementOptions": "FileManager.ItemReplacementOptions",
        "NSURLRequestCachePolicy": "URLRequest.CachePolicy", "NSTimeZoneNameStyle": "TimeZone.NameStyle", "NSNumberFormatterStyle": "NumberFormatter.Style",
        "NSDateFormatterStyle": "DateFormatter.Style", "NSPostingStyle": "NotificationQueue.PostingStyle", "NSXMLParserError": "XMLParser.ErrorCode",
        "NSFontWeight": "NSFont.Weight", "NSFontDescriptorSymbolicTraits": "NSFontDescriptor.SymbolicTraits", "NSImageScaling": "NSImageScaling",
        "NSTextFieldBezelStyle": "NSTextField.BezelStyle", "NSButtonType": "NSButton.ButtonType", "NSPopoverBehavior": "NSPopover.Behavior",
        "NSVisualEffectMaterial": "NSVisualEffectView.Material", "NSVisualEffectBlendingMode": "NSVisualEffectView.BlendingMode",
        "NSVisualEffectState": "NSVisualEffectView.State", "NSAlertStyle": "NSAlert.Style", "NSWindowTitleVisibility": "NSWindow.TitleVisibility",
        "NSStatusItemBehavior": "NSStatusItem.Behavior", "NSTableViewAnimationOptions": "NSTableView.AnimationOptions",
        "NSTableViewDropOperation": "NSTableView.DropOperation", "NSTableViewSelectionHighlightStyle": "NSTableView.SelectionHighlightStyle",
        "NSTrackingAreaOptions": "NSTrackingArea.Options", "NSViewLayerContentsRedrawPolicy": "NSView.LayerContentsRedrawPolicy",
        "NSAutoresizingMaskOptions": "NSView.AutoresizingMask", "NSStackViewGravity": "NSStackView.Gravity", "NSStackViewDistribution": "NSStackView.Distribution",
        "NSPasteboardName": "NSPasteboard.Name", "NSPasteboardReadingOptionKey": "NSPasteboard.ReadingOptionKey", "NSCompositingOperation": "NSCompositingOperation",
        "NSFocusRingType": "NSFocusRingType", "NSCursor": "NSCursor", "NSExceptionName": "NSExceptionName", "NSStringEncoding": "UInt",
        "NSURLSessionResponseDisposition": "URLSession.ResponseDisposition", "NSURLSessionAuthChallengeDisposition": "URLSession.AuthChallengeDisposition",
        "NSHTTPCookieAcceptPolicy": "HTTPCookie.AcceptPolicy", "NSTextCheckingType": "NSTextCheckingResult.CheckingType",
        "NSWritingDirection": "NSWritingDirection", "NSSelectionDirection": "NSWindow.SelectionDirection", "NSUnderlineStyle": "NSUnderlineStyle",
    ]

    /// The Swift name of a named type (no pointers, no nullability).
    private func baseName(_ base: String) -> String {
        if let s = Self.scalarTypes[base] { return s }
        if let b = Self.bridged[base] { return b }
        if let r = Self.renamed[base], typedefs[base] == nil, enumByName[base] == nil { return r }
        if let e = enumByName[base], let n = e.swiftName { return n }
        if typedefs[base] != nil || structNames.contains(base) || enumByName[base] != nil || classNames.contains(base) || protocolNames.contains(base) { return base }
        // CF-style references: `CGEventRef` is `CGEvent` in Swift.
        if base.hasSuffix("Ref"), base.count > 3 {
            let stem = String(base.dropLast(3))
            if options.knownTypes.contains(base), !options.knownTypes.contains(stem) { return base }
            if options.knownTypes.contains(stem) || opaqueNames.contains(stem) || (base.hasPrefix("CF") || base.hasPrefix("CG") || base.hasPrefix("CT") || base.hasPrefix("Sec") || base.hasPrefix("AX") || base.hasPrefix("IO") || base.hasPrefix("CV") || base.hasPrefix("CM")) { return stem }
        }
        return base
    }

    /// Whether `base` names an object or reference type (nullable in C).
    private func isReference(_ t: CType) -> Bool {
        if case .none = t.callable {} else { return true }
        if t.base == "id" || t.base == "Class" || t.base == "SEL" || t.base == "instancetype" || t.base == "CFTypeRef" { return true }
        if t.pointers > 0 { return true }
        if let td = typedefs[t.base] {
            if td.opaqueStruct != nil { return true }
            if td.isTypedEnum { return false }
            return isReference(td.type)
        }
        if ["dispatch_queue_t", "dispatch_block_t", "dispatch_source_t", "dispatch_semaphore_t", "dispatch_group_t", "dispatch_data_t", "xpc_object_t", "xpc_connection_t", "va_list"].contains(t.base) { return t.base != "va_list" }
        if t.base.hasSuffix("Ref"), Self.scalarTypes[t.base] == nil, !structNames.contains(t.base), enumByName[t.base] == nil { return true }
        return false
    }

    private func isObjectPointer(_ t: CType) -> Bool {
        guard t.pointers == 1 else { return false }
        if Self.scalarTypes[t.base] != nil && t.base != "id" { return false }
        if structNames.contains(t.base) || enumByName[t.base] != nil { return false }
        if t.base.hasPrefix("struct ") || t.base.hasPrefix("union ") || t.base.isEmpty { return false }
        if let td = typedefs[t.base] { if td.opaqueStruct != nil || td.isTypedEnum { return false }; return classNames.contains(td.type.base) && td.type.pointers == 0 }
        // A capitalised, non-C name behind one star: an Objective-C object.
        guard let f = t.base.first else { return false }
        if t.base.hasSuffix("_t") { return false }
        if f.isLowercase { return false }
        if t.base.hasSuffix("Ref") { return false }
        // C structs of the SDK passed by pointer.
        if ["CGRect", "CGPoint", "CGSize", "NSRect", "NSPoint", "NSSize", "NSRange", "CGAffineTransform", "CGVector", "CFRange", "AudioObjectPropertyAddress",
            "AudioStreamBasicDescription", "ProcessSerialNumber", "CGEventTapInformation", "CATransform3D", "NSEdgeInsets", "CMTime", "CMTimeRange",
            "AudioBufferList", "FSRef", "AEDesc", "Point", "Rect", "MIDIPacketList", "IOHIDValueScale", "NSDecimal", "NSOperatingSystemVersion",
            "UInt8", "UInt16", "UInt32", "UInt64", "SInt32", "SInt16", "SInt64", "Float32", "Float64", "CGFloat", "NSInteger", "NSUInteger", "BOOL", "Boolean",
            "OSStatus", "OSType", "CGDirectDisplayID", "CGWindowID", "CGSConnectionID", "IOReturn", "AXError", "CGError", "CGEventType", "CGKeyCode", "UniChar",
            "CGGammaValue", "CGDisplayCount", "CGWindowLevel", "IOOptionBits", "CFIndex", "NSTimeInterval", "CFTimeInterval", "AudioObjectID", "AudioDeviceID",
            "CGCharCode", "CGEventFlags", "CGEventTimestamp", "IOHIDFloat", "FILE", "DIR", "ProcessInfoRec", "FourCharCode", "MIDITimeStamp", "Byte"].contains(t.base) { return false }
        return true
    }

    /// The Swift spelling of a C type in a given position. `audited`:
    /// inside NS_ASSUME_NONNULL, where unannotated pointers are nonnull.
    func swiftType(_ t: CType, _ position: Position, audited: Bool, escaping: Bool = true) -> String {
        func optional(_ s: String, wrap: Bool = false) -> String {
            let inner = wrap || s.contains("->") || s.hasPrefix("any ") || s.hasPrefix("@") ? "(\(s))" : s
            switch t.nullability {
            case .nullable?: return inner + "?"
            case .nonnull?: return s
            default:
                if audited && t.nullability == nil { return s }
                return position == .generic || position == .typealiasTarget ? inner + "?" : inner + "!"
            }
        }
        // Blocks and function pointers.
        switch t.callable {
        case .block(let r, let ps), .function(let r, let ps):
            let params = ps.map { swiftType($0, .parameter, audited: audited, escaping: false).replacingOccurrences(of: "@escaping ", with: "") }.joined(separator: ", ")
            let res = r.base == "void" && r.pointers == 0 ? "Void" : swiftType(r, .result, audited: audited)
            // C function pointers too: Runway's API takes Swift closures.
            let closure = "(\(params)) -> \(res)"
            let nonnull = t.nullability == .nonnull || (audited && t.nullability == nil)
            if nonnull { return position == .parameter && escaping ? "@escaping " + closure : closure }
            return "(\(closure))" + (t.nullability == .nullable || position == .generic || position == .typealiasTarget ? "?" : "!")
        case .none: break
        }
        if let n = t.arrayCount, position == .field, n > 0, n <= 32 {
            var el = t
            el.arrayCount = nil
            let e = swiftType(el, .field, audited: audited)
            return "(" + Array(repeating: e, count: n).joined(separator: ", ") + ")"
        }
        var t = t
        if t.arrayCount != nil { t.pointers += 1; t.arrayCount = nil }
        let base = t.base
        // Typed-out collections.
        if t.pointers == 1 {
            let g = t.generics.map { swiftType($0, .generic, audited: true) }
            switch base {
            case "NSArray": return optional("[\(g.first ?? "Any")]")
            case "NSMutableArray" where position != .parameter: return optional("NSMutableArray")
            case "NSDictionary": return optional("[\(g.count == 2 ? hashable(g[0]) : "AnyHashable"): \(g.count == 2 ? g[1] : "Any")]")
            case "NSSet": return optional("Set<\(g.first.map(hashable) ?? "AnyHashable")>")
            case "NSString": return optional("String")
            case "NSError" where t.nullability == nil && position == .parameter: return audited ? "Error" : "Error!"
            case "char": return optional(t.isConst ? "UnsafePointer<CChar>" : "UnsafeMutablePointer<CChar>")
            case "void": return optional(t.isConst ? "UnsafeRawPointer" : "UnsafeMutableRawPointer")
            case "id": return "AutoreleasingUnsafeMutablePointer<AnyObject?>" + (t.nullability == .nonnull ? "" : "!")
            default: break
            }
            if isObjectPointer(t) {
                var name = baseName(base)
                if name == "Self" { return name }
                if base == "NSObject", !t.protocols.isEmpty { name = "NSObject" }
                return optional(name)
            }
        }
        if t.pointers == 0 {
            if base == "id" {
                if !t.protocols.isEmpty {
                    let ps = t.protocols.map(baseName).joined(separator: " & ")
                    return optional("any " + ps, wrap: false)
                }
                switch t.nullability {
                case .nullable?: return "Any?"
                case .nonnull?: return "Any"
                default: return audited ? "Any" : (position == .generic ? "Any" : "Any!")
                }
            }
            if base == "instancetype" { return position == .result ? "Self" : "Self" }
            if base == "Class" { return optional(t.protocols.isEmpty ? "AnyClass" : "AnyClass") }
            if base == "SEL" { return optional("Selector") }
            if base == "void" { return "Void" }
            if let td = typedefs[base], td.opaqueStruct != nil { return optional(baseName(base)) }
            if isReference(t) { return optional(baseName(base)) }
            return baseName(base)
        }
        // Pointers to non-objects.
        var pointee = t
        pointee.pointers -= 1
        pointee.nullability = nil
        pointee.isConst = false
        if t.pointers == 2, isObjectPointer(pointee) || pointee.base == "id" {
            // `NSError **`, `NSString **`: out-parameters for objects.
            // Nothing bridges inside a pointer: `NSString **` points at `NSString?`.
            let name = pointee.base == "id" ? "AnyObject?" : (classNames.contains(pointee.base) || options.knownTypes.contains(pointee.base) || pointee.base.hasPrefix("NS") ? pointee.base : baseName(pointee.base)) + "?"
            return "AutoreleasingUnsafeMutablePointer<\(name)>" + optionalSuffix(t, position, audited)
        }
        let isOpaque = base.hasPrefix("struct ") || base.hasPrefix("union ") || base.isEmpty
            || (t.pointers == 1 && Self.scalarTypes[base] == nil && !structNames.contains(base) && enumByName[base] == nil && typedefs[base] == nil
                && !options.knownTypes.contains(base) && (base.first?.isLowercase ?? true))
        if isOpaque { return optional("OpaquePointer") }
        var inner: String
        if pointee.pointers == 0, isReference(pointee) {
            // `CFTypeRef *`, `CGImageRef *`: out-parameters for references.
            var p2 = pointee
            p2.nullability = .nullable
            inner = swiftType(p2, .generic, audited: true)
            if case .none = pointee.callable, !(typedefs[pointee.base]?.opaqueStruct == nil && pointee.pointers == 0 && pointee.base.hasSuffix("Ref") == false && false) {
                if pointee.base != "CFTypeRef" && pointee.base != "id" { inner = "Unmanaged<\(inner.dropLast())>?" }
                else { inner = "Unmanaged<AnyObject>?" }
            }
        } else {
            inner = swiftType(pointee, .generic, audited: true)
        }
        return optional((t.isConst ? "UnsafePointer<" : "UnsafeMutablePointer<") + inner + ">")
    }

    private func hashable(_ s: String) -> String { s == "Any" ? "AnyHashable" : s }

    private func optionalSuffix(_ t: CType, _ position: Position, _ audited: Bool) -> String {
        switch t.nullability {
        case .nullable?: return "?"
        case .nonnull?: return ""
        default: return audited ? "" : (position == .generic || position == .typealiasTarget ? "?" : "!")
        }
    }

    /// A value for a stand-in to return or hold.
    func defaultValue(_ t: CType, swift: String) -> String? {
        if swift == "Void" { return "" }
        if swift.hasSuffix("?") { return "nil" }
        if swift.hasSuffix("!") {
            // Unaudited results: callers use them unwrapped, so an empty value beats nil.
            let inner = String(swift.dropLast())
            if inner == "String" { return "\"\"" }
            if inner.hasPrefix("[") { return defaultValue(t, swift: inner) }
            if inner.hasPrefix("Set<") { return "[]" }
            if inner == "Data" { return "Data()" }
            return "nil"
        }
        if swift.hasPrefix("[") { return swift.contains(":") && !swift.hasPrefix("[[") && swift.dropFirst().split(separator: ":").count == 2 && bracketDepthZeroColon(swift) ? "[:]" : "[]" }
        if swift.hasPrefix("Set<") { return "[]" }
        if swift == "Self" { return nil }
        switch swift {
        case "Bool": return "false"
        case "String": return "\"\""
        case "Any": return "NSNull()"
        case "Data": return "Data()"
        case "Date": return "Date()"
        case "URL": return "URL(fileURLWithPath: \"/\")"
        case "UUID": return "UUID()"
        case "Error": return "NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)"
        case "AXError", "CGError": return ".failure"
        case "IOReturn", "kern_return_t": return "-536870212"  // kIOReturnError
        case "OSStatus": return "-50"  // paramErr
        case "CGFloat", "Double", "Float", "TimeInterval", "CFTimeInterval", "CFAbsoluteTime", "IOHIDFloat": return "0"
        case "CGRect", "NSRect", "CGPoint", "NSPoint", "CGSize", "NSSize", "CGVector": return ".zero"
        case "NSRange": return "NSRange(location: NSNotFound, length: 0)"
        case "CGAffineTransform": return ".identity"
        case "AnyClass": return "NSObject.self"
        case "Selector": return "Selector(\"\")"
        case "IndexPath": return "IndexPath()"
        case "IndexSet": return "IndexSet()"
        case "ComparisonResult": return ".orderedSame"
        case "Notification.Name": return "Notification.Name(\"\")"
        case "DispatchQueue": return ".main"
        default: break
        }
        if swift.contains("->") { return nil }
        if swift.hasPrefix("(") { // a tuple (fixed array)
            let n = swift.dropFirst().dropLast().split(separator: ",").count
            var el = t
            el.arrayCount = nil
            guard let d = defaultValue(el, swift: swiftType(el, .field, audited: true)) else { return nil }
            return "(" + Array(repeating: d, count: n).joined(separator: ", ") + ")"
        }
        if let e = enumByName[t.base] ?? enumByName.values.first(where: { $0.swiftName == swift }) {
            switch e.style {
            case .nsOptions: return "[]"
            case .nsEnum:
                let names = caseNames(e)
                if let zero = e.cases.firstIndex(where: { $0.value == 0 }) { return "." + names[zero] }
                return names.first.map { "." + $0 }
            default: return "\(swift)(0)"
            }
        }
        if let td = typedefs[t.base], td.isTypedEnum { return "\(swift)(rawValue: \(defaultValue(td.type, swift: swiftType(td.type, .field, audited: true)) ?? "\"\""))" }
        if let r = resolvedTypedef(t.base), t.pointers == 0 {
            return defaultValue(r, swift: swiftType(r, .result, audited: true))
        }
        if structNames.contains(t.base) { return "\(swift)()" }
        if isScalar(swift) { return "0" }
        if swift.contains("Pointer") { return nil }
        // A C value type of the SDK (an enum, an option set, a struct): zeroed.
        if t.pointers == 0, !isReference(t), !classNames.contains(t.base) { return "RunwayObjC.zeroed()" }
        // A class (the header's or a framework's): a fresh object.
        return "\(swift)()"
    }

    private func bracketDepthZeroColon(_ s: String) -> Bool {
        var depth = 0
        for c in s {
            if c == "[" || c == "<" || c == "(" { depth += 1 } else if c == "]" || c == ">" || c == ")" { depth -= 1 }
            if c == ":", depth == 1 { return true }
        }
        return false
    }

    private func isScalar(_ swift: String) -> Bool {
        ["Int", "UInt", "Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64", "CChar", "unichar", "pid_t", "uid_t", "gid_t",
         "time_t", "mach_port_t", "OSType", "FourCharCode", "mode_t", "dev_t", "CGDirectDisplayID", "CGWindowID", "io_service_t", "io_object_t",
         "io_connect_t", "io_iterator_t", "io_registry_entry_t", "CGKeyCode", "CGWindowLevel", "IOOptionBits", "CGCharCode", "UniChar",
         "AudioObjectID", "AudioDeviceID", "CGSConnectionID", "CGEventTimestamp", "task_t", "natural_t", "integer_t", "boolean_t", "CGDisplayCount",
         "IOHIDEventType", "IOHIDEventField", "CGSSpaceID", "CGSWindowID", "CFOptionFlags", "CFHashCode", "CFTypeID", "NSEventSubtype_", "LSSharedFileListItemID_",
         "mach_msg_type_number_t", "vm_address_t", "vm_size_t", "CGGammaValue", "host_t", "thread_t", "processor_t", "clock_serv_t"].contains(swift)
    }

    // MARK: Names

    /// Swift's names for an NS_ENUM's cases: the prefix every case shares
    /// (whole words, usually the enum's name) goes, the rest is lowerCamel.
    func caseNames(_ e: CEnum) -> [String] {
        let all = e.cases.map { camelWords($0.name) }
        guard !all.isEmpty else { return [] }
        var prefix = all.count == 1 ? commonPrefix(all[0], camelWords(e.name)) : all[0]
        for w in all.dropFirst() { prefix = commonPrefix(prefix, w) }
        // The enum's name bounds it when cases share more by accident… and
        // every case keeps at least one word.
        var n = prefix.count
        while n > 0, all.contains(where: { $0.count <= n || ($0[n].first?.isNumber ?? false) }) { n -= 1 }
        return all.map { words in
            var rest = Array(words[n...])
            while rest.first == "_" { rest.removeFirst() }
            let joined = rest.filter { $0 != "_" }.joined()
            return escaped(lowerCamel(joined))
        }
    }

    private func commonPrefix(_ a: [String], _ b: [String]) -> [String] {
        var out: [String] = []
        for (x, y) in zip(a, b) { if x == y { out.append(x) } else { break } }
        return out
    }

    /// Whether the last words of a label name the parameter's type
    /// (`atIndex:(NSUInteger)`, `withString:(NSString *)`), which Swift omits.
    private func typeWords(_ t: CType) -> [[String]] {
        var names: [String] = []
        let base = t.base
        switch base {
        case "NSInteger", "NSUInteger", "int", "unsigned int", "long", "unsigned long", "NSNumber": names += ["Index", "Integer", "Int", "Number"]
        case "BOOL", "bool": names += ["Bool", "Boolean"]
        case "SEL": names += ["Selector"]
        case "Class": names += ["Class"]
        case "id": names += ["Object"]
        case "CGFloat", "double", "float": names += ["Float", "Double"]
        case "NSArray", "NSMutableArray": names += ["Array"] + (t.generics.first.map { g in typeWords(g).map { $0.joined() + "s" } } ?? ["Objects"])
        case "NSDictionary", "NSMutableDictionary": names += ["Dictionary"]
        case "NSSet", "NSMutableSet": names += ["Set"]
        default: break
        }
        var stem = base
        for p in ["NS", "CF", "CG", "UI", "CA", "AV", "CI", "CL", "MK", "SK", "WK", "AX", "IO", "CT", "CM", "CV"] where stem.hasPrefix(p) && stem.count > p.count + 1 && stem.dropFirst(p.count).first!.isUppercase {
            stem = String(stem.dropFirst(p.count))
            break
        }
        if stem.hasSuffix("Ref") { stem = String(stem.dropLast(3)) }
        if stem.hasPrefix("Mutable") { names.append(String(stem.dropFirst(7))) }
        names.append(stem)
        // The header's own prefix: `MASShortcut` also answers to `Shortcut`.
        let words = camelWords(stem)
        if words.count > 1 { for k in 1..<words.count { names.append(words[k...].joined()) } }
        return names.filter { !$0.isEmpty }.map(camelWords)
    }

    /// Drops trailing words of `words` that restate the parameter's type
    /// (never down to nothing, a keyword or a bare `is`/`get`/`set`).
    private func pruned(_ words: [String], for t: CType, keepAtLeast: Int) -> [String] {
        for name in typeWords(t).sorted(by: { $0.count > $1.count }) {
            guard words.count >= name.count + keepAtLeast, !name.isEmpty else { continue }
            if Array(words.suffix(name.count)).map({ $0.lowercased() }) == name.map({ $0.lowercased() }) {
                let rest = Array(words.dropLast(name.count))
                let joined = rest.joined()
                if swiftKeywords.contains(joined) || ["is", "get", "set", "has", "with", "should", "can", "will", "did", "does"].contains(joined) { continue }
                return rest
            }
        }
        return words
    }

    struct SwiftSignature {
        var isInit = false
        var name: String
        var labels: [String]  // "_" for none
    }

    /// The Swift name of a method, as the Clang importer derives it.
    func swiftSignature(_ m: ObjCMethod, in container: ObjCContainer) -> SwiftSignature {
        if let explicit = m.swiftName, let open = explicit.firstIndex(of: "(") {
            let name = String(explicit[..<open])
            let labels = explicit[explicit.index(after: open)...].dropLast().split(separator: ":").map(String.init)
            return SwiftSignature(isInit: name == "init", name: name, labels: labels)
        }
        if let explicit = m.swiftName { return SwiftSignature(name: explicit, labels: []) }
        let params = m.pieces.compactMap(\.param)
        let first = m.pieces[0].label
        var labels = m.pieces.dropFirst().map { $0.label.isEmpty ? "_" : $0.label }
        // Initializers.
        if !m.isClass, first.hasPrefix("init"), first.count == 4 || first.dropFirst(4).first!.isUppercase {
            var firstLabel = String(first.dropFirst(4))
            if firstLabel.hasPrefix("With"), firstLabel.count > 4 { firstLabel = String(firstLabel.dropFirst(4)) }
            if params.isEmpty { return SwiftSignature(isInit: true, name: "init", labels: firstLabel.isEmpty ? [] : [lowerCamel(firstLabel)]) }
            var words = camelWords(firstLabel)
            if !words.isEmpty { words = pruned(words, for: params[0].type, keepAtLeast: 1) }
            return SwiftSignature(isInit: true, name: "init", labels: [words.isEmpty ? "_" : lowerCamel(words.joined())] + labels.enumerated().map { i, l in pruneLabel(l, params[i + 1].type) })
        }
        // Class factory methods: `+ (instancetype)shortcutWithKeyCode:…` on MASShortcut.
        if m.isClass, !params.isEmpty, m.result.base == "instancetype" || m.result.base == container.name {
            let words = camelWords(first)
            if let with = words.firstIndex(of: "With"), with > 0, with + 1 < words.count {
                let head = words[..<with].joined().lowercased()
                let cls = camelWords(container.name).map { $0.lowercased() }
                let suffixes = (0..<cls.count).map { cls[$0...].joined() }
                if suffixes.contains(head) {
                    let w = pruned(Array(words[(with + 1)...]), for: params[0].type, keepAtLeast: 1)
                    return SwiftSignature(isInit: true, name: "init", labels: [lowerCamel(w.joined())] + labels.enumerated().map { i, l in pruneLabel(l, params[i + 1].type) })
                }
            }
        }
        guard !params.isEmpty else {
            // `+sharedMonitor` on MASShortcutMonitor is `shared()`: a result's type isn't restated.
            if m.result.base == "instancetype" || m.result.base == container.name {
                var result = CType(base: container.name)
                result.pointers = 1
                let words = pruned(camelWords(first), for: result, keepAtLeast: 1)
                if words.count < camelWords(first).count, !first.hasPrefix("init"), !first.hasPrefix("new"), !first.hasPrefix("copy") { return SwiftSignature(name: words.joined(), labels: []) }
            }
            return SwiftSignature(name: first, labels: [])
        }
        // The first piece: its last preposition starts the first argument label.
        var words = camelWords(first)
        var firstLabel: [String] = []
        if let k = words.indices.dropFirst().last(where: { prepositions.contains(words[$0]) }) {
            // `With` right after the verb's object stays unless something follows it.
            firstLabel = Array(words[k...])
            words = Array(words[..<k])
            firstLabel = pruned(firstLabel, for: params[0].type, keepAtLeast: 1)
        } else {
            words = pruned(words, for: params[0].type, keepAtLeast: 1)
        }
        labels = labels.enumerated().map { i, l in pruneLabel(l, params[i + 1].type) }
        return SwiftSignature(name: words.joined(), labels: [firstLabel.isEmpty ? "_" : lowerCamel(firstLabel.joined())] + labels)
    }

    private func pruneLabel(_ label: String, _ t: CType) -> String {
        guard label != "_" else { return label }
        let words = camelWords(label)
        // `atIndex:` → `at:`, `alreadyTakenInMenu:` → `alreadyTakenIn:`: the
        // type's name goes when a preposition is left to end the label.
        guard words.count > 1 else { return label }
        let rest = pruned(words, for: t, keepAtLeast: 1)
        guard rest.count < words.count, let last = rest.last.map({ $0.prefix(1).uppercased() + $0.dropFirst() }), prepositions.contains(last) else { return label }
        return rest.joined()
    }

    // MARK: Emitting

    private mutating func emit(_ s: String = "") { lines.append(s) }

    public mutating func source() -> String {
        emit("// Generated by runway: Swift stand-ins for Objective-C/C declarations\(options.origin.isEmpty ? "" : " (" + options.origin + ")").")
        emit("// The implementations can't be built on this platform; these keep the API and report the feature unavailable.")
        emit("import Foundation")
        for i in options.imports where i != "Foundation" { emit("\(options.reexportImports ? "@_exported " : "")import \(i)") }
        emit()
        emitOpaqueTypes()
        emitTypedefs()
        emitEnums()
        emitStructs()
        emitConstants()
        emitProtocols()
        emitClasses()
        emitFunctions()
        return lines.joined(separator: "\n") + "\n"
    }

    private mutating func emitOpaqueTypes() {
        var declared = Set<String>()
        for td in model.typedefs where td.opaqueStruct != nil {
            let name = td.name
            let stem = name.hasSuffix("Ref") && name.count > 3 ? String(name.dropLast(3)) : name
            if options.knownTypes.contains(stem) || options.knownTypes.contains(name) || !declared.insert(stem).inserted { continue }
            opaqueNames.insert(stem)
            emit("\(access)final class \(stem): Hashable, @unchecked Sendable {")
            emit("    \(access)init() {}")
            emit("    \(access)static func == (a: \(stem), b: \(stem)) -> Bool { a === b }")
            emit("    \(access)func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }")
            emit("}")
            if stem != name { emit("\(access)typealias \(name) = \(stem)") }
        }
        // Classes named only by `@class`: something to hold a reference to.
        for name in model.forwardClasses where !classNames.contains(name) && !options.knownTypes.contains(name) && Self.bridged[name] == nil && declared.insert(name).inserted {
            classNames.insert(name)
            emit("\(classAccess)class \(name): NSObject {}")
        }
        for name in model.forwardProtocols where !protocolNames.contains(name) && !options.knownTypes.contains(name) && declared.insert(name).inserted {
            protocolNames.insert(name)
            emit("\(access)protocol \(name): AnyObject {}")
        }
        if !declared.isEmpty { emit() }
    }

    private mutating func emitTypedefs() {
        var any = false
        for td in model.typedefs where td.opaqueStruct == nil {
            if options.knownTypes.contains(td.name) || structNames.contains(td.name) || enumByName[td.name] != nil || classNames.contains(td.name) { continue }
            if td.type.base == td.name { continue }
            if Self.scalarTypes[td.name] != nil || Self.bridged[td.name] != nil { continue }
            if td.isTypedEnum {
                let raw = swiftType(td.type, .typealiasTarget, audited: true)
                emit("\(access)struct \(td.name): RawRepresentable, Hashable, @unchecked Sendable {")
                emit("    \(access)var rawValue: \(raw)")
                emit("    \(access)init(rawValue: \(raw)) { self.rawValue = rawValue }")
                emit("    \(access)init(_ rawValue: \(raw)) { self.rawValue = rawValue }")
                emit("}")
            } else {
                var target = swiftType(td.type, .typealiasTarget, audited: true)
                if target.hasSuffix("?"), isReference(td.type), !target.contains("->") { target.removeLast() }
                if target == td.name { continue }
                emit("\(access)typealias \(td.name) = \(target)")
            }
            any = true
        }
        if any { emit() }
    }

    private func intType(_ underlying: String) -> String {
        let u = underlying.replacingOccurrences(of: "const ", with: "")
        if let s = Self.scalarTypes[u] { return s }
        if let r = resolvedTypedef(u) { return intType(r.base) }
        return u.isEmpty ? "Int32" : u
    }

    private func literal(_ v: Int64, type: String) -> String {
        if type.hasPrefix("U"), v < 0 { return "\(type)(bitPattern: \(v))" .replacingOccurrences(of: "UInt(bitPattern", with: "UInt(bitPattern") }
        if type == "UInt32", v > Int64(UInt32.max) { return "\(v & 0xffff_ffff)" }
        if type == "Int32", v > Int64(Int32.max) { return "Int32(bitPattern: \(UInt32(truncatingIfNeeded: v)))" }
        return "\(v)"
    }

    private mutating func emitEnums() {
        for e in model.enums {
            switch e.style {
            case .anonymous:
                // Constants of the underlying type (Int for a plain `enum {}`).
                let ty = e.underlying == "int" || e.underlying.isEmpty ? "Int" : intType(e.underlying)
                for c in e.cases where !options.knownValues.contains(c.name) {
                    emit("\(access)let \(escaped(c.name)): \(ty) = \(literal(c.value ?? 0, type: ty))")
                }
            case .plain:
                if options.knownTypes.contains(e.name) { continue }
                let raw = e.underlying == "int" || e.underlying.isEmpty ? (e.cases.contains { ($0.value ?? 0) < 0 } ? "Int32" : "UInt32") : intType(e.underlying)
                emit("\(access)struct \(e.name): RawRepresentable, Hashable, Sendable {")
                emit("    \(access)var rawValue: \(raw)")
                emit("    \(access)init(_ rawValue: \(raw)) { self.rawValue = rawValue }")
                emit("    \(access)init(rawValue: \(raw)) { self.rawValue = rawValue }")
                emit("}")
                for c in e.cases { emit("\(access)let \(escaped(c.name)) = \(e.name)(\(literal(c.value ?? 0, type: raw)))") }
            case .nsEnum:
                let name = e.swiftName ?? e.name
                if options.knownTypes.contains(name) { continue }
                let raw = intType(e.underlying)
                let names = caseNames(e)
                emit("\(access)enum \(name): \(raw), Hashable, Sendable {")
                var seenValues = Set<Int64>(), seenNames = Set<String>()
                var aliases: [String] = []
                for (i, c) in e.cases.enumerated() {
                    guard seenNames.insert(names[i]).inserted else { continue }
                    if seenValues.insert(c.value ?? 0).inserted {
                        emit("    case \(names[i]) = \(c.value ?? 0)")
                    } else if let first = e.cases.firstIndex(where: { $0.value == c.value }) {
                        aliases.append("    \(access)static var \(names[i]): \(name) { .\(names[first]) }")
                    }
                }
                for a in aliases { emit(a) }
                emit("}")
            case .nsOptions:
                let name = e.swiftName ?? e.name
                if options.knownTypes.contains(name) { continue }
                let raw = intType(e.underlying)
                let names = caseNames(e)
                emit("\(access)struct \(name): OptionSet, Hashable, Sendable {")
                emit("    \(access)var rawValue: \(raw)")
                emit("    \(access)init(rawValue: \(raw)) { self.rawValue = rawValue }")
                var seen = Set<String>()
                for (i, c) in e.cases.enumerated() where (c.value ?? 0) != 0 && seen.insert(names[i]).inserted {
                    emit("    \(access)static let \(names[i]) = \(name)(rawValue: \(literal(c.value ?? 0, type: raw)))")
                }
                emit("}")
            }
            emit()
        }
    }

    private mutating func emitStructs() {
        for s in model.structs where !options.knownTypes.contains(s.name) {
            emit("\(access)struct \(s.name) {")
            var inits: [(String, String, String)] = []
            for f in s.fields {
                let ty = swiftType(f.type, .field, audited: false)
                let dv = defaultValue(f.type, swift: ty) ?? "nil"
                emit("    \(access)var \(escaped(f.name)): \(ty) = \(dv)")
                inits.append((f.name, ty, dv))
            }
            emit("    \(access)init() {}")
            if !inits.isEmpty, inits.count <= 16 {
                let params = inits.map { "\(escaped($0.0)): \($0.1.hasSuffix("!") ? String($0.1.dropLast()) + "?" : $0.1)" }.joined(separator: ", ")
                emit("    \(access)init(\(params)) { " + inits.map { "self.\(escaped($0.0)) = \(escaped($0.0))" }.joined(separator: "; ") + " }")
            }
            emit("}")
            emit()
        }
    }

    /// A C initializer as a Swift expression, when it's simple enough.
    private func constantExpression(_ tokens: [String], type: String) -> String? {
        if tokens.count == 1, let s = tokens.first {
            if s.hasPrefix("@\"") { return String(s.dropFirst()) }
            if s.hasPrefix("\"") { return s }
            if let f = s.first, f.isNumber, s.contains(".") || (s.lowercased().hasSuffix("f") && !s.lowercased().hasPrefix("0x")) {
                return s.trimmingCharacters(in: CharacterSet(charactersIn: "fFlL"))
            }
        }
        if tokens.count == 2, tokens[0] == "-", let f = tokens[1].first, f.isNumber, tokens[1].contains(".") {
            return "-" + tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: "fFlL"))
        }
        // `CFSTR("x")`
        if tokens.count == 4, tokens[0] == "CFSTR", tokens[2].hasPrefix("\"") { return tokens[2] + (type == "String" ? "" : " as CFString") }
        return nil
    }

    private mutating func emitConstants() {
        var any = false
        var emitted = Set<String>()
        for e in model.enums { for c in e.cases { emitted.insert(c.name) } }
        for v in model.variables where !options.knownValues.contains(v.name) && emitted.insert(v.name).inserted {
            var ty = swiftType(v.type, .result, audited: true)
            if ty.hasSuffix("!") { ty = String(ty.dropLast()) }
            var value: String?
            if let tokens = v.value {
                value = constantExpression(tokens, type: ty)
                if value == nil, let n = constants[v.name] {
                    value = ["Double", "Float", "CGFloat", "TimeInterval"].contains(ty) || isScalar(ty) || resolvedTypedef(v.type.base).map({ Self.scalarTypes[$0.base] != nil }) == true
                        ? literal(n, type: ty) : nil
                    if value == nil, let e = enumByName[v.type.base], e.style == .plain { value = "\(ty)(\(n))" }
                    if value == nil, ty == "Bool" { value = n != 0 ? "true" : "false" }
                }
            } else if ty == "String" {
                value = lit(v.name)  // an exported key or notification name: its own name
            } else if let td = typedefs[v.type.base], td.isTypedEnum {
                value = "\(ty)(rawValue: \(lit(v.name)))"
            } else if ty == "Notification.Name" {
                value = "Notification.Name(\(lit(v.name)))"
            }
            guard let val = value ?? defaultValue(v.type, swift: ty) else {
                if ty.contains("Pointer") { emit("\(access)let \(escaped(v.name)): \(ty)? = nil"); any = true }
                continue
            }
            emit("\(access)\(v.type.isConst || v.value != nil ? "let" : "nonisolated(unsafe) var") \(escaped(v.name)): \(ty) = \(val)")
            any = true
        }
        // `#define`d numbers and strings.
        for m in model.macros where m.params == nil && !m.body.isEmpty && !options.knownValues.contains(m.name) && !emitted.contains(m.name) {
            if m.name.hasPrefix("_") || m.name.hasSuffix("_h") || m.name.hasSuffix("_H") || m.name.hasSuffix("_H_") { continue }
            if let s = constantExpression(m.body, type: "String") {
                let isString = s.hasPrefix("\"")
                emit("\(access)let \(escaped(m.name))\(isString ? ": String" : ": Double") = \(s)")
                emitted.insert(m.name)
                any = true
            } else if let n = constants[m.name], m.body.allSatisfy({ !$0.hasPrefix("\"") }) {
                // Swift imports integer macros as Int32 (or wider when they don't fit).
                let unsigned = m.body.contains { $0.first!.isNumber && $0.lowercased().hasSuffix("u") || $0.lowercased().hasSuffix("ul") && $0.first!.isNumber }
                let ty = unsigned ? (n > Int64(UInt32.max) ? "UInt64" : "UInt32") : (n > Int64(Int32.max) || n < Int64(Int32.min) ? "Int64" : "Int32")
                emit("\(access)let \(escaped(m.name)): \(ty) = \(n)")
                emitted.insert(m.name)
                any = true
            }
        }
        if any { emit() }
    }

    private func throwsConversion(_ m: ObjCMethod) -> Bool {
        guard let last = m.pieces.last?.param, last.type.base == "NSError", last.type.pointers == 2 else { return false }
        let l = m.pieces.last!.label.lowercased()
        return l == "error" || l.hasSuffix("error") || m.pieces.count == 1
    }

    private struct RenderedMethod {
        var decl: String      // `func foo(_ a: Int) -> Bool`
        var body: String      // statements
        var isInit: Bool
        var key: String       // for de-duplication
    }

    private func render(_ m: ObjCMethod, in c: ObjCContainer, forProtocol: Bool) -> RenderedMethod? {
        var m = m
        var sig = swiftSignature(m, in: c)
        var doesThrow = false
        if throwsConversion(m), m.swiftName == nil {
            doesThrow = true
            m.pieces.removeLast()
            if m.pieces.isEmpty {
                // `- (BOOL)save:(NSError **)error` → `save() throws`
                var name = sig.name
                for suffix in ["AndReturnError", "WithError", "ReturnError"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
                sig.name = name
                sig.labels = []
                m.pieces = [(label: name, param: nil)]
            } else {
                sig.labels.removeLast()
            }
        }
        let params = m.pieces.compactMap(\.param)
        guard sig.labels.count == params.count || params.isEmpty else { return nil }
        var parts: [String] = []
        var seen = Set<String>()
        for (i, p) in params.enumerated() {
            let label = sig.labels[i]
            var name = p.name
            if !seen.insert(name).inserted { name += "\(i)" }
            let ty = swiftType(p.type, .parameter, audited: m.audited)
            parts.append(label == name ? "\(escaped(label)): \(ty)" : "\(label == "_" ? "_" : escaped(label)) \(escaped(name) == name ? name : "`\(name)`"): \(ty)")
        }
        if sig.isInit {
            let failable = m.audited && m.result.nullability != .nullable ? "" : (m.result.nullability == .nullable ? "?" : "!")
            let decl = "convenience init\(doesThrow ? "" : failable)(\(parts.joined(separator: ", ")))\(doesThrow ? " throws" : "")"
            return RenderedMethod(decl: decl, body: "self.init()", isInit: true, key: "init(" + sig.labels.joined(separator: ":") + ")")
        }
        var resType = swiftType(m.result, .result, audited: m.audited)
        if m.result.base == "instancetype" {
            resType = m.isClass ? c.name : "Self"
            if m.isClass { resType += optionalSuffix(m.result, .result, m.audited) }
        }
        if doesThrow {
            if resType == "Bool" { resType = "Void" }
            if resType.hasSuffix("!") || resType.hasSuffix("?") { resType.removeLast() }
        }
        var body = ""
        if doesThrow {
            body = "throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)"
        } else if resType == "Self" {
            body = "return self"
        } else if resType != "Void" {
            if let d = defaultValue(m.result, swift: resType) {
                body = "return \(d)"
            } else if resType.contains("->") {
                return nil
            } else { body = "return \(resType)()" }
            if m.result.base == "instancetype" || resType == c.name || resType == c.name + "!", m.isClass, classNames.contains(c.name), !resType.hasSuffix("?") { body = "return \(c.name)()" }
            // `+ (id)sharedManager`, `+ (instancetype)defaultCenter`: one object.
            if m.isClass, params.isEmpty, c.kind == .interface, classNames.contains(c.name), !forProtocol,
               ["id", "instancetype", c.name].contains(m.result.base), m.result.nullability != .nullable {
                body = "return _runwaySharedInstance"
            }
        }
        let name = escaped(sig.name)
        let prefix = m.isClass ? (forProtocol ? "static " : "class ") : ""
        let discardable = resType != "Void" && !forProtocol ? "@discardableResult " : ""
        let decl = "\(discardable)\(prefix)func \(name)(\(parts.joined(separator: ", ")))\(doesThrow ? " throws" : "")\(resType == "Void" ? "" : " -> \(resType)")"
        return RenderedMethod(decl: decl, body: body, isInit: false, key: (m.isClass ? "+" : "-") + name + "(" + sig.labels.joined(separator: ":") + ")")
    }

    private func propertyName(_ p: ObjCProperty) -> String {
        if let n = p.swiftName { return n }
        if let g = p.getter { return g }
        return p.name
    }

    private func propertyType(_ p: ObjCProperty) -> String {
        var ty = swiftType(p.type, .property, audited: p.audited)
        if ty.hasPrefix("@escaping ") { ty = String(ty.dropFirst(10)) }
        if p.isWeak, !ty.hasSuffix("?"), !ty.hasSuffix("!") { ty += "?" }
        if p.isWeak, ty.hasSuffix("!") { ty = String(ty.dropLast()) + "?" }
        return ty
    }

    private mutating func emitProtocols() {
        for c in model.containers where c.kind == .proto {
            if options.knownTypes.contains(c.name) { continue }
            let parents = c.protocols.filter { protocolNames.contains($0) || $0 == "NSObject" }.map { $0 == "NSObject" ? "NSObjectProtocol" : $0 }
            emit("\(access)protocol \(c.name): \((parents.isEmpty ? ["AnyObject"] : parents).joined(separator: ", ")) {")
            var defaults: [String] = []
            var seen = Set<String>()
            for p in c.properties {
                let ty = propertyType(p)
                let name = escaped(propertyName(p))
                guard seen.insert(name).inserted else { continue }
                emit("    \(p.isClass ? "static " : "")var \(name): \(ty) { get\(p.isReadonly ? "" : " set") }")
                if p.isOptional, let d = defaultValue(p.type, swift: ty) {
                    defaults.append("    \(access)\(p.isClass ? "static " : "")var \(name): \(ty) { get { \(d.isEmpty ? "()" : d) } \(p.isReadonly ? "" : "set {} ")}")
                }
            }
            for m in c.methods {
                guard let r = render(m, in: c, forProtocol: true), !r.isInit, seen.insert(r.key).inserted else { continue }
                emit("    " + r.decl.replacingOccurrences(of: "@discardableResult ", with: ""))
                if m.isOptional { defaults.append("    \(access)\(r.decl.replacingOccurrences(of: "@discardableResult ", with: "")) { \(r.body) }") }
            }
            emit("}")
            if !defaults.isEmpty {
                emit("extension \(c.name) {")
                for d in defaults { emit(d) }
                emit("}")
            }
            emit()
        }
    }

    /// Members a protocol (and its parents) requires, for classes that adopt it.
    private func requirements(of proto: String, visited: inout Set<String>) -> (methods: [ObjCMethod], properties: [ObjCProperty]) {
        guard visited.insert(proto).inserted, let c = model.containers.first(where: { $0.kind == .proto && $0.name == proto }) else { return ([], []) }
        var ms = c.methods.filter { !$0.isOptional }, ps = c.properties.filter { !$0.isOptional }
        for parent in c.protocols {
            let r = requirements(of: parent, visited: &visited)
            ms += r.methods
            ps += r.properties
        }
        return (ms, ps)
    }

    private mutating func emitClasses() {
        // Categories merge into their class when it's declared here.
        var merged: [ObjCContainer] = []
        for c in model.containers where c.kind == .interface {
            if let i = merged.firstIndex(where: { $0.name == c.name }) {
                merged[i].methods += c.methods
                merged[i].properties += c.properties
                merged[i].protocols += c.protocols
            } else { merged.append(c) }
        }
        var extensions: [ObjCContainer] = []
        for c in model.containers where c.kind == .category {
            if let i = merged.firstIndex(where: { $0.name == c.name }) {
                merged[i].methods += c.methods.filter { m in !merged[i].methods.contains { $0.selector == m.selector && $0.isClass == m.isClass } }
                merged[i].properties += c.properties.filter { p in !merged[i].properties.contains { $0.name == p.name } }
                merged[i].protocols += c.protocols
            } else if let i = extensions.firstIndex(where: { $0.name == c.name }) {
                extensions[i].methods += c.methods
                extensions[i].properties += c.properties
            } else { extensions.append(c) }
        }
        // Superclasses first.
        var ordered: [ObjCContainer] = []
        var pending = merged
        while !pending.isEmpty {
            let names = Set(pending.map(\.name))
            let ready = pending.filter { c in c.superclass.map { !names.contains($0) || $0 == c.name } ?? true }
            if ready.isEmpty { ordered += pending; break }
            ordered += ready
            pending.removeAll { c in ready.contains { $0.name == c.name } }
        }
        for c in ordered where !options.knownTypes.contains(c.name) {
            let superName = c.superclass.map { classNames.contains($0) ? $0 : baseName($0) } ?? "NSObject"
            let adopted = c.protocols.reduce(into: [String]()) { if protocolNames.contains($1), !$0.contains($1) { $0.append($1) } }
            emit("\(classAccess)class \(c.name): \(([superName] + adopted).joined(separator: ", ")) {")
            var seen = Set<String>()
            var props = c.properties, methods = c.methods
            var visited = Set<String>()
            for proto in adopted {
                let r = requirements(of: proto, visited: &visited)
                props += r.properties.filter { p in !props.contains { $0.name == p.name } }
                for m in r.methods {
                    // A method the class redeclares takes the protocol's types
                    // (Objective-C lets them differ; Swift's witness must match).
                    if let i = methods.firstIndex(where: { $0.selector == m.selector && $0.isClass == m.isClass }) { methods[i] = m } else { methods.append(m) }
                }
            }
            // Optional requirements the class declares must match too.
            for proto in adopted {
                guard let pc = model.containers.first(where: { $0.kind == .proto && $0.name == proto }) else { continue }
                for m in pc.methods where m.isOptional {
                    if let i = methods.firstIndex(where: { $0.selector == m.selector && $0.isClass == m.isClass }) {
                        var replacement = m
                        replacement.isOptional = false
                        methods[i] = replacement
                    }
                }
            }
            // Getter-style methods a property already declares.
            for p in props {
                let ty = propertyType(p)
                let name = escaped(propertyName(p))
                guard seen.insert((p.isClass ? "+" : "-") + name + "()").inserted else { continue }
                seen.insert((p.isClass ? "+" : "-") + "set" + p.name.prefix(1).uppercased() + p.name.dropFirst() + "(_)")
                let override = inheritsMember(named: propertyName(p), from: c) ? "override " : ""
                if p.isClass {
                    guard let d = defaultValue(p.type, swift: ty) ?? (ty.contains("->") ? Optional("nil") : nil) else { continue }
                    let t2 = ty.contains("->") && !ty.hasSuffix("?") && !ty.hasSuffix("!") ? "(\(ty))?" : ty
                    emit("    \(classAccess)\(override)class var \(name): \(t2) { get { \(d == "\(c.name)()" ? "_runwayShared" : d) } \(p.isReadonly ? "" : "set {} ")}")
                    if d == "\(c.name)()" { emit("    nonisolated(unsafe) private static let _runwayShared = \(c.name)()") }
                } else if !override.isEmpty {
                    guard let d = defaultValue(p.type, swift: ty) else { continue }
                    emit("    \(classAccess)override var \(name): \(ty) { get { \(d) } \(p.isReadonly ? "" : "set {} ")}")
                } else if p.isReadonly, let d = defaultValue(p.type, swift: ty), d != "\(ty)()" || structNames.contains(p.type.base) {
                    // Read-only: computed, so subclasses can override the getter.
                    emit("    \(classAccess)var \(name): \(ty) { \(d) }")
                } else if ty.contains("->"), !ty.hasSuffix("?"), !ty.hasSuffix("!") {
                    emit("    \(classAccess)var \(name): (\(ty))! = nil")
                } else if let d = defaultValue(p.type, swift: ty), d != "\(ty)()" || structNames.contains(p.type.base) {
                    emit("    \(classAccess)\(p.isWeak ? "weak " : "")var \(name): \(ty)\(d == "nil" ? "" : " = \(d)")")
                } else {
                    // An object with no obvious default: implicitly unwrapped, nil until set.
                    emit("    \(classAccess)var \(name): \(ty)! = nil")
                }
            }
            var needsShared = false
            for m in methods {
                guard let r = render(m, in: c, forProtocol: false), seen.insert(r.key).inserted else { continue }
                if r.isInit, m.pieces.compactMap(\.param).isEmpty, r.key == "init()" { continue }  // inherited
                if r.body.contains("_runwaySharedInstance") { needsShared = true }
                // Explicit accessors of a declared property.
                if m.pieces.count == 1, m.pieces[0].param != nil, m.pieces[0].label.hasPrefix("set"), seen.contains((m.isClass ? "+" : "-") + m.pieces[0].label + "(_)") { continue }
                emit("    " + attributed(r.decl, classAccess) + " { \(r.body) }")
            }
            if needsShared { emit("    nonisolated(unsafe) private static let _runwaySharedInstance = \(c.name)()") }
            emit("}")
            emit()
        }
        for c in extensions {
            let target = Self.bridged[c.name] ?? c.name
            guard target != "Error" else { continue }
            emit("extension \(target) {")
            var seen = Set<String>()
            let isValueType = Self.bridged[c.name] != nil && !target.hasPrefix("NS") && ["String", "Data", "Date", "URL", "UUID", "IndexPath", "IndexSet", "Locale", "TimeZone", "Calendar", "DateComponents", "CharacterSet", "URLRequest", "URLComponents", "Notification", "URLQueryItem", "AffineTransform", "DateInterval", "PersonNameComponents", "Measurement"].contains(target)
            for p in c.properties {
                let ty = propertyType(p)
                let name = escaped(propertyName(p))
                guard seen.insert(name).inserted, let d = defaultValue(p.type, swift: ty) ?? (ty.contains("->") ? Optional("nil") : nil) else { continue }
                let t2 = ty.contains("->") && !ty.hasSuffix("?") && !ty.hasSuffix("!") ? "(\(ty))?" : ty
                emit("    \(access)\(p.isClass ? "static " : "")var \(name): \(t2) { get { \(d) } \(p.isReadonly ? "" : (isValueType ? "nonmutating set {} " : "set {} "))}")
            }
            for m in c.methods {
                guard var r = render(m, in: c, forProtocol: false), seen.insert(r.key).inserted else { continue }
                if r.isInit {
                    if isValueType { r.decl = r.decl.replacingOccurrences(of: "convenience ", with: "") }
                    if m.pieces.compactMap(\.param).isEmpty { continue }
                }
                if isValueType || !target.hasPrefix("NS") && Self.bridged[c.name] != nil { r.decl = r.decl.replacingOccurrences(of: "class func", with: "static func") }
                r.decl = r.decl.replacingOccurrences(of: "class func", with: "static func")
                if r.body == "return self", isValueType { r.body = "return self" }
                emit("    " + attributed(r.decl, access) + " { \(r.body) }")
            }
            emit("}")
            emit()
        }
    }

    /// `@discardableResult` goes before the access modifier.
    private func attributed(_ decl: String, _ access: String) -> String {
        if decl.hasPrefix("convenience init") || decl.hasPrefix("init") { return (access == "open " ? "public " : access) + decl }
        return decl.hasPrefix("@discardableResult ") ? "@discardableResult " + access + decl.dropFirst("@discardableResult ".count) : access + decl
    }

    /// Whether a superclass declared in these headers already has the member.
    private func inheritsMember(named name: String, from c: ObjCContainer) -> Bool {
        var s = c.superclass
        var hops = 0
        while let n = s, hops < 16, let sup = model.containers.first(where: { $0.kind == .interface && $0.name == n }) {
            if sup.properties.contains(where: { propertyName($0) == name }) { return true }
            s = sup.superclass
            hops += 1
        }
        return false
    }

    private mutating func emitFunctions() {
        for f in model.functions where !options.knownValues.contains(f.name) {
            if f.name.hasPrefix("__") { continue }
            var parts: [String] = []
            var seen = Set<String>()
            for (i, p) in f.params.enumerated() {
                var name = p.name
                if !seen.insert(name).inserted { name += "\(i)" }
                parts.append("_ \(escaped(name)): \(swiftType(p.type, .parameter, audited: f.audited))")
            }
            if f.isVariadic { parts.append("_ arguments: CVarArg...") }
            var res = swiftType(f.result, .result, audited: f.audited)
            // A Core Foundation result nothing says how to manage is `Unmanaged`.
            if !f.managedResult, case .none = f.result.callable, f.result.pointers == 0, isReference(f.result),
               f.result.base.hasSuffix("Ref"), !["Any", "Any!", "Any?"].contains(res) {
                var inner = res
                if inner.hasSuffix("!") || inner.hasSuffix("?") { inner.removeLast() }
                if inner == "CFTypeRef" { inner = "AnyObject" }
                res = "Unmanaged<\(inner)>!"
            }
            var body = ""
            if res != "Void" {
                guard let d = defaultValue(f.result, swift: res) ?? (res.contains("->") ? nil : Optional("\(res)()")) else { continue }
                body = "return \(d)"
            }
            if res.hasPrefix("@escaping ") { res = String(res.dropFirst(10)) }
            emit("\(res == "Void" ? "" : "@discardableResult ")\(access)func \(escaped(f.name))(\(parts.joined(separator: ", ")))\(res == "Void" ? "" : " -> \(res)") { \(body) }")
        }
    }
}

/// Swift stand-ins for the declarations in `headers` (in order; later
/// headers see earlier ones' macros and types).
public func objcStandInSource(headers: [String], options: ObjCStandInOptions) -> String {
    var reader = ObjCHeaderReader()
    for h in headers { reader.read(h) }
    var writer = ObjCStandInWriter(model: reader.model, constants: reader.knownConstants, options: options)
    return writer.source()
}
