# Gauge zones (meta.zones)

`set-zones.py` already contains the real paths and zone bands — run it once (§2.6 of
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

`[TODO-CONFIRM]` whether the script was actually run on the Pi — the values were prepared, but
whether they were applied to the live tree is unverified. The script is idempotent.
