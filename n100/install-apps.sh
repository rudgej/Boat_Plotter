#!/usr/bin/env bash
#
# Boat Plotter - install the application layer
#
#   sudo ./n100/install-apps.sh
#   sudo ./n100/install-apps.sh --check    # show what would happen
#
# Run AFTER ./n100/bootstrap.sh. Needs internet throughout - Debian's netinst
# requires it anyway, so the box will be online.
#
# Rationale: these cannot sensibly be pre-downloaded to a USB stick. apt and
# npm both need repository indexes and dependency resolution, so staging them
# by hand from a Mac produces missing-dependency failures on the day. What
# actually costs time is reading docs and typing commands, not bandwidth - so
# this script handles the deterministic parts and prints the rest.
#
set -uo pipefail

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '    ok   %s\n' "$*"; }
warn() { printf '    WARN %s\n' "$*"; }
run()  { if [[ $CHECK_ONLY -eq 1 ]]; then printf '    would: %s\n' "$*"; else "$@"; fi; }

[[ $EUID -eq 0 || $CHECK_ONLY -eq 1 ]] || { echo "run with sudo (or --check)" >&2; exit 1; }

say "1. Node 22 (Signal K 2.37 needs >=22; Debian 13 ships 20.19)"
NODE_MAJOR=$(node --version 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
if [[ "${NODE_MAJOR:-0}" -ge 22 ]]; then
    ok "node $(node --version)"
else
    warn "node ${NODE_MAJOR:-not installed} - adding NodeSource 22"
    run bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -'
    run apt-get install -y nodejs
    ok "nodejs 22 installed"
fi

say "2. Signal K (npm; the old bin/install.sh URL is 404)"
if command -v signalk-server >/dev/null 2>&1; then
    ok "signalk-server present: $(signalk-server --version 2>/dev/null || echo installed)"
else
    run npm install -g signalk-server --allow-scripts=@canboat/canboatjs
fi
if [[ -f /etc/systemd/system/signalk.service || -f /lib/systemd/system/signalk.service ]]; then
    ok "signalk.service exists"
else
    warn "run 'sudo signalk-server-setup' once, interactively (port 3000) - it creates the service"
fi

say "3. AvNav (oss.boating repo - free-x.de, suite trixie)"
if dpkg -s avnav >/dev/null 2>&1; then
    ok "avnav already installed"
else
    run bash -c 'curl -fsSL https://www.free-x.de/debian/oss.boating.gpg.key | gpg --dearmor > /usr/share/keyrings/oss.boating.gpg'
    run bash -c 'echo "deb [signed-by=/usr/share/keyrings/oss.boating.gpg] https://www.free-x.de/debian trixie main contrib non-free" > /etc/apt/sources.list.d/boating.list'
    run apt-get update -qq
    run apt-get install -y avnav || warn "avnav failed - retry: apt install -y python3-bluez && apt install -y avnav"
fi

say "4. Tailscale (remote access, MIGRATION 11)"
if command -v tailscale >/dev/null 2>&1; then
    ok "tailscale present: $(tailscale version 2>/dev/null | head -1)"
else
    run bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
fi
if tailscale status >/dev/null 2>&1; then
    ok "already logged in"
else
    warn "log in once:  sudo tailscale up --ssh --advertise-routes=192.168.10.0/24"
    warn "then approve the route AND disable key expiry in the admin console"
fi

say "5. remaining packages"
run apt-get install -y rclone nginx
ok "rclone (Dropbox manuals) and nginx (manuals on :8081)"

cat <<'STILL'

==> now by hand in the browser (cannot be scripted)
    1. Signal K admin  http://localhost:3000
         - first login: create user boat / bossy
         - Data Connections -> Add -> NMEA 2000 -> SocketCAN -> can0
         - Data Connections -> Add -> Serial -> /dev/rs485-1 @ 4800  (input only)
         - Data Connections -> Add -> Serial -> /dev/rs485-2 @ 38400 (input only)
    2. Appstore -> Webapps -> install KIP
    3. Appstore -> plugins -> install, then enable:
         signalk-to-nmea2000  (enable the Wind 130306 conversion - the TX path)
         signalk-derived-data
         signalk-shelly2      (then re-apply the units:bool patch, MIGRATION 9)
    4. AvNav  http://localhost:8080
         - install ochartsng, re-licence the chart set
         - copy avnav_server.xml if bootstrap has not already (MIGRATION 4)
    5. rclone config   (Dropbox OAuth login for the manuals sync)
    6. sudo ./pi-dock/inject-kip.sh          (Engine dashboard into the kiosk)
    7. sudo python3 signalk-zones/set-zones.py   (gauge zones, from the repo root)

Then: MIGRATION 10 validation, the unattended power-cycle test, and the soak.

STILL
