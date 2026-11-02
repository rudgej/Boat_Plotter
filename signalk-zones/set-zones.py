#!/usr/bin/env python3
"""
Set Signal K gauge zones (meta.zones) for the boat.

Zones are stored in SI units (Signal K convention):
  temperature: Kelvin (K)   = degC + 273.15
  pressure:    Pascal (Pa)  = bar * 100000
  depth:       metres (m)
  voltage:     volts (V)

Each zone: {"lower": .., "upper": .., "state": "nominal|alert|warn|alarm|emergency"}
"""
import json, sys, urllib.request

BASE = "http://localhost:3000/signalk/v1/api/vessels/self"

# --- zone definitions (converted from user's degC / bar / m / V) ---
TEMP = [  # degC: 0-85.9 nominal, 85.9-92.9 alert, 92.9+ warn (gapless)
    {"lower": 273.15, "upper": 359.05, "state": "nominal"},
    {"lower": 359.05, "upper": 366.05, "state": "alert"},
    {"lower": 366.05, "upper": 473.15, "state": "warn"},
]
OIL_TEMP = [  # degC: 0-100.9 nominal, 100.9-110.9 alert, 110.9+ warn (gapless)
    {"lower": 273.15, "upper": 374.05, "state": "nominal"},
    {"lower": 374.05, "upper": 384.05, "state": "alert"},
    {"lower": 384.05, "upper": 473.15, "state": "warn"},
]
DEPTH = [  # m: 0-2 warn, 2+ nominal (gapless)
    {"lower": 0.0, "upper": 2.0, "state": "warn"},
    {"lower": 2.0, "upper": 1000.0, "state": "nominal"},
]
VOLTS = [  # V: 0-23 warn, 23-24 alert, 24-28.5 nominal, 28.5+ warn (gapless)
    {"lower": 0.0, "upper": 23.0, "state": "warn"},
    {"lower": 23.0, "upper": 24.0, "state": "alert"},
    {"lower": 24.0, "upper": 28.5, "state": "nominal"},
    {"lower": 28.5, "upper": 40.0, "state": "warn"},
]
OIL_PRESS = [  # bar: 0-1 warn, 1-2 alert, 2+ nominal (gapless)
    {"lower": 0.0, "upper": 100000.0, "state": "warn"},
    {"lower": 100000.0, "upper": 200000.0, "state": "alert"},
    {"lower": 200000.0, "upper": 2000000.0, "state": "nominal"},
]
BOOST = [  # bar: 0-5 nominal, 5+ warn (gapless)
    {"lower": 0.0, "upper": 500000.0, "state": "nominal"},
    {"lower": 500000.0, "upper": 2000000.0, "state": "warn"},
]

TARGETS = [
    ("propulsion/port/temperature", TEMP),
    ("propulsion/starboard/temperature", TEMP),
    ("propulsion/port/oilTemperature", OIL_TEMP),
    ("propulsion/starboard/oilTemperature", OIL_TEMP),
    ("propulsion/port/oilPressure", OIL_PRESS),
    ("propulsion/starboard/oilPressure", OIL_PRESS),
    ("propulsion/port/boostPressure", BOOST),
    ("propulsion/starboard/boostPressure", BOOST),
    ("environment/depth/belowTransducer", DEPTH),
    ("electrical/batteries/0/voltage", VOLTS),
]


def put_zones(path, zones):
    url = f"{BASE}/{path}/meta/zones"
    data = json.dumps({"value": zones}).encode()
    req = urllib.request.Request(
        url, data=data, method="PUT",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


def main():
    ok = 0
    for path, zones in TARGETS:
        try:
            status = put_zones(path, zones)
            print(f"  {status}  {path}")
            ok += 1
        except Exception as e:
            print(f"  FAIL  {path}: {e}")
    print(f"\n{ok}/{len(TARGETS)} zones applied")


if __name__ == "__main__":
    main()
