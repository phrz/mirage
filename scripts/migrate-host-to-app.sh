#!/bin/sh
# One-time move of a host from the old ~/.local/bin/miraged LaunchAgent to the host inside Mirage.app (DESIGN §3.1).
# Pairings, the host identity and resume state stay in ~/Library/Application Support/Mirage, so every paired device
# keeps working. Afterwards: grant Screen Recording and Accessibility once (printed at the end), and deploy with
# scripts/deploy-host.sh.
set -e
cd "$(dirname "$0")/.."
HOST=${1:-mac-daddy}
APP=$(sh scripts/make-viewer-app.sh | tail -1)
codesign --verify --strict "$APP"
echo "== installing Mirage.app on $HOST"
rsync -a --delete "$APP/" "$HOST:/Applications/Mirage.app/"
echo "== stopping and removing the old LaunchAgent and ~/.local/bin/miraged"
ssh "$HOST" 'set -e
  launchctl bootout gui/$(id -u)/com.paulherz.mirage.host 2>/dev/null || true
  rm -f ~/Library/LaunchAgents/com.paulherz.mirage.host.plist ~/.local/bin/miraged
  ls ~/Library/Application\ Support/Mirage/authorized-devices.json >/dev/null && echo "pairings kept: $(/Applications/Mirage.app/Contents/MacOS/miraged devices | wc -l | tr -d " ") devices"'
echo "== enabling the host inside the app (SMAppService login-item agent)"
ssh "$HOST" 'open -a /Applications/Mirage.app --args --allow-connections; sleep 6
  launchctl print gui/$(id -u)/com.paulherz.mirage.host 2>/dev/null | grep -E "state =|program|path =" | head -4 || echo "agent not loaded yet: approve Mirage in System Settings > General > Login Items"
  tail -n 6 ~/Library/Logs/mirage-host.log'
cat <<'INFO'

== once, on the host Mac (System Settings > Privacy & Security):
   Screen & System Audio Recording, and Device Control and Data Access (Accessibility before macOS 27): enable "miraged"
   (/Applications/Mirage.app/Contents/MacOS/miraged; the host asks for both when it starts, so it is listed).
   If Settings lists it as "Mirage" (or "Mirage Viewer", from older builds) instead, enable that. The Mirage menu-bar item shows
   "Mirage needs Screen Recording / Device Control and Data Access" with buttons to these panes until the host sees both grants;
   then restart it: launchctl kickstart -k gui/$(id -u)/com.paulherz.mirage.host
INFO
