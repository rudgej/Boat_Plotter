#!/bin/bash
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority
wmctrl -a "OpenCPN" 2>/dev/null && exit 0
exec /usr/bin/opencpn
