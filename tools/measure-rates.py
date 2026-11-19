#!/usr/bin/env python3
"""Measure the real update interval of Signal K paths.

Polls the REST API and records every change of timestamp, then reports the
gaps. Used to set stale-watchdog timeouts from measurement rather than guesswork.
"""
import json
import sys
import time
import urllib.request

BASE = "http://localhost:3000/signalk/v1/api/vessels/self"
PATHS = [
    "environment/depth/belowTransducer",
    "environment/wind/speedApparent",
    "navigation/position",
    "navigation/speedOverGround",
    "navigation/headingTrue",
]
DURATION = 30
POLL = 0.25


def stamp(path):
    try:
        with urllib.request.urlopen("%s/%s" % (BASE, path), timeout=5) as r:
            return json.load(r).get("timestamp")
    except Exception:
        return None


last = {p: stamp(p) for p in PATHS}
gaps = {p: [] for p in PATHS}
seen_at = {p: time.time() for p in PATHS}
start = time.time()

while time.time() - start < DURATION:
    time.sleep(POLL)
    for p in PATHS:
        ts = stamp(p)
        if ts and ts != last[p]:
            now = time.time()
            gaps[p].append(now - seen_at[p])
            seen_at[p] = now
            last[p] = ts

print("\n  measured over %d s (poll %.2f s)\n" % (DURATION, POLL))
print("  %-38s %6s %8s %8s" % ("path", "updates", "median", "max"))
for p in PATHS:
    g = gaps[p]
    if not g:
        print("  %-38s %6d %8s %8s" % (p, 0, "-", "-"))
        continue
    g_sorted = sorted(g)
    median = g_sorted[len(g_sorted) // 2]
    print("  %-38s %6d %7.2fs %7.2fs" % (p, len(g), median, max(g)))
