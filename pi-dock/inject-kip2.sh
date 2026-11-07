#!/bin/bash
exec > /tmp/inject2.log 2>&1
echo "start $(date +%H:%M:%S)"
pkill -f kiosk-kip 2>/dev/null
pkill -f "remote-debugging-port=9222" 2>/dev/null
sleep 1
setsid chromium --headless=new --disable-gpu --no-sandbox --password-store=basic --remote-debugging-port=9222 --user-data-dir=/home/pi/.config/kiosk-kip http://localhost:3000/@mxtommy/kip/ >/tmp/kc2.log 2>&1 &
echo "chromium launched"
for i in $(seq 1 25); do
  if curl -s --max-time 2 http://127.0.0.1:9222/json/list >/tmp/jl.json 2>/dev/null && [ -s /tmp/jl.json ]; then
    echo "port up after ${i}s"
    break
  fi
  sleep 1
done
node /home/pi/inject-kip.mjs
echo "node exit $?"
pkill -f "remote-debugging-port=9222" 2>/dev/null
echo "done $(date +%H:%M:%S)"
