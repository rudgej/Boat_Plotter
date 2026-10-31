#!/bin/bash
# Idempotent NAT/masquerade for BoatNetwork (192.168.10.0/24) out to the uplink.
nft delete table ip boatnetwork 2>/dev/null
nft add table ip boatnetwork
nft add chain ip boatnetwork postrouting '{ type nat hook postrouting priority srcnat; }'
nft add rule ip boatnetwork postrouting ip saddr 192.168.10.0/24 oifname != wlan1 masquerade
