#!/bin/bash
#
# Put the N100 payload on a USB stick as plain files.  RUN ON THE MAC, with sudo.
#
#   sudo ./n100/make-payload-usb.sh /dev/rdisk7
#
# ERASES the stick and formats it FAT32 (label PAYLOAD), then copies the kit:
# repo tarball, offline wheels, rclone deb, FIRST-STEPS, SHA256SUMS.
# Any size from 128 MB up is plenty - the payload is ~70 MB.
#
# Needed because the installer stick is a raw ISO image and cannot also hold
# files. This stick is read on the N100 after Debian is installed.
#
set -euo pipefail

STAGE="$HOME/Downloads/n100-staging"
die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo:  sudo $0 ${1:-/dev/rdiskN}"
[[ -n "${1:-}" ]] || die "usage: sudo $0 /dev/rdiskN   (see 'diskutil list')"
[[ -d "$STAGE" ]] || die "staging folder not found: $STAGE"

DEV="${1#/dev/}"; DEV="${DEV#r}"
[[ "$DEV" =~ ^disk[0-9]+$ ]] || die "target must be a whole disk like /dev/rdiskN, not a partition"

echo "==> checking $DEV"
INFO="$(diskutil info "/dev/$DEV")"
grep -q "Removable Media:.*Removable" <<<"$INFO" || die "/dev/$DEV is not removable - refusing"
SIZE_B=$(sed -n 's/.*Disk Size:.*(\([0-9][0-9]*\) Bytes).*/\1/p' <<<"$INFO")
[[ -n "$SIZE_B" ]] || die "could not read size of /dev/$DEV"
if (( SIZE_B < 50000000 )); then die "/dev/$DEV is too small for the ~70 MB payload"; fi
if (( SIZE_B > 256000000000 )); then die "/dev/$DEV is $((SIZE_B/1000000000)) GB - that looks like a real drive"; fi
ROOTDEV="$(diskutil info / | sed -n 's/.*Part of Whole: *//p')"
[[ "$ROOTDEV" != "$DEV" ]] || die "/dev/$DEV is the boot disk"

echo; diskutil info "/dev/$DEV" | grep -E "Device / Media Name|Volume Name|Disk Size|Removable"
echo
echo "This will ERASE /dev/$DEV and copy the payload from:"
echo "  $STAGE"
read -r -p "Type ERASE to continue: " REPLY
[[ "$REPLY" == "ERASE" ]] || die "aborted"

echo "==> formatting FAT32 as PAYLOAD"
diskutil eraseDisk FAT32 PAYLOAD MBRFormat "/dev/$DEV" >/dev/null || die "eraseDisk failed"
sleep 2

VOL="/Volumes/PAYLOAD"
[[ -d "$VOL" ]] || die "volume did not mount at $VOL"

echo "==> copying payload"
mkdir -p "$VOL/offline"
AVAIL_KB=$(df -k "$VOL" | awk 'NR==2 {print $4}')
ISO_BYTES=$(stat -f%z "$STAGE"/debian-*.iso 2>/dev/null || echo 0)
if (( AVAIL_KB * 1024 >= ISO_BYTES + 100000000 )); then
    echo "    space for the ISO too - copying it"
    cp "$STAGE"/debian-*.iso "$VOL/"
else
    echo "    not enough room for the 756 MB ISO - payload only (that's expected)"
fi
cp    "$STAGE"/Boat_Plotter-*.tar.gz "$VOL/"
cp    "$STAGE"/FIRST-STEPS.txt "$STAGE"/SHA256SUMS "$VOL/"
cp -R "$STAGE"/offline/wheels     "$VOL/offline/" 2>/dev/null || true
cp -R "$STAGE"/offline/debs       "$VOL/offline/" 2>/dev/null || true

sync
echo "==> verifying"
( cd "$VOL" && shasum -a 256 -c SHA256SUMS 2>/dev/null | grep -v "^./debian" || true )
echo
echo "Contents:"; ls -1 "$VOL"
echo; du -sh "$VOL"
echo
echo "==> ejecting"; diskutil eject "/dev/$DEV" || true
echo
echo "Done. On the N100 after Debian is installed:"
echo "  mount the stick, then:  tar xzf /media/*/Boat_Plotter-*.tar.gz"
