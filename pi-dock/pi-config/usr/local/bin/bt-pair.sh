#!/bin/bash
# One-tap Bluetooth pairing for the boat hifi.
. /usr/local/bin/kiosk-launch.sh

msg() { zenity --info --text="$1" --title="BoatNetwork" --width=480 2>/dev/null; }
warn() { zenity --warning --text="$1" --title="BoatNetwork" --width=480 2>/dev/null; }

kiosk_env

# Use this machine's own adapter - the address differs per box.
CTRL=$(bluetoothctl list 2>/dev/null | awk '/Controller/{print $2; exit}')
if [ -z "$CTRL" ]; then
    warn "No Bluetooth adapter found."
    exit 1
fi

msg "Put the hifi into pairing mode now, then press OK.\nThe plotter will scan for 25 seconds."

printf 'select %s\npower on\npairable on\ndiscoverable on\nquit\n' "$CTRL" | bluetoothctl >/dev/null 2>&1

timeout 25 bluetoothctl scan on > /tmp/bt-scan.txt 2>&1 || true

# Ignore our own adapter and anything already paired (phones, etc).
MAC=$(grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' /tmp/bt-scan.txt \
  | tr 'a-f' 'A-F' \
  | grep -vF "$(echo "$CTRL" | tr 'a-f' 'A-F')" \
  | sort -u | head -1)

if [ -z "$MAC" ]; then
    warn "No device found.\nPut the hifi in pairing mode and try again."
    exit 1
fi

printf 'select %s\nagent NoInputNoOutput\ndefault-agent\npair %s\ntrust %s\nquit\n' "$CTRL" "$MAC" | bluetoothctl >/tmp/bt-pair.txt 2>&1

echo "$MAC" | sudo tee /etc/boat-hifi-mac >/dev/null

if grep -qi "successful\|already exists\|AlreadyExists" /tmp/bt-pair.txt; then
    msg "Paired: $MAC\nConnecting audio..."
    /usr/local/bin/bt-hifi-connect.sh
    msg "Ready. Music will now play on the hifi."
else
    warn "Pairing to $MAC may not have completed.\nTry again with the hifi in pairing mode."
    exit 1
fi
