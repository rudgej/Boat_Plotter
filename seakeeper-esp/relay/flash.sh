#!/bin/bash
# Build and flash the SeaKeeper relay firmware onto the WT32-ETH01.
#
# The board has NO USB socket: it is programmed through its header pins with a
# 3.3 V USB-to-UART adapter and pogo pins. It also has no auto-reset circuit,
# so IO0 -> GND and an EN reset must be done by hand for every upload. This
# script walks you through both points where that matters.
#
# Usage:
#   ./flash.sh                        # build, upload, then open the monitor
#   ./flash.sh --no-monitor           # build and upload only
#   PORT=/dev/cu.usbserial-XXXX ./flash.sh
set -e
cd "$(dirname "$0")"

PIO="$HOME/.platformio/penv/bin/pio"
if [ ! -x "$PIO" ]; then
    echo "PlatformIO not found at $PIO"
    echo "Install it, or open this project in VS Code with the PlatformIO extension."
    exit 1
fi

echo "== Building =="
"$PIO" run

if [ -z "${PORT:-}" ]; then
    PORT=$(ls /dev/cu.* 2>/dev/null \
        | grep -iE "usbserial|usbmodem|SLAB|wchusb|ch340|CP210" \
        | grep -viE "bluetooth|BTH" | head -1)
fi

if [ -z "${PORT:-}" ]; then
    echo
    echo "No USB-to-UART adapter found."
    echo "Wire the pogo harness first (see ../SETUP.md section 1):"
    echo "  adapter TX  -> board RXD   (right header, 2nd pin)"
    echo "  adapter RX  -> board TXD   (right header, 1st pin)"
    echo "  adapter GND -> board GND   (right header, 4th pin)"
    echo "  adapter 3V3 -> board 3V3   (left header, 3rd pin)"
    echo
    echo "Detected ports:"
    ls /dev/cu.* 2>/dev/null || echo "  (none)"
    exit 1
fi

echo
echo "== Put the board in download mode now =="
echo "  1. Wire IO0 (right header, 3rd pin) to GND and LEAVE IT CONNECTED"
echo "  2. Tap EN (left header, 1st pin) to GND to reset"
echo "  There is no DTR/RTS auto-reset on this board, so this cannot be automated."
echo
read -r -p "Press Enter once IO0 is grounded and the board has been reset... " _

echo
echo "== Uploading to $PORT =="
"$PIO" run -t upload --upload-port "$PORT"

echo
echo "== Upload complete =="
echo "  1. DISCONNECT IO0 from GND - it is the RMII clock input, and leaving it"
echo "     grounded gives a reset loop"
echo "  2. Tap EN (left header, 1st pin) to GND to start the firmware"
echo

if [ "${1:-}" != "--no-monitor" ]; then
    echo "Opening the monitor at 115200 (Ctrl-C to exit)."
    "$PIO" device monitor --port "$PORT" --baud 115200
fi
