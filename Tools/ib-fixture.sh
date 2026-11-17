#!/bin/sh
# End to end: the storyboard app (Examples/IBFixtureApp) launched under Xvfb
# from Info.plist's NSMainStoryboardFile, clicked through with xdotool (real
# X events: buttons, a checkbox, a key equivalent, a sheet segue), then
# screenshotted.
#
#   Tools/ib-fixture.sh [out.png]      (from runway/, after `swift build --product IBFixtureApp`)
#
# Inside the X session (xvfb-run) it runs itself with --inside.
set -e
if [ "$1" = "--inside" ]; then
    out="$2"
    RUNWAY_SCREENSHOT="$out" RUNWAY_SCREENSHOT_DELAY=9000 .build/debug/IBFixtureApp > "$out.log" 2>&1 &
    app=$!
    sleep 3
    wid=$(xdotool search --sync --name "IB Fixture" | head -1)
    click() { xdotool mousemove --window "$wid" "$1" "$2" click 1; sleep 0.4; }
    click 65 94      # Increment (target: the view controller)
    click 65 94      # Increment
    click 30 128     # "Count by ten" checkbox
    click 65 94      # Increment: +10
    click 150 94     # Reset (target: First Responder, through the responder chain)
    click 65 94      # Increment: +10
    xdotool key --window "$wid" ctrl+i   # Counter ▸ Increment (⌘I), nil-targeted
    sleep 0.5
    click 440 194    # Details… (a sheet segue; prepare(for:sender:))
    wait $app || true
    exit 0
fi
out="${1:-/tmp/ib-fixture.png}"
cp Examples/IBFixtureApp/Resources/Info.plist .build/debug/Info.plist
timeout 60 xvfb-run -a -s "-screen 0 1280x800x24" "$0" --inside "$out"
grep -v "dbus\|suspend thread" "$out.log"
