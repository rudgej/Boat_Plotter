#!/bin/bash
#
# Bluetooth button. Approved flow:
#
#   1. Press the button.
#   2. If something is connected: "Connected to X. Remove it?" [Remove] [Cancel].
#      Cancel changes nothing.
#   3. On Remove, the search starts immediately - in a window that is on screen
#      the whole time, showing progress.
#   4. Every device found is listed. No filtering.
#   5. Choose one: it pairs, connects, and the audio is routed to it.
#   6. "Done."
#
# Rules:
#   - A window never closes itself. It closes when Cancel is pressed or when the
#     step finishes.
#   - Nothing runs without a window on screen, so a press never produces silence.
#   - No other program's windows are touched.
#
set -u

. /usr/local/bin/kiosk-launch.sh
kiosk_env

TITLE="Bluetooth speaker"

# Every dialog goes through this. Apps here run fullscreen, and a dialog that
# opens behind Spotify looks frozen: the click lands on Spotify instead, so
# "Close" appears to do nothing. zenity stays in the foreground so its input
# still works; a detached helper raises the window once it exists.
show() {
    ( sleep 0.6; wlrctl window focus "app-id:zenity" >/dev/null 2>&1 ) >/dev/null 2>&1 &
    zenity "$@"
}

# Take sole control. Two presses used to leave two runs fighting: the older one
# kept a "No devices found" box on screen, and its bluetoothctl remove could
# delete the device the newer run was trying to connect to. Pressing the button
# again now ends the previous run and its dialogs, then starts fresh.
LOCKFILE=/tmp/bt-pair.pid
if [ -f "$LOCKFILE" ]; then
    OLD=$(cat "$LOCKFILE" 2>/dev/null || true)
    if [ -n "${OLD:-}" ] && [ "$OLD" != "$$" ] && kill -0 "$OLD" 2>/dev/null; then
        # Its dialogs first, then the script itself.
        ps -eo pid,ppid | awk -v p="$OLD" '$2 == p { print $1 }' |
            while read -r z; do kill -9 "$z" 2>/dev/null; done
        kill -9 "$OLD" 2>/dev/null
        sleep 0.3
    fi
fi
echo $$ >"$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

# Any dialog of ours left by a run that already died. Safe to match on the
# title here: this script's own command line does not contain it.
for zpid in $(pgrep -f -- "--title=$TITLE" 2>/dev/null || true); do
    kill -9 "$zpid" 2>/dev/null || true
done

# A window that stays up while work runs. It is closed by this script when the
# work ends, or by the user pressing Cancel - never on a timer.
#
# The input is a pipe this script owns (fd 8), not "( sleep 300 ) | zenity":
# with a pipeline, waiting for the window waited on the feeder instead and the
# whole run sat there for five minutes with nothing on screen.
PROGRESS_PID=""
PROGRESS_PIPE=""
start_progress() {
    PROGRESS_PIPE="/tmp/bt-prog.$$"
    rm -f "$PROGRESS_PIPE"
    mkfifo "$PROGRESS_PIPE" || return 0
    zenity --progress --title="$TITLE" --width=460 --pulsate --auto-close \
        --text="$1" <"$PROGRESS_PIPE" 2>/dev/null &
    PROGRESS_PID=$!
    exec 8>"$PROGRESS_PIPE"
    ( sleep 0.5; wlrctl window focus "app-id:zenity" >/dev/null 2>&1 ) >/dev/null 2>&1 &
}

stop_progress() {
    if [ -n "$PROGRESS_PIPE" ]; then
        exec 8>&-
        rm -f "$PROGRESS_PIPE"
        PROGRESS_PIPE=""
    fi
    if [ -n "$PROGRESS_PID" ]; then
        wait "$PROGRESS_PID" 2>/dev/null || true
        PROGRESS_PID=""
    fi
}

# True while the window is up. False means the user pressed Cancel.
progress_alive() { [ -n "$PROGRESS_PID" ] && kill -0 "$PROGRESS_PID" 2>/dev/null; }

cmd() { timeout 35 bluetoothctl "$@" 2>/dev/null; }

# Queries must NOT use "bluetoothctl --timeout N": that makes even a lookup wait
# the full N seconds. Building the list with "--timeout 5 info" per device cost
# 5 s each, so the box vanished and the list appeared 30-40 s later.
q() { timeout 6 bluetoothctl "$@" 2>/dev/null; }

# --- 2. already connected? ------------------------------------------------
CONNECTED=$(timeout 8 bluetoothctl devices Connected 2>/dev/null | head -1)
if [ -n "$CONNECTED" ]; then
    C_MAC=$(printf '%s' "$CONNECTED" | awk '{print $2}')
    C_NAME=$(printf '%s' "$CONNECTED" | cut -d' ' -f3-)

    show --question --title="$TITLE" --width=460 --ok-label="Remove" \
        --cancel-label="Cancel" \
        --text="Connected to $C_NAME.

Remove it and pair another device?" 2>/dev/null
    [ $? -eq 0 ] || exit 0

    timeout 15 bluetoothctl remove "$C_MAC" >/dev/null 2>&1
fi

# --- 3. wait for the user to say the device is in pairing mode -----------
# Nothing is searched until Start is pressed, so the device is in pairing mode
# at the right moment. Searching the instant Remove was pressed is why devices
# were never found.
show --question --title="$TITLE" --width=460 --ok-label="Start" \
    --cancel-label="Cancel" --default-cancel \
    --text="Put the device into pairing mode.

Press Start to begin the search." 2>/dev/null
[ $? -eq 0 ] || exit 0

# --- 3b. search, with the window on screen the whole time ----------------
SCAN=$(mktemp)
start_progress "Searching for devices in pairing mode...

This window stays until the search finishes."

cmd --timeout 15 scan bredr >"$SCAN" &
SCAN_PID=$!

while kill -0 "$SCAN_PID" 2>/dev/null; do
    if ! progress_alive; then
        # Cancel was pressed: stop searching and leave everything as it was.
        kill "$SCAN_PID" 2>/dev/null || true
        rm -f "$SCAN"
        exit 0
    fi
    sleep 0.5
done
wait "$SCAN_PID" 2>/dev/null || true

# --- 4. list everything found --------------------------------------------
# The progress window stays up until this list is ready, so the screen never
# goes blank between the search ending and the list appearing.
#
# A device BlueZ already knows about is reported as "[CHG] Device ..." rather
# than "[NEW] Device ...", so matching only NEW found nothing when the speaker
# was already in the cache. Any "Device <mac>" line counts.
ROWS=$(mktemp)
grep -oE 'Device ([0-9A-Fa-f:]{17})' "$SCAN" 2>/dev/null |
    awk '{ print $2 }' | tr 'a-f' 'A-F' | sort -u |
    while read -r mac; do
        printf '%s\t%s\n' "$mac" "$(q info "$mac" |
            sed -n 's/^[[:space:]]*Name: //p' | head -1 | grep . || echo "$mac")"
    done >"$ROWS"
rm -f "$SCAN"
stop_progress

if [ ! -s "$ROWS" ]; then
    rm -f "$ROWS"
    show --info --title="$TITLE" --width=460 --ok-label="Close" \
        --text="No devices found.

Put the speaker into pairing mode and press Bluetooth again." 2>/dev/null
    exit 1
fi

LIST=$(mktemp)
cut -f2 "$ROWS" >"$LIST"
CHOSEN=$(show --list --title="$TITLE" --width=520 --height=320 \
    --ok-label="Connect" --cancel-label="Cancel" --column="Device" \
    --text="Choose the device to connect." <"$LIST" 2>/dev/null)
rm -f "$LIST"
[ -n "${CHOSEN:-}" ] || { rm -f "$ROWS"; exit 0; }

TARGET=$(awk -F'\t' -v n="$CHOSEN" '$2 == n { print $1; exit }' "$ROWS")
rm -f "$ROWS"
[ -n "$TARGET" ] || exit 1

# --- 5. pair, connect, route the audio -----------------------------------
start_progress "Connecting to $CHOSEN..."

# "bluetoothctl --timeout N" blocks for the full N seconds even when the
# command succeeds (measured: --timeout 10 takes 10,030 ms, without it 17 ms).
# Written as pair --timeout 20 then trust --timeout 8 then connect, that left a
# 28-second gap between pairing and connecting - and in that gap the speaker
# leaves pairing mode and refuses the connection, so it only ever connected if
# you put it back into pairing mode by hand.
#
# Instead: start pairing, wait only until the bond actually exists, then connect
# straight away.
timeout 25 bluetoothctl pair "$TARGET" >/dev/null 2>&1 &
for _ in $(seq 1 25); do
    q info "$TARGET" | grep -qi 'Paired: yes' && break
    sleep 1
done
timeout 10 bluetoothctl trust "$TARGET" >/dev/null 2>&1

if ! q info "$TARGET" | grep -qi 'Paired: yes'; then
    stop_progress
    show --info --title="$TITLE" --width=460 --ok-label="Close" \
        --text="Could not pair with $CHOSEN.

Put it into pairing mode and press Bluetooth again." 2>/dev/null
    exit 1
fi

timeout 20 bluetoothctl connect "$TARGET" >/dev/null 2>&1 &

# The audio output does not exist the instant connect is issued: A2DP is still
# negotiating. Checking once immediately is why a working speaker was reported
# as "has not offered an audio output" and then started playing later.
MAC_U=$(printf '%s' "$TARGET" | tr 'a-z' 'A-Z' | tr ':' '_')
IDX=""
for _ in $(seq 1 15); do
    IDX=$(pactl list short sinks 2>/dev/null |
        awk -v m="$MAC_U" '{ n = toupper($2); if (index(n, m)) { print $1; exit } }')
    [ -n "$IDX" ] && break
    sleep 1
done

if [ -n "${IDX:-}" ]; then
    pactl set-default-sink "$IDX" >/dev/null 2>&1
    for input in $(pactl list short sink-inputs 2>/dev/null | awk '{print $1}'); do
        pactl move-sink-input "$input" "$IDX" >/dev/null 2>&1
    done
fi
stop_progress

# --- 6. done -------------------------------------------------------------
if [ -n "${IDX:-}" ]; then
    show --info --title="$TITLE" --width=460 --ok-label="Done" \
        --text="Done.
$CHOSEN is connected and the audio is on it." 2>/dev/null
else
    show --info --title="$TITLE" --width=460 --ok-label="Done" \
        --text="Done.
$CHOSEN is paired, but it has not offered an audio output.

Switch it on or wake it, then press Bluetooth again." 2>/dev/null
fi
