#!/bin/sh
# Last-resort rollback over SSH (DESIGN §3.10, the one hole): puts HOST's kept previous build
# (~/Library/Application Support/Mirage/Previous/Mirage.app) back at /Applications/Mirage.app and restarts the host agent,
# for a build too broken to roll itself back (one that dies before main). It runs the previous build's own
# `miraged update --rollback` (the same atomic swap the updater does), else, for a previous build from before the
# updater, two renames.
#   scripts/rollback-host.sh HOST
set -e
HOST=${1:?usage: scripts/rollback-host.sh HOST}
ssh "$HOST" 'set -e
  PREV="$HOME/Library/Application Support/Mirage/Previous/Mirage.app"
  APP=/Applications/Mirage.app
  [ -d "$PREV" ] || { echo "no previous build at $PREV" >&2; exit 1; }
  if "$PREV/Contents/MacOS/miraged" update --help 2>/dev/null | grep -q -- --rollback; then
    "$PREV/Contents/MacOS/miraged" update --rollback --app "$APP"
  else
    TMP="$APP.rollback-$$"
    mv "$APP" "$TMP" && mv "$PREV" "$APP" && mv "$TMP" "$PREV"
    rm -f "$HOME/Library/Application Support/Mirage/pending-update.json"
    echo "rolled back by rename (the previous build predates the updater)"
  fi
  # The restored build may be signed differently from the one the agent was registered for: --ensure-agent restarts it
  # and registers it again through Mirage.app if launchd refuses it (a launch constraint, EX_CONFIG).
  if "$APP/Contents/MacOS/miraged" update --help 2>/dev/null | grep -q -- --ensure-agent; then
    "$APP/Contents/MacOS/miraged" update --ensure-agent || echo "the host agent does not start: launchctl print gui/$(id -u)/com.paulherz.mirage.host" >&2
  else
    launchctl kickstart -k gui/$(id -u)/com.paulherz.mirage.host
    launchctl print gui/$(id -u)/com.paulherz.mirage.host | grep -E "^\s(state|job state|last exit code) ="
  fi
  sleep 3
  tail -n 6 ~/Library/Logs/mirage-host.log'
