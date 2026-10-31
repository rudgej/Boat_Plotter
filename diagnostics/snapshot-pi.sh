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
  /home/pi/.config/labwc/rc.xml \
  /var/lib/avnav/avnav_server.xml \
  /usr/lib/udev/rules.d/aic.rules
echo "=== tarball ==="
ls -la /tmp/pi-config.tar.gz
