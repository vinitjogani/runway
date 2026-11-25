# Native mappings

What each Apple API is backed by on each platform. "(to do)" marks gaps.

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
| `NSTextView` / TextKit 1 | GtkTextView (see [below](#text-views)) | plain multi-line text |
| NSView input, `NSCursor`, `registerForDraggedTypes` | GTK event controllers, CSS cursors, GtkDropTarget | key/mouse via the window |
| `NSApp.mainMenu`, `NSMenu.popUp` | GtkPopoverMenuBar per window, in its titlebar row; GtkPopoverMenu | key equivalents |
| Titlebar, `NSToolbar`, full-size content | client-side titlebar row (traffic lights, menu bar, title) and a toolbar band; safe areas | (to do) |
| `NSScreen` | GDK monitors | one screen |

For the Windows backend's controls, look and services in detail, see the
[Win32 backend README](../../Sources/RunwayWin32/README.md).

## Text views

`NSTextView` and TextKit 1 (`NSTextStorage`, `NSLayoutManager` and its
delegate) are backed on Linux by a GtkTextView that lays out and draws the
storage as tags:

- null glyphs are invisible, and whitespace control glyphs are spacers;
- the delegate's paragraph spacing and temporary attributes apply;
- `drawBackground` and `draw(_:)` run as snapshot layers under and over the
  text;
- keys, typing (input method), clicks, selection, undo and the pasteboard go
  through AppKit's methods.

## Window chrome on Linux

A Mac window's titlebar holds the traffic lights, the title and (unified)
the toolbar, and the menu bar is at the top of the screen. On Linux each
titled window draws its own titlebar row, the same under any window manager
or none:

- the traffic lights at the leading edge;
- the menu bar beside them, with the app's name in bold, as on the Mac;
- the title, centred, when no toolbar shows it.

A visible toolbar adds a band below that row (38 pt for `.unifiedCompact`,
46 pt for unified) with the title, subtitle and items, lined up with split
views at the sidebar and inspector tracking separators.

With `.fullSizeContentView` the content runs under the band, as on the Mac:

- the band is the content's safe-area top inset (`safeAreaInsets`,
  `safeAreaRect` and `safeAreaLayoutGuide` follow it down the view tree);
- `contentLayoutRect` leaves it out;
- scroll views that adjust their insets automatically start below it;
- clicking its empty parts reaches the content (controls, and views whose
  `mouseDownCanMoveWindow` is false) or drags the window.

Otherwise the band sits above the content on the titlebar's material. Sheets
have no titlebar.

Some behaviour is up to the window manager, so it doesn't happen under Xvfb,
which has none: where a window opens (`center()`, `cascadeTopLeft`, frame
origins), moving it (`performDrag`), minimising, and the minimum size it
enforces while the user resizes. Sizes (`setContentSize`, `minSize`, frame
autosave) are the toolkit's and hold everywhere.

### Global menu bar

Where the desktop has a global menu bar, the menu goes there, as on the Mac.
That covers Unity, KDE Plasma, and Xfce, MATE or Budgie with their appmenu
plugin.

- Each window exports its menu as `com.canonical.dbusmenu` and registers with
  `com.canonical.AppMenu.Registrar`. KDE also gets the
  `_KDE_NET_WM_APPMENU_*` window properties.
- The exported menu is the same `GMenuModel` and actions the in-window bar
  uses. Shortcuts, separators, checkmarks and enabled states carry over, and
  menus validate as they open.
- While a host is present, the titlebar row drops the menu. A window with a
  toolbar loses the row entirely.
- In a window with a toolbar and full-size content, the traffic lights always
  float at the leading edge of the toolbar band, as on a Mac with a unified
  toolbar, where such apps leave room for them. Without a global menu host the
  row above keeps only the in-window menu bar. `standardWindowButton(_:)`
  returns their frames.
- The host is watched, so the in-window bar comes back if the host goes
  away. Stock GNOME, Ubuntu's default included, has no global menu, so the
  in-window bar stays there.
- This currently needs X11, since the registrar names windows by X11 id.
  `RUNWAY_GLOBAL_MENU=0` turns it off.

### Menu-bar apps

`NSStatusItem` (and SwiftUI's `MenuBarExtra`) is a tray item where the
desktop has a StatusNotifierItem host. Where it has none, the app's status
items show in a small window of their own, so the app stays reachable.
`RUNWAY_STATUS_ITEM_CLICK=n` clicks the nth one after launch, for
screenshots.

## Symbols

SF Symbols names (`NSImage(systemSymbolName:)`, `Image(systemName:)`) are
drawn as open line art from [Lucide](https://lucide.dev) (ISC licence).
Lucide uses SF's rounded strokes on a 24-unit grid. The table is in
`Sources/RunwayCore/SymbolArt+Table.swift`, generated by
`Tools/symbols/generate.py`.

- The variants `.fill`, `.circle`, `.circle.fill`, `.square` and `.slash` are
  composed as SF composes them.
- On GTK each symbol is a `GtkSymbolicPaintable`, drawn in the widget's CSS
  colour, so tints, hover, disabled states and dark mode follow the theme.
- Names with no art fall back to the Adwaita icon theme.
- On Windows, symbols map to Segoe Fluent Icons / Segoe MDL2 Assets glyphs.

To use your own artwork in previews, set `RUNWAY_SYMBOLS_PATH` to a local
directory of SVG icons you have rights to use. Name each icon after the exact
symbol with a `.svg` extension, such as `waveform.path.ecg.svg`, and use a
transparent, standalone SVG with a square view box. GTK scales and tints its
silhouette with the control. A missing or unreadable override uses Runway's
built-in artwork.
