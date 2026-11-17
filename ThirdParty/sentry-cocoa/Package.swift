// swift-tools-version:5.9
// Runway's stand-in for sentry-cocoa (github.com/getsentry/sentry-cocoa),
// whose Swift package is a prebuilt Apple-only xcframework. Same identity,
// product and module (Sentry); the SDK starts disabled and sends nothing.
import PackageDescription

let package = Package(
    name: "Sentry",
    products: [
        .library(name: "Sentry", targets: ["Sentry"]),
        .library(name: "Sentry-Dynamic", targets: ["Sentry"]),
        .library(name: "SentrySwiftUI", targets: ["Sentry"]),
    ],
    targets: [.target(name: "Sentry")]
)
