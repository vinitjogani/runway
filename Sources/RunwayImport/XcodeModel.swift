// What an Xcode project says about its targets, independent of the format
// it was read from (project.pbxproj, the JSON project.xcproj, an XcodeGen
// spec): files resolved to disk, build settings as assignment stacks.

import Foundation

public struct XcodeProject {
    public enum Format: String { case pbxproj = "project.pbxproj", xcproj = "project.xcproj (JSON)", xcodegen = "XcodeGen project.yml" }
    public var name: String
    public var format: Format
    /// The `.xcodeproj` (or project.yml).
    public var file: URL
    /// SRCROOT / PROJECT_DIR: the directory group paths are relative to.
    public var sourceRoot: URL
    public var configurations: [String] = []
    public var defaultConfiguration: String?
    public var developmentRegion: String?
    /// Project-level settings per configuration: its xcconfig's assignments,
    /// then the project's own.
    public var settings: [String: [SettingAssignment]] = [:]
    public var targets: [XcodeTarget] = []
    public var packages: [XcodePackage] = []
    /// Directories holding a Package.swift the project refers to (local
    /// packages added as folder references or inside synchronized folders).
    public var packageDirectories: [URL] = []
    /// Package.resolved next to the project (project.xcworkspace/xcshareddata/swiftpm).
    public var resolvedFile: URL?
    public var notes: [String] = []

    public init(name: String, format: Format, file: URL, sourceRoot: URL) {
        self.name = name; self.format = format; self.file = file; self.sourceRoot = sourceRoot
    }

    public func target(named n: String) -> XcodeTarget? { targets.first { $0.name == n } }
}

/// A file Xcode copies into the bundle's Resources: where it comes from and
/// where it lands (`Foo.png`, `en.lproj/Main.strings`, `Themes` for a folder
/// reference).
public struct XcodeResource: Equatable {
    public var url: URL
    public var bundlePath: String
    public init(url: URL, bundlePath: String) { self.url = url; self.bundlePath = bundlePath }
}

public struct XcodeProductDependency: Equatable {
    public var product: String
    /// Index into `XcodeProject.packages`, when the project says which.
    public var package: Int?
    public init(product: String, package: Int?) { self.product = product; self.package = package }
}

public struct XcodePackage: Equatable {
    public enum Location: Equatable {
        case remote(url: String, requirement: PlanDependency.Requirement)
        case local(URL)
    }
    public var location: Location
    public init(_ location: Location) { self.location = location }

    public var identity: String {
        switch location {
        case .remote(let url, _): return packageIdentity(url)
        case .local(let u): return u.standardizedFileURL.lastPathComponent.lowercased()
        }
    }
}

public struct XcodeTarget {
    public var name: String
    /// The product type without its `com.apple.product-type.` prefix:
    /// `application`, `framework`, `library.static`, `bundle.unit-test`,
    /// `app-extension`, `tool`… (`aggregate`/`legacy` for those targets).
    public var productType: String
    public var settings: [String: [SettingAssignment]] = [:]
    public var sources: [URL] = []
    /// Other files in the Sources phase (C, Objective-C, Metal, Core Data
    /// models…).
    public var otherSources: [URL] = []
    public var resources: [XcodeResource] = []
    public var dependencies: [String] = []
    public var packageProducts: [XcodeProductDependency] = []
    /// Targets whose products this one copies into itself (Embed phases).
    public var embeds: [String] = []
    /// Info.plist entries the spec gives directly (XcodeGen `info.properties`).
    public var infoProperties: [String: Any]?
    public var notes: [String] = []
    public init(name: String, productType: String) { self.name = name; self.productType = productType }

    public enum Role: String { case app, library, test, uiTest, tool, appExtension, other }
    public var role: Role {
        switch productType {
        case "application": return .app
        case "framework", "library.static", "library.dynamic", "framework.static": return .library
        case "bundle.unit-test": return .test
        case "bundle.ui-testing": return .uiTest
        case "tool": return .tool
        case _ where productType.contains("extension") || productType.contains("xpc-service") || productType.contains("widget")
            || productType.contains("app-clip") || productType.contains("watchapp"):
            return .appExtension
        default: return .other
        }
    }
}

/// Folder kinds Xcode treats as one item (copied whole) rather than
/// descending into them.
public let opaqueFolderExtensions: Set<String> = [
    "xcassets", "bundle", "framework", "xcframework", "app", "appex", "xpc", "rtfd", "scnassets", "xcdatamodeld",
    "xcmappingmodel", "docc", "playground", "plugin", "kext", "mlpackage", "xctemplate", "storyboardc", "nib", "icon",
    "spriteatlas", "xcstickers", "car", "mdimporter", "qlgenerator", "prefPane", "saver", "wdgt",
]

/// Extensions of files a target compiles rather than copies.
public let compiledExtensions: Set<String> = ["swift", "c", "m", "mm", "cc", "cpp", "cxx", "s", "metal", "xcdatamodeld", "xcmappingmodel",
                                               "intentdefinition", "mlmodel", "mlpackage", "rcproject", "iig", "defs", "l", "y"]

/// Files that never become resources (headers, build configuration, signing).
public func isBuildOnlyFile(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    if ["h", "hh", "hpp", "pch", "modulemap", "xcconfig", "entitlements", "xctestplan", "storekit", "docc", "md", "markdown", "swiftlint"].contains(ext) { return true }
    if name == "Info.plist" || name.hasSuffix("-Info.plist") || name.hasSuffix("_Info.plist") { return true }
    if name == "LICENSE" || name == ".DS_Store" || name == "Package.swift" || name == "Package.resolved" { return true }
    return false
}

/// Where a resource at `relative` (inside a group or synchronized folder)
/// lands in the bundle: flattened to its name, keeping `<lang>.lproj/`.
public func bundlePath(forResource relative: String) -> String {
    let parts = relative.split(separator: "/").map(String.init)
    if let i = parts.lastIndex(where: { $0.hasSuffix(".lproj") }) {
        return parts[i...].joined(separator: "/")
    }
    return parts.last ?? relative
}
