#!/bin/sh
# Runs scalebench over the corpus, one image at a time (single thread, so the timings are clean), then the scroll study.
# Corpus: corpus/capture.sh (real Test Bench windows) + corpus/render.sh (offscreen renders) -> corpus/out/*.png.
set -e
cd "$(dirname "$0")"
OUT=${OUT:-results}
mkdir -p "$OUT"
HDR=$(grep '^#define HDR' scalebench.c | sed 's/^#define HDR "//; s/\\n"$//')
# FROM=name.png resumes an interrupted run at that image (appending).
if [ -z "$FROM" ]; then
    echo "$HDR" > "$OUT/tiles.csv"; echo "$HDR" > "$OUT/layers.csv"
    echo "image,cat,dy,n,exact_guess,exact_base_lh,fresh_base,resid_vs_guess,lh_band,full2x" > "$OUT/scroll.csv"
fi
cat_of() {
    case "$1" in
        *text*|*terminal*|*code*|*document*|*spreadsheet*) echo text ;;
        *vibrancy*|*controls*|*icons*|*gradients*) echo ui ;;
        *photos*|*noise-photo*|*wallpaper*) echo photo ;;
        *) echo mixed ;;
    esac
}
for f in corpus/out/*.png; do
    [ -n "$FROM" ] && [ "$(basename "$f")" \< "$FROM" ] && continue
    c=$(cat_of "$(basename "$f")")
    echo "$f $c" >&2
    .build/scalebench "$f" "$c" "$OUT/tiles.csv" "$OUT/layers.csv" $BENCH_ARGS
    .build/scalebench --scroll "$f" "$c" "$OUT/scroll.csv"
done
sh run-extra.sh
