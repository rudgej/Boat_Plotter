#!/usr/bin/env bash
#
# Snapshot the finished N100 install -> one small tarball you can keep anywhere.
#
#   sudo ./n100/snapshot-n100.sh                 # -> /tmp/bossy-snapshot-<date>.tar.gz
#   sudo ./n100/snapshot-n100.sh /media/usb      # also copy it to a stick
#
# WHY NOT A DISK IMAGE
# The N100 has 128 GB of NVMe. A byte-for-byte image needs a target at least as
# large as the *used* space (several GB once AvNav charts are on board), so it
# will not fit a 4 GB stick. It is also the wrong artefact: charts are encrypted
# and machine-bound, so a restored image would still need re-licensing.
#
# What actually rebuilds this box quickly is the configuration: units, scripts,
# Signal K settings and plugin config, KIP dashboards, zones, network config,
# and a manifest of what was installed. That is a few MB, restores in minutes,
# and diffs meaningfully against the repo.
#
# Does NOT capture: chart data, manuals, media, or any secret. rclone.conf is
# included with its OAuth token REDACTED - re-run `rclone config` after a
# restore.
#
set -uo pipefail

OUTDIR="${1:-/tmp}"
STAMP="$(date +%Y%m%d-%H%M)"
WORK="$(mktemp -d)"
TAR="$OUTDIR/bossy-snapshot-$STAMP.tar.gz"
say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
ok()  { printf '    ok   %s\n' "$*"; }
warn(){ printf '    WARN %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
mkdir -p "$OUTDIR" || exit 1

say "1. config trees"
mkdir -p "$WORK/config"
for d in etc/systemd/system etc/udev/rules.d etc/nginx etc/hostapd \
         etc/NetworkManager etc/default etc/xdg/labwc usr/local/bin; do
    [[ -e "/$d" ]] && { mkdir -p "$WORK/config/$(dirname "$d")"; cp -a "/$d" "$WORK/config/$d" 2>/dev/null; }
done
ok "units, udev, nginx, hostapd, NM, labwc autostart, /usr/local/bin"

say "2. Signal K"
if [[ -d /home/pi/.signalk ]]; then
    mkdir -p "$WORK/signalk"
    for f in settings.json package.json package-lock.json; do
        [[ -f "/home/pi/.signalk/$f" ]] && cp -a "/home/pi/.signalk/$f" "$WORK/signalk/" 2>/dev/null
    done
    cp -a /home/pi/.signalk/plugin-config-data "$WORK/signalk/" 2>/dev/null
    cp -a /home/pi/.signalk/applicationData   "$WORK/signalk/" 2>/dev/null   # KIP dashboards
    # custom plugins that are not in the repo
    for p in holdingtank-status signalk-fuel-economy; do
        [[ -d "/home/pi/.signalk/node_modules/$p" ]] && \
            cp -a "/home/pi/.signalk/node_modules/$p" "$WORK/signalk/" 2>/dev/null
    done
    ok "settings, plugin configs, applicationData (KIP), custom plugins"
else
    warn "no /home/pi/.signalk"
fi

say "3. secrets redacted"
if [[ -f /home/pi/.config/rclone/rclone.conf ]]; then
    mkdir -p "$WORK/secrets"
    sed -E 's/^(token|client_secret|pass|password)[[:space:]]*=.*/\1 = REDACTED/' \
        /home/pi/.config/rclone/rclone.conf > "$WORK/secrets/rclone.conf.redacted"
    ok "rclone.conf with tokens redacted"
fi
[[ -f /etc/signalk-automation.env ]] && \
    sed -E 's/^(SIGNALK_PASSWORD)[[:space:]]*=.*/\1=REDACTED/' /etc/signalk-automation.env \
    > "$WORK/secrets/signalk-automation.env.redacted" 2>/dev/null && ok "automation env redacted"

say "4. manifest (what is actually installed)"
{
    echo "# apt packages explicitly installed"
    apt-mark showmanual 2>/dev/null
    echo
    echo "# node global packages"
    npm ls -g --depth=0 2>/dev/null
    echo
    echo "# enabled units"
    systemctl list-unit-files --state=enabled --no-legend 2>/dev/null
    echo
    echo "# versions"
    node --version 2>/dev/null; npm --version 2>/dev/null
    signalk-server --version 2>/dev/null
    dpkg-query -W -f='${Package} ${Version}\n' avnav rclone nginx can-utils 2>/dev/null
} > "$WORK/MANIFEST.txt" 2>&1
ok "MANIFEST.txt"

say "5. live state still held in memory"
{
    echo "# signal k zones (written by set-zones.py)"
    curl -s --max-time 5 http://localhost:3000/signalk/v1/api/vessels/self \
      | python3 -c "import json,sys;d=json.load(sys.stdin);print(json.dumps(d,indent=1)[:20000])" 2>/dev/null \
      || echo "(Signal K not responding)"
    echo
    echo "# can0"
    ip -details link show can0 2>/dev/null
    echo "# serial"
    ls -l /dev/rs485-* /dev/ttyS* 2>/dev/null
    echo "# disk usage"
    df -h / 2>/dev/null
} > "$WORK/STATE.txt" 2>&1
ok "STATE.txt (zones, can0, serial, disk)"

say "6. packing"
tar czf "$TAR" -C "$WORK" . 2>/dev/null
SIZE=$(du -h "$TAR" | cut -f1)
rm -rf "$WORK"
ok "$TAR ($SIZE)"

if [[ "$OUTDIR" != "/tmp" ]]; then
    sync
    ok "copied to $OUTDIR (unmount/eject safely before removing the stick)"
fi

cat <<EOF

==> restored by
    1. rebuild with bootstrap.sh + install-apps.sh
    2. untar this over / and re-run bootstrap.sh (it re-applies the config trees)
    3. re-run 'rclone config' (the token was redacted)
    4. re-licence the AvNav charts (machine-bound)
    5. restart signalk, then re-run signalk-zones/set-zones.py

==> NOT in this snapshot, by design
    charts, manuals, media, rclone OAuth token, passwords
EOF
