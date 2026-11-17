// The second pass: text edits to one file. Every edit stays on the line it
// replaces, so line numbers (and diagnostics) don't move; generated
// extensions go after the file's last line.

import Foundation
import SwiftSyntax

struct Edit {
    var start: Int
    var end: Int
    var text: String
    var seq: Int
}

final class Rewriter: SyntaxVisitor {
    let index: PackageIndex
    let path: String
    let bytes: [UInt8]
    private(set) var edits: [Edit] = []
    private(set) var tail: [String] = []
    /// Whether an edit needs `RunwayObjC` in scope.
    private(set) var needsImport = false
    private var seq = 0
    private var contexts: [(name: String, kind: String)] = []
    private var generatedForType: Set<String> = []
    /// Rewriting only to read moved overrides' text (see Relocate.swift):
    /// nothing is blanked or inserted.
    let movedTextMode: Bool
    /// Starts of this file's overrides that move into a class body.
    private let movingStarts: Set<Int>
    /// This file's file-private names that moved overrides use.
    private let relaxed: Set<String>
    /// Ranges blanked because their override moved.
    private var blanked: [(start: Int, end: Int, seq: Int)] = []
    /// Imports the class bodies here need for members moved in.
    private(set) var movedImports: [String] = []
    /// Comments for the end of the file (overrides left in place…).
    private(set) var notes: [String] = []

    init(index: PackageIndex, path: String, bytes: [UInt8], movedTextMode: Bool = false) {
        self.index = index
        self.path = path
        self.bytes = bytes
        self.movedTextMode = movedTextMode
        var starts = Set<Int>()
        for o in index.files[path]?.extensionOverrides ?? [] {
            if case .move = index.placement(o) { starts.insert(o.start) }
        }
        movingStarts = starts
        relaxed = index.relaxedNames(in: path)
        super.init(viewMode: .sourceAccurate)
    }

    /// The edits, without those inside blanked members.
    var finalEdits: [Edit] {
        guard !blanked.isEmpty else { return edits }
        return edits.filter { e in !blanked.contains { b in e.seq != b.seq && e.start >= b.start && e.start <= b.end } }
    }

    // MARK: Edit helpers

    private func add(_ start: Int, _ end: Int, _ text: String, runtime: Bool = true) {
        seq += 1
        edits.append(Edit(start: start, end: end, text: text, seq: seq))
        if runtime { needsImport = true }
    }

    private func replace(_ node: some SyntaxProtocol, _ text: String, runtime: Bool = true) {
        add(node.positionAfterSkippingLeadingTrivia.utf8Offset, node.endPositionBeforeTrailingTrivia.utf8Offset, text, runtime: runtime)
    }

    private func insert(at pos: AbsolutePosition, _ text: String) { add(pos.utf8Offset, pos.utf8Offset, text) }

    /// Removes a node and the spaces after it on its line.
    private func remove(_ node: some SyntaxProtocol) {
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        var end = node.endPositionBeforeTrailingTrivia.utf8Offset
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        add(start, end, "", runtime: false)
    }

    private var currentClass: ClassFact? {
        for c in contexts.reversed() where c.kind == "class" || c.kind == "extension" {
            return index.classFact(index.resolveTypeName(c.name))
        }
        return nil
    }

    private func qualified(_ name: String) -> String {
        guard let outer = contexts.last else { return name }
        return outer.name + "." + name
    }

    // MARK: Attributes and modifiers

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        if strippedAttributes.contains(Selectors.attributeName(node)) { remove(node) }
        if Selectors.attributeName(node) == "NSApplicationDelegateAdaptor" { delegateAdaptor(node) }
        conventionAttribute(node)
        swiftDataAttribute(node)
        entryAttribute(node)
        return .skipChildren
    }

    /// `@convention(block)` has no meaning without Objective-C blocks, and
    /// `@convention(c)` only admits C types: Runway's frameworks are Swift
    /// (`CGEvent` is a class, option sets are structs), so a C function
    /// type that names anything but C scalars and pointers becomes a plain
    /// Swift function type, which is what Runway's API takes.
    private func conventionAttribute(_ node: AttributeSyntax) {
        guard Selectors.attributeName(node) == "convention", let args = node.arguments?.trimmedDescription else { return }
        if args == "block" { remove(node); return }
        guard args == "c", let attributed = node.parent?.parent?.as(AttributedTypeSyntax.self) else { return }
        let cTypes: Set<String> = ["Void", "Int", "UInt", "Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64", "Bool", "Float",
                                   "Double", "CChar", "CInt", "CUnsignedInt", "CLong", "CUnsignedLong", "CShort", "CDouble", "CFloat", "CBool", "CSignedChar",
                                   "CUnsignedChar", "UnsafeMutableRawPointer", "UnsafeRawPointer", "OpaquePointer", "UnsafePointer", "UnsafeMutablePointer",
                                   "Optional", "Never", "size_t", "pid_t", "CGFloat", "Unmanaged", "AnyObject", "CVaListPointer", "FILE", "stat", "dirent",
                                   "sigaction", "siginfo_t", "pthread_t", "timespec", "timeval", "sockaddr", "socklen_t", "ssize_t", "off_t", "uid_t", "gid_t",
                                   "mode_t", "time_t", "tm", "jmp_buf", "va_list", "Int32?", "Self"]
        for t in attributed.baseType.tokens(viewMode: .sourceAccurate) {
            if case .identifier(let name) = t.tokenKind, !cTypes.contains(name) { remove(node); return }
        }
    }

    /// `@Entry var name: T = value` in `extension EnvironmentValues` (a
    /// SwiftUI macro): a computed property over a generated EnvironmentKey.
    private func entryAttribute(_ node: AttributeSyntax) {
        guard Selectors.attributeName(node) == "Entry", let v = node.parent?.parent?.as(VariableDeclSyntax.self),
              let ext = v.parent?.parent?.parent?.parent?.as(ExtensionDeclSyntax.self),
              ext.extendedType.trimmedDescription.hasSuffix("EnvironmentValues"),
              v.bindings.count == 1, let b = v.bindings.first,
              let name = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return }
        let key = "__RunwayEntryKey_" + name
        let type = b.typeAnnotation?.type.trimmedDescription
        let initial = b.initializer?.value.trimmedDescription
        let mods = v.modifiers.map { $0.trimmedDescription }.joined(separator: " ")
        let start = v.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = v.endPositionBeforeTrailingTrivia.utf8Offset
        let lines = bytes[start..<end].filter { $0 == 0x0A }.count
        let propType = type ?? "\(key).Value"
        add(start, end, (mods.isEmpty ? "" : mods + " ") + "var \(name): \(propType) { get { self[\(key).self] } set { self[\(key).self] = newValue } }"
            + String(repeating: "\n", count: lines), runtime: false)
        let body: String
        if let type {
            body = "static var defaultValue: \(type) { \(initial ?? "nil") }"
        } else {
            body = "nonisolated(unsafe) static let defaultValue = SwiftUI._entryDefault { \(initial ?? "nil") }"
        }
        let access = v.modifiers.contains { ["public", "open"].contains($0.name.text) } ? "public " : ""
        tail.append("\(access)struct \(key): SwiftUI.EnvironmentKey { \(access)\(body) }")
    }

    /// SwiftData's macros have no implementation off Apple's toolchain:
    /// `@Model class X` becomes `@Observable class X` plus a generated
    /// `PersistentModel` conformance listing its relationships; property
    /// macros go (`@Transient` becomes `@ObservationIgnored`).
    private func swiftDataAttribute(_ node: AttributeSyntax) {
        let name = Selectors.attributeName(node)
        guard ["Model", "Relationship", "Attribute", "Transient"].contains(name) else { return }
        let owner = node.parent?.parent
        if name == "Model", let cls = owner?.as(ClassDeclSyntax.self) {
            // A model is nonisolated whatever the module's default isolation
            // (SwiftData's PersistentModel is a SendableMetatype protocol,
            // which exempts its types): key paths to its properties must be
            // Sendable for #Predicate.
            let isolated = cls.attributes.contains { $0.as(AttributeSyntax.self).map { Selectors.attributeName($0).hasSuffix("Actor") } ?? false }
                || cls.modifiers.contains { $0.name.text == "nonisolated" }
            replace(node, isolated ? "@Observable" : "@Observable nonisolated", runtime: false)
            // The class's own context is already pushed (visit(ClassDeclSyntax)).
            let type = contexts.last.map { $0.name.hasSuffix(cls.name.text) ? $0.name : qualified(cls.name.text) } ?? cls.name.text
            var rels: [String] = []
            for member in cls.memberBlock.members {
                guard let v = member.decl.as(VariableDeclSyntax.self),
                      let rel = v.attributes.compactMap({ $0.as(AttributeSyntax.self) }).first(where: { Selectors.attributeName($0) == "Relationship" }),
                      let b = v.bindings.first, let prop = b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                      let t = b.typeAnnotation?.type.trimmedDescription else { continue }
                var cascade = false
                var inverse: String?
                if case .argumentList(let args)? = rel.arguments {
                    for a in args {
                        let value = a.expression.trimmedDescription
                        if a.label?.text == "deleteRule" { cascade = value.hasSuffix("cascade") }
                        if a.label?.text == "inverse" { inverse = value }
                    }
                }
                let kp = "\\\(type).\(prop)"
                if t.hasPrefix("[") {
                    rels.append(".toMany(\(kp)\(inverse.map { ", inverse: \($0)" } ?? ""), cascade: \(cascade))")
                } else {
                    rels.append(".toOne(\(kp), cascade: \(cascade))")
                }
            }
            tail.append("\(isolated ? "" : "nonisolated ")extension \(type): SwiftData.PersistentModel {\n    static var _runwayRelationships: [SwiftData._RunwayRelationship] { [\(rels.joined(separator: ", "))] }\n}")
        } else if owner?.is(VariableDeclSyntax.self) == true {
            if name == "Transient" { replace(node, "@ObservationIgnored", runtime: false) } else { remove(node) }
        }
    }

    /// `@NSApplicationDelegateAdaptor(AppDelegate.self)`: Apple creates the
    /// delegate through the Objective-C runtime; off it, a delegate class's
    /// `init()` (not `required`) can't be called through its metatype, so
    /// the attribute gets a factory: `(AppDelegate.self, { AppDelegate() })`.
    private func delegateAdaptor(_ node: AttributeSyntax) {
        var type: String?
        if case .argumentList(let args)? = node.arguments, let first = args.first?.expression.trimmedDescription,
           first.hasSuffix(".self"), args.count == 1 {
            type = String(first.dropLast(".self".count))
        } else if node.arguments == nil, let v = node.parent?.parent?.as(VariableDeclSyntax.self),
                  let t = v.bindings.first?.typeAnnotation?.type.trimmedDescription {
            type = t
        }
        guard let type else { return }
        replace(node, "@NSApplicationDelegateAdaptor(\(type).self, { \(type)() })", runtime: false)
    }

    override func visit(_ node: DeclModifierSyntax) -> SyntaxVisitorContinueKind {
        switch node.name.text {
        case "dynamic": remove(node)
        case "private", "fileprivate":
            // Moved members, and the file-private declarations they use, become internal.
            if let decl = Relocate.filePrivateDecl(of: node),
               movingStarts.contains(decl.positionAfterSkippingLeadingTrivia.utf8Offset)
                || Relocate.declNames(decl).contains(where: relaxed.contains) {
                replace(node.name, "internal", runtime: false)
            }
        case "optional":
            if insideObjCProtocol(node) { remove(node) }
        default: break
        }
        return .skipChildren
    }

    private func insideObjCProtocol(_ node: some SyntaxProtocol) -> Bool {
        var p = node.parent
        while let n = p {
            if let proto = n.as(ProtocolDeclSyntax.self) { return proto.attributes.has("objc") }
            if n.is(CodeBlockSyntax.self) { return false }
            p = n.parent
        }
        return false
    }

    // MARK: #if

    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        if let cond = node.condition {
            let text = cond.trimmedDescription
            let new = Conditions.rewrite(text)
            if new != text { replace(cond, new, runtime: false) }
        }
        return .visitChildren
    }

    // MARK: Types

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let q = qualified(node.name.text)
        contexts.append((q, "class"))
        guard !isLocalDecl(node), let c = index.classFact(q), c.file == path else { return .visitChildren }
        // swift-corelibs-foundation's Thread can't be subclassed (some of its
        // overridable members don't load outside Foundation): the class
        // inherits Runway's thread class with the same API instead.
        if let first = node.inheritanceClause?.inheritedTypes.first, ["Thread", "Foundation.Thread"].contains(first.type.trimmedDescription) {
            replace(first.type, "RunwayFoundation.SubclassableThread", runtime: false)
        }
        var conformances: [String] = []
        let dispatching = index.isDispatching(c)
        let inherits = index.inheritsDispatch(c)
        if dispatching && !inherits { conformances.append("@preconcurrency RunwayObjC.SelectorDispatching") }
        if index.implementsObserveValue(q) {
            if !index.inheritsObserveValue(c) { conformances.append("@preconcurrency RunwayObjC.KeyValueObserving") }
        }
        if !conformances.isEmpty {
            if let clause = node.inheritanceClause, let last = clause.inheritedTypes.last {
                insert(at: last.endPositionBeforeTrailingTrivia, ", " + conformances.joined(separator: ", "))
            } else {
                let after = node.genericParameterClause?.endPositionBeforeTrailingTrivia ?? node.name.endPositionBeforeTrailingTrivia
                insert(at: after, ": " + conformances.joined(separator: ", "))
            }
        }
        var hookOwnLine = false
        if !movedTextMode {
            let brace = node.memberBlock.rightBrace.positionAfterSkippingLeadingTrivia
            if let block = index.movedBlock(into: q, classFile: path, braceOffset: brace.utf8Offset, bytes: bytes) {
                add(brace.utf8Offset, brace.utf8Offset, block.text, runtime: false)
                movedImports += block.imports.filter { !movedImports.contains($0) }
                hookOwnLine = true
            }
        }
        if dispatching {
            let parts = index.partFiles(q, target: index.target(of: path))
            let mangled = Generate.mangle(q)
            let access = Generate.memberAccess(c.access)
            var body = ""
            for (i, _) in parts.enumerated() {
                body += "if _runwayPart_\(mangled)(&m, RunwayObjC.Part\(i).self) { return true }; "
            }
            body += inherits ? "return super._runwayHandle(&m)" : "return false"
            let hook = "\(access)\(inherits ? "override " : "")func _runwayHandle(_ m: inout RunwayObjC.Message) -> Bool { \(body) } "
            // Same line as the closing brace; after `;` when a member ends on that line too.
            let brace = node.memberBlock.rightBrace
            let ownLine = brace.leadingTrivia.contains { $0.isNewline } || (brace.previousToken(viewMode: .sourceAccurate)?.trailingTrivia.contains { $0.isNewline } ?? true)
            let afterOpen = brace.previousToken(viewMode: .sourceAccurate)?.id == node.memberBlock.leftBrace.id
            insert(at: brace.positionAfterSkippingLeadingTrivia, (ownLine || afterOpen || hookOwnLine ? "" : "; ") + hook)
            tail.append(Generate.wrap(c.conditions, "extension \(q) { func _runwayPart_\(mangled)<P: RunwayObjC.PartTag>(_ m: inout RunwayObjC.Message, _: P.Type) -> Bool { false } }"))
        }
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { contexts.removeLast() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { contexts.append((qualified(node.name.text), "struct")); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { contexts.removeLast() }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { contexts.append((qualified(node.name.text), "enum")); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { contexts.removeLast() }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { contexts.append((qualified(node.name.text), "actor")); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { contexts.removeLast() }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        contexts.append((typeName(node.extendedType), "extension"))
        if !movedTextMode && !isLocalDecl(node) { relocateOverrides(node) }
        return .visitChildren
    }

    /// An override in an extension of a class the package doesn't declare
    /// (`extension NSTextView { override func performKeyEquivalent(with:) }`)
    /// has no class body to move into. It becomes a plain member under
    /// another name (`_runwayDetached_performKeyEquivalent`), with its
    /// `super.` calls reaching the class's own implementation: the code
    /// compiles and can be called, but the framework doesn't dispatch to it.
    private func detachOverrides(_ node: ExtensionDeclSyntax) -> Set<Int> {
        var detached = Set<Int>()
        for item in Relocate.overrideItems(node.memberBlock) {
            let start = item.positionAfterSkippingLeadingTrivia.utf8Offset
            func retarget(_ body: some SyntaxProtocol, _ name: String) {
                for t in body.tokens(viewMode: .sourceAccurate) where t.tokenKind == .keyword(.super) {
                    if let m = t.parent?.parent?.as(MemberAccessExprSyntax.self), m.declName.baseName.text == name { replace(t, "self", runtime: false) }
                }
            }
            if let f = item.decl.as(FunctionDeclSyntax.self), let o = f.modifiers.first(where: { $0.name.text == "override" }) {
                remove(o)
                replace(f.name, "_runwayDetached_" + f.name.text, runtime: false)
                if let body = f.body { retarget(body, f.name.text) }
                detached.insert(start)
            } else if let v = item.decl.as(VariableDeclSyntax.self), let o = v.modifiers.first(where: { $0.name.text == "override" }),
                      v.bindings.count == 1, let b = v.bindings.first, let id = b.pattern.as(IdentifierPatternSyntax.self), b.accessorBlock != nil {
                remove(o)
                replace(id.identifier, "_runwayDetached_" + id.identifier.text, runtime: false)
                if let block = b.accessorBlock { retarget(block, id.identifier.text) }
                detached.insert(start)
            }
        }
        return detached
    }

    /// Blanks the overrides that move into their class body; notes the rest.
    private func relocateOverrides(_ node: ExtensionDeclSyntax) {
        var detached = Set<Int>()
        if index.classFact(typeName(node.extendedType)) == nil, node.genericWhereClause == nil, !Relocate.hasGenericArguments(node.extendedType) {
            detached = detachOverrides(node)
        }
        for o in Relocate.overrides(in: node, path: path) {
            if detached.contains(o.start) {
                let line = Relocate.location(o.start, bytes).line
                notes.append("// RunwayTranspiler: \(o.summary) (line \(line)) extends \(o.typeName), a class outside this package: "
                             + "kept as a plain member (_runwayDetached_…); the framework doesn't call it on this platform.")
                continue
            }
            switch index.placement(o) {
            case .move(let c):
                let text = String(decoding: bytes[o.start..<o.end], as: UTF8.self)
                let lines = text.filter { $0 == "\n" }.count
                let where_ = c.file == path ? "" : " in \((c.file as NSString).lastPathComponent)"
                add(o.start, o.end, "/* \(o.summary): moved into the body of \(c.qualifiedName)\(where_) by RunwayTranspiler */"
                    + String(repeating: "\n", count: lines), runtime: false)
                blanked.append((o.start, o.end, seq))
            case .leave(let why):
                let line = Relocate.location(o.start, bytes).line
                notes.append("// RunwayTranspiler: \(o.summary) (line \(line)) stays in its extension of \(o.typeName): \(why). "
                             + "Without the Objective-C runtime Swift can't override from an extension, so it won't compile on this platform.")
            }
        }
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { contexts.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let protoName = qualified(node.name.text)
        contexts.append((protoName, "protocol"))
        guard node.attributes.has("objc") else { return .visitChildren }
        // @objc protocols are class-bound.
        if let clause = node.inheritanceClause, let first = clause.inheritedTypes.first {
            let names = clause.inheritedTypes.map { typeName($0.type) }
            if !names.contains("AnyObject") && !names.contains("NSObjectProtocol") && !names.contains("class") {
                add(first.positionAfterSkippingLeadingTrivia.utf8Offset, first.positionAfterSkippingLeadingTrivia.utf8Offset, "AnyObject, ", runtime: false)
            }
        } else {
            let after = node.primaryAssociatedTypeClause?.endPositionBeforeTrailingTrivia ?? node.name.endPositionBeforeTrailingTrivia
            add(after.utf8Offset, after.utf8Offset, ": AnyObject", runtime: false)
        }
        // Optional requirements become requirements with defaults.
        var defaults: [String] = []
        let access = node.modifiers.accessLevel == "public" || node.modifiers.accessLevel == "open" ? "public " : ""
        for item in node.memberBlock.members {
            let conds = ifConditions(of: item)
            if let f = item.decl.as(FunctionDeclSyntax.self), f.modifiers.has("optional") {
                defaults.append(Generate.wrap(conds, "    \(access)" + Generate.defaultImplementation(f)))
            } else if let v = item.decl.as(VariableDeclSyntax.self), v.modifiers.has("optional"), let d = Generate.defaultImplementation(v) {
                defaults.append(Generate.wrap(conds, "    \(access)" + d))
            }
        }
        if !defaults.isEmpty {
            tail.append(Generate.wrap(ifConditions(of: node), "extension \(protoName) {\n\(defaults.joined(separator: "\n"))\n}"))
        }
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { contexts.removeLast() }

    // MARK: Members

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let ctx = contexts.last, ctx.kind == "class" || ctx.kind == "extension",
              let override = node.modifiers.first(where: { $0.name.text == "override" }) else { return .visitChildren }
        let name = node.name.text
        let cls = currentClass
        if name == "observeValue", node.signature.parameterClause.parameters.count == 4 {
            if cls.map({ !index.inheritsObserveValue($0) }) ?? true { remove(override) }
        } else if validationHooks.contains(name) {
            if cls.map({ !index.inheritsHook(name, $0) }) ?? true { remove(override) }
        } else if nsObjectHooks.contains(name), node.signature.parameterClause.parameters.isEmpty, let c = cls, index.rootsInNSObject(c) {
            remove(override)
        } else if name == "responds", node.signature.parameterClause.parameters.count == 1,
                  node.signature.parameterClause.parameters.first?.firstName.text == "to", ctx.kind == "class" {
            // `respondsToSelector:` is an extension method here (no Objective-C
            // runtime to override it in): the class answers through RespondsOverriding.
            remove(override)
            let conformance = "extension \(ctx.name): @preconcurrency RunwayObjC.RespondsOverriding {}"
            if !tail.contains(conformance) { tail.append(conformance) }
        }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.modifiers.has("dynamic"), let ctx = contexts.last, ctx.kind == "class",
              node.bindings.count == 1, let b = node.bindings.first,
              let id = b.pattern.as(IdentifierPatternSyntax.self),
              node.bindingSpecifier.tokenKind == .keyword(.var),
              !node.modifiers.has("lazy"), !node.modifiers.has("static"), !node.modifiers.has("class") else { return .visitChildren }
        let name = id.identifier.text
        let key = Selectors.explicitName(node.attributes) ?? name
        let will = "RunwayObjC.KVO.willChange(self, \"\(key)\")"
        func did(_ old: String) -> String { "RunwayObjC.KVO.didChange(self, \"\(key)\", old: \(old), new: self.\(name))" }
        if let acc = b.accessorBlock {
            guard case .accessors(let list) = acc.accessors else { return .visitChildren }
            let kinds = list.map { $0.accessorSpecifier.text }
            if kinds.contains("get") || kinds.contains("set") || kinds.contains("_read") || kinds.contains("_modify") { return .visitChildren }
            var missing = ""
            for a in list {
                guard let body = a.body else { continue }
                let at = body.leftBrace.endPositionBeforeTrailingTrivia
                if a.accessorSpecifier.text == "willSet" {
                    insert(at: at, " \(will);")
                } else if a.accessorSpecifier.text == "didSet" {
                    let old = a.parameters?.name.text ?? "oldValue"
                    insert(at: at, " \(did(old));")
                }
            }
            if !kinds.contains("willSet") { missing += " willSet { \(will) }" }
            if !kinds.contains("didSet") { missing += " didSet { \(did("oldValue")) }" }
            if !missing.isEmpty { insert(at: acc.rightBrace.positionAfterSkippingLeadingTrivia, missing.dropFirst() + " ") }
        } else {
            insert(at: b.endPositionBeforeTrailingTrivia, " { willSet { \(will) } didSet { \(did("oldValue")) } }")
        }
        return .visitChildren
    }

    /// `#Preview { … }` is Xcode's canvas, compile-time only: the macro has
    /// no implementation off Apple's toolchain, so the declaration goes
    /// (blank lines keep every line where it was).
    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.macroName.text == "Preview" else { return .visitChildren }
        let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
        let end = node.endPositionBeforeTrailingTrivia.utf8Offset
        let lines = bytes[start..<end].filter { $0 == 0x0A }.count
        add(start, end, String(repeating: "\n", count: lines), runtime: false)
        return .skipChildren
    }

    /// Apple frameworks whose clang submodules apps import (`import os.log`,
    /// `import AppKit.NSEvent`): Runway's modules are Swift modules with no
    /// submodules, so the import names the framework.
    static let appleSubmoduleParents: Set<String> = [
        "os", "Carbon", "AppKit", "IOKit", "Darwin", "SystemConfiguration", "Foundation", "CoreFoundation", "CoreServices",
        "ApplicationServices", "Cocoa", "CoreGraphics", "Security", "QuartzCore", "PDFKit", "AVFoundation", "CoreAudio",
        "AudioToolbox", "Network", "CoreText", "ImageIO", "Metal", "WebKit",
    ]

    override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.importKindSpecifier == nil, let first = node.path.first?.name.text else { return .skipChildren }
        if node.path.count == 1, first == "ObjectiveC" {
            replace(node.path, "Foundation", runtime: false)
        } else if node.path.count > 1, Self.appleSubmoduleParents.contains(first) {
            replace(node.path, first, runtime: false)
        }
        return .skipChildren
    }

    // MARK: Expressions

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        switch node.macroName.text {
        case "Preview":
            let start = node.positionAfterSkippingLeadingTrivia.utf8Offset
            let end = node.endPositionBeforeTrailingTrivia.utf8Offset
            add(start, end, String(repeating: "\n", count: bytes[start..<end].filter { $0 == 0x0A }.count), runtime: false)
            return .skipChildren
        case "selector":
            guard let ref = SelectorExpr.parse(node) else { return .visitChildren }
            let name: String
            switch ref {
            case .resolved(let s): name = s
            case .bare(let base, let type):
                let ctx = contexts.last(where: { $0.kind == "class" || $0.kind == "extension" })?.name
                name = index.resolveBare(base, type: type, context: ctx)
            }
            replace(node, "Selector(\"\(name)\")")
            return .skipChildren
        case "keyPath":
            guard let arg = node.arguments.first?.expression else { return .visitChildren }
            var comps = arg.trimmedDescription.split(separator: ".").map(String.init)
            // #keyPath(Type.a.b) is "a.b".
            if comps.count > 1, let f = comps.first?.first, f.isUppercase { comps.removeFirst() }
            replace(node, "\"" + comps.map { $0.replacingOccurrences(of: "?", with: "") }.joined(separator: ".") + "\"", runtime: false)
            return .skipChildren
        default:
            return .visitChildren
        }
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        let labels: [String?] = node.arguments.map { $0.label?.text }
        // x?.optionalRequirement?(args)  →  RunwayObjC.ifResponds(x, Selector("…"))?.optionalRequirement(args)
        if let chain = node.calledExpression.as(OptionalChainingExprSyntax.self),
           let member = chain.expression.as(MemberAccessExprSyntax.self), let base = member.base,
           let req = index.optionalRequirement(name: member.declName.baseName.text, labels: Self.callLabels(node)),
           !index.propertyNames.contains(req.name) {
            let inner = base.as(OptionalChainingExprSyntax.self)?.expression ?? base
            add(inner.positionAfterSkippingLeadingTrivia.utf8Offset, inner.positionAfterSkippingLeadingTrivia.utf8Offset, "RunwayObjC.ifResponds(")
            add(inner.endPositionBeforeTrailingTrivia.utf8Offset, member.declName.positionAfterSkippingLeadingTrivia.utf8Offset, ", Selector(\"\(req.selector)\"))?.")
            remove(chain.questionMark)
            return .visitChildren
        }
        // `ProcessInfo()` (corelibs has no public initializer) is the shared instance.
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self), ref.baseName.text == "ProcessInfo", node.arguments.isEmpty, node.trailingClosure == nil {
            replace(node, "ProcessInfo.processInfo", runtime: false)
            return .skipChildren
        }
        if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self), ref.baseName.text == "Timer",
           labels.contains("target"), labels.contains("selector") {
            replace(ref, "RunwayObjC.SelectorTimer")
            return .visitChildren
        }
        let calleeName: String? = node.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
            ?? node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
        // `set(value, forKey:)` on UserDefaults (inside its extensions, or on
        // `UserDefaults.standard`): through RunwayFoundation's `_runwaySet`,
        // which makes CGFloats property-list numbers (see there).
        if labels == [nil, "forKey"], node.trailingClosure == nil {
            if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self), ref.baseName.text == "set",
               contexts.last.map({ $0.kind == "extension" && $0.name == "UserDefaults" }) == true {
                replace(ref, "_runwaySet", runtime: false)
            } else if let m = node.calledExpression.as(MemberAccessExprSyntax.self), m.declName.baseName.text == "set",
                      let base = m.base?.trimmedDescription, base == "UserDefaults.standard" || base == "self" && contexts.last.map({ $0.kind == "extension" && $0.name == "UserDefaults" }) == true {
                replace(m.declName, "_runwaySet", runtime: false)
            }
        }
        switch calleeName {
        case "willChangeValue", "didChangeValue":
            // `willChangeValue(for: \.isEnabled)` → `willChangeValue(forKey: "isEnabled")`
            if labels == ["for"], let first = node.arguments.first, let label = first.label,
               let kp = first.expression.as(KeyPathExprSyntax.self), let key = Self.keyName(kp) {
                replace(label, "forKey")
                replace(first.expression, "\"\(key)\"")
            }
        case "responds":
            if let m = node.calledExpression.as(MemberAccessExprSyntax.self), m.base?.is(SuperExprSyntax.self) == true,
               labels == ["to"], let first = node.arguments.first, let label = first.label, let colon = first.colon {
                replace(node.calledExpression, "RunwayObjC.superResponds")
                add(label.positionAfterSkippingLeadingTrivia.utf8Offset, colon.endPositionBeforeTrailingTrivia.utf8Offset, "self, to:")
            }
        case "observe":
            if let first = node.arguments.first, first.label == nil, let kp = first.expression.as(KeyPathExprSyntax.self),
               node.trailingClosure != nil || labels.contains("options") || labels.contains("changeHandler"),
               let key = Self.keyName(kp) {
                insert(at: first.expression.endPositionBeforeTrailingTrivia, ", _runwayKey: \"\(key)\"")
            }
        case "removeObserver":
            if let m = node.calledExpression.as(MemberAccessExprSyntax.self), let base = m.base,
               base.trimmedDescription.contains("otificationCenter"),
               labels == [nil] || labels == [nil, "name", "object"] {
                replace(m.declName, "_runwayRemoveObserver")
            }
        case "observeValue":
            if let m = node.calledExpression.as(MemberAccessExprSyntax.self), m.base?.is(SuperExprSyntax.self) == true,
               currentClass.map({ !index.inheritsObserveValue($0) }) ?? true {
                replace(node.calledExpression, "RunwayObjC.KVO.unhandledObservation")
            }
        case let n? where nsObjectHooks.contains(n):
            if let m = node.calledExpression.as(MemberAccessExprSyntax.self), m.base?.is(SuperExprSyntax.self) == true,
               node.arguments.isEmpty, let c = currentClass, index.rootsInNSObject(c) {
                replace(node.calledExpression, "RunwayObjC.nsObjectHook")
            }
        case let n? where validationHooks.contains(n):
            if let m = node.calledExpression.as(MemberAccessExprSyntax.self), m.base?.is(SuperExprSyntax.self) == true,
               currentClass.map({ !index.inheritsHook(n, $0) }) ?? true {
                replace(node.calledExpression, "RunwayObjC.defaultValidation")
            }
        default: break
        }
        return .visitChildren
    }

    /// `info["bounds"]?["X"]`: with Objective-C, `AnyObject` answers a
    /// string subscript dynamically (`objectForKeyedSubscript:`), so code
    /// digs through untyped property lists this way. Chained literal-key
    /// lookups go through `RunwayObjC.keyed`, which keeps typed
    /// dictionaries typed and looks the key up in an object otherwise.
    override func visit(_ node: SubscriptCallExprSyntax) -> SyntaxVisitorContinueKind {
        func literalKey(_ s: SubscriptCallExprSyntax) -> ExprSyntax? {
            guard s.arguments.count == 1, let a = s.arguments.first, a.label == nil, a.expression.is(StringLiteralExprSyntax.self),
                  s.trailingClosure == nil else { return nil }
            return a.expression
        }
        guard let key = literalKey(node), let chain = node.calledExpression.as(OptionalChainingExprSyntax.self),
              let inner = chain.expression.as(SubscriptCallExprSyntax.self), literalKey(inner) != nil else { return .visitChildren }
        let start = inner.positionAfterSkippingLeadingTrivia.utf8Offset
        add(start, start, "RunwayObjC.keyed(")
        add(inner.endPositionBeforeTrailingTrivia.utf8Offset, key.positionAfterSkippingLeadingTrivia.utf8Offset, ", ")
        add(key.endPositionBeforeTrailingTrivia.utf8Offset, node.rightSquare.endPositionBeforeTrailingTrivia.utf8Offset, ")")
        return .visitChildren
    }

    /// `Darwin.write(…)`: Mac code qualifies C library calls with the Darwin
    /// module, which Foundation re-exports there; Foundation re-exports the
    /// platform's C library everywhere, so the qualifier becomes Foundation.
    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if let base = node.base?.as(DeclReferenceExprSyntax.self), base.baseName.text == "Darwin" { replace(base, "Foundation", runtime: false) }
        return .visitChildren
    }

    static func callLabels(_ node: FunctionCallExprSyntax) -> [String?] {
        var l: [String?] = node.arguments.map { $0.label?.text }
        if node.trailingClosure != nil { l.append(nil) }
        for c in node.additionalTrailingClosures { l.append(c.label.text) }
        return l
    }

    /// "a.b" for `\.a.b` / `\Root.a?.b`; nil with subscripts and the like.
    static func keyName(_ kp: KeyPathExprSyntax) -> String? {
        var names: [String] = []
        for c in kp.components {
            switch c.component {
            case .property(let p): names.append(p.declName.baseName.text)
            case .optional: continue
            default: return nil
            }
        }
        return names.isEmpty ? nil : names.joined(separator: ".")
    }

    // MARK: Generated parts

    /// Dispatch-table parts for the types this file adds reachable members to.
    func generateParts() {
        let t = index.target(of: path)
        guard let facts = index.files[path] else { return }
        var types = Set<String>()
        for (type, _) in facts.members { types.insert(index.resolveTypeName(type)) }
        for type in types.sorted() {
            if let c = index.classFact(type), index.target(of: c.file) == t {
                let parts = index.partFiles(type, target: t)
                guard let k = parts.firstIndex(of: path) else { continue }
                let ms = index.reachableMembers(type).filter { $0.file == path }
                tail.append(Generate.part(type: type, name: "_runwayPart_" + Generate.mangle(type), tag: k, members: ms))
            } else {
                let ms = index.externalMembers(type, file: path)
                if ms.isEmpty { continue }
                let parts = index.externalPartFiles(type, target: t)
                guard let k = parts.firstIndex(of: path) else { continue }
                let fn = "_runwayExt_" + Generate.mangle(type)
                tail.append(Generate.part(type: type, name: fn, tag: k, members: ms))
                if k == 0 {
                    var body = ""
                    for i in parts.indices { body += "if \(fn)(&m, RunwayObjC.Part\(i).self) { return true }; " }
                    tail.append("""
                    extension \(type): @preconcurrency RunwayObjC.ExternalSelectorDispatching {
                        public func _runwayHandleExternal(_ m: inout RunwayObjC.Message) -> Bool { \(body)return false }
                        func \(fn)<P: RunwayObjC.PartTag>(_ m: inout RunwayObjC.Message, _: P.Type) -> Bool { false }
                    }
                    """)
                }
            }
        }
        if !tail.isEmpty { needsImport = true }
    }
}
