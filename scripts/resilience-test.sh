#!/bin/sh
# Loopback resilience scenarios for DESIGN §4a (M2.5). Runs a local host (miraged serve --port 7800)
# in *input-sink* mode (MIRAGE_INPUT_SINK: every input the host would inject is written to a file
# instead; nothing reaches this Mac's real input) and headless viewers against localhost, then asserts
# the pass conditions from the viewers' --stats JSON and the logs. Needs: a release build, Screen
# Recording granted to .build/release/miraged, `localhost` paired (mirage connect localhost --pair …),
# an awake display. No sudo: the dummynet profiles are a documented section at the end.
#
#   scripts/resilience-test.sh all            # every scenario below, PASS/FAIL per §4a row
#   scripts/resilience-test.sh outage-stop    # SIGSTOP the host 30 s mid-stream (path black hole), resume
#   scripts/resilience-test.sh outage-kill    # kill -9 the host, restart it 30 s later (host restart)
#   scripts/resilience-test.sh outage-short   # SIGSTOP 8 s: the QUIC connection itself must survive
#   scripts/resilience-test.sh loss           # 5 % random datagram loss, moving picture: no freeze > 500 ms
#   scripts/resilience-test.sh burst          # 2 s loss bursts every 10 s: picture back < 500 ms after each
#   scripts/resilience-test.sh input          # 1000 keystrokes under 5 % loss + a 2 s burst: order, no loss, no dups
#   scripts/resilience-test.sh keepalive      # idle 40 s: one datagram per 10 s from the viewer, no close
set -u
cd "$(dirname "$0")/.."
PORT=${PORT:-7800}
OUT=${OUT:-/tmp/mirage-resilience}
HOSTBIN=${HOSTBIN:-.build/release/miraged}
VIEWERBIN=${VIEWERBIN:-.build/release/mirage-viewer}
BENCH=.build/MirageTestBench.app/Contents/MacOS/MirageTestBench
mkdir -p "$OUT"
# Copies so a rebuild during a run does not pull the binaries from under the processes.
cp "$HOSTBIN" "$OUT/miraged"; cp "$VIEWERBIN" "$OUT/mirage-viewer"
HOSTBIN="$OUT/miraged"; VIEWERBIN="$OUT/mirage-viewer"
PASSED=0; FAILED=0; UNTESTED=0
RESULTS="$OUT/results.txt"; : > "$RESULTS"

say() { echo "$*"; echo "$*" >> "$RESULTS"; }
pass() { PASSED=$((PASSED+1)); say "PASS  $*"; }
fail() { FAILED=$((FAILED+1)); say "FAIL  $*"; }
json() { python3 -c "import json,sys; j=json.load(open('$1')); v=j; [v:=v[k] for k in '$2'.split('.')]; print(v)" 2>/dev/null; }

stop_all() { pkill -f "$HOSTBIN serve --port $PORT" 2>/dev/null; pkill -f "$VIEWERBIN localhost --port $PORT" 2>/dev/null; pkill -x MirageTestBench 2>/dev/null; sleep 0.5; }
start_host() { # $1 = name, rest = extra env assignments
    name=$1; shift
    rm -f "$OUT/$name.input.jsonl"   # the sink appends; a previous run's events must not count
    env MIRAGE_INPUT_SINK="$OUT/$name.input.jsonl" "$@" nohup "$HOSTBIN" serve --port "$PORT" > "$OUT/$name.host.log" 2>&1 &
    HOSTPID=$!; sleep 1.5
}
start_viewer() { # $1 = name, $2 = duration, rest = extra args; env via VIEWER_ENV
    name=$1; dur=$2; shift 2
    env $VIEWER_ENV nohup "$VIEWERBIN" localhost --port "$PORT" --headless --duration "$dur" --bitrate 800 --window 1280x720 --stats "$OUT/$name.json" "$@" > "$OUT/$name.viewer.log" 2>&1 &
    VIEWERPID=$!
}
start_bench() { # a moving picture of our own: the test bench's animation mode
    [ -x "$BENCH" ] || experiments/testbench/make.sh > /dev/null
    nohup "$BENCH" --motion > /dev/null 2>&1 & BENCHPID=$!; sleep 1.5
}
VIEWER_ENV=""

# --- Outage survival: a 30 s black hole (host process frozen) returns to the same session.
outage_stop() {
    stop_all; start_host outage-stop; start_viewer outage-stop 58; sleep 12
    kill -STOP $HOSTPID; T0=$(python3 -c 'import time;print(time.time())'); sleep 30; kill -CONT $HOSTPID; T1=$(python3 -c 'import time;print(time.time())')
    wait $VIEWERPID 2>/dev/null; stop_all
    R=$(json "$OUT/outage-stop.json" resumes); RC=$(json "$OUT/outage-stop.json" reconnects); RP=$(json "$OUT/outage-stop.json" resumeToPictureMs)
    GAP=$(json "$OUT/outage-stop.json" maxPictureGapMs)
    BACK=$(python3 -c "print(round($GAP/1000 - ($T1-$T0), 2))")
    say "outage-stop: resumes=$R reconnects=$RC resume→picture ms=$RP picture gap ${GAP} ms, i.e. picture back $BACK s after the path returned"
    grep -E "resumed after|suspended|resuming" "$OUT/outage-stop.host.log" | sed 's/^.\{24\}//' | head -4
    if [ "$R" = 1 ] && [ "$RC" = 0 ] && python3 -c "exit(0 if $BACK < 2.0 else 1)"; then pass "§4a outage survival (30 s black hole): same session resumed, picture back ${BACK} s after the path returned (< 2 s)"; else fail "§4a outage survival (30 s black hole): resumes=$R reconnects=$RC back=${BACK}s"; fi
}

# --- Host restart: the viewer never dead-ends, no re-pairing; the host cannot keep caches across a kill.
outage_kill() {
    stop_all; start_host outage-kill; start_viewer outage-kill 58; sleep 12
    kill -9 $HOSTPID; T0=$(python3 -c 'import time;print(time.time())'); sleep 30
    start_host outage-kill-2; T1=$(python3 -c 'import time;print(time.time())')
    wait $VIEWERPID 2>/dev/null; stop_all
    R=$(json "$OUT/outage-kill.json" resumes); RC=$(json "$OUT/outage-kill.json" reconnects); GAP=$(json "$OUT/outage-kill.json" maxPictureGapMs)
    BACK=$(python3 -c "print(round($GAP/1000 - ($T1-$T0), 2))")
    ATT=$(grep -c "reconnecting in" "$OUT/outage-kill.viewer.log")
    say "outage-kill: reconnect attempts=$ATT resumes=$R reconnects=$RC picture back $BACK s after the host was back (new session: a killed host has no state to resume)"
    if [ "$RC" = 1 ] && python3 -c "exit(0 if $BACK < 4.0 else 1)"; then pass "§4a reconnect policy (host killed 30 s): $ATT attempts, no re-pairing, fresh stream ${BACK} s after the host returned"; else fail "§4a reconnect policy (host killed): reconnects=$RC back=${BACK}s attempts=$ATT"; fi
}

# --- A short black hole must not even cost a reconnect: QUIC idle timeout 45 s, watchdog 12 s.
outage_short() {
    stop_all; start_host outage-short; start_viewer outage-short 30; sleep 10
    kill -STOP $HOSTPID; sleep 8; kill -CONT $HOSTPID
    wait $VIEWERPID 2>/dev/null; stop_all
    R=$(json "$OUT/outage-short.json" resumes); RC=$(json "$OUT/outage-short.json" reconnects); GAP=$(json "$OUT/outage-short.json" maxPictureGapMs)
    say "outage-short: 8 s black hole: resumes=$R reconnects=$RC picture gap ${GAP} ms"
    if [ "$R" = 0 ] && [ "$RC" = 0 ] && python3 -c "exit(0 if $GAP < 10000 else 1)"; then pass "§4a idle timeout: an 8 s black hole is not a close (connection survived, picture back $(python3 -c "print(round($GAP/1000-8,2))") s after)"; else fail "§4a idle timeout: resumes=$R reconnects=$RC gap=${GAP}ms"; fi
}

# --- Loss: 5 % random datagram loss on the host's video path against a moving picture (the bench's --motion
# window). §4a: no freeze longer than 500 ms; recovery by parity and NACK, keyframes last.
# Freezes are counted from 20 s after connecting: the fresh picture's lossless blocks take ~15 s at an 800
# kbps cap and hold video to 3–8 fps meanwhile (a budget matter, M2), which is not what the loss row measures.
# A 0 % baseline with the same picture runs first so the loss run's numbers have a reference.
loss() {
    stop_all; start_bench; start_host loss-baseline; start_viewer loss-baseline 45 --steady-after 20
    wait $VIEWERPID 2>/dev/null; stop_all
    say "loss baseline (0 %): video fps median $(json "$OUT/loss-baseline.json" fpsMedian), longest video gap $(json "$OUT/loss-baseline.json" maxVideoGapMs) ms after 20 s"
    stop_all; start_bench; start_host loss MIRAGE_TEST_LOSS=0.05 MIRAGE_TEST_SEED=7; start_viewer loss 45 --steady-after 20
    wait $VIEWERPID 2>/dev/null; stop_all
    GAP=$(json "$OUT/loss.json" maxVideoGapMs); OVER=$(python3 -c "import json;print(len(json.load(open('$OUT/loss.json'))['videoGapsOver500ms']))"); FPS=$(json "$OUT/loss.json" fpsMedian)
    NACK=$(json "$OUT/loss.json" recoveredByNack); PAR=$(json "$OUT/loss.json" recoveredByParity); LOST=$(json "$OUT/loss.json" lostTotal); SENT=$(json "$OUT/loss.json" nacksSent)
    KEYS=$(grep -c " keyframe [0-9]" "$OUT/loss.host.log"); TARGET=$(json "$OUT/loss.json" controllerTargetKbpsMedian)
    say "loss 5 %: video fps median $FPS at a controller target of $TARGET kbps, longest video gap ${GAP} ms, gaps > 500 ms: $OVER; recovered by parity $PAR, by NACK $NACK ($SENT nacks), frames given up $LOST, keyframes $KEYS"
    if python3 -c "exit(0 if $GAP < 500 and $OVER == 0 else 1)"; then pass "§4a loss (5 % random): longest freeze ${GAP} ms (< 500 ms), parity $PAR / NACK $NACK recoveries, $LOST frames lost, $KEYS keyframes"; else fail "§4a loss (5 % random): longest freeze ${GAP} ms, $OVER freezes over 500 ms"; fi
}

# --- Bursts: everything dropped for 2 s every 10 s. Nothing can show during the burst; the picture must be
# back within 500 ms of its end (a gap report and an immediate recovery keyframe, not a timeout).
burst() {
    stop_all; start_bench; start_host burst MIRAGE_TEST_BURST_MS=2000 MIRAGE_TEST_BURST_EVERY_S=10 MIRAGE_TEST_LOSS=0.05 MIRAGE_TEST_SEED=7; start_viewer burst 48 --steady-after 15
    wait $VIEWERPID 2>/dev/null; stop_all
    GAP=$(json "$OUT/burst.json" maxVideoGapMs); OVER=$(python3 -c "import json;print(len(json.load(open('$OUT/burst.json'))['videoGapsOver500ms']))"); B=$(json "$OUT/burst.json" bursts)
    GAPS=$(python3 -c "import json;print([round(g) for g in json.load(open('$OUT/burst.json'))['videoGapsOver500ms']])")
    KEYS=$(grep -c " keyframe [0-9]" "$OUT/burst.host.log")
    AFTER=$(python3 -c "print(round($GAP - 2000))")
    say "bursts: 4 × 2 s in 45 s (plus 5 % loss): video gaps over 500 ms $GAPS; the longest, ${GAP} ms, is ${AFTER} ms after its burst ended; gap reports $B; keyframes $KEYS"
    # Bursts at 20, 30 and 40 s fall inside the measured window (from 15 s): each is one gap of 2 s plus the
    # recovery; a burst that swallowed a whole frame is recovered by the host's stale deadline instead of a
    # viewer gap report, so the report count is informational.
    if python3 -c "exit(0 if $GAP < 2500 and $OVER <= 4 else 1)"; then pass "§4a loss (2 s bursts): video back ${AFTER} ms after the worst burst (< 500 ms); gaps over 500 ms are the $OVER bursts themselves"; else fail "§4a loss (2 s bursts): longest video gap ${GAP} ms, $OVER gaps over 500 ms"; fi
}

# --- Input integrity: 1000 scripted keystrokes at 20 keys/s from the viewer, 5 % loss on the viewer's input
# datagrams and on the host's acks plus a 2 s burst each way, against a host in input-sink mode (nothing is
# injected anywhere; the host writes what it *would* inject to a file). Order, no loss, no duplicates.
input() {
    stop_all; start_host input MIRAGE_TEST_LOSS=0.05 MIRAGE_TEST_BURST_MS=2000 MIRAGE_TEST_BURST_EVERY_S=20 MIRAGE_TEST_SEED=3
    VIEWER_ENV="MIRAGE_TEST_LOSS=0.05 MIRAGE_TEST_BURST_MS=2000 MIRAGE_TEST_BURST_EVERY_S=20 MIRAGE_TEST_SEED=5"
    start_viewer input 75 --scenario keys:1000; VIEWER_ENV=""
    wait $VIEWERPID 2>/dev/null; stop_all
    python3 - "$OUT/input.json" "$OUT/input.input.jsonl" <<'PY' > "$OUT/input.compare.txt"
import json, sys
sent = json.load(open(sys.argv[1])).get("keysSent") or []
got = []
for line in open(sys.argv[2]):
    line = line.strip()
    if not line: continue
    m = json.loads(line)
    if "key" in m:
        k = m["key"]["_0"]
        got.append(f"{k['seq']}:{1 if k['down'] else 0}:{k.get('characters') or ''}")
dups = len(got) - len(set(got))
missing = [x for x in sent if x not in set(got)]
extra = [x for x in got if x not in set(sent)]
inorder = [x for x in got if x in set(sent)] == [x for x in sent if x in set(got)]
print(f"sent={len(sent)} received={len(got)} duplicates={dups} missing={len(missing)} extra={len(extra)} order={'ok' if inorder else 'BROKEN'}")
print("RESULT", "PASS" if sent and got == sent else "FAIL")
PY
    cat "$OUT/input.compare.txt" | head -1
    PK=$(json "$OUT/input.json" inputPackets); DR=$(json "$OUT/input.json" inputDropped)
    say "input: $(head -1 "$OUT/input.compare.txt"); $PK input datagrams for 2000 events, $DR dropped by the queue cap"
    if grep -q "RESULT PASS" "$OUT/input.compare.txt"; then pass "§4a input integrity: 1000 keystrokes under 5 % loss + 2 s bursts: host applied every event once, in order"; else fail "§4a input integrity: $(head -1 "$OUT/input.compare.txt")"; fi
}

# --- Keepalive: 40 s idle, one small datagram per 10 s from the viewer, the connection stays up.
keepalive() {
    stop_all; start_host keepalive; start_viewer keepalive 42
    wait $VIEWERPID 2>/dev/null; stop_all
    KA=$(json "$OUT/keepalive.json" keepalivesSent); R=$(json "$OUT/keepalive.json" resumes); RC=$(json "$OUT/keepalive.json" reconnects)
    say "keepalive: $KA datagram pings in 42 s (one per 10 s plus the opener), resumes=$R reconnects=$RC, QUIC idle timeout 45 s both ends"
    if [ "$R" = 0 ] && [ "$RC" = 0 ] && [ "$KA" -le 6 ] && [ "$KA" -ge 4 ]; then pass "§4a keepalives sparse: $KA pings in 42 s, no close"; else fail "§4a keepalives: pings=$KA resumes=$R reconnects=$RC"; fi
}

# --- Link conditioner profiles (sudo; documented, not run by this script) -----------------------------
# The scenarios above inject loss in Mirage's own datagram send paths, which proves the recovery logic but
# cannot touch the reliable QUIC streams (tiles, copy-rects, control) or add delay. macOS dummynet can; it
# needs root, so these are the commands to run by hand in a second terminal while a scenario runs
# (`PORT=7800 scripts/resilience-test.sh loss` etc. with MIRAGE_TEST_LOSS left unset in the host).
#
#   # one pipe for everything to/from the loopback host port (pf's default "set skip on lo0" is replaced by this ruleset)
#   sudo dnctl -q flush; sudo dnctl pipe 1 config delay 0ms
#   printf 'dummynet out proto udp from any to 127.0.0.1 port 7800 pipe 1\ndummynet in proto udp from 127.0.0.1 port 7800 to any pipe 1\n' | sudo pfctl -q -f -; sudo pfctl -q -e
#
#   # §4a profiles (each line replaces the previous one; dnctl takes effect at once):
#   sudo dnctl pipe 1 config plr 0.05                                   # loss row: 5 % random loss, both streams and datagrams
#   sudo dnctl pipe 1 config plr 1.0; sleep 2; sudo dnctl pipe 1 config plr 0.05   # a 2 s burst (repeat every 10 s)
#   sudo dnctl pipe 1 config plr 1.0; sleep 30; sudo dnctl pipe 1 config plr 0     # outage row: a 30 s black hole on the path itself
#   sudo dnctl pipe 1 config bw 1Mbit/s delay 200ms plr 0.01 queue 50   # DESIGN review §2.3 rig (1 Mbps, 200 ms, 1 %)
#   sudo dnctl pipe 1 config bw 1Mbit/s delay 200ms plr 0.02            # Constrained with loss (the Japan hotel link)
#   sudo dnctl pipe 1 config bw 256Kbit/s delay 350ms plr 0.03          # Extreme: congested rural cellular
#   sudo dnctl pipe 1 config bw 64Kbit/s delay 700ms plr 0.05 queue 20  # Extreme: Iridium / Antarctic satellite
#
#   # the recorded Japan bus trace (RTT, loss and throughput stepped every 10 s from the log):
#   sudo experiments/linktraces/replay.sh experiments/linktraces/2026-10-17-japan-bus-4g 127.0.0.1
#
#   # restore the link
#   sudo dnctl -q flush; sudo pfctl -q -d
#
# Pass conditions are the same rows of DESIGN §4a; read them from the viewer's --stats JSON
# (maxVideoGapMs, videoGapsOver500ms, resumes, reconnects, resumeToPictureMs, keepalivesSent, inputPackets).

case "${1:-all}" in
    input) input ;;
    keepalive) keepalive ;;
    loss) loss ;;
    burst) burst ;;
    outage-stop) outage_stop ;;
    outage-kill) outage_kill ;;
    outage-short) outage_short ;;
    all) keepalive; outage_short; outage_stop; outage_kill; loss; burst; input ;;
    *) echo "unknown scenario $1"; exit 2 ;;
esac
echo; echo "passed $PASSED  failed $FAILED  (details in $RESULTS)"; [ "$FAILED" = 0 ]
