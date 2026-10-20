#!/bin/sh
# One-command deploy of the host, now inside Mirage.app (DESIGN §3.1): builds the app (scripts/make-viewer-app.sh:
# the macOS slice with Contents/MacOS/miraged embedded and signed with the Apple Development identity under the stable
# identifier com.paulherz.mirage.host, so Screen Recording and Accessibility grants survive rebuilds), copies it to
# HOST:/Applications/Mirage.app and restarts the login-item agent. The host must have been migrated once
# (scripts/migrate-host-to-app.sh). CLI on the host: /Applications/Mirage.app/Contents/MacOS/miraged (serve, devices, …).
set -e
cd "$(dirname "$0")/.."
HOST=${1:-mac-daddy}
APP=$(sh scripts/make-viewer-app.sh | tail -1)
codesign --verify --strict "$APP"
codesign -dv "$APP/Contents/MacOS/miraged" 2>&1 | grep -q "Identifier=com.paulherz.mirage.host" || { echo "error: miraged is not signed as com.paulherz.mirage.host" >&2; exit 1; }
rsync -a --delete "$APP/" "$HOST:/Applications/Mirage.app/"
ssh "$HOST" 'launchctl kickstart -k gui/$(id -u)/com.paulherz.mirage.host && sleep 2 && tail -n 4 ~/Library/Logs/mirage-host.log'
