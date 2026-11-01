#!/bin/bash
{
  echo "=== $(date '+%F %T') ==="
  free -h
  echo "--- kernel memory (slab leak detector) ---"
  grep -E "^(Slab|SReclaimable|SUnreclaim|KernelStack|PageTables):" /proc/meminfo
  echo "--- top 12 by RSS ---"
  ps -eo pid,rss,comm,args --sort=-rss | head -13
  echo
} >> /var/log/memwatch.log 2>&1
