#!/bin/bash
# One-shot installer for engine-trends on Bossy. Run as pi (passwordless sudo).
set -euo pipefail

sudo -n install -m 755 /tmp/engine-trends.py /usr/local/bin/engine-trends.py
sudo -n install -m 644 /tmp/engine-trends.service /etc/systemd/system/engine-trends.service
sudo -n install -d -o pi -g pi /home/pi/.engine-trends

sudo -n mkdir -p /home/pi/.signalk/node_modules/enginetrends-status
sudo -n cp /tmp/enginetrends-status/index.js \
           /tmp/enginetrends-status/package.json \
           /home/pi/.signalk/node_modules/enginetrends-status/
sudo -n chown -R pi:pi /home/pi/.signalk/node_modules/enginetrends-status

CFG=/home/pi/.signalk/plugin-config-data/enginetrends-status.json
printf '%s\n' '{"enabled":true,"configuration":{},"enableDebug":false}' > /tmp/et-plugin.json
sudo -n cp /tmp/et-plugin.json "$CFG"
sudo -n chown pi:pi "$CFG"

echo "=== node load check ==="
node -e 'const p=require("/home/pi/.signalk/node_modules/enginetrends-status"); console.log("plugin module loads, exported type:", typeof p)'

echo "=== python syntax on box ==="
python3 -c 'import ast; ast.parse(open("/usr/local/bin/engine-trends.py").read()); print("py OK")'

echo "=== files ==="
ls -l /usr/local/bin/engine-trends.py /etc/systemd/system/engine-trends.service
ls -l /home/pi/.signalk/node_modules/enginetrends-status/ "$CFG"

echo "=== unit verify ==="
sudo -n systemd-analyze verify /etc/systemd/system/engine-trends.service 2>&1 || true
