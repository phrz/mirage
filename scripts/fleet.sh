#!/bin/sh
# Runs Mirage's per-host commands over SSH on every Mac in a hosts file, in parallel, and prints one line per host
# (DESIGN §3.10, U5): phrz's Workbench and ARD Macs.
#
#   scripts/fleet.sh [--dry-run] HOSTS_FILE status
#   scripts/fleet.sh [--dry-run] HOSTS_FILE install [--channel stable|beta|nightly] [--policy ask|automatic]
#   scripts/fleet.sh [--dry-run] HOSTS_FILE update
#
#   HOSTS_FILE: one SSH destination per line (a name from ~/.ssh/config, user@host, …); # starts a comment.
#   status    `miraged update --status-line` on each: version, channel, latest, agent, streaming, grants, policy
#   install   scripts/install-host.sh on each (through `sh -s`); on a Mac that has Mirage it replaces an older build
#   update    `miraged update --now` on each (the same updater as the remote trigger)
#   --dry-run print what would run, run nothing
#
# Never changes a signing identity remotely: neither install-host.sh nor `miraged update` crosses one without
# --allow-identity-change, which this script never passes (and refuses to). Such a host reports the refusal; its grants
# and agent registration need a person at that Mac. A fresh install over SSH also ends with steps for a person there
# (the grants, which TCC never allows remotely, and Login Items approval if macOS asks).
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
DRY=
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
HOSTS=${1:?usage: scripts/fleet.sh [--dry-run] HOSTS_FILE status|install|update [--channel c] [--policy p]}
ACTION=${2:?usage: scripts/fleet.sh [--dry-run] HOSTS_FILE status|install|update}
shift 2
CHANNEL=; POLICY=
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL=$2; shift 2 ;;
        --policy) POLICY=$2; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --allow-identity-change) echo "error: fleet.sh never changes a signing identity remotely: run install-host.sh --allow-identity-change at that Mac" >&2; exit 2 ;;
        *) echo "error: unknown option $1" >&2; exit 2 ;;
    esac
done
case "$ACTION" in status|install|update) ;; *) echo "error: the action is status, install or update" >&2; exit 2 ;; esac
[ -f "$HOSTS" ] || { echo "error: no hosts file $HOSTS" >&2; exit 2; }
case "$CHANNEL" in ""|stable|beta|nightly) ;; *) echo "error: --channel is stable, beta or nightly" >&2; exit 2 ;; esac
case "$POLICY" in ""|ask|automatic) ;; *) echo "error: --policy is ask or automatic" >&2; exit 2 ;; esac

MIRAGED=/Applications/Mirage.app/Contents/MacOS/miraged
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8"
INSTALL_ARGS=
[ -n "$CHANNEL" ] && INSTALL_ARGS="$INSTALL_ARGS --channel $CHANNEL"
[ -n "$POLICY" ] && INSTALL_ARGS="$INSTALL_ARGS --policy $POLICY"
HOSTLIST=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$HOSTS" | awk '{print $1}')
[ -n "$HOSTLIST" ] || { echo "error: $HOSTS lists no hosts" >&2; exit 2; }

# One host, one action. $1 = host, $2 = action.
remote() {
    case "$2" in
        status) $SSH "$1" "$MIRAGED update --status-line" ;;
        install) $SSH "$1" "sh -s --$INSTALL_ARGS" < "$DIR/install-host.sh" ;;
        update) $SSH "$1" "$MIRAGED update --now" ;;
    esac
}
describe() {
    case "$2" in
        status) echo "$SSH $1 '$MIRAGED update --status-line'" ;;
        install) echo "$SSH $1 'sh -s --$INSTALL_ARGS' < $DIR/install-host.sh" ;;
        update) echo "$SSH $1 '$MIRAGED update --now'" ;;
    esac
}

if [ -n "$DRY" ]; then
    for h in $HOSTLIST; do describe "$h" "$ACTION"; done
    [ "$ACTION" = status ] || for h in $HOSTLIST; do describe "$h" status; done
    exit 0
fi

OUT=$(mktemp -d "${TMPDIR:-/tmp}/mirage-fleet.XXXXXX")
trap 'rm -rf "$OUT"' EXIT INT TERM
# All hosts at once; each one's output in its own log.
run_all() {
    i=0
    for h in $HOSTLIST; do
        i=$((i + 1))
        ( set +e; remote "$h" "$1" > "$OUT/$i.$1.log" 2>&1; echo $? > "$OUT/$i.$1.rc" ) &
    done
    wait
}

failed=0
if [ "$ACTION" != status ]; then
    echo "== $ACTION on $(echo "$HOSTLIST" | wc -l | tr -d ' ') hosts"
    run_all "$ACTION"
    i=0
    for h in $HOSTLIST; do
        i=$((i + 1))
        rc=$(cat "$OUT/$i.$ACTION.rc")
        [ "$rc" = 0 ] && mark=ok || { mark="FAILED ($rc)"; failed=1; }
        echo "-- $h: $mark"
        tail -n 4 "$OUT/$i.$ACTION.log" | sed 's/^/   /'
    done
    echo
fi

run_all status
i=0
for h in $HOSTLIST; do
    i=$((i + 1))
    rc=$(cat "$OUT/$i.status.rc")
    case "$rc" in
        0) line=$(tail -n 1 "$OUT/$i.status.log") ;;
        255) line="unreachable over SSH" ;;
        127) line="Mirage not installed" ;;
        *) line="status failed ($rc): $(tail -n 1 "$OUT/$i.status.log")" ;;
    esac
    printf '%-18s %s\n' "$h" "$line"
done
exit $failed
