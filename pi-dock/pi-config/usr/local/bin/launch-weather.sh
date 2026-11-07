#!/bin/bash
# Launch or refresh the weather kiosk (Windy) at the boat's current position.
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/1000

CLASS="weather-kiosk"
PROFILE="/home/pi/.config/kiosk-weather"
POS=$(/usr/local/bin/get-boat-pos.sh)

# Windy URL: /?{overlay},{lat},{lon},{zoom}
#   overlay "waves" = significant wave height; switch to "wind" for wind barbs.
URL="https://www.windy.com/?waves,${POS},10"

# Chromium is a native Wayland window; relaunching is the reliable focus method.
# labwc window rule (rc.xml) maximizes it above the bottom dock.
if pgrep -f "kiosk-weather" >/dev/null 2>&1; then
    pkill -f "kiosk-weather" 2>/dev/null
    sleep 1
fi

nohup chromium --app="$URL" --class="$CLASS" --touch-events=enabled --enable-virtual-keyboard \
    --ozone-platform=wayland \
    --user-data-dir="$PROFILE" --password-store=basic >/dev/null 2>&1 &
