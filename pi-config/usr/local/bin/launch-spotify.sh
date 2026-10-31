#!/bin/bash
# Launch Spotify web player as a kiosk on the plotter screen.
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/1000

CLASS="spotify-kiosk"
PROFILE="/home/pi/.config/kiosk-spotify"
URL="https://open.spotify.com/"

# No kill here — if Spotify is already running, Chromium signals the existing
# instance to focus instead of reloading (which would stop playback).
nohup chromium --app="$URL" --class="$CLASS" --touch-events=enabled \
    --ozone-platform=wayland \
    --user-data-dir="$PROFILE" --password-store=basic >/dev/null 2>&1 &
