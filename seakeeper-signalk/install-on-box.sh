#!/bin/sh
# Install seakeeper-signalk on the N100.
#
# Run this ON the boat computer, from a directory holding index.js and
# package.json (the README shows the scp that gets them there).
set -e

DEST=/home/pi/.signalk/node_modules/seakeeper-signalk
CFG=/home/pi/.signalk/plugin-config-data/seakeeper-signalk.json

echo "=== 1. copy the plugin ==="
sudo -n mkdir -p "$DEST"
sudo -n cp index.js package.json "$DEST"/
sudo -n chown -R pi:pi "$DEST"

echo "=== 2. enable it ==="
# Left disabled by default so a plugin appearing under node_modules cannot start
# talking to the network on its own. Configuration below is the shipped default.
if [ -f "$CFG" ]; then
    echo "config already present, leaving it alone: $CFG"
else
    printf '%s\n' '{"enabled":true,"configuration":{"host":"192.168.0.2","port":9001,"instance":1,"rateHz":1,"staleSeconds":10},"enableDebug":false}' > /tmp/sk-plugin.json
    sudo -n cp /tmp/sk-plugin.json "$CFG"
    sudo -n chown pi:pi "$CFG"
    echo "wrote $CFG"
fi

echo "=== 3. module load check ==="
node -e '
const p = require("/home/pi/.signalk/node_modules/seakeeper-signalk");
console.log("plugin module loads, exported type:", typeof p);
'

echo "=== 4. mqtt module resolution check ==="
node -e '
const { createRequire } = require("module");
try { require("mqtt"); console.log("mqtt: local copy"); }
catch (e) {
  const r = createRequire("/usr/lib/node_modules/signalk-server/package.json");
  console.log("mqtt: borrowed from signalk-server", r("mqtt/package.json").version);
}
'

echo "=== 5. restart signalk ==="
sudo -n systemctl restart signalk
for i in $(seq 1 40); do systemctl is-active --quiet signalk && break; sleep 1; done
echo -n "service: "
systemctl is-active signalk
