#!/bin/bash
# Launch or focus the Spotify web player as a fullscreen kiosk window.
. /usr/local/bin/kiosk-launch.sh
kiosk_launch "spotify-kiosk" "https://open.spotify.com/" "/home/pi/.config/kiosk-spotify"
