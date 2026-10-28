#!/bin/sh
# Installs Mirage on this Mac as a host, from the release feed (DESIGN §3.10, U5): one command, run by a person at the
# new Mac (or by scripts/fleet.sh over SSH: `ssh HOST 'sh -s -- --channel nightly' < scripts/install-host.sh`).
#
#   1. fetches the channel head (github.com/phrz/mirage releases, HTTPS only: channel-<name>/manifest.json and its
#      signatures) and verifies it before anything else: an Ed25519 signature by a key embedded below (macOS's own perl,
#      no other tools), for this channel, not expired, and naming a build at or above this channel's floor below (so a
#      replayed old manifest cannot install an old build);
#   2. downloads the zip it names, checks its size and SHA-256, lists it (no absolute paths, no "..", no symlink out),
#      and unpacks it into a fresh directory;
#   3. checks the bundle with this Mac's own tools before running anything from it: the code-signing requirement pinned
#      for Mirage (Apple-anchored, com.paulherz.mirage / com.paulherz.mirage.host, team M8MME6Q9DA), Gatekeeper's
#      notarization assessment, and that its sealed Info.plist is the manifest's build;
#   4. hands over to the bundle's own miraged (`update --install-bundle`): it verifies the manifest again with the keys
#      it was built with, checks the bundle as the updater does (self-test included), refuses a signing-identity change
#      over an installed Mirage unless --allow-identity-change, installs /Applications/Mirage.app (over an older install
#      through the updater's own swap, trial and commit), sets the channel and policy, turns the host on, and prints the
#      Screen Recording and Device Control (Accessibility) steps, named as this Mac's System Settings names them.
#
#   scripts/install-host.sh [--channel stable|beta|nightly] [--policy ask|automatic] [--viewer-only] [--force]
#                           [--allow-identity-change] [--dry-run] [--verify-only] [--feed URL] [--app PATH]
#     --viewer-only  this Mac connects to others but is not shared: the same signed /Applications/Mirage.app, with Share
#                    This Mac off (the host agent only keeps Mirage up to date; no permissions are asked). Turn sharing on
#                    later in Mirage's menu.
#
#   A host (shared):   sh install-host.sh --channel nightly
#   A viewer-only Mac: sh install-host.sh --channel nightly --viewer-only
#     --dry-run      verify everything and say what would happen; change nothing
#     --verify-only  verify the channel head (step 1) and stop
#     --force        reinstall even when this build or a newer one is installed
#     --feed         another feed (an https URL, or file:// for tests); it must still be signed by an embedded key
#     --app PATH     install somewhere else than /Applications/Mirage.app (tests, with --dry-run)
# Run it as the person logged in at this Mac (not root): the settings, the kept previous build and the host agent are
# theirs.
set -e

# BEGIN MIRAGE MANIFEST KEYS (scripts/release.sh keys-init writes these; release.sh --check keeps them equal to
# Sources/MirageCore/Update/TrustedKeys.swift; release.sh raises the floors as it publishes)
TRUSTED_KEYS="RkdiYPOI6pgPA7XtzSH8qSYzO01fsuWk2nXTGl4sA6c= xt0I5ZG+3e8M5gXc1odsxj+dC7xjmtH2+nqCSLGn3/I="
REVOKED_KEYS=""
MIN_BUILD_STABLE=0
MIN_BUILD_BETA=0
MIN_BUILD_NIGHTLY=564
# END MIRAGE MANIFEST KEYS

CHANNEL=stable; POLICY=; FORCE=; ALLOW_ID=; DRY=; TARGET=; VERIFY_ONLY=; VIEWER_ONLY=
FEED=https://github.com/phrz/mirage/releases/download
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL=$2; shift 2 ;;
        --policy) POLICY=$2; shift 2 ;;
        --force) FORCE=1; shift ;;
        --viewer-only) VIEWER_ONLY=1; shift ;;
        --allow-identity-change) ALLOW_ID=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --verify-only) VERIFY_ONLY=1; shift ;;
        --feed) FEED=${2%/}; shift 2 ;;
        --app) TARGET=$2; shift 2 ;;
        -h|--help) sed -n '2,34p' "$0" 2>/dev/null || true; exit 0 ;;
        *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
done
case "$CHANNEL" in stable|beta|nightly) ;; *) echo "error: --channel is stable, beta or nightly" >&2; exit 2 ;; esac
case "$POLICY" in ""|ask|automatic) ;; *) echo "error: --policy is ask or automatic" >&2; exit 2 ;; esac
case "$CHANNEL" in stable) FLOOR=$MIN_BUILD_STABLE ;; beta) FLOOR=$MIN_BUILD_BETA ;; nightly) FLOOR=$MIN_BUILD_NIGHTLY ;; esac
# Tests only, and only to verify: other keys, floor and clock (never for an install).
if [ -n "$VERIFY_ONLY" ]; then
    TRUSTED_KEYS=${MIRAGE_INSTALL_TEST_KEYS:-$TRUSTED_KEYS}
    FLOOR=${MIRAGE_INSTALL_TEST_MIN_BUILD:-$FLOOR}
fi
DR_APP='anchor apple generic and identifier "com.paulherz.mirage" and certificate leaf[subject.OU] = "M8MME6Q9DA"'
DR_HOST='anchor apple generic and identifier "com.paulherz.mirage.host" and certificate leaf[subject.OU] = "M8MME6Q9DA"'
die() { echo "error: $*" >&2; exit 1; }

if [ -z "$VERIFY_ONLY" ]; then
    [ "$(id -u)" != 0 ] || die "do not run this as root (sudo): run it as the person logged in at this Mac"
    CONSOLE=$(stat -f %Su /dev/console 2>/dev/null || echo "?")
    [ "$CONSOLE" != root ] || die "nobody is logged in at this Mac: a person must log in first (the host runs in their session)"
    [ "$CONSOLE" = "$(id -un)" ] || die "this runs as $(id -un), but $CONSOLE is logged in at this Mac: run it as $CONSOLE (the settings and the host agent are theirs)"
    MAJOR=$(sw_vers -productVersion | cut -d. -f1)
    [ "$MAJOR" -ge 15 ] || die "Mirage needs macOS 15 or later (this Mac has $(sw_vers -productVersion))"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mirage-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM   # the EXIT trap cleans up
case "$FEED" in https://*) PROTO="=https" ;; file://*) PROTO="=file" ;; *) die "--feed must be https:// (or file:// for tests)" ;; esac
fetch() { curl -fsSL --proto "$PROTO" --proto-redir "$PROTO" --retry 2 --max-time 600 -o "$2" "$1" || die "cannot fetch $1"; }

# Ed25519 (RFC 8032 §5.1.7) with macOS's own perl (Math::BigInt, Digest::SHA, MIME::Base64: all core). Arguments: the
# manifest, its signatures file, then trusted keys (base64); REVOKED holds revoked key IDs. Exit 0 and print the key ID
# when a trusted, unrevoked key's signature verifies.
cat > "$WORK/ed25519.pl" <<'PERL'
use strict; use warnings;
use Math::BigInt; use Digest::SHA qw(sha512 sha256); use MIME::Base64 qw(decode_base64);
my $p = Math::BigInt->new(2)->bpow(255)->bsub(19);
my $L = Math::BigInt->new(2)->bpow(252)->badd(Math::BigInt->new('27742317777372353535851937790883648493'));
sub md { return $_[0] % $p; }
sub inv { return $_[0]->copy->bmodpow($p - 2, $p); }
my $d = md(Math::BigInt->new(-121665) * inv(Math::BigInt->new(121666)));
my $I = Math::BigInt->new(2)->bmodpow(($p - 1) / 4, $p);
sub lenum { return Math::BigInt->from_hex(unpack('H*', scalar reverse $_[0]) || '0'); }
sub recover_x {
    my ($y, $sign) = @_;
    return undef if $y >= $p;
    my $y2 = md($y * $y);
    my $x2 = md(($y2 - 1) * inv(md($d * $y2 + 1)));
    if ($x2->is_zero) { return $sign ? undef : Math::BigInt->new(0); }
    my $x = $x2->copy->bmodpow(($p + 3) / 8, $p);
    $x = md($x * $I) if md($x * $x - $x2) != 0;
    return undef if md($x * $x - $x2) != 0;
    $x = $p - $x if ($x->copy->band(1)->numify) != $sign;
    return $x;
}
sub decode_point {
    my $b = shift;
    return undef unless length($b) == 32;
    my $n = lenum($b);
    my $sign = $n->copy->brsft(255)->numify & 1;
    my $y = $n->copy->band(Math::BigInt->new(2)->bpow(255)->bsub(1));
    my $x = recover_x($y, $sign);
    return undef unless defined $x;
    return [$x, $y, Math::BigInt->new(1), md($x * $y)];
}
sub add {
    my ($P, $Q) = @_;
    my $A = md(($P->[1] - $P->[0]) * ($Q->[1] - $Q->[0]));
    my $B = md(($P->[1] + $P->[0]) * ($Q->[1] + $Q->[0]));
    my $C = md(2 * $P->[3] * $Q->[3] * $d);
    my $D = md(2 * $P->[2] * $Q->[2]);
    my ($E, $F, $G, $H) = ($B - $A, $D - $C, $D + $C, $B + $A);
    return [md($E * $F), md($G * $H), md($F * $G), md($E * $H)];
}
sub mul {
    my ($s, $P) = @_;
    my $Q = [Math::BigInt->new(0), Math::BigInt->new(1), Math::BigInt->new(1), Math::BigInt->new(0)];
    my $bits = $s->copy->as_bin; $bits =~ s/^0b//;
    for my $bit (split //, $bits) { $Q = add($Q, $Q); $Q = add($Q, $P) if $bit eq '1'; }
    return $Q;
}
sub equal { my ($P, $Q) = @_; return md($P->[0] * $Q->[2] - $Q->[0] * $P->[2]) == 0 && md($P->[1] * $Q->[2] - $Q->[1] * $P->[2]) == 0; }
my $Gy = md(4 * inv(Math::BigInt->new(5)));
my $G = [recover_x($Gy, 0), $Gy, Math::BigInt->new(1), undef]; $G->[3] = md($G->[0] * $G->[1]);
sub verify {
    my ($pub, $sig, $msg) = @_;
    return 0 unless length($pub) == 32 && length($sig) == 64;
    my $A = decode_point($pub) or return 0;
    my $Rs = substr($sig, 0, 32);
    my $R = decode_point($Rs) or return 0;
    my $S = lenum(substr($sig, 32, 32));
    return 0 if $S >= $L;
    my $k = lenum(sha512($Rs . $pub . $msg)) % $L;
    return equal(mul($S, $G), add($R, mul($k, $A)));
}
my ($manifest, $sigs, @keys) = @ARGV;
sub slurp { open(my $f, '<:raw', $_[0]) or die "cannot read $_[0]\n"; local $/; my $c = <$f>; close $f; return $c; }
my $msg = slurp($manifest); my $sj = slurp($sigs);
my %sig; while ($sj =~ /"([0-9a-f]{16})"\s*:\s*"([A-Za-z0-9+\/=\\]+)"/g) { my ($id, $v) = ($1, $2); $v =~ s/\\//g; $sig{$id} = $v; }   # JSON may escape "/" as "\/"
my %revoked = map { $_ => 1 } split ' ', ($ENV{REVOKED} // '');
for my $k (@keys) {
    my $pub = decode_base64($k);
    my $id = unpack('H*', substr(sha256($pub), 0, 8));
    next if $revoked{$id} || !exists $sig{$id};
    if (verify($pub, decode_base64($sig{$id}), $msg)) { print "$id\n"; exit 0; }
}
exit 1;
PERL

MURL=$FEED/channel-$CHANNEL/manifest.json
echo "== $CHANNEL channel head: $MURL"
fetch "$MURL" "$WORK/manifest.json"
fetch "${MURL%/*}/manifest.sigs.json" "$WORK/manifest.sigs.json"
# shellcheck disable=SC2086
KEYID=$(REVOKED=$REVOKED_KEYS /usr/bin/perl "$WORK/ed25519.pl" "$WORK/manifest.json" "$WORK/manifest.sigs.json" $TRUSTED_KEYS) \
    || die "the channel head is not signed by a key this script trusts"
field() { plutil -extract "$1" raw -o - "$WORK/manifest.json" 2>/dev/null || die "the manifest has no $1"; }
VERSION=$(field version); BUILD=$(field build); ZIPURL=$(field zipURL); SHA=$(field zipSHA256); SIZE=$(field zipSize)
[ "$(field channel)" = "$CHANNEL" ] || die "the manifest is for $(field channel), not $CHANNEL"
NOW=${MIRAGE_INSTALL_TEST_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
[ -z "$VERIFY_ONLY" ] && NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EXPIRES=$(field expires)
[ "$(printf '%s\n%s\n' "$NOW" "$EXPIRES" | sort | head -1)" = "$NOW" ] && [ "$NOW" != "$EXPIRES" ] || die "the manifest expired at $EXPIRES"
[ "$BUILD" -ge "$FLOOR" ] 2>/dev/null || die "the channel head names build $BUILD, below this script's floor $FLOOR for $CHANNEL (an old or replayed manifest)"
echo "   signed by $KEYID: Mirage $VERSION ($BUILD), expires $EXPIRES"
[ -z "$VERIFY_ONLY" ] || { echo "manifest ok"; exit 0; }

case "$ZIPURL" in https://*|file://*) ;; *) ZIPURL=${MURL%/*}/$ZIPURL ;; esac   # relative to the manifest
echo "== downloading $ZIPURL"
fetch "$ZIPURL" "$WORK/Mirage.zip"
[ "$(stat -f %z "$WORK/Mirage.zip")" = "$SIZE" ] || die "the zip is $(stat -f %z "$WORK/Mirage.zip") bytes, the manifest says $SIZE"
GOT=$(shasum -a 256 "$WORK/Mirage.zip" | cut -d' ' -f1 | tr 'A-F' 'a-f')
[ "$GOT" = "$(printf '%s' "$SHA" | tr 'A-F' 'a-f')" ] || die "the zip's SHA-256 does not match the manifest"
# Every entry inside Mirage.app/, none absolute or climbing out, and no symlink pointing out.
zipinfo -1 "$WORK/Mirage.zip" > "$WORK/entries" || die "cannot list the zip"
! grep -Eqv '^Mirage\.app/' "$WORK/entries" || die "the zip holds entries outside Mirage.app/"
! grep -Eq '(^/|(^|/)\.\.(/|$))' "$WORK/entries" || die "the zip holds an absolute or climbing path"
zipinfo -l "$WORK/Mirage.zip" | awk '$1 ~ /^l/ { print substr($0, index($0, $10)) }' > "$WORK/links"
while IFS= read -r link; do
    [ -n "$link" ] || continue
    target=$(unzip -p "$WORK/Mirage.zip" "$link")
    case "$target" in /*|*..*) die "the zip's symlink $link points out ($target)" ;; esac
done < "$WORK/links"
mkdir "$WORK/x"
ditto -x -k "$WORK/Mirage.zip" "$WORK/x" || die "cannot unpack the zip"
APP=$WORK/x/Mirage.app
[ -d "$APP" ] || die "the zip holds no Mirage.app"

echo "== checking the bundle with this Mac's tools"
codesign --verify --strict --deep -R="$DR_APP" "$APP" 2>/dev/null || die "Mirage.app is not signed by team M8MME6Q9DA as com.paulherz.mirage"
codesign --verify --strict -R="$DR_HOST" "$APP/Contents/MacOS/miraged" 2>/dev/null || die "its miraged is not signed by team M8MME6Q9DA as com.paulherz.mirage.host"
ASSESS=$(spctl --assess --type execute -vv "$APP" 2>&1) || die "Gatekeeper rejects it: $ASSESS"
case "$ASSESS" in *accepted*"source=Notarized Developer ID"*) ;; *) die "Gatekeeper does not accept it as a notarized Developer ID app: $ASSESS" ;; esac
SEALED=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
[ "$SEALED" = "$BUILD" ] || die "the bundle is build $SEALED, the manifest says $BUILD"
echo "   signed by M8MME6Q9DA, notarized, build $SEALED"

# Builds before U5 have no installer half: say so rather than install without its own checks.
"$APP/Contents/MacOS/miraged" update --help 2>/dev/null | grep -q -- --status-line \
    || die "Mirage $VERSION ($BUILD) predates install-host.sh's installer (U5): wait for a newer $CHANNEL build, or install by hand"
set -- update --install-bundle "$APP" --manifest "$WORK/manifest.json" --sigs "$WORK/manifest.sigs.json" --channel "$CHANNEL"
[ -n "$POLICY" ] && set -- "$@" --set "policy=$POLICY"
[ -n "$FORCE" ] && set -- "$@" --force
[ -n "$ALLOW_ID" ] && set -- "$@" --allow-identity-change
[ -n "$DRY" ] && set -- "$@" --dry-run
[ -n "$TARGET" ] && set -- "$@" --app "$TARGET"
if [ -n "$VIEWER_ONLY" ]; then
    "$APP/Contents/MacOS/miraged" update --help-hidden 2>/dev/null | grep -q -- --share \
        || die "Mirage $VERSION ($BUILD) predates --viewer-only: wait for a newer $CHANNEL build"
    set -- "$@" --share off
fi
echo "== installing (the bundle's own miraged verifies the manifest again with its built-in keys)"
"$APP/Contents/MacOS/miraged" "$@"
