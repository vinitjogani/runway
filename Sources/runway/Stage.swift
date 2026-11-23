// Staging: a Plan becomes a SwiftPM package under runway/.runway/stage/
// whose sources are transformed copies of the app's and whose manifest
// links Runway's module for every Apple framework a target imports.

import Foundation
import RunwayImport
import RunwayTranspiler

/// The single hook every staged Swift source goes through: RunwayTranspiler
/// maps Objective-C runtime features (`@objc`, `#selector`, `dynamic`, KVO,
/// target/action) onto RunwayObjC, keeping every line where it was.
/// `index`, when given, is the package-wide view the transpiler resolves
/// class hierarchies against (Xcode projects have no Sources/ layout for it
/// to find one by itself).
func transformSource(_ text: String, path: String, index: PackageIndex? = nil) -> String {
    if let index { return RunwayTranspiler.transform(source: text, fileName: path, index: index) }
    return RunwayTranspiler.transform(source: text, fileName: path)
}

/// A staged copy of `origin`: the transformed text, wrapped in a
/// `#sourceLocation` that points back at the original file. `#filePath`,
/// `#file` and diagnostics then name the original, so fixtures found
/// relative to `#filePath` resolve in the app's own tree. (`-file-prefix-map`
/// doesn't remap `#filePath` — verified with Swift 6.4 — so it can't do this.)
///
/// `main.swift` keeps its name and gets no directive: the compiler warns when
/// a directive gives a file the same `#fileID` as its physical name.
func stagedSourceText(origin: URL, text: String, index: PackageIndex? = nil) -> String {
    let transformed = rewriteApplicationMain(flattenSubmoduleImports(transformSource(text, path: index == nil ? origin.path : origin.standardizedFileURL.path, index: index)))
    if origin.lastPathComponent == "main.swift" || transformed.hasPrefix("#!") { return transformed }
    return "#sourceLocation(file: \(lit(origin.path)), line: 1)\n" + transformed + (transformed.hasSuffix("\n") ? "" : "\n") + "#sourceLocation()\n"
}

/// The Swift stand-ins for a target's Objective-C/C headers: the frameworks
/// the headers include are imported (re-exported for a bridging header,
/// which makes them visible to every file of the target on a Mac).
func objcStandIns(for t: PlanTarget, root: URL) throws -> String {
    var options = ObjCStandInOptions()
    options.access = t.standInAccess
    options.knownTypes = knownRunwayTypes(root)
    // A module's public stand-ins must not repeat what Runway's frameworks
    // declare; a bridging header's are the target's own and shadow them.
    if t.standInAccess == "public" { options.knownValues = knownRunwayValues(root) }
    options.origin = t.standInHeaders.map(\.lastPathComponent).prefix(6).joined(separator: ", ") + (t.standInHeaders.count > 6 ? "…" : "")
    var imports: [String] = []
    for fw in appleFrameworks(includedBy: t.standInHeaders) {
        let module = fw == "Cocoa" ? "AppKit" : fw
        guard runwayModules.contains(module), module != "Darwin", !imports.contains(module) else { continue }
        imports.append(module)
    }
    options.imports = imports
    // Objective-C modules and bridging headers pass on what they import.
    options.reexportImports = true
    let texts = try t.standInHeaders.map { try readSource($0) }
    return objcStandInSource(headers: texts, options: options)
}

/// Clang submodules of Apple frameworks (`import Carbon.HIToolbox`,
/// `import os.log`, `import IOKit.pwr_mgt`) name parts of one framework;
/// Runway's frameworks are single Swift modules, so the import becomes the
/// module's (on the same line). Submodules Runway gives a module map of
/// their own (`CoreImage.CIFilterBuiltins`) stay.
let submodulesWithModuleMaps: Set<String> = ["CoreImage.CIFilterBuiltins"]

func flattenSubmoduleImports(_ text: String) -> String {
    guard text.contains("import ") else { return text }
    let rx = try! NSRegularExpression(pattern: #"^(\s*(?:@\w+\s+)*(?:(?:public|internal|package|private|fileprivate)\s+)?import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?)([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_.]*)"#, options: [.anchorsMatchLines])
    var out = text
    for m in rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard let whole = Range(m.range, in: text), let mod = Range(m.range(at: 2), in: text), let sub = Range(m.range(at: 3), in: text),
              let prefix = Range(m.range(at: 1), in: text) else { continue }
        let module = String(text[mod])
        guard runwayModules.contains(module), !submodulesWithModuleMaps.contains(module + "." + text[sub]) else { continue }
        // `import struct Foundation.URL`-style imports name a declaration; keep those.
        if text[prefix].range(of: #"import\s+(struct|class|enum|protocol|func|var|let|typealias)\s"#, options: .regularExpression) != nil { continue }
        out.replaceSubrange(Range(NSRange(whole, in: text), in: out)!, with: text[prefix] + module)
    }
    return out
}

/// `@NSApplicationMain` (the pre-Swift 5.3 spelling of an AppKit app's
/// entry point) becomes `@main`: Runway's AppKit gives
/// `NSApplicationDelegate` the `main()` that attribute calls.
func rewriteApplicationMain(_ text: String) -> String {
    guard text.contains("@NSApplicationMain") else { return text }
    return text.replacingOccurrences(of: #"@NSApplicationMain\b"#, with: "@main", options: .regularExpression)
}

/// Source text, UTF-8 (or Latin-1, which old projects sometimes have).
func readSource(_ url: URL) throws -> String {
    if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
    return try String(contentsOf: url, encoding: .isoLatin1)
}

/// `Foo.swift` is staged as `Foo.staged.swift` (see stagedSourceText).
func stagedSourceName(_ rel: String) -> String {
    let name = (rel as NSString).lastPathComponent
    guard name != "main.swift", rel.hasSuffix(".swift") else { return rel }
    return String(rel.dropLast(".swift".count)) + ".staged.swift"
}

struct Staged {
    var dir: URL
    var plan: Plan
}

/// How a staged manifest refers to its package dependencies: by path (a
/// staged copy, a Runway third-party shim or an untouched checkout), keyed
/// by package identity.
typealias DependencyPaths = [String: String]

/// Writes the staged package for `plan` at `dir`. The package is written
/// to a scratch directory first and then synchronised into `dir`, so files
/// whose content didn't change keep their timestamps (incremental builds)
/// and SwiftPM's `.build` stays.
func stagePlan(_ plan: Plan, at dir: URL, root: URL, dependencies: DependencyPaths = [:], iosPreview: IOSPreview? = nil, extraFiles: (URL) throws -> Void = { _ in }) throws -> Staged {
    let scratch = dir.deletingLastPathComponent().appendingPathComponent("." + dir.lastPathComponent + ".staging")
    try? fm.removeItem(at: scratch)
    ensureDir(scratch)
    try writeStagedPackage(plan, into: scratch, root: root, dependencies: dependencies, iosPreview: iosPreview)
    try extraFiles(scratch)
    ensureDir(dir)
    syncTree(from: scratch, to: dir, keep: [".build", ".swiftpm", "Package.resolved", "Dependencies"])
    try? fm.removeItem(at: scratch)
    return Staged(dir: dir, plan: plan)
}

/// Makes `dst` hold what `src` holds: changed files copied, unchanged ones
/// left alone, extra ones removed (but `keep` at the top level).
func syncTree(from src: URL, to dst: URL, keep: Set<String>) {
    func sync(_ s: URL, _ d: URL, top: Bool) {
        let srcEntries = Set((try? fm.contentsOfDirectory(atPath: s.path)) ?? [])
        for e in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] where !srcEntries.contains(e) && !(top && keep.contains(e)) {
            try? fm.removeItem(at: d.appendingPathComponent(e))
        }
        for e in srcEntries.sorted() {
            let sa = s.appendingPathComponent(e), da = d.appendingPathComponent(e)
            let attrs = try? fm.attributesOfItem(atPath: sa.path)
            let isLink = (attrs?[.type] as? FileAttributeType) == .typeSymbolicLink
            if !isLink && isDirectory(sa) {
                if !isDirectory(da) || ((try? fm.attributesOfItem(atPath: da.path))?[.type] as? FileAttributeType) == .typeSymbolicLink {
                    try? fm.removeItem(at: da)
                    try? fm.createDirectory(at: da, withIntermediateDirectories: true)
                }
                sync(sa, da, top: false)
                continue
            }
            if !isLink, let a = fm.contents(atPath: sa.path), !isDirectory(da), fm.contents(atPath: da.path) == a { continue }
            try? fm.removeItem(at: da)
            try? fm.copyItem(at: sa, to: da)
        }
    }
    sync(src, dst, top: true)
}

/// The package-wide transpiler index for a plan whose files don't sit in a
/// SwiftPM layout (Xcode projects).
private func writeStagedPackage(_ plan: Plan, into dir: URL, root: URL, dependencies: DependencyPaths, iosPreview: IOSPreview?) throws {
    let staged = plan.targets.filter { [.executable, .library, .test, .system, .macro].contains($0.kind) }
    let localNames = Set(staged.map(\.name))
    for t in plan.targets where !localNames.contains(t.name) {
        log("note: \(t.name) (\(t.kind.rawValue)) left out: \(t.notes.first ?? "not buildable here")")
    }
    let sources = try staged.map { target -> [(path: String, source: String)] in
        guard target.kind != .macro else { return [] }
        return try target.sources.map { file in
            let text = try readSource(file.origin)
            return (file.origin.standardizedFileURL.path, iosPreview?.rewriteConditions(in: text) ?? text)
        }
    }
    let index = plan.origin == .swiftPM && iosPreview == nil ? nil :
        PackageIndex(files: sources.flatMap { $0 }, root: plan.root.path)
    // `package:` arguments name a dependency by identity or by an alias.
    var identityOf: [String: String] = [:]
    for d in plan.dependencies {
        identityOf[d.identity.lowercased()] = d.identity
        for a in d.aliases { identityOf[a.lowercased()] = d.identity }
    }
    var needsLocalization = false
    var usesMacros = false
    var decls: [String] = []
    for (t, originals) in zip(staged, sources) {
        let base = "Targets/\(t.name)"
        let tdir = dir.appendingPathComponent(base)
        for n in t.notes { log("note: \(t.name): \(n)") }

        // Macros run in the compiler on the host: their sources are copied
        // as they are and link nothing of Runway's.
        if t.kind == .macro {
            usesMacros = true
            for f in t.sources { try copyItem(f.origin, tdir.appendingPathComponent(f.staged)) }
            let deps = t.localDependencies.filter(localNames.contains).map(lit) + t.productDependencies.map { p in
                p.package.map { ".product(name: \(lit(p.product)), package: \(lit(identityOf[$0.lowercased()] ?? $0)))" } ?? lit(p.product)
            }
            var args = ["name: \(lit(t.name))", "dependencies: [\(deps.joined(separator: ", "))]", "path: \(lit(base))"]
            let settings = t.settings.map { $0.render() }
            if !settings.isEmpty { args.append("swiftSettings: [\(settings.joined(separator: ", "))]") }
            decls.append("        .macro(\(args.joined(separator: ", ")))")
            continue
        }

        var needed = Set<String>()
        for (f, original) in zip(t.sources, originals) {
            let text = stagedSourceText(origin: f.origin, text: original.source, index: index)
            try write(text, to: tdir.appendingPathComponent(stagedSourceName(f.staged)))
            needed.formUnion(runwayImports(in: text, local: localNames))
        }
        for f in t.verbatim { try copyItem(f.origin, tdir.appendingPathComponent(f.staged)) }

        // Objective-C/C declarations whose implementation isn't built here.
        if !t.standInHeaders.isEmpty {
            let text = try objcStandIns(for: t, root: root)
            try write(text, to: tdir.appendingPathComponent("_RunwayObjCStandIns.swift"))
            needed.formUnion(runwayImports(in: text.replacingOccurrences(of: "@_exported ", with: ""), local: localNames))
        }

        // The table AppKit finds the target's classes by (Interface Builder
        // documents' customClass, NSClassFromString): from the original
        // sources, under the module's name and the Xcode module name if it differs.
        if !t.sources.isEmpty {
            if let registry = RunwayTranspiler.classRegistrySource(module: t.name, aliases: t.moduleAliases, files: originals) {
                try write(registry, to: tdir.appendingPathComponent("_RunwayClassRegistry.swift"))
            }
        }

        // Resources: copied as declared, asset catalogs and string catalogs
        // converted into what Runway and corelibs Foundation read. Xcode
        // targets' resources go to the main bundle instead (laid out as in
        // Contents/Resources; assembleMainBundle puts them next to the app).
        var resourceDecls: [String] = []
        if t.mainBundleResources {
            let bundle = dir.appendingPathComponent("_RunwayBundles/\(t.name)/Resources")
            for r in t.resources { try copyItem(r.origin, bundle.appendingPathComponent(r.staged)) }
            // One RunwayAssets per bundle: an app's holds its frameworks' catalogs too.
            var catalogs = t.assetCatalogs
            if t.kind == .executable {
                for lib in plan.targets where lib.kind == .library && lib.mainBundleResources { catalogs += lib.assetCatalogs.filter { !catalogs.contains($0) } }
            }
            if !catalogs.isEmpty { try convertAssetCatalogs(catalogs, into: bundle.appendingPathComponent("RunwayAssets")) }
            if !t.stringCatalogs.isEmpty {
                _ = try convertStringCatalogs(t.stringCatalogs, into: bundle, sourceLanguage: plan.defaultLocalization ?? "en")
            }
        } else {
            for r in t.resources {
                try copyItem(r.origin, tdir.appendingPathComponent(r.staged))
                resourceDecls.append(".\(r.rule.rawValue)(\(lit(r.staged)))")
                if r.staged.contains(".lproj/") { needsLocalization = true }
            }
            if !t.assetCatalogs.isEmpty {
                let out = tdir.appendingPathComponent("_RunwayResources/RunwayAssets")
                try convertAssetCatalogs(t.assetCatalogs, into: out)
                resourceDecls.append(".copy(\(lit("_RunwayResources/RunwayAssets")))")
            }
            if !t.stringCatalogs.isEmpty {
                let out = tdir.appendingPathComponent("_RunwayResources/Strings")
                let written = try convertStringCatalogs(t.stringCatalogs, into: out, sourceLanguage: plan.defaultLocalization ?? "en")
                for w in written { resourceDecls.append(".process(\(lit("_RunwayResources/Strings/" + w)))") }
                if !written.isEmpty { needsLocalization = true }
            }
        }

        // An app's Info.plist, for Bundle.main once built (see assembleMainBundle).
        if let info = t.infoPlist {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            let url = dir.appendingPathComponent("_RunwayBundles/\(t.name)/Info.plist")
            ensureDir(url.deletingLastPathComponent())
            try data.write(to: url)
        }

        if t.kind == .system {
            var args = ["name: \(lit(t.name))", "path: \(lit(base))"] + t.extraArguments
            args = args.filter { !$0.hasPrefix("publicHeadersPath") && !$0.hasPrefix("cSettings") && !$0.hasPrefix("linkerSettings") }
            decls.append("        .systemLibrary(\(args.joined(separator: ", ")))")
            continue
        }

        var deps = t.localDependencies.filter(localNames.contains).map(lit)
        deps += t.productDependencies.compactMap { p in
            guard let pkg = p.package else { return lit(p.product) }
            let id = identityOf[pkg.lowercased()] ?? pkg
            if !dependencies.isEmpty && dependencies[id] == nil && identityOf[pkg.lowercased()] == nil { return nil }
            return ".product(name: \(lit(p.product)), package: \(lit(id)))"
        }
        let isSwift = !t.sources.isEmpty || !t.standInHeaders.isEmpty
        if isSwift { needed.formUnion(["RunwayFoundation", "RunwayObjC"]) }
        deps += needed.sorted().map { ".product(name: \(lit($0)), package: \"runway\")" }
        var args = ["name: \(lit(t.name))", "dependencies: [\(deps.joined(separator: ", "))]", "path: \(lit(base))"]
        if !resourceDecls.isEmpty { args.append("resources: [\(resourceDecls.joined(separator: ", "))]") }
        args += t.extraArguments
        if isSwift {
            // Every file implicitly imports what Apple's Foundation has and
            // corelibs splits off or lacks: FoundationNetworking (URLSession…)
            // and RunwayFoundation (compression, Trash, CF names).
            let implicit = (implicitImports + ["RunwayFoundation", "RunwayObjC", "Observation"]).flatMap { ["-Xfrontend", "-import-module", "-Xfrontend", $0] }
            let settings = t.settings.map { $0.render() } + [SwiftSetting(kind: .unsafeFlags(implicit), configuration: nil).render()]
            // PackageDescription's order: …cSettings, cxxSettings, swiftSettings, linkerSettings.
            let swiftArg = "swiftSettings: [\(settings.joined(separator: ", "))]"
            if let i = args.firstIndex(where: { $0.hasPrefix("linkerSettings") }) { args.insert(swiftArg, at: i) } else { args.append(swiftArg) }
        }
        let fn = t.kind == .executable ? "executableTarget" : t.kind == .test ? "testTarget" : "target"
        decls.append("        .\(fn)(\(args.joined(separator: ", ")))")
    }

    let products = plan.products.filter { $0.targets.allSatisfy(localNames.contains) }.map { p in
        let targets = p.targets.map(lit).joined(separator: ", ")
        return p.type == "executable"
            ? "        .executable(name: \(lit(p.name)), targets: [\(targets)])"
            : "        .library(name: \(lit(p.name)), targets: [\(targets)])"
    }
    var packageDecls = ["        .package(name: \"runway\", path: \(lit(root.path)))"]
    for d in plan.dependencies {
        if let path = dependencies[d.identity] {
            packageDecls.append("        .package(path: \(lit(path)))")
            continue
        }
        switch d.source {
        case .local(let path):
            packageDecls.append("        .package(path: \(lit(path.path)))")
            log("note: local package \(d.identity) is used as it is, not staged against Runway")
        case .remote(let url):
            let req: String
            switch d.requirement {
            case .exact(let v): req = "exact: \(lit(v))"
            case .range(let lo, let hi): req = "\(lit(lo))..<\(lit(hi))"
            case .branch(let b): req = "branch: \(lit(b))"
            case .revision(let r): req = "revision: \(lit(r))"
            case .any: req = "from: \"0.0.0\""
            }
            packageDecls.append("        .package(url: \(lit(url)), \(req))")
            log("note: remote package \(d.identity) is resolved by SwiftPM as it is, not staged against Runway")
        }
    }
    var header = "    name: \(lit(plan.name)),\n"
    if let loc = plan.defaultLocalization ?? (needsLocalization ? "en" : nil) { header += "    defaultLocalization: \(lit(loc)),\n" }
    let modes = plan.languageModes.isEmpty ? "" : ",\n    swiftLanguageModes: [\(plan.languageModes.map { "." + $0 }.joined(separator: ", "))]"
    let manifest = """
    // swift-tools-version:6.2
    // Generated by runway from \(plan.root.path) (\(plan.origin.rawValue)). Don't edit: re-run runway.
    import PackageDescription
    \(usesMacros ? "import CompilerPluginSupport\n" : "")
    let package = Package(
    \(header)    products: [
    \(products.joined(separator: ",\n"))
        ],
        dependencies: [
    \(packageDecls.joined(separator: ",\n"))
        ],
        targets: [
    \(decls.joined(separator: ",\n"))
        ]\(modes)
    )

    """
    try write(manifest, to: dir.appendingPathComponent("Package.swift"))
}

/// After `swift build`: make the build directory the app's main bundle, as
/// corelibs Foundation sees it. Bundle.main on Linux and Windows is the
/// executable's directory, read flat: Info.plist, `<lang>.lproj/…` and
/// resources sit right next to the binary. So each app's Info.plist, the
/// contents of its SwiftPM resource bundle (`<Package>_<Target>.resources`
/// or `.bundle`) and, for Xcode apps, the Contents/Resources layout staged
/// in `_RunwayBundles/<target>/Resources` (its frameworks' first) are copied
/// there. With several apps in one package the chosen product (or the first
/// app) wins.
func assembleMainBundle(_ staged: Staged, binDir: URL, product: String?) {
    let apps = staged.plan.targets.filter { $0.kind == .executable }
    let chosen = apps.first { $0.name == product || $0.productName == product } ?? apps.first
    guard let app = chosen else { return }
    let plist = staged.dir.appendingPathComponent("_RunwayBundles/\(app.name)/Info.plist")
    if exists(plist) { try? copyItem(plist, binDir.appendingPathComponent("Info.plist")) }
    let entries = (try? fm.contentsOfDirectory(atPath: binDir.path)) ?? []
    // `.resources` (SwiftPM's native build system) or `.bundle` (swift-build).
    for e in entries where e.hasSuffix("_\(app.name).resources") || e.hasSuffix("_\(app.name).bundle") {
        var bundle = binDir.appendingPathComponent(e)
        if isDirectory(bundle.appendingPathComponent("Contents/Resources")) { bundle = bundle.appendingPathComponent("Contents/Resources") }
        for item in (try? fm.contentsOfDirectory(atPath: bundle.path)) ?? [] where item != "Info.plist" {
            try? copyItem(bundle.appendingPathComponent(item), binDir.appendingPathComponent(item))
        }
    }
    // Xcode targets: the libraries' resources, then the app's own on top.
    let libraries = staged.plan.targets.filter { $0.mainBundleResources && $0.kind == .library }.map(\.name)
    for name in libraries + [app.name] {
        let resources = staged.dir.appendingPathComponent("_RunwayBundles/\(name)/Resources")
        for item in (try? fm.contentsOfDirectory(atPath: resources.path)) ?? [] {
            mergeItem(resources.appendingPathComponent(item), into: binDir.appendingPathComponent(item))
        }
    }
}

/// Copies a file or folder, merging folders (`en.lproj` from several targets).
func mergeItem(_ src: URL, into dst: URL) {
    if isDirectory(src) && isDirectory(dst) {
        for e in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] { mergeItem(src.appendingPathComponent(e), into: dst.appendingPathComponent(e)) }
    } else {
        try? copyItem(src, dst)
    }
}
