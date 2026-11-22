#!/bin/bash
# Launch or focus the Seakeeper web UI.
. /usr/local/bin/kiosk-launch.sh

# The unit sits behind the WT32-ETH01 relay bridge and is NOT reachable from
# BoatNetwork at its own address. The page must still be *loaded* from that
# address: its JavaScript compares the host it was served from against the
# address the unit advertises (seakeeper/gyros -> {"ip_address":"192.168.0.2"}),
# and only on a match does it subscribe to status or send commands. Any other
# host gives a page that renders but shows no data and cannot control anything.
#
# So load http://192.168.0.2/ and let seakeeper-redirect.service DNAT that
# address to the bridge, which relays ports 80 and 9001.
URL="http://192.168.0.2/"
[ -s /home/pi/.config/seakeeper-url ] && URL=$(cat /home/pi/.config/seakeeper-url)

kiosk_launch "seakeeper-kiosk" "$URL" "/home/pi/.config/kiosk-seakeeper" \
    "app-id:chrome-192.168.0.2__-Default"
