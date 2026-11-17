<p align="center"><img src="brand/logo.svg" width="96" alt="Runway logo"></p>

# Runway

**Build SwiftUI and AppKit Mac apps, unchanged, for Linux and Windows.** Runway is a
compilation layer: a drop-in `SwiftUI` and a slice of `AppKit` implemented
over each platform's native toolkit (GTK 4 on Linux, Win32 on Windows), shims
for the small Apple frameworks apps lean on, and a build tool that stages an
existing SwiftPM app against them without touching its sources.

```sh
cd runway
swift build --product runway
.build/debug/runway check ../my-macos-app
.build/debug/runway test ../my-macos-app
.build/debug/runway run ../my-macos-app
swift run RunwayGallery                    # a plain SwiftUI app on Linux
```

Needs a Swift 6.2+ toolchain for Linux or Windows (swift.org) and, on Linux,
GTK 4.12+ (`apt install libgtk-4-dev`). On macOS there's nothing to do: the
apps build with Apple's own frameworks.

## How it fits together

```
 your app's sources (unchanged)
   import SwiftUI / AppKit / ImageIO / …
        │  staged by `runway` (transformed copies + a generated Package.swift)
        ▼
 Runway modules with Apple's names
   SwiftUI     views, @State/@Binding/@Observable, environment, layout with
               SwiftUI's rules, controls, Form, List, sheets, App/Scene
   AppKit      the view system: NSView (draw(_:), flipped coordinates, hit
               testing), Auto Layout (Cassowary), NSResponder chain and
               target/action, NSEvent, tracking areas, cursors, drag and drop,
               NSWindow/NSWindowController/NSViewController, NSMenu as the menu
               bar; NSColor, NSFont, NSImage, NSPasteboard, NSWorkspace, panels…
   shims       CoreGraphics, ImageIO, UniformTypeIdentifiers, NaturalLanguage,
               ServiceManagement, Security, CryptoKit, RunwayFoundation
        │  RunwayCore: the backend contract (widgets, measure, place, windows,
        ▼  services); layout is computed above it, identical everywhere
 RunwayGTK (Linux)      GTK 4 widgets in an absolute-layout container, Cairo,
                        GdkPixbuf, GIO, D-Bus FileManager1, GtkFileDialog…
 RunwayWin32 (Windows)  custom-drawn controls, DirectWrite, Windows shell APIs
 HeadlessBackend        no display: tests, CI, `--headless`
```

The SwiftUI layer resolves a view tree into layout nodes each render, keeping
`@State` and native widgets by each view's structural identity (its position
in the tree, as SwiftUI does), and tracks `@Observable` reads with
`withObservationTracking` so model changes re-render. Layout follows
SwiftUI's propose → choose → place protocol (stacks divide space from least
to most flexible by layout priority; flexible frames clamp; `fixedSize`
proposes the ideal size), so screens laid out on the Mac lay out the same.
Backends only provide widgets, measure them and put them where they're told,
which keeps them small and makes every platform lay out the same way.

## Native mappings

| Apple API | Linux | Windows |
|---|---|---|
| SwiftUI controls | GTK 4 widgets, Mac-styled | custom-drawn, Mac-styled |
| Shapes, gradients | Cairo | Direct2D/GDI |
| `NSPasteboard` | GDK clipboard (text, `text/uri-list`) | Clipboard (CF_UNICODETEXT, CF_HDROP) |
| `NSWorkspace.open` / reveal | GIO default handler / FileManager1 over D-Bus | ShellExecute / SHOpenFolderAndSelectItems |
| `NSSound(named:)` | freedesktop sound theme | system sounds |
| `NSOpenPanel` / `NSSavePanel` / `NSAlert` | GtkFileDialog / GtkAlertDialog | common item dialogs / TaskDialog |
| `SMAppService.mainApp` | XDG autostart entry | HKCU `…\Run` |
| ImageIO | GdkPixbuf loaders (+ EXIF orientation) | WIC (to do) |
| UniformTypeIdentifiers | Apple's type tree + shared-mime-info | Apple's type tree |
| NaturalLanguage | Swift tokenizers, language detection; word vectors from `.vec` files | same |
| Keychain (`SecItem…`) | per-user 0600 store | per-user store |
| `NSData.compressed(.zlib)`, `trashItem` | zlib, freedesktop Trash | built-in inflater |
| `Color(nsColor:)`, dynamic colours | follow light/dark | follow light/dark |
| `NSView.draw(_:)`, `NSBezierPath`, `CGContext` | display list replayed with Cairo; text with Pango | (to do) |
| `NSTextView` / TextKit 1 (`NSTextStorage`, `NSLayoutManager` and its delegate) | GtkTextView laying out and drawing the storage as tags: null glyphs invisible, whitespace control glyphs as spacers, the delegate's paragraph spacing, temporary attributes; `drawBackground`/`draw(_:)` as snapshot layers under and over the text; keys, typing (input method), clicks, selection, undo and the pasteboard through AppKit's methods | plain multi-line text |
| NSView input, `NSCursor`, `registerForDraggedTypes` | GTK event controllers, CSS cursors, GtkDropTarget | key/mouse via the window |
| `NSApp.mainMenu`, `NSMenu.popUp` | GtkPopoverMenuBar per window, in its titlebar row; GtkPopoverMenu | key equivalents |
| Titlebar, `NSToolbar`, full-size content | client-side titlebar row (traffic lights, menu bar, title) and a toolbar band; safe areas | (to do) |
| `NSScreen` | GDK monitors | one screen |

## Window chrome

**Menu bar on the desktop's top bar.** Where the desktop has a global menu bar, the menu goes there, as on the Mac. That covers Unity, KDE Plasma, and Xfce, MATE or Budgie with their appmenu plugin.
- Each window exports its menu as `com.canonical.dbusmenu` and registers with `com.canonical.AppMenu.Registrar`. KDE also gets the `_KDE_NET_WM_APPMENU_*` window properties.
- The exported menu is the same `GMenuModel` and actions the in-window bar uses. Shortcuts, separators, checkmarks and enabled states carry over, and menus validate as they open.
- While a host is present, the titlebar row drops the menu. A window with a toolbar loses the row entirely: its traffic lights float at the leading edge of the toolbar band, as on a Mac with a unified toolbar, and `standardWindowButton(_:)` returns their frames.
- The host is watched, so the in-window bar comes back if the host goes away. Stock GNOME, Ubuntu's default included, has no global menu, so the in-window bar stays there.
- This currently needs X11, since the registrar names windows by X11 id. `RUNWAY_GLOBAL_MENU=0` turns it off.

**Symbols.** SF Symbols names (`NSImage(systemSymbolName:)`, `Image(systemName:)`) are drawn as open line art from Lucide (ISC licence). Lucide uses SF's rounded strokes on a 24-unit grid, and the table is in `RunwayCore/SymbolArt+Table.swift`, generated by `Tools/symbols/generate.py`.
- The variants `.fill`, `.circle`, `.circle.fill`, `.square` and `.slash` are composed as SF composes them.
- On GTK each symbol is a `GtkSymbolicPaintable`, drawn in the widget's CSS colour, so tints, hover, disabled states and dark mode follow the theme.
- Names with no art fall back to the Adwaita icon theme.


A Mac window's titlebar holds the traffic lights, the title and (unified)
the toolbar, and the menu bar is at the top of the screen. On Linux each
titled window draws its own titlebar row, the same under any window
manager or none: the traffic lights at the leading edge, the menu bar
beside them (the app's name in bold, as on the Mac), and the title centred
when no toolbar shows it. A visible toolbar adds a band below that row
(38 pt for `.unifiedCompact`, 46 for unified) with the title, subtitle and
items, lined up with split views at the sidebar and inspector tracking
separators. With `.fullSizeContentView` the content runs under the band,
as on the Mac: the band is the content's safe-area top inset
(`safeAreaInsets`, `safeAreaRect` and `safeAreaLayoutGuide` follow it down
the view tree), `contentLayoutRect` leaves it out, scroll views that adjust
their insets automatically start below it, and clicking its empty parts
reaches the content (controls, views that say `mouseDownCanMoveWindow` is
false) or drags the window. Otherwise the band sits above the content on
the titlebar's material. Sheets have no titlebar.

Up to the window manager (so not under Xvfb, which has none): where a
window opens (`center()`, `cascadeTopLeft`, frame origins), moving it
(`performDrag`), minimising, and the minimum size it enforces while the
user resizes. Sizes (`setContentSize`, `minSize`, frame autosave) are the
toolkit's and hold everywhere.

## Interface Builder documents

AppKit reads `.xib` and `.storyboard` sources (Xcode 12–16, macOS) at run
time from the bundle (`Base.lproj`, the preferred `<lang>.lproj`, the top
level, SwiftPM resource bundles), as Cocoa reads compiled nibs
(`Sources/AppKit/InterfaceBuilder/`). Objects are made as nib loading makes
them: views, controllers and an app's custom subclasses through
`init?(coder:)` (IB's properties are set by the time `super.init(coder:)`
returns), windows through `init(contentRect:styleMask:backing:defer:)`,
custom objects through `init()`; then constraints, connections (outlets and
outlet collections by KVC through the transpiler's tables, AppKit's own
outlets, target/action with First Responder as nil-targeted, bindings to
`NSUserDefaultsController`), user-defined runtime attributes, and
`awakeFromNib` to every object and then the File's Owner. `NSNib`,
`Bundle.loadNibNamed`, `NSViewController` loading its nib (`nibName`, else
one named like the class), `NSWindowController(windowNibName:)`,
`NSStoryboard` (scenes on demand; a controller's view or window loads
lazily from its scene; relationship, embed, show, sheet, modal and popover
segues with `prepare(for:sender:)`), view-based table prototypes for
`makeView(withIdentifier:owner:)`, Base-internationalized `.strings`, and
`NSApplicationMain` / `@main` loading Info.plist's `NSMainStoryboardFile`
or `NSMainNibFile` all work as on the Mac.

Swift has no `NSClassFromString`: `customClass` resolves through
RunwayObjC's `ClassRegistry`: a table the build tool generates per module
(`RunwayTranspiler.classRegistrySource`, also listing `init()` and window
initializers, which a metatype can't call), else the Swift runtime's
metadata by mangled name. `swift run RunwayIBCheck <dir>` loads documents
without their app and reports what isn't read; the corpus's results are in
`Tools/corpus/ib-results.md`, and `Tools/ib-fixture.sh` runs the
storyboard app in `Examples/IBFixtureApp` under Xvfb and clicks through it.

## The build tool

Zero configuration: `runway <check|plan|stage|build|run|test> <dir>` and
nothing else. There is no per-app porting code; what an app needs that
Runway doesn't map yet fails to compile as a missing Apple API, and the fix
belongs in Runway's modules.

`<dir>` holds the app the way its developers build it on a Mac:

| Project | Read by |
|---|---|
| SwiftPM package (`Package.swift`) | `swift package dump-package` (`Sources/runway/SwiftPM.swift`) |
| Xcode project (`.xcodeproj/project.pbxproj`) | RunwayImport's OpenStep plist parser and object graph (`PBXProject.swift`) |
| Xcode's JSON project format (`.xcodeproj/project.xcproj`) | `XcprojJSON.swift` |
| Xcode workspace (`.xcworkspace`) | its projects (the one with the macOS app) and local packages |
| XcodeGen spec (`project.yml`) with no generated project | `XcodeGen.swift` (a YAML subset parser) |
| Tuist (`Project.swift`) | not read: run `tuist generate` on a Mac and point runway at the result |

A workspace, then a project, then `project.yml`, then `Package.swift` in
`<dir>` wins (one folder down is searched too); `--project <name|path>`
picks one when there are several, and `--target <name>` builds another app
target than the main one (the macOS app no other target embeds, named like
the project when there are several). `runway plan <dir>` prints what was
read: targets, files, resources, settings, Info.plist, packages.

**Xcode projects** (`Sources/RunwayImport`, a library the tool and its tests
share) become one SwiftPM target per Xcode target the app needs: the app
as an executable named after its `PRODUCT_MODULE_NAME` (`Hidden Bar` →
`Hidden_Bar`, Xcode's c99 rule), the frameworks and static libraries it
links, helper apps and tools it embeds (executables), and unit tests whose
host or dependency is in that set. App extensions, widgets, XPC services,
UI tests, iOS-only and unrelated targets are left out, each with a note.
For each target:

- **Files**: the Sources and Resources build phases resolved through the
  group tree (`<group>`, `SOURCE_ROOT` and absolute paths; SDK, build
  products and developer-dir references ignored), variant groups as
  `<lang>.lproj/` files, folder references whole, and Xcode 16 synchronized
  folders with their exception sets (a target's own folder minus its
  exceptions, plus files other folders' exceptions give it; files moved to
  a copy phase by a build-phase exception left out; folders holding a
  `Package.swift` are local packages, not sources). A target of only
  portable C sources becomes a C target; Objective-C, and C that needs
  Apple's SDK, become Swift stand-ins (see "Objective-C and C code" below). Core Data models, Metal and intent
  definitions aren't compiled (noted).
- **Build settings** for Debug and Release, as Xcode stacks them: its
  defaults, the project's xcconfig (`#include`, `#include?`), the
  project's settings, the target's xcconfig (also one inside a synchronized
  folder), the target's settings; `[config=…][sdk=…]` conditions,
  `$(inherited)`, `$(VAR:modifier)` (`c99extidentifier`, `rfc1034identifier`,
  `lower`, `base`…). `SWIFT_VERSION` (language mode),
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` and `-D` in `OTHER_SWIFT_FLAGS`
  (defines), `SWIFT_UPCOMING_FEATURE_*`, `-enable-upcoming-feature`,
  `SWIFT_STRICT_CONCURRENCY=complete`, `SWIFT_APPROACHABLE_CONCURRENCY` and
  `SWIFT_DEFAULT_ACTOR_ISOLATION` carry over, conditioned on the
  configuration where Debug and Release differ.
- **Info.plist**: `INFOPLIST_FILE` with its `$(VAR)`s expanded, merged with
  what `GENERATE_INFOPLIST_FILE` and the `INFOPLIST_KEY_*` settings generate
  (`CFBundleIdentifier` from `PRODUCT_BUNDLE_IDENTIFIER`,
  `CFBundleShortVersionString` from `MARKETING_VERSION`, `CFBundleVersion`
  from `CURRENT_PROJECT_VERSION`…); `CFBundleExecutable` names the Linux
  binary.
- **Resources** keep Xcode's `Contents/Resources` layout and land next to
  the executable as the main bundle: files flattened to their names,
  `<lang>.lproj/` kept (`Base.lproj/Main.storyboard`, `.xib`s, `.strings`),
  folder references whole; asset catalogs (the app's and its frameworks')
  become one `RunwayAssets`, string catalogs `.lproj/*.strings`. So
  `Bundle.main.path(forResource: "Main", ofType: "storyboard")` finds the
  storyboard where AppKit's Interface Builder loading looks for it.
- **Dependencies**: target dependencies and frameworks linked from other
  targets become target dependencies; package products become product
  dependencies of the packages that declare them (a product with no
  package named is matched against the local packages the project or
  workspace refers to, then the remote ones).

**Package dependencies** (remote and local, of Xcode projects and SwiftPM
packages alike, `Sources/runway/Dependencies.swift`) are staged with the
app. Each package in the graph is fetched once at the revision
Package.resolved pins (the workspace's, the project's
`project.xcworkspace/xcshareddata/swiftpm`, or the package's), else the
newest tag the requirement allows, into `.runway/deps/checkouts/<rev>/<identity>`
(`RUNWAY_DEPS_MIRROR=<dir>` reuses local clones named `<owner>__<repo>`).
Then it is

- **staged** like the app (transformed sources, Runway's modules linked per
  import, macros built for the host, tests and plugins left out) into
  `<stage>/Dependencies/<identity>` when a library target imports an Apple
  framework Runway provides (`#if canImport(os) import os`-style optional
  imports don't count) or uses `URLSession` without `FoundationNetworking`;
- **rewired**: copied with its manifest's `.package(url:/path:)` pointing at
  the staged paths, when it's plain Swift with dependencies;
- **used as it is** (the checkout) when it's plain Swift with none;
- **left out** when it only provides build-tool plugins (SwiftLint's…):
  its dependents are staged without their plugin uses.

Manifests that declare dynamic libraries are regenerated (swift-build
can't link those against system library targets).

Every reference to a package then points at one local path, so SwiftPM
never sees an identity at two locations.

**Objective-C and C code** that needs Apple's SDK or the Objective-C
runtime can't be compiled here, so Runway reads its headers and writes
Swift **stand-ins** (`RunwayImport/ObjCHeaders.swift`, `ObjCStandIns.swift`;
`runway standins <header>…` prints them): the declarations under the names
Swift's importer gives them on a Mac (`initWithFoo:` → `init(foo:)`,
`+sharedMonitor` → `shared()`, NS_ENUM cases without their prefix, `FooRef`
→ `Foo`, `NSError **` → `throws`, Core Foundation results `Unmanaged`
outside CF_IMPLICIT_BRIDGING), with bodies that report the feature
unavailable: objects can be made and hold their properties, methods return
false / 0 / nil / empty values, functions that report errors return a
failure. They are generated for

- an Xcode target's **bridging header** (internal names; the frameworks it
  includes are re-exported to the target, as a bridging header does),
- an Xcode framework's Objective-C sources (its umbrella header and the
  headers of its `.m` files, public),
- a SwiftPM **C-family target** with Objective-C sources or unguarded
  includes of Apple headers (its public headers; the target becomes a Swift
  target of the same name). Portable C targets still compile as C; C++
  targets aren't stood in for,
- a **binary target** (xcframework) that ships C headers.

The app then builds and runs with whatever was behind those headers
switched off.

**Third-party shims** (`ThirdParty/<identity>`): Mac frameworks shipped as
binary xcframeworks can't be built here, so Runway carries drop-in packages
with the same identity, products, module names and the public API apps
use, reporting the feature unavailable. A dependency whose identity names a
folder in `ThirdParty/` is replaced by it (and staged like any other):

| Shim | Stands in for | Behaviour |
|---|---|---|
| `Sparkle` | sparkle-project/Sparkle (9 of 18 corpus apps; forks with the same identity too) | `SPUStandardUpdaterController`, `SPUUpdater`, delegates, `SUAppcastItem`, Sparkle 1's `SUUpdater`: `canCheckForUpdates` is false, `start()` throws "unavailable", checks do nothing; settings persist in UserDefaults; KVO works |
| `sentry-cocoa` | getsentry/sentry-cocoa | `SentrySDK.start`/`capture` do nothing |
| `firebase-ios-sdk` | firebase/firebase-ios-sdk (Core, Analytics, Crashlytics) | `FirebaseApp.configure` records options; events and errors are dropped |
| `plcrashreporter` | microsoft/plcrashreporter | `enable()` fails, never a pending report |

`runway stage` writes the staged package to `.runway/stage/<name>/`:

- **Sources** are copies, not symlinks, each passed through one hook,
  `transformSource(_:path:)` in `Sources/runway/Stage.swift` (where the
  RunwayTranspiler plugs in), and wrapped in `#sourceLocation(file: <original
  path>)`. `#filePath`, `#file` and compiler diagnostics therefore name the
  app's own files, so `#filePath`-relative fixtures resolve in the app's tree
  (`-file-prefix-map` doesn't remap `#filePath`, so it can't do this).
  `Foo.swift` is staged as `Foo.staged.swift` so the directive's `#fileID`
  doesn't clash with the physical name; `main.swift` keeps its name and gets
  no directive.
- **Package.swift** keeps the app's targets, products, dependencies and
  compiler settings (language mode, default isolation, defines, upcoming
  features), adds Runway's module for each Apple framework a target imports
  (`Cocoa` counts as AppKit), and implicitly imports `FoundationNetworking`
  (URLSession lives there off Apple platforms) and `RunwayFoundation` into
  every file.
- **Resources** are copied as declared. Asset catalogs become
  `RunwayAssets/RunwayAssets.json` plus the image files (colour sets as
  light/dark sRGB, image sets as files per scale; vector PDFs rasterized
  to 1x and 2x PNGs with Poppler's `pdftocairo` when it's installed), read at run time by
  `RunwayAssets` in RunwayCore. String catalogs (`.xcstrings`) become
  `<lang>.lproj/<table>.strings`.
- **Bundle.main**: an app's Info.plist (`Resources/Info.plist`, `Info.plist`
  or one in the target, matched by `CFBundleExecutable`) is installed next to
  the built executable along with its resources, since corelibs Foundation
  reads the executable's directory as the main bundle. `bundleIdentifier`,
  `infoDictionary` and `localizedString` then work as on a Mac.

`runway test` stages only the test targets and what they depend on, and
`--product` only that product's targets, so an app target that can't build
yet doesn't stop its library's tests. The staged package is written to a
scratch folder and synchronised into place, so unchanged files keep their
timestamps and rebuilds stay incremental. `runway check` reports, file by
file, which imports and AppKit names are covered. Nothing in the app's
folder is written. `Tests/Fixtures/StagingFixture` exercises the staging
(Info.plist, catalogs, `#filePath`): `runway run` and `runway test` on it.
`Tests/RunwayToolTests` checks the importers on small Xcode projects
(groups and variant groups, synchronized folders and exceptions, xcconfigs,
generated Info.plists, local and remote packages and pins, the JSON format,
XcodeGen); `Tools/corpus/import-results.md` records how each Xcode app of
the corpus stages and builds.

## Compatibility results

See the [corpus build results](Tools/corpus/import-results.md) for examples of apps staged and built on Linux.

## Layout

```
Sources/SwiftUI            the SwiftUI layer
Sources/AppKit             the AppKit slice
Sources/RunwayCore         backend contract, paint/font model, headless backend
Sources/RunwayGTK          Linux backend (+ CRunwayGtk: the absolute-layout container, dialogs)
Sources/RunwayWin32        Windows backend
Sources/RunwayPlatform     picks the backend (RUNWAY_BACKEND=headless for none)
Sources/<Apple framework>  shims
Sources/runway             the build tool
Sources/RunwayImport       its project readers: Xcode (pbxproj, JSON), workspaces, XcodeGen, xcconfig
ThirdParty                 drop-in packages for binary-only Mac frameworks (Sparkle…)
Examples/RunwayGallery     a plain SwiftUI app
Tests/Fixtures             packages the build tool is checked against
Tests/RunwayTests          the layer's tests (headless)
```

Menu-bar apps: `NSStatusItem` (and SwiftUI's `MenuBarExtra`) is a tray
item where the desktop has a StatusNotifierItem host; where it has none,
the app's status items show in a small window of their own, so the app
stays reachable (`RUNWAY_STATUS_ITEM_CLICK=n` clicks the nth one after
launch, for screenshots).

`RUNWAY_SCRATCH_PATH=<dir>` makes every staged app build in one SwiftPM
build directory, so Runway's own modules compile once for all of them
(each app's bundle is then put together in `<stage>/_RunwayApp`).

Environment: `RUNWAY_BACKEND=headless`, `RUNWAY_COLOR_SCHEME=light|dark`,
`RUNWAY_SCREENSHOT=out.png` (render every window to PNG, then quit),
`RUNWAY_WORD_VECTORS=/dir` (fastText `en.vec`… for NaturalLanguage).

## Website

[`site/`](site) is Runway's one-page website (static HTML, built with Vite):

```sh
cd site
npm install
npm run dev     # http://localhost:5173
npm run build   # site/dist, deploy anywhere static
```

In production it runs from [`docker-compose.yml`](docker-compose.yml) (Vite build served by nginx on port 80), deployed on Dokploy at runway.vj.ms.

The logo and colours are in [`brand/`](brand).
