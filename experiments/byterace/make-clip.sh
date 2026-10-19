#!/bin/sh
# A 32 s 1280x720 test clip: a camera-like pan over a detailed still (a Mandelbrot render) with film grain,
# and a moving testsrc2 inset (hard edges, text). Generated, so nothing copyrighted is recorded.
set -e
OUT=${1:-clip.mp4}
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "mandelbrot=s=2560x1440:start_scale=1.2:maxiter=300:end_pts=1" -frames:v 1 /tmp/byterace-still.png
ffmpeg -hide_banner -loglevel error -y -loop 1 -framerate 30 -i /tmp/byterace-still.png -f lavfi -i "testsrc2=s=320x180:r=30" \
  -filter_complex "[0]crop=1280:720:x='600+500*sin(t/5)':y='360+300*sin(t/3.3)',noise=alls=7:allf=t[bg];[bg][1]overlay=x='100+t*25':y='400+80*sin(t*2)'" \
  -t 32 -c:v libx264 -preset fast -crf 20 -pix_fmt yuv420p "$OUT"
rm -f /tmp/byterace-still.png
