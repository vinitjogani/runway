// The app's sources are the .swiftfixture files beside this one, which the
// RunwayTranspileFixtures plugin transpiles at build time (as `runway`
// does when it stages an app), plus the class table it generates for them.
//
// Running it: Info.plist goes next to the executable (as `runway build`
// installs it), then
//
//     cp Examples/IBFixtureApp/Resources/Info.plist .build/debug/
//     RUNWAY_SCREENSHOT=/tmp/ib.png xvfb-run -a .build/debug/IBFixtureApp
//
// Tools/ib-fixture.sh does that and clicks through the window.
