#!/usr/bin/env bash
# Install the out-of-tree driver for the AIC8800D80 USB Wi-Fi adapter.
#
# Debian 13 ships no driver for this chipset, so the BrosTrend AX900
# (368b:8d83) enumerates but never creates a wlan interface. The adapter is
# used for the BoatNetwork AP; the onboard RTL8821CE stays free for the
# internet uplink.
#
# Notes on why this specific source tree:
#   * a69c:8d80 is only the firmware-download stage. After aic_load_fw runs it
#     re-enumerates as 368b:8d83, which older trees (including Radxa's) do not
#     know about at all - they fail with "failed with errno 0".
#   * This tree defines USB_PRODUCT_ID_AIC8800M80_CUS1 0x8D83 in
#     drivers/aic8800/aic8800_fdrv/aicwf_usb.h, so the ID is handled natively.
#   * The firmware search path is /lib/firmware/aic8800D80 (no prefix). Radxa's
#     tree looks in the same place but its package installs elsewhere, which
#     silently yields "wrong size of firmware file".
#
# DKMS is used so the module is rebuilt on kernel upgrades.
set -euo pipefail

REPO="${REPO:-https://github.com/shenmintao/aic8800d80}"
SRC="${SRC:-/usr/local/src/aic8800d80}"

apt-get install -y dkms "linux-headers-$(uname -r)" git

# Stale firmware from a previous attempt makes the chip hang on boot.
rm -rf /lib/firmware/aic8800 /lib/firmware/aic8800_fw \
       /lib/firmware/aic8800D80 /lib/firmware/aic8800D80N \
       /lib/firmware/aic8800D80X2 /lib/firmware/aic8800DC \
       /lib/firmware/aic8800DLN

rm -rf "$SRC"
git clone --depth 1 "$REPO" "$SRC"
cd "$SRC"
./install.sh

# Both stages must be loaded: aic_load_fw handles the initial a69c:8d80
# firmware-download ID, aic8800_fdrv the post-firmware 368b:8d83 ID. udev
# autoloads them from the module aliases, but listing them here makes the
# ordering explicit and survives a dongle that appears late in boot.
printf 'aic_load_fw\naic8800_fdrv\n' >/etc/modules-load.d/aic8800.conf

echo
echo "==> Reloading modules"
modprobe -r aic8800_fdrv 2>/dev/null || true
modprobe aic8800_fdrv

sleep 5
if ls /sys/class/net/wl* >/dev/null 2>&1; then
    echo "==> Wi-Fi interfaces now present:"
    for d in /sys/class/net/wl*; do
        real=$(readlink -f "$d/device" 2>/dev/null || true)
        case "$real" in
            */usb*) echo "    $(basename "$d")  (USB - use for BoatNetwork AP)" ;;
            *)      echo "    $(basename "$d")  (PCI - onboard, use for uplink)" ;;
        esac
    done
else
    echo "WARNING: no wlan interface appeared - check dmesg | grep -i aic" >&2
    exit 1
fi
