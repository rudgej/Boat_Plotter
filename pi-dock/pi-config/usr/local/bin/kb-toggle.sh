#!/bin/bash
# On-screen keyboard toggle for the kiosk.
#
# squeekboard is installed but unusable here: it needs the compositor to speak
# input-method-unstable-v1, which labwc does not implement, so it runs and never
# appears. wvkbd instead uses zwp_virtual_keyboard_v1 (already supported by
# wlroots), so it works with the same Chromium kiosk windows.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

if pgrep -x wvkbd-mobintl >/dev/null 2>&1; then
    pkill -x wvkbd-mobintl
    exit 0
fi

nohup wvkbd-mobintl -L 320 >/dev/null 2>&1 &
