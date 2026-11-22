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
# Set KIOSK_BROWSER to use a different binary (Spotify needs Google Chrome for
# its Widevine CDM; Debian's chromium ships none and cannot play DRM audio).
#
# Requires wlrctl (apt install wlrctl): pressing an app's button while it is
# already running raises its window instead of restarting it.
kiosk_launch() {
    local class="$1" url="$2" profile="$3"
    local browser="${KIOSK_BROWSER:-chromium}"
    # Window matcher for an already-running instance. Chromium's Wayland app_id
    # is derived from the URL, not from --class, so the default matches the host
    # name in the window title; override with a 4th argument when that is wrong.
    local match="${4:-title:${url#*//}}"
    match="${match%/}"

    kiosk_env

    # Already running? Ask the compositor to raise it.
    #
    # Both alternatives were measured and rejected: killing it first costs ~8 s
    # of cold start (which is why switching away and back felt dead), and simply
    # relaunching opens a *duplicate* window - two more MQTT connections against
    # a unit that only tolerates so many.
    #
    # KIOSK_RESTART=1 forces the old kill-and-restart for a misbehaving app.
    if [ "${KIOSK_RESTART:-0}" != "1" ] &&
       pgrep -f -- "--user-data-dir=${profile}" >/dev/null 2>&1; then
        if wlrctl window focus "$match" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if pkill -f -- "--user-data-dir=${profile}" 2>/dev/null; then
        sleep 1
    fi

    nohup "$browser" \
        --app="$url" \
        --class="$class" \
        --ozone-platform=wayland \
        --start-maximized \
        --touch-events=enabled \
        --enable-virtual-keyboard \
        --autoplay-policy=no-user-gesture-required \
        --no-first-run \
        --no-default-browser-check \
        --user-data-dir="$profile" \
        --password-store=basic >/dev/null 2>&1 &
}
