#!/bin/bash
# One-way sync of the boat manuals library: Dropbox -> local.
# Idempotent and safe to run on a timer. Never writes back to Dropbox.
#
# Remote name and folder are set up once with `rclone config` (see
# pi-dock/dropbox/README.md). Nothing secret lives in this repo.
LOG=/var/log/manuals-sync.log
REMOTE="${MANUALS_REMOTE:-dropbox:BoatManuals}"
LOCAL="${MANUALS_LOCAL:-/home/pi/manuals}"

# No network, no point: fail quietly rather than filling the log on the boat.
if ! rclone lsd "$REMOTE" >/dev/null 2>&1; then
    echo "$(date '+%F %T') remote unreachable, skipping" >>"$LOG"
    exit 0
fi

mkdir -p "$LOCAL"
if rclone sync "$REMOTE" "$LOCAL" --log-file "$LOG" --log-level INFO --stats-one-line; then
    echo "$(date '+%F %T') sync ok ($(find "$LOCAL" -type f | wc -l) files)" >>"$LOG"
else
    echo "$(date '+%F %T') sync FAILED" >>"$LOG"
    exit 1
fi
