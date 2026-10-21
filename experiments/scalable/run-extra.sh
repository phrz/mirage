#!/bin/sh
# Bytes-only side studies over the corpus: the plain 1x / 1.5x / 2x WebP ladder (--scales) and the Laplacian
# variant of B (--lap: 2x residual against the upsampled base, mod 256, as a WebP lossless image).
set -e
cd "$(dirname "$0")"
OUT=${OUT:-results}
BIN=${BIN:-.build/scalebench}
mkdir -p "$OUT"
echo "image,cat,layer2x,layer15x,layer1x,tiles,tiles2x,tiles15x,tiles1x" > "$OUT/scales.csv"
echo "image,cat,tiles,A,base,lap_nearest,lap_bilinear" > "$OUT/lap.csv"
cat_of() {
    case "$1" in
        *text*|*terminal*|*code*|*document*|*spreadsheet*) echo text ;;
        *vibrancy*|*controls*|*icons*|*gradients*) echo ui ;;
        *photos*|*noise-photo*|*wallpaper*) echo photo ;;
        *) echo mixed ;;
    esac
}
for f in corpus/out/*.png; do
    c=$(cat_of "$(basename "$f")")
    $BIN --scales "$f" "$c" "$OUT/scales.csv"
    $BIN --lap "$f" "$c" "$OUT/lap.csv"
done
