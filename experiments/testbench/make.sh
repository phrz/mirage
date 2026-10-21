#!/bin/sh
# Builds .build/MirageTestBench.app (needs DEVELOPER_DIR pointing at Xcode on macOS 27).
set -e
cd "$(dirname "$0")/../.."
APP=.build/MirageTestBench.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -framework AppKit -o "$APP/Contents/MacOS/MirageTestBench" experiments/testbench/testbench.swift experiments/testbench/scenes.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MirageTestBench</string>
  <key>CFBundleIdentifier</key><string>com.paulherz.mirage.testbench</string>
  <key>CFBundleName</key><string>Mirage Test Bench</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign -f -s - "$APP" >/dev/null 2>&1 || true
echo "$APP"
