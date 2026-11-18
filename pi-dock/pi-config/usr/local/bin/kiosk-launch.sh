#!/bin/bash
# Shared helper for the kiosk launchers. Sourced, never executed directly.
#
# `kiosk_env` sets the *pi desktop session* environment. The launchers are run
# by the pi-dock button and by labwc autostart, where XDG_RUNTIME_DIR is NOT
# inherited (or is inherited as a stale value), and Chromium refuses to start
# with "Failed to connect to Wayland display" if it is wrong. Deriving it from
# the current uid keeps this correct no matter which user or uid the session
# ends up with.
#
# `kiosk_launch` starts Chromium as an app window. `--start-maximized`, not
# `--start-fullscreen`: a fullscreen window covers the whole output and ignores
# the dock's layer-shell exclusive zone, which hides AvNav's bottom toolbar
# behind the dock. Maximised is constrained to the usable area instead.
#
# Relaunching is also the only reliable way to raise a native-Wayland window
# (xdotool/wmctrl cannot see them).

kiosk_env() {
    export DISPLAY=:0
    export XAUTHORITY=/home/pi/.Xauthority
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
}

# kiosk_launch <window-class> <url> <profile-dir>
kiosk_launch() {
    local class="$1" url="$2" profile="$3"

    kiosk_env

    # Close any existing instance for this profile. Matching on the profile
    # directory targets exactly one app, so the buttons never kill each other.
    if pkill -f -- "--user-data-dir=${profile}" 2>/dev/null; then
        sleep 1
    fi

    nohup chromium \
        --app="$url" \
        --class="$class" \
        --ozone-platform=wayland \
        --start-maximized \
        --touch-events=enabled \
        --enable-virtual-keyboard \
        --no-first-run \
        --no-default-browser-check \
        --user-data-dir="$profile" \
        --password-store=basic >/dev/null 2>&1 &
}
