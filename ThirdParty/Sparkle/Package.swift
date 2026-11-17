// swift-tools-version:5.9
// Runway's stand-in for Sparkle (github.com/sparkle-project/Sparkle), which
// ships as a macOS-only binary xcframework. Same package identity
// ("sparkle"), product and module name, and the API apps use; updates are
// reported unavailable: `canCheckForUpdates` is false and checks do nothing.
// Written like Mac code (@objc, dynamic): `runway` stages it through the
// transpiler like any other dependency, so KVO and #selector work.
import PackageDescription

let package = Package(
    name: "Sparkle",
    products: [.library(name: "Sparkle", targets: ["Sparkle"])],
    targets: [.target(name: "Sparkle")]
)
