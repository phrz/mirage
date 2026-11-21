#!/bin/sh
# Linux host releases, from any Mac that reaches a Linux builder with Docker over SSH (default: bigrig). Usually run by
# scripts/release.sh (after a Mac release, or `scripts/release.sh linux`); on its own:
#
#   linux/release.sh                    build HEAD on the builder and publish it to the linux-host release
#   linux/release.sh build DIR          build only, into DIR (mirage-host-linux-<arch>)
#   linux/release.sh publish DIR        sign the binaries in DIR for HEAD's build number and publish them
#   linux/release.sh key-to-1password FILE   store a Linux manifest key file ({privateKey, publicKey, keyID}) in 1Password
#
# The build is HEAD as committed (git archive), so the checkout is never stamped: the build number is HEAD's commit count
# and the commit its short hash, passed to linux/Dockerfile. Hosts update from the linux-host release within minutes
# (a viewer's arrow) or 6 hours (their own check).
#
# The signing key (Ed25519, TrustedKeys.linux) is read with the 1Password CLI from MIRAGE_LINUX_KEY_REF
# (default op://Private/Mirage Linux manifest key/credential), else MIRAGE_LINUX_KEY (base64 private key), else the file
# MIRAGE_LINUX_KEY_FILE. Environment: MIRAGE_LINUX_BUILDER (an ssh host with Docker; its processor is the build's).
set -eu
cd "$(dirname "$0")/.."
BUILDER=${MIRAGE_LINUX_BUILDER:-bigrig}
VAULT=${MIRAGE_OP_VAULT:-Private}
KEY_TITLE="Mirage Linux manifest key"
KEY_REF=${MIRAGE_LINUX_KEY_REF:-op://$VAULT/$KEY_TITLE/credential}
KEY_FILE=${MIRAGE_LINUX_KEY_FILE:-$HOME/.config/mirage/linux-manifest-key.json}
TAG=linux-host
REPO=phrz/mirage

die() { echo "linux release: $*" >&2; exit 1; }
say() { echo "linux release: $*"; }
REL() { DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} swift build -c release --product mirage-release >/dev/null && .build/release/mirage-release "$@"; }

build_number() { git rev-list --count HEAD; }
commit() { git rev-parse --short HEAD; }

# The private key, base64, on stdout.
linux_key() {
    if [ -n "${MIRAGE_LINUX_KEY:-}" ]; then echo "$MIRAGE_LINUX_KEY"; return; fi
    if command -v op >/dev/null 2>&1; then
        k=$(op read "$KEY_REF" 2>/dev/null || true)
        if [ -n "$k" ]; then echo "$k"; return; fi
    fi
    if [ -f "$KEY_FILE" ]; then python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['privateKey'])" "$KEY_FILE"; return; fi
    die "no Linux manifest key: install the 1Password CLI and sign in (it reads $KEY_REF), or set MIRAGE_LINUX_KEY"
}

build() {
    dir=$1; mkdir -p "$dir"
    n=$(build_number); c=$(commit)
    [ -z "$(git status --porcelain -- Sources linux)" ] || say "note: uncommitted changes in Sources/ or linux/ are not in the build (it is HEAD as committed)"
    arch=$(ssh -o BatchMode=yes "$BUILDER" uname -m) || die "cannot reach the builder $BUILDER over SSH"
    case "$arch" in x86_64|aarch64) ;; *) die "builder $BUILDER is $arch" ;; esac
    say "building $n ($c) for $arch on ${BUILDER}…"
    git archive --format=tar HEAD Sources linux |
        ssh -o BatchMode=yes "$BUILDER" "docker build -q -f linux/Dockerfile --build-arg BUILD=$n --build-arg COMMIT=$c -t mirage-host-build:$n -" >/dev/null ||
        die "the build failed on $BUILDER (run it again without -q there to see why)"
    ssh -o BatchMode=yes "$BUILDER" "docker run --rm mirage-host-build:$n cat /out/mirage-host" > "$dir/mirage-host-linux-$arch.part"
    ssh -o BatchMode=yes "$BUILDER" "docker run --rm mirage-host-build:$n /out/mirage-host version" | grep -q "build $n ($c) $arch" ||
        die "the built binary does not say build $n ($c) $arch"
    ssh -o BatchMode=yes "$BUILDER" "docker image rm -f mirage-host-build:$n >/dev/null" || true
    mv "$dir/mirage-host-linux-$arch.part" "$dir/mirage-host-linux-$arch"
    say "built $dir/mirage-host-linux-$arch ($(wc -c < "$dir/mirage-host-linux-$arch" | tr -d ' ') bytes)"
}

publish() {
    dir=$1
    n=$(build_number); c=$(commit)
    # Hosts install only a higher build: a lower one (a rebased branch) would be ignored by every host, silently.
    live=$(curl -fsSL "https://github.com/$REPO/releases/download/$TAG/linux-x86_64.manifest.json" 2>/dev/null |
        python3 -c "import json,sys; print(json.load(sys.stdin)['build'])" 2>/dev/null || echo 0)
    [ "$n" -gt "$live" ] || die "build $n is not above the published build $live: hosts would ignore it"
    key=$(linux_key)
    cp linux/install.sh "$dir/install.sh"
    bins="" manifests=""
    for a in x86_64 aarch64; do
        b="$dir/mirage-host-linux-$a"
        [ -f "$b" ] || continue
        REL manifest --channel stable --version Linux --build "$n" --commit "$c" --zip "$b" --zip-url "mirage-host-linux-$a" \
            --min-os ubuntu-26.04 --expires-days 365 --out "$dir/linux-$a.manifest.json" >/dev/null
        echo "$key" | REL sign --manifest "$dir/linux-$a.manifest.json" --out "$dir/linux-$a.manifest.sigs.json" >/dev/null
        bins="$bins $b"; manifests="$manifests $dir/linux-$a.manifest.json $dir/linux-$a.manifest.sigs.json"
    done
    [ -n "$bins" ] || die "no binaries in $dir"
    # Binaries first, manifests last: a host never reads a manifest whose binary is not up yet.
    gh release upload "$TAG" -R "$REPO" --clobber "$dir/install.sh" $bins
    gh release upload "$TAG" -R "$REPO" --clobber $manifests
    say "published Linux build $n ($c):$(for b in $bins; do printf ' %s' "${b##*-linux-}"; done)"
}

key_to_1password() {
    f=${1:?key-to-1password FILE}
    command -v op >/dev/null 2>&1 || die "install the 1Password CLI first: brew install 1password-cli (then 1Password › Settings › Developer › Integrate with 1Password CLI)"
    op read "$KEY_REF" >/dev/null 2>&1 && die "1Password already has $KEY_REF"
    python3 - "$f" "$KEY_TITLE" <<'EOF' | op item create --vault "$VAULT" - >/dev/null
import json, sys
k = json.load(open(sys.argv[1]))
print(json.dumps({"title": sys.argv[2], "category": "API_CREDENTIAL",
    "fields": [
        {"id": "credential", "type": "CONCEALED", "label": "credential", "value": k["privateKey"]},
        {"id": "publicKey", "type": "STRING", "label": "public key", "value": k["publicKey"]},
        {"id": "keyID", "type": "STRING", "label": "key ID", "value": k["keyID"]},
        {"id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notesPlain",
         "value": "Signs Mirage's Linux host releases (linux/release.sh). The public half is TrustedKeys.linux in the mirage repo; hosts trust no other key for Linux updates."}]}))
EOF
    [ "$(op read "$KEY_REF")" = "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['privateKey'])" "$f")" ] || die "stored, but reading it back did not match"
    say "stored in 1Password: $KEY_REF"
}

# What a release needs here: the key, and the builder reachable with Docker.
can_release() {
    ok=0
    ( linux_key >/dev/null ) 2>/dev/null || { echo "missing: the Linux manifest key ($KEY_REF)" >&2; ok=1; }
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$BUILDER" 'docker version --format "{{.Server.Version}}"' >/dev/null 2>&1 ||
        { echo "missing: Docker on the Linux builder $BUILDER over SSH (MIRAGE_LINUX_BUILDER)" >&2; ok=1; }
    return $ok
}

case "${1:-}" in
"") d=.build/linux-release/$(build_number); build "$d"; publish "$d" ;;
can-release) can_release ;;
build) build "${2:?build DIR}" ;;
publish) publish "${2:?publish DIR}" ;;
key-to-1password) key_to_1password "${2:-$KEY_FILE}" ;;
*) sed -n 2,17p "$0"; exit 1 ;;
esac
