#!/bin/sh
# Replays a recorded link trace against a target host using macOS dummynet (needs sudo).
# Usage: sudo ./replay.sh TRACE_DIR TARGET_IP [WINDOW_SECONDS=10]
# Builds one pipe for traffic to/from TARGET_IP and every WINDOW seconds sets its delay,
# packet loss and bandwidth from the trace: delay = median RTT/2 of the window, loss = fraction
# of missing icmp_seq in the window, bandwidth = the most recent throughput probe (down/up).
set -e
TRACE=$1; TARGET=$2; WIN=${3:-10}
[ -d "$TRACE" ] && [ -n "$TARGET" ] || { echo "usage: sudo $0 TRACE_DIR TARGET_IP [WINDOW]"; exit 2; }
dnctl -q flush || true
dnctl pipe 1 config delay 0ms
cat > /tmp/mirage-replay.pf <<PF
dummynet out proto { udp tcp icmp } from any to $TARGET pipe 1
dummynet in  proto { udp tcp icmp } from $TARGET to any pipe 1
PF
pfctl -q -f /tmp/mirage-replay.pf; pfctl -q -e || true
echo "replaying $TRACE against $TARGET in ${WIN}s windows; ctrl-c to stop (pipes are flushed on exit)"
trap 'dnctl -q flush; pfctl -q -d; echo "link restored"; exit 0' INT TERM
python3 -I - "$TRACE" "$WIN" <<'PY' | while read -r DELAY LOSS BW; do
import sys, re, statistics
trace, win = sys.argv[1], int(sys.argv[2])
rows = []
for line in open(f"{trace}/ping.log"):
    m = re.match(r"(\d+\.\d+) .*icmp_seq=(\d+) .*time=([\d.]+)", line)
    if m: rows.append((float(m.group(1)), int(m.group(2)), float(m.group(3))))
tp = []
try:
    for line in open(f"{trace}/throughput.log"):
        m = re.match(r"(\d+) up_s=(\S+) down_s=(\S+)", line)
        if m and m.group(3) != "fail": tp.append((int(m.group(1)), 8.0 / float(m.group(3))))  # Mbit/s for 1 MB
except FileNotFoundError: pass
if not rows: sys.exit("no ping rows")
t0 = rows[0][0]
i = 0
while i < len(rows):
    j = i
    while j < len(rows) and rows[j][0] < rows[i][0] + win: j += 1
    seg = rows[i:j]
    rtt = statistics.median(r[2] for r in seg)
    expected = seg[-1][1] - seg[0][1] + 1
    loss = max(0.0, 1 - len(seg) / expected) if expected > 0 else 0.0
    now = seg[0][0]
    bw = next((b for (ts, b) in reversed(tp) if ts <= now), tp[0][1] if tp else 5.0)
    print(f"{int(rtt/2)} {loss:.3f} {max(0.05, bw):.2f}")
    i = j
PY
  dnctl pipe 1 config delay "${DELAY}ms" plr "$LOSS" bw "${BW}Mbit/s" queue 50
  printf 'delay %sms  loss %s  bw %s Mbit/s\n' "$DELAY" "$LOSS" "$BW"
  sleep "$WIN"
done
dnctl -q flush; pfctl -q -d; echo "trace finished, link restored"
