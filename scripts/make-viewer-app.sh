#!/bin/sh
# Wraps the mirage-viewer executable in a minimal .app bundle (SwiftUI needs a bundle to
# behave like a real app: key window, Dock icon, stable TCC identity). Output: .build/MirageViewer.app
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/mirage-viewer
APP=.build/MirageViewer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/mirage-viewer"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon/Mirage.icns "$APP/Contents/Resources/Mirage.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>mirage-viewer</string>
  <key>CFBundleIconFile</key><string>Mirage</string>
  <key>CFBundleIdentifier</key><string>com.paulherz.mirage.viewer</string>
  <key>CFBundleName</key><string>Mirage Viewer</string>
  <key>CFBundleDisplayName</key><string>Mirage Viewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
if [ -n "$IDENTITY" ]; then codesign -f -s "$IDENTITY" --identifier com.paulherz.mirage.viewer "$APP" >/dev/null 2>&1 || true; fi
echo "$APP"
