// The package-wide view: class hierarchies, every selector the package
// names, and which members each class's dispatch table must reach.

import Foundation
import SwiftParser
import SwiftSyntax

public final class PackageIndex: @unchecked Sendable {
    let root: String?
    private(set) var files: [String: FileFacts] = [:]
    private var classes: [String: ClassFact] = [:]
    private var classesBySimpleName: [String: [ClassFact]] = [:]
    /// Members by resolved type name (a package class's qualified name, or
    /// the extended type's name for types outside the package).
    private var members: [String: [MemberFact]] = [:]
    private(set) var selectorRefs: Set<String> = []
    private(set) var selectorBaseRefs: Set<String> = []
    private(set) var optionalRequirements: [String: [OptionalRequirement]] = [:]
    private(set) var optionalSelectors: Set<String> = []
    private(set) var propertyNames: Set<String> = []
    private var observeValueTypes: Set<String> = []
    private var validateTypes: [String: Set<String>] = [:]
    private var nonClassTypes: Set<String> = []
    private var reachableCache: [String: [MemberFact]] = [:]
    /// Every file's extension overrides (see Relocate.swift), in file order.
    private(set) var extensionOverrides: [ExtensionOverride] = []
    private let relocationLock = NSLock()
    var movedTextCache: [String: [Int: String]] = [:]
    var relaxedCache: [String: Set<String>] = [:]
    var classesBySimpleNameView: [String: [ClassFact]] { classesBySimpleName }

    func withRelocationLock<T>(_ body: () -> T) -> T {
        relocationLock.lock(); defer { relocationLock.unlock() }
        return body()
    }

    /// An index of the given files (path, source).
    public convenience init(files: [(path: String, source: String)], root: String? = nil) {
        self.init(scans: files.map { f in
            let tree = Parser.parse(source: f.source)
            let s = Scanner(path: f.path)
            s.walk(tree)
            return s.facts
        }, root: root)
    }

    init(scans: [FileFacts], root: String?) {
        self.root = root
        for f in scans { files[f.path] = f }
        for f in scans {
            for c in f.classes where !c.isLocal {
                if classes[c.qualifiedName] == nil { classes[c.qualifiedName] = c }
                classesBySimpleName[c.name, default: []].append(c)
            }
            selectorRefs.formUnion(f.selectorRefs)
            extensionOverrides += f.extensionOverrides
            selectorBaseRefs.formUnion(f.selectorBaseRefs)
            propertyNames.formUnion(f.propertyNames)
            nonClassTypes.formUnion(f.nonClassTypes)
            for r in f.optionalRequirements {
                optionalRequirements[r.name, default: []].append(r)
                optionalSelectors.insert(r.selector)
            }
        }
        for f in scans {
            for (type, ms) in f.members { members[resolveTypeName(type), default: []].append(contentsOf: ms) }
            for t in f.observeValueTypes { observeValueTypes.insert(resolveTypeName(t)) }
            for (t, hooks) in f.validateTypes { validateTypes[resolveTypeName(t), default: []].formUnion(hooks) }
        }
    }

    /// Scans every Swift file under `root`'s Sources and Tests.
    convenience init(packageRoot root: String) {
        var paths: [String] = []
        let fm = FileManager.default
        for dir in ["Sources", "Tests"] {
            let base = (root as NSString).appendingPathComponent(dir)
            guard let e = fm.enumerator(atPath: base) else { continue }
            while let rel = e.nextObject() as? String {
                if rel.hasSuffix(".swift") { paths.append((base as NSString).appendingPathComponent(rel)) }
            }
        }
        paths.sort()
        var scans: [FileFacts] = []
        for p in paths {
            guard let data = fm.contents(atPath: p), let src = String(data: data, encoding: .utf8) else { continue }
            let s = Scanner(path: p)
            s.walk(Parser.parse(source: src))
            scans.append(s.facts)
        }
        self.init(scans: scans, root: root)
    }

    // MARK: Lookups

    func resolveTypeName(_ name: String) -> String {
        if classes[name] != nil { return name }
        let simple = String(name.split(separator: ".").last ?? Substring(name))
        if let cs = classesBySimpleName[simple], cs.count == 1, name == simple || cs[0].qualifiedName.hasSuffix("." + name) {
            return cs[0].qualifiedName
        }
        return name
    }

    func classFact(_ qualifiedName: String) -> ClassFact? { classes[qualifiedName] }

    func superclass(of c: ClassFact) -> ClassFact? {
        guard let s = c.superName, let cs = classesBySimpleName[s] else { return nil }
        // Prefer one in the same target, then any.
        let candidates = cs.filter { $0.qualifiedName != c.qualifiedName }
        return candidates.first { target(of: $0.file) == target(of: c.file) } ?? candidates.first
    }

    func ancestors(of c: ClassFact) -> [ClassFact] {
        var out: [ClassFact] = []
        var seen: Set<String> = [c.qualifiedName]
        var cur = superclass(of: c)
        while let s = cur, !seen.contains(s.qualifiedName) {
            out.append(s); seen.insert(s.qualifiedName)
            cur = superclass(of: s)
        }
        return out
    }

    /// The SwiftPM target a file belongs to (`Sources/<Target>/…`).
    func target(of path: String) -> String {
        let comps = path.split(separator: "/")
        if let i = comps.lastIndex(where: { $0 == "Sources" || $0 == "Tests" }), i + 1 < comps.count { return String(comps[i + 1]) }
        return ""
    }

    func isReachable(_ m: MemberFact, objcMembers: Bool) -> Bool {
        if m.nonobjc || !m.dispatchable { return false }
        if m.explicit || objcMembers || m.inObjCExtension { return true }
        if selectorRefs.contains(m.selector) || selectorBaseRefs.contains(m.name) { return true }
        if let s = m.setterSelector, selectorRefs.contains(s) { return true }
        if case .method = m.kind {
            if optionalSelectors.contains(m.selector) || validationHooks.contains(m.name) || nsObjectHooks.contains(m.selector) { return true }
        }
        return false
    }

    /// Members of `type` a selector can reach, across the package.
    func reachableMembers(_ type: String) -> [MemberFact] {
        if let c = reachableCache[type] { return c }
        let objcMembers = classes[type]?.objcMembers ?? false
        let r = (members[type] ?? []).filter { isReachable($0, objcMembers: objcMembers) }
        reachableCache[type] = r
        return r
    }

    func isDispatching(_ c: ClassFact) -> Bool { !c.isLocal && !reachableMembers(c.qualifiedName).isEmpty }

    /// Whether an ancestor in the package already has a dispatch table
    /// (so this class's hook overrides it).
    func inheritsDispatch(_ c: ClassFact) -> Bool { ancestors(of: c).contains { isDispatching($0) } }

    /// Whether the class's chain of package superclasses ends at NSObject.
    func rootsInNSObject(_ c: ClassFact) -> Bool {
        let root = ancestors(of: c).last ?? c
        return root.superName == "NSObject"
    }

    func inheritsObserveValue(_ c: ClassFact) -> Bool { ancestors(of: c).contains { observeValueTypes.contains($0.qualifiedName) } }

    func implementsObserveValue(_ qualifiedName: String) -> Bool { observeValueTypes.contains(qualifiedName) }

    func inheritsHook(_ hook: String, _ c: ClassFact) -> Bool {
        ancestors(of: c).contains { validateTypes[$0.qualifiedName]?.contains(hook) == true }
    }

    /// The files contributing reachable members to `type`, in part order.
    func partFiles(_ type: String, target t: String) -> [String] {
        let files = Set(reachableMembers(type).map(\.file)).filter { target(of: $0) == t || t.isEmpty }
        return Array(files.sorted().prefix(32))
    }

    /// Type names (outside the package, or another target's classes) that
    /// `file`'s extensions add reachable members to.
    func externalTypes(in file: String) -> [String] {
        let t = target(of: file)
        var out: [String] = []
        for (type, ms) in members where ms.contains(where: { $0.file == file }) {
            if let c = classes[type], target(of: c.file) == t { continue }
            if nonClassTypes.contains(type) || nonClassTypes.contains(where: { $0.hasSuffix("." + type) }) { continue }
            if externalMembers(type, file: file).isEmpty { continue }
            out.append(type)
        }
        return out.sorted()
    }

    /// Reachable members `file` adds to a type outside this target: only
    /// explicitly exposed ones (`@objc`…), since a bare name match on a type
    /// the package can't see may not even be a class.
    func externalMembers(_ type: String, file: String) -> [MemberFact] {
        if classes[type] != nil { return reachableMembers(type).filter { $0.file == file } }
        return (members[type] ?? []).filter { $0.file == file && !$0.nonobjc && $0.dispatchable && ($0.explicit || $0.inObjCExtension) }
    }

    /// The files of target `t` adding reachable members to external `type`,
    /// in part order (the first carries the conformance).
    func externalPartFiles(_ type: String, target t: String) -> [String] {
        let fs = Set((members[type] ?? []).map(\.file)).filter { target(of: $0) == t && !externalMembers(type, file: $0).isEmpty }
        return Array(fs.sorted().prefix(32))
    }

    /// Optional requirement matching a call `name(labels…)`.
    func optionalRequirement(name: String, labels: [String?]) -> OptionalRequirement? {
        optionalRequirements[name]?.first { $0.labels == labels }
    }

    /// The selector for `#selector(base)` with no argument labels.
    func resolveBare(_ base: String, type: String?, context: String?) -> String {
        func candidates(_ t: String) -> Set<String> {
            Set((members[resolveTypeName(t)] ?? []).filter { $0.name == base }.map(\.selector))
        }
        for t in [type, context].compactMap({ $0 }) {
            let c = candidates(t)
            if c.count == 1 { return c.first! }
            if let cls = classes[resolveTypeName(t)] {
                for a in ancestors(of: cls) {
                    let ac = candidates(a.qualifiedName)
                    if ac.count == 1 { return ac.first! }
                }
            }
        }
        if type == nil || classes[resolveTypeName(type!)] != nil {
            let all = Set(members.values.flatMap { $0 }.filter { $0.name == base }.map(\.selector))
            if all.count == 1 { return all.first! }
        }
        if Selectors.senderActions.contains(base) { return base + ":" }
        return base
    }
}
