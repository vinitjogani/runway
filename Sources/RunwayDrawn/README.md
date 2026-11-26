# RunwayDrawn

The drawn backend: `DrawnBackend: Backend` (`Win32Backend` is an alias). It runs unchanged SwiftUI apps
on Windows 10 (1703+) and 11, with controls drawn to look like the Mac's rather
than like Win32 common controls.

## Design

- **Lightweight widgets.** Each widget is a Swift object (`W32Widget`) in its
  window's tree. There is no HWND per control. A window paints its tree with
  Direct2D and hit-tests it itself, so controls can be rounded, antialiased,
  translucent, and accent-filled, and they sit exactly where SwiftUI's layout
  puts them.
- **Native text input.** Text fields and editors are real `EDIT` controls
  (Common Controls 6, activated at start-up without an exe manifest). Each is
  placed over a custom-drawn field with a Mac-style accent focus ring, and
  clipped to its scroll view. This keeps IME, selection, undo, the clipboard
  and accessibility native.
- **Two halves.** The Swift half (`*.swift`) owns the widget tree, layout of
  chrome, input and the look. `Native/` is a flat C API (`runway_win32.h`)
  implemented in C++ over Win32, Direct2D, DirectWrite, WIC, DWM and the
  Shell. The C API keeps COM and Windows types out of Swift.
- **Look.** Push buttons (22 px, radius 6, soft shadow, hairline border;
  default/prominent buttons get an accent gradient, #007AFF light / #0A84FF
  dark); switches with an animated knob; checkboxes; segmented controls with a
  raised selected pill; pop-up buttons with the accent chevron square (menu via
  `TrackPopupMenuEx`); pull-down menu buttons; sliders; linear and spinning
  progress; steppers; links; colour wells (`ChooseColorW`); overlay scroll
  bars. Text uses DirectWrite with Segoe UI Variable (or Segoe UI) at 13 px,
  styled runs, alignment, line limits, and head/middle/tail truncation. SF
  Symbols map to Segoe Fluent Icons / Segoe MDL2 Assets glyphs
  (`Win32Symbols.swift`). Canvases run `DrawCommand`s: fills and strokes,
  dashes, rounded rects, ellipses, paths, and linear/radial gradients.
- **Windows.** Per-monitor DPI awareness (v2), the immersive dark title bar,
  and Mica behind the title bar on Windows 11. Set `RUNWAY_WIN32_MICA=full` to
  put Mica behind the whole window, or `off` to disable it. Light/dark follows
  `AppsUseLightTheme` live. Ctrl maps to ⌘ in `KeyPress`. The message loop
  also drains libdispatch's main queue, so `Task { @MainActor … }` works.
  `schedule` posts one message; an idle window runs no timers.
- **Services.** Clipboard (`CF_UNICODETEXT`, `CF_HDROP` + Preferred
  DropEffect), `ShellExecuteW`, `SHOpenFolderAndSelectItems`, `PlaySoundW`
  (macOS sound names mapped to Windows events), `IFileOpenDialog` /
  `IFileSaveDialog`, and alerts drawn as Mac-style modal windows.

## One backend, two platforms

The Swift half never touches platform types: it speaks the flat C API in
`Native/include/runway_drawn.h`. That API has two bindings:

- `Native/win32/` — Win32, Direct2D, DirectWrite, WIC, DWM, OLE and the Shell
  (C++). The default backend on Windows.
- `Native/gtk/` — GTK 4, Cairo and Pango (C): windows with a drawing area,
  native `GtkText`/`GtkTextView` children for text input in clipping
  containers, popovers for popups, GMenu menu bars and context menus. Opt-in
  on Linux with `RUNWAY_BACKEND=drawn`; RunwayGTK stays the default there
  until the drawn backend has reached parity.

So controls, layout, input routing and AppKit's view system (raw window
events, monitors, menus, cursors, drag and drop, popovers, rich text views
with layers, CGDisplayList replay) are written once.

Fonts: Inter (for San Francisco) and JetBrains Mono (for SF Mono and Menlo),
under the SIL Open Font License, are compiled into every app (CRunwayFonts)
and registered at start; `RUNWAY_SYSTEM_FONTS=1` uses the desktop's fonts.
SF Symbols are drawn from Runway's vector art (`SymbolPaths`), not fonts.

## Verification

The backend is cross-compiled with the Swift 6.4 Windows SDK (SwiftPM's
native build system, Microsoft's SDK and CRT via xwin) and run under Wine 9:
the Runway Gallery and Merge, including its inbox, diffs, inline comments
(RichEdit composer with drawn placeholders), popovers, the native menu bar,
settings, the agent panel and its model picker. On Linux the GTK binding runs
the same apps under Xvfb. `RUNWAY_DEBUG_INPUT=1` logs how presses are routed;
Ctrl+Shift+F12 dumps a window's widget tree to stderr.

## Accessibility

The widget tree is turned into an accessibility tree by RunwayCore's
`AccessibilityTree`, which follows SwiftUI's rules: controls are elements with
a role, a name, a value and states; layout containers are transparent; what
SwiftUI's accessibility modifiers declare renames, hides, combines or groups.
The tree is built only once an assistive technology asks for it, and is sent
to the platform layer as a flat `rw_a11y_node` list with stable ids:

- **Windows:** a UI Automation provider per element (`Native/win32/rw_a11y.cpp`),
  with control types, names, help text, states, hit testing, navigation,
  focus, and the Invoke, Toggle, Value, RangeValue and SelectionItem
  patterns. The window answers `WM_GETOBJECT` with the root.
- **Linux:** an invisible, click-through widget per element
  (`Native/gtk/rw_gtk_a11y.c`) with its role, label, description, value and
  states, so GTK exposes it over AT-SPI. Its actions are installed widget
  actions (`a11y.default`, `a11y.increment`, ...).

Actions, new values and focus requests come back as `RW_EV_A11Y_*` events.
`RUNWAY_A11Y=0` turns the tree off on Linux (`=1` forces it without an
accessibility bus). `RUNWAY_A11Y_INVOKE=<name>` invokes an element once on
Windows, through the provider interfaces (diagnostics).

## Known gaps

No keyboard focus for non-text controls (Tab moves between text fields, as
on the Mac by default), no text selection in `Text`, and no dragging out of
the app (drops in work). GTK 4 can't place windows on Wayland (`setPosition`
works on X11).
