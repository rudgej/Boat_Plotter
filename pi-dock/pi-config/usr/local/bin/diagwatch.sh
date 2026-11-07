#!/bin/bash
# High-frequency diagnostic logger for the freeze investigation.
# Every 2 s records: 5V rail voltage, core voltage, throttle flags,
# load average, free RAM and the top-CPU process.
# Appends to /var/log/diagwatch.log (bounded at ~20 MB by trimming the head).
LOG=/var/log/diagwatch.log
MAXBYTES=20000000

while true; do
  TS=$(date '+%Y-%m-%d %H:%M:%S')
  EXT5V=$(vcgencmd pmic_read_adc 2>/dev/null | grep EXT5V_V | grep -oE '[0-9]+\.[0-9]+')
  CORE=$(vcgencmd pmic_read_adc 2>/dev/null | grep VDD_CORE_V | grep -oE '[0-9]+\.[0-9]+')
  THR=$(vcgencmd get_throttled 2>/dev/null | awk -F= '{print $2}')
  LOAD=$(awk '{print $1}' /proc/loadavg)
  FREE=$(free -m | awk '/Mem:/{print $7}')
  DSTATE=$(ps -eo stat= 2>/dev/null | grep -c '^D')
  TOP=$(ps -eo comm=,pcpu= --sort=-pcpu | head -1 | awk '{printf "%s(%.0f%%)",$1,$2}')
  echo "$TS V=$EXT5V core=$CORE thr=$THR load=$LOAD free=${FREE}M dstate=$DSTATE top=$TOP" >> "$LOG"
  sync -f "$LOG"

  SZ=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
  if [ "$SZ" -gt "$MAXBYTES" ]; then
    tail -n 200000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
  sleep 2
done
