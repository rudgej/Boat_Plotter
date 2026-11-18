#!/usr/bin/env bash
# Create the BoatNetwork access point on the USB Wi-Fi adapter.
#
# The N100's onboard card (RTL8821CE) reports no concurrent interface
# combinations, so it cannot be a station and an AP at the same time. The
# onboard card therefore stays free for the internet uplink (Starlink /
# Bossywifi) and the USB adapter carries the AP that the Shelly devices and
# on-board sensors join.
#
# The passphrase is deliberately NOT stored in this repository. Pass it in:
#
#   sudo PASS='...' ./n100/setup-boatnetwork.sh
#
# Re-running the script is safe; it replaces the existing connection.
set -euo pipefail

SSID="${SSID:-BoatNetwork}"
# Must match the Pi's old BoatNetwork subnet: the Shelly devices are configured
# with static 192.168.10.x addresses and would otherwise be unreachable.
AP_ADDR="${AP_ADDR:-192.168.10.1/24}"
DHCP_RANGE="${DHCP_RANGE:-192.168.10.100,192.168.10.200}"
CHANNEL="${CHANNEL:-6}"

if [ -z "${PASS:-}" ]; then
    echo "ERROR: PASS is not set. Usage: sudo PASS='<passphrase>' $0" >&2
    exit 1
fi

# Locate the USB adapter rather than the onboard card. USB netdevs report
# driver "usb" (the interface driver is on the child node), so match on the
# sysfs path instead of the driver name. Override with AP_IF=<ifname>.
find_ap_if() {
    local dev real
    for dev in /sys/class/net/wl*; do
        [ -e "$dev" ] || continue
        real=$(readlink -f "$dev/device" 2>/dev/null || true)
        case "$real" in
            */usb*) basename "$dev"; return 0 ;;
        esac
    done
    return 1
}

if [ -n "${AP_IF:-}" ]; then
    echo "==> AP interface (forced): $AP_IF"
else
    AP_IF=$(find_ap_if) || {
        echo "ERROR: no USB Wi-Fi interface found." >&2
        echo "       Is the adapter plugged in and its DKMS module loaded?" >&2
        exit 1
    }
    echo "==> AP interface: $AP_IF"
fi

# NetworkManager starts its own dnsmasq per shared connection. The standalone
# Debian dnsmasq normally owns 0.0.0.0:53 and makes that bind fail with
# "Address already in use", which aborts the whole AP activation.
if systemctl list-unit-files dnsmasq.service >/dev/null 2>&1; then
    systemctl disable --now dnsmasq 2>/dev/null || true
    systemctl mask dnsmasq 2>/dev/null || true
    echo "==> standalone dnsmasq masked (NetworkManager provides DHCP/DNS)"
fi

# hostapd is only needed by the Pi implementation; here NetworkManager drives
# the AP and a competing hostapd would fight it for the interface.
if systemctl list-unit-files hostapd.service >/dev/null 2>&1; then
    systemctl disable --now hostapd 2>/dev/null || true
    systemctl mask hostapd 2>/dev/null || true
    echo "==> hostapd masked (NetworkManager owns the AP)"
fi

nmcli connection delete "$SSID" >/dev/null 2>&1 || true
nmcli connection add type wifi ifname "$AP_IF" con-name "$SSID" ssid "$SSID" >/dev/null
nmcli connection modify "$SSID" \
    802-11-wireless.mode ap \
    802-11-wireless.band bg \
    802-11-wireless.channel "$CHANNEL" \
    802-11-wireless.powersave 2 \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "$PASS" \
    wifi-sec.proto rsn \
    wifi-sec.pairwise ccmp \
    wifi-sec.group ccmp \
    ipv4.method shared \
    ipv4.addresses "$AP_ADDR" \
    ipv4.shared-dhcp-range "$DHCP_RANGE" \
    ipv6.method ignore \
    connection.autoconnect yes

nmcli connection up "$SSID"
echo "==> $SSID is up on $AP_IF ($AP_ADDR)"
ip -br addr show "$AP_IF"
