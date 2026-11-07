#!/bin/bash
# Launch Spotify web player as a fullscreen kiosk on the plotter screen.
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/1000

CLASS="spotify-kiosk"
PROFILE="/home/pi/.config/kiosk-spotify"
URL="https://open.spotify.com/"

# Relaunch so it always comes back fullscreen (matches the other kiosk apps).
if pgrep -f "chromium.*--app=${URL}" >/dev/null 2>&1; then
    pkill -f "chromium.*--app=${URL}" 2>/dev/null
    sleep 1
fi

nohup chromium --app="$URL" --class="$CLASS" --touch-events=enabled --enable-virtual-keyboard \
    --ozone-platform=wayland \
    --user-data-dir="$PROFILE" --password-store=basic >/dev/null 2>&1 &
