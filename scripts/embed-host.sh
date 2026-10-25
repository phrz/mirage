#!/bin/sh
# Xcode build phase (macOS only): embeds the host in Mirage.app. Builds miraged with SwiftPM, copies it to
# Contents/MacOS/miraged and its LaunchAgent plist to Contents/Library/LaunchAgents, and signs miraged with the app's
# signing identity under the stable identifier com.paulherz.mirage.host (the TCC grants for Screen Recording and
# Accessibility follow the signature's designated requirement: identifier + team, so they survive rebuilds).
# Hardened runtime when the app has it (DESIGN §3.10: notarization requires it on every executable), and a secure
# timestamp for a Developer ID identity (notarization requires that too; none for development builds, which stay offline).
set -e
[ "$PLATFORM_NAME" = "macosx" ] || exit 0
ROOT="$PROJECT_DIR/.."
cd "$ROOT"
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" \
    xcrun swift build -c release --product miraged --scratch-path "$ROOT/.build" 2>&1 | grep -E "error|warning: unable|Compiling miraged|Build complete" || true
BIN="$ROOT/.build/release/miraged"
[ -x "$BIN" ] || { echo "error: miraged was not built" >&2; exit 1; }
CONTENTS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
install -m 0755 "$BIN" "$CONTENTS/MacOS/miraged"
mkdir -p "$CONTENTS/Library/LaunchAgents"
install -m 0644 "$PROJECT_DIR/LaunchAgents/com.paulherz.mirage.host.plist" "$CONTENTS/Library/LaunchAgents/"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
set -- --identifier com.paulherz.mirage.host
[ "${ENABLE_HARDENED_RUNTIME:-NO}" = YES ] && set -- "$@" --options runtime
case "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" in
    "Developer ID Application"*) set -- "$@" --timestamp ;;
    *) set -- "$@" --timestamp=none ;;
esac
codesign -f -s "$IDENTITY" "$@" "$CONTENTS/MacOS/miraged"
