// Reading the JSON project format (`<Name>.xcodeproj/project.xcproj`) some
// projects commit instead of project.pbxproj: JSON with trailing commas,
// folder-based membership with per-target exclusions, targets by name.

import Foundation

public enum XcprojJSONReader {
    public static func read(_ xcodeproj: URL) throws -> XcodeProject {
        let file = xcodeproj.appendingPathComponent("project.xcproj")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw ImportError("can't read \(file.path)") }
        guard let json = try JSONSerialization.jsonObject(with: Data(removingTrailingCommas(text).utf8)) as? [String: Any] else {
            throw ImportError("\(file.path) isn't a JSON object")
        }
        return read(json, xcodeproj: xcodeproj)
    }

    /// JSON5-ish trailing commas (`[a, b,]`, `{"k": 1,}`) out, outside strings.
    public static func removingTrailingCommas(_ s: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var inString = false, escaped = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "]" || chars[j] == "}" { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    static func requirement(_ v: [String: Any]) -> PlanDependency.Requirement {
        if let m = v["up-to-next-major-version"] as? String { return .range(m, nextVersion(m, major: true)) }
        if let m = v["up-to-next-minor-version"] as? String { return .range(m, nextVersion(m, major: false)) }
        if let e = v["version"] as? String ?? v["exact-version"] as? String { return .exact(e) }
        if let b = v["branch"] as? String { return .branch(b) }
        if let r = v["revision"] as? String { return .revision(r) }
        if let r = v["range"] as? [String: Any], let lo = r["minimum"] as? String ?? r["from"] as? String {
            return .range(lo, (r["maximum"] as? String) ?? (r["to"] as? String) ?? nextVersion(lo, major: true))
        }
        return .any
    }

    static func stringSettings(_ d: [String: Any]?) -> [SettingAssignment] {
        var out: [SettingAssignment] = []
        for (k, v) in d ?? [:] {
            let value: String
            if let s = v as? String { value = s }
            else if let a = v as? [Any] { value = a.map { "\($0)" }.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") }
            else if let b = v as? Bool { value = b ? "YES" : "NO" }
            else { value = "\(v)" }
            out.append(SettingAssignment(rawKey: k, value: value))
        }
        out.sort { ($0.conditions.count, $0.key) < ($1.conditions.count, $1.key) }
        return out
    }

    public static func read(_ json: [String: Any], xcodeproj: URL) -> XcodeProject {
        let sourceRoot = xcodeproj.deletingLastPathComponent().standardizedFileURL
        var xp = XcodeProject(name: xcodeproj.deletingPathExtension().lastPathComponent, format: .xcproj, file: xcodeproj, sourceRoot: sourceRoot)
        xp.defaultConfiguration = json["default-configuration"] as? String
        xp.developmentRegion = (json["localizations"] as? [String: Any])?["development"] as? String
        let files = json["files"] as? [[String: Any]] ?? []

        // Anchors name a top-level folder (by path) that a relative path starts from.
        func anchorURL(_ anchor: String) -> URL {
            func find(_ es: [[String: Any]], _ base: URL) -> URL? {
                for e in es {
                    let p = e["path"] as? String
                    let here = p.map { base.appendingPathComponent($0) } ?? base
                    if p == anchor || (e["name"] as? String) == anchor { return here }
                    if let c = e["children"] as? [[String: Any]], let f = find(c, here) { return f }
                }
                return nil
            }
            return find(files, sourceRoot) ?? sourceRoot.appendingPathComponent(anchor)
        }
        func configFile(_ c: [String: Any]) -> URL? {
            guard let f = c["file"] as? [String: Any] else { return (c["file"] as? String).map { sourceRoot.appendingPathComponent($0) } }
            if let anchor = f["anchor"] as? String, let rel = f["relative-path"] as? String { return anchorURL(anchor).appendingPathComponent(rel) }
            return (f["path"] as? String).map { sourceRoot.appendingPathComponent($0) }
        }
        var notes: [String] = []
        func xcconfigStack(_ url: URL?, _ config: String) -> [SettingAssignment] {
            guard let url else { return [] }
            var missing: [String] = []
            let s = XCConfig.parse(url, missing: &missing)
            for m in missing { notes.append("xcconfig \(m) (configuration \(config)) is missing") }
            return s
        }

        let projectSettings = stringSettings(json["build-settings"] as? [String: Any])
        for c in json["configurations"] as? [[String: Any]] ?? [] {
            guard let name = c["name"] as? String else { continue }
            xp.configurations.append(name)
            xp.settings[name] = xcconfigStack(configFile(c), name) + projectSettings + stringSettings(c["build-settings"] as? [String: Any])
        }

        var packageByName: [String: Int] = [:]
        for p in json["packages"] as? [[String: Any]] ?? [] {
            if let repo = p["repository"] as? String {
                packageByName[packageIdentity(repo)] = xp.packages.count
                xp.packages.append(XcodePackage(.remote(url: repo, requirement: requirement(p["version"] as? [String: Any] ?? [:]))))
            } else if let path = p["path"] as? String {
                let u = URL(fileURLWithPath: path, relativeTo: sourceRoot).standardizedFileURL
                packageByName[u.lastPathComponent.lowercased()] = xp.packages.count
                xp.packages.append(XcodePackage(.local(u)))
            }
        }

        let targetsJSON = json["targets"] as? [[String: Any]] ?? []
        var productOwner: [String: String] = [:]  // "VirtualCore.framework" -> "VirtualCore"
        for t in targetsJSON {
            if let n = t["name"] as? String, let p = t["product"] as? String { productOwner[(p as NSString).lastPathComponent] = n }
        }
        var targets: [String: XcodeTarget] = [:]
        var order: [String] = []
        for t in targetsJSON {
            guard let name = t["name"] as? String else { continue }
            let type = (t["product-type"] as? String) ?? (t["kind"] as? String) ?? "aggregate"
            var xt = XcodeTarget(name: name, productType: type.replacingOccurrences(of: "com.apple.product-type.", with: ""))
            let own = stringSettings(t["build-settings"] as? [String: Any])
            var special: [String: URL] = [:]
            for c in t["specialized-configurations"] as? [[String: Any]] ?? [] {
                if let n = c["name"] as? String, let u = configFile(c) { special[n] = u }
            }
            for config in xp.configurations { xt.settings[config] = xcconfigStack(special[config], config) + own }
            xt.dependencies = t["dependencies"] as? [String] ?? []
            for m in t["package-product-members"] as? [[String: Any]] ?? [] {
                guard let product = m["product-name"] as? String, !product.hasPrefix("plugin:") else { continue }
                let pkg = (m["package"] as? String).flatMap { packageByName[$0.lowercased()] }
                xt.packageProducts.append(XcodeProductDependency(product: product, package: pkg))
            }
            targets[name] = xt
            order.append(name)
        }

        func memberships(_ e: [String: Any]) -> [(target: String, phase: String?)] {
            (e["target-membership"] as? [Any] ?? []).compactMap { m in
                let s = (m as? String) ?? ((m as? [String: Any])?["build-phase"] as? String)
                guard let s else { return nil }
                let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
                return (parts[0], parts.count > 1 ? parts[1] : nil)
            }
        }

        var packageDirs: [URL] = []
        func visit(_ entries: [[String: Any]], _ base: URL) {
            for e in entries {
                let p = e["path"] as? String
                if let p, p.hasPrefix("<") {
                    // <PRODUCTS>/X.framework: linked or embedded products of other targets.
                    if let owner = productOwner[(p as NSString).lastPathComponent] {
                        for m in memberships(e) {
                            guard targets[m.target] != nil else { continue }
                            if m.phase == "frameworks" { if !targets[m.target]!.dependencies.contains(owner) { targets[m.target]!.dependencies.append(owner) } }
                            else if m.phase?.hasPrefix("copy") == true, !targets[m.target]!.embeds.contains(owner) { targets[m.target]!.embeds.append(owner) }
                        }
                    }
                    continue
                }
                let here = (p.map { URL(fileURLWithPath: $0, relativeTo: base) } ?? base).standardizedFileURL
                let kind = e["kind"] as? String
                if kind == "folder" {
                    var excluded: [String: Set<String>] = [:], phaseExcluded: [String: Set<String>] = [:]
                    for x in e["membership-exceptions"] as? [[String: Any]] ?? [] {
                        if let t = x["target"] as? String { excluded[t, default: []].formUnion(x["exclusions"] as? [String] ?? []) }
                        if let ph = x["build-phase"] as? String {
                            let t = String(ph.split(separator: "/").first ?? "")
                            phaseExcluded[t, default: []].formUnion(x["inclusions"] as? [String] ?? [])
                        }
                    }
                    let items = isDirectory(here) ? synchronizedItems(here, packages: &packageDirs) : []
                    for m in memberships(e) where targets[m.target] != nil {
                        for item in items where !isListed(item.relative, in: excluded[m.target] ?? [])
                            && !isListed(item.relative, in: phaseExcluded[m.target] ?? []) {
                            targets[m.target]!.addSynchronized(item)
                        }
                    }
                    if memberships(e).isEmpty, isDirectory(here) { _ = synchronizedItems(here, packages: &packageDirs) }
                } else if let children = e["children"] as? [[String: Any]] {
                    visit(children, here)
                } else if p != nil {
                    if exists(here.appendingPathComponent("Package.swift")) { packageDirs.append(here) }
                    for m in memberships(e) where targets[m.target] != nil {
                        let rel = relativePath(here, from: sourceRoot)
                        switch m.phase {
                        case "resources": targets[m.target]!.resources.append(XcodeResource(url: here, bundlePath: bundlePath(forResource: rel)))
                        case "compile-sources":
                            if here.pathExtension == "swift" { targets[m.target]!.sources.append(here) } else { targets[m.target]!.otherSources.append(here) }
                        case nil: targets[m.target]!.addSynchronized(SyncItem(relative: rel, url: here, isFolder: isDirectory(here)))
                        default: break
                        }
                    }
                }
            }
        }
        visit(files, sourceRoot)
        xp.targets = order.compactMap { targets[$0] }
        for d in packageDirs where !xp.packageDirectories.contains(d) { xp.packageDirectories.append(d) }
        let shared = xcodeproj.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        if exists(shared) { xp.resolvedFile = shared }
        xp.notes = notes
        return xp
    }
}
