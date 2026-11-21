#!/bin/sh
# Mirage host for Linux (GNOME on Wayland): installs mirage-host for the logged-in user, starts it with the desktop
# session, and prints a pairing code for the Mirage app on a Mac.
#
#   curl -fsSL <this script's URL> | sh
#
# Run it in a terminal of the desktop session you want to share, as yourself (not with sudo). It asks for your password
# only if a library or the firewall needs changing.
set -eu

BASE=${MIRAGE_LINUX_BASE:-https://github.com/phrz/mirage/releases/download/linux-host}
BIN="$HOME/.local/bin/mirage-host"
UNIT="$HOME/.config/systemd/user/mirage-host.service"
PORT=7799

say() { printf '%s\n' "$*"; }
die() { printf 'mirage: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run this as yourself, in your desktop session (not with sudo)"
case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) die "unsupported processor $(uname -m)" ;;
esac
[ -n "${XDG_RUNTIME_DIR:-}" ] || die "no desktop session here (XDG_RUNTIME_DIR is not set): open a terminal on the desktop and run this there"

say "Downloading mirage-host ($ARCH)…"
mkdir -p "$HOME/.local/bin" "$(dirname "$UNIT")"
TMP=$(mktemp)
curl -fsSL "$BASE/mirage-host-linux-$ARCH" -o "$TMP" || die "download failed: $BASE/mirage-host-linux-$ARCH"
chmod 755 "$TMP"

# Libraries the desktop may lack (x265 encodes the picture; openssl makes the host's TLS certificate).
MISSING=$(ldd "$TMP" 2>/dev/null | awk '/not found/ {print $1}')
PKGS=""
for lib in $MISSING; do
    case "$lib" in
        libx265.so.*) PKGS="$PKGS libx265-${lib#libx265.so.}" ;;
        libnuma.so.*) PKGS="$PKGS libnuma1" ;;
        libpipewire-0.3.so.*) PKGS="$PKGS libpipewire-0.3-0t64" ;;
        *) PKGS="$PKGS $lib" ;;
    esac
done
command -v openssl >/dev/null 2>&1 || PKGS="$PKGS openssl"
if [ -n "$PKGS" ]; then
    say "Installing:$PKGS"
    sudo apt-get install -y $PKGS || die "could not install$PKGS"
fi
mv -f "$TMP" "$BIN"

# The firewall, when ufw is on.
if command -v ufw >/dev/null 2>&1 && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
    sudo ufw allow $PORT/udp >/dev/null && say "Firewall: allowed UDP $PORT"
fi

cat >"$UNIT" <<EOF
[Unit]
Description=Mirage host
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=$BIN serve
Restart=always
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF
systemctl --user daemon-reload
systemctl --user enable mirage-host.service >/dev/null 2>&1
systemctl --user restart mirage-host.service
sleep 1
systemctl --user is-active --quiet mirage-host.service || {
    journalctl --user -u mirage-host.service -n 20 --no-pager
    die "mirage-host did not start (log above)"
}
say "mirage-host is running and starts with your desktop session."
say "Logs: journalctl --user -u mirage-host -f"

# Pairing reads the Allow answer from the terminal (the script itself may be on stdin).
if [ -r /dev/tty ]; then
    "$BIN" pair </dev/tty
else
    say "Pair a Mac: run  mirage-host pair"
fi
