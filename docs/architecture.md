# Architecture

Runway is a compilation layer. An app's sources stay unchanged; the `runway`
build tool stages a copy of them against Runway's modules, which carry
Apple's framework names and are implemented over each platform's native
toolkit.

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
 RunwayDrawn            custom-drawn controls over Win32/D2D (Windows) or GTK/Cairo (Linux)
 HeadlessBackend        no display: tests, CI, `--headless`
```

## The SwiftUI layer

Each render, the SwiftUI layer resolves the view tree into layout nodes. It
keeps `@State` and native widgets by each view's structural identity (its
position in the tree, as SwiftUI does), and tracks `@Observable` reads with
`withObservationTracking` so model changes re-render.

Layout follows SwiftUI's propose → choose → place protocol:

- stacks divide space from least to most flexible, by layout priority;
- flexible frames clamp;
- `fixedSize` proposes the ideal size.

So screens laid out on the Mac lay out the same.

## Backends

Backends only provide widgets, measure them and put them where they're told.
This keeps them small and makes every platform lay out the same way.

- **RunwayGTK** (Linux): GTK 4 widgets, Mac-styled, in an absolute-layout
  container; drawing with Cairo and Pango. See
  [native mappings](frameworks/native-mappings.md).
- **RunwayDrawn** (Windows; Linux with `RUNWAY_BACKEND=drawn`): lightweight
  custom-drawn widgets over a flat C layer, Direct2D on Windows and Cairo on
  Linux, with native text inputs. See the [drawn backend README](../Sources/RunwayDrawn/README.md) for its design,
  how it has been verified, and known gaps.
- **HeadlessBackend** (in RunwayCore): no display, for tests, CI and
  `--headless`. Select it with `RUNWAY_BACKEND=headless`.

`RunwayPlatform` picks the backend at run time.

## Source layout

```
Sources/SwiftUI            the SwiftUI layer
Sources/AppKit             the AppKit slice (Interface Builder loading in InterfaceBuilder/)
Sources/RunwayCore         backend contract, paint/font model, headless backend
Sources/RunwayGTK          Linux backend (+ CRunwayGtk: the absolute-layout container, dialogs)
Sources/RunwayDrawn        Drawn backend (Swift half; Native/win32 and Native/gtk are its C layers)
Sources/RunwayPlatform     picks the backend (RUNWAY_BACKEND=headless for none)
Sources/<Apple framework>  shims (CoreGraphics, ImageIO, Security, …)
Sources/runway             the build tool
Sources/RunwayImport       its project readers: Xcode (pbxproj, JSON), workspaces, XcodeGen, xcconfig
Sources/RunwayTranspiler   source transforms applied while staging
ThirdParty                 drop-in packages for binary-only Mac frameworks (Sparkle…)
Examples/                  sample apps: RunwayGallery (plain SwiftUI), AppKitDemo,
                           AppKitControls, RunwayStress, IBFixtureApp
Tests/Fixtures             packages the build tool is checked against
Tests/RunwayTests          the layer's tests (headless)
Tests/RunwayToolTests      the project importers' tests
Tools/                     corpus scripts, IB checker, measurement, symbol generator
```

## Related

- [Project import and staging](project-import.md): how the build tool turns an
  app into a package that builds against these modules.
- [Interface Builder](interface-builder.md): how AppKit reads `.xib` and
  `.storyboard` files.
