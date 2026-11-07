#!/bin/bash
{
  echo "=== $(date '+%F %T') ==="
  free -h
  echo "--- top 12 by RSS ---"
  ps -eo pid,rss,comm,args --sort=-rss | head -13
  echo
} >> /var/log/memwatch.log 2>&1
