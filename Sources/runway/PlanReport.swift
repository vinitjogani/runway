// Wiring the plan to its resolved dependencies, and `runway plan`: what an
// app is made of as Runway reads it.

import Foundation
import RunwayImport

/// The staged package's directory name: the app's name, filesystem-safe.
func stageName(_ name: String) -> String {
    String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "-" })
}

/// Products the app names without saying which package declares them
/// (Xcode's package product dependencies on local packages, byName
/// dependencies): matched against the resolved packages' products.
/// References to packages that couldn't be resolved are dropped, noted.
func linkUnresolvedProducts(_ plan: inout Plan, _ graph: DependencyGraph) {
    let local = Set(plan.targets.map(\.name))
    var identityOf: [String: String] = [:]
    for d in plan.dependencies {
        identityOf[d.identity.lowercased()] = d.identity.lowercased()
        for a in d.aliases { identityOf[a.lowercased()] = d.identity.lowercased() }
    }
    let direct = Set(plan.dependencies.map { $0.identity.lowercased() })
    for i in plan.targets.indices {
        var refs: [ProductRef] = []
        for var p in plan.targets[i].productDependencies {
            if p.package == nil {
                if local.contains(p.product) { refs.append(p); continue }
                // Prefer the app's direct dependencies.
                let candidates = graph.resolved.values.sorted { (direct.contains($0.identity) ? 0 : 1, $0.identity) < (direct.contains($1.identity) ? 0 : 1, $1.identity) }
                guard let r = candidates.first(where: { $0.products.contains(p.product) }) else {
                    log("warning: \(plan.targets[i].name): no package provides product \(p.product); left out")
                    continue
                }
                if !direct.contains(r.identity), let d = graph.declarations[r.identity] {
                    plan.dependencies.append(d)
                }
                p.package = r.identity
                identityOf[r.identity] = r.identity
            }
            let id = identityOf[p.package!.lowercased()] ?? p.package!.lowercased()
            if graph.resolved[id] == nil {
                log("warning: \(plan.targets[i].name): product \(p.product) left out (package \(p.package!): \(graph.failed[id] ?? "not resolved"))")
                continue
            }
            // A manifest evaluated on Linux can leave out Apple-only products (`#if canImport(Darwin)`).
            if let r = graph.resolved[id], r.mode != .sharedWithRunway, !r.products.isEmpty, !r.products.contains(p.product) {
                log("warning: \(plan.targets[i].name): package \(id) declares no product \(p.product) on this platform (its manifest leaves it out); left out")
                continue
            }
            if !refs.contains(p) { refs.append(p) }
        }
        plan.targets[i].productDependencies = refs
    }
    plan.dependencies = plan.dependencies.filter { graph.resolved[$0.identity.lowercased()] != nil }
}

/// Removes staged dependencies the graph no longer has.
func pruneStagedDependencies(_ stageDir: URL, keep: Set<String>) {
    let dir = stageDir.appendingPathComponent("Dependencies")
    for e in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !keep.contains(e.lowercased()) {
        try? fm.removeItem(at: dir.appendingPathComponent(e))
    }
}

/// `runway plan`: the plan, target by target.
func printPlan(_ plan: Plan) {
    let platform = plan.xcodePlatform.map { ", \($0.name)" } ?? ""
    print("\(plan.name) (\(plan.origin.rawValue)\(platform), \(plan.root.path))")
    for n in plan.notes { print("  note: \(n)") }
    for t in plan.targets {
        print("\n\(t.name) [\(t.kind.rawValue)]\(t.productName.map { " product \($0)" } ?? "")")
        print("  sources: \(t.sources.count) Swift\(t.verbatim.isEmpty ? "" : ", \(t.verbatim.count) other")")
        for f in t.sources.prefix(5) { print("    \(f.staged)") }
        if t.sources.count > 5 { print("    …") }
        if !t.resources.isEmpty {
            print("  resources (\(t.mainBundleResources ? "main bundle" : "SwiftPM bundle")): \(t.resources.count)")
            for r in t.resources.prefix(8) { print("    \(r.staged)") }
            if t.resources.count > 8 { print("    …") }
        }
        if !t.assetCatalogs.isEmpty { print("  asset catalogs: \(t.assetCatalogs.map(\.lastPathComponent).joined(separator: ", "))") }
        if !t.stringCatalogs.isEmpty { print("  string catalogs: \(t.stringCatalogs.map(\.lastPathComponent).joined(separator: ", "))") }
        if !t.localDependencies.isEmpty { print("  depends on: \(t.localDependencies.joined(separator: ", "))") }
        if !t.productDependencies.isEmpty {
            print("  products: \(t.productDependencies.map { $0.product + ($0.package.map { " (\($0))" } ?? "") }.joined(separator: ", "))")
        }
        if !t.settings.isEmpty { print("  settings: \(t.settings.map { $0.render() }.joined(separator: " "))") }
        if let info = t.infoPlist {
            let keys = ["CFBundleIdentifier", "CFBundleName", "CFBundleExecutable", "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion", "LSUIElement", "NSPrincipalClass", "NSMainStoryboardFile"]
            print("  Info.plist: " + keys.compactMap { k in info[k].map { "\(k)=\($0)" } }.joined(separator: " ") + " (\(info.count) keys)")
        }
        for n in t.notes { print("  note: \(n)") }
    }
    if !plan.dependencies.isEmpty {
        print("\npackages:")
        for d in plan.dependencies {
            let source: String
            switch d.source {
            case .remote(let url): source = url
            case .local(let p): source = p.path
            }
            let pin = d.pinnedVersion ?? d.pinnedRevision.map { String($0.prefix(12)) } ?? plan.pins[d.identity]?.version ?? plan.pins[d.identity]?.revision.map { String($0.prefix(12)) }
            print("  \(d.identity): \(source) \(d.requirement)\(pin.map { ", pinned \($0)" } ?? "")")
        }
    }
}
