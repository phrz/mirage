#!/bin/sh
# Loopback assertion for lossy-first refinement on a static picture (DESIGN §3.3b): a fresh stream
# against a screen that never changes must climb the ladder and finish its lossless blocks within
# a few seconds. Needs a local host (miraged serve --port 7800, screen recording granted) and an
# awake display; covers the screen with the test bench in --static mode for the run.
# Usage: scripts/test-static-picture.sh [KBPS] [SECONDS]   (default 800 kbps, 15 s)
set -e
cd "$(dirname "$0")/.."
KBPS=${1:-800}; SECS=${2:-15}
LOG=${MIRAGE_HOST_LOG:-/tmp/mirage-static-host.log}
OUT=/tmp/mirage-static.json
pkill -x MirageTestBench 2>/dev/null || true
pkill -f "miraged serve --port 7800" 2>/dev/null || true
sleep 1
nohup .build/release/miraged serve --port 7800 > "$LOG" 2>&1 &
HOSTPID=$!
nohup .build/MirageTestBench.app/Contents/MacOS/MirageTestBench --static > /dev/null 2>&1 &
BENCHPID=$!
sleep 3
.build/release/mirage-viewer localhost --port 7800 --headless --duration "$SECS" --bitrate "$KBPS" --window 3024x1964 --stats "$OUT" > /tmp/mirage-static-viewer.log 2>&1 || true
kill $BENCHPID 2>/dev/null || true
kill $HOSTPID 2>/dev/null || true
COMPLETE=$(grep -c "fresh picture: complete" "$LOG" || true)
TOP=$(grep -o "fresh picture: rung [0-9] is the top" "$LOG" | tail -1)
FINAL=$(python3 -c "import json; j=json.load(open('$OUT')); print(j.get('rungFinal'))" 2>/dev/null || echo "?")
echo "static picture @ ${KBPS} kbps for ${SECS} s: lossless blocks complete=${COMPLETE} (${TOP}), viewer's final rung=${FINAL}"
grep -E "fresh picture|keyframe" "$LOG" | sed 's/^.\{24\}//' | head -12
if [ "$COMPLETE" -lt 1 ]; then echo "FAIL: the picture did not finish refining"; exit 1; fi
echo PASS
