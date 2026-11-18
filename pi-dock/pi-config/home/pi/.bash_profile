# Plotter kiosk: on the console (tty1) start the Wayland compositor directly.
# No desktop environment is installed. Ctrl+Alt+F2 gives a plain console.

# Silence the terminal bell. The hardware speaker is already blacklisted in
# /etc/modprobe.d/nobeep.conf; this covers the console/VT bell as well.
setterm -blength 0 2>/dev/null || true

if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ] && [ -x /usr/bin/labwc ]; then
    exec labwc
fi
