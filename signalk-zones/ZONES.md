# Gauge zones (meta.zones)

`set-zones.py` already contains the real paths and zone bands — run it once (§2.8 of
`MIGRATION.md`), then restart Signal K so KIP gauges pick the zones up. Values below are as encoded
in the script (display units; the script converts to SI).

| Path | Band (display) | State |
|---|---|---|
| `propulsion/{port,starboard}/temperature` | 0–85.9 / 85.9–92.9 / 92.9+ °C | nominal / alert / warn |
| `propulsion/{port,starboard}/oilTemperature` | 0–100.9 / 100.9–110.9 / 110.9+ °C | nominal / alert / warn |
| `propulsion/{port,starboard}/oilPressure` | 0–1 / 1–2 / 2+ bar | warn / alert / nominal |
| `propulsion/{port,starboard}/boostPressure` | 0–5 / 5+ bar | nominal / warn |
| `environment/depth/belowTransducer` | 0–2 / 2+ m | warn / nominal |
| `electrical/batteries/0/voltage` | 0–23 / 23–24 / 24–28.5 / 28.5+ V | warn / alert / nominal / warn |

## Status: APPLIED and verified on the N100 (2026-11-19)

All 10 paths carry their zones, and they survive a Signal K restart.

### Authentication is required

Signal K security is enabled on this box, so the script's original unauthenticated `PUT`s failed
with `401 Unauthorized`. `set-zones.py` now takes a bearer token — either `SIGNALK_TOKEN`, or
`SIGNALK_USER` + `SIGNALK_PASSWORD` and it logs in itself. The credentials already exist for the
automation units, so run it with:

```bash
sudo bash -c 'set -a; . /etc/signalk-automation.env; set +a; python3 /tmp/set-zones.py'
```

It now reads each path back after writing and reports `readback OK`, so a silent failure is not
possible.

### Persistence

Zones are stored in `/home/pi/.signalk/baseDeltas.json`, which Signal K replays at startup. Verified
by restarting `signalk` and reading the paths back **without** re-applying — every path still had its
zones. No cron job or plugin is needed to keep them.

### Note on checking

`environment.wind.speedApparent` is **not** in the target list and never will have zones. Checking
that path for zones returns nothing and says nothing about whether this script worked. Verify against
the paths in the table above.

The script is idempotent — re-running it is harmless.
