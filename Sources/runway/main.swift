// runway: build, run and test an unchanged Apple app on Linux or Windows.
// Zero configuration: point it at the app's folder and it works out the rest.
//
//   runway check <dir>   Portability report: every file's imports and
//                        the Apple APIs it uses, against what Runway maps.
//   runway plan  <dir>   What the app is made of, as Runway reads it: targets,
//                        files, resources, settings, packages.
//   runway stage <dir>   Writes the staged package and prints its path.
//   runway build <dir>   Stages, then `swift build`.
//   runway run   <dir>   Stages, builds, then runs the app (--headless for no display).
//   runway test  <dir>   Stages, then `swift test`.
//
// <dir> holds a SwiftPM package (Package.swift), an Xcode project or
// workspace (.xcodeproj in the project.pbxproj or the JSON project.xcproj
// format, .xcworkspace), or an XcodeGen project.yml.
// Options: --project <name|path>, --target <app>, --platform macos|ios, --product <name>,
// --filter <test>, --skip <test>, -c debug|release, --headless,
// --device iphone-pro|iphone|ipad, --ios-simulator-code.
//
// Xcode projects are read by RunwayImport into the same plan a SwiftPM
// package gives (one SwiftPM target per Xcode target). Package
// dependencies are fetched at their pinned revisions and staged the same
// way, or replaced by Runway's third-party shims (Dependencies.swift).
//
// Staging leaves the app untouched. Under runway/.runway it
// writes a copy of every source through transformSource(_:path:) (the
// transpiler hook; see Stage.swift), wrapped in #sourceLocation so #filePath
// and diagnostics name the original file, and a Package.swift whose targets
// depend on Runway's module for each Apple framework they import: `import
// SwiftUI` gets Runway's SwiftUI, `import AppKit` (or Cocoa) its AppKit, and
// so on. Compiler settings (language mode, default isolation, defines)
// carry over; resources are copied, asset and string catalogs converted
// (Resources.swift); an app's Info.plist becomes its Bundle.main's.

import Foundation
import RunwayImport
import RunwayTranspiler

// MARK: check

func check(_ plan: Plan) {
    let local = Set(plan.targets.map(\.name) + plan.targets.flatMap { $0.productDependencies.map(\.product) })
    print("Portability report: \(plan.name) (\(plan.root.path))\n")
    var totals = (files: 0, portable: 0)
    let appKitName = try! NSRegularExpression(pattern: "\\bNS[A-Z][A-Za-z]+")
    for t in plan.targets {
        print("\(t.name) (\(t.kind.rawValue))")
        var unsupportedByModule: [String: Int] = [:]
        for f in t.sources {
            guard let s = try? String(contentsOf: f.origin, encoding: .utf8) else { continue }
            let mods = imports(in: s)
            let blockers = mods.filter { classify($0, local: local) == .unsupported }
            // AppKit names beyond the slice Runway's AppKit covers.
            var appkit: [String] = []
            if mods.contains(where: { canonicalModule($0) == "AppKit" }) {
                let names = Set(appKitName.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } })
                appkit = names.filter { !providedAppKit.contains($0) && !$0.hasSuffix("Notification") && !$0.hasSuffix("Delegate") }.sorted()
            }
            totals.files += 1
            let portable = blockers.isEmpty && appkit.isEmpty
            if portable { totals.portable += 1 }
            var detail = mods.map { m -> String in
                switch classify(m, local: local) {
                case .runway: return m + "→runway"
                case .unsupported: unsupportedByModule[m, default: 0] += 1; return m + "✗"
                default: return m
                }
            }.joined(separator: " ")
            if !appkit.isEmpty { detail += "  unmapped AppKit: " + appkit.prefix(8).joined(separator: ", ") + (appkit.count > 8 ? "…" : "") }
            print("  \((portable ? "portable" : "needs work").padding(toLength: 11, withPad: " ", startingAt: 0)) \(f.staged)  [\(detail)]")
        }
        for (m, n) in unsupportedByModule.sorted(by: { $0.key < $1.key }) {
            print("    ✗ \(m) in \(n) file\(n == 1 ? "" : "s"): \(unsupportedModules[m] ?? "not mapped by Runway")")
        }
        print()
    }
    print("\(totals.portable) of \(totals.files) files pass the import and AppKit name scan. Use runway build to check API compatibility.")
}

// MARK: CLI

let usage = """
usage: runway <check|plan|stage|build|run|test> <dir> [options] [-- args]
  <dir>                    a SwiftPM package, an Xcode project or workspace, or an XcodeGen spec
  --project <name|path>    which .xcodeproj/.xcworkspace/project.yml, when there are several
  --target <name>          the Xcode app target to build (default: the main app)
  --platform <macos|ios>   the Xcode app platform (default: inferred, preferring macos)
  --product <name>         product to build or run
  --filter <pattern>       tests to run
  --skip <pattern>         tests to skip
  -c, --configuration      debug (default) or release
  --headless               run with no display (RUNWAY_BACKEND=headless)
  --device <iphone-pro|iphone|ipad>  viewport for a SwiftUI preview
  --ios-simulator-code     include simulator-only branches in an iOS project
"""

var args = Array(CommandLine.arguments.dropFirst())
// `runway standins <header>…`: prints the Swift stand-ins Runway writes for
// Objective-C/C headers (see RunwayImport/ObjCStandIns.swift), to inspect them.
if args.first == "standins" {
    var options = ObjCStandInOptions()
    options.knownTypes = knownRunwayTypes(runwayRoot())
    print(objcStandInSource(headers: args.dropFirst().compactMap { try? readSource(URL(fileURLWithPath: $0)) }, options: options))
    exit(0)
}
guard let command = args.first, ["check", "plan", "stage", "build", "run", "test"].contains(command) else {
    let help = ["-h", "--help", "help"].contains(args.first ?? "")
    (help ? FileHandle.standardOutput : FileHandle.standardError).write(Data((usage + "\n").utf8))
    exit(help ? 0 : 1)
}
args.removeFirst()

var packagePath: String?
var product: String?
var projectOption: String?
var targetOption: String?
var platformOption: XcodePlatform?
var filters: [String] = []
var skips: [String] = []
var configuration = "debug"
var headless = false
var previewDevice: String?
var includeSimulatorCode = false
var passthrough: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--product": product = args.isEmpty ? nil : args.removeFirst()
    case "--project": projectOption = args.isEmpty ? nil : args.removeFirst()
    case "--target": targetOption = args.isEmpty ? nil : args.removeFirst()
    case "--platform":
        guard let value = args.first, let platform = XcodePlatform(rawValue: value.lowercased()) else {
            die("--platform needs macos or ios")
        }
        args.removeFirst()
        platformOption = platform
    case "--filter": if !args.isEmpty { filters.append(args.removeFirst()) }
    case "--skip": if !args.isEmpty { skips.append(args.removeFirst()) }
    case "-c", "--configuration": configuration = args.isEmpty ? "debug" : args.removeFirst()
    case "--headless": headless = true
    case "--device":
        guard let value = args.first, ["iphone-pro", "iphone", "ipad"].contains(value) else { die("--device needs iphone-pro, iphone or ipad") }
        args.removeFirst()
        previewDevice = value
    case "--ios-simulator-code": includeSimulatorCode = true
    case "--": passthrough = args; args = []
    default:
        if a.hasPrefix("-") { die("unknown option \(a)\n\(usage)") }
        if packagePath == nil { packagePath = a } else { die("unexpected argument \(a)") }
    }
}

let root = runwayRoot()
let packageDir = URL(fileURLWithPath: packagePath ?? ".").standardizedFileURL

var plan: Plan
do {
    let located = try ProjectLocator.locate(packageDir, project: projectOption, platform: platformOption)
    if case .swiftPM(let dir) = located {
        if platformOption != nil { die("--platform selects targets in Xcode projects and XcodeGen specs") }
        plan = try planSwiftPM(dir, scratch: root.appendingPathComponent(".runway/manifests/\(c99Name(dir.path))"))
    } else {
        plan = try planXcodeProject(located, options: XcodeImportOptions(target: targetOption, platform: platformOption))
    }
} catch { die("\(error)") }
if previewDevice != nil, command != "run" { die("--device is used with runway run") }
if includeSimulatorCode, plan.xcodePlatform != .iOS { die("--ios-simulator-code requires an iOS project") }
if command != "plan" { for n in plan.notes { log("note: \(n)") } }

/// The targets `roots` need, themselves included.
func closure(of roots: [String], in plan: Plan) -> Set<String> {
    var keep = Set<String>(), queue = roots
    while let n = queue.popLast() {
        guard keep.insert(n).inserted, let t = plan.targets.first(where: { $0.name == n }) else { continue }
        queue += t.localDependencies
        // byName dependencies that name a local target.
        queue += t.productDependencies.filter { $0.package == nil }.map(\.product).filter { p in plan.targets.contains { $0.name == p } }
    }
    return keep
}

// Stage only what the command needs: `test` the test targets and what they
// depend on, `build/run --product` that product's targets. An app target
// that can't build yet then doesn't stop its library's tests.
var wanted: [String]?
if command == "test" {
    wanted = plan.targets.filter { $0.kind == .test }.map(\.name)
} else if let p = product, ["build", "run"].contains(command) {
    wanted = plan.products.first { $0.name == p }?.targets ?? [p]
}
if let wanted, command != "check" {
    let keep = closure(of: wanted, in: plan)
    plan.targets = plan.targets.filter { keep.contains($0.name) }
}
// Xcode projects: `build`/`run` stage the app without its tests.
if plan.origin != .swiftPM, ["build", "run", "stage"].contains(command) {
    plan.targets = plan.targets.filter { $0.kind != .test }
}
// Packages no staged target uses (a test-only snapshot library…) aren't fetched.
if command != "check", command != "plan", !plan.targets.contains(where: { $0.productDependencies.contains { $0.package == nil && !plan.targets.map(\.name).contains($0.product) } }) {
    let used = Set(plan.targets.flatMap { $0.productDependencies.compactMap { $0.package?.lowercased() } })
    plan.dependencies = plan.dependencies.filter { d in used.contains(d.identity.lowercased()) || !d.aliases.isDisjoint(with: Set(used.map { $0 })) || d.aliases.contains { used.contains($0.lowercased()) } }
}

if command == "check" {
    check(plan)
    exit(0)
}
if command == "plan" {
    printPlan(plan)
    exit(0)
}

// Package dependencies: fetched, staged (or shimmed) and wired by path.
let iosPreview = plan.xcodePlatform == .iOS ? IOSPreview(includingSimulatorCode: includeSimulatorCode) : nil
let stageFolder = switch iosPreview {
case nil: "stage"
case let preview?: preview.includingSimulatorCode ? "stage-ios-simulator" : "stage-ios"
}
let stageDir = root.appendingPathComponent(".runway/\(stageFolder)/\(stageName(plan.name))")
var graph = DependencyGraph(root: root, appStage: stageDir, pins: plan.pins, iosPreview: iosPreview)
let dependencyPaths = graph.resolve(plan).filter { ![.sharedWithRunway, .dropped].contains(graph.resolved[$0.key.lowercased()]?.mode) }
plan.dependencies.removeAll { graph.resolved[$0.identity.lowercased()]?.mode == .dropped }
linkUnresolvedProducts(&plan, graph)
pruneStagedDependencies(stageDir, keep: Set(graph.resolved.values.filter { $0.mode != .asIs }.map(\.identity)))

let staged: Staged
do {
    staged = try stagePlan(plan, at: stageDir, root: root, dependencies: dependencyPaths, iosPreview: iosPreview)
} catch { die("staging \(plan.name) failed: \(error)") }
log("staged \(plan.name) at \(staged.dir.path)")
if command == "stage" {
    print(staged.dir.path)
    exit(0)
}

let swift = which("swift")
var env = headless ? ["RUNWAY_BACKEND": "headless"] : [:]
if let device = previewDevice {
    env["RUNWAY_PREVIEW_DEVICE"] = device
} else if plan.xcodePlatform == .iOS, ProcessInfo.processInfo.environment["RUNWAY_PREVIEW_DEVICE"] == nil {
    env["RUNWAY_PREVIEW_DEVICE"] = "iphone-pro"
}
refreshModuleCacheIfRunwayChanged(staged.dir, root: root)

// RUNWAY_SCRATCH_PATH=<dir>: one SwiftPM build directory for every staged
// app, so Runway's own modules are compiled once and shared between apps
// (the default is a `.build` per staged package).
let scratchArgs: [String] = ProcessInfo.processInfo.environment["RUNWAY_SCRATCH_PATH"].map { ["--scratch-path", URL(fileURLWithPath: $0).standardizedFileURL.path] } ?? []

func binDir() -> URL {
    let out = run(swift, ["build", "-c", configuration, "--show-bin-path"] + scratchArgs, cwd: staged.dir, capture: true, quiet: true)
    return URL(fileURLWithPath: out.output.trimmingCharacters(in: .whitespacesAndNewlines))
}

switch command {
case "build", "run":
    var buildArgs = ["build", "-c", configuration] + scratchArgs
    let apps = plan.targets.filter { $0.kind == .executable }
    // Xcode projects build their main app (the first executable); embedded
    // helpers and tools build with --product <name>.
    let runProduct = product ?? (command == "run" || plan.origin != .swiftPM ? apps.first?.name : nil)
    if let p = runProduct { buildArgs += ["--product", p] }
    let built = run(swift, buildArgs, cwd: staged.dir)
    guard built.status == 0 else { exit(built.status) }
    var bin = binDir()
    // A shared build directory holds every app's products side by side, so
    // each app's main bundle (its executable, Info.plist and resources) is
    // put together in a folder of its own instead.
    if !scratchArgs.isEmpty, let p = runProduct ?? apps.first?.name, exists(bin.appendingPathComponent(p)) {
        let appDir = staged.dir.appendingPathComponent("_RunwayApp")
        try? fm.removeItem(at: appDir)
        ensureDir(appDir)
        try? fm.copyItem(at: bin.appendingPathComponent(p), to: appDir.appendingPathComponent(p))
        // SwiftPM resource bundles (the app's and its packages') are found next to the executable.
        for e in (try? fm.contentsOfDirectory(atPath: bin.path)) ?? [] where e.hasSuffix(".resources") || e.hasSuffix(".bundle") {
            if e.hasSuffix("_\(p).resources") || e.hasSuffix("_\(p).bundle") {
                try? fm.copyItem(at: bin.appendingPathComponent(e), to: appDir.appendingPathComponent(e))
            } else {
                try? fm.createSymbolicLink(at: appDir.appendingPathComponent(e), withDestinationURL: bin.appendingPathComponent(e))
            }
        }
        bin = appDir
        log("app bundle at \(appDir.path)")
    }
    assembleMainBundle(staged, binDir: bin, product: runProduct)
    if command == "build" { exit(0) }
    guard let p = runProduct else { die("\(plan.name) has no executable to run") }
    let ran = run(bin.appendingPathComponent(p).path, passthrough, env: env)
    exit(ran.status)
default:
    var testArgs = ["test", "-c", configuration] + scratchArgs
    for f in filters { testArgs += ["--filter", f] }
    for s in skips { testArgs += ["--skip", s] }
    let result = run(swift, testArgs, cwd: staged.dir, env: env)
    exit(result.status)
}
