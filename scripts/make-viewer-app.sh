#!/bin/sh
# Builds the Mac app: the macOS slice of the universal app target (App/Mirage.xcodeproj, the same target TestFlight
# ships for iOS), Mirage.app, bundle ID com.paulherz.mirage. Incremental; no App Store involvement. Output:
# .build/Mirage.app (install: scripts/install-viewer-app.sh, which also replaces a MirageViewer.app from older builds).
# The command-line viewer for scripts stays `swift build -c release`.
#
# Version identity (DESIGN §3.10): the build number is the commit count of HEAD, MIRAGE_COMMIT its short hash, and the
# channel stays empty ("local": never published). scripts/release.sh stamps its own: BUILD=, MIRAGE_CHANNEL=, VERSION=.
#
# Signing (DESIGN §3.10, phrz 2026-10-25): Developer ID Application, team M8MME6Q9DA, hardened runtime: the designated
# requirement every release keeps, so the Screen Recording and Accessibility grants survive updates (switching from Apple
# Development costs one re-grant). MIRAGE_SIGNING: auto (default: Developer ID when this Mac's keychain has it, else Apple
# Development, with a note), developer-id (required), development (Apple Development, whose grants differ).
set -e
cd "$(dirname "$0")/.."
# Xcode's toolchain, not the Command Line Tools (their manifest API can't read Package.swift on macOS 27).
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for x in /Applications/Xcode.app /Applications/Xcode-27.1.0-Beta.app; do
        [ -d "$x" ] && { export DEVELOPER_DIR="$x/Contents/Developer"; break; }
    done
fi
APP=.build/Mirage.app
BUILD=${BUILD:-$(git rev-list --count HEAD)}
COMMIT=${MIRAGE_COMMIT:-$(git rev-parse --short=7 HEAD)}
TEAM=M8MME6Q9DA
SIGNING=${MIRAGE_SIGNING:-auto}
has_developer_id() { security find-identity -v -p codesigning 2>/dev/null | grep -q "\"Developer ID Application: .*($TEAM)\""; }
[ "$SIGNING" = auto ] && { if has_developer_id; then SIGNING=developer-id; else SIGNING=development; fi; }
set -- CURRENT_PROJECT_VERSION="$BUILD" MIRAGE_COMMIT="$COMMIT" MIRAGE_CHANNEL="${MIRAGE_CHANNEL:-}" \
    MIRAGE_TEST_EXIT_IN_MAIN="${MIRAGE_TEST_EXIT_IN_MAIN:-}"
[ -n "${VERSION:-}" ] && set -- "$@" MARKETING_VERSION="$VERSION"
case "$SIGNING" in
    developer-id)
        has_developer_id || { echo "error: no \"Developer ID Application: … ($TEAM)\" identity in this Mac's keychain; scripts/release.sh --check says how to add it" >&2; exit 1; }
        # Manual: a Developer ID app needs no provisioning profile. --timestamp: notarization needs a secure timestamp.
        set -- "$@" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=$TEAM \
            OTHER_CODE_SIGN_FLAGS=--timestamp ;;
    development) echo "note: signing with Apple Development (no Developer ID Application identity here, or MIRAGE_SIGNING=development)" >&2 ;;
    *) echo "error: MIRAGE_SIGNING is auto, developer-id or development" >&2; exit 1 ;;
esac
# No -allowProvisioningUpdates: a macOS build with automatic signing needs no provisioning profile, and the flag made
# xcodebuild wait for the Apple account (it hung while this Mac was locked). testflight.sh keeps it for iOS.
xcodebuild -project App/Mirage.xcodeproj -scheme Mirage -configuration Release -destination 'platform=macOS' \
    -derivedDataPath .build/xcode -quiet build "$@"
rm -rf "$APP" .build/MirageViewer.app
ditto ".build/xcode/Build/Products/Release/Mirage.app" "$APP"
echo "$APP"
