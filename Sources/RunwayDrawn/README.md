# RunwayWin32

The Windows backend: `Win32Backend: Backend`. It runs unchanged SwiftUI apps
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

## Verification

This module has not been compiled with Swift for Windows here. No Windows
Swift SDK can be installed for cross-compilation on Linux, and `WinSDK` needs
Microsoft's SDK headers. What was checked:

- `Native/*.cpp` compile warning-free with Clang and GCC (C++14) against the
  mingw-w64 Windows headers. They also link into a Windows executable, where
  every Win32/D2D/DWrite/Shell import resolves.
- That executable runs under Wine. Tests cover the window, DPI scale, Direct2D
  drawing (checked by reading back pixels and a screenshot), DirectWrite
  measurement (wrapping, line limits, truncation), EDIT text and line-break
  round trips, clipboard text and files, and key mapping.
- The Swift files type-check against `RunwayCore` and the C header. They were
  also run on Linux over a recording stub of the C API, driving the Runway
  Gallery: painting, clicks, typing and submit, pop-up and segmented pickers,
  sheets, alerts, the slider, switch animation, wheel scrolling, resize, ⌘Q,
  and dark mode.

## Known gaps

No accessibility tree (UI Automation) for the custom-drawn controls, no
tooltips, no keyboard focus for non-text controls (Tab moves between text
fields, as on the Mac by default), no text selection in `Text`, and no drag and
drop. The EDIT font is GDI Segoe UI rather than Segoe UI Variable.
