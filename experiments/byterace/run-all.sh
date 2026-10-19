#!/bin/sh
# Replays every recorded scene in $1 (default ./seq) at the given video budgets; results/<scene>.{txt,json}.
SEQ=${1:-seq}; KBPS=${2:-600,2000}
mkdir -p results
for d in "$SEQ"/*/; do
  s=$(basename "$d")
  nice .build/release/byterace run "$d" --kbps "$KBPS" --out "results/$s.json" | tee "results/$s.txt"
done
