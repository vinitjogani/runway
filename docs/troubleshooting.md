# Troubleshooting

**My app fails to compile with a missing Apple API.**
That's expected in alpha: Runway has no per-app porting code, so anything an
app uses that Runway doesn't map yet surfaces as a compile error naming the
missing API. Run `runway check <dir>` to see which imports and AppKit names
are covered, file by file. The fix belongs in Runway's modules; see
[CONTRIBUTING](../CONTRIBUTING.md). [Corpus status](corpus/status.md) lists
the first errors real apps hit today.

**The failure is in a dependency, not my app.**
Packages that import Apple frameworks are staged like the app, so their gaps
show up too. Objective-C dependencies can't compile here; Runway replaces
their headers with [stand-ins](project-import.md#objective-c-and-c-code) where
it can. Binary-only frameworks (Sparkle, Sentry, Firebase, PLCrashReporter)
are replaced by [shims](project-import.md#third-party-shims).

**Runway says my project is Tuist.**
Tuist projects aren't read. Run `tuist generate` on a Mac and point runway at
the generated project.

**It picked the wrong project or target.**
Use `--project <name|path>`, `--target <name>`, or `--platform ios` for the
iOS app in a mixed project. `runway plan <dir>` shows what was selected.

**A `runway` binary outside its checkout can't find Runway's modules.**
Set `RUNWAY_ROOT=/path/to/runway`.

**I have no display (CI, containers).**
Use `--headless` (or `RUNWAY_BACKEND=headless`), or run under Xvfb:
`xvfb-run -a dbus-run-session -- …`. Add `RUNWAY_SCREENSHOT=out.png` to
capture windows and quit.

**Under Xvfb, windows don't centre, move or minimise.**
Those are up to the window manager, and Xvfb has none. Sizes still hold.
See [window chrome](frameworks/native-mappings.md#window-chrome-on-linux).

**The menu isn't in my desktop's top bar.**
The global menu needs a host (Unity, KDE Plasma, or Xfce/MATE/Budgie with
their appmenu plugin) and X11. Stock GNOME has none, so the menu stays in
the window. `RUNWAY_GLOBAL_MENU=0` forces the in-window menu.

**My menu-bar app has no tray icon.**
Without a StatusNotifierItem host, status items show in a small window of
their own.

**Vector PDF images are missing from asset catalogs.**
Install Poppler (`pdftocairo`); Runway uses it to rasterize them.

**Rebuilding many apps is slow.**
Set `RUNWAY_SCRATCH_PATH=<dir>` so Runway's own modules compile once for all
staged apps.

**The iOS preview shows the wrong font.**
Install one of Open Sans, Noto Sans Display, Noto Sans or Liberation Sans,
or set `RUNWAY_IOS_SYSTEM_FONT`. See [iOS on Linux](ios.md#fonts).
