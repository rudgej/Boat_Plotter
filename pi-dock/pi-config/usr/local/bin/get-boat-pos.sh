#!/bin/bash
# Print the boat's position as "lat,lon" (decimal degrees).
# Prefers Signal K live position; falls back to a stored default.
DEFAULT_FILE="/home/pi/.config/boat-pos"
DEFAULT_LAT="43.5804"
DEFAULT_LON="7.1250"

LAT=""; LON=""

# Try Signal K first (real GPS, once available).
POS=$(curl -s -m 4 "http://localhost:3000/signalk/v1/api/vessels/self/navigation/position" 2>/dev/null)
if echo "$POS" | grep -q '"latitude"'; then
    LAT=$(echo "$POS" | grep -oE '"latitude": ?-?[0-9.]+' | head -1 | grep -oE '\-?[0-9.]+$')
    LON=$(echo "$POS" | grep -oE '"longitude": ?-?[0-9.]+' | head -1 | grep -oE '\-?[0-9.]+$')
fi

# Fall back to stored default file.
if [ -z "$LAT" ] || [ -z "$LON" ]; then
    if [ -s "$DEFAULT_FILE" ]; then
        LAT=$(cut -d, -f1 "$DEFAULT_FILE")
        LON=$(cut -d, -f2 "$DEFAULT_FILE")
    else
        LAT="$DEFAULT_LAT"; LON="$DEFAULT_LON"
    fi
fi

printf "%.4f,%.4f" "$LAT" "$LON"
