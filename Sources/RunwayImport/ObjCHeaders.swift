// Objective-C and C headers, read into a small declaration model.
//
// Swift on Linux can't import Objective-C, and C headers that include
// Apple's SDK can't be compiled there either. Runway reads such headers
// itself (bridging headers, framework umbrella headers, the public headers
// of Objective-C package targets) and writes Swift stand-ins with the names
// Swift's importer would give the declarations (ObjCStandIns.swift): the
// app's Swift then compiles against the same API, and the code behind it
// reports the feature unavailable.
//
// This is a tolerant reader, not a C compiler: comments and attributes are
// dropped, conditionals are decided with what a 64-bit macOS Objective-C
// build defines, and a declaration it can't read is skipped.

import Foundation

// MARK: Model

public struct CType: Equatable {
    public enum Nullability: Equatable { case nonnull, nullable, unspecified }
    /// The spelled base type: `NSString`, `unsigned long`, `id`, `struct foo`.
    public var base: String
    public var generics: [CType] = []
    /// `id<P, Q>` or `Foo<P>`.
    public var protocols: [String] = []
    public var pointers = 0
    public var isConst = false
    public var nullability: Nullability?
    /// Block (`^`) or function pointer (`*`) types: the result is `base…`'s
    /// type and these are the parameters.
    public indirect enum Callable: Equatable { case none, block(CType, [CType]), function(CType, [CType]) }
    public var callable: Callable = .none
    public var arrayCount: Int?
    public var isOut = false
    public init(base: String) { self.base = base }
}

public struct CParam: Equatable {
    public var name: String
    public var type: CType
}

public struct ObjCMethod {
    public var isClass: Bool
    public var result: CType
    /// Selector pieces: `("insert", key)`, `("value", value)`; a piece with
    /// no parameter is a no-argument method's name.
    public var pieces: [(label: String, param: CParam?)]
    public var swiftName: String?
    public var isOptional = false
    public var audited = false
    public var isDesignated = false
    public var selector: String { pieces.map { $0.label + ($0.param == nil ? "" : ":") }.joined() }
}

public struct ObjCProperty {
    public var name: String
    public var type: CType
    public var isClass = false
    public var isReadonly = false
    public var isWeak = false
    public var getter: String?
    public var isOptional = false
    public var audited = false
    public var swiftName: String?
}

public struct ObjCContainer {
    public enum Kind { case interface, category, proto }
    public var kind: Kind
    public var name: String
    public var superclass: String?
    public var protocols: [String] = []
    public var methods: [ObjCMethod] = []
    public var properties: [ObjCProperty] = []
}

public struct CEnum {
    public enum Style { case nsEnum, nsOptions, plain, anonymous }
    public var style: Style
    public var name: String
    public var underlying: String
    public var cases: [(name: String, value: Int64?)]
    public var swiftName: String?
}

public struct CStruct {
    public var name: String
    public var fields: [CParam]
}

public struct CFunction {
    public var name: String
    public var result: CType
    public var params: [CParam]
    public var isVariadic = false
    public var audited = false
    public var swiftName: String?
    /// Declared under CF_IMPLICIT_BRIDGING_ENABLED or with CF_RETURNS_*: a
    /// Core Foundation result is memory-managed. Otherwise Swift imports it as `Unmanaged`.
    public var managedResult = false
}

public struct CVariable {
    public var name: String
    public var type: CType
    /// The initializer's tokens (`static const`), if any.
    public var value: [String]?
    public var audited = false
}

public struct CTypedef {
    public var name: String
    public var type: CType
    /// `typedef struct __Foo *FooRef;`: an opaque reference type.
    public var opaqueStruct: String?
    /// `NS_TYPED_ENUM` and friends: a wrapper type for constants.
    public var isTypedEnum = false
}

public struct CMacro {
    public var name: String
    public var params: [String]?
    public var body: [String]
}

public struct ObjCHeaderModel {
    public var containers: [ObjCContainer] = []
    public var enums: [CEnum] = []
    public var structs: [CStruct] = []
    public var functions: [CFunction] = []
    public var variables: [CVariable] = []
    public var typedefs: [CTypedef] = []
    public var macros: [CMacro] = []
    public var forwardClasses: [String] = []
    public var forwardProtocols: [String] = []
    /// `#import <Framework/Header.h>`: the frameworks named.
    public var frameworks: [String] = []
    /// `#import "local.h"` paths, as spelled.
    public var localIncludes: [String] = []
    public init() {}
}

// MARK: Preprocessing

/// What a 64-bit macOS Objective-C compile defines (for `#if`).
private let predefined: [String: Int64] = [
    "__OBJC__": 1, "__LP64__": 1, "__APPLE__": 1, "__MACH__": 1, "TARGET_OS_OSX": 1, "TARGET_OS_MAC": 1, "__clang__": 1,
    "TARGET_OS_IPHONE": 0, "TARGET_OS_IOS": 0, "TARGET_OS_TV": 0, "TARGET_OS_WATCH": 0, "TARGET_OS_SIMULATOR": 0,
    "TARGET_OS_MACCATALYST": 0, "TARGET_OS_VISION": 0, "__arm64__": 1, "__x86_64__": 0, "__i386__": 0, "__BLOCKS__": 1,
    "NS_BLOCKS_AVAILABLE": 1, "__has_feature": 1, "__has_include": 1, "TARGET_OS_EMBEDDED": 0, "TARGET_IPHONE_SIMULATOR": 0,
    "DEBUG": 0, "__MAC_OS_X_VERSION_MAX_ALLOWED": 150000, "__MAC_OS_X_VERSION_MIN_REQUIRED": 130000,
    "MAC_OS_X_VERSION_MAX_ALLOWED": 150000, "MAC_OS_X_VERSION_MIN_REQUIRED": 130000, "__STDC_VERSION__": 201112,
]

func stripComments(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    let s = Array(text.unicodeScalars)
    var i = 0
    while i < s.count {
        let c = s[i]
        if c == "/", i + 1 < s.count, s[i + 1] == "/" {
            while i < s.count, s[i] != "\n" { i += 1 }
            continue
        }
        if c == "/", i + 1 < s.count, s[i + 1] == "*" {
            i += 2
            while i + 1 < s.count, !(s[i] == "*" && s[i + 1] == "/") { if s[i] == "\n" { out.append("\n") }; i += 1 }
            i += 2
            out.append(" ")
            continue
        }
        if c == "\"" || c == "'" {
            out.append(c)
            i += 1
            while i < s.count, s[i] != c, s[i] != "\n" {
                if s[i] == "\\", i + 1 < s.count { out.append(s[i]); i += 1 }
                out.append(s[i])
                i += 1
            }
            if i < s.count { out.append(s[i]); i += 1 }
            continue
        }
        out.append(c)
        i += 1
    }
    return String(out)
}

func tokenize(_ text: String) -> [String] {
    var out: [String] = []
    let s = Array(text.unicodeScalars)
    var i = 0
    func isIdent(_ c: Unicode.Scalar) -> Bool { c == "_" || c == "$" || (c.isASCII && (CharacterSet.alphanumerics.contains(c))) }
    while i < s.count {
        let c = s[i]
        if c == " " || c == "\t" || c == "\n" || c == "\r" { i += 1; continue }
        if isIdent(c) {
            var j = i
            // Numbers keep their dots, exponents and suffixes.
            let number = CharacterSet.decimalDigits.contains(c)
            while j < s.count, isIdent(s[j]) || (number && (s[j] == "." || ((s[j] == "+" || s[j] == "-") && (s[j - 1] == "e" || s[j - 1] == "E") && !(s.count > i + 1 && (s[i + 1] == "x" || s[i + 1] == "X"))))) { j += 1 }
            out.append(String(String.UnicodeScalarView(s[i..<j])))
            i = j
            continue
        }
        if c == "\"" || c == "'" {
            var j = i + 1
            while j < s.count, s[j] != c { if s[j] == "\\" { j += 1 }; j += 1 }
            out.append(String(String.UnicodeScalarView(s[i..<min(j + 1, s.count)])))
            i = j + 1
            continue
        }
        if c == "@", i + 1 < s.count, s[i + 1] == "\"" {
            var j = i + 2
            while j < s.count, s[j] != "\"" { if s[j] == "\\" { j += 1 }; j += 1 }
            out.append(String(String.UnicodeScalarView(s[i..<min(j + 1, s.count)])))
            i = j + 1
            continue
        }
        if c == "@", i + 1 < s.count, isIdent(s[i + 1]) {
            var j = i + 1
            while j < s.count, isIdent(s[j]) { j += 1 }
            out.append(String(String.UnicodeScalarView(s[i..<j])))
            i = j
            continue
        }
        for op in ["<<", ">>", "...", "->", "==", "!=", "<=", ">=", "&&", "||"] where i + op.unicodeScalars.count <= s.count {
            if String(String.UnicodeScalarView(s[i..<(i + op.unicodeScalars.count)])) == op { out.append(op); i += op.unicodeScalars.count; break }
        }
        if i < s.count, s[i] == c, !(out.last.map { ["<<", ">>", "...", "->", "==", "!=", "<=", ">=", "&&", "||"].contains($0) && $0.unicodeScalars.first == c } ?? false) || out.isEmpty {
            out.append(String(c))
            i += 1
        }
    }
    return out
}

/// Integer constant expressions: enumerator values, `#if` conditions,
/// `#define`d numbers.
struct ConstantEvaluator {
    var known: [String: Int64]
    var defined: (String) -> Bool = { _ in false }
    private var t: [String] = []
    private var i = 0

    init(known: [String: Int64]) { self.known = known }

    mutating func evaluate(_ tokens: [String]) -> Int64? {
        t = tokens
        i = 0
        guard !t.isEmpty, let v = ternary(), i == t.count else { return nil }
        return v
    }

    private var peek: String? { i < t.count ? t[i] : nil }
    private mutating func eat(_ s: String) -> Bool { if peek == s { i += 1; return true }; return false }

    private mutating func ternary() -> Int64? {
        guard let c = binary(0) else { return nil }
        if eat("?") {
            guard let a = ternary(), eat(":"), let b = ternary() else { return nil }
            return c != 0 ? a : b
        }
        return c
    }

    private static let levels: [[String]] = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

    private mutating func binary(_ level: Int) -> Int64? {
        if level == Self.levels.count { return unary() }
        guard var l = binary(level + 1) else { return nil }
        while let op = peek, Self.levels[level].contains(op) {
            i += 1
            guard let r = binary(level + 1) else { return nil }
            switch op {
            case "||": l = (l != 0 || r != 0) ? 1 : 0
            case "&&": l = (l != 0 && r != 0) ? 1 : 0
            case "|": l |= r
            case "^": l ^= r
            case "&": l &= r
            case "==": l = l == r ? 1 : 0
            case "!=": l = l != r ? 1 : 0
            case "<": l = l < r ? 1 : 0
            case ">": l = l > r ? 1 : 0
            case "<=": l = l <= r ? 1 : 0
            case ">=": l = l >= r ? 1 : 0
            case "<<": l = r >= 0 && r < 64 ? l << r : 0
            case ">>": l = r >= 0 && r < 64 ? l >> r : 0
            case "+": l = l &+ r
            case "-": l = l &- r
            case "*": l = l &* r
            case "/": if r == 0 { return nil }; l /= r
            default: if r == 0 { return nil }; l %= r
            }
        }
        return l
    }

    private mutating func unary() -> Int64? {
        guard let tok = peek else { return nil }
        if eat("-") { return unary().map { 0 &- $0 } }
        if eat("+") { return unary() }
        if eat("~") { return unary().map { ~$0 } }
        if eat("!") { return unary().map { $0 == 0 ? 1 : 0 } }
        if tok == "defined" {
            i += 1
            let paren = eat("(")
            guard let name = peek else { return nil }
            i += 1
            if paren { _ = eat(")") }
            return (defined(name) || (predefined[name] != nil)) ? 1 : 0
        }
        if eat("(") {
            // A cast: `(type)value`.
            let start = i
            var j = i, isType = true, n = 0
            while j < t.count, t[j] != ")" {
                let w = t[j]
                if !(typeWords.contains(w) || w == "*" || (n == 0 && w.first.map { $0.isLetter || $0 == "_" } == true && known[w] == nil && predefined[w] == nil)) { isType = false }
                n += 1
                j += 1
            }
            if isType, n > 0, j + 1 < t.count, t[j + 1] != ")" , !["+", "*", "/", "|", "&", "<<", ">>", "?", ":", "==", "<", ">"].contains(t[j + 1]) {
                i = j + 1
                return unary()
            }
            i = start
            guard let v = ternary(), eat(")") else { return nil }
            return v
        }
        i += 1
        if tok.hasPrefix("'") {
            // Four-character codes.
            var v: Int64 = 0
            for u in tok.dropFirst().dropLast().unicodeScalars { v = (v << 8) | Int64(u.value & 0xff) }
            return v
        }
        if let f = tok.unicodeScalars.first, CharacterSet.decimalDigits.contains(f) {
            var digits = tok.lowercased()
            while let l = digits.last, "ul".contains(l), !digits.hasPrefix("0x") || true {
                if digits.hasPrefix("0x"), !"ul".contains(l) { break }
                digits.removeLast()
            }
            if digits.hasPrefix("0x") { return Int64(digits.dropFirst(2), radix: 16) ?? UInt64(digits.dropFirst(2), radix: 16).map { Int64(bitPattern: $0) } }
            if digits.hasPrefix("0b") { return Int64(digits.dropFirst(2), radix: 2) }
            if digits.count > 1, digits.hasPrefix("0"), !digits.contains(".") { return Int64(digits.dropFirst(), radix: 8) }
            return Int64(digits)
        }
        if let v = known[tok] { return v }
        if let v = predefined[tok] {
            // `__has_feature(x)`-style calls count as true.
            if peek == "(" { skipParens() }
            return v
        }
        if tok == "YES" || tok == "true" { return 1 }
        if tok == "NO" || tok == "false" { return 0 }
        return nil
    }

    private mutating func skipParens() {
        var depth = 0
        while i < t.count {
            if t[i] == "(" { depth += 1 } else if t[i] == ")" { depth -= 1; if depth == 0 { i += 1; return } }
            i += 1
        }
    }
}

let typeWords: Set<String> = [
    "int", "unsigned", "signed", "long", "short", "char", "float", "double", "void", "const", "NSInteger", "NSUInteger", "CGFloat",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "size_t", "UInt32", "SInt32", "UInt8",
    "UInt16", "UInt64", "SInt64", "SInt16", "BOOL", "bool", "OSStatus", "OSType", "IOReturn", "kern_return_t", "struct", "enum",
]

/// Attribute-like macros with arguments, dropped with their parentheses.
private let attributeCalls: Set<String> = [
    "__attribute__", "__attribute", "CF_BRIDGED_TYPE", "CF_BRIDGED_MUTABLE_TYPE", "CF_RELATED_TYPE", "NS_SWIFT_BRIDGED_TYPEDEF_", "API_AVAILABLE", "API_DEPRECATED", "API_UNAVAILABLE", "API_DEPRECATED_WITH_REPLACEMENT", "NS_AVAILABLE",
    "NS_AVAILABLE_MAC", "NS_AVAILABLE_IOS", "NS_DEPRECATED", "NS_DEPRECATED_MAC", "NS_DEPRECATED_IOS", "NS_CLASS_AVAILABLE",
    "NS_CLASS_AVAILABLE_MAC", "NS_CLASS_DEPRECATED", "NS_ENUM_AVAILABLE", "NS_ENUM_AVAILABLE_MAC", "NS_ENUM_DEPRECATED",
    "DEPRECATED_MSG_ATTRIBUTE", "__deprecated_msg", "NS_FORMAT_FUNCTION", "NS_FORMAT_ARGUMENT", "CF_FORMAT_FUNCTION", "__OSX_AVAILABLE_STARTING",
    "__OSX_AVAILABLE", "__OSX_AVAILABLE_BUT_DEPRECATED", "__OSX_DEPRECATED", "__IOS_AVAILABLE", "__TVOS_AVAILABLE", "__WATCHOS_AVAILABLE",
    "NS_SWIFT_UNAVAILABLE", "NS_SWIFT_ASYNC_NAME", "NS_SWIFT_ASYNC", "NS_SWIFT_ASYNC_THROWS_ON_FALSE", "NS_SWIFT_UI_ACTOR_", "CF_SWIFT_NAME_",
    "__has_attribute_", "NS_DEPRECATED_WITH_REPLACEMENT_MAC", "CF_ENUM_AVAILABLE", "CF_ENUM_DEPRECATED", "CF_AVAILABLE", "CF_DEPRECATED",
    "__declspec", "__asm", "__asm__", "asm", "NS_SWIFT_SENDING_", "__printflike", "__API_AVAILABLE", "__API_DEPRECATED", "__API_UNAVAILABLE",
    "OS_SWIFT_NAME_", "CF_AVAILABLE_MAC", "CF_DEPRECATED_MAC", "CM_AVAILABLE", "__SWIFT_UNAVAILABLE_MSG", "NS_ERROR_ENUM_", "CF_REFINED_FOR_SWIFT_",
    "__availability", "XPC_SWIFT_NAME_", "NS_HEADER_AUDIT_BEGIN", "NS_HEADER_AUDIT_END", "__SPI_AVAILABLE", "SPI_AVAILABLE", "__WATCHOS_PROHIBITED_",
    "NS_SWIFT_NONISOLATED_", "__deprecated_enum_msg", "DEPRECATED_ATTRIBUTE_", "NS_AUTOMATED_REFCOUNT_UNAVAILABLE_", "__has_feature_",
]

/// Words that add nothing to a declaration's Swift shape.
private let noiseWords: Set<String> = [
    "NS_DESIGNATED_INITIALIZER_", "NS_REQUIRES_SUPER", "NS_RETURNS_RETAINED", "NS_RETURNS_NOT_RETAINED", "NS_RETURNS_INNER_POINTER",
    "NS_REFINED_FOR_SWIFT", "NS_NOESCAPE", "CF_NOESCAPE", "NS_REQUIRES_NIL_TERMINATION",
    "NS_ROOT_CLASS", "NS_SWIFT_NOTHROW", "NS_WARN_UNUSED_RESULT", "CF_WARN_UNUSED_RESULT", "DEPRECATED_ATTRIBUTE", "UNAVAILABLE_ATTRIBUTE",
    "NS_INLINE", "CF_INLINE", "FOUNDATION_EXPORT", "FOUNDATION_EXTERN", "APPKIT_EXTERN", "CF_EXPORT", "CG_EXTERN", "OBJC_EXPORT", "OBJC_EXTERN",
    "UIKIT_EXTERN", "extern", "__unused", "__kindof", "__weak", "__strong", "__unsafe_unretained", "__autoreleasing", "__block", "volatile",
    "register", "restrict", "__restrict", "inline", "__inline", "__inline__", "IBOutlet", "IBInspectable", "IB_DESIGNABLE", "IBAction_",
    "NS_SWIFT_SENDABLE", "NS_SWIFT_NONSENDABLE", "NS_SWIFT_UI_ACTOR", "NS_SWIFT_NONISOLATED", "NS_SWIFT_SENDING", "OS_OBJECT_RETURNS_RETAINED",
    "CF_CONSUMED", "NS_RELEASES_ARGUMENT", "__const", "__signed", "CF_BRIDGED_TYPE_", "NS_NONATOMIC_IOSONLY", "NS_AUTOMATED_REFCOUNT_UNAVAILABLE",
    "__deprecated", "__pure2", "__dead2", "NS_ASSUME_NONNULL_BEGIN_", "API_TO_BE_DEPRECATED", "CF_EXTERN_C_BEGIN", "CF_EXTERN_C_END", "__BEGIN_DECLS", "__END_DECLS", "NS_EXTENSION_UNAVAILABLE_IOS_",
    "NS_DIRECT", "NS_DIRECT_MEMBERS", "NS_NO_TAIL_CALL", "NS_VALID_UNTIL_END_OF_SCOPE", "CF_RELEASES_ARGUMENT", "NS_UNAVAILABLE_",
    "_Noreturn", "__dead", "NS_SWIFT_DISABLE_ASYNC", "NS_SWIFT_UNAVAILABLE_FROM_ASYNC_", "weak_import", "WEAK_IMPORT_ATTRIBUTE", "__THROW",
    "NS_EXTENSION_UNAVAILABLE_", "auto", "_Atomic_", "__nonnull_", "CM_INLINE", "CG_INLINE", "OS_ALWAYS_INLINE", "OS_INLINE", "OS_EXPORT",
    "XPC_EXPORT", "XPC_NONNULL_ALL", "XPC_WARN_RESULT", "XPC_MALLOC", "XPC_RETURNS_RETAINED", "XPC_NONNULL1", "XPC_NONNULL2", "XPC_NONNULL3",
    "NS_ENUM_FLAG_", "NS_NOINLINE", "OS_NOTHROW", "OS_WARN_RESULT", "OS_NONNULL_ALL", "__CF_ENUM_FIXED_IS_AVAILABLE_",
]

public struct ObjCHeaderReader {
    public private(set) var model = ObjCHeaderModel()
    private var constants: [String: Int64] = [:]
    private var macroNames = Set<String>()

    public init() {}

    /// Reads one header's text into the model.
    public mutating func read(_ text: String) {
        let tokens = preprocess(text)
        parse(tokens)
    }

    public var knownConstants: [String: Int64] { constants }

    // MARK: Lines: conditionals, includes, defines

    private mutating func preprocess(_ text: String) -> [String] {
        var joined = stripComments(text.replacingOccurrences(of: "\r\n", with: "\n")).replacingOccurrences(of: "\\\n", with: " ")
        if !joined.hasSuffix("\n") { joined += "\n" }
        var kept: [String] = []
        // Each open conditional: (currently active, some branch already taken, parent active).
        var stack: [(active: Bool, taken: Bool, parent: Bool)] = []
        var active: Bool { stack.last.map { $0.active && $0.parent } ?? true }
        func condition(_ tokens: [String], _ macros: Set<String>, _ constants: [String: Int64]) -> Bool {
            var ev = ConstantEvaluator(known: constants)
            ev.defined = { macros.contains($0) }
            // Unknown names in a condition count as 0, as in C; unknown calls as true.
            if let v = ev.evaluate(tokens) { return v != 0 }
            var patched: [String] = []
            var k = 0
            while k < tokens.count {
                let w = tokens[k]
                if w.first.map({ $0.isLetter || $0 == "_" }) == true, w != "defined", constants[w] == nil, predefined[w] == nil,
                   !(k > 0 && (tokens[k - 1] == "defined" || (k > 1 && tokens[k - 1] == "(" && tokens[k - 2] == "defined"))) {
                    if k + 1 < tokens.count, tokens[k + 1] == "(" {
                        var depth = 0
                        k += 1
                        while k < tokens.count { if tokens[k] == "(" { depth += 1 } else if tokens[k] == ")" { depth -= 1; if depth == 0 { break } }; k += 1 }
                        patched.append("1")
                    } else { patched.append("0") }
                } else { patched.append(w) }
                k += 1
            }
            return (ev.evaluate(patched) ?? 1) != 0
        }
        for line in joined.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else {
                if active { kept.append(String(line)) }
                continue
            }
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            let directive = String(body.prefix { $0.isLetter })
            let rest = body.dropFirst(directive.count).trimmingCharacters(in: .whitespaces)
            switch directive {
            case "if":
                let on = active && condition(tokenize(rest), macroNames, constants)
                stack.append((on, on, active))
            case "ifdef":
                let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                let on = (macroNames.contains(name) || (predefined[name] ?? 0) != 0 || (predefined[name] != nil && name.hasPrefix("__")))
                stack.append((on, on, active))
            case "ifndef":
                let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                let on = !(macroNames.contains(name) || predefined[name] != nil)
                stack.append((on, on, active))
            case "elif":
                guard var top = stack.popLast() else { break }
                let on = !top.taken && condition(tokenize(rest), macroNames, constants)
                top.active = on
                top.taken = top.taken || on
                stack.append(top)
            case "else":
                guard var top = stack.popLast() else { break }
                top.active = !top.taken
                top.taken = true
                stack.append(top)
            case "endif":
                _ = stack.popLast()
            case "import", "include":
                guard active else { break }
                if rest.hasPrefix("<"), let end = rest.firstIndex(of: ">") {
                    let path = rest[rest.index(after: rest.startIndex)..<end]
                    if let fw = path.split(separator: "/").first, path.contains("/"), !model.frameworks.contains(String(fw)) { model.frameworks.append(String(fw)) }
                    else if !path.contains("/") { model.localIncludes.append(String(path)) }
                    if path.contains("/") { model.localIncludes.append(String(path)) }
                } else if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
                    model.localIncludes.append(String(rest[rest.index(after: rest.startIndex)..<end]))
                }
            case "define":
                guard active else { break }
                let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                guard !name.isEmpty else { break }
                var after = rest.dropFirst(name.count)
                var params: [String]?
                if after.hasPrefix("(") , let close = after.firstIndex(of: ")") {
                    params = after[after.index(after: after.startIndex)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    after = after[after.index(after: close)...]
                }
                macroNames.insert(name)
                model.macros.removeAll { $0.name == name }
                model.macros.append(CMacro(name: name, params: params, body: tokenize(String(after))))
            case "undef":
                guard active else { break }
                let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                macroNames.remove(name)
                model.macros.removeAll { $0.name == name }
            default: break  // pragma, error, warning
            }
        }
        return clean(tokenize(kept.joined(separator: "\n")))
    }

    /// Drops attributes and expands the header's own simple macros.
    private func clean(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        func skipParens() {
            guard i < tokens.count, tokens[i] == "(" else { return }
            var depth = 0
            while i < tokens.count {
                if tokens[i] == "(" { depth += 1 } else if tokens[i] == ")" { depth -= 1; if depth == 0 { i += 1; return } }
                i += 1
            }
        }
        let objectLike = Dictionary(model.macros.filter { $0.params == nil }.map { ($0.name, $0.body) }, uniquingKeysWith: { $1 })
        while i < tokens.count {
            let t = tokens[i]
            i += 1
            if attributeCalls.contains(t) { skipParens(); continue }
            if noiseWords.contains(t) { continue }
            if t == "NS_DESIGNATED_INITIALIZER" { out.append("@designated"); continue }
            if t == "NS_UNAVAILABLE" || t == "UNAVAILABLE_ATTRIBUTE" { out.append("@unavailable"); continue }
            if t == "NS_SWIFT_NAME" || t == "CF_SWIFT_NAME" || t == "OS_SWIFT_NAME" {
                let start = i
                skipParens()
                if start + 1 < i { out.append("@swiftname:" + tokens[(start + 1)..<(i - 1)].joined()) }
                continue
            }
            if t == "NS_EXTENSIBLE_STRING_ENUM" || t == "NS_STRING_ENUM" || t == "NS_TYPED_ENUM" || t == "NS_TYPED_EXTENSIBLE_ENUM" || t == "CF_TYPED_ENUM"
                || t == "CF_EXTENSIBLE_STRING_ENUM" || t == "CF_STRING_ENUM" || t == "CF_TYPED_EXTENSIBLE_ENUM" { out.append("@typedenum"); continue }
            if t == "CF_IMPLICIT_BRIDGING_ENABLED" { out.append("@bridging:on"); continue }
            if t == "CF_IMPLICIT_BRIDGING_DISABLED" { out.append("@bridging:off"); continue }
            if t == "CF_RETURNS_RETAINED" || t == "CF_RETURNS_NOT_RETAINED" { out.append("@managed"); continue }
            if t == "NS_ASSUME_NONNULL_BEGIN" || t == "CF_ASSUME_NONNULL_BEGIN" { out.append("@audit:on"); continue }
            if t == "NS_ASSUME_NONNULL_END" || t == "CF_ASSUME_NONNULL_END" { out.append("@audit:off"); continue }
            // A project's own export/availability macros.
            if t.count > 5, t == t.uppercased(), t.first!.isLetter,
               t.hasSuffix("_EXPORT") || t.hasSuffix("_EXTERN") || t.hasSuffix("_PUBLIC") || t.hasSuffix("_API") || t.hasSuffix("_INLINE") || t.hasSuffix("_UNAVAILABLE")
                || t.hasSuffix("_DEPRECATED") || t.hasSuffix("_VISIBLE") || t.hasSuffix("_EXTERN_C") {
                if i < tokens.count, tokens[i] == "(", !t.hasSuffix("_EXTERN"), !t.hasSuffix("_EXPORT"), !t.hasSuffix("_INLINE") { skipParens() }
                continue
            }
            if t.count > 8, t == t.uppercased(), t.contains("_AVAILABLE") || t.contains("_DEPRECATED"), i < tokens.count, tokens[i] == "(" { skipParens(); continue }
            // The header's own object-like macros naming a type or attribute (not constants).
            if let body = objectLike[t], body.count <= 6, !body.contains(t), !(body.count == 1 && (body[0].first!.isNumber || body[0].hasPrefix("\"") || body[0].hasPrefix("@\""))),
               body.allSatisfy({ $0.first.map { $0.isLetter || $0 == "_" || $0 == "*" } == true }) {
                out += clean(body)
                continue
            }
            out.append(t)
        }
        return out
    }

    // MARK: Declarations

    private var t: [String] = []
    private var p = 0
    private var audited = false
    private var implicitBridging = false

    private var peek: String? { p < t.count ? t[p] : nil }

    private mutating func parse(_ tokens: [String]) {
        t = tokens
        p = 0
        audited = false
        // Constants this header's macros define, before its declarations use them.
        defineMacroConstants()
        // Every step consumes at least one token, and a header gets a bounded
        // number of steps: a construct this reader doesn't know (C++…) can
        // cost declarations, never the build.
        var steps = 0
        while p < t.count, steps < 4 * t.count + 64 {
            let start = p
            parseTopLevel()
            if p <= start { p = start + 1 }
            steps += 1
        }
        defineMacroConstants()
    }

    private mutating func defineMacroConstants() {
        var ev = ConstantEvaluator(known: constants)
        for _ in 0..<3 {
            for m in model.macros where m.params == nil && constants[m.name] == nil {
                ev.known = constants
                if let v = ev.evaluate(expandMacros(m.body)) { constants[m.name] = v }
            }
        }
    }

    /// Function-like macros of the header, expanded in a token list.
    func expandMacros(_ tokens: [String], depth: Int = 0) -> [String] {
        guard depth < 6 else { return tokens }
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let w = tokens[i]
            if let m = model.macros.first(where: { $0.name == w }) {
                if let params = m.params {
                    guard i + 1 < tokens.count, tokens[i + 1] == "(" else { out.append(w); i += 1; continue }
                    var args: [[String]] = [[]], d = 0, j = i + 1
                    while j < tokens.count {
                        let x = tokens[j]
                        if x == "(" { d += 1; if d == 1 { j += 1; continue } }
                        if x == ")" { d -= 1; if d == 0 { break } }
                        if x == ",", d == 1 { args.append([]) } else { args[args.count - 1].append(x) }
                        j += 1
                    }
                    var body: [String] = []
                    for b in m.body {
                        if let k = params.firstIndex(of: b), k < args.count { body += ["("] + args[k] + [")"] } else { body.append(b) }
                    }
                    out += ["("] + expandMacros(body, depth: depth + 1) + [")"]
                    i = j + 1
                    continue
                }
                if constants[w] == nil, !m.body.isEmpty, !m.body.contains(w) {
                    out += ["("] + expandMacros(m.body, depth: depth + 1) + [")"]
                    i += 1
                    continue
                }
            }
            out.append(w)
            i += 1
        }
        return out
    }

    /// Tokens up to (not including) the `;` that ends a declaration at depth 0,
    /// which is consumed. A `{…}` body ends it too.
    private mutating func declarationTokens() -> (tokens: [String], body: Bool) {
        var out: [String] = []
        var depth = 0
        while p < t.count {
            let w = t[p]
            if w == "(" || w == "[" { depth += 1 }
            if w == ")" || w == "]" { depth -= 1 }
            if depth <= 0 {
                if w == ";" { p += 1; return (out, false) }
                if w == "{" {
                    skipBraces()
                    // `struct {…} name;` continues; a function body ends the declaration.
                    if peek == ";" { p += 1 }
                    return (out, true)
                }
                if w.hasPrefix("@") && ["@interface", "@protocol", "@end", "@class", "@implementation"].contains(w) { return (out, false) }
            }
            out.append(w)
            p += 1
        }
        return (out, false)
    }

    private mutating func skipBraces() {
        var depth = 0
        while p < t.count {
            if t[p] == "{" { depth += 1 } else if t[p] == "}" { depth -= 1; if depth == 0 { p += 1; return } }
            p += 1
        }
    }

    private mutating func bracedTokens() -> [String] {
        guard peek == "{" else { return [] }
        var depth = 0
        var out: [String] = []
        while p < t.count {
            let w = t[p]
            p += 1
            if w == "{" { depth += 1; if depth == 1 { continue } }
            if w == "}" { depth -= 1; if depth == 0 { break } }
            out.append(w)
        }
        return out
    }

    private mutating func parseTopLevel() {
        guard let w = peek else { return }
        switch w {
        case "@audit:on": audited = true; p += 1
        case "@audit:off": audited = false; p += 1
        case "@bridging:on": implicitBridging = true; p += 1
        case "@bridging:off": implicitBridging = false; p += 1
        case ";": p += 1
        case "@class":
            p += 1
            while let n = peek, n != ";" {
                if n != ",", n.first!.isLetter || n.first! == "_" { if !model.forwardClasses.contains(n) { model.forwardClasses.append(n) } }
                p += 1
                if peek == "<" { skipAngles() }
            }
            p += 1
        case "@import":
            // `@import Foundation;`
            p += 1
            if let name = peek, name != ";" {
                let fw = String(name.split(separator: ".").first ?? Substring(name))
                if !model.frameworks.contains(fw) { model.frameworks.append(fw) }
            }
            while let n = peek, n != ";" { p += 1; _ = n }
            p += 1
        case "@protocol": parseProtocol()
        case "@interface": parseInterface()
        case "@implementation":
            while let n = peek, n != "@end" { p += 1; _ = n }
            p += 1
        case "@end", "@unavailable", "@designated": p += 1
        case "typedef": p += 1; parseTypedef()
        case "NS_ENUM", "NS_OPTIONS", "NS_CLOSED_ENUM", "CF_ENUM", "CF_OPTIONS", "CF_CLOSED_ENUM", "NS_ERROR_ENUM":
            if let e = parseNSEnum() { addEnum(e) }
            _ = declarationTokens()
        case "enum", "struct", "union":
            parseTagged(typedefName: nil)
        case "static", "const":
            parseDeclaration()
        default:
            if w.hasPrefix("@swiftname:") || w == "@typedenum" { p += 1; return }
            parseDeclaration()
        }
    }

    private mutating func skipAngles() {
        var depth = 0
        while p < t.count {
            if t[p] == "<" { depth += 1 } else if t[p] == ">" { depth -= 1; if depth == 0 { p += 1; return } } else if t[p] == ">>" { depth -= 2; if depth <= 0 { p += 1; return } }
            p += 1
        }
    }

    private mutating func addEnum(_ e: CEnum) {
        var next: Int64 = 0
        var resolved = e
        for (i, c) in e.cases.enumerated() {
            let v = c.value ?? next
            resolved.cases[i].value = v
            constants[c.name] = v
            next = v &+ 1
        }
        if e.style != .anonymous { model.enums.removeAll { $0.name == e.name } }
        model.enums.append(resolved)
    }

    /// `NS_ENUM(Type, Name) { cases }` at `p` (after an optional `typedef`).
    private mutating func parseNSEnum() -> CEnum? {
        guard let macro = peek else { return nil }
        p += 1
        guard peek == "(" else { return nil }
        p += 1
        var args: [[String]] = [[]]
        var depth = 1
        while p < t.count {
            let w = t[p]
            p += 1
            if w == "(" { depth += 1 }
            if w == ")" { depth -= 1; if depth == 0 { break } }
            if w == ",", depth == 1 { args.append([]) } else { args[args.count - 1].append(w) }
        }
        var name: String, underlying: String
        if macro == "NS_ERROR_ENUM" {
            guard let n = args.last?.last else { return nil }
            name = n
            underlying = "NSInteger"
        } else {
            guard args.count >= 2, let n = args[1].last else {
                // `NS_ENUM(NSInteger) { … }`: anonymous.
                let cases = parseEnumerators(bracedTokens())
                return CEnum(style: .anonymous, name: "", underlying: args.first?.joined(separator: " ") ?? "int", cases: cases)
            }
            name = n
            underlying = args[0].joined(separator: " ")
        }
        var swiftName: String?
        while let w = peek, w != "{", w != ";" {
            if w.hasPrefix("@swiftname:") { swiftName = String(w.dropFirst("@swiftname:".count)) }
            p += 1
        }
        guard peek == "{" else { return nil }  // a forward declaration
        let cases = parseEnumerators(bracedTokens())
        _ = name
        return CEnum(style: macro.hasSuffix("OPTIONS") ? .nsOptions : .nsEnum, name: name, underlying: underlying, cases: cases, swiftName: swiftName)
    }

    private func parseEnumerators(_ body: [String]) -> [(name: String, value: Int64?)] {
        var out: [(String, Int64?)] = []
        var known = constants
        var next: Int64 = 0
        var item: [String] = []
        var depth = 0
        func flush(_ item: [String]) {
            var item = item.filter { !$0.hasPrefix("@swiftname:") && $0 != "@unavailable" }
            guard let name = item.first, name.first.map({ $0.isLetter || $0 == "_" }) == true else { return }
            item.removeFirst()
            var value: Int64?
            if item.first == "=" {
                var ev = ConstantEvaluator(known: known)
                value = ev.evaluate(expandMacros(Array(item.dropFirst())))
            } else { value = next }
            if let v = value { known[name] = v; next = v &+ 1 } else { next = next &+ 1 }
            out.append((name, value))
        }
        for w in body {
            if w == "(" { depth += 1 } else if w == ")" { depth -= 1 }
            if w == ",", depth == 0 { flush(item); item = [] } else { item.append(w) }
        }
        flush(item)
        return out
    }

    private func parseFields(_ body: [String]) -> [CParam] {
        var out: [CParam] = []
        var item: [String] = []
        var depth = 0
        for w in body {
            if w == "{" || w == "(" { depth += 1 } else if w == "}" || w == ")" { depth -= 1 }
            if w == ";", depth == 0 {
                // `int a, b;` declares several.
                if !item.contains("("), item.contains(",") {
                    let parts = item.split(separator: ",").map(Array.init)
                    if let first = parts.first, let (_, ty) = Optional(parseDeclarator(first)), let n0 = parseDeclarator(first).name {
                        out.append(CParam(name: n0, type: ty))
                        for extra in parts.dropFirst() {
                            var ty2 = ty
                            ty2.pointers = extra.filter { $0 == "*" }.count
                            if let n = extra.last(where: { $0.first.map { $0.isLetter || $0 == "_" } == true }) { out.append(CParam(name: n, type: ty2)) }
                        }
                    }
                } else if !item.isEmpty, !item.contains("{") {
                    // Bit-fields: `unsigned x : 3`.
                    var decl = item
                    if let colon = decl.firstIndex(of: ":") { decl = Array(decl[..<colon]) }
                    let d = parseDeclarator(decl)
                    if let n = d.name { out.append(CParam(name: n, type: d.type)) }
                }
                item = []
            } else { item.append(w) }
        }
        return out
    }

    /// `enum`/`struct`/`union` at `p`, standing alone or inside a typedef.
    private mutating func parseTagged(typedefName: String?) {
        guard let keyword = peek else { return }
        p += 1
        var tag: String?
        if let n = peek, n != "{", n != ":", n != ";" { tag = n; p += 1 }
        var underlying = keyword == "enum" ? "int" : ""
        if peek == ":" {
            p += 1
            var parts: [String] = []
            while let w = peek, w != "{", w != ";" { parts.append(w); p += 1 }
            underlying = parts.joined(separator: " ")
        }
        guard peek == "{" else {
            // A reference to a tagged type starting a declaration: `struct foo *bar(void);`.
            p -= (tag == nil ? 1 : 2)
            if peek == keyword { parseDeclaration() }
            return
        }
        let body = bracedTokens()
        // What follows the brace: the typedef's name(s), or variables.
        var trailing: [String] = []
        while let w = peek, w != ";" { trailing.append(w); p += 1 }
        p += 1
        let names = trailing.filter { $0.first.map { $0.isLetter || $0 == "_" } == true && !$0.hasPrefix("@") }
        let swiftName = trailing.first { $0.hasPrefix("@swiftname:") }.map { String($0.dropFirst("@swiftname:".count)) }
        let name = names.first(where: { _ in !trailing.contains("*") }) ?? tag
        if keyword == "enum" {
            let cases = parseEnumerators(body)
            if let n = name { addEnum(CEnum(style: .plain, name: n, underlying: underlying, cases: cases, swiftName: swiftName)) }
            else { addEnum(CEnum(style: .anonymous, name: "", underlying: underlying, cases: cases)) }
            if let n = name, let tag, tag != n { model.typedefs.append(CTypedef(name: tag, type: CType(base: n))) }
        } else if let n = name {
            model.structs.removeAll { $0.name == n }
            model.structs.append(CStruct(name: n, fields: keyword == "union" ? [] : parseFields(body)))
            if let tag, tag != n { model.typedefs.append(CTypedef(name: tag, type: CType(base: n))) }
            // `typedef struct {…} Foo, *FooPtr;`
            if trailing.contains("*"), let ptr = names.last, ptr != n {
                var ty = CType(base: n)
                ty.pointers = 1
                model.typedefs.append(CTypedef(name: ptr, type: ty))
            }
        }
        _ = typedefName
    }

    private mutating func parseTypedef() {
        guard let w = peek else { return }
        if ["NS_ENUM", "NS_OPTIONS", "NS_CLOSED_ENUM", "CF_ENUM", "CF_OPTIONS", "CF_CLOSED_ENUM", "NS_ERROR_ENUM"].contains(w) {
            if let e = parseNSEnum() { addEnum(e) }
            _ = declarationTokens()
            return
        }
        if ["enum", "struct", "union"].contains(w) {
            // With a body: a definition. Without: `typedef struct __Foo *FooRef;`.
            var q = p + 1
            while q < t.count, t[q] != "{", t[q] != ";" { q += 1 }
            if q < t.count, t[q] == "{" { parseTagged(typedefName: ""); return }
            let (tokens, _) = declarationTokens()
            let d = parseDeclarator(tokens)
            guard let name = d.name else { return }
            if tokens.contains("(") {
                model.typedefs.append(CTypedef(name: name, type: d.type))
            } else if d.type.pointers > 0, w != "enum" {
                var td = CTypedef(name: name, type: d.type, opaqueStruct: tokens.count > 1 ? tokens[1] : nil)
                td.isTypedEnum = false
                model.typedefs.append(td)
            } else if tokens.count > 2, tokens[1] != name {
                // `typedef struct foo foo_t;` (defined elsewhere, or opaque).
                model.typedefs.append(CTypedef(name: name, type: CType(base: tokens[1])))
            }
            return
        }
        let (raw, _) = declarationTokens()
        let typed = raw.contains("@typedenum")
        let tokens = raw.filter { $0 != "@typedenum" && !$0.hasPrefix("@swiftname:") && $0 != "@unavailable" }
        let d = parseDeclarator(tokens)
        guard let name = d.name else { return }
        model.typedefs.removeAll { $0.name == name }
        var td = CTypedef(name: name, type: d.type)
        td.isTypedEnum = typed
        model.typedefs.append(td)
    }

    /// A function, a variable or something this reader skips.
    private mutating func parseDeclaration() {
        let wasAudited = audited
        let (raw, _) = declarationTokens()
        guard !raw.isEmpty else { return }
        if raw.contains("@unavailable") { return }
        let swiftName = raw.first { $0.hasPrefix("@swiftname:") }.map { String($0.dropFirst("@swiftname:".count)) }
        let managed = implicitBridging || raw.contains("@managed")
        var tokens = raw.filter { !$0.hasPrefix("@swiftname:") && $0 != "@designated" && $0 != "@typedenum" && $0 != "@managed" }
        tokens.removeAll { $0 == "static" }
        guard !tokens.isEmpty else { return }
        // An initializer: `static const int x = 3;`
        var depth = 0
        var eq: Int?
        for (i, w) in tokens.enumerated() {
            if w == "(" { depth += 1 } else if w == ")" { depth -= 1 }
            if w == "=", depth == 0 { eq = i; break }
        }
        if let eq {
            let d = parseDeclarator(Array(tokens[..<eq]))
            guard let name = d.name else { return }
            let value = Array(tokens[(eq + 1)...])
            var ev = ConstantEvaluator(known: constants)
            if let v = ev.evaluate(expandMacros(value)) { constants[name] = v }
            model.variables.removeAll { $0.name == name }
            model.variables.append(CVariable(name: name, type: d.type, value: value, audited: wasAudited))
            return
        }
        // A function: name followed by a parameter list at depth 0, not a
        // function pointer variable `ret (*name)(…)`.
        if let open = tokens.firstIndex(of: "("), open > 0, tokens.last == ")", tokens[open - 1].first.map({ $0.isLetter || $0 == "_" }) == true,
           !typeWords.contains(tokens[open - 1]) || open > 1 {
            let name = tokens[open - 1]
            let head = Array(tokens[..<(open - 1)])
            guard !head.isEmpty else { return }  // a macro invocation
            let result = parseDeclarator(head + ["_"]).type
            var params: [CParam] = []
            var variadic = false
            let inner = Array(tokens[(open + 1)..<(tokens.count - 1)])
            for (i, part) in splitTopLevel(inner).enumerated() {
                if part == ["void"] { continue }
                if part == ["..."] { variadic = true; continue }
                let d = parseDeclarator(part, nameOptional: true)
                params.append(CParam(name: d.name ?? "arg\(i + 1)", type: d.type))
            }
            model.functions.removeAll { $0.name == name }
            var fn = CFunction(name: name, result: result, params: params, isVariadic: variadic, audited: wasAudited, swiftName: swiftName)
            fn.managedResult = managed
            model.functions.append(fn)
            return
        }
        let d = parseDeclarator(tokens)
        guard let name = d.name, d.type.base != name else { return }
        // Several declarators (`extern int a, b;`) are rare; take the first.
        model.variables.removeAll { $0.name == name }
        model.variables.append(CVariable(name: name, type: d.type, value: nil, audited: wasAudited))
    }

    func splitTopLevel(_ tokens: [String]) -> [[String]] {
        var out: [[String]] = [[]]
        var depth = 0
        for w in tokens {
            if w == "(" || w == "<" || w == "[" { depth += 1 } else if w == ")" || w == ">" || w == "]" { depth -= 1 } else if w == ">>" { depth -= 2 }
            if w == ",", depth == 0 { out.append([]) } else { out[out.count - 1].append(w) }
        }
        return out.filter { !$0.isEmpty }
    }

    /// A C declarator: the type and the declared name (the last identifier,
    /// or the one inside `(^name)` / `(*name)`).
    func parseDeclarator(_ tokensIn: [String], nameOptional: Bool = false) -> (name: String?, type: CType) {
        var tokens = tokensIn.filter { $0 != "@designated" && $0 != "@unavailable" && !$0.hasPrefix("@swiftname:") && $0 != "@typedenum" }
        var arrayCount: Int?
        // Trailing array bounds.
        while tokens.last == "]", let open = tokens.lastIndex(of: "[") {
            var ev = ConstantEvaluator(known: constants)
            arrayCount = ev.evaluate(Array(tokens[(open + 1)..<(tokens.count - 1)])).map { Int($0) } ?? 0
            tokens = Array(tokens[..<open])
        }
        // Blocks and function pointers: `ret (^name)(params)`.
        if let open = tokens.firstIndex(of: "("), open + 1 < tokens.count, tokens[open + 1] == "^" || tokens[open + 1] == "*" {
            var depth = 0, close = open
            for i in open..<tokens.count {
                if tokens[i] == "(" { depth += 1 } else if tokens[i] == ")" { depth -= 1; if depth == 0 { close = i; break } }
            }
            let isBlock = tokens[open + 1] == "^"
            let inside = Array(tokens[(open + 2)..<close])
            let result = parseDeclarator(Array(tokens[..<open]) + ["_"]).type
            var params: [CType] = []
            if close + 1 < tokens.count, tokens[close + 1] == "(", tokens.last == ")" {
                for part in splitTopLevel(Array(tokens[(close + 2)..<(tokens.count - 1)])) where part != ["void"] && part != ["..."] {
                    params.append(parseDeclarator(part, nameOptional: true).type)
                }
            }
            var ty = CType(base: "")
            ty.callable = isBlock ? .block(result, params) : .function(result, params)
            var name: String?
            for w in inside {
                switch w {
                case "_Nullable", "nullable", "__nullable", "_Null_unspecified": ty.nullability = w == "_Null_unspecified" ? .unspecified : .nullable
                case "_Nonnull", "nonnull", "__nonnull": ty.nullability = .nonnull
                case "const": break
                default: if w.first.map({ $0.isLetter || $0 == "_" }) == true { name = w }
                }
            }
            // Qualifiers before the block: `nullable void (^)(void)`.
            for w in tokens[..<open] {
                if w == "nullable" || w == "_Nullable" || w == "__nullable" { ty.nullability = .nullable }
                if w == "nonnull" || w == "_Nonnull" { ty.nullability = .nonnull }
            }
            ty.arrayCount = arrayCount
            return (name, ty)
        }
        var ty = CType(base: "")
        var words: [String] = []
        var name: String?
        var i = 0
        var afterStar = false
        while i < tokens.count {
            let w = tokens[i]
            switch w {
            case "const": if !afterStar { ty.isConst = true }
            case "_Nullable", "nullable", "__nullable": ty.nullability = .nullable
            case "_Nonnull", "nonnull", "__nonnull": ty.nullability = .nonnull
            case "_Null_unspecified", "null_unspecified", "__null_unspecified": ty.nullability = .unspecified
            case "null_resettable": ty.nullability = .unspecified
            case "out", "inout", "bycopy", "byref", "oneway", "in":
                if words.isEmpty { if w == "out" || w == "inout" { ty.isOut = true } } else { words.append(w) }
            case "*": ty.pointers += 1; afterStar = true
            case "<":
                // Generic arguments or protocol qualifiers.
                var depth = 0, j = i
                var inner: [String] = []
                while j < tokens.count {
                    let x = tokens[j]
                    if x == "<" { depth += 1; if depth == 1 { j += 1; continue } }
                    if x == ">" { depth -= 1; if depth == 0 { break } }
                    if x == ">>" { depth -= 2; if depth <= 0 { if depth < 0 { inner.append(">") }; break } }
                    inner.append(x)
                    j += 1
                }
                let parts = splitTopLevel(inner)
                let isProtocolList = words.last == "id" || parts.allSatisfy { $0.count == 1 }
                    && !(["NSArray", "NSMutableArray", "NSSet", "NSMutableSet", "NSDictionary", "NSMutableDictionary", "NSOrderedSet", "NSHashTable", "NSMapTable", "NSCache", "NSEnumerator", "NSCountedSet", "NSMeasurement", "NSFetchRequest"].contains(words.last ?? ""))
                    && !parts.contains { $0.contains("*") }
                if isProtocolList { ty.protocols = parts.compactMap(\.first) } else { ty.generics = parts.map { parseDeclarator($0, nameOptional: true).type } }
                i = j
            default:
                words.append(w)
            }
            i += 1
        }
        // The last word is the name, unless only type words remain.
        let qualifiers: Set<String> = ["unsigned", "signed", "long", "short", "struct", "enum", "union", "int", "char", "double", "float", "void"]
        if words.count > 1 {
            let last = words[words.count - 1]
            let rest = Array(words.dropLast())
            // `struct foo` and `unsigned long` are whole types; `struct foo bar`,
            // `unsigned short ch` and `NSString name` end in a name.
            let tagOnly = rest.count == 1 && ["struct", "enum", "union"].contains(rest[0])
            if !qualifiers.contains(last) && !tagOnly {
                name = last
                words.removeLast()
            }
        }
        if name == "_" , tokensIn.last == "_" { name = nil }
        if words.count > 1 { words = words.filter { !["struct", "union", "enum"].contains($0) } }
        ty.base = words.joined(separator: " ")
        ty.arrayCount = arrayCount
        return (name, ty)
    }

    // MARK: Objective-C containers

    private mutating func parseProtocol() {
        p += 1
        guard let name = peek else { return }
        p += 1
        // Forward declarations: `@protocol A, B;`
        if peek == ";" || peek == "," {
            var names = [name]
            while let w = peek, w != ";" { if w != "," { names.append(w) }; p += 1 }
            p += 1
            for n in names where !model.forwardProtocols.contains(n) { model.forwardProtocols.append(n) }
            return
        }
        var c = ObjCContainer(kind: .proto, name: name)
        if peek == "<" { c.protocols = angleNames() }
        parseMembers(&c)
        model.containers.append(c)
    }

    private mutating func angleNames() -> [String] {
        var out: [String] = []
        guard peek == "<" else { return out }
        var depth = 0
        while p < t.count {
            let w = t[p]
            p += 1
            if w == "<" { depth += 1; continue }
            if w == ">" { depth -= 1; if depth == 0 { break }; continue }
            if w != ",", depth == 1, w.first.map({ $0.isLetter || $0 == "_" }) == true { out.append(w) }
        }
        return out
    }

    private mutating func parseInterface() {
        p += 1
        guard let name = peek else { return }
        p += 1
        var c = ObjCContainer(kind: .interface, name: name)
        // Lightweight generics: `@interface Foo<T> : NSObject`.
        if peek == "<" {
            var q = p, depth = 0
            while q < t.count { if t[q] == "<" { depth += 1 } else if t[q] == ">" { depth -= 1; if depth == 0 { break } }; q += 1 }
            if q + 1 < t.count, t[q + 1] == ":" { p = q + 1 }
        }
        if peek == ":" {
            p += 1
            c.superclass = peek
            p += 1
            if peek == "<" {
                // Either the superclass's generic arguments or protocols.
                let save = p
                let names = angleNames()
                if peek == "<" { c.protocols = angleNames() } else if names.allSatisfy({ !$0.isEmpty }) && !t[save..<p].contains("*") { c.protocols = names }
            }
        } else if peek == "(" {
            c.kind = .category
            while let w = peek, w != ")" { p += 1; _ = w }
            p += 1
            if peek == "<" { c.protocols = angleNames() }
        } else if peek == "<" {
            c.protocols = angleNames()
        }
        if peek == "{" { skipBraces() }  // instance variables
        parseMembers(&c)
        model.containers.append(c)
    }

    private mutating func parseMembers(_ c: inout ObjCContainer) {
        var optional = false
        while let w = peek {
            switch w {
            case "@end": p += 1; return
            case "@interface", "@protocol", "@implementation": return  // a missing @end
            case "@optional": optional = true; p += 1
            case "@required": optional = false; p += 1
            case "@audit:on": audited = true; p += 1
            case "@audit:off": audited = false; p += 1
            case "@property": p += 1; parseProperty(&c, optional: optional)
            case "-", "+": parseMethod(&c, optional: optional)
            case "{": skipBraces()
            case "typedef": p += 1; parseTypedef()
            default:
                let start = p
                if ["NS_ENUM", "NS_OPTIONS", "enum", "struct"].contains(w) { parseTopLevel() } else { p += 1 }
                if p <= start { p = start + 1 }
            }
        }
    }

    private mutating func parseProperty(_ c: inout ObjCContainer, optional: Bool) {
        var prop = ObjCProperty(name: "", type: CType(base: "id"), isOptional: optional, audited: audited)
        var attrNullability: CType.Nullability?
        if peek == "(" {
            p += 1
            var attrs: [[String]] = [[]]
            var depth = 1
            while p < t.count {
                let w = t[p]
                p += 1
                if w == "(" { depth += 1 }
                if w == ")" { depth -= 1; if depth == 0 { break } }
                if w == ",", depth == 1 { attrs.append([]) } else { attrs[attrs.count - 1].append(w) }
            }
            for a in attrs {
                switch a.first {
                case "readonly": prop.isReadonly = true
                case "class": prop.isClass = true
                case "weak": prop.isWeak = true
                case "nullable": attrNullability = .nullable
                case "nonnull": attrNullability = .nonnull
                case "null_resettable", "null_unspecified": attrNullability = .unspecified
                case "getter": if a.count >= 3 { prop.getter = a[2] }
                default: break
                }
            }
        }
        let (raw, _) = declarationTokens()
        if raw.contains("@unavailable") { return }
        prop.swiftName = raw.first { $0.hasPrefix("@swiftname:") }.map { String($0.dropFirst("@swiftname:".count)) }
        let d = parseDeclarator(raw)
        guard let name = d.name else { return }
        prop.name = name
        prop.type = d.type
        if prop.type.nullability == nil { prop.type.nullability = attrNullability }
        c.properties.removeAll { $0.name == name && $0.isClass == prop.isClass }
        c.properties.append(prop)
    }

    private mutating func parseMethod(_ c: inout ObjCContainer, optional: Bool) {
        let isClass = peek == "+"
        p += 1
        let wasAudited = audited
        var tokens: [String] = []
        var depth = 0
        while p < t.count {
            let w = t[p]
            if w == "(" { depth += 1 } else if w == ")" { depth -= 1 }
            if depth == 0, w == ";" { p += 1; break }
            if depth == 0, w == "{" { skipBraces(); if peek == ";" { p += 1 }; break }
            if depth == 0, ["@end", "@property", "@optional", "@required"].contains(w) { break }
            if depth == 0, (w == "-" || w == "+"), !tokens.isEmpty, tokens.last != ":" { break }
            tokens.append(w)
            p += 1
        }
        if tokens.contains("@unavailable") { return }
        let designated = tokens.contains("@designated")
        let swiftName = tokens.first { $0.hasPrefix("@swiftname:") }.map { String($0.dropFirst("@swiftname:".count)) }
        tokens.removeAll { $0.hasPrefix("@") && !$0.hasPrefix("@\"") }
        var i = 0
        func parenthesized() -> [String]? {
            guard i < tokens.count, tokens[i] == "(" else { return nil }
            var depth = 0
            var out: [String] = []
            while i < tokens.count {
                let w = tokens[i]
                i += 1
                if w == "(" { depth += 1; if depth == 1 { continue } }
                if w == ")" { depth -= 1; if depth == 0 { break } }
                out.append(w)
            }
            return out
        }
        var result = CType(base: "id")
        if let r = parenthesized() { result = parseDeclarator(r + ["_"]).type }
        var pieces: [(String, CParam?)] = []
        while i < tokens.count {
            var label = ""
            if tokens[i] != ":" { label = tokens[i]; i += 1 }
            if i < tokens.count, tokens[i] == ":" {
                i += 1
                var ty = CType(base: "id")
                if let pt = parenthesized() { ty = parseDeclarator(pt + ["_"]).type }
                var name = "arg\(pieces.count + 1)"
                if i < tokens.count, tokens[i] != ":", tokens[i] != "," { name = tokens[i]; i += 1 }
                pieces.append((label, CParam(name: name, type: ty)))
            } else {
                if label.isEmpty || label == "," || label == "..." { i += 1; continue }
                pieces.append((label, nil))
                // `, ...` variadics and trailing attributes end the selector.
                break
            }
        }
        guard !pieces.isEmpty else { return }
        var m = ObjCMethod(isClass: isClass, result: result, pieces: pieces.map { (label: $0.0, param: $0.1) }, swiftName: swiftName, isOptional: optional, audited: wasAudited)
        m.isDesignated = designated
        let sel = m.selector
        c.methods.removeAll { $0.selector == sel && $0.isClass == isClass }
        c.methods.append(m)
    }
}
