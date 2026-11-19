#!/bin/bash
# Verify the enginetrends-status plugin registered engineHealth.* paths:
# an authenticated PUT should return 200 (405 means "path not registered").
set -uo pipefail
set -a
# shellcheck disable=SC1091
. /etc/signalk-automation.env
set +a
BASE="${SIGNALK_URL:-http://localhost:3000}"

TOKEN=$(curl -s -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"$SIGNALK_USER\",\"password\":\"$SIGNALK_PASSWORD\"}" \
  "$BASE/signalk/v1/auth/login" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')

if [ -z "$TOKEN" ]; then echo "LOGIN FAILED"; exit 1; fi
echo "login ok"

for path in engineHealth/port/status engineHealth/port/coolant/readout \
            engineHealth/starboard/band; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    -d '{"value":"NORMAL"}' "$BASE/signalk/v1/api/vessels/self/$path")
  echo "PUT $path -> $code"
done

echo "--- read back ---"
curl -s "$BASE/signalk/v1/api/vessels/self/engineHealth" | head -c 400
echo
