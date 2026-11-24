# iOS apps on Linux (alpha)

Runway can build supported iOS SwiftUI apps with the Linux Swift toolchain
and preview them with GTK. These builds produce Linux executables: they are
for previewing and testing, not a replacement for Xcode.

## Quick start

Point Runway at an iOS Xcode project, workspace or XcodeGen spec. For
example, from a Runway checkout next to your iOS app:

```sh
swift build --product runway
.build/debug/runway plan  ../my-ios-app --platform ios
.build/debug/runway build ../my-ios-app --platform ios
.build/debug/runway run   ../my-ios-app --platform ios --device iphone-pro
.build/debug/runway test  ../my-ios-app/Packages/MyAppCore
```

`--platform ios` selects the iOS app in a mixed project; Runway otherwise
prefers the macOS app.

In a cloud container, keep the Runway checkout alongside the binary. A
binary copied elsewhere can find the compatibility modules through
`RUNWAY_ROOT=/path/to/runway`.

## Devices

| `--device` | Viewport (points) | Horizontal size class |
|---|---|---|
| `iphone-pro` (default) | 402 × 874 | compact |
| `iphone` | 393 × 852 | compact |
| `ipad` | 820 × 1180 | regular |

The iPhone Pro profile reserves 62 points above the navigation bar, uses
44-point toolbar controls, and places a 64-point floating tab bar 20 points
from the sides and bottom. The app can specify its own window size.

## Headless runs and screenshots

`--headless` runs the app without a display. `RUNWAY_SCREENSHOT` captures a
GTK window to PNG and exits. In a container, use an existing X display or
Xvfb:

```sh
xvfb-run -a dbus-run-session -- env RUNWAY_SCREENSHOT=/tmp/runway-ios-preview.png \
  .build/debug/runway run ../my-ios-app --platform ios --device iphone-pro
```

Set `RUNWAY_SCREENSHOT_SCALE=3` for a 1206 × 2622 PNG from the iPhone Pro
profile. The GTK renderer draws at the capture scale and the layout keeps the
same 402 × 874 logical points.

## Rendering

On GTK, the floating tab bar and toolbar capsules blur the content behind
them. A translucent tint and a single shaded rim give each capsule depth.
Text, icons and controls are drawn above the glass at their usual size.

### Fonts

GTK previews prefer Open Sans when available, followed by Noto Sans Display,
Noto Sans and Liberation Sans.

- `RUNWAY_IOS_SYSTEM_FONT` selects an installed family by name.
- `RUNWAY_IOS_SYSTEM_FONT_FILES` registers colon-separated paths to local
  font files for the preview process (Linux). Use faces from the same family
  for regular, varied weights, and italic text.

Runway loads the app's custom fonts from its bundle.

## Conditional compilation

Runway enables `#if os(iOS)` branches in staged iOS app sources and their
staged packages. Host checks such as `os(Linux)` still reflect the host
toolchain.

`--ios-simulator-code` also enables `targetEnvironment(simulator)` branches,
for apps with debug fixtures. Pass arguments to your app after `--`:

```sh
.build/debug/runway run ../my-ios-app --platform ios --ios-simulator-code -- --show-preview
```

## Limits

Use Xcode or an iOS device to verify Apple SDK compilation, UIKit rendering,
extensions, device behaviour and signing.

- Live Activity requests and system background scheduling report
  unavailability in the preview.
- Background URL sessions can transfer files while the app is running.
