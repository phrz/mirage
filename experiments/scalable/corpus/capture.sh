#!/bin/sh
# Builds the Test Bench and captures its scene windows through the window server at 2x
# (`screencapture -l WINDOW -o`: that one window, no shadow, nothing else on the screen).
# Needs Screen Recording for the calling app already granted (checked first, never prompted for).
# Usage: corpus/capture.sh OUTDIR
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../../.."
OUT="${1:-$HERE/out}"
mkdir -p "$OUT" "$HERE/../.build"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.0-Beta.app/Contents/Developer}"
sh "$ROOT/experiments/testbench/make.sh" >/dev/null
swiftc -O -o "$HERE/../.build/winid" "$HERE/winid.swift"
printf 'import CoreGraphics\nexit(CGPreflightScreenCaptureAccess() ? 0 : 1)\n' > "$HERE/../.build/preflight.swift"
swiftc -O -o "$HERE/../.build/preflight" "$HERE/../.build/preflight.swift"
"$HERE/../.build/preflight" || { echo "no Screen Recording access; not capturing (render offscreen instead)"; exit 1; }
BIN="$ROOT/.build/MirageTestBench.app/Contents/MacOS/MirageTestBench"
for spec in text text:dark terminal vibrancy vibrancy:dark controls controls:dark mixed mixed:dark photos code chat:dark; do
    name="${spec%%:*}"; dark=""; [ "$spec" != "$name" ] && dark="--dark"
    "$BIN" --scene "$name" $dark --seconds 8 &
    pid=$!
    sleep 3
    wid=$("$HERE/../.build/winid" $pid)
    file="$OUT/w-$(echo "$spec" | tr ':' '-').png"
    [ -n "$wid" ] && screencapture -x -o -l "$wid" "$file" && echo "$file"
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
done
