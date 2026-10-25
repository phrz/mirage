#!/bin/sh
# Publishes a Mirage release (DESIGN §3.10, Developer ID, notarization, the feed): runs the suite, stamps the version,
# builds the Mac app signed with Developer ID Application (team M8MME6Q9DA, hardened runtime), notarizes and staples it,
# zips it, writes and signs manifest.json, publishes the release on github.com/phrz/mirage and moves the channel head.
# Runs on phrz's MacBook, where the identity, the notarytool profile and the manifest key live; written so a CI job can
# call it unchanged (MIRAGE_MANIFEST_KEY instead of the keychain).
#
#   scripts/release.sh --check                  what this Mac still needs to release, and how to set it up
#   scripts/release.sh keys-init                once: generate the manifest keys (current + next), see below
#   scripts/release.sh nightly                  release HEAD of main as nightly-<build>
#   scripts/release.sh beta N                   release vVERSION-beta.N
#   scripts/release.sh stable                   release vVERSION
#   options (after the channel):
#     --no-publish   build, notarize, sign into .build/release/<tag>/ as a local feed; nothing goes to GitHub
#     --broken       a deliberately broken build that exits in main (U3's rollback test); implies --no-publish
#     --skip-tests   skip `swift test` (a rebuild of a commit already tested)
#   environment:
#     VERSION=0.4.1  (default: MARKETING_VERSION in App/project.yml)   BUILD=…  (default: commit count of HEAD)
#     NOTES="…"      release notes                                       MIRAGE_NEXT_KEY=<base64 public key>: nextKey
#     MIRAGE_MANIFEST_KEY=<base64 private key>   sign with this instead of the keychain's current key (CI)
#     MIRAGE_EXTRA_SIGNING_KEY_FILE=path         a second private key (rotation: the promoted key, from 1Password)
#
# The manifest's signing key: its private half is in the login keychain as the generic password service
# com.paulherz.mirage.manifest-key, account current; its public half (and the offline next key's) are compiled into the
# app in Sources/MirageUpdater/TrustedKeys.swift.
set -e
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ]; then
    for x in /Applications/Xcode.app /Applications/Xcode-27.1.0-Beta.app; do
        [ -d "$x" ] && { export DEVELOPER_DIR=$x/Contents/Developer; break; }
    done
fi
TEAM=M8MME6Q9DA
REPO=phrz/mirage
PROFILE=mirage
KEY_SERVICE=com.paulherz.mirage.manifest-key
DR_APP='anchor apple generic and identifier "com.paulherz.mirage" and certificate leaf[subject.OU] = "M8MME6Q9DA"'
DR_HOST='anchor apple generic and identifier "com.paulherz.mirage.host" and certificate leaf[subject.OU] = "M8MME6Q9DA"'

die() { echo "error: $*" >&2; exit 1; }
tool() { .build/release/mirage-release "$@"; }
build_tool() { swift build -c release --product mirage-release >/dev/null 2>&1 || swift build -c release --product mirage-release; }

# MARK: what this Mac needs

check_identity() {
    security find-identity -v -p codesigning 2>/dev/null | grep -q "\"Developer ID Application: .*($TEAM)\"" && return 0
    cat >&2 <<EOF
missing: a "Developer ID Application" signing identity for team $TEAM in this Mac's keychain.
  Set up once: Xcode > Settings > Accounts > (the team) > Manage Certificates… > + > Developer ID Application
  (the Account Holder's role is needed to create one), or download it from developer.apple.com > Certificates
  and open the .cer with its private key in this keychain. Check: security find-identity -v -p codesigning
EOF
    return 1
}
check_notary() {
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 && return 0
    cat >&2 <<EOF
missing: the notarytool keychain profile "$PROFILE".
  Set up once (an app-specific password from appleid.apple.com > Sign-In and Security, or an App Store Connect API key):
    xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id $TEAM --password <app-specific-password>
  Check: xcrun notarytool history --keychain-profile $PROFILE
EOF
    return 1
}
check_manifest_key() {
    [ -n "${MIRAGE_MANIFEST_KEY:-}" ] && return 0
    security find-generic-password -s "$KEY_SERVICE" -a current >/dev/null 2>&1 && return 0
    cat >&2 <<EOF
missing: the manifest signing key (keychain item $KEY_SERVICE / current).
  Set up once: scripts/release.sh keys-init (then commit Sources/MirageUpdater/TrustedKeys.swift).
EOF
    return 1
}
check_compiled_keys() {
    grep -q '^        "[A-Za-z0-9+/=]\{44\}",' Sources/MirageUpdater/TrustedKeys.swift && return 0
    echo "missing: trusted manifest public keys in Sources/MirageUpdater/TrustedKeys.swift (scripts/release.sh keys-init writes them)" >&2
    return 1
}
check_gh() {
    gh auth status >/dev/null 2>&1 && return 0
    echo "missing: GitHub CLI authentication for $REPO (gh auth login)" >&2
    return 1
}

if [ "${1:-}" = --check ]; then
    ok=0
    check_identity || ok=1
    check_notary || ok=1
    check_manifest_key || ok=1
    check_compiled_keys || ok=1
    check_gh || ok=1
    [ $ok = 0 ] && echo "ready to release"
    exit $ok
fi

# MARK: keys-init

if [ "${1:-}" = keys-init ]; then
    security find-generic-password -s "$KEY_SERVICE" -a current >/dev/null 2>&1 && die "a current manifest key is already in the keychain ($KEY_SERVICE); rotation is a manual step (DESIGN §3.10)"
    build_tool
    CUR=$(tool keygen); NXT=$(tool keygen)
    field() { plutil -extract "$2" raw -o - - <<EOF
$1
EOF
    }
    CUR_PUB=$(field "$CUR" publicKey); CUR_PRIV=$(field "$CUR" privateKey); CUR_ID=$(field "$CUR" keyID)
    NXT_PUB=$(field "$NXT" publicKey); NXT_PRIV=$(field "$NXT" privateKey); NXT_ID=$(field "$NXT" keyID)
    # -T: /usr/bin/security reads it back without a prompt at release time.
    # Through security's own command reader (-i), so the private key is never an argument `ps` could show.
    echo "add-generic-password -s $KEY_SERVICE -a current -l \"Mirage manifest key $CUR_ID\" -T /usr/bin/security -w $CUR_PRIV" | security -i
    python3 - "$CUR_PUB" "$CUR_ID" "$NXT_PUB" "$NXT_ID" <<'PY'
import sys, re
cur, cur_id, nxt, nxt_id = sys.argv[1:]
p = "Sources/MirageUpdater/TrustedKeys.swift"
s = open(p).read()
block = (f'        // BEGIN MIRAGE MANIFEST KEYS\n        "{cur}", // current {cur_id}\n        "{nxt}", // next {nxt_id} (private half offline)\n'
         '        // END MIRAGE MANIFEST KEYS')
s = re.sub(r'        // BEGIN MIRAGE MANIFEST KEYS\n.*?        // END MIRAGE MANIFEST KEYS', block, s, flags=re.S)
open(p, "w").write(s)
PY
    cat <<EOF
current key $CUR_ID: private half saved in the login keychain ($KEY_SERVICE / current).
next key $NXT_ID: store this private half in 1Password now, and nowhere on this Mac (it is not saved anywhere else):

    $NXT_PRIV

Both public keys are in Sources/MirageUpdater/TrustedKeys.swift: commit it. Hosts trust releases from the first build
that carries them.
EOF
    exit 0
fi

# MARK: a release

CHANNEL=${1:-}
case "$CHANNEL" in
    nightly|stable) shift ;;
    beta) shift; BETA=${1:-}; [ -n "$BETA" ] || die "beta needs its number: scripts/release.sh beta N"; shift ;;
    *) die "usage: scripts/release.sh --check | keys-init | nightly | beta N | stable [--no-publish] [--broken] [--skip-tests]" ;;
esac
PUBLISH=1; BROKEN=; TESTS=1
for a in "$@"; do
    case "$a" in
        --no-publish) PUBLISH= ;;
        --broken) BROKEN=1; PUBLISH= ;;
        --skip-tests) TESTS= ;;
        *) die "unknown option $a" ;;
    esac
done

ok=0
check_identity || ok=1
check_notary || ok=1
check_manifest_key || ok=1
check_compiled_keys || ok=1
[ -n "$PUBLISH" ] && { check_gh || ok=1; }
[ $ok = 0 ] || die "this Mac is not set up to release (above)"

if [ -n "$PUBLISH" ]; then
    [ -z "$(git status --porcelain)" ] || die "the working tree has changes: a release is exactly a commit"
    [ "$(git rev-parse --abbrev-ref HEAD)" = main ] || die "releases are cut from main (HEAD is $(git rev-parse --abbrev-ref HEAD))"
fi

VERSION=${VERSION:-$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' App/project.yml | head -1)}
BUILD=${BUILD:-$(git rev-list --count HEAD)}
COMMIT=$(git rev-parse --short=7 HEAD)
case "$CHANNEL" in
    nightly) TAG=nightly-$BUILD ;;
    beta) TAG=v$VERSION-beta.$BETA ;;
    stable) TAG=v$VERSION ;;
esac
[ -n "$BROKEN" ] && TAG=broken-$BUILD
OUT=.build/release/$TAG
ZIPNAME=Mirage-$VERSION-$BUILD.zip
echo "== $TAG: Mirage $VERSION ($BUILD) $COMMIT on $CHANNEL${BROKEN:+, deliberately broken}${PUBLISH:-, local only}"

mkdir -p .build/release
if [ -n "$TESTS" ]; then
    echo "== swift test"
    swift test > .build/release/test.log 2>&1 || { tail -30 .build/release/test.log; die "the suite fails (.build/release/test.log)"; }
    grep -E "Executed [0-9]+ tests" .build/release/test.log | tail -1
fi

echo "== build (Developer ID, hardened runtime)"
build_tool
APP=$(BUILD=$BUILD VERSION=$VERSION MIRAGE_CHANNEL=$CHANNEL MIRAGE_SIGN=developer-id MIRAGE_TEST_EXIT_IN_MAIN=${BROKEN:+YES} \
    sh scripts/make-viewer-app.sh | tail -1)
codesign --verify --strict --deep "$APP"
codesign --verify --strict -R="$DR_APP" "$APP" || die "Mirage.app does not satisfy the pinned requirement: $DR_APP"
codesign --verify --strict -R="$DR_HOST" "$APP/Contents/MacOS/miraged" || die "miraged does not satisfy: $DR_HOST"
for b in "$APP" "$APP/Contents/MacOS/miraged"; do
    codesign -dv "$b" 2>&1 | grep -q 'flags=.*runtime' || die "$b lacks the hardened runtime"
    codesign -d --entitlements :- "$b" 2>/dev/null | grep -q get-task-allow && die "$b carries get-task-allow (notarization rejects it)"
done

echo "== self-test of the built host"
SELF=$("$APP/Contents/MacOS/miraged" --self-test) || die "the built miraged fails its self-test: $SELF"
echo "$SELF" | grep -q "\"build\":$BUILD," || die "the self-test reports another build: $SELF"
echo "$SELF" | head -1

echo "== notarize (notarytool, profile $PROFILE) and staple"
rm -rf "$OUT"; mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$OUT/notarize.log" | grep -E "status:|id:" || true
grep -q "status: Accepted" "$OUT/notarize.log" || die "notarization was not accepted (see $OUT/notarize.log; xcrun notarytool log <id> --keychain-profile $PROFILE)"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || die "Gatekeeper does not accept $APP as a notarized Developer ID app"
rm "$OUT/notarize.zip"

echo "== zip and manifest"
ditto -c -k --keepParent "$APP" "$OUT/$ZIPNAME"
# Published: the release's asset URL. Local (a feed for tests): channel-<name>/ beside <tag>/ under .build/release, or
# under .build/release/broken for a broken build, so it never shadows a good local head.
if [ -n "$PUBLISH" ]; then ZIPURL=https://github.com/$REPO/releases/download/$TAG/$ZIPNAME
elif [ -n "$BROKEN" ]; then ZIPURL=../../$TAG/$ZIPNAME; HEAD_DIR=.build/release/broken/channel-$CHANNEL
else ZIPURL=../$TAG/$ZIPNAME; HEAD_DIR=.build/release/channel-$CHANNEL; fi
[ -n "$BROKEN" ] && NOTES="deliberately broken: exits in main (rollback test)"
tool manifest --channel "$CHANNEL" --version "$VERSION" --build "$BUILD" --commit "$COMMIT" --zip "$OUT/$ZIPNAME" \
    --zip-url "$ZIPURL" --notes "${NOTES:-}" ${MIRAGE_NEXT_KEY:+--next-key "$MIRAGE_NEXT_KEY"} --out "$OUT/manifest.json"
{
    if [ -n "${MIRAGE_MANIFEST_KEY:-}" ]; then echo "$MIRAGE_MANIFEST_KEY"
    else security find-generic-password -s "$KEY_SERVICE" -a current -w; fi
    [ -n "${MIRAGE_EXTRA_SIGNING_KEY_FILE:-}" ] && cat "$MIRAGE_EXTRA_SIGNING_KEY_FILE"
    true
} | tool sign --manifest "$OUT/manifest.json" --out "$OUT/manifest.sigs.json"
tool verify --manifest "$OUT/manifest.json" --sigs "$OUT/manifest.sigs.json" --channel "$CHANNEL" || die "the signed manifest does not verify with this tree's trusted keys"

if [ -z "$PUBLISH" ]; then
    mkdir -p "$HEAD_DIR"
    cp "$OUT/manifest.json" "$OUT/manifest.sigs.json" "$HEAD_DIR/"
    FEED=$(cd "$(dirname "$HEAD_DIR")" && pwd)
    cat <<EOF
== local feed: $FEED (channel-$CHANNEL/manifest.json, its zip in .build/release/$TAG/)
   Copy $FEED/channel-$CHANNEL and .build/release/$TAG to a host with the same layout, then there:
   /Applications/Mirage.app/Contents/MacOS/miraged update --now --channel $CHANNEL --feed <the copy of $(basename "$FEED")>
EOF
    exit 0
fi

echo "== publish $TAG and move channel-$CHANNEL"
PRE=; [ "$CHANNEL" = stable ] || PRE=--prerelease
gh release create "$TAG" "$OUT/$ZIPNAME" "$OUT/manifest.json" "$OUT/manifest.sigs.json" --repo "$REPO" \
    --target "$(git rev-parse HEAD)" --title "Mirage $VERSION ($BUILD) $CHANNEL" --notes "${NOTES:-$CHANNEL build $BUILD from $COMMIT}" $PRE
# The channel head: a rolling prerelease (never "Latest") whose only assets are the current manifest and its signatures.
if ! gh release view "channel-$CHANNEL" --repo "$REPO" >/dev/null 2>&1; then
    gh release create "channel-$CHANNEL" --repo "$REPO" --target "$(git rev-parse HEAD)" --prerelease \
        --title "channel-$CHANNEL (rolling head)" --notes "The current $CHANNEL manifest for Mirage's updater (DESIGN §3.10). Not a release: see $TAG."
fi
gh release upload "channel-$CHANNEL" "$OUT/manifest.json" "$OUT/manifest.sigs.json" --repo "$REPO" --clobber

if [ "$CHANNEL" = nightly ]; then
    echo "== prune nightlies beyond the newest 10"
    gh release list --repo "$REPO" --limit 300 --json tagName -q '.[].tagName' | grep '^nightly-[0-9]*$' | sort -t- -k2 -n -r | tail -n +11 |
        while read -r old; do gh release delete "$old" --repo "$REPO" --yes --cleanup-tag && echo "deleted $old"; done
fi
echo "== done: https://github.com/$REPO/releases/tag/$TAG"
