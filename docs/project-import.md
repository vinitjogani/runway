# Project import and staging

The `runway` build tool takes an app the way its developers build it on a
Mac and stages it as a Swift package that builds against Runway's modules.

## Commands

```sh
runway <check|plan|stage|build|run|test> <dir>
```

Zero configuration. There is no per-app porting code: what an app needs that
Runway doesn't map yet fails to compile as a missing Apple API, and the fix
belongs in Runway's modules.

| Command | Does |
|---|---|
| `check` | Reports, file by file, which imports and AppKit names are covered |
| `plan` | Prints the selected targets, files, resources, settings, Info.plist and packages |
| `stage` | Writes the staged package and prints its path |
| `build` | Stages and builds |
| `run` | Stages, builds and runs the app |
| `test` | Stages only the test targets and what they depend on, and runs them |
| `standins <header>…` | Prints the Swift stand-ins generated for Objective-C headers ([below](#objective-c-and-c-code)) |

Options (`runway --help` prints them):

| Option | |
|---|---|
| `--project <name\|path>` | which `.xcodeproj`, `.xcworkspace` or `project.yml`, when there are several |
| `--target <name>` | the Xcode app target to build (default: the main app) |
| `--platform <macos\|ios>` | the Xcode app platform (default: inferred, preferring macOS); see [iOS](ios.md) |
| `--product <name>` | product to build or run; stages only that product's targets |
| `--filter <pattern>`, `--skip <pattern>` | tests to run or skip |
| `-c, --configuration` | `debug` (default) or `release` |
| `--headless` | run with no display (`RUNWAY_BACKEND=headless`) |
| `--device <iphone-pro\|iphone\|ipad>` | viewport for a SwiftUI preview |
| `--ios-simulator-code` | include simulator-only branches in an iOS project |
| `-- args` | arguments passed to the app |

Nothing in the app's folder is written. Because `test` and `--product` stage
only what they need, an app target that can't build yet doesn't stop its
library's tests.

## Project formats

`<dir>` may hold:

| Project | Read by |
|---|---|
| SwiftPM package (`Package.swift`) | `swift package dump-package` (`Sources/runway/SwiftPM.swift`) |
| Xcode project (`.xcodeproj/project.pbxproj`) | RunwayImport's OpenStep plist parser and object graph (`PBXProject.swift`) |
| Xcode's JSON project format (`.xcodeproj/project.xcproj`) | `XcprojJSON.swift` |
| Xcode workspace (`.xcworkspace`) | its projects and local packages |
| XcodeGen spec (`project.yml`) with no generated project | `XcodeGen.swift` (a YAML subset parser) |
| Tuist (`Project.swift`) | not read: run `tuist generate` on a Mac and point runway at the result |

Precedence in `<dir>`: a workspace, then a project, then `project.yml`, then
`Package.swift`. One folder down is searched too. Runway selects the main
macOS or iOS app automatically, preferring macOS when both are present.

## Xcode projects

The Xcode readers live in `Sources/RunwayImport`, a library the tool and its
tests share. An Xcode project becomes one SwiftPM target per Xcode target the
app needs:

- the app, as an executable named after its `PRODUCT_MODULE_NAME`
  (`Hidden Bar` → `Hidden_Bar`, Xcode's c99 rule);
- the frameworks and static libraries it links;
- helper apps and tools it embeds (as executables);
- unit tests whose host or dependency is in that set.

App extensions, widgets, XPC services, UI tests and unrelated targets are
left out, each with a note. For each target Runway reads:

**Files.** The Sources and Resources build phases, resolved through the group
tree (`<group>`, `SOURCE_ROOT` and absolute paths; SDK, build-products and
developer-dir references ignored). Variant groups become `<lang>.lproj/`
files, and folder references are taken whole. Xcode 16 synchronized folders
are read with their exception sets: a target's own folder minus its
exceptions, plus files other folders' exceptions give it. Files moved to a
copy phase by a build-phase exception are left out, and folders holding a
`Package.swift` are local packages, not sources. A target of only portable C
sources becomes a C target; Objective-C, and C that needs Apple's SDK, become
Swift [stand-ins](#objective-c-and-c-code). Core Data models, Metal and
intent definitions aren't compiled (noted).

**Build settings**, for Debug and Release, stacked as Xcode stacks them: its
defaults, the project's xcconfig (`#include`, `#include?`), the project's
settings, the target's xcconfig (also one inside a synchronized folder), the
target's settings. `[config=…][sdk=…]` conditions, `$(inherited)` and
`$(VAR:modifier)` (`c99extidentifier`, `rfc1034identifier`, `lower`,
`base`…) are evaluated. These carry over, conditioned on the configuration
where Debug and Release differ:

- `SWIFT_VERSION` (language mode);
- `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `-D` in `OTHER_SWIFT_FLAGS`
  (defines);
- `SWIFT_UPCOMING_FEATURE_*` and `-enable-upcoming-feature`;
- `SWIFT_STRICT_CONCURRENCY=complete`, `SWIFT_APPROACHABLE_CONCURRENCY` and
  `SWIFT_DEFAULT_ACTOR_ISOLATION`.

**Info.plist.** `INFOPLIST_FILE` with its `$(VAR)`s expanded, merged with
what `GENERATE_INFOPLIST_FILE` and the `INFOPLIST_KEY_*` settings generate
(`CFBundleIdentifier` from `PRODUCT_BUNDLE_IDENTIFIER`,
`CFBundleShortVersionString` from `MARKETING_VERSION`, `CFBundleVersion`
from `CURRENT_PROJECT_VERSION`…). `CFBundleExecutable` names the Linux
binary.

**Resources** keep Xcode's `Contents/Resources` layout and land next to the
executable as the main bundle: files flattened to their names,
`<lang>.lproj/` kept (`Base.lproj/Main.storyboard`, `.xib`s, `.strings`),
folder references whole. Asset catalogs (the app's and its frameworks')
become one `RunwayAssets`, and string catalogs become `.lproj/*.strings`.
So `Bundle.main.path(forResource: "Main", ofType: "storyboard")` finds the
storyboard where AppKit's [Interface Builder](interface-builder.md) loading
looks for it.

**Dependencies.** Target dependencies and frameworks linked from other
targets become target dependencies. Package products become product
dependencies of the packages that declare them (a product with no package
named is matched against the local packages the project or workspace refers
to, then the remote ones).

## Package dependencies

Remote and local packages, of Xcode projects and SwiftPM packages alike, are
staged with the app (`Sources/runway/Dependencies.swift`).

Each package in the graph is fetched once, at the revision Package.resolved
pins (the workspace's, the project's
`project.xcworkspace/xcshareddata/swiftpm`, or the package's), else the
newest tag the requirement allows, into
`.runway/deps/checkouts/<rev>/<identity>`. `RUNWAY_DEPS_MIRROR=<dir>` reuses
local clones named `<owner>__<repo>`.

Each package is then:

- **staged** like the app (transformed sources, Runway's modules linked per
  import, macros built for the host, tests and plugins left out) into
  `<stage>/Dependencies/<identity>`, when a library target imports an Apple
  framework Runway provides (`#if canImport(os) import os`-style optional
  imports don't count) or uses `URLSession` without `FoundationNetworking`;
- **rewired**: copied with its manifest's `.package(url:/path:)` pointing at
  the staged paths, when it's plain Swift with dependencies;
- **used as it is** (the checkout), when it's plain Swift with none;
- **left out**, when it only provides build-tool plugins (SwiftLint's…): its
  dependents are staged without their plugin uses.

Manifests that declare dynamic libraries are regenerated (swift-build can't
link those against system library targets). Every reference to a package
then points at one local path, so SwiftPM never sees an identity at two
locations.

## Objective-C and C code

Objective-C, and C that needs Apple's SDK or the Objective-C runtime, can't
be compiled here. Runway reads its headers and writes Swift **stand-ins**
(`Sources/RunwayImport/ObjCHeaders.swift`, `ObjCStandIns.swift`;
`runway standins <header>…` prints them).

The declarations use the names Swift's importer gives them on a Mac
(`initWithFoo:` → `init(foo:)`, `+sharedMonitor` → `shared()`, NS_ENUM cases
without their prefix, `FooRef` → `Foo`, `NSError **` → `throws`, Core
Foundation results `Unmanaged` outside CF_IMPLICIT_BRIDGING). Their bodies
report the feature unavailable: objects can be made and hold their
properties, methods return false / 0 / nil / empty values, and functions that
report errors return a failure.

Stand-ins are generated for:

- an Xcode target's **bridging header** (internal names; the frameworks it
  includes are re-exported to the target, as a bridging header does);
- an Xcode framework's Objective-C sources (its umbrella header and the
  headers of its `.m` files, public);
- a SwiftPM **C-family target** with Objective-C sources or unguarded
  includes of Apple headers (its public headers; the target becomes a Swift
  target of the same name). Portable C targets still compile as C; C++
  targets aren't stood in for;
- a **binary target** (xcframework) that ships C headers.

The app then builds and runs with whatever was behind those headers switched
off.

## Third-party shims

Mac frameworks shipped as binary xcframeworks can't be built here, so Runway
carries drop-in packages in [`ThirdParty/<identity>`](../ThirdParty) with the
same identity, products, module names and the public API apps use, reporting
the feature unavailable. A dependency whose identity names a folder in
`ThirdParty/` is replaced by it (and staged like any other).

| Shim | Stands in for | Behaviour |
|---|---|---|
| `Sparkle` | sparkle-project/Sparkle (9 of 18 corpus apps; forks with the same identity too) | `SPUStandardUpdaterController`, `SPUUpdater`, delegates, `SUAppcastItem`, Sparkle 1's `SUUpdater`: `canCheckForUpdates` is false, `start()` throws "unavailable", checks do nothing; settings persist in UserDefaults; KVO works |
| `sentry-cocoa` | getsentry/sentry-cocoa | `SentrySDK.start`/`capture` do nothing |
| `firebase-ios-sdk` | firebase/firebase-ios-sdk (Core, Analytics, Crashlytics) | `FirebaseApp.configure` records options; events and errors are dropped |
| `plcrashreporter` | microsoft/plcrashreporter | `enable()` fails, never a pending report |

## The staged package

`runway stage` prints the path of the staged package under Runway's
`.runway/` directory. Desktop, iOS, and iOS simulator-branch builds have
separate stage directories. The staged package is written to a scratch
folder and synchronised into place, so unchanged files keep their timestamps
and rebuilds stay incremental.

**Sources** are copies, not symlinks. Each passes through one hook,
`transformSource(_:path:)` in `Sources/runway/Stage.swift` (where the
RunwayTranspiler plugs in), and is wrapped in `#sourceLocation(file:
<original path>)`. `#filePath`, `#file` and compiler diagnostics therefore
name the app's own files, so `#filePath`-relative fixtures resolve in the
app's tree (`-file-prefix-map` doesn't remap `#filePath`, so it can't do
this). `Foo.swift` is staged as `Foo.staged.swift` so the directive's
`#fileID` doesn't clash with the physical name; `main.swift` keeps its name
and gets no directive.

**Package.swift** keeps the app's targets, products, dependencies and
compiler settings (language mode, default isolation, defines, upcoming
features). It adds Runway's module for each Apple framework a target imports
(`Cocoa` counts as AppKit), and implicitly imports `FoundationNetworking`
(URLSession lives there off Apple platforms) and `RunwayFoundation` into
every file.

**Resources** are copied as declared.

- Asset catalogs become `RunwayAssets/RunwayAssets.json` plus the image
  files, read at run time by `RunwayAssets` in RunwayCore: colour sets as
  light/dark sRGB, image sets as files per scale, and vector PDFs rasterized
  to 1x and 2x PNGs with Poppler's `pdftocairo` when it's installed.
- String catalogs (`.xcstrings`) become `<lang>.lproj/<table>.strings`.

**Bundle.main.** An app's Info.plist (`Resources/Info.plist`, `Info.plist`
or one in the target, matched by `CFBundleExecutable`) is installed next to
the built executable along with its resources, since corelibs Foundation
reads the executable's directory as the main bundle. `bundleIdentifier`,
`infoDictionary` and `localizedString` then work as on a Mac.

**Shared build directory.** `RUNWAY_SCRATCH_PATH=<dir>` makes every staged
app build in one SwiftPM build directory, so Runway's own modules compile
once for all of them (each app's bundle is then put together in
`<stage>/_RunwayApp`).

## Tests for the build tool

- `Tests/Fixtures/StagingFixture` exercises the staging (Info.plist,
  catalogs, `#filePath`): `runway run` and `runway test` on it.
- `Tests/RunwayToolTests` checks the importers on small Xcode projects:
  groups and variant groups, synchronized folders and exceptions, xcconfigs,
  generated Info.plists, local and remote packages and pins, the JSON format,
  XcodeGen.
- [Corpus status](corpus/status.md) records how each Xcode app of the corpus
  stages and builds.
