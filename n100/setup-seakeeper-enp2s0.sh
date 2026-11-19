#!/bin/bash
# Direct Seakeeper link on enp2s0.
#
# The assumed Seakeeper IP is 172.16.102.1 (from seakeeper-esp/SETUP.md 5, the
# ChatGPT assumption the ESP32 bridge was also built around). The bridge used
# 172.16.102.254/24 as its downlink, so the box uses the same address here: the
# Seakeeper sees the same subnet it was pre-configured for, and the bridge and a
# direct cable are interchangeable.
#
# never-default: enp2s0 must never become the internet route (wlp3s0/enp4s0 are).
set -uo pipefail

CON=seakeeper
ADDR=172.16.102.254/24

if nmcli -t -f NAME con show | grep -qx "$CON"; then
    echo "connection '$CON' already exists - showing it"
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
