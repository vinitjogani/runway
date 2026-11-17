// Small helpers shared by the importers and the `runway` tool: paths,
// names, build-setting variable expansion, Package.resolved.

import Foundation

private var files: FileManager { FileManager.default }

public func isDirectory(_ url: URL) -> Bool {
    var d: ObjCBool = false
    return files.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
}

public func exists(_ url: URL) -> Bool { files.fileExists(atPath: url.path) }

/// Every file under `dir` (recursively), as paths relative to it. Hidden
/// entries and `.build` are skipped.
public func filesUnder(_ dir: URL) -> [String] {
    let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
    guard let e = files.enumerator(atPath: base) else { return [] }
    var out: [String] = []
    while let rel = e.nextObject() as? String {
        let name = (rel as NSString).lastPathComponent
        if name.hasPrefix(".") || name == ".build" {
            if isDirectory(URL(fileURLWithPath: base + "/" + rel)) { e.skipDescendants() }
            continue
        }
        if !isDirectory(URL(fileURLWithPath: base + "/" + rel)) { out.append(rel) }
    }
    return out.sorted()
}

/// The path of `url` relative to `base`, with `..` where needed.
public func relativePath(_ url: URL, from base: URL) -> String {
    let a = url.standardizedFileURL.pathComponents
    let b = base.standardizedFileURL.pathComponents
    var i = 0
    while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
    let parts = Array(repeating: "..", count: b.count - i) + Array(a[i...])
    return parts.isEmpty ? "." : parts.joined(separator: "/")
}

/// A Swift string literal for `s`.
public func lit(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default: out.unicodeScalars.append(c)
        }
    }
    return out + "\""
}

/// A name usable as a SwiftPM target and Swift module: what Xcode derives
/// for PRODUCT_MODULE_NAME from PRODUCT_NAME (`$(PRODUCT_NAME:c99extidentifier)`):
/// characters that can't appear in an identifier become `_`, and a leading
/// digit gets a `_` in front.
public func c99Name(_ s: String) -> String {
    var out = ""
    for (i, c) in s.unicodeScalars.enumerated() {
        let ok = CharacterSet.alphanumerics.contains(c) && c.isASCII || c == "_"
        if i == 0, CharacterSet.decimalDigits.contains(c) { out += "_" }
        out.unicodeScalars.append(ok ? c : "_")
    }
    return out.isEmpty ? "_" : out
}

/// SwiftPM's package identity for a repository URL or path.
public func packageIdentity(_ location: String) -> String {
    var last = location
    while last.hasSuffix("/") { last.removeLast() }
    last = String(last.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? Substring(last))
    if last.hasSuffix(".git") { last.removeLast(4) }
    return last.lowercased()
}

/// Reads a property list (XML, binary or OpenStep text).
public func readPropertyList(_ url: URL) throws -> Any {
    let data = try Data(contentsOf: url)
    if let v = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) { return v }
    return try OpenStepPlist.parse(String(decoding: data, as: UTF8.self)).foundation
}

/// Reads Package.resolved (v1, v2 or v3).
public func readResolved(_ url: URL) -> [String: Pin] {
    guard let d = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    var out: [String: Pin] = [:]
    let pins = (json["pins"] as? [[String: Any]]) ?? ((json["object"] as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
    for p in pins {
        let location = (p["location"] as? String) ?? (p["repositoryURL"] as? String) ?? ""
        let identity = (p["identity"] as? String) ?? packageIdentity(location)
        let state = p["state"] as? [String: Any] ?? [:]
        out[identity.lowercased()] = Pin(revision: state["revision"] as? String, version: state["version"] as? String,
                                         branch: state["branch"] as? String, location: location)
    }
    return out
}

/// The `.xcassets` (or other bundle-like folder) a file is inside, if any.
public func enclosingBundle(_ rel: String, ext: String) -> String? {
    var acc: [String] = []
    for c in rel.split(separator: "/") {
        acc.append(String(c))
        if (c as NSString).pathExtension == ext { return acc.joined(separator: "/") }
    }
    return nil
}

/// `$(VAR)` / `${VAR}` in every string of a plist value.
public func expandPlistVariables(_ value: Any, _ vars: [String: String]) -> Any {
    if let s = value as? String { return expandSimpleVariables(s, vars) }
    if let a = value as? [Any] { return a.map { expandPlistVariables($0, vars) } }
    if let d = value as? [String: Any] { return d.mapValues { expandPlistVariables($0, vars) } }
    return value
}

public func expandSimpleVariables(_ s: String, _ vars: [String: String]) -> String {
    expandVariables(s) { vars[$0] ?? "" }
}

/// Expands `$(VAR)`, `${VAR}` and `$(VAR:modifier)` (nested references
/// inside the parentheses too) through `lookup`. `$VAR` with no
/// parentheses is expanded as well, as Xcode does for plain identifiers.
public func expandVariables(_ s: String, _ lookup: (String) -> String) -> String {
    guard s.contains("$") else { return s }
    let chars = Array(s)
    var out = ""
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "$", i + 1 < chars.count, chars[i + 1] == "(" || chars[i + 1] == "{" {
            let open = chars[i + 1], close: Character = open == "(" ? ")" : "}"
            var depth = 1, j = i + 2
            while j < chars.count, depth > 0 {
                if chars[j] == open { depth += 1 } else if chars[j] == close { depth -= 1 }
                if depth > 0 { j += 1 }
            }
            if j < chars.count {
                let inner = expandVariables(String(chars[(i + 2)..<j]), lookup)
                let parts = inner.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                var v = lookup(parts.first ?? "")
                for m in parts.dropFirst() { v = applyModifier(m, v) }
                out += v
                i = j + 1
                continue
            }
        } else if c == "$", i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1] == "_" {
            var j = i + 1
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
            out += lookup(String(chars[(i + 1)..<j]))
            i = j
            continue
        }
        out.append(c)
        i += 1
    }
    return out
}

public func applyModifier(_ m: String, _ v: String) -> String {
    switch m {
    case "rfc1034identifier": return String(v.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "-" })
    case "c99extidentifier", "identifier": return c99Name(v)
    case "lower": return v.lowercased()
    case "upper": return v.uppercased()
    case "base": return ((v as NSString).lastPathComponent as NSString).deletingPathExtension
    case "file": return (v as NSString).lastPathComponent
    case "dir": return (v as NSString).deletingLastPathComponent
    case "suffix": let e = (v as NSString).pathExtension; return e.isEmpty ? "" : "." + e
    case "standardizepath": return (v as NSString).standardizingPath
    case "quote": return v.contains(" ") ? "\"" + v + "\"" : v
    default:
        if m.hasPrefix("default=") { return v.isEmpty ? String(m.dropFirst("default=".count)) : v }
        return v
    }
}

/// Splits a build-setting list value the way Xcode does: on whitespace,
/// honouring double and single quotes and backslash escapes.
public func splitSettingList(_ s: String) -> [String] {
    var out: [String] = [], cur = "", quote: Character?, escaped = false, any = false
    for c in s {
        if escaped { cur.append(c); escaped = false; continue }
        if c == "\\" { escaped = true; any = true; continue }
        if let q = quote {
            if c == q { quote = nil } else { cur.append(c) }
            continue
        }
        if c == "\"" || c == "'" { quote = c; any = true; continue }
        if c == " " || c == "\t" || c == "\n" {
            if any || !cur.isEmpty { out.append(cur); cur = ""; any = false }
            continue
        }
        cur.append(c)
    }
    if any || !cur.isEmpty { out.append(cur) }
    return out
}
