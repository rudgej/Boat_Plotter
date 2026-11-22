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

# Close only windows this script left behind itself, from a run that died.
for zpid in $(pgrep -f -- "--title=$TITLE" 2>/dev/null || true); do
    zppid=$(ps -o ppid= -p "$zpid" 2>/dev/null | tr -d ' ')
    [ -z "$zppid" ] && continue
    if ! ps -o args= -p "$zppid" 2>/dev/null | grep -q 'bt-pair\.sh'; then
        kill -9 "$zpid" 2>/dev/null || true
    fi
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

# --- 2. already connected? ------------------------------------------------
CONNECTED=$(timeout 8 bluetoothctl devices Connected 2>/dev/null | head -1)
if [ -n "$CONNECTED" ]; then
    C_MAC=$(printf '%s' "$CONNECTED" | awk '{print $2}')
    C_NAME=$(printf '%s' "$CONNECTED" | cut -d' ' -f3-)

    zenity --question --title="$TITLE" --width=460 --ok-label="Remove" \
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
zenity --question --title="$TITLE" --width=460 --ok-label="Start" \
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
stop_progress

# --- 4. list everything found --------------------------------------------
ROWS=$(mktemp)
grep -oE '\[NEW\] Device ([0-9A-Fa-f:]{17})( .*)?' "$SCAN" 2>/dev/null |
    sed 's/^\[NEW\] Device //' |
    awk '{ mac=$1; $1=""; sub(/^ /,""); printf "%s\t%s\n", mac, ($0 == "" ? mac : $0) }' |
    sort -u >"$ROWS"
rm -f "$SCAN"

if [ ! -s "$ROWS" ]; then
    rm -f "$ROWS"
    zenity --info --title="$TITLE" --width=460 --ok-label="Close" \
        --text="No devices found.

Put the speaker into pairing mode and press Bluetooth again." 2>/dev/null
    exit 1
fi

LIST=$(mktemp)
cut -f2 "$ROWS" >"$LIST"
CHOSEN=$(zenity --list --title="$TITLE" --width=520 --height=320 \
    --ok-label="Connect" --cancel-label="Cancel" --column="Device" \
    --text="Choose the device to connect." <"$LIST" 2>/dev/null)
rm -f "$LIST"
[ -n "${CHOSEN:-}" ] || { rm -f "$ROWS"; exit 0; }

TARGET=$(awk -F'\t' -v n="$CHOSEN" '$2 == n { print $1; exit }' "$ROWS")
rm -f "$ROWS"
[ -n "$TARGET" ] || exit 1

# --- 5. pair, connect, route the audio -----------------------------------
start_progress "Connecting to $CHOSEN..."
cmd --timeout 25 pair "$TARGET" >/dev/null
cmd --timeout 10 trust "$TARGET" >/dev/null
cmd --timeout 20 connect "$TARGET" >/dev/null

MAC_U=$(printf '%s' "$TARGET" | tr 'a-z' 'A-Z' | tr ':' '_')
IDX=$(pactl list short sinks 2>/dev/null |
    awk -v m="$MAC_U" '{ n = toupper($2); if (index(n, m)) { print $1; exit } }')

if [ -n "${IDX:-}" ]; then
    pactl set-default-sink "$IDX" >/dev/null 2>&1
    for input in $(pactl list short sink-inputs 2>/dev/null | awk '{print $1}'); do
        pactl move-sink-input "$input" "$IDX" >/dev/null 2>&1
    done
fi
stop_progress

# --- 6. done -------------------------------------------------------------
if [ -n "${IDX:-}" ]; then
    zenity --info --title="$TITLE" --width=460 --ok-label="Done" \
        --text="Done.
$CHOSEN is connected and the audio is on it." 2>/dev/null
else
    zenity --info --title="$TITLE" --width=460 --ok-label="Done" \
        --text="Done.
$CHOSEN is paired, but it has not offered an audio output.

Switch it on or wake it, then press Bluetooth again." 2>/dev/null
fi
