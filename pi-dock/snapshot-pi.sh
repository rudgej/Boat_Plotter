#!/bin/bash
cd /tmp
rm -f pi-config.tar.gz
sudo tar czf pi-config.tar.gz \
  /etc/hostapd/hostapd.conf \
  /etc/boatnetwork-dnsmasq.conf \
  /etc/default/hostapd \
  /etc/NetworkManager/conf.d/boatnetwork-unmanaged.conf \
  /etc/systemd/journald.conf.d/40-rpi-volatile-storage.conf \
  /etc/systemd/system/boatnetwork.service \
  /etc/systemd/system/boatnetwork-dnsmasq.service \
  /etc/systemd/system/bt-hifi.service \
  /etc/systemd/system/nvme-write-cache.service \
  /etc/systemd/system/memwatch.service \
  /etc/systemd/system/memwatch.timer \
  /etc/systemd/system/hostapd.service.d/restart.conf \
  /etc/systemd/system/opencpn-hdmi.service.d/clean-lock.conf \
  /etc/systemd/system/opencpn-headless.service.d/clean-lock.conf \
  /usr/local/bin/launch-plotter.sh \
  /usr/local/bin/launch-avnav.sh \
  /usr/local/bin/launch-grafana.sh \
  /usr/local/bin/launch-kip.sh \
  /usr/local/bin/launch-seakeeper.sh \
  /usr/local/bin/launch-signalk.sh \
  /usr/local/bin/launch-spotify.sh \
  /usr/local/bin/launch-weather.sh \
  /usr/local/bin/bt-hifi-connect.sh \
  /usr/local/bin/bt-pair.sh \
  /usr/local/bin/boatnetwork-up.sh \
  /usr/local/bin/memwatch.sh \
  /usr/local/bin/poweroff.sh \
  /usr/local/bin/get-boat-pos.sh \
  /usr/local/bin/fake-gps.sh \
  /usr/local/bin/can-watchdog.sh \
  /usr/local/bin/shelly-watchdog.sh \
  /usr/local/bin/holding-tank-dump.py \
  /usr/local/bin/cockpit-light.py \
  /usr/local/bin/set-timezone.py \
  /usr/local/bin/diagwatch.sh \
  /etc/systemd/system/can0-nmea2000.service \
  /etc/systemd/system/signalk.service.d/override.conf \
  /etc/systemd/system/can-watchdog.service \
  /etc/systemd/system/can-watchdog.timer \
  /etc/systemd/system/shelly-watchdog.service \
  /etc/systemd/system/shelly-watchdog.timer \
  /etc/systemd/system/holding-tank-dump.service \
  /etc/systemd/system/cockpit-light.service \
  /etc/systemd/system/set-timezone.service \
  /etc/systemd/system/set-timezone.timer \
  /etc/systemd/system/diagwatch.service \
  /home/pi/.signalk/node_modules/holdingtank-status/index.js \
  /home/pi/.signalk/node_modules/holdingtank-status/package.json \
  /home/pi/.signalk/plugin-config-data/signalk-shelly2.json \
  /home/pi/.signalk/plugin-config-data/derived-data.json \
  /home/pi/.signalk/plugin-config-data/holdingtank-status.json \
  /home/pi/.signalk/applicationData/users/boat/kip/11.0.0.json \
  /home/pi/.config/labwc/rc.xml \
  /etc/xdg/labwc/autostart \
  /boot/firmware/config.txt \
  /var/lib/avnav/avnav_server.xml \
  /usr/lib/udev/rules.d/aic.rules

# Regenerate the signalk-shelly2 switch-units patch (see README "Shelly switch").
(
  cd /home/pi/.signalk/node_modules/signalk-shelly2/dist/components
  diff -u SwitchBase.js.bak SwitchBase.js > /tmp/switchbase.patch || true
)

echo "=== tarball ==="
ls -la /tmp/pi-config.tar.gz /tmp/switchbase.patch
