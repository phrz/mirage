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
# A change of signing identity (Apple Development ↔ Developer ID) costs the host's Screen Recording and Accessibility
# grants (TCC follows the designated requirement) and the agent's registration: refused unless
# MIRAGE_ALLOW_IDENTITY_CHANGE=1, as `miraged update` refuses it without --allow-identity-change.
dr() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'; }
REMOTE_DR=$(ssh "$HOST" 'for b in /Applications/Mirage.app /Applications/Mirage.app/Contents/MacOS/miraged; do [ -e "$b" ] && codesign -d -r- "$b" 2>&1 | sed -n "s/^designated => //p"; done' || true)
LOCAL_DR=$(dr "$APP"; dr "$APP/Contents/MacOS/miraged")
IDENTITY_CHANGE=
if [ -n "$REMOTE_DR" ] && [ "$REMOTE_DR" != "$LOCAL_DR" ]; then
    IDENTITY_CHANGE=1
    echo "######## signing identity change on $HOST:" >&2
    echo "  installed: $REMOTE_DR" | tr '\n' ' ' >&2; echo >&2
    echo "  this build: $LOCAL_DR" | tr '\n' ' ' >&2; echo >&2
    if [ "${MIRAGE_ALLOW_IDENTITY_CHANGE:-}" != 1 ]; then
        echo "######## refused: the grants and the agent registration will need a person at $HOST. To go ahead: MIRAGE_ALLOW_IDENTITY_CHANGE=1 $0 $HOST" >&2
        exit 1
    fi
fi
rsync -a --delete "$APP/" "$HOST:/Applications/Mirage.app/"
# Restart the agent onto the new code, and check it runs. launchd keeps a launch constraint (LWCR) from the signature
# SMAppService registered: a miraged signed differently fails to spawn ("spawn failed", exit 78 EX_CONFIG, "needs LWCR
# update") until Mirage.app registers the agent again. --ensure-agent does that through a one-shot job in the GUI
# session (`open` itself fails over SSH: "Could not switch to audit session"); when even that cannot reach the app, a
# person must open Mirage.app once on the host (it registers again at launch when the signature changed).
if ! ssh "$HOST" '/Applications/Mirage.app/Contents/MacOS/miraged update --ensure-agent; s=$?; sleep 2; tail -n 4 ~/Library/Logs/mirage-host.log; exit $s'; then
    echo "######## $HOST: the host agent does not run. If the lines above say Mirage.app could not be reached, open Mirage.app once on $HOST." >&2
    exit 1
fi
if [ -n "$IDENTITY_CHANGE" ]; then
    cat >&2 <<EOF
######## $HOST was signed with another identity: at $HOST, once,
  System Settings > Privacy & Security > Screen & System Audio Recording, and then Accessibility: remove the old
  Mirage / miraged rows (−), add /Applications/Mirage.app/Contents/MacOS/miraged (+) and switch it on; then
  launchctl kickstart -k gui/\$(id -u)/com.paulherz.mirage.host
EOF
fi
