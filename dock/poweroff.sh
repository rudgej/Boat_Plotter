#!/bin/bash
# Graceful shutdown with on-screen confirmation.
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority

if zenity --question --title="Power Off" \
     --text="Shut down the boat computer now?\n\nTap Shut Down to power off safely." \
     --ok-label="Shut Down" --cancel-label="Cancel" --width=420 2>/dev/null; then
    sudo -n systemctl poweroff
fi
