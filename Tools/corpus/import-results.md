# Xcode project import: corpus results

`runway stage` and `runway build` on each Xcode app of the corpus with no
configuration (Swift 6.4.2, Linux, 2026-11-10). AeroSpace was run on
`AeroSpace/xcode` (its XcodeGen-generated project; the repository root is
a SwiftPM package). KeyboardCowboy is Tuist-only: runway stops and says to
run `tuist generate` first. "Stage" means the staged package is
well-formed: SwiftPM resolves it and starts compiling. The compile-error
column gives the first module that fails and what it fails on. These are
API gaps in Runway's frameworks or Mac-only code in the app's
dependencies, not import bugs, unless marked **tool**. Every staged
`.build` was deleted after its run.

| App | Format | Targets staged | Swift files | Bundle resources | Packages | Stage | First compile error |
|---|---|---|---|---|---|---|---|
| Stats | pbxproj | Stats, 11 frameworks (Kit, CPU, GPU…), LaunchAtLogin + SMC helper/tool, Tests | 124 | 57 + catalog | 0 | OK | **app sources**: `import CoreAudio` (SystemStats.swift): CoreAudio isn't provided |
| HiddenBar | pbxproj | Hidden_Bar (`Hidden Bar` → c99), HiddenTests | 35 | 20 (10 `.lproj`, Base.lproj/Main.storyboard) + catalog | 1 | OK | dep HotKey (staged): `CFArrayGetCount`, NSApp in nonisolated code (Carbon/CF gaps) |
| Rectangle | pbxproj (sync folders) | Rectangle, RectangleTests | 221 | 5 + catalog + 2 string catalogs | 2 (Sparkle → shim) | OK | dep MASShortcut is Objective-C (`Foundation/Foundation.h` not found) |
| MonitorControl | pbxproj | MonitorControl, MonitorControlHelper | 29 | 70 + catalog | 4 (Sparkle → shim) | OK | dep SimplyCoreAudio: `import CoreAudio` |
| Gifski | pbxproj (sync folders) | Gifski, GifskiTests | 38 | 4 + catalog | 4 (Sentry → shim) | OK | dep ExtendedAttributes: `import System` (swift-system's module isn't linked) |
| SwiftBar | pbxproj | SwiftBar, SwiftBarTests | 70 | 10 + 2 catalogs | 5 (Sparkle → shim) | OK | dep LaunchAtLogin: `SMLoginItemSetEnabled` (ServiceManagement gap) |
| AeroSpace (xcode/) | pbxproj (from XcodeGen) | AeroSpace + local package AeroSpacePackage (staged, with its macro target) | 1 (+ package) | 1 + catalog | 1 local (+ swift-collections, HotKey, TOMLDecoder…) | OK | package's `PrivateApi` C target includes `ApplicationServices/ApplicationServices.h` |
| Amethyst | pbxproj + workspace | Amethyst, AmethystTests | 80 | 20 (xibs) + catalog | 12 (Sparkle → shim) | OK | dep SwiftyJSON (as is): `ambiguous use of operator '<'` (corelibs Foundation difference). RxCocoa isn't declared by RxSwift's manifest on Linux, so it's dropped with a warning |
| Maccy | pbxproj | Maccy, MaccyTests | 130 | 271 (43 `.lproj`) + catalog | 9 (Sparkle → shim) | OK | dep Sauce: `NSF13FunctionKey`…, `DistributedNotificationCenter` `suspensionBehavior:` |
| LinearMouse | pbxproj (sync folders) + 8 local packages | LinearMouse, LinearMouseUnitTests | 296 | 70 + catalog + string catalog | 8 + local Modules/* | OK | local package PointerKit's C target `PointerKitC` (IOKit HID headers). The previous run reached the **app sources**: `objc_getAssociatedObject` |
| Clipy | pbxproj (sync folders) + local package | Clipy, ClipyTests | 97 | 9 + catalog + 2 string catalogs | 14 (Sparkle, Firebase → shims) | **tool**: realm-swift's staged manifest has duplicate `Base.lproj/*.storyboard` resources | Realm is C++/ObjC anyway (not buildable) |
| FSNotes | pbxproj + workspace | FSNotes | 229 | 29 + catalog + 2 string catalogs | 6 (libssh2/SoulverCore/libgit2 xcframeworks left out) | OK | dep ZipArchive is Objective-C |
| NetNewsWire | pbxproj (sync folders, local packages in an unowned synchronized folder) | NetNewsWire, NetNewsWireTests (17 local packages staged) | 218 | 69 + catalog + 18 string catalogs | 3 remote (Sparkle, PLCrashReporter → shims) + local Modules/* | **tool**: swift-build reports "missing target CZlib" for Runway's AppKit in this graph (still to look into). The previous run, before local packages were found, reached dep Zip: `fopen` optional on Glibc | — |
| VirtualBuddy | JSON project.xcproj | VirtualBuddy, VirtualUI, VirtualCore, VirtualWormhole, VirtualInstallation, DeepLinkSecurity, VirtualBuddyGuest, VirtualBuddyGuestHelper, 2 test targets | 315 | 10 + 6 catalogs | 9 (Sparkle → shim) | OK | dep libfragmentzip: `stderr` not concurrency-safe (Swift 6 mode on Glibc) |
| CodeEdit | pbxproj (sync folders) | CodeEdit (tests left out of `build`) | 664 | 22 + 2 catalogs | 17 (Sparkle → shim) | OK | dep LogStream: C module `ExternalAppLoggerHeaders` (OSLog private headers) |
| KeyboardCowboy | Tuist | — | — | — | — | not read (Tuist) | — |

Spot checks of the staged packages:

- **Sources**: each target's Sources phase or synchronized folders. For
  example, CodeEdit's `OpenWithCodeEdit` exception keeps `FinderSync.swift`
  out of the app, and the Info.plist exceptions are honoured. Objective-C
  files in Swift targets are left out with a note (HiddenBar
  `HBNativeVisibilityShim.m`, VirtualBuddy's `.m` helpers, Stats' `lldb.m`
  and `reader.m`). Each file is wrapped in `#sourceLocation`, so
  diagnostics name the corpus files.
- **Resources**: `_RunwayBundles/<app>/Resources` mirrors
  `Contents/Resources`: `Base.lproj/Main.storyboard` (HiddenBar,
  Rectangle, LinearMouse), Amethyst's xibs, `<lang>.lproj/Localizable.strings`
  (Maccy: 43 languages), folder references (NetNewsWire's `.nnwtheme`
  folders), and one RunwayAssets per app with its frameworks' catalogs.
- **Info.plist**: `INFOPLIST_FILE` expanded (`$(MARKETING_VERSION)`,
  `$(PRODUCT_BUNDLE_IDENTIFIER)`), or generated (AeroSpace, VirtualBuddy
  guest: `LSUIElement` as a boolean). `CFBundleExecutable` is the module
  name. VirtualBuddy's xcconfigs are anchored in a folder
  (`codes.rambo.VirtualBuddy`, version 2.3 (431)). FSNotes's main target
  sets no MARKETING_VERSION, so its version is empty, as in Xcode.
- **Settings**: language mode per SWIFT_VERSION, DEBUG-only defines,
  upcoming features and default isolation (Xcode 16 templates).
- **Dependencies**: pinned revisions from the project's or workspace's
  Package.resolved. Shims stand in for Sparkle, Sentry, Firebase and
  PLCrashReporter. swift-syntax is shared with Runway by URL.
  Mac-UI packages are staged, pure-Swift ones used as they are or
  rewired.

Commonest blockers after import: Objective-C/C dependency targets
(MASShortcut, ZipArchive, PrivateApi, PointerKitC); missing frameworks
CoreAudio and `System`; Carbon key codes and CF array API; ServiceManagement's
legacy `SMLoginItemSetEnabled`; and `objc_getAssociatedObject`.
