#!/bin/bash
# Direct Seakeeper link on enp2s0.
#
# The Seakeeper is a DHCP client. Measured 2026-11-21: it answers on
# 192.168.0.2 (HTTP 80, SSH 22, MQTT-over-WebSocket 9001). The 172.16.102.x
# figure this script used to carry was a guess inherited from
# seakeeper-esp/SETUP.md and was never true. See seakeeper-link.md.
#
# never-default: enp2s0 must never become the internet route (wlp3s0/enp4s0 are).
set -uo pipefail

CON=seakeeper
# Measured 2026-11-21: the unit answers on 192.168.0.2, not 172.16.102.1.
# The 172.16.102.x figure was a guess recorded in seakeeper-esp/SETUP.md and
# inherited by everything downstream. See seakeeper-link.md.
ADDR=192.168.0.254/24

if nmcli -t -f NAME con show | grep -qx "$CON"; then
    # Update in place. Reporting "already exists" and doing nothing was a real
    # trap: the connection shipped with 172.16.102.254/24, so on a box that
    # already had it the script silently left the wrong subnet in place.
    echo "connection '$CON' exists - updating to $ADDR"
    sudo -n nmcli con mod "$CON" \
        connection.interface-name enp2s0 \
        ipv4.method manual \
        ipv4.addresses "$ADDR" \
        ipv4.gateway "" \
        ipv4.dns "" \
        ipv4.never-default yes \
        ipv6.method disabled \
        connection.autoconnect yes \
        connection.autoconnect-priority 50
else
    sudo -n nmcli con add type ethernet ifname enp2s0 con-name "$CON" \
        ipv4.method manual \
        ipv4.addresses "$ADDR" \
        ipv4.gateway "" \
        ipv4.dns "" \
        ipv4.never-default yes \
        ipv6.method disabled \
        connection.autoconnect yes \
        connection.autoconnect-priority 50
fi

echo
echo "=== definition ==="
sudo -n nmcli -f connection.id,connection.interface-name,connection.autoconnect,connection.autoconnect-priority,ipv4.method,ipv4.addresses,ipv4.never-default,ipv6.method con show "$CON"

echo
echo "=== enp2s0 state (DOWN is expected with no cable) ==="
ip -br addr show enp2s0
nmcli -f GENERAL.STATE dev show enp2s0 | head -2

echo
echo "=== routes unaffected? default must stay on wlp3s0/enp4s0 ==="
ip route | grep default
