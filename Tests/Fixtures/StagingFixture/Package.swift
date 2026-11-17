// swift-tools-version:6.0
// A fixture for the runway tool: an app with an Info.plist, an asset
// catalog, a string catalog and .strings, and tests that find fixtures
// through #filePath. From runway/:
//   .build/debug/runway run  Tests/Fixtures/StagingFixture
//   .build/debug/runway test Tests/Fixtures/StagingFixture
import PackageDescription

let package = Package(
    name: "StagingFixture",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "FixtureKit", swiftSettings: [.define("FIXTURE_DEBUG", .when(configuration: .debug))]),
        .executableTarget(name: "FixtureApp", dependencies: ["FixtureKit"], resources: [.process("Resources")]),
        .testTarget(name: "FixtureKitTests", dependencies: ["FixtureKit"], exclude: ["fixture.txt"]),
    ]
)
