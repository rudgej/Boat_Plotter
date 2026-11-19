#!/usr/bin/env python3
"""Measure how often Signal K actually receives each wind value.

Subscribes to Signal K's own WebSocket delta stream and timestamps every
arrival, so this measures what the server receives rather than what the wire
carries. Reports the gaps - the irregular ones are what makes a warning light
blink and then pause.
"""
import json
import statistics
import time

import websocket

URL = "ws://localhost:3000/signalk/v1/stream?subscribe=self"
DURATION = 60
WATCH = (
    "environment.wind.",
    "environment.depth.",
    "navigation.position",
)

arrivals = {}
end = time.time() + DURATION

ws = websocket.create_connection(URL, timeout=DURATION + 10)
try:
    while time.time() < end:
        try:
            raw = ws.recv()
        except Exception:
            break
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        for update in msg.get("updates", []):
            for value in update.get("values", []):
                path = value.get("path", "")
                if not path.startswith(WATCH):
                    continue
                if value.get("value") is None:
                    continue
                arrivals.setdefault(path, []).append(time.time())
finally:
    ws.close()

print("\n  measured %d s at the Signal K websocket\n" % DURATION)
print("  %-42s %7s %8s %8s %5s" % ("path", "count", "median", "max", ">1s"))
for path in sorted(arrivals):
    ts = arrivals[path]
    if len(ts) < 2:
        print("  %-42s %7d %8s %8s %5s" % (path, len(ts), "-", "-", "-"))
        continue
    gaps = [ts[i + 1] - ts[i] for i in range(len(ts) - 1)]
    over = sum(1 for g in gaps if g > 1.0)
    print("  %-42s %7d %7.2fs %7.2fs %5d"
          % (path, len(ts), statistics.median(gaps), max(gaps), over))
