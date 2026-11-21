#!/bin/sh
# Linux host releases (run on phrz-mini-m4-pro, which holds the Linux manifest key).
#
#   linux/release.sh stamp            stamp LinuxBuild.swift with this checkout's build number and commit (before building)
#   linux/release.sh unstamp          put LinuxBuild.swift back
#   linux/release.sh publish DIR      sign manifests for DIR/mirage-host-linux-{x86_64,aarch64} and upload them, the binaries
#                                     and install.sh to the linux-host release (hosts update from it within 6 hours)
#
# The binaries are built on Linux from the stamped sources (linux/Package.swift; x86_64 in an Ubuntu 26.04 chroot).
set -eu
cd "$(dirname "$0")/.."
STAMP=linux/Sources/mirage-host/LinuxBuild.swift
KEY=${MIRAGE_LINUX_KEY:-$HOME/.config/mirage/linux-manifest-key.json}
TAG=linux-host
REL=.build/debug/mirage-release

case "${1:-}" in
stamp)
    n=$(git rev-list --count HEAD); c=$(git rev-parse --short HEAD)
    sed -i '' -e "s/static let number = [0-9]*/static let number = $n/" -e "s/static let commit = \"[^\"]*\"/static let commit = \"$c\"/" "$STAMP"
    grep -E "number =|commit =" "$STAMP"
    ;;
unstamp)
    git checkout -- "$STAMP"
    ;;
publish)
    DIR=${2:?publish DIR}
    n=$(grep -o 'static let number = [0-9]*' "$STAMP" | grep -o '[0-9]*$')
    c=$(grep -o 'static let commit = "[^"]*"' "$STAMP" | cut -d'"' -f2)
    [ "$n" -gt 0 ] || { echo "LinuxBuild.swift is not stamped (run: linux/release.sh stamp, then build)"; exit 1; }
    [ -f "$KEY" ] || { echo "no Linux manifest key at $KEY"; exit 1; }
    # Hosts install only a higher build: a lower one (a rebased branch) would be ignored by every host, silently.
    live=$(curl -fsSL "https://github.com/phrz/mirage/releases/download/$TAG/linux-x86_64.manifest.json" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['build'])" 2>/dev/null || echo 0)
    [ "$n" -gt "$live" ] || { echo "build $n is not above the published build $live: hosts would ignore it"; exit 1; }
    DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} swift build --product mirage-release >/dev/null
    cp linux/install.sh "$DIR/install.sh"
    for a in x86_64 aarch64; do
        b="$DIR/mirage-host-linux-$a"
        [ -f "$b" ] || { echo "missing $b"; exit 1; }
        "$REL" manifest --channel stable --version Linux --build "$n" --commit "$c" --zip "$b" --zip-url "mirage-host-linux-$a" \
            --min-os ubuntu-26.04 --expires-days 365 --out "$DIR/linux-$a.manifest.json"
        python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['privateKey'])" "$KEY" |
            "$REL" sign --manifest "$DIR/linux-$a.manifest.json" --out "$DIR/linux-$a.manifest.sigs.json"
    done
    # Binaries first, manifests last: a host never reads a manifest whose binary is not up yet.
    gh release upload "$TAG" -R phrz/mirage --clobber "$DIR/install.sh" "$DIR/mirage-host-linux-x86_64" "$DIR/mirage-host-linux-aarch64"
    gh release upload "$TAG" -R phrz/mirage --clobber "$DIR"/linux-*.manifest.json "$DIR"/linux-*.manifest.sigs.json
    echo "published Linux build $n ($c)"
    ;;
*)
    sed -n 2,10p "$0"; exit 1 ;;
esac
