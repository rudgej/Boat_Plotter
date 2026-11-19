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
Restore steps are in `MIGRATION.md` §2.10: copy both files to `/home/pi/` (hard-coded paths), make
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

## Lost — being rebuilt by hand by the owner (decision, 2026-11-19)

~3 dashboards did not survive the dead Pi and their contents are not recoverable. **This is closed
as a documentation item** — the owner has decided to recreate all dashboards from scratch in the KIP
editor rather than attempt a reconstruction, so no further inventory work is needed here.

KIP editor, as served by the running box:

```
http://bossy.local:3000/@mxtommy/kip/
```

(by IP: `http://192.168.1.183:3000/@mxtommy/kip/` — the plugin is `@mxtommy/kip` v4.8.5)

Note the `/signalk/@mxtommy/kip/` and `/kip/` variants both return 404; the path above is the only
working one.

Dashboards are per-user browser state unless you log into Signal K in KIP (Settings → Connectivity),
which stores them server-side under
`~/.signalk/applicationData/users/<user>/kip/`. Logging in is what makes a rebuild survive a
re-image, so do that first if the rebuild is worth keeping.

Gauge colours come from the `meta.zones` set by `signalk-zones/set-zones.py` — run that before
judging the gauge colours, and see `signalk-zones/ZONES.md` for the auth requirement.
