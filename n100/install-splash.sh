#!/usr/bin/env bash
# Replace the text boot console with the Fairline splash.
#
# What this suppresses:
#   * the GRUB menu          -> GRUB_TIMEOUT=0 + GRUB_TIMEOUT_STYLE=hidden
#   * kernel/systemd chatter -> quiet splash loglevel=3
#   * the blinking cursor    -> vt.global_cursor_default=0
#
# The splash image itself lives at n100/plymouth/splash.png and is generated
# from pi-dock/Fairline Nautical Crest Logo.png (light background, because the
# crest and wordmark are navy and would vanish on a dark one).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/plymouth"
THEME_DIR=/usr/share/plymouth/themes/fairline
GRUB=/etc/default/grub

[ -f "$SRC/splash.png" ] || { echo "ERROR: $SRC/splash.png missing" >&2; exit 1; }

apt-get install -y plymouth plymouth-themes

install -d "$THEME_DIR"
install -m 644 "$SRC/fairline.plymouth" "$THEME_DIR/fairline.plymouth"
install -m 644 "$SRC/fairline.script"   "$THEME_DIR/fairline.script"
install -m 644 "$SRC/splash.png"        "$THEME_DIR/splash.png"

plymouth-set-default-theme fairline

# Rewrite only the three settings we care about, keeping any other local edits.
if grep -q '^GRUB_TIMEOUT=' "$GRUB"; then
    sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=0|' "$GRUB"
else
    echo 'GRUB_TIMEOUT=0' >> "$GRUB"
fi

if grep -q '^GRUB_TIMEOUT_STYLE=' "$GRUB"; then
    sed -i 's|^GRUB_TIMEOUT_STYLE=.*|GRUB_TIMEOUT_STYLE=hidden|' "$GRUB"
else
    echo 'GRUB_TIMEOUT_STYLE=hidden' >> "$GRUB"
fi

CMDLINE='quiet splash loglevel=3 vt.global_cursor_default=0'
if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB"; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE\"|" "$GRUB"
else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE\"" >> "$GRUB"
fi

update-grub
update-initramfs -u

echo
echo "==> Active theme: $(plymouth-set-default-theme 2>/dev/null || echo '?')"
grep -E '^GRUB_(TIMEOUT|TIMEOUT_STYLE|CMDLINE_LINUX_DEFAULT)=' "$GRUB"
