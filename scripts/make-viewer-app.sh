#!/bin/sh
# Builds the Mac app: the macOS slice of the universal app target (App/Mirage.xcodeproj, the same target TestFlight
# ships for iOS), Mirage.app, bundle ID com.paulherz.mirage, signed with this Mac's Apple Development certificate (stable
# TCC identity). Incremental; no App Store involvement. Output: .build/Mirage.app (install: scripts/install-viewer-app.sh,
# which also replaces a MirageViewer.app from older builds). The command-line viewer for scripts stays
# `swift build -c release`.
set -e
cd "$(dirname "$0")/.."
# Xcode's toolchain, not the Command Line Tools (their manifest API can't read Package.swift on macOS 27).
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for x in /Applications/Xcode.app /Applications/Xcode-27.1.0-Beta.app; do
        [ -d "$x" ] && { export DEVELOPER_DIR="$x/Contents/Developer"; break; }
    done
fi
APP=.build/Mirage.app
# No -allowProvisioningUpdates: a macOS build with automatic signing needs no provisioning profile, and the flag made
# xcodebuild wait for the Apple account (it hung while this Mac was locked). testflight.sh keeps it for iOS.
xcodebuild -project App/Mirage.xcodeproj -scheme Mirage -configuration Release -destination 'platform=macOS' \
    -derivedDataPath .build/xcode -quiet build
rm -rf "$APP" .build/MirageViewer.app
ditto ".build/xcode/Build/Products/Release/Mirage.app" "$APP"
echo "$APP"
