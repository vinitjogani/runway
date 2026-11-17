// Package dependencies, staged like the app: every package in the graph
// (remote or local) is fetched at its pinned revision and
//
//   - replaced by a Runway third-party shim when Runway has one for it
//     (ThirdParty/<identity>: binary-only Mac frameworks such as Sparkle,
//     with their module names and API, reporting the feature unavailable);
//   - staged through the same pipeline as the app (transformed sources,
//     Runway's modules linked per import) when any of its targets imports an
//     Apple framework Runway provides or needs FoundationNetworking;
//   - used as it is when it's plain Swift with no dependencies, or copied
//     with its manifest's dependencies rewired to the staged paths.
//
// Every reference to a package in the graph then points at one local path,
// so SwiftPM never sees the same identity at two locations.

import Foundation
import RunwayImport

struct ResolvedPackage {
    var identity: String
    /// The package directory the manifests refer to.
    var path: URL
    enum Mode: String { case shim, staged, rewired, asIs = "as is", sharedWithRunway = "shared with Runway (by URL)", dropped = "left out (build-time plugins only)" }
    var mode: Mode
    var products: [String]
    var revision: String?
}

struct DependencyGraph {
    let root: URL
    /// Where staged dependencies go: <app stage>/Dependencies/<identity>.
    let stageDir: URL
    var pins: [String: Pin]
    var resolved: [String: ResolvedPackage] = [:]
    var failed: [String: String] = [:]
    /// Each resolved package as first declared (for wiring it to the app).
    var declarations: [String: PlanDependency] = [:]
    private var inProgress: Set<String> = []

    init(root: URL, appStage: URL, pins: [String: Pin]) {
        self.root = root
        self.stageDir = appStage.appendingPathComponent("Dependencies")
        self.pins = pins
    }

    var checkouts: URL { root.appendingPathComponent(".runway/deps/checkouts") }
    /// The packages Runway's own manifest depends on.
    var runwayOwnPins: [String: Pin] { readResolved(root.appendingPathComponent("Package.resolved")) }
    var thirdParty: URL { root.appendingPathComponent("ThirdParty") }

    /// The folder a package is fetched or staged into: its identity, spelled
    /// as its URL or folder spells it. (Old manifests name products by
    /// package name, `dependencies: ["RSCore"]`, which SwiftPM matches
    /// against the folder's name case-sensitively.)
    func directoryName(_ d: PlanDependency) -> String {
        let raw: String
        switch d.source {
        case .local(let u): raw = u.standardizedFileURL.lastPathComponent
        case .remote(let url):
            var last = url
            while last.hasSuffix("/") { last.removeLast() }
            last = String(last.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? Substring(last))
            if last.hasSuffix(".git") { last.removeLast(4) }
            raw = last
        }
        return raw.lowercased() == d.identity.lowercased() ? raw : d.identity
    }

    /// The Runway shim standing in for `identity`, if any.
    func shim(for identity: String) -> URL? {
        for e in (try? fm.contentsOfDirectory(atPath: thirdParty.path)) ?? [] where e.lowercased() == identity.lowercased() {
            let u = thirdParty.appendingPathComponent(e)
            if exists(u.appendingPathComponent("Package.swift")) { return u }
        }
        return nil
    }

    /// Resolves (and stages) every dependency of `plan`; returns the paths
    /// its manifest refers to them by.
    mutating func resolve(_ plan: Plan) -> DependencyPaths {
        var out: DependencyPaths = [:]
        for d in plan.dependencies {
            if let r = resolvePackage(d, referrer: plan.root) { out[d.identity] = r.path.path }
        }
        return out
    }

    mutating func resolvePackage(_ d: PlanDependency, referrer: URL) -> ResolvedPackage? {
        let id = d.identity.lowercased()
        if let r = resolved[id] { return r }
        if failed[id] != nil || inProgress.contains(id) { return nil }
        inProgress.insert(id)
        defer { inProgress.remove(id) }
        declarations[id] = d

        // A package Runway itself depends on (swift-syntax) stays a URL
        // reference everywhere, so SwiftPM resolves one version for both.
        if case .remote(let url) = d.source, runwayOwnPins[id] != nil {
            let r = ResolvedPackage(identity: id, path: URL(fileURLWithPath: url), mode: .sharedWithRunway, products: [])
            resolved[id] = r
            log("dependency \(id): \(r.mode.rawValue)")
            return r
        }
        let shimDir = shim(for: id)
        let dir: URL, revision: String?
        if let s = shimDir {
            dir = s
            revision = nil
            log("dependency \(id): Runway's third-party shim (\(relativePath(s, from: root)))")
        } else {
            switch d.source {
            case .local(let path):
                dir = path
                revision = nil
            case .remote(let url):
                guard let (rev, version) = revisionFor(d, url: url) else {
                    failed[id] = "no revision of \(url) matches \(d.requirement)"
                    log("warning: dependency \(id): \(failed[id]!)")
                    return nil
                }
                let checkout = checkouts.appendingPathComponent(String(rev.prefix(12))).appendingPathComponent(directoryName(d))
                if !fetch(url: url, revision: rev, into: checkout) {
                    failed[id] = "couldn't fetch \(url) at \(rev)"
                    log("warning: dependency \(id): \(failed[id]!)")
                    return nil
                }
                dir = checkout
                revision = rev
                log("dependency \(id): \(url) at \(version.map { "\($0) " } ?? "")\(rev.prefix(12))")
            }
        }
        guard exists(dir.appendingPathComponent("Package.swift")) else {
            failed[id] = "\(dir.path) has no Package.swift"
            log("warning: dependency \(id): \(failed[id]!)")
            return nil
        }
        var sub: Plan
        do {
            sub = try planSwiftPM(dir, scratch: root.appendingPathComponent(".runway/manifests/\(c99Name(dir.path))"))
        } catch {
            failed[id] = "\(error)"
            log("warning: dependency \(id): \(error)")
            return nil
        }
        let products = sub.products.map(\.name)
        // A package of build-tool plugins only (SwiftLint's…) has nothing
        // to link: it is left out, and so are its dependents' uses of it.
        if shimDir == nil, sub.products.isEmpty, sub.targets.contains(where: { $0.kind == .plugin }) {
            let r = ResolvedPackage(identity: id, path: dir, mode: .dropped, products: [], revision: revision)
            resolved[id] = r
            log("dependency \(id): \(r.mode.rawValue)")
            return r
        }
        // Prebuilt Apple binaries (xcframework binaryTargets) can't link
        // here; without a Runway shim the package is left out, and the
        // app's imports of it fail as missing modules. (Binaries only a
        // plugin uses don't count; ones that ship C headers became
        // stand-in targets when the package was read.)
        var linked = Set<String>(), queue = sub.targets.filter { $0.kind == .library || $0.kind == .executable }.map(\.name)
        while let n = queue.popLast() {
            guard linked.insert(n).inserted, let t = sub.targets.first(where: { $0.name == n }) else { continue }
            queue += t.localDependencies
        }
        let binaries = sub.targets.filter { $0.kind == .binary && linked.contains($0.name) }.map(\.name)
        if shimDir == nil, !binaries.isEmpty {
            failed[id] = "binary-only targets \(binaries.joined(separator: ", ")) (xcframeworks) and no Runway shim in ThirdParty/"
            log("warning: dependency \(id): \(failed[id]!)")
            return nil
        }

        // Its own dependencies first (staged paths are needed to rewire it).
        var subPaths: DependencyPaths = [:]
        var usesDropped = false
        for dep in sub.dependencies {
            var dep = dep
            if case .local(let p) = dep.source, !exists(p.appendingPathComponent("Package.swift")) {
                dep.source = .local(path: URL(fileURLWithPath: p.path, relativeTo: dir).standardizedFileURL)
            }
            if let r = resolvePackage(dep, referrer: dir) {
                if r.mode == .dropped { usesDropped = true } else if r.mode != .sharedWithRunway { subPaths[dep.identity] = r.path.path }
            }
        }

        // A package whose own dependency can't be had can't build either.
        let missing = sub.dependencies.map { $0.identity.lowercased() }.filter { failed[$0] != nil }
        if !missing.isEmpty {
            failed[id] = "depends on \(missing.joined(separator: ", ")), which can't be used (\(missing.compactMap { failed[$0] }.first ?? ""))"
            log("warning: dependency \(id): \(failed[id]!)")
            return nil
        }
        let target = stageDir.appendingPathComponent(directoryName(d))
        var r = ResolvedPackage(identity: id, path: dir, mode: .asIs, products: products, revision: revision)
        // A manifest that names a left-out plugin package, or declares
        // dynamic libraries (which swift-build can't link against system
        // library targets), is written afresh rather than copied.
        let manifestText = (try? String(contentsOf: dir.appendingPathComponent("Package.swift"), encoding: .utf8)) ?? ""
        let rewrite = usesDropped || manifestText.contains(".dynamic")
        if shimDir != nil || needsStaging(sub) || rewrite {
            // Only what an app links: libraries (and the macros and C
            // targets they use); tests, plugins and binaries only plugins use stay behind.
            sub.targets = sub.targets.filter { $0.kind != .test && $0.kind != .plugin && !($0.kind == .binary && !linked.contains($0.name)) }
            // byName references to other packages' products need the package
            // spelled out in the (tools 6) staged manifest.
            linkUnresolvedProducts(&sub, self)
            for i in sub.targets.indices where sub.targets[i].kind == .binary {
                sub.targets[i].notes.append("binary target (an xcframework) can't be used on Linux")
            }
            sub.dependencies = sub.dependencies.filter { subPaths[$0.identity] != nil || resolved[$0.identity.lowercased()]?.mode == .sharedWithRunway }
            do {
                _ = try stagePlan(sub, at: target, root: root, dependencies: subPaths)
                r.path = target
                r.mode = shimDir != nil ? .shim : .staged
            } catch {
                failed[id] = "staging failed: \(error)"
                log("warning: dependency \(id): \(failed[id]!)")
                return nil
            }
        } else if !sub.dependencies.isEmpty {
            do {
                try rewire(dir, into: target, paths: subPaths)
                r.path = target
                r.mode = .rewired
            } catch {
                log("warning: dependency \(id): couldn't rewire its manifest (\(error)); used as it is")
            }
        }
        if r.mode != .asIs || d.source.isLocal { log("dependency \(id): \(r.mode.rawValue)") }
        resolved[id] = r
        return r
    }

    /// Whether any library target imports an Apple framework Runway
    /// provides (so it must link Runway's module) or uses URLSession
    /// without FoundationNetworking.
    func needsStaging(_ p: Plan) -> Bool {
        let local = Set(p.targets.map(\.name))
        for t in p.targets where t.kind == .library || t.kind == .executable {
            if !t.standInHeaders.isEmpty { return true }
            for f in t.sources {
                guard let s = try? readSource(f.origin) else { continue }
                // Optional system modules (`#if canImport(os) import os`) don't make a package Mac-only.
                if !runwayImports(in: s, local: local, skippingGuarded: ["Darwin", "os", "OSLog", "Combine", "Dispatch", "Compression", "CommonCrypto", "CryptoKit", "System"]).isEmpty { return true }
                if (s.contains("URLSession") || s.contains("URLRequest")) && !s.contains("FoundationNetworking") { return true }
                // stdio with Darwin's nullability (`fopen`'s result passed on unchecked): RunwayFoundation has the overloads.
                // (Code with its own Linux branches already handles Glibc's.)
                if (s.contains("fopen(") || s.contains("fdopen(") || s.contains("popen(")) && !s.contains("os(Linux)") && !s.contains("canImport(Glibc)") { return true }
            }
        }
        return false
    }

    // MARK: Revisions

    func revisionFor(_ d: PlanDependency, url: String) -> (String, String?)? {
        let id = d.identity.lowercased()
        if let rev = d.pinnedRevision { return (rev, d.pinnedVersion) }
        if let pin = pins[id], let rev = pin.revision { return (rev, pin.version) }
        if case .revision(let r) = d.requirement { return (r, nil) }
        // Ask the remote: its tags and branches.
        let out = run(which("git"), ["ls-remote", "--tags", "--heads", url], capture: true, quiet: true)
        guard out.status == 0 else { return nil }
        var tags: [(Version, String, String)] = [], heads: [String: String] = [:]
        for line in out.output.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 2 else { continue }
            if parts[1].hasPrefix("refs/heads/") { heads[String(parts[1].dropFirst("refs/heads/".count))] = parts[0] }
            if parts[1].hasPrefix("refs/tags/") {
                var tag = String(parts[1].dropFirst("refs/tags/".count))
                let peeled = tag.hasSuffix("^{}")
                if peeled { tag.removeLast(3) }
                guard let v = Version(tag) else { continue }
                tags.removeAll { $0.1 == tag && peeled }  // the peeled commit wins over the tag object
                if !tags.contains(where: { $0.1 == tag }) { tags.append((v, tag, parts[0])) }
            }
        }
        switch d.requirement {
        case .branch(let b): return heads[b].map { ($0, nil) }
        case .exact(let v):
            return tags.first { $0.1 == v || $0.1 == "v" + v || $0.0 == Version(v) }.map { ($0.2, $0.1) }
        case .range(let lo, let hi):
            guard let l = Version(lo), let h = Version(hi) else { return nil }
            return tags.filter { $0.0 >= l && $0.0 < h && ($0.0.prerelease.isEmpty || !l.prerelease.isEmpty) }.max { $0.0 < $1.0 }.map { ($0.2, $0.1) }
        case .any:
            return tags.filter { $0.0.prerelease.isEmpty }.max { $0.0 < $1.0 }.map { ($0.2, $0.1) } ?? heads["main"].map { ($0, nil) } ?? heads["master"].map { ($0, nil) }
        case .revision(let r): return (r, nil)
        }
    }

    /// A shallow checkout of `revision`, reused when already there. A local
    /// mirror (RUNWAY_DEPS_MIRROR/<owner>__<repo>) is used when it has the commit.
    func fetch(url: String, revision: String, into dir: URL) -> Bool {
        if exists(dir.appendingPathComponent("Package.swift")) { return true }
        try? fm.removeItem(at: dir)
        ensureDir(dir)
        let git = which("git")
        func ok(_ args: [String], cwd: URL? = nil) -> Bool { run(git, args, cwd: cwd, capture: true, quiet: true).status == 0 }
        var source = url
        if let mirrors = ProcessInfo.processInfo.environment["RUNWAY_DEPS_MIRROR"] {
            let parts = url.replacingOccurrences(of: ".git", with: "").split(separator: "/").suffix(2).map { $0.lowercased() }
            let mirror = URL(fileURLWithPath: mirrors).appendingPathComponent(parts.joined(separator: "__"))
            if isDirectory(mirror), ok(["cat-file", "-e", revision + "^{commit}"], cwd: mirror) { source = mirror.path }
        }
        guard ok(["init", "-q"], cwd: dir),
              ok(["fetch", "-q", "--depth", "1", source, revision], cwd: dir) || ok(["fetch", "-q", source, revision], cwd: dir),
              ok(["checkout", "-q", "FETCH_HEAD"], cwd: dir) else {
            try? fm.removeItem(at: dir)
            return false
        }
        if exists(dir.appendingPathComponent(".gitmodules")) {
            _ = ok(["submodule", "update", "-q", "--init", "--recursive", "--depth", "1"], cwd: dir)
        }
        return true
    }

    // MARK: Rewiring

    /// A copy of the package whose manifests' `.package(url:/path:)`
    /// dependencies point at `paths` (by identity).
    func rewire(_ dir: URL, into target: URL, paths: DependencyPaths) throws {
        let scratch = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".staging")
        try? fm.removeItem(at: scratch)
        ensureDir(scratch.deletingLastPathComponent())
        try fm.copyItem(at: dir, to: scratch)
        try? fm.removeItem(at: scratch.appendingPathComponent(".git"))
        try? fm.removeItem(at: scratch.appendingPathComponent(".build"))
        for e in (try? fm.contentsOfDirectory(atPath: scratch.path)) ?? [] where e.hasPrefix("Package") && e.hasSuffix(".swift") {
            let u = scratch.appendingPathComponent(e)
            let text = try String(contentsOf: u, encoding: .utf8)
            try rewireManifest(text, base: dir, paths: paths).write(to: u, atomically: true, encoding: .utf8)
        }
        ensureDir(target)
        syncTree(from: scratch, to: target, keep: [".build"])
        try? fm.removeItem(at: scratch)
    }
}

extension PlanDependency.Source {
    var isLocal: Bool { if case .local = self { return true }; return false }
}

/// `.package(url: "…", from: "1.0")` and `.package(path: "…")` calls whose
/// identity `paths` knows become `.package(path: "<staged>")` (keeping a
/// `name:` argument).
func rewireManifest(_ text: String, base: URL, paths: DependencyPaths) -> String {
    let chars = Array(text)
    var out = "", i = 0
    let needle = Array(".package(")
    let urlArg = try! NSRegularExpression(pattern: #"\b(url|path)\s*:\s*"([^"]+)""#)
    let nameArg = try! NSRegularExpression(pattern: #"^\s*name\s*:\s*"([^"]+)""#)
    while i < chars.count {
        if chars[i] == ".", i + needle.count <= chars.count, Array(chars[i..<(i + needle.count)]) == needle {
            // The call's balanced parentheses.
            var depth = 0, j = i + needle.count - 1, inString = false
            while j < chars.count {
                let c = chars[j]
                if c == "\"" && (j == 0 || chars[j - 1] != "\\") { inString.toggle() }
                if !inString { if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth == 0 { break } } }
                j += 1
            }
            guard j < chars.count else { break }
            let args = String(chars[(i + needle.count)..<j])
            if let m = urlArg.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)),
               let kr = Range(m.range(at: 1), in: args), let vr = Range(m.range(at: 2), in: args) {
                let location = String(args[vr])
                let identity = args[kr] == "path"
                    ? URL(fileURLWithPath: location, relativeTo: base).standardizedFileURL.lastPathComponent.lowercased()
                    : packageIdentity(location)
                if let p = paths[identity] {
                    let name = nameArg.firstMatch(in: args, range: NSRange(args.startIndex..., in: args)).flatMap { Range($0.range(at: 1), in: args) }.map { String(args[$0]) }
                    out += name.map { ".package(name: \(lit($0)), path: \(lit(p)))" } ?? ".package(path: \(lit(p)))"
                    i = j + 1
                    continue
                }
            }
        }
        out.append(chars[i])
        i += 1
    }
    return out
}

/// A semantic version (`1.2.3`, `v1.2`, `2.0.0-beta.1`).
struct Version: Comparable, Equatable {
    var parts: [Int]
    var prerelease: String
    init?(_ s: String) {
        var t = s
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let main = t.split(separator: "-", maxSplits: 1).map(String.init)
        let nums = main[0].split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.count <= 4, nums.allSatisfy({ $0 != nil }) else { return nil }
        parts = nums.map { $0! }
        while parts.count < 3 { parts.append(0) }
        prerelease = main.count > 1 ? main[1] : ""
    }
    static func < (a: Version, b: Version) -> Bool {
        if a.parts != b.parts { return a.parts.lexicographicallyPrecedes(b.parts) }
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        return a.prerelease < b.prerelease
    }
}
