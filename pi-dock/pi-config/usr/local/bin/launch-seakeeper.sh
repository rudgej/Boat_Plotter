#!/bin/bash
# Launch or focus the Seakeeper web UI (served via the ESP32 Ethernet-WiFi bridge).
. /usr/local/bin/kiosk-launch.sh

# Default: ESP32 static IP on BoatNetwork, port 80 forwarded to Seakeeper.
URL="http://192.168.10.50/"
[ -s /home/pi/.config/seakeeper-url ] && URL=$(cat /home/pi/.config/seakeeper-url)

kiosk_launch "seakeeper-kiosk" "$URL" "/home/pi/.config/kiosk-seakeeper"
