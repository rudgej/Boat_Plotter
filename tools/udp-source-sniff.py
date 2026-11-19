#!/usr/bin/env python3
"""Show which device is sending the NMEA wind sentences, and how often.

Sniffs UDP/10110 with a raw socket (needs root) and reports the source address
of every datagram plus the gaps between them. Uses only the standard library -
no tcpdump required.

    sudo python3 tools/udp-source-sniff.py [seconds] [port]

Useful when the source of a feed is unknown: it answers "which box is sending
this, and is it regular".
"""
import socket
import struct
import sys
import time
from collections import defaultdict

SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 20
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 10110

ETH_P_IP = 0x0800

sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP))
sock.settimeout(0.5)

arrivals = defaultdict(list)
payloads = {}
end = time.time() + SECONDS

while time.time() < end:
    try:
        frame, addr = sock.recvfrom(65535)
    except socket.timeout:
        continue
    if len(frame) < 34:
        continue

    ihl = (frame[14] & 0x0F) * 4
    if frame[23] != 17:            # UDP
        continue
    udp = 14 + ihl
    if len(frame) < udp + 8:
        continue
    dport = struct.unpack("!H", frame[udp + 2:udp + 4])[0]
    if dport != PORT:
        continue

    src = socket.inet_ntoa(frame[26:30])
    length = struct.unpack("!H", frame[udp + 4:udp + 6])[0]
    body = frame[udp + 8:udp + max(8, length)]
    arrivals[src].append(time.time())
    payloads.setdefault(src, body)

sock.close()

print("\n  sniffed UDP/%d for %d s\n" % (PORT, SECONDS))
if not arrivals:
    print("  no traffic on that port")
for src in sorted(arrivals):
    ts = sorted(arrivals[src])
    gaps = [ts[i + 1] - ts[i] for i in range(len(ts) - 1)]
    print("  %-16s %4d packets" % (src, len(ts)), end="")
    if gaps:
        gaps_sorted = sorted(gaps)
        print("  median %.2fs  max %.2fs  gaps>1s: %d"
              % (gaps_sorted[len(gaps_sorted) // 2], max(gaps), sum(1 for g in gaps if g > 1)))
    else:
        print()
    text = payloads[src].decode("ascii", "replace").strip()
    print("      first sentence: %s" % text[:90])
