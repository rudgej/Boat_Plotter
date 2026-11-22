#!/bin/bash
# Connect to the saved Bluetooth speaker and make it the default audio sink.
#
# Rewritten because the original only looked for a sink that appeared *during*
# this run. When the speaker was already connected - the normal case, since the
# box reconnects to a trusted device - no new sink appeared, so it waited 12 s
# and reported failure while the box stayed on the built-in card.
#
# Now it finds the BlueZ sink by the saved address and makes that the default,
# whether it has just appeared or was already there.
. /usr/local/bin/kiosk-launch.sh

kiosk_env

CTRL=$(bluetoothctl list 2>/dev/null | awk '/Controller/{print $2; exit}')
MAC=$(tr -d '[:space:]' < /etc/boat-hifi-mac 2>/dev/null)
[ -n "$CTRL" ] || { echo "no bluetooth adapter"; exit 1; }
[ -n "$MAC" ] || { echo "no /etc/boat-hifi-mac"; exit 0; }

bluetoothctl power on >/dev/null 2>&1
bluetoothctl --timeout 5 trust "$MAC" >/dev/null 2>&1
# Skip the connect when the link is already up; it blocks for the whole timeout.
bluetoothctl info "$MAC" 2>/dev/null | grep -qi 'Connected: yes' ||
    bluetoothctl --timeout 15 connect "$MAC" >/dev/null 2>&1 || true

# Find the Audio/Sink that belongs to this address. pw-dump is used because
# wpctl's text output does not tie a sink to its device, and pactl is not
# installed here.
sink_id() {
    pw-dump 2>/dev/null | python3 -c '
import json, sys
mac = sys.argv[1].upper()
try:
    objs = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in objs:
    props = o.get("info", {}).get("props", {})
    if props.get("media.class") != "Audio/Sink":
        continue
    addr = str(props.get("api.bluez5.address", "")).upper()
    if addr == mac or (not addr and props.get("device.api") == "bluez5"):
        print(o["id"])
        break
' "$MAC"
}

for _ in $(seq 1 20); do
    ID=$(sink_id)
    if [ -n "$ID" ]; then
        wpctl set-default "$ID" >/dev/null 2>&1
        echo "hifi connected, default sink: $ID $MAC"
        exit 0
    fi
    sleep 1
done

echo "hifi $MAC not present as an audio sink"
exit 1
