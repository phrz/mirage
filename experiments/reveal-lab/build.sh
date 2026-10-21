#!/bin/zsh
# Builds "build/Reveal Lab.app" from the SwiftPM package in this directory.
set -euo pipefail
cd "${0:A:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-27.1.0-Beta.app/Contents/Developer}"
swift build -c release
APP="build/Reveal Lab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/RevealLab" "$APP/Contents/MacOS/RevealLab"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Reveal Lab</string>
  <key>CFBundleDisplayName</key><string>Reveal Lab</string>
  <key>CFBundleIdentifier</key><string>com.phrz.mirage.reveal-lab</string>
  <key>CFBundleExecutable</key><string>RevealLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $PWD/$APP"
