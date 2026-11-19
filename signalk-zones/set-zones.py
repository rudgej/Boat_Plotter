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
import json, os, sys, urllib.request

ORIGIN = os.environ.get("SIGNALK_URL", "http://localhost:3000").rstrip("/")
BASE = f"{ORIGIN}/signalk/v1/api/vessels/self"

# Signal K security is enabled on this boat, so every write needs a bearer
# token. Supply SIGNALK_TOKEN directly, or SIGNALK_USER + SIGNALK_PASSWORD and
# the script will log in for you. /etc/signalk-automation.env already holds the
# same credentials the systemd units use.
_TOKEN = None


def token():
    global _TOKEN
    if _TOKEN is not None:
        return _TOKEN
    env_token = os.environ.get("SIGNALK_TOKEN")
    if env_token:
        _TOKEN = env_token
        return _TOKEN
    user = os.environ.get("SIGNALK_USER")
    password = os.environ.get("SIGNALK_PASSWORD")
    if not (user and password):
        _TOKEN = ""
        return _TOKEN
    body = json.dumps({"username": user, "password": password}).encode()
    req = urllib.request.Request(
        f"{ORIGIN}/signalk/v1/auth/login", data=body, method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        _TOKEN = json.load(r)["token"]
    return _TOKEN

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
    headers = {"Content-Type": "application/json"}
    tok = token()
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(url, data=data, method="PUT", headers=headers)
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


def read_zones(path):
    """Read back what the server actually holds for this path."""
    url = f"{BASE}/{path}"
    headers = {}
    tok = token()
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.load(r).get("meta", {}).get("zones")
    except Exception:
        return None


def main():
    ok = 0
    if not token():
        print("  no SIGNALK_TOKEN / SIGNALK_USER+PASSWORD - writes will 401")
    for path, zones in TARGETS:
        try:
            status = put_zones(path, zones)
            back = read_zones(path)
            match = "readback OK" if back == zones else "READBACK MISMATCH"
            print(f"  {status}  {path}  {match}")
            if back == zones:
                ok += 1
        except Exception as e:
            print(f"  FAIL  {path}: {e}")
    print(f"\n{ok}/{len(TARGETS)} zones applied and verified")


if __name__ == "__main__":
    main()
