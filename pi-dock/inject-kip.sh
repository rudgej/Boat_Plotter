#!/bin/bash
# Inject KIP dashboard config into the kiosk Chromium profile.
pkill -f kiosk-kip 2>/dev/null
pkill -f "remote-debugging-port=9222" 2>/dev/null
sleep 1
nohup chromium --headless=new --disable-gpu --no-sandbox --remote-debugging-port=9222 --user-data-dir=/home/pi/.config/kiosk-kip about:blank >/tmp/kip-chromium.log 2>&1 &
sleep 7
node /home/pi/inject-kip.mjs
pkill -f "remote-debugging-port=9222" 2>/dev/null
echo "INJECT_DONE"
