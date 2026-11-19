#!/usr/bin/env python3
"""Report what the engine-trends daemon has actually recorded, and whether it looks sane."""
import json
import sqlite3
import subprocess
import urllib.request

DB = "/home/pi/.engine-trends/engine-trends.db"


def q(c, sql, args=()):
    return c.execute(sql, args).fetchall()


def main():
    c = sqlite3.connect(DB)

    print("=== services ===")
    out = subprocess.run(
        ["systemctl", "is-active", "signalk", "avnav", "engine-trends", "nginx",
         "manuals-sync.timer"], capture_output=True, text=True).stdout.split()
    for name, state in zip(["signalk", "avnav", "engine-trends", "nginx", "manuals-sync.timer"], out):
        print("  %-18s %s" % (name, state))

    print("\n=== trips ===")
    for tid, eng, st, en, act in q(c, "select id,engine,started,ended,active from trips order by started"):
        print("  %s %-9s %s -> %s active=%s" % (tid[:8], eng, st, en or "-", act))

    print("\n=== session records ===")
    rows = q(c, "select engine,band,param,n,median,mean,sd,min,max,duration_s "
                "from session_records order by engine,band,param")
    if not rows:
        print("  (none)")
    for e, b, p, n, med, mean, sd, mn, mx, dur in rows:
        print("  %-9s b%d %-12s n=%-4s median=%-9.3f mean=%-9.3f sd=%-6.3f "
              "min=%-9.3f max=%-9.3f dur=%.0fs"
              % (e, b, p, n, med, mean, sd, mn, mx, dur or 0))

    print("\n=== baselines ===")
    rows = q(c, "select engine,band,param,state,qualified_seconds,ref_median,"
                "op_median,op_robust_sd from baselines order by engine,band,param")
    if not rows:
        print("  (none)")
    for e, b, p, s, qs, ref, op, ors in rows:
        print("  %-9s b%d %-12s %-16s qual=%5.1fmin ref=%s op=%s rsd=%s"
              % (e, b, p, s, (qs or 0) / 60, ("%.3f" % ref) if ref is not None else "-",
                 ("%.3f" % op) if op is not None else "-",
                 ("%.3f" % ors) if ors is not None else "-"))

    print("\n=== reviews ===")
    rows = q(c, "select ts,engine,band,param,kind,message from reviews order by ts")
    if not rows:
        print("  (none)")
    for ts, e, b, p, k, m in rows:
        print("  %s %-9s b%s %-12s %-10s %s" % (ts, e, b, p, k, m))

    print("\n=== row counts ===")
    for t in ("baseline_samples", "session_samples"):
        print("  %-18s %s" % (t, q(c, "select count(*) from %s" % t)[0][0]))

    print("\n=== live engineHealth ===")
    try:
        with urllib.request.urlopen(
                "http://localhost:3000/signalk/v1/api/vessels/self/engineHealth", timeout=8) as r:
            d = json.load(r)
    except Exception as e:  # noqa: BLE001
        print("  unreadable:", e)
        return
    for eng, v in d.items():
        print("  %s  band=%s status=%s" % (
            eng, v.get("band", {}).get("value"), v.get("status", {}).get("value")))
        for p in ("rpm", "coolant", "oilTemp", "oilPressure", "boost", "fuel"):
            if p in v:
                print("     %-12s %s  [%s]" % (
                    p, v[p].get("readout", {}).get("value"),
                    v[p].get("baselineStatus", {}).get("value")))


if __name__ == "__main__":
    main()
