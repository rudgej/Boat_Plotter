#!/bin/bash
#
# Verify a written Debian installer stick against the ISO.
#
#   sudo ./n100/verify-usb.sh /dev/rdiskN
#
# Run in Terminal.app. macOS gates raw block-device access per application
# (TCC "Removable Volumes") and denies it even to root from an editor's
# integrated terminal, so dd there fails with "Operation not permitted".
#
# Design notes, learned the hard way:
#  - never use `dd bs=1` on a raw device: macOS refuses 1-byte blocks, the read
#    returns nothing, and an empty read looks exactly like a failed check.
#  - read ONE bulk chunk to a temp file, then inspect it locally. Fewer raw
#    syscalls, and every check can be re-run without touching the stick again.
#  - compare with cmp rather than hashing: on mismatch it names the first
#    differing byte, which tells you far more than two different digests.
#
set -uo pipefail

ISO="$(ls -1 "$HOME"/Downloads/n100-staging/debian-*-amd64-netinst.iso 2>/dev/null | head -1)"
TMP=/tmp/stick-head.img
die() { echo "FAIL: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo"
[[ -n "${1:-}" ]] || die "usage: sudo $0 /dev/rdiskN"
[[ -n "$ISO" ]] || die "ISO not found in ~/Downloads/n100-staging/"

DEV="${1#/dev/}"; DEV="${DEV#r}"
[[ "$DEV" =~ ^disk[0-9]+$ ]] || die "give a whole disk like /dev/rdiskN"

ISO_BYTES=$(stat -f%z "$ISO")
echo "ISO : $(basename "$ISO") ($ISO_BYTES bytes)"
diskutil info "/dev/$DEV" | grep -E "Device / Media Name|Disk Size|Removable" | sed 's/^/      /'
echo

diskutil unmountDisk force "/dev/$DEV" >/dev/null 2>&1 || true

# Read exactly ISO_BYTES when the size divides evenly into big blocks, so the
# copy needs no truncation afterwards (truncate behaviour varies by macOS).
if (( ISO_BYTES % 1048576 == 0 )); then BS=1m; BLK=1048576
elif (( ISO_BYTES % 512 == 0 ));     then BS=512; BLK=512
else BS=1m; BLK=1048576; fi
COUNT=$(( ISO_BYTES / BLK ))

echo "== reading ${ISO_BYTES} bytes from /dev/r$DEV (bs=$BS x $COUNT, about 40 s) =="
rm -f "$TMP"
if ! dd if="/dev/r$DEV" of="$TMP" bs="$BS" count="$COUNT" 2>&1 | tail -2; then
    die "dd failed - is the device present and unmounted?"
fi
GOT_BYTES=$(stat -f%z "$TMP" 2>/dev/null || echo 0)
echo "    read back: $GOT_BYTES bytes"
if (( GOT_BYTES < 65536 )); then
    die "only $GOT_BYTES bytes readable - raw access is being blocked, or the stick is dead"
fi

echo
echo "== structure checks (on the copy) =="
hexat() { dd if="$TMP" bs=512 skip=$(( $1 / 512 )) count=1 2>/dev/null | dd bs=1 skip=$(( $1 % 512 )) count=$2 2>/dev/null | xxd -p; }
SIG=$(hexat 510 2)
[[ "$SIG" == "55aa" ]] && echo "  MBR boot signature at 510            OK" \
                       || echo "  MBR boot signature at 510            MISSING (got '$SIG')"
PVD=$(dd if="$TMP" bs=32768 skip=1 count=1 2>/dev/null | dd bs=1 skip=1 count=5 2>/dev/null)
[[ "$PVD" == "CD001" ]] && echo "  ISO9660 'CD001' at 32768             OK" \
                        || echo "  ISO9660 'CD001' at 32768             MISSING (got '$PVD')"
GPT=$(dd if="$TMP" bs=512 skip=1 count=1 2>/dev/null | dd bs=1 count=8 2>/dev/null)
[[ "$GPT" == "EFI PART" ]] && echo "  GPT header 'EFI PART' at 512         OK" \
                           || echo "  GPT header 'EFI PART' at 512         MISSING (got '$GPT')"

echo
echo "== byte-for-byte comparison with the ISO =="
if (( GOT_BYTES > ISO_BYTES )); then
    truncate -s "$ISO_BYTES" "$TMP" 2>/dev/null || true
    GOT_BYTES=$(stat -f%z "$TMP")
fi
if (( GOT_BYTES != ISO_BYTES )); then
    echo "  size mismatch: stick copy $GOT_BYTES vs ISO $ISO_BYTES"
fi
if cmp -s "$TMP" "$ISO"; then
    echo "  PASS - the stick is byte-identical to the ISO. It will boot."
    rm -f "$TMP"
    exit 0
fi
echo "  DIFFERS. Locating the differences..."
# cmp -l prints "offset val1 val2" (1-based) for each differing byte.
FIRST=$(cmp -l "$TMP" "$ISO" 2>/dev/null | head -5)
if [[ -n "$FIRST" ]]; then
    echo "    first differing bytes (offset, stick, iso):"
    echo "$FIRST" | sed 's/^/      /'
else
    echo "    no differing bytes reported - the files differ only in length"
fi

# One pass, capped, then derive which 1 MiB blocks are affected. Cheaper and
# more informative than hashing 756 blocks individually.
DIFF_OUT=$(cmp -l "$TMP" "$ISO" 2>/dev/null | head -200000)
NDIFF=$(printf '%s\n' "$DIFF_OUT" | grep -c . || true)
if (( NDIFF >= 200000 )); then
    echo "    more than 200000 bytes differ - the image did not land correctly"
    DIFFBLOCKS=999
else
    echo "    differing bytes: $NDIFF"
    if (( NDIFF > 0 )); then
        BLOCKS=$(printf '%s\n' "$DIFF_OUT" | awk '{print int(($1-1)/1048576)}' | sort -un | tr '\n' ' ')
        echo "    affected 1 MiB blocks: $BLOCKS"
        FROMLBA=$(printf '%s\n' "$DIFF_OUT" | awk 'NR==1{print int(($1-1)/1048576)}')
        TOLBA=$(printf '%s\n' "$DIFF_OUT" | awk 'END{print int(($1-1)/1048576)}')
    fi
    DIFFBLOCKS=$NDIFF
fi

# The EFI System Partition from the ISO's own MBR: LBA 4116, 7360 sectors.
ESP_START=$(( 4116 * 512 )); ESP_END=$(( (4116 + 7360) * 512 ))
echo "    ISO EFI partition covers bytes $ESP_START .. $ESP_END"
echo
if (( NDIFF > 0 && NDIFF < 200000 )); then
    echo "  DIFFERS (localised) - see the byte offsets above."
    echo "  If they fall inside the EFI partition range, macOS wrote into the FAT ESP"
    echo "  (it mounts it read-write and drops .fseventsd/.Spotlight-V100 there). That"
    echo "  does not stop the stick booting, but reflash for a clean image:"
    echo "    sudo ./n100/make-usb.sh /dev/r$DEV"
else
    echo "  FAIL - the image did not land correctly. Reflash:"
    echo "    sudo ./n100/make-usb.sh /dev/r$DEV"
fi
rm -f "$TMP"
exit 1
