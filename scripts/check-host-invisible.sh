#!/bin/sh
# check-host-invisible.sh: fails if any running miraged is registered with LaunchServices as a Foreground app (a Dock tile).
# miraged sets its activation policy to prohibited at start (stayInvisible); run on the host Mac, e.g. `ssh host sh -s < this`.
bad=$(lsappinfo list 2>/dev/null | awk '/executable path=.*\/MacOS\/miraged"/ {m=1; next} m && /type="/ {match($0, /type="[A-Za-z]+"/); t=substr($0, RSTART+6, RLENGTH-7); match($0, /pid = [0-9]+/); print substr($0, RSTART+6, RLENGTH-6), t; m=0}' | while read pid t; do kill -0 "$pid" 2>/dev/null && [ "$t" = Foreground ] && echo "$pid"; done)
if [ -n "$bad" ]; then echo "FAIL: miraged registered as Foreground (Dock tile): pid $bad"; exit 1; fi
echo "ok: no miraged with a Dock tile"
