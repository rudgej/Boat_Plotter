# KIP dashboards — inventory

Two dashboards survive in the repo; the rest were lost with the dead Pi.

## Surviving

### "Engine" — `pi-dock/kip-config.json` (`dashboardsConfig`)

Four radial gauges, **port engine only**:

- `self.propulsion.port.revolutions` (rpm)
- `self.propulsion.port.oilPressure`
- `self.propulsion.port.temperature` (coolant)
- `self.propulsion.port.oilTemperature`

**This one does not come back with `.signalk`** — it's injected into the KIP kiosk's Chromium
localStorage over CDP by `inject-kip.sh` + `inject-kip.mjs`, which read `/home/pi/kip-config.json`.
Restore steps are in `MIGRATION.md` §2.9: copy both files to `/home/pi/` (hard-coded paths), make
sure `nodejs` is present, then run `inject-kip.sh`. Requires Node 21+/22+ for a global `WebSocket`.

### "default" — `pi-dock/pi-config/home/pi/.signalk/applicationData/users/boat/kip/11.0.0.json`

The main helm dashboard (10 numeric, 6 linear gauges, 1 compass, 1 wind-steer, 1 boolean switch,
2 text):

- **wind** — `angleApparent`, `speedApparent`, `directionTrue`, `angleTrueGround`, `speedOverGround`
- **nav** — `speedOverGround`, `courseOverGroundTrue`, `headingTrue`, `course.calcValues.bearingTrue`
- **depth** — `environment.depth.belowTransducer`
- **engines (both)** — `propulsion.{port,starboard}.{revolutions,temperature,oilPressure,oilTemperature}`
- **fuel** — `propulsion.{port,starboard}.fuel.rate`, `propulsion.main.fuel.economy`
- **holding tank** — `electrical.switches.shellyplus1-e465b842fb34.state`,
  `holdingTank.dumpAutoActive`, `holdingTank.dumpTimeRemainingText`

## Lost (rebuild by hand) — `[TODO-CONFIRM]`

~3 dashboards did not survive; contents unknown. At minimum a **Starboard** gauge dashboard
mirroring "Engine" is likely. Rebuild them after the box is live and the `self` tree is visible.
