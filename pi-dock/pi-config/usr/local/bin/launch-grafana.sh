#!/bin/bash
# Launch or focus the Grafana dashboard as a fullscreen app window.
. /usr/local/bin/kiosk-launch.sh
kiosk_launch "grafana-kiosk" "http://localhost:3001" "/home/pi/.config/kiosk-grafana" \
    "title:Grafana"
