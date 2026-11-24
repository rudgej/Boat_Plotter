# NMEA 2000 — the live bus

First connection of the N100 to the **real boat CAN bus** (everything before 2026-11-24 was bench
testing against a simulator). This document records what is actually on the network, what Signal K
does with it, and what is still broken.

**Verified on the boat, 2026-11-24**, using `candump` on `can0` plus the Signal K REST API.

---

## 1. Interface

| Item | Value |
|---|---|
| Adapter | CANable / Geschwister Schneider, USB `1d50:606f` |
| Kernel driver | `gs_usb` (+ `can_dev`, `can_raw`) |
| Interface | `can0` |
| Bitrate | **250 kbit/s**, sample point 0.875 |
| State | `ERROR-ACTIVE`, `restart-ms 0` |
| Bring-up unit | `can0-nmea2000.service` (oneshot, `Before=signalk.service`) |
| Health check | `can-watchdog.timer` → `can-watchdog.service` every 10 s |
| Bus load | ~150 frames/s, 23 distinct PGNs |

Do **not** add `After=dev-can0.device` to the bring-up unit — `/dev/can0` does not exist for a
network interface and the job hangs the whole boot. See `MIGRATION.md`.

---

## 2. Devices on the bus

Identified from each device's ISO Address Claim (`60928`) and Product Information (`126996`).

| Source addr | Manufacturer | Unique no. | Device function | Sends |
|---|---|---|---|---|
| **1** | Garmin (229) | 120040 | 145 — GNSS | Position, COG/SOG, time, variation, DOPs, sats in view, proprietary 126720 |
| **2** | Garmin (229) | 1076725 | 205 | Heading, depth, speed through water, navigation data, temperature, XTE, variation, proprietary 126720 |
| **9** | Garmin (229) | 2070918 | 160 | Address claim only |
| **56** | Yacht Devices (717) | 30255 | 160 | **Engine gateway** — 127488, 127489, 127497, 127505, 127508 |
| **100** | Signal K (999) | 31415 | — | The N100 itself: 130306 wind, 127505 fresh water |

`SA 25` (mfg 2046) appears in Signal K's source table with a single `126998` from four days ago.
Nothing else is heard from it — treat as not present.

---

## 3. PGN inventory

Counts are **CAN frames**, not messages. Fast-packet PGNs use several frames per message:
`127489` = 4 frames/message, `127497` = 2, `129540` ≈ 24, `126720` ≈ 10.

| PGN | Parameter Group | Source | Frames / 45 s | ~Rate | Status |
|---|---|---|---|---|---|
| 129540 | GNSS Sats in View | 1 | 1434 | 31.9 Hz | ✅ decoded |
| 126720 | Manufacturer Proprietary (fast-packet) | 1, 2 | 1215 | 27.0 Hz | ❌ not decoded (vendor-specific, no public definition) |
| 127488 | Engine Rapid Update | 56 | 904 | 20.1 Hz | ✅ 10 Hz per engine |
| 127489 | Engine Dynamic Parameters | 56 | 728 | 16.2 Hz | ✅ 2 Hz per engine (4 frames each) |
| 127250 | Vessel Heading | 2 | 450 | 10.0 Hz | ✅ decoded |
| 129025 | Position, Rapid Update | 1 | 448 | 10.0 Hz | ✅ decoded |
| 129026 | COG & SOG, Rapid Update | 1 | 448 | 10.0 Hz | ✅ decoded |
| 129029 | GNSS Position Data | 1 | 315 | 7.0 Hz | ✅ decoded |
| 129284 | Navigation Data | 2 | 225 | 5.0 Hz | ✅ decoded |
| 127497 | Trip Parameters, Engine | 56 | 180 | 4.0 Hz | ⚠️ decoded but **gateway truncates it** |
| 127258 | Magnetic Variation | 1, 2 | 90 | 2.0 Hz | ✅ decoded |
| 130306 | Wind Data | 100 | 90 | 2.0 Hz | ✅ transmitted by Signal K |
| 127505 | Fluid Level | 56, 100 | 63 | 1.4 Hz | ⚠️ two sources, see §7 |
| 128259 | Speed, Water Referenced | 2 | 45 | 1.0 Hz | ⚠️ paddle wheel dead, reads 0 |
| 128267 | Water Depth | 2 | 45 | 1.0 Hz | ✅ decoded |
| 129283 | Cross Track Error | 2 | 45 | 1.0 Hz | ✅ decoded (sends "not available", no route) |
| 126992 | System Time | 1 | 45 | 1.0 Hz | ✅ decoded |
| 129539 | GNSS DOPs | 1 | 45 | 1.0 Hz | ✅ decoded |
| 127508 | Battery Status | 56 | 31 | 0.7 Hz | ✅ 26.05 V, current/temp N/A |
| 130312 | Temperature | 2 | 9 | 0.2 Hz | ❌ sender dead, reads −4.7 °C |
| 59904 | ISO Request | 2 | 4 | 0.1 Hz | transport |
| 60928 | ISO Address Claim | 9 | 4 | 0.1 Hz | transport |
| 126993 | Heartbeat | 56, 100 | 2 | 0.0 Hz | transport |

Bus totals: **6,865 frames in 45 s ≈ 153 frames/s**, 23 distinct PGNs.

---

## 4. Signal K configuration

Provider `n2k-can0` in `~/.signalk/settings.json`:

```json
{
  "id": "n2k-can0",
  "enabled": true,
  "pipeElements": [{
    "type": "providers/simple",
    "options": {
      "type": "NMEA2000",
      "subOptions": {
        "type": "canbus-canboatjs",
        "interface": "can0",
        "uniqueNumber": 31415,
        "mfgCode": 999
      }
    }
  }]
}
```

Versions verified current on 2026-11-24: `signalk-server` 2.37.0, `@canboat/canboatjs` 3.20.0,
`@canboat/ts-pgns` 1.11.18 (correct — canboatjs 3.20.0 requires `^1.11.9`; the 5.x on npm is a
different major it does not use).

---

## 5. Engine data (gateway at SA 56)

Two instances, 0 = port, 1 = starboard. Confirmed independent: stopping starboard drops its
`rpm`, fuel rate and oil pressure to zero while port continues unaffected.

| Field | PGN | Port | Starboard | Signal K path |
|---|---|---|---|---|
| rpm | 127488 | 521–529 | 0 / 527 | `propulsion.*.revolutions` (**rev/s**, ×60 for rpm) |
| Boost | 127488 | 6000–8000 Pa | 6000–8000 Pa | `propulsion.*.boostPressure` |
| Trim | 127488 | N/A | N/A | — |
| Oil pressure | 127489 | 360–484 kPa | 480 kPa | `propulsion.*.oilPressure` |
| Oil temperature | 127489 | 295–311 K | 289 K | `propulsion.*.oilTemperature` |
| Coolant temperature | 127489 | 301–315 K | 289–292 K | `propulsion.*.temperature` |
| Alternator | 127489 | 26.05–26.15 V | **N/A** | `propulsion.*.alternatorVoltage` |
| Fuel rate | 127489 | 1.8 → 3.1 L/h (cold → warm) | 1.8 L/h (cold) | `propulsion.*.fuel.rate` (**m³/s**) |
| Engine hours | 127489 | 1190.0 h | 1191.3 h | `propulsion.*.runTime` (**seconds**) |
| Coolant pressure | 127489 | N/A | N/A | ⚠️ shows as `0` |
| Fuel pressure | 127489 | 344 kPa | 336 kPa | ❌ **×1000 wrong in Signal K** |
| Load / torque | 127489 | N/A | N/A | — |
| Discrete status 1/2 | 127489 | `0x0000` | `0x0000` | 24 × `notifications.propulsion.*` |
| Battery voltage | 127508 | — | 26.05 V | `electrical.batteries.1.voltage` |

**Only one voltage source exists on the bus.** Alternator voltage appears on instance 0 only;
starboard sends `0x7FFF` (not available). Battery Status carries instance 1 only. Same 26.05 V,
reported twice under different instance numbering.

### Fuel rate depends on engine temperature — it is not a fault

Measured on the raw bus (`127489`, byte 9–10 × 0.1). Fuel rate and oil pressure move in opposite
directions as the engine warms, which is the expected signature of a cold start:

| Time | State | rpm | Fuel rate | Oil pressure |
|---|---|---|---|---|
| 09:34 | port alone, just started (cold) | 525 | 1.8 L/h (`12 00`) | 4.84 bar |
| 09:45 | both running | 524 | 3.0 L/h (`1e 00`) | 4.00 bar |
| 09:55 | starboard shut down | 526 | 3.1 L/h (`1f 00`) | 3.68 bar |
| 09:58 | steady | 525 | 3.1–3.2 L/h (`1f`/`20 00`) | 3.60 bar |

Starboard read 1.8 L/h because it had *just* started; port read 1.8 L/h immediately after its own
start and 3.1 L/h once warm. The earlier apparent "67% disparity at matched rpm" was cold versus
warm, not a misscaling. **Confirm by starting starboard cold: it should read ~1.8 L/h and climb
towards ~3.1 L/h as it warms.**

**Discrete status** is two 16-bit bitfields of engine warning-lamp states, mapped by Signal K into
24 discrete notifications:

- *Status 1:* Check Engine, Low Oil Pressure, Low Oil Level, Low Fuel Pressure, Low System Voltage,
  Low Coolant Level, Water Flow, Water In Fuel, Charge Indicator, Preheat Indicator, High Boost
  Pressure, Rev Limit Exceeded, EGR System, Throttle Position Sensor, Emergency Stop Mode,
  Warning Level 1
- *Status 2:* Warning Level 2, Power Reduction, Maintenance Needed, Engine Shutting Down,
  Sub/Secondary Throttle, Neutral Start Protect

`0x0000` = every lamp off, which is now meaningful because the gateway has real engine data.

---

## 6. What Signal K transmits onto the bus

Signal K claims address **100** and transmits:

| PGN | Content | Rate | Why |
|---|---|---|---|
| 130306 | Wind, **Reference 2 = Apparent** | 2 Hz | The masthead sensor's own readings, so the Garmin displays get wind |
| 127505 | Fluid level, type 1 (fresh water), instance 0 | ~1 Hz | From the ESP32 water sensor via NMEA 0183 UDP |

Transmit counters confirm this is the *only* thing the N100 puts on the bus: a 10-second window
showed a TX delta of 9, and all 9 frames were fluid level.

---

## 7. Changes made on 2026-11-24

Both edits are to plugin configuration under `~/.signalk/plugin-config-data/`. Timestamped
backups were taken as `*.bak-20261124-091345`.

### 7.1 `derived-data.json` — enable true heading

```json
"configuration": {
  "wind":    { "groundWind": true, "directionTrue": true, "windShift": true },
  "heading": { "heading": true }
}
```

**Why:** `navigation.headingTrue` did not exist, and the ground-wind calculator requires four
inputs — `headingTrue`, `speedOverGround`, `speedApparent`, `angleApparent`. Three were present,
so it silently returned `null` every cycle. Enabling the `heading` group (which derives
`headingTrue` from `headingMagnetic` + `magneticVariation`) unlocked it immediately.

**Result:** `environment.wind.directionTrue`, `angleTrueGround` and `speedOverGround` now populate,
computed from **GPS SOG** — the dead paddle wheel is never consulted.

### 7.2 `sk-to-nmea2000.json` — publish apparent wind

```json
"configuration": {
  "TANKS":   { "enabled": true, "tanks": [{ "signalkPath": "tanks.freshWater.0", "instanceId": 0 }] },
  "WINDv2":  { "enabled": true }
}
```

**Why:** `WIND_TRUE_GROUND` was enabled but emitted nothing, for the same reason as above — its
first required path (`environment.wind.directionTrue`) did not exist. `WINDv2` uses
`angleApparent` + `speedApparent`, which do exist, and publishes Reference 2 (Apparent).

**Result:** `130306` now on the bus at 2 Hz from SA 100, confirmed by capture.

**Do not use `WIND_TRUE_GROUND` to publish true wind.** Its keys are `directionTrue` +
`environment.wind.speedOverGround`, which is correct — but the apparent-wind path is the one the
Garmin instruments expect to receive, and they derive true wind themselves.

---

## 8. Known defects

| # | Defect | Evidence | Owner |
|---|---|---|---|
| 1 | **Fuel pressure ×1000** | raw `344 kPa`, canboatjs emits `344000`, Signal K publishes `344000000` | Signal K / canboat integration |
| 2 | **"Not available" becomes `0`** | canboat omits `coolantPressure` entirely; Signal K publishes `0` | Signal K |
| 3 | **`127497` truncated** | gateway sends **9 bytes** where the standard defines 15; fuel-rate average/economy are `0x7FFF…` | Yacht Devices gateway |
| 4 | **`tripFuelUsed` is not fuel** | 7826 L (port) / 41145 L (stbd) after minutes of idling; port crept +1 L in ten minutes; stbd froze on shutdown | consequence of #3 |
| 5 | **Boost implausible** | 0.06–0.08 bar at idle, and identical on both engines when one was stopped | gateway |
| 6 | **Fresh water reported twice** | SA 100 transmits it (Signal K), SA 56 echoes it back | gateway echo |
| 7 | **Unit-preference paths wrong** | `default-categories.json` lists `propulsion.*.fuelPressure`; real path is `propulsion.*.fuel.pressure` | Signal K |
| 8 | **No gear/transmission data** | `127493` never appears on the bus | gateway |

### Fuel pressure — the one to remember

```js
// canboatjs, fed the real bytes:
{ fuelPressure: 344000 }          // 3.44 bar — correct

// Signal K data model:
propulsion.port.fuel.pressure = 344000000   // 3,520 bar — wrong, exactly ×1000
```

Only this field is affected. `oilPressure` (resolution 100) and `boostPressure` (resolution 100)
are both correct; `fuelPressure` has resolution 1000. The scaling code could not be located —
there are no literal `oilPressure` or `"propulsion.` strings in `signalk-server` or `canboatjs`,
so the mapping is assembled dynamically. Versions are current, so no upgrade fixes it.

**Workaround: divide `propulsion.*.fuel.pressure` by 1000 in any consumer.**

### Dead sensors — not faults

| Sensor | Symptom | Consequence |
|---|---|---|
| Paddle wheel (speed through water, 128259) | reads `0` always | True wind must use **SOG**, not STW. Garmin's own true-wind page will therefore be wrong while moving unless its boat-speed source is set to GPS |
| Water temperature sender (130312) | reads −4.7 °C | `environment.water.temperature` is garbage; filter it or ignore |

---

## 9. Unit traps when building dashboards

Signal K stores SI values. Gauges must convert:

| Path | Unit stored | To get |
|---|---|---|
| `propulsion.*.revolutions` | **rev/s** | × 60 → rpm |
| `propulsion.*.fuel.rate` | **m³/s** | × 3,600,000 → L/h |
| `propulsion.*.temperature`, `oilTemperature` | **Kelvin** | − 273.15 → °C |
| `propulsion.*.runTime` | **seconds** | ÷ 3600 → hours |
| `propulsion.*.trip.fuelUsed` | **m³** | × 1000 → L (but see defect #4) |
| `propulsion.*.oilPressure` | Pa | ÷ 100,000 → bar |

Multiplying twice is the classic error — e.g. applying the rpm conversion to a value already in rpm.

---

## 10. Verification commands

On the N100:

```sh
# interface state and error counters
ip -details -statistics link show can0

# who is on the bus
timeout 20 candump can0 | awk '{print $2}' | sort | uniq -c | sort -rn

# every distinct payload for one PGN (spot "not available" = ff ff / ff 7f / 7f)
timeout 20 candump can0 | grep 09F20138 | awk '{print $4 " " $5 " " $6 " " $7 " " $8 " " $9 " " $10 " " $11}' | sort -u

# what Signal K holds
curl -s localhost:3000/signalk/v1/api/vessels/self/propulsion/port | python3 -m json.tool

# true wind chain
curl -s localhost:3000/signalk/v1/api/vessels/self/environment/wind | python3 -m json.tool
```

Reading a raw `127489` payload (26 bytes, after the fast-packet length byte):

```
 00  e8 12  73 0b  db 74  32 0a  12 00  90 5b 41 00  ff ff  58 01  7f  00 00  00 00  7f 7f
 i   oilP   oilT    temp   alt    fuel   engineHours  coolP  fuelP  rsv  d1   d2   load trq
     ×100   ×0.1   ×0.01  ×0.01   ×0.1      ×1 s      ×100   ×1000
```

---

## 11. Open items

1. Fix fuel pressure scaling (defect #1) and the not-available→0 substitution (defect #2).
2. Confirm the cold/warm fuel-rate behaviour by starting starboard cold (see §5) — expected ~1.8 L/h
   rising to ~3.1 L/h, matching port.
3. Stop SA 56 echoing the fresh-water level back onto the bus (defect #6).
4. Ask the gateway for `127493` (gear) and for a full-length `127497`.
5. Publish true wind to N2K as well as apparent, or rely on the Garmin computing it.
6. Filter the dead water-temperature sender out of the data model.
