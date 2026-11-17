// Xcode 16 synchronized folders (PBXFileSystemSynchronizedRootGroup, and
// the JSON format's `folder` entries): every file under the folder belongs
// to the targets that own it, minus their membership exceptions; targets
// that don't own the folder get just the files their exceptions name.

import Foundation

public struct SyncItem: Equatable {
    /// Path relative to the synchronized folder.
    public var relative: String
    public var url: URL
    /// A folder copied as one item (an asset catalog, a bundle, an explicit folder).
    public var isFolder: Bool
}

/// The items of a synchronized folder: files, and folders Xcode treats as a
/// unit. Directories holding a Package.swift are local packages, not
/// sources: they're reported in `packages` and skipped.
public func synchronizedItems(_ dir: URL, explicitFolders: Set<String> = [], packages: inout [URL]) -> [SyncItem] {
    var out: [SyncItem] = []
    func walk(_ d: URL, _ prefix: String) {
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).sorted()
        for e in entries where !e.hasPrefix(".") {
            let url = d.appendingPathComponent(e)
            let rel = prefix.isEmpty ? e : prefix + "/" + e
            if isDirectory(url) {
                if exists(url.appendingPathComponent("Package.swift")) { packages.append(url.standardizedFileURL); continue }
                let ext = url.pathExtension
                if opaqueFolderExtensions.contains(ext) || explicitFolders.contains(rel) {
                    out.append(SyncItem(relative: rel, url: url, isFolder: true))
                } else {
                    walk(url, rel)
                }
            } else {
                out.append(SyncItem(relative: rel, url: url, isFolder: false))
            }
        }
    }
    walk(dir, "")
    return out
}

/// Whether `relative` is one of `paths` or inside one of them.
public func isListed(_ relative: String, in paths: Set<String>) -> Bool {
    if paths.contains(relative) { return true }
    var p = relative
    while let slash = p.lastIndex(of: "/") {
        p = String(p[..<slash])
        if paths.contains(p) { return true }
    }
    return false
}

extension XcodeTarget {
    /// Adds a synchronized folder's item the way Xcode classifies it: Swift
    /// files compile, other compiled kinds are noted, build-only files
    /// (headers, xcconfigs, entitlements, Info.plist) are skipped, everything
    /// else is a resource.
    public mutating func addSynchronized(_ item: SyncItem) {
        let ext = item.url.pathExtension.lowercased()
        if ext == "swift", !item.isFolder { sources.append(item.url); return }
        if compiledExtensions.contains(ext) { otherSources.append(item.url); return }
        if isBuildOnlyFile(item.url.lastPathComponent) { return }
        resources.append(XcodeResource(url: item.url, bundlePath: bundlePath(forResource: item.relative)))
    }
}
