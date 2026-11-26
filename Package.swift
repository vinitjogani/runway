// swift-tools-version:6.0
// Runway: SwiftUI (and the slice of AppKit SwiftUI code reaches for) on
// Linux and Windows, over each platform's native toolkit.
//
//   SwiftUI                 The SwiftUI API: views, state, Observation,
//                           environment, modifiers, layout (SwiftUI's own
//                           rules), App/Scene. Backend-independent.
//   AppKit                  NSApplication, NSWindow, NSHostingController,
//                           NSColor, NSPasteboard, NSWorkspace, NSSound…
//                           mapped to the platform, not a full AppKit.
//   RunwayCore              The backend contract, paint/font/geometry
//                           model, platform services, a headless backend.
//   RunwayGTK (+CRunwayGtk) Linux: GTK 4 widgets, Cairo, GdkPixbuf.
//   RunwayDrawn             Mac-style controls Runway draws itself, over a flat
//                           C layer: Win32/Direct2D on Windows, GTK/Cairo on
//                           Linux (opt-in there: RUNWAY_BACKEND=drawn).
//   RunwayPlatform          Picks the backend for the platform.
//   Framework shims         CoreGraphics, ImageIO, UniformTypeIdentifiers,
//                           NaturalLanguage, ServiceManagement, Security,
//                           CryptoKit, RunwayFoundation (Foundation gaps).
//   runway                  The build tool: stages an unchanged SwiftPM app
//                           against these modules and builds/runs/tests it.
import PackageDescription

let linux = TargetDependencyCondition.when(platforms: [.linux])
let windows = TargetDependencyCondition.when(platforms: [.windows])
let windowsOrLinux = TargetDependencyCondition.when(platforms: [.windows, .linux])
let windowsOnly = BuildSettingCondition.when(platforms: [.windows])

let package = Package(
    name: "Runway",
    products: [
        .library(name: "SwiftUI", targets: ["SwiftUI"]),
        .library(name: "AppKit", targets: ["AppKit"]),
        .library(name: "UIKit", targets: ["UIKit"]),
        .library(name: "RunwayCore", targets: ["RunwayCore"]),
        .library(name: "RunwayFoundation", targets: ["RunwayFoundation"]),
        .library(name: "CoreGraphics", targets: ["CoreGraphics"]),
        .library(name: "ImageIO", targets: ["ImageIO"]),
        .library(name: "UniformTypeIdentifiers", targets: ["UniformTypeIdentifiers"]),
        .library(name: "NaturalLanguage", targets: ["NaturalLanguage"]),
        .library(name: "ServiceManagement", targets: ["ServiceManagement"]),
        .library(name: "Security", targets: ["Security"]),
        .library(name: "CryptoKit", targets: ["CryptoKit"]),
        .library(name: "Cocoa", targets: ["Cocoa"]),
        .library(name: "Darwin", targets: ["Darwin"]),
        .executable(name: "runway", targets: ["runway"]),
    ],
    targets: [
        // Native toolkits.
        .systemLibrary(name: "CGtk", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
        .target(name: "CRunwayGtk", dependencies: [.target(name: "CGtk", condition: linux)],
                linkerSettings: ["fontconfig", "pangoft2-1.0"].map { .linkedLibrary($0, .when(platforms: [.linux])) }),

        // Core and backends.
        // Inter and JetBrains Mono (OFL), compiled into every app.
        .target(name: "CRunwayFonts", exclude: ["fonts"]),
        .target(name: "RunwayCore", dependencies: ["CoreGraphics", "CRunwayFonts"]),
        .target(name: "RunwayGTK", dependencies: [
            "RunwayCore",
            .target(name: "CGtk", condition: linux),
            .target(name: "CRunwayGtk", condition: linux),
        ]),
        // Windows: the Swift backend over a small C++ layer (Direct2D,
        // DirectWrite, WIC, Win32) that exposes a flat C API.
        // The drawn backend's native layer: the same flat C API (runway_drawn.h)
        // over Win32/Direct2D (Native/win32) and over GTK/Cairo/Pango (Native/gtk).
        .target(name: "CRunwayDrawn", dependencies: [.target(name: "CGtk", condition: linux), .target(name: "CRunwayGtk", condition: linux)], path: "Sources/RunwayDrawn/Native", linkerSettings: [
            "user32", "gdi32", "d2d1", "dwrite", "dwmapi", "uxtheme", "comdlg32", "shell32", "ole32", "winmm", "advapi32",
        ].map { .linkedLibrary($0, windowsOnly) }),
        .target(name: "RunwayDrawn", dependencies: [
            "RunwayCore", "CoreGraphics",
            .target(name: "CRunwayDrawn", condition: windowsOrLinux),
        ], exclude: ["Native", "README.md"]),
        .target(name: "RunwayPlatform", dependencies: [
            "RunwayCore",
            .target(name: "RunwayGTK", condition: linux),
            .target(name: "CGtk", condition: linux),
            .target(name: "RunwayDrawn", condition: windowsOrLinux),
        ]),

        // The UI layer.
        .target(name: "AppKit", dependencies: ["RunwayCore", "RunwayPlatform", "CoreGraphics", "QuartzCore", "UniformTypeIdentifiers", "RunwayFoundation", "CoreText"]),
        .target(name: "UIKit", dependencies: ["AppKit", "CoreGraphics", "CoreText", "RunwayCore"]),
        .target(name: "SwiftUI", dependencies: ["RunwayCore", "RunwayPlatform", "AppKit", "UIKit", "CoreGraphics"]),

        // Apple framework shims, each mapped to the platform's native API.
        .systemLibrary(name: "CRunwayZlib", providers: [.apt(["zlib1g-dev"])]),
        .target(name: "CRunwayFoundation"),
        .target(name: "RunwayFoundation", dependencies: [.target(name: "CRunwayZlib", condition: linux), "CRunwayFoundation", "Combine"],
                linkerSettings: [.linkedLibrary("ws2_32", windowsOnly)]),
        .target(name: "CoreGraphics", dependencies: ["RunwayFoundation", "RunwayCF", "RunwayX11"]),
        .systemLibrary(name: "CGdkPixbuf", pkgConfig: "gdk-pixbuf-2.0", providers: [.apt(["libgdk-pixbuf-2.0-dev"])]),
        .target(name: "ImageIO", dependencies: [
            "CoreGraphics", "RunwayFoundation", "UniformTypeIdentifiers",
            .target(name: "CGdkPixbuf", condition: linux),
        ]),
        .target(name: "UniformTypeIdentifiers"),
        .target(name: "NaturalLanguage"),
        .target(name: "ServiceManagement", dependencies: ["RunwayFoundation"]),
        .target(name: "Security", dependencies: ["RunwayFoundation"]),
        .target(name: "CryptoKit"),
        // Umbrella and platform modules with Apple's names.
        .target(name: "Cocoa", dependencies: ["AppKit"]),
        .target(name: "Darwin"),

        // The build tool.
        .executableTarget(name: "runway"),

        // A pure SwiftUI app: the layer's own gallery and smoke test.
        .executableTarget(name: "RunwayGallery", dependencies: ["SwiftUI"], path: "Examples/RunwayGallery"),
        // 2,000 rows and a typing loop: the graph's stress test (Tools/measure.sh).
        .executableTarget(name: "RunwayStress", dependencies: ["SwiftUI", "RunwayCore"], path: "Examples/RunwayStress"),

        .testTarget(name: "RunwayTests", dependencies: [
            "SwiftUI", "RunwayCore", "UniformTypeIdentifiers", "NaturalLanguage", "CryptoKit",
            "RunwayFoundation", "ImageIO", "ServiceManagement", "Security", "Cocoa", "Darwin",
        ], path: "Tests/RunwayTests"),
    ],
    swiftLanguageModes: [.v5]
)

// MARK: - Media, graphics and ML frameworks
//
// Each Apple framework below is its own target and library product, named
// exactly like Apple's module, so `import AVFoundation` etc. resolve to them.
//
//   CoreVideo, CoreMedia     pixel buffers, times, sample buffers (Swift).
//   AVFoundation, AVKit      assets, playback, reading/writing, compositions,
//                            capture devices: GStreamer on Linux (CRunwayGst
//                            over CGStreamer), honest errors elsewhere.
//   ScreenCaptureKit         shareable content and the SCStream surface.
//   CoreImage                CIImage/CIFilter/CIContext on a CPU renderer
//                            (+ CoreImageBuiltins: the clang name behind
//                            `import CoreImage.CIFilterBuiltins`).
//   QuartzCore, Metal,       a CALayer tree; Metal answers "no device";
//   MetalKit, CoreText       CoreText over Pango/HarfBuzz/fontconfig.
//   VideoToolbox, Speech,    surfaces that report unavailability through
//   Vision, FoundationModels their own status and error paths.
let mediaModules = [
    "CoreVideo", "CoreMedia", "AVFoundation", "AVKit", "ScreenCaptureKit", "CoreImage", "QuartzCore", "Metal", "MetalKit",
    "CoreText", "VideoToolbox", "Speech", "Vision", "FoundationModels", "WebKit",
]
package.products += mediaModules.map { Product.library(name: $0, targets: [$0]) }
package.targets += [
    .systemLibrary(name: "CGStreamer", pkgConfig: "gstreamer-pbutils-1.0",
                   providers: [.apt(["libgstreamer1.0-dev", "libgstreamer-plugins-base1.0-dev"])]),
    .systemLibrary(name: "CPangoCairo", pkgConfig: "pangocairo", providers: [.apt(["libpango1.0-dev"])]),
    .target(name: "CRunwayGst", dependencies: [.target(name: "CGStreamer", condition: linux)],
            linkerSettings: [.linkedLibrary("gstapp-1.0", .when(platforms: [.linux]))]),
    .target(name: "CoreImageBuiltins"),

    .target(name: "CoreVideo", dependencies: ["CoreGraphics", "RunwayFoundation"]),
    .target(name: "CoreMedia", dependencies: ["CoreVideo", "RunwayFoundation"]),
    .target(name: "QuartzCore", dependencies: ["CoreGraphics", "CoreVideo", "Metal", "RunwayFoundation"]),
    .target(name: "Metal", dependencies: ["CoreGraphics", "RunwayFoundation"]),
    .target(name: "MetalKit", dependencies: ["Metal", "QuartzCore", "AppKit"]),
    .target(name: "CoreImage", dependencies: [
        "CoreGraphics", "CoreVideo", "ImageIO", "Metal", "RunwayFoundation", "CoreImageBuiltins",
    ]),
    .target(name: "CoreText", dependencies: [
        "CoreGraphics", "RunwayCore", "RunwayFoundation",
        .target(name: "CPangoCairo", condition: linux),
    ]),
    .target(name: "AVFoundation", dependencies: [
        "CoreMedia", "CoreVideo", "CoreGraphics", "QuartzCore", "ImageIO", "UniformTypeIdentifiers", "RunwayFoundation", "CRunwayGst",
        .target(name: "CGStreamer", condition: linux),
    ]),
    .target(name: "AVKit", dependencies: ["AVFoundation", "AppKit"]),
    .target(name: "ScreenCaptureKit", dependencies: [
        "CoreMedia", "CoreVideo", "CoreGraphics", "RunwayFoundation", "CRunwayGst", "AVFoundation",
        .target(name: "CGtk", condition: linux),
    ]),
    .target(name: "VideoToolbox", dependencies: ["CoreMedia", "CoreVideo", "RunwayFoundation"]),
    .target(name: "Speech", dependencies: ["AVFoundation", "CoreMedia", "RunwayFoundation"]),
    .target(name: "Vision", dependencies: ["CoreImage", "CoreVideo", "RunwayFoundation"]),
    .target(name: "FoundationModels", dependencies: ["RunwayFoundation"]),
    .systemLibrary(name: "CWebKitGTK", pkgConfig: "webkitgtk-6.0", providers: [.apt(["libwebkitgtk-6.0-dev"])]),
    .target(name: "CRunwayWebKit", dependencies: [.target(name: "CWebKitGTK", condition: linux)]),
    .target(name: "WebKit", dependencies: [
        "AppKit", "CRunwayWebKit",
        .target(name: "CGtk", condition: linux), .target(name: "CRunwayGtk", condition: linux),
    ]),

    .testTarget(name: "MediaTests", dependencies: [
        "CoreMedia", "CoreVideo", "AVFoundation", "CoreImage", "CoreText", "QuartzCore", "ScreenCaptureKit", "Metal",
        "Speech", "FoundationModels", "Vision", "VideoToolbox", "ImageIO",
    ], path: "Tests/MediaTests"),
]
// MARK: - RunwayObjC and RunwayTranspiler
// The Objective-C runtime slice (selectors, target/action, perform, KVC/KVO,
// selector-based observers and timers) and the source rewriter that maps
// `@objc`/`#selector`/`dynamic` code onto it as apps are staged. Only the
// transpiler (and its tests) depend on swift-syntax.
package.dependencies.append(.package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0"..<"700.0.0"))  // apps staged against Runway may pin a newer swift-syntax for their macros: one version serves both
package.products.append(contentsOf: [
    .library(name: "RunwayObjC", targets: ["RunwayObjC"]),
    .library(name: "RunwayTranspiler", targets: ["RunwayTranspiler"]),
    .executable(name: "runway-transpile", targets: ["runway-transpile"]),
])
package.targets.append(contentsOf: [
    .target(name: "RunwayObjC", dependencies: ["RunwayDistributedNotifications"]),
    .target(name: "RunwayTranspiler", dependencies: [
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
    ]),
    // Runs the transpiler over files or packages and checks the output.
    .executableTarget(name: "runway-transpile", dependencies: ["RunwayTranspiler"]),
    .testTarget(name: "RunwayTranspilerTests", dependencies: [
        "RunwayTranspiler", "RunwayObjC",
        .product(name: "SwiftParser", package: "swift-syntax"),
    ], path: "Tests/RunwayTranspilerTests", exclude: ["Runtime"]),
    // End to end: Mac-style fixtures, transpiled at build time, compiled
    // against AppKit + RunwayObjC and run.
    .plugin(name: "RunwayTranspileFixtures", capability: .buildTool(), dependencies: ["runway-transpile"]),
    .testTarget(name: "RunwayObjCRuntimeTests", dependencies: ["AppKit", "RunwayObjC"],
                path: "Tests/RunwayTranspilerTests/Runtime",
                plugins: ["RunwayTranspileFixtures"]),
])
if let tool = package.targets.first(where: { $0.name == "runway" }) {
    // The build tool runs every staged source through the transpiler.
    tool.dependencies.append("RunwayTranspiler")
}
if let appKit = package.targets.first(where: { $0.name == "AppKit" }) {
    // AppKit re-exports RunwayObjC (Selector, sendAction) once it drops its own Selector.
    appKit.dependencies.append("RunwayObjC")
}

// MARK: - AppKit view system: tests and demo
// AppKit's headless tests (Auto Layout, coordinates, responders, menus,
// drawing) and an AppKit-first demo (a window controller, custom drawing,
// Auto Layout, a main menu, mouse tracking).
package.targets.append(contentsOf: [
    .executableTarget(name: "AppKitDemo", dependencies: ["AppKit"], path: "Examples/AppKitDemo"),
    .testTarget(name: "AppKitTests", dependencies: ["AppKit", "RunwayCore", "CoreGraphics", "RunwayObjC"], path: "Tests/AppKitTests"),
])
// NSImage(data:) and file images decode through ImageIO.
package.targets.first { $0.name == "AppKit" }?.dependencies.append("ImageIO")

// MARK: - System-service frameworks
// Combine, os/OSLog, UserNotifications, CoreServices (FSEvents), Carbon hot
// keys, ApplicationServices (Accessibility, CGEvent), IOKit power, Network,
// StoreKit, CloudKit, LocalAuthentication, EventKit, Contacts, CoreLocation,
// WidgetKit, ActivityKit, BackgroundTasks, AppIntents: Apple's API surface,
// native where there is an equivalent, otherwise using the API's own availability,
// authorization and error paths. Each is a library with Apple's module name.
let systemFrameworks: [(name: String, dependencies: [Target.Dependency])] = [
    ("Combine", []),
    ("os", ["CRunwaySystem"]),
    ("OSLog", ["os"]),
    ("CoreServices", ["RunwayCF", "UniformTypeIdentifiers", "Security"]),
    ("UserNotifications", ["RunwayDBus"]),
    ("ApplicationServices", ["RunwayCF", "CoreGraphics", "RunwayX11"]),
    ("Carbon", ["CoreServices", "ApplicationServices", "RunwayX11"]),
    ("IOKit", ["RunwayCF", "RunwayDBus"]),
    ("SystemConfiguration", ["RunwayCF", "RunwayNet"]),
    ("Network", ["RunwayNet"]),
    ("LocalAuthentication", []),
    ("CoreLocation", []),
    ("StoreKit", []),
    ("EventKit", []),
    ("Contacts", []),
    ("WidgetKit", ["SwiftUI"]),
    ("CloudKit", []),
    ("ActivityKit", []),
    ("BackgroundTasks", []),
]
// Spelled out (tools read the product list from this file).
package.products += [
    .library(name: "Combine", targets: ["Combine"]),
    .library(name: "os", targets: ["os"]),
    .library(name: "OSLog", targets: ["OSLog"]),
    .library(name: "CoreServices", targets: ["CoreServices"]),
    .library(name: "UserNotifications", targets: ["UserNotifications"]),
    .library(name: "ApplicationServices", targets: ["ApplicationServices"]),
    .library(name: "Carbon", targets: ["Carbon"]),
    .library(name: "IOKit", targets: ["IOKit"]),
    .library(name: "SystemConfiguration", targets: ["SystemConfiguration"]),
    .library(name: "Network", targets: ["Network"]),
    .library(name: "LocalAuthentication", targets: ["LocalAuthentication"]),
    .library(name: "CoreLocation", targets: ["CoreLocation"]),
    .library(name: "StoreKit", targets: ["StoreKit"]),
    .library(name: "EventKit", targets: ["EventKit"]),
    .library(name: "Contacts", targets: ["Contacts"]),
    .library(name: "WidgetKit", targets: ["WidgetKit"]),
    .library(name: "CloudKit", targets: ["CloudKit"]),
    .library(name: "ActivityKit", targets: ["ActivityKit"]),
    .library(name: "BackgroundTasks", targets: ["BackgroundTasks"]),
]
assert(package.products.count == Set(package.products.map(\.name)).count, "a framework is missing from the products list")
package.targets += systemFrameworks.map { .target(name: $0.name, dependencies: $0.dependencies) }
package.targets += [
    // Atomics and futex/WaitOnAddress waits (os_unfair_lock).
    .target(name: "CRunwaySystem"),
    // Core Foundation names shared by the frameworks that re-export it.
    .target(name: "RunwayCF", dependencies: ["RunwayFoundation"]),
    // D-Bus over GIO's GDBus (Linux): notifications, portals, login1, UPower.
    .systemLibrary(name: "CGio", pkgConfig: "gio-unix-2.0", providers: [.apt(["libglib2.0-dev"])]),
    .target(name: "RunwayDBus", dependencies: [.target(name: "CGio", condition: linux)]),
    // Xlib loaded at run time (hot keys, window list).
    .target(name: "RunwayX11"),
    // Interfaces, routes and change notifications (rtnetlink / NotifyAddrChange).
    .target(name: "RunwayNet"),
    // DistributedNotificationCenter (Foundation's; corelibs lacks it), over D-Bus.
    .target(name: "RunwayDistributedNotifications", dependencies: ["RunwayDBus"]),
]
package.targets += [
    .testTarget(name: "FrameworkTests", dependencies: systemFrameworks.map { .target(name: $0.name) } + ["RunwayDistributedNotifications"],
                path: "Tests/FrameworkTests"),
]

// MARK: - Integration between the layers
// SwiftUI's ObservableObject/@Published are Combine's (as on Apple platforms);
// `import AppKit`/`Cocoa` brings ApplicationServices (AXIsProcessTrusted,
// CGEvent), and Foundation brings DistributedNotificationCenter.
package.targets.first { $0.name == "SwiftUI" }?.dependencies.append("Combine")
package.targets.first { $0.name == "AppKit" }?.dependencies.append("ApplicationServices")
// `import Cocoa`/`import AppKit` bring these along on a Mac (through AppKit's and Core Graphics' own imports).
package.targets.first { $0.name == "AppKit" }?.dependencies += ["IOKit", "Security", "CoreServices", "CoreImage"]
package.targets.first { $0.name == "RunwayFoundation" }?.dependencies.append(.target(name: "RunwayDistributedNotifications", condition: linux))

// MARK: - AppKit's standard controls: demo and tests
// The controls themselves live in the AppKit target (Button.swift,
// TableView.swift…); these are their gallery app and headless tests.
package.targets.append(contentsOf: [
    .executableTarget(name: "AppKitControlsDemo", dependencies: ["AppKit"], path: "Examples/AppKitControls"),
    .testTarget(name: "AppKitControlsTests", dependencies: ["AppKit", "RunwayCore", "RunwayObjC"], path: "Tests/AppKitControlsTests"),
])

// MARK: - Pixel engines optimized in debug builds too
// These modules loop over every pixel of every frame (Core Graphics'
// rasterizer, Core Image's CPU renderer, CoreVideo's conversions, the frame
// engine behind AVPlayer, AVAssetWriter and AVVideoComposition): unoptimized
// they run 10–50× slower, too slow to preview or export video. Apps still
// build and debug their own code at -Onone.
let pixelModules: Set<String> = ["CoreGraphics", "CoreVideo", "CoreImage", "AVFoundation", "QuartzCore", "CoreMedia"]
for t in package.targets where pixelModules.contains(t.name) {
    t.swiftSettings = (t.swiftSettings ?? []) + [.unsafeFlags(["-O"], .when(configuration: .debug))]
}
package.targets.first { $0.name == "CoreImageBuiltins" }?.cSettings = [.unsafeFlags(["-O2"], .when(configuration: .debug))]

// MARK: - Frameworks the corpus apps import
// Small Apple frameworks measured against real apps (Tools/corpus): each a
// library with Apple's module name that re-exports Foundation. Real where
// the platform has the thing (Compression over zlib/liblzma, CommonCrypto
// over CryptoKit, SwiftData over SQLite, Charts drawn with SwiftUI shapes),
// otherwise the API surface answering as a Mac without the hardware or
// service would (no Bluetooth, no Wi-Fi interfaces, no scripting targets).
let corpusFrameworks: [(name: String, dependencies: [Target.Dependency])] = [
    ("CoreTransferable", ["UniformTypeIdentifiers"]),
    ("AppIntents", ["UniformTypeIdentifiers", "RunwayFoundation"]),
    ("Intents", ["RunwayFoundation"]),
    ("CommonCrypto", ["CryptoKit"]),
    ("Compression", [.target(name: "CRunwayZlib", condition: .when(platforms: [.linux]))]),
    ("CoreBluetooth", []),
    ("CoreWLAN", []),
    ("ScriptingBridge", ["RunwayFoundation"]),
    ("simd", []),
    ("SwiftData", ["SwiftUI"]),
    ("Charts", ["SwiftUI"]),
    ("CoreAudio", ["CoreMedia", "RunwayFoundation"]),
    ("AudioToolbox", ["CoreAudio", "RunwayFoundation"]),
    ("System", []),
]
// Spelled out (tools read the product list from this file).
package.products += [
    .library(name: "CoreTransferable", targets: ["CoreTransferable"]),
    .library(name: "AppIntents", targets: ["AppIntents"]),
    .library(name: "Intents", targets: ["Intents"]),
    .library(name: "CommonCrypto", targets: ["CommonCrypto"]),
    .library(name: "Compression", targets: ["Compression"]),
    .library(name: "CoreBluetooth", targets: ["CoreBluetooth"]),
    .library(name: "CoreWLAN", targets: ["CoreWLAN"]),
    .library(name: "ScriptingBridge", targets: ["ScriptingBridge"]),
    .library(name: "simd", targets: ["simd"]),
    .library(name: "SwiftData", targets: ["SwiftData"]),
    .library(name: "Charts", targets: ["Charts"]),
    .library(name: "CoreAudio", targets: ["CoreAudio"]),
    .library(name: "AudioToolbox", targets: ["AudioToolbox"]),
    .library(name: "System", targets: ["System"]),
]
package.targets += corpusFrameworks.map { .target(name: $0.name, dependencies: $0.dependencies) }
package.targets += [
    .testTarget(name: "CorpusFrameworkTests", dependencies: corpusFrameworks.map { .target(name: $0.name) } + ["SwiftUI", "RunwayFoundation", "Security", "ServiceManagement", "CoreGraphics"],
                path: "Tests/CorpusFrameworkTests"),
]
// SwiftUI re-exports CoreTransferable (Transferable, drop destinations, ShareLink).
package.targets.first { $0.name == "SwiftUI" }?.dependencies += ["CoreTransferable", "UniformTypeIdentifiers"]

// MARK: - The build tool's project importer
// RunwayImport reads what an app is made of — SwiftPM plans, Xcode projects
// (project.pbxproj, the JSON project.xcproj, workspaces), XcodeGen specs and
// xcconfig build settings — into the plan the `runway` tool stages. Its
// tests use small fixture projects (Tests/RunwayToolTests/Fixtures).
package.targets.append(contentsOf: [
    .target(name: "RunwayImport"),
    .testTarget(name: "RunwayToolTests", dependencies: ["RunwayImport"], path: "Tests/RunwayToolTests", exclude: ["Fixtures"]),
])
package.targets.first { $0.name == "runway" }?.dependencies.append("RunwayImport")

// MARK: - Interface Builder documents
// AppKit loads .xib and .storyboard sources at run time
// (Sources/AppKit/InterfaceBuilder/); these are their tests (fixtures
// loaded headlessly), the corpus harness that loads every document in a
// tree without its app (Tools/ib-check), and an end-to-end app launched
// from a storyboard (Examples/IBFixtureApp, transpiled like a staged app).
package.targets.append(contentsOf: [
    .executableTarget(name: "RunwayIBCheck", dependencies: ["AppKit", "RunwayCore"], path: "Tools/ib-check"),
    .testTarget(name: "InterfaceBuilderTests", dependencies: ["AppKit", "RunwayCore", "RunwayObjC", "RunwayTranspiler"],
                path: "Tests/InterfaceBuilderTests", resources: [.copy("Fixtures")]),
    .executableTarget(name: "IBFixtureApp", dependencies: ["AppKit", "Cocoa"], path: "Examples/IBFixtureApp",
                      exclude: ["Resources/Info.plist"], resources: [.copy("Resources/Base.lproj")],
                      plugins: ["RunwayTranspileFixtures"]),
])
