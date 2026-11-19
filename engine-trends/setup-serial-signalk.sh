#!/bin/bash
# Give Signal K ownership of the two onboard serial ports.
#
#   1. add pi to dialout           (Signal K runs as pi; the ports are root:dialout)
#   2. add two NMEA 0183 serial providers to settings.json
#   3. restart Signal K and verify nothing else broke
#
# Signal K is stopped while settings.json is edited because it rewrites that
# file itself, so an edit against the running server can be silently lost.
set -uo pipefail

SJ=/home/pi/.signalk/settings.json
BAK="$SJ.bak-$(date +%Y%m%d-%H%M%S)"

echo "=== 1. dialout ==="
sudo -n usermod -aG dialout pi
getent group dialout

echo
echo "=== 2. stop signalk, back up and edit settings.json ==="
sudo -n cp -a "$SJ" "$BAK"
echo "backup: $BAK"
sudo -n systemctl stop signalk

python3 - "$SJ" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)

providers = cfg.setdefault("pipedProviders", [])
existing = {p.get("id") for p in providers}

# Schema taken from signalk-server/settings/volare-serial-settings.json:
# a serial NMEA 0183 input is a serialport element feeding an nmea0183-signalk
# element. Option names are `device` and `baudrate` (not baudRate).
want = [
    ("nmea0183-rs485-1", "/dev/rs485-1", 4800),    # COM1 - instruments
    ("nmea0183-rs485-2", "/dev/rs485-2", 38400),   # COM2 - AIS
]

for pid, device, baud in want:
    if pid in existing:
        print("  %s already present, leaving alone" % pid)
        continue
    providers.append({
        "id": pid,
        "enabled": True,
        "pipeElements": [
            {
                "type": "providers/serialport",
                "options": {"device": device, "baudrate": baud},
            },
            {
                "type": "providers/nmea0183-signalk",
                "options": {},
            },
        ],
    })
    print("  added %s -> %s @ %d 8N1" % (pid, device, baud))

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

echo
echo "=== resulting provider ids ==="
python3 -c "
import json
d = json.load(open('$SJ'))
for p in d['pipedProviders']:
    print('  ', p['id'], 'enabled=%s' % p.get('enabled', True))
"

echo
echo "=== 3. start signalk ==="
sudo -n systemctl start signalk
for i in $(seq 1 40); do systemctl is-active --quiet signalk && break; sleep 1; done
sleep 6
echo -n "service: "; systemctl is-active signalk

echo
echo "=== 4. the serial ports now opened by whom? ==="
sudo -n fuser -v /dev/ttyS0 /dev/ttyS1 2>&1 || echo "  nobody opened them (check the log below)"

echo
echo "=== 5. permission errors in the log? ==="
sudo -n journalctl -u signalk --since "-2 min" --no-pager 2>&1 \
  | grep -iE "EACCES|permission denied|serialport|rs485|error" | tail -15 \
  || echo "  none"

echo
echo "=== 6. CAN data still flowing? ==="
curl -s http://localhost:3000/signalk/v1/api/vessels/self/propulsion/port/revolutions 2>&1 | head -c 200
echo
