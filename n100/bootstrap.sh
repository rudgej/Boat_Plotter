#!/usr/bin/env bash
#
# Boat Plotter - N100 bootstrap
#
# Run ON the freshly installed Debian 13 box, from the root of this repo:
#
#     sudo ./n100/bootstrap.sh
#     sudo ./n100/bootstrap.sh --check     # report only, change nothing
#
# Automates the mechanical half of MIGRATION.md: packages (1.4/1.5), the one
# Python dep Debian lacks, config restore (4), the dock build (7), udev and
# enabling the units (4). Idempotent - safe to re-run.
#
# It deliberately does NOT do:
#   - BIOS settings (auto power-on, Secure Boot, Intel VMD)   -> MIGRATION 1
#   - RS485 board jumpers                                     -> MIGRATION 6
#   - the Debian install itself                               -> MIGRATION 1
#   - Signal K first login, Data Connections, plugin installs -> MIGRATION 2, 5  (browser)
#   - AvNav chart re-licensing                                -> MIGRATION 3
#   - Tailscale login                                         -> MIGRATION 11
#
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$REPO_DIR/pi-dock/pi-config"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    ok   %s\n' "$*"; }
warn() { printf '    WARN %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if [[ $CHECK_ONLY -eq 1 ]]; then printf '    would: %s\n' "$*"; else "$@"; fi; }

PKGS="git curl wget htop lm-sensors hostapd dnsmasq network-manager labwc kanshi
squeekboard pcmanfm libgtk-3-dev libgtk-layer-shell-dev gcc pkg-config python3
python3-pip bluez bluez-tools pipewire pipewire-pulse wireplumber can-utils jq picocom
chromium nodejs nginx rclone zenity grim wlr-randr"

UNITS="boatnetwork.service boatnetwork-dnsmasq.service can0-nmea2000.service
can-watchdog.timer shelly-watchdog.timer holding-tank-dump.service
cockpit-light.service memwatch.timer set-timezone.timer bt-hifi.service
manuals-sync.timer"

say "0. sanity"
[[ -d "$REPO_DIR/pi-dock" ]] || { echo "pi-dock/ not found - run from the repo root" >&2; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || warn "arch is $(uname -m), expected x86_64 - is this the N100?"
[[ $EUID -eq 0 || $CHECK_ONLY -eq 1 ]] || { echo "run with sudo (or use --check)" >&2; exit 1; }
ok "repo at $REPO_DIR"

say "1. packages (MIGRATION 1.4)"
missing=""
for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || missing="$missing $p"; done
if [[ -n "${missing// /}" ]]; then
    warn "missing:$missing"
    run apt-get update -qq
    # shellcheck disable=SC2086
    run apt-get install -y $missing
else
    ok "all present"
fi

say "2. python deps Debian does not package (MIGRATION 1.5)"
if python3 -c "import timezonefinder" 2>/dev/null; then
    ok "timezonefinder present"
else
    warn "timezonefinder missing (needed by set-timezone.timer)"
    run python3 -m pip install --break-system-packages -q timezonefinder
fi

say "3. restore pi-config (MIGRATION 4)"
for d in etc usr home var; do
    [[ -d "$CFG/$d" ]] || continue
    if [[ $CHECK_ONLY -eq 1 ]]; then
        printf '    would: cp -a %s/%s/. /%s/\n' "$CFG" "$d" "$d"
    else
        cp -a "$CFG/$d/." "/$d/" && ok "restored /$d"
    fi
done
[[ -d "$CFG/boot" ]] && ok "boot/ skipped (Pi config.txt - x86 uses GRUB)"

say "4. dock (MIGRATION 7) - dock.c is GTK3"
if have pkg-config && pkg-config --exists gtk-layer-shell-0 2>/dev/null; then
    run gcc "$REPO_DIR/pi-dock/dock.c" -o /usr/local/bin/pi-dock \
        $(pkg-config --cflags --libs gtk+-3.0 gtk-layer-shell-0) \
        && ok "dock built (GTK3 layer-shell)" || warn "dock build failed"
else
    warn "gtk-layer-shell-0 not found - need libgtk-3-dev libgtk-layer-shell-dev"
fi

say "5. KIP Engine dashboard (MIGRATION 2.8)"
if [[ -f "$REPO_DIR/pi-dock/kip-config.json" ]]; then
    run cp "$REPO_DIR/pi-dock/kip-config.json" "$REPO_DIR/pi-dock/inject-kip.mjs" /home/pi/
    if [[ $CHECK_ONLY -eq 0 ]]; then
        chown pi:pi /home/pi/kip-config.json /home/pi/inject-kip.mjs 2>/dev/null
    fi
    ok "kip-config.json + inject-kip.mjs -> /home/pi/"
    ok "run ./pi-dock/inject-kip.sh LATER, once Signal K + chromium are up"
else
    warn "pi-dock/kip-config.json not found"
fi

say "6. udev + units (MIGRATION 4/5/6)"
run udevadm control --reload
run udevadm trigger		# creates /dev/rs485-* symlinks now, not only at next boot
run systemctl daemon-reload
for u in $UNITS; do
    if [[ -e "/etc/systemd/system/$u" ]]; then
        if [[ $CHECK_ONLY -eq 1 ]]; then
            printf '    would: systemctl enable --now %s\n' "$u"
        else
            systemctl enable --now "$u" >/dev/null 2>&1 && ok "enabled $u" || warn "failed to enable $u"
        fi
    else
        warn "$u not found in /etc/systemd/system"
    fi
done
ok "NOT enabled (Pi-only): gpu-noidle, nvme-noidle, diagwatch, opencpn-*"

say "7. verification"
if [[ -d /sys/class/net/can0 ]]; then ok "can0 exists"
else warn "can0 missing - check 'lsusb | grep 1d50:606f' (MIGRATION 5)"; fi
for p in /dev/rs485-1 /dev/rs485-2; do
    if [[ -e $p ]]; then ok "$p present"
    else warn "$p missing - are the RS485 jumpers set? (MIGRATION 6)"; fi
done
if systemctl is-active --quiet signalk 2>/dev/null; then ok "signalk running"
else warn "signalk not running yet - install it (MIGRATION 2)"; fi

cat <<'STILL'

==> still needs hands (cannot be scripted)
    1. BIOS: Restore AC Power Loss = Power On, Secure Boot off, Intel VMD off    (MIGRATION 1)
    2. Signal K first login; NMEA 2000 connection -> SocketCAN -> can0           (MIGRATION 5)
    3. Appstore: signalk-to-nmea2000 + Wind(130306); fuel-economy;               (MIGRATION 2)
       holdingtank-status; then run signalk-zones/set-zones.py
    4. AvNav ocharts re-licence (machine-bound fingerprint)                       (MIGRATION 3)
    5. RS485 data connections, input-only: 4800 and 38400                        (MIGRATION 6)
    6. Tailscale login                                                            (MIGRATION 11)
    7. Unattended power-cycle test                                                (MIGRATION 10)

STILL
