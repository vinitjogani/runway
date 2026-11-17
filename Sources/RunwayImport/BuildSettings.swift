// Xcode build settings: xcconfig files, conditional assignments
// (`KEY[config=Debug][sdk=macosx*]`), `$(inherited)` and `$(VAR:modifier)`
// expansion, and the levels Xcode stacks them in (defaults < project
// xcconfig < project < target xcconfig < target).

import Foundation

/// One `KEY[cond=value]… = value` assignment.
public struct SettingAssignment: Equatable {
    public var key: String
    public var conditions: [String: String]
    public var value: String
    public init(key: String, conditions: [String: String] = [:], value: String) {
        self.key = key; self.conditions = conditions; self.value = value
    }

    /// Parses `OTHER_SWIFT_FLAGS[config=Debug][sdk=macosx*]` into key and conditions.
    public init(rawKey: String, value: String) {
        var key = rawKey.trimmingCharacters(in: .whitespaces)
        var conditions: [String: String] = [:]
        while let open = key.firstIndex(of: "["), let close = key[open...].firstIndex(of: "]") {
            let cond = key[key.index(after: open)..<close]
            for part in cond.split(separator: ",") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 { conditions[kv[0]] = kv[1] }
            }
            key.removeSubrange(open...close)
        }
        self.init(key: key.trimmingCharacters(in: .whitespaces), conditions: conditions, value: value)
    }
}

/// What conditional assignments are evaluated against.
public struct SettingContext: Equatable {
    public var configuration: String
    public var sdk = "macosx"
    public var arch = "arm64"
    public init(configuration: String) { self.configuration = configuration }

    public func matches(_ conditions: [String: String]) -> Bool {
        for (k, pattern) in conditions {
            let value: String
            switch k {
            case "config": value = configuration
            case "sdk": value = sdk
            case "arch": value = arch
            case "variant": value = "normal"
            default: return false
            }
            if !globMatch(pattern, value) { return false }
        }
        return true
    }
}

/// `*` and `?` wildcards; `macosx*` matches `macosx` and `macosx14.0`.
public func globMatch(_ pattern: String, _ s: String) -> Bool {
    let p = Array(pattern), t = Array(s)
    func m(_ i: Int, _ j: Int) -> Bool {
        if i == p.count { return j == t.count }
        if p[i] == "*" { return m(i + 1, j) || (j < t.count && m(i, j + 1)) }
        return j < t.count && (p[i] == "?" || p[i] == t[j]) && m(i + 1, j + 1)
    }
    return m(0, 0)
}

public enum XCConfig {
    /// Every assignment in `url`, `#include`d files spliced in where they
    /// appear (relative to the including file; `#include?` may be missing).
    public static func parse(_ url: URL, depth: Int = 0, missing: inout [String]) -> [SettingAssignment] {
        guard depth < 16 else { return [] }
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            missing.append(url.path)
            return []
        }
        return parse(text: text, base: url.deletingLastPathComponent(), depth: depth, missing: &missing)
    }

    public static func parse(text: String, base: URL, depth: Int = 0, missing: inout [String]) -> [SettingAssignment] {
        var out: [SettingAssignment] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            var line = String(raw)
            if let c = line.range(of: "//") { line = String(line[..<c.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#include") {
                let optional = line.hasPrefix("#include?")
                guard let q1 = line.firstIndex(of: "\""), let q2 = line[line.index(after: q1)...].firstIndex(of: "\"") else { continue }
                let path = String(line[line.index(after: q1)..<q2])
                if path.hasPrefix("<") { continue }  // <DEVELOPER_DIR>/… : Apple's own
                let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
                if !FileManager.default.fileExists(atPath: target.path) {
                    if !optional { missing.append(target.path) }
                    continue
                }
                var nested: [String] = []
                out += parse(target, depth: depth + 1, missing: &nested)
                missing += nested
                continue
            }
            // The `=` after the key and its `[cond=value]` qualifiers.
            var depth = 0
            guard let eq = line.indices.first(where: { i in
                if line[i] == "[" { depth += 1 } else if line[i] == "]" { depth -= 1 }
                return line[i] == "=" && depth == 0
            }) else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value.removeLast(); value = value.trimmingCharacters(in: .whitespaces) }
            out.append(SettingAssignment(rawKey: String(line[..<eq]), value: value))
        }
        return out
    }
}

/// The assignments of a pbxproj `buildSettings` dictionary, conditional
/// ones after unconditional ones so they win on lookup. List values are
/// joined the way Xcode does (quoting items with spaces).
public func settingAssignments(_ dict: [String: PlistValue]) -> [SettingAssignment] {
    var out = dict.map { k, v in SettingAssignment(rawKey: k, value: settingString(v)) }
    out.sort { ($0.conditions.count, $0.key) < ($1.conditions.count, $1.key) }
    return out
}

public func settingString(_ v: PlistValue) -> String {
    switch v {
    case .string(let s): return s
    case .array(let a):
        return a.compactMap(\.string).map { $0.contains(" ") && !$0.hasPrefix("\"") ? "\"" + $0 + "\"" : $0 }.joined(separator: " ")
    default: return ""
    }
}

/// Evaluates settings over a stack of assignments, lowest level first.
/// `$(inherited)` refers to the same setting below the assignment that
/// uses it; other references see the whole stack.
public struct BuildSettings {
    public private(set) var stack: [SettingAssignment]
    public let context: SettingContext

    public init(stack: [SettingAssignment], context: SettingContext) {
        self.context = context
        self.stack = stack.filter { context.matches($0.conditions) }
    }

    public subscript(key: String) -> String? { value(key) }

    /// The fully expanded value, or nil when nothing assigns it.
    public func value(_ key: String) -> String? {
        guard let i = topIndex(key, below: stack.count) else { return nil }
        var visiting = Set<String>()
        return expand(at: i, &visiting)
    }

    public func string(_ key: String, default d: String = "") -> String { value(key) ?? d }

    public func bool(_ key: String) -> Bool {
        ["YES", "TRUE", "1"].contains((value(key) ?? "").trimmingCharacters(in: .whitespaces).uppercased())
    }

    public func list(_ key: String) -> [String] { splitSettingList(value(key) ?? "") }

    /// Every key assigned anywhere in the stack.
    public var keys: Set<String> { Set(stack.map(\.key)) }

    func topIndex(_ key: String, below: Int) -> Int? {
        var i = below - 1
        while i >= 0 {
            if stack[i].key == key { return i }
            i -= 1
        }
        return nil
    }

    private func expand(at i: Int, _ visiting: inout Set<String>) -> String {
        let a = stack[i]
        let token = "\(a.key)#\(i)"
        guard visiting.insert(token).inserted else { return "" }  // a cycle
        defer { visiting.remove(token) }
        return expandVariables(a.value) { name in
            if name == "inherited" {
                guard let j = topIndex(a.key, below: i) else { return "" }
                return expand(at: j, &visiting)
            }
            guard let j = topIndex(name, below: stack.count) else {
                return ProcessInfo.processInfo.environment[name] ?? ""
            }
            return expand(at: j, &visiting)
        }.trimmingCharacters(in: .whitespaces)
    }
}
