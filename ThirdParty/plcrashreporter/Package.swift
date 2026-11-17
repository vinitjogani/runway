// swift-tools-version:5.9
// Runway's stand-in for PLCrashReporter (github.com/microsoft/plcrashreporter),
// an Objective-C/C crash reporter built on Mach exception handling. Same
// identity, product and module (CrashReporter); it never has a pending
// report, so apps' crash-log flows stay idle.
import PackageDescription

let package = Package(
    name: "CrashReporter",
    products: [.library(name: "CrashReporter", targets: ["CrashReporter"])],
    targets: [.target(name: "CrashReporter")]
)
