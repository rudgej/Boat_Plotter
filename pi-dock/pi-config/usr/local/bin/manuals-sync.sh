#!/bin/bash
# One-way sync of the boat manuals library: Dropbox -> local.
# Idempotent and safe to run on a timer. Never writes back to Dropbox.
#
# Remote name and folder are set up once with `rclone config` (see
# pi-dock/dropbox/README.md). Nothing secret lives in this repo.
LOG="${MANUALS_LOG:-$HOME/manuals-sync.log}"
REMOTE="${MANUALS_REMOTE:-dropbox:Boat-Manuals}"
LOCAL="${MANUALS_LOCAL:-/home/pi/manuals}"

# The service runs as User=pi, so it must log somewhere pi can write. Keeping
# the log under /var/log needs a pre-created file owned by pi, and on a rebuilt
# box that file does not exist yet - the sync then failed silently on every
# timer tick ("Permission denied") while still looking "finished" to systemd.
# $HOME is always writable, so this cannot regress. Override with MANUALS_LOG.
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

# No network, no point: fail quietly rather than filling the log on the boat.
if ! rclone lsd "$REMOTE" >/dev/null 2>&1; then
    echo "$(date '+%F %T') remote unreachable, skipping" >>"$LOG"
    exit 0
fi

mkdir -p "$LOCAL"
# NOTICE rather than INFO: a run that changes nothing should produce almost no
# log. The library is static, so INFO per-file lines are pure noise over years.
if rclone sync "$REMOTE" "$LOCAL" --log-file "$LOG" --log-level NOTICE \
        --stats-one-line; then
    echo "$(date '+%F %T') sync ok ($(find "$LOCAL" -type f | wc -l) files)" >>"$LOG"
else
    echo "$(date '+%F %T') sync FAILED" >>"$LOG"
    exit 1
fi
