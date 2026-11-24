<p align="center"><img src="brand/logo.svg" width="96" alt="Runway logo"></p>

# Runway

**Build Apple app sources on Linux and Windows.**

Runway lets you build and run an existing SwiftUI or AppKit Mac app on other
platforms without changing its sources. It provides:

- drop-in `SwiftUI` and `AppKit` modules, implemented over each platform's
  native toolkit (GTK 4 on Linux, Win32 on Windows);
- shims for the Apple frameworks apps lean on (CoreGraphics, ImageIO,
  UniformTypeIdentifiers, Security, and many more);
- a zero-configuration build tool, `runway`, that reads your Xcode project or
  Swift package and stages it against those modules.

It can also build supported iOS SwiftUI apps and preview them on Linux.

## Status

Runway is **alpha**. Expect gaps, and expect APIs that are missing or not
mapped yet.

| Target | Status |
|---|---|
| macOS apps on Linux (GTK 4) | Working: the main target |
| iOS SwiftUI apps previewed on Linux | Alpha |
| macOS apps on Windows (Win32) | In progress: the backend has not been compiled with Swift for Windows yet ([details](Sources/RunwayWin32/README.md)) |

On macOS there's nothing to do: apps build with Apple's own frameworks.

See [corpus status](docs/corpus/status.md) for how real open-source Mac apps
fare today.

## Requirements

- A Swift 6.2+ toolchain for Linux or Windows ([swift.org](https://swift.org/install)).
- On Linux, GTK 4.12+ and a few system libraries, for example on Debian or Ubuntu:

  ```sh
  sudo apt install libgtk-4-dev zlib1g-dev libgdk-pixbuf-2.0-dev libglib2.0-dev \
    libpango1.0-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libwebkitgtk-6.0-dev
  ```

- Optional: Xvfb for running apps without a display, and Poppler's
  `pdftocairo` for rasterizing vector PDFs in asset catalogs.

## Quick start

Clone Runway next to the app you want to build, then build the tool:

```sh
git clone https://github.com/vinitjogani/runway
cd runway
swift build --product runway
```

Point it at a Mac app's folder (an Xcode project, workspace, XcodeGen spec or
Swift package):

```sh
.build/debug/runway check ../my-macos-app   # which imports and AppKit names are covered
.build/debug/runway plan  ../my-macos-app   # the targets, files, resources and settings it found
.build/debug/runway build ../my-macos-app
.build/debug/runway run   ../my-macos-app
.build/debug/runway test  ../my-macos-app
```

For an iOS app, add `--platform ios`:

```sh
.build/debug/runway run ../my-ios-app --platform ios --device iphone-pro
```

Or try a plain SwiftUI app that ships with Runway:

```sh
swift run RunwayGallery
```

Nothing in your app's folder is written. There is no per-app porting code:
anything your app uses that Runway doesn't map yet fails to compile as a
missing Apple API.

## Documentation

| Topic | |
|---|---|
| [Architecture](docs/architecture.md) | How the modules, layout engine and backends fit together; source layout |
| [Native mappings](docs/frameworks/native-mappings.md) | What each Apple API maps to on Linux and Windows; window chrome, menus, symbols |
| [Project import and staging](docs/project-import.md) | The `runway` tool: project formats, Xcode import, package dependencies, Objective-C stand-ins, third-party shims |
| [Interface Builder](docs/interface-builder.md) | Loading `.xib` and `.storyboard` files at run time |
| [iOS on Linux](docs/ios.md) | Building and previewing iOS SwiftUI apps |
| [Configuration](docs/configuration.md) | Environment variables |
| [Troubleshooting](docs/troubleshooting.md) | Common problems and what to do |
| [Corpus status](docs/corpus/status.md) | Results on real open-source Mac apps |
| [Windows backend](Sources/RunwayWin32/README.md) | Design and verification of the Win32 backend |

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to
build, test and where fixes belong.

## License

A license has not been chosen yet. Until one is added, no license is granted
to use, copy or distribute this code. Bundled third-party material keeps its
own license: SF Symbols stand-in artwork comes from
[Lucide](https://lucide.dev) (ISC; portions from Feather, MIT).
