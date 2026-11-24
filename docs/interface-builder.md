# Interface Builder documents

Runway's AppKit reads `.xib` and `.storyboard` sources (Xcode 12–16, macOS)
at run time, the way Cocoa reads compiled nibs. The loader is in
`Sources/AppKit/InterfaceBuilder/`.

## Where documents are found

From the bundle: `Base.lproj`, the preferred `<lang>.lproj`, the top level,
and SwiftPM resource bundles. The build tool lays an app's resources out so
that `Bundle.main.path(forResource: "Main", ofType: "storyboard")` finds them
(see [project import](project-import.md#xcode-projects)).

## How objects are made

As nib loading makes them:

- views, controllers and an app's custom subclasses through `init?(coder:)`
  (IB's properties are set by the time `super.init(coder:)` returns);
- windows through `init(contentRect:styleMask:backing:defer:)`;
- custom objects through `init()`.

Then, in order: constraints; connections (outlets and outlet collections by
KVC through the transpiler's tables, AppKit's own outlets, target/action with
First Responder as nil-targeted, bindings to `NSUserDefaultsController`);
user-defined runtime attributes; and `awakeFromNib` to every object and then
the File's Owner.

## What works as on the Mac

- `NSNib`, `Bundle.loadNibNamed`
- `NSViewController` loading its nib (`nibName`, else one named like the class)
- `NSWindowController(windowNibName:)`
- `NSStoryboard`: scenes on demand; a controller's view or window loads
  lazily from its scene; relationship, embed, show, sheet, modal and popover
  segues with `prepare(for:sender:)`
- view-based table prototypes for `makeView(withIdentifier:owner:)`
- Base-internationalized `.strings`
- `NSApplicationMain` / `@main` loading Info.plist's `NSMainStoryboardFile`
  or `NSMainNibFile`

## Custom classes

Swift has no `NSClassFromString`. `customClass` resolves through RunwayObjC's
`ClassRegistry`: a table the build tool generates per module
(`RunwayTranspiler.classRegistrySource`, which also lists `init()` and window
initializers, since a metatype can't call those), else the Swift runtime's
metadata by mangled name.

## Checking documents

- `swift run RunwayIBCheck <dir>` loads documents without their app and
  reports what isn't read. The corpus's results are in
  [`Tools/corpus/ib-results.md`](../Tools/corpus/ib-results.md), which also
  lists the known gaps behind the remaining entries.
- `Tools/ib-fixture.sh` runs the storyboard app in `Examples/IBFixtureApp`
  under Xvfb and clicks through it.
