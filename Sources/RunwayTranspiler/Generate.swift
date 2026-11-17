// Generated code: dispatch-table parts, `@objc optional` defaults.

import SwiftSyntax

enum Generate {
    static func mangle(_ qualifiedName: String) -> String {
        String(qualifiedName.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    }

    /// The access a generated member of a class with this access needs.
    static func memberAccess(_ classAccess: String) -> String {
        switch classAccess {
        case "open": return "open "
        case "public": return "public "
        case "package": return "package "
        default: return ""
        }
    }

    /// `text` inside the given `#if` conditions.
    static func wrap(_ conditions: [String], _ text: String) -> String {
        guard !conditions.isEmpty else { return text }
        return "#if " + conditions.joined(separator: " && ") + "\n" + text + "\n#endif"
    }

    /// A parameter type usable in `x as T`.
    static func castType(_ t: String) -> String {
        var s = t
        for attr in ["@escaping ", "@Sendable ", "__owned ", "__shared ", "borrowing ", "consuming ", "sending "] {
            s = s.replacingOccurrences(of: attr, with: "")
        }
        if s.hasSuffix("!") { s = String(s.dropLast()) + "?" }
        return s
    }

    static func part(type: String, name: String, tag: Int, members: [MemberFact]) -> String {
        var perform: [String] = [], responds: [String] = [], values: [String] = [], sets: [String] = []
        var seen = Set<String>(), seenKeys = Set<String>()
        var usesArgs = false
        for m in members {
            let w = { (s: String) in wrap(m.conditions, s) }
            switch m.kind {
            case .method(let params, let throwsFlag, let mainActor):
                guard seen.insert(m.selector).inserted else { continue }
                let overloaded = members.contains {
                    if case .method(let p2, _, _) = $0.kind { return $0.name == m.name && p2.map(\.label) == params.map(\.label) && p2 != params }
                    return false
                }
                let args = params.enumerated().map { i, p in
                    (p.label.map { "\($0): " } ?? "") + "RunwayObjC.arg(a, \(i))" + (overloaded ? " as \(castType(p.typeText))" : "")
                }.joined(separator: ", ")
                if !params.isEmpty { usesArgs = true }
                var call = "self.\(m.name)(\(args))"
                if throwsFlag { call = "try? " + call }
                var stmt = "m.result = RunwayObjC.box(\(call))"
                if mainActor { stmt = "MainActor.assumeIsolated { \(stmt) }" }
                perform.append(w("            case \"\(m.selector)\": \(stmt); return true"))
                responds.append(w("            case \"\(m.selector)\": return true"))
            case .property(let settable, let notifies):
                if seen.insert(m.selector).inserted {
                    perform.append(w("            case \"\(m.selector)\": m.result = RunwayObjC.box(self.\(m.name)); return true"))
                    responds.append(w("            case \"\(m.selector)\": return true"))
                }
                if settable, let setter = m.setterSelector, seen.insert(setter).inserted {
                    usesArgs = true
                    perform.append(w("            case \"\(setter)\": self.\(m.name) = RunwayObjC.arg(a, 0); return true"))
                    responds.append(w("            case \"\(setter)\": return true"))
                }
                guard seenKeys.insert(m.selector).inserted else { continue }
                values.append(w("            case \"\(m.selector)\": m.result = RunwayObjC.box(self.\(m.name)); return true"))
                if settable {
                    sets.append(w("            case \"\(m.selector)\": self.\(m.name) = RunwayObjC.arg([v], 0); m.notifies = \(notifies); return true"))
                }
            }
        }
        func sw(_ subject: String, _ cases: [String]) -> String {
            "            switch \(subject) {\n" + cases.joined(separator: "\n") + "\n            default: return false\n            }"
        }
        var body = "        switch m.kind {\n"
        body += perform.isEmpty ? "        case .perform: return false\n"
            : "        case .perform(let s, \(usesArgs ? "let a" : "_")):\n\(sw("s.name", perform).replacingOccurrences(of: "\n            case", with: "\n            case"))\n"
        body += responds.isEmpty ? "        case .responds: return false\n" : "        case .responds(let s):\n\(sw("s.name", responds))\n"
        body += values.isEmpty ? "        case .value: return false\n" : "        case .value(let k):\n\(sw("k", values))\n"
        body += sets.isEmpty ? "        case .setValue: return false\n" : "        case .setValue(let k, let v):\n\(sw("k", sets))\n"
        body += "        }"
        return """
        extension \(type) {
            func \(name)(_ m: inout RunwayObjC.Message, _: RunwayObjC.Part\(tag).Type) -> Bool {
        \(body)
            }
        }
        """
    }

    // MARK: @objc optional defaults

    static func defaultBody(returnType: TypeSyntax?, name: String) -> String {
        guard let t = returnType else { return "" }
        let text = t.trimmedDescription
        if text == "Void" || text == "()" { return "" }
        if t.is(OptionalTypeSyntax.self) || t.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) || text.hasSuffix("?") { return "nil" }
        return "fatalError(\"@objc optional requirement \(name) isn't implemented\")"
    }

    static func defaultImplementation(_ f: FunctionDeclSyntax) -> String {
        let generic = f.genericParameterClause?.trimmedDescription ?? ""
        let whereClause = f.genericWhereClause.map { " " + $0.trimmedDescription } ?? ""
        let body = defaultBody(returnType: f.signature.returnClause?.type, name: f.name.text)
        return "func \(f.name.text)\(generic)\(f.signature.trimmedDescription)\(whereClause) { \(body) }"
    }

    static func defaultImplementation(_ v: VariableDeclSyntax) -> String? {
        guard v.bindings.count == 1, let b = v.bindings.first, let type = b.typeAnnotation?.type else { return nil }
        let name = b.pattern.trimmedDescription
        let body = defaultBody(returnType: type, name: name)
        var settable = false
        if case .accessors(let list)? = b.accessorBlock?.accessors { settable = list.contains { $0.accessorSpecifier.text == "set" } }
        let getter = body.isEmpty ? "()" : body
        return settable ? "var \(name): \(type.trimmedDescription) { get { \(getter) } set {} }" : "var \(name): \(type.trimmedDescription) { \(getter) }"
    }
}
