#!/bin/bash
# Launch the KIP engine dashboard (Signal K webapp).
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/1000

CLASS="kip-kiosk"
PROFILE="/home/pi/.config/kiosk-kip"

URL="http://localhost:3000/@mxtommy/kip/"

if pgrep -f "kiosk-kip" >/dev/null 2>&1; then
    pkill -f "kiosk-kip" 2>/dev/null
    sleep 1
fi

nohup chromium --app="$URL" --class="$CLASS" --touch-events=enabled --enable-virtual-keyboard \
    --ozone-platform=wayland \
    --user-data-dir="$PROFILE" --password-store=basic >/dev/null 2>&1 &
