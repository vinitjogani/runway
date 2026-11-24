# Configuration

Runway needs no configuration file. These environment variables change how
staged apps run and how the build tool works.

## Running apps

| Variable | Effect |
|---|---|
| `RUNWAY_BACKEND=headless` | Run with no display (same as `--headless`) |
| `RUNWAY_COLOR_SCHEME=light\|dark` | Force the light or dark appearance |
| `RUNWAY_SCREENSHOT=out.png` | Render every window to PNG, then quit |
| `RUNWAY_SCREENSHOT_SCALE=<n>` | Capture scale for `RUNWAY_SCREENSHOT` (e.g. `3`) |
| `RUNWAY_STATUS_ITEM_CLICK=<n>` | Click the nth status item after launch, for screenshots |
| `RUNWAY_GLOBAL_MENU=0` | Keep the menu in the window even where a global menu bar exists |
| `RUNWAY_SYMBOLS_PATH=<dir>` | Override SF Symbols artwork with your own SVGs ([details](frameworks/native-mappings.md#symbols)) |
| `RUNWAY_WORD_VECTORS=<dir>` | fastText word vectors (`en.vec`…) for NaturalLanguage |
| `RUNWAY_METRICS=1` | The app reports render counts and timings |
| `RUNWAY_WIN32_MICA=full\|off` | Windows: Mica behind the whole window, or none |

## iOS previews

| Variable | Effect |
|---|---|
| `RUNWAY_IOS_SYSTEM_FONT=<family>` | Installed font family used as the system font |
| `RUNWAY_IOS_SYSTEM_FONT_FILES=<a:b:…>` | Local font files to register for the preview (Linux) |

See [iOS on Linux](ios.md).

## Build tool

| Variable | Effect |
|---|---|
| `RUNWAY_ROOT=/path/to/runway` | Where a `runway` binary copied out of its checkout finds Runway's modules |
| `RUNWAY_SCRATCH_PATH=<dir>` | Build every staged app in one SwiftPM build directory, so Runway's modules compile once |
| `RUNWAY_DEPS_MIRROR=<dir>` | Reuse local clones of package dependencies, named `<owner>__<repo>` |
| `RUNWAY_CORPUS_DIR=<dir>` | Where the corpus scripts keep app clones (default `~/.cache/runway-corpus/apps`) |
