#!/bin/bash
#
# Bluetooth speaker button.
#
# Press it and it tells you what it is doing, from the first second to the last.
# Everything wrong with the earlier attempts came down to three ideas:
#
#   1. Never close a dialog and then work silently. A tap that makes the box
#      vanish and does nothing visible for 20 seconds reads as broken. A
#      pulsating window stays up for the whole operation and is closed by this
#      script when the work is really finished.
#   2. Never let a button say "OK" on a question. Every dialog here labels its
#      buttons with what they do: Connect, Scan, Pair, Clear it, Keep it, Done.
#   3. Never run a command without a limit. A "bluetoothctl remove" once sat for
#      74 seconds behind a "Connecting audio..." message. Queries are instant;
#      actions are capped.
#
# The saved speaker lives in /etc/boat-hifi-mac and survives reboots.

set -u

# --- single instance ------------------------------------------------------
# mkdir rather than flock: a dialog that outlives this script used to inherit the
# lock descriptor and lock the button out for good. A directory cannot be
# inherited, and a lock left by a crashed run is cleared automatically.
LOCKDIR=/tmp/bt-pair.lock.d
if [ -d "$LOCKDIR" ]; then
    # Only a live process that is not this one counts as a real run.
    # (pgrep on the script name matches this very process, which made every
    # press decide another run was active and quietly do nothing.)
    other=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "${other:-}" ] && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null; then
        exit 0
    fi
    rm -rf "$LOCKDIR"
fi
mkdir "$LOCKDIR" 2>/dev/null || exit 0
echo $$ >"$LOCKDIR/pid"

. /usr/local/bin/kiosk-launch.sh
kiosk_env

INTERACTIVE=1
[ "${BT_PAIR_NONINTERACTIVE:-0}" = "1" ] && INTERACTIVE=0

MACFILE=/etc/boat-hifi-mac
LOG=/var/log/bt-pair.log
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG" 2>/dev/null || true; }

# --- bounded calls --------------------------------------------------------
# "bluetoothctl --timeout N" makes even a query wait the full N seconds, which
# is why pairing used to take 40 s. Queries get no --timeout; actions do.
q() { timeout 8 bluetoothctl "$@" 2>/dev/null; }
act() { timeout 35 bluetoothctl "$@" 2>/dev/null; }

name_of() { q info "$1" | sed -n 's/^[[:space:]]*Name: //p' | head -1; }
is_paired() { q info "$1" | grep -qi 'Paired: yes'; }
underscored() { printf '%s' "$1" | tr 'a-z' 'A-Z' | tr ':' '_'; }

sink_index() {
    timeout 5 pactl list short sinks 2>/dev/null |
        awk -v m="$1" '{ n = toupper($2); if (index(n, m)) { print $1; exit } }'
}
speaker_working() { [ -n "$(sink_index "$(underscored "$1")")" ]; }

# --- dialogs --------------------------------------------------------------
PROGRESS_PID=""

# A pulsating window that stays until progress_end closes it.
#
# zenity --progress keeps an OK button even with --no-cancel, so a tap closed
# the box while the scan carried on invisibly - the "box just goes" complaint.
# --auto-close removes the buttons; the window lives as long as its input, which
# is a sleep here, and is killed when the work is done.
progress() { # text
    [ "$INTERACTIVE" = 1 ] || { echo "$1"; return 0; }
    progress_end
    ( sleep 120 ) | zenity --progress --title="Bluetooth speaker" --width=460 \
        --pulsate --auto-close --text="$1" 2>/dev/null 9>&- &
    PROGRESS_PID=$!
    sleep 0.4
    wlrctl window focus "app-id:zenity" >/dev/null 2>&1 || true
}

progress_end() {
    if [ -n "$PROGRESS_PID" ]; then
        kill "$PROGRESS_PID" 2>/dev/null || true
        wait "$PROGRESS_PID" 2>/dev/null || true
        PROGRESS_PID=""
    fi
}

# True while the progress window is still up. If the user pressed Cancel it is
# gone, and the long operation behind it must stop rather than carry on
# invisibly and pop a result box out of nowhere later.
progress_running() { [ -n "$PROGRESS_PID" ] && kill -0 "$PROGRESS_PID" 2>/dev/null; }

dialog() { # runs zenity, raising it above the fullscreen apps
    zenity "$@" 2>/dev/null &
    local pid=$!
    sleep 0.4
    wlrctl window focus "app-id:zenity" >/dev/null 2>&1 || true
    wait "$pid"
    return $?
}

info() {
    progress_end
    if [ "$INTERACTIVE" = 1 ]; then
        dialog --info --title="Bluetooth speaker" --width=460 \
            --ok-label="Done" --text="$1"
    else
        echo "$1"
    fi
    log "said: $(printf '%s' "$1" | tr '\n' ' ')"
}

ask_yes() { # text, ok-label, cancel-label
    progress_end
    [ "$INTERACTIVE" = 1 ] || return 1
    dialog --question --title="Bluetooth speaker" --width=460 \
        --ok-label="$2" --cancel-label="$3" --default-cancel --text="$1"
}

choose() { # text, ok-label, rows as "mac|label", echoes the mac
    progress_end
    [ "$INTERACTIVE" = 1 ] || return 1
    printf '%s\n' "$3" |
        dialog --list --title="Bluetooth speaker" --width=520 --height=260 \
            --ok-label="$2" --cancel-label="Cancel" \
            --column="MAC" --column="Speaker" --hide-column=1 --print-column=1 \
            --text="$1"
}

cleanup() { progress_end; rm -rf "$LOCKDIR"; }
trap cleanup EXIT INT TERM

# --- speaker list ---------------------------------------------------------
paired_audio() {
    q devices Paired | while read -r _ mac _rest; do
        local txt name state
        txt=$(q info "$mac")
        printf '%s' "$txt" | grep -qiE '^[[:space:]]*Icon: audio' || continue
        name=$(printf '%s' "$txt" | sed -n 's/^[[:space:]]*Name: //p' | head -1)
        state=""
        printf '%s' "$txt" | grep -qi 'Connected: yes' && state=" - connected"
        printf '%s|%s%s\n' "$mac" "${name:-$mac}" "$state"
    done
}

# --- actions --------------------------------------------------------------
connect_speaker() {
    local mac="$1" name idx moved=0 input
    name=$(name_of "$mac")
    log "connecting $mac"

    progress "Connecting to ${name:-$mac}..."

    act --timeout 5 power on >/dev/null
    if ! q info "$mac" | grep -qi 'Connected: yes'; then
        act --timeout 12 connect "$mac" >/dev/null
    fi
    if ! progress_running; then
        log "connect cancelled"
        exit 0
    fi

    for _ in 1 2 3 4 5 6; do
        idx=$(sink_index "$(underscored "$mac")")
        [ -n "$idx" ] && break
        sleep 1
    done

    if [ -z "$idx" ]; then
        progress_end
        log "no audio from $mac"
        return 1
    fi

    timeout 5 pactl set-default-sink "$idx" >/dev/null 2>&1
    # A default only affects new sounds, so anything already playing has to be
    # moved or it carries on coming out of the built-in speakers.
    for input in $(timeout 5 pactl list short sink-inputs 2>/dev/null | awk '{print $1}'); do
        timeout 5 pactl move-sink-input "$input" "$idx" >/dev/null 2>&1 && moved=$((moved + 1))
    done
    log "sink $idx default, moved $moved stream(s)"

    printf '%s\n' "$mac" | sudo tee "$MACFILE" >/dev/null
    progress_end
    info "Music now plays on ${name:-$mac}."
    return 0
}

forget_speaker() {
    local mac="$1" name
    name=$(name_of "$mac")
    progress "Forgetting ${name:-$mac}..."
    act --timeout 10 remove "$mac" >/dev/null
    if [ "$(cat "$MACFILE" 2>/dev/null | tr -d '[:space:]')" = "$mac" ]; then
        sudo rm -f "$MACFILE"
    fi
    log "forgot $mac"
    progress_end
    info "${name:-$mac} has been forgotten.
Press Bluetooth again when you want to pair it."
}

scan_and_pair() {
    local scan cands mac name target scanpid

    # Scanning is started in the background and watched, rather than blocking for
    # the full enquiry window. A speaker in pairing mode answers within a couple
    # of seconds, so the wait is as short as the speaker allows instead of a
    # fixed 20 s of nothing.
    progress "Looking for a speaker...

Put it into pairing mode. This takes a few seconds."

    scan=$(mktemp)
    act --timeout 25 scan bredr >"$scan" &
    scanpid=$!

    local waited=0 audio_found=0
    while [ "$waited" -lt 22 ]; do
        sleep 1
        waited=$((waited + 1))
        if ! progress_running; then
            kill "$scanpid" 2>/dev/null || true
            rm -f "$scan"
            log "scan cancelled after ${waited}s"
            exit 0
        fi
        for mac in $(grep -oE '\[NEW\] Device ([0-9A-Fa-f:]{17})' "$scan" 2>/dev/null |
            awk '{print $3}' | tr 'a-f' 'A-F' | sort -u); do
            if q info "$mac" | grep -qiE '^[[:space:]]*Icon: audio'; then
                audio_found=1
                break
            fi
        done
        [ "$audio_found" = 1 ] && break
    done

    kill "$scanpid" 2>/dev/null || true
    wait "$scanpid" 2>/dev/null || true
    log "scan finished after ${waited}s, audio device found: $audio_found"
    progress_end

    cands=$(mktemp)
    for mac in $(grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "$scan" |
        tr 'a-f' 'A-F' | sort -u); do
        q info "$mac" | grep -qiE '^[[:space:]]*Icon: audio' || continue
        name=$(name_of "$mac")
        printf '%s|%s\n' "$mac" "${name:-unknown}" >>"$cands"
    done
    rm -f "$scan"

    if [ ! -s "$cands" ]; then
        rm -f "$cands"
        info "No speaker answered.

Put the speaker into pairing mode - most only advertise for a couple of
minutes - then press Bluetooth again."
        return 1
    fi

    target=$(choose "Choose the speaker to pair." "Pair" "$(cat "$cands")")
    rm -f "$cands"
    [ -n "${target:-}" ] || return 0

    progress "Pairing with $(name_of "$target")..."
    log "pairing $target"
    act --timeout 25 pair "$target" >/dev/null
    if ! is_paired "$target"; then
        # A stale entry from the LE advertisement is the usual cause.
        log "retrying $target without its cache entry"
        act --timeout 10 remove "$target" >/dev/null
        sleep 2
        act --timeout 25 pair "$target" >/dev/null
    fi
    progress_end

    if ! is_paired "$target"; then
        info "Pairing did not complete.

Make sure the speaker is still in pairing mode, then try again."
        return 1
    fi

    act --timeout 10 trust "$target" >/dev/null
    connect_speaker "$target"
}

# --- main -----------------------------------------------------------------
MAC=$(cat "$MACFILE" 2>/dev/null | tr -d '[:space:]')

# Direct entry points, for testing and for running an action from a script:
#   BT_PAIR_ACTION=scan | connect:<mac> | forget:<mac>
case "${BT_PAIR_ACTION:-}" in
scan) scan_and_pair; exit $? ;;
connect:*) connect_speaker "${BT_PAIR_ACTION#connect:}"; exit $? ;;
forget:*) forget_speaker "${BT_PAIR_ACTION#forget:}"; exit $? ;;
esac

if [ "$INTERACTIVE" = 0 ]; then
    if [ -n "${MAC:-}" ] && speaker_working "$MAC"; then
        echo "connected and playing: $(name_of "$MAC")"
    else
        echo "not connected"
    fi
    exit 0
fi

if [ -n "${MAC:-}" ] && speaker_working "$MAC"; then
    name=$(name_of "$MAC")
    if ask_yes "${name:-$MAC} is connected.

Clear it? You will need to pair it again before it can be used." "Clear it" "Keep it"; then
        forget_speaker "$MAC"
    fi
    exit 0
fi

choice=$(choose "Which speaker?" "Select" "$(paired_audio)
SCAN|Scan for a new speaker...")
[ -n "${choice:-}" ] || exit 0

if [ "$choice" = "SCAN" ]; then
    scan_and_pair
else
    if ! connect_speaker "$choice"; then
        name=$(name_of "$choice")
        if ask_yes "${name:-$choice} did not answer.

Look for a different speaker?" "Look" "Cancel"; then
            scan_and_pair
        fi
    fi
fi
