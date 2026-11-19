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

**Signal K security is on.** Reads are open; writes need a login. The user is `boat`; the password
is *not* in this repo — it lives in `/etc/signalk-automation.env` on the box, which is also what the
automation units use.

**Log into KIP** (Settings → Signal K → Connectivity → *Login to server*) before building
dashboards. Logged out, KIP keeps them in the browser's localStorage and they never reach the box.
Logged in, they are written to `~/.signalk/applicationData/users/boat/kip/` and survive a re-image.

## Hardware

CWWK Fanless Industrial Mini PC — Intel N100, 8 GB RAM, 128 GB M.2 NVMe, 2× RS232/RS485 COM, dual
2.5 GbE, 12 V DC. Replaces the Raspberry Pi 5, which died of a 5 V rail fault from the Waveshare CAN
HAT.

## Network

| Interface | Role |
|---|---|
| `wlp3s0` (onboard RTL8821CE) | Internet uplink. `Bossywifi` (priority 10), `3cpr` (priority 5). Currently `192.168.1.183` |
| `wlx6815790f593c` (BrosTrend AX900) | **BoatNetwork** access point, `192.168.10.1/24`, DHCP `.100–.200` |
| `enp2s0` | Seakeeper, `172.16.102.254/24`, `never-default` |
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

NMEA 2000 arrives via `can0`. NMEA 0183 arrives on three feeds configured in Signal K: the wind
sensor over UDP 10110, and two serial ports at 4800 and 38400 baud. **Signal K owns both serial
ports**; AvNav reads everything through Signal K rather than opening the ports itself.

## Repository layout

- **`MIGRATION.md`** — the full rebuild plan and the record of what was done. Start here.
- **`pi-dock/`** — the live plotter config: Signal K settings, KIP dashboards, dock launcher,
  BoatNetwork AP, Shelly automation, watchdogs. Full docs in **`pi-dock/README.md`**.
- **`engine-trends/`** — engine trend monitor: `SPEC.md` (locked spec), `engine-trends.py` (systemd
  daemon + Signal K publishing), `report.py` and the verification tools.
- **`n100/`** — x86 build kit: `bootstrap.sh`, `install-apps.sh`, USB installer scripts,
  `snapshot-n100.sh`, and the bathymetry base-map builder.
- **`signalk-zones/`** — `set-zones.py` writes the gauge bands; needs a login token, see `ZONES.md`.
- **`signalk-plugins/`** — the `enginetrends-status` plugin plus wind/GPS diagnostic scripts.
- **`seakeeper-esp/`** — ESP32 firmware for the Seakeeper interface.
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
3. **RS485 needs an auto-direction transceiver.** Both ports are wired and Signal K holds them
   open (`/dev/rs485-1`→`ttyS0` @4800, `/dev/rs485-2`→`ttyS1` @38400), but `ioctl(TIOCSRS485)`
   returns `ENOTTY`, so the UART cannot flip the driver direction in software.
4. **KIP will be signed out by any reboot.** Signal K signs tokens with a random key generated at
   startup unless `SECRETKEY` is set, so every restart invalidates them — verified: 200 before a
   restart, 401 after. Set `SECRETKEY` in the `signalk` unit environment to make logins stick.
5. **KIP dashboards are being rebuilt by hand** after the Pi died. The two surviving ones are in the
   repo, but the helm set is being recreated.
6. **Charts are licensed for France Mediterranean only** (o-charts, system `Bossy`, 101 cells).
7. **No satellite count.** Position arrives over N2K, so there is no NMEA 0183 `GSV` sentence and
   `navigation.gnss.satellites` stays empty — expected, not a fault.

## If the box boots to a bare login prompt instead of the kiosk

Check these in order — both have bitten us.

1. **Is the log redirect failing?** `~/.bash_profile` execs `labwc` and used to redirect to
   `/var/log/labwc.log`. `/var/log` is root-owned, so `pi` cannot create that file, bash never runs
   the `exec`, and you get the login prompt. It now logs to `~/labwc.log`. If `~/labwc.log` does not
   exist after a boot, the shell never got that far.
2. **Is the wrong VT in the foreground?** `sudo fgconsole` must print `1`. labwc can only take the
   display from the active terminal; if it has been switched to VT 2/3, labwc fails with
   `Timeout waiting session to become active` / `Failed to start a DRM session` and exits. Fix with
   `sudo chvt 1` then `sudo systemctl restart getty@tty1`.

HDMI output is **HDMI-A-2** on this box (`HDMI-A-1` is unconnected); it runs at 1920×1200.


## Rebuilding from scratch

Read `MIGRATION.md`. It covers the OS layer, app install, Wi-Fi and AP setup, DNS, Signal K data
connections and security, the Shelly and engine-trends services, the manuals sync, Seakeeper
Ethernet, charts and remote access.

