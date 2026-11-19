#!/bin/bash
# Point manuals-sync at the real Dropbox folder and run the first sync.
set -euo pipefail

REMOTE="dropbox:Boat-Manuals"

sudo -n mkdir -p /etc/systemd/system/manuals-sync.service.d
printf '[Service]\nEnvironment="MANUALS_REMOTE=%s"\n' "$REMOTE" > /tmp/manuals-env.conf
sudo -n cp /tmp/manuals-env.conf /etc/systemd/system/manuals-sync.service.d/10-remote.conf
sudo -n systemctl daemon-reload

echo "=== drop-in ==="
cat /etc/systemd/system/manuals-sync.service.d/10-remote.conf

echo "=== first sync (can take a minute: 152 MiB) ==="
sudo -n systemctl start manuals-sync.service
systemctl show -p Result --value manuals-sync.service

echo "=== log ==="
sudo -n tail -15 /home/pi/manuals-sync.log 2>&1

echo "=== local library ==="
find /home/pi/manuals -type f | wc -l
du -sh /home/pi/manuals
find /home/pi/manuals -type f | head -5

echo "=== nginx serves it ==="
curl -s -o /dev/null -w "index http=%{http_code}\n" http://localhost:8081/
curl -s -o /dev/null -w "pdf  http=%{http_code}\n" \
  "http://localhost:8081/$(find /home/pi/manuals -type f -name '*.pdf' | head -1 | sed 's|/home/pi/manuals/||' | sed 's| |%20|g')"
