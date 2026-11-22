#!/bin/bash
# Launch or focus the KIP engine dashboard (Signal K webapp).
. /usr/local/bin/kiosk-launch.sh
kiosk_launch "kip-kiosk" "http://localhost:3000/@mxtommy/kip/" "/home/pi/.config/kiosk-kip" \
    "app-id:chrome-localhost__@mxtommy_kip_-Default"
