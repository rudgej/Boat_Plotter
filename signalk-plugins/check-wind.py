#!/usr/bin/env python3
"""Check live wind data in Signal K: values, sources, timestamps, and whether they change."""
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


def flat(d, prefix=""):
    out = {}
    if isinstance(d, dict):
        if "value" in d and not isinstance(d["value"], dict):
            out[prefix] = (d.get("value"), d.get("timestamp"), d.get("$source"))
        else:
            for k, v in d.items():
                if isinstance(v, dict):
                    out.update(flat(v, prefix + ("." if prefix else "") + k))
    return out


def sample():
    return flat(get("/environment/wind"))


a = sample()
print("=== environment.wind ===")
if not a:
    print("  NO WIND DATA AT ALL")
for k, (v, ts, src) in sorted(a.items()):
    print("  %-28s %-12s  ts=%s  src=%s" % (k, v, ts, src))

t0 = time.time()
time.sleep(6)
b = sample()
print("\n=== after %.0fs (did it change?) ===" % (time.time() - t0))
for k in sorted(b):
    old = a.get(k, (None,))[0]
    new = b[k][0]
    flag = "CHANGED" if old != new else "same"
    print("  %-28s %s -> %s   %s" % (k, old, new, flag))

print("\n=== other environment keys ===")
d = get("/environment")
for k, v in sorted(d.items()):
    if isinstance(v, dict):
        print("  %s: %s" % (k, list(v.keys())[:6]))
