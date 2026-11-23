// Xcode projects into plans: groups and variant groups, synchronized
// folders and their exceptions, xcconfigs, generated Info.plists, package
// references and pins, the JSON project format, XcodeGen specs, and how a
// directory's project is found.

import Foundation
import XCTest
@testable import RunwayImport

final class PBXImportTests: XCTestCase {
    var project: XcodeProject!
    var plan: Plan!

    override func setUpWithError() throws {
        project = try PBXProjectReader.read(fixtures.appendingPathComponent("GroupsApp/GroupsApp.xcodeproj"))
        plan = try planXcodeProject(.xcode(project: project.file, workspace: fixtures.appendingPathComponent("GroupsApp/GroupsApp.xcworkspace")))
    }

    func target(_ n: String) throws -> PlanTarget { try XCTUnwrap(plan.targets.first { $0.name == n }, "no target \(n)") }

    func testGroupsResolveToFiles() throws {
        let app = try XCTUnwrap(project.target(named: "Groups App"))
        let root = fixtures.appendingPathComponent("GroupsApp").standardizedFileURL
        XCTAssertEqual(app.sources.map { relativePath($0, from: root) }, ["App/GroupsApp.swift", "App/Helper.swift", "Shared/Shared.swift"])
        XCTAssertEqual(app.otherSources.map(\.lastPathComponent), ["Legacy.m"])
        XCTAssertEqual(Set(app.resources.map(\.bundlePath)), [
            "Base.lproj/Main.storyboard", "en.lproj/Main.strings", "en.lproj/Localizable.strings", "Assets.xcassets", "Themes", "ding.aiff",
        ])
        XCTAssertEqual(app.dependencies, ["Kit"])
        XCTAssertEqual(app.embeds, ["Kit"])
        XCTAssertEqual(app.packageProducts.map(\.product), ["Remote", "LocalKit"])  // the plugin isn't a product to link
        XCTAssertEqual(project.packages.count, 2)
        XCTAssertEqual(project.packages[0].location, .remote(url: "https://github.com/example/Remote.git", requirement: .range("1.2.0", "2.0.0")))
        XCTAssertEqual(project.target(named: "GroupsAppTests")?.dependencies, ["Groups App"])  // via the container item proxy
    }

    func testTargetsAndModuleNames() throws {
        XCTAssertEqual(plan.targets.map(\.name), ["Groups_App", "Kit", "GroupsAppTests"])
        XCTAssertEqual(try target("Groups_App").kind, .executable)
        XCTAssertEqual(try target("Kit").kind, .library)
        XCTAssertEqual(try target("GroupsAppTests").kind, .test)
        XCTAssertEqual(try target("Groups_App").localDependencies, ["Kit"])
        XCTAssertEqual(try target("GroupsAppTests").localDependencies, ["Groups_App"])
        XCTAssertTrue(plan.notes.contains { $0.contains("Widget") && $0.contains("app-extension") })
        XCTAssertEqual(plan.products.map(\.name), ["Groups_App"])
    }

    func testSourcesAndResourcesStaging() throws {
        let app = try target("Groups_App")
        XCTAssertEqual(app.sources.map(\.staged), ["App/GroupsApp.swift", "App/Helper.swift", "Shared/Shared.swift"])
        XCTAssertTrue(app.mainBundleResources)
        XCTAssertEqual(app.assetCatalogs.map(\.lastPathComponent), ["Assets.xcassets"])
        XCTAssertEqual(Set(app.resources.map(\.staged)), ["Base.lproj/Main.storyboard", "en.lproj/Main.strings", "en.lproj/Localizable.strings", "Themes", "ding.aiff"])
        XCTAssertTrue(app.notes.contains { $0.contains("Legacy.m") })
    }

    func testSettings() throws {
        let app = try target("Groups_App").settings
        XCTAssertTrue(app.contains(SwiftSetting(kind: .languageMode("v5"), configuration: nil)))  // SWIFT_VERSION from the project's xcconfig
        XCTAssertTrue(app.contains(SwiftSetting(kind: .define("APPCOND"), configuration: nil)))
        XCTAssertTrue(app.contains(SwiftSetting(kind: .define("DEBUG"), configuration: "debug")))
        XCTAssertTrue(app.contains(SwiftSetting(kind: .define("DEBUG_EXTRA"), configuration: "debug")))
        XCTAssertTrue(app.contains(SwiftSetting(kind: .define("FROM_XCCONFIG"), configuration: nil)))  // $(inherited) in OTHER_SWIFT_FLAGS
        XCTAssertTrue(app.contains(SwiftSetting(kind: .define("FOO"), configuration: nil)))
        XCTAssertTrue(app.contains(SwiftSetting(kind: .upcoming("ExistentialAny"), configuration: nil)))
        XCTAssertTrue(app.contains(SwiftSetting(kind: .upcoming("MemberImportVisibility"), configuration: nil)))
        XCTAssertTrue(app.contains(SwiftSetting(kind: .upcoming("NonisolatedNonsendingByDefault"), configuration: nil)))  // approachable concurrency
        XCTAssertTrue(app.contains(SwiftSetting(kind: .upcoming("StrictConcurrency"), configuration: "debug")))  // project Debug only
        XCTAssertTrue(app.contains(SwiftSetting(kind: .defaultIsolationMainActor, configuration: nil)))
        let kit = try target("Kit").settings
        XCTAssertTrue(kit.contains(SwiftSetting(kind: .languageMode("v6"), configuration: nil)))
        XCTAssertTrue(kit.contains(SwiftSetting(kind: .upcoming("ExistentialAny"), configuration: nil)))
        XCTAssertFalse(kit.contains(SwiftSetting(kind: .upcoming("GlobalConcurrency"), configuration: nil)), "on by default in Swift 6")
    }

    func testGeneratedInfoPlist() throws {
        let info = try XCTUnwrap(try target("Groups_App").infoPlist)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.example.Groups-App")
        XCTAssertEqual(info["CFBundleName"] as? String, "Groups App")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Groups_App")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "2.1")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "7")
        XCTAssertEqual(info["LSUIElement"] as? Bool, true)
        XCTAssertEqual(info["NSHumanReadableCopyright"] as? String, "© Example")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(try target("Groups_App").bundleIdentifier, "com.example.Groups-App")
    }

    func testPackagesAndPins() throws {
        XCTAssertEqual(Set(plan.dependencies.map(\.identity)), ["remote", "localkit"])
        let remote = try XCTUnwrap(plan.dependencies.first { $0.identity == "remote" })
        XCTAssertEqual(remote.requirement, .range("1.2.0", "2.0.0"))
        XCTAssertEqual(remote.pinnedVersion, "1.4.2")  // from the workspace's Package.resolved
        XCTAssertEqual(remote.pinnedRevision, "0123456789abcdef0123456789abcdef01234567")
        let local = try XCTUnwrap(plan.dependencies.first { $0.identity == "localkit" })
        guard case .local(let path) = local.source else { return XCTFail("LocalKit should be local") }
        XCTAssertEqual(path.lastPathComponent, "LocalKit")
        let products = try target("Groups_App").productDependencies
        XCTAssertEqual(products, [ProductRef(product: "Remote", package: "remote"), ProductRef(product: "LocalKit", package: "localkit")])
    }

    func testWorkspace() throws {
        let ws = try Workspace(fixtures.appendingPathComponent("GroupsApp/GroupsApp.xcworkspace"))
        XCTAssertEqual(ws.projects.map(\.lastPathComponent), ["GroupsApp.xcodeproj"])
        XCTAssertEqual(ws.folders.map(\.lastPathComponent), ["LocalKit"])
        XCTAssertNotNil(ws.resolvedFile)
    }

    func testIOSSDKRootInPBXProject() throws {
        let text = try String(contentsOf: project.file.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        let mobile = text.replacingOccurrences(of: "SDKROOT = macosx;", with: "SDKROOT = iphoneos;")
            .replacingOccurrences(of: "MACOSX_DEPLOYMENT_TARGET = 14.0;", with: "IPHONEOS_DEPLOYMENT_TARGET = 17.0;")
        let xp = try PBXProjectReader.read(OpenStepPlist.parse(mobile), xcodeproj: project.file)
        let importer = XcodeImporter(xp)
        let plan = try importer.plan()
        XCTAssertEqual(plan.xcodePlatform, .iOS)
        XCTAssertEqual(plan.targets.map(\.name), ["Groups_App", "Kit", "GroupsAppTests"])
        let info = try XCTUnwrap(plan.targets.first?.infoPlist)
        XCTAssertEqual(info["MinimumOSVersion"] as? String, "17.0")
        XCTAssertNil(info["LSMinimumSystemVersion"])
        XCTAssertThrowsError(try importer.plan(options: .init(platform: .macOS)))
    }
}

final class SynchronizedFolderTests: XCTestCase {
    func testMembershipExceptions() throws {
        let xp = try PBXProjectReader.read(fixtures.appendingPathComponent("SyncApp/SyncApp.xcodeproj"))
        let root = fixtures.appendingPathComponent("SyncApp").standardizedFileURL
        let app = try XCTUnwrap(xp.target(named: "SyncApp"))
        // Its folder minus its exceptions, plus the file the Widget folder's exception gives it.
        XCTAssertEqual(Set(app.sources.map { relativePath($0, from: root) }), ["SyncApp/App.swift", "SyncApp/Model/Item.swift", "Widget/SharedWithApp.swift"])
        // Resources: catalogs and bundle-like folders whole, lproj kept, build-only files and the copy phase's file out.
        XCTAssertEqual(Set(app.resources.map(\.bundlePath)), ["en.lproj/Localizable.strings", "Assets.xcassets", "data.json", "Base.lproj/Window.xib"])
        XCTAssertEqual(xp.packageDirectories.map(\.lastPathComponent), ["LocalPkg"])
        let widget = try XCTUnwrap(xp.target(named: "Widget"))
        // The owner keeps the file it shares; the app folder's exception adds one.
        XCTAssertEqual(Set(widget.sources.map(\.lastPathComponent)), ["Widget.swift", "SharedWithApp.swift", "ExtensionOnly.swift"])
    }

    func testPlanWithAnchoredXCConfigAndInfoPlistFile() throws {
        let plan = try planXcodeProject(.xcode(project: fixtures.appendingPathComponent("SyncApp/SyncApp.xcodeproj"), workspace: nil))
        XCTAssertEqual(plan.targets.map(\.name), ["SyncApp", "SyncAppTests"])
        let app = try XCTUnwrap(plan.targets.first)
        XCTAssertTrue(app.settings.contains(SwiftSetting(kind: .languageMode("v6"), configuration: nil)))  // from Config.xcconfig in the folder
        let info = try XCTUnwrap(app.infoPlist)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "SyncApp")
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.example.SyncApp")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "3.0")
        XCTAssertEqual(info["MyKey"] as? String, "from-xcconfig")
        XCTAssertEqual(info["LSUIElement"] as? Bool, false, "the file's value wins over INFOPLIST_KEY_*")
        XCTAssertEqual(info["NSPrincipalClass"] as? String, "NSApplication")
        XCTAssertFalse(app.resources.contains { $0.staged == "Info.plist" })
    }
}

final class OtherFormatTests: XCTestCase {
    func testJSONProjectFormat() throws {
        let xp = try XcprojJSONReader.read(fixtures.appendingPathComponent("JSONApp/JSONApp.xcodeproj"))
        XCTAssertEqual(xp.targets.map(\.name), ["JSONApp", "Core"])
        let app = try XCTUnwrap(xp.target(named: "JSONApp"))
        XCTAssertEqual(app.sources.map(\.lastPathComponent), ["JSONApp.swift"])  // Skipped.swift is excluded
        XCTAssertEqual(app.dependencies, ["Core"])  // linked through the Products group
        XCTAssertEqual(app.embeds, ["Core"])
        XCTAssertEqual(xp.packages.first?.location, .remote(url: "https://github.com/example/Helpers.git", requirement: .range("2.3.0", "2.4.0")))

        let plan = try XcodeImporter(xp).plan()
        XCTAssertEqual(plan.targets.map(\.name), ["JSONApp", "Core"])
        let p = try XCTUnwrap(plan.targets.first)
        XCTAssertEqual(p.localDependencies, ["Core"])
        XCTAssertEqual(p.productDependencies, [ProductRef(product: "Helpers", package: "helpers")])
        XCTAssertEqual(p.infoPlist?["CFBundleIdentifier"] as? String, "codes.example.JSONApp")  // target xcconfig including the project's
        XCTAssertEqual(p.infoPlist?["CFBundleShortVersionString"] as? String, "4.5")
        XCTAssertTrue(p.settings.contains(SwiftSetting(kind: .define("JSON_DEBUG"), configuration: "debug")))
    }

    func testXcodeGenSpec() throws {
        let located = try ProjectLocator.locate(fixtures.appendingPathComponent("GenApp"))
        XCTAssertEqual(located, .xcodeGen(fixtures.appendingPathComponent("GenApp/project.yml")))
        let plan = try planXcodeProject(located)
        XCTAssertEqual(plan.origin, .xcodeGen)
        let app = try XCTUnwrap(plan.targets.first)
        XCTAssertEqual(app.name, "GenApp")
        XCTAssertEqual(app.sources.map { ($0.staged as NSString).lastPathComponent }, ["GenApp.swift"])  // Generated/** excluded
        XCTAssertEqual(app.resources.map(\.staged), ["greeting.txt"])
        XCTAssertTrue(app.settings.contains(SwiftSetting(kind: .languageMode("v6"), configuration: nil)))
        XCTAssertTrue(app.settings.contains(SwiftSetting(kind: .define("GEN_DEBUG"), configuration: "debug")))
        XCTAssertEqual(app.infoPlist?["CFBundleIdentifier"] as? String, "com.example.genapp")
        XCTAssertEqual(app.infoPlist?["CFBundleDisplayName"] as? String, "Gen App")
        XCTAssertEqual(app.infoPlist?["LSUIElement"] as? Bool, true)
        XCTAssertEqual(Set(plan.dependencies.map(\.identity)), ["yams", "localkit"])
        XCTAssertEqual(Set(app.productDependencies), [ProductRef(product: "Yams", package: "yams"), ProductRef(product: "LocalKit", package: "localkit")])
    }

    func testMixedXcodeGenPlatformsAndSimulatorSettings() throws {
        let spec = fixtures.appendingPathComponent("GenApp/project.yml")
        let yaml = """
        name: MultiApp
        options:
          deploymentTarget:
            iOS: "17.0"
        targets:
          Desktop:
            type: application
            platform: macOS
            sources: [Sources/App/GenApp.swift]
          Mobile:
            type: application
            platform: iOS
            sources: [Sources/App/GenApp.swift]
            info:
              path: Generated/Info.plist
              properties:
                CFBundleDisplayName: Mobile App
            settings:
              base:
                PRODUCT_MODULE_NAME[sdk=iphonesimulator*]: MobilePreview
                OTHER_SWIFT_FLAGS[sdk=iphonesimulator*]: "-D SIMULATOR_SETTINGS"
                OTHER_SWIFT_FLAGS[sdk=iphoneos*]: "-D DEVICE_SETTINGS"
            dependencies:
              - target: Shared
              - target: TVKit
              - target: Widget
                embed: true
          Shared:
            type: framework
            sources: [Sources/App/GenApp.swift]
          TVKit:
            type: framework
            platform: tvOS
            sources: [Sources/App/GenApp.swift]
          Widget:
            type: app-extension
            platform: iOS
          MobileUITests:
            type: bundle.ui-testing
            platform: iOS
            dependencies:
              - target: Mobile
        """
        let data = try XCTUnwrap(YAML.parse(yaml) as? [String: Any])
        let xp = XcodeGenReader.read(data, spec: spec)
        let importer = XcodeImporter(xp)
        XCTAssertEqual(xp.target(named: "Mobile")?.embeds, ["Widget"])
        let desktop = try importer.plan()
        XCTAssertEqual(desktop.xcodePlatform, .macOS)
        XCTAssertEqual(desktop.targets.map(\.name), ["Desktop"])

        let mobile = try importer.plan(options: .init(platform: .iOS))
        XCTAssertEqual(mobile.xcodePlatform, .iOS)
        XCTAssertEqual(mobile.targets.map(\.name), ["MobilePreview", "Shared"])
        let app = try XCTUnwrap(mobile.targets.first)
        XCTAssertEqual(app.localDependencies, ["Shared"])
        XCTAssertEqual(app.infoPlist?["MinimumOSVersion"] as? String, "17.0")
        XCTAssertEqual(app.infoPlist?["CFBundleDisplayName"] as? String, "Mobile App")
        XCTAssertTrue(app.notes.contains { $0.contains("properties from XcodeGen spec") })
        XCTAssertTrue(app.settings.contains(SwiftSetting(kind: .define("SIMULATOR_SETTINGS"), configuration: nil)))
        XCTAssertFalse(app.settings.contains(SwiftSetting(kind: .define("DEVICE_SETTINGS"), configuration: nil)))
        XCTAssertTrue(mobile.notes.contains { $0.contains("TVKit") && $0.contains("does not support iOS") })
        XCTAssertTrue(mobile.notes.contains { $0.contains("Widget") && $0.contains("app-extension") })
        XCTAssertTrue(mobile.notes.contains { $0.contains("MobileUITests") && $0.contains("UI tests") })
        XCTAssertEqual(try importer.plan(options: .init(target: "MobilePreview")).xcodePlatform, .iOS)
        XCTAssertThrowsError(try importer.plan(options: .init(target: "Desktop", platform: .iOS)))
    }

    func testLocator() throws {
        let groups = fixtures.appendingPathComponent("GroupsApp")
        // The workspace wins over the bare project; it names the project.
        XCTAssertEqual(try ProjectLocator.locate(groups), .xcode(project: groups.appendingPathComponent("GroupsApp.xcodeproj").standardizedFileURL,
                                                                workspace: groups.appendingPathComponent("GroupsApp.xcworkspace")))
        XCTAssertEqual(try ProjectLocator.locate(groups, project: "GroupsApp.xcodeproj"),
                       .xcode(project: groups.appendingPathComponent("GroupsApp.xcodeproj"), workspace: nil))
        XCTAssertEqual(try ProjectLocator.locate(groups.appendingPathComponent("Packages/LocalKit")), .swiftPM(groups.appendingPathComponent("Packages/LocalKit")))
        XCTAssertThrowsError(try ProjectLocator.locate(fixtures.appendingPathComponent("TuistApp"))) { e in
            XCTAssertTrue("\(e)".contains("tuist generate"))
        }
    }

    func testRequestedTarget() throws {
        let xp = try PBXProjectReader.read(fixtures.appendingPathComponent("GroupsApp/GroupsApp.xcodeproj"))
        XCTAssertEqual(try XcodeImporter(xp).mainApp("Kit").name, "Kit")
        XCTAssertThrowsError(try XcodeImporter(xp).mainApp("Nope"))
        XCTAssertEqual(try XcodeImporter(xp).plan(options: .init(target: "Kit")).targets.map(\.name), ["Kit"])
    }

    func testDeclaredProducts() {
        XCTAssertEqual(declaredProducts(inPackageAt: fixtures.appendingPathComponent("GroupsApp/Packages/LocalKit")), ["LocalKit"])
    }
}
