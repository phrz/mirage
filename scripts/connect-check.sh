#!/bin/sh
# connect.sh NAME PROFILE(fast4g|20m|japan) [COMP]: the M-FIVE connect acceptance run on mac-daddy:7899. The viewer records
# composited frames every 100 ms from the stream's start; connectcheck measures coherent/crisp/flicker per region.
S=${SCRATCH:?set SCRATCH to the directory holding ab-c.sh and connectcheck}
N=$1; P=$2; C=${3:-1}
case $P in fast4g) TH="Fast 4G";; 20m) TH="20000/5000/30";; japan) TH="Japan bus 4G";; *) echo "profile?"; exit 1;; esac
rm -rf $S/$N-frames
MIRAGE_TEST_FRAMES=$S/$N-frames MIRAGE_TEST_FRAMES_MS=100 DUR=45 BITRATE=0 THROTTLE="$TH" $S/ab-c.sh $N passive $C > /dev/null 2>&1
grep -E "connect probe|stage 1" $S/$N/host-run.log | cut -c12-180
$S/connectcheck $S/$N-frames 40
