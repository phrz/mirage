#!/bin/sh
# ============================================================================================================================
# DEVELOPER ONLY. This installs a local development build (Apple Development signed, no release host, no updates): a
# "crippled" copy that says the host is missing. Every Mac's everyday Mirage is the signed release from the feed:
#     sh scripts/install-host.sh --channel nightly                 (a Mac you share)
#     sh scripts/install-host.sh --channel nightly --viewer-only   (a Mac that only connects to others)
# Set MIRAGE_DEV_VIEWER=1 to run this anyway.
# ============================================================================================================================
# Installs the Mac app as DEST/Mirage.app (DEST: ~/Applications by default), replacing a copy from older builds named
# MirageViewer.app or "Mirage Viewer.app" (same bundle ID, com.paulherz.mirage): one Mirage in Finder, Launchpad and
# Spotlight. Pairings and settings are untouched (~/Library/Application Support/Mirage and the com.paulherz.mirage
# defaults follow the bundle ID, not the file name).
#   scripts/install-viewer-app.sh [DEST]          builds (scripts/make-viewer-app.sh), then installs
#   APP=path/Mirage.app scripts/install-viewer-app.sh [DEST]   installs that build
# A running Mirage keeps running from the old copy until it is quit; open the new one afterwards.
set -e
if [ "${MIRAGE_DEV_VIEWER:-}" != 1 ]; then
    echo "install-viewer-app.sh installs a DEVELOPMENT build, not the release (no host, no updates)." >&2
    echo "For a Mac's everyday Mirage: sh scripts/install-host.sh --channel nightly [--viewer-only]" >&2
    echo "Set MIRAGE_DEV_VIEWER=1 to install the development build anyway." >&2
    exit 2
fi
cd "$(dirname "$0")/.."
DEST=${1:-$HOME/Applications}
APP=${APP:-$(sh scripts/make-viewer-app.sh | tail -1)}
BUNDLE_ID=com.paulherz.mirage
LSREGISTER=${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
[ "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] \
    || { echo "error: $APP is not $BUNDLE_ID" >&2; exit 1; }
mkdir -p "$DEST"

# The host agent (Allow Connections to This Mac) registered from an older copy runs from inside that copy.
OLD_AGENT=$(launchctl print "gui/$(id -u)/com.paulherz.mirage.host" 2>/dev/null | sed -n 's/^[[:space:]]*program = //p' | head -1)

NEW="$DEST/Mirage.app"
rm -rf "$NEW"
ditto "$APP" "$NEW"
"$LSREGISTER" -f "$NEW" 2>/dev/null || true
echo "installed $NEW"

for OLD in "$DEST/MirageViewer.app" "$DEST/Mirage Viewer.app"; do
    [ -d "$OLD" ] || continue
    id=$(plutil -extract CFBundleIdentifier raw "$OLD/Contents/Info.plist" 2>/dev/null || true)
    if [ "$id" != "$BUNDLE_ID" ]; then echo "left $OLD alone (bundle ID ${id:-unknown})"; continue; fi
    "$LSREGISTER" -u "$OLD" 2>/dev/null || true
    rm -rf "$OLD"
    echo "removed the older copy $OLD"
    case "$OLD_AGENT" in
        "$OLD"/*) echo "note: this Mac's host ran from $OLD. In Mirage's menu-bar item turn Allow Connections to This Mac off and on again, so it runs from $NEW." ;;
    esac
done
