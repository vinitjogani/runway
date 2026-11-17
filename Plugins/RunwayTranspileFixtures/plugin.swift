// Build-tool plugin for the transpiler's end-to-end tests: each
// `*.swiftfixture` in the target is run through RunwayTranspiler and the
// result is compiled into the test target, so the tests exercise the
// transformed code against Runway's AppKit and RunwayObjC.
//
// Fixtures that import AppKit are stubbed (their `// stub:` lines) while
// AppKit still declares its own `Selector` (before it re-exports RunwayObjC's).

import Foundation
import PackagePlugin

@main
struct RunwayTranspileFixtures: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let tool = try context.tool(named: "runway-transpile")
        let appKitDir = context.package.directoryURL.appending(path: "Sources/AppKit")
        let appKitFiles = ((try? FileManager.default.contentsOfDirectory(at: appKitDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "swift" }
        let appKitText = appKitFiles.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }.joined()
        let appKitOwnsSelector = appKitText.contains("public struct Selector") && !appKitText.contains("import RunwayObjC")
        let fixtures = target.sourceFiles.map { $0.url }.filter { $0.pathExtension == "swiftfixture" }
        // Each fixture is transpiled with the others indexed: they're one
        // module, so an override in one's extension moves into another's class.
        let others = fixtures.flatMap { ["--with", $0.path] }
        // The module's class table (Interface Builder's customClass lookups).
        let registry = context.pluginWorkDirectoryURL.appending(path: "_RunwayClassRegistry.swift")
        let registryCommand: Command = .buildCommand(
            displayName: "Generating the class registry for \(target.name)",
            executable: tool.url,
            arguments: ["--registry", target.moduleName, registry.path] + fixtures.map(\.path),
            inputFiles: fixtures,
            outputFiles: [registry])
        return [registryCommand] + fixtures.map { url in
            let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let stub = appKitOwnsSelector && source.contains("import AppKit")
            let out = context.pluginWorkDirectoryURL.appending(path: url.deletingPathExtension().lastPathComponent + ".swift")
            return .buildCommand(
                displayName: "Transpiling \(url.lastPathComponent)",
                executable: tool.url,
                arguments: ["--emit", url.path, out.path] + (stub ? ["--stub"] : []) + others,
                inputFiles: fixtures + appKitFiles,
                outputFiles: [out])
        }
    }
}
