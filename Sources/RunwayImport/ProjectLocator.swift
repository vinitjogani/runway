// What kind of project a directory holds, and which one to build:
// an Xcode workspace (its projects and local packages), an Xcode project,
// an XcodeGen spec, a SwiftPM package, or a Tuist manifest (unsupported
// until `tuist generate` has written an .xcodeproj).

import Foundation

public enum LocatedProject: Equatable {
    case swiftPM(URL)
    case xcode(project: URL, workspace: URL?)
    case xcodeGen(URL)
}

/// The projects and folders a workspace's contents.xcworkspacedata lists.
public struct Workspace {
    public var url: URL
    public var projects: [URL] = []
    /// Folder references (local packages among them).
    public var folders: [URL] = []

    public init(_ url: URL) throws {
        self.url = url
        let data = url.appendingPathComponent("contents.xcworkspacedata")
        guard let text = try? String(contentsOf: data, encoding: .utf8) else { throw ImportError("can't read \(data.path)") }
        let base = url.deletingLastPathComponent()
        // <Group location = "group:Sub"> nests relative locations; track the stack.
        var groups: [URL] = [base]
        let tag = try! NSRegularExpression(pattern: #"<(/?)(FileRef|Group)\b([^>]*?)(/?)>"#)
        let loc = try! NSRegularExpression(pattern: #"location\s*=\s*"([^"]*)""#)
        for m in tag.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let closing = Range(m.range(at: 1), in: text).map { !text[$0].isEmpty } ?? false
            let kind = Range(m.range(at: 2), in: text).map { String(text[$0]) } ?? ""
            let attrs = Range(m.range(at: 3), in: text).map { String(text[$0]) } ?? ""
            let selfClosing = Range(m.range(at: 4), in: text).map { !text[$0].isEmpty } ?? false
            if closing {
                if kind == "Group", groups.count > 1 { groups.removeLast() }
                continue
            }
            var resolved: URL?
            if let lm = loc.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)), let r = Range(lm.range(at: 1), in: attrs) {
                let location = String(attrs[r])
                let parts = location.split(separator: ":", maxSplits: 1).map(String.init)
                let path = parts.count == 2 ? parts[1] : location
                switch parts.first {
                case "group": resolved = URL(fileURLWithPath: path, relativeTo: groups.last!)
                case "container": resolved = URL(fileURLWithPath: path, relativeTo: base)
                case "absolute": resolved = URL(fileURLWithPath: path)
                case "self": resolved = base
                default: resolved = URL(fileURLWithPath: path, relativeTo: base)
                }
                resolved = resolved?.standardizedFileURL
            }
            if kind == "Group" {
                if !selfClosing { groups.append(resolved ?? groups.last!) }
                continue
            }
            guard let u = resolved else { continue }
            if u.pathExtension == "xcodeproj" { projects.append(u) } else if isDirectory(u) { folders.append(u) }
        }
    }

    /// Package.resolved shared by the workspace.
    public var resolvedFile: URL? {
        let u = url.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
        return exists(u) ? u : nil
    }
}

public enum ProjectLocator {
    /// The project in `dir` (or `dir` itself when it is an .xcodeproj,
    /// .xcworkspace, project.yml or Package.swift). `project` picks one by
    /// name or path when several are there.
    public static func locate(_ dir: URL, project: String? = nil) throws -> LocatedProject {
        let fm = FileManager.default
        if let p = project {
            let u = p.hasPrefix("/") ? URL(fileURLWithPath: p) : dir.appendingPathComponent(p)
            if exists(u) { return try locate(u.standardizedFileURL) }
            // A name: Foo, Foo.xcodeproj, Foo.xcworkspace.
            for candidate in [p, p + ".xcworkspace", p + ".xcodeproj"] where exists(dir.appendingPathComponent(candidate)) {
                return try locate(dir.appendingPathComponent(candidate))
            }
            throw ImportError("no project \(p) in \(dir.path)")
        }
        switch dir.pathExtension {
        case "xcodeproj": return .xcode(project: dir, workspace: nil)
        case "xcworkspace": return .xcode(project: try projectInWorkspace(Workspace(dir)), workspace: dir)
        default: break
        }
        if dir.lastPathComponent == "Package.swift" { return .swiftPM(dir.deletingLastPathComponent()) }
        if dir.lastPathComponent.hasSuffix(".yml") || dir.lastPathComponent.hasSuffix(".yaml") { return try xcodeGenOrProject(dir) }
        guard isDirectory(dir) else { throw ImportError("\(dir.path) doesn't exist") }

        let entries = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }.map { dir.appendingPathComponent($0) }
        let projects = entries.filter { $0.hasSuffix(".xcodeproj") }.map { dir.appendingPathComponent($0) }
        // A workspace that isn't just CocoaPods' wrapper around the project.
        for w in prefer(workspaces, named: dir.lastPathComponent) {
            if let ws = try? Workspace(w), !ws.projects.isEmpty, let p = try? projectInWorkspace(ws) { return .xcode(project: p, workspace: w) }
        }
        if !projects.isEmpty {
            let readable = projects.filter { exists($0.appendingPathComponent("project.pbxproj")) || exists($0.appendingPathComponent("project.xcproj")) }
            if let p = prefer(readable, named: dir.lastPathComponent).first { return .xcode(project: p, workspace: nil) }
        }
        if entries.contains("project.yml") { return try xcodeGenOrProject(dir.appendingPathComponent("project.yml")) }
        if entries.contains("Package.swift") { return .swiftPM(dir) }
        if entries.contains("Project.swift") || entries.contains("Workspace.swift") || entries.contains("Tuist") {
            throw ImportError("\(dir.path) is a Tuist project: Runway reads Xcode projects, so run `tuist generate` (or `tuist install && tuist generate`) on a Mac first and point runway at the .xcodeproj or .xcworkspace it writes")
        }
        // One level down (an app kept in `xcode/`, `macOS/`…).
        for e in entries where !e.hasPrefix(".") && isDirectory(dir.appendingPathComponent(e)) && !["build", "Build", "DerivedData", "Pods", "Carthage", "node_modules"].contains(e) {
            let sub = dir.appendingPathComponent(e)
            let names = (try? fm.contentsOfDirectory(atPath: sub.path)) ?? []
            if names.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) || names.contains("project.yml") {
                if let found = try? locate(sub) { return found }
            }
        }
        throw ImportError("no Package.swift, .xcodeproj, .xcworkspace or XcodeGen project.yml in \(dir.path)")
    }

    /// project.yml: the .xcodeproj XcodeGen generated next to it, if any; else the spec.
    static func xcodeGenOrProject(_ spec: URL) throws -> LocatedProject {
        let dir = spec.deletingLastPathComponent()
        let generated = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".xcodeproj") }.sorted()
        if let g = generated.first(where: { exists(dir.appendingPathComponent($0).appendingPathComponent("project.pbxproj")) }) {
            return .xcode(project: dir.appendingPathComponent(g), workspace: nil)
        }
        return .xcodeGen(spec)
    }

    static func prefer(_ urls: [URL], named name: String) -> [URL] {
        urls.sorted { a, b in
            let an = a.deletingPathExtension().lastPathComponent == name, bn = b.deletingPathExtension().lastPathComponent == name
            return an != bn ? an : a.path < b.path
        }
    }

    /// The workspace's project with a macOS app (the largest one; Pods
    /// projects last).
    public static func projectInWorkspace(_ ws: Workspace) throws -> URL {
        let candidates = ws.projects.filter { $0.lastPathComponent != "Pods.xcodeproj" && exists($0) }
        guard !candidates.isEmpty else { throw ImportError("\(ws.url.lastPathComponent) lists no Xcode project") }
        var best: (URL, Int)?
        for p in candidates {
            guard let xp = try? readXcodeProject(p) else { continue }
            let score = xp.targets.filter { $0.role == .app }.map { $0.sources.count + 1000 }.max() ?? xp.targets.count
            if best == nil || score > best!.1 { best = (p, score) }
        }
        return best?.0 ?? candidates[0]
    }
}

/// Reads an .xcodeproj in whichever format it's in.
public func readXcodeProject(_ xcodeproj: URL) throws -> XcodeProject {
    if exists(xcodeproj.appendingPathComponent("project.pbxproj")) { return try PBXProjectReader.read(xcodeproj) }
    if exists(xcodeproj.appendingPathComponent("project.xcproj")) { return try XcprojJSONReader.read(xcodeproj) }
    throw ImportError("\(xcodeproj.path) has neither project.pbxproj nor project.xcproj")
}

/// Reads a located Xcode project (with its workspace's packages and pins)
/// and plans it.
public func planXcodeProject(_ located: LocatedProject, options: XcodeImportOptions = .init()) throws -> Plan {
    var xp: XcodeProject
    var resolved: [URL] = []
    switch located {
    case .xcode(let project, let workspace):
        xp = try readXcodeProject(project)
        if let w = workspace, let ws = try? Workspace(w) {
            for f in ws.folders where exists(f.appendingPathComponent("Package.swift")) && !xp.packageDirectories.contains(f) {
                xp.packageDirectories.append(f)
            }
            if let r = ws.resolvedFile { resolved.append(r) }
            xp.notes.append("workspace \(w.lastPathComponent)")
        }
        if let r = xp.resolvedFile { resolved.append(r) }
    case .xcodeGen(let spec):
        xp = try XcodeGenReader.read(spec)
        let r = spec.deletingLastPathComponent().appendingPathComponent("\(xp.name).xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        if exists(r) { resolved.append(r) }
    case .swiftPM(let dir):
        throw ImportError("\(dir.path) is a SwiftPM package, not an Xcode project")
    }
    var pins: [String: Pin] = [:]
    for r in resolved.reversed() { pins.merge(readResolved(r)) { _, new in new } }
    return try XcodeImporter(xp, pins: pins).plan(options: options)
}
