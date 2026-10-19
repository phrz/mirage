#!/bin/sh
# Sleep durability (DESIGN §4a, "like mosh"): a headless viewer is frozen with SIGSTOP for N seconds, as a closed lid
# would freeze it, then continued; it must come back to the *same* session (resume token) with the host's caches intact
# (a masked keyframe and diffs, not a fresh picture). Watch-only: nothing is injected.
#
#   scripts/sleep-test.sh HOST [PORT] SECONDS...    e.g. scripts/sleep-test.sh mac-daddy 7799 60 600 3600
#
# Per run: resumes/reconnects and resume-to-picture from the viewer's --stats JSON, and the host's verdict from its log
# when the host is reachable over SSH (HOST's ~/Library/Logs/mirage-host.log, or ./host.log for localhost runs: HOSTLOG=).
set -u
cd "$(dirname "$0")/.."
H=$1; shift; P=7799
case "${1:-}" in 7[0-9][0-9][0-9]) P=$1; shift;; esac
OUT=${OUT:-/tmp/mirage-sleep}; mkdir -p "$OUT"
V=${VIEWER:-.build/release/mirage-viewer}
for N in "$@"; do
    R="$OUT/stop-$N"; mkdir -p "$R"
    "$V" "$H" --port "$P" --headless --duration $((N + 75)) --bitrate 800 --window 1512x982 --stats "$R/stats.json" > "$R/viewer.out" 2> "$R/viewer.log" &
    VP=$!
    trap 'kill -CONT $VP 2>/dev/null; kill $VP 2>/dev/null' EXIT INT TERM
    sleep 20
    T0=$(date -u +%H:%M:%S); kill -STOP $VP; echo "stopped the viewer for $N s at ${T0}Z"
    sleep "$N"; kill -CONT $VP; echo "continued at $(date -u +%H:%M:%S)Z"
    wait $VP
    python3 - "$R/stats.json" "$N" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); n=sys.argv[2]
ok=d.get('resumes',0)>=1 and d.get('reconnects',0)==0
print(f"stop {n} s: resumes {d.get('resumes')} reconnects {d.get('reconnects')} resume-to-picture {d.get('resumeToPictureMs')} ms -> {'PASS (same session)' if ok else 'FAIL'}")
PY
    if [ -n "${HOSTLOG:-}" ]; then grep -E "suspended|resumed after|resuming its session|fresh picture|caches shed" "$HOSTLOG" | tail -4
    elif [ "$H" != localhost ]; then ssh "$H" 'grep -E "suspended|resumed after|resuming its session|caches shed" ~/Library/Logs/mirage-host.log | tail -4'; fi
done
