#!/bin/bash
# Deploy and verify the touch-friendly manuals index + PDF back button.
set -uo pipefail

sudo -n install -m 644 /tmp/manuals-index.css /etc/nginx/manuals-index.css
sudo -n install -m 644 /tmp/manuals-site /etc/nginx/sites-available/manuals
sudo -n nginx -t 2>&1 || { echo "NGINX CONFIG INVALID - not reloading"; exit 1; }
sudo -n systemctl reload nginx
sleep 1

echo "=== 1. index is restyled ==="
curl -s http://localhost:8081/ | grep -c "font-size" | sed 's/^/  css rules injected: /'

echo "=== 2. a folder link + big fonts present ==="
curl -s http://localhost:8081/ | grep -o 'href="Engines/"' | head -1

echo "=== 3. PDF now returns the wrapper (not the raw file) ==="
PDF=$(find /home/pi/manuals -type f -name "*.pdf" | head -1)
REL=${PDF#/home/pi/manuals/}
URL="http://localhost:8081/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$REL")"
echo "  path: $REL"
curl -s -o /tmp/wrap.html -w "  http=%{http_code} type=%{content_type}\n" "$URL"
grep -o 'id="bar"' /tmp/wrap.html | head -1 | sed 's/^/  has back bar: /'
grep -o '<iframe src="[^"]*"' /tmp/wrap.html | head -1 | sed 's/^/  iframe: /'

echo "=== 4. the real PDF still streams with Range from /raw/ ==="
RAW="http://localhost:8081/raw/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$REL")"
curl -s -r 0-1023 -o /dev/null -w "  raw http=%{http_code} bytes=%{size_download} type=%{content_type}\n" "$RAW"

echo "=== 4b. a FULL download must be byte-identical (no CSS appended) ==="
curl -s -o /tmp/raw.pdf "$RAW"
LOCAL_SIZE=$(stat -c %s "$PDF")
GOT_SIZE=$(stat -c %s /tmp/raw.pdf)
echo "  file=$LOCAL_SIZE served=$GOT_SIZE"
[ "$LOCAL_SIZE" = "$GOT_SIZE" ] && echo "  OK identical" || echo "  MISMATCH - response body was modified!"
head -c 5 /tmp/raw.pdf | grep -q '%PDF' && echo "  header %PDF OK" || echo "  BAD header"

echo "=== 5. a path with a space in it ==="
SP=$(find /home/pi/manuals -type f -name "*.pdf" | grep " " | head -1)
if [ -n "$SP" ]; then
  SR=${SP#/home/pi/manuals/}
  SRAW="http://localhost:8081/raw/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$SR")"
  curl -s -r 0-1023 -o /dev/null -w "  spaced raw http=%{http_code} bytes=%{size_download}\n" "$SRAW"
  echo "  ($SR)"
fi

echo "=== 6. errors? ==="
sudo -n tail -5 /var/log/nginx/manuals-error.log 2>/dev/null || echo "  (no error log yet)"
