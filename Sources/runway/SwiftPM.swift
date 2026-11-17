// Reading a SwiftPM package into a Plan: `swift package dump-package`
// (the manifest evaluated by SwiftPM itself), then the files on disk.

import Foundation
import RunwayImport

/// Where SwiftPM looks for a target when the manifest gives no path.
private func defaultTargetPath(_ dir: URL, name: String, type: String) -> String {
    let roots: [String]
    switch type {
    case "test": roots = ["Tests", "Sources", "Source", "src", "srcs"]
    case "plugin": roots = ["Plugins"]
    default: roots = ["Sources", "Source", "src", "srcs"]
    }
    for r in roots where isDirectory(dir.appendingPathComponent(r).appendingPathComponent(name)) { return r + "/" + name }
    return (type == "test" ? "Tests/" : "Sources/") + name
}

let cFamilyExtensions: Set<String> = ["c", "m", "mm", "cc", "cpp", "cxx", "s", "S"]
let headerExtensions: Set<String> = ["h", "hh", "hpp", "inc", "modulemap"]

func dumpPackage(_ dir: URL, scratch: URL) throws -> [String: Any] {
    let swift = which("swift")
    ensureDir(scratch)
    let out = run(swift, ["package", "dump-package", "--package-path", dir.path, "--scratch-path", scratch.path], capture: true)
    guard out.status == 0, let json = try? JSONSerialization.jsonObject(with: Data(out.output.utf8)) as? [String: Any] else {
        throw StageError("couldn't read \(dir.path)/Package.swift (swift package dump-package failed)")
    }
    return json
}

/// Conditions that exclude Linux and Windows drop a setting or dependency.
private func appliesOffApple(_ condition: Any?) -> Bool {
    guard let cond = condition as? [String: Any], let platforms = cond["platformNames"] as? [String], !platforms.isEmpty else { return true }
    #if os(Windows)
    return platforms.contains("windows")
    #else
    return platforms.contains("linux")
    #endif
}

private func configOf(_ condition: Any?) -> String? {
    (condition as? [String: Any])?["config"] as? String
}

func planSwiftPM(_ pkg: URL, scratch: URL) throws -> Plan {
    let json = try dumpPackage(pkg, scratch: scratch)
    let name = json["name"] as? String ?? pkg.lastPathComponent
    let tools = ((json["toolsVersion"] as? [String: Any])?["_version"] as? String) ?? "5.9"
    var notes: [String] = []

    // Dependencies.
    var deps: [PlanDependency] = []
    for d in json["dependencies"] as? [[String: Any]] ?? [] {
        if let sc = (d["sourceControl"] as? [[String: Any]])?.first {
            let identity = sc["identity"] as? String ?? ""
            let loc = sc["location"] as? [String: Any]
            let url = ((loc?["remote"] as? [[String: Any]])?.first?["urlString"] as? String)
                ?? ((loc?["local"] as? [[String: Any]])?.first?["path"] as? String) ?? ""
            let r = sc["requirement"] as? [String: Any] ?? [:]
            var req = PlanDependency.Requirement.any
            if let range = (r["range"] as? [[String: Any]])?.first, let lo = range["lowerBound"] as? String, let hi = range["upperBound"] as? String { req = .range(lo, hi) }
            else if let e = (r["exact"] as? [String])?.first { req = .exact(e) }
            else if let b = (r["branch"] as? [String])?.first { req = .branch(b) }
            else if let rv = (r["revision"] as? [String])?.first { req = .revision(rv) }
            var dep = PlanDependency(identity: identity, source: .remote(url: url), requirement: req)
            dep.aliases = [identity]
            if let n = sc["nameForTargetDependencyResolutionOnly"] as? String { dep.aliases.insert(n) }
            dep.aliases.insert(packageIdentity(url))
            deps.append(dep)
        } else if let fs = (d["fileSystem"] as? [[String: Any]])?.first {
            let identity = fs["identity"] as? String ?? ""
            let path = fs["path"] as? String ?? ""
            var dep = PlanDependency(identity: identity, source: .local(path: URL(fileURLWithPath: path, relativeTo: pkg).standardizedFileURL), requirement: .any)
            dep.aliases = [identity]
            if let n = fs["nameForTargetDependencyResolutionOnly"] as? String { dep.aliases.insert(n) }
            deps.append(dep)
        } else if let reg = (d["registry"] as? [[String: Any]])?.first {
            notes.append("registry dependency \(reg["identity"] as? String ?? "?") isn't supported; left out")
        }
    }

    let rawTargets = json["targets"] as? [[String: Any]] ?? []
    let allPaths = rawTargets.map { t -> String in
        let n = t["name"] as! String, ty = t["type"] as! String
        return (t["path"] as? String) ?? defaultTargetPath(pkg, name: n, type: ty)
    }

    var targets: [PlanTarget] = []
    for (ti, t) in rawTargets.enumerated() {
        let tname = t["name"] as! String
        let type = t["type"] as! String
        let path = allPaths[ti]
        let kind: TargetKind
        switch type {
        case "executable": kind = .executable
        case "test": kind = .test
        case "system": kind = .system
        case "plugin": kind = .plugin
        case "binary": kind = .binary
        case "macro": kind = .macro
        default: kind = .library
        }
        var pt = PlanTarget(name: tname, kind: kind)
        let src = pkg.appendingPathComponent(path)

        for d in t["dependencies"] as? [[String: Any]] ?? [] {
            for (k, v) in d {
                guard let arr = v as? [Any], let n = arr.first as? String else { continue }
                let cond = arr.last
                guard appliesOffApple(cond is NSNull ? nil : cond) else { pt.notes.append("dependency \(n) is Apple-only; left out"); continue }
                switch k {
                case "target": pt.localDependencies.append(n)
                case "product": pt.productDependencies.append(ProductRef(product: n, package: arr.count > 1 ? arr[1] as? String : nil))
                default:  // byName: a target here or a product of a dependency
                    if rawTargets.contains(where: { ($0["name"] as? String) == n }) { pt.localDependencies.append(n) } else { pt.productDependencies.append(ProductRef(product: n, package: nil)) }
                }
            }
        }

        switch kind {
        case .binary:
            // An xcframework can't link here, but when it ships C or
            // Objective-C headers its API can be stood in for in Swift.
            if let p = t["path"] as? String {
                let headers = binaryFrameworkHeaders(pkg.appendingPathComponent(p), module: tname, scratch: scratch)
                if !headers.isEmpty {
                    var lib = PlanTarget(name: tname, kind: .library)
                    lib.standInHeaders = headers
                    lib.standInAccess = "public"
                    lib.notes.append("binary target (an xcframework): built as Swift stand-ins for its \(headers.count) header\(headers.count == 1 ? "" : "s"), reporting the feature unavailable")
                    targets.append(lib)
                    continue
                }
            }
            if let u = t["url"] as? String { pt.extraArguments.append("url: \(lit(u))") }
            if let p = t["path"] as? String { pt.extraArguments.append("path: \(lit(p))") }
            targets.append(pt)
            continue
        case .plugin:
            pt.notes.append("plugin targets run at build time on the host; left out")
            targets.append(pt)
            continue
        case .system:
            if let pc = t["pkgConfig"] as? String { pt.extraArguments.append("pkgConfig: \(lit(pc))") }
        default: break
        }

        // Files: everything under the target's directory but other targets'
        // directories nested inside it and the manifest's exclusions.
        let excludes = (t["exclude"] as? [String] ?? []).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        let nested = allPaths.enumerated().compactMap { (i, p) -> String? in
            i != ti && p.hasPrefix(path + "/") ? String(p.dropFirst(path.count + 1)) : nil
        }
        let skip = excludes + nested
        let declared = (t["resources"] as? [[String: Any]] ?? []).compactMap { r -> (PlanResource.Rule, String)? in
            guard let p = r["path"] as? String else { return nil }
            let rule = ((r["rule"] as? [String: Any])?.keys.first) ?? "process"
            return (rule == "copy" ? .copy : .process, p.hasSuffix("/") ? String(p.dropLast()) : p)
        }
        func under(_ f: String, _ prefixes: [String]) -> Bool { prefixes.contains { f == $0 || f.hasPrefix($0 + "/") } }
        let files = filesUnder(src).filter { !under($0, skip) }
        let hasCFamily = files.contains { cFamilyExtensions.contains(($0 as NSString).pathExtension) }
        let copyDirs = declared.filter { $0.0 == .copy }.map(\.1)
        var interfaceCopies: [String] = []
        for f in files {
            let ext = (f as NSString).pathExtension
            let origin = src.appendingPathComponent(f)
            if under(f, copyDirs) { continue }
            if let catalog = enclosingBundle(f, ext: "xcassets") {
                let u = src.appendingPathComponent(catalog)
                if !pt.assetCatalogs.contains(u) { pt.assetCatalogs.append(u) }
                continue
            }
            if under(f, declared.map(\.1)) {
                if ext == "xcstrings" { pt.stringCatalogs.append(origin); continue }
                if ext == "swift" { pt.sources.append(PlanFile(origin: origin, staged: f)); continue }
                pt.resources.append(PlanResource(rule: .process, origin: origin, staged: f))
                continue
            }
            if ext == "swift" { pt.sources.append(PlanFile(origin: origin, staged: f)) }
            else if hasCFamily || kind == .system { pt.verbatim.append(PlanFile(origin: origin, staged: f)) }
            else if ext == "xcstrings" { pt.stringCatalogs.append(origin) }
            else if kind != .executable, kind != .test, enclosingBundle(f, ext: "lproj") != nil, !["xib", "storyboard"].contains(ext) {
                // Localized files SwiftPM processes without being told (with a defaultLocalization).
                pt.resources.append(PlanResource(rule: .process, origin: origin, staged: f))
            }
            else if kind == .executable, let lproj = enclosingBundle(f, ext: "lproj"),
                    !interfaceCopies.contains(where: { ($0 as NSString).lastPathComponent == (lproj as NSString).lastPathComponent }) || interfaceCopies.contains(lproj) {
                // Undeclared localized folders (Base.lproj/Main.storyboard, en.lproj/*.strings): copied whole.
                if !interfaceCopies.contains(lproj) { interfaceCopies.append(lproj) }
            } else if kind == .executable, ["xib", "storyboard"].contains(ext), enclosingBundle(f, ext: "lproj") == nil {
                // Undeclared Interface Builder documents: copied, for Bundle.main to find next to the app.
                interfaceCopies.append(f)
            }
            // Other files (docs, Info.plist…) SwiftPM would warn about; leave them.
        }
        for c in interfaceCopies {
            pt.resources.append(PlanResource(rule: .copy, origin: src.appendingPathComponent(c), staged: c))
        }
        for c in copyDirs where exists(src.appendingPathComponent(c)) {
            pt.resources.append(PlanResource(rule: .copy, origin: src.appendingPathComponent(c), staged: c))
        }

        // A C-family target that needs Apple's SDK or the Objective-C runtime
        // becomes a Swift target of stand-ins generated from its public headers.
        var standIn = false
        if hasCFamily, kind == .library || kind == .executable, pt.sources.isEmpty {
            let cFiles = pt.verbatim.map(\.origin).filter { cFamilyExtensions.contains($0.pathExtension) || headerExtensions.contains($0.pathExtension) }
            // C++ can't be stood in for from its headers (templates, classes):
            // such targets stay C++ and fail to compile where they need Apple's SDK.
            let isCxx = pt.verbatim.contains { ["cpp", "cc", "cxx", "hpp", "hh"].contains($0.origin.pathExtension) }
            if !isCxx, needsAppleSDK(cFamilyFiles: cFiles) {
                standIn = true
                let publicDir = (t["publicHeadersPath"] as? String) ?? "include"
                var roots = pt.verbatim.filter { $0.staged.hasPrefix(publicDir + "/") && ["h", "hh"].contains($0.origin.pathExtension) }.map(\.origin)
                if roots.isEmpty { roots = pt.verbatim.map(\.origin).filter { $0.pathExtension == "h" } }
                // An umbrella header named like the target reads first (it orders the rest).
                roots.sort { a, b in (a.deletingPathExtension().lastPathComponent == tname ? 0 : 1, a.path) < (b.deletingPathExtension().lastPathComponent == tname ? 0 : 1, b.path) }
                var index: [String: [URL]] = [:]
                for v in pt.verbatim where ["h", "hh"].contains(v.origin.pathExtension) { index[v.origin.lastPathComponent, default: []].append(v.origin) }
                pt.standInHeaders = headerClosure(of: roots, searchRoots: [src, src.appendingPathComponent(publicDir)], index: index)
                pt.standInAccess = "public"
                pt.notes.append("C-family target that needs Apple's SDK or the Objective-C runtime: built as Swift stand-ins for its \(pt.standInHeaders.count) public header\(pt.standInHeaders.count == 1 ? "" : "s"), reporting the feature unavailable")
                pt.verbatim = []
            }
        }

        // Settings.
        var cSettings: [String] = [], linker: [String] = []
        for s in t["settings"] as? [[String: Any]] ?? [] {
            guard let kindDict = s["kind"] as? [String: Any], appliesOffApple(s["condition"]) else { continue }
            let tool = s["tool"] as? String ?? "swift"
            let config = configOf(s["condition"])
            let cond = config.map { ", .when(configuration: .\($0))" } ?? ""
            for (k, v) in kindDict {
                let arg = (v as? [String: Any])?["_0"]
                if tool == "swift" {
                    switch k {
                    case "defaultIsolation":
                        if (arg as? String) == "MainActor" { pt.settings.append(SwiftSetting(kind: .defaultIsolationMainActor, configuration: config)) }
                    case "define": if let a = arg as? String { pt.settings.append(SwiftSetting(kind: .define(a), configuration: config)) }
                    case "enableUpcomingFeature": if let a = arg as? String { pt.settings.append(SwiftSetting(kind: .upcoming(a), configuration: config)) }
                    case "enableExperimentalFeature": if let a = arg as? String { pt.settings.append(SwiftSetting(kind: .experimental(a), configuration: config)) }
                    case "unsafeFlags": if let a = arg as? [String] { pt.settings.append(SwiftSetting(kind: .unsafeFlags(a), configuration: config)) }
                    case "swiftLanguageMode":
                        if let m = (arg as? [String: Any])?.keys.first { pt.settings.append(SwiftSetting(kind: .languageMode(m), configuration: config)) }
                        else if let m = arg as? String { pt.settings.append(SwiftSetting(kind: .languageMode("v" + m.replacingOccurrences(of: ".", with: "_")), configuration: config)) }
                    default: pt.notes.append("swift setting \(k) isn't carried over")
                    }
                } else if tool == "c" || tool == "cxx" {
                    switch k {
                    case "define": if let a = arg as? String {
                        let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
                        cSettings.append(parts.count == 2 ? ".define(\(lit(parts[0])), to: \(lit(parts[1]))\(cond))" : ".define(\(lit(a))\(cond))")
                    }
                    case "headerSearchPath": if let a = arg as? String { cSettings.append(".headerSearchPath(\(lit(a))\(cond))") }
                    case "unsafeFlags": if let a = arg as? [String] { cSettings.append(".unsafeFlags([\(a.map(lit).joined(separator: ", "))]\(cond))") }
                    default: break
                    }
                } else if tool == "linker" {
                    switch k {
                    case "linkedLibrary": if let a = arg as? String { linker.append(".linkedLibrary(\(lit(a))\(cond))") }
                    case "unsafeFlags": if let a = arg as? [String] { linker.append(".unsafeFlags([\(a.map(lit).joined(separator: ", "))]\(cond))") }
                    default: break  // frameworks: Apple-only
                    }
                }
            }
        }
        if !standIn {
            if let p = t["publicHeadersPath"] as? String { pt.extraArguments.append("publicHeadersPath: \(lit(p))") }
            if !cSettings.isEmpty { pt.extraArguments.append("cSettings: [\(cSettings.joined(separator: ", "))]") }
            if !linker.isEmpty { pt.extraArguments.append("linkerSettings: [\(linker.joined(separator: ", "))]") }
        }
        pt.productName = kind == .executable ? tname : nil
        targets.append(pt)
    }

    var products: [(String, String, [String])] = []
    for p in json["products"] as? [[String: Any]] ?? [] {
        let type = ((p["type"] as? [String: Any])?.keys.first) ?? "library"
        if type == "plugin" || type == "macro" { continue }
        products.append((p["name"] as! String, type, p["targets"] as? [String] ?? []))
    }
    var modes = (json["swiftLanguageModes"] as? [Any] ?? json["swiftLanguageVersions"] as? [Any] ?? []).compactMap { m -> String? in
        if let s = m as? String { return "v" + s.replacingOccurrences(of: ".", with: "_") }
        if let d = m as? [String: Any], let k = d.keys.first { return k.hasPrefix("v") ? k : "v" + k }
        return nil
    }
    // A manifest from before tools 6 means the Swift 5 language mode.
    if modes.isEmpty { modes = [(Int(tools.split(separator: ".").first ?? "5") ?? 5) >= 6 ? "v6" : "v5"] }

    var plan = Plan(name: name, root: pkg, targets: targets, products: products, dependencies: deps,
                    languageModes: modes, defaultLocalization: json["defaultLocalization"] as? String, notes: notes)
    plan.pins = readResolved(pkg.appendingPathComponent("Package.resolved"))
    attachSwiftPMInfoPlists(&plan)
    return plan
}

/// SwiftPM apps that wrap themselves into a .app with a script keep their
/// Info.plist next to the package (Resources/Info.plist, Info.plist, or in
/// the target). Give it to the executable it names (CFBundleExecutable), or
/// to the only executable.
private func attachSwiftPMInfoPlists(_ plan: inout Plan) {
    let executables = plan.targets.indices.filter { plan.targets[$0].kind == .executable }
    guard !executables.isEmpty else { return }
    var candidates = ["Resources/Info.plist", "Info.plist", "Support/Info.plist", "App/Info.plist"].map { plan.root.appendingPathComponent($0) }
    for i in executables {
        candidates.append(plan.root.appendingPathComponent("Sources/\(plan.targets[i].name)/Info.plist"))
        candidates.append(plan.root.appendingPathComponent("Sources/\(plan.targets[i].name)/Resources/Info.plist"))
    }
    for c in candidates where exists(c) {
        guard let dict = (try? readPropertyList(c)) as? [String: Any] else { continue }
        let exe = dict["CFBundleExecutable"] as? String
        let match = executables.first { plan.targets[$0].name == exe } ?? (executables.count == 1 ? executables[0] : nil)
        guard let i = match, plan.targets[i].infoPlist == nil else { continue }
        var vars = ["EXECUTABLE_NAME": plan.targets[i].name, "PRODUCT_NAME": plan.targets[i].name, "TARGET_NAME": plan.targets[i].name, "DEVELOPMENT_LANGUAGE": plan.defaultLocalization ?? "en"]
        vars["PRODUCT_BUNDLE_IDENTIFIER"] = dict["CFBundleIdentifier"] as? String
        plan.targets[i].infoPlist = expandPlistVariables(dict, vars) as? [String: Any]
        plan.targets[i].bundleIdentifier = plan.targets[i].infoPlist?["CFBundleIdentifier"] as? String
        plan.targets[i].notes.append("Info.plist from \(relativePath(c, from: plan.root))")
    }
}


/// The public headers of a binary target's framework: the macOS slice of an
/// `.xcframework` (unzipped into `scratch` when it's a `.zip`), its
/// `<Name>.framework/Headers` or `Headers` folder; the umbrella header first.
func binaryFrameworkHeaders(_ artifact: URL, module: String, scratch: URL) -> [URL] {
    var root = artifact
    if artifact.pathExtension == "zip" {
        let out = scratch.appendingPathComponent("artifacts/" + artifact.deletingPathExtension().lastPathComponent)
        if !isDirectory(out), let unzip = whichIfPresent("unzip") {
            ensureDir(out)
            if run(unzip, ["-q", "-o", artifact.path, "-d", out.path], capture: true, quiet: true).status != 0 { try? fm.removeItem(at: out) }
        }
        root = out
    }
    guard isDirectory(root) else { return [] }
    var headerDirs: [URL] = []
    if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
        for case let u as URL in e where u.lastPathComponent == "Headers" && isDirectory(u) { headerDirs.append(u) }
    }
    // Prefer the macOS slice, then any.
    headerDirs.sort { a, b in (a.path.contains("macos") ? 0 : 1, a.path) < (b.path.contains("macos") ? 0 : 1, b.path) }
    guard let dir = headerDirs.first else { return [] }
    let headers = filesUnder(dir).filter { $0.hasSuffix(".h") }.map { dir.appendingPathComponent($0) }
    return headers.sorted { a, b in
        (a.deletingPathExtension().lastPathComponent == module ? 0 : 1, a.path) < (b.deletingPathExtension().lastPathComponent == module ? 0 : 1, b.path)
    }
}
