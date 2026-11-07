#!/bin/bash
LOG=/var/log/shelly-watchdog.log
MARK=/tmp/shelly-watchdog-restarted
# Holding tank + cockpit lighting Shellys on BoatNetwork
SHELLY_IPS="192.168.10.151 192.168.10.142"

# Only act if at least one Shelly is reachable (otherwise a restart won't help)
reachable=0
for ip in $SHELLY_IPS; do
    if curl -s -m 3 "http://$ip/rpc/Shelly.GetStatus" >/dev/null 2>&1; then
        reachable=1
        break
    fi
done
if [ "$reachable" -ne 1 ]; then
    exit 0
fi

count=$(journalctl -u signalk --since "90 seconds ago" --no-pager 2>/dev/null |
grep -c "WebSocket is not connected (state: 3)")

if [ "$count" -ge 3 ]; then
    if [ ! -f "$MARK" ] || [ $(( $(date +%s) - $(stat -c %Y "$MARK") )) -ge 300 ]; then
        echo "$(date '+%F %T') Shelly reachable but plugin WS stuck ($count errors/90s) - restarting signalk" >> "$LOG"
        touch "$MARK"
        systemctl restart signalk.service
    fi
fi
