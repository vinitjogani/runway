// End to end: the fixtures are transpiled at build time (the
// RunwayTranspileFixtures plugin), compiled against Runway's AppKit and
// RunwayObjC, and run here, checking that dispatch reaches the methods.

import XCTest

final class RuntimeTests: XCTestCase {
    func testFoundationRuntime() {
        var log = runFoundationFixture()
        // The run loop's timers: their relative order is up to timing.
        let timed = log.suffix(3).sorted()
        log.removeLast(min(3, log.count))
        XCTAssertEqual(timed, ["later kept", "tick 1 info", "tick 2 info"])
        XCTAssertEqual(log, [
            "ping",
            "hello bob",
            "sum 5",
            "responds ping=true nope=false",
            "job responds jobDidFinish=true jobShouldRetry=false",
            "delegate: finished job",
            "retry=unimplemented",
            "note JobNote first",
            "observe progress 0.0 -> 0.5",
            "kvo progress 0.0 -> 0.5",
            "observe owner.name Optional(\"ann\")",
            "observe owner.name Optional(\"cy\")",
            "observe progress 0.5 -> 1.0",
            "kvc label=renamed owner.name=cy",
            "observe progress 1.0 -> 0.25",
        ])
    }

    @MainActor func testAppKitTargetAction() throws {
        let log = try runAppKitFixture()
        XCTAssertEqual(log, [
            "enabled Save=true Revert=false Close=true",
            "sent save: true",
            "sent click: true",
            "enabled Save=true Revert=true Close=true",
            "sent revert: true",
            "sent close: true closed=true",
            "unknown: false",
            "save from Save",
            "dirty false -> false",   // KVO reports every set, as on the Mac
            "button clicked",
            "dirty false -> true",
            "revert",
            "autosave draft",
        ])
    }

    /// Overrides declared in an extension in another file, moved into the
    /// class body, are what AppKit dispatches to; #filePath/#line still name
    /// where they were written.
    @MainActor func testOverridesFromAnExtensionInAnotherFile() {
        XCTAssertEqual(runViewFixture(), [
            "hit canvas true",
            "flipped true",
            "canvas down 1 at ViewFixtureOverrides.swiftfixture:11",
            "canvas down 1 at ViewFixtureOverrides.swiftfixture:11",
            "draw canvas 100x50 strokes=2",
        ])
    }
}
