#!/bin/bash
# Build a chart-like world base map (shaded relief + bathymetry) as MBTiles.
#
# The shipped med-base.mbtiles is Natural Earth *outlines* only, which reads as
# a purple coastline rather than a chart. This uses Natural Earth's 1:10m
# cross-blended hypsometric tints WITH shaded relief, ocean bottom and
# drainages (HYP_HR_SR_OB_DR) -- the dataset made for exactly this purpose.
#
# Output: /var/lib/avnav/charts/world-bathy.mbtiles  (zooms 0-7)
set -euo pipefail

D=/home/pi/basemap-build
SRC=HYP_HR_SR_OB_DR
# The bare GeoTIFF returns 403 from the CDN; the .zip does not. A User-Agent is
# also required -- without one even the zip is refused.
URL="https://naciscdn.org/naturalearth/10m/raster/$SRC.zip"
OUT=${1:-/var/lib/avnav/charts/world-bathy.mbtiles}
MAXZ=${2:-7}

mkdir -p "$D"
cd "$D"

if [ ! -f "$SRC.tif" ]; then
    echo "downloading $SRC.zip (approx 386 MB)..."
    curl -fL -A "Mozilla/5.0" --retry 3 --retry-delay 5 -o "$SRC.zip.part" "$URL"
    mv "$SRC.zip.part" "$SRC.zip"
    # unzip is not installed on this box; python3's zipfile is always there.
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall('.')" "$SRC.zip"
fi
TIF=$(ls "$SRC".tif 2>/dev/null | head -1)
[ -n "$TIF" ] || TIF=$(ls *.tif | head -1)
echo "source: $TIF ($(du -h "$TIF" | cut -f1))"
gdalinfo "$TIF" 2>/dev/null | head -6

echo "tiling zooms 0-$MAXZ (this takes a few minutes)..."
rm -rf tiles
gdal2tiles.py -p mercator -s EPSG:4326 -z "0-$MAXZ" --processes=4 \
    -r bilinear -w none -q "$TIF" tiles

echo "packing to MBTiles..."
python3 "$(dirname "$0")/mbtiles-pack.py" tiles "$D/world-bathy.mbtiles" 0 "$MAXZ" \
    "World shaded relief + bathymetry"

sudo -n install -d -o avnav -g avnav "$(dirname "$OUT")"
sudo -n install -m 644 -o avnav -g avnav "$D/world-bathy.mbtiles" "$OUT"
sudo -n systemctl restart avnav
echo "installed: $OUT"
ls -lh "$OUT"
