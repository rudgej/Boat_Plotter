#!/bin/bash
#
# Connect the remembered Bluetooth speaker and put the audio on it.
#
# This is the piece that was missing the whole time. Setting a default sink only
# affects streams started AFTERWARDS: anything already playing stays on the old
# output. So pairing and "connecting" could both succeed while the music kept
# coming out of the built-in speakers, which is exactly the "paired but no
# music" report. The fix is to MOVE the running streams as well.
#
# pactl is used rather than wpctl because it can move a stream; wpctl cannot.
#
# Exit 0 only when the speaker is genuinely carrying audio.
#
# Usage: bt-hifi-connect.sh [--check]
#   --check  report whether the speaker is currently a sink, change nothing

set -u

. /usr/local/bin/kiosk-launch.sh
kiosk_env

LOG=/var/log/bt-pair.log
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; }

MACFILE=/etc/boat-hifi-mac
MAC=$(tr -d '[:space:]' <"$MACFILE" 2>/dev/null || true)
[ -n "${MAC:-}" ] || { echo "no saved speaker"; exit 1; }

# PipeWire names a Bluetooth sink bluez_output.88_C6_26_C9_DD_0A.1, so the
# address in underscores identifies it.
MAC_U=$(printf '%s' "$MAC" | tr 'a-z' 'A-Z' | tr ':' '_')

sink_index() {
    pactl list short sinks 2>/dev/null | awk -v m="$MAC_U" '
        {
            name = toupper($2)
            if (index(name, m)) { print $1; exit }
        }'
}

if [ "${1:-}" = "--check" ]; then
    if [ -n "$(sink_index)" ]; then
        echo "present"
        exit 0
    fi
    echo "absent"
    exit 1
fi

bluetoothctl power on >/dev/null 2>&1

if bluetoothctl info "$MAC" 2>/dev/null | grep -qi 'Connected: yes'; then
    log "bluetooth reports already connected: $MAC"
else
    log "connecting $MAC"
    bluetoothctl --timeout 15 connect "$MAC" >/dev/null 2>&1 || true
fi

IDX=""
for _ in $(seq 1 15); do
    IDX=$(sink_index)
    [ -n "$IDX" ] && break
    sleep 1
done

if [ -z "$IDX" ]; then
    log "no audio sink appeared for $MAC (speaker off, out of range, or not offering audio)"
    echo "no audio sink"
    exit 1
fi

pactl set-default-sink "$IDX" >/dev/null 2>&1

MOVED=0
for input in $(pactl list short sink-inputs 2>/dev/null | awk '{print $1}'); do
    if pactl move-sink-input "$input" "$IDX" >/dev/null 2>&1; then
        MOVED=$((MOVED + 1))
    fi
done

log "sink $IDX is default, moved $MOVED playing stream(s)"
echo "connected: sink $IDX, moved $MOVED stream(s)"
exit 0
