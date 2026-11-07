#!/bin/bash
LOG=/var/log/can-watchdog.log

info=$(ip -details link show can0 2>/dev/null)

if [ -z "$info" ]; then
    echo "$(date '+%F %T') can0 missing - restarting can0-nmea2000 + signalk" >> "$LOG"
    systemctl restart can0-nmea2000.service
    systemctl restart signalk.service
    exit 0
fi

if ! echo "$info" | grep -q 'state UP'; then
    echo "$(date '+%F %T') can0 not UP - restarting can0-nmea2000 + signalk" >> "$LOG"
    systemctl restart can0-nmea2000.service
    systemctl restart signalk.service
    exit 0
fi

if echo "$info" | grep -q 'BUS-OFF'; then
    echo "$(date '+%F %T') can0 BUS-OFF - restarting can0-nmea2000 + signalk" >> "$LOG"
    systemctl restart can0-nmea2000.service
    systemctl restart signalk.service
    exit 0
fi

# Interrupt-storm detection: if the MCP2515 INT line sticks low the IRQ count
# climbs far faster than frames are actually received. Sample over 2 s.
irq1=$(grep "spi0.0" /proc/interrupts | awk '{s=0; for(i=2;i<=NF;i++){if($i ~ /^[0-9]+$/) s+=$i; else break} print s}')
rx1=$(cat /sys/class/net/can0/statistics/rx_packets 2>/dev/null || echo 0)
sleep 2
irq2=$(grep "spi0.0" /proc/interrupts | awk '{s=0; for(i=2;i<=NF;i++){if($i ~ /^[0-9]+$/) s+=$i; else break} print s}')
rx2=$(cat /sys/class/net/can0/statistics/rx_packets 2>/dev/null || echo 0)

d_irq=$(( ${irq2:-0} - ${irq1:-0} ))
d_rx=$(( ${rx2:-0} - ${rx1:-0} ))

# Normal traffic: ~100 IRQs in 2 s. A storm is thousands, and far exceeds RX.
if [ "$d_irq" -gt 1500 ] && [ "$d_irq" -gt $(( d_rx * 5 )) ]; then
    echo "$(date '+%F %T') can0 IRQ storm (irq=$d_irq rx=$d_rx in 2s) - restarting can0-nmea2000 + signalk" >> "$LOG"
    systemctl restart can0-nmea2000.service
    systemctl restart signalk.service
fi

exit 0
