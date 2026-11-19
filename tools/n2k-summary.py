#!/usr/bin/env python3
"""Summarise the CAN bus: which source addresses are talking, and which PGNs.

Reads `candump -L` style lines ("(ts) can0 ID#DATA") from stdin and groups by
source address and PGN. Also decodes PGN 60928 (ISO Address Claim) so a device's
NAME can be read, which is how you identify a mystery transmitter.
"""
import collections
import sys


def pgn_of(can_id):
    """Extract PGN and source address from a 29-bit CAN id."""
    sa = can_id & 0xFF
    pf = (can_id >> 16) & 0xFF
    ps = (can_id >> 8) & 0xFF
    dp = (can_id >> 24) & 0x01
    if pf < 240:
        pgn = (dp << 16) | (pf << 8)          # PDU1: destination in PS
    else:
        pgn = (dp << 16) | (pf << 8) | ps     # PDU2: group extension in PS
    return pgn, sa


def decode_name(b):
    """ISO Address Claim payload -> manufacturer / function / class."""
    if len(b) < 8:
        return None
    name = int.from_bytes(bytes(b), "little")
    unique = name & 0x1FFFFF
    mfg = (name >> 21) & 0x7FF
    func = (name >> 49) & 0xFF
    cls = (name >> 56) & 0x7F
    return unique, mfg, func, cls


by_sa = collections.defaultdict(collections.Counter)

for line in sys.stdin:
    line = line.strip()
    if not line or "#" not in line:
        continue
    try:
        head, data = line.split("#", 1)
        ident = head.split()[-1]          # "(ts) can0 ID#DATA" -> "ID"
        can_id = int(ident, 16)
    except (ValueError, IndexError):
        continue
    pgn, sa = pgn_of(can_id)
    payload = bytes.fromhex(data[:16])
    by_sa[sa][pgn] += 1
    if pgn == 60928:
        info = decode_name(payload)
        if info:
            print("  ADDRESS CLAIM from 0x%02X: unique=%d mfg_code=%d function=%d class=%d"
                  % (sa, info[0], info[1], info[2], info[3]))

for sa in sorted(by_sa):
    print("\n  source 0x%02X (address %d) sent %d distinct PGNs:"
          % (sa, sa, len(by_sa[sa])))
    for pgn, count in by_sa[sa].most_common():
        print("    PGN %-6d %5d frames" % (pgn, count))
