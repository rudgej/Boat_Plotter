#!/usr/bin/env python3
"""Confirm whether Signal K has a valid GPS position / satellites right now."""
import json
import time
import urllib.request

BASE = "http://localhost:3000/signalk/v1/api/vessels/self"


def get(path):
    try:
        with urllib.request.urlopen(BASE + path, timeout=8) as r:
            return json.load(r)
    except Exception as e:  # noqa: BLE001
        return {"_error": str(e)}


def show(label, path):
    d = get(path)
    if "_error" in d:
        print("  %-24s <%s>" % (label, d["_error"]))
        return
    val = d.get("value", "<none>")
    print("  %-24s value=%s" % (label, val))
    print("  %-24s ts=%s src=%s" % ("", d.get("timestamp"), d.get("$source")))


print("=== position / GNSS ===")
show("navigation.position", "/navigation/position")
show("gnss.satellites", "/navigation/gnss/satellites")
show("gnss.antennaAltitude", "/navigation/gnss/antennaAltitude")

print("\n=== overnight: is the position timestamp stale? ===")
p = get("/navigation/position")
ts = p.get("timestamp")
if ts:
    try:
        from datetime import datetime, timezone
        t = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=timezone.utc)
        age = (datetime.now(timezone.utc) - t).total_seconds()
        print("  age = %.0f seconds (%.1f hours)" % (age, age / 3600))
        print("  -> %s" % ("LIVE" if age < 60 else "STALE / not updating"))
    except Exception as e:  # noqa: BLE001
        print("  could not parse timestamp:", e)

print("\n=== navigation sources present ===")
nav = get("/navigation")
for k, v in sorted(nav.items()):
    if isinstance(v, dict) and "value" in v:
        print("  %-24s %s (%s)" % (k, v.get("value"), v.get("$source")))
