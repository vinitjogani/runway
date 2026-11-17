// Reading `<Name>.xcodeproj/project.pbxproj`: the object graph (groups,
// file references, build phases, build configurations, package
// references, synchronized folders) resolved into an XcodeProject.

import Foundation

public struct ImportError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

public enum PBXProjectReader {
    public static func read(_ xcodeproj: URL) throws -> XcodeProject {
        let file = xcodeproj.appendingPathComponent("project.pbxproj")
        let root: PlistValue
        do { root = try OpenStepPlist.parse(contentsOf: file) } catch {
            throw ImportError("can't parse \(file.path): \(error)")
        }
        return try read(root, xcodeproj: xcodeproj)
    }

    public static func read(_ root: PlistValue, xcodeproj: URL) throws -> XcodeProject {
        guard let objects = root["objects"]?.dict, let rootID = root["rootObject"]?.string, let proj = objects[rootID]?.dict else {
            throw ImportError("\(xcodeproj.path): no root object")
        }
        var g = Graph(objects: objects, project: proj, xcodeproj: xcodeproj)
        return g.build()
    }

    struct Graph {
        let objects: [String: PlistValue]
        let project: [String: PlistValue]
        let xcodeproj: URL
        let sourceRoot: URL
        var parent: [String: String] = [:]
        var notes: [String] = []

        init(objects: [String: PlistValue], project: [String: PlistValue], xcodeproj: URL) {
            self.objects = objects
            self.project = project
            self.xcodeproj = xcodeproj
            let dir = xcodeproj.deletingLastPathComponent()
            let projectDir = project["projectDirPath"]?.string ?? ""
            sourceRoot = (projectDir.isEmpty ? dir : URL(fileURLWithPath: projectDir, relativeTo: dir)).standardizedFileURL
            for (id, o) in objects {
                for c in o["children"]?.strings ?? [] { parent[c] = id }
            }
        }

        func obj(_ id: String?) -> [String: PlistValue]? { id.flatMap { objects[$0]?.dict } }
        func isa(_ id: String?) -> String { obj(id)?["isa"]?.string ?? "" }

        /// A file or group's location on disk; nil for ones relative to the
        /// SDK, the build products or the developer directory.
        func path(of id: String, depth: Int = 0) -> URL? {
            guard depth < 64, let o = obj(id) else { return nil }
            let p = o["path"]?.string
            switch o["sourceTree"]?.string ?? "<group>" {
            case "<group>":
                let base: URL?
                if let par = parent[id] { base = path(of: par, depth: depth + 1) } else { base = sourceRoot }
                guard let base else { return nil }
                guard let p, !p.isEmpty else { return base }
                return URL(fileURLWithPath: p, relativeTo: base).standardizedFileURL
            case "SOURCE_ROOT":
                return URL(fileURLWithPath: p ?? "", relativeTo: sourceRoot).standardizedFileURL
            case "<absolute>":
                return p.map { URL(fileURLWithPath: $0).standardizedFileURL }
            default:
                return nil  // BUILT_PRODUCTS_DIR, SDKROOT, DEVELOPER_DIR…
            }
        }

        /// The path of a file reference relative to its nearest group, for
        /// working out its place in the bundle (`en.lproj/Foo.strings`).
        func groupRelativePath(of id: String) -> String {
            obj(id)?["path"]?.string ?? obj(id)?["name"]?.string ?? ""
        }

        func configurations(_ listID: String?) -> (names: [String], defaultName: String?, settings: [String: [SettingAssignment]], notes: [String]) {
            guard let list = obj(listID) else { return ([], nil, [:], []) }
            var names: [String] = [], settings: [String: [SettingAssignment]] = [:], notes: [String] = []
            for cid in list["buildConfigurations"]?.strings ?? [] {
                guard let c = obj(cid), let name = c["name"]?.string else { continue }
                names.append(name)
                var stack: [SettingAssignment] = []
                var xcconfig: URL?
                if let ref = c["baseConfigurationReference"]?.string { xcconfig = path(of: ref) }
                if xcconfig == nil, let anchor = c["baseConfigurationReferenceAnchor"]?.string, let dir = path(of: anchor),
                   let rel = c["baseConfigurationReferenceRelativePath"]?.string {
                    xcconfig = dir.appendingPathComponent(rel)  // an xcconfig inside a synchronized folder
                }
                if let x = xcconfig {
                    var missing: [String] = []
                    stack += XCConfig.parse(x, missing: &missing)
                    for m in missing { notes.append("xcconfig \(m) (configuration \(name)) is missing") }
                }
                stack += settingAssignments(c["buildSettings"]?.dict ?? [:])
                settings[name] = stack
            }
            return (names, list["defaultConfigurationName"]?.string, settings, notes)
        }

        static func requirement(_ r: [String: PlistValue]) -> PlanDependency.Requirement {
            let min = r["minimumVersion"]?.string ?? "0.0.0"
            switch r["kind"]?.string ?? "" {
            case "upToNextMajorVersion": return .range(min, nextVersion(min, major: true))
            case "upToNextMinorVersion": return .range(min, nextVersion(min, major: false))
            case "versionRange": return .range(min, r["maximumVersion"]?.string ?? nextVersion(min, major: true))
            case "exactVersion": return .exact(r["version"]?.string ?? min)
            case "branch": return .branch(r["branch"]?.string ?? "main")
            case "revision": return .revision(r["revision"]?.string ?? "")
            default: return .any
            }
        }

        mutating func build() -> XcodeProject {
            var xp = XcodeProject(name: xcodeproj.deletingPathExtension().lastPathComponent, format: .pbxproj, file: xcodeproj, sourceRoot: sourceRoot)
            xp.developmentRegion = project["developmentRegion"]?.string
            let projectConfigs = configurations(project["buildConfigurationList"]?.string)
            xp.configurations = projectConfigs.names
            xp.defaultConfiguration = projectConfigs.defaultName
            xp.settings = projectConfigs.settings
            notes += projectConfigs.notes

            // Packages, by object ID.
            var packageIndex: [String: Int] = [:]
            for pid in (project["packageReferences"]?.strings ?? []) + objects.keys.sorted() where packageIndex[pid] == nil {
                guard let p = obj(pid) else { continue }
                switch p["isa"]?.string {
                case "XCRemoteSwiftPackageReference":
                    guard let url = p["repositoryURL"]?.string else { continue }
                    packageIndex[pid] = xp.packages.count
                    xp.packages.append(XcodePackage(.remote(url: url, requirement: Graph.requirement(p["requirement"]?.dict ?? [:]))))
                case "XCLocalSwiftPackageReference":
                    guard let rel = p["relativePath"]?.string ?? p["path"]?.string else { continue }
                    packageIndex[pid] = xp.packages.count
                    xp.packages.append(XcodePackage(.local(URL(fileURLWithPath: rel, relativeTo: sourceRoot).standardizedFileURL)))
                default: continue
                }
            }

            // Local packages and nested projects referenced as files.
            for (_, o) in objects {
                guard o["isa"]?.string == "PBXFileReference" else { continue }
                let type = o["lastKnownFileType"]?.string ?? o["explicitFileType"]?.string ?? ""
                if type == "wrapper.pb-project", let name = o["path"]?.string {
                    notes.append("nested project \(name) is not imported (its products are left out)")
                }
            }
            for (id, o) in objects where o["isa"]?.string == "PBXFileReference" {
                let type = o["lastKnownFileType"]?.string ?? ""
                guard ["wrapper", "folder", "text"].contains(type) || (o["path"]?.string ?? "").hasSuffix("Package.swift"),
                      var u = path(of: id) else { continue }
                if u.lastPathComponent == "Package.swift" { u = u.deletingLastPathComponent() }
                if exists(u.appendingPathComponent("Package.swift")), !xp.packageDirectories.contains(u) { xp.packageDirectories.append(u) }
            }

            // Which target produces which product reference.
            var productOwner: [String: String] = [:]
            let targetIDs = project["targets"]?.strings ?? []
            for tid in targetIDs {
                if let ref = obj(tid)?["productReference"]?.string, let n = obj(tid)?["name"]?.string { productOwner[ref] = n }
            }

            // Synchronized folders: exceptions per (group, target), and
            // build-phase exceptions per phase.
            var syncExceptions: [String: [String: Set<String>]] = [:]  // group -> target -> paths
            var phaseExceptions: [String: Set<String>] = [:]  // "group|phase" -> paths
            for (gid, g) in objects where g["isa"]?.string == "PBXFileSystemSynchronizedRootGroup" {
                for eid in g["exceptions"]?.strings ?? [] {
                    guard let e = obj(eid) else { continue }
                    let paths = Set(e["membershipExceptions"]?.strings ?? [])
                    switch e["isa"]?.string {
                    case "PBXFileSystemSynchronizedBuildFileExceptionSet":
                        if let t = e["target"]?.string { syncExceptions[gid, default: [:]][t, default: []].formUnion(paths) }
                    case "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet":
                        if let ph = e["buildPhase"]?.string { phaseExceptions["\(gid)|\(ph)", default: []].formUnion(paths) }
                    default: break
                    }
                }
            }
            var syncItemsCache: [String: [SyncItem]] = [:]
            var packageDirs = xp.packageDirectories
            func syncItems(_ gid: String) -> [SyncItem] {
                if let c = syncItemsCache[gid] { return c }
                guard let g = obj(gid), let dir = path(of: gid), isDirectory(dir) else { syncItemsCache[gid] = []; return [] }
                let folders = Set(g["explicitFolders"]?.strings ?? [])
                    .union((g["explicitFileTypes"]?.dict ?? [:]).filter { $0.value.string?.hasPrefix("folder") == true }.keys)
                let items = synchronizedItems(dir, explicitFolders: folders, packages: &packageDirs)
                syncItemsCache[gid] = items
                return items
            }
            let syncGroupIDs = objects.keys.filter { isa($0) == "PBXFileSystemSynchronizedRootGroup" }.sorted()

            for tid in targetIDs {
                guard let t = obj(tid), let name = t["name"]?.string else { continue }
                let kind = t["isa"]?.string ?? ""
                var type = (t["productType"]?.string ?? "").replacingOccurrences(of: "com.apple.product-type.", with: "")
                if kind == "PBXAggregateTarget" { type = "aggregate" }
                if kind == "PBXLegacyTarget" { type = "legacy" }
                var xt = XcodeTarget(name: name, productType: type)
                let cfg = configurations(t["buildConfigurationList"]?.string)
                xt.settings = cfg.settings
                xt.notes += cfg.notes

                var phaseIDs = Set<String>()
                for ph in t["buildPhases"]?.strings ?? [] {
                    guard let phase = obj(ph) else { continue }
                    phaseIDs.insert(ph)
                    let files = phase["files"]?.strings ?? []
                    switch phase["isa"]?.string {
                    case "PBXSourcesBuildPhase":
                        for bf in files {
                            guard let ref = obj(bf)?["fileRef"]?.string else { continue }
                            if isa(ref) == "PBXVariantGroup" || isa(ref) == "XCVersionGroup" {
                                if let u = path(of: ref) { xt.otherSources.append(u) }
                                continue
                            }
                            guard let u = path(of: ref) else { continue }
                            if u.pathExtension == "swift" { xt.sources.append(u) } else { xt.otherSources.append(u) }
                        }
                    case "PBXResourcesBuildPhase":
                        for bf in files {
                            guard let ref = obj(bf)?["fileRef"]?.string, let r = obj(ref) else { continue }
                            if r["isa"]?.string == "PBXVariantGroup" {
                                let groupName = r["name"]?.string ?? ""
                                for child in r["children"]?.strings ?? [] {
                                    guard let u = path(of: child) else { continue }
                                    let rel = groupRelativePath(of: child)
                                    var bp = bundlePath(forResource: rel)
                                    if !bp.contains(".lproj/") {
                                        let lang = obj(child)?["name"]?.string ?? "Base"
                                        bp = "\(lang).lproj/\(groupName.isEmpty ? u.lastPathComponent : groupName)"
                                    }
                                    xt.resources.append(XcodeResource(url: u, bundlePath: bp))
                                }
                            } else if let u = path(of: ref) {
                                // A localized file outside a variant group keeps its lproj.
                                let parentDir = u.deletingLastPathComponent().lastPathComponent
                                let bp = parentDir.hasSuffix(".lproj") ? parentDir + "/" + u.lastPathComponent : u.lastPathComponent
                                xt.resources.append(XcodeResource(url: u, bundlePath: bp))
                            }
                        }
                    case "PBXFrameworksBuildPhase":
                        for bf in files {
                            guard let b = obj(bf) else { continue }
                            if let ref = b["fileRef"]?.string, let owner = productOwner[ref] {
                                if !xt.dependencies.contains(owner) { xt.dependencies.append(owner) }
                            }
                            if let pr = b["productRef"]?.string { addProduct(pr, to: &xt, packageIndex) }
                        }
                    case "PBXCopyFilesBuildPhase":
                        for bf in files {
                            if let ref = obj(bf)?["fileRef"]?.string, let owner = productOwner[ref], !xt.embeds.contains(owner) {
                                xt.embeds.append(owner)
                            }
                        }
                    default: break
                    }
                }
                for pr in t["packageProductDependencies"]?.strings ?? [] { addProduct(pr, to: &xt, packageIndex) }
                for d in t["dependencies"]?.strings ?? [] {
                    guard let dep = obj(d) else { continue }
                    if let target = dep["target"]?.string, let n = obj(target)?["name"]?.string {
                        if !xt.dependencies.contains(n) { xt.dependencies.append(n) }
                    } else if let proxy = obj(dep["targetProxy"]?.string), let remote = proxy["remoteGlobalIDString"]?.string,
                              let n = obj(remote)?["name"]?.string {
                        if !xt.dependencies.contains(n) { xt.dependencies.append(n) }
                    } else if let pr = dep["productRef"]?.string {
                        addProduct(pr, to: &xt, packageIndex)
                    }
                }

                // Synchronized folders this target owns, and others' exceptions naming it.
                let own = Set(t["fileSystemSynchronizedGroups"]?.strings ?? [])
                for gid in syncGroupIDs {
                    let excepted = syncExceptions[gid]?[tid] ?? []
                    let isOwner = own.contains(gid)
                    if !isOwner && excepted.isEmpty { continue }
                    var phaseExcluded = Set<String>()
                    for ph in phaseIDs { phaseExcluded.formUnion(phaseExceptions["\(gid)|\(ph)"] ?? []) }
                    for item in syncItems(gid) {
                        let listed = isListed(item.relative, in: excepted)
                        if isOwner == listed { continue }  // owners skip their exceptions; others take only them
                        if isListed(item.relative, in: phaseExcluded) { continue }  // moved to a copy phase
                        xt.addSynchronized(item)
                    }
                }
                xp.targets.append(xt)
            }
            // Synchronized folders no target owns can still hold local packages (NetNewsWire's Modules).
            for gid in syncGroupIDs { _ = syncItems(gid) }
            for d in packageDirs where !xp.packageDirectories.contains(d) { xp.packageDirectories.append(d) }
            let shared = xcodeproj.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
            if exists(shared) { xp.resolvedFile = shared }
            xp.notes = notes
            return xp
        }

        func addProduct(_ id: String, to t: inout XcodeTarget, _ packageIndex: [String: Int]) {
            guard let p = obj(id), var name = p["productName"]?.string else { return }
            if name.hasPrefix("plugin:") { return }  // build-tool plugins run on the host; not staged
            if name.hasPrefix("macro:") { name = String(name.dropFirst("macro:".count)) }
            let dep = XcodeProductDependency(product: name, package: p["package"]?.string.flatMap { packageIndex[$0] })
            if !t.packageProducts.contains(dep) { t.packageProducts.append(dep) }
        }
    }
}

/// `1.2.3` → `2.0.0` (major) or `1.3.0` (minor).
public func nextVersion(_ v: String, major: Bool) -> String {
    let parts = v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [0]
    let ma = parts.first ?? 0, mi = parts.count > 1 ? parts[1] : 0
    return major ? "\(ma + 1).0.0" : "\(ma).\(mi + 1).0"
}
