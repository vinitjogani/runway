// Overrides declared in extensions move into the class body.
//
// On Apple platforms an extension of an Objective-C class may override a
// superclass member (`extension Editor { override func mouseDown(with:) }`):
// the runtime dispatches it. Swift without that runtime rejects it ("cannot
// be overridden from extension"), so each such member (`override` methods,
// properties and subscripts, `override`/`required` initializers) moves into
// the body of its class, which may be in another file:
//
//   - In the extension's file the member is blanked in place (a comment on
//     its first line, its newlines kept), so no other line moves.
//   - In the class's file the members are inserted just before the closing
//     brace, each under `#sourceLocation(file: <extension file>, line: <its
//     line>)` and its `#if` conditions; then `#sourceLocation(file: <class
//     file>, line: <closing brace's line>)` puts the class file back, so
//     diagnostics, `#filePath` and `#line` keep naming the original place.
//     (Directives replace each other; `runway`'s outer wrapper names the
//     same class file, and its closing `#sourceLocation()` still ends it.)
//   - The class file gains the extension file's top-level imports it lacks
//     (`; import X` on its first import line, as for RunwayObjC).
//   - Access: a moved member now lives in another file, so the file-private
//     declarations of its own file it references (`private`/`fileprivate`,
//     at file scope or as members of any type or extension there, including
//     a `private extension`) become `internal` there, and so, transitively,
//     do the file-private declarations those reference (a private helper's
//     private parameter type…). Matching is by name: an over-approximation
//     that only ever widens to `internal` within the module, never
//     narrowing anything. A moved member's own `private`/`fileprivate` goes
//     too (the extension file's dispatch table may still call it).
//
// Left in place, with a comment after the file's last line saying why:
// overrides in generic or constrained extensions (`extension Foo<Int>`,
// `extension Foo where T: P`), and in extensions of classes declared
// outside the package or in another of its modules.
//
// The class's file learns what to insert from the package index (each
// file's scan records its extension overrides and keeps its syntax tree), so
// files can be transformed one at a time, in any order: members are ordered
// by (file path, offset), and each extension file's rewritten member text is
// computed once per index and cached.

import Foundation
import SwiftSyntax

/// An `override` (or `required`) member declared in an extension.
struct ExtensionOverride {
    var typeName: String
    var file: String
    /// The member item: its first token (attributes included) to its end (`;` included).
    var start: Int
    var end: Int
    /// The extension's and the member's `#if` conditions, outermost first.
    var conditions: [String]
    /// The extension has generic arguments or a `where` clause.
    var constrained: Bool
    /// "override func mouseDown(with:)", for comments.
    var summary: String
    /// Names the member's text mentions.
    var identifiers: Set<String>
}

/// A `private`/`fileprivate` declaration (not local), for relaxing.
struct FilePrivateDecl {
    var names: [String]
    var identifiers: Set<String>
}

enum OverridePlacement {
    case move(ClassFact)
    case leave(String)
}

// MARK: Syntax

enum Relocate {
    static let beginMarker = "// RunwayTranspiler: overrides moved here from extensions (Swift without the Objective-C runtime can't override from one)"
    static let endMarker = "// RunwayTranspiler: end of moved overrides"

    /// The override items of an extension's member block (through `#if`).
    static func overrideItems(_ block: MemberBlockSyntax) -> [MemberBlockItemSyntax] {
        var out: [MemberBlockItemSyntax] = []
        func walk(_ items: MemberBlockItemListSyntax) {
            for item in items {
                if let ifc = item.decl.as(IfConfigDeclSyntax.self) {
                    for clause in ifc.clauses { if case .decls(let d)? = clause.elements { walk(d) } }
                } else if isOverride(item.decl) {
                    out.append(item)
                }
            }
        }
        walk(block.members)
        return out
    }

    static func isOverride(_ d: DeclSyntax) -> Bool {
        if let f = d.as(FunctionDeclSyntax.self) { return f.modifiers.has("override") }
        if let v = d.as(VariableDeclSyntax.self) { return v.modifiers.has("override") }
        if let s = d.as(SubscriptDeclSyntax.self) { return s.modifiers.has("override") }
        if let i = d.as(InitializerDeclSyntax.self) { return i.modifiers.has("override") || i.modifiers.has("required") }
        return false
    }

    static func overrides(in ext: ExtensionDeclSyntax, path: String) -> [ExtensionOverride] {
        let items = overrideItems(ext.memberBlock)
        guard !items.isEmpty else { return [] }
        let constrained = ext.genericWhereClause != nil || hasGenericArguments(ext.extendedType)
        let name = typeName(ext.extendedType)
        return items.map { item in
            ExtensionOverride(
                typeName: name, file: path,
                start: item.positionAfterSkippingLeadingTrivia.utf8Offset, end: item.endPositionBeforeTrailingTrivia.utf8Offset,
                conditions: ifConditions(of: item), constrained: constrained, summary: summary(item.decl),
                identifiers: identifiers(in: item))
        }
    }

    static func hasGenericArguments(_ t: TypeSyntax) -> Bool {
        if let i = t.as(IdentifierTypeSyntax.self) { return i.genericArgumentClause != nil }
        if let m = t.as(MemberTypeSyntax.self) { return m.genericArgumentClause != nil || hasGenericArguments(m.baseType) }
        return !t.is(IdentifierTypeSyntax.self) && !t.is(MemberTypeSyntax.self)
    }

    static func summary(_ d: DeclSyntax) -> String {
        if let f = d.as(FunctionDeclSyntax.self) {
            let labels = f.signature.parameterClause.parameters.map { ($0.firstName.tokenKind == .wildcard ? "_" : $0.firstName.text) + ":" }
            return "override func \(f.name.text)(\(labels.joined()))"
        }
        if let v = d.as(VariableDeclSyntax.self) { return "override var " + v.bindings.map { $0.pattern.trimmedDescription }.joined(separator: ", ") }
        if d.is(SubscriptDeclSyntax.self) { return "override subscript" }
        if let i = d.as(InitializerDeclSyntax.self) {
            let labels = i.signature.parameterClause.parameters.map { ($0.firstName.tokenKind == .wildcard ? "_" : $0.firstName.text) + ":" }
            return (i.modifiers.has("required") ? "required" : "override") + " init(\(labels.joined()))"
        }
        return "override"
    }

    static func identifiers(in node: some SyntaxProtocol) -> Set<String> {
        var out = Set<String>()
        for t in node.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let s) = t.tokenKind { out.insert(s.hasPrefix("`") ? String(s.dropFirst().dropLast()) : s) }
        }
        return out
    }

    /// The names a declaration introduces (a `private extension`'s: its members').
    static func declNames(_ d: Syntax) -> [String] {
        if let f = d.as(FunctionDeclSyntax.self) { return [f.name.text] }
        if let v = d.as(VariableDeclSyntax.self) {
            return v.bindings.flatMap { b in Array(identifiers(in: b.pattern)) }
        }
        if let c = d.as(ClassDeclSyntax.self) { return [c.name.text] }
        if let s = d.as(StructDeclSyntax.self) { return [s.name.text] }
        if let e = d.as(EnumDeclSyntax.self) { return [e.name.text] }
        if let a = d.as(ActorDeclSyntax.self) { return [a.name.text] }
        if let p = d.as(ProtocolDeclSyntax.self) { return [p.name.text] }
        if let t = d.as(TypeAliasDeclSyntax.self) { return [t.name.text] }
        if d.is(SubscriptDeclSyntax.self) { return ["subscript"] }
        if d.is(InitializerDeclSyntax.self) {
            // `Helper(…)` names the type.
            var p = d.parent
            while let n = p {
                if let c = n.as(ClassDeclSyntax.self) { return [c.name.text] }
                if let s = n.as(StructDeclSyntax.self) { return [s.name.text] }
                if let e = n.as(EnumDeclSyntax.self) { return [e.name.text] }
                if let a = n.as(ActorDeclSyntax.self) { return [a.name.text] }
                if let x = n.as(ExtensionDeclSyntax.self) { return [String(typeName(x.extendedType).split(separator: ".").last ?? "")] }
                p = n.parent
            }
        }
        if let x = d.as(ExtensionDeclSyntax.self) {
            var names: [String] = []
            func walk(_ items: MemberBlockItemListSyntax) {
                for item in items {
                    if let ifc = item.decl.as(IfConfigDeclSyntax.self) {
                        for clause in ifc.clauses { if case .decls(let ds)? = clause.elements { walk(ds) } }
                    } else {
                        names += declNames(Syntax(item.decl))
                    }
                }
            }
            walk(x.memberBlock.members)
            return names
        }
        return []
    }

    /// The declaration a file-private modifier belongs to, if it's one that
    /// relaxing can concern (not local; `private`/`fileprivate`, with or
    /// without `(set)`).
    static func filePrivateDecl(of m: DeclModifierSyntax) -> Syntax? {
        guard m.name.text == "private" || m.name.text == "fileprivate",
              let decl = m.parent?.parent, decl.is(DeclSyntax.self), !isLocalDecl(decl) else { return nil }
        return decl
    }

    /// Every file-private declaration of a file (only read for files that
    /// lose overrides).
    static func filePrivateDecls(_ tree: SourceFileSyntax) -> [FilePrivateDecl] {
        final class Finder: SyntaxVisitor {
            var found: [FilePrivateDecl] = []
            override func visit(_ node: DeclModifierSyntax) -> SyntaxVisitorContinueKind {
                if let d = Relocate.filePrivateDecl(of: node) {
                    found.append(FilePrivateDecl(names: Relocate.declNames(d), identifiers: Relocate.identifiers(in: d)))
                }
                return .skipChildren
            }
        }
        let f = Finder(viewMode: .sourceAccurate)
        f.walk(tree)
        return f.found
    }

    /// A top-level import, as the class file should repeat it.
    static func importText(_ i: ImportDeclSyntax) -> String {
        let attrs = i.attributes.compactMap { a -> String? in
            guard case .attribute(let attr) = a else { return nil }
            let n = Selectors.attributeName(attr)
            return n == "testable" || n == "preconcurrency" ? "@" + n + " " : nil
        }.joined()
        let kind = i.importKindSpecifier.map { $0.text + " " } ?? ""
        return attrs + "import " + kind + i.path.trimmedDescription
    }

    static func lit(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 1-based line and column of a byte offset.
    static func location(_ offset: Int, _ bytes: [UInt8]) -> (line: Int, column: Int) {
        var line = 1, lineStart = 0
        var i = 0
        while i < offset && i < bytes.count {
            if bytes[i] == 0x0A { line += 1; lineStart = i + 1 }
            i += 1
        }
        return (line, offset - lineStart + 1)
    }
}

// MARK: The package's view

extension PackageIndex {
    /// Where an extension override goes.
    func placement(_ o: ExtensionOverride) -> OverridePlacement {
        if o.constrained {
            return .leave("the extension is generic or constrained, so its members can't join the class body")
        }
        let q = resolveTypeName(o.typeName)
        let t = target(of: o.file)
        let simple = String(q.split(separator: ".").last ?? Substring(q))
        let candidates = (classesBySimpleNameView[simple] ?? []).filter { $0.qualifiedName == q && !$0.isLocal }
        if let c = candidates.first(where: { target(of: $0.file) == t }) { return .move(c) }
        if let c = candidates.first { return .leave("\(q) is declared in another module (\(target(of: c.file)))") }
        return .leave("\(o.typeName) isn't a class declared in this package")
    }

    /// The overrides moving into `q`'s body (declared in `classFile`), in a
    /// fixed order: by file, then position.
    func movedOverrides(into q: String, classFile: String) -> [ExtensionOverride] {
        extensionOverrides.filter {
            if case .move(let c) = placement($0) { return c.qualifiedName == q && c.file == classFile }
            return false
        }.sorted { ($0.file, $0.start) < ($1.file, $1.start) }
    }

    /// Overrides of `file` that move to another file.
    func outgoingOverrides(of file: String) -> [ExtensionOverride] {
        (files[file]?.extensionOverrides ?? []).filter {
            if case .move(let c) = placement($0) { return c.file != file }
            return false
        }
    }

    /// Names of `file`'s file-private declarations that become internal:
    /// those its outgoing overrides reference, transitively.
    func relaxedNames(in file: String) -> Set<String> {
        if let c = withRelocationLock({ relaxedCache[file] }) { return c }
        var result = Set<String>()
        let outgoing = outgoingOverrides(of: file)
        if !outgoing.isEmpty, let tree = files[file]?.tree {
            let decls = Relocate.filePrivateDecls(tree)
            var refs = outgoing.reduce(into: Set<String>()) { $0.formUnion($1.identifiers) }
            var done = Array(repeating: false, count: decls.count)
            var changed = true
            while changed {
                changed = false
                for (i, d) in decls.enumerated() where !done[i] && d.names.contains(where: refs.contains) {
                    done[i] = true
                    changed = true
                    result.formUnion(d.names)
                    refs.formUnion(d.identifiers)
                }
            }
        }
        withRelocationLock { relaxedCache[file] = result }
        return result
    }

    /// `o`'s text as the transpiler rewrites it in its own file.
    func movedText(_ o: ExtensionOverride) -> String {
        if let t = withRelocationLock({ movedTextCache[o.file]?[o.start] }) { return t }
        guard let facts = files[o.file], let tree = facts.tree else { return "" }
        let bytes = Array(tree.syntaxTextBytes)
        let r = Rewriter(index: self, path: o.file, bytes: bytes, movedTextMode: true)
        r.walk(tree)
        var texts: [Int: String] = [:]
        for m in facts.extensionOverrides {
            let inner = r.edits.filter { $0.start >= m.start && $0.end <= m.end }.map {
                Edit(start: $0.start - m.start, end: $0.end - m.start, text: $0.text, seq: $0.seq)
            }
            texts[m.start] = String(decoding: RunwayTranspiler.apply(inner, to: Array(bytes[m.start..<m.end])), as: UTF8.self)
        }
        withRelocationLock { movedTextCache[o.file] = texts }
        return texts[o.start] ?? ""
    }

    /// The block inserted before `q`'s closing brace (which is at `braceOffset`
    /// of `classFile`, whose text is `bytes`), and the imports it needs.
    func movedBlock(into q: String, classFile: String, braceOffset: Int, bytes: [UInt8]) -> (text: String, imports: [String])? {
        let moved = movedOverrides(into: q, classFile: classFile)
        guard !moved.isEmpty else { return nil }
        var text = "\n" + Relocate.beginMarker + "\n"
        var imports = Set<String>()
        for o in moved {
            let member = movedText(o)
            guard let tree = files[o.file]?.tree else { continue }
            let at = Relocate.location(o.start, Array(tree.syntaxTextBytes))
            // The directive goes outside the `#if` (SwiftSyntax doesn't take
            // one inside a member block's `#if`), naming the `#if` line as the
            // line before the member's (it's inside one, so there is one).
            if o.conditions.isEmpty {
                text += "#sourceLocation(file: \(Relocate.lit(o.file)), line: \(at.line))\n"
            } else {
                text += "#sourceLocation(file: \(Relocate.lit(o.file)), line: \(max(1, at.line - 1)))\n"
                text += "#if " + o.conditions.joined(separator: " && ") + "\n"
            }
            text += String(repeating: " ", count: at.column - 1) + member + "\n"
            if !o.conditions.isEmpty { text += "#endif\n" }
            if o.file != classFile { imports.formUnion(files[o.file]?.imports ?? []) }
            if member.contains("RunwayObjC.") { imports.insert("import RunwayObjC") }
        }
        let brace = Relocate.location(braceOffset, bytes)
        text += Relocate.endMarker + "\n"
        text += "#sourceLocation(file: \(Relocate.lit(classFile)), line: \(brace.line))\n"
        // The brace now starts its line: keep its column.
        text += String(repeating: " ", count: brace.column - 1)
        let have = Set(files[classFile]?.imports ?? [])
        return (text, imports.subtracting(have).sorted())
    }
}
