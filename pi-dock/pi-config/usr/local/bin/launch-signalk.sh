#!/bin/bash
# Launch or focus the Signal K dashboard as a fullscreen app window.
. /usr/local/bin/kiosk-launch.sh
kiosk_launch "signalk-kiosk" "http://localhost:3000" "/home/pi/.config/kiosk-signalk" \
    "title:Signal K Server"
