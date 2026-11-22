#!/bin/bash
#
# seakeeper-dropwatch — record why the SeaKeeper page loses its connection.
#
# Writes to /var/log/seakeeper-dropwatch.log:
#   CONNS a -> b   every time the number of established MQTT connections to the
#                  unit changes, with the current sockets listed underneath
#   WIFI ...       every Wi-Fi event on the BoatNetwork access point: stations
#                  joining and leaving. A page that drops with no WIFI line
#                  next to it was not a Wi-Fi problem.
#   HEARTBEAT      every 5 minutes, so a silent log is provably alive
#
# The window count is recorded alongside, because Chromium throttles or freezes
# a hidden window, which would stop the page's MQTT keepalive and let the relay
# close its connection after 120 s of silence.
#
set -u

LOG=/var/log/seakeeper-dropwatch.log
TARGET=192.168.0.2
PORT=9001

# The AP interface is whichever one owns the BoatNetwork gateway address.
IFACE=$(ip -4 -o addr 2>/dev/null |
    awk '$4 ~ /^192\.168\.10\.1\// {print $2; exit}')

# wlrctl needs the kiosk user's Wayland session.
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/1000

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"
}

conns() {
    ss -tn 2>/dev/null | grep -c "$TARGET:$PORT"
}

windows() {
    wlrctl toplevel list 2>/dev/null | grep -c "$TARGET"
}

log "=== dropwatch started (AP interface: ${IFACE:-not found}) ==="

# This iw build has no -i for event; it watches every interface, so lines from
# the other radio are filtered out by interface name.
if [ -n "${IFACE:-}" ]; then
    (
        iw event -t 2>&1 |
            grep --line-buffered -F "$IFACE" |
            while IFS= read -r line; do log "WIFI $line"; done
    ) &
fi

prev=$(conns)
log "starting with $prev connection(s), $(windows) window(s)"

beats=0
while :; do
    n=$(conns)
    if [ "$n" != "$prev" ]; then
        w=$(windows)
        log "CONNS $prev -> $n  (windows=$w)"
        ss -tn 2>/dev/null | grep "$TARGET:$PORT" |
            awk '{printf "    %s %s %s\n", $1, $4, $5}' | while IFS= read -r l; do
                log "$l"
            done
        prev=$n
    fi

    beats=$((beats + 1))
    if [ $((beats % 60)) -eq 0 ]; then
        log "HEARTBEAT conns=$n windows=$(windows)"
    fi
    sleep 5
done
