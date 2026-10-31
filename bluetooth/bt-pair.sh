#!/bin/bash
# One-tap Bluetooth pairing for the boat hifi.
export DISPLAY=:0
export XAUTHORITY=/home/pi/.Xauthority
export XDG_RUNTIME_DIR=/run/user/1000
CTRL="88:A2:9E:62:2A:93"   # Pi onboard Bluetooth

zenity --info --text="Put the hifi into pairing mode now, then press OK.\nThe Pi will scan for 25 seconds." --title="BoatNetwork" --width=480 2>/dev/null

printf 'select %s\npower on\npairable on\ndiscoverable on\nquit\n' "$CTRL" | bluetoothctl >/dev/null 2>&1

timeout 25 bluetoothctl scan on > /tmp/bt-scan.txt 2>&1 || true

MAC=$(grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' /tmp/bt-scan.txt \
  | tr 'a-f' 'A-F' \
  | grep -vE '88:A2:9E:62:2A:93|0B:3B:22:AC:88:20' | sort -u | head -1)

if [ -z "$MAC" ]; then
  zenity --warning --text="No device found.\nPut the hifi in pairing mode and try again." --title="BoatNetwork" --width=480 2>/dev/null
  exit 1
fi

printf 'select %s\nagent NoInputNoOutput\ndefault-agent\npair %s\ntrust %s\nquit\n' "$CTRL" "$MAC" "$MAC" | bluetoothctl >/tmp/bt-pair.txt 2>&1

echo "$MAC" | sudo tee /etc/boat-hifi-mac >/dev/null

if grep -qi "successful" /tmp/bt-pair.txt; then
  zenity --info --text="Paired: $MAC\nConnecting audio..." --title="BoatNetwork" --width=480 2>/dev/null
  /usr/local/bin/bt-hifi-connect.sh
  zenity --info --text="Ready. Music will now play on the hifi." --title="BoatNetwork" --width=480 2>/dev/null
else
  zenity --warning --text="Pairing to $MAC may not have completed.\nTry again with the hifi in pairing mode." --title="BoatNetwork" --width=480 2>/dev/null
  exit 1
fi
