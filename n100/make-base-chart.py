#!/usr/bin/env python3
"""Generate an offline MBTiles base chart for AvNav from Natural Earth data.

Natural Earth is public domain (naturalearthdata.com), so the output can be
redistributed and generated without any tile-server usage policy problems.

This produces a *reference* base chart: coastline, land, lakes, country
borders and major place names. It is deliberately NOT for navigation -- the
navigational charts are the bought o-charts/oeSENC ones.

    ./make-base-chart.py --bbox -6,29,37,47 --zoom 0-8 --out med-base.mbtiles

Requirements: pillow, numpy, pyshp (pip install pillow numpy pyshp)
"""

import argparse
import io
import math
import os
import sqlite3
import ssl
import sys
import urllib.request
import zipfile

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import shapefile  # pyshp

NE = "https://naturalearth.s3.amazonaws.com"
LAYERS = {
    "land": "10m_physical/ne_10m_land",
    "lakes": "10m_physical/ne_10m_lakes",
    "borders": "10m_cultural/ne_10m_admin_0_boundary_lines_land",
    "places": "10m_cultural/ne_10m_populated_places",
}

SEA = (156, 197, 222)
LAND = (238, 231, 208)
LAKE = (156, 197, 222)
COAST = (58, 96, 122)
BORDER = (150, 130, 150)
GRID = (140, 160, 180)
LABEL = (60, 60, 70)

TILE = 256
SS = 2  # supersampling factor for antialiasing


def log(msg):
    print(msg, flush=True)


# ---------------------------------------------------------------- download

def _ssl_context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def fetch_layer(cache, name):
    base = LAYERS[name]
    stem = os.path.basename(base)
    shp = os.path.join(cache, stem + ".shp")
    if os.path.exists(shp):
        return shp
    os.makedirs(cache, exist_ok=True)
    url = "%s/%s.zip" % (NE, base)
    log("  downloading %s" % url)
    with urllib.request.urlopen(url, timeout=120, context=_ssl_context()) as r:
        data = r.read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for member in z.namelist():
            if member.lower().endswith((".shp", ".shx", ".dbf", ".prj", ".cpg")):
                with open(os.path.join(cache, member), "wb") as f:
                    f.write(z.read(member))
    if not os.path.exists(shp):
        sys.exit("missing shapefile after unzip: %s" % shp)
    return shp


# ------------------------------------------------------------- projection

def merc(lon, lat):
    """lon/lat -> normalised web-mercator u,v in [0,1]."""
    lat = np.clip(lat, -85.05112878, 85.05112878)
    u = (np.asarray(lon, dtype=np.float64) + 180.0) / 360.0
    s = np.sin(np.radians(lat))
    v = 0.5 - np.log((1.0 + s) / (1.0 - s)) / (4.0 * math.pi)
    return u, v


class Shape:
    __slots__ = ("u", "v", "umin", "vmin", "umax", "vmax", "area")

    def __init__(self, u, v):
        self.u = u
        self.v = v
        self.umin, self.umax = float(u.min()), float(u.max())
        self.vmin, self.vmax = float(v.min()), float(v.max())
        self.area = (self.umax - self.umin) * (self.vmax - self.vmin)


def load_shapes(shp_path, bbox):
    """Read polygons/lines, clip by bbox, project to normalised mercator."""
    lon0, lat0, lon1, lat1 = bbox
    out = []
    sf = shapefile.Reader(shp_path)
    for shp in sf.shapes():
        bx0, by0, bx1, by1 = shp.bbox
        if bx1 < lon0 or bx0 > lon1 or by1 < lat0 or by0 > lat1:
            continue
        pts = np.asarray(shp.points, dtype=np.float64)
        if len(pts) < 2:
            continue
        for part in _parts(shp, pts):
            if len(part) < 2:
                continue
            u, v = merc(part[:, 0], part[:, 1])
            out.append(Shape(u, v))
    out.sort(key=lambda s: -s.area)
    return out


def _parts(shp, pts):
    idx = list(shp.parts) + [len(pts)]
    for i in range(len(idx) - 1):
        yield pts[idx[i]:idx[i + 1]]


def load_places(shp_path, bbox):
    lon0, lat0, lon1, lat1 = bbox
    out = []
    sf = shapefile.Reader(shp_path)
    fields = [f[0] for f in sf.fields[1:]]
    i_name = fields.index("NAME") if "NAME" in fields else None
    i_rank = fields.index("SCALERANK") if "SCALERANK" in fields else None
    if i_name is None:
        return out
    for rec in sf.iterShapeRecords():
        lon, lat = rec.shape.points[0] if rec.shape.points else (None, None)
        if lon is None or not (lon0 <= lon <= lon1 and lat0 <= lat <= lat1):
            continue
        name = rec.record[i_name]
        rank = rec.record[i_rank] if i_rank is not None else 5
        u, v = merc(lon, lat)
        out.append((name, float(u), float(v), int(rank)))
    return out


# ---------------------------------------------------------------- drawing

def font(size):
    for path in ("/System/Library/Fonts/Supplemental/Arial.ttf",
                 "/System/Library/Fonts/Helvetica.ttc",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    return ImageFont.load_default()


def draw_tile(z, tx, ty, shapes, lakes, borders, places, fonts):
    size = TILE * SS
    img = Image.new("RGB", (size, size), SEA)
    d = ImageDraw.Draw(img)
    if z >= 2:
        span = 1.0 / (1 << z)
        # graticule
        step = 30 if z < 3 else 10 if z < 5 else 5 if z < 7 else 1
        for lon in range(-180, 181, step):
            u, _ = merc(lon, 0)
            px = (u - tx * span) / span * size
            if 0 <= px <= size:
                d.line([(px, 0), (px, size)], fill=GRID, width=1)
        lat = -80
        while lat <= 80:
            _, v = merc(0, lat)
            py = (v - ty * span) / span * size
            if 0 <= py <= size:
                d.line([(0, py), (size, py)], fill=GRID, width=1)
            lat += step

    k = size / (1.0 / (1 << z))  # px per normalised unit
    ox, oy = tx * (1.0 / (1 << z)), ty * (1.0 / (1 << z))

    def draw_set(items, fill=None, outline=None, width=1):
        for s in items:
            if s.umax < ox or s.umin > ox + 1.0 / (1 << z):
                continue
            if s.vmax < oy or s.vmin > oy + 1.0 / (1 << z):
                continue
            pts = list(zip((s.u - ox) * k, (s.v - oy) * k))
            if len(pts) < 2:
                continue
            if fill is not None and len(pts) > 2:
                d.polygon(pts, fill=fill, outline=outline)
            elif outline is not None:
                d.line(pts, fill=outline, width=width)

    if z >= 2:
        draw_set(shapes, fill=LAND, outline=None)
        draw_set(borders, outline=BORDER, width=max(1, SS // 2))
        draw_set(lakes, fill=LAKE, outline=COAST)
        draw_set(shapes, outline=COAST, width=max(1, SS))
    else:
        draw_set(shapes, fill=LAND)

    if z >= 5 and places:
        f = fonts[min(len(fonts) - 1, max(0, z - 5))]
        maxrank = 6 if z < 6 else 9 if z < 7 else 12
        for name, u, v, rank in places:
            if rank > maxrank:
                continue
            x = (u - ox) * k
            y = (v - oy) * k
            if not (-40 <= x <= size + 40 and -20 <= y <= size + 20):
                continue
            d.ellipse([x - 2 * SS, y - 2 * SS, x + 2 * SS, y + 2 * SS], fill=LABEL)
            d.text((x + 4 * SS, y - 6 * SS), str(name), font=f, fill=LABEL,
                   stroke_width=SS, stroke_fill=LAND)

    return img.resize((TILE, TILE), Image.LANCZOS)


# ------------------------------------------------------------------ mbtiles

def tile_range(z, bbox):
    lon0, lat0, lon1, lat1 = bbox
    n = 1 << z
    u0, v0 = merc(lon0, lat1)
    u1, v1 = merc(lon1, lat0)
    x0 = max(0, int(math.floor(u0 * n)))
    x1 = min(n - 1, int(math.floor(u1 * n)))
    y0 = max(0, int(math.floor(v0 * n)))
    y1 = min(n - 1, int(math.floor(v1 * n)))
    return x0, x1, y0, y1


def count_tiles(bbox, zmin, zmax):
    total = 0
    for z in range(zmin, zmax + 1):
        x0, x1, y0, y1 = tile_range(z, bbox)
        total += max(0, x1 - x0 + 1) * max(0, y1 - y0 + 1)
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bbox", required=True, help="lon_min,lat_min,lon_max,lat_max")
    ap.add_argument("--zoom", default="0-8", help="zoom range, e.g. 0-8")
    ap.add_argument("--out", required=True)
    ap.add_argument("--name", default="AvNav base chart")
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/ne10m"))
    args = ap.parse_args()

    bbox = tuple(float(v) for v in args.bbox.split(","))
    if len(bbox) != 4:
        sys.exit("--bbox needs 4 comma separated numbers")
    zmin, zmax = (int(v) for v in args.zoom.split("-"))

    log("natural earth cache: %s" % args.cache)
    paths = {}
    for name in ("land", "lakes", "borders", "places"):
        log("loading %s" % name)
        paths[name] = fetch_layer(args.cache, name)

    land = load_shapes(paths["land"], bbox)
    lakes = load_shapes(paths["lakes"], bbox)
    borders = load_shapes(paths["borders"], bbox)
    places = load_places(paths["places"], bbox)
    log("shapes: land=%d lakes=%d borders=%d places=%d"
        % (len(land), len(lakes), len(borders), len(places)))

    total = count_tiles(bbox, zmin, zmax)
    log("rendering %d tiles for z%d-%d" % (total, zmin, zmax))

    fonts = [font(9 * SS), font(10 * SS), font(11 * SS), font(12 * SS)]

    if os.path.exists(args.out):
        os.remove(args.out)
    db = sqlite3.connect(args.out)
    db.executescript(
        "CREATE TABLE metadata (name TEXT, value TEXT);"
        "CREATE UNIQUE INDEX name ON metadata (name);"
        "CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER,"
        " tile_row INTEGER, tile_data BLOB);"
        "CREATE UNIQUE INDEX tile_index ON tiles"
        " (zoom_level, tile_column, tile_row);"
    )
    meta = {
        "name": args.name,
        "format": "png",
        "type": "baselayer",
        "version": "1",
        "description": "Natural Earth base chart - reference only, NOT for navigation",
        "bounds": "%.4f,%.4f,%.4f,%.4f" % (bbox[0], bbox[1], bbox[2], bbox[3]),
        "minzoom": str(zmin),
        "maxzoom": str(zmax),
    }
    db.executemany("INSERT INTO metadata VALUES (?,?)", meta.items())

    done = 0
    batch = []
    for z in range(zmin, zmax + 1):
        x0, x1, y0, y1 = tile_range(z, bbox)
        for ty in range(y0, y1 + 1):
            for tx in range(x0, x1 + 1):
                img = draw_tile(z, tx, ty, land, lakes, borders, places, fonts)
                buf = io.BytesIO()
                img.save(buf, "PNG", optimize=True)
                tms_y = (1 << z) - 1 - ty
                batch.append((z, tx, tms_y, buf.getvalue()))
                done += 1
            if len(batch) >= 200:
                db.executemany("INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)", batch)
                batch = []
        if batch:
            db.executemany("INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)", batch)
            batch = []
        db.commit()
        log("  z%d done (%d/%d tiles)" % (z, done, total))

    db.commit()
    db.execute("VACUUM")
    db.close()
    log("wrote %s (%.1f MB)" % (args.out, os.path.getsize(args.out) / 1e6))


if __name__ == "__main__":
    main()
