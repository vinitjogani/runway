// The first pass: what each file declares that the Objective-C runtime would
// see (classes, their selector-reachable members, `@objc optional`
// requirements) and which selectors it names. The package index merges
// these so each file's rewrite knows about the rest of the package.

import SwiftSyntax

struct ParamFact: Hashable {
    var label: String?
    var typeText: String
}

struct MemberFact {
    enum Kind {
        case method(params: [ParamFact], throws: Bool, mainActor: Bool)
        case property(settable: Bool, notifies: Bool)
    }
    var kind: Kind
    var name: String
    /// The method's selector, or the property's getter selector.
    var selector: String
    /// Selector for the property's setter, when it has one.
    var setterSelector: String?
    /// `@objc`, `@IBAction`, `dynamic`… (before `@objcMembers` applies).
    var explicit: Bool
    var nonobjc: Bool
    /// Declared in an `@objc extension`.
    var inObjCExtension: Bool
    /// In the class body (not an extension).
    var inBody: Bool
    var isPrivate: Bool
    /// Can be called from a generated table (not generic, async, inout…).
    var dispatchable: Bool
    var conditions: [String]
    var file: String
}

struct ClassFact {
    var qualifiedName: String
    var name: String
    var superName: String?
    var access: String
    var isLocal: Bool
    var objcMembers: Bool
    var mainActor: Bool
    var conditions: [String]
    var file: String
}

struct OptionalRequirement {
    var name: String
    var labels: [String?]?   // nil for a property
    var selector: String
}

/// A type the file extends (the extension's members are in `members`).
struct ExtensionFact {
    var typeName: String
    var conditions: [String]
}

final class FileFacts {
    let path: String
    var classes: [ClassFact] = []
    var extensions: [ExtensionFact] = []
    /// Members by the qualified name of the type that declares them.
    var members: [String: [MemberFact]] = [:]
    var selectorRefs: Set<String> = []
    /// Bare names from `#selector(foo)` (arity unknown).
    var selectorBaseRefs: Set<String> = []
    var optionalRequirements: [OptionalRequirement] = []
    var propertyNames: Set<String> = []
    /// Structs, enums, protocols and actors the file declares.
    var nonClassTypes: Set<String> = []
    /// Types (qualified) implementing these hooks, for `override` decisions.
    var observeValueTypes: Set<String> = []
    var validateTypes: [String: Set<String>] = [:]
    /// `override` members of extensions, which move into their class's body.
    var extensionOverrides: [ExtensionOverride] = []
    /// Top-level imports (outside `#if`), as `Relocate.importText` spells them.
    var imports: [String] = []
    /// The file's tree, kept when it has extension overrides (their text is
    /// rewritten for the class's file).
    var tree: SourceFileSyntax?

    init(path: String) { self.path = path }
}

/// Validation hooks AppKit calls by selector (NSObject has no such methods
/// off Apple platforms, so `override` is dropped when the superclass isn't
/// in the package).
let validationHooks: Set<String> = ["validateMenuItem", "validateToolbarItem", "validateUserInterfaceItem"]

/// Methods nib loading sends by selector that NSObject declares on the Mac
/// but not off Apple platforms: in classes rooted in NSObject, `override` and
/// `super.awakeFromNib()` go (AppKit's responders, menus and cells declare them).
let nsObjectHooks: Set<String> = ["awakeFromNib", "prepareForInterfaceBuilder"]

let strippedAttributes: Set<String> = [
    "objc", "objcMembers", "nonobjc", "IBAction", "IBOutlet", "IBOutletCollection", "IBInspectable",
    "IBDesignable", "IBSegueAction", "NSManaged", "GKInspectable",
]
let explicitAttributes: Set<String> = ["objc", "IBAction", "IBOutlet", "IBOutletCollection", "IBInspectable", "IBSegueAction", "NSManaged"]

// MARK: Syntax helpers

extension AttributeListSyntax {
    func names() -> [String] {
        compactMap { if case .attribute(let a) = $0 { return Selectors.attributeName(a) }; return nil }
    }
    func has(_ name: String) -> Bool { names().contains(name) }
}

extension DeclModifierListSyntax {
    func has(_ name: String) -> Bool { contains { $0.name.text == name } }
    var accessLevel: String {
        for m in self {
            switch m.name.text {
            case "open", "public", "package", "internal", "fileprivate", "private":
                if m.detail == nil { return m.name.text }
            default: break
            }
        }
        return ""
    }
}

func isLocalDecl(_ node: some SyntaxProtocol) -> Bool {
    var p = node.parent
    while let n = p {
        if n.is(CodeBlockSyntax.self) || n.is(ClosureExprSyntax.self) || n.is(AccessorBlockSyntax.self) { return true }
        if n.is(SourceFileSyntax.self) { return false }
        p = n.parent
    }
    return false
}

/// `#if` conditions enclosing a node, outermost first, each as a condition
/// that holds exactly when that clause is active.
func ifConditions(of node: some SyntaxProtocol) -> [String] {
    var out: [String] = []
    var p = Syntax(node).parent
    while let n = p {
        if let clause = n.as(IfConfigClauseSyntax.self), let list = clause.parent?.as(IfConfigClauseListSyntax.self) {
            var parts: [String] = []
            for c in list {
                if c.id == clause.id {
                    if let cond = c.condition { parts.append("(" + Conditions.rewrite(cond.trimmedDescription) + ")") }
                    break
                }
                if let cond = c.condition { parts.append("!(" + Conditions.rewrite(cond.trimmedDescription) + ")") }
            }
            out.insert(parts.isEmpty ? "true" : parts.joined(separator: " && "), at: 0)
        }
        p = n.parent
    }
    return out
}

/// The name a type expression refers to, without generic arguments
/// (`Foo<T>` → `Foo`, `Outer.Inner` → `Outer.Inner`).
func typeName(_ t: TypeSyntax) -> String {
    if let i = t.as(IdentifierTypeSyntax.self) { return i.name.text }
    if let m = t.as(MemberTypeSyntax.self) { return typeName(m.baseType) + "." + m.name.text }
    if let a = t.as(AttributedTypeSyntax.self) { return typeName(a.baseType) }
    return t.trimmedDescription
}

enum Conditions {
    /// `#if` condition text with the Mac's answers for platform checks:
    /// `os(macOS)`/`os(OSX)` hold, `targetEnvironment(macCatalyst)` doesn't.
    static func rewrite(_ s: String) -> String {
        guard s.contains("os") || s.contains("macCatalyst") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if let (len, repl) = match(s, i) {
                out += repl
                i = s.index(i, offsetBy: len)
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func match(_ s: String, _ i: String.Index) -> (Int, String)? {
        if i > s.startIndex {
            let prev = s[s.index(before: i)]
            if prev.isLetter || prev.isNumber || prev == "_" { return nil }
        }
        for (fn, args, value) in [("os", ["macOS", "OSX"], "true"), ("targetEnvironment", ["macCatalyst"], "false")] {
            guard s[i...].hasPrefix(fn) else { continue }
            var j = s.index(i, offsetBy: fn.count)
            func skip() { while j < s.endIndex, s[j] == " " || s[j] == "\t" { j = s.index(after: j) } }
            skip()
            guard j < s.endIndex, s[j] == "(" else { continue }
            j = s.index(after: j); skip()
            for a in args where s[j...].hasPrefix(a) {
                var k = s.index(j, offsetBy: a.count)
                while k < s.endIndex, s[k] == " " || s[k] == "\t" { k = s.index(after: k) }
                if k < s.endIndex, s[k] == ")" {
                    return (s.distance(from: i, to: s.index(after: k)), value)
                }
            }
        }
        return nil
    }
}

// MARK: The scanner

final class Scanner: SyntaxVisitor {
    let facts: FileFacts
    /// Enclosing type contexts: (qualified name, kind, @objc extension).
    private var contexts: [(name: String, kind: String, objcExt: Bool)] = []

    init(path: String) {
        facts = FileFacts(path: path)
        super.init(viewMode: .sourceAccurate)
    }

    private func qualified(_ name: String) -> String {
        guard let outer = contexts.last else { return name }
        return outer.name + "." + name
    }

    override func visit(_ node: SourceFileSyntax) -> SyntaxVisitorContinueKind { facts.tree = node; return .visitChildren }
    override func visitPost(_ node: SourceFileSyntax) { if facts.extensionOverrides.isEmpty { facts.tree = nil } }

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.parent?.parent?.parent?.is(SourceFileSyntax.self) == true { facts.imports.append(Relocate.importText(node)) }
        return .skipChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let q = qualified(node.name.text)
        let sup = node.inheritanceClause?.inheritedTypes.first.map { typeName($0.type) }
        facts.classes.append(ClassFact(
            qualifiedName: q, name: node.name.text, superName: sup.map { String($0.split(separator: ".").last ?? Substring($0)) },
            access: node.modifiers.accessLevel, isLocal: isLocalDecl(node),
            objcMembers: node.attributes.has("objcMembers"), mainActor: node.attributes.has("MainActor"),
            conditions: ifConditions(of: node), file: facts.path))
        contexts.append((q, "class", false))
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { contexts.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { facts.nonClassTypes.insert(qualified(node.name.text)); contexts.append((qualified(node.name.text), "struct", false)); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { contexts.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { facts.nonClassTypes.insert(qualified(node.name.text)); contexts.append((qualified(node.name.text), "enum", false)); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { contexts.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { facts.nonClassTypes.insert(qualified(node.name.text)); contexts.append((qualified(node.name.text), "actor", false)); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { contexts.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = typeName(node.extendedType)
        if !isLocalDecl(node) { facts.extensionOverrides += Relocate.overrides(in: node, path: facts.path) }
        facts.extensions.append(ExtensionFact(typeName: name, conditions: ifConditions(of: node)))
        contexts.append((name, "extension", node.attributes.has("objc")))
        return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { contexts.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        facts.nonClassTypes.insert(qualified(node.name.text))
        guard node.attributes.has("objc") else { return .visitChildren }
        for item in node.memberBlock.members {
            if let f = item.decl.as(FunctionDeclSyntax.self), f.modifiers.has("optional") {
                let labels = Selectors.labels(f.signature.parameterClause.parameters)
                let sel = Selectors.explicitName(f.attributes) ?? Selectors.name(base: f.name.text, labels: labels)
                facts.optionalRequirements.append(OptionalRequirement(name: f.name.text, labels: labels, selector: sel))
            } else if let v = item.decl.as(VariableDeclSyntax.self), v.modifiers.has("optional") {
                for b in v.bindings {
                    if let id = b.pattern.as(IdentifierPatternSyntax.self) {
                        facts.optionalRequirements.append(OptionalRequirement(name: id.identifier.text, labels: nil,
                                                                              selector: Selectors.explicitName(v.attributes) ?? id.identifier.text))
                    }
                }
            }
        }
        return .skipChildren
    }

    private var inTypeMember: (name: String, kind: String, objcExt: Bool)? {
        guard let c = contexts.last, c.kind == "class" || c.kind == "extension" else { return nil }
        return c
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let ctx = inTypeMember, isMember(node) else { return .visitChildren }
        let name = node.name.text
        if name == "observeValue", node.signature.parameterClause.parameters.count == 4 { facts.observeValueTypes.insert(ctx.name) }
        if validationHooks.contains(name) { facts.validateTypes[ctx.name, default: []].insert(name) }
        if node.modifiers.has("static") || node.modifiers.has("class") { return .visitChildren }
        let params = node.signature.parameterClause.parameters
        let labels = Selectors.labels(params)
        let sel = Selectors.explicitName(node.attributes) ?? Selectors.name(base: name, labels: labels)
        let isAsync = node.signature.effectSpecifiers?.asyncSpecifier != nil
        let throwsClause = node.signature.effectSpecifiers?.throwsClause != nil
        var dispatchable = node.genericParameterClause == nil && !isAsync
        for p in params {
            let t = p.type.trimmedDescription
            if p.ellipsis != nil || t.hasPrefix("inout ") || t.hasPrefix("some ") || t.contains("some ") { dispatchable = false }
        }
        if case .identifier = node.name.tokenKind {} else { dispatchable = false }  // operators
        let explicit = node.attributes.names().contains { explicitAttributes.contains($0) } || node.modifiers.has("dynamic")
        let m = MemberFact(
            kind: .method(params: params.map { ParamFact(label: $0.firstName.tokenKind == .wildcard ? nil : $0.firstName.text, typeText: $0.type.trimmedDescription) },
                          throws: throwsClause, mainActor: node.attributes.has("MainActor")),
            name: name, selector: sel, setterSelector: nil, explicit: explicit,
            nonobjc: node.attributes.has("nonobjc"), inObjCExtension: ctx.objcExt, inBody: ctx.kind == "class",
            isPrivate: ["private", "fileprivate"].contains(node.modifiers.accessLevel),
            dispatchable: dispatchable, conditions: ifConditions(of: node), file: facts.path)
        facts.members[ctx.name, default: []].append(m)
        return .visitChildren
    }

    private func isMember(_ node: some SyntaxProtocol) -> Bool {
        // Directly in a member block (possibly through #if clauses).
        var p = node.parent
        while let n = p {
            if n.is(MemberBlockSyntax.self) { return true }
            if n.is(CodeBlockSyntax.self) || n.is(ClosureExprSyntax.self) || n.is(AccessorBlockSyntax.self) || n.is(SourceFileSyntax.self) { return false }
            p = n.parent
        }
        return false
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for b in node.bindings { if let id = b.pattern.as(IdentifierPatternSyntax.self) { facts.propertyNames.insert(id.identifier.text) } }
        guard let ctx = inTypeMember, isMember(node), !node.modifiers.has("static"), !node.modifiers.has("class") else { return .visitChildren }
        let explicit = node.attributes.names().contains { explicitAttributes.contains($0) } || node.modifiers.has("dynamic")
        let isLet = node.bindingSpecifier.tokenKind == .keyword(.let)
        for b in node.bindings {
            guard let id = b.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = id.identifier.text
            let objcName = (node.bindings.count == 1 ? Selectors.explicitName(node.attributes) : nil) ?? name
            var settable = !isLet
            var computed = false
            if let acc = b.accessorBlock {
                switch acc.accessors {
                case .getter: settable = false; computed = true
                case .accessors(let list):
                    let kinds = list.map { $0.accessorSpecifier.text }
                    if kinds.contains("get") || kinds.contains("_read") {
                        computed = true
                        settable = kinds.contains("set") || kinds.contains("_modify")
                    }
                }
            }
            let notifies = node.modifiers.has("dynamic") && !computed && !isLet && node.bindings.count == 1 && !node.modifiers.has("lazy") && ctx.kind == "class"
            facts.members[ctx.name, default: []].append(MemberFact(
                kind: .property(settable: settable, notifies: notifies), name: name, selector: objcName,
                setterSelector: settable ? Selectors.setter(objcName) : nil, explicit: explicit,
                nonobjc: node.attributes.has("nonobjc"), inObjCExtension: ctx.objcExt, inBody: ctx.kind == "class",
                isPrivate: ["private", "fileprivate"].contains(node.modifiers.accessLevel),
                dispatchable: true, conditions: ifConditions(of: node), file: facts.path))
        }
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "selector", let ref = SelectorExpr.parse(node) {
            switch ref {
            case .resolved(let s): facts.selectorRefs.insert(s)
            case .bare(let base, _): facts.selectorBaseRefs.insert(base)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Selector("name:") and NSSelectorFromString("name:") name selectors too.
        let callee = node.calledExpression.trimmedDescription
        if callee == "Selector" || callee == "NSSelectorFromString", node.arguments.count == 1,
           let lit = node.arguments.first?.expression.as(StringLiteralExprSyntax.self),
           lit.segments.count == 1, case .stringSegment(let seg)? = lit.segments.first {
            facts.selectorRefs.insert(seg.content.text)
        }
        return .visitChildren
    }
}

/// What a `#selector(...)` names.
enum SelectorExpr {
    case resolved(String)
    /// `#selector(foo)` or `#selector(Type.foo)`: arity from the package.
    case bare(base: String, type: String?)

    static func parse(_ node: MacroExpansionExprSyntax) -> SelectorExpr? {
        guard let arg = node.arguments.first else { return nil }
        var expr = arg.expression
        let kind = arg.label?.text
        // Strip `as (T) -> U` coercions.
        if let a = expr.as(AsExprSyntax.self) { expr = a.expression }
        if let s = expr.as(SequenceExprSyntax.self), let f = s.elements.first { expr = f }
        var typePrefix: String?
        var ref: DeclReferenceExprSyntax?
        if let d = expr.as(DeclReferenceExprSyntax.self) {
            ref = d
        } else if let m = expr.as(MemberAccessExprSyntax.self) {
            ref = m.declName
            if let base = m.base {
                let t = base.trimmedDescription
                if t != "self" && t != "super" { typePrefix = t.split(separator: ".").last.map(String.init) }
            }
        }
        guard let ref else { return nil }
        let base = ref.baseName.text
        if kind == "getter" { return .resolved(base) }
        if kind == "setter" { return .resolved(Selectors.setter(base)) }
        if let args = ref.argumentNames {
            let labels: [String?] = args.arguments.map { $0.name.tokenKind == .wildcard ? nil : $0.name.text }
            return .resolved(Selectors.name(base: base, labels: labels))
        }
        return .bare(base: base, type: typePrefix)
    }
}
