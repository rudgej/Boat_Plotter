#!/bin/bash
# Launch or focus the AvNav chartplotter (touch web UI).
. /usr/local/bin/kiosk-launch.sh
kiosk_launch "avnav-kiosk" "http://localhost:8080" "/home/pi/.config/kiosk-avnav" \
    "title:AVNav-Web"
