#!/bin/bash
#
# Write the Debian installer to a USB stick.  RUN ON THE MAC, with sudo.
#
#   sudo ./n100/make-usb.sh /dev/rdisk6
#
# DESTROYS the target stick. Guardrails below refuse anything that looks wrong:
#  - must be a /dev/diskN that is removable
#  - must be between 1 GB and 64 GB
#  - must NOT be the boot disk
#  - requires the word ERASE typed back
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISO="$(ls -1 "$HOME/Downloads/n100-staging"/debian-*-amd64-netinst.iso 2>/dev/null | head -1)"
WANT_SHA="a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo:  sudo $0 ${1:-/dev/rdiskN}"
[[ -n "${1:-}" ]] || die "usage: sudo $0 /dev/rdiskN   (see 'diskutil list')"
[[ -n "$ISO" ]]   || die "ISO not found in ~/Downloads/n100-staging/"

DEV="${1#/dev/}"; DEV="${DEV#r}"          # normalise rdisk6 -> disk6
[[ "$DEV" =~ ^disk[0-9]+$ ]] || die "target must be a whole disk like /dev/rdiskN, not a partition"

echo "==> checking $DEV"
INFO="$(diskutil info "/dev/$DEV")"
grep -q "Removable Media:.*Removable" <<<"$INFO" || die "/dev/$DEV is not removable - refusing"
SIZE_B=$(sed -n 's/.*Disk Size:.*(\([0-9][0-9]*\) Bytes).*/\1/p' <<<"$INFO")
[[ -n "$SIZE_B" ]] || die "could not read size of /dev/$DEV"
if (( SIZE_B < 1000000000 )); then die "/dev/$DEV is $((SIZE_B/1000000)) MB - too small for a 756 MB ISO"; fi
if (( SIZE_B > 64000000000 )); then die "/dev/$DEV is $((SIZE_B/1000000000)) GB - that looks like a real drive"; fi

ROOTDEV="$(diskutil info / | sed -n 's/.*Part of Whole: *//p')"
[[ "$ROOTDEV" != "$DEV" ]] || die "/dev/$DEV is the boot disk"

echo
diskutil info "/dev/$DEV" | grep -E "Device / Media Name|Volume Name|Disk Size|Removable|File System"
echo
echo "This will ERASE /dev/$DEV and write:"
echo "  $ISO"
read -r -p "Type ERASE to continue: " REPLY
[[ "$REPLY" == "ERASE" ]] || die "aborted"

echo "==> verifying ISO"
ACTUAL="$(shasum -a 256 "$ISO" | awk '{print $1}')"
[[ "$ACTUAL" == "$WANT_SHA" ]] || die "ISO checksum mismatch: $ACTUAL"
echo "    ok"

echo "==> unmounting"
diskutil unmountDisk "/dev/$DEV" >/dev/null || true

echo "==> writing (this takes a few minutes)"
sudo dd if="$ISO" of="/dev/r$DEV" bs=4m status=progress || die "dd failed"
sync

echo "==> reading back and verifying (another minute)"
SRC_SHA="$(shasum -a 256 "$ISO" | awk '{print $1}')"
ISO_BYTES="$(stat -f%z "$ISO")"
# dd one block past the end, then truncate to the exact ISO length, so the
# hash covers exactly the image bytes. Guard against an empty read: hashing
# nothing yields e3b0c442... and would compare equal to another empty read.
DEV_SHA="$(dd if="/dev/r$DEV" bs=4m count=$(( ISO_BYTES / 4194304 + 1 )) 2>/dev/null \
           | head -c "$ISO_BYTES" | shasum -a 256 | awk '{print $1}')"
if [[ -z "$DEV_SHA" || "$DEV_SHA" == e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]]; then
    die "read-back returned no data - cannot confirm the write"
fi
if [[ "$DEV_SHA" != "$SRC_SHA" ]]; then
    echo "  source: $SRC_SHA"
    echo "  stick : $DEV_SHA"
    die "read-back mismatch - reflash, the stick may be failing"
fi
echo "    ok - stick matches the ISO byte-for-byte"

echo "==> ejecting"
diskutil eject "/dev/$DEV" || true

cat <<EOF

Done. /dev/$DEV now boots the Debian installer.

  On the N100: plug it in, power on, press F7/F11, choose the entry starting
  "UEFI:", then "Guided - use entire disk".

  The stick's own filesystem is replaced by the ISO, so the payload
  (repo tarball + offline wheels/debs) goes on the OTHER, smaller stick.
EOF
