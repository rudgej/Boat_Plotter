# RPI Plotter

Boat computer on a Raspberry Pi 5 ("openplotter", Debian 13 trixie, OpenPlotter 5).
This repo is the **configuration and tooling record** for everything done to the
Pi outside of the standard OpenPlotter install — so we know what was changed, why,
and how to reproduce it on a fresh card.

> **Private repo** — contains boat-local credentials (e.g. the `BoatNetwork`
> Wi-Fi password). Do not make public.

---

## Hardware

- Raspberry Pi 5 (8 GB), NVMe boot ("X15 SSD 256GB" on PCIe).
- Display: 1920x1200 touchscreen; `labwc` Wayland compositor + Xwayland.
- Audio: display speakers via HDMI (vc4hdmi0).
- CAN: Waveshare CAN HAT (`can0`, 250 kbit/s) — also the board's 5V power source.
- USB WiFi dongle: aicsemi **AIC8800D80** (`a69c:5723` → `a69c:8d80`) — the
  `BoatNetwork` AP radio.

**⚠ Known issue:** the Pi is powered *through* the CAN HAT, which can't hold
5V/5A cleanly — this causes the under-voltage flag and flaky onboard Wi-Fi.
Feed the Pi directly (proper 5V/5A supply or a rated 12V→5V buck).

---

## Repo layout

| Folder | What it is |
|--------|-----------|
| `dock/` | The bottom GTK layer-shell dock (`dock.c`) + power button script |
| `kiosk/` | Chromium kiosk launchers for each dock app |
| `boatnetwork/` | The `BoatNetwork` AP config (hostapd + dnsmasq + systemd) |
| `bluetooth/` | Bluetooth hifi pairing/connect scripts + service |
| `kip/` | KIP engine dashboard config + localStorage injector |
| `diagnostics/` | Memory watchdog, persistent-journal notes, CDP test scripts |
| `logo/` | Fairline splash/logo assets and generators |
| `misc/` | OpenCPN chart helpers and old panel config |
| `pi-config/` | **Live snapshot** of the Pi's `/etc`, `/usr/local/bin`, etc. |

---

## The dock

`dock/dock.c` builds a GTK3 + gtk-layer-shell bottom bar (OVERLAY layer, 56 px
exclusive zone). Buttons, left to right:

**Plotter · Signal K · Grafana · AvNav · Weather · Seakeeper · Engine · Spotify · Bluetooth · Power**

Build & install on the Pi:

```bash
gcc dock.c -o pi-dock $(pkg-config --cflags --libs gtk+-3.0 gtk-layer-shell-0)
sudo cp pi-dock /usr/local/bin/pi-dock.new && sudo mv /usr/local/bin/pi-dock.new /usr/local/bin/pi-dock
```

The dock is respawned by `/etc/xdg/labwc/autostart` via `lwrespawn`. To reload a
new binary: `pkill -x pi-dock` (lwrespawn restarts it).

Chromium kiosk windows run as **native Wayland** (`--ozone-platform=wayland`),
so each needs a Maximize rule in `~/.config/labwc/rc.xml` matched by its `--class`
value (e.g. `<windowRule identifier="avnav-kiosk">`). Do **not** use `--kiosk` —
it overrides the Maximize rule.

---

## Kiosk apps

Each dock button runs a launcher in `/usr/local/bin/`:

| Button | Launcher | App | Port/URL |
|--------|----------|-----|----------|
| Plotter | `launch-plotter.sh` | OpenCPN | `DISPLAY :0`, configdir `~/.opencpn` |
| Signal K | `launch-signalk.sh` | Signal K web UI | `localhost:3000` |
| Grafana | `launch-grafana.sh` | Grafana | `localhost:3001` |
| AvNav | `launch-avnav.sh` | AvNav | `localhost:8080` |
| Weather | `launch-weather.sh` | Windy kiosk | `windy.com/?waves,lat,lon,10` |
| Seakeeper | `launch-seakeeper.sh` | Seakeeper web UI | `http://192.168.10.50/` (ESP32 bridge) |
| Engine | `launch-kip.sh` | KIP dashboard | `localhost:3000/@mxtommy/kip/` |
| Spotify | `launch-spotify.sh` | Spotify web player | `open.spotify.com` |
| Bluetooth | `bt-pair.sh` | hifi pairing wizard | — |

Launcher pattern: kill+relaunch for dashboards, **except Spotify** — it must
*not* be killed (Chromium single-instance focuses the existing window instead,
so music keeps playing).

---

## BoatNetwork AP

USB AIC8800 dongle is the AP radio (`wlan1`), onboard Wi-Fi (`wlan0`) stays on
the internet.

- SSID **BoatNetwork**, password **B0ssywifi**, subnet **192.168.10.0/24**.
- Pi: `192.168.10.1`, DHCP range `.100–.200` (leaves `.50/.60/.61` for
  ESP32/Shelly static addresses).
- Isolated by design (no NAT) — it's a device network for the ESP32 bridge and
  Shelly relays. Optional NAT files are in `boatnetwork/` but **not deployed**.

Services (all enabled):
- `boatnetwork.service` → runs `boatnetwork-up.sh` (waits for `wlan1`, assigns IP).
- `hostapd.service` (config `/etc/hostapd/hostapd.conf`) → the AP.
- `boatnetwork-dnsmasq.service` → DHCP/DNS on `wlan1`.

**Getting the dongle to work** (aicsemi AIC8800D80):
1. It first enumerates as USB storage `a69c:5723`; eject it to switch to
   `a69c:8d80` ("AIC Wlan"). `udev` rule `aic.rules` does this at boot.
2. The driver is out-of-tree: built from `shenmintao/aic8800d80` via DKMS
   (`install.sh` handles firmware + rules + DKMS + initramfs). Modules:
   `aic8800_fdrv` + `aic_load_fw`. Rebuilds automatically on kernel updates.

---

## Bluetooth hifi + Spotify

Spotify runs as a kiosk web player on the plotter screen (no phone). Audio goes
out HDMI by default, and auto-switches to the hifi over Bluetooth A2DP when
connected.

- `bluetooth/bt-pair.sh` — one-tap pairing (scans 25 s, pairs, saves MAC to
  `/etc/boat-hifi-mac`). Uses the **onboard** BT controller
  (`88:A2:9E:62:2A:93`); the dongle's BT (`0B:3B:…`) is unreliable.
- `bluetooth/bt-hifi.service` — on boot, connects the hifi and sets it as the
  PipeWire default sink.

**Critical audio fix:** OpenCPN was grabbing the HDMI ALSA device directly
(no `pipewire-alsa` bridge), which blocked Spotify's audio entirely
(play button did nothing). Fixed with `apt install pipewire-alsa` — now ALSA
`default` routes through PipeWire and everything shares the card.

Widevine DRM works out of the box on this Chromium 153 arm64
(`libwidevinecdm0` + component CDM in the kiosk profile).

---

## KIP engine dashboard

KIP (`@mxtommy/kip`) is installed as a Signal K webapp. The "Engine" dashboard
(4 radial gauges: RPM, oil pressure, coolant temp, oil temp) is in
`kip/kip-config.json`. It was injected into the kiosk profile's `localStorage`
via headless Chromium + CDP (`kip/inject-kip2.sh`).

KIP localStorage keys: `appConfig`, `connectionConfig`, `dashboardsConfig`,
`themeConfig`. Note: temperature unit string is `celsius`, pressure `bar`,
frequency `rpm`.

---

## Other fixes & diagnostics

- **NVMe corruption** (power cuts losing writes): disabled the drive's volatile
  write cache (`nvme set-feature -f 0x06 -V 0`), re-applied each boot by
  `nvme-write-cache.service`.
- **OpenCPN "safe mode" dialog**: `startcheck.dat` is removed pre-launch by
  `opencpn-*.service.d/clean-lock.conf` drop-ins.
- **OpenCPN charts FIFO collision**: patched the OpenCPN-side binaries to use
  `/tmp/OCPN_PIPEY` instead of the AvNav-used `/tmp/OCPN_PIPEX`.
- **Persistent journal**: RPi OS ships `Storage=volatile`; shadowed with
  `/etc/systemd/journald.conf.d/40-rpi-volatile-storage.conf` → `Storage=persistent`.
- **Memory watchdog**: `memwatch.timer` samples `free` + top processes every
  5 min to `/var/log/memwatch.log` (to catch an overnight leak).
- **`fake-gps.service`** was disabled (fixed position feed to AvNav, outranked
  Signal K).

---

## Re-snapshotting the Pi config

`diagnostics/snapshot-pi.sh` tars the key `/etc`, `/usr/local/bin`, and app
configs. Run it on the Pi and extract into `pi-config/` to refresh the record:

```bash
scp diagnostics/snapshot-pi.sh pi@<ip>:/tmp/
ssh pi@<ip> 'bash /tmp/snapshot-pi.sh'
scp pi@<ip>:/tmp/pi-config.tar.gz /tmp/
tar xzf /tmp/pi-config.tar.gz -C pi-config/
```

---

## Still to do (boat day)

- Pair the actual hifi (tap **Bluetooth**, put hifi in pairing mode).
- Confirm Seakeeper IP, flash the ESP32 bridge, join BoatNetwork.
- Proper 5V/5A power feed (fixes under-voltage + flaky Wi-Fi).
