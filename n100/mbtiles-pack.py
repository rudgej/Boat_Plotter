#!/usr/bin/env python3
"""
Pack a gdal2tiles output directory into a spec-compliant MBTiles file.

gdal2tiles with `-p mercator` writes tiles as tiles/<z>/<x>/<y>.png using the
TMS row order, which is exactly what the MBTiles spec expects -- so the row
index is used as-is. Do not "fix" it without checking, or the world inverts.

Usage: mbtiles-pack.py <tiles-dir> <out.mbtiles> <minzoom> <maxzoom> [name]
"""
import os
import sqlite3
import sys

tiles_dir, out_path, minz, maxz = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
name = sys.argv[5] if len(sys.argv) > 5 else "World shaded relief + bathymetry"

if os.path.exists(out_path):
    os.remove(out_path)

db = sqlite3.connect(out_path)
db.execute("PRAGMA journal_mode=OFF")
db.execute("PRAGMA synchronous=OFF")
db.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
db.execute("CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, "
           "tile_row INTEGER, tile_data BLOB)")
db.execute("CREATE UNIQUE INDEX tile_index ON tiles "
           "(zoom_level, tile_column, tile_row)")

rows = []
count = 0
for z in range(minz, maxz + 1):
    zdir = os.path.join(tiles_dir, str(z))
    if not os.path.isdir(zdir):
        continue
    for xname in os.listdir(zdir):
        xdir = os.path.join(zdir, xname)
        if not os.path.isdir(xdir):
            continue
        for yname in os.listdir(xdir):
            if not yname.endswith(".png"):
                continue
            with open(os.path.join(xdir, yname), "rb") as f:
                data = f.read()
            rows.append((z, int(xname), int(yname[:-4]), data))
            count += 1
        if len(rows) >= 500:
            db.executemany("INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)", rows)
            rows = []
if rows:
    db.executemany("INSERT OR REPLACE INTO tiles VALUES (?,?,?,?)", rows)

meta = {
    "name": name,
    "format": "png",
    "type": "baselayer",
    "version": "1.0",
    "description": "Natural Earth 1:10m cross-blended hypsometric tints with "
                   "shaded relief, ocean bottom and drainages",
    "bounds": "-180.0,-85.0511,180.0,85.0511",
    "center": "0,0,%d" % minz,
    "minzoom": str(minz),
    "maxzoom": str(maxz),
}
db.executemany("INSERT INTO metadata VALUES (?,?)", list(meta.items()))
db.commit()
db.execute("VACUUM")
db.commit()
db.close()
print("packed %d tiles -> %s (%.1f MB)" % (count, out_path, os.path.getsize(out_path) / 1048576))
