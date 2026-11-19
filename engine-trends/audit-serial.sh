#!/bin/bash
# Audit the box for serial-port readiness and Signal K config capture.
set -uo pipefail

echo "=== 1. can pi even open the serial ports? ==="
id pi
echo -n "dialout members: "; getent group dialout
ls -l /dev/ttyS0 /dev/ttyS1 /dev/rs485-1 /dev/rs485-2 2>&1
echo -n "pi open test: "
sudo -n -u pi python3 -c "
import os
for d in ('/dev/ttyS0','/dev/ttyS1'):
    try:
        fd=os.open(d, os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK); os.close(fd); print(d,'OK',end='  ')
    except Exception as e: print(d,'FAIL',e)
" 2>&1

echo
echo "=== 2. Signal K serial support ==="
node -e 'try{require("/usr/lib/node_modules/signalk-server/node_modules/serialport");console.log("serialport: present")}catch(e){console.log("serialport: MISSING",e.code)}' 2>&1
ls /usr/lib/node_modules/ 2>/dev/null | head -5

echo
echo "=== 3. Signal K config files present ==="
ls -l /home/pi/.signalk/settings.json 2>&1
python3 - <<'PY'
import json, os
p = "/home/pi/.signalk/settings.json"
if not os.path.exists(p):
    print("  settings.json: ABSENT")
else:
    d = json.load(open(p))
    print("  top-level keys:", sorted(d.keys()))
    for k in ("pipedProviders", "interfaces", "security", "ssl"):
        if k in d:
            print("  %s: %s" % (k, type(d[k]).__name__))
    pp = d.get("pipedProviders", [])
    print("  pipedProviders count:", len(pp))
    for x in pp:
        cfg = x.get("pipeElements", [{}])
        print("   -", x.get("id"), [c.get("options", {}).get("type") for c in cfg],
              [c.get("options", {}) for c in cfg][:1])
PY

echo
echo "=== 4. udev rule naming ==="
cat /etc/udev/rules.d/60-rs485.rules 2>&1

echo
echo "=== 5. Serial provider npm package at top level ==="
ls -d /home/pi/.signalk/node_modules/*serial* 2>/dev/null || echo "  (no serial* in ~/.signalk/node_modules)"
