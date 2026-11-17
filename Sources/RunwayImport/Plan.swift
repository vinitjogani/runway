// The staging plan: what an app package is made of, in the shape the
// stager turns into a staged SwiftPM package. Read from a SwiftPM manifest
// (the `runway` tool's SwiftPM.swift) or imported from an Xcode project
// (XcodeImport.swift).

import Foundation

public enum TargetKind: String, Sendable { case executable, library, test, system, plugin, binary, macro }

/// A file the staged target compiles or ships, with where it came from.
public struct PlanFile: Equatable {
    public var origin: URL
    /// Path relative to the staged target directory.
    public var staged: String
    public init(origin: URL, staged: String) { self.origin = origin; self.staged = staged }
}

public struct PlanResource: Equatable {
    public enum Rule: String, Sendable { case process, copy }
    public var rule: Rule
    public var origin: URL
    /// Path relative to the staged target directory or, for main-bundle
    /// resources, to the bundle's Resources directory.
    public var staged: String
    public init(rule: Rule, origin: URL, staged: String) { self.rule = rule; self.origin = origin; self.staged = staged }
}

public struct ProductRef: Hashable {
    public var product: String
    /// The dependency's package identity (or name, for byName).
    public var package: String?
    public init(product: String, package: String?) { self.product = product; self.package = package }
}

/// A conditioned compiler setting: `.define("DEBUG", .when(configuration: .debug))`.
public struct SwiftSetting: Hashable {
    public enum Kind: Hashable {
        case define(String)
        case upcoming(String)
        case experimental(String)
        case languageMode(String)
        case defaultIsolationMainActor
        case unsafeFlags([String])
    }
    public var kind: Kind
    public var configuration: String?  // "debug" | "release" | nil (both)
    public init(kind: Kind, configuration: String?) { self.kind = kind; self.configuration = configuration }

    public func render() -> String {
        let cond = configuration.map { ", .when(configuration: .\($0))" } ?? ""
        switch kind {
        case .define(let d): return ".define(\(lit(d))\(cond))"
        case .upcoming(let f): return ".enableUpcomingFeature(\(lit(f))\(cond))"
        case .experimental(let f): return ".enableExperimentalFeature(\(lit(f))\(cond))"
        case .languageMode(let m): return ".swiftLanguageMode(.\(m)\(cond))"
        case .defaultIsolationMainActor: return ".defaultIsolation(MainActor.self\(cond))"
        case .unsafeFlags(let f): return ".unsafeFlags([\(f.map(lit).joined(separator: ", "))]\(cond))"
        }
    }
}

public struct PlanTarget {
    public var name: String
    public var kind: TargetKind
    /// Swift sources (staged as transformed copies).
    public var sources: [PlanFile] = []
    /// Non-Swift files a C-family/system target needs, copied verbatim.
    public var verbatim: [PlanFile] = []
    public var resources: [PlanResource] = []
    /// `.xcassets` folders, converted into RunwayAssets at staging.
    public var assetCatalogs: [URL] = []
    /// `.xcstrings` catalogs, converted into `<lang>.lproj/<table>.strings`.
    public var stringCatalogs: [URL] = []
    /// Xcode targets: resources, asset and string catalogs go into the app's
    /// main bundle (next to the executable, laid out as in
    /// `Contents/Resources`), not into a SwiftPM resource bundle.
    public var mainBundleResources = false
    public var localDependencies: [String] = []
    public var productDependencies: [ProductRef] = []
    public var settings: [SwiftSetting] = []
    /// Raw extra arguments for C targets (publicHeadersPath:, cSettings:…).
    public var extraArguments: [String] = []
    /// The main bundle's Info.plist (apps), resolved.
    public var infoPlist: [String: Any]?
    public var bundleIdentifier: String?
    /// Other names Interface Builder documents may give this module
    /// (an Xcode target's own name, c99-ified, when its module is named otherwise).
    public var moduleAliases: [String] = []
    /// The executable product's name, for apps.
    public var productName: String?
    /// Objective-C/C headers whose declarations the target's Swift (or the
    /// targets importing it) uses while their implementation can't be built
    /// here: Swift stand-ins are generated for them at staging (ObjCStandIns.swift).
    public var standInHeaders: [URL] = []
    /// `public` when the headers are the module's API, `internal` for a bridging header.
    public var standInAccess = "internal"
    public var notes: [String] = []
    public init(name: String, kind: TargetKind) { self.name = name; self.kind = kind }
}

/// A package the app depends on.
public struct PlanDependency {
    public enum Source {
        case remote(url: String)
        case local(path: URL)
    }
    public enum Requirement: CustomStringConvertible, Equatable {
        case exact(String), range(String, String), branch(String), revision(String), any
        public var description: String {
            switch self {
            case .exact(let v): return "exactly \(v)"
            case .range(let a, let b): return "\(a)..<\(b)"
            case .branch(let b): return "branch \(b)"
            case .revision(let r): return "revision \(r)"
            case .any: return "any version"
            }
        }
    }
    public var identity: String
    public var source: Source
    public var requirement: Requirement
    /// From Package.resolved, when present.
    public var pinnedRevision: String?
    public var pinnedVersion: String?
    /// Names other manifests refer to this package by (`package:` arguments).
    public var aliases: Set<String> = []
    public init(identity: String, source: Source, requirement: Requirement) {
        self.identity = identity; self.source = source; self.requirement = requirement
    }
}

public struct Pin: Equatable {
    public var revision: String?
    public var version: String?
    public var branch: String?
    public var location: String
    public init(revision: String?, version: String?, branch: String? = nil, location: String) {
        self.revision = revision; self.version = version; self.branch = branch; self.location = location
    }
}

public struct Plan {
    public enum Origin: String { case swiftPM = "SwiftPM package", xcode = "Xcode project", xcodeGen = "XcodeGen spec" }
    public var name: String
    /// The package's (or Xcode project's source root) directory.
    public var root: URL
    public var targets: [PlanTarget]
    public var products: [(name: String, type: String, targets: [String])]
    public var dependencies: [PlanDependency]
    /// The package-level default language mode ("v5", "v6").
    public var languageModes: [String]
    public var defaultLocalization: String?
    public var notes: [String] = []
    /// Package.resolved pins, by identity.
    public var pins: [String: Pin] = [:]
    public var origin: Origin = .swiftPM
    public init(name: String, root: URL, targets: [PlanTarget], products: [(name: String, type: String, targets: [String])],
                dependencies: [PlanDependency], languageModes: [String], defaultLocalization: String?, notes: [String] = []) {
        self.name = name; self.root = root; self.targets = targets; self.products = products; self.dependencies = dependencies
        self.languageModes = languageModes; self.defaultLocalization = defaultLocalization; self.notes = notes
    }
}
