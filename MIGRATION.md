# Boat Plotter — Migration to x86 (CWWK N100)

> Read top-to-bottom when the box has arrived and you're SSH'd in, aiming for a one-pass rebuild.
> `[TODO-CONFIRM]` = needs a value from you/the boat before proceeding.

## 0. Hardware & architecture

- **CWWK Fanless Industrial Mini PC** — Intel **N100**, **8 GB RAM**, **128 GB M.2 NVMe** (included),
  **2× DB9 COM (RS232/RS485, jumper-switchable)**, dual **2.5 GbE i226-V**, 2× HDMI + DP + USB-C,
  SIM slot, M.2 E-key, **12 V DC in**.
- **CAN / NMEA 2000:** CANable2 USB-CAN (STM32G431CB), **candlelight** firmware → kernel
  `gs_usb` → `can0`. Already re-flashed from slcan; see §5.
- **Second Wi-Fi:** the AIC8800 USB dongle (BoatNetwork AP).
- **Display:** existing HDMI touchscreen (ILITEK 222A:0001) — USB touch + HDMI.
- **Spare:** old 256 GB X15 NVMe is *not* boot; keep as spare.

**Decision: plain Debian 13 amd64 + Signal K + AvNav + KIP. No OpenPlotter, no OpenCPN**
(AvNav replaces OpenCPN; it talks to Signal K directly over WebSocket).

---

## 1. OS install

1. Debian 13 (Trixie) amd64 netinst, **no desktop yet**. Hostname `bossy`, user `pi` (sudo),
   disk = the 128 GB NVMe, **ext4** (installer default — journaling on). Enable SSH.
2. Static net (match old Pi): Wi-Fi uplink `192.168.1.50/24`; AP later `192.168.10.1/24`.
3. GRUB — disable NVMe APST (belt-and-braces vs idle wedge):
   - `/etc/default/grub` → append to `GRUB_CMDLINE_LINUX_DEFAULT`: `nvme_core.default_ps_max_latency_us=0`
   - `sudo update-grub && sudo reboot`
4. Base packages:
   ```
   sudo apt update && sudo apt install -y git curl wget htop lm-sensors \
     hostapd dnsmasq network-manager labwc kanshi squeekboard pcmanfm \
     libgtk-4-dev libgtk4-layer-shell-dev gcc pkg-config python3 python3-pip \
     bluez pipewire pipewire-pulse can-utils jq
   ```
   `[TODO-CONFIRM]` `dock.c` targets GTK4 layer-shell; if it's GTK3, install
   `libgtk-3-dev libgtk3-layer-shell-dev` instead (see `pi-dock/README.md` §1).

---

## 2. Signal K

1. Install per **signalk.org** (verify current URL; standard form):
   ```
   curl -sL https://raw.githubusercontent.com/SignalK/signalk-server/master/bin/install.sh | sudo bash
   ```
   (port **3000**)
2. Restore data (from this repo checkout):
   ```
   sudo cp -a pi-dock/pi-config/home/pi/.signalk/. /home/pi/.signalk/
   sudo chown -R pi:pi /home/pi/.signalk
   ```
   Restores KIP dashboards (`applicationData/users/boat/kip/11.0.0.json`), plugin configs
   (`derived-data.json`, `holdingtank-status.json`, `signalk-shelly2.json`), and the
   `holdingtank-status` plugin code.
3. Register `holdingtank-status` in `/home/pi/.signalk/package.json` dependencies, restart signalk.
4. First login: create user **`boat`** / **`bossy`** (admin).
   Recreate `/etc/signalk-automation.env` from `signalk-automation.env.example` (chmod 600).
5. Install **`signalk-to-nmea2000`** from *Appstore → Signal K plugins*, and enable its
   **`Wind (130306)`** conversion. This is what makes the plotter *transmit* on the N2K bus
   (§5) — without it Signal K only listens. Plugin config isn't captured by `snapshot-pi.sh`,
   so it's a one-off UI setup.

---

## 3. AvNav (no OpenCPN)

1. Per **avnav.eu** docs (add their Debian repo) → `sudo apt install avnav` (port **8080**).
2. Install the **ochartsng** plugin and **re-license the chart set** (fingerprint is machine-bound;
   this is the one unavoidable re-activation).

---

## 4. Restore the Pi config (with the x86 delta)

```
sudo cp -a pi-dock/pi-config/etc/. /etc/
sudo cp -a pi-dock/pi-config/usr/. /usr/
sudo cp -a pi-dock/pi-config/home/. /home/
sudo systemctl daemon-reload
```

**Enable:**
```
sudo systemctl enable boatnetwork.service boatnetwork-dnsmasq.service \
  can0-nmea2000.service can-watchdog.timer shelly-watchdog.timer \
  holding-tank-dump.service cockpit-light.service memwatch.timer \
  set-timezone.timer bt-hifi.service
```

**Delete / don't enable (Pi-specific):**
`gpu-noidle.service`, `nvme-noidle.service`, `diagwatch.service`,
`opencpn-hdmi.service.d`, `opencpn-headless.service.d` (no `config.txt` on x86 — GRUB is §1.3).

`signalk.service.d/override.conf` (`Wants=`/`After=` can0-nmea2000) **stays**.

---

## 5. CAN / NMEA 2000 (CANable2 replaces the MCP2515 HAT)

> **Adapter is already provisioned — nothing to flash on the N100.** The CANable2
> (Openlight Labs, STM32G431CB, s/n `207C3283594B`) has been re-flashed from `slcan` to
> **candlelight**, so Linux sees a `gs_usb` device and the kernel creates `can0` by itself.
> The steps below only pin the name, confirm it, and wire it up.

**How it presents itself in each mode:**

| Mode | USB ID | Linux sees | Use |
|---|---|---|---|
| **candlelight** ← current | `1d50:606f` | `can0` via kernel `gs_usb`, **no daemon** | Signal K N2K **and** CAN analysis |
| slcan (old) | `16d0:117e` | `/dev/ttyACM0`, needs `slcand` | serial-only CAN tools on other OSes |

In candlelight mode there is **no `/dev/ttyACM*`** — that is correct, not a fault. The
**USB serial number changes too**: `207C3283594B` (the slcan firmware's string) becomes the
STM32 96-bit UID `0048004C594B500920343237`. Another reason the udev rule keys off
`DRIVERS=="gs_usb"` rather than a serial or VID:PID.

1. **udev rule** — committed at `pi-dock/pi-config/etc/udev/rules.d/70-canable.rules`,
   so §4's `cp -a pi-dock/pi-config/etc/. /etc/` installs it. It matches the *driver*, not a
   VID:PID, so a reflash or a replacement dongle still lands on `can0`:
   ```
   ACTION=="add", SUBSYSTEM=="net", DRIVERS=="gs_usb", NAME="can0"
   ```
   `sudo udevadm control --reload`
2. `can0-nmea2000.service` is **already generic**
   (`ip link set can0 up type can bitrate 250000 restart-ms 100`) — no edit.
3. `/usr/local/bin/can-watchdog.sh` still contains an MCP2515 IRQ-storm block (greps
   `/proc/interrupts` for `spi0.0`). On the N100 that grep returns nothing, the arithmetic
   collapses to `0`, and the check never fires — **harmless, leave it or delete it**. The
   missing / not-UP / BUS-OFF checks above it are what matter, and they work unchanged.
4. **Signal K → N2K data connection.** `settings.json` is *not* captured by
   `snapshot-pi.sh`, so this is the one thing that must be recreated by hand. Once:
   *Data Connections → Add → NMEA 2000*, then:
   - **Connection type:** `SocketCAN`
   - **CAN interface:** `can0`
   - leave the rest at defaults → **Enable** → **Save**.

   Sanity check ~10 s later: `curl -s localhost:3000/signalk/v1/api/vessels/self/navigation`
   should be updating.
5. Reboot or `sudo udevadm trigger`, then:
   ```
   ip -details link show can0   # expect state UP, can state ERROR-ACTIVE, bitrate 250000
   candump -t d can0 | head -5  # raw N2K frames
   ```
   If `can0` is missing → `lsusb | grep 1d50:606f` (adapter not in candlelight mode).
   If it is BUS-OFF on a live bus → wiring/termination, see below.

**Termination and wiring — check before the first power-up on the boat**

- The CANable2 has an **onboard 120 Ω switch**: **towards the board edge = OFF**.
  This adapter is a *drop* onto an already-terminated NMEA 2000 backbone, so it **must be
  OFF**. CAN_H↔CAN_L across the unpowered backbone should read **~60 Ω**; ~120 Ω means a
  missing terminator, ~40 Ω means three.
- NMEA 2000 micro-C: **pin 4 = CAN_H (white)**, **pin 5 = CAN_L (blue)**,
  **pin 2 = NET-S / GND (black)**. Do **not** connect pin 3 (12 V+). The CANable2 is
  **non-isolated**, so carry NET-S through to its GND terminal.

**Analysing traffic while Signal K is running.** `socketcan` is multi-listener, so you do
not need to stop Signal K to sniff:
```
candump -L can0                             # log format
candump -L can0 | analyzer -json | jq .     # canboat PGN decode
canbusload can0@250000
```
Wireshark/tshark on `can0` works too (NMEA 2000 dissector included).

⚠️ Address it as `socketcan` (`can0`), **never** via `python-can`'s `interface="gs_usb"`.
The firmware declares a **170 MHz** CAN clock (correct for the G431 — it is in the binary as
`0x0A21FE80` in the bit-timing table), and the `gs_usb` Python helper only carries hard-coded
timing tables for 48 MHz and 80 MHz clocks, so it dies with *"No suitable bit timings found"*.
The Linux kernel instead computes timings from the firmware's own constraints
(BRP 1–512, TSEG1 2–256, TSEG2 2–128), which resolves 250 kbit/s to BRP 40 / TSEG1 14 /
TSEG2 2 = 88.2 % sample point. `can0` at 250 kbit/s is fine; only that Python path is not.

**Transmitting onto the bus — the plotter is a node, not just a tap**

`can0` is brought up as a normal interface (not listen-only), so `canboatjs` can put frames
on the bus. This was verified on the actual adapter: **100 % TX-complete at 5 Hz and again at
50 Hz while simultaneously receiving ~51 f/s, with zero error frames.**

Wire it up with the **`signalk-to-nmea2000`** plugin (Signal K → Appstore). Its built-in
`Wind (130306)` conversion maps `environment.wind.angleApparent` + `environment.wind.speedApparent`
to PGN **130306**, priority **2**, reference **Apparent**, broadcast to 255. The
`windTrueGround` / `windTrueWater` conversions cover the true-wind variants.

Two behaviours that matter:

- **N2K-sourced data is never re-transmitted.** The plugin deliberately drops any value whose
  source is NMEA 2000, so it can't echo another instrument's PGN back onto the bus. Wind must
  therefore enter Signal K from a non-N2K source — here the **ESP32 wind sensor over NMEA 0183/UDP
  10110**, which qualifies. Never enable *"Also send data that came from NMEA 2000"*.
  `[TODO-CONFIRM]` that the sensor's sentences land as `environment.wind.angleApparent` /
  `speedApparent` (MWV does; VWR gives true wind, which needs the `windTrueGround` conversion).
- **The plotter claims an address and becomes a visible node.** `canboatjs` performs ISO Address
  Claim (PGN 60928, using null address 254 while claiming), so other instruments will see the
  plotter as a real device. Address clashes show up under *Data → Source Discovery*.

**Switching back to `slcan`** — only needed if a CAN tool on a *different* machine speaks
serial rather than socketcan. Hold **BOOT**, plug in, then
<https://canable.io/updater/canable2.html> → *slcan with FD support* → Connect and Update
(~30 s, reversible). ⚠️ Do **not** use mainline `candle-usb/candleLight_fw`: it explicitly
does not support STM32G431 yet. The canable.io *candlelight* build for CANable 2.0 is the
only correct one for this hardware — a verified copy plus the re-flash commands live in
[`pi-dock/canable2/`](pi-dock/canable2/README.md) so it works offline on the boat.

---

## 6. 2× RS485 (built-in DB9 COMs)

On-board SuperIO ports (`/dev/ttyS0`, `/dev/ttyS1`) — **stable across boots** (unlike USB serial).
Optional clarity symlinks:
```
# /etc/udev/rules.d/60-rs485.rules
KERNEL=="ttyS0", SYMLINK+="rs485-1"
KERNEL=="ttyS1", SYMLINK+="rs485-2"
```
1. Set both COMs to **RS485** via the board jumpers (default is RS232).
2. Signal K → Data Connections → Serial provider per port (`/dev/rs485-1`, `/dev/rs485-2`).
3. **Baud must match the instrument** `[TODO-CONFIRM]`: 4800 = classic NMEA 0183, 38400 = AIS/fast.
   Confirm what the old HAT's two RS485 lines actually fed.

---

## 7. Kiosk, dock & full app inventory

Rebuild the dock:
```
gcc dock.c -o pi-dock $(pkg-config --cflags --libs gtk4-layer-shell gtk4)   # GTK3 variant if needed
sudo install -m 755 pi-dock /usr/local/bin/pi-dock
```
`/etc/xdg/labwc/autostart` is unchanged and launches `pcmanfm`, `pi-dock`, `kanshi`,
`squeekboard`, then `launch-avnav.sh`.

**The dock's nine buttons → what each needs on x86** (all scripts restored via §4):

| Button | Script | Needs |
|---|---|---|
| AvNav | `launch-avnav.sh` | AvNav (§3), Chromium `--app` → `:8080` |
| Engine | `launch-kip.sh` | KIP / Signal K `:3000` |
| Weather | `launch-weather.sh` | Chromium → weather web app (no server install) |
| Seakeeper | `launch-seakeeper.sh` | `seakeeper-esp/` firmware on the ESP32 (repo) + its web UI |
| Spotify | `launch-spotify.sh` | Chromium → Spotify web (no server install) |
| Signal K | `launch-signalk.sh` | Signal K `:3000` |
| Grafana | `launch-grafana.sh` | `[TODO-CONFIRM]` Grafana server if it was running on the old Pi |
| Bluetooth | `bt-pair.sh` / `bt-hifi.service` | bluez + pipewire (§1.4) |
| Power | `poweroff.sh` | nothing — just `poweroff` |

- `launch-plotter.sh` = fullscreen plotter window (AvNav). Update ports in the launch scripts if the new box serves on different ones.
- Touchscreen: USB HID touch + HDMI on Intel i915 — out of the box.

---

## 8. BoatNetwork AP (AIC8800 USB dongle)

Config unchanged (`boatnetwork/` + `pi-config/etc/{hostapd,default,NetworkManager}`):
SSID `BoatNetwork` / `B0ssywifi`, box at `192.168.10.1`, DHCP `.100–.200`.
Keep `NetworkManager/conf.d/boatnetwork-unmanaged.conf`. The dongle may enumerate as `wlan1` —
confirm with `ip link` and adjust `boatnetwork-up.sh` if the name differs.

---

## 9. Shelly automation

- Restored via §2 + §4. Re-apply the **`units:bool` patch** to `signalk-shelly2`'s
  `dist/components/SwitchBase.js` (one-line removal; see `pi-dock/README.md` §7) after any plugin reinstall.
- Shelly devices unchanged (`.151` holding tank, `.142` cockpit light). Daemons are Python — run as-is.

---

## 10. Validation & soak

```
sudo systemctl status signalk avnav can0-nmea2000
ip -details link show can0
curl -s localhost:3000/signalk/v1/api/vessels/self | head
curl -sI localhost:8080 | head -1
candump -t d can0 | grep -m5 '"130306"\|130306'   # wind PGNs the plotter transmits
```
For the last one, cross-check that PGN 130306 is appearing with a **source address other than
the instruments'** — that's the plotter's own claimed address, and it proves the TX path end to
end. If it never appears, check the `signalk-to-nmea2000` plugin's `Wind (130306)` conversion is
enabled and that wind is arriving from a non-N2K source (see §5).

Then leave it idle 24–48 h. No 5V rail, no HAT, no Pi PMIC — the soak should simply pass.

---

## 11. Remote access (Tailscale)

Install **Tailscale** (WireGuard mesh VPN) so the box is reachable from anywhere — no port
forwarding, and it keeps working through marina Wi-Fi / phone hotspots where the uplink IP
changes or isn't routable:

```
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up            # add --ssh if you want key-based SSH via the tailnet
```

Log in at **login.tailscale.com**, then `tailscale ip` prints a stable `100.x.y.z` address.
From any device on your tailnet:

- Signal K → `http://<tailscale-ip>:3000`
- AvNav    → `http://<tailscale-ip>:8080`
- SSH      → `ssh pi@<tailscale-ip>`

Notes:

- This is a **system service**, not a Signal K plugin — it sits underneath everything, so it
  also gives you remote access for RS485/CAN/automation debugging.
- Free for personal use; runs as a systemd service and survives reboots.

---

## 12. Gemini checklist — what we adopted, what we corrected

1. **Persistent serial naming** — *adopted.* Built-in `ttyS*` are already stable; the only USB
   device (CANable) is pinned to `can0` by udev (§5.1). The `by-path`/`by-id` symlink advice
   matters for USB serial adapters; ours is built-in, so this is a non-issue but the symlinks are
   added anyway for clarity (§6).
2. **Baud rate 4800 / 38400** — *adopted as guidance.* The correct value is dictated by whatever is
   wired to each RS485 line, not by Signal K — `[TODO-CONFIRM]` (§6.3).
3. **ext4 + journaling** — *adopted.* Debian installer default (§1.1).
4. **Minimise disk writes** — *adopted lightly.* Set Signal K log level to info and skip aggressive
   voyage recording; on NVMe it's a longevity nicety, not a correctness fix.
5. **Plugins:**
   - `derived-data` — *already in use* (true wind etc.), restored with config (§2).
   - `holdingtank-status` — *already in use*, restored (§2).
   - **"Signal K to NMEA 0183" — NOT needed.** That plugin exists to feed NMEA 0183 *consumers*
     (e.g. OpenCPN over TCP/UDP). AvNav connects to Signal K natively over WebSocket, so installing
     it would be dead weight. Only add it if a future tool needs a raw 0183 feed.

---

## 13. Follow-up phases (deferred — do NOT build during the base rebuild)

These are planned but deliberately **not** part of the initial rebuild. Do them after the box is
fully running and verified:

- **Engine trend monitoring** — full locked spec at [`engine-trends/SPEC.md`](engine-trends/SPEC.md).
  Build `engine-trends.py` + systemd unit once Signal K is live and the two engines' N2K paths are
  visible in the `self` tree (instance→Port/Starboard mapping to be confirmed on the boat).
- Grafana / InfluxDB charting — optional, only if month-scale visual trends are wanted later.
