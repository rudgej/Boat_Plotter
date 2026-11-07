#!/usr/bin/env python3
"""
cockpit-light.py - cockpit lighting automation.

Turns the cockpit light ON at sunset (computed from the boat's GPS position)
and OFF at 23:00 local time. If you switch it off yourself during the evening,
it stays off for the rest of that evening (won't be switched back on until the
next dusk).

Env (defaults shown):
  SIGNALK_URL, SIGNALK_USER, SIGNALK_PASSWORD
  SWITCH_PATH = electrical/switches/shellyplus1pm-441793d69434/state
  POSITION_PATH = navigation/position
  POLL_SECONDS = 30
  STATE_FILE = /home/pi/.cockpit-light/state.json
  DRY_RUN = 1 -> log commands instead of sending them
"""

import json
import math
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone, timedelta

BASE = os.environ.get("SIGNALK_URL", "http://localhost:3000")
USER = os.environ.get("SIGNALK_USER", "boat")
PASSWORD = os.environ.get("SIGNALK_PASSWORD", "")

SWITCH_PATH = os.environ.get(
    "SWITCH_PATH", "electrical/switches/shellyplus1pm-441793d69434/state")
POSITION_PATH = os.environ.get("POSITION_PATH", "navigation/position")
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "30"))
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"
STATE_FILE = os.environ.get("STATE_FILE", "/home/pi/.cockpit-light/state.json")

ZENITH_DEG = 90.833  # sunset (upper limb touches horizon)

token = None
last_commanded = None   # True/False/None: last value we commanded
prev_on = None          # last observed switch state (for falling-edge detection)
state = {"suppress_until": 0.0, "on_date": "", "lat": None, "lon": None}


def log(msg):
    print("%s %s" % (datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), msg), flush=True)


def api(method, path, body=None, auth=False):
    req = urllib.request.Request(
        BASE + "/signalk/v1/api/vessels/self/" + path, data=body, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    if auth and token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=8) as resp:
        return json.loads(resp.read().decode())


def login():
    global token
    body = json.dumps({"username": USER, "password": PASSWORD}).encode()
    req = urllib.request.Request(BASE + "/signalk/v1/auth/login", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=8) as resp:
        token = json.loads(resp.read().decode())["token"]
    log("signed in to Signal K")


def read_path(path):
    try:
        return api("GET", path)
    except Exception:
        return None


def read_switch():
    obj = read_path(SWITCH_PATH)
    if not obj or "value" not in obj:
        return None
    return bool(obj["value"])


def read_position():
    obj = read_path(POSITION_PATH)
    if obj and obj.get("value") is not None:
        v = obj["value"]
        lat = v.get("latitude")
        lon = v.get("longitude")
        if lat is not None and lon is not None:
            try:
                return float(lat), float(lon)
            except (TypeError, ValueError):
                return None
    return None


def put_path(path, value):
    global token
    if DRY_RUN:
        log("DRY-RUN: would PUT %s = %s" % (path, value))
        return True
    body = json.dumps({"value": value}).encode()
    for attempt in range(2):
        try:
            api("PUT", path, body=body, auth=True)
            return True
        except urllib.error.HTTPError as e:
            if e.code == 401 and attempt == 0:
                try:
                    login()
                except Exception:
                    pass
                continue
            log("PUT %s failed: %s" % (path, e))
            return False
        except Exception as e:
            log("PUT %s failed: %s" % (path, e))
            return False
    return False


def command_switch(on):
    global last_commanded
    put_path(SWITCH_PATH, on)
    last_commanded = on


def load_state():
    global state
    try:
        with open(STATE_FILE) as f:
            state.update(json.load(f))
    except Exception:
        pass


def save_state():
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)


def sunset_utc(lat, lon, day):
    """Approximate sunset time (UTC) for a lat/lon and local calendar date."""
    n = day.timetuple().tm_yday
    decl = -23.44 * math.cos(math.radians(360.0 / 365.0 * (n + 10)))
    b = math.radians(360.0 / 365.0 * (n - 81))
    eot = 9.87 * math.sin(2 * b) - 7.53 * math.cos(b) - 1.5 * math.sin(b)  # minutes
    cos_ha = -math.tan(math.radians(lat)) * math.tan(math.radians(decl))
    cos_ha = max(-1.0, min(1.0, cos_ha))
    ha = math.degrees(math.acos(cos_ha))
    minutes = 720.0 - 4.0 * lon - eot + 4.0 * ha
    return datetime(day.year, day.month, day.day, tzinfo=timezone.utc) + timedelta(minutes=minutes)


def local_23_utc():
    """Epoch seconds of 23:00 today in the system's local timezone."""
    now_local = datetime.now().astimezone()
    t = now_local.replace(hour=23, minute=0, second=0, microsecond=0)
    return t.timestamp()


def main():
    global last_commanded, prev_on

    load_state()
    for _ in range(10):
        try:
            login()
            break
        except Exception as e:
            log("login failed (%s), retrying" % e)
            time.sleep(5)

    log("starting: switch=%s dry_run=%s" % (SWITCH_PATH, DRY_RUN))

    while True:
        try:
            now = time.time()
            today = datetime.now().astimezone().date()
            today_str = today.isoformat()

            pos = read_position()
            if pos and (pos[0] != state.get("lat") or pos[1] != state.get("lon")):
                state["lat"], state["lon"] = pos
                save_state()

            lat, lon = state.get("lat"), state.get("lon")
            on = read_switch()

            sunset = sunset_utc(lat, lon, today).timestamp() if lat is not None and lon is not None else None
            t23 = local_23_utc()

            if sunset is not None:
                in_window = sunset <= now < t23
            else:
                in_window = False

            # Manual-off detection: falling edge we didn't cause, after our daily auto-on.
            if (state.get("on_date") == today_str and prev_on is True
                    and on is False and last_commanded is not False):
                if state.get("suppress_until", 0.0) < t23:
                    state["suppress_until"] = t23
                    save_state()
                    log("manual off detected - suppressing auto-on until 23:00 local")

            # Auto-on at dusk (once per day, unless suppressed).
            if (in_window and on is False
                    and now >= state.get("suppress_until", 0.0)
                    and state.get("on_date") != today_str):
                log("sunset reached - turning cockpit light ON")
                command_switch(True)
                state["on_date"] = today_str
                save_state()

            # Auto-off at 23:00 local.
            if now >= t23:
                if on is True:
                    log("23:00 local - turning cockpit light OFF")
                    command_switch(False)
                if state.get("suppress_until", 0.0):
                    state["suppress_until"] = 0.0
                    save_state()

            prev_on = on

        except Exception as e:
            log("loop error: %s" % e)

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
