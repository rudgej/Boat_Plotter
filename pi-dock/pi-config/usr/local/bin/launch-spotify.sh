#!/bin/bash
# Launch or focus the Spotify web player as a fullscreen kiosk window.
. /usr/local/bin/kiosk-launch.sh

# Widevine: only Google Chrome ships the CDM, and Spotify will not play without it.
KIOSK_BROWSER=/usr/bin/google-chrome-stable
kiosk_launch "spotify-kiosk" "https://open.spotify.com/" "/home/pi/.config/kiosk-spotify"
