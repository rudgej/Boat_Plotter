#!/usr/bin/env python3
"""
engine-trends.py - engine change-detection monitor for Bossy.

Implements engine-trends/SPEC.md (locked). This is a monitoring system, not an
alarm system: it detects *change* in engine behaviour against learned baselines
and reports either

    NORMAL
    REVIEW - <short factual message>

Messages state what changed, never a diagnosis. The engines' own alarms remain
authoritative.

Design notes that differ from the SPEC's dependency list
-------------------------------------------------------
The SPEC lists numpy/scipy. Neither is used here. Everything (percentiles, MAD,
OLS slope, Theil-Sen, Mann-Kendall) is implemented in the standard library so
the daemon has exactly one dependency - `websocket-client`, which is already
installed on Bossy. A boat box should not need a package install to keep
monitoring. Same maths, no moving parts.

Data path:  CAN -> Signal K (propulsion.*) -> this daemon -> SQLite
            this daemon -> Signal K (engineHealth.* + notifications)

Run modes:
    engine-trends.py              normal daemon (systemd)
    engine-trends.py --selftest   synthetic 45-minute run, no Signal K needed
    engine-trends.py --status     print baseline/session/review summary and exit
    engine-trends.py --dry-run    do everything but do not PUT to Signal K
"""

import argparse
import json
import math
import os
import queue
import signal
import sqlite3
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections import deque
from datetime import datetime, timezone

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

def _f(name, default):
    try:
        return float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return float(default)


def _i(name, default):
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return int(default)


BASE_URL = os.environ.get("SIGNALK_URL", "http://localhost:3000").rstrip("/")
WS_URL = BASE_URL.replace("http://", "ws://").replace("https://", "wss://")
USER = os.environ.get("SIGNALK_USER", "boat")
PASSWORD = os.environ.get("SIGNALK_PASSWORD", "")

DATA_DIR = os.environ.get("ENGINE_TRENDS_DIR", "/home/pi/.engine-trends")
DB_PATH = os.environ.get("ENGINE_TRENDS_DB", os.path.join(DATA_DIR, "engine-trends.db"))

# Engine keys. Signal K exposes propulsion.port and propulsion.starboard on
# Bossy; the SPEC's numeric instances are accepted as an alternative.
ENGINE_KEYS = [
    ("port", os.environ.get("ENGINE_PORT_KEY", "port")),
    ("starboard", os.environ.get("ENGINE_STARBOARD_KEY", "starboard")),
]
INSTANCE_KEYS = {
    0: os.environ.get("ENGINE_INSTANCE_PORT", "0"),
    1: os.environ.get("ENGINE_INSTANCE_STARBOARD", "1"),
}
ENGINE_LABEL = {"port": "Port", "starboard": "Starboard"}

EVAL_SECONDS = _f("EVAL_SECONDS", 15)
STALE_SECONDS = _f("STALE_SECONDS", 30)

COOLANT_MIN_C = _f("COOLANT_MIN_C", 75)
RPM_STABLE_WINDOW_S = _f("RPM_STABLE_WINDOW_S", 30)
RPM_STABLE_MAX_DRIFT = _f("RPM_STABLE_MAX_DRIFT", 100)
MIN_QUALIFY_MIN = _f("MIN_QUALIFY_MIN", 5)
BASELINE_MINUTES = _f("BASELINE_MINUTES", 30)

STAB_WINDOW_MIN = _f("STAB_WINDOW_MIN", 10)
STAB_CHECKS = _i("STAB_CHECKS", 2)

Z_DEVIATION = _f("Z_DEVIATION", 3.0)
Z_CONSECUTIVE = _i("Z_CONSECUTIVE", 2)
TREND_MIN_SESSIONS = _i("TREND_MIN_SESSIONS", 20)
TREND_REF_SD = _f("TREND_REF_SD", 2.0)
NEW_RECORD_MIN_SESSIONS = _i("NEW_RECORD_MIN_SESSIONS", 20)

# Guards our own reporting: a REVIEW for the same key is not repeated inside
# this window even if the condition persists. Nothing is lost (it is already
# in SQLite) - this only stops notification spam.
REVIEW_COOLDOWN_S = _f("REVIEW_COOLDOWN_S", 900)

OP_MAX_SESSIONS = _i("OP_MAX_SESSIONS", 8)
ANOMALY_WINDOWS_MIN = (5, 10, 20)


# Parameter table. `conv` turns the Signal K SI value into the display unit the
# SPEC talks in. `stab_env` is the temperature-stabilisation tolerance env var;
# only temperatures have one (SPEC 5: independent per parameter).
PARAMS = {
    "rpm": dict(
        path="revolutions", label="RPM", unit="rpm", fmt="{:.0f}",
        conv=lambda v: v * 60.0, is_temp=False,
        anom_env="RPM_ANOMALY_RPM", anom_default=0.0,
    ),
    "coolant": dict(
        path="temperature", label="Coolant temperature", unit="°C", fmt="{:.1f}",
        conv=lambda v: v - 273.15, is_temp=True,
        stab_env="COOLANT_STAB_TOL_C", stab_default=2.0,
        anom_env="COOLANT_ANOMALY_C", anom_default=3.0,
    ),
    "oilTemp": dict(
        path="oilTemperature", label="Oil temperature", unit="°C", fmt="{:.1f}",
        conv=lambda v: v - 273.15, is_temp=True,
        stab_env="OIL_STAB_TOL_C", stab_default=1.0,
        anom_env="OIL_TEMP_ANOMALY_C", anom_default=3.0,
    ),
    "oilPressure": dict(
        path="oilPressure", label="Oil pressure", unit="bar", fmt="{:.2f}",
        conv=lambda v: v / 1e5, is_temp=False,
        anom_env="OIL_PRESS_ANOMALY_BAR", anom_default=1.0,
    ),
    "boost": dict(
        path="boostPressure", label="Turbo boost", unit="bar", fmt="{:.2f}",
        conv=lambda v: v / 1e5, is_temp=False,
        anom_env="BOOST_ANOMALY_BAR", anom_default=0.30,
    ),
    "fuel": dict(
        path="fuel.rate", label="Fuel flow", unit="L/h", fmt="{:.1f}",
        conv=lambda v: v * 3.6e6, is_temp=False,
        anom_env="FUEL_ANOMALY_LPH", anom_default=2.0,
    ),
}
PARAM_ORDER = ["rpm", "coolant", "oilTemp", "oilPressure", "boost", "fuel"]

for _p in PARAMS.values():
    _p["stab_tol"] = _f(_p["stab_env"], _p["stab_default"]) if "stab_env" in _p else None
    _p["anom"] = _f(_p["anom_env"], _p["anom_default"])

# RPM bands, SPEC 4. Lower inclusive, upper exclusive. Idle is not baselineable.
BANDS = [
    (1, 1000, 1400, "Band 1 (1000-1400)"),
    (2, 1400, 1800, "Band 2 (1400-1800)"),
    (3, 1800, 2100, "Band 3 (1800-2100)"),
    (4, 2100, 2350, "Band 4 (2100-2350)"),
]
IDLE_LABEL = "Idle / manoeuvring"


def band_for(rpm):
    """Return (band_number, label) or (None, label) when not baselineable."""
    if rpm is None:
        return None, "N/A"
    if rpm < 1000:
        return None, IDLE_LABEL
    for num, lo, hi, label in BANDS:
        if lo <= rpm < hi:
            return num, label
    return None, "Above Band 4"


# --------------------------------------------------------------------------
# Statistics (stdlib only)
# --------------------------------------------------------------------------

def median(xs):
    if not xs:
        return None
    s = sorted(xs)
    n = len(s)
    m = n // 2
    return s[m] if n % 2 else 0.5 * (s[m - 1] + s[m])


def percentile(xs, p):
    """Linear-interpolation percentile, p in 0..100. xs need not be sorted."""
    if not xs:
        return None
    s = sorted(xs)
    if len(s) == 1:
        return s[0]
    k = (len(s) - 1) * (p / 100.0)
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return s[int(k)]
    return s[lo] * (hi - k) + s[hi] * (k - lo)


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def stdev(xs):
    if not xs or len(xs) < 2:
        return 0.0
    m = sum(xs) / len(xs)
    var = sum((x - m) ** 2 for x in xs) / (len(xs) - 1)
    return math.sqrt(var)


def mad(xs):
    """Median absolute deviation about the median."""
    if not xs:
        return 0.0
    m = median(xs)
    return median([abs(x - m) for x in xs])


def robust_sd(xs, resolution_floor=0.0):
    """
    1.4826 * MAD, falling back to SD when MAD is 0, then to a configured
    resolution floor. Never returns 0 (SPEC 6: never divide by zero).
    """
    if not xs:
        return max(resolution_floor, 1e-9)
    m = mad(xs)
    if m > 0:
        return max(1.4826 * m, resolution_floor, 1e-9)
    sd = stdev(xs)
    return max(sd, resolution_floor, 1e-9)


def ols_slope(pairs):
    """Least-squares slope of value over time. pairs = [(t, v), ...]."""
    n = len(pairs)
    if n < 2:
        return 0.0
    t0 = pairs[0][0]
    xs = [p[0] - t0 for p in pairs]
    ys = [p[1] for p in pairs]
    mx = sum(xs) / n
    my = sum(ys) / n
    den = sum((x - mx) ** 2 for x in xs)
    if den <= 0:
        return 0.0
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return num / den


def theil_sen(pairs):
    """
    Median of pairwise slopes. pairs = [(t, v), ...] chronological.
    O(n^2) but n is 'number of sessions', i.e. tens.
    """
    n = len(pairs)
    if n < 2:
        return 0.0
    slopes = []
    for i in range(n - 1):
        ti, vi = pairs[i]
        for j in range(i + 1, n):
            dt = pairs[j][0] - ti
            if dt > 0:
                slopes.append((pairs[j][1] - vi) / dt)
    return median(slopes) if slopes else 0.0


def mann_kendall(xs):
    """
    Mann-Kendall trend test with tie correction.
    Returns (S, z, p_two_sided).
    """
    n = len(xs)
    if n < 3:
        return 0, 0.0, 1.0
    s = 0
    for i in range(n - 1):
        for j in range(i + 1, n):
            d = xs[j] - xs[i]
            if d > 0:
                s += 1
            elif d < 0:
                s -= 1
    # tie groups
    counts = {}
    for x in xs:
        counts[x] = counts.get(x, 0) + 1
    tie_term = sum(c * (c - 1) * (2 * c + 5) for c in counts.values() if c > 1)
    var = (n * (n - 1) * (2 * n + 5) - tie_term) / 18.0
    if var <= 0:
        return s, 0.0, 1.0
    if s > 0:
        z = (s - 1) / math.sqrt(var)
    elif s < 0:
        z = (s + 1) / math.sqrt(var)
    else:
        z = 0.0
    p = math.erfc(abs(z) / math.sqrt(2.0))
    return s, z, p


# --------------------------------------------------------------------------
# Database
# --------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS baselines (
    engine              TEXT NOT NULL,
    band                INTEGER NOT NULL,
    param               TEXT NOT NULL,
    state               TEXT NOT NULL DEFAULT 'NOT_ESTABLISHED',
    qualified_seconds   REAL NOT NULL DEFAULT 0,
    ref_n               INTEGER, ref_median REAL, ref_mean REAL, ref_sd REAL,
    ref_robust_sd       REAL, ref_min REAL, ref_max REAL,
    ref_p25 REAL, ref_p75 REAL,
    op_n                INTEGER, op_median REAL, op_mean REAL, op_sd REAL,
    op_robust_sd        REAL, op_min REAL, op_max REAL,
    op_p25 REAL, op_p75 REAL,
    updated             TEXT,
    PRIMARY KEY (engine, band, param)
);

-- Samples belonging to qualifying periods that are still accumulating toward
-- the 30-minute baseline threshold. Deleted once a baseline is established.
CREATE TABLE IF NOT EXISTS baseline_samples (
    engine    TEXT NOT NULL,
    band      INTEGER NOT NULL,
    param     TEXT NOT NULL,
    period_id TEXT NOT NULL,
    ts        REAL NOT NULL,
    value     REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_bs ON baseline_samples (engine, band, param);

CREATE TABLE IF NOT EXISTS trips (
    id      TEXT PRIMARY KEY,
    engine  TEXT NOT NULL,
    started TEXT NOT NULL,
    ended   TEXT,
    active  INTEGER NOT NULL DEFAULT 1
);

-- In-progress samples only. Deleted when the trip is finalised, so individual
-- 15-s samples are never retained (SPEC 7). They exist here purely so an
-- in-progress session survives a reboot (SPEC 7).
CREATE TABLE IF NOT EXISTS session_samples (
    trip_id TEXT NOT NULL,
    band    INTEGER NOT NULL,
    param   TEXT NOT NULL,
    ts      REAL NOT NULL,
    value   REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_ss ON session_samples (trip_id, band, param);

CREATE TABLE IF NOT EXISTS session_records (
    id         TEXT PRIMARY KEY,
    trip_id    TEXT NOT NULL,
    seq        INTEGER NOT NULL,
    engine     TEXT NOT NULL,
    band       INTEGER NOT NULL,
    param      TEXT NOT NULL,
    started    TEXT,
    ended      TEXT,
    duration_s REAL,
    n          INTEGER,
    median     REAL, mean REAL, sd REAL,
    min        REAL, max REAL, p25 REAL, p75 REAL,
    robust_sd  REAL,
    created    TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_sr ON session_records (engine, band, param, seq);

CREATE TABLE IF NOT EXISTS reviews (
    id      TEXT PRIMARY KEY,
    ts      TEXT NOT NULL,
    engine  TEXT NOT NULL,
    band    INTEGER,
    param   TEXT NOT NULL,
    kind    TEXT NOT NULL,
    message TEXT NOT NULL,
    stats   TEXT
);
"""


class Db:
    def __init__(self, path):
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        self.path = path
        self.lock = threading.Lock()
        self.c = sqlite3.connect(path, check_same_thread=False, timeout=30)
        self.c.execute("PRAGMA journal_mode=WAL")
        self.c.execute("PRAGMA synchronous=FULL")
        self.c.executescript(SCHEMA)
        self.c.commit()

    def x(self, sql, args=()):
        with self.lock:
            cur = self.c.execute(sql, args)
            return cur.fetchall()

    def run(self, sql, args=()):
        with self.lock:
            self.c.execute(sql, args)
            self.c.commit()

    def runmany(self, sql, rows):
        if not rows:
            return
        with self.lock:
            self.c.executemany(sql, rows)
            self.c.commit()


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_from_epoch(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# --------------------------------------------------------------------------
# Signal K client
# --------------------------------------------------------------------------

class SkClient:
    """
    Maintains a websocket subscription to the Signal K self stream and keeps
    the latest (SI value, timestamp) per path. Also seeds from the HTTP tree so
    the first evaluation has data.
    """

    def __init__(self, url, ws_url, user, password):
        self.url = url
        self.ws_url = ws_url
        self.user = user
        self.password = password
        self.lock = threading.Lock()
        self.values = {}          # path -> (value, ts_epoch)
        self.token = None
        self._stop = threading.Event()

    # -- auth ------------------------------------------------------------
    def login(self):
        if not self.password:
            return None
        body = json.dumps({"username": self.user, "password": self.password}).encode()
        req = urllib.request.Request(
            self.url + "/signalk/v1/auth/login", data=body, method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                tok = json.load(r).get("token")
                self.token = tok
                return tok
        except Exception as e:  # noqa: BLE001
            log("login failed: %s" % e)
            return None

    def _auth_headers(self):
        return {"Authorization": "Bearer " + self.token} if self.token else {}

    # -- seed ------------------------------------------------------------
    def seed(self):
        try:
            with urllib.request.urlopen(
                self.url + "/signalk/v1/api/vessels/self/propulsion", timeout=10
            ) as r:
                tree = json.load(r)
        except Exception as e:  # noqa: BLE001
            log("seed failed: %s" % e)
            return
        t = time.time()
        with self.lock:
            for eng, sub in tree.items():
                if not isinstance(sub, dict):
                    continue
                for pdef in PARAMS.values():
                    v = _dig(sub, pdef["path"])
                    if isinstance(v, dict) and isinstance(v.get("value"), (int, float)):
                        try:
                            ts = datetime.strptime(
                                v.get("timestamp", ""), "%Y-%m-%dT%H:%M:%S.%fZ"
                            ).replace(tzinfo=timezone.utc).timestamp()
                        except Exception:  # noqa: BLE001
                            ts = t
                        self.values["propulsion.%s.%s" % (eng, pdef["path"])] = (
                            float(v["value"]), ts,
                        )

    # -- websocket -------------------------------------------------------
    def start(self):
        th = threading.Thread(target=self._ws_loop, name="sk-ws", daemon=True)
        th.start()

    def _ws_loop(self):
        try:
            import websocket  # websocket-client
        except ImportError:
            log("websocket-client missing; running on HTTP polling only")
            return
        while not self._stop.is_set():
            try:
                # Build the URL per attempt, not once: a Signal K restart
                # invalidates existing tokens ("invalid signature"), and a
                # cached URL would retry with the dead token forever.
                if not self.token:
                    self.login()
                url = self.ws_url + "/signalk/v1/stream?subscribe=self"
                if self.token:
                    url += "&token=" + self.token
                ws = websocket.create_connection(url, timeout=20)
                log("websocket connected")
                while not self._stop.is_set():
                    raw = ws.recv()
                    if not raw:
                        break
                    self._ingest(raw)
                ws.close()
            except Exception as e:  # noqa: BLE001
                if not self._stop.is_set():
                    log("websocket error: %s (reconnecting)" % e)
                    # Drop the token so the next attempt logs in again.
                    self.token = None
                    time.sleep(5)

    def _ingest(self, raw):
        try:
            msg = json.loads(raw)
        except Exception:  # noqa: BLE001
            return
        for upd in msg.get("updates", []) or []:
            ts_raw = upd.get("timestamp")
            try:
                ts = datetime.strptime(
                    ts_raw, "%Y-%m-%dT%H:%M:%S.%fZ"
                ).replace(tzinfo=timezone.utc).timestamp()
            except Exception:  # noqa: BLE001
                ts = time.time()
            with self.lock:
                for v in upd.get("values", []) or []:
                    path = v.get("path", "")
                    if not path.startswith("propulsion."):
                        continue
                    val = v.get("value")
                    if isinstance(val, (int, float)):
                        self.values[path] = (float(val), ts)

    def get(self, path):
        with self.lock:
            return self.values.get(path)

    def stop(self):
        self._stop.set()

    # -- publish ---------------------------------------------------------
    def put(self, rel_path, value, kind="value"):
        body = json.dumps({"value": value}).encode()
        req = urllib.request.Request(
            self.url + "/signalk/v1/api/vessels/self/" + rel_path,
            data=body, method="PUT",
            headers={"Content-Type": "application/json"},
        )
        for h, hv in self._auth_headers().items():
            req.add_header(h, hv)
        try:
            with urllib.request.urlopen(req, timeout=8) as r:
                r.read()
            return True
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                if self.login():
                    return self.put(rel_path, value, kind)
            log("PUT %s failed: HTTP %s" % (rel_path, e.code))
            return False
        except Exception as e:  # noqa: BLE001
            log("PUT %s failed: %s" % (rel_path, e))
            return False


def _dig(tree, dotted):
    cur = tree
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


# --------------------------------------------------------------------------
# The monitor
# --------------------------------------------------------------------------

class Monitor:
    def __init__(self, db, client, dry_run=False):
        self.db = db
        self.client = client
        self.dry_run = dry_run

        self.trip = {}        # engine -> trip dict {id, started}
        self.rpm_hist = {}    # engine -> deque[(t, rpm)]
        self.temp_hist = {}   # (engine, param) -> deque[(t, v)]
        self.stab = {}        # (engine, param) -> dict
        self.run = {}         # (engine, band, param) -> dict
        self.trip_hist = {}   # (engine, param) -> deque[(t, v)]  (anomaly D)
        self.anom = {}        # (engine, param) -> dict
        self.last_review = {} # (engine, param, kind) -> t
        self.status = {}      # engine -> dict(status, message, t)
        self.baselines = {}   # (engine, band, param) -> row dict

        self._load_baselines()
        self._resume_trips()

    # -- persistence helpers --------------------------------------------
    B_COLS = ("engine", "band", "param", "state", "qualified_seconds",
              "ref_n", "ref_median", "ref_mean", "ref_sd", "ref_robust_sd",
              "ref_min", "ref_max", "ref_p25", "ref_p75",
              "op_n", "op_median", "op_mean", "op_sd", "op_robust_sd",
              "op_min", "op_max", "op_p25", "op_p75", "updated")

    def _load_baselines(self):
        rows = self.db.x("SELECT %s FROM baselines" % ",".join(self.B_COLS))
        for r in rows:
            d = dict(zip(self.B_COLS, r))
            self.baselines[(d["engine"], d["band"], d["param"])] = d

    def _baseline_row(self, engine, band, param):
        key = (engine, band, param)
        if key not in self.baselines:
            self.db.run(
                "INSERT OR IGNORE INTO baselines (engine, band, param, updated)"
                " VALUES (?,?,?,?)", (engine, band, param, now_iso())
            )
            self.baselines[key] = dict(
                engine=engine, band=band, param=param,
                state="NOT_ESTABLISHED", qualified_seconds=0.0,
                ref_n=None, ref_median=None, ref_mean=None, ref_sd=None,
                ref_robust_sd=None, ref_min=None, ref_max=None,
                ref_p25=None, ref_p75=None,
                op_n=None, op_median=None, op_mean=None, op_sd=None,
                op_robust_sd=None, op_min=None, op_max=None,
                op_p25=None, op_p75=None, updated=now_iso(),
            )
        return self.baselines[key]

    def _save_baseline(self, b):
        self.db.run(
            """UPDATE baselines SET state=?, qualified_seconds=?,
               ref_n=?, ref_median=?, ref_mean=?, ref_sd=?, ref_robust_sd=?,
               ref_min=?, ref_max=?, ref_p25=?, ref_p75=?,
               op_n=?, op_median=?, op_mean=?, op_sd=?, op_robust_sd=?,
               op_min=?, op_max=?, op_p25=?, op_p75=?, updated=?
               WHERE engine=? AND band=? AND param=?""",
            (b["state"], b["qualified_seconds"],
             b.get("ref_n"), b.get("ref_median"), b.get("ref_mean"),
             b.get("ref_sd"), b.get("ref_robust_sd"), b.get("ref_min"),
             b.get("ref_max"), b.get("ref_p25"), b.get("ref_p75"),
             b.get("op_n"), b.get("op_median"), b.get("op_mean"),
             b.get("op_sd"), b.get("op_robust_sd"), b.get("op_min"),
             b.get("op_max"), b.get("op_p25"), b.get("op_p75"),
             now_iso(), b["engine"], b["band"], b["param"]),
        )

    def _resume_trips(self):
        """SPEC 7: an in-progress session survives a reboot."""
        rows = self.db.x("SELECT id, engine FROM trips WHERE active=1")
        for trip_id, engine in rows:
            self.trip[engine] = {"id": trip_id}
            log("resumed in-progress trip %s for %s" % (trip_id[:8], engine))

    # -- review ----------------------------------------------------------
    def review(self, t, engine, band, param, kind, message, stats):
        """
        SPEC 7: a REVIEW is committed to SQLite the instant it is raised, then
        raised as a Signal K notification. Nothing is ever lost.

        A repeat of the *same* condition inside REVIEW_COOLDOWN_S is suppressed
        entirely. That is not data loss - the first occurrence is already
        durable and still current in SQLite; it only stops one slow drift from
        writing a row every 30 seconds and spamming notifications.
        """
        key = (engine, param, kind)
        last = self.last_review.get(key, -1e9)
        if t - last < REVIEW_COOLDOWN_S:
            return
        self.last_review[key] = t
        payload = json.dumps(stats, default=str) if stats else None
        # Write-through, before anything else is done with it.
        self.db.run(
            "INSERT INTO reviews (id, ts, engine, band, param, kind, message, stats)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (str(uuid.uuid4()), iso_from_epoch(t), engine, band, param, kind,
             message, payload),
        )
        self.status.setdefault(engine, {})
        self.status[engine] = {"status": "REVIEW", "message": message, "t": t}
        self._notify(engine, message)
        log("REVIEW %s/%s: %s" % (engine, param, message))

    def _notify(self, engine, message):
        if self.dry_run:
            return
        self.client.put(
            "notifications.engineHealth.%s" % engine,
            {"state": "alert", "message": message, "method": ["visual"],
             "timestamp": now_iso()},
            kind="notification",
        )

    # -- the tick --------------------------------------------------------
    def tick(self, t):
        readings = {}
        for engine, engine_key in ENGINE_KEYS:
            vals = {}
            for pname, pdef in PARAMS.items():
                got = self.client.get("propulsion.%s.%s" % (engine_key, pdef["path"]))
                if not got:
                    vals[pname] = None
                    continue
                si, ts = got
                if t - ts > STALE_SECONDS:
                    vals[pname] = None       # SPEC 3: stale is excluded
                    continue
                vals[pname] = pdef["conv"](si)
            readings[engine] = vals

        for engine, engine_key in ENGINE_KEYS:
            self._engine_tick(t, engine, readings[engine])

        self._publish(t)

    def _engine_tick(self, t, engine, v):
        rpm = v["rpm"]
        coolant = v["coolant"]

        # --- rpm drift over the preceding 30 s -------------------------
        h = self.rpm_hist.setdefault(engine, deque())
        if rpm is not None:
            h.append((t, rpm))
        while h and t - h[0][0] > RPM_STABLE_WINDOW_S + EVAL_SECONDS:
            h.popleft()
        rpm_drift = None
        if len(h) >= 2:
            vals = [x[1] for x in h]
            rpm_drift = max(vals) - min(vals)

        # --- trip lifecycle -------------------------------------------
        running = rpm is not None and rpm >= 1000 and coolant is not None \
            and coolant >= COOLANT_MIN_C
        trip = self.trip.get(engine)
        if running and trip is None:
            trip_id = str(uuid.uuid4())
            self.db.run("INSERT INTO trips (id, engine, started, active) VALUES (?,?,?,1)",
                        (trip_id, engine, iso_from_epoch(t)))
            self.trip[engine] = {"id": trip_id, "started": t}
            log("trip started for %s" % engine)
        elif not running and trip is not None:
            self._end_trip(t, engine)
            trip = None

        # --- cool temp stabilisation state may drop out ---------------
        if not running:
            for pname, pdef in PARAMS.items():
                if pdef["is_temp"]:
                    self.stab.pop((engine, pname), None)
                    self.temp_hist.pop((engine, pname), None)

        band, band_label = band_for(rpm)

        for pname, pdef in PARAMS.items():
            val = v[pname]
            stable = True
            if pdef["is_temp"]:
                self._update_temp_history(t, engine, pname, val)
                stable = self._check_stabilised(t, engine, pname)

            qualifies = (
                trip is not None
                and val is not None
                and coolant is not None and coolant >= COOLANT_MIN_C
                and band is not None
                and rpm_drift is not None and rpm_drift <= RPM_STABLE_MAX_DRIFT
                and stable
            )

            self._run_tick(t, engine, band, pname, val, qualifies, trip)

            # --- current-trip anomaly (SPEC 8 D) ----------------------
            if trip is not None and val is not None and stable:
                self._anomaly_tick(t, engine, band, pname, pdef, val, qualifies)

        self.status.setdefault(engine, {"status": "NORMAL", "message": "", "t": t})

    # -- temperature stabilisation --------------------------------------
    def _update_temp_history(self, t, engine, pname, val):
        q = self.temp_hist.setdefault((engine, pname), deque())
        if val is not None:
            q.append((t, val))
        while q and t - q[0][0] > (STAB_WINDOW_MIN * 60) + 60:
            q.popleft()

    def _check_stabilised(self, t, engine, pname):
        """
        SPEC 5: OLS slope over a rolling 10-min window predicts the change over
        that window; stabilised when the prediction is inside tolerance for two
        consecutive 10-minute checks.
        """
        pdef = PARAMS[pname]
        st = self.stab.setdefault((engine, pname), {"consec": 0, "next": 0.0,
                                                    "stabilised": False})
        if not st["stabilised"]:
            if t >= st["next"]:
                q = self.temp_hist.get((engine, pname))
                pairs = [(x[0], x[1]) for x in q] if q else []
                if len(pairs) >= 8:
                    pred = ols_slope(pairs) * (STAB_WINDOW_MIN * 60)
                    if abs(pred) <= pdef["stab_tol"]:
                        st["consec"] += 1
                    else:
                        st["consec"] = 0
                    if st["consec"] >= STAB_CHECKS:
                        st["stabilised"] = True
                        log("%s %s stabilised" % (engine, pname))
                st["next"] = t + (STAB_WINDOW_MIN * 60)
        return st["stabilised"]

    # -- qualifying runs -> baseline accumulation -----------------------
    def _run_tick(self, t, engine, band, pname, val, qualifies, trip):
        key = (engine, band, pname) if band is not None else None
        if key is None:
            return
        r = self.run.get(key)
        if qualifies:
            if r is None:
                r = {"start": t, "last": t, "samples": [], "persisted": 0,
                     "trip": trip["id"]}
                self.run[key] = r
            r["last"] = t
            r["samples"].append((t, val))
        else:
            if r is not None:
                self._close_run(t, engine, band, pname, r)
                self.run.pop(key, None)

    def _close_run(self, t, engine, band, pname, r):
        dur = r["last"] - r["start"]
        if dur < MIN_QUALIFY_MIN * 60:
            return  # SPEC 5: shorter periods are discarded
        b = self._baseline_row(engine, band, pname)
        # Once a reference baseline exists it is permanent (SPEC 6), so later
        # periods must not feed baseline_samples again - otherwise a drifted
        # run would silently overwrite the reference.
        if b["state"] == "ESTABLISHED":
            b["qualified_seconds"] += dur
            self._save_baseline(b)
            return
        period_id = str(uuid.uuid4())
        self.db.runmany(
            "INSERT INTO baseline_samples (engine, band, param, period_id, ts, value)"
            " VALUES (?,?,?,?,?,?)",
            [(engine, band, pname, period_id, ts, v) for ts, v in r["samples"]],
        )
        b["qualified_seconds"] += dur
        if b["state"] == "NOT_ESTABLISHED":
            b["state"] = "ESTABLISHING"
        self._save_baseline(b)
        self._try_establish(engine, band, pname, b)

    # -- baseline establishment -----------------------------------------
    def _try_establish(self, engine, band, pname, b):
        if b["state"] == "ESTABLISHED":
            return  # permanent reference; never recomputed
        need = BASELINE_MINUTES * 60
        if b["qualified_seconds"] < need:
            return
        rows = self.db.x(
            "SELECT period_id, ts, value FROM baseline_samples"
            " WHERE engine=? AND band=? AND param=? ORDER BY ts",
            (engine, band, pname),
        )
        if not rows:
            return
        values = [r[2] for r in rows]
        med = median(values)
        pdef = PARAMS[pname]
        res_floor = 0.01 if pdef["unit"] in ("bar",) else 0.05
        rsd = robust_sd(values, res_floor)

        # SPEC 6 pass criteria
        within = sum(1 for x in values
                     if abs((x - med) / rsd) <= 3.0) / len(values)
        # residual variation: a very wide spread is not a baseline
        max_rel = _f("BASELINE_MAX_REL_SD", 0.25)
        variation_ok = abs(med) > 0 and rsd <= max_rel * abs(med)
        # no significant intra-session temperature trend
        trend_ok = True
        if pdef["is_temp"]:
            by_period = {}
            for pid, ts, val in rows:
                by_period.setdefault(pid, []).append((ts, val))
            for pairs in by_period.values():
                if len(pairs) >= 8:
                    pred = ols_slope(pairs) * (STAB_WINDOW_MIN * 60)
                    if abs(pred) > pdef["stab_tol"]:
                        trend_ok = False
                        break

        if within >= 0.95 and variation_ok and trend_ok:
            stats = dict(
                n=len(values), median=med, mean=mean(values), sd=stdev(values),
                robust_sd=rsd, min=min(values), max=max(values),
                p25=percentile(values, 25), p75=percentile(values, 75),
            )
            b.update(state="ESTABLISHED")
            b.update({("ref_" + k): v for k, v in stats.items()})
            b.update({("op_" + k): v for k, v in stats.items()})
            self._save_baseline(b)
            self.db.run("DELETE FROM baseline_samples WHERE engine=? AND band=?"
                        " AND param=?", (engine, band, pname))
            log("baseline ESTABLISHED %s band %s %s (n=%d, median=%.3f)"
                % (engine, band, pname, stats["n"], med))
        # else: keep the valid periods, keep accumulating (SPEC 6)

    # -- current-trip anomaly (SPEC 8 D) --------------------------------
    def _anomaly_tick(self, t, engine, band, pname, pdef, val, qualifies):
        threshold = pdef["anom"]
        q = self.trip_hist.setdefault((engine, pname), deque())
        q.append((t, val))
        while q and t - q[0][0] > (max(ANOMALY_WINDOWS_MIN) * 60) + 60:
            q.popleft()
        if threshold <= 0 or not qualifies:
            return
        st = self.anom.setdefault((engine, pname), {"count": 0})
        triggered = None
        for win in ANOMALY_WINDOWS_MIN:
            start_t = t - win * 60
            # nearest sample at or before the window start
            base = None
            for ts, v0 in q:
                if ts <= start_t:
                    base = v0
                else:
                    break
            if base is None:
                continue
            change = val - base
            if abs(change) >= threshold:
                triggered = (win, change)
                break
        if triggered:
            st["count"] += 1
            if st["count"] >= 2:  # two consecutive 15-s evaluations
                win, change = triggered
                direction = "increased" if change > 0 else "decreased"
                msg = ("%s — %s %s has %s by %s %s over the last %d minutes."
                       % ("REVIEW", ENGINE_LABEL.get(engine, engine),
                          pdef["label"].lower(), direction,
                          pdef["fmt"].format(abs(change)), pdef["unit"], win))
                self.review(t, engine, band, pname, "TRIP",
                            msg, {"change": change, "window_min": win,
                                  "value": val, "baseline": base})
                st["count"] = 0
        else:
            st["count"] = 0

    # -- trip end: session records + long-term trends -------------------
    def _end_trip(self, t, engine):
        trip = self.trip.pop(engine)
        trip_id = trip["id"]

        # close any qualifying runs still open
        for key in [k for k in list(self.run) if k[0] == engine]:
            _, band, pname = key
            self._close_run(t, engine, band, pname, self.run.pop(key))

        # finalise in-progress samples into session records
        bands = self.db.x(
            "SELECT DISTINCT band, param FROM session_samples WHERE trip_id=?",
            (trip_id,),
        )
        for band, pname in bands:
            rows = self.db.x(
                "SELECT ts, value FROM session_samples WHERE trip_id=?"
                " AND band=? AND param=? ORDER BY ts", (trip_id, band, pname))
            if not rows:
                continue
            vals = [r[1] for r in rows]
            pdef = PARAMS[pname]
            res_floor = 0.01 if pdef["unit"] == "bar" else 0.05
            stats = dict(
                n=len(vals), median=median(vals), mean=mean(vals),
                sd=stdev(vals), min=min(vals), max=max(vals),
                p25=percentile(vals, 25), p75=percentile(vals, 75),
                robust_sd=robust_sd(vals, res_floor),
            )
            seq = self.db.x(
                "SELECT COALESCE(MAX(seq),0)+1 FROM session_records"
                " WHERE engine=? AND band=? AND param=?",
                (engine, band, pname))[0][0]
            self.db.run(
                """INSERT INTO session_records
                   (id, trip_id, seq, engine, band, param, started, ended,
                    duration_s, n, median, mean, sd, min, max, p25, p75,
                    robust_sd, created)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (str(uuid.uuid4()), trip_id, seq, engine, band, pname,
                 iso_from_epoch(rows[0][0]), iso_from_epoch(rows[-1][0]),
                 rows[-1][0] - rows[0][0], stats["n"], stats["median"],
                 stats["mean"], stats["sd"], stats["min"], stats["max"],
                 stats["p25"], stats["p75"], stats["robust_sd"], now_iso()),
            )
            self._long_term(t, engine, band, pname, stats)

        # SPEC 7: individual samples are never retained
        self.db.run("DELETE FROM session_samples WHERE trip_id=?", (trip_id,))
        self.db.run("UPDATE trips SET active=0, ended=? WHERE id=?",
                    (iso_from_epoch(t), trip_id))
        self.status.setdefault(engine, {})["status"] = "NORMAL"
        self.status[engine]["message"] = ""
        for key in [k for k in list(self.trip_hist) if k[0] == engine]:
            self.trip_hist.pop(key, None)
        for key in [k for k in list(self.anom) if k[0] == engine]:
            self.anom.pop(key, None)
        log("trip ended for %s" % engine)

    def _long_term(self, t, engine, band, pname, stats):
        rows = self.db.x(
            "SELECT seq, median, robust_sd FROM session_records"
            " WHERE engine=? AND band=? AND param=? ORDER BY seq",
            (engine, band, pname))
        if len(rows) < 2:
            return
        b = self._baseline_row(engine, band, pname)
        pdef = PARAMS[pname]
        lab = ENGINE_LABEL.get(engine, engine)
        op_med = b.get("op_median")
        op_rsd = b.get("op_robust_sd")
        ref_med = b.get("ref_median")
        ref_rsd = b.get("ref_robust_sd")

        # A. persistent deviation vs operational baseline, two consecutive
        if op_med is not None and op_rsd:
            z_now = (stats["median"] - op_med) / op_rsd
            if len(rows) >= 2:
                z_prev = (rows[-2][1] - op_med) / op_rsd
                if abs(z_now) >= Z_DEVIATION and abs(z_prev) >= Z_DEVIATION \
                        and (z_now > 0) == (z_prev > 0):
                    verb = "higher" if z_now > 0 else "lower"
                    self.review(
                        t, engine, band, pname, "PERSISTENT",
                        "REVIEW — %s %s in %s is persistently %s than normal "
                        "(%.1f vs %.1f %s)."
                        % (lab, pdef["label"].lower(),
                           "this RPM band", verb, stats["median"], op_med,
                           pdef["unit"]),
                        {"z_now": z_now, "z_prev": z_prev, "op_median": op_med},
                    )

        # B. gradual deterioration over full history
        pairs = [(i, r[1]) for i, r in enumerate(rows)]
        if len(rows) >= TREND_MIN_SESSIONS:
            _, z, p = mann_kendall([r[1] for r in rows])
            slope = theil_sen(pairs)
            if p < 0.05 and slope != 0 and ref_med is not None and ref_rsd:
                latest = rows[-1][1]
                dev = latest - ref_med
                if abs(dev) >= TREND_REF_SD * ref_rsd and (dev > 0) == (slope > 0):
                    verb = "rising" if slope > 0 else "falling"
                    self.review(
                        t, engine, band, pname, "GRADUAL",
                        "REVIEW — %s %s has been %s across the last %d "
                        "sessions and is now %.1f %s from its original "
                        "reference of %.1f %s."
                        % (lab, pdef["label"].lower(), verb, len(rows),
                           abs(dev), pdef["unit"], ref_med, pdef["unit"]),
                        {"slope_per_session": slope, "mk_p": p, "deviation": dev},
                    )

        # C. new recorded high / low
        prev = [r[1] for r in rows[:-1]]
        if len(prev) >= NEW_RECORD_MIN_SESSIONS:
            latest = rows[-1][1]
            if latest > max(prev) or latest < min(prev):
                which = "high" if latest > max(prev) else "low"
                self.review(
                    t, engine, band, pname, "RECORD",
                    "REVIEW — %s %s is at a new recorded %s for this RPM band "
                    "(%.1f %s)."
                    % (lab, pdef["label"].lower(), which, latest, pdef["unit"]),
                    {"new": latest, "previous": max(prev) if which == "high"
                     else min(prev), "sessions": len(prev)},
                )

        # operational baseline follows accepted sessions (SPEC 6)
        active_review = self.status.get(engine, {}).get("status") == "REVIEW"
        if not active_review:
            recent = rows[-OP_MAX_SESSIONS:]
            meds = [r[1] for r in recent]
            new_med = median(meds)
            new_rsd = robust_sd(meds, 0.01) if len(meds) >= 3 else b.get("op_robust_sd")
            b.update(op_n=len(meds), op_median=new_med, op_mean=mean(meds),
                     op_sd=stdev(meds),
                     op_robust_sd=new_rsd or b.get("op_robust_sd"),
                     op_min=min(meds), op_max=max(meds),
                     op_p25=percentile(meds, 25), op_p75=percentile(meds, 75))
            if b.get("ref_median") is None:
                b.update(ref_n=len(meds), ref_median=new_med, ref_mean=mean(meds),
                         ref_sd=stdev(meds), ref_robust_sd=new_rsd,
                         ref_min=min(meds), ref_max=max(meds),
                         ref_p25=percentile(meds, 25),
                         ref_p75=percentile(meds, 75))
            self._save_baseline(b)

    # -- publishing to Signal K -----------------------------------------
    def _publish(self, t):
        for engine, engine_key in ENGINE_KEYS:
            st = self.status.setdefault(engine, {"status": "NORMAL",
                                                "message": "", "t": t})
            got_rpm = self.client.get("propulsion.%s.revolutions" % engine_key)
            rpm = got_rpm[0] * 60.0 if got_rpm else None
            band, label = band_for(rpm)

            self._put("engineHealth.%s.band" % engine, label)
            self._put("engineHealth.%s.status" % engine, st["status"])
            self._put("engineHealth.%s.message" % engine, st["message"])

            for pname, pdef in PARAMS.items():
                got = self.client.get("propulsion.%s.%s"
                                      % (engine_key, pdef["path"]))
                if not got or t - got[1] > STALE_SECONDS:
                    cur = None
                else:
                    cur = pdef["conv"](got[0])
                base = None
                bstate = "N/A"
                if band is not None:
                    b = self.baselines.get((engine, band, pname))
                    if b:
                        bstate = b["state"]
                        if b["state"] == "ESTABLISHED" and b.get("op_median") is not None:
                            base = b["op_median"]
                fmt = pdef["fmt"]
                cur_txt = fmt.format(cur) if cur is not None else "N/A"
                if base is not None:
                    base_txt = fmt.format(base)
                    readout = "%s: %s %s (baseline %s %s)" % (
                        pdef["label"], cur_txt, pdef["unit"], base_txt, pdef["unit"])
                else:
                    base_txt = "N/A"
                    readout = "%s: %s %s (baseline N/A)" % (
                        pdef["label"], cur_txt, pdef["unit"])

                self._put("engineHealth.%s.%s.current" % (engine, pname), cur)
                self._put("engineHealth.%s.%s.baseline" % (engine, pname), base)
                self._put("engineHealth.%s.%s.baselineStatus" % (engine, pname), bstate)
                self._put("engineHealth.%s.%s.baselineText" % (engine, pname), base_txt)
                self._put("engineHealth.%s.%s.currentText" % (engine, pname), cur_txt)
                self._put("engineHealth.%s.%s.readout" % (engine, pname), readout)

    def _put(self, path, value):
        if self.dry_run:
            return
        # Skip nulls: Signal K PUT rejects a null value and it carries no info.
        if value is None:
            return
        self.client.put(path, value)

    # -- session sample persistence (reboot survival) -------------------
    def persist_samples(self, t):
        """
        Flush newly-arrived qualifying samples so a reboot resumes the trip.

        The run's samples must stay in memory as well: they are the raw data
        for baseline validation when the run closes (SPEC 6 needs the sample
        distribution, not just a summary). So we only write the ones not yet
        written, tracked by a cursor, and never clear the list here.
        """
        rows = []
        for (engine, band, pname), r in self.run.items():
            trip = self.trip.get(engine)
            if not trip:
                continue
            start = r.get("persisted", 0)
            fresh = r["samples"][start:]
            for ts, v in fresh:
                rows.append((trip["id"], band, pname, ts, v))
            r["persisted"] = start + len(fresh)
        if rows:
            self.db.runmany(
                "INSERT INTO session_samples (trip_id, band, param, ts, value)"
                " VALUES (?,?,?,?,?)", rows)


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def log(msg):
    print("%s %s" % (datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), msg),
          flush=True)


def run_daemon(dry_run=False):
    db = Db(DB_PATH)
    client = SkClient(BASE_URL, WS_URL, USER, PASSWORD)
    if PASSWORD:
        client.login()
    client.seed()
    client.start()
    mon = Monitor(db, client, dry_run=dry_run)
    log("engine-trends started (db=%s, eval=%ss, dry_run=%s)"
        % (DB_PATH, EVAL_SECONDS, dry_run))

    stop = threading.Event()

    def _sig(_n, _f):
        stop.set()

    signal.signal(signal.SIGTERM, _sig)
    signal.signal(signal.SIGINT, _sig)

    next_tick = time.time()
    while not stop.is_set():
        now = time.time()
        if now >= next_tick:
            try:
                mon.tick(now)
                mon.persist_samples(now)
            except Exception as e:  # noqa: BLE001
                log("tick error: %r" % e)
            next_tick = now + EVAL_SECONDS
        stop.wait(min(1.0, max(0.05, next_tick - time.time())))
    client.stop()
    log("engine-trends stopped")


def print_status():
    db = Db(DB_PATH)
    print("== baselines ==")
    rows = db.x("SELECT engine, band, param, state, qualified_seconds,"
                " op_median, op_robust_sd FROM baselines"
                " ORDER BY engine, band, param")
    if not rows:
        print("  (none yet)")
    for e, b, p, s, qs, om, ors in rows:
        print("  %-9s b%d %-12s %-16s qual=%5.1fmin op_median=%s"
              % (e, b, p, s, (qs or 0) / 60.0,
                 ("%.3f" % om) if om is not None else "—"))
    print("== sessions ==")
    rows = db.x("SELECT engine, band, param, COUNT(*), MAX(seq) FROM session_records"
                " GROUP BY engine, band, param ORDER BY engine, band, param")
    if not rows:
        print("  (none yet)")
    for e, b, p, n, mx in rows:
        print("  %-9s b%d %-12s %d session(s)" % (e, b, p, n))
    print("== reviews ==")
    rows = db.x("SELECT ts, engine, param, kind, message FROM reviews"
                " ORDER BY ts DESC LIMIT 20")
    if not rows:
        print("  (none)")
    for ts, e, p, k, m in rows:
        print("  %s %-9s %-12s %-10s %s" % (ts, e, p, k, m))


def selftest():
    """
    Synthetic 50-minute run: engine warms up, stabilises, holds Band 2, then
    drifts. Verifies the pipeline without Signal K. Uses a temp database.
    """
    tmp = tempfile.mkdtemp(prefix="engine-trends-selftest-")
    db = Db(os.path.join(tmp, "test.db"))

    class FakeClient:
        def __init__(self):
            self.values = {}
            self.puts = 0

        def get(self, path):
            return self.values.get(path)

        def put(self, path, value, kind="value"):
            self.puts += 1
            return True

    fake = FakeClient()
    mon = Monitor(db, fake, dry_run=False)

    t = 1_700_000_000.0
    step = EVAL_SECONDS
    engine_key = "port"
    coolant_c = 20.0
    rpm = 900.0
    ok = True

    # 12 min warm-up at idle -> coolant climbs past 75
    for _ in range(int(12 * 60 / step)):
        coolant_c = min(88.0, coolant_c + 0.12)
        rpm = 900.0
        _fake_set(fake, engine_key, rpm, coolant_c, oil_c=70.0)
        mon.tick(t)
        t += step
    # 80 min in Band 2, steady coolant 85. Stabilisation needs two 10-minute
    # checks (~20 min) and a baseline needs 30 min of stabilised data after
    # that, so this has to be comfortably longer than 50 minutes.
    for i in range(int(80 * 60 / step)):
        coolant_c = 85.0
        rpm = 1600.0
        oil_c = 95.0
        _fake_set(fake, engine_key, rpm, coolant_c, oil_c=oil_c,
                  oil_bar=4.6, boost_bar=0.4, fuel_lph=18.0)
        mon.tick(t)
        mon.persist_samples(t)
        t += step

    # Break the qualifying run without ending the trip: rev up into Band 1 for
    # a few ticks (rpm drift > 100), which closes the Band 2 run and lets the
    # baseline establish from the steady period alone. This mirrors the real
    # case where a throttle change separates two steady stretches.
    for i in range(3):
        _fake_set(fake, engine_key, 1300.0, 85.0, oil_c=95.0,
                  oil_bar=4.6, boost_bar=0.4, fuel_lph=18.0)
        mon.tick(t)
        mon.persist_samples(t)
        t += step

    # 10 min coolant rises to 92 -> should trigger a REVIEW
    for i in range(int(10 * 60 / step)):
        coolant_c = 85.0 + (7.0 * i / (10 * 60 / step))
        rpm = 1600.0
        _fake_set(fake, engine_key, rpm, coolant_c, oil_c=95.0,
                  oil_bar=4.6, boost_bar=0.4, fuel_lph=18.0)
        mon.tick(t)
        mon.persist_samples(t)
        t += step

    # stop -> finalise trip
    _fake_set(fake, engine_key, 800.0, 80.0, oil_c=90.0)
    for i in range(3):
        mon.tick(t)
        t += step

    b = db.x("SELECT state, qualified_seconds, op_median FROM baselines"
             " WHERE engine='port' AND band=2 AND param='coolant'")
    s = db.x("SELECT n, median FROM session_records WHERE engine='port'"
             " AND band=2 AND param='coolant'")
    r = db.x("SELECT kind, message FROM reviews")

    print("selftest db:", tmp)
    print("baseline:", b)
    print("sessions:", len(s))
    print("reviews:", r)
    if not b or b[0][0] != "ESTABLISHED":
        ok = False
        print("FAIL: coolant Band 2 baseline not established")
    if not s:
        ok = False
        print("FAIL: no session record produced")
    if not r:
        ok = False
        print("FAIL: no REVIEW raised for the 7 °C rise")
    print("SELFTEST", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def _fake_set(fake, engine_key, rpm, coolant_c, oil_c, oil_bar=0.0,
              boost_bar=0.0, fuel_lph=0.0):
    """Write SI values into the fake client exactly as Signal K would."""
    fake.values.clear()
    p = "propulsion.%s." % engine_key
    fake.values[p + "revolutions"] = (rpm / 60.0, time.time())
    fake.values[p + "temperature"] = (coolant_c + 273.15, time.time())
    fake.values[p + "oilTemperature"] = (oil_c + 273.15, time.time())
    fake.values[p + "oilPressure"] = (oil_bar * 1e5, time.time())
    fake.values[p + "boostPressure"] = (boost_bar * 1e5, time.time())
    fake.values[p + "fuel.rate"] = (fuel_lph / 3.6e6, time.time())


def main():
    ap = argparse.ArgumentParser(description="engine-trends monitor")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        sys.exit(selftest())
    if args.status:
        print_status()
        return
    run_daemon(dry_run=args.dry_run)


if __name__ == "__main__":
    main()
