#!/usr/bin/env bash
# Measures Runway apps: memory, launch time, renders, idle CPU and wakeups.
#
#   Tools/measure.sh [options] [scenario…]
#
# Scenarios (default: gallery stress local):
#   gallery   Examples/RunwayGallery, idle after launch.
#   stress    Examples/RunwayStress: 2,000 rows, then RUNWAY_STRESS_KEYS
#             keystrokes (each a state change) into state owned by the view
#             holding the rows (every keystroke re-runs the list), then idle.
#   local     The same, typing into a search field view's own state.
#
# Options:
#   --runs N        runs per scenario, medians reported (default 3)
#   --keys N        keystrokes in the stress scenario (default 100)
#   --idle S        seconds of idle sampled for CPU/wakeups (default 5)
#   --debug         measure the debug build instead of release
#   --no-build      don't (re)build first
#   --env K=V       extra environment for the app (repeatable), e.g.
#                   --env GSK_RENDERER=gl
#   --tsv FILE      also append one TSV row per scenario to FILE
#
# Needs Xvfb (a private display is started); runs the binary directly so the
# PID measured is the app's. Numbers come from /proc: VmRSS (resident now),
# VmHWM (peak resident), RssAnon (heap and other private memory), RssFile
# (mapped files: libraries, fonts, icon caches; mostly shared with other
# processes), Pss (shared pages split among the processes using them), USS
# (private pages only: what quitting the app would free, the closest to a
# Mac's memory footprint), utime+stime over the idle window, and context switches summed
# over all threads (wakeups: 0 means truly idle), and poll() calls per
# second over 3 s via strace (a loop spinning without sleeping shows here).
# The app reports render
# counts and timings itself when RUNWAY_METRICS=1.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
runs=3 keys=100 idle=5 config=release build=1 tsv=""
extra_env=()
scenarios=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs) runs="$2"; shift 2 ;;
        --keys) keys="$2"; shift 2 ;;
        --idle) idle="$2"; shift 2 ;;
        --debug) config=debug; shift ;;
        --no-build) build=0; shift ;;
        --env) extra_env+=("$2"); shift 2 ;;
        --tsv) tsv="$2"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) scenarios+=("$1"); shift ;;
    esac
done
[[ ${#scenarios[@]} -eq 0 ]] && scenarios=(gallery stress local)

if command -v swift >/dev/null 2>&1; then :; else
    export PATH=/opt/swift/swift-6.4.2-RELEASE-ubuntu24.04/usr/bin:$PATH
fi
cd "$here"
if [[ $build == 1 ]]; then
    swift build -c "$config" --product RunwayGallery >/dev/null
    swift build -c "$config" --product RunwayStress >/dev/null
fi
bindir="$(swift build -c "$config" --show-bin-path)"

work="$(mktemp -d)"
display=":$((90 + RANDOM % 900))"
Xvfb "$display" -screen 0 1400x900x24 -nolisten tcp >/dev/null 2>&1 &
xvfb_pid=$!
trap 'kill $xvfb_pid 2>/dev/null || true; rm -rf "$work"' EXIT
for _ in $(seq 50); do [[ -e /tmp/.X11-unix/X${display#:} ]] && break; sleep 0.1; done

clk_tck=$(getconf CLK_TCK)

status_kb() { awk -v k="$2:" '$1 == k { print $2 }' "/proc/$1/status"; }
cpu_ticks() { awk '{ print $14 + $15 }' "/proc/$1/stat"; }
ctx_switches() {
    local total=0 t
    for t in /proc/"$1"/task/*/status; do
        total=$((total + $(awk '/^(voluntary|nonvoluntary)_ctxt_switches:/ { s += $2 } END { print s + 0 }' "$t" 2>/dev/null || echo 0)))
    done
    echo "$total"
}
wait_for() {   # file pattern timeout-seconds
    local i
    for i in $(seq $(($3 * 20))); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.05; done
    return 1
}
median() { sort -n | awk '{ a[NR] = $1 } END { if (NR == 0) print "-"; else if (NR % 2) print a[(NR + 1) / 2]; else printf "%.1f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2 }'; }

run_once() {   # scenario run-index -> prints "key value" lines
    local scenario=$1 log="$work/$1-$2.log" bin envs=()
    case "$scenario" in
        gallery) bin="$bindir/RunwayGallery" ;;
        stress) bin="$bindir/RunwayStress"; envs+=("RUNWAY_STRESS_KEYS=$keys") ;;
        local) bin="$bindir/RunwayStress"; envs+=("RUNWAY_STRESS_KEYS=$keys" "RUNWAY_STRESS_MODE=local") ;;
        *) echo "unknown scenario $scenario" >&2; exit 2 ;;
    esac
    local t0 pid
    t0=$(date +%s%3N)
    env DISPLAY="$display" RUNWAY_METRICS=1 NO_AT_BRIDGE="${NO_AT_BRIDGE:-}" ${envs[@]+"${envs[@]}"} ${extra_env[@]+"${extra_env[@]}"} "$bin" 2>"$log" >/dev/null &
    pid=$!
    if ! wait_for "$log" "runway-metrics first-frame" 60; then
        echo "no first frame from $scenario; log:" >&2; cat "$log" >&2; kill $pid 2>/dev/null; exit 1
    fi
    local first launch
    first=$(grep -m1 "runway-metrics first-frame" "$log" | sed 's/.*wall=//')
    launch=$(awk -v a="$first" -v b="$t0" 'BEGIN { printf "%.0f", a - b }')
    local renders_launch
    renders_launch=$(grep -c "runway-metrics render" "$log" || true)
    local stress_ms="-" per_key="-"
    if [[ $scenario == stress || $scenario == local ]]; then
        wait_for "$log" "runway-metrics stress-done" 600 || { echo "stress never finished" >&2; kill $pid; exit 1; }
        stress_ms=$(grep -m1 "stress-done" "$log" | sed 's/.* ms=//')
        per_key=$(awk -v a="$stress_ms" -v k="$keys" 'BEGIN { printf "%.2f", a / k }')
    fi
    sleep 1.5   # settle: let GTK finish frames and the allocator trim
    local renders_before c0 s0 c1 s1
    renders_before=$(grep -c "runway-metrics render" "$log" || true)
    c0=$(cpu_ticks $pid); s0=$(ctx_switches $pid)
    sleep "$idle"
    c1=$(cpu_ticks $pid); s1=$(ctx_switches $pid)
    # Main-loop iterations: poll()s that return at once don't show up as
    # context switches, so count them (all threads) with strace if present.
    local polls="-"
    if command -v strace >/dev/null 2>&1; then
        timeout 3 strace -f -c -p $pid -e trace=poll,ppoll,epoll_wait,epoll_pwait,select,pselect6 -o "$work/strace.txt" >/dev/null 2>&1 || true
        polls=$(awk '$NF == "total" { printf "%.1f", $4 / 3 }' "$work/strace.txt" 2>/dev/null)
        [[ -n $polls ]] || polls=0
    fi
    local renders_after
    renders_after=$(grep -c "runway-metrics render" "$log" || true)
    local last_render
    last_render=$(grep "runway-metrics render" "$log" | tail -1)
    echo "rss_mb $(awk -v k="$(status_kb $pid VmRSS)" 'BEGIN { printf "%.1f", k / 1024 }')"
    echo "hwm_mb $(awk -v k="$(status_kb $pid VmHWM)" 'BEGIN { printf "%.1f", k / 1024 }')"
    echo "anon_mb $(awk -v k="$(status_kb $pid RssAnon)" 'BEGIN { printf "%.1f", k / 1024 }')"
    echo "file_mb $(awk -v k="$(status_kb $pid RssFile)" 'BEGIN { printf "%.1f", k / 1024 }')"
    echo "pss_mb $(awk '$1 == "Pss:" { printf "%.1f", $2 / 1024 }' /proc/$pid/smaps_rollup)"
    echo "uss_mb $(awk '$1 == "Private_Clean:" || $1 == "Private_Dirty:" { s += $2 } END { printf "%.1f", s / 1024 }' /proc/$pid/smaps_rollup)"
    echo "threads $(status_kb $pid Threads)"
    echo "launch_ms $launch"
    echo "renders_launch $renders_launch"
    echo "renders_total $renders_after"
    echo "idle_renders $((renders_after - renders_before))"
    echo "idle_cpu_pct $(awk -v d=$((c1 - c0)) -v t="$clk_tck" -v s="$idle" 'BEGIN { printf "%.2f", 100 * d / t / s }')"
    echo "idle_polls_s $polls"
    echo "idle_wakeups_s $(awk -v d=$((s1 - s0)) -v s="$idle" 'BEGIN { printf "%.1f", d / s }')"
    echo "widgets $(sed -n 's/.*widgets=\([0-9]*\).*/\1/p' <<<"$last_render")"
    echo "last_render_ms $(sed -n 's/.* ms=\([0-9.]*\).*/\1/p' <<<"$last_render")"
    echo "stress_ms $stress_ms"
    echo "ms_per_key $per_key"
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
}

keys_order=(rss_mb hwm_mb anon_mb file_mb pss_mb uss_mb threads launch_ms renders_launch renders_total idle_renders idle_cpu_pct idle_wakeups_s idle_polls_s widgets last_render_ms stress_ms ms_per_key)
echo "Runway measure: $config build, $runs run(s), median; env: ${extra_env[*]:-(default)}"
for scenario in "${scenarios[@]}"; do
    for r in $(seq "$runs"); do run_once "$scenario" "$r" >"$work/$scenario-$r.out"; done
    printf '\n%s\n' "$scenario"
    row="$scenario"
    for k in "${keys_order[@]}"; do
        v=$(cat "$work/$scenario"-*.out | awk -v k="$k" '$1 == k { print $2 }' | { grep -v '^-$' || true; } | median)
        printf '  %-16s %s\n' "$k" "$v"
        row+=$'\t'"$v"
    done
    if [[ -n $tsv ]]; then
        [[ -s $tsv ]] || (IFS=$'\t'; echo "scenario	${keys_order[*]}" >"$tsv")
        echo "$row" >>"$tsv"
    fi
done
