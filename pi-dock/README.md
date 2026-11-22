# Boat Pi ("Bossy") — Dock & Systems Configuration

This directory contains everything that runs on the boat's Raspberry Pi **5**
(hostname **`Bossy`**) beyond the wind-sensor firmware in the repo root. The Pi
is the boat's navigation/automation hub: Signal K, the KIP touch dashboard, a
launcher dock, the BoatNetwork Wi-Fi AP, a Shelly switch, and the holding-tank
discharge automation.

> The wind sensor firmware itself lives in the repo root (`src/`, `include/`,
> `platformio.ini`). This `pi-dock/` folder is the Pi-side configuration.

---

## 1. The box, at a glance

| Item | Value |
|---|---|
| Host / OS | Raspberry Pi 5, Debian 13, OpenPlotter 5.0.2 |
| User | `pi` (passwordless sudo) |
| SSH | `pi@192.168.1.47` (Ethernet, reliable) or `pi@192.168.1.50` (Wi-Fi, flaky) |
| Window manager | labwc (Wayland); panel `wf-panel-pi` |
| Dock | `/usr/local/bin/pi-dock` (GTK layer-shell, built from `dock.c`) |
| BoatNetwork AP | `wlan1` (AIC8800 dongle), Pi = `192.168.10.1`, SSID `BoatNetwork`, DHCP `.100–.200` |
| Signal K | `localhost:3000`, v2.33, **security enabled** |
| KIP | v4.8.5 at `/@mxtommy/kip/`, shared server-side config |
| Shelly | Shelly Plus 1, `192.168.10.151`, relay controls the holding-tank discharge |

### Credentials (not all in git — see §10)

- SSH: `pi` / (interactive password auth, key not set up)
- Signal K login: user **`boat`** (admin, R/W) — password not recorded here; see the local secrets file
- BoatNetwork Wi-Fi: SSID **`BoatNetwork`** — password not recorded here
- Shelly admin password: not tracked here (device-local)

---

## 2. Layout of this directory

- `pi-config/` — a **mirror of the Pi filesystem** with the deployed files
  (`etc/`, `usr/`, `home/`, `var/`). This is the source of truth to restore.
- `snapshot-pi.sh` — run **on the Pi**; tars the deployed files into
  `/tmp/pi-config.tar.gz` and regenerates `signalk-shelly2` patch. Copy it back
  and extract into `pi-config/`.
- `boatnetwork/` — BoatNetwork AP config (hostapd/dnsmasq/NAT) working copies.
- `dock.c` — source for the GTK layer-shell launcher dock (`pi-dock`): full-width
  bottom bar, text-only buttons (no icons) with vertical dividers, order
  AvNav · Engine · Weather · Seakeeper · Spotify · Signal K · Grafana · Bluetooth · Power.
- `launch-*.sh` — kiosk launchers (Chromium `--app` windows, `--start-fullscreen`).
- `kip-config.json` + `inject-kip*.mjs/sh` — KIP app-level config and injection tooling.
- `kip-config/` data lives in `pi-config/home/pi/.signalk/applicationData/users/boat/kip/11.0.0.json` (the actual dashboards).
- `memwatch.*`, `can-watchdog.*`, `shelly-watchdog.*`, `holding-tank-dump.*` — reliability/automation services (see §6).
- `signalk-shelly2-state-units.patch` — the one-line patch applied to the Shelly plugin (see §7).
- `holding-tank-dump.env.example` — template for the secrets file (the real one is NOT committed).
- `boot/firmware/config.txt` (in `pi-config/`) — includes `dtoverlay=ramoops-pi5` (crash capture).
- `etc/xdg/labwc/autostart` (in `pi-config/`) — starts desktop/panel/dock and auto-launches AvNav on boot.
- `diagwatch.*` — 2 s diagnostic logger (5V/core voltage, throttle flags, load) → `/var/log/diagwatch.log`.

---

## 3. Restoring / deploying to a Pi

`pi-config/` mirrors the Pi filesystem, so restoring is a matter of copying files
into place and enabling the units:

```bash
# from the repo root, on the Pi (adjust host/user)
scp -r pi-dock/pi-config/etc pi@192.168.1.47:/tmp/restore/etc   # etc
sudo cp -a /tmp/restore/etc/. /etc/
sudo cp -a /tmp/restore/usr/. /usr/
sudo cp -a /tmp/restore/home/. /home/
sudo systemctl daemon-reload
# enable the services/timers
sudo systemctl enable boatnetwork.service boatnetwork-dnsmasq.service
sudo systemctl enable can0-nmea2000.service can-watchdog.timer
sudo systemctl enable shelly-watchdog.timer memwatch.timer holding-tank-dump.service cockpit-light.service
# secrets file (never committed)
sudo cp pi-dock/signalk-automation.env.example /etc/signalk-automation.env
sudo nano /etc/signalk-automation.env   # set real password; chmod 600
# the holdingtank-status Signal K plugin must be installed & enabled
sudo mkdir -p /home/pi/.signalk/node_modules/holdingtank-status
sudo cp pi-dock/pi-config/home/pi/.signalk/node_modules/holdingtank-status/{index.js,package.json} \
        /home/pi/.signalk/node_modules/holdingtank-status/
# add it to /home/pi/.signalk/package.json dependencies and restart signalk
```

To **snapshot** (capture current Pi state into this repo):

```bash
scp pi-dock/snapshot-pi.sh pi@192.168.1.47:/tmp/
ssh pi@192.168.1.47 'bash /tmp/snapshot-pi.sh'
scp pi@192.168.1.47:/tmp/pi-config.tar.gz /tmp/
tar xzf /tmp/pi-config.tar.gz -C pi-dock/pi-config/   # run from repo root
```

---

## 4. Service inventory

| Unit | Type | What it does |
|---|---|---|
| `boatnetwork.service` / `-dnsmasq.service` | service | Bring up `wlan1` AP + DHCP (see §5) |
| `can0-nmea2000.service` | oneshot | Bring up `can0` at 250 kbit/s (`Before=signalk.service`) |
| `signalk.service` | service | Signal K server (`override.conf` makes it wait for `can0-nmea2000`) |
| `can-watchdog.timer` (10 s) | oneshot | Restarts CAN + Signal K if `can0` missing / not UP / BUS-OFF, or on an MCP2515 IRQ storm |
| `shelly-watchdog.timer` (60 s) | oneshot | Restarts Signal K when the Shelly plugin's WebSocket is stuck (rate-limited 1/5 min) |
| `holding-tank-dump.service` | simple | Holding-tank discharge automation daemon (§8) |
| `memwatch.timer` | oneshot | Logs memory/process snapshot to `/var/log/memwatch.log` |
| `diagwatch.service` | simple | 2 s diagnostic logger (voltage/throttle/load) → `/var/log/diagwatch.log` |
| `bt-one-radio.service` | oneshot | Keeps the internal radio pairable (bondable) and the dongle's Bluetooth off (§7a) |
| `nvme-write-cache.service` | service | NVMe write-cache tuning |

---

## 5. BoatNetwork AP (wlan1)

SSID `BoatNetwork`, Pi is `192.168.10.1`, dnsmasq hands out
`.100–.200`. Config in `boatnetwork/` and `pi-config/etc/`:

- `hostapd.conf`, `/etc/default/hostapd` — the AP itself
- `boatnetwork-dnsmasq.conf` — DHCP/DNS
- `boatnetwork-nat.sh` + `boatnetwork-nat.service` — masquerade NAT to the uplink
- `boatnetwork-up.sh` — interface bring-up
- `NetworkManager/conf.d/boatnetwork-unmanaged.conf` — keep NM off `wlan1`

---

## 6. CAN / NMEA 2000 reliability

On the Pi, `can0` was an MCP2515 SPI interface at 250 kbit/s. On the **N100** it is a
**CANable2** in candlelight mode, i.e. a kernel `gs_usb` socketcan interface pinned to
`can0` by `etc/udev/rules.d/70-canable.rules` — see `MIGRATION.md` §5. The reliability
plumbing is unchanged:

- **Boot ordering** — `can0-nmea2000.service` sets `Before=signalk.service`,
  and `signalk.service.d/override.conf` adds `Wants=`/`After=` for it, so Signal K
  never starts before the CAN socket exists.
- **`can-watchdog`** — a 10 s timer checks `ip -details link show can0` and
  restarts both `can0-nmea2000` and `signalk` if the interface is missing, not
  UP, or BUS-OFF. Logs to `/var/log/can-watchdog.log`.

`can-watchdog.sh` in this repo still carries the **MCP2515 IRQ-storm block** (it greps
`/proc/interrupts` for `spi0.0`). On the N100 that block is inert — `spi0.0` does not exist,
so it evaluates to zero and never restarts anything. Deleting it is cosmetic, not required.

Because `can0` is socketcan, you can sniff alongside Signal K without stopping it:
`candump -L can0`, or `candump -L can0 | analyzer -json` for decoded PGNs.

The interface is brought up **normal, not listen-only**, because the plotter also *transmits*:
wind data goes out as PGN 130306 via the `signalk-to-nmea2000` plugin. See `MIGRATION.md` §5.
Verified throughput on this adapter: 100 % TX-complete at 50 Hz with concurrent RX.

The ESP32 wind sensor also feeds Signal K over NMEA 0183/UDP on port **10110**
(see the repo-root README).

---

## 7. Shelly switches (holding tank + cockpit lighting)

Two Shellys on BoatNetwork, controlled through the `signalk-shelly2` plugin
(v2.2.0, Gen 2+ only):

| Shelly | IP | Signal K switch path |
|---|---|---|
| Plus 1 (holding-tank discharge) | `192.168.10.151` | `electrical.switches.shellyplus1-e465b842fb34.state` |
| Plus 1PM (cockpit lighting) | `192.168.10.142` | `electrical.switches.shellyplus1pm-441793d69434.state` |

Plugin config: `pi-config/home/pi/.signalk/plugin-config-data/signalk-shelly2.json`.
**Important:** the plugin only connects devices listed in `deviceConfigs` — a
new Shelly must be added there (id, address, hostname, model).

### The `units: bool` patch

KIP's switch picker was **empty** and rejected the switch path as "not
recognised". Root cause: the Shelly plugin tagged `state` with a non-standard
`units: 'bool'`, and KIP maps *any* units string to the `number` type, so the
switch was classified numeric instead of boolean (the switch picker only lists
booleans). The fix is a one-line change in the plugin's
`dist/components/SwitchBase.js` — remove the `units: 'bool'` meta. See
`signalk-shelly2-state-units.patch`:

```diff
-                meta: {
-                    units: 'bool'
-                },
+                meta: {},
```

This must be re-applied if the `signalk-shelly2` plugin is ever upgraded.
`snapshot-pi.sh` regenerates the patch from `SwitchBase.js.bak` each run.

### Shelly self-heal

`shelly-watchdog` restarts Signal K when **either** Shelly is reachable but the
plugin's WebSocket has ≥3 "not connected (state: 3)" errors in 90 s (rate-limited
to once per 5 min). Logs to `/var/log/shelly-watchdog.log`.

---

## 7a. Bluetooth speaker (dock button)

The **Bluetooth** button on the dock runs `/usr/local/bin/bt-pair.sh`. Music goes
to whatever speaker it connects: the speaker is set as the default output *and*
the stream that is already playing is moved onto it.

The flow, deliberately this simple:

1. Press **Bluetooth**.
2. If something is connected: `Connected to X. — Remove it and pair another
   device?` — **[Remove] / [Cancel]**. Cancel changes nothing.
3. `Put the device into pairing mode. — Press Start to begin the search.`
   Nothing is scanned until Start, so the speaker really is in pairing mode.
4. A pulsating window stays up for the whole search; only Cancel or the search
   finishing closes it.
5. Every device found is listed, unfiltered. Pick one.
6. It pairs, connects, routes the audio, and says `Done`.

### Packages this needs (not installed by default)

| Package | Why |
|---|---|
| `libspa-0.2-bluetooth` | without it PipeWire cannot offer a Bluetooth sink; the link dies with `br-connection-profile-unavailable` |
| `pulseaudio-utils` | provides `pactl`, the only tool here that can move a *playing* stream (`wpctl` cannot) |

### Five traps, each measured on this box

1. **`bluetoothctl --timeout N` blocks for the full N even when the command has
   already succeeded.** Measured: `--timeout 10 info` takes 10,030 ms; the same
   query without it takes 17 ms. Never put it on a query, and never use it to
   sequence `pair` → `trust` → `connect`: that inserted a 28-second gap, the
   speaker leaves pairing mode as soon as it is bonded, and the connect then
   fails with `br-connection-refused`. Pair, wait only until `Paired: yes`, then
   connect at once — measured bond-to-audio-output 57 ms.
2. **A device BlueZ already knows is reported as `[CHG] Device`, not `[NEW]
   Device`.** Matching only `[NEW]` produced "no devices found" while the
   speaker was advertising at −26 dBm.
3. **A default sink alone moves nothing.** Sounds already playing stay on the old
   output, which is why pairing appeared to succeed with no music. Use
   `pactl move-sink-input`.
4. **Dialogs open behind the fullscreen kiosk apps**, so a tap lands on the app
   behind and "Close" appears dead. Raise each dialog with
   `wlrctl window focus app-id:zenity` once it exists, and never give a dialog a
   `--timeout` — it closes itself and then a later box looks like it appeared at
   random.
5. **A backgrounded `zenity` gets stdin from `/dev/null`**, so `zenity --list <
   rows` shows an empty box. Run dialogs in the foreground; raise them from a
   detached helper instead.

### Two radios, and the reason pairing never survived a reboot

The box has two Bluetooth adapters, `bossy #1` (`00:A6:2B:DC:22:1F`, onboard)
and `bossy #2` (`0B:3B:22:AC:88:20`, the AIC8800D80 USB stick that also provides
the BoatNetwork access point). BlueZ's default controller changed after a
`systemctl restart bluetooth`, and pairing history is per-radio:
`/var/lib/bluetooth/<controller>/<device>`.

`bt-one-radio.service` runs `bt-one-radio.sh` at boot and settles it: any
controller whose address has the locally-administered bit set (a generated
address, i.e. the dongle) is powered off, and the one with a hardware address is
made pairable. Its Wi-Fi is left alone — `BoatNetwork` stays `activated`.

The speaker pairing did not persist, and the fault was on the adapter, not the
speaker:

```text
Pairable: no    current settings: powered ssp br/edr le secure-conn
Pairable: yes   current settings: powered bondable ssp br/edr le secure-conn
```

`bondable` is only present while the adapter is **pairable**, and only a bondable
adapter writes a `[LinkKey]`. With bonding off the speaker paired, played, and
the key was never stored — so it was forgotten at power-off. Proof: no device on
this box had ever had a `[LinkKey]` saved. Setting `Pairable` over D-Bus turns
bonding on; nothing else needs setting. After pairing once with it on:

```text
Paired: yes  Bonded: yes  Trusted: yes
[LinkKey] Key=A113… Type=4          # /var/lib/bluetooth/<ctrl>/<mac>/info
```

What then keeps it working across a reboot, and why: the key file above, the
device being **trusted** (so it may re-connect without asking), and
WirePlumber's saved default sink
(`~/.local/state/wireplumber/default-nodes`), which points at
`bluez_output.88_C6_26_C9_DD_0A.1`. The speaker re-connects itself on power-up.

Two commands to diagnose it:

```sh
sudo grep -l LinkKey /var/lib/bluetooth/*/*/info   # none = nothing has ever bonded
bluetoothctl show | grep -E 'Pairable|Powered'     # Pairable: no = the cause
```

A corrupt bond can be cleared with:

```sh
sudo systemctl stop bluetooth
sudo rm -rf /var/lib/bluetooth/*/88:C6:26:C9:DD:0A     # the device's MAC
sudo systemctl start bluetooth
```

### Two more traps, from making that boot service reliable

6. **`btmgmt` hangs when run as a systemd unit** — indefinitely, not slowly. The
   same call over SSH takes 14–20 ms. `bluetoothctl power off` fed from a pipe
   behaves the same way. The boot script therefore uses `busctl` only; it was
   measured at 161 ms for the whole unit, against 45 s when it used `btmgmt`.
7. **`udevadm settle` waited its full 30 s timeout on every start here**, even
   though nothing was still appearing. Waiting for the adapter objects with a
   short bounded loop is faster and cannot stall the boot.

Files: `pi-config/usr/local/bin/bt-pair.sh`,
`pi-config/usr/local/bin/bt-one-radio.sh`,
`pi-config/etc/systemd/system/bt-one-radio.service`.

---

## 8. Holding-tank discharge automation

A Python daemon (`holding-tank-dump.py`, systemd `holding-tank-dump.service`)
polls Signal K every second and implements:

1. **Always-on 5-minute auto-off** — whenever the switch is ON it is turned OFF
   after 5 minutes, unless you turn it off yourself or the automation does.
2. **Automatic discharge** — the switch is turned ON when:
   - SOG has been **> 7 kn continuously for 5 minutes**, **and**
   - the last auto discharge was **≥ 24 h ago**.
   It is turned OFF **immediately** if SOG drops **≤ 7 kn**.

The 24-hour gate is persisted to `/home/pi/.holding-tank-dump/state.json` so a
reboot doesn't reset it. Safe defaults: if the daemon starts and the switch is
already on, it closes it within a second (unknown how long it was open); if SOG
is unavailable during an auto discharge it closes the valve.

Tuning is via environment (`/etc/signalk-automation.env`, see
`signalk-automation.env.example`): `THRESHOLD_KNOTS=7.0`,
`QUALIFY_SECONDS=300`, `DUMP_SECONDS=300`, `COOLDOWN_SECONDS=86400`,
`POLL_SECONDS=1.0`. There is also `DRY_RUN=1` to log actions without touching
the valve (safe for testing).

### Companion plugin: `holdingtank-status`

Signal K only accepts writes to paths a plugin owns, so a tiny plugin
(`pi-config/home/pi/.signalk/node_modules/holdingtank-status/`) registers put
handlers for the status paths and stores the values. Enabled via
`plugin-config-data/holdingtank-status.json`.

### Status paths (shown in KIP)

| Path (`self.…`) | Type | Meaning | KIP widget |
|---|---|---|---|
| `holdingTank.dumpTimeRemaining` | number | seconds remaining (0 idle) | Numeric |
| `holdingTank.dumpTimeRemainingText` | string | `"m:ss"` (empty idle) | Text |
| `holdingTank.dumpAutoActive` | string | `"ACTIVE"` while auto dumping, else `""` | Text |
| `holdingTank.lastAutoDump` | timestamp | last auto-discharge time (only after first dump) | Date & Time |

> KIP pickers filter by value **type**, so each value must be published in the
> type its widget lists (hence the number/string/timestamp split above). Boolean
> has no read-only display widget in KIP, which is why `dumpAutoActive` is text.

---

## 9. Cockpit lighting automation (dusk → 23:00)

A Python daemon (`cockpit-light.py`, systemd `cockpit-light.service`) turns the
cockpit light ON at **sunset** and OFF at **23:00 local time**.

- Sunset is computed **from the boat's GPS position** (`navigation.position`)
  with a solar algorithm, so it follows the boat wherever it is.
- 23:00 uses the system's **local time**. The Pi's clock is NTP-synced, and
  `set-timezone.timer` updates the timezone from the boat's GPS position every
  10 min (offline `timezonefinder` lookup), so "local time" follows the boat.
- **Manual override**: if you switch the light OFF yourself during the evening,
  it stays off for the rest of that evening — it won't be switched back on until
  the next dusk.
- It's still controllable anytime from KIP
  (`self.electrical.switches.shellyplus1pm-441793d69434.state`).

State (`suppress_until`, last auto-on date, last GPS position) is persisted to
`/home/pi/.cockpit-light/state.json`.

---

## 10. KIP dashboards & wind

- KIP v4.8.5, kiosk via `launch-kip.sh` (Chromium `--app`, fullscreen). The
  "Engine" dock button launches KIP.
- Dashboards are stored **server-side** per Signal K user:
  `~/.signalk/applicationData/users/boat/kip/11.0.0.json` (committed here).
  Both the helm kiosk and any laptop log in as `boat` so they share the config.
- Wind: the `derived-data` plugin (`plugin-config-data/derived-data.json`)
  computes **true** wind (`speedOverGround`, `angleTrueGround`, `directionTrue`,
  `directionGround`) from apparent wind + SOG/heading. Wind speeds display whole
  knots, angles whole degrees.

---

## 11. Secrets & what's deliberately NOT committed

- `/etc/signalk-automation.env` — real Signal K password; commit the `.example` only.
- Shelly admin password — device-local.
- Any Signal K `security.json` password hash — the hash file is not tracked, and
  the login password is deliberately not recorded here.

The committed `hostapd.conf` is **redacted** — `wpa_passphrase=CHANGE_ME_BOATNETWORK_PSK`.
Set the real passphrase on the box after restoring (`sudo nano /etc/hostapd/hostapd.conf`)
and never commit it. Note git history predates the redaction, so treat any
earlier commit as containing it.

---

## 12. Handy commands / handoff notes

```bash
# Signal K
ssh pi@192.168.1.47
sudo systemctl restart signalk
curl -s localhost:3000/signalk/v1/api/vessels/self | head

# login token for scripted writes
curl -s -X POST localhost:3000/signalk/v1/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"boat","password":"$SK_PASSWORD"}'

# automation
journalctl -u holding-tank-dump -f
journalctl -u can-watchdog -f
tail -f /var/log/can-watchdog.log /var/log/shelly-watchdog.log

# toggle the discharge valve manually (relay!)
TOKEN=$(curl -s -X POST localhost:3000/signalk/v1/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"boat","password":"$SK_PASSWORD"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -X PUT -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"value":true}' \
  localhost:3000/signalk/v1/api/vessels/self/electrical/switches/shellyplus1-e465b842fb34/state
```

### Known gotchas

- KIP path pickers are type-filtered; a widget only lists paths matching its
  type (see §8 table).
- `signalk-shelly2` only connects devices in `deviceConfigs`.
- Don't delete OpenCPN `chartlist.dat` on the Pi (startup hang).
- SSH default-password nag is suppressed (`/etc/profile.d/sshpwd.sh.disabled`).
- **Intermittent idle hangs (investigation 2026-11-03/04, NOT yet resolved)**: the
  Pi silently hangs after ~20 min–2.5 h **at idle**, never during active use. Measured
  with a 0.5 s monitor: no IRQ storm, 5 V stable, load ~0.06, no kernel panic
  (`pstore` empty). CAN reception was **ruled out** (crashed with `can0` down and the
  engine sim unpowered). Every crash ends with the disk returning **EIO**, which is what
  kills sshd (login needs disk) and Signal K static serving. Leading hypothesis:
  the **budget X15 NVMe SSD wedges at idle** (runtime PM / APST low-power states).
  Deployed: `nvme-noidle.service` (pins the SSD `power/control=on`) and
  `nvme_core.default_ps_max_latency_us=0` in cmdline (disables APST; needs a reboot to
  take effect). Also deployed `gpu-noidle.service` (GPU runtime PM off) — effect uncertain,
  it was the earlier theory. Remaining suspects: power delivery (dual supply) and the
  Waveshare CAN HAT. `ramoops` is enabled and captures any kernel panic to
  `/var/lib/systemd/pstore/` after a reboot. `can-watchdog` also detects MCP2515 IRQ
  storms (see §6).
- The Shelly Plus 1 reboots on power glitches (`reset_reason=1`); the watchdog
  and the daemon both tolerate brief outages.
