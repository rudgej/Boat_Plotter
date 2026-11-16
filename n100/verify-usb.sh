#!/bin/bash
#
# Verify a written Debian installer stick, byte-for-byte.
#
#   sudo ./n100/verify-usb.sh /dev/rdiskN
#
# Run in Terminal.app, not from an editor's integrated terminal: macOS blocks
# raw block-device access (TCC "Removable Volumes") for most apps, even as
# root, so dd fails with "Operation not permitted" there.
#
set -uo pipefail

ISO="$(ls -1 "$HOME/Downloads/n100-staging"/debian-*-amd64-netinst.iso 2>/dev/null | head -1)"
EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
die() { echo "FAIL: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${1:-}" ]] || die "usage: sudo $0 /dev/rdiskN"
[[ -n "$ISO" ]] || die "ISO not found in ~/Downloads/n100-staging/"

DEV="${1#/dev/}"; DEV="${DEV#r}"
[[ "$DEV" =~ ^disk[0-9]+$ ]] || die "give a whole disk like /dev/rdiskN"

ISO_BYTES=$(stat -f%z "$ISO")
ISO_SHA=$(shasum -a 256 "$ISO" | awk '{print $1}')

echo "ISO : $ISO ($ISO_BYTES bytes)"
echo "disk: /dev/$DEV"
diskutil info "/dev/$DEV" | grep -E "Device / Media Name|Disk Size|Removable" | sed 's/^/      /'
echo

diskutil unmountDisk force "/dev/$DEV" >/dev/null 2>&1

echo "== structure checks =="
SIG=$(dd if="/dev/r$DEV" bs=512 count=1 2>/dev/null | dd bs=1 skip=510 count=2 2>/dev/null | xxd -p)
[[ "$SIG" == "55aa" ]] && echo "  MBR signature 55aa                  OK" \
                       || echo "  MBR signature 55aa                  MISSING (got '$SIG')"
PVD=$(dd if="/dev/r$DEV" bs=1 skip=32769 count=5 2>/dev/null)
[[ "$PVD" == "CD001" ]] && echo "  ISO9660 'CD001' at 32768            OK" \
                        || echo "  ISO9660 'CD001' at 32768            MISSING (got '$PVD')"
GPT=$(dd if="/dev/r$DEV" bs=1 skip=512 count=8 2>/dev/null)
[[ "$GPT" == "EFI PART" ]] && echo "  GPT header 'EFI PART' at 512        OK" \
                           || echo "  GPT header 'EFI PART' at 512        MISSING (got '$GPT')"
echo

echo "== full image hash (this is the one that matters) =="
GOT=$(dd if="/dev/r$DEV" bs=4m count=$(( ISO_BYTES / 4194304 + 1 )) 2>/dev/null \
      | head -c "$ISO_BYTES" | shasum -a 256 | awk '{print $1}')
echo "  expected: $ISO_SHA"
echo "  on stick: $GOT"
echo

if [[ -z "$GOT" || "$GOT" == "$EMPTY_SHA" ]]; then
    die "read returned no data - check you passed a whole disk (/dev/rdiskN)"
elif [[ "$GOT" == "$ISO_SHA" ]]; then
    echo "PASS - the stick is byte-identical to the ISO. It will boot."
    exit 0
else
    echo "FAIL - the stick does not match the ISO. Reflash it."
    exit 1
fi
