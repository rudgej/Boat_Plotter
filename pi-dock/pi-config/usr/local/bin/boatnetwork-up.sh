#!/bin/bash
# Wait for wlan1 (the AIC8800 dongle), bring it up, assign the AP address.
for i in $(seq 1 30); do
  if [ -d /sys/class/net/wlan1 ]; then
    break
  fi
  sleep 1
done
ip link set wlan1 up
ip addr add 192.168.10.1/24 dev wlan1 2>/dev/null || true
