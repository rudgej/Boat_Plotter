# CANable2 firmware (offline copy)

The adapter ships/arrives as an **slcan** device. The plotter needs **candlelight**
(kernel `gs_usb` → `can0`), so the firmware is kept here so it can be re-flashed on the
boat with no internet.

| | |
|---|---|
| File | `canable2_fw-ba6b1dd.bin` (16,752 bytes) |
| SHA-256 | `81e6a6754a79843f6c8620c6a88b5646abf5c9723458e22b573fdab46d934bf8` |
| Source | <https://canable.io/builds/canable2/candlelight/canable2_fw-ba6b1dd.bin> |
| Target | CANable 2.0, STM32G431CB, flash base `0x08000000` |
| Result | USB `1d50:606f`, no serial port — Linux creates `can0` |

Verify the download before flashing:

```
sha256sum -c <<< "81e6a6754a79843f6c8620c6a88b5646abf5c9723458e22b573fdab46d934bf8  canable2_fw-ba6b1dd.bin"
```

## Flash

1. Unplug the adapter, hold **BOOT**, plug it back in. The LED glows dim = DFU mode.
2. `sudo apt install dfu-util` (Linux) / `brew install dfu-util` (macOS).
3. `sudo dfu-util -d 0483:df11 -a 0 -s 0x08000000:leave -D canable2_fw-ba6b1dd.bin`
4. Replug. `lsusb | grep 1d50:606f` on Linux, or `system_profiler SPUSBDataType | grep -A3 1d50` on macOS.

## Do not use mainline candleLight_fw

<https://github.com/candle-usb/candleLight_fw> states outright that **STM32G431-based
devices are not supported yet**. The canable.io build above is the only correct one for
this hardware.

## Going back to slcan

Only needed for a CAN tool on another machine that speaks serial instead of socketcan —
<https://canable.io/updater/canable2.html> → *slcan with FD support*. On Linux, slcan mode
appears as `/dev/ttyACM0` and needs `slcand`; it does **not** create `can0` on its own.
