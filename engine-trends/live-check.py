#!/usr/bin/env python3
"""Live check of the engine-trends pipeline. Run on the box as pi."""
import json
import sqlite3
import subprocess
import urllib.request

SK = "http://localhost:3000/signalk/v1/api/vessels/self/propulsion"
DB = "/home/pi/.engine-trends/engine-trends.db"


def dig(tree, *parts):
    cur = tree
    for p in parts:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(p, {})
    return cur.get("value") if isinstance(cur, dict) else None


def main():
    print("=== live propulsion (display units) ===")
    try:
        with urllib.request.urlopen(SK, timeout=10) as r:
            d = json.load(r)
    except Exception as e:  # noqa: BLE001
        print("  could not read Signal K:", e)
        d = {}

    for eng in ("port", "starboard"):
        v = d.get(eng, {})
        rpm = dig(v, "revolutions")
        cool = dig(v, "temperature")
        oilt = dig(v, "oilTemperature")
        oilp = dig(v, "oilPressure")
        boost = dig(v, "boostPressure")
        fuel = dig(v, "fuel", "rate")
        print("  %-9s rpm=%-7s coolant=%-7s oilT=%-7s oilP=%-6s boost=%-6s fuel=%s" % (
            eng,
            "%.0f" % (rpm * 60) if rpm is not None else "-",
            "%.1f" % (cool - 273.15) if cool is not None else "-",
            "%.1f" % (oilt - 273.15) if oilt is not None else "-",
            "%.2f" % (oilp / 1e5) if oilp is not None else "-",
            "%.2f" % (boost / 1e5) if boost is not None else "-",
            "%.1f" % (fuel * 3.6e6) if fuel is not None else "-",
        ))

    print("=== daemon log (last 12) ===")
    out = subprocess.run(
        ["sudo", "-n", "journalctl", "-u", "engine-trends", "-n", "12",
         "--no-pager", "--output=cat"],
        capture_output=True, text=True).stdout.strip()
    print("\n".join("  " + l for l in out.splitlines()[-12:]) or "  (no entries)")

    print("=== database ===")
    c = sqlite3.connect(DB)
    for q, label in [
        ("SELECT COUNT(*) FROM trips", "trips"),
        ("SELECT COUNT(*) FROM trips WHERE active=1", "open trips"),
        ("SELECT COUNT(*) FROM session_samples", "in-progress samples"),
        ("SELECT COUNT(*) FROM baseline_samples", "baseline samples"),
        ("SELECT COUNT(*) FROM session_records", "session records"),
        ("SELECT COUNT(*) FROM reviews", "reviews"),
        ("SELECT COUNT(*) FROM baselines WHERE state='ESTABLISHED'", "established baselines"),
    ]:
        print("  %-22s %s" % (label, c.execute(q).fetchone()[0]))

    rows = c.execute("SELECT engine, started, ended FROM trips ORDER BY started").fetchall()
    for eng, st, en in rows:
        print("  trip %-9s %s -> %s" % (eng, st, en or "OPEN"))


if __name__ == "__main__":
    main()
