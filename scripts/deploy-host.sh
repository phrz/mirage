#!/bin/sh
# One-command deploy of the host, now inside Mirage.app (DESIGN §3.1): builds the app (scripts/make-viewer-app.sh:
# the macOS slice with Contents/MacOS/miraged embedded and signed under the stable identifier com.paulherz.mirage.host,
# so Screen Recording and Accessibility grants survive rebuilds), copies it to HOST:/Applications/Mirage.app and restarts
# the login-item agent. The inner loop, beside the updater (DESIGN §3.10).
#
# Signed with Developer ID Application (phrz, 2026-10-25), like every release, without notarizing: an rsync-copied bundle
# carries no quarantine flag. Its designated requirement is the releases', so the grants given once after the switch from
# Apple Development hold for deploys and updates alike. Until this Mac has the Developer ID certificate the deploy falls
# back to Apple Development with a loud warning (a missing certificate never blocks a deploy). MIRAGE_SIGN=dev forces
# Apple Development; MIRAGE_SIGN=developer-id refuses to deploy without Developer ID (each switch between the two needs
# the grants again). The host must have been migrated once
# (scripts/migrate-host-to-app.sh). CLI on the host: /Applications/Mirage.app/Contents/MacOS/miraged (serve, devices, …).
set -e
cd "$(dirname "$0")/.."
HOST=${1:-mac-daddy}
export MIRAGE_SIGN=${MIRAGE_SIGN:-auto}
APP=$(sh scripts/make-viewer-app.sh | tail -1)
codesign --verify --strict "$APP"
if ! codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "######## WARNING: deploying an Apple Development build to $HOST (no Developer ID here, or MIRAGE_SIGN=dev)." >&2
fi
codesign -dv "$APP/Contents/MacOS/miraged" 2>&1 | grep -q "Identifier=com.paulherz.mirage.host" || { echo "error: miraged is not signed as com.paulherz.mirage.host" >&2; exit 1; }
rsync -a --delete "$APP/" "$HOST:/Applications/Mirage.app/"
ssh "$HOST" 'launchctl kickstart -k gui/$(id -u)/com.paulherz.mirage.host && sleep 2 && tail -n 4 ~/Library/Logs/mirage-host.log'
