#!/bin/bash
# Launch or focus the offline boat manuals library as a fullscreen app window.
. /usr/local/bin/kiosk-launch.sh
kiosk_launch "manuals-kiosk" "http://localhost:8081" "/home/pi/.config/kiosk-manuals" \
    "title:Index of /"
