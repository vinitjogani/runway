// Clang module caches don't notice a header added to an umbrella directory,
// so a staged app built before Runway gained a C header keeps failing with
// "cannot find type" until the cache goes. Fingerprint Runway's C headers and
// module maps; when they change, drop the staged package's module caches.

import Foundation
import RunwayImport

func refreshModuleCacheIfRunwayChanged(_ staged: URL, root: URL) {
    var parts: [String] = []
    if let e = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
        for case let url as URL in e where ["h", "modulemap"].contains(url.pathExtension) {
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            parts.append("\(url.path)|\(v?.fileSize ?? 0)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
    }
    let fingerprint = parts.sorted().joined(separator: "\\n")
    let stamp = staged.appendingPathComponent(".build/runway-headers.stamp")
    if (try? String(contentsOf: stamp, encoding: .utf8)) == fingerprint { return }
    if let e = FileManager.default.enumerator(at: staged.appendingPathComponent(".build"), includingPropertiesForKeys: nil) {
        var caches: [URL] = []
        for case let url as URL in e where url.lastPathComponent.hasPrefix("ModuleCache") {
            caches.append(url)
            e.skipDescendants()
        }
        for c in caches { try? FileManager.default.removeItem(at: c) }
    }
    try? FileManager.default.createDirectory(at: stamp.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fingerprint.write(to: stamp, atomically: true, encoding: .utf8)
}
