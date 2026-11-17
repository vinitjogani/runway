// An Xcode project (any format) becomes a Plan: one SwiftPM target per
// Xcode target the app needs (the app as an executable named after its
// module, its frameworks and static libraries, embedded helper apps and
// tools, its unit tests), with build settings evaluated for the Debug and
// Release configurations, the app's Info.plist resolved and its resources
// laid out as in Contents/Resources.

import Foundation

public struct XcodeImportOptions {
    /// The app target to build (`--target`); otherwise the project's main app.
    public var target: String?
    public init(target: String? = nil) { self.target = target }
}

/// Upcoming features Swift 6 turns on by default (enabling them again in
/// the Swift 6 language mode is an error).
let swift6Features: Set<String> = [
    "ConciseMagicFile", "ForwardTrailingClosures", "BareSlashRegexLiterals", "DeprecateApplicationMain", "ImportObjcForwardDeclarations",
    "DisableOutwardActorInference", "GlobalConcurrency", "InferSendableFromCaptures", "IsolatedDefaultValues", "RegionBasedIsolation",
    "DynamicActorIsolation", "GlobalActorIsolatedTypesUsability", "StrictConcurrency",
]

/// `SWIFT_UPCOMING_FEATURE_<NAME>` setting names whose feature name isn't
/// just the CamelCase of the setting.
let upcomingFeatureSettingNames: [String: String] = [
    "IMPORT_OBJC_FORWARD_DECLS": "ImportObjcForwardDeclarations",
    "DISABLE_OUTWARD_ACTOR_ISOLATION": "DisableOutwardActorInference",
    "NONISOLATED_NONSENDING_BY_DEFAULT": "NonisolatedNonsendingByDefault",
    "INFER_ISOLATED_CONFORMANCES": "InferIsolatedConformances",
]

/// Info.plist keys `INFOPLIST_KEY_*` settings give as booleans.
let booleanInfoPlistKeys: Set<String> = [
    "LSUIElement", "LSBackgroundOnly", "LSRequiresIPhoneOS", "NSSupportsAutomaticTermination", "NSSupportsSuddenTermination",
    "ITSAppUsesNonExemptEncryption", "LSMultipleInstancesProhibited", "NSHighResolutionCapable", "UIApplicationSupportsIndirectInputEvents",
    "UIRequiresFullScreen", "UIStatusBarHidden", "LSSupportsOpeningDocumentsInPlace", "UIFileSharingEnabled", "NSAppleScriptEnabled",
    "UISupportsDocumentBrowser", "GKGameCenterBadgingDisabled", "NSRequiresAquaSystemAppearance",
]

/// What Xcode's `PRODUCT_NAME:c99extidentifier` and friends compute.
public func moduleName(forProduct product: String) -> String { c99Name(product) }

func camelCaseFeature(_ snake: String) -> String {
    if let n = upcomingFeatureSettingNames[snake] { return n }
    return snake.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
}

public struct XcodeImporter {
    public let project: XcodeProject
    public var releaseConfig: String
    public var debugConfig: String
    /// Package.resolved pins (the workspace's or the project's).
    public var pins: [String: Pin] = [:]

    public init(_ project: XcodeProject, pins: [String: Pin] = [:]) {
        self.project = project
        self.pins = pins
        let configs = project.configurations
        releaseConfig = configs.contains("Release") ? "Release" : (project.defaultConfiguration ?? configs.last ?? "Release")
        debugConfig = configs.contains("Debug") ? "Debug" : (configs.first { $0.lowercased().contains("debug") } ?? releaseConfig)
    }

    /// The build settings of `target` in `config`: Xcode's defaults, then the
    /// project's levels, then the target's.
    public func settings(_ target: XcodeTarget, _ config: String) -> BuildSettings {
        let root = project.sourceRoot.path
        var defaults: [SettingAssignment] = [
            .init(key: "TARGET_NAME", value: target.name),
            .init(key: "TARGETNAME", value: target.name),
            .init(key: "PROJECT_NAME", value: project.name),
            .init(key: "PROJECT_DIR", value: root), .init(key: "SRCROOT", value: root), .init(key: "SOURCE_ROOT", value: root),
            .init(key: "PROJECT_FILE_PATH", value: project.file.path),
            .init(key: "CONFIGURATION", value: config),
            .init(key: "PLATFORM_NAME", value: "macosx"), .init(key: "SDKROOT", value: "macosx"),
            .init(key: "EFFECTIVE_PLATFORM_NAME", value: ""),
            .init(key: "PRODUCT_NAME", value: "$(TARGET_NAME)"),
            .init(key: "PRODUCT_MODULE_NAME", value: "$(PRODUCT_NAME:c99extidentifier)"),
            .init(key: "EXECUTABLE_NAME", value: "$(PRODUCT_NAME)"),
            .init(key: "DEVELOPMENT_LANGUAGE", value: project.developmentRegion ?? "en"),
            .init(key: "CURRENT_ARCH", value: "arm64"), .init(key: "ARCHS", value: "arm64"),
            .init(key: "MACOSX_DEPLOYMENT_TARGET", value: "13.0"),
            .init(key: "SWIFT_ACTIVE_COMPILATION_CONDITIONS", value: ""),
            .init(key: "PRODUCT_BUNDLE_PACKAGE_TYPE", value: target.role == .library ? "FMWK" : target.role == .test ? "BNDL" : "APPL"),
        ]
        defaults.append(.init(key: "BUILT_PRODUCTS_DIR", value: project.sourceRoot.appendingPathComponent("build").path))
        return BuildSettings(stack: defaults + (project.settings[config] ?? []) + (target.settings[config] ?? []), context: SettingContext(configuration: config))
    }

    /// Targets built for macOS (multi-platform ones included).
    public func isMacTarget(_ t: XcodeTarget) -> Bool {
        let s = settings(t, releaseConfig)
        let sdk = s.string("SDKROOT").lowercased()
        let supported = s.string("SUPPORTED_PLATFORMS").lowercased()
        if !supported.isEmpty { return supported.contains("macosx") }
        if ["iphoneos", "appletvos", "watchos", "xros", "driverkit"].contains(where: { sdk.contains($0) }) { return false }
        return true
    }

    /// The app `runway build` builds: the one asked for, else the macOS app
    /// no other target embeds, named like the project if several.
    public func mainApp(_ requested: String?) throws -> XcodeTarget {
        if let r = requested {
            guard let t = project.targets.first(where: { $0.name == r || moduleName(of: $0) == r }) else {
                throw ImportError("no target \(r) in \(project.file.lastPathComponent); targets: \(project.targets.map(\.name).joined(separator: ", "))")
            }
            return t
        }
        let apps = project.targets.filter { $0.role == .app && isMacTarget($0) }
        let embedded = Set(project.targets.flatMap(\.embeds))
        let candidates = apps.filter { !embedded.contains($0.name) }
        let pool = candidates.isEmpty ? apps : candidates
        if let named = pool.first(where: { $0.name == project.name }) { return named }
        if let best = pool.max(by: { $0.sources.count < $1.sources.count }) { return best }
        // No app: a tool or a framework project.
        if let tool = project.targets.first(where: { $0.role == .tool && isMacTarget($0) }) { return tool }
        if let lib = project.targets.first(where: { $0.role == .library && isMacTarget($0) }) { return lib }
        throw ImportError("\(project.file.lastPathComponent) has no macOS app, tool or framework target (targets: \(project.targets.map { "\($0.name) [\($0.productType)]" }.joined(separator: ", ")))")
    }

    public func moduleName(of t: XcodeTarget) -> String {
        let s = settings(t, releaseConfig)
        let m = s.string("PRODUCT_MODULE_NAME")
        return c99Name(m.isEmpty ? t.name : m)
    }

    /// The targets staged for `app`: it, what it depends on (transitively),
    /// the helper apps and tools it embeds, and unit tests of those.
    public func targetClosure(of app: XcodeTarget) -> (included: [XcodeTarget], skipped: [(String, String)]) {
        var keep: [String] = [], skipped: [(String, String)] = []
        var queue = [app.name]
        while let n = queue.first {
            queue.removeFirst()
            guard !keep.contains(n), !skipped.contains(where: { $0.0 == n }), let t = project.target(named: n) else { continue }
            if n != app.name {
                switch t.role {
                case .appExtension: skipped.append((n, "\(t.productType) (app extensions, widgets and XPC services aren't built)")); continue
                case .uiTest, .other: skipped.append((n, "\(t.productType) isn't built")); continue
                default: break
                }
                if !isMacTarget(t) { skipped.append((n, "not a macOS target")); continue }
            }
            keep.append(n)
            queue += t.dependencies + t.embeds
        }
        for t in project.targets where t.role == .test && isMacTarget(t) && !keep.contains(t.name) {
            let deps = Set(t.dependencies)
            let host = settings(t, releaseConfig).string("TEST_HOST")
            if !deps.isDisjoint(with: keep) || host.contains("/\(app.name).app/") || host.contains("\(settings(app, releaseConfig).string("PRODUCT_NAME")).app") {
                keep.append(t.name)
                for d in t.dependencies where !keep.contains(d) {
                    if let dt = project.target(named: d), dt.role == .library, isMacTarget(dt) { keep.append(d) }
                }
            }
        }
        for t in project.targets where !keep.contains(t.name) && !skipped.contains(where: { $0.0 == t.name }) {
            let why: String
            switch t.role {
            case _ where !isMacTarget(t): why = "not a macOS target"
            case .app: why = "another app (pass --target \(t.name) to build it)"
            case .appExtension: why = "\(t.productType) (app extensions, widgets and XPC services aren't built)"
            case .uiTest: why = "UI tests aren't run"
            default: why = "not needed by \(app.name)"
            }
            skipped.append((t.name, why))
        }
        return (keep.compactMap { project.target(named: $0) }, skipped)
    }

    // MARK: Settings

    /// Swift compiler settings for one configuration.
    public func swiftSettings(_ s: BuildSettings) -> (kinds: [SwiftSetting.Kind], notes: [String]) {
        var out: [SwiftSetting.Kind] = [], notes: [String] = []
        func add(_ k: SwiftSetting.Kind) { if !out.contains(k) { out.append(k) } }
        var mode = "v5"
        if let v = s.value("SWIFT_VERSION"), !v.isEmpty {
            let major = Int(v.split(separator: ".").first ?? "5") ?? 5
            mode = major >= 6 ? "v6" : "v5"
            if major < 5 { notes.append("SWIFT_VERSION \(v) is built in the Swift 5 language mode") }
        }
        add(.languageMode(mode))
        for d in s.list("SWIFT_ACTIVE_COMPILATION_CONDITIONS") where !d.isEmpty && d != "$(inherited)" { add(.define(d)) }
        let flags = s.list("OTHER_SWIFT_FLAGS")
        var i = 0, dropped: [String] = []
        while i < flags.count {
            let f = flags[i]
            switch f {
            case "-D" where i + 1 < flags.count: add(.define(flags[i + 1])); i += 1
            case _ where f.hasPrefix("-D") && f.count > 2: add(.define(String(f.dropFirst(2))))
            case "-enable-upcoming-feature" where i + 1 < flags.count: add(.upcoming(flags[i + 1])); i += 1
            case "-enable-experimental-feature" where i + 1 < flags.count: add(.experimental(flags[i + 1])); i += 1
            case "-strict-concurrency=complete": add(.upcoming("StrictConcurrency"))
            case _ where ["-Xfrontend", "-Xcc", "-Xlinker"].contains(f) && i + 1 < flags.count: dropped.append(f + " " + flags[i + 1]); i += 1
            default: dropped.append(f)
            }
            i += 1
        }
        if !dropped.isEmpty { notes.append("OTHER_SWIFT_FLAGS not carried over: \(dropped.joined(separator: " "))") }
        if s.string("SWIFT_STRICT_CONCURRENCY").lowercased() == "complete" { add(.upcoming("StrictConcurrency")) }
        if s.string("SWIFT_DEFAULT_ACTOR_ISOLATION") == "MainActor" { add(.defaultIsolationMainActor) }
        if s.bool("SWIFT_APPROACHABLE_CONCURRENCY") {
            for f in ["DisableOutwardActorInference", "GlobalActorIsolatedTypesUsability", "InferIsolatedConformances",
                      "InferSendableFromCaptures", "NonisolatedNonsendingByDefault"] { add(.upcoming(f)) }
        }
        for key in s.keys.sorted() where key.hasPrefix("SWIFT_UPCOMING_FEATURE_") {
            if s.bool(key) { add(.upcoming(camelCaseFeature(String(key.dropFirst("SWIFT_UPCOMING_FEATURE_".count))))) }
        }
        if mode == "v6" { out.removeAll { if case .upcoming(let f) = $0 { return swift6Features.contains(f) }; return false } }
        return (out, notes)
    }

    /// Settings from both configurations, conditioned where they differ.
    func mergedSwiftSettings(_ t: XcodeTarget) -> (settings: [SwiftSetting], notes: [String]) {
        let rel = swiftSettings(settings(t, releaseConfig)), dbg = swiftSettings(settings(t, debugConfig))
        var out: [SwiftSetting] = []
        for k in rel.kinds {
            if case .languageMode = k { out.append(SwiftSetting(kind: k, configuration: nil)); continue }
            out.append(SwiftSetting(kind: k, configuration: dbg.kinds.contains(k) ? nil : "release"))
        }
        for k in dbg.kinds where !rel.kinds.contains(k) {
            if case .languageMode = k { continue }
            out.append(SwiftSetting(kind: k, configuration: "debug"))
        }
        return (out, Array(Set(rel.notes + dbg.notes)).sorted())
    }

    // MARK: Info.plist

    /// The app's Info.plist as Xcode would produce it: INFOPLIST_FILE with
    /// `$(VAR)`s expanded, merged with what GENERATE_INFOPLIST_FILE and the
    /// INFOPLIST_KEY_* settings generate.
    public func infoPlist(_ t: XcodeTarget, executable: String) -> (plist: [String: Any], notes: [String]) {
        let s = settings(t, releaseConfig)
        var notes: [String] = []
        func lookup(_ name: String) -> String { name == "EXECUTABLE_NAME" ? executable : s.string(name) }
        func expand(_ v: Any) -> Any {
            if let str = v as? String { return expandVariables(str, lookup) }
            if let a = v as? [Any] { return a.map(expand) }
            if let d = v as? [String: Any] { return d.mapValues(expand) }
            return v
        }
        var dict: [String: Any] = [:]
        let file = s.string("INFOPLIST_FILE")
        if !file.isEmpty {
            let url = URL(fileURLWithPath: file, relativeTo: project.sourceRoot).standardizedFileURL
            if let d = (try? readPropertyList(url)) as? [String: Any] {
                dict = expand(d) as? [String: Any] ?? [:]
                notes.append("Info.plist from \(relativePath(url, from: project.sourceRoot))")
            } else {
                notes.append("INFOPLIST_FILE \(file) can't be read")
            }
        }
        var generated: [String: Any] = [:]
        if s.bool("GENERATE_INFOPLIST_FILE") || file.isEmpty {
            for key in s.keys where key.hasPrefix("INFOPLIST_KEY_") {
                let k = String(key.dropFirst("INFOPLIST_KEY_".count))
                let v = s.string(key)
                generated[k] = booleanInfoPlistKeys.contains(k) ? (["YES", "TRUE", "1"].contains(v.uppercased()) as Any) : v as Any
            }
            if !file.isEmpty { notes.append("Info.plist entries generated from INFOPLIST_KEY_* settings merged in") }
            else { notes.append("Info.plist generated from build settings") }
        }
        let standard: [String: String] = [
            "CFBundleDevelopmentRegion": s.string("DEVELOPMENT_LANGUAGE", default: "en"),
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": s.string("PRODUCT_BUNDLE_IDENTIFIER"),
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": s.string("PRODUCT_NAME"),
            "CFBundlePackageType": s.string("PRODUCT_BUNDLE_PACKAGE_TYPE", default: "APPL"),
            "CFBundleShortVersionString": s.string("MARKETING_VERSION"),
            "CFBundleVersion": s.string("CURRENT_PROJECT_VERSION"),
            "LSMinimumSystemVersion": s.string("MACOSX_DEPLOYMENT_TARGET"),
        ]
        if s.bool("GENERATE_INFOPLIST_FILE") || file.isEmpty {
            for (k, v) in standard where !v.isEmpty { generated[k] = v }
        }
        for (k, v) in t.infoProperties ?? [:] { generated[k] = expand(v) }
        // Keys in the file win, as in Xcode; generated ones fill the gaps.
        for (k, v) in generated where dict[k] == nil || (dict[k] as? String)?.isEmpty == true { dict[k] = v }
        dict["CFBundleExecutable"] = executable  // the binary on Linux is named after the module
        for k in ["CFBundleIdentifier", "CFBundleName", "CFBundleShortVersionString", "CFBundleVersion"] where (dict[k] as? String ?? "").isEmpty {
            if let v = standard[k], !v.isEmpty { dict[k] = v }
        }
        return (dict, notes)
    }

    // MARK: The plan

    public func plan(options: XcodeImportOptions = .init()) throws -> Plan {
        let app = try mainApp(options.target)
        let (included, skipped) = targetClosure(of: app)
        var notes = project.notes
        notes.append("\(project.format.rawValue) \(project.file.lastPathComponent): building \(app.name) (\(app.productType)), \(releaseConfig)/\(debugConfig) settings")
        for (n, why) in skipped { notes.append("target \(n) left out: \(why)") }

        // Module names, unique.
        var names: [String: String] = [:], used = Set<String>()
        for t in included {
            var m = moduleName(of: t)
            while used.contains(m) { m += "_" }
            used.insert(m)
            names[t.name] = m
        }

        // Packages the included targets use, plus local packages that
        // declare products no package reference names.
        var deps: [PlanDependency] = []
        func addDependency(_ p: XcodePackage) -> String {
            let id = p.identity
            if !deps.contains(where: { $0.identity == id }) {
                var d: PlanDependency
                switch p.location {
                case .remote(let url, let req): d = PlanDependency(identity: id, source: .remote(url: url), requirement: req)
                case .local(let u): d = PlanDependency(identity: id, source: .local(path: u), requirement: .any)
                }
                d.aliases = [id]
                if let pin = pins[id] { d.pinnedRevision = pin.revision; d.pinnedVersion = pin.version }
                deps.append(d)
            }
            return id
        }
        var localDirs = (project.packages.compactMap { p -> URL? in
            if case .local(let u) = p.location { return u }
            return nil
        } + project.packageDirectories).reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } }
        // Products no package reference names: also look for packages in
        // the project's folders (Xcode finds them through folders the
        // project's groups or synchronized folders show).
        let named = Set(localDirs.flatMap { declaredProducts(inPackageAt: $0) })
        let remoteIDs = Set(project.packages.filter { if case .remote = $0.location { return true }; return false }.map(\.identity))
        let unnamed = included.flatMap(\.packageProducts).filter { $0.package == nil && !named.contains($0.product) && !remoteIDs.contains($0.product.lowercased()) }
        if !unnamed.isEmpty {
            for d in packageDirectories(under: project.sourceRoot, depth: 3) where !localDirs.contains(d) { localDirs.append(d) }
        }
        let localPackages: [(dir: URL, products: [String])] = localDirs.map { ($0, declaredProducts(inPackageAt: $0)) }

        var targets: [PlanTarget] = []
        var headers: [String: [URL]]?
        func projectHeaders() -> [String: [URL]] {
            if let h = headers { return h }
            let h = headerIndex(under: project.sourceRoot)
            headers = h
            return h
        }
        for t in included {
            let module = names[t.name]!
            let kind: TargetKind
            switch t.role {
            case .app, .tool: kind = .executable
            case .test: kind = .test
            default: kind = .library
            }
            var pt = PlanTarget(name: module, kind: kind)
            pt.mainBundleResources = true
            let s = settings(t, releaseConfig)
            for alias in [c99Name(t.name), c99Name(s.string("PRODUCT_NAME"))] where alias != module && !pt.moduleAliases.contains(alias) {
                pt.moduleAliases.append(alias)
            }
            pt.productName = kind == .executable ? module : nil
            pt.notes += t.notes

            var seen = Set<String>()
            for src in t.sources where seen.insert(src.path).inserted {
                guard exists(src) else { pt.notes.append("source \(relativePath(src, from: project.sourceRoot)) is missing"); continue }
                pt.sources.append(PlanFile(origin: src, staged: stagedPath(src)))
            }
            let cFiles = t.otherSources.filter { ["c"].contains($0.pathExtension) }
            let objc = t.otherSources.filter { ["m", "mm"].contains($0.pathExtension) }
            let cxx = t.otherSources.filter { ["cc", "cpp", "cxx"].contains($0.pathExtension) }
            let rest = t.otherSources.filter { !["c", "m", "mm", "cc", "cpp", "cxx"].contains($0.pathExtension) }
            // C-family code that needs Apple's SDK or the Objective-C runtime
            // isn't compiled: Swift stand-ins are generated from its headers.
            let cFamily = cFiles + objc + cxx
            let bridging = s.string("SWIFT_OBJC_BRIDGING_HEADER")
            var standInRoots: [URL] = []
            if !bridging.isEmpty {
                let u = URL(fileURLWithPath: bridging, relativeTo: project.sourceRoot).standardizedFileURL
                if exists(u) { standInRoots.append(u) } else { pt.notes.append("bridging header \(bridging) is missing") }
            }
            let adjacentHeaders = cFamily.compactMap { f -> URL? in
                let h = f.deletingPathExtension().appendingPathExtension("h")
                if exists(h) { return h }
                return projectHeaders()[h.lastPathComponent]?.first
            }
            let appleOnly = !cFamily.isEmpty && needsAppleSDK(cFamilyFiles: cFamily + adjacentHeaders)
            if pt.sources.isEmpty, !cFiles.isEmpty, objc.isEmpty, !appleOnly {
                // A pure C target: its sources, and headers next to them as its public headers.
                for c in cFiles + cxx { pt.verbatim.append(PlanFile(origin: c, staged: stagedPath(c))) }
                var headers = Set<String>()
                for dir in Set((cFiles + cxx).map { $0.deletingLastPathComponent() }) {
                    for h in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where h.hasSuffix(".h") && headers.insert(h).inserted {
                        pt.verbatim.append(PlanFile(origin: dir.appendingPathComponent(h), staged: "include/" + h))
                    }
                }
                pt.notes.append("a C target (\(cFiles.count + cxx.count) files)")
            } else {
                if !cFamily.isEmpty {
                    let names = cFamily.map(\.lastPathComponent)
                    pt.notes.append("C-family sources aren't compiled (they need Apple's SDK or the Objective-C runtime): \(names.prefix(6).joined(separator: ", "))\(names.count > 6 ? "…" : "") become Swift stand-ins that report the feature unavailable")
                }
                if kind == .library, !cFamily.isEmpty {
                    // A framework's Objective-C API: its umbrella header and the headers of its sources.
                    pt.standInAccess = "public"
                    for name in [t.name + ".h", module + ".h"] {
                        if let u = projectHeaders()[name]?.first, !standInRoots.contains(u) { standInRoots.append(u) }
                    }
                    for h in adjacentHeaders where !standInRoots.contains(h) { standInRoots.append(h) }
                }
                if !standInRoots.isEmpty {
                    pt.standInHeaders = headerClosure(of: standInRoots, searchRoots: [project.sourceRoot], index: projectHeaders())
                    pt.notes.append("Swift stand-ins generated for \(pt.standInHeaders.count) header\(pt.standInHeaders.count == 1 ? "" : "s") (\(standInRoots.map(\.lastPathComponent).prefix(4).joined(separator: ", "))\(standInRoots.count > 4 ? "…" : ""))")
                }
            }
            for r in rest { pt.notes.append("\(r.lastPathComponent) (\(r.pathExtension)) isn't compiled on Linux") }

            // Resources, laid out as in Contents/Resources.
            var bundlePaths = Set<String>()
            let infoFile = s.string("INFOPLIST_FILE")
            let infoURL = infoFile.isEmpty ? nil : URL(fileURLWithPath: infoFile, relativeTo: project.sourceRoot).standardizedFileURL
            for r in t.resources {
                guard exists(r.url) else { pt.notes.append("resource \(relativePath(r.url, from: project.sourceRoot)) is missing"); continue }
                if r.url.standardizedFileURL == infoURL { continue }
                switch r.url.pathExtension {
                case "xcassets": if !pt.assetCatalogs.contains(r.url) { pt.assetCatalogs.append(r.url) }
                case "xcstrings": if !pt.stringCatalogs.contains(r.url) { pt.stringCatalogs.append(r.url) }
                default:
                    guard bundlePaths.insert(r.bundlePath).inserted else { continue }
                    pt.resources.append(PlanResource(rule: .copy, origin: r.url, staged: r.bundlePath))
                }
            }

            for d in t.dependencies {
                guard let m = names[d], let dt = project.target(named: d) else { continue }
                // Apps and tools are built alongside, not linked; tests link the app they test.
                if (dt.role == .app || dt.role == .tool) && kind != .test { continue }
                if !pt.localDependencies.contains(m) { pt.localDependencies.append(m) }
            }
            for p in t.packageProducts {
                var package: String?
                if let i = p.package, i < project.packages.count { package = addDependency(project.packages[i]) }
                else if let local = localPackages.first(where: { $0.products.contains(p.product) }) {
                    package = addDependency(XcodePackage(.local(local.dir)))
                } else if let remote = project.packages.first(where: { $0.identity == p.product.lowercased() }) {
                    package = addDependency(remote)
                }
                let ref = ProductRef(product: p.product, package: package)
                if !pt.productDependencies.contains(ref) { pt.productDependencies.append(ref) }
            }

            let ss = mergedSwiftSettings(t)
            pt.settings = ss.settings
            pt.notes += ss.notes
            if kind == .executable {
                let info = infoPlist(t, executable: module)
                pt.infoPlist = info.plist
                pt.bundleIdentifier = info.plist["CFBundleIdentifier"] as? String
                pt.notes += info.notes
            }
            targets.append(pt)
        }
        // Products whose package the project doesn't say: any remote package
        // could declare them, so every remote package is a dependency; the
        // tool matches them once the packages are fetched.
        if targets.contains(where: { $0.productDependencies.contains { $0.package == nil } }) {
            for p in project.packages { if case .remote = p.location { _ = addDependency(p) } }
        }

        var plan = Plan(name: project.name, root: project.sourceRoot, targets: targets,
                        products: targets.filter { $0.kind == .executable }.map { ($0.name, "executable", [$0.name]) },
                        dependencies: deps, languageModes: ["v5"], defaultLocalization: project.developmentRegion, notes: notes)
        plan.pins = pins
        plan.origin = project.format == .xcodegen ? .xcodeGen : .xcode
        return plan
    }

    /// A source's path inside its staged target: relative to the project,
    /// with `..` steps spelled `_up` so files outside it stay apart.
    func stagedPath(_ u: URL) -> String {
        relativePath(u, from: project.sourceRoot).split(separator: "/").map { $0 == ".." ? "_up" : String($0) }.joined(separator: "/")
    }
}

/// Folders holding a Package.swift under `dir`, `depth` levels down (not
/// inside hidden folders, build output or bundles).
public func packageDirectories(under dir: URL, depth: Int) -> [URL] {
    guard depth > 0 else { return [] }
    var out: [URL] = []
    for e in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    where !e.hasPrefix(".") && !["build", "Build", "DerivedData", "Pods", "Carthage", "node_modules"].contains(e) {
        let u = dir.appendingPathComponent(e)
        guard isDirectory(u), !opaqueFolderExtensions.contains(u.pathExtension), u.pathExtension != "xcodeproj", u.pathExtension != "xcworkspace" else { continue }
        if exists(u.appendingPathComponent("Package.swift")) { out.append(u.standardizedFileURL); continue }
        out += packageDirectories(under: u, depth: depth - 1)
    }
    return out
}

/// Products a package's manifest declares, read from its text (no
/// evaluation): `.library(name: "X"…)`, `.executable(name: "X"…)`.
public func declaredProducts(inPackageAt dir: URL) -> [String] {
    guard let text = try? String(contentsOf: dir.appendingPathComponent("Package.swift"), encoding: .utf8) else { return [] }
    let rx = try! NSRegularExpression(pattern: #"\.(?:library|executable)\s*\(\s*name:\s*"([^"]+)""#)
    return rx.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
}
