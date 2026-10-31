#!/bin/bash
# Launch or focus the AvNav chartplotter (touch web UI).
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority

CLASS="avnav-kiosk"
URL="http://localhost:8080"
PROFILE="/home/pi/.config/kiosk-avnav"

# Chromium runs as a native Wayland window, so X11 tools (xdotool/wmctrl)
# cannot see or focus it. Relaunching is the reliable way to bring it to front.
# labwc window rule (rc.xml) maximizes the window above the bottom dock.
if pgrep -f "chromium.*--app=${URL}" >/dev/null 2>&1; then
    pkill -f "chromium.*--app=${URL}" 2>/dev/null
    sleep 1
fi

nohup chromium --app="$URL" --class="$CLASS" --touch-events=enabled \
    --user-data-dir="$PROFILE" --password-store=basic >/dev/null 2>&1 &
