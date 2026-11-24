# What data we actually have

Complete inventory of every value Signal K holds from the boat's instruments, verified live on
**2026-11-24**. This is the reference list: if a value is not here, we do not have it.

Companion document: `nmea2000-live-bus.md` (the wire itself — devices, PGNs, rates, defects).

---

## 1. Devices on the NMEA 2000 network

| Source addr | Make | What it is | Contributes |
|---|---|---|---|
| **1** | Garmin (229) | GNSS receiver | Position, SOG, COG, sats, time, variation |
| **2** | Garmin (229) | Instrument/plotter | Heading, depth, speed through water, navigation data, XTE |
| **9** | Garmin (229) | — | Address claim only, no data |
| **56** | Yacht Devices (717) | Engine gateway | Both engines, battery, fuel level |
| **100** | Signal K (999) | The N100 itself | Transmits wind and fresh-water level onto the bus |

Devices seen in the past but not present: **SA 25** (manufacturer 2046 — the home simulator,
contributes no data).

---

## 2. Navigation — position and motion

10 Hz from the Garmin GNSS, path source `n2k-can0.1` unless noted.

| Path | Unit | Example | Notes |
|---|---|---|---|
| `navigation.position` | lat/lon | 43.5861, 7.1231 | 10 Hz |
| `navigation.speedOverGround` | **m/s** | 0.05 | × 1.94384 for knots |
| `navigation.courseOverGroundTrue` | **rad** | 6.2345 | × 57.2958 for degrees |
| `navigation.datetime` | ISO | 2026-11-24T10:26:40Z | from PGN 126992 |
| `navigation.headingMagnetic` | **rad** | 4.7123 | `n2k-can0.2` |
| `navigation.magneticVariation` | rad | 0.0234 | `n2k-can0.2` |
| `navigation.headingTrue` | rad | 4.7357 | **derived** (magnetic + variation) |
| `navigation.speedThroughWater` | m/s | 0 | ⚠️ paddle wheel dead, always 0 |
| `navigation.speedThroughWaterReferenceType` | enum | 129 | Paddle wheel |
| `navigation.gnss.satellites` | count | 18–20 | |
| `navigation.gnss.satellitesInView` | object | count + per-sat elev/az/SNR | |
| `navigation.gnss.horizontalDilution` | ratio | 0.59 | HDOP |
| `navigation.gnss.positionDilution` | ratio | 0.97 | PDOP |
| `navigation.gnss.geoidalSeparation` | m | 47.62 | |
| `navigation.gnss.antennaAltitude` | m | 50.93 | |
| `navigation.gnss.type` | string | GPS+SBAS/WAAS+GLONASS | |
| `navigation.gnss.methodQuality` | string | DGNSS fix | |
| `navigation.gnss.integrity` | string | no Integrity checking | |

---

## 3. Navigation — route and waypoint

From the plotter's `127284` Navigation Data plus Signal K's own course calculation
(`course-provider`). Verified with an active ROUTE TO and in autopilot track mode.

| Path | Unit | Example | Notes |
|---|---|---|---|
| `navigation.course.calcValues.distance` | **m** | 627.1 | to active waypoint |
| `navigation.course.calcValues.bearingTrue` | **rad** | 1.2483 | |
| `navigation.course.calcValues.bearingMagnetic` | rad | 1.2140 | |
| `navigation.course.calcValues.bearingTrackTrue` | rad | 1.2461 | track, not bearing |
| `navigation.course.calcValues.bearingTrackMagnetic` | rad | 1.2118 | |
| `navigation.course.calcValues.crossTrackError` | **m** | −1.42 | negative = left of track |
| `navigation.course.calcValues.estimatedTimeOfArrival` | ISO | 2026-11-24T23:19:47Z | |
| `navigation.course.calcValues.timeToGo` | **s** | 46388 | |
| `navigation.course.calcValues.velocityMadeGood` | m/s | 0.0135 | |
| `navigation.course.calcValues.calcMethod` | string | GreatCircle | |
| `navigation.course.calcValues.previousPoint.distance` | m | 1.76 | |
| `navigation.courseGreatCircle.bearingTrackTrue` | rad | 1.2458 | direct from `127284` |
| `navigation.courseGreatCircle.activeRoute.startTime` | ISO | 2026-11-24T10:04:47Z | when route was activated |

**Not available:** `route.distance`, `route.estimatedTimeOfArrival`, `route.timeToGo`,
`targetSpeed` — all `None`. There is **no NMEA 2000 PGN for a whole route**, only the next
waypoint. A full route only exists if it is created in Signal K itself (AvNav or the course API),
not on the Garmin.

The destination position (43.6179570 N, 7.1304639 E) is in the `127284` frame but does **not**
appear in `courseGreatCircle.nextPoint.position` — Signal K calculates the course instead of
taking the plotter's destination.

---

## 4. Wind

| Path | Unit | Source | Notes |
|---|---|---|---|
| `environment.wind.angleApparent` | **rad** | `nmea0183-wind.WI` | ESP32 sensor, relative to bow |
| `environment.wind.speedApparent` | **m/s** | `nmea0183-wind.WI` | |
| `environment.wind.directionTrue` | rad | `derived-data` | **computed** from apparent + SOG |
| `environment.wind.angleTrueGround` | rad | `derived-data` | computed |
| `environment.wind.speedOverGround` | **m/s** | `derived-data` | ⚠️ this is **wind** speed, not boat speed |

True wind is computed using **GPS SOG**, never the paddle wheel. Displayed correctly on the
Garmin, which receives `130306` Reference 2 (Apparent) from Signal K at 2 Hz.

### Relative angle vs compass bearing — the CYD trap

Two different things wear the label "wind direction", and mixing them up is the easiest mistake
to make on this boat.

Worked example: **boat heading 270°, stopped, wind from the bow at 5 kt.**

| Where | Shows | What it means |
|---|---|---|
| Signal K `angleApparent` | `0` rad | from the bow — **relative** |
| Signal K `directionTrue` | `270°` (4.712 rad) | from the west — **compass** |
| Garmin apparent page | `0°`, 5 kt | relative |
| Garmin true page | `270°`, 5 kt | compass, computed on the Garmin |
| **CYD connected to Signal K** | `270°`, 5 kt | compass — correct, it is fed `directionTrue` |
| **CYD in local mode** | `000°`, 5 kt | **relative only** — `000` means *dead ahead*, **not** north |

`directionTrue = headingTrue + angleApparent`. With the wind dead ahead the two are equal, which
is why direction and heading matched exactly in the 2026-11-24 capture.

**The CYD only reports a relative angle when it has no heading to work from** — that is, in local
mode when the N100 is unavailable and it is running on the fallback AP. Connected to Signal K it
receives `directionTrue` and displays a proper compass bearing. So a `000` on the CYD is a
symptom of local mode, and should be read as "on the bow", never as a compass direction.

When the boat moves, the CYD's relative reading stays relative (still correct), while Signal K
recalculates `directionTrue` using SOG. One approximation: ground wind subtracts SOG along the
**heading** axis rather than the COG axis, so it drifts slightly with strong current or leeway —
the honest limit of having no working paddle wheel.

---

## 5. Environment — depth and temperature

| Path | Unit | Source | Notes |
|---|---|---|---|
| `environment.depth.belowTransducer` | **m** | `n2k-can0.2` | 1 Hz, working |
| `environment.water.temperature` | **K** | `n2k-can0.2` | ⚠️ sender dead, reads 268.44 K = −4.7 °C |
| `environment.inside.engineRoom.temperature` | **K** | `gentemp.XX` | generator temp sender, e.g. 291.46 K = 18.3 °C |

---

## 6. Engines — port (instance 0) and starboard (instance 1)

Gateway at SA 56. Values below are from the running-engine session.

| Path | Unit | Port (running) | Starboard (running) | Notes |
|---|---|---|---|---|
| `propulsion.*.revolutions` | **rev/s** | 13.17 (= 790 rpm) | 15.15 (= 909 rpm) | × 60 for rpm |
| `propulsion.*.boostPressure` | **Pa** | 8000 | 6000 | 0.06–0.08 bar at idle |
| `propulsion.*.oilPressure` | **Pa** | 452 000 | 504 000 | 4.5–5.0 bar |
| `propulsion.*.oilTemperature` | **K** | 330.1 (57 °C) | 319.1 (46 °C) | |
| `propulsion.*.temperature` | **K** | 332.15 (59 °C) | 324.15 (51 °C) | coolant |
| `propulsion.*.alternatorVoltage` | **V** | 25.85 | **absent** | only one voltage source on the bus |
| `propulsion.*.fuel.rate` | **m³/s** | 3.4 L/h | 3.3 L/h | × 3 600 000 for L/h |
| `propulsion.*.runTime` | **s** | 4 285 800 | 4 289 940 | ÷ 3600 for hours |
| `propulsion.*.trip.fuelUsed` | **m³** | 7.83 (junk) | 41.15 (junk) | ⚠️ not fuel — see defects |
| `propulsion.*.fuel.pressure` | **Pa** | ⚠️ unreliable | ⚠️ unreliable | × 1000 too high when running |

**Fuel rate tracks engine temperature**, not a fault: 1.8 L/h cold → 3.1–3.4 L/h warm, at the
same rpm. Confirmed by both engines converging to 3.3–3.4 L/h once warm.

**Not available from this gateway:** engine load, engine torque, tilt/trim, coolant pressure,
gear/transmission (`127493` is never transmitted).

---

## 7. Electrical

| Path | Unit | Source | Notes |
|---|---|---|---|
| `electrical.batteries.1.voltage` | **V** | `n2k-can0.56` | 25.2–26.15 V (24 V system) |
| `electrical.switches.shellyplus1-e465b842fb34.state` | bool | `signalk-shelly2` | |
| `electrical.switches.shellyplus1-e465b842fb34.input.on` | bool | `signalk-shelly2` | |
| `electrical.switches.shellyplus1-e465b842fb34.temperature` | **K** | `signalk-shelly2` | |
| `...address` / `...hostname` / `...id` / `...model` | string | `signalk-shelly2` | device metadata |

---

## 8. Tanks

| Path | Unit | Source | Notes |
|---|---|---|---|
| `tanks.freshWater.0.currentLevel` | **ratio** | `nmea0183-wind.35` | 0.81 = 81 %, live but ⚠️ timestamp frozen at 2010-01-01 |
| `tanks.freshWater.0.capacity` | **m³** | `nmea0183-wind.35` | 1.0 m³ = 1000 L |
| `tanks.fuel.1.currentLevel` | ratio | `n2k-can0.56` | ⚠️ 0 % from the gateway, capacity N/A — sensor not connected |

---

## 9. Engine trend monitor (plugin output, derived)

Per engine, under `engineHealth.port.*` and `engineHealth.starboard.*`, 33 paths each:

| Path pattern | Meaning |
|---|---|
| `engineHealth.<eng>.band` | Operating band, e.g. `Idle / manoeuvring` |
| `engineHealth.<eng>.status` | `NORMAL` |
| `engineHealth.<eng>.rpm.current` / `.baselineStatus` / `.readout` | rpm vs baseline |
| `engineHealth.<eng>.coolant.*` | coolant °C vs baseline |
| `engineHealth.<eng>.oilTemp.*` | oil °C vs baseline |
| `engineHealth.<eng>.oilPressure.*` | bar vs baseline |
| `engineHealth.<eng>.fuel.*` | L/h vs baseline |
| `engineHealth.<eng>.boost.*` | bar vs baseline |
| `engineHealth.<eng>.message` | summary text |

Baselines are `N/A` until enough running hours have been recorded.

---

## 10. Alarms and notifications

| Path | State | Meaning |
|---|---|---|
| 28 × `notifications.propulsion.<eng>.<flag>` per engine | mostly `normal` | Engine warning lamps from `127489` discrete status bitfields |
| `notifications.environment.depth.belowTransducer` | `warn` | Depth below 2 m |
| `notifications.n2kEngineFix.status` | `normal` | Breadcrumb from the local fix plugin |

Engine flags cover: check engine, low oil pressure/level, low fuel pressure, low system voltage,
low coolant level, water flow, water in fuel, charge indicator, preheat, high boost, rev limit,
EGR, throttle sensor, emergency stop, warning levels 1 and 2, power reduction, maintenance,
shutting down, sub/secondary throttle, neutral start protect, comm error, over-temperature.

### 10.1 Engine alarms — the complete list

**28 notification paths per engine**, 56 in total, from two different origins. Paths are
`notifications.propulsion.port.*` and `notifications.propulsion.starboard.*`.

**24 come from the gateway's Discrete Status bitfields** (`$source: n2k-can0.56`) — these are the
engine's own warning lamps, transmitted in PGN 127489. `0x0000` = all clear, which is what the
engines reported throughout the 2026-11-24 session:

| Flag | Indicates |
|---|---|
| `checkEngine` | General ECU fault / "check engine" lamp |
| `lowOilPressure` | Oil pressure below threshold |
| `lowOilLevel` | Oil level low |
| `lowFuelPressure` | Fuel supply pressure low |
| `lowSystemVoltage` | Charging system voltage low |
| `lowCoolantLevel` | Coolant level low |
| `waterFlow` | Cooling water flow problem |
| `waterInFuel` | Water in the fuel filter/separator |
| `chargeIndicator` | Alternator/charging fault lamp |
| `preheatIndicator` | Glow-plug/preheat active |
| `highBoostPressure` | Turbo/supercharger over-boost |
| `revLimitExceeded` | Engine exceeded its rev limit |
| `eGRSystem` | EGR system fault |
| `throttlePositionSensor` | Throttle position sensor fault |
| `emergencyStopMode` | Emergency stop engaged |
| `warningLevel1` | Manufacturer warning, level 1 |
| `warningLevel2` | Manufacturer warning, level 2 |
| `powerReduction` | Engine derating power |
| `maintenanceNeeded` | Maintenance due |
| `shuttingDown` | Engine in shutdown sequence |
| `subOrSecondaryThrottle` | Secondary throttle active/faulty |
| `neutralStartProtect` | Neutral start protection active |
| `commError` | Communication error on the engine bus |
| `overTemperature` | Engine over-temperature |

The first 16 correspond to the standard **Discrete Status 1** warning-lamp set; the rest to
**Discrete Status 2** (derate and protection flags). Note that canboat's PGN definition does
*not* enumerate the individual bits, so exact bit positions are not documented here — only the
resulting Signal K paths, which are what a dashboard consumes.

**4 are Signal K's own threshold alerts** (`$source: self.notificationhandler`), computed from
value ranges rather than reported by the engine:

| Flag | Rule Signal K applies |
|---|---|
| `oilPressure` | 200 000 < value < 2 000 000 Pa |
| `oilTemperature` | 273.15 < value < 374.05 K |
| `temperature` | 273.15 < value < 359.05 K |
| `boostPressure` | 0 < value < 500 000 Pa |

These are the ones that produced the false low-oil-pressure warning while the engine was merely
switched off — the gateway reported `0` Pa and Signal K had no way to know it meant "no data".

Plus two non-engine notifications:

| Path | State | Meaning |
|---|---|---|
| `notifications.environment.depth.belowTransducer` | `warn` | Depth below 2 m |
| `notifications.n2kEngineFix.status` | `normal` | Breadcrumb from the local fix plugin |

---

## 11. SeaKeeper gyro — available over MQTT, not N2K

There is **no standard NMEA 2000 PGN for a gyro stabiliser**, so a SeaKeeper cannot be read off
the CAN bus in anything decodable. Its data comes over **MQTT**, bridged into Signal K at 1 Hz by
the `seakeeper-signalk` plugin in this repo (`seakeeper-link.md` has the full protocol).

**Current state: offline.** The plugin is installed and enabled, but `enp2s0` shows
`NO-CARRIER` — the SeaKeeper Ethernet link is not plugged in, so no `seakeeper-signalk` source
exists in the model.

### 11.1 Every field in the status message

Subscribe to `seakeeper/status/1` on `ws://192.168.0.2:9001/mqtt`. Complete payload, all 34
fields:

| Field | Type | Meaning |
|---|---|---|
| `flywheel_speed` | number | **Actual rotor rpm**, live |
| `flywheel_speed_percent` | number | 0–100, drives the speed ring |
| `flywheel_min_speed` / `flywheel_max_speed` | number | 7600 / 9700 on this unit |
| `flywheel_crt_selected_speed` | number | Selector: 0 = max, 1 = min |
| `stabilize_available` | bool | Gates the Stabilise button — false until at speed |
| `stabilize_enabled` | 0/1 | Stabilisation actually engaged |
| `power_available` / `power_enabled` | 0/1 | Power control state |
| `boat_roll_angle` | float | **Degrees** — the boat's roll, the number worth plotting |
| `gyro_angle` | float | Degrees |
| `roll_angle_flipped` | bool | Display inversion flag |
| `battery_voltage` | float | V (12.4 V nominal here) |
| `battery_displayed` / `battery_segments` | number | Battery gauge rendering |
| `drive_current` | float | A |
| `drive_temperature` | **string** | e.g. `"29.0° C"` — parse, do not treat as a number |
| `enclosure_pressure` | **string** | |
| `sea_hours` | number | Hours at sea (1311) |
| `run_hours` | number | Total run hours (1434) |
| `serial` | string | `"60055"` |
| `model` | string | `"6"` |
| `seakeeper_instance` | number | Instance id |
| `gcm`, `imu`, `tcml`, `display`, `drive1`, `drive2` | string | Firmware/hardware versions |
| `language` | number | |
| `graph_is_dial_left` | 0/1 | Display orientation |
| `progress_bar_available` | bool | |
| `progress_bar_percentage` | number | |
| `active_alarm_history` | number | Alarm history count |

### 11.2 What the bridge publishes into Signal K

| Signal K path | From | Units |
|---|---|---|
| `navigation.attitude.roll` | `boat_roll_angle` | **radians** (unit sends degrees) |
| `propulsion.gyro.rpm` | `flywheel_speed` | rpm |
| `propulsion.gyro.targetRpm` | `flywheel_crt_selected_speed` | rpm |
| `propulsion.gyro.powerEnabled` | `power_enabled` | bool |
| `propulsion.gyro.stabilizeEnabled` | `stabilize_enabled` | bool |
| `propulsion.gyro.stabilizeAvailable` | `stabilize_available` | bool |
| `notifications.seakeeper` | `alarming_seekepers` | normal / alarm |

Fields **not** currently bridged but available: `sea_hours`, `run_hours`, `battery_voltage`,
`drive_current`, `drive_temperature`, `enclosure_pressure`, `gyro_angle`.

### 11.3 Commands (MQTT publish)

To `seakeeper/request/1`, JSON payloads: `{"power":1}` / `{"power":0}`,
`{"flywheel_speed":1}` (min) / `{"flywheel_speed":0}` (max — note the inversion),
`{"stabilize":1}` / `{"stabilize":0}`.

### 11.4 Getting roll onto the Garmin

Signal K can publish **PGN 127257 Attitude** — a *standard* PGN — from
`navigation.attitude.roll` via the `ATTITUDE` conversion in `sk-to-nmea2000`. That is the clean
route to a roll display on a Garmin, and avoids reverse-engineering proprietary SeaKeeper frames.
Not enabled at the time of writing.


---

## 12. What Signal K transmits onto NMEA 2000

| PGN | Content | Rate |
|---|---|---|
| `130306` | Wind, Reference 2 (Apparent), from the ESP32 sensor | 2 Hz |
| `127505` | Fluid level, fresh water instance 0, ~81 % | ~1 Hz |

---

## 13. Unit conversions — get these wrong and every gauge lies

| Quantity | Signal K stores | Convert |
|---|---|---|
| Engine speed | **rev/s** | × 60 → rpm |
| Fuel rate | **m³/s** | × 3 600 000 → L/h |
| Temperature | **Kelvin** | − 273.15 → °C |
| Engine hours | **seconds** | ÷ 3600 → hours |
| Trip fuel | **m³** | × 1000 → litres |
| Angles | **radians** | × 57.2958 → degrees |
| Speed | **m/s** | × 1.94384 → knots |
| Volumes | **m³** | × 1000 → litres |

---

## 14. Do not trust these

| Item | Problem |
|---|---|
| `propulsion.*.fuel.pressure` | Signal K publishes **1000× too high** (3.4 bar reads as 3520 bar). canboat decodes it correctly; the error is inside Signal K. Divide by 1000. |
| `propulsion.*.trip.fuelUsed` | Gateway truncates `127497` to 9 of 15 bytes; the value is a slow counter, not fuel used |
| `propulsion.*.coolantPressure` | Gateway never sends it; appeared as `0` before being cleared |
| `environment.water.temperature` | Sender dead for years, reads −4.7 °C |
| `navigation.speedThroughWater` | Paddle wheel dead, always 0 |
| `tanks.freshWater.0.currentLevel` timestamp | Live value, but stamped `2010-01-01` — breaks anything relying on time |
| `tanks.fuel.1.currentLevel` | 0 % with no capacity — sensor not connected |
| `propulsion.main.fuel.economy` | Derived from total fuel and SOG; meaningless when stationary |

---

## 15. Not present at all

| Item | Why |
|---|---|
| **AIS targets** | No AIS PGNs on the bus, no other vessels in Signal K. AIS is believed to be NMEA 0183 / Garmin Ethernet — see below |
| **Autopilot (heading and track mode)** | Tested in both modes: no `127237`, no `127251`, no proprietary pilot PGNs, no new source address. The pilot is not on this bus |
| **Rudder angle** | `127245` absent; `steering` subtree does not exist in Signal K |
| **Engine load / torque / trim** | Gateway sends `0x7F` ("not available") |
| **Full route** | No N2K PGN carries one |
| **Other AIS / traffic** | — |

### The NMEA 0183 side

Two serial ports are configured and both have **received zero bytes since boot**
(`rx:0` on `ttyS0` and `ttyS1`):

| Provider | Device | Baud | Hint |
|---|---|---|---|
| `nmea0183-rs485-1` | `/dev/rs485-1` → `ttyS0` | 4800 | standard 0183 |
| `nmea0183-rs485-2` | `/dev/rs485-2` → `ttyS1` | **38400** | **the AIS baud rate** — the box was prepared for an AIS feed |

Wiring the autopilot's (or AIS receiver's) 0183 output to these ports would give, automatically:

| Sentence | Gives |
|---|---|
| `$RSA` | `steering.rudderAngle` — the only realistic source of rudder angle |
| `$APB` | XTE and bearing-to-steer |
| `$HDG` / `$HDM` | True/magnetic heading |
| `!AIVDM` | AIS targets → `vessels.*`, also visible in AvNav |
