#!/usr/bin/env python3
"""
holding-tank-dump.py - holding tank discharge automation for Bossy.

Rules:
  1. Whenever the dump switch is ON it is automatically turned OFF after
     DUMP_SECONDS, unless it is turned off earlier (manually or by the
     automation below).
  2. It is automatically turned ON when:
       a. SOG has been > THRESHOLD_KNOTS for at least QUALIFY_SECONDS, and
       b. at least COOLDOWN_SECONDS have passed since the last auto dump.
     It is turned OFF at once if SOG drops to <= THRESHOLD_KNOTS.

Status published to Signal K (under the "self" context, so KIP sees
self.holdingTank.*):
  holdingTank.dumpTimeRemaining     number, seconds remaining (0 when idle)
  holdingTank.dumpTimeRemainingText string, "m:ss" ("" when idle)
  holdingTank.dumpAutoActive        string, "ACTIVE" while the auto dump runs ("" idle)
  holdingTank.lastAutoDump          timestamp of the last auto dump

Tuning via environment (defaults shown):
  SIGNALK_URL, SIGNALK_USER, SIGNALK_PASSWORD
  THRESHOLD_KNOTS=7.0, QUALIFY_SECONDS=300, DUMP_SECONDS=300,
  COOLDOWN_SECONDS=86400, POLL_SECONDS=1.0, STATE_FILE
  DRY_RUN=1 -> log PUTs instead of sending them (safe testing).
"""

import json
import math
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

BASE = os.environ.get("SIGNALK_URL", "http://localhost:3000")
USER = os.environ.get("SIGNALK_USER", "boat")
PASSWORD = os.environ.get("SIGNALK_PASSWORD", "")

SOG_PATH = "navigation/speedOverGround"
SWITCH_PATH = "electrical/switches/shellyplus1-e465b842fb34/state"
REMAIN_PATH = "holdingTank/dumpTimeRemaining"
REMAIN_TEXT_PATH = "holdingTank/dumpTimeRemainingText"
AUTO_PATH = "holdingTank/dumpAutoActive"
LAST_PATH = "holdingTank/lastAutoDump"

THRESHOLD_KNOTS = float(os.environ.get("THRESHOLD_KNOTS", "7.0"))
QUALIFY_SECONDS = float(os.environ.get("QUALIFY_SECONDS", "300"))
DUMP_SECONDS = float(os.environ.get("DUMP_SECONDS", "300"))
COOLDOWN_SECONDS = float(os.environ.get("COOLDOWN_SECONDS", "86400"))
POLL_SECONDS = float(os.environ.get("POLL_SECONDS", "1.0"))
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"

KNOTS_TO_MS = 0.514444
THRESHOLD_MS = THRESHOLD_KNOTS * KNOTS_TO_MS

STATE_FILE = os.environ.get("STATE_FILE", "/home/pi/.holding-tank-dump/state.json")

token = None
mode = None            # None | "MANUAL" | "AUTO"
on_since = None        # epoch seconds when the current ON period began
qualify_start = None   # epoch seconds when SOG first exceeded the threshold
last_auto = None       # epoch seconds of the last automated dump
published = {}         # last published values (avoid redundant PUTs)

# Command bookkeeping so stale reads don't misclassify our own commands.
last_commanded = None
last_command_time = 0.0
COMMAND_GRACE = 6.0    # seconds to trust our own command over a lagging read


def log(msg):
    print("%s %s" % (datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), msg), flush=True)


def api(method, path, body=None, auth=False):
    req = urllib.request.Request(
        BASE + "/signalk/v1/api/vessels/self/" + path, data=body, method=method
    )
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
    except Exception as e:
        log("read %s failed: %s" % (path, e))
        return None


def read_sog():
    obj = read_path(SOG_PATH)
    if obj and obj.get("value") is not None:
        try:
            return float(obj["value"])
        except (TypeError, ValueError):
            return None
    return None


def read_switch():
    """Return (bool, epoch_seconds) for the switch state."""
    obj = read_path(SWITCH_PATH)
    if not obj or "value" not in obj:
        return None, None
    on = bool(obj["value"])
    ts = None
    t = obj.get("timestamp")
    if t:
        try:
            ts = datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
        except ValueError:
            ts = None
    return on, ts


def put_path(path, value):
    """PUT a value to Signal K. Returns True on success (or dry run)."""
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


def publish(path, value):
    if published.get(path) == value:
        return
    if put_path(path, value):
        published[path] = value


def command_switch(on):
    global last_commanded, last_command_time
    put_path(SWITCH_PATH, on)
    last_commanded = on
    last_command_time = time.time()


def load_state():
    global last_auto
    try:
        with open(STATE_FILE) as f:
            last_auto = json.load(f).get("last_auto_dump")
        log("state loaded: last_auto=%s" % last_auto)
    except Exception:
        last_auto = None


def save_state():
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"last_auto_dump": last_auto}, f)
    os.replace(tmp, STATE_FILE)


def main():
    global mode, on_since, qualify_start, last_auto

    load_state()
    for _ in range(10):
        try:
            login()
            break
        except Exception as e:
            log("login failed (%s), retrying" % e)
            time.sleep(5)

    log("starting: threshold=%.1f kn qualify=%ds dump=%ds cooldown=%ds dry_run=%s" %
        (THRESHOLD_KNOTS, QUALIFY_SECONDS, DUMP_SECONDS, COOLDOWN_SECONDS, DRY_RUN))

    while True:
        try:
            now = time.time()
            sog = read_sog()
            on_read, sw_ts = read_switch()

            # Trust our own command over a lagging read-back for a short grace.
            if last_commanded is not None and now - last_command_time < COMMAND_GRACE:
                on = last_commanded
            else:
                on = on_read

            if on:
                if mode is None:
                    mode = "MANUAL"
                    on_since = sw_ts if sw_ts else now
                    log("switch ON (manual), auto-off in %ds" % DUMP_SECONDS)

                if mode == "AUTO" and (sog is None or sog <= THRESHOLD_MS):
                    kn = (sog / KNOTS_TO_MS) if sog is not None else 0.0
                    log("SOG %.2f kn <= %.1f kn, turning off (auto)" % (kn, THRESHOLD_KNOTS))
                    command_switch(False)
                    mode = None
                    on_since = None

                elif on_since and now - on_since >= DUMP_SECONDS:
                    log("dump timer elapsed, turning off")
                    command_switch(False)
                    mode = None
                    on_since = None

            else:
                mode = None
                on_since = None

            # Qualification for an auto dump (only while the switch is off).
            if not on:
                if sog is not None and sog > THRESHOLD_MS:
                    if qualify_start is None:
                        qualify_start = now
                    elif now - qualify_start >= QUALIFY_SECONDS:
                        if last_auto is None or now - last_auto >= COOLDOWN_SECONDS:
                            log("auto dump: SOG>%.1f kn for %ds and cooldown passed, turning on" %
                                (THRESHOLD_KNOTS, QUALIFY_SECONDS))
                            command_switch(True)
                            mode = "AUTO"
                            on_since = now
                            last_auto = now
                            save_state()
                            qualify_start = None
                else:
                    qualify_start = None

            # Publish status.
            if mode and on_since:
                remaining = max(0, math.ceil(DUMP_SECONDS - (now - on_since)))
                text = "%d:%02d" % (remaining // 60, remaining % 60)
            else:
                remaining = 0
                text = ""

            publish(REMAIN_PATH, remaining)
            publish(REMAIN_TEXT_PATH, text)
            publish(AUTO_PATH, "ACTIVE" if mode == "AUTO" else "")
            if last_auto:
                publish(LAST_PATH,
                        datetime.fromtimestamp(last_auto, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))

        except Exception as e:
            log("loop error: %s" % e)

        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
