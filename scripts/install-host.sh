#!/bin/sh
# Installs Mirage on this Mac as a host, from the release feed (DESIGN §3.10, U5): one command, run by a person at the
# new Mac (or by scripts/fleet.sh over SSH: `ssh HOST 'sh -s -- --channel nightly' < scripts/install-host.sh`).
#
#   1. fetches the channel head (github.com/phrz/mirage releases: channel-<name>/manifest.json and its signatures);
#   2. downloads the zip it names and checks its size and SHA-256;
#   3. checks the bundle with this Mac's own tools before running anything from it: the code-signing requirement pinned
#      for Mirage (Apple-anchored, com.paulherz.mirage / com.paulherz.mirage.host, team M8MME6Q9DA) and Gatekeeper's
#      notarization assessment;
#   4. hands over to the bundle's own miraged, now known to be genuine (`update --install-bundle`): it verifies the
#      manifest's signature with the keys it was built with and that the manifest describes this very bundle, checks it
#      again as the updater does (self-test included), refuses a signing-identity change over an installed Mirage
#      unless --allow-identity-change, installs /Applications/Mirage.app (an older install is swapped and kept as the
#      previous build), sets the channel and policy, turns the host on (the agent and Mirage at login), and prints the
#      Screen Recording and Device Control (Accessibility) steps, named as this Mac's System Settings names them.
#
#   scripts/install-host.sh [--channel stable|beta|nightly] [--policy ask|automatic] [--force] [--allow-identity-change]
#                           [--dry-run] [--feed URL]
#     --dry-run   verify everything and say what would happen; change nothing
#     --force     reinstall even when this build or a newer one is installed
#     --feed      another feed (a URL or file:// directory with channel-<name>/), for tests; it must still be signed
#     --app PATH  install somewhere else than /Applications/Mirage.app (tests, with --dry-run)
set -e
CHANNEL=stable; POLICY=; FORCE=; ALLOW_ID=; DRY=; TARGET=
FEED=https://github.com/phrz/mirage/releases/download
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL=$2; shift 2 ;;
        --policy) POLICY=$2; shift 2 ;;
        --force) FORCE=1; shift ;;
        --allow-identity-change) ALLOW_ID=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --feed) FEED=${2%/}; shift 2 ;;
        --app) TARGET=$2; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" 2>/dev/null || true; exit 0 ;;
        *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
done
case "$CHANNEL" in stable|beta|nightly) ;; *) echo "error: --channel is stable, beta or nightly" >&2; exit 2 ;; esac
case "$POLICY" in ""|ask|automatic) ;; *) echo "error: --policy is ask or automatic" >&2; exit 2 ;; esac
DR_APP='anchor apple generic and identifier "com.paulherz.mirage" and certificate leaf[subject.OU] = "M8MME6Q9DA"'
DR_HOST='anchor apple generic and identifier "com.paulherz.mirage.host" and certificate leaf[subject.OU] = "M8MME6Q9DA"'
die() { echo "error: $*" >&2; exit 1; }

MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 15 ] || die "Mirage needs macOS 15 or later (this Mac has $(sw_vers -productVersion))"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mirage-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM
fetch() { curl -fsSL --retry 2 --max-time 600 -o "$2" "$1" || die "cannot fetch $1"; }
MURL=$FEED/channel-$CHANNEL/manifest.json
echo "== $CHANNEL channel head: $MURL"
fetch "$MURL" "$WORK/manifest.json"
fetch "${MURL%/*}/manifest.sigs.json" "$WORK/manifest.sigs.json"
field() { plutil -extract "$1" raw -o - "$WORK/manifest.json" 2>/dev/null || die "the manifest has no $1"; }
VERSION=$(field version); BUILD=$(field build); ZIPURL=$(field zipURL); SHA=$(field zipSHA256); SIZE=$(field zipSize)
case "$ZIPURL" in https://*|http://*|file://*) ;; *) ZIPURL=${MURL%/*}/$ZIPURL ;; esac   # relative to the manifest
echo "== Mirage $VERSION ($BUILD): $ZIPURL"
fetch "$ZIPURL" "$WORK/Mirage.zip"
[ "$(stat -f %z "$WORK/Mirage.zip")" = "$SIZE" ] || die "the zip is $(stat -f %z "$WORK/Mirage.zip") bytes, the manifest says $SIZE"
[ "$(shasum -a 256 "$WORK/Mirage.zip" | cut -d' ' -f1)" = "$SHA" ] || die "the zip's SHA-256 does not match the manifest"
ditto -x -k "$WORK/Mirage.zip" "$WORK/x" || die "cannot unpack the zip"
APP=$WORK/x/Mirage.app
[ -d "$APP" ] || die "the zip holds no Mirage.app"

echo "== checking the bundle with this Mac's tools"
codesign --verify --strict --deep -R="$DR_APP" "$APP" 2>/dev/null || die "Mirage.app is not signed by team M8MME6Q9DA as com.paulherz.mirage"
codesign --verify --strict -R="$DR_HOST" "$APP/Contents/MacOS/miraged" 2>/dev/null || die "its miraged is not signed by team M8MME6Q9DA as com.paulherz.mirage.host"
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || die "Gatekeeper does not accept it as a notarized Developer ID app"
echo "   signed by M8MME6Q9DA, notarized"

set -- update --install-bundle "$APP" --manifest "$WORK/manifest.json" --sigs "$WORK/manifest.sigs.json" --channel "$CHANNEL"
[ -n "$POLICY" ] && set -- "$@" --set "policy=$POLICY"
[ -n "$FORCE" ] && set -- "$@" --force
[ -n "$ALLOW_ID" ] && set -- "$@" --allow-identity-change
[ -n "$DRY" ] && set -- "$@" --dry-run
[ -n "$TARGET" ] && set -- "$@" --app "$TARGET"
# Builds before U5 have no installer half: say so rather than install without the manifest's signature checked.
"$APP/Contents/MacOS/miraged" update --help 2>/dev/null | grep -q -- --status-line \
    || die "Mirage $VERSION ($BUILD) predates install-host.sh's installer (U5): wait for a newer $CHANNEL build, or install by hand"
echo "== installing (the bundle's own miraged verifies the manifest's signature)"
"$APP/Contents/MacOS/miraged" "$@"
