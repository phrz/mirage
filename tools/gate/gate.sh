#!/bin/zsh
# The gate harness (docs/reset): scripted sessions through a production host with a headless viewer, numbers only.
# Usage: tools/gate/gate.sh HOST [profiles] [scenarios]
#   profiles: comma list of LAN, cafe, 4G, bus (default all)
#   scenarios: comma list of connect, typing, scroll, drag, video (default all)
# Needs: the host unlocked and idle, nobody else connected, the "Mirage Test Bench" window open on it (experiments/testbench;
# `video` wants it started with --plasma). Lock and unlock are run by hand (tools/gate/README.md). The truth reference is
# turned on per run (--truth on the stream request), never in the host's tunables.json. Frames are deleted after each run.
set -u
HOST=${1:?host}; PROFILES=${2:-LAN,cafe,4G,bus}; SCENARIOS=${3:-connect,typing,scroll,drag,video}
ROOT=${0:A:h}/../..; V="$ROOT/.build/debug/mirage-viewer"; OUT=${GATE_OUT:-$ROOT/.build/gate}; mkdir -p "$OUT"
[[ -x "$OUT/truth" ]] || swiftc -O "$ROOT/tools/gate/truth.swift" -o "$OUT/truth" || exit 1
# Loopback (the host is this Mac): read its log here instead of over ssh.
hostlog() { if [[ $HOST == (localhost|127.0.0.1|$(scutil --get LocalHostName)|$(scutil --get LocalHostName).local|$(hostname -s)) ]]; then zsh -c "$1"; else ssh -o BatchMode=yes "$HOST" "$1"; fi }
throttle() { case $1 in LAN) ;; cafe) echo "--throttle 5000/1000/40/0.5" ;; 4G) echo "--throttle Fast 4G" ;; bus) echo "--throttle Japan bus 4G" ;; esac }
scenario() { case $1 in connect) echo "--duration 12" ;; typing) echo "--duration 26 --scenario selecttype:20" ;; scroll) echo "--duration 26 --scenario scroll:20" ;;
    drag) echo "--duration 26 --scenario drag:20" ;; video) echo "--duration 20 --scenario idle:15" ;; esac }
printf "| profile | case | fps (median) | motion fps | frame gap p95 ms | key-to-pixel p50/max ms | crisp median/max ms | partial | cells wrong/frame | longest wrong | first whole | keyframes | kbps idle/active | host px -> stream px |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n" > "$OUT/table.md"
for p in ${(s:,:)PROFILES}; do for c in ${(s:,:)SCENARIOS}; do
    tag="$p-$c"; F="$OUT/$tag"; rm -rf "${F:?}"; mkdir -p "$F"
    S=$(python3 -c 'import time;print(time.time())'); ST=$(date -u +%Y-%m-%dT%H:%M:%S)
    eval "MIRAGE_TEST_FRAMES='$F' MIRAGE_TEST_FRAMES_MS=33 '$V' $HOST --headless --truth --window 1600x900 --scale 2 $(scenario $c) $(throttle $p) --stats '$OUT/$tag.json'" > "$OUT/$tag.out" 2> "$OUT/$tag.err"
    hostlog "grep '^20' ~/Library/Logs/mirage-host.log | awk -v t='$ST' '\$0 >= t'" > "$OUT/$tag.host"
    grep 'truth reference' "$OUT/$tag.host" | sed -E 's/^([^ ]+) truth reference: ([0-9a-f]+).*/\1 \2/' > "$OUT/$tag.refs"
    "$OUT/truth" "$F" "$OUT/$tag.refs" $S > "$OUT/$tag.truth" 2>&1; rm -rf "${F:?}"
    python3 - "$OUT/$tag.json" "$OUT/$tag.truth" "$p" "$c" >> "$OUT/table.md" <<'PY'
import json, re, sys
j = json.load(open(sys.argv[1])) if open(sys.argv[1]).read().strip() else {}
t = open(sys.argv[2]).read()
def g(k): return j.get(k)
f = lambda v: "-" if v is None else (f"{v:.0f}" if isinstance(v, (int, float)) else str(v))
mf = g("motionFps"); mfs = f"{sorted(mf)[len(mf)//2]:.0f}" if mf else "-"
part = re.search(r"partial (\d+) \(([\d.]+)%\)", t); cells = re.search(r"mean ([\d.]+); longest-wrong region: ([\d.]+) s", t); whole = re.search(r"first whole frame at (\S+) s", t)
print(f"| {sys.argv[3]} | {sys.argv[4]} | {f(g('fpsMedian'))} | {mfs} | {f(g('videoGapP95Ms'))} | {f(g('keyLatencyMsMedian'))}/{f(g('keyLatencyMsMax'))} | {f(g('crispMsMedian'))}/{f(g('crispMsMax'))} | "
      f"{part.group(2)+'%' if part else '-'} | {cells.group(1) if cells else '-'} | {cells.group(2)+' s' if cells else '-'} | {whole.group(1)+' s' if whole else '-'} | "
      f"{f(g('keyframes'))} | {f(g('idleKbpsMedian'))}/{f(g('activeKbpsMedian'))} | {g('hostPixels') or '-'} -> {g('streamPixels') or '-'} |")
PY
    sleep 3
done; done
cat "$OUT/table.md"
