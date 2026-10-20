#!/bin/sh
# Archives the universal app's iOS slice (App/Mirage.xcodeproj, bundle ID com.paulherz.mirage) and uploads it to
# App Store Connect for TestFlight, signing automatically with the Apple ID Xcode is signed in to (team M8MME6Q9DA).
# iOS only: the Mac viewer is the same target's macOS slice, built and deployed locally by make-viewer-app.sh.
# The build number is the UTC time (BUILD=… overrides); the version is MARKETING_VERSION in App/project.yml.
#   scripts/testflight.sh            archive + upload
#   scripts/testflight.sh --no-upload   archive + export an .ipa into .build/testflight/export only
set -e
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-27.1.0-Beta.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode-27.1.0-Beta.app/Contents/Developer
fi
BUILD=${BUILD:-$(date -u +%Y%m%d%H%M)}
DEST=upload; [ "${1:-}" = "--no-upload" ] && DEST=export
OUT=.build/testflight
rm -rf "$OUT"; mkdir -p "$OUT"
xcodebuild -project App/Mirage.xcodeproj -scheme Mirage -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$OUT/Mirage-iOS.xcarchive" -derivedDataPath .build/xcode -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD" -quiet archive
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>M8MME6Q9DA</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Mirage-iOS.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" -allowProvisioningUpdates
echo "build $BUILD: $( [ "$DEST" = upload ] && echo "uploaded to App Store Connect (TestFlight processes it in ~5-15 min)" || echo "exported to $OUT/export")"
