#!/bin/bash
# Launch or focus the Seakeeper web UI.
. /usr/local/bin/kiosk-launch.sh

# Direct cable on enp2s0 (192.168.0.254/24). The unit was measured at
# 192.168.0.2 on 2026-11-21 — see seakeeper-link.md. The old value pointed at
# the ESP32 bridge on BoatNetwork; that path needs its own address if it is
# ever revived.
URL="http://192.168.0.2/"
[ -s /home/pi/.config/seakeeper-url ] && URL=$(cat /home/pi/.config/seakeeper-url)

kiosk_launch "seakeeper-kiosk" "$URL" "/home/pi/.config/kiosk-seakeeper"
