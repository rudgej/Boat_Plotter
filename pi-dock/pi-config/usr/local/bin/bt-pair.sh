#!/bin/bash
#
# One-tap Bluetooth pairing for the boat speaker / hi-fi.
#
# Rewritten after the original failed on the N100 with "no BT found" every time.
# Three faults, all fixed here:
#
#  1. `bluetoothctl scan on > file` with no stdin. bluetoothctl reads stdin, so
#     end-of-file makes it quit at once and the file stays empty. That is what
#     produced "no device found" however long you waited. Fixed by driving the
#     scan with `bluetoothctl --timeout N scan`, which needs no stdin.
#
#  2. The old code took the FIRST MAC address it saw. A boat AP also sees
#     phones, televisions and fitness bands, so it could pair with a TV. Now
#     only devices BlueZ classifies as audio are offered, and a picker appears
#     if several answer.
#
#  3. BlueZ often caches a speaker from its LE advertisement and then tries to
#     pair over LE. An A2DP speaker is Classic (BR/EDR) only, so pairing fails
#     with "profile unavailable". Fixed by scanning `bredr`, and by clearing the
#     cache entry and retrying once if the first attempt fails.
#
# Audio also needs libspa-0.2-bluetooth installed, or PipeWire cannot present
# the speaker as a sink and the link dies with br-connection-profile-unavailable.
#
# Set BT_PAIR_NONINTERACTIVE=1 to run without zenity dialogs (for testing over
# ssh): messages go to stdout instead.

set -u

. /usr/local/bin/kiosk-launch.sh

INTERACTIVE=1
[ "${BT_PAIR_NONINTERACTIVE:-0}" = "1" ] && INTERACTIVE=0

say() {
    if [ "$INTERACTIVE" = 1 ]; then
        zenity --info --timeout=20 --text="$1" --title="BoatNetwork" --width=480 2>/dev/null
    else
        echo "$1"
    fi
}

warn() {
    if [ "$INTERACTIVE" = 1 ]; then
        zenity --warning --timeout=40 --text="$1" --title="BoatNetwork" --width=480 2>/dev/null
    else
        echo "WARN: $1" >&2
    fi
}

kiosk_env

# --- 1. an adapter at all -------------------------------------------------
# This box has two radios; bluetoothctl uses its default controller, which is
# the dual-mode one, so no explicit selection is needed for a one-shot command.
CTRL=$(bluetoothctl list 2>/dev/null | awk '/Controller/{print $2; exit}')
if [ -z "$CTRL" ]; then
    warn "No Bluetooth adapter found.
Check that the service is running:
  systemctl status bluetooth"
    exit 1
fi
bluetoothctl power on >/dev/null 2>&1

# --- 1a. already-known speaker: connect, no scan --------------------------
# Scanning is only needed the first time. A speaker that is already paired does
# not answer an inquiry, so the old script could never find it again - and
# pressing the button then paired with whatever else happened to be audible.
SAVED=$(tr -d '[:space:]' </etc/boat-hifi-mac 2>/dev/null || true)
if [ -n "${SAVED:-}" ]; then
    info=$(bluetoothctl info "$SAVED" 2>/dev/null)
    if printf '%s' "$info" | grep -qi 'Paired: yes'; then
        name=$(printf '%s' "$info" | sed -n 's/^[[:space:]]*Name: //p' | head -1)
        # Only connect when it is not already up: a needless connect blocks for
        # the full timeout and makes the button feel broken.
        if printf '%s' "$info" | grep -qi 'Connected: yes'; then
            say "Already connected to ${name:-$SAVED}."
        else
            say "Reconnecting to ${name:-$SAVED}..."
            bluetoothctl --timeout 15 connect "$SAVED" >/dev/null 2>&1 || true
        fi
        /usr/local/bin/bt-hifi-connect.sh
        exit 0
    fi
fi

# --- 2. scan, Classic only ------------------------------------------------
say "Put the speaker into pairing mode now.
Scanning for 25 seconds..."

SCAN=$(mktemp)
bluetoothctl --timeout 25 scan bredr >"$SCAN" 2>&1 || true

# --- 3. keep only audio devices ------------------------------------------
# BlueZ fills Icon from the device's Class of Device during discovery, so
# "audio-card" / "audio-headset" identifies speakers and headphones.
cands=""
for mac in $(grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$SCAN" |
    tr 'a-f' 'A-F' | sort -u); do
    [ "$mac" = "$(printf '%s' "$CTRL" | tr 'a-f' 'A-F')" ] && continue
    info=$(bluetoothctl info "$mac" 2>/dev/null)
    printf '%s' "$info" | grep -qiE '^[[:space:]]*Icon: audio' || continue
    name=$(printf '%s' "$info" | sed -n 's/^[[:space:]]*Name: //p' | head -1)
    cands="${cands}${mac}|${name:-unknown}
"
done
rm -f "$SCAN"

if [ -z "$cands" ]; then
    warn "No speaker found.
Only Bluetooth audio devices are offered.
Put the speaker in pairing mode and press Bluetooth again."
    exit 1
fi

# --- 4. choose ------------------------------------------------------------
count=$(printf '%s' "$cands" | grep -c .)
MAC=""
if [ "$count" -gt 1 ] && [ "$INTERACTIVE" = 1 ]; then
    choice=$(printf '%s' "$cands" |
        zenity --list --title="Pick a speaker" --width=520 --height=260 \
            --text="Several audio devices answered. The one in pairing mode is usually the newest." \
            --column="MAC" --column="Name" 2>/dev/null)
    MAC=$(printf '%s' "$choice" | awk '{print $1}')
else
    MAC=$(printf '%s' "$cands" | head -1 | cut -d'|' -f1)
fi
if [ -z "$MAC" ]; then
    warn "Nothing selected."
    exit 1
fi

# --- 5. pair, retrying once without the cache ----------------------------
pair_ok() {
    bluetoothctl info "$1" 2>/dev/null | grep -qi 'Paired: yes'
}

bluetoothctl --timeout 30 pair "$MAC" >/tmp/bt-pair.txt 2>&1 || true
if ! pair_ok "$MAC"; then
    # A stale LE-only cache entry is the usual cause: drop it and try again.
    bluetoothctl remove "$MAC" >/dev/null 2>&1
    sleep 2
    bluetoothctl --timeout 30 pair "$MAC" >/tmp/bt-pair.txt 2>&1 || true
fi

if ! pair_ok "$MAC"; then
    warn "Could not pair with $MAC.
Keep the speaker in pairing mode and try again.
Details are in /tmp/bt-pair.txt"
    exit 1
fi

bluetoothctl --timeout 10 trust "$MAC" >/dev/null 2>&1
echo "$MAC" | sudo tee /etc/boat-hifi-mac >/dev/null

say "Paired with $MAC.
Connecting audio..."

/usr/local/bin/bt-hifi-connect.sh

say "Ready. Music will play on the speaker."
