#!/usr/bin/env python3
"""Sample propulsion twice, ~30 s apart, and report rates + qualification forecast."""
import json
import time
import urllib.request

SK = "http://localhost:3000/signalk/v1/api/vessels/self/propulsion"


def dig(tree, *parts):
    cur = tree
    for p in parts:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(p, {})
    return cur.get("value") if isinstance(cur, dict) else None


def sample():
    with urllib.request.urlopen(SK, timeout=10) as r:
        d = json.load(r)
    out = {}
    for eng in ("port", "starboard"):
        v = d.get(eng, {})
        rpm = dig(v, "revolutions")
        cool = dig(v, "temperature")
        out[eng] = dict(
            rpm=rpm * 60 if rpm is not None else None,
            coolant=cool - 273.15 if cool is not None else None,
        )
    return out


a = sample()
t0 = time.time()
time.sleep(30)
b = sample()
dt = time.time() - t0

print("=" * 66)
for eng in a:
    ra, rb = a[eng]["rpm"], b[eng]["rpm"]
    ca, cb = a[eng]["coolant"], b[eng]["coolant"]
    print("%-9s rpm %s -> %s   coolant %.2f -> %.2f °C  (%.1fs)" % (eng, ra, rb, ca, cb, dt))
    if ca is not None and cb is not None and dt > 0:
        rate = (cb - ca) / dt * 60.0
        print("           coolant rate %+.3f °C/min" % rate)
        if rate > 0.01:
            need = 75.0 - cb
            print("           reaches 75 °C in ~%.0f min (if the rate holds and it does not plateau)" % (need / rate))
        else:
            print("           coolant is NOT rising")
    print("           rpm >= 1000 needed for a trip: %s" % ("YES" if (rb or 0) >= 1000 else "NO"))
print("=" * 66)
