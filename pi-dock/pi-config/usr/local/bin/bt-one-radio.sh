#!/bin/bash
#
# Turn off Bluetooth on the Wi-Fi dongle. Its Wi-Fi is left alone.
#
# The AIC8800D80 USB stick provides the BoatNetwork access point (wlx…,
# 192.168.10.1). The same chip also exposes a Bluetooth radio, which is not why
# it was fitted. Two problems came from leaving that radio on:
#
#   * BlueZ makes one controller the default. Which one that is depends on
#     enumeration order, so pairing sometimes happened through the dongle
#     without anyone choosing it.
#   * The dongle has no Bluetooth address burned in, so it generates one - the
#     locally-administered bit is set. Bonding records are stored per controller
#     address (/var/lib/bluetooth/<controller>/<device>/), so a radio whose
#     address can change cannot hold a pairing.
#
# The controller to keep is the one with a real hardware address; anything with
# a generated address is switched off. That test is used rather than hard-coding
# a MAC, because the generated one can differ from boot to boot.
#
set -u

for mac in $(bluetoothctl list 2>/dev/null | awk '/^Controller/ { print $2 }'); do
    # Locally-administered bit (0x02) of the first octet: set means the address is
    # generated rather than burned in. Tested arithmetically - an earlier version
    # listed nibble values by hand and missed "B", so 0B:3B:… was kept by mistake.
    first_octet=$((16#$(printf '%s' "$mac" | cut -c1-2)))
    if [ $((first_octet & 2)) -ne 0 ]; then
        printf 'select %s\npower off\nquit\n' "$mac" | bluetoothctl >/dev/null 2>&1
        logger -t bt-one-radio "powered off $mac (generated address, not the internal radio)"
    else
        logger -t bt-one-radio "keeping $mac (hardware address)"
    fi
done
