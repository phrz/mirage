#!/bin/sh
# Signs miraged with a stable identity (so TCC grants survive rebuilds) and restarts it on the host.
set -e
cd "$(dirname "$0")/.."
HOST=${1:-mac-daddy}
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
if [ -n "$IDENTITY" ]; then
  codesign -f -s "$IDENTITY" --identifier com.paulherz.mirage.host .build/release/miraged
else
  echo "warning: no Apple Development identity; ad-hoc signature means TCC must be re-granted after every build" >&2
fi
scp -q .build/release/miraged .build/release/mirage "$HOST":~/.local/bin/
ssh "$HOST" 'launchctl kickstart -k gui/$(id -u)/com.paulherz.mirage.host && sleep 2 && tail -n 4 ~/Library/Logs/mirage-host.log'
