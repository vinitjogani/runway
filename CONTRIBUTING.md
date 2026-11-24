# Contributing to Runway

Thanks for your interest. Runway is alpha, so bug reports with a small
reproduction, and fixes for missing Apple APIs, are the most useful
contributions.

## Building and testing

You need the toolchain and libraries listed in the
[README](README.md#requirements).

```sh
swift build                  # everything
swift build --product runway # just the build tool
swift test                   # the test suites run headless; no display needed
swift test --filter RunwayToolTests
```

Sample apps to try changes on:

```sh
swift run RunwayGallery       # a plain SwiftUI app
swift run AppKitDemo
swift run AppKitControlsDemo
```

Useful tools:

- `Tools/measure.sh`: memory, launch time, renders, idle CPU and wakeups of
  the sample apps (needs Xvfb).
- `Tools/ib-fixture.sh`: runs `Examples/IBFixtureApp` from its storyboard
  under Xvfb and clicks through it.
- `Tools/corpus/`: measures Runway against real open-source Mac apps (see
  [corpus status](docs/corpus/status.md)).
- `Tools/symbols/generate.py`: regenerates the SF Symbols table from Lucide.

## Where fixes belong

Runway has no per-app porting code, and `runway` takes no per-app
configuration. When an app fails to build because an Apple API is missing,
the fix is to add or complete that API in Runway's module of the same name
(`Sources/AppKit`, `Sources/SwiftUI`, `Sources/<Framework>`), not to change
the app.

- Layout is computed above the backends and must stay identical on every
  platform; backends only create, measure and place widgets. See
  [architecture](docs/architecture.md).
- Add tests next to the area you change (`Tests/RunwayTests` for SwiftUI,
  `Tests/AppKitTests`, `Tests/FrameworkTests`, `Tests/RunwayToolTests` for
  the importers). They run against the headless backend.
- Windows changes can't be compiled with Swift for Windows on Linux yet; see
  how the backend is verified in its
  [README](Sources/RunwayWin32/README.md#verification).

## Website and brand

[`site/`](site) is Runway's one-page website (static HTML, built with Vite):

```sh
cd site
npm install
npm run dev     # http://localhost:5173
npm run build   # site/dist, deploy anywhere static
```

In production it runs from [`docker-compose.yml`](docker-compose.yml) (the
Vite build served by nginx on port 80), deployed on Dokploy at runway.vj.ms.
The logo, colours and type are described in [`brand/`](brand/README.md).

## Pull requests

- Keep each pull request to one change, with a test where you can.
- Describe what an app could not do before and can do now.
- Update the docs in [`docs/`](docs) when behaviour or options change.
- In running text, the name is always "Runway".

## License

The project has not chosen a license yet. Please hold off on substantial
contributions until one is added.
