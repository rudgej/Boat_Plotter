#!/bin/bash
#
# Keep one Bluetooth radio, with bonding actually enabled.
#
# TWO THINGS THIS FIXES
#
# 1. The AIC8800D80 USB stick provides the BoatNetwork access point (wlx…,
#    192.168.10.1) and also exposes a Bluetooth radio that was never wanted.
#    BlueZ makes one controller the default, so pairing sometimes went through
#    the dongle without anyone choosing it. The dongle also has no Bluetooth
#    address burned in and generates one - the locally-administered bit is set -
#    and bonds are stored per controller address, so a changing address cannot
#    hold a pairing.
#
# 2. The internal radio could not store a pairing, and this was the real fault:
#
#        Pairable: no   ->  current settings: powered ssp br/edr le secure-conn
#        Pairable: yes  ->  current settings: powered bondable ssp br/edr …
#
#    "bondable" is missing while the adapter is not pairable. With bonding off a
#    speaker pairs, plays, and no link key is written, so it is forgotten at
#    power-off. No device on this box had ever had a [LinkKey] saved, which is
#    what pointed at the adapter rather than at the speaker. Setting Pairable
#    through D-Bus turns bondable on; nothing else needs to be set.
#
# WHY PURE D-BUS
#
# btmgmt was used first and hung indefinitely when run as a systemd unit, which
# stalled the boot; so did "bluetoothctl power off" driven from a pipe, and
# "udevadm settle" waited its full 30 s timeout every start. busctl is a single
# D-Bus round trip, a few milliseconds, and cannot sit waiting for a terminal.
#
set -u

# The adapter objects appear once BlueZ has claimed the controllers, which can be
# slightly after this runs. Wait briefly for at least two, but never for long:
# the loop exits as soon as they are there.
for _ in $(seq 1 20); do
    n=$(busctl tree org.bluez --list 2>/dev/null | grep -c '/org/bluez/hci[0-9]*$')
    [ "$n" -ge 2 ] && break
    sleep 1
done

for path in $(busctl tree org.bluez --list 2>/dev/null | grep '/org/bluez/hci[0-9]*$'); do
    iface=${path##*/}          # hci0, hci1, …
    mac=$(busctl get-property org.bluez "$path" org.bluez.Adapter1 Address 2>/dev/null \
          | awk -F'"' '{print $2}')
    [ -n "$mac" ] || continue

    # Locally-administered bit (0x02) of the first octet: set means the address was
    # generated rather than burned in. Tested arithmetically - an earlier version
    # listed nibble values by hand and missed "B", so 0B:3B:… was kept by mistake.
    first_octet=$((16#$(printf '%s' "$mac" | cut -c1-2)))
    if [ $((first_octet & 2)) -ne 0 ]; then
        busctl set-property org.bluez "$path" org.bluez.Adapter1 Powered b false 2>/dev/null
        logger -t bt-one-radio "powered off $iface $mac (generated address, not the internal radio)"
    else
        # Pairable is the switch that enables bonding, and bonding is what makes
        # BlueZ write the link key. Without it a pairing does not survive.
        busctl set-property org.bluez "$path" org.bluez.Adapter1 Powered b true 2>/dev/null
        busctl set-property org.bluez "$path" org.bluez.Adapter1 Pairable b true 2>/dev/null
        logger -t bt-one-radio "keeping $iface $mac, pairable (bondable) on"
    fi
done
