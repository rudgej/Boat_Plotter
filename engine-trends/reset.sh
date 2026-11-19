#!/bin/bash
# Wipe the engine-trends database (baselines, sessions, reviews) and start clean.
#
# Use after bench testing with a simulator: the statistics are computed
# correctly but describe an engine that does not exist, and a single real run
# would be compared against them.
#
# The daemon holds baselines and in-progress runs in memory, so the service MUST
# be stopped first - deleting the file under a running daemon leaves it with
# stale state that it would happily write back.
#
#   ./reset.sh          asks for confirmation
#   ./reset.sh --force  no prompt (for scripts)
set -euo pipefail

DB_DIR="${ENGINE_TRENDS_DIR:-/home/pi/.engine-trends}"
DB="$DB_DIR/engine-trends.db"

if [ "${1:-}" != "--force" ]; then
    echo "This will permanently delete all engine-trends history:"
    echo "  $DB"
    printf 'Type "yes" to continue: '
    read -r answer
    [ "$answer" = "yes" ] || { echo "aborted"; exit 1; }
fi

echo "stopping engine-trends..."
sudo -n systemctl stop engine-trends

# -wal and -shm must go too, or SQLite can recover the old content into the
# "new" database.
sudo -n rm -f "$DB" "$DB-wal" "$DB-shm"

echo "starting engine-trends..."
sudo -n systemctl start engine-trends
sleep 2

systemctl is-active engine-trends >/dev/null \
    && echo "done - service active, database is empty" \
    || { echo "FAILED - service is not active"; exit 1; }
