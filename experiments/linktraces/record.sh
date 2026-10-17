#!/bin/sh
# Records a replayable link trace to HOST: ICMP RTT/loss at 5 Hz (ping.log) and a 1 MB scp
# throughput probe each direction every 3 min (throughput.log). Usage: record.sh HOST MINUTES NAME
HOST=${1:-mac-daddy}; MIN=${2:-25}; NAME=${3:-trace}; OUT="$NAME"; mkdir -p "$OUT"
echo "start $(date -u +%FT%TZ) host=$HOST minutes=$MIN" > "$OUT/meta.txt"
( ping -i 0.2 -c $((MIN*300)) "$HOST" 2>&1 | while IFS= read -r line; do printf '%s %s\n' "$(date +%s.%N | cut -c1-14)" "$line"; done > "$OUT/ping.log" ) &
PING=$!
head -c 1000000 /dev/urandom > "$OUT/.blob"
END=$(( $(date +%s) + MIN*60 ))
while [ "$(date +%s)" -lt "$END" ]; do
  T0=$(date +%s.%N); scp -q -o ConnectTimeout=20 "$OUT/.blob" "$HOST:/tmp/mirage-blob" 2>/dev/null && UP=$(echo "$(date +%s.%N) - $T0" | bc) || UP=fail
  T0=$(date +%s.%N); scp -q -o ConnectTimeout=20 "$HOST:/tmp/mirage-blob" "$OUT/.blob2" 2>/dev/null && DOWN=$(echo "$(date +%s.%N) - $T0" | bc) || DOWN=fail
  echo "$(date +%s) up_s=$UP down_s=$DOWN (1 MB each)" >> "$OUT/throughput.log"
  sleep 180
done
wait $PING
rm -f "$OUT/.blob" "$OUT/.blob2"
echo "end $(date -u +%FT%TZ)" >> "$OUT/meta.txt"
