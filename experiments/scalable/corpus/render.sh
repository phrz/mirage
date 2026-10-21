#!/bin/sh
# The 18 offscreen renders of the corpus (the other 12 images come from capture.sh).
cd "$(dirname "$0")/.."
.build/render corpus/out document-sans document-serif document-japanese document-small document-sans:dark spreadsheet \
    dashboard dashboard:dark gradients noise-photo wallpaper chat terminal:seed2 mixed:seed2 icons icons:dark controls vibrancy:dark
