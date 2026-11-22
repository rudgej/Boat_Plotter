#!/bin/bash
# Launch or refresh the weather kiosk (Windy) at the boat's current position.
. /usr/local/bin/kiosk-launch.sh

# Windy URL: /?{overlay},{lat},{lon},{zoom}
#   overlay "waves" = significant wave height; switch to "wind" for wind barbs.
POS=$(/usr/local/bin/get-boat-pos.sh)
kiosk_launch "weather-kiosk" "https://www.windy.com/?waves,${POS},10" "/home/pi/.config/kiosk-weather" \
    "app-id:chrome-www.windy.com__-Default"
