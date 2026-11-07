#!/bin/bash
exec > /tmp/play-result.txt 2>&1
echo "start $(date +%H:%M:%S)"
pkill -f kiosk-spotify 2>/dev/null
pkill -f "remote-debugging-port=9223" 2>/dev/null
sleep 1
rm -rf /tmp/spotify-test
cp -r /home/pi/.config/kiosk-spotify /tmp/spotify-test 2>/dev/null || mkdir -p /tmp/spotify-test
setsid chromium --headless=new --disable-gpu --no-sandbox --password-store=basic --autoplay-policy=no-user-gesture-required --remote-debugging-port=9223 --user-data-dir=/tmp/spotify-test https://open.spotify.com/ >/tmp/play-chromium.log 2>&1 &
sleep 12
node /tmp/play-test.mjs
echo "EXIT=$?"
pkill -f "remote-debugging-port=9223" 2>/dev/null
echo "done $(date +%H:%M:%S)"
