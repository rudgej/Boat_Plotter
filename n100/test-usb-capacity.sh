#!/bin/bash
#
# Test whether a USB stick really has the capacity it claims.
#
#   sudo ./n100/test-usb-capacity.sh /dev/rdiskN
#
# DESTRUCTIVE: writes a 1 MiB test pattern at several offsets. Run on a stick
# you are prepared to lose.
#
# Why this exists: a stick sold as 8 GB can contain ~750 MiB of real flash and
# a controller that silently discards everything past the end, reporting
# success. Writes appear to work, reads return zeros, and the failure only
# shows up much later. One of these was caught by verify-usb.sh when the last
# 6 MiB of a 756 MiB Debian image read back as zeros.
#
# Reads the pattern straight back at each offset and reports the highest offset
# that verified.
#
set -uo pipefail
BLOCK=1048576          # 1 MiB
die() { echo "FAIL: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${1:-}" ]] || die "usage: sudo $0 /dev/rdiskN"
DEV="${1#/dev/}"; DEV="${DEV#r}"
[[ "$DEV" =~ ^disk[0-9]+$ ]] || die "give a whole disk like /dev/rdiskN"

SIZE_B=$(diskutil info "/dev/$DEV" | sed -n 's/.*Disk Size:.*(\([0-9][0-9]*\) Bytes).*/\1/p')
[[ -n "$SIZE_B" ]] || die "cannot read disk size"
CLAIM_MIB=$(( SIZE_B / BLOCK ))
echo "Device claims $(( SIZE_B / 1000000000 )) GB ($CLAIM_MIB MiB) of capacity"
echo
echo "DESTRUCTIVE TEST - this overwrites data at the offsets below."
read -r -p "Type ERASE to continue: " R
[[ "$R" == "ERASE" ]] || die "aborted"

diskutil unmountDisk force "/dev/$DEV" >/dev/null 2>&1 || true

# Offsets to probe: a spread from small to (nearly) the claimed end.
OFFSETS="64 256 512 700 745 800 1024 2048 4096 $( (( CLAIM_MIB > 6000 )) && echo 6000 7900 )"
GOOD=0
for mib in $OFFSETS; do
    (( mib + 2 > CLAIM_MIB )) && continue
    # Fixed 16-char pattern, unique per offset, written at the START of the
    # block and read back from the same place - so a stale or shifted block
    # cannot masquerade as a pass.
    PAT=$(printf 'USBTEST-%04d-MiB' "$mib")
    dd if=/dev/zero of=/tmp/usbblk.bin bs=$BLOCK count=1 2>/dev/null
    printf '%s' "$PAT" | dd of=/tmp/usbblk.bin bs=1 seek=0 conv=notrunc 2>/dev/null

    dd if=/tmp/usbblk.bin of="/dev/r$DEV" bs=$BLOCK seek=$mib conv=notrunc 2>/dev/null
    sync
    BACK=$(dd if="/dev/r$DEV" bs=$BLOCK skip=$mib count=1 2>/dev/null | head -c 16)
    if [[ "$BACK" == "$PAT" ]]; then
        printf "  %6s MiB  OK\n" "$mib"
        GOOD=$mib
    else
        printf "  %6s MiB  FAILED (wrote '%s', read back '%s')\n" "$mib" "$PAT" "${BACK:-nothing}"
    fi
done
rm -f /tmp/usbblk.bin

echo
if (( GOOD >= 745 )); then
    echo "Real capacity is at least ${GOOD} MiB. Large enough for the 756 MiB ISO:"
    (( GOOD >= 756 )) && echo "  yes - use this stick for the installer." \
                      || echo "  NO - it holds ${GOOD} MiB but the ISO needs 756 MiB."
else
    echo "Real capacity is far below what the stick claims (verified only ${GOOD} MiB)."
    echo "This stick is counterfeit - do NOT use it. Buy a branded stick (SanDisk,"
    echo "Samsung, Kingston) from a reputable seller and test it with this script."
fi
