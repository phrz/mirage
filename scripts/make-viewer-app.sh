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
# Development costs one re-grant). MIRAGE_SIGN:
#   auto (default)  Developer ID when this Mac's keychain has it; else Apple Development, with a loud warning (a missing
#                   certificate never blocks a build or a host deploy)
#   developer-id    Developer ID required: an error without it (release.sh)
#   dev             Apple Development, even when Developer ID is there (its grants differ from Developer ID's)
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
SIGNING=${MIRAGE_SIGN:-auto}
has_developer_id() { security find-identity -v -p codesigning 2>/dev/null | grep -q "\"Developer ID Application: .*($TEAM)\""; }
if [ "$SIGNING" = auto ]; then
    if has_developer_id; then SIGNING=developer-id
    else
        SIGNING=dev
        cat >&2 <<EOF
######## WARNING: no "Developer ID Application: … ($TEAM)" identity in this Mac's keychain.
######## Signing with Apple Development instead. A host's Screen Recording and Accessibility grants follow the
######## signature: they will need granting again once Developer ID builds arrive (scripts/release.sh --check).
EOF
    fi
fi
set -- CURRENT_PROJECT_VERSION="$BUILD" MIRAGE_COMMIT="$COMMIT" MIRAGE_CHANNEL="${MIRAGE_CHANNEL:-}" \
    MIRAGE_TEST_EXIT_IN_MAIN="${MIRAGE_TEST_EXIT_IN_MAIN:-}"
[ -n "${VERSION:-}" ] && set -- "$@" MARKETING_VERSION="$VERSION"
case "$SIGNING" in
    developer-id)
        has_developer_id || { echo "error: MIRAGE_SIGN=developer-id, but no \"Developer ID Application: … ($TEAM)\" identity is in this Mac's keychain; scripts/release.sh --check says how to add it" >&2; exit 1; }
        # Manual: a Developer ID app needs no provisioning profile. --timestamp: notarization needs a secure timestamp.
        # Hardened runtime with Developer ID only (notarization needs it); Apple Development builds are signed as before.
        # CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: a plain `xcodebuild build` injects com.apple.security.get-task-allow
        # (debugger attach) into every signature, which notarization rejects; only archives drop it by default.
        set -- "$@" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=$TEAM \
            ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ;;
    dev|development) ;;
    *) echo "error: MIRAGE_SIGN is auto, developer-id or dev" >&2; exit 1 ;;
esac
# No -allowProvisioningUpdates: a macOS build with automatic signing needs no provisioning profile, and the flag made
# xcodebuild wait for the Apple account (it hung while this Mac was locked). testflight.sh keeps it for iOS.
xcodebuild -project App/Mirage.xcodeproj -scheme Mirage -configuration Release -destination 'platform=macOS' \
    -derivedDataPath .build/xcode -quiet build "$@"
rm -rf "$APP" .build/MirageViewer.app
ditto ".build/xcode/Build/Products/Release/Mirage.app" "$APP"
echo "$APP"
