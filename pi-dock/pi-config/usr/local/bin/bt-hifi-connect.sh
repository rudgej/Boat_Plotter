#!/bin/bash
# Connect to the boat hifi (Bluetooth A2DP) and make it the default audio sink.
. /usr/local/bin/kiosk-launch.sh

kiosk_env

CTRL=$(bluetoothctl list 2>/dev/null | awk '/Controller/{print $2; exit}')
MAC=$(tr -d '[:space:]' < /etc/boat-hifi-mac 2>/dev/null)
[ -n "$CTRL" ] || { echo "no bluetooth adapter"; exit 1; }
[ -n "$MAC" ] || { echo "no /etc/boat-hifi-mac"; exit 0; }

printf 'select %s\npower on\ntrust %s\nconnect %s\nquit\n' "$CTRL" "$MAC" "$MAC" | bluetoothctl >/dev/null 2>&1

sinks() {
    wpctl status 2>/dev/null | awk '/Sinks:/{s=1;next} /Sources:/{s=0} s && /[0-9]+\./{gsub(/\./,"",$1); print $1}' | sort
}

before=$(sinks)

for i in $(seq 1 12); do
    after=$(sinks)
    NEW=$(comm -13 <(printf "%s\n" "$before") <(printf "%s\n" "$after") | head -1)
    if [ -n "$NEW" ]; then
        wpctl set-default "$NEW" >/dev/null 2>&1
        echo "hifi connected, default sink: $NEW"
        exit 0
    fi
    sleep 1
done
echo "hifi not connected yet"
exit 1
