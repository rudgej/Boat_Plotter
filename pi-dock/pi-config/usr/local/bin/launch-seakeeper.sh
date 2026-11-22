#!/bin/bash
# Launch or focus the Seakeeper web UI.
. /usr/local/bin/kiosk-launch.sh

# The unit is reached through the WT32-ETH01 relay bridge: the bridge holds the
# Ethernet side (192.168.0.254/24) and relays 80 and 9001 onto BoatNetwork, so
# the kiosk only ever talks to 192.168.10.50. The unit itself is at 192.168.0.2
# on the far side of that bridge and is not directly reachable from here.
# See seakeeper-esp/relay/README.md and seakeeper-link.md.
URL="http://192.168.10.50/"
[ -s /home/pi/.config/seakeeper-url ] && URL=$(cat /home/pi/.config/seakeeper-url)

kiosk_launch "seakeeper-kiosk" "$URL" "/home/pi/.config/kiosk-seakeeper"
