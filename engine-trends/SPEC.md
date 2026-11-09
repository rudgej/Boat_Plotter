# Engine Trend Monitoring — Final Specification (Boat_Plotter)

Status: **locked for implementation** · Target: Signal K on the CWWK N100 box
Data source: **NMEA 2000 via CANable (can0)** — all six parameters confirmed present, including oil temperature.

---

## 1. Purpose

A monitoring system (not an alarm system) for two engines, **Port** and **Starboard**, that
detects *change* in engine behaviour before it becomes a problem, using learned baselines and
historical comparison. Output is exactly one of two states:

- `NORMAL`
- `REVIEW — <short factual message>`

Messages state **what changed**, never a diagnosis. Examples:

- `REVIEW — Coolant temperature has increased from 80 °C to 85 °C in the last 10 minutes.`
- `REVIEW — Coolant temperature is at a new recorded high for this RPM band.`
- `REVIEW — Port coolant temperature is rising while Starboard remains stable.`

The engine's own alarm systems remain separate and authoritative.

---

## 2. Data path (what we actually have)

```
Engine sensors → NMEA 2000 backbone → CANable (gs_usb) → can0 @ 250 kbit/s
   → Signal K (canboatjs N2K provider) → propulsion.* paths → engine-trends daemon
```

Two engines arrive as `propulsion.<instance>.*`, keyed by the N2K **engine instance** (PGN 60928).
The instance→Port/Starboard mapping is **configuration**, verified on the boat (defaults: instance 0 = Port, 1 = Starboard).

### Parameters and Signal K units

Signal K stores SI; all thresholds and messages must convert for humans.

| Parameter | Signal K path (candidate) | Signal K unit | Display unit |
|---|---|---|---|
| RPM | `propulsion.<id>.revolutions` | Hz | rpm (`× 60`) |
| Coolant temp | `propulsion.<id>.coolantTemperature` | K | °C (`− 273.15`) |
| Oil temp | `propulsion.<id>.oilTemperature` | K | °C |
| Oil pressure | `propulsion.<id>.oilPressure` | Pa | bar (`÷ 1e5`) |
| Turbo boost | `propulsion.<id>.boostPressure` | Pa | bar |
| Fuel flow | `propulsion.<id>.fuel.rate` | m³/s | l/h (`× 3.6e6`) |

> The daemon **discovers the live paths and units from the Signal K `self` tree at startup** and
> maps them through config; the candidates above are the defaults to confirm on first boot. No path
> is hard-coded, and a parameter that never arrives is skipped cleanly (its baselines stay
> `NOT_ESTABLISHED`).

Missing, invalid, or stale readings are always excluded.

---

## 3. Sampling

- Subscribe to the Signal K WebSocket stream (`/signalk/v1/stream?subscribe=self`); buffer the
  latest value **and its source timestamp** per path.
- Evaluate every **15 s** on a timer.
- A reading is **stale** if its last update is older than 30 s — exclude it.
- Individual 15-s readings are **not** persisted.

---

## 4. RPM bands

| Band | RPM |
|---|---|
| Idle / manoeuvring | < 1 000 |
| Band 1 | 1 000 – 1 400 |
| Band 2 | 1 400 – 1 800 |
| Band 3 | 1 800 – 2 100 |
| Band 4 | 2 100 – 2 350 |

- Idle/manoeuvring is **never** used for baselines or trends.
- All comparisons happen **within the same band**.

---

## 5. Qualifying data & stabilisation

A sample qualifies for baseline/trend use only when **all** hold:

1. Coolant temp ≥ **75 °C**.
2. RPM in one of the four operating bands.
3. RPM has moved ≤ **100 rpm** over the preceding 30 s.
4. The parameter in question has passed its own stabilisation test.

A qualifying period must last ≥ **5 continuous minutes**; shorter periods are discarded.

### Temperature stabilisation (independent per parameter)

- Linear-regression slope over a rolling **10-minute** window → predicted change over that window.
- A parameter is "stabilised" only when that predicted change is within its configured tolerance for
  **two consecutive 10-minute checks**.
- Tolerances are independently configurable for coolant and oil temperature.
- Trip anomaly detection for a parameter is disabled until that parameter stabilises (warm-up must
  not generate REVIEWs).

---

## 6. Baselines

48 independent baselines = 2 engines × 4 bands × 6 parameters.

- Each baseline requires ≥ **30 min** of qualifying, stabilised data (accumulating across sessions;
  each contributing period ≥ 5 min).
- States: `NOT_ESTABLISHED` → `ESTABLISHING` → `ESTABLISHED`.

### Robust validation (before `ESTABLISHED`)

- Statistics: count, median, mean, SD, min, max, 25th/75th percentile, MAD.
- `robust_SD = 1.4826 × MAD`; `robust_z = (x − median) / robust_SD`.
- Exclude samples with `|robust_z| > 3`. If MAD = 0, fall back to SD or a configurable resolution floor (never divide by zero).
- Pass only when: ≥ 95 % of samples within 3 robust SDs of the median; no excessive residual
  variation; no significant intra-session temperature trend (session regression slope within the
  configured tolerance); ≥ 30 min of valid data remain after exclusions.
- On failure: keep the valid session summaries, keep accumulating, do **not** establish.

### Dual baseline

| Baseline | Behaviour |
|---|---|
| **Original reference** | From the first 30 min of validated data; **never changes automatically**; reset only manually. Permanent reference for long-term deterioration. |
| **Operational** | Starts equal to reference; evolves using accepted session statistics (robust); never incorporates data under an active REVIEW. Represents *current* normal. |

Long-term trend analysis always uses the **complete** session history, not just the operational baseline.

---

## 7. Sessions & storage

A **session** starts when RPM ≥ 1 000 **and** coolant ≥ 75 °C. Three outings in one day = three sessions.
An in-progress session **survives a reboot** (resumed, not restarted).

### Session record (stored per engine × band × parameter)

Session ID, datetime, engine, band, parameter, qualifying duration, sample count, median, mean, SD,
min, max, 25th/75th percentile, robust SD. **Session medians** are the unit of long-term comparison.
Individual 15-s samples are never retained.

### Database — the decision

- **SQLite**, embedded in the daemon (`/home/pi/.engine-trends/engine-trends.db`). No separate DB server.
- `journal_mode=WAL`, `synchronous=FULL` — durable against abrupt power-off (the key being turned off).
- **Write-through:** a REVIEW event is committed to SQLite the instant it is raised, before anything else.
- Retained indefinitely: baselines, session records, and REVIEW events. Never pruned.

### REVIEW events

Every REVIEW is durably logged and carries: id, datetime, engine, band, parameter, message, and the
statistics that triggered it. **No acknowledgement state** — the requirement is simply that nothing
is ever lost. (Simplification from earlier draft: acknowledgement is out of scope.)

---

## 8. Long-term trend detection

All comparisons use session medians in chronological order, same engine/band/parameter.

**A. Persistent deviation (vs operational baseline)**
`Z = (session_median − op_baseline_median) / op_baseline_robust_SD`. REVIEW when `|Z| ≥ 3` **and**
the deviation repeats in **two consecutive qualifying sessions** in the same band.

**B. Gradual deterioration (full history)**
Theil-Sen slope + Mann-Kendall significance. REVIEW when: ≥ **20** session records; Mann-Kendall
`p < 0.05`; latest session median ≥ **2 robust SDs** from the original reference baseline; trend
direction consistent with that deviation.

**C. Historical high / low**
A session median that exceeds **all** previous session medians (in the relevant direction) is a new
high/low. REVIEW only when ≥ **20** previous sessions exist.

**D. Current-trip anomaly (independent of the above)**
Rolling 5/10/20-minute windows on this trip's 15-s samples: current value, value at window start,
absolute change, regression slope. REVIEW when a sustained change exceeds the parameter-specific
threshold and is present for ≥ **2 consecutive 15-s evaluations**. Per-parameter thresholds, in
display units.

---

## 9. Output & UI (KIP-first)

**What KIP can do:** KIP is a *current-state* dashboard — it renders the live value of Signal K
paths (gauges, numeric, text, date/time). It **cannot scroll a history list** — there is no
time-series or log-list widget in KIP.

So:

| Surface | What it shows |
|---|---|
| **KIP** | Live status per engine: `self.engineHealth.port.status` (`NORMAL`/`REVIEW`) and `self.engineHealth.port.message` (the latest factual message). One widget pair per engine. |
| **Signal K notifications** | Each REVIEW also raises `notifications.engineHealth.<engine>`, visible in Signal K's own notification UI. |
| **History** | SQLite (source of truth). Viewing history is *not* in KIP — read it from the DB, or via a tiny read-only page served by the daemon if desired (deferred; not required for v1). |

The guarantee that matters: a REVIEW is written to SQLite and raised as a Signal K notification
**immediately**, so turning the key off never loses it.

---

## 10. Configuration (env)

`/etc/signalk-automation.env` (same file as the other daemons), all values with defaults:

- `ENGINE_INSTANCE_PORT=0`, `ENGINE_INSTANCE_STARBOARD=1`
- Signal K URL (`http://localhost:3000`)
- `COOLANT_MIN_C=75`, `RPM_STABLE_WINDOW_S=30`, `RPM_STABLE_MAX_DRIFT=100`
- `MIN_QUALIFY_MIN=5`, `BASELINE_MINUTES=30`
- `COOLANT_STAB_TOL_C`, `OIL_STAB_TOL_C` (independent)
- Per-parameter trip-anomaly thresholds (in display units)
- `Z_DEVIATION=3.0`, `Z_CONSECUTIVE=2`, `TREND_MIN_SESSIONS=20`, `TREND_REF_SD=2.0`
- `NEW_RECORD_MIN_SESSIONS=20`

---

## 11. Deployment (matches existing daemon convention)

| File | Location |
|---|---|
| Source | `engine-trends/engine-trends.py` → deployed to `/usr/local/bin/engine-trends.py` |
| systemd unit | `engine-trends/engine-trends.service` → `/etc/systemd/system/` |
| Database | `/home/pi/.engine-trends/engine-trends.db` (created at first run) |
| Config | `/etc/signalk-automation.env` |
| SPEC | `engine-trends/SPEC.md` (this file) |

Dependencies: Python 3, `numpy`, `scipy` (Theil-Sen, Mann-Kendall), `websocket-client` (or `aiohttp`).
Runs as a systemd service alongside `holding-tank-dump` and `cockpit-light`.
