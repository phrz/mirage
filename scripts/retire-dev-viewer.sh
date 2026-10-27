#!/bin/sh
# Retires a development copy of Mirage (scripts/install-viewer-app.sh: Apple Development signed, no release host) and
# installs the signed release with Share This Mac off, as every viewer-only Mac runs it:
#   1. checks the copy (default ~/Applications/Mirage.app; another path only with --app) is Mirage (com.paulherz.mirage),
#      not a release (a release carries a stapled notarization ticket; the signer alone says nothing), and not
#      /Applications/Mirage.app;
#   2. asks before doing anything (--yes skips the question), the install included;
#   3. quits Mirage, makes sure no login item or host agent runs from that copy, and moves it to the Trash (not deleted:
#      it can be put back);
#   4. runs scripts/install-host.sh --channel nightly --viewer-only (/Applications/Mirage.app, the signed release).
# Pairings and settings stay (~/Library/Application Support/Mirage follows the bundle ID, not the copy).
#   scripts/retire-dev-viewer.sh [--app PATH/Mirage.app] [--channel stable|beta|nightly] [--yes]
set -e
cd "$(dirname "$0")/.."
DEV="$HOME/Applications/Mirage.app"; YES=; CHANNEL=nightly
while [ $# -gt 0 ]; do
    case "$1" in
        --yes) YES=1; shift ;;
        --channel) CHANNEL=$2; shift 2 ;;
        --app) DEV=$2; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
done
case "$CHANNEL" in stable|beta|nightly) ;; *) echo "error: --channel is stable, beta or nightly" >&2; exit 2 ;; esac
DEV=${DEV%/}
ask() {
    [ -n "$YES" ] && return 0
    printf "%s [y/N] " "$1"
    read -r answer || answer=
    case "$answer" in y|Y|yes) return 0 ;; *) echo "nothing changed"; exit 0 ;; esac
}

case "$DEV" in
    /Applications/Mirage.app) echo "error: $DEV is the release's place; this script only retires a development copy" >&2; exit 1 ;;
esac
if [ ! -d "$DEV" ]; then
    echo "no Mirage at $DEV: nothing to retire."
    echo "Installing the signed release as a viewer-only Mac turns Share This Mac off on this Mac."
    ask "Install /Applications/Mirage.app (viewer only)?"
    exec sh scripts/install-host.sh --channel "$CHANNEL" --viewer-only
fi
ID=$(plutil -extract CFBundleIdentifier raw "$DEV/Contents/Info.plist" 2>/dev/null || true)
[ "$ID" = com.paulherz.mirage ] || { echo "error: $DEV is not Mirage (bundle id ${ID:-unknown})" >&2; exit 1; }
AUTH=$(codesign -dvv "$DEV" 2>&1 | sed -n 's/^Authority=//p' | head -1)
# A release is notarized with its ticket stapled (release.sh staples it). The signer says nothing: install-viewer-app.sh
# can sign a development copy with the Developer ID too (phrz's ~/Applications copy, build 481), unnotarized.
if command -v xcrun >/dev/null 2>&1 && xcrun --find stapler >/dev/null 2>&1; then
    if xcrun stapler validate -q "$DEV" >/dev/null 2>&1; then
        echo "error: $DEV carries a stapled notarization ticket: a release, not a development copy; leaving it" >&2; exit 1
    fi
    WHY="no stapled notarization ticket"
else
    # No stapler (no developer tools): Gatekeeper's verdict instead.
    case "$(spctl --assess --type execute -vv "$DEV" 2>&1)" in
        *"source=Notarized Developer ID"*) echo "error: $DEV is notarized: a release, not a development copy; leaving it" >&2; exit 1 ;;
    esac
    WHY="not notarized"
fi
echo "$DEV is a development copy ($WHY; signed by ${AUTH:-nobody})."
echo "This quits Mirage, moves that copy to the Trash, and installs the signed release (/Applications/Mirage.app, viewer only)."
ask "Go ahead?"

osascript -e 'tell application id "com.paulherz.mirage" to quit' 2>/dev/null || true
sleep 2
# Nothing may keep running from the copy: its host agent (launchd's program path inside it) or its own login item.
AGENT=$(launchctl print "gui/$(id -u)/com.paulherz.mirage.host" 2>/dev/null | sed -n 's/^[[:space:]]*program = //p' | head -1)
case "$AGENT" in
    "$DEV"/*)
        echo "its host agent is registered from the copy ($AGENT): unregistering it"
        launchctl bootout "gui/$(id -u)/com.paulherz.mirage.host" 2>/dev/null || true ;;
esac
if pgrep -f "$DEV/Contents/MacOS/" >/dev/null 2>&1; then
    echo "error: something still runs from $DEV (pgrep -fl '$DEV/Contents/MacOS/'); quit it, then run this again" >&2; exit 1
fi
TRASH="$HOME/.Trash/Mirage (development) $(date +%Y%m%d-%H%M%S).app"
mv "$DEV" "$TRASH"
echo "moved to $TRASH"
exec sh scripts/install-host.sh --channel "$CHANNEL" --viewer-only
