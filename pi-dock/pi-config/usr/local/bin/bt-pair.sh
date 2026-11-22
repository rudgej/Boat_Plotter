#!/bin/bash
#
# Connect the boat's Bluetooth speaker. One speaker, remembered.
#
# Press the button:
#   - a speaker is remembered and paired  -> connect it and make it the default
#                                            audio output (about 5 s)
#   - nothing remembered, or the remembered one has gone from BlueZ
#                                         -> scan once, confirm, pair, remember
#
# The address lives in /etc/boat-hifi-mac and survives reboots. Deliberately no
# list of devices and no picker: on this boat the speaker is fitted once and
# does not change, and a list invites connecting to a phone that happens to be
# in range. To point it at a different speaker, either remove that file or let
# the saved one disappear - the button then looks for a new one by itself.
#
# Background, because each of these was a real failure on this box:
#
#  - bluetoothctl reads stdin, so "scan on > file" hit end-of-file and quit at
#    once, leaving an empty capture and a permanent "no speaker found". The scan
#    is driven with --timeout instead.
#  - A scan sees phones and televisions. Only devices BlueZ classifies as audio
#    are considered, and pairing asks first.
#  - BlueZ caches a speaker from its LE advertisement and then tries to pair
#    over LE, which an A2DP speaker cannot answer. Scan bredr only, and clear a
#    stale cache entry and retry once.
#  - Audio needs libspa-0.2-bluetooth, or PipeWire cannot offer the speaker as a
#    sink and the link dies with br-connection-profile-unavailable.
#
# BT_PAIR_NONINTERACTIVE=1 for use over ssh (no dialogs).

set -u

. /usr/local/bin/kiosk-launch.sh

INTERACTIVE=1
[ "${BT_PAIR_NONINTERACTIVE:-0}" = "1" ] && INTERACTIVE=0

MACFILE=/etc/boat-hifi-mac

say() {
    if [ "$INTERACTIVE" = 1 ]; then
        zenity --info --timeout=15 --text="$1" --title="BoatNetwork" --width=480 2>/dev/null
    else
        echo "$1"
    fi
}

warn() {
    if [ "$INTERACTIVE" = 1 ]; then
        zenity --warning --timeout=30 --text="$1" --title="BoatNetwork" --width=480 2>/dev/null
    else
        echo "WARN: $1" >&2
    fi
}

# One yes/no, so a television or a phone is never paired by accident.
confirm() {
    if [ "$INTERACTIVE" = 1 ]; then
        zenity --question --text="$1" --title="BoatNetwork" --width=480 2>/dev/null
        return $?
    fi
    return 0
}

bluetooth_on() {
    bluetoothctl power on >/dev/null 2>&1
}

info_of() { bluetoothctl info "$1" 2>/dev/null; }

is_paired() { info_of "$1" | grep -qi 'Paired: yes'; }
is_connected() { info_of "$1" | grep -qi 'Connected: yes'; }
name_of() { info_of "$1" | sed -n 's/^[[:space:]]*Name: //p' | head -1; }

connect_saved() {
    local mac="$1" name
    name=$(name_of "$mac")
    if is_connected "$mac"; then
        say "Already connected to ${name:-$mac}."
    else
        say "Connecting to ${name:-$mac}..."
        bluetoothctl --timeout 20 connect "$mac" >/dev/null 2>&1 || true
    fi
    /usr/local/bin/bt-hifi-connect.sh
}

# Scan, confirm, pair, remember.
pair_new() {
    say "Put the speaker into pairing mode now.
Scanning for 25 seconds..."

    local scan cands mac name
    scan=$(mktemp)
    bluetoothctl --timeout 25 scan bredr >"$scan" 2>&1 || true

    cands=$(mktemp)
    local found=0
    for mac in $(grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$scan" |
        tr 'a-f' 'A-F' | sort -u); do
        printf '%s' "$(info_of "$mac")" | grep -qiE '^[[:space:]]*Icon: audio' || continue
        name=$(name_of "$mac")
        printf '%s|%s\n' "$mac" "${name:-unknown}"
        found=1
    done >"$cands"
    rm -f "$scan"

    if [ "$found" = 0 ]; then
        warn "No speaker found.
Only Bluetooth audio devices are offered.
Put the speaker in pairing mode and press Bluetooth again."
        rm -f "$cands"
        return 1
    fi

    local target=""
    # Without a human to confirm, only pair a device that was named explicitly.
    # Left to itself this paired a Samsung television that happened to be in
    # range, which is exactly what the confirmation exists to prevent.
    if [ "$INTERACTIVE" = 0 ] && [ -z "${BT_PAIR_TARGET:-}" ]; then
        warn "Non-interactive and no BT_PAIR_TARGET given: refusing to pair blindly."
        rm -f "$cands"
        return 1
    fi
    while IFS='|' read -r mac name; do
        if [ "$INTERACTIVE" = 1 ]; then
            confirm "Pair with \"$name\"?
MAC $mac" || continue
        elif [ "$(printf '%s' "$mac" | tr 'a-f' 'A-F')" != "$(printf '%s' "$BT_PAIR_TARGET" | tr 'a-f' 'A-F')" ]; then
            continue
        fi
        target="$mac"
        break
    done <"$cands"
    rm -f "$cands"

    if [ -z "$target" ]; then
        warn "Nothing selected."
        return 1
    fi

    bluetoothctl --timeout 30 pair "$target" >/tmp/bt-pair.txt 2>&1 || true
    if ! is_paired "$target"; then
        # A stale LE-only cache entry is the usual cause: drop it and retry.
        bluetoothctl remove "$target" >/dev/null 2>&1
        sleep 2
        bluetoothctl --timeout 30 pair "$target" >/tmp/bt-pair.txt 2>&1 || true
    fi
    if ! is_paired "$target"; then
        warn "Could not pair with $target.
Keep the speaker in pairing mode and try again.
Details are in /tmp/bt-pair.txt"
        return 1
    fi

    bluetoothctl --timeout 10 trust "$target" >/dev/null 2>&1

    # Only remember a device that actually offers an audio output. A television
    # or a phone will pair happily and then never appear as a sink, so saving it
    # first would leave every later press trying to connect to the wrong thing.
    printf '%s\n' "$target" | sudo tee "$MACFILE" >/dev/null
    if /usr/local/bin/bt-hifi-connect.sh; then
        say "Ready. Music will play on $(name_of "$target" || echo "$target")."
    else
        sudo rm -f "$MACFILE"
        bluetoothctl remove "$target" >/dev/null 2>&1
        warn "$target paired but offered no audio output, so it has been forgotten.
Press Bluetooth again with the speaker in pairing mode."
        return 1
    fi
}

CTRL=$(bluetoothctl list 2>/dev/null | awk '/Controller/{print $2; exit}')
if [ -z "$CTRL" ]; then
    warn "No Bluetooth adapter found.
Check that the service is running:
  systemctl status bluetooth"
    exit 1
fi
bluetooth_on

MAC=$(tr -d '[:space:]' <"$MACFILE" 2>/dev/null || true)

if [ -n "${MAC:-}" ]; then
    if is_paired "$MAC"; then
        connect_saved "$MAC"
        exit 0
    fi
    # Remembered but no longer paired - pairing details lost, so start again.
    warn "The saved speaker ($MAC) is no longer paired with this box.
Looking for a new one."
    sudo rm -f "$MACFILE"
fi

pair_new
