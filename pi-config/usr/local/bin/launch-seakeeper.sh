#!/bin/bash
# Launch the Seakeeper web UI (served via the ESP32 Ethernet-WiFi bridge).
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/1000

CLASS="seakeeper-kiosk"
PROFILE="/home/pi/.config/kiosk-seakeeper"

# Default: ESP32 static IP on BoatNetwork, port 80 forwarded to Seakeeper.
URL="http://192.168.10.50/"
[ -s /home/pi/.config/seakeeper-url ] && URL=$(cat /home/pi/.config/seakeeper-url)

if pgrep -f "kiosk-seakeeper" >/dev/null 2>&1; then
    pkill -f "kiosk-seakeeper" 2>/dev/null
    sleep 1
fi

nohup chromium --app="$URL" --class="$CLASS" --touch-events=enabled \
    --ozone-platform=wayland \
    --user-data-dir="$PROFILE" --password-store=basic >/dev/null 2>&1 &
