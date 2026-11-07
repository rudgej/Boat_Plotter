#!/usr/bin/env python3
"""Set the system timezone from the boat's GPS position.

Runs as root via a systemd timer. timezonefinder does the lat/lon -> IANA
timezone lookup offline (no API key needed); the Pi's NTP keeps UTC correct.
After changing the timezone, cockpit-light.service is restarted so it recomputes
sunset / 23:00 in the new local time.
"""

import json
import subprocess
import urllib.request
from timezonefinder import TimezoneFinder

BASE = "http://localhost:3000"
tf = TimezoneFinder()


def get_position():
    try:
        with urllib.request.urlopen(
            BASE + "/signalk/v1/api/vessels/self/navigation/position", timeout=8
        ) as r:
            v = json.load(r)["value"]
            return float(v["latitude"]), float(v["longitude"])
    except Exception as e:
        print("position read failed:", e)
        return None


def current_tz():
    try:
        with open("/etc/timezone") as f:
            return f.read().strip()
    except Exception:
        return ""


def main():
    pos = get_position()
    if not pos:
        return
    lat, lon = pos
    tz = tf.timezone_at(lat=lat, lng=lon)
    if not tz:
        print("no timezone found for %.3f,%.3f" % (lat, lon))
        return
    cur = current_tz()
    if tz == cur:
        return
    print("timezone change: %s -> %s (pos %.3f,%.3f)" % (cur, tz, lat, lon), flush=True)
    subprocess.run(["timedatectl", "set-timezone", tz], check=True)
    subprocess.run(["systemctl", "restart", "cockpit-light.service"])


if __name__ == "__main__":
    main()
