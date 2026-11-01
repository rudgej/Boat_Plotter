#!/bin/bash
# Flash the WT32-ETH01 with esp32_ethernet_router (prebuilt, ESP-IDF v5.5.4).
# Usage:
#   ./flash.sh                 # write firmware, keep NVS (saved Wi-Fi creds)
#   ERASE=1 ./flash.sh         # full erase first (destroys saved settings)
set -e

cd "$(dirname "$0")/firmware"

# Find the USB serial adapter (FTDI / CP210x / CH340 / SLAB).
PORT=$(ls /dev/cu.* 2>/dev/null | grep -iE "usbserial|usbmodem|SLAB|wchusb|ch340|CP210|cu\." | grep -viE "bluetooth|BLTH" | head -1)

if [ -z "$PORT" ]; then
    echo "No USB serial adapter found."
    echo
    echo "Wire it to the WT32-ETH01 first (see SETUP.md):"
    echo "  adapter TX  -> board RXD (right header 2nd pin)"
    echo "  adapter RX  -> board TXD (right header 1st pin)"
    echo "  adapter GND -> board GND (right header 4th pin)"
    echo "  adapter 3V3 -> board 3V3 (left header 3rd pin)"
    echo "Then hold IO0 (right header 3rd pin) to GND and power on."
    echo
    echo "Detected ports:"
    ls /dev/cu.* 2>/dev/null || echo "  (none)"
    exit 1
fi

echo "Using port: $PORT"

if [ "${ERASE:-0}" = "1" ]; then
    echo "Erasing full flash..."
    esptool.py --chip esp32 --port "$PORT" erase_flash
fi

esptool.py --chip esp32 --port "$PORT" --baud 460800 write_flash \
    0x1000  bootloader.bin \
    0x8000  partition-table.bin \
    0xf000  ota_data_initial.bin \
    0x20000 esp32_eth_router.bin

echo
echo "Flash complete. Disconnect IO0 from GND, reset (tap EN->GND),"
echo "then open the serial console at 115200:"
echo "  screen $PORT 115200"
