#!/bin/bash
#
# Bluetooth speaker button.
#
# One press does one thing, and says what happened. The previous version was
# unusable for reasons that were entirely mine:
#
#  - every dialog had a --timeout, so message boxes closed themselves and then
#    popped up again later, apparently at random
#  - it showed several dialogs in a row with slow work between them (a 20 s
#    connect, a 25 s scan), so the message you saw had nothing to do with what
#    was happening
#  - pressing it again stacked another run on top, producing "failed to pair"
#    boxes minutes later
#  - and it never moved the audio stream, so a "successful" connect left the
#    music playing out of the built-in speakers
#
# Now: a single lock so only one run exists, one progress window while working,
# one result. No dialog closes itself. Audio is verified before success is
# claimed.
#
# The speaker is remembered in /etc/boat-hifi-mac and survives reboots.

set -u

# Only one press at a time. A second press while a dialog is open is ignored
# instead of starting a second scan behind the first.
LOCK=/tmp/bt-pair.lock
exec 9>"$LOCK" || exit 0
flock -n 9 || exit 0

. /usr/local/bin/kiosk-launch.sh

INTERACTIVE=1
[ "${BT_PAIR_NONINTERACTIVE:-0}" = "1" ] && INTERACTIVE=0

LOG=/var/log/bt-pair.log
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; }

MACFILE=/etc/boat-hifi-mac
ZPID=""

# A pulsating window while work happens. No timeout: it closes when the script
# closes it.
busy() {
    if [ "$INTERACTIVE" = 1 ]; then
        zenity --progress --title="Bluetooth speaker" --text="$1" \
            --pulsate --no-cancel --width=460 2>/dev/null &
        ZPID=$!
    else
        echo "$1"
    fi
}

idle() {
    if [ -n "$ZPID" ]; then
        kill "$ZPID" 2>/dev/null || true
        wait "$ZPID" 2>/dev/null || true
        ZPID=""
    fi
}

say() {
    idle
    if [ "$INTERACTIVE" = 1 ]; then
        zenity --info --title="Bluetooth speaker" --width=480 --text="$1" 2>/dev/null
    else
        echo "$1"
    fi
    log "showed: $(printf '%s' "$1" | tr '\n' ' ')"
}

ask() {
    idle
    if [ "$INTERACTIVE" = 1 ]; then
        zenity --question --title="Bluetooth speaker" --width=480 --text="$1" 2>/dev/null
        return $?
    fi
    return 1
}

name_of() { bluetoothctl info "$1" 2>/dev/null | sed -n 's/^[[:space:]]*Name: //p' | head -1; }
is_paired() { bluetoothctl info "$1" 2>/dev/null | grep -qi 'Paired: yes'; }

CTRL=$(bluetoothctl list 2>/dev/null | awk '/Controller/{print $2; exit}')
if [ -z "$CTRL" ]; then
    say "No Bluetooth adapter on this box."
    exit 1
fi
bluetoothctl power on >/dev/null 2>&1

# --- try the remembered speaker ------------------------------------------
connect_remembered() {
    local mac="$1" name
    name=$(name_of "$mac")
    busy "Connecting to ${name:-$mac}...
This takes a few seconds."

    if /usr/local/bin/bt-hifi-connect.sh >/dev/null 2>&1; then
        say "${name:-$mac} is connected and playing.
Music now comes out of it."
        return 0
    fi

    log "connect failed for $mac"
    idle
    if ask "${name:-$mac} did not answer.

Look for a different speaker instead?"; then
        return 2
    fi
    return 1
}

# --- find and pair a new speaker -----------------------------------------
pair_new() {
    busy "Put the speaker into pairing mode.

Looking for it now - about 20 seconds..."

    local scan cands mac name found
    scan=$(mktemp)
    bluetoothctl --timeout 20 scan bredr >"$scan" 2>&1 || true

    cands=$(mktemp)
    found=0
    for mac in $(grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$scan" |
        tr 'a-f' 'A-F' | sort -u); do
        [ "$mac" = "$(printf '%s' "$CTRL" | tr 'a-f' 'A-F')" ] && continue
        bluetoothctl info "$mac" 2>/dev/null | grep -qiE '^[[:space:]]*Icon: audio' || continue
        name=$(name_of "$mac")
        printf '%s|%s\n' "$mac" "${name:-unknown}" >>"$cands"
        found=1
    done
    rm -f "$scan"

    if [ "$found" = 0 ]; then
        say "No speaker answered.

Only Bluetooth audio devices are offered, so a phone or a television will not
appear here. Put the speaker into pairing mode and press Bluetooth again."
        rm -f "$cands"
        return 1
    fi

    local target=""
    while IFS='|' read -r mac name; do
        if [ "$INTERACTIVE" = 1 ]; then
            ask "Pair with \"$name\"?" || continue
        elif [ -z "${BT_PAIR_TARGET:-}" ] ||
            [ "$(printf '%s' "$mac" | tr 'a-f' 'A-F')" != "$(printf '%s' "$BT_PAIR_TARGET" | tr 'a-f' 'A-F')" ]; then
            continue
        fi
        target="$mac"
        break
    done <"$cands"
    rm -f "$cands"

    if [ -z "$target" ]; then
        say "Nothing was paired."
        return 1
    fi

    busy "Pairing with $(name_of "$target")...
This takes a few seconds."

    log "pairing $target"
    bluetoothctl --timeout 30 pair "$target" >/dev/null 2>&1 || true
    if ! is_paired "$target"; then
        # A stale cache entry from the LE advertisement is the usual cause.
        log "pair failed, clearing cache and retrying"
        bluetoothctl remove "$target" >/dev/null 2>&1
        sleep 2
        bluetoothctl --timeout 30 pair "$target" >/dev/null 2>&1 || true
    fi
    if ! is_paired "$target"; then
        say "Pairing failed.

Make sure the speaker is still in pairing mode - most stop advertising after
a couple of minutes - then press Bluetooth again."
        return 1
    fi

    bluetoothctl --timeout 10 trust "$target" >/dev/null 2>&1

    # Only keep it if it actually plays. A television pairs happily and then
    # offers no audio, and remembering it would break every later press.
    printf '%s\n' "$target" | sudo tee "$MACFILE" >/dev/null
    busy "Connecting the audio..."
    if /usr/local/bin/bt-hifi-connect.sh >/dev/null 2>&1; then
        say "Paired with $(name_of "$target").
Music now comes out of it."
        return 0
    fi

    sudo rm -f "$MACFILE"
    bluetoothctl remove "$target" >/dev/null 2>&1
    say "$(name_of "$target") paired but offered no audio, so it has been
forgotten.

If that was the right speaker, check it is switched on and awake."
    return 1
}

# --- decide what to do ---------------------------------------------------
MAC=$(tr -d '[:space:]' <"$MACFILE" 2>/dev/null || true)

if [ -n "${MAC:-}" ]; then
    if is_paired "$MAC"; then
        connect_remembered "$MAC"
        case $? in
        0) exit 0 ;;
        2) pair_new; exit $? ;;
        *) exit 1 ;;
        esac
    fi
    log "saved speaker $MAC is no longer paired; forgetting it"
    sudo rm -f "$MACFILE"
fi

pair_new
exit $?
