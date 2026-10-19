#!/bin/sh
# Records every scene into $1 (default ./seq): one at a time, each ≤ 40 s, windows bottom-right, never key.
# The video scene needs a clip: make-clip.sh writes one with ffmpeg.
set -e
OUT=${1:-seq}; CLIP=${2:-clip.mp4}
BIN=.build/release/bytrec
for s in "typing 40" "terminal 40" "scroll 40" "spinner 20" "anim 20" "anim-rich 20" "video 30" "mixed 40"; do
  set -- $s
  "$BIN" "$1" "$2" "$OUT" --clip "$CLIP"
  sleep 2
done
