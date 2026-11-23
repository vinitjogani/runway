// XcodeGen specs (`project.yml`), read when no generated .xcodeproj is
// there: targets, sources (with excludes), settings (base/configs, presets
// left to Xcode's defaults), configFiles, packages and dependencies.

import Foundation

public enum XcodeGenReader {
    public static func read(_ spec: URL) throws -> XcodeProject {
        guard let text = try? String(contentsOf: spec, encoding: .utf8) else { throw ImportError("can't read \(spec.path)") }
        guard let y = try YAML.parse(text) as? [String: Any] else { throw ImportError("\(spec.path): not a YAML mapping") }
        return read(y, spec: spec)
    }

    static func settingsStack(_ s: Any?, config: String, base: URL, configFiles: [String: Any]?, notes: inout [String]) -> [SettingAssignment] {
        var out: [SettingAssignment] = []
        if let f = configFiles?[config] as? String {
            var missing: [String] = []
            out += XCConfig.parse(base.appendingPathComponent(f), missing: &missing)
            notes += missing.map { "xcconfig \($0) is missing" }
        }
        guard let d = s as? [String: Any] else { return out }
        func assignments(_ m: [String: Any]?) -> [SettingAssignment] {
            (m ?? [:]).map { SettingAssignment(rawKey: $0.key, value: ($0.value as? [Any]).map { $0.map { "\($0)" }.joined(separator: " ") } ?? "\($0.value)") }
                .sorted { ($0.conditions.count, $0.key) < ($1.conditions.count, $1.key) }
        }
        if d["base"] != nil || d["configs"] != nil || d["groups"] != nil {
            out += assignments(d["base"] as? [String: Any])
            let configs = d["configs"] as? [String: Any] ?? [:]
            let match = configs.first { $0.key.lowercased() == config.lowercased() }?.value as? [String: Any]
            out += assignments(match)
        } else {
            out += assignments(d)
        }
        return out
    }

    static func requirement(_ p: [String: Any]) -> PlanDependency.Requirement {
        if let v = p["from"] as? String ?? p["majorVersion"] as? String { return .range(v, nextVersion(v, major: true)) }
        if let v = p["minorVersion"] as? String { return .range(v, nextVersion(v, major: false)) }
        if let v = p["exactVersion"] as? String ?? p["version"] as? String { return .exact(v) }
        if let lo = p["minVersion"] as? String { return .range(lo, p["maxVersion"] as? String ?? nextVersion(lo, major: true)) }
        if let b = p["branch"] as? String { return .branch(b) }
        if let r = p["revision"] as? String { return .revision(r) }
        return .any
    }

    /// `*`, `**` and `?` globs over a relative path.
    static func globPath(_ pattern: String, _ path: String) -> Bool {
        let rx = "^" + NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*\\*/", with: "(.*/)?")
            .replacingOccurrences(of: "\\*\\*", with: ".*")
            .replacingOccurrences(of: "\\*", with: "[^/]*")
            .replacingOccurrences(of: "\\?", with: "[^/]") + "(/.*)?$"
        return path.range(of: rx, options: .regularExpression) != nil
    }

    public static func read(_ y: [String: Any], spec: URL) -> XcodeProject {
        let base = spec.deletingLastPathComponent().standardizedFileURL
        var xp = XcodeProject(name: y["name"] as? String ?? base.lastPathComponent, format: .xcodegen, file: spec, sourceRoot: base)
        var notes: [String] = []
        let options = y["options"] as? [String: Any] ?? [:]
        xp.developmentRegion = options["developmentLanguage"] as? String
        xp.configurations = (y["configs"] as? [String: Any]).map { $0.keys.sorted() } ?? ["Debug", "Release"]
        xp.defaultConfiguration = xp.configurations.contains("Release") ? "Release" : xp.configurations.last
        for c in xp.configurations {
            xp.settings[c] = settingsStack(y["settings"], config: c, base: base, configFiles: y["configFiles"] as? [String: Any], notes: &notes)
        }
        var packageByName: [String: Int] = [:]
        for (name, v) in (y["packages"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let p = v as? [String: Any] else { continue }
            if let url = p["url"] as? String {
                packageByName[name] = xp.packages.count
                xp.packages.append(XcodePackage(.remote(url: url, requirement: requirement(p))))
            } else if let path = p["path"] as? String {
                packageByName[name] = xp.packages.count
                xp.packages.append(XcodePackage(.local(URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL)))
            }
        }
        var packageDirs: [URL] = []
        for (name, v) in (y["targets"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let t = v as? [String: Any] else { continue }
            var xt = XcodeTarget(name: name, productType: (t["type"] as? String) ?? "application")
            var defaults: [SettingAssignment] = []
            if let platform = t["platform"] as? String, let preset = platformPresets[platform.lowercased()] {
                defaults.append(SettingAssignment(key: "SDKROOT", value: preset.sdks[0]))
                defaults.append(SettingAssignment(key: "SUPPORTED_PLATFORMS", value: preset.sdks.joined(separator: " ")))
                let deploymentTargets = options["deploymentTarget"] as? [String: Any]
                let version = t["deploymentTarget"] as? String
                    ?? deploymentTargets?.first { $0.key.lowercased() == platform.lowercased() }?.value as? String
                if let version { defaults.append(SettingAssignment(key: preset.deploymentKey, value: version)) }
            }
            for c in xp.configurations {
                xt.settings[c] = defaults + settingsStack(t["settings"], config: c, base: base, configFiles: t["configFiles"] as? [String: Any], notes: &notes)
            }
            if let info = t["info"] as? [String: Any] {
                if let path = info["path"] as? String {
                    for c in xp.configurations { xt.settings[c, default: []].insert(SettingAssignment(key: "INFOPLIST_FILE", value: path), at: 0) }
                }
                if let props = info["properties"] as? [String: Any] { xt.infoProperties = props.mapValues(yamlPlistValue) }
            }
            var sources: [Any] = t["sources"] as? [Any] ?? []
            if let s = t["sources"] as? String { sources = [s] }
            for s in sources {
                let entry: [String: Any] = (s as? [String: Any]) ?? ["path": "\(s)"]
                guard let path = entry["path"] as? String else { continue }
                let url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
                let excludes = entry["excludes"] as? [String] ?? []
                let phase = entry["buildPhase"] as? String
                if phase == "none" { continue }
                if isDirectory(url) && (entry["type"] as? String) != "folder" && !opaqueFolderExtensions.contains(url.pathExtension) {
                    for item in synchronizedItems(url, packages: &packageDirs) where !excludes.contains(where: { globPath($0, item.relative) }) {
                        if phase == "resources" { xt.resources.append(XcodeResource(url: item.url, bundlePath: bundlePath(forResource: item.relative))) }
                        else { xt.addSynchronized(item) }
                    }
                } else if exists(url) {
                    let item = SyncItem(relative: url.lastPathComponent, url: url, isFolder: isDirectory(url))
                    if phase == "resources" || (entry["type"] as? String) == "folder" { xt.resources.append(XcodeResource(url: url, bundlePath: url.lastPathComponent)) }
                    else { xt.addSynchronized(item) }
                } else if (entry["optional"] as? String) != "true" {
                    xt.notes.append("source \(path) doesn't exist")
                }
            }
            for d in t["dependencies"] as? [[String: Any]] ?? [] {
                if let target = d["target"] as? String {
                    xt.dependencies.append(target)
                    if (d["embed"] as? String) == "true" || (d["embed"] as? Bool) == true { xt.embeds.append(target) }
                } else if let pkg = d["package"] as? String {
                    let products = (d["products"] as? [String]) ?? [(d["product"] as? String) ?? pkg]
                    for p in products { xt.packageProducts.append(XcodeProductDependency(product: p, package: packageByName[pkg])) }
                }
            }
            xp.targets.append(xt)
        }
        xp.packageDirectories = packageDirs
        xp.notes = notes
        return xp
    }

    private static let platformPresets: [String: (sdks: [String], deploymentKey: String)] = [
        "macos": (["macosx"], "MACOSX_DEPLOYMENT_TARGET"),
        "ios": (["iphoneos", "iphonesimulator"], "IPHONEOS_DEPLOYMENT_TARGET"),
        "tvos": (["appletvos", "appletvsimulator"], "TVOS_DEPLOYMENT_TARGET"),
        "watchos": (["watchos", "watchsimulator"], "WATCHOS_DEPLOYMENT_TARGET"),
        "visionos": (["xros", "xrsimulator"], "XROS_DEPLOYMENT_TARGET"),
        "driverkit": (["driverkit"], "DRIVERKIT_DEPLOYMENT_TARGET"),
    ]
}

/// YAML scalars as plist values: `true`/`false` are booleans.
func yamlPlistValue(_ v: Any) -> Any {
    if let s = v as? String {
        if s == "true" { return true }
        if s == "false" { return false }
        return s
    }
    if let a = v as? [Any] { return a.map(yamlPlistValue) }
    if let d = v as? [String: Any] { return d.mapValues(yamlPlistValue) }
    return v
}
