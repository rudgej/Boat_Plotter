# Plotter kiosk: on the console (tty1) start the Wayland compositor directly.
# No desktop environment is installed. Ctrl+Alt+F2 gives a plain console.

# Silence the terminal bell (the hardware bell is also blacklisted in
# /etc/modprobe.d/nobeep.conf and no-beep.service zeroes the VT bell).
setterm -blength 0 2>/dev/null || true

if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ] && [ -x /usr/bin/labwc ]; then
    # Wipe anything the boot printed so the kiosk starts on a blank screen
    # instead of scrolling text. Errors still go to the journal.
    printf '\033[2J\033[H' > /dev/tty1 2>/dev/null || true
    # Log to $HOME, NOT /var/log. /var/log is root-owned (drwxr-xr-x), so pi
    # cannot create the file, bash cannot set up the redirect, exec never runs
    # and the shell exits - getty then re-prompts, and the box boots to a bare
    # login prompt with no kiosk. That is exactly what happened 2026-11-19.
    exec labwc >"$HOME/labwc.log" 2>&1
fi
