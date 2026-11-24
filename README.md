# Boat plotter — Signal K / AvNav on a CWWK N100

Configuration, documentation and tooling for the boat's navigation box: a fanless N100 running
Debian 13, serving Signal K, AvNav, KIP dashboards, an offline manuals library and an engine trend
monitor. This replaces the Raspberry Pi 5 plotter build.

**State: live and in use.** Everything below was verified on the box on 2026-11-19 unless marked
otherwise.

## Access

All of these work from anywhere over Tailscale, and from the boat Wi-Fi without it (use
`bossy.local` in place of `bossy`).

| What | URL |
|---|---|
| Signal K admin | `http://bossy:3000` |
| **KIP dashboards** | `http://bossy:3000/@mxtommy/kip/` |
| **AvNav charts** | `http://bossy:8080/viewer/avnav_viewer.html` |
| Manuals (PDFs) | `http://bossy:8081` |
| o-charts manager | `http://bossy:8083/static/index.html` — **LAN only, see Known gaps** |
| Shell | `ssh pi@bossy` |
| Seakeeper UI | `http://192.168.0.2/` — DNAT'd to the ESP32 relay bridge by `seakeeper-redirect.service`; firmware lives in [esp-seakeeper-relay](https://github.com/rudgej/esp-seakeeper-relay) |

**Signal K security is on.** Reads are open; writes need a login. The user is `boat`; the password
is *not* in this repo — it lives in `/etc/signalk-automation.env` on the box, which is also what the
automation units use.

**Log into KIP** (Settings → Signal K → Connectivity → *Login to server*) before building
dashboards. Logged out, KIP keeps them in the browser's localStorage and they never reach the box.
Logged in, they are written to `~/.signalk/applicationData/users/boat/kip/` and survive a re-image.

## Accounts and SSH

Two human accounts exist, both with `NOPASSWD` sudo. No passwords are recorded in this repo.

| Account | uid | Notes |
|---|---|---|
| `pi` | 1001 | Created post-install; the account the laptops use |
| `boat` | 1000 | The original install account, and the name used for Signal K / KIP logins |

| Machine | Key | Authorised on |
|---|---|---|
| iMac | `~/.ssh/id_ed25519` (`jeremy@imac`) | `pi` |
| MacBook | `~/.ssh/id_boat` — **no passphrase** | `pi` and `boat` |

**Connect from the MacBook with `IdentitiesOnly=yes`:**

```sh
ssh -i ~/.ssh/id_boat -o IdentitiesOnly=yes pi@192.168.10.1
```

Without `IdentitiesOnly=yes` ssh offers the MacBook's default `id_ed25519` first, which *has* a
passphrase, and the session ends at a password prompt even though the correct key is authorised.
That cost an hour on 2026-11-21 — it is the whole reason this section exists.

### Which address

| Route | Address | Depends on |
|---|---|---|
| **The box's own BoatNetwork AP** | `192.168.10.1` | nothing — always present |
| Home Wi-Fi (`3cpr`) | `192.168.1.183` | being at home |
| mDNS | `bossy.local` | same subnet as the box |
| Tailscale | `100.102.160.120` | the box having internet |

`192.168.10.1` is an address the box **provides**, not one it receives, so it does not change when
the boat's router changes. It is the one to rely on at sea.

### Putting the box on the boat's Starlink network

First time only, and it needs a few minutes with no internet:

1. Join the **BoatNetwork** Wi-Fi and ssh to `192.168.10.1`.
2. On the box: `sudo nmcli device wifi connect "<starlink-ssid>" password "<password>"`
3. Switch the laptop back to the Starlink Wi-Fi.

After that the box joins Starlink on its own at boot, the laptop keeps its internet, and the AP stays
as a fallback. To avoid losing connectivity during step 2, tether the laptop over USB instead — the
AP has no gateway, so the phone becomes the default route while Wi-Fi still reaches the box.

## Hardware

CWWK Fanless Industrial Mini PC — Intel N100, 8 GB RAM, 128 GB M.2 NVMe, 2× RS232/RS485 COM, dual
2.5 GbE, 12 V DC. Replaces the Raspberry Pi 5, which died of a 5 V rail fault from the Waveshare CAN
HAT.

## Network

| Interface | Role |
|---|---|
| `wlp3s0` (onboard RTL8821CE) | Internet uplink. `Bossywifi` (priority 10), `3cpr` (priority 5). Currently `192.168.1.183` |
| `wlx6815790f593c` (BrosTrend AX900) | **BoatNetwork** access point, `192.168.10.1/24`, DHCP `.100–.200` |
| `enp2s0` | **Unused in normal operation.** The SeaKeeper sits behind the ESP32 relay bridge; its `192.168.0.254/24` profile is kept only for the direct-cable fallback |
| `enp4s0` | Second uplink — cable unplugged at time of writing |

**Tailscale** (WireGuard mesh, no port forwarding) is the remote-access path: `bossy` is
`100.102.160.120` / `bossy.taile75f3e.ts.net`, MagicDNS on, no subnet routes advertised. On the Mac,
`tailscale status` must be run from the real bundle path — a `/usr/local/bin` symlink crashes it, so
`~/.zshrc` has an alias instead.

## Services

| Unit | Port | Role |
|---|---|---|
| `signalk` | 3000 | Data hub, plugin host, security |
| `avnav` | 8080 | Chart plotter |
| `nginx` | 8081 | Offline manuals library (Dropbox-synced PDFs) |
| `ochartsng` provider | 8083 | o-charts licence manager |
| `engine-trends` | — | Engine trend monitor daemon (see `engine-trends/SPEC.md`) |
| `manuals-sync.timer` | — | Pulls Boat Manuals from Dropbox every 6 h |
| `can0-nmea2000` | — | Brings CAN up before Signal K starts |
| `tailscaled` | — | Remote access |
| `holding-tank-dump` | — | Auto sewage discharge (see Boat automations) |
| `cockpit-light` | — | Dusk-to-23:00 cockpit lighting |
| `bt-one-radio` | — | Keeps the internal Bluetooth radio pairable and the Wi-Fi dongle's Bluetooth off |
| `set-timezone.timer` | — | GPS-derived timezone, every 10 min |

NMEA 2000 arrives via `can0`. NMEA 0183 arrives on three feeds configured in Signal K: the wind
sensor over UDP 10110, and two serial ports at 4800 and 38400 baud. **Signal K owns both serial
ports**; AvNav reads everything through Signal K rather than opening the ports itself.

### Firmware updates (OTA)

The sensor firmware is updated from this box, over `BoatNetwork` only: each
device opens its OTA port while associated to the primary network and closes it
on `BoatNetwork2`.

```bash
pio run -e <env>                        # on the Mac: .pio/build/<env>/firmware.bin
scp .pio/build/<env>/firmware.bin pi@bossy.local:~/ota/
ssh pi@bossy.local '~/ota/ota_push.sh ~/ota/firmware.bin bossy-ota <address>'
```

| Device | Address | Version readback |
|---|---|---|
| Water level | `192.168.10.191` | `fw` in `/status` |
| Wind | `192.168.10.171` | `fw` in `/status` (from its next flash) |
| Generator temperature | `192.168.10.172` | `fw` in `/status` |
| CYD display | `192.168.10.154` | serial boot banner only |

Read the version back — `curl -s http://192.168.10.191/status | tr ',' '\n' | grep fw`
— because the uploader reporting success does not mean the new image is running.
Full procedure, partition notes and failure signatures: `MIGRATION.md` §8.10.

### Boat automations

Three custom Python scripts in `/usr/local/bin`, each run by systemd:

| Unit | What it does |
|---|---|
| `holding-tank-dump.service` | Auto sewage discharge: turns the dump switch **off** after its timeout, gated on SOG qualifying and a cooldown. Fails **safe** — if the switch cannot be read it does nothing. |
| `cockpit-light.service` | Light on at computed sunset (from GPS position), off at 23:00 local. If you switch it off manually that evening, it stays off until the next dusk. |
| `set-timezone.service` + `.timer` | Sets the system timezone from GPS position with `timezonefinder` (offline, no API key), then restarts `cockpit-light` so sunset is recomputed. |

**State as of 2026-11-20: all three run, none can act.** Both Shelly relays are absent from
BoatNetwork, so the plugin publishes no `electrical.switches` paths at all and the two switch
scripts read 404 (one per second, which also fills Signal K's access log). Independently,
`set-timezone` has no position to work from: no GPS provider is configured, and
`navigation.position` has metadata but has never carried a value. The timezone is set by hand.

The Shellies are `shellyplus1-e465b842fb34` @ `.151` (sewage) and `shellyplus1pm-441793d69434` @
`.142` (cockpit lights). When they return, **restart Signal K** — the plugin does not reconnect on
its own.

## Repository layout

- **`MIGRATION.md`** — the full rebuild plan and the record of what was done. Start here.
- **`seakeeper-link.md`** — the SeaKeeper Ethernet link, web UI and MQTT interface, measured on
  the boat 2026-11-21. The unit answers on `192.168.0.2`, not the `172.16.102.1` that
  `MIGRATION.md` §18 and `seakeeper-esp/SETUP.md` still describe.
- **`nmea2000-live-bus.md`** — the NMEA 2000 backbone measured on the boat 2026-11-24, the first
  time the N100 saw the real bus rather than a simulator. Device inventory by source address, full
  PGN table with rates, engine gateway data, what Signal K transmits back, and the known defects
  (fuel pressure ×1000, not-available reported as 0, truncated `127497`).
- **`pi-dock/`** — the live plotter config: Signal K settings, KIP dashboards, dock launcher,
  BoatNetwork AP, Shelly automation, Bluetooth speaker pairing, watchdogs. Full docs in
  **`pi-dock/README.md`**.
- **`engine-trends/`** — engine trend monitor: `SPEC.md` (locked spec), `engine-trends.py` (systemd
  daemon + Signal K publishing), `report.py` and the verification tools.
- **`n100/`** — x86 build kit: `bootstrap.sh`, `install-apps.sh`, USB installer scripts,
  `snapshot-n100.sh`, and the bathymetry base-map builder.
- **`stale-watchdog/`** — Signal K plugin that alerts when a data feed stops updating. Signal K has
  no native data expiry, so a dead GPS keeps showing its last value forever. Depth is treated as
  safety-critical (alarm, value blanked); GPS and wind are warnings. See its `README.md`.
- **`signalk-zones/`** — `set-zones.py` writes the gauge bands; needs a login token, see `ZONES.md`.
- **`signalk-plugins/`** — the `enginetrends-status` plugin plus wind/GPS diagnostic scripts.
- **`seakeeper-esp/`** — flashing kit for the Seakeeper bridge: a WT32-ETH01
  running [martin-ger/esp32_ethernet_router](https://github.com/martin-ger/esp32_ethernet_router)
  **unmodified**. `SETUP.md` has the wiring and configuration; `flash.sh` and the
  prebuilt binaries are here. That router firmware turned out to be the wrong
  tool — see below.
- **`seakeeper-signalk/`** — Signal K plugin that reads the gyro over MQTT and publishes roll,
  on/off, stabilise-available, stabilising, target rpm, actual rpm and an alarm flag at 1 Hz,
  using a single MQTT connection. See its `README.md` for the path mapping.
  The bridge firmware itself now lives in
  [esp-seakeeper-relay](https://github.com/rudgej/esp-seakeeper-relay) — PlatformIO/ESP-IDF,
  replaces the off-the-shelf router because that did destination-only NAT and left the unit
  ARPing a host that was never reachable. The protocol is documented there in
  `docs/seakeeper-protocol.md`.
- **`pi-dock/pi-config/home/pi/.signalk/settings.json`** — Signal K's own config (data connections
  and security). Without this a restored Signal K has no data connections at all.
- **`shelly-migration-baseline.md`** — Shelly switch migration notes.

## Known gaps

These are real and understood, not mysteries — details in `MIGRATION.md` §14.

1. **Engine trends has learned nothing yet.** The monitor runs and publishes correct live values,
   but the simulator idles at ~2848 rpm, *above Band 4's 2350 ceiling*, so nothing ever qualifies.
   Either run 1400–2100 rpm for ~45 min, or decide the real D12 cruises above 2350 and add a Band 5
   to `SPEC.md`.
2. **o-charts on `:8083` refuses tailnet clients.** TCP connects, then the provider never reads the
   request — sockets sit in `CLOSE-WAIT` with the bytes unread. LAN and localhost are fine. Workaround:
   `ssh -N -L 8083:127.0.0.1:8083 pi@bossy`, then use `http://localhost:8083`.
3. **RS485 pinout — SOLVED 2026-11-21: A/B are DB9 pins 2 and 3, ground on pin 5.** Never a software
   fault. Both UARTs transmit, and the kernel exposes no RS485 control (`ioctl(TIOCSRS485)` →
   `ENOTTY`), so direction switching is done in the transceiver. The decisive measurement was taken
   with COM1 transmitting and a meter on each pin against pin 5: **pin 1 sat dead at 0.00 V** while
   **pin 2 (1.64 V) and pin 3 (2.53 V)** both rested mid-rail — those are A and B. Pin 1 never carried
   anything, which is exactly what made the natural "pins 1 and 2" assumption fail, twice.
   A straight-through cable wired **2–2, 3–3, 5–5 with pin 1 unconnected** now loops back cleanly:
   `tx:32 rx:32` in both directions, payload intact, no A/B swap needed.
   `tools/rs485-loopback.py` performs the test, but **stop Signal K first** — it holds both ports open
   and swallows the bytes. **Instrument pinouts remain unknown**: do not assume a device's pin 2 is A
   just because this box's is; swap 2 and 3 at the instrument end if the data arrives garbled.
4. **KIP will be signed out by any reboot.** Signal K signs tokens with a random key generated at
   startup unless `SECRETKEY` is set, so every restart invalidates them — verified: 200 before a
   restart, 401 after. Set `SECRETKEY` in the `signalk` unit environment to make logins stick.
5. **KIP dashboards are being rebuilt by hand** after the Pi died. The two surviving ones are in the
   repo, but the helm set is being recreated.
6. **Charts are licensed for France Mediterranean only** (o-charts, system `Bossy`, 101 cells).
7. **No satellite count.** Position arrives over N2K, so there is no NMEA 0183 `GSV` sentence and
   `navigation.gnss.satellites` stays empty — expected, not a fault.

## If the box boots to a bare login prompt instead of the kiosk

Check these in order — all three have bitten us.

1. **Is the kernel console on tty1?** This was the real cause on 2026-11-19. `/etc/default/grub` had
   `GRUB_CMDLINE_LINUX="console=tty3"`, which makes **VT3** the displayed terminal at boot and
   auto-spawns `getty@tty3`. The kiosk still starts on tty1, but VT1 is not the foreground terminal,
   so labwc cannot take the display, dies, and you are left looking at the tty3 login prompt.
   It must be `console=tty1`. Verify with `cat /proc/cmdline`, fix with
   `sed -i 's/console=tty3/console=tty1/' /etc/default/grub && update-grub`, then reboot.
   The working file is captured at `pi-dock/pi-config/etc/default/grub`.
2. **Is `sudo fgconsole` printing `1`?** Even with the cmdline correct, a manual VT switch leaves
   labwc unable to start. Fix with `sudo chvt 1` then `sudo systemctl restart getty@tty1`.
3. **Is the log redirect failing?** `~/.bash_profile` execs `labwc` and used to redirect to
   `/var/log/labwc.log`. `/var/log` is root-owned, so `pi` cannot create that file, bash never runs
   the `exec`, and you get the login prompt. It now logs to `~/labwc.log`. If `~/labwc.log` does not
   exist after a boot, the shell never got that far.

`sudo fgconsole` and `/proc/cmdline` together explain almost every "no kiosk" case.

HDMI output is **HDMI-A-2** on this box (`HDMI-A-1` is unconnected); it runs at 1920×1200. Which
HDMI port you use is irrelevant to the kiosk — all VTs share every connected output.



## Rebuilding from scratch

Read `MIGRATION.md`. It covers the OS layer, app install, Wi-Fi and AP setup, DNS, Signal K data
connections and security, the Shelly and engine-trends services, the manuals sync, Seakeeper
Ethernet, charts and remote access.

Four packages are easy to miss because nothing fails loudly without them, and each breaks a
feature that is otherwise working:

| Package | Without it |
|---|---|
| `libspa-0.2-bluetooth` | no Bluetooth sink; the link fails with `br-connection-profile-unavailable` |
| `pulseaudio-utils` | no `pactl`, so a stream already playing cannot be moved to the speaker |
| `wlrctl` | the dock buttons cannot raise a window, so pressing one appears to do nothing (8 s of relaunching instead) |
| `btmgmt` (`bluez` tools) | no way to read or set the adapter's bonding settings |

