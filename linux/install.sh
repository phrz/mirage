#!/bin/sh
# Mirage host for Linux: installs mirage-host as a system service that starts at boot and shows the screen itself (the
# login screen, the lock screen, any desktop), and prints a pairing code for Mirage on a Mac when nothing is paired yet.
#
#   curl -fsSL <this script's URL> | sh
#
# Run it as yourself in a terminal (it asks for your password through sudo). Running it again updates mirage-host and
# keeps its pairings. Where the screen cannot be read directly (a GPU's tiled framebuffer), it falls back to sharing your
# GNOME session as a user service, which needs you logged in and keeps the screen from idle-locking.
set -eu

BASE=${MIRAGE_LINUX_BASE:-https://github.com/phrz/mirage/releases/download/linux-host}
BIN=/usr/local/bin/mirage-host
SYSTEM_UNIT=/etc/systemd/system/mirage-host.service
USER_UNIT="$HOME/.config/systemd/user/mirage-host.service"
STORE=/var/lib/mirage
PORT=7799

say() { printf '%s\n' "$*"; }
die() { printf 'mirage: %s\n' "$*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
case "$(uname -m)" in
    x86_64|amd64) ARCH=x86_64 ;;
    aarch64|arm64) ARCH=aarch64 ;;
    *) die "unsupported processor $(uname -m)" ;;
esac

say "Downloading mirage-host ($ARCH)…"
TMP=$(mktemp)
curl -fsSL "$BASE/mirage-host-linux-$ARCH" -o "$TMP" || die "download failed: $BASE/mirage-host-linux-$ARCH"
chmod 755 "$TMP"

# Libraries the system may lack (openssl makes the host's TLS certificate).
MISSING=$(ldd "$TMP" 2>/dev/null | awk '/not found/ {print $1}')
PKGS=""
for lib in $MISSING; do
    case "$lib" in
        libpipewire-0.3.so.*) PKGS="$PKGS libpipewire-0.3-0t64" ;;
        libdrm.so.*) PKGS="$PKGS libdrm2" ;;
        *) PKGS="$PKGS $lib" ;;
    esac
done
command -v openssl >/dev/null 2>&1 || PKGS="$PKGS openssl"
if [ -n "$PKGS" ]; then
    say "Installing:$PKGS"
    $SUDO apt-get install -y $PKGS || die "could not install$PKGS"
fi
$SUDO install -m 755 "$TMP" "$BIN"
rm -f "$TMP"
rm -f "$HOME/.local/bin/mirage-host"   # an earlier per-user install

# Virtual keyboard and pointer, now and at every boot.
$SUDO modprobe uinput 2>/dev/null || true
echo uinput | $SUDO tee /etc/modules-load.d/mirage.conf >/dev/null

if command -v ufw >/dev/null 2>&1 && grep -q '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
    $SUDO ufw allow $PORT/udp >/dev/null && say "Firewall: allowed UDP $PORT"
fi

user_service() {
    # GNOME's own sharing, as the logged-in user.
    [ -n "${XDG_RUNTIME_DIR:-}" ] || die "no desktop session here: open a terminal on the desktop and run this there"
    mkdir -p "$(dirname "$USER_UNIT")"
    cat >"$USER_UNIT" <<EOF
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
    say "mirage-host is running and starts when you log in."
    say "Logs: journalctl --user -u mirage-host -f"
    PAIR="$BIN pair"
    PAIRED=$("$BIN" devices 2>/dev/null | grep -vc '^no paired devices' || true)
}

system_service() {
    # Pairings and identity from an earlier per-user install come along, so paired Macs keep connecting.
    if ! $SUDO test -d "$STORE" && [ -d "$HOME/.local/share/Mirage" ]; then
        $SUDO cp -a "$HOME/.local/share/Mirage" "$STORE"
        $SUDO chown -R root:root "$STORE"
        $SUDO chmod 700 "$STORE"
        say "Kept the pairings of the earlier install."
    fi
    $SUDO tee "$SYSTEM_UNIT" >/dev/null <<EOF
[Unit]
Description=Mirage host (shares this computer's screen with paired Mirage viewers)
After=network-online.target systemd-user-sessions.service
Wants=network-online.target

[Service]
ExecStartPre=-/sbin/modprobe uinput
ExecStart=$BIN serve
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    # The per-user service of an earlier install goes (a viewer connected through it reconnects in a moment).
    if [ -f "$USER_UNIT" ]; then
        systemctl --user disable --now mirage-host.service >/dev/null 2>&1 || true
        rm -f "$USER_UNIT"
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable mirage-host.service >/dev/null 2>&1
    $SUDO systemctl restart mirage-host.service
    sleep 1
    $SUDO systemctl is-active --quiet mirage-host.service || {
        $SUDO journalctl -u mirage-host.service -n 20 --no-pager
        die "mirage-host did not start (log above)"
    }
    say "mirage-host is running and starts at boot: Mirage shows the login screen, the lock screen and the desktop."
    say "Logs: sudo journalctl -u mirage-host -f"
    PAIR="$SUDO $BIN pair"
    PAIRED=$($SUDO "$BIN" devices 2>/dev/null | grep -vc '^no paired devices' || true)
}

say "Checking that this computer's screen can be shown…"
if CHECK=$($SUDO "$BIN" check 2>&1); then
    say "$CHECK"
    system_service
else
    say "$CHECK"
    say "Sharing your GNOME session instead (needs you logged in)."
    user_service
fi

if [ "${PAIRED:-0}" -gt 0 ]; then
    say "Already paired; pair another device with:  $PAIR"
elif (: </dev/tty) 2>/dev/null; then
    $PAIR </dev/tty
else
    say "Pair a Mac: run  $PAIR"
fi
